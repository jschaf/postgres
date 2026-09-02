#!/usr/bin/env bash
#
# pool_soak.sh --- plan §7.2's reset soak, driven through the pool library
# (pool/memcow_pool.py) by pool/pool_soak.py.  This script owns the server;
# the Python owns the loop.  See pool_soak.py for what is verified per reset
# and what the two measurements are.
#
# The server is started as reset_soak.sh starts it (mmap DSM so segments can
# be counted from outside, track_counts off, no parallel query, no prepared
# transactions, autovacuum off, bounded WAL), plus shared_preload_libraries=
# memcow_lanes so that the authentication-time fence is live: every fresh
# connection the soak opens presents the lane's current nonce and passes
# both fences, every iteration.
#
# Usage:
#   pool_soak.sh --seed DIR --pgdata DIR [--build-dir DIR] [options]
#     --iterations N        resets to perform (default 10000)
#     --fence-every K       exercise the fence every K (default 100)
#     --fresh-every K       fresh-connection digest every K (default 50)
#     --lanes A,B           lanes to partition to this process (default 2)
#     --conns M             connections per lane (default 2)
#     --retire-after K      replace a lane's backends after K epochs (default 50)
#     --shared-buffers SZ   for the §7.4 measurement (default: server default)
#     --measure-tmp         orphaned pgsql_tmp measurement
#     --measure-shdepend    pg_shdepend growth as a non-pinned role
#     --outputdir DIR       logs (default <pgdata>/../pool-soak-out)
#     --ram-mount DIR       for re-assembly if the PGDATA needs recovery
#
# Exit status: 0 pass, 1 fail, 2 could not run.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

set -o pipefail

MC_PROG=pool_soak.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
POOLDIR=$(cd -- "$HERE/../pool" && pwd)
SEEDDIR_SCRIPTS=$(cd -- "$HERE/../seed" && pwd)
# shellcheck source=./common.sh
. "$HERE/common.sh"

SEED= PGDATA= RAM_MOUNT= BUILD_DIR= OUTPUTDIR=
CONTROL_DB=${MEMCOW_CONTROL_DB:-memcow_control}
ITER=10000 FENCE_EVERY=100 FRESH_EVERY=50 RETIRE_AFTER=50
LANES=memcow_lane_00,memcow_lane_01
CONNS=2
SHARED_BUFFERS=
MEASURE=()

