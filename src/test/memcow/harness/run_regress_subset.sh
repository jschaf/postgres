#!/usr/bin/env bash
#
# run_regress_subset.sh --- run a named subset of the core regression tests
#                           against one described server.
#
# "Described server" = { bindir, PGDATA, extra GUCs }.  The script starts the
# postmaster itself (so it can set PGC_POSTMASTER GUCs such as io_method,
# shared_buffers and, in Phase 1, the memcow switch), points pg_regress at it
# with --host/--port, and shuts it down cleanly afterwards.
#
# It does NOT invent a test runner.  The subset is turned into an ordinary
# pg_regress schedule by filtering src/test/regress/parallel_schedule
# (gen_schedule.py), and pg_regress does the rest -- including creating and
# dropping the `regression` database, substituting @abs_srcdir@/@libdir@/
# @testtablespace@, comparing against expected/ with resultmap and alternative
# expected files, and emitting TAP.  That is exactly what meson does; the only
# differences are that we own the server instead of using --temp-instance, and
# that the schedule is filtered.
#
# Outputs, all under --outputdir:
#   schedule            the generated pg_regress schedule
#   pg_regress.log      pg_regress stdout+stderr (TAP)
#   regression.diffs    pg_regress's diffs against expected/ (if any)
#   results/            the actual .out files -- this is what diff_engines.sh
#                       compares between engines
#   postmaster.log      the server log -- this is what check_leaks.sh scans
#   engine.txt          key=value description of the server that ran
#   status.txt          key=value verdict
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

# See check_leaks.sh for why there is no `set -u`.
set -o pipefail

MC_PROG=run_regress_subset.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
. "$HERE/common.sh"

usage()
{
	cat <<'EOF'
Usage: run_regress_subset.sh --pgdata DIR --outputdir DIR [options]

Server description (exactly one of --pgdata / --pgdata-template):
  --pgdata DIR          data directory to run, used in place
  --pgdata-template DIR copy DIR to <outputdir>/pgdata and run the copy.  This
                        is the hermetic mode and the one the matrix uses: a
                        regression run leaves cluster-wide state behind (the
                        regress_tblspace tablespace, regress_* roles, advanced
                        OID/XID counters) that pg_regress does not clean up,
                        so a reused PGDATA is not a repeatable starting point.
  --init                initdb --pgdata if it does not exist yet (in-place mode)
  --guc NAME=VALUE      extra server GUC (repeatable)
  --label NAME          label recorded in engine.txt/status.txt

Build resolution (defaults come from the meson build dir):
  --build-dir DIR       meson build dir (default $MEMCOW_BUILD_DIR, else the
                        build-fast/ next to the source tree this harness
                        belongs to, else the main checkout's)
  --bindir DIR          override postgres/initdb/pg_ctl/psql location
  --pg-regress PATH     override the pg_regress binary
  --regress-src DIR     override src/test/regress (sql/, expected/, schedule).
                        Defaults to the source tree the build came from --
                        NOT to this worktree, because inputs and binaries must
                        be from the same commit.
  --dlpath DIR          override pg_regress --dlpath

Test selection:
  --subset NAME|FILE    subset name under subsets/ or a path (default: phase0)
  --max-concurrent-tests N   pg_regress limit (default 20, as meson uses)

Run control:
  --outputdir DIR       where results/logs go (required; created)
  --port N              server port (default: an unused one)
  --sockdir DIR         unix socket directory (default: a short mktemp dir)
  --no-leak-check       skip the leak scan (the caller will do it)
  --keep-server         leave the postmaster running on exit (debugging)

Exit status: 0 all tests matched expected and the leak check was clean,
1 regression failures or leaks, 2 could not run.
EOF
}

PGDATA_DIR=
PGDATA_TEMPLATE=
DO_INIT=0
LABEL=
BUILD_DIR=
SUBSET=phase0
OUTPUTDIR=
PORT=
SOCKDIR=
MAXCONC=20
LEAKCHECK=1
KEEP_SERVER=0
GUCS=()

while [ $# -gt 0 ]; do
	case $1 in
		--pgdata)      PGDATA_DIR=$2; shift 2 ;;
		--pgdata-template) PGDATA_TEMPLATE=$2; shift 2 ;;
		--init)        DO_INIT=1; shift ;;
		--guc)         GUCS[${#GUCS[@]}]=$2; shift 2 ;;
		--label)       LABEL=$2; shift 2 ;;
		--build-dir)   BUILD_DIR=$2; shift 2 ;;
		--bindir)      MC_BINDIR=$2; shift 2 ;;
		--pg-regress)  MC_PG_REGRESS=$2; shift 2 ;;
		--regress-src) MC_REGRESS_SRC=$2; shift 2 ;;
		--dlpath)      MC_DLPATH=$2; shift 2 ;;
		--subset)      SUBSET=$2; shift 2 ;;
		--max-concurrent-tests) MAXCONC=$2; shift 2 ;;
		--outputdir)   OUTPUTDIR=$2; shift 2 ;;
		--port)        PORT=$2; shift 2 ;;
		--sockdir)     SOCKDIR=$2; shift 2 ;;
		--no-leak-check) LEAKCHECK=0; shift ;;
		--keep-server) KEEP_SERVER=1; shift ;;
		-h|--help)     usage; exit 0 ;;
		*)             usage >&2; mc_die "unknown option: $1" ;;
	esac
