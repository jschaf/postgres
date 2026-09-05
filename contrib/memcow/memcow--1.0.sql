/* contrib/memcow/memcow--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION memcow" to load this file. \quit

-- Control-connection functions (plan §4): never call these in the lane
-- concerned.
CREATE FUNCTION memcow_lane_reset(dboid oid, timeout_ms int DEFAULT 5000)
RETURNS bigint
AS 'MODULE_PATHNAME', 'memcow_lane_reset_sql'
LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION memcow_lane_open(dboid oid, arm boolean DEFAULT true)
RETURNS bigint
AS 'MODULE_PATHNAME', 'memcow_lane_open_sql'
LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION memcow_lane_retire(dboid oid)
RETURNS void
AS 'MODULE_PATHNAME', 'memcow_lane_retire_sql'
LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION memcow_lane_register(dboid oid, pid int)
RETURNS void
AS 'MODULE_PATHNAME', 'memcow_lane_register_sql'
LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION memcow_lane_unregister(dboid oid, pid int)
RETURNS void
AS 'MODULE_PATHNAME', 'memcow_lane_unregister_sql'
LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION memcow_lane_status(dboid oid,
    OUT state text, OUT epoch bigint, OUT nonce bigint, OUT registered int,
    OUT arena_bytes bigint, OUT attached int, OUT attached_old int,
    OUT reclaim_pending boolean, OUT writes_discarded bigint,
    OUT poisoned_pages bigint, OUT arena_limit bigint)
RETURNS record
AS 'MODULE_PATHNAME', 'memcow_lane_status_sql'
LANGUAGE C STRICT VOLATILE;

-- Test helper: deliver a sinval catchup interrupt to one backend.
CREATE FUNCTION memcow_lane_catchup(pid int)
RETURNS void
AS 'MODULE_PATHNAME', 'memcow_lane_catchup_sql'
LANGUAGE C STRICT VOLATILE;

-- Cost attribution (plan §7.4): where the lane's last completed reset spent
-- its time, in microseconds, step by step.  NULLs if no reset has completed.
CREATE FUNCTION memcow_lane_reset_timings(dboid oid,
    OUT epoch bigint, OUT total_us bigint, OUT fence_us bigint,
    OUT prepare_us bigint, OUT publish_us bigint, OUT barrier_us bigint,
    OUT sweep_buffers_us bigint, OUT sweep_files_us bigint,
    OUT reclaim_wait_us bigint, OUT poison_us bigint, OUT destroy_us bigint,
    OUT fence_polls int, OUT reclaim_polls int, OUT stragglers int,
    OUT poisoned_pages bigint)
RETURNS record
AS 'MODULE_PATHNAME', 'memcow_lane_reset_timings_sql'
LANGUAGE C STRICT VOLATILE;

-- Test helper (plan §7.4, barrier absorption): hold off interrupts in THIS
-- backend for ms milliseconds, so that it cannot absorb a ProcSignal barrier
-- until then -- a deterministic CFI-starved process.
CREATE FUNCTION memcow_lane_starve_interrupts(ms int)
RETURNS void
AS 'MODULE_PATHNAME', 'memcow_lane_starve_interrupts_sql'
LANGUAGE C STRICT VOLATILE;

-- Lane-backend functions (plan §3.9): run in the lane, on each retained
-- connection, after memcow_lane_reset returned.
CREATE FUNCTION memcow_backend_reset()
RETURNS bigint
AS 'MODULE_PATHNAME', 'memcow_backend_reset_sql'
LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION memcow_backend_counters(OUT name text, OUT value bigint)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'memcow_backend_counters_sql'
LANGUAGE C STRICT VOLATILE;

REVOKE ALL ON FUNCTION memcow_lane_reset(oid, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_lane_open(oid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_lane_retire(oid) FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_lane_register(oid, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_lane_unregister(oid, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_lane_status(oid) FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_lane_catchup(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_lane_reset_timings(oid) FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_lane_starve_interrupts(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_backend_reset() FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_backend_counters() FROM PUBLIC;

CREATE FUNCTION memcow_login() RETURNS event_trigger
AS 'MODULE_PATHNAME', 'memcow_login'
LANGUAGE C;

CREATE EVENT TRIGGER memcow_admission ON login EXECUTE FUNCTION memcow_login();
-- A startup packet's session_replication_role must not suppress this fence.
ALTER EVENT TRIGGER memcow_admission ENABLE ALWAYS;
