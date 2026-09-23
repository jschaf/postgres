/*-------------------------------------------------------------------------
 * lanes.c -- preload registration, admission hooks, and lane SQL functions.
 *
 * shared_preload_libraries=memcow is required even when memcow.enabled=off.
 * CREATE EXTENSION installs the SQL interface and an ALWAYS ON login trigger.
 * The seed builder installs these in template1 before cloning the lanes, so
 * their catalog rows survive resets. Lane reset/open/registry calls run on
 * the control connection; backend_reset runs on each retained lane backend.
 *
 * Copyright (c) 2026, PostgreSQL Global Development Group
 * contrib/memcow/lanes.c
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "catalog/pg_database.h"
#include "catalog/dependency.h"
#include "catalog/objectaccess.h"
#include "catalog/pg_extension.h"
#include "catalog/pg_tablespace.h"
#include "commands/extension.h"
#include "commands/tablespace.h"
#include "commands/event_trigger.h"
#include "utils/guc.h"
#include "fmgr.h"
#include "funcapi.h"
#include "libpq/auth.h"
#include "libpq/libpq-be.h"
#include "miscadmin.h"
#include "memcow.h"
#include "storage/procsignal.h"
#include "utils/builtins.h"
#include "utils/injection_point.h"
#include "utils/syscache.h"

PG_MODULE_MAGIC;

static const f_smgr memcow_smgr =
{
	.smgr_init = memcow_init,
	.smgr_shutdown = NULL,
	.smgr_releaseall = memcow_release_stale_epochs,
	.smgr_open = memcow_open,
	.smgr_close = memcow_close,
	.smgr_create = memcow_create,
	.smgr_exists = memcow_exists,
	.smgr_unlink = memcow_unlink,
	.smgr_extend = memcow_extend,
	.smgr_zeroextend = memcow_zeroextend,
	.smgr_prefetch = memcow_prefetch,
	.smgr_maxcombine = memcow_maxcombine,
	.smgr_readv = memcow_readv,
	.smgr_startreadv = memcow_startreadv,
	.smgr_writev = memcow_writev,
	.smgr_writeback = memcow_writeback,
	.smgr_nblocks = memcow_nblocks,
	.smgr_truncate = memcow_truncate,
	.smgr_immedsync = memcow_immedsync,
	.smgr_registersync = memcow_registersync,
	.smgr_fd = memcow_fd,
	.volatile_storage = true,
};

static ClientAuthentication_hook_type prev_client_auth_hook = NULL;
static object_access_hook_type prev_object_access_hook = NULL;

/* ----------------------------------------------------------------
 *		the authentication-time fence (plan §5 I2, fence 2 of 3)
 * ----------------------------------------------------------------
 */

/*
 * The nonce a startup packet presents, or 0.  ClientAuthentication() runs
 * before process_startup_options() has applied the packet's GUC settings, so
 * the memcow.lane_nonce variable is still its boot value here and the packet
 * has to be read directly: the "options" parameter (PGOPTIONS, split exactly
 * as process_startup_options() will split it) and any GUC pairs the packet
 * carried.  The last setting wins, as it does for GUCs.
 */
static void
memcow_match_nonce(const char *nv, uint32 *nonce)
{
	char *name;
	char *value;

	ParseLongOption(nv, &name, &value);
	if (value != NULL && pg_strcasecmp(name, "event_triggers") == 0)
	{
		bool enabled;

		if (!parse_bool(value, &enabled) || !enabled)
			ereport(FATAL,
					(errcode(ERRCODE_CANNOT_CONNECT_NOW),
					 errmsg("memcow requires event_triggers=on at login")));
	}
	if (value != NULL && pg_strcasecmp(name, "memcow.lane_nonce") == 0)
	{
		char *end;
		unsigned long v = strtoul(value, &end, 10);

		*nonce = (end == value || *end != '\0' || v > PG_INT32_MAX) ? 0 : (uint32) v;
	}
	pfree(name);
	if (value != NULL)
		pfree(value);
}

