#!/usr/bin/env bash
#
# bench.sh --- owns the server for one plan §7.4 benchmark run and starts the
# driver (bench/bench_lease.py or bench/bench_reset.py).  The server is
# started as pool_soak.sh starts it (mmap DSM so segments can be counted
# from outside, no parallel query, no prepared transactions, autovacuum off,
# bounded WAL, shared_preload_libraries=memcow_lanes so both admission
# fences are live) at the shared_buffers the caller asks for -- §7.4 says
# 512MB -- and the leak scan of the log runs after the driver.
#
# Usage:
#   bench.sh --seed DIR --pgdata DIR --driver lease|reset [--build-dir DIR]
#            [--shared-buffers SZ] [--guc name=value ...] [--outputdir DIR] [--ram-mount DIR]
#            -- <driver arguments>
#
# Exit status: the driver's (0 pass / control behaved, 1 fail), or 1 if the
# server log shows an assert, crash or leak; 2 could not run.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

set -o pipefail

MC_PROG=bench.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BENCHDIR=$(cd -- "$HERE/../bench" && pwd)
SEEDDIR_SCRIPTS=$(cd -- "$HERE/../seed" && pwd)
# shellcheck source=./common.sh
. "$HERE/common.sh"

SEED= PGDATA= RAM_MOUNT= BUILD_DIR= OUTPUTDIR= DRIVER=
CONTROL_DB=${MEMCOW_CONTROL_DB:-memcow_control}
SHARED_BUFFERS=512MB
EXTRA_GUCS=

while [ $# -gt 0 ]; do
	case $1 in
		--seed)        SEED=$2; shift 2 ;;
		--pgdata)      PGDATA=$2; shift 2 ;;
		--ram-mount)   RAM_MOUNT=$2; shift 2 ;;
		--build-dir)   BUILD_DIR=$2; shift 2 ;;
		--outputdir)   OUTPUTDIR=$2; shift 2 ;;
		--driver)      DRIVER=$2; shift 2 ;;
		--shared-buffers) SHARED_BUFFERS=$2; shift 2 ;;
		--guc)         EXTRA_GUCS="$EXTRA_GUCS -c $2"; shift 2 ;;
		--)            shift; break ;;
		-h|--help)     sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)             mc_die "unknown option: $1" ;;
	esac
done

[ -n "$SEED" ]   || mc_die "--seed is required"
[ -n "$PGDATA" ] || mc_die "--pgdata is required"
case $DRIVER in lease|reset) ;; *) mc_die "--driver must be lease or reset" ;; esac
SEED=$(mc_abspath "$SEED"); PGDATA=$(mc_abspath "$PGDATA")
[ -f "$SEED/memcow_seed.fingerprint" ] || mc_die "not a seed: $SEED"
[ -f "$PGDATA/PG_VERSION" ] || mc_die "not a data directory: $PGDATA"
: "${RAM_MOUNT:=$(dirname -- "$PGDATA")}"
[ -n "$BUILD_DIR" ] || BUILD_DIR=$(mc_default_build_dir) || mc_die "pass --build-dir"
mc_resolve_build "$BUILD_DIR"
: "${OUTPUTDIR:=$(dirname -- "$PGDATA")/bench-out}"
mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")
SOCKDIR=$(mc_make_sockdir) || mc_die "cannot create a socket directory"
PORT=$(mc_free_port) || mc_die "cannot find a free port"
LOGFILE="$OUTPUTDIR/postmaster.log"

pg_start()
{
	"$MC_BINDIR/pg_ctl" -D "$PGDATA" -l "$LOGFILE" -p "$MC_BINDIR/postgres" \
		-o "-c memcow_enabled=on -c memcow_seed_directory=$SEED \
		    -c shared_preload_libraries=memcow_lanes \
		    -c listen_addresses= -c unix_socket_directories=$SOCKDIR \
		    -c log_min_messages=warning -c log_statement=none \
		    -c restart_after_crash=off -c dynamic_shared_memory_type=mmap \
		    -c track_counts=off -c max_parallel_workers_per_gather=0 \
		    -c max_prepared_transactions=0 -c autovacuum=off \
		    -c max_wal_size=256MB -c shared_buffers=$SHARED_BUFFERS $EXTRA_GUCS -p $PORT" \
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

PGHOST=$SOCKDIR PGPORT=$PORT "$MC_BINDIR/psql" -X -q -d "$CONTROL_DB" \
	-c "CREATE EXTENSION IF NOT EXISTS memcow_lanes" \
	-c "CREATE EXTENSION IF NOT EXISTS injection_points" \
	-c "CREATE EXTENSION IF NOT EXISTS pg_buffercache" >/dev/null 2>&1 ||
	mc_die "cannot create the control-database extensions"

mc_banner "memcow §7.4 benchmark: $DRIVER" "seed: $SEED" "pgdata: $PGDATA" \
	"shared_buffers: $SHARED_BUFFERS   driver args: $*" "logs: $OUTPUTDIR"

python3 "$BENCHDIR/bench_$DRIVER.py" --libdir "$MC_LIBDIR" --host "$SOCKDIR" --port "$PORT" \
	--user "${PGUSER:-postgres}" --control-db "$CONTROL_DB" --pgdata "$PGDATA" \
	--logfile "$LOGFILE" $( [ "$DRIVER" = reset ] && printf -- '--workdir %s' "$OUTPUTDIR/work" ) \
	--report "$OUTPUTDIR/report.json" "$@" 2>&1 | tee "$OUTPUTDIR/driver.log"
RC=${PIPESTATUS[0]}

hits=$(grep -nE 'TRAP: |PANIC:|was terminated by signal|leaked AIO handle|AIO handle was not submitted|refcount leak|resource was not closed|open AIO batch at end' "$LOGFILE" 2>/dev/null)
if [ -n "$hits" ]; then
	printf 'FAIL  server log shows an assert/crash/leak:\n%s\n' "$hits"
	RC=1
fi
{ echo "driver=$DRIVER"; echo "shared_buffers=$SHARED_BUFFERS"; echo "rc=$RC"; } >"$OUTPUTDIR/bench_status.txt"
exit "$RC"
