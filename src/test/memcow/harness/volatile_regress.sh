#!/usr/bin/env bash
#
# volatile_regress.sh --- the core regression schedule on a volatile server,
#                         against the same schedule on an ordinary one.
#
# pg_regress creates its `regression` database, and a volatile server
# refuses CREATE DATABASE.  So this derives a regress seed: a copy of the
# memcow seed that already holds `regression`, created the way pg_regress
# creates it and cleanly shut down.  Side A runs the schedule on an ordinary
# memcow server over a writable copy of that seed; side B runs it on a
# volatile_data_directory server whose data directory is the regress seed
# itself.  Both use pg_regress --use-existing, the same GUCs and the same
# schedule.
#
# A test whose results differ between the sides is a divergence, whether or
# not pg_regress passed either side.  It is EXPECTED when, hunk by hunk, the
# first change carries one of the mode's own named refusals (temporary files,
# the commands PreventInVolatileDataDirectory refuses) or the absent lock file,
# and every later change is another refusal, a removal, or the errors a
# refusal leaves behind (objects never created, aborted transactions).
# Anything else, and a missing result, is UNEXPECTED and fails the run.  The
# regress seed must be byte-identical after side B.
#
# Usage:
#   volatile_regress.sh --seed DIR --outputdir DIR [--build-dir DIR]
#                       [--schedule FILE] [--guc NAME=VALUE ...]
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

set -o pipefail

MC_PROG=volatile_regress.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
. "$HERE/common.sh"

SEED='' OUTPUTDIR='' BUILD_DIR='' SCHEDULE=''
GUCS=(max_prepared_transactions=0 autovacuum=off max_parallel_workers_per_gather=0)
while [ $# -gt 0 ]; do
	case $1 in
		--seed)      SEED=$2; shift 2 ;;
		--outputdir) OUTPUTDIR=$2; shift 2 ;;
		--build-dir) BUILD_DIR=$2; shift 2 ;;
		--schedule)  SCHEDULE=$2; shift 2 ;;
		--guc)       GUCS+=("$2"); shift 2 ;;
		-h|--help)   sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)           mc_die "unknown option: $1" ;;
	esac
done
[ -n "$SEED" ] || mc_die "--seed is required"
[ -n "$OUTPUTDIR" ] || mc_die "--outputdir is required"
SEED=$(mc_abspath "$SEED")
[ -n "$BUILD_DIR" ] || BUILD_DIR=$(mc_default_build_dir) || mc_die "pass --build-dir"
mc_resolve_build "$BUILD_DIR"
: "${SCHEDULE:=$MC_REGRESS_SRC/parallel_schedule}"
rm -rf "$OUTPUTDIR" && mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")
export PGUSER=${PGUSER:-postgres}

REGSEED=$OUTPUTDIR/regress-seed
PORT=$(mc_free_port)

stock_gucs()
{
	local g opts="-c port=$PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories="
	opts="$opts -c shared_preload_libraries=memcow -c fsync=off -c wal_level=minimal -c max_wal_senders=0"
	for g in "$@"; do
		opts="$opts -c $g"
	done
	printf '%s' "$opts"
}

# --- the regress seed ------------------------------------------------------

mc_log "deriving the regress seed at $REGSEED"
cp -Rp "$SEED" "$REGSEED" && chmod -R u+w "$REGSEED" || mc_die "copy failed"
"$MC_BINDIR/pg_ctl" -D "$REGSEED" -l "$OUTPUTDIR/regress-seed.log" -w -t 120 \
	-o "$(stock_gucs memcow.enabled=off)" start >/dev/null || mc_die "cannot start the seed copy"
# As pg_regress's create_database() does it.
"$MC_BINDIR/psql" -X -q -h 127.0.0.1 -p "$PORT" -d postgres -v ON_ERROR_STOP=1 <<'SQL' ||
CREATE DATABASE "regression" TEMPLATE=template0;
ALTER DATABASE "regression" SET lc_messages TO 'C';
ALTER DATABASE "regression" SET lc_monetary TO 'C';
ALTER DATABASE "regression" SET lc_numeric TO 'C';
ALTER DATABASE "regression" SET lc_time TO 'C';
ALTER DATABASE "regression" SET bytea_output TO 'hex';
ALTER DATABASE "regression" SET timezone_abbreviations TO 'Default';
CHECKPOINT;
SQL
	mc_die "cannot create the regression database"
"$MC_BINDIR/pg_ctl" -D "$REGSEED" -m fast -w -t 120 stop >/dev/null || mc_die "clean stop failed"
rm -f "$REGSEED/postmaster.opts"

run_side()
{
	local side=$1
	mkdir -p "$OUTPUTDIR/$side"
	PATH="$MC_BINDIR:$PATH" "$MC_PG_REGRESS" \
		--bindir="$MC_BINDIR" --inputdir="$MC_REGRESS_SRC" \
		--expecteddir="$MC_REGRESS_SRC" --dlpath="$MC_DLPATH" \
		--outputdir="$OUTPUTDIR/$side" --schedule="$SCHEDULE" \
		--max-concurrent-tests=20 --host=127.0.0.1 --port="$PORT" \
		--use-existing --dbname=regression >"$OUTPUTDIR/$side/pg_regress.log" 2>&1
	sed -n -E 's/^ok [0-9]+[[:space:]]+[-+][[:space:]]+([^[:space:]]+).*/\1 ok/p;
	           s/^not ok [0-9]+[[:space:]]+[-+][[:space:]]+([^[:space:]]+).*/\1 not-ok/p' \
		"$OUTPUTDIR/$side/pg_regress.log" | sort >"$OUTPUTDIR/$side/tap_status.txt"
	mc_log "$side: $(grep -c ' ok$' "$OUTPUTDIR/$side/tap_status.txt") ok, $(grep -c ' not-ok$' "$OUTPUTDIR/$side/tap_status.txt") not ok"
}