static uint32
memcow_presented_nonce(Port *port)
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
				memcow_match_nonce(nv, &nonce);
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
			memcow_match_nonce(nv, &nonce);
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
memcow_client_auth(Port *port, int status)
{
	if (prev_client_auth_hook)
		prev_client_auth_hook(port, status);

	if (status != STATUS_OK)
		return;
	if (!memcow_enabled || port->database_name == NULL)
		return;

	if (IS_INJECTION_POINT_ATTACHED("memcow-skip-auth"))
		return;

	/* Database/role defaults must not disable the seed-backed login fence. */
	SetConfigOption("event_triggers", "on", PGC_SUSET, PGC_S_OVERRIDE);

	/*
	 * For the race tests (plan §7.3 a): a connection to a LANE that this
	 * fence admitted can be parked here, authenticated but not yet holding
	 * the database startup lock nor advertised in the ProcArray, while a
	 * reset runs past it.  Never fires for a database that is not a lane, so
	 * the control connection is unaffected.
	 */
	if (memcow_lane_auth_check(port->database_name, memcow_presented_nonce(port)))
		INJECTION_POINT("memcow-lanes-post-auth", NULL);
}

/* Core has already checked ownership and dependencies at OAT_DROP. */
static void
memcow_object_access(ObjectAccessType access, Oid classId, Oid objectId,
					 int subId, void *arg)
{
	if (prev_object_access_hook)
		prev_object_access_hook(access, classId, objectId, subId, arg);
	if (!memcow_enabled)
		return;

	if (access == OAT_DROP && classId == TableSpaceRelationId &&
		memcow_tablespace_in_use(objectId))
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("tablespace \"%s\" is not empty", get_tablespace_name(objectId))));

	/* A cleared dathasloginevt is shared state and would outlive lane reset. */
	if (!creating_extension && (access == OAT_DROP || access == OAT_POST_ALTER))
	{
		Oid ext = get_extension_oid("memcow", true);

		if (OidIsValid(ext) &&
			((classId == ExtensionRelationId && objectId == ext) ||
			 getExtensionOfObject(classId, objectId) == ext))
			ereport(ERROR,
					(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
					 errmsg("cannot modify memcow admission or control objects while enabled")));
	}
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
		elog(ERROR, "memcow must be loaded through shared_preload_libraries");

	DefineCustomBoolVariable("memcow.enabled",
		"Serve relation pages from a read-only seed plus an in-memory overlay.", NULL,
		&memcow_enabled, false, PGC_POSTMASTER, GUC_DISALLOW_IN_AUTO_FILE,
		NULL, NULL, NULL);
	DefineCustomStringVariable("memcow.seed_directory",
		"Directory holding the read-only PGDATA seed.", NULL,
		&memcow_seed_directory, "", PGC_POSTMASTER, GUC_SUPERUSER_ONLY,
		NULL, NULL, NULL);
	DefineCustomIntVariable("memcow.lane_nonce",
		"Lane nonce presented in the startup packet; zero presents none.", NULL,
		&memcow_lane_nonce, 0, 0, INT_MAX, PGC_BACKEND, 0,
		NULL, NULL, NULL);
	DefineCustomIntVariable("memcow.lane_arena_limit",
		"Maximum size of one lane-epoch arena; zero means no limit.", NULL,
		&memcow_lane_arena_limit, 0, 0, MAX_KILOBYTES, PGC_SIGHUP, GUC_UNIT_MB,
		NULL, NULL, NULL);
	DefineCustomIntVariable("memcow.slru_pages",
		"Pages of SLRU storage for volatile_data_directory.",
		"Every SLRU page a volatile server writes is kept here for the life of the server.",
		&memcow_slru_pages, 4096, 16, INT_MAX / 2, PGC_POSTMASTER, 0,
		NULL, NULL, NULL);
	MarkGUCPrefixReserved("memcow");

	RegisterStorageManager(&memcow_smgr, memcow_enabled);
	if (memcow_enabled && VolatileDataDirectory)
		memcow_slru_register();
	memcow_shmem_setup();

	prev_object_access_hook = object_access_hook;
	object_access_hook = memcow_object_access;

	prev_client_auth_hook = ClientAuthentication_hook;
	ClientAuthentication_hook = memcow_client_auth;
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

/* The per-connection adopt call (plan §3.9): see memcow_backend_adopt(). */
PG_FUNCTION_INFO_V1(memcow_backend_reset_sql);
Datum
memcow_backend_reset_sql(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64((int64) memcow_backend_adopt());
}

/* Runs in the seed-backed ON login trigger before either protocol dispatches. */
PG_FUNCTION_INFO_V1(memcow_login);
Datum
memcow_login(PG_FUNCTION_ARGS)
{
	if (!CALLED_AS_EVENT_TRIGGER(fcinfo))
		elog(ERROR, "memcow_login must be called as an event trigger");
	memcow_check_admission();
	PG_RETURN_NULL();
}
