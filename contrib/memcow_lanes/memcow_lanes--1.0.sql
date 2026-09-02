/* contrib/memcow_lanes/memcow_lanes--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION memcow_lanes" to load this file. \quit

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
    OUT reclaim_pending boolean)
RETURNS record
AS 'MODULE_PATHNAME', 'memcow_lane_status_sql'
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
REVOKE ALL ON FUNCTION memcow_lane_register(oid, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_lane_unregister(oid, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_lane_status(oid) FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_backend_reset() FROM PUBLIC;
REVOKE ALL ON FUNCTION memcow_backend_counters() FROM PUBLIC;
