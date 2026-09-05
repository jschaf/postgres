#!/usr/bin/env bash
#
# run_regress_subset.sh --- run a named subset of the core regression tests
#                           against one described server.
#
# "Described server" = { PGDATA template, extra GUCs }.  The template is
# copied into the output directory and run there (a regression run leaves
# cluster-wide state behind -- the regress_tblspace tablespace, regress_*
# roles, advanced OID/XID counters -- so a reused PGDATA is not a repeatable
# starting point).  The script starts the postmaster itself, so it can set
# PGC_POSTMASTER GUCs such as io_method, shared_buffers and the memcow switch,
# points pg_regress at it with --host/--port, and shuts it down afterwards.
#
# It does NOT invent a test runner.  The subset is turned into an ordinary
# pg_regress schedule by filtering src/test/regress/parallel_schedule
# (gen_schedule.py), and pg_regress does the rest -- creating and dropping
# the `regression` database, substituting @abs_srcdir@ etc., comparing
# against expected/ with resultmap and alternative files, emitting TAP.
#
# Outputs, all under --outputdir:
#   schedule            the generated pg_regress schedule
#   pg_regress.log      pg_regress stdout+stderr (TAP)
#   regression.diffs    pg_regress's diffs against expected/ (if any)
#   results/            the actual .out files -- what io_matrix.sh compares
#   postmaster.log      the server log -- what mc_check_log scans
#   tap_status.txt      one "<test> ok|not-ok" line per test
#   engine.txt          key=value description of the server that ran
#   status.txt          key=value verdict
#
# Usage:
#   run_regress_subset.sh --pgdata-template DIR --outputdir DIR
#       [--subset NAME|FILE] [--guc NAME=VALUE ...] [--label NAME]
#       [--build-dir DIR]
#
# Exit status: 0 all tests matched expected and the log was clean,
# 1 regression failures or leaks, 2 could not run.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

set -o pipefail

MC_PROG=run_regress_subset.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
. "$HERE/common.sh"

PGDATA_TEMPLATE= LABEL= BUILD_DIR= OUTPUTDIR=
SUBSET=phase0
GUCS=()

while [ $# -gt 0 ]; do
	case $1 in
		--pgdata-template) PGDATA_TEMPLATE=$2; shift 2 ;;
		--guc)         GUCS[${#GUCS[@]}]=$2; shift 2 ;;
		--label)       LABEL=$2; shift 2 ;;
		--build-dir)   BUILD_DIR=$2; shift 2 ;;
		--subset)      SUBSET=$2; shift 2 ;;
		--outputdir)   OUTPUTDIR=$2; shift 2 ;;
		-h|--help)     sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)             mc_die "unknown option: $1" ;;
	esac
done

[ -n "$OUTPUTDIR" ] || mc_die "--outputdir is required"
[ -n "$PGDATA_TEMPLATE" ] || mc_die "--pgdata-template is required"
[ -n "$BUILD_DIR" ] || BUILD_DIR=$(mc_default_build_dir) ||
	mc_die "cannot find a meson build dir; pass --build-dir or set MEMCOW_BUILD_DIR"
mc_resolve_build "$BUILD_DIR"

SUBSET_FILE=$SUBSET
[ -f "$SUBSET_FILE" ] || SUBSET_FILE="$HERE/subsets/$SUBSET.txt"
[ -f "$SUBSET_FILE" ] || mc_die "no such subset: $SUBSET (looked for $HERE/subsets/$SUBSET.txt)"

mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")
[ -n "$LABEL" ] || LABEL=$(basename -- "$OUTPUTDIR")

PGDATA_TEMPLATE=$(mc_abspath "$PGDATA_TEMPLATE")
[ -f "$PGDATA_TEMPLATE/PG_VERSION" ] || mc_die "not a data directory: $PGDATA_TEMPLATE"
mc_server_running "$PGDATA_TEMPLATE" &&
	mc_die "a postmaster is running on the template $PGDATA_TEMPLATE"
PGDATA_DIR="$OUTPUTDIR/pgdata"
mc_log "copying template $PGDATA_TEMPLATE -> $PGDATA_DIR"
rm -rf "$PGDATA_DIR"
cp -R "$PGDATA_TEMPLATE" "$PGDATA_DIR" || mc_die "template copy failed"
rm -f "$PGDATA_DIR/postmaster.pid"

SCHEDULE="$OUTPUTDIR/schedule"
python3 "$HERE/gen_schedule.py" --regress-src "$MC_REGRESS_SRC" \
	--subset "$SUBSET_FILE" --out "$SCHEDULE" --print-groups || mc_die "schedule generation failed"

PORT=$(mc_free_port) || mc_die "cannot find a free port"
SOCKDIR=$(mc_make_sockdir) || mc_die "cannot create a socket directory"
LOGFILE="$OUTPUTDIR/postmaster.log"
: >"$LOGFILE"; : >"$LOGFILE.pg_ctl"
trap 'mc_server_cleanup "$PGDATA_DIR" "$LOGFILE" "$SOCKDIR"' EXIT INT TERM

