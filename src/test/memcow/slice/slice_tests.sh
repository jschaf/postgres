#!/usr/bin/env bash
#
# slice_tests.sh --- the memcow-specific half of the plan §7.1 gate.
#
# diff_engines.sh answers "does memcow produce the same output as md?".  It
# cannot answer anything that has no md counterpart, and §7.1 names four such
# things while this project's findings log names five more.  Those nine cases
# live here, plus a tenth (S10) written for a defect this suite found on its
# first differential run.  Each one drives a real cluster: the seed built by
# seed/build_seed.sh, the RAM-backed runtime PGDATA assembled by
# seed/assemble_ramdir.sh, and a postmaster started with memcow_enabled=on on
# its COMMAND LINE (contract ADDENDUM §O -- there is no other way to set it).
#
# ---------------------------------------------------------------------------
# The cases
# ---------------------------------------------------------------------------
#
#   S1  mixed seed/overlay vectors     §7.1 item 1
#   S2  overlay page corruption        §7.1 item 2
#   S3  ALTER TABLE SET TABLESPACE     §7.1 item 3
#   S4  pg_prewarm, all three modes    §7.1 item 4
#   S5  past-EOF read is a clean ERROR findings: commit 1.3's two-phase loop
#   S6  fingerprint mismatch is FATAL  findings: ten implemented failure modes
#   S7  the seed is byte-identical     invariant I3
#   S8  a crashed cluster will not run findings: reinit.c, Assert(!InRecovery)
#   S9  documented divergences         findings: pg_relation_size returns 0
#   S10 truncate runs in a critical section        <- currently FAILS, see below
#
# ---------------------------------------------------------------------------
# Every case has a negative control, and it is not optional
# ---------------------------------------------------------------------------
#
# A test that has never failed is not known to work.  `--negative-control`
# re-runs each selected case with a deliberate, case-specific sabotage applied
# and requires the case to FAIL; a case that still passes with its subject
# broken is reported as an INSENSITIVE INSTRUMENT and fails the run.  The
# sabotage for each case is documented at its `nc_` function.  This is the same
# discipline the Phase 0 harness earned its trust with.
#
# ---------------------------------------------------------------------------
# Isolation between cases: restart, do not re-assemble
# ---------------------------------------------------------------------------
#
# The overlay lives in DSA over dynamic shared memory, so it dies with the
# postmaster.  A postmaster restart therefore reverts every relation in the
# cluster to the seed -- which makes a restart the cheapest possible reset and
# is why each case starts by restarting rather than by re-assembling 200 MB of
# RAM disk.  Two consequences, both worth knowing:
#
#   * committed catalog changes vanish across a restart too (they are relation
#     pages like any other), while pg_control, the WAL and the SLRUs in the RAM
#     PGDATA do NOT revert.  That asymmetry is the design (plan Appendix C:
#     cluster-monotonic state is exempt from reversion), but it means a case
#     may not assume anything it created in a previous case still exists.
#   * pg_filenode.map is a real file in the RAM PGDATA and does NOT revert, so
#     a mapped-catalog rewrite would survive a restart while its storage did
#     not.  That is exactly the hazard plan §4.7/§6 forbids and verifies; no
#     case here performs one.
#
# S8 deliberately crashes the cluster and therefore re-assembles the RAM dir
# afterwards -- a crashed memcow cluster cannot restart, by design.
#
# ---------------------------------------------------------------------------
# Why this is NOT registered as a meson suite
# ---------------------------------------------------------------------------
#
# It would take one line in src/test/meson.build, and it would be wrong.  A
# meson suite is expected to run from a clean checkout; this one needs a 200 MB
# seed cluster built by the exact binary under test (the fingerprint pins the
# postgres binary's size and SHA-256) and a mounted RAM disk, neither of which
# meson can produce and neither of which should be produced silently under
# `meson test`.  Wiring it in would give `meson test` a suite that fails for
# environmental reasons on every machine that has not run build_seed.sh, which
# trains people to ignore it.  The entry points are run_gate.sh --phase 1 and,
# above that, build/ci.sh.
#
# Usage:
#   slice_tests.sh --seed DIR --pgdata DIR [--build-dir DIR] [options]
#
#     --seed DIR          the read-only seed (build_seed.sh -o)
#     --pgdata DIR        the assembled runtime PGDATA (assemble_ramdir.sh)
#     --ram-mount DIR     mount point assemble_ramdir.sh was given; needed only
#                         by S8, which has to re-assemble.  Defaults to the
#                         parent of --pgdata.
#     --build-dir DIR     meson build dir (default: $MEMCOW_BUILD_DIR)
#     --outputdir DIR     logs and artifacts (default: <pgdata>/../slice-out)
#     --db NAME           database to run in (default: memcow_lane_00)
#     --case NAME         run only this case (repeatable); default: all
#     --list              list the cases and exit
#     --negative-control  run the sabotage variant of each selected case and
#                         require it to fail
#     --keep-going        keep running after a failing case (default)
#     --stop-on-fail      stop at the first failing case
#
# Exit status: 0 every selected case passed, 1 a case failed, 2 could not run.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

# See check_leaks.sh for why there is no `set -u`.
set -o pipefail

MC_PROG=slice_tests.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HARNESS=$(cd -- "$HERE/../harness" && pwd)
SEEDDIR_SCRIPTS=$(cd -- "$HERE/../seed" && pwd)
# shellcheck source=../harness/common.sh
. "$HARNESS/common.sh"

ALL_CASES="S1_mixed_vectors S2_overlay_corruption S3_set_tablespace \
S4_pg_prewarm S5_past_eof S6_fingerprint S7_seed_immutable S8_crash_refuses \
S9_documented_divergences S10_truncate_crit_section"

SEED=
PGDATA=
RAM_MOUNT=
BUILD_DIR=
OUTPUTDIR=
DB=memcow_lane_00
CASES=()
NEGATIVE=0
STOP_ON_FAIL=0

while [ $# -gt 0 ]; do
	case $1 in
		--seed)        SEED=$2; shift 2 ;;
		--pgdata)      PGDATA=$2; shift 2 ;;
		--ram-mount)   RAM_MOUNT=$2; shift 2 ;;
		--build-dir)   BUILD_DIR=$2; shift 2 ;;
		--outputdir)   OUTPUTDIR=$2; shift 2 ;;
		--db)          DB=$2; shift 2 ;;
		--case)        CASES[${#CASES[@]}]=$2; shift 2 ;;
		--list)        printf '%s\n' $ALL_CASES; exit 0 ;;
		--negative-control) NEGATIVE=1; shift ;;
		--keep-going)  STOP_ON_FAIL=0; shift ;;
		--stop-on-fail) STOP_ON_FAIL=1; shift ;;
		-h|--help)     sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)             mc_die "unknown option: $1" ;;
	esac
done

[ -n "$SEED" ]   || mc_die "--seed is required"
[ -n "$PGDATA" ] || mc_die "--pgdata is required"
SEED=$(mc_abspath "$SEED")
PGDATA=$(mc_abspath "$PGDATA")
[ -f "$SEED/PG_VERSION" ] || mc_die "not a seed PGDATA: $SEED"
[ -f "$SEED/memcow_seed.fingerprint" ] ||
	mc_die "no memcow_seed.fingerprint in $SEED -- not a seed built by build_seed.sh"
[ -f "$PGDATA/PG_VERSION" ] || mc_die "not a data directory: $PGDATA"
: "${RAM_MOUNT:=$(dirname -- "$PGDATA")}"

[ -n "$BUILD_DIR" ] || BUILD_DIR=$(mc_default_build_dir) ||
	mc_die "cannot find a meson build dir; pass --build-dir or set MEMCOW_BUILD_DIR"
mc_resolve_build "$BUILD_DIR"

: "${OUTPUTDIR:=$(dirname -- "$PGDATA")/slice-out}"
mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")

[ ${#CASES[@]} -gt 0 ] || read -r -a CASES <<<"$ALL_CASES"

for c in "${CASES[@]}"; do
	case " $ALL_CASES " in
		*" $c "*) ;;
		*) mc_die "unknown case: $c (see --list)" ;;
	esac
done

SOCKDIR=$(mc_make_sockdir) || mc_die "cannot create a socket directory"
PORT=$(mc_free_port) || mc_die "cannot find a free port"
LOGFILE="$OUTPUTDIR/postmaster.log"