done

[ -n "$OUTPUTDIR" ] || { usage >&2; mc_die "--outputdir is required"; }
if [ -n "$PGDATA_DIR" ] && [ -n "$PGDATA_TEMPLATE" ]; then
	mc_die "--pgdata and --pgdata-template are mutually exclusive"
fi
if [ -z "$PGDATA_DIR" ] && [ -z "$PGDATA_TEMPLATE" ]; then
	usage >&2; mc_die "one of --pgdata / --pgdata-template is required"
fi

[ -n "$BUILD_DIR" ] || BUILD_DIR=$(mc_default_build_dir) ||
	mc_die "cannot find a meson build dir; pass --build-dir or set MEMCOW_BUILD_DIR"
mc_resolve_build "$BUILD_DIR"

# subset name -> file
SUBSET_FILE=$SUBSET
[ -f "$SUBSET_FILE" ] || SUBSET_FILE="$HERE/subsets/$SUBSET.txt"
[ -f "$SUBSET_FILE" ] || mc_die "no such subset: $SUBSET (looked for $HERE/subsets/$SUBSET.txt)"

mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")
[ -n "$LABEL" ] || LABEL=$(basename -- "$OUTPUTDIR")

# --- PGDATA -----------------------------------------------------------------

if [ -n "$PGDATA_TEMPLATE" ]; then
	PGDATA_TEMPLATE=$(mc_abspath "$PGDATA_TEMPLATE")
	if [ ! -d "$PGDATA_TEMPLATE" ] && [ $DO_INIT -eq 1 ]; then
		mkdir -p "$(dirname -- "$PGDATA_TEMPLATE")"
		mc_initdb "$PGDATA_TEMPLATE"
	fi
	[ -f "$PGDATA_TEMPLATE/PG_VERSION" ] ||
		mc_die "not a data directory: $PGDATA_TEMPLATE (pass --init to create it)"
	mc_server_running "$PGDATA_TEMPLATE" &&
		mc_die "a postmaster is running on the template $PGDATA_TEMPLATE"
	PGDATA_DIR="$OUTPUTDIR/pgdata"
	mc_log "copying template $PGDATA_TEMPLATE -> $PGDATA_DIR"
	rm -rf "$PGDATA_DIR"
	cp -R "$PGDATA_TEMPLATE" "$PGDATA_DIR" || mc_die "template copy failed"
	# A stale pid file in the template would block startup.
	rm -f "$PGDATA_DIR/postmaster.pid"