# --- side A: an ordinary memcow server over a copy -------------------------

cp -Rp "$REGSEED" "$OUTPUTDIR/a-pgdata"
"$MC_BINDIR/pg_ctl" -D "$OUTPUTDIR/a-pgdata" -l "$OUTPUTDIR/a.log" -w -t 120 \
	-o "$(stock_gucs memcow.enabled=on "memcow.seed_directory=$REGSEED" "${GUCS[@]}")" \
	start >/dev/null || mc_die "side A did not start"
run_side a
"$MC_BINDIR/pg_ctl" -D "$OUTPUTDIR/a-pgdata" -m fast -w -t 120 stop >/dev/null

# --- side B: a volatile server on the regress seed itself -------------------

mc_seed_manifest "$REGSEED" "$OUTPUTDIR/regress-seed.before"
mc_volatile_start "$REGSEED" "$PORT" "$OUTPUTDIR/b.log" "$OUTPUTDIR/b.pid" \
	log_min_messages=warning "${GUCS[@]}" || mc_die "side B did not start"
run_side b
mc_volatile_stop "$OUTPUTDIR/b.pid" INT
mc_seed_manifest "$REGSEED" "$OUTPUTDIR/regress-seed.after"

# --- classification --------------------------------------------------------

# Every test whose results differ between the sides, whatever pg_regress
# said about either, is classified hunk by hunk (classify below).
RC=0
python3 - "$OUTPUTDIR" "$SCHEDULE" >"$OUTPUTDIR/divergences.txt" <<'PY' || RC=1
import difflib, os, re, sys

out, schedule = sys.argv[1:3]
# The mode's named refusals, and the lock file it never writes
# (misc_functions reads postmaster.pid through pg_read_file()).
REFUSAL = re.compile(r'(is|are) not supported when "volatile_data_directory" is enabled'
                     r'|could not (open|stat) file "postmaster\.pid"'
                     # test_setup's CREATE TABLESPACE regress_tblspace is refused
                     r'|tablespace "regress_tblspace" does not exist')
# What a refusal leaves behind later in the same file: objects that were never
# created, aborted transactions, and the error's own context lines.
CASCADE = re.compile(r'^(ERROR: .*(does not exist|current transaction is aborted)'
                     r'|LINE \d+:|DETAIL: |HINT: |CONTEXT: |QUERY: |\s*\^\s*$|\s*$)')
# Tests whose counter checks cannot grow in the mode: it writes no relation
# WAL, no WAL to files and no buffers at checkpoints.  Only a single-line
# "t" -> "f" change is accepted there.
COUNTERS = {'stats'}
# Tests where a refusal changes later results, not just errors.  Named, with
# the reason; after its first refusal such a test may differ freely.
RESULT_CASCADES = {
    'cluster': 'CLUSTER over maintenance_work_mem is refused, so clstr_4 stays unsorted',
    'tablespace': 'CREATE TABLESPACE is refused, so the catalog queries find no tablespace',
}

tests = []
for line in open(schedule):
    if line.startswith('test:'):
        tests += line.split()[1:]
bad = 0
for test in tests:
    a_path = os.path.join(out, 'a', 'results', test + '.out')
    b_path = os.path.join(out, 'b', 'results', test + '.out')
    if not os.path.exists(a_path):
        continue
    if not os.path.exists(b_path):
        print(test, 'UNEXPECTED (no result on the volatile side)')
        bad += 1
        continue
    a = open(a_path, errors='replace').read().splitlines()
    b = open(b_path, errors='replace').read().splitlines()
    if a == b:
        continue
    refused = False
    verdict = 'EXPECTED'
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == 'equal':
            continue
        added = b[j1:j2]
        if test in COUNTERS and a[i1:i2] == [' t'] and added == [' f']:
            continue
        if any(REFUSAL.search(line) for line in added):
            refused = True
            continue
        if not refused:
            verdict = 'UNEXPECTED (differs before any refusal: A line %d)' % (i1 + 1)
            break
        if test in RESULT_CASCADES:
            continue
        if not all(CASCADE.match(line) for line in added):
            verdict = 'UNEXPECTED (non-error lines after a refusal: A line %d)' % (i1 + 1)
            break
    print(test, verdict)
    bad += verdict != 'EXPECTED'
sys.exit(1 if bad else 0)
PY

if ! cmp -s "$OUTPUTDIR/regress-seed.before" "$OUTPUTDIR/regress-seed.after"; then
	mc_warn "the regress seed changed under side B"
	diff "$OUTPUTDIR/regress-seed.before" "$OUTPUTDIR/regress-seed.after" | head -20 >&2
	RC=1
fi
mc_check_log "$OUTPUTDIR/b.log" || RC=1

mc_banner "volatile regression: $([ $RC -eq 0 ] && echo PASS || echo FAIL)" \
	"A: $(grep -c ' ok$' "$OUTPUTDIR/a/tap_status.txt") ok  B: $(grep -c ' ok$' "$OUTPUTDIR/b/tap_status.txt") ok" \
	"divergent tests: $(grep -c . "$OUTPUTDIR/divergences.txt") ($(grep -c UNEXPECTED "$OUTPUTDIR/divergences.txt") unexpected)" \
	"details: $OUTPUTDIR/divergences.txt"
exit $RC
