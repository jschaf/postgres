/*-------------------------------------------------------------------------
 *
 * memcow_lanes.c
 *	  SQL surface for memcow lanes -- reset, open, retire, registry, status,
 *	  adopt -- and the authentication-time admission fence.
 *
 * A thin veneer over the lane functions in src/backend/storage/smgr/memcow.c
 * (see the LANES section there for the protocol and for why the control
 * plane lives in core).  This module exists because SQL-callable functions
 * need pg_proc rows and the core patch does not touch the catalogs: CREATE
 * EXTENSION provides them.
 *
 * TWO WAYS TO LOAD IT, and what each one gives:
 *
 *   CREATE EXTENSION alone      every SQL function below works.  The
 *                               admission fences in force are the pool's
 *                               wrapper invalidation and the PostgresMain
 *                               check (plan §5 I2, fences 1 and 3).
 *   shared_preload_libraries    additionally installs the
 *                               ClientAuthentication_hook nonce check
 *                               (fence 2 of 3): a connection string that
 *                               escaped the pool is refused at
 *                               authentication, before the server spends a
 *                               database startup on it and before the
 *                               backend is visible to a reset's fence.
 *
 * Where each function runs (plan §3):
 *   memcow_lane_reset / open / retire / register / unregister / status /
 *     catchup -- on the CONTROL connection, never in the lane concerned.
 *     Created in the control database by whoever drives the lanes.
 *   memcow_backend_reset / memcow_backend_counters -- in a LANE backend.
 *     Created in the lane databases by the SEED BUILDER (build_seed.sh), not
 *     at run time: anything created in a lane at run time is overlay content
 *     that the next reset discards, including the extension's own catalog
 *     rows.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * contrib/memcow_lanes/memcow_lanes.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "catalog/pg_database.h"
#include "fmgr.h"
#include "funcapi.h"
#include "libpq/auth.h"
#include "libpq/libpq-be.h"
#include "miscadmin.h"
#include "storage/memcow.h"
#include "storage/procsignal.h"
#include "utils/builtins.h"
#include "utils/injection_point.h"
#include "utils/inval.h"
#include "utils/syscache.h"
#include "utils/tuplestore.h"

PG_MODULE_MAGIC;

static ClientAuthentication_hook_type prev_client_auth_hook = NULL;

/* ----------------------------------------------------------------
 *		the authentication-time fence (plan §5 I2, fence 2 of 3)
 * ----------------------------------------------------------------
 */

/*
 * The nonce a startup packet presents, or 0.  ClientAuthentication() runs
 * before process_startup_options() has applied the packet's GUC settings, so
 * the memcow_lane_nonce variable is still its boot value here and the packet
 * has to be read directly: the "options" parameter (PGOPTIONS, split exactly
 * as process_startup_options() will split it) and any GUC pairs the packet
 * carried.  The last setting wins, as it does for GUCs.
 */
static void
memcow_lanes_match_nonce(const char *nv, uint32 *nonce)
{
	const char *eq = strchr(nv, '=');
	const char *name = "memcow_lane_nonce";
	size_t		len;

	if (eq == NULL)
		return;
	len = eq - nv;
	if (len != strlen(name))
		return;
	for (size_t i = 0; i < len; i++)
	{
		char		c = pg_ascii_tolower((unsigned char) nv[i]);

		if (c == '-')
			c = '_';
		if (c != name[i])
			return;
	}

	{
		char	   *end;
		unsigned long v = strtoul(eq + 1, &end, 10);

		if (end == eq + 1 || *end != '\0' || v > PG_INT32_MAX)
			*nonce = 0;			/* malformed: presents nothing */
		else
			*nonce = (uint32) v;
	}
}

static uint32
memcow_lanes_presented_nonce(Port *port)
{
	uint32		nonce = 0;

	if (port->cmdline_options != NULL)
	{
		int			maxac = 2 + (strlen(port->cmdline_options) + 1) / 2;
		char	  **av = palloc_array(char *, maxac);
		int			ac = 0;

		pg_split_opts(av, &ac, port->cmdline_options);
		for (int i = 0; i < ac; i++)
		{
			const char *nv = NULL;

			if (strcmp(av[i], "-c") == 0)
			{
				if (i + 1 < ac)
					nv = av[++i];
			}
			else if (strncmp(av[i], "-c", 2) == 0)
				nv = av[i] + 2;
			else if (strncmp(av[i], "--", 2) == 0)
				nv = av[i] + 2;
			if (nv != NULL)
				memcow_lanes_match_nonce(nv, &nonce);
		}
		pfree(av);
	}

	{
		ListCell   *lc = list_head(port->guc_options);

		while (lc != NULL)
		{
			char	   *name = lfirst(lc);
			char	   *value;
			char	   *nv;

			lc = lnext(port->guc_options, lc);
			if (lc == NULL)
				break;
			value = lfirst(lc);
			lc = lnext(port->guc_options, lc);

			nv = psprintf("%s=%s", name, value);
			memcow_lanes_match_nonce(nv, &nonce);
			pfree(nv);
		}
	}

	return nonce;
}