else
	PGDATA_DIR=$(mc_abspath "$PGDATA_DIR")
	if [ ! -d "$PGDATA_DIR" ]; then
		[ $DO_INIT -eq 1 ] || mc_die "no such PGDATA: $PGDATA_DIR (pass --init to create it)"
		mkdir -p "$(dirname -- "$PGDATA_DIR")"
		mc_initdb "$PGDATA_DIR"
	fi
fi

[ -f "$PGDATA_DIR/PG_VERSION" ] || mc_die "not a data directory: $PGDATA_DIR"

if mc_server_running "$PGDATA_DIR"; then
	mc_die "a postmaster is already running on $PGDATA_DIR; stop it first"
fi

# --- schedule ---------------------------------------------------------------

SCHEDULE="$OUTPUTDIR/schedule"
python3 "$HERE/gen_schedule.py" \
	--regress-src "$MC_REGRESS_SRC" \
	--subset "$SUBSET_FILE" \
	--out "$SCHEDULE" --print-groups || mc_die "schedule generation failed"

# --- server -----------------------------------------------------------------

[ -n "$PORT" ] || PORT=$(mc_free_port) || mc_die "cannot find a free port"

OWN_SOCKDIR=0
if [ -z "$SOCKDIR" ]; then
	SOCKDIR=$(mc_make_sockdir) || mc_die "cannot create a socket directory"
	OWN_SOCKDIR=1
fi

LOGFILE="$OUTPUTDIR/postmaster.log"
: >"$LOGFILE"
: >"$LOGFILE.pg_ctl"

cleanup()
{
	if [ $KEEP_SERVER -eq 0 ] && mc_server_running "$PGDATA_DIR"; then
		mc_server_stop "$PGDATA_DIR" "$LOGFILE"
	fi
	if [ $OWN_SOCKDIR -eq 1 ] && [ $KEEP_SERVER -eq 0 ]; then
		rm -rf "$SOCKDIR"
	fi
}
trap cleanup EXIT INT TERM

mc_server_start "$PGDATA_DIR" "$PORT" "$SOCKDIR" "$LOGFILE" \
	${GUCS[@]+"${GUCS[@]}"} || mc_die "postmaster would not start"

