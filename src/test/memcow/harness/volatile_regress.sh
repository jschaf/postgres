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
# A test that fails on B but not on A is a divergence.  It is EXPECTED when
# B's result has lines A's lacks and they carry one of the mode's own named
# refusals (temporary files, the commands PreventInVolatileDataDirectory
# refuses) or the absent lock file; anything else is UNEXPECTED and fails the
# run.  The regress seed must be byte-identical after side B.
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

# The mode's named refusals, and the lock file it never writes (misc_functions
# reads postmaster.pid through pg_read_file()).
REFUSAL='temporary files are not supported when "volatile_data_directory" is enabled|is not supported when "volatile_data_directory" is enabled|could not (open|stat) file "postmaster.pid"'
RC=0
: >"$OUTPUTDIR/divergences.txt"
while read -r test status; do
	[ "$status" = not-ok ] || continue
	if grep -qx "$test not-ok" "$OUTPUTDIR/a/tap_status.txt"; then
		echo "$test both-fail" >>"$OUTPUTDIR/divergences.txt"
		continue
	fi
	# The hunks of B's result that A's result does not have.
	if new=$(diff "$OUTPUTDIR/a/results/$test.out" "$OUTPUTDIR/b/results/$test.out" 2>/dev/null |
		grep '^>'); [ -z "$new" ]; then
		echo "$test EXPECTED (identical to A)" >>"$OUTPUTDIR/divergences.txt"
	elif printf '%s\n' "$new" | grep -Eq "$REFUSAL"; then
		echo "$test EXPECTED ($(printf '%s\n' "$new" | grep -Eo "$REFUSAL" | sort -u | tr '\n' ';'))" \
			>>"$OUTPUTDIR/divergences.txt"
	else
		echo "$test UNEXPECTED" >>"$OUTPUTDIR/divergences.txt"
		RC=1
	fi
done <"$OUTPUTDIR/b/tap_status.txt"

if ! cmp -s "$OUTPUTDIR/regress-seed.before" "$OUTPUTDIR/regress-seed.after"; then
	mc_warn "the regress seed changed under side B"
	diff "$OUTPUTDIR/regress-seed.before" "$OUTPUTDIR/regress-seed.after" | head -20 >&2
	RC=1
fi
mc_check_log "$OUTPUTDIR/b.log" || RC=1

mc_banner "volatile regression: $([ $RC -eq 0 ] && echo PASS || echo FAIL)" \
	"A: $(grep -c ' ok$' "$OUTPUTDIR/a/tap_status.txt") ok  B: $(grep -c ' ok$' "$OUTPUTDIR/b/tap_status.txt") ok" \
	"divergences: $(grep -c . "$OUTPUTDIR/divergences.txt") ($(grep -c UNEXPECTED "$OUTPUTDIR/divergences.txt") unexpected)" \
	"details: $OUTPUTDIR/divergences.txt"
exit $RC
