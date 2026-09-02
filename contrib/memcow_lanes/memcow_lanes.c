/*-------------------------------------------------------------------------
 *
 * memcow_lanes.c
 *	  SQL surface for memcow lanes: reset, open, registry, status, adopt.
 *
 * A thin veneer over the lane functions in src/backend/storage/smgr/memcow.c
 * (see the LANES section there for the protocol and for why the control
 * plane lives in core).  This module exists because SQL-callable functions
 * need pg_proc rows and the core patch does not touch the catalogs: CREATE
 * EXTENSION provides them.  It needs no shared_preload_libraries and no
 * hooks.
 *
 * Where each function runs (plan §3):
 *   memcow_lane_reset / open / register / unregister / status -- on the
 *     CONTROL connection, never in the lane concerned.  Created in the
 *     control database by whoever drives the lanes.
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
#include "miscadmin.h"
#include "storage/memcow.h"
#include "utils/builtins.h"
#include "utils/inval.h"
#include "utils/syscache.h"
#include "utils/tuplestore.h"

PG_MODULE_MAGIC;

/*
 * The lane's default tablespace, which the reset needs to locate the two
 * per-database files it sweeps.  Catalog access stays here rather than in
 * memcow.c.
 */
static Oid
lane_tablespace(Oid dbOid)
{
	HeapTuple	tup;
	Oid			spc;

	tup = SearchSysCache1(DATABASEOID, ObjectIdGetDatum(dbOid));
	if (!HeapTupleIsValid(tup))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_DATABASE),
				 errmsg("database with OID %u does not exist", dbOid)));
	spc = ((Form_pg_database) GETSTRUCT(tup))->dattablespace;
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

	PG_RETURN_INT64((int64) memcow_lane_open(dbOid, arm));
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
	Datum		values[8];
	bool		nulls[8];

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

	PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls)));
}

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