# --- record what actually ran ----------------------------------------------
#
# The GUCs asked for are not necessarily the GUCs in effect (shared_buffers
# gets rounded, io_method could be rejected).  Record the server's own answer,
# not ours.
ENGINE_INFO="$OUTPUTDIR/engine.txt"
{
	echo "label=$LABEL"
	echo "pgdata=$PGDATA_DIR"
	echo "pgdata_template=${PGDATA_TEMPLATE:-<none, in-place>}"
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
# Phase 1: the memcow switch, if this build has one.  Absent in Phase 0.
# NB: the GUC is memcow.enabled, not memcow -- an earlier version of this file
# probed the wrong name and therefore reported <absent> even with memcow on,
# which is exactly the sort of thing that makes an A/B record worthless.
# memcow.seed_directory is GUC_SUPERUSER_ONLY, so this must be a superuser
# connection; it is (the harness connects as the bootstrap superuser).
for g in memcow.enabled memcow.seed_directory
do
	v=$(mc_psql "$SOCKDIR" "$PORT" postgres \
		"SELECT coalesce((SELECT setting FROM pg_settings WHERE name = '$g'), '<absent>')" 2>/dev/null) ||
		v='<absent>'
	echo "$g=$v" >>"$ENGINE_INFO"
done

mc_log "engine:"
sed 's/^/    /' "$ENGINE_INFO" >&2

# --- clear cluster-wide leftovers ------------------------------------------
#
# pg_regress drops and recreates the `regression` database, and drops the roles
# it was told to create with --create-role.  It does NOT clean up cluster-wide
# objects the test SQL itself created: test_setup's `regress_tblspace`
# tablespace and the regress_* roles from the tablespace test survive a run and
# make the *next* run on the same PGDATA fail ("tablespace regress_tblspace
# already exists").  --pgdata-template avoids this entirely; this sweep is what
# makes plain --pgdata reusable.  Order matters: the database owns objects in
# the tablespace, so it has to go first.
# NB: one statement per psql -c.  DROP DATABASE cannot run inside the implicit
# transaction block psql builds when a single -c holds several statements.
mc_psql "$SOCKDIR" "$PORT" postgres "DROP DATABASE IF EXISTS regression" >/dev/null 2>&1 ||
	mc_warn "could not drop a pre-existing regression database"
leftovers=$(mc_psql "$SOCKDIR" "$PORT" postgres \
	"SELECT 'DROP TABLESPACE ' || quote_ident(spcname) FROM pg_tablespace
	  WHERE spcname LIKE 'regress%'
	 UNION ALL
	 SELECT 'DROP ROLE ' || quote_ident(rolname) FROM pg_roles
	  WHERE rolname LIKE 'regress%'" 2>/dev/null)
if [ -n "$leftovers" ]; then
	mc_warn "clearing cluster-wide leftovers from a previous run:"
	printf '%s\n' "$leftovers" | sed 's/^/      /' >&2
	printf '%s\n' "$leftovers" | sed 's/$/;/' |
		PGHOST=$SOCKDIR PGPORT=$PORT "$MC_BINDIR/psql" -X -q -v ON_ERROR_STOP=1 -d postgres ||
		mc_die "could not clear leftovers; use --pgdata-template for a hermetic run"
fi

# --- pg_regress -------------------------------------------------------------
#
# No --temp-instance and no --use-existing: pg_regress therefore drops and
# recreates the `regression` database on the server we started, which is what
# makes repeated runs against a reused PGDATA reproducible.

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
	--max-concurrent-tests="$MAXCONC" \
	--host="$SOCKDIR" \
	--port="$PORT" \
	--dbname=regression \
	>"$REGRESS_LOG" 2>&1
REGRESS_RC=$?

tail -20 "$REGRESS_LOG" >&2

# TAP counts, so a caller can compare dispositions between engines.
# NB: `grep -c` exits 1 on zero matches, so `|| echo 0` would append a second
# line rather than substitute one.  Count with wc instead.
OK_COUNT=$(grep '^ok ' "$REGRESS_LOG" 2>/dev/null | wc -l | tr -d ' ')
NOK_COUNT=$(grep '^not ok ' "$REGRESS_LOG" 2>/dev/null | wc -l | tr -d ' ')
# One line per test: "<name> <ok|not-ok>", stable order, for cheap diffing.
# pg_regress prints "ok N  - name  ms" for a serial test and "ok N  + name  ms"
# for a member of a parallel group.
sed -n -E 's/^ok [0-9]+[[:space:]]+[-+][[:space:]]+([^[:space:]]+).*/\1 ok/p;
           s/^not ok [0-9]+[[:space:]]+[-+][[:space:]]+([^[:space:]]+).*/\1 not-ok/p' \
	"$REGRESS_LOG" | sort >"$OUTPUTDIR/tap_status.txt"

# --- stop the server, then look for leaks -----------------------------------
#
# The stop must happen before the scan: AtProcExit_Buffers() and
# pgaio_shutdown() only run when the backends actually exit.
if [ $KEEP_SERVER -eq 0 ]; then
	mc_server_stop "$PGDATA_DIR" "$LOGFILE" || mc_warn "pg_ctl stop reported failure"
fi

LEAK_RC=0
if [ $LEAKCHECK -eq 1 ]; then
	bash "$HERE/check_leaks.sh" \
		--log "$LOGFILE" \
		--engine-info "$ENGINE_INFO" \
		--pgdata "$PGDATA_DIR" \
		--outputdir "$OUTPUTDIR"
	LEAK_RC=$?
fi

# --- verdict ----------------------------------------------------------------

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
	mc_log "PASS  [$LABEL] $OK_COUNT tests ok, 0 failed, leak check clean"
else
	mc_log "FAIL  [$LABEL] pg_regress rc=$REGRESS_RC ($NOK_COUNT failed), leakcheck rc=$LEAK_RC"
	[ -s "$OUTPUTDIR/regression.diffs" ] &&
		mc_log "      diffs: $OUTPUTDIR/regression.diffs"
fi
exit $RC