# ---------------------------------------------------------------------------
# server control
#
# memcow_enabled and memcow_seed_directory go on the postmaster COMMAND LINE.
# That is not a stylistic choice: ALTER SYSTEM is refused
# (GUC_DISALLOW_IN_AUTO_FILE), initdb -c leaks the setting into the seed's
# postgresql.conf which assemble_ramdir then copies into the RAM dir, and
# PGOPTIONS / ALTER DATABASE|ROLE / SET all fail on a PGC_POSTMASTER GUC.
# Contract ADDENDUM §O.
# ---------------------------------------------------------------------------

SEED_OVERRIDE=          # S6 points the server at a doctored seed
EXTRA_GUCS=()

pg_start()
{
	local seed=${SEED_OVERRIDE:-$SEED}
	local opts
	opts="-c memcow_enabled=on"
	opts="$opts -c memcow_seed_directory=$seed"
	opts="$opts -c listen_addresses="
	opts="$opts -c unix_socket_directories=$SOCKDIR"
	opts="$opts -c log_min_messages=warning"
	opts="$opts -c log_statement=none"
	opts="$opts -c restart_after_crash=off"
	opts="$opts -p $PORT"
	local g
	for g in ${EXTRA_GUCS[@]+"${EXTRA_GUCS[@]}"}; do
		opts="$opts -c $g"
	done
	"$MC_BINDIR/pg_ctl" -D "$PGDATA" -l "$LOGFILE" -p "$MC_BINDIR/postgres" \
		-o "$opts" -w -t 60 start >>"$LOGFILE.pg_ctl" 2>&1
}

pg_stop()
{
	local mode=${1:-fast}
	"$MC_BINDIR/pg_ctl" -D "$PGDATA" -m "$mode" -w -t 60 stop \
		>>"$LOGFILE.pg_ctl" 2>&1
}

pg_running() { "$MC_BINDIR/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; }

# cluster_state --- pg_control's own word for whether this PGDATA is startable.
cluster_state()
{
	"$MC_BINDIR/pg_controldata" -D "$PGDATA" 2>/dev/null |
		sed -n 's/^Database cluster state: *//p'
}

# ensure_startable --- a memcow PGDATA that needs recovery cannot be started at
# all (that is S8's whole subject), so if a previous case or a previous run of
# this script left one behind, re-assemble rather than reporting every
# subsequent case as "server would not start".  This is repair, and it says so
# in the log; it is never applied inside S8, which calls pg_start directly.
ensure_startable()
{
	local st
	st=$(cluster_state)
	case $st in
		"shut down"|"shut down in recovery") return 0 ;;
		"")	mc_warn "cannot read pg_controldata for $PGDATA"; return 1 ;;
		*)	mc_warn "PGDATA is in state '$st' (needs recovery); re-assembling"
			reassemble ;;
	esac
}

# restart --- the per-case reset.  Returns non-zero if the server will not come
# back, which every case treats as a hard failure.
restart()
{
	if pg_running; then
		if ! pg_stop fast; then
			mc_warn "clean shutdown failed; forcing, then re-assembling"
			pg_stop immediate
		fi
	fi
	ensure_startable || return 1
	: >"$LOGFILE"
	pg_start
}

reassemble()
{
	pg_running && pg_stop immediate
	bash "$SEEDDIR_SCRIPTS/assemble_ramdir.sh" -s "$SEED" -m "$RAM_MOUNT" \
		-b "$MC_BINDIR" -f >"$OUTPUTDIR/reassemble.log" 2>&1
}

# psql SQL... --- tuples-only, unaligned, errors NOT fatal (cases assert on the
# text of errors as often as on results).  stderr is folded into stdout so a
# case can match ERROR/WARNING text.
psql()
{
	PGHOST=$SOCKDIR PGPORT=$PORT "$MC_BINDIR/psql" -X -q -A -t \
		-d "$DB" -v ON_ERROR_STOP=0 "$@" 2>&1
}

# ---------------------------------------------------------------------------
# assertion helpers
#
# Each case accumulates failures in CASE_FAIL rather than returning early, so
# one run reports every broken expectation instead of only the first.
# ---------------------------------------------------------------------------

CASE_FAIL=0

ck()      # ck DESCRIPTION CONDITION-RC
{
	if [ "$2" -eq 0 ]; then
		printf '    ok      %s\n' "$1"
	else
		printf '    NOT OK  %s\n' "$1"
		CASE_FAIL=1
	fi
}

ck_eq()   # ck_eq DESCRIPTION EXPECTED ACTUAL
{
	if [ "$2" = "$3" ]; then
		printf '    ok      %s (= %s)\n' "$1" "$2"
	else
		printf '    NOT OK  %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
		CASE_FAIL=1
	fi
}

ck_match() # ck_match DESCRIPTION REGEX TEXT
{
	if printf '%s' "$3" | grep -Eq "$2"; then
		printf '    ok      %s\n' "$1"
	else
		printf '    NOT OK  %s: no match for /%s/ in:\n' "$1" "$2"
		printf '%s\n' "$3" | sed 's/^/              /'
		CASE_FAIL=1
	fi
}

ck_nomatch()
{
	if printf '%s' "$3" | grep -Eq "$2"; then
		printf '    NOT OK  %s: unexpected match for /%s/ in:\n' "$1" "$2"
		printf '%s\n' "$3" | sed 's/^/              /'
		CASE_FAIL=1
	else
		printf '    ok      %s\n' "$1"
	fi
}

# ck_no_crash --- the standing requirement on every case: nothing in this
# case's slice of the server log may be an assert, a PANIC, a signal death or
# one of the resource-leak messages core emits at backend exit.  The allowlist
# is check_leaks.sh's; it is narrow on purpose (a clean regression run logs
# hundreds of legitimate WARNINGs and ERRORs).
ck_no_crash()
{
	local hits
	hits=$(grep -nE 'TRAP: |PANIC:|was terminated by signal|leaked AIO handle|AIO handle was not submitted|refcount leak|resource was not closed|open AIO batch at end' \
		"$LOGFILE" 2>/dev/null)
	if [ -z "$hits" ]; then
		printf '    ok      no asserts, PANICs, signal deaths or leaks in the server log\n'
	else
		printf '    NOT OK  server log shows an assert/crash/leak:\n'
		printf '%s\n' "$hits" | sed 's/^/              /'
		CASE_FAIL=1
	fi
}

# ---------------------------------------------------------------------------
# shared fixtures
# ---------------------------------------------------------------------------

# seed_digest --- SHA-256 of every relation-shaped file in the seed, sorted.
# This is invariant I3's instrument: the seed must be byte-identical before and
# after any workload.  Scoped to base/ and global/ because only there does
# md.c's naming convention mean "relation fork segment" (pg_xact segments are
# literally named 0000).
seed_digest()
{
	local out=$1
	( cd "$SEED" && find base global -type f 2>/dev/null | sort |
	  xargs shasum -a 256 ) >"$out" 2>/dev/null
}

# runtime_relation_files --- how many relation-shaped files the RUNNING PGDATA
# holds.  Under memcow this must be zero: every page served has to have come
# from the seed mapping or the overlay, because md had nothing to read.
runtime_relation_files()
{
	find "$PGDATA/base" "$PGDATA/global" -type f 2>/dev/null |
		grep -cE '/[0-9]+(_fsm|_vm|_init)?(\.[0-9]+)?$'
}

ensure_test_aio()
{
	psql -c "CREATE EXTENSION IF NOT EXISTS test_aio" >/dev/null 2>&1
}

ensure_pg_prewarm()
{
	psql -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm" >/dev/null 2>&1
}

# fork_nblocks REL FORK --- the fork's size AS MEMCOW REPORTS IT.
#
# Not pg_relation_size(): that one stat()s the runtime PGDATA and answers 0
# under memcow (see S9).  pg_prewarm in 'prefetch' mode asks smgrnblocks() and
# returns the number of blocks in the range, which is the size memcow itself
# believes in -- exactly the number a past-EOF test has to be relative to.
# Prints nothing if the answer is not a number, so callers can tell.
fork_nblocks()
{
	local n
	ensure_pg_prewarm
	n=$(psql -tA -c "SELECT pg_prewarm('$1', 'prefetch', '${2:-main}')" 2>/dev/null)
	case $n in
		''|*[!0-9]*) return 1 ;;
		*) printf '%s\n' "$n" ;;
	esac
}

