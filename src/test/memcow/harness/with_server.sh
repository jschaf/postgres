#!/usr/bin/env bash
#
# with_server.sh --- own a memcow lane server for one Python driver run.
#
# Starts the postmaster on the assembled RAM PGDATA with memcow enabled and
# the GUCs every soak and benchmark needs (mmap DSM so segments can be
# counted as files under pg_dynshmem from outside the server; track_counts
# off, because cumulative stats are cluster-monotonic and would grow the
# stats DSA by a segment every few hundred relations the workload leaves
# behind; no parallel query, whose per-session DSM segment is retained until
# the session exits; the plan §6 preconditions; bounded WAL), creates the
# memcow extension in the control database, exports the connection details,
# runs the driver, scans the log, stops the server.
#
# Usage:
#   with_server.sh --seed DIR --pgdata DIR [--build-dir DIR] [--ram-mount DIR]
#                  [--shared-buffers SZ] [--guc name=value ...]
#                  [--outputdir DIR] -- DRIVER [ARGS...]
#
# The driver runs with PGHOST, PGPORT, PGUSER, MEMCOW_LIBDIR, MEMCOW_PGDATA,
# MEMCOW_LOGFILE and MEMCOW_OUTPUTDIR set.
#
# Exit status: the driver's, or 1 if the server log shows an assert, crash or
# leak; 2 could not run.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

set -o pipefail

MC_PROG=with_server.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
. "$HERE/common.sh"

SEED= PGDATA= RAM_MOUNT= BUILD_DIR= OUTPUTDIR= SHARED_BUFFERS=
CONTROL_DB=${MEMCOW_CONTROL_DB:-memcow_control}
GUCS=()

while [ $# -gt 0 ]; do
	case $1 in
		--seed)        SEED=$2; shift 2 ;;
		--pgdata)      PGDATA=$2; shift 2 ;;
		--ram-mount)   RAM_MOUNT=$2; shift 2 ;;
		--build-dir)   BUILD_DIR=$2; shift 2 ;;
		--outputdir)   OUTPUTDIR=$2; shift 2 ;;
		--shared-buffers) SHARED_BUFFERS=$2; shift 2 ;;
		--guc)         GUCS[${#GUCS[@]}]=$2; shift 2 ;;
		--)            shift; break ;;
		-h|--help)     sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)             mc_die "unknown option: $1" ;;
	esac
done

[ $# -gt 0 ] || mc_die "no driver given after --"
[ -n "$SEED" ]   || mc_die "--seed is required"
[ -n "$PGDATA" ] || mc_die "--pgdata is required"
SEED=$(mc_abspath "$SEED"); PGDATA=$(mc_abspath "$PGDATA")
[ -f "$SEED/memcow_seed.fingerprint" ] || mc_die "not a seed: $SEED"
[ -f "$PGDATA/PG_VERSION" ] || mc_die "not a data directory: $PGDATA"
: "${RAM_MOUNT:=$(dirname -- "$PGDATA")}"
[ -n "$BUILD_DIR" ] || BUILD_DIR=$(mc_default_build_dir) || mc_die "pass --build-dir"
mc_resolve_build "$BUILD_DIR"
: "${OUTPUTDIR:=$(dirname -- "$PGDATA")/driver-out}"
mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")
SOCKDIR=$(mc_make_sockdir) || mc_die "cannot create a socket directory"
PORT=$(mc_free_port) || mc_die "cannot find a free port"
LOGFILE="$OUTPUTDIR/postmaster.log"

trap 'mc_server_cleanup "$PGDATA" "$LOGFILE" "$SOCKDIR"' EXIT INT TERM
mc_ensure_startable "$PGDATA" "$SEED" "$RAM_MOUNT" "$OUTPUTDIR" || mc_die "re-assembly failed"
: >"$LOGFILE"; : >"$LOGFILE.pg_ctl"
mc_server_start "$PGDATA" "$PORT" "$SOCKDIR" "$LOGFILE" \
	memcow.enabled=on "memcow.seed_directory=$SEED" \
	dynamic_shared_memory_type=mmap track_counts=off \
	max_parallel_workers_per_gather=0 max_prepared_transactions=0 \
	autovacuum=off max_wal_size=256MB \
	${SHARED_BUFFERS:+shared_buffers=$SHARED_BUFFERS} \
	${GUCS[@]+"${GUCS[@]}"} || mc_die "server did not start; see $LOGFILE"

# Only memcow itself: every catalog row created in the control database is
# a page copied into its never-reset overlay, and the soak's DSM-flat check
# counts that arena's segments too.  A driver that needs pg_buffercache or
# injection_points creates them itself.
PGHOST=$SOCKDIR PGPORT=$PORT "$MC_BINDIR/psql" -X -q -d "$CONTROL_DB" \
	-c "CREATE EXTENSION IF NOT EXISTS memcow" >/dev/null 2>&1 ||
	mc_die "cannot create the memcow extension in $CONTROL_DB"

mc_banner "memcow server for: $*" "seed: $SEED" "pgdata: $PGDATA" \
	"shared_buffers: ${SHARED_BUFFERS:-default}  gucs: ${GUCS[*]-}" "logs: $OUTPUTDIR"

PGHOST=$SOCKDIR PGPORT=$PORT PGUSER=${PGUSER:-postgres} \
MEMCOW_LIBDIR=$MC_LIBDIR MEMCOW_PGDATA=$PGDATA MEMCOW_LOGFILE=$LOGFILE \
MEMCOW_OUTPUTDIR=$OUTPUTDIR MEMCOW_CONTROL_DB=$CONTROL_DB \
	"$@" 2>&1 | tee "$OUTPUTDIR/driver.log"
RC=${PIPESTATUS[0]}

# The stop comes first: the exit-time leak WARNINGs are written by backends
# on their way out.
mc_server_stop "$PGDATA" "$LOGFILE" || mc_warn "pg_ctl stop reported failure"
mc_check_log "$LOGFILE" "$PGDATA" || RC=1
echo "rc=$RC" >"$OUTPUTDIR/status.txt"
exit "$RC"