while [ $# -gt 0 ]; do
	case $1 in
		--seed)        SEED=$2; shift 2 ;;
		--pgdata)      PGDATA=$2; shift 2 ;;
		--ram-mount)   RAM_MOUNT=$2; shift 2 ;;
		--build-dir)   BUILD_DIR=$2; shift 2 ;;
		--outputdir)   OUTPUTDIR=$2; shift 2 ;;
		--iterations)  ITER=$2; shift 2 ;;
		--fence-every) FENCE_EVERY=$2; shift 2 ;;
		--fresh-every) FRESH_EVERY=$2; shift 2 ;;
		--lanes)       LANES=$2; shift 2 ;;
		--conns)       CONNS=$2; shift 2 ;;
		--retire-after) RETIRE_AFTER=$2; shift 2 ;;
		--shared-buffers) SHARED_BUFFERS=$2; shift 2 ;;
		--measure-tmp) MEASURE[${#MEASURE[@]}]=--measure-tmp; shift ;;
		--measure-shdepend) MEASURE[${#MEASURE[@]}]=--measure-shdepend; shift ;;
		-h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)             mc_die "unknown option: $1" ;;
	esac
done

[ -n "$SEED" ]   || mc_die "--seed is required"
[ -n "$PGDATA" ] || mc_die "--pgdata is required"
SEED=$(mc_abspath "$SEED"); PGDATA=$(mc_abspath "$PGDATA")
[ -f "$SEED/memcow_seed.fingerprint" ] || mc_die "not a seed: $SEED"
[ -f "$PGDATA/PG_VERSION" ] || mc_die "not a data directory: $PGDATA"
: "${RAM_MOUNT:=$(dirname -- "$PGDATA")}"
[ -n "$BUILD_DIR" ] || BUILD_DIR=$(mc_default_build_dir) || mc_die "pass --build-dir"
mc_resolve_build "$BUILD_DIR"
: "${OUTPUTDIR:=$(dirname -- "$PGDATA")/pool-soak-out}"
mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")
SOCKDIR=$(mc_make_sockdir) || mc_die "cannot create a socket directory"
PORT=$(mc_free_port) || mc_die "cannot find a free port"
LOGFILE="$OUTPUTDIR/postmaster.log"

pg_start()
{
	local extra=
	[ -n "$SHARED_BUFFERS" ] && extra="-c shared_buffers=$SHARED_BUFFERS"
	"$MC_BINDIR/pg_ctl" -D "$PGDATA" -l "$LOGFILE" -p "$MC_BINDIR/postgres" \
		-o "-c memcow_enabled=on -c memcow_seed_directory=$SEED \
		    -c shared_preload_libraries=memcow_lanes \
		    -c listen_addresses= -c unix_socket_directories=$SOCKDIR \
		    -c log_min_messages=warning -c log_statement=none \
		    -c restart_after_crash=off -c dynamic_shared_memory_type=mmap \
		    -c track_counts=off -c max_parallel_workers_per_gather=0 \
		    -c max_prepared_transactions=0 -c autovacuum=off \
		    -c max_wal_size=256MB $extra -p $PORT" \
		-w -t 60 start >>"$LOGFILE.pg_ctl" 2>&1
}
pg_stop() { "$MC_BINDIR/pg_ctl" -D "$PGDATA" -m "${1:-fast}" -w -t 60 stop >>"$LOGFILE.pg_ctl" 2>&1; }
pg_running() { "$MC_BINDIR/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; }
cluster_state() { "$MC_BINDIR/pg_controldata" -D "$PGDATA" 2>/dev/null | sed -n 's/^Database cluster state: *//p'; }

cleanup()
{
	pg_running && { pg_stop fast || pg_stop immediate; }
	rm -rf "$SOCKDIR"
}
trap cleanup EXIT INT TERM

case $(cluster_state) in
	"shut down"|"shut down in recovery") ;;
	*) mc_warn "PGDATA needs recovery; re-assembling"
	   bash "$SEEDDIR_SCRIPTS/assemble_ramdir.sh" -s "$SEED" -m "$RAM_MOUNT" -b "$MC_BINDIR" -f \
	       >"$OUTPUTDIR/reassemble.log" 2>&1 || mc_die "re-assembly failed" ;;
esac

: >"$LOGFILE"; : >"$LOGFILE.pg_ctl"
pg_start || mc_die "server did not start; see $LOGFILE"

mc_banner "memcow reset soak through the pool (plan §7.2 via §3)" \
	"seed:       $SEED" "pgdata:     $PGDATA" "lanes:      $LANES x $CONNS conns" \
	"iterations: $ITER   fence every: $FENCE_EVERY   fresh every: $FRESH_EVERY   retire after: $RETIRE_AFTER epochs" \
	"shared_buffers: ${SHARED_BUFFERS:-default}   measurements: ${MEASURE[*]:-none}" \
	"logs:       $OUTPUTDIR"

python3 "$POOLDIR/pool_soak.py" --libdir "$MC_LIBDIR" --host "$SOCKDIR" --port "$PORT" \
	--user "${PGUSER:-postgres}" --control-db "$CONTROL_DB" \
	--lanes "$LANES" --conns "$CONNS" --pgdata "$PGDATA" \
	--iterations "$ITER" --fence-every "$FENCE_EVERY" --fresh-every "$FRESH_EVERY" \
	--retire-after "$RETIRE_AFTER" --report "$OUTPUTDIR/report.json" \
	${MEASURE[@]+"${MEASURE[@]}"}
RC=$?

# leak / crash scan, as in the slice tests
hits=$(grep -nE 'TRAP: |PANIC:|was terminated by signal|leaked AIO handle|AIO handle was not submitted|refcount leak|resource was not closed|open AIO batch at end' "$LOGFILE" 2>/dev/null)
if [ -n "$hits" ]; then
	printf 'FAIL  server log shows an assert/crash/leak:\n%s\n' "$hits"
	RC=1
fi

{ echo "iterations=$ITER"; echo "rc=$RC"; } >"$OUTPUTDIR/soak_status.txt"
if [ $RC -eq 0 ]; then
	mc_banner "POOL SOAK PASS -- $ITER resets through the pool"
else
	mc_banner "POOL SOAK FAIL" "logs: $OUTPUTDIR"
fi
exit $RC