# ===========================================================================
# S1 -- mixed seed/overlay vectors (plan §7.1 item 1)
#
# public.events is 67 blocks in the seed.  Dirtying every odd block leaves the
# relation half seed and half overlay with a boundary between EVERY adjacent
# pair of blocks, which is the worst case for a per-block resolution loop and
# the likeliest home for an off-by-one.
#
# The oracle is the relation's own physical layout.  Before dirtying, each row
# is recorded together with the block it sits on and a digest of its contents.
# A row that was on an even (seed-served) block must afterwards still be on
# that same block with that same digest: if the read path ever served block N-1
# or N+1 in place of block N, a scan would report those tuples under the wrong
# block number and the mapping would break.  No external reference run is
# needed, which is the point -- this catches a resolution bug even when both
# engines are memcow.
#
# The test also asserts that the reads actually SPAN the boundary rather than
# happening one block at a time: test_aio's read_buffers() reports how many
# blocks each StartReadBuffers call covered, and a 16-block read over
# alternating sources is 15 seed<->overlay transitions inside one
# memcow_startreadv.
# ===========================================================================

S1_mixed_vectors()
{
	restart || { ck "server started" 1; return; }
	ensure_test_aio

	local out
	out=$(psql -c "
CREATE TABLE mixmap AS
  SELECT event_id, (ctid::text::point)[0]::int AS blk, md5(t.*::text) AS h
  FROM public.events t;
SELECT 'rows', count(*) FROM mixmap;
SELECT 'blocks', max(blk) + 1 FROM mixmap;
")
	ck_match "snapshot of the seed layout taken" '^rows\|4000$' "$out"
	ck_match "seed relation is genuinely multi-block" '^blocks\|6[0-9]$' "$out"

	# --- round 1: dirty the odd blocks -----------------------------------
	out=$(psql -c "
UPDATE public.events SET kind = kind
 WHERE (ctid::text::point)[0]::int % 2 = 1;
CHECKPOINT;
")
	ck_nomatch "round 1 dirtying raised no error" 'ERROR' "$out"

	out=$(psql -c "SELECT evict_rel('public.events')" \
		-c "SELECT blockoff, nblocks FROM read_buffers('public.events', 0, 16)")
	ck_match "one readv covered 16 blocks, i.e. 15 seed<->overlay transitions" \
		'^0\|16$' "$out"

	out=$(psql -c "SELECT evict_rel('public.events')" -c "
SELECT 'total', count(*) FROM public.events;
SELECT 'even_moved', count(*) FROM public.events t JOIN mixmap m USING (event_id)
  WHERE m.blk % 2 = 0 AND (t.ctid::text::point)[0]::int <> m.blk;
SELECT 'even_changed', count(*) FROM public.events t JOIN mixmap m USING (event_id)
  WHERE m.blk % 2 = 0 AND md5(t.*::text) <> m.h;
SELECT 'lost', count(*) FROM mixmap m
  WHERE NOT EXISTS (SELECT 1 FROM public.events t WHERE t.event_id = m.event_id);
SELECT 'changed', count(*) FROM public.events t JOIN mixmap m USING (event_id)
  WHERE md5(t.*::text) <> m.h;
")
	ck_match "round 1: every row still present"          '^total\|4000$'      "$out"
	ck_match "round 1: seed-served rows did not move"    '^even_moved\|0$'    "$out"
	ck_match "round 1: seed-served rows unchanged"       '^even_changed\|0$'  "$out"
	ck_match "round 1: no row lost"                      '^lost\|0$'          "$out"
	ck_match "round 1: no row's contents changed"        '^changed\|0$'       "$out"

	# --- round 2: dirty what round 1 left alone --------------------------
	#
	# The second round matters because it inverts which half of the relation
	# comes from where: blocks that were seed-served are now overlay pages
	# sitting on top of a seed page, and the previously-overlaid ones are
	# read again from the overlay.  A resolution path that happened to work
	# when "odd = overlay" will not survive both.
	out=$(psql -c "
UPDATE public.events SET kind = kind
 WHERE (ctid::text::point)[0]::int % 2 = 0;
CHECKPOINT;
")
	ck_nomatch "round 2 dirtying raised no error" 'ERROR' "$out"

	out=$(psql -c "SELECT evict_rel('public.events')" -c "
SELECT 'total', count(*) FROM public.events;
SELECT 'lost', count(*) FROM mixmap m
  WHERE NOT EXISTS (SELECT 1 FROM public.events t WHERE t.event_id = m.event_id);
SELECT 'changed', count(*) FROM public.events t JOIN mixmap m USING (event_id)
  WHERE md5(t.*::text) <> m.h;
SELECT 'idx', count(*) FROM public.events WHERE account_id = 42;
SELECT 'idxref', count(*) FROM mixmap m JOIN public.events t USING (event_id)
  WHERE t.account_id = 42;
")
	ck_match "round 2: every row still present"   '^total\|4000$' "$out"
	ck_match "round 2: no row lost"               '^lost\|0$'     "$out"
	ck_match "round 2: no row's contents changed" '^changed\|0$'  "$out"
	# The index is itself a half-seed half-overlay relation by now.
	local a b
	a=$(printf '%s' "$out" | sed -n 's/^idx|//p')
	b=$(printf '%s' "$out" | sed -n 's/^idxref|//p')
	ck_eq "index scan agrees with the heap after both rounds" "$b" "$a"

	ck_no_crash
}

# The sabotage: read the relation with an off-by-one range, which is what a
# broken per-block resolution would effectively do.  If the case's oracle
# cannot tell the difference, the oracle is not measuring block identity.
nc_S1_mixed_vectors()
{
	restart || { ck "server started" 1; return; }
	ensure_test_aio
	psql -c "CREATE TABLE mixmap AS
	  SELECT event_id, (ctid::text::point)[0]::int AS blk, md5(t.*::text) AS h
	  FROM public.events t" >/dev/null
	# Shift every recorded block by one.  A correct engine now MUST make the
	# 'even_moved' assertion fail; a case that still passes is not looking at
	# block identity at all.
	psql -c "UPDATE mixmap SET blk = blk + 1" >/dev/null
	local out
	out=$(psql -c "
SELECT 'even_moved', count(*) FROM public.events t JOIN mixmap m USING (event_id)
  WHERE m.blk % 2 = 0 AND (t.ctid::text::point)[0]::int <> m.blk;
")
	ck_match "sabotage detected: block identity check reacts to a 1-block shift" \
		'^even_moved\|[1-9]' "$out"
}

# ===========================================================================
# S2 -- overlay page corruption (plan §7.1 item 2)
#
# THE MECHANISM, and why it is sound.
#
# An overlay page cannot be corrupted with dd: it is not a file, it is BLCKSZ
# bytes inside a DSA arena in dynamic shared memory.  The mechanism used here
# is upstream's own page-corruption helper, test_aio's modify_rel_block()
# (src/test/modules/test_aio/test_aio.c), which reads a block into local
# memory, evicts the buffer, damages the copy -- pd_special = BLCKSZ + 1 for a
# header corruption, or pd_checksum + 1 for a checksum corruption -- and writes
# it back with smgrwrite().
#
# Under md that write lands in a file.  Under memcow the identical call lands
# in memcow_writev(), i.e. in the overlay, by exactly the path a checkpoint or
# a buffer eviction uses.  So the bytes really are the overlay's, no engine
# code is modified, no injection point is needed, and the tool is one upstream
# already trusts for this job.  The test proves the placement rather than
# asserting it: after corrupting, the seed's own copy of the block is shown to
# be untouched, and a postmaster restart -- which discards the overlay and
# nothing else -- makes the corruption disappear.
#
# The case is only meaningful because overlay pages are stored post-
# PageSetChecksum (bufmgr.c:4596, localbuf.c:203), so the unmodified buffer
# completion callback runs PageIsVerified() over an overlay page exactly as it
# would over a page md read from disk.
# ===========================================================================

S2_overlay_corruption()
{
	restart || { ck "server started" 1; return; }
	ensure_test_aio

	local relfile out before after
	relfile=$(psql -tA -c "SELECT pg_relation_filepath('public.events')")
	[ -f "$SEED/$relfile" ] || { ck "seed file $relfile exists" 1; return; }
	before=$(shasum -a 256 "$SEED/$relfile" | awk '{print $1}')

	# --- corrupt the page header -----------------------------------------
	out=$(psql -c "SELECT modify_rel_block('public.events', 5, corrupt_header=>true)" \
		-c "SELECT evict_rel('public.events')" \
		-c "SELECT count(*) FROM public.events")
	ck_match "a corrupt overlay page is a clean ERROR naming the block" \
		'ERROR:  invalid page in block 5 of relation' "$out"
	ck_nomatch "and not a crash" 'server closed the connection|TRAP' "$out"

	# --- the same page, zero_damaged_pages honoured -----------------------
	out=$(psql -c "SET zero_damaged_pages = on;
SELECT evict_rel('public.events');
SELECT count(*) FROM public.events;")
	ck_match "zero_damaged_pages=on turns it into a WARNING" \
		'WARNING:  invalid page in block 5 of relation .*; zeroing out page' "$out"
	ck_nomatch "zero_damaged_pages=on does not raise" 'ERROR' "$out"
	ck_match "and the query completes with the page zeroed (fewer rows)" \
		'^3[0-9]{3}$' "$out"

	# --- the corruption is in the overlay, not the seed -------------------
	#
	# Two independent proofs.  First the seed file itself is unchanged.  Then
	# a restart -- which discards the DSA arena and nothing else -- makes the
	# damage vanish, which no file-backed corruption would do.  The restart
	# also gives the checksum sub-case below a clean relation to work on,
	# since block 5 is still damaged until the overlay goes away.
	after=$(shasum -a 256 "$SEED/$relfile" | awk '{print $1}')
	ck_eq "the seed file is byte-identical after corrupting the overlay" \
		"$before" "$after"

	restart || { ck "server restarted" 1; return; }
	ensure_test_aio
	out=$(psql -c "SELECT count(*) FROM public.events")
	ck_match "a restart discards the overlay and the corruption with it" \
		'^4000$' "$out"

	# --- corrupt only the checksum ---------------------------------------
	out=$(psql -c "SELECT modify_rel_block('public.events', 9, corrupt_checksum=>true)" \
		-c "SELECT evict_rel('public.events')" \
		-c "SELECT count(*) FROM public.events")
	ck_match "a bad checksum on an overlay page is caught too" \
		'ERROR:  invalid page in block 9 of relation' "$out"

	after=$(shasum -a 256 "$SEED/$relfile" | awk '{print $1}')
	ck_eq "and the seed is still byte-identical" "$before" "$after"

	ck_no_crash
}

# The sabotage: corrupt nothing at all, but run the identical assertions.  If
# they still pass, they are matching something other than the error the engine
# produced -- e.g. a stale log line, or a regex so loose it matches the prompt.
nc_S2_overlay_corruption()
{
	restart || { ck "server started" 1; return; }
	ensure_test_aio
	local out
	out=$(psql -c "SELECT evict_rel('public.events')" \
		-c "SELECT count(*) FROM public.events")
	if printf '%s' "$out" | grep -Eq 'ERROR:  invalid page in block 5 of relation'; then
		ck "sabotage detected: uncorrupted read must NOT report an invalid page" 1
	else
		ck "sabotage detected: uncorrupted read reports no invalid page" 0
	fi
}

# ===========================================================================
# S3 -- ALTER TABLE ... SET TABLESPACE (plan §7.1 item 3)
#
# This is the one case that exercises RelationCopyStorage() (storage.c:519),
# the main synchronous smgrreadv() caller and a genuinely different code path
# from the AIO read: no handle, no synthetic completion, memcow_readv() rather
# than memcow_startreadv().  It also drives smgrextend() per block into a
# relation whose tablespace does not exist in the seed at all.
#
# THE SEED'S TABLESPACE SITUATION, which is what makes this interesting: the
# seed has pg_default and pg_global and nothing else, so a second tablespace is
# necessarily 100% overlay.  CREATE TABLESPACE itself creates only a directory
# and a symlink in the RUNNING PGDATA -- no relation file -- and the test
# asserts that the tablespace directory stays empty of relation files
# afterwards, which is the local form of invariant I3.
# ===========================================================================

S3_set_tablespace()
{
	restart || { ck "server started" 1; return; }
	ensure_test_aio

	local tsdir="$RAM_MOUNT/slice_tblspc"
	rm -rf "$tsdir"; mkdir -p "$tsdir" || { ck "tablespace dir created" 1; return; }

	local out before_events before_docs
	before_events=$(psql -tA -c "SELECT md5(string_agg(t.*::text, '|' ORDER BY event_id)) FROM public.events t")
	before_docs=$(psql -tA -c "SELECT md5(string_agg(d.*::text, '|' ORDER BY doc_id)) FROM public.documents d")

	out=$(psql -c "CREATE TABLESPACE slice_ts LOCATION '$tsdir'")
	ck_nomatch "CREATE TABLESPACE succeeds under memcow" 'ERROR' "$out"

	# A heap with an index, then a TOASTed relation: RelationCopyStorage runs
	# over the main/fsm/vm forks of each, and over the TOAST heap and index.
	out=$(psql -c "ALTER TABLE public.events SET TABLESPACE slice_ts")
	ck_nomatch "ALTER TABLE events SET TABLESPACE succeeds" 'ERROR' "$out"
	out=$(psql -c "ALTER TABLE public.documents SET TABLESPACE slice_ts")
	ck_nomatch "ALTER TABLE documents (TOASTed) SET TABLESPACE succeeds" 'ERROR' "$out"
	out=$(psql -c "ALTER INDEX public.events_account_id_idx SET TABLESPACE slice_ts")
	ck_nomatch "ALTER INDEX SET TABLESPACE succeeds" 'ERROR' "$out"

	# Re-read from the copy, and again after evicting so the read is served
	# from the overlay under the NEW tablespace rather than from cache.
	out=$(psql -tA -c "SELECT md5(string_agg(t.*::text, '|' ORDER BY event_id)) FROM public.events t")
	ck_eq "heap content survives RelationCopyStorage" "$before_events" "$out"
	out=$(psql -c "SELECT evict_rel('public.events'); SELECT evict_rel('public.documents')" >/dev/null;
	      psql -tA -c "SELECT md5(string_agg(t.*::text, '|' ORDER BY event_id)) FROM public.events t")
	ck_eq "and again after eviction, i.e. re-read from the new overlay" \
		"$before_events" "$out"
	out=$(psql -tA -c "SELECT md5(string_agg(d.*::text, '|' ORDER BY doc_id)) FROM public.documents d")
	ck_eq "TOASTed content survives too" "$before_docs" "$out"

	out=$(psql -tA -c "SELECT count(*) FROM public.events WHERE account_id = 42")
	local viaidx
	viaidx=$(psql -tA -c "SET enable_seqscan = off; SELECT count(*) FROM public.events WHERE account_id = 42")
	ck_eq "the moved index agrees with the heap" "$out" "$viaidx"

	local nfiles
	nfiles=$(find "$tsdir" -type f 2>/dev/null |
		 grep -cE '/[0-9]+(_fsm|_vm|_init)?(\.[0-9]+)?$')
	ck_eq "the new tablespace holds no relation files (I3)" "0" "$nfiles"

	psql -c "ALTER TABLE public.events SET TABLESPACE pg_default;
	         ALTER TABLE public.documents SET TABLESPACE pg_default;
	         ALTER INDEX public.events_account_id_idx SET TABLESPACE pg_default;
	         DROP TABLESPACE slice_ts" >/dev/null
	ck_no_crash
}

# The sabotage: compare the content digest against a deliberately wrong value.
# If the case still passes, its comparison is not actually comparing.
nc_S3_set_tablespace()
{
	restart || { ck "server started" 1; return; }
	local before after
	before=$(psql -tA -c "SELECT md5(string_agg(t.*::text, '|' ORDER BY event_id)) FROM public.events t")
	after=$(psql -tA -c "SELECT md5(string_agg(t.*::text, '|' ORDER BY event_id) || 'x') FROM public.events t")
	if [ "$before" = "$after" ]; then
		ck "sabotage detected: digest comparison reacts to changed content" 1
	else
		ck "sabotage detected: digest comparison reacts to changed content" 0
	fi
}

# ===========================================================================
# S4 -- pg_prewarm, all three modes (plan §7.1 item 4)
#
#   'read'     -> smgrread()      -> memcow_readv()      (synchronous)
#   'buffer'   -> ReadBufferExtended -> smgrstartreadv() -> memcow_startreadv()
#   'prefetch' -> smgrprefetch()  -> memcow_prefetch()
#
# Coverage is by fork and by access method, because those are the axes memcow's
# path builder and its per-fork state actually vary along: main/fsm/vm of a
# heap, a btree, a GIN index (different page layout, metapage, pending list),
# and a TOAST heap plus its index.
#
# The assertion is not just "it returned": each mode is required to report the
# SAME number of blocks, and that number must equal the fork's real size.  A
# prewarm that silently prewarms nothing returns 0 and would otherwise pass.
# ===========================================================================

S4_pg_prewarm()
{
	restart || { ck "server started" 1; return; }
	psql -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm" >/dev/null

	local rels=(
		"public.events:main"
		"public.events:fsm"
		"public.events:vm"
		"public.accounts:main"
		"public.accounts_pkey:main"
		"public.events_account_id_idx:main"
		"public.documents_meta_idx:main"
		"public.staging:main"
	)
	local spec rel fork r b p
	for spec in "${rels[@]}"; do
		rel=${spec%%:*}
		fork=${spec##*:}
		r=$(psql -tA -c "SELECT pg_prewarm('$rel', 'read', '$fork')")
		b=$(psql -tA -c "SELECT pg_prewarm('$rel', 'buffer', '$fork')")
		p=$(psql -tA -c "SELECT pg_prewarm('$rel', 'prefetch', '$fork')")
		ck_match "pg_prewarm read $rel($fork) returned a block count" '^[0-9]+$' "$r"
		if [ "$fork" = main ]; then
			ck "  $rel($fork) is non-empty (read $r blocks)" \
			   "$([ "${r:-0}" -gt 0 ] && echo 0 || echo 1)"
		fi
		ck_eq "  buffer mode agrees with read mode for $rel($fork)"   "$r" "$b"
		ck_eq "  prefetch mode agrees with read mode for $rel($fork)" "$r" "$p"
	done

	# The TOAST relation, named through the catalog rather than hard-coded.
	local toast
	toast=$(psql -tA -c "SELECT reltoastrelid::regclass::text FROM pg_class WHERE oid = 'public.documents'::regclass")
	if [ -n "$toast" ] && [ "$toast" != "-" ]; then
		r=$(psql -tA -c "SELECT pg_prewarm('$toast', 'read', 'main')")
		b=$(psql -tA -c "SELECT pg_prewarm('$toast', 'buffer', 'main')")
		p=$(psql -tA -c "SELECT pg_prewarm('$toast', 'prefetch', 'main')")
		ck "TOAST relation $toast is non-empty (read $r blocks)" \
		   "$([ "${r:-0}" -gt 0 ] && echo 0 || echo 1)"
		ck_eq "  buffer mode agrees for the TOAST relation"   "$r" "$b"
		ck_eq "  prefetch mode agrees for the TOAST relation" "$r" "$p"
		local ti
		ti=$(psql -tA -c "SELECT indexrelid::regclass::text FROM pg_index WHERE indrelid = '$toast'::regclass")
		if [ -n "$ti" ]; then
			r=$(psql -tA -c "SELECT pg_prewarm('$ti', 'read', 'main')")
			ck "TOAST index $ti prewarms ($r blocks)" \
			   "$([ "${r:-0}" -gt 0 ] && echo 0 || echo 1)"
		fi
	else
		ck "public.documents has a TOAST relation" 1
	fi

	# Prewarming must not have disturbed anything.
	local n
	n=$(psql -tA -c "SELECT count(*) FROM public.events")
	ck_eq "content unchanged after prewarming every mode" "4000" "$n"
	ck_no_crash
}

# The sabotage attacks both halves of the case's oracle.  The "non-empty" half
# has to be shown capable of seeing zero -- otherwise a prewarm that silently
# prewarms nothing passes.  The "modes agree" half has to be shown capable of
# seeing disagreement -- otherwise 0 == 0 == 0 counts as agreement.
nc_S4_pg_prewarm()
{
	restart || { ck "server started" 1; return; }
	ensure_pg_prewarm
	local r other
	psql -c "CREATE TABLE nc_empty (a int)" >/dev/null
	r=$(psql -tA -c "SELECT pg_prewarm('nc_empty', 'read', 'main')")
	ck "sabotage detected: an empty relation prewarms 0 blocks, which the case's non-empty check rejects" \
	   "$([ "${r:-x}" = "0" ] && echo 0 || echo 1)"

	r=$(psql -tA -c "SELECT pg_prewarm('public.events', 'read', 'main')")
	other=$(psql -tA -c "SELECT pg_prewarm('public.accounts_pkey', 'buffer', 'main')")
	ck "sabotage detected: the modes-agree comparison distinguishes $r from $other" \
	   "$([ "$r" != "$other" ] && echo 0 || echo 1)"
}

# ===========================================================================
# S5 -- a past-EOF read is a clean, catchable ERROR (findings)
#
# memcow registers no AIO completion callback, so it cannot report a failure
# through the AIO result at all: bufmgr reads a short result as "the tail
# buffers failed", skips PageIsVerified() for them, terminates them not-valid
# and re-issues the identical read -- forever (contract ADDENDUM §D and §I).
# memcow_startreadv() therefore resolves every block BEFORE touching the
# handle and raises ereport(ERROR) if any of them cannot be served.  This case
# is the proof that the two-phase loop is there and works: a read past the end
# of a relation must come back as an error the client can catch, in bounded
# time, with the server still up.
#
# The bounded-time half is the part that would otherwise be untested, so the
# read is run under a hard timeout: a hang here is the specific failure mode
# the two-phase loop exists to prevent, and a hung test that merely takes
# forever is indistinguishable from a passing one.
# ===========================================================================

S5_past_eof()
{
	restart || { ck "server started" 1; return; }
	ensure_test_aio

	local nblk out rc
	nblk=$(fork_nblocks public.events main) || {
		ck "could not learn the fork size from smgrnblocks()" 1; return; }
	ck "the fork is $nblk blocks according to smgrnblocks()" \
	   "$([ "$nblk" -gt 0 ] && echo 0 || echo 1)"

	# smgrstartreadv path (the AIO one, via test_aio's low-level helper).
	#
	# Under a hard timeout on purpose: a hang is the exact failure the
	# two-phase loop exists to prevent (a short synthetic result makes bufmgr
	# re-issue the identical read forever), and a test that merely never
	# finishes looks the same as one that passes.
	out=$(PGHOST=$SOCKDIR PGPORT=$PORT perl -e '
		my $pid = fork();
		if ($pid == 0) { exec @ARGV or exit 127; }
		local $SIG{ALRM} = sub { kill 9, $pid; waitpid $pid, 0; exit 99 };
		alarm 60;
		waitpid $pid, 0;
		exit($? >> 8);
	' "$MC_BINDIR/psql" -X -q -A -t -d "$DB" -v ON_ERROR_STOP=0 \
		-c "SELECT read_rel_block_ll('public.events', $((nblk + 5)), nblocks=>1)" 2>&1)
	rc=$?
	ck "the past-EOF read returned within 60s (rc=$rc, 99 would be a timeout)" \
	   "$([ "$rc" -ne 99 ] && echo 0 || echo 1)"
	ck_match "smgrstartreadv past EOF is a catchable ERROR naming the block" \
		"ERROR:  memcow could not read block $((nblk + 5)) of relation" "$out"

	# The server must still be up and serving.
	out=$(psql -c "SELECT count(*) FROM public.events")
	ck_match "the server survived the error" '^4000$' "$out"

	# ... and a second one, to show it is not a one-shot poison.
	out=$(psql -c "SELECT read_rel_block_ll('public.events', $((nblk + 1)), nblocks=>1)")
	ck_match "a second past-EOF read behaves the same" \
		'ERROR:  memcow could not read block' "$out"
	out=$(psql -c "SELECT count(*) FROM public.events")
	ck_match "and the server is still up" '^4000$' "$out"

	ck_no_crash
}

# The sabotage: read a block that IS in range.  It must not produce the error
# the case matches on; if it does, the case is matching stale text.
nc_S5_past_eof()
{
	restart || { ck "server started" 1; return; }
	ensure_test_aio
	local out
	out=$(psql -c "SELECT read_rel_block_ll('public.events', 3, nblocks=>1)")
	ck_nomatch "sabotage detected: an in-range read produces no past-EOF error" \
		'memcow could not read block' "$out"
}

# ===========================================================================
# S6 -- a fingerprint mismatch is FATAL and names the offending key (findings)
#
# The fingerprint is what stands between "you rebuilt the server and forgot to
# rebuild the seed" and a cluster that reads plausible-looking garbage.  Four
# of the implemented failure modes are exercised here; the checksum one is the
# important one, because a checksum-version mismatch would otherwise present
# as PageIsVerified() failing on EVERY page, i.e. as total data corruption
# rather than as a configuration error.
#
# The doctored seed is a directory of SYMLINKS into the real seed with one
# real file -- the fingerprint -- replacing the link.  Nothing writes to the
# seed, which matters: the seed's immutability is a safety requirement, not
# just a convention (memcow serves pages by memcpy from a PROT_READ mapping,
# so a truncated seed file is a SIGBUS, not a short read).
# ===========================================================================

s6_fake_seed()   # s6_fake_seed DIR SED-EXPR|--delete-key KEY|--no-file
{
	local dir=$1; shift
	rm -rf "$dir"; mkdir -p "$dir" || return 1
	local f
	for f in "$SEED"/* "$SEED"/.[!.]*; do
		[ -e "$f" ] || continue
		case $(basename -- "$f") in
			memcow_seed.fingerprint) ;;
			*) ln -s "$f" "$dir/" ;;
		esac
	done
	case $1 in
		--no-file) return 0 ;;
		--delete-key)
			grep -v "^$2=" "$SEED/memcow_seed.fingerprint" \
				>"$dir/memcow_seed.fingerprint" ;;
		*)  sed "$1" "$SEED/memcow_seed.fingerprint" \
				>"$dir/memcow_seed.fingerprint" ;;
	esac
}

s6_expect_fatal()   # s6_expect_fatal LABEL DIR REGEX
{
	local label=$1 dir=$2 rx=$3
	pg_running && pg_stop fast
	: >"$LOGFILE"
	SEED_OVERRIDE=$dir
	if pg_start; then
		SEED_OVERRIDE=
		ck "$label: startup must FAIL, but the server came up" 1
		pg_stop fast
		return
	fi
	SEED_OVERRIDE=
	local log
	log=$(cat "$LOGFILE" 2>/dev/null)
	ck_match "$label" "$rx" "$log"
}

S6_fingerprint()
{
	local fake="$OUTPUTDIR/fakeseed"

	s6_fake_seed "$fake" 's/^data_page_checksum_version=.*/data_page_checksum_version=0/' &&
	s6_expect_fatal "checksum-version mismatch is FATAL and names the key" \
		"$fake" 'FATAL.*data_page_checksum_version'

	s6_fake_seed "$fake" 's/^catalog_version_no=.*/catalog_version_no=1/' &&
	s6_expect_fatal "catalog_version_no mismatch is FATAL and names the key" \
		"$fake" 'FATAL.*catalog_version_no'

	s6_fake_seed "$fake" 's/^postgres_binary_bytes=.*/postgres_binary_bytes=1/' &&
	s6_expect_fatal "stale binary (postgres_binary_bytes) is FATAL" \
		"$fake" 'FATAL.*postgres_binary_bytes'

	s6_fake_seed "$fake" 's/^block_size=.*/block_size=4096/' &&
	s6_expect_fatal "block_size mismatch is FATAL" \
		"$fake" 'FATAL.*block_size'

	s6_fake_seed "$fake" --delete-key catalog_version_no &&
	s6_expect_fatal "a deleted key is FATAL, not silently skipped" \
		"$fake" 'FATAL.*catalog_version_no'

	s6_fake_seed "$fake" 's/^memcow_seed_fingerprint_version=.*/memcow_seed_fingerprint_version=99/' &&
	s6_expect_fatal "an unsupported fingerprint format version is FATAL" \
		"$fake" 'FATAL.*(fingerprint|version)'

	s6_fake_seed "$fake" --no-file &&
	s6_expect_fatal "a missing fingerprint file is FATAL and names the file" \
		"$fake" 'FATAL.*memcow_seed.fingerprint'

	# The unmodified seed must still start, or the above proves nothing.
	pg_running && pg_stop fast
	: >"$LOGFILE"
	if pg_start; then
		ck "the unmodified seed still starts" 0
		local out
		out=$(psql -c "SELECT count(*) FROM public.events")
		ck_match "and serves pages" '^4000$' "$out"
	else
		ck "the unmodified seed still starts" 1
	fi
	rm -rf "$fake"
}

# The sabotage: a doctored seed whose fingerprint is doctored to the SAME
# value it already has.  Startup must succeed; if the case's harness reports a
# FATAL anyway, it is reading a stale log rather than this start's.
nc_S6_fingerprint()
{
	local fake="$OUTPUTDIR/fakeseed-nc"
	s6_fake_seed "$fake" 's/^block_size=.*/block_size=8192/' || { ck "fake seed built" 1; return; }
	pg_running && pg_stop fast
	: >"$LOGFILE"
	SEED_OVERRIDE=$fake
	if pg_start; then
		SEED_OVERRIDE=
		ck "sabotage detected: an unmodified fingerprint does NOT produce a FATAL" 0
		pg_stop fast
	else
		SEED_OVERRIDE=
		ck "sabotage detected: an unmodified fingerprint does NOT produce a FATAL" 1
		cat "$LOGFILE" | sed 's/^/              /'
	fi
	rm -rf "$fake"
}

# ===========================================================================
# S7 -- the seed is byte-identical after a full write workload (invariant I3)
#
# This is the premise of the whole design, so it is measured rather than
# argued: SHA-256 of every relation file in the seed before and after a
# workload that inserts, updates, deletes, COPYs, creates and drops relations,
# builds indexes, vacuums, checkpoints and shuts down cleanly.  The workload
# has to end in a CLEAN shutdown, because the shutdown checkpoint is itself a
# write of every dirty page including the hint-bit-dirtied pages of read-only
# seed relations -- which is the case that made commit 4 necessary at all.
#
# The companion assertion is that the RUNNING PGDATA holds zero relation
# files.  Together they are the strong form of the claim: every page the
# workload read came from the seed mapping or the overlay, because md had
# nothing on disk to read, and every page it wrote went to the overlay,
# because the seed did not change.
# ===========================================================================

S7_seed_immutable()
{
	restart || { ck "server started" 1; return; }

	local nrel
	nrel=$(runtime_relation_files)
	ck_eq "the runtime PGDATA holds no relation files at all" "0" "$nrel"

	seed_digest "$OUTPUTDIR/seed.before"
	local nseed
	nseed=$(wc -l <"$OUTPUTDIR/seed.before" | tr -d ' ')
	ck "the seed holds relation files to compare ($nseed)" \
	   "$([ "${nseed:-0}" -gt 100 ] && echo 0 || echo 1)"

	local out
	out=$(psql -c "
CREATE TABLE w_heap (id bigint primary key, pad text);
INSERT INTO w_heap SELECT i, repeat('w', 200) FROM generate_series(1, 20000) i;
CREATE INDEX w_heap_pad_idx ON w_heap ((substr(pad, 1, 8)));
UPDATE public.accounts SET status = 'idle' WHERE account_id % 3 = 0;
DELETE FROM public.ledger WHERE entry_no % 7 = 0;
INSERT INTO public.events SELECT 100000 + i, 1 + (i % 5000), 'purchase',
       now(), jsonb_build_object('seq', i) FROM generate_series(1, 5000) i;
COPY public.events TO '$OUTPUTDIR/events.copy';
CREATE TABLE w_copy (LIKE public.events);
COPY w_copy FROM '$OUTPUTDIR/events.copy';
CREATE TEMP TABLE w_temp AS SELECT * FROM public.ledger;
UPDATE w_temp SET amount = amount + 1;
TRUNCATE w_copy;
DROP TABLE w_heap;
" \
		-c "VACUUM (ANALYZE) public.accounts" \
		-c "VACUUM public.events" \
		-c "CHECKPOINT")
	ck_nomatch "the write workload raised no error" '^ERROR' "$out"

	# The clean shutdown is part of the workload, not cleanup: the shutdown
	# checkpoint writes every remaining dirty page through memcow_writev.
	if pg_stop fast; then
		ck "a clean 'fast' shutdown succeeds after the workload" 0
	else
		ck "a clean 'fast' shutdown succeeds after the workload" 1
	fi

	seed_digest "$OUTPUTDIR/seed.after"
	if diff -u "$OUTPUTDIR/seed.before" "$OUTPUTDIR/seed.after" \
			>"$OUTPUTDIR/seed.diff" 2>&1; then
		ck "the seed is byte-identical across all $nseed relation files" 0
	else
		ck "the seed is byte-identical across all $nseed relation files" 1
		head -40 "$OUTPUTDIR/seed.diff" | sed 's/^/              /'
	fi

	nrel=$(runtime_relation_files)
	ck_eq "and the runtime PGDATA still holds no relation files" "0" "$nrel"

	ck_no_crash
	pg_start
}

# The sabotage: touch one byte of a COPY of the seed and show the digest
# instrument reacts.  Nothing writes to the real seed -- that is a safety
# requirement (a truncated or rewritten seed file is a SIGBUS in memcow, not a
# short read), so the control operates on a copy.
nc_S7_seed_immutable()
{
	local tmp="$OUTPUTDIR/seedcopy"
	rm -rf "$tmp"; mkdir -p "$tmp/base" || { ck "scratch dir" 1; return; }
	local victim
	victim=$(cd "$SEED" && find base -type f | sort | head -1)
	[ -n "$victim" ] || { ck "found a seed file to copy" 1; return; }
	mkdir -p "$tmp/$(dirname -- "$victim")"
	cp "$SEED/$victim" "$tmp/$victim"
	local a b
	a=$(shasum -a 256 "$tmp/$victim" | awk '{print $1}')
	printf 'x' | dd of="$tmp/$victim" bs=1 seek=100 conv=notrunc 2>/dev/null
	b=$(shasum -a 256 "$tmp/$victim" | awk '{print $1}')
	if [ "$a" = "$b" ]; then
		ck "sabotage detected: the seed digest reacts to a single changed byte" 1
	else
		ck "sabotage detected: the seed digest reacts to a single changed byte" 0
	fi
	rm -rf "$tmp"
}

# ===========================================================================
# S8 -- a crashed cluster refuses to restart under memcow (findings)
#
# Recovery is the one thing memcow cannot survive.  reinit.c's
# ResetUnloggedRelationsInDbspaceDir() walks base/<db>/ with raw ReadDir(),
# bare unlink() and copy_file() -- no smgr involvement at all -- and WAL replay
# wants to write relation pages that live in a read-only tree outside the
# running PGDATA.  Both are recovery-gated, which is exactly why the seed is
# required to be cleanly shut down, and why memcow carries an Assert(!InRecovery)
# at the point where the seed is first opened.
#
# So: crash the cluster, try to start it, and require that it does NOT come up.
# restart_after_crash=off (set by assemble_ramdir.sh) is what keeps the failure
# from becoming a restart loop.  The RAM dir is then re-assembled, because a
# crashed memcow PGDATA is not a thing that can be repaired.
# ===========================================================================

S8_crash_refuses()
{
	restart || { ck "server started" 1; return; }

	# The crash has to leave REAL work for redo, or the test proves nothing:
	# with an empty WAL tail the startup process finishes recovery without
	# ever resolving a relation fork, and the cluster comes up.  So: pin the
	# redo point with a checkpoint, then write a lot -- including an update to
	# a relation that lives in the SEED, whose replay must read a seed page --
	# and crash before the next checkpoint.
	psql -c "CHECKPOINT" >/dev/null
	psql -c "CREATE TABLE s8_marker AS SELECT i, repeat('m', 200) AS pad
	           FROM generate_series(1, 20000) i" \
	     -c "UPDATE public.accounts SET status = 'crashtest'
	          WHERE account_id % 5 = 0" >/dev/null

	pg_stop immediate
	ck "the cluster was stopped with -m immediate (i.e. it needs recovery)" $?

	: >"$LOGFILE"
	if pg_start; then
		ck "a crashed memcow cluster must NOT start, but it did" 1
		pg_stop immediate
	else
		ck "a crashed memcow cluster refuses to start" 0
		local log
		log=$(cat "$LOGFILE" 2>/dev/null)
		ck_match "the log says recovery was attempted" \
			'database system was not properly shut down|automatic recovery in progress' "$log"
		ck_match "and memcow's own tripwire is what stopped it" \
			'failed Assert\("!InRecovery"\)|InRecovery' "$log"
		ck_match "the postmaster gave up rather than looping" \
			'shutting down due to startup process failure|database system is shut down' "$log"
	fi

	if reassemble; then
		ck "the RAM dir re-assembles after the crash" 0
	else
		ck "the RAM dir re-assembles after the crash" 1
	fi
	: >"$LOGFILE"
	pg_start
}

# The sabotage: stop cleanly instead of crashing.  The cluster must then start;
# if the case's "refuses to start" assertion still fires, it is not measuring
# the crash.
nc_S8_crash_refuses()
{
	restart || { ck "server started" 1; return; }
	pg_stop fast
	: >"$LOGFILE"
	if pg_start; then
		ck "sabotage detected: a CLEANLY stopped memcow cluster does start" 0
	else
		ck "sabotage detected: a CLEANLY stopped memcow cluster does start" 1
		cat "$LOGFILE" | sed 's/^/              /'
	fi
}

# ===========================================================================
# S9 -- the documented divergences, asserted rather than discovered (findings)
#
# pg_relation_size() and its relatives stat() the path relpathbackend() builds,
# in the RUNNING PGDATA, without going through smgr (dbsize.c:326-348).  Under
# memcow the running PGDATA has no relation files, so they return 0 while the
# data reads back perfectly.  That is a real behavioural difference and it is
# NOT currently fixed, so this case pins the CURRENT behaviour: if someone
# later makes pg_relation_size() smgr-aware, this case fails and whoever did it
# gets told to delete the corresponding rule from harness/divergences.txt --
# which is the only thing keeping the zero-diff gate honest.
#
# It is deliberately a test and not a comment, because the alternative -- an
# unexplained "t" turning into "f" in the middle of the vacuum test -- is how
# real regressions get waved through.
# ===========================================================================

S9_documented_divergences()
{
	restart || { ck "server started" 1; return; }

	local out
	out=$(psql -c "
SELECT 'relsize', pg_relation_size('public.events');
SELECT 'rows', count(*) FROM public.events;
SELECT 'totalsize', pg_total_relation_size('public.documents');
SELECT 'toastrows', count(*) FROM public.documents;
SELECT 'idxsize', pg_indexes_size('public.accounts');
")
	ck_match "KNOWN DIVERGENCE: pg_relation_size() reports 0 under memcow" \
		'^relsize\|0$' "$out"
	ck_match "  ... while the rows read back correctly" '^rows\|4000$' "$out"
	ck_match "KNOWN DIVERGENCE: pg_total_relation_size() reports 0" \
		'^totalsize\|0$' "$out"
	ck_match "  ... while the TOASTed rows read back correctly" '^toastrows\|250$' "$out"
	ck_match "KNOWN DIVERGENCE: pg_indexes_size() reports 0" '^idxsize\|0$' "$out"

	# The smgr-level size IS correct; only the stat()-based one is not.  That
	# is what makes this a dbsize.c divergence rather than a memcow bug.
	psql -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm" >/dev/null
	local nblk
	nblk=$(psql -tA -c "SELECT pg_prewarm('public.events', 'prefetch', 'main')")
	ck "  ... and smgrnblocks() is right ($nblk blocks), so the divergence is dbsize.c's" \
	   "$([ "${nblk:-0}" -gt 0 ] && echo 0 || echo 1)"

	# pg_database_size: same root cause, and cheap to reach.
	out=$(psql -c "SELECT 'dbsize', pg_database_size(current_database()) < 40 * 1024 * 1024")
	ck_match "KNOWN DIVERGENCE: pg_database_size() sees only the RAM PGDATA" \
		'^dbsize\|t$' "$out"

	# --- the divergence that is a HAZARD rather than a reporting quirk ----
	#
	# DROP TABLESPACE decides whether a tablespace still holds anything by
	# scanning its directory: destroy_tablespace_directories() calls
	# directory_is_empty() on each subdirectory (tablespace.c:754-769) and the
	# false return is what raises "tablespace ... is not empty"
	# (tablespace.c:527-532).  Under memcow no relation file is ever written
	# there, so the directory is empty however much the tablespace holds, and
	# the DROP SUCCEEDS -- removing the catalog row while the relations are
	# still live in the overlay.  Stock md refuses.
	#
	# Pinned here for the same reason as the pg_relation_size cases: this is
	# the difference between a named, cited hazard and twenty mystery lines in
	# the regress `tablespace` diff.  It goes last in this case because it
	# leaves the database referring to a tablespace that no longer exists;
	# the next case restarts, which reverts the catalog with the overlay.
	local tsdir="$RAM_MOUNT/slice_s9_tblspc"
	rm -rf "$tsdir"; mkdir -p "$tsdir"
	out=$(psql -c "CREATE TABLESPACE slice_s9_ts LOCATION '$tsdir'" \
		-c "CREATE TABLE s9_in_ts (a int) TABLESPACE slice_s9_ts" \
		-c "INSERT INTO s9_in_ts SELECT generate_series(1, 5000)" \
		-c "CHECKPOINT" \
		-c "SELECT 'rows', count(*) FROM s9_in_ts" \
		-c "DROP TABLESPACE slice_s9_ts" \
		-c "SELECT 'gone', count(*) FROM pg_tablespace WHERE spcname = 'slice_s9_ts'")
	ck_match "  the tablespace really did hold a populated relation" '^rows\|5000$' "$out"
	ck_nomatch "KNOWN DIVERGENCE (HAZARD): DROP TABLESPACE does NOT report \"is not empty\"" \
		'is not empty' "$out"
	ck_match "  ... it succeeds, and the catalog row is gone while the data was live" \
		'^gone\|0$' "$out"

	ck_no_crash
}

# The sabotage: assert the OPPOSITE (that pg_relation_size is non-zero).  If
# that also passes, the case is not reading the server's answer.
nc_S9_documented_divergences()
{
	restart || { ck "server started" 1; return; }
	local out
	out=$(psql -c "SELECT 'relsize', pg_relation_size('public.events')")
	ck_nomatch "sabotage detected: pg_relation_size is not non-zero" \
		'^relsize\|[1-9]' "$out"

	# And the tablespace half: an EMPTY tablespace drops cleanly under both
	# engines, so if that also produced "is not empty" the case's check would
	# be matching something other than the emptiness decision.
	local tsdir="$RAM_MOUNT/slice_s9nc_tblspc"
	rm -rf "$tsdir"; mkdir -p "$tsdir"
	out=$(psql -c "CREATE TABLESPACE slice_s9nc_ts LOCATION '$tsdir'" \
		-c "DROP TABLESPACE slice_s9nc_ts" \
		-c "SELECT 'gone', count(*) FROM pg_tablespace WHERE spcname = 'slice_s9nc_ts'")
	ck_match "sabotage detected: an EMPTY tablespace drops cleanly (so the check is about emptiness)" \
		'^gone\|0$' "$out"
	ck_nomatch "  and reports nothing about being non-empty" 'is not empty' "$out"
}

# ===========================================================================
# S10 -- smgr_truncate runs inside a critical section
#
# ***THIS CASE CURRENTLY FAILS.  IT IS A REAL ENGINE DEFECT, NOT A TEST BUG.***
#
# RelationTruncate() calls smgrtruncate() inside START_CRIT_SECTION()
# (src/backend/catalog/storage.c:386-424; the redo path does the same at
# :1077-1079).  memcow_truncate() frees the overlay pages it drops, and both
# dsa_free() and dshash_delete_entry() may have to call dsa_get_address() on a
# DSA segment this backend has not mapped yet -- which calls dsm_attach(),
# which palloc()s.  Allocating inside a critical section trips
# Assert(CritSectionCount == 0 || allowInCritSection) (mcxt.c:1240) and kills
# the backend; with restart_after_crash=off it takes the cluster with it.  On a
# non-assert build the same code would instead risk an ereport(ERROR) out of
# dsm_attach() inside a critical section, i.e. a PANIC.
#
# Reproduction, two sessions, no harness required:
#     session 1:  CREATE TABLE t AS SELECT i, repeat('x',400)
#                   FROM generate_series(1,200000) i;
#                 DELETE FROM t;
#     session 2:  VACUUM (TRUNCATE on) t;
#
# Two backends are needed because the segments have to be unmapped in the
# TRUNCATING backend; a backend that allocated the pages itself already has
# them mapped, which is why this does not fire every time and why it surfaced
# as an intermittent crash in the differential run rather than as a clean
# failure.  The other reaching path is ON COMMIT DELETE ROWS temp tables via
# PreCommit_on_commit_actions() -> heap_truncate(), which is what actually
# crashed the `truncate` regression test.
#
# The constraint this implies is permanent and belongs beside the
# memcow_close() infallibility rules in the contract ADDENDUM:
# ***memcow_truncate() must be allocation-free.***
# ===========================================================================

S10_truncate_crit_section()
{
	restart || { ck "server started" 1; return; }

	local out
	out=$(psql -c "
CREATE TABLE s10_trunc AS
  SELECT i, repeat('x', 400) AS pad FROM generate_series(1, 200000) i;
DELETE FROM s10_trunc;
")
	ck_nomatch "session 1 built a large multi-segment overlay" '^ERROR' "$out"

	# A FRESH backend: it has not mapped the DSA segments session 1 allocated.
	out=$(psql -c "VACUUM (TRUNCATE on) s10_trunc")
	ck_nomatch "VACUUM truncate from a second backend does not lose the connection" \
		'server closed the connection|connection to server was lost' "$out"
	ck_nomatch "... and does not raise" '^ERROR' "$out"

	if pg_running; then
		ck "the cluster survived the truncate" 0
	else
		ck "the cluster survived the truncate" 1
	fi

	ck_no_crash
	pg_running || { : >"$LOGFILE"; pg_start; }
}

# The sabotage: do the same work in ONE backend, where the segments are already
# mapped and dsa_free() therefore does not have to attach.  That must NOT
# crash; if it does, the case is not isolating the cross-backend condition.
nc_S10_truncate_crit_section()
{
	restart || { ck "server started" 1; return; }
	local out
	out=$(psql -c "CREATE TABLE s10_nc AS SELECT i, repeat('x', 400) AS pad
	                 FROM generate_series(1, 200000) i;
	               DELETE FROM s10_nc;" \
		-c "VACUUM (TRUNCATE on) s10_nc" \
		-c "SELECT 'alive', count(*) FROM s10_nc")
	ck_match "sabotage detected: same work in a single backend does not crash" \
		'^alive\|0$' "$out"
	pg_running || { : >"$LOGFILE"; pg_start; }
}

# ===========================================================================
# driver
# ===========================================================================

# Stop CLEANLY on the way out.  An immediate stop would leave a PGDATA that
# needs recovery, which under memcow is a PGDATA that cannot be started at all
# -- so a tidy-looking cleanup would silently cost the next run its cluster.
cleanup()
{
	if pg_running; then
		pg_stop fast || pg_stop immediate
	fi
	rm -rf "$SOCKDIR"
}
trap cleanup EXIT INT TERM

: >"$LOGFILE"
: >"$LOGFILE.pg_ctl"

mc_banner "memcow slice tests (plan §7.1)" \
	"seed:     $SEED" \
	"pgdata:   $PGDATA" \
	"bindir:   $MC_BINDIR" \
	"database: $DB" \
	"cases:    ${CASES[*]}" \
	"mode:     $([ $NEGATIVE -eq 1 ] && echo 'NEGATIVE CONTROL (each case must FAIL)' || echo normal)"

if [ "${MC_BUILD_CASSERT:-no}" != yes ]; then
	mc_warn "cassert=false: S8 and S10 rely on assertions and are much weaker here"
fi

PASSED=0
FAILED=0
FAILED_NAMES=

for c in "${CASES[@]}"; do

	CASE_FAIL=0
	if [ $NEGATIVE -eq 1 ]; then
		printf '\n--- %s [negative control] ---\n' "$c"
		"nc_$c"
		# In negative-control mode the sabotage function itself asserts that
		# the instrument reacted, so CASE_FAIL still means "broken".
	else
		printf '\n--- %s ---\n' "$c"
		"$c"
	fi
	if [ $CASE_FAIL -eq 0 ]; then
		printf '  PASS  %s\n' "$c"
		PASSED=$((PASSED + 1))
	else
		printf '  FAIL  %s\n' "$c"
		FAILED=$((FAILED + 1))
		FAILED_NAMES="$FAILED_NAMES $c"
		[ $STOP_ON_FAIL -eq 1 ] && break
	fi
done

RC=0
[ $FAILED -eq 0 ] || RC=1

{
	echo "passed=$PASSED"
	echo "failed=$FAILED"
	echo "failed_cases=${FAILED_NAMES# }"
	echo "negative_control=$NEGATIVE"
	echo "rc=$RC"
} >"$OUTPUTDIR/slice_status.txt"

if [ $RC -eq 0 ]; then
	mc_banner "SLICE TESTS PASS -- $PASSED case(s), 0 failed"
else
	mc_banner "SLICE TESTS FAIL -- $PASSED passed, $FAILED failed:${FAILED_NAMES}" \
		"logs: $OUTPUTDIR"
fi
exit $RC