/*
 * ClientAuthentication_hook.  Runs after authentication proper and before
 * "connection authorized" is logged, the database startup lock is taken, or
 * the backend advertises its database in the ProcArray -- which is why this
 * cannot be the last fence (plan A.1.3) and why a refusal here is
 * distinguishable in the log: its DETAIL names this fence, and no
 * "connection authorized" line follows for the PID.
 */
static void
memcow_lanes_client_auth(Port *port, int status)
{
	uint32		presented;
	Oid			dbOid;
	uint32		nonce;
	MemcowLaneState state;
	MemcowAuthVerdict verdict;

	if (prev_client_auth_hook)
		prev_client_auth_hook(port, status);

	if (status != STATUS_OK)
		return;
	if (!memcow_enabled || port->database_name == NULL)
		return;

	presented = memcow_lanes_presented_nonce(port);
	verdict = memcow_lane_auth_check(port->database_name, presented,
									 &dbOid, &nonce, &state);

	switch (verdict)
	{
		case MEMCOW_AUTH_NOT_A_LANE:
			return;
		case MEMCOW_AUTH_ADMIT:
			break;
		case MEMCOW_AUTH_REFUSE_NOT_OPEN:
			ereport(FATAL,
					(errcode(ERRCODE_CANNOT_CONNECT_NOW),
					 errmsg("memcow lane for database \"%s\" is not open (state: %s)",
							port->database_name,
							memcow_lane_state_name(state)),
					 errdetail("Refused by the memcow_lanes authentication fence (plan §5 I2, fence 2 of 3).")));
			break;
		case MEMCOW_AUTH_REFUSE_NONCE:
			ereport(FATAL,
					(errcode(ERRCODE_CANNOT_CONNECT_NOW),
					 errmsg("memcow lane nonce mismatch for database \"%s\"",
							port->database_name),
					 errdetail("The connection presented nonce %u at authentication; refused by the memcow_lanes authentication fence (plan §5 I2, fence 2 of 3).",
							   presented)));
			break;
	}

	/*
	 * For the race tests (plan §7.3 a): a connection to a LANE that this
	 * fence admitted can be parked here, authenticated but not yet holding
	 * the database startup lock nor advertised in the ProcArray, while a
	 * reset runs past it.  Never fires for a database that is not a lane, so
	 * the control connection is unaffected.
	 */
	INJECTION_POINT("memcow-lanes-post-auth", NULL);
}

void
_PG_init(void)
{
	/*
	 * Only a preloaded library may install the hook: a backend that loads
	 * this module through CREATE EXTENSION or a function call has already
	 * been authenticated, and installing a hook there would affect nothing
	 * but leave a dangling function pointer in a library loaded per backend.
	 */
	if (!process_shared_preload_libraries_in_progress)
		return;

	prev_client_auth_hook = ClientAuthentication_hook;
	ClientAuthentication_hook = memcow_lanes_client_auth;
}

/* ----------------------------------------------------------------
 *		control-connection functions
 * ----------------------------------------------------------------
 */

/*
 * The lane's default tablespace and name.  The reset needs the tablespace
 * to locate the two per-database files it sweeps; memcow_lane_open records
 * the name for the authentication fence.  Catalog access stays here rather
 * than in memcow.c.
 */
static HeapTuple
lane_database_tuple(Oid dbOid)
{
	HeapTuple	tup;

	tup = SearchSysCache1(DATABASEOID, ObjectIdGetDatum(dbOid));
	if (!HeapTupleIsValid(tup))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_DATABASE),
				 errmsg("database with OID %u does not exist", dbOid)));
	return tup;
}

static Oid
lane_tablespace(Oid dbOid)
{
	HeapTuple	tup = lane_database_tuple(dbOid);
	Oid			spc = ((Form_pg_database) GETSTRUCT(tup))->dattablespace;

	ReleaseSysCache(tup);
	return spc;
}

PG_FUNCTION_INFO_V1(memcow_lane_reset_sql);
Datum
memcow_lane_reset_sql(PG_FUNCTION_ARGS)
{
	Oid			dbOid = PG_GETARG_OID(0);
	int32		timeout_ms = PG_GETARG_INT32(1);
	uint32		epoch;

	epoch = memcow_lane_reset(dbOid, lane_tablespace(dbOid), timeout_ms);
	PG_RETURN_INT64((int64) epoch);
}

PG_FUNCTION_INFO_V1(memcow_lane_open_sql);
Datum
memcow_lane_open_sql(PG_FUNCTION_ARGS)
{
	Oid			dbOid = PG_GETARG_OID(0);
	bool		arm = PG_GETARG_BOOL(1);
	HeapTuple	tup = lane_database_tuple(dbOid);
	char		datname[NAMEDATALEN];
	uint32		nonce;

	strlcpy(datname, NameStr(((Form_pg_database) GETSTRUCT(tup))->datname),
			sizeof(datname));
	ReleaseSysCache(tup);

	nonce = memcow_lane_open(dbOid, arm, datname);
	PG_RETURN_INT64((int64) nonce);
}