mc_server_start "$PGDATA_DIR" "$PORT" "$SOCKDIR" "$LOGFILE" \
	${GUCS[@]+"${GUCS[@]}"} || mc_die "postmaster would not start"

# Record what actually ran: the server's own answer, not the request
# (shared_buffers gets rounded, io_method could be rejected).
ENGINE_INFO="$OUTPUTDIR/engine.txt"
{
	echo "label=$LABEL"
	echo "pgdata=$PGDATA_DIR"
	echo "pgdata_template=$PGDATA_TEMPLATE"
	echo "bindir=$MC_BINDIR"
	echo "build_dir=$MC_BUILD_DIR"
	echo "regress_src=$MC_REGRESS_SRC"
	echo "subset=$SUBSET_FILE"
	echo "requested_gucs=${GUCS[*]-}"
	echo "port=$PORT"
} >"$ENGINE_INFO"
for g in server_version debug_assertions io_method shared_buffers temp_buffers \
         max_connections autovacuum fsync wal_level log_min_messages
do
	v=$(mc_psql "$SOCKDIR" "$PORT" postgres "SHOW $g" 2>/dev/null) || v='<unavailable>'
	echo "$g=$v" >>"$ENGINE_INFO"
done
# memcow.seed_directory is GUC_SUPERUSER_ONLY; the harness connects as the
# bootstrap superuser.
for g in memcow.enabled memcow.seed_directory
do
	v=$(mc_psql "$SOCKDIR" "$PORT" postgres \
		"SELECT coalesce((SELECT setting FROM pg_settings WHERE name = '$g'), '<absent>')" 2>/dev/null) ||
		v='<absent>'
	echo "$g=$v" >>"$ENGINE_INFO"
done
mc_log "engine:"
sed 's/^/    /' "$ENGINE_INFO" >&2

REGRESS_LOG="$OUTPUTDIR/pg_regress.log"
mc_log "running pg_regress ($(grep -c '^test:' "$SCHEDULE") groups) -> $OUTPUTDIR"
PATH="$MC_BINDIR:$PATH" \
"$MC_PG_REGRESS" \
	--bindir="$MC_BINDIR" \
	--inputdir="$MC_REGRESS_SRC" \
	--expecteddir="$MC_REGRESS_SRC" \
	--dlpath="$MC_DLPATH" \
	--outputdir="$OUTPUTDIR" \
	--schedule="$SCHEDULE" \
	--max-concurrent-tests=20 \
	--host="$SOCKDIR" \
	--port="$PORT" \
	--dbname=regression \
	>"$REGRESS_LOG" 2>&1
REGRESS_RC=$?
tail -20 "$REGRESS_LOG" >&2

# One line per test: "<name> <ok|not-ok>", stable order, for cheap diffing.
# pg_regress prints "ok N  - name  ms" for a serial test and "ok N  + name"
# for a member of a parallel group.
sed -n -E 's/^ok [0-9]+[[:space:]]+[-+][[:space:]]+([^[:space:]]+).*/\1 ok/p;
           s/^not ok [0-9]+[[:space:]]+[-+][[:space:]]+([^[:space:]]+).*/\1 not-ok/p' \
	"$REGRESS_LOG" | sort >"$OUTPUTDIR/tap_status.txt"
OK_COUNT=$(grep -c ' ok$' "$OUTPUTDIR/tap_status.txt" | tr -d ' ')
NOK_COUNT=$(grep -c ' not-ok$' "$OUTPUTDIR/tap_status.txt" | tr -d ' ')

# The stop must happen before the scan: AtProcExit_Buffers() and
# pgaio_shutdown() only run when the backends actually exit.
mc_server_stop "$PGDATA_DIR" "$LOGFILE" || mc_warn "pg_ctl stop reported failure"

LEAK_RC=0
if [ "$(sed -n 's/^debug_assertions=//p' "$ENGINE_INFO")" != on ]; then
	echo "LEAKCHECK FAIL  debug_assertions is not on: the pin-leak checks are compiled out"
	LEAK_RC=1
fi
mc_check_log "$LOGFILE" "$PGDATA_DIR" "$OUTPUTDIR" || LEAK_RC=1

{
	echo "label=$LABEL"
	echo "subset=$SUBSET_FILE"
	echo "pg_regress_rc=$REGRESS_RC"
	echo "tests_ok=$OK_COUNT"
	echo "tests_failed=$NOK_COUNT"
	echo "leakcheck_rc=$LEAK_RC"
	echo "outputdir=$OUTPUTDIR"
} >"$OUTPUTDIR/status.txt"

RC=0
[ "$REGRESS_RC" -eq 0 ] || RC=1
[ "$LEAK_RC" -eq 0 ] || RC=1
if [ $RC -eq 0 ]; then
	mc_log "PASS  [$LABEL] $OK_COUNT tests ok, 0 failed, log clean"
else
	mc_log "FAIL  [$LABEL] pg_regress rc=$REGRESS_RC ($NOK_COUNT failed), leakcheck rc=$LEAK_RC"
	[ -s "$OUTPUTDIR/regression.diffs" ] && mc_log "      diffs: $OUTPUTDIR/regression.diffs"
fi
exit $RC