PG_FUNCTION_INFO_V1(memcow_lane_retire_sql);
Datum
memcow_lane_retire_sql(PG_FUNCTION_ARGS)
{
	memcow_lane_retire(PG_GETARG_OID(0));
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(memcow_lane_register_sql);
Datum
memcow_lane_register_sql(PG_FUNCTION_ARGS)
{
	memcow_lane_register(PG_GETARG_OID(0), PG_GETARG_INT32(1), true);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(memcow_lane_unregister_sql);
Datum
memcow_lane_unregister_sql(PG_FUNCTION_ARGS)
{
	memcow_lane_register(PG_GETARG_OID(0), PG_GETARG_INT32(1), false);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(memcow_lane_status_sql);
Datum
memcow_lane_status_sql(PG_FUNCTION_ARGS)
{
	Oid			dbOid = PG_GETARG_OID(0);
	MemcowLaneStatus st;
	TupleDesc	tupdesc;
	Datum		values[11];
	bool		nulls[11];

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	memcow_lane_status(dbOid, &st);

	memset(nulls, 0, sizeof(nulls));
	values[0] = CStringGetTextDatum(memcow_lane_state_name(st.state));
	values[1] = Int64GetDatum((int64) st.epoch);
	values[2] = Int64GetDatum((int64) st.nonce);
	values[3] = Int32GetDatum(st.nregistered);
	values[4] = Int64GetDatum(st.arena_bytes);
	values[5] = Int32GetDatum((int32) st.attached);
	values[6] = Int32GetDatum((int32) st.attached_old);
	values[7] = BoolGetDatum(st.reclaim_pending);
	values[8] = Int64GetDatum((int64) st.writes_discarded);
	values[9] = Int64GetDatum((int64) st.poisoned_pages);
	values[10] = Int64GetDatum(st.arena_limit);

	PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls)));
}

/*
 * memcow_lane_catchup(pid) -- a test helper: deliver a sinval catchup
 * interrupt to one backend, exactly as SICleanupQueue() would to a backend
 * that has fallen far behind.  An idle backend processes it on the spot
 * (ProcessClientReadInterrupt -> ProcessCatchupEvent), inside a transaction,
 * and rebuilds whatever relcache entries the queued messages name -- which
 * for a nailed catalog means reading its own database's pg_class.  That is
 * plan Appendix B(h)'s hazard, and §7.3 (e) wants it on demand rather than
 * after four thousand queued messages.  Superuser only, like
 * pg_terminate_backend's mechanism.
 */
PG_FUNCTION_INFO_V1(memcow_lane_catchup_sql);
Datum
memcow_lane_catchup_sql(PG_FUNCTION_ARGS)
{
	int			pid = PG_GETARG_INT32(0);

	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser to send a catchup interrupt")));

	if (SendProcSignal(pid, PROCSIG_CATCHUP_INTERRUPT, INVALID_PROC_NUMBER) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("could not signal backend %d: %m", pid)));

	PG_RETURN_VOID();
}

/* ----------------------------------------------------------------
 *		lane-backend functions
 * ----------------------------------------------------------------
 */

/*
 * The per-connection adopt call (plan §3.9, Appendix A.1.1).
 * InvalidateSystemCaches() discards relcache, catcache, the relation map
 * cache and -- via smgrreleaseall() -- this backend's attachment to the old
 * epoch; memcow_backend_adopt() then verifies that and reports the epoch.
 */
PG_FUNCTION_INFO_V1(memcow_backend_reset_sql);
Datum
memcow_backend_reset_sql(PG_FUNCTION_ARGS)
{
	InvalidateSystemCaches();
	PG_RETURN_INT64((int64) memcow_backend_adopt());
}

PG_FUNCTION_INFO_V1(memcow_backend_counters_sql);
Datum
memcow_backend_counters_sql(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	MemcowBackendCounters c;
	struct
	{
		const char *name;
		uint64		value;
	}			rows[7];

	InitMaterializedSRF(fcinfo, 0);
	memcow_get_backend_counters(&c);

	rows[0].name = "attaches";
	rows[0].value = c.attaches;
	rows[1].name = "detaches";
	rows[1].value = c.detaches;
	rows[2].name = "nblocks_pin_refresh";
	rows[2].value = c.nblocks_pin_refresh;
	rows[3].name = "truncate_pinned";
	rows[3].value = c.truncate_pinned;
	rows[4].name = "truncate_traversed";
	rows[4].value = c.truncate_traversed;
	rows[5].name = "truncate_allocated";
	rows[5].value = c.truncate_allocated;
	rows[6].name = "writes_discarded";
	rows[6].value = c.writes_discarded;

	for (int i = 0; i < lengthof(rows); i++)
	{
		Datum		values[2];
		bool		nulls[2] = {false, false};

		values[0] = CStringGetTextDatum(rows[i].name);
		values[1] = Int64GetDatum((int64) rows[i].value);
		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	PG_RETURN_VOID();
}
