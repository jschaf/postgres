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
# seed/assemble_ramdir.sh, and a postmaster started with memcow.enabled=on on
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
#   S10 truncate runs in a critical section        findings: fixed; the acceptance test
#
#   Phase 2 (plan §4 / §7.2), written BEFORE the reset existed, per the
#   2026-09-01 brief -- these four are the falsification slice for
#   memcow_lane_reset and are run by run_gate.sh --phase 2:
#
#   S11 reset reverts a written page                 plan §4, I1
#   S12 reset reclaims blocks_high pages             ADDENDUM §P(c), §7.2 "DSM flat"
#   S13 reset invalidates the cached record pointer  ADDENDUM §P(d)
#   S14 reset while a truncate is in flight          plan §4.3 fence, Appendix B(i)
#
#   Phase 3 (plan §3, §5 I2, §7.3, CONCERN 4a), run by run_gate.sh --phase 3:
#
#   S15 the authentication-time fence               plan §5 I2 fence 2 of 3
#   S16 the per-lane arena limit, a named error     CONCERN 4a
#   R1  §7.3 (a): connection parked after auth, reset runs past it
#   R2  §7.3 (b): SIGSTOPped straggler; reset fails closed, never publishes
#   R3  §7.3 (c): cancel with an IO in flight, release + reset at once
#   R4  §7.3 (d): checkpointer parked in FlushBuffer across a reset
#   R5  §7.3 (e): nailed-catalog sinval to parked pool backends mid-reset
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
#     --phase 1|2|3       run only that phase's cases (S1-S10, S11-S14, or
#                         S15-S16 + R1-R5)
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
# shellcheck source=../harness/sessions.sh
. "$HARNESS/sessions.sh"

PHASE1_CASES="S1_mixed_vectors S2_overlay_corruption S3_set_tablespace \
S4_pg_prewarm S5_past_eof S6_fingerprint S7_seed_immutable S8_crash_refuses \
S9_documented_divergences S10_truncate_crit_section"
PHASE2_CASES="S11_reset_reverts S12_reset_reclaims S13_reset_invalidates_pin \
S14_reset_vs_truncate"
PHASE3_CASES="S15_auth_fence S16_arena_limit R1_auth_window R2_stopped_straggler \
R3_cancel_inflight_io R4_checkpoint_discard R5_sinval_nailed"
ALL_CASES="$PHASE1_CASES $PHASE2_CASES $PHASE3_CASES"

SEED=
PGDATA=
RAM_MOUNT=
BUILD_DIR=
OUTPUTDIR=
DB=memcow_lane_00
CASES=()
PHASE=
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
		--phase)       PHASE=$2; shift 2 ;;
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

if [ ${#CASES[@]} -eq 0 ]; then
	case $PHASE in
		'')  read -r -a CASES <<<"$ALL_CASES" ;;
		1)   read -r -a CASES <<<"$PHASE1_CASES" ;;
		2)   read -r -a CASES <<<"$PHASE2_CASES" ;;
		3)   read -r -a CASES <<<"$PHASE3_CASES" ;;
		*)   mc_die "unknown --phase $PHASE (expected 1, 2 or 3)" ;;
	esac
fi

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
# memcow.enabled and memcow.seed_directory go on the postmaster COMMAND LINE.
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
	opts="-c shared_preload_libraries=memcow -c memcow.enabled=on"
	opts="$opts -c memcow.seed_directory=$seed"
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

	# --- the divergence that WAS a hazard, and is now a refusal ------------
	#
	# DROP TABLESPACE decides whether a tablespace still holds anything by
	# scanning its directory: destroy_tablespace_directories() calls
	# directory_is_empty() on each subdirectory (tablespace.c) and the false
	# return is what raises "tablespace ... is not empty".  Under memcow no
	# relation file is ever written there, so the scan always saw an empty
	# directory and the DROP SUCCEEDED -- removing the catalog row while the
	# relations were still live in the overlay.  DropTableSpace() now asks
	# memcow_tablespace_in_use() first, which walks every database's overlay
	# (and the seed's pg_tblspc/<oid>/) and refuses exactly where md does.
	#
	# Pinned here for the same reason as the pg_relation_size cases: this is
	# a named, cited core path that reaches relation storage without smgr,
	# and the fix lives outside memcow.c.  Three things are checked: the
	# refusal, that the catalog row survives it, and that the data is still
	# readable afterwards.  Then the relation is dropped and the tablespace is
	# dropped for real, which must succeed -- the check is about emptiness,
	# not a blanket refusal (nc_S9 covers the empty case as well).
	local tsdir="$RAM_MOUNT/slice_s9_tblspc"
	rm -rf "$tsdir"; mkdir -p "$tsdir"
	out=$(psql -c "CREATE TABLESPACE slice_s9_ts LOCATION '$tsdir'" \
		-c "CREATE TABLE s9_in_ts (a int) TABLESPACE slice_s9_ts" \
		-c "INSERT INTO s9_in_ts SELECT generate_series(1, 5000)" \
		-c "CHECKPOINT" \
		-c "SELECT 'rows', count(*) FROM s9_in_ts" \
		-c "DROP TABLESPACE slice_s9_ts" \
		-c "SELECT 'gone', count(*) FROM pg_tablespace WHERE spcname = 'slice_s9_ts'" \
		-c "SELECT 'still', count(*) FROM s9_in_ts")
	ck_match "  the tablespace really did hold a populated relation" '^rows\|5000$' "$out"
	ck_match "FIXED HAZARD: DROP TABLESPACE on a populated tablespace reports \"is not empty\"" \
		'is not empty' "$out"
	ck_match "  ... and the catalog row survives" '^gone\|1$' "$out"
	ck_match "  ... and the data is still readable" '^still\|5000$' "$out"
	out=$(psql -c "DROP TABLE s9_in_ts" \
		-c "DROP TABLESPACE slice_s9_ts" \
		-c "SELECT 'gone', count(*) FROM pg_tablespace WHERE spcname = 'slice_s9_ts'")
	ck_nomatch "  ... and once the relation is dropped the tablespace is droppable" \
		'is not empty' "$out"
	ck_match "  ... and then it is really gone" '^gone\|0$' "$out"

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
# This case was written against the unfixed engine and FAILED there; it is a
# real engine defect, since fixed (memcow_truncate() is now a pure whiteout
# that re-locks a record pointer cached by memcow_nblocks() and never walks
# the shared table; see the comments on both), and this case is the
# acceptance criterion for that fix staying fixed.
#
# RelationTruncate() calls smgrtruncate() inside START_CRIT_SECTION()
# (src/backend/catalog/storage.c:386-424; the redo path does the same at
# :1077-1079).  memcow_truncate() USED TO free the overlay pages it drops, and
# both dsa_free() and dshash_delete_entry() may have to call dsa_get_address()
# on a DSA segment this backend has not mapped yet -- which calls dsm_attach(),
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
# Phase 2 fixtures: the control connection, lane bookkeeping, and persistent
# sessions.
#
# memcow_lane_reset(D) runs on a CONTROL connection that is never connected
# to D (plan §4).  The seed builds a control database for exactly this
# (build_seed.sh, $CONTROL_DB, cloned from template0); the memcow
# extension is created there at test time -- the control database's overlay
# is permanent (plan §6), so that survives every reset, but not a restart,
# hence ensure_memcow per case.  The lane-side half of the extension
# (memcow_backend_reset) lives in the SEED's lane databases, because anything
# created in a lane at test time is overlay content that the reset discards.
#
# Two cases need a backend that stays connected ACROSS a reset (that is what
# a retained pool backend is), so there is a small persistent-session helper
# below: a psql reading a FIFO, driven with sess_query.  bash 3.2 compatible
# on purpose (macOS /bin/bash), hence the explicit fd numbers.
# ===========================================================================

CONTROL_DB=${MEMCOW_CONTROL_DB:-memcow_control}

psql_ctl()
{
	PGHOST=$SOCKDIR PGPORT=$PORT "$MC_BINDIR/psql" -X -q -A -t \
		-d "$CONTROL_DB" -v ON_ERROR_STOP=0 "$@" 2>&1
}

ensure_memcow()
{
	psql_ctl -c "CREATE EXTENSION IF NOT EXISTS memcow" >/dev/null 2>&1
}

ensure_injection_points()	# ensure_injection_points [DB]
{
	PGHOST=$SOCKDIR PGPORT=$PORT "$MC_BINDIR/psql" -X -q -A -t -d "${1:-$DB}" \
		-c "CREATE EXTENSION IF NOT EXISTS injection_points" >/dev/null 2>&1
}

lane_oid()
{
	psql_ctl -c "SELECT oid FROM pg_database WHERE datname = '$DB'"
}

# lane_status OID FIELD --- one column of memcow_lane_status(OID)
lane_status()
{
	psql_ctl -c "SELECT $2 FROM memcow_lane_status($1)"
}

# dsm_files --- how many dynamic shared memory segments exist RIGHT NOW.
# Only meaningful under dynamic_shared_memory_type=mmap, where every segment
# is a file in pg_dynshmem/; that is the one implementation whose segments
# can be counted from outside the server without trusting memcow's own
# bookkeeping, which is the point of counting them.
dsm_files()
{
	find "$PGDATA/pg_dynshmem" -name 'mmap.*' 2>/dev/null | wc -l | tr -d ' '
}

# --- persistent sessions: sess_open / sess_query / ... are in
# --- harness/sessions.sh, shared with reset_soak.sh
# wake_until_done NAME SEQ POINT [TIMEOUT] --- wake POINT from the control
# connection until session NAME's command SEQ has completed; rc 1 on timeout.
# Repeated on purpose: a backend can reach the same point more than once in
# one command, and a wakeup that finds nobody waiting is an ERROR that is
# simply retried.
wake_until_done()
{
	local name=$1 seq=$2 point=$3 timeout=${4:-30} i=0
	while ! sess_wait "$name" "$seq" 1; do
		psql_ctl -c "SELECT injection_points_wakeup('$point')" >/dev/null 2>&1
		i=$((i + 1))
		[ $i -lt $timeout ] || return 1
	done
}

# wait_for_wait_event PID EVENT [TIMEOUT] --- poll pg_stat_activity from the
# control connection until PID reports wait_event EVENT; rc 1 on timeout.
wait_for_wait_event()
{
	local pid=$1 ev=$2 timeout=${3:-20} i=0 got
	while :; do
		got=$(psql_ctl -c "SELECT wait_event FROM pg_stat_activity WHERE pid = $pid")
		[ "$got" = "$ev" ] && return 0
		i=$((i + 1))
		[ $i -lt $((timeout * 10)) ] || return 1
		sleep 0.1
	done
}

# ===========================================================================
# S11 -- reset reverts a written page (plan §4, invariant I1)
#
# The whole reason the engine exists.  Epoch 0 does the three things a test
# does to a lane -- update a seed row, create a relation, drop a seed relation
# (an UNLOGGED one, so the init fork's whiteout is reverted too) -- and
# checkpoints, so every page is in the overlay rather than merely dirty in
# shared buffers.  Then memcow_lane_reset(D).  Afterwards a FRESH backend must
# see exactly the seed, and a RETAINED backend -- one that was connected
# through the reset, registered and idle, the shape of a pool connection --
# must see exactly the seed after memcow_backend_reset(), and nothing before
# it is allowed to have served it a stale page.
#
# The admission fence is asserted on the way: while the lane is RESETTING a
# new connection is refused before its first command, and once the lane is
# opened ARMED, a connection has to present the lane's nonce.
# ===========================================================================

S11_reset_reverts()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	local dboid out epoch nonce pid digest_seed digest_after
	dboid=$(lane_oid)
	ck_match "lane database oid resolved" '^[0-9]+$' "$dboid"

	# The seed's own digest, taken from a freshly restarted server before
	# anything has been written: the value every epoch has to come back to.
	digest_seed=$(psql -c "SELECT md5(string_agg(relname || ':' || nrows || ':' || digest, ',' ORDER BY relname))
  FROM public.memcow_seed_digest")
	ck_match "seed digest taken before the workload" '^[0-9a-f]{32}$' "$digest_seed"

	# --- epoch 0 workload ---------------------------------------------
	out=$(psql -c "
UPDATE public.events SET kind = 'epoch-zero' WHERE event_id = 1;
CREATE TABLE s11_new AS SELECT 42 AS x;
DROP TABLE public.staging CASCADE;  -- takes memcow_seed_digest with it
CHECKPOINT;
SELECT 'kind', kind FROM public.events WHERE event_id = 1;
SELECT 'new', count(*) FROM pg_class WHERE relname = 's11_new';
SELECT 'staging', count(*) FROM pg_class WHERE relname = 'staging';
")
	ck_match "epoch 0: the updated row is visible"       '^kind\|epoch-zero$' "$out"
	ck_match "epoch 0: the created relation exists"      '^new\|1$'           "$out"
	ck_match "epoch 0: the dropped seed relation is gone" '^staging\|0$'      "$out"

	# --- a retained backend, registered and idle ---------------------
	sess_open A 7
	pid=$(sess_query A 7 "SELECT pg_backend_pid()")
	ck_match "retained session A connected" '^[0-9]+$' "$pid"
	out=$(sess_query A 7 "SELECT 'kind', kind FROM public.events WHERE event_id = 1")
	ck_match "session A saw the epoch-0 page (so its caches are warm)" '^kind\|epoch-zero$' "$out"
	out=$(psql_ctl -c "SELECT memcow_lane_register($dboid, $pid)")
	ck_nomatch "session A registered with the lane" 'ERROR' "$out"

	# --- the reset ----------------------------------------------------
	epoch=$(psql_ctl -c "SELECT memcow_lane_reset($dboid)")
	ck_eq "memcow_lane_reset(D) returned epoch 1" 1 "$epoch"

	# Checked BEFORE anything reconnects: a new backend rewrites the init
	# file as part of its own startup, which would mask a reset that failed
	# to remove it.
	if [ -e "$PGDATA/base/$dboid/pg_internal.init" ]; then
		ck "reset removed base/<D>/pg_internal.init" 1
	else
		ck "reset removed base/<D>/pg_internal.init" 0
	fi
	if cmp -s "$PGDATA/base/$dboid/pg_filenode.map" "$SEED/base/$dboid/pg_filenode.map"; then
		ck "base/<D>/pg_filenode.map is byte-identical to the seed's" 0
	else
		ck "base/<D>/pg_filenode.map is byte-identical to the seed's" 1
	fi
	ck_eq "lane state after reset is RESETTING (admission closed)" RESETTING \
		"$(lane_status "$dboid" state)"

	out=$(psql -c "SELECT 1")
	ck_match "a new connection is refused while the lane is RESETTING" \
		'FATAL:.*lane.*not open' "$out"

	# --- open, unarmed: a fresh backend sees the seed ------------------
	out=$(psql_ctl -c "SELECT memcow_lane_open($dboid, false)")
	ck_eq "memcow_lane_open(D, arm => false) returns nonce 0" 0 "$out"
	ck_eq "lane state is OPEN" OPEN "$(lane_status "$dboid" state)"

	out=$(psql -c "
SELECT 'kind', kind FROM public.events WHERE event_id = 1;
SELECT 'new', count(*) FROM pg_class WHERE relname = 's11_new';
SELECT 'staging', count(*) FROM public.staging;
SELECT 'events', count(*) FROM public.events;
SELECT 'digest', md5(string_agg(relname || ':' || nrows || ':' || digest, ',' ORDER BY relname))
  FROM public.memcow_seed_digest;
")
	ck_match "fresh backend: the seed row is back"                 '^kind\|logout$'  "$out"
	ck_match "fresh backend: the epoch-0 relation is gone"         '^new\|0$'        "$out"
	ck_match "fresh backend: the dropped seed relation is back"    '^staging\|1000$' "$out"
	ck_match "fresh backend: events has the seed's 4000 rows"      '^events\|4000$'  "$out"
	digest_after=$(printf '%s' "$out" | sed -n 's/^digest|//p')
	ck_eq "fresh backend: seed digest equals the seed's own" "$digest_seed" "$digest_after"

	# --- the retained backend adopts -----------------------------------
	out=$(sess_query A 7 "SELECT public.memcow_backend_reset()")
	ck_eq "session A: memcow_backend_reset() adopted epoch 1" 1 "$out"
	out=$(sess_query A 7 "
SELECT 'kind', kind FROM public.events WHERE event_id = 1;
SELECT 'new', count(*) FROM pg_class WHERE relname = 's11_new';
SELECT 'staging', count(*) FROM public.staging;
")
	ck_match "session A: the seed row is back"              '^kind\|logout$'  "$out"
	ck_match "session A: the epoch-0 relation is gone"      '^new\|0$'        "$out"
	ck_match "session A: the dropped seed relation is back" '^staging\|1000$' "$out"
	ck_nomatch "session A: no error while adopting" 'ERROR|FATAL' "$out"

	# --- armed open: the nonce fence -----------------------------------
	nonce=$(psql_ctl -c "SELECT memcow_lane_open($dboid, true)")
	ck_match "memcow_lane_open(D, arm => true) returns a nonce" '^[1-9][0-9]*$' "$nonce"
	out=$(psql -c "SELECT 1")
	ck_match "armed lane: a connection without the nonce is refused" 'FATAL:.*nonce' "$out"
	out=$(PGOPTIONS="-c memcow.lane_nonce=$((nonce + 1))" psql -c "SELECT 1")
	ck_match "armed lane: a connection with a stale nonce is refused" 'FATAL:.*nonce' "$out"
	out=$(PGOPTIONS="-c memcow.lane_nonce=$nonce" psql -c "SELECT 1")
	ck_match "armed lane: a connection with the current nonce is admitted" '^1$' "$out"
	# The retained backend was admitted at epoch 0 and stays: the fence is
	# for NEW connections; retained ones are the registry's business.
	out=$(sess_query A 7 "SELECT 1")
	ck_match "retained session A is unaffected by arming" '^1$' "$out"

	sess_close A 7
	ck_no_crash
}

# The sabotage: everything the same, but no memcow_lane_reset(D) in the
# middle (the lane is merely closed and reopened).  The case's central
# assertion -- the epoch-0 write is gone -- must then fail.
nc_S11_reset_reverts()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	local dboid out
	dboid=$(lane_oid)
	psql -c "UPDATE public.events SET kind = 'epoch-zero' WHERE event_id = 1; CHECKPOINT;" >/dev/null
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(psql -c "SELECT 'kind', kind FROM public.events WHERE event_id = 1")
	ck_match "sabotage detected: without a reset the epoch-0 write persists" \
		'^kind\|epoch-zero$' "$out"
	ck_no_crash
}

# ===========================================================================
# S12 -- reset reclaims blocks_high pages (ADDENDUM §P(c); §7.2 "DSM flat")
#
# memcow_truncate() cannot free (it runs in a critical section), so a fork
# keeps its overlay pages up to its peak size until unlink or reset.  A
# 200,000-row table filled, emptied and VACUUM-truncated to zero blocks is
# therefore ~13 MB of arena that nothing but the reset can reclaim.  The
# instrument is NOT memcow's own accounting: under
# dynamic_shared_memory_type=mmap every DSM segment is a file in
# pg_dynshmem/, so the segment count is observable from outside the server.
# It must go up when the arena grows and come back to exactly the post-reset
# baseline after the next reset -- the old arena's segments, all of them,
# gone.
# ===========================================================================

S12_reset_reclaims()
{
	EXTRA_GUCS=(dynamic_shared_memory_type=mmap)
	restart || { EXTRA_GUCS=(); ck "server started" 1; return; }
	EXTRA_GUCS=()
	ensure_memcow
	local dboid out n1 n2 n3 bytes
	dboid=$(lane_oid)

	# Reset once first so the baseline is "a lane at a fresh epoch", which
	# is the state every later reset has to return to.
	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid)")
	ck_eq "reset #1 -> epoch 1" 1 "$out"
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	n1=$(dsm_files)
	ck_match "baseline DSM segment count measured" '^[0-9]+$' "$n1"

	out=$(psql \
		-c "CREATE TABLE s12 AS SELECT i, repeat('x', 400) AS pad FROM generate_series(1, 200000) i" \
		-c "DELETE FROM s12" \
		-c "VACUUM (TRUNCATE on) s12" \
		-c "CHECKPOINT")
	ck_nomatch "fill, empty and truncate raised no error" 'ERROR' "$out"
	ck_eq "s12 is 0 blocks after the truncate" 0 "$(fork_nblocks s12)"

	bytes=$(lane_status "$dboid" arena_bytes)
	ck_match "arena reports its size" '^[0-9]+$' "$bytes"
	if [ "${bytes:-0}" -ge 12000000 ]; then
		ck "the truncated fork's pages are retained in the arena (>= 12 MB)" 0
	else
		ck "the truncated fork's pages are retained in the arena (>= 12 MB), got $bytes" 1
	fi
	n2=$(dsm_files)
	if [ "$n2" -ge $((n1 + 2)) ]; then
		ck "DSM segment count grew with the arena ($n1 -> $n2)" 0
	else
		ck "DSM segment count grew with the arena ($n1 -> $n2)" 1
	fi

	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid)")
	ck_eq "reset #2 -> epoch 2" 2 "$out"
	ck_eq "no attachment to the old epoch remains" 0 "$(lane_status "$dboid" attached_old)"
	ck_eq "reclaim is not pending" f "$(lane_status "$dboid" reclaim_pending)"
	n3=$(dsm_files)
	ck_eq "DSM segment count is back to the baseline (old arena destroyed)" "$n1" "$n3"
	bytes=$(lane_status "$dboid" arena_bytes)
	if [ "${bytes:-0}" -lt 4000000 ]; then
		ck "the new epoch's arena is small (< 4 MB)" 0
	else
		ck "the new epoch's arena is small (< 4 MB), got $bytes" 1
	fi

	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(psql -c "SELECT 'gone', count(*) FROM pg_class WHERE relname = 's12'")
	ck_match "s12 does not exist at epoch 2" '^gone\|0$' "$out"

	ck_no_crash
}

# The sabotage: no reset #2.  The segments must then still be there, i.e.
# the "back to baseline" assertion is what carries this case.
nc_S12_reset_reclaims()
{
	EXTRA_GUCS=(dynamic_shared_memory_type=mmap)
	restart || { EXTRA_GUCS=(); ck "server started" 1; return; }
	EXTRA_GUCS=()
	ensure_memcow
	local dboid n1 n2
	dboid=$(lane_oid)
	psql_ctl -c "SELECT memcow_lane_reset($dboid)" >/dev/null
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	n1=$(dsm_files)
	psql -c "CREATE TABLE s12 AS SELECT i, repeat('x', 400) AS pad FROM generate_series(1, 200000) i" \
	     -c "DELETE FROM s12" -c "VACUUM (TRUNCATE on) s12" -c "CHECKPOINT" >/dev/null
	n2=$(dsm_files)
	if [ "$n2" -gt "$n1" ]; then
		ck "sabotage detected: without a reset the arena's segments remain ($n1 -> $n2)" 0
	else
		ck "sabotage detected: without a reset the arena's segments remain ($n1 -> $n2)" 1
	fi
	ck_no_crash
}

# ===========================================================================
# S13 -- reset invalidates the cached record pointer (ADDENDUM §P(d))
#
# memcow_nblocks() caches a raw pointer to the fork's overlay record in the
# backend, so that memcow_truncate() -- inside a critical section -- can
# re-lock it without walking shared memory.  After a reset that record lives
# in a DISCARDED arena.  A retained backend that warmed the pin at epoch 0
# and truncates at epoch 1 must therefore (a) notice the pin is stale on its
# next memcow_nblocks() and re-pin, and (b) truncate through the fresh pin,
# never through the allocating fallback.  memcow's per-backend counters make
# both observable; the truncate landing in the right epoch, and being
# reverted by the next reset, make it correct.
# ===========================================================================

S13_reset_invalidates_pin()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	local dboid out pid c_before c_after
	dboid=$(lane_oid)

	sess_open A 7
	pid=$(sess_query A 7 "SELECT pg_backend_pid()")
	psql_ctl -c "SELECT memcow_lane_register($dboid, $pid)" >/dev/null
	ensure_pg_prewarm

	# Warm the pin: a seq scan sizes the fork through smgrnblocks().
	out=$(sess_query A 7 "SELECT 'rows', count(*) FROM public.events")
	ck_match "session A sized public.events at epoch 0" '^rows\|4000$' "$out"
	c_before=$(sess_query A 7 "SELECT value FROM public.memcow_backend_counters() WHERE name = 'nblocks_pin_refresh'")
	ck_match "counter readable" '^[0-9]+$' "$c_before"

	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid)")
	ck_eq "reset -> epoch 1" 1 "$out"
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(sess_query A 7 "SELECT public.memcow_backend_reset()")
	ck_eq "session A adopted epoch 1" 1 "$out"

	# The truncate.  pg_prewarm went with the overlay, so recreate it here.
	out=$(sess_query A 7 "
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
DELETE FROM public.events;
VACUUM (TRUNCATE on) public.events;
SELECT 'nblocks', pg_prewarm('public.events', 'prefetch', 'main');
SELECT name || '=' || value FROM public.memcow_backend_counters()
 WHERE name IN ('nblocks_pin_refresh', 'truncate_pinned', 'truncate_unpinned');
" 60)
	ck_nomatch "session A: DELETE + VACUUM raised no error and did not crash" \
		'ERROR|FATAL|server closed' "$out"
	ck_match "session A: the fork is 0 blocks after the truncate" '^nblocks\|0$' "$out"
	c_after=$(printf '%s' "$out" | sed -n 's/^nblocks_pin_refresh=//p')
	if [ -n "$c_after" ] && [ "$c_after" -gt "$c_before" ]; then
		ck "the stale epoch-0 pin was detected and refreshed ($c_before -> $c_after)" 0
	else
		ck "the stale epoch-0 pin was detected and refreshed ($c_before -> ${c_after:-?})" 1
	fi
	ck_match "the truncate went through the (fresh) pinned record" '^truncate_pinned=[1-9]' "$out"
	ck_match "the truncate never needed the unwarmed fallback"      '^truncate_unpinned=0$' "$out"

	# It landed in epoch 1 -- another backend agrees -- and the next reset
	# takes it away again.
	out=$(psql -c "SELECT 'rows', count(*) FROM public.events")
	ck_match "a fresh backend sees the epoch-1 truncate" '^rows\|0$' "$out"
	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid)")
	ck_eq "reset -> epoch 2" 2 "$out"
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(psql -c "SELECT 'rows', count(*) FROM public.events")
	ck_match "epoch 2: the truncate is reverted" '^rows\|4000$' "$out"

	sess_close A 7
	ck_no_crash
}

# The sabotage: the same session does the same warm-up and truncate with no
# reset in between.  The pin is then legitimately fresh and the refresh
# counter must NOT move -- if the case's "stale pin detected" assertion held
# here too, it would be measuring the truncate, not the reset.
nc_S13_reset_invalidates_pin()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	local out c_before c_after
	sess_open A 7
	ensure_pg_prewarm
	sess_query A 7 "SELECT count(*) FROM public.events" >/dev/null
	c_before=$(sess_query A 7 "SELECT value FROM public.memcow_backend_counters() WHERE name = 'nblocks_pin_refresh'")
	out=$(sess_query A 7 "
DELETE FROM public.events;
VACUUM (TRUNCATE on) public.events;
SELECT name || '=' || value FROM public.memcow_backend_counters()
 WHERE name IN ('nblocks_pin_refresh', 'truncate_pinned');
" 60)
	c_after=$(printf '%s' "$out" | sed -n 's/^nblocks_pin_refresh=//p')
	ck_eq "sabotage detected: without a reset the pin is not refreshed" "$c_before" "$c_after"
	ck_match "... while the truncate still used the pin" '^truncate_pinned=[1-9]' "$out"
	sess_close A 7
	ck_no_crash
}

# ===========================================================================
# S14 -- reset while a truncate is in flight in another backend
#         (plan §4.3 FENCE, Appendix B(i), ADDENDUM §A / §P(a))
#
# A backend parked INSIDE memcow_truncate() -- inside RelationTruncate()'s
# critical section, via the memcow-truncate-before-whiteout injection point
# -- is the worst possible moment for a reset: it holds no transaction id,
# so an xid check would call it idle, and it cannot be interrupted, so a
# SIGTERM cannot make it go away.  Two variants:
#
#   registered   the pool claims the backend is idle and it is not.  The
#                reset must REFUSE (backend not idle), publish nothing, and
#                leave the epoch unchanged; once the truncate completes a
#                retry succeeds and the epoch-0 truncate is discarded.
#   unregistered a straggler.  The reset SIGTERMs it, it cannot die inside
#                the critical section, and the reset must FAIL CLOSED on its
#                timeout -- lane still closed, epoch unchanged, nothing
#                published -- rather than publish over a live writer.  Once
#                the straggler leaves the critical section it dies of the
#                pending SIGTERM and a retry succeeds (Phase 3 changed this
#                from "lane retired": a reset that published nothing leaves
#                the lane exactly as trustworthy as it found it, and whether
#                to retire it is the pool's call -- plan Appendix B(i)).
# ===========================================================================

S14_reset_vs_truncate()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	ensure_injection_points
	ensure_injection_points "$CONTROL_DB"
	local dboid out pid seq
	dboid=$(lane_oid)

	sess_open B 8
	pid=$(sess_query B 8 "SELECT pg_backend_pid()")
	psql_ctl -c "SELECT memcow_lane_register($dboid, $pid)" >/dev/null

	# --- variant 1: registered but not idle -----------------------------
	# Attach first, THEN load: injection_points_load() copies the point's
	# shmem definition into this backend's cache, and it is the cached copy
	# that INJECTION_POINT_CACHED() in memcow_truncate() runs, without
	# allocating, inside the critical section.
	out=$(sess_query B 8 "
SELECT injection_points_set_local();
SELECT injection_points_attach('memcow-truncate-before-whiteout', 'wait');
SELECT injection_points_load('memcow-truncate-before-whiteout');
DELETE FROM public.events;
")
	ck_nomatch "session B armed the injection point and emptied events" 'ERROR' "$out"
	seq=$(sess_send B 8 "VACUUM (TRUNCATE on) public.events")
	if wait_for_wait_event "$pid" memcow-truncate-before-whiteout 20; then
		ck "session B is parked inside memcow_truncate()" 0
	else
		ck "session B is parked inside memcow_truncate()" 1
	fi

	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 2000)")
	ck_match "reset REFUSED: a registered backend is not idle" \
		'ERROR:.*(not idle|active)' "$out"
	ck_eq "epoch unchanged after the refusal" 0 "$(lane_status "$dboid" epoch)"
	ck_eq "lane is closed (RESETTING) after the refusal" RESETTING "$(lane_status "$dboid" state)"

	if wake_until_done B "$seq" memcow-truncate-before-whiteout 30; then
		ck "session B's truncate completed after wakeup" 0
	else
		ck "session B's truncate completed after wakeup" 1
	fi
	out=$(sess_query B 8 "SELECT injection_points_detach('memcow-truncate-before-whiteout'); SELECT 'rows', count(*) FROM public.events")
	ck_match "epoch 0 now holds the truncated relation" '^rows\|0$' "$out"

	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 5000)")
	ck_eq "retry succeeds once B is idle -> epoch 1" 1 "$out"
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(sess_query B 8 "SELECT public.memcow_backend_reset(); SELECT 'rows', count(*) FROM public.events")
	ck_match "session B adopted epoch 1" '^1$' "$out"
	ck_match "session B: the epoch-0 truncate is gone" '^rows\|4000$' "$out"
	out=$(psql -c "SELECT 'rows', count(*) FROM public.events")
	ck_match "fresh backend: the epoch-0 truncate is gone" '^rows\|4000$' "$out"

	# --- variant 2: an unregistered straggler that cannot die -----------
	psql_ctl -c "SELECT memcow_lane_unregister($dboid, $pid)" >/dev/null
	ensure_injection_points
	out=$(sess_query B 8 "
CREATE EXTENSION IF NOT EXISTS injection_points;
SELECT injection_points_set_local();
SELECT injection_points_attach('memcow-truncate-before-whiteout', 'wait');
SELECT injection_points_load('memcow-truncate-before-whiteout');
DELETE FROM public.events;
")
	ck_nomatch "session B re-armed the injection point at epoch 1" 'ERROR' "$out"
	seq=$(sess_send B 8 "VACUUM (TRUNCATE on) public.events")
	if wait_for_wait_event "$pid" memcow-truncate-before-whiteout 20; then
		ck "session B is parked again" 0
	else
		ck "session B is parked again" 1
	fi

	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 1500)")
	ck_match "reset FAILS CLOSED: the straggler did not exit within the timeout" \
		'ERROR:.*(straggler|did not exit|timed out)' "$out"
	ck_eq "epoch unchanged after the timeout" 1 "$(lane_status "$dboid" epoch)"
	ck_eq "lane stays CLOSED (RESETTING) after the timeout, not retired" RESETTING "$(lane_status "$dboid" state)"
	ck_eq "nothing was published (no reclaim pending)" f "$(lane_status "$dboid" reclaim_pending)"

	wake_until_done B "$seq" memcow-truncate-before-whiteout 30 || true
	out=$(sess_query B 8 "SELECT 1" 10 || true)
	ck_match "the straggler died of the SIGTERM once it left the critical section" \
		'FATAL:.*terminating connection|server closed the connection|connection to server was lost' \
		"$(sess_output B "$seq"; printf '%s' "$out")"
	wait_for_pid_gone "$pid" 20 || ck "the straggler is gone from pg_stat_activity" 1

	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 5000)")
	ck_eq "retry succeeds once the straggler is gone -> epoch 2" 2 "$out"
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(psql -c "SELECT 'rows', count(*) FROM public.events")
	ck_match "epoch 2: the straggler's epoch-1 truncate is gone" '^rows\|4000$' "$out"

	sess_close B 8
	ck_no_crash
}

# The sabotage: nothing is parked (no injection point), so the registered
# backend really is idle when the reset runs.  The reset must then SUCCEED --
# if the case's "refused" assertion held here too, the fence would be
# refusing idle backends, i.e. measuring nothing.
nc_S14_reset_vs_truncate()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	local dboid out pid
	dboid=$(lane_oid)
	sess_open B 8
	pid=$(sess_query B 8 "SELECT pg_backend_pid()")
	psql_ctl -c "SELECT memcow_lane_register($dboid, $pid)" >/dev/null
	out=$(sess_query B 8 "DELETE FROM public.events; VACUUM (TRUNCATE on) public.events;" 60)
	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 2000)")
	ck_eq "sabotage detected: with nothing in flight the reset is NOT refused" 1 "$out"
	sess_close B 8
	ck_no_crash
}


# ===========================================================================
# Phase 3 helpers
# ===========================================================================

ensure_pg_buffercache()		# in the control database
{
	psql_ctl -c "CREATE EXTENSION IF NOT EXISTS pg_buffercache" >/dev/null 2>&1
}

checkpointer_pid()
{
	psql_ctl -c "SELECT pid FROM pg_stat_activity WHERE backend_type = 'checkpointer'"
}

# attach_point NAME ACTION [CONDITION] --- a GLOBAL injection point, from the
# control database (no set_local): it fires in whatever process reaches it.
attach_point()
{
	if [ -n "${3:-}" ]; then
		psql_ctl -c "SELECT injection_points_attach('$1', '$2', '$3')"
	else
		psql_ctl -c "SELECT injection_points_attach('$1', '$2')"
	fi
}
detach_point() { psql_ctl -c "SELECT injection_points_detach('$1')" >/dev/null 2>&1; }
wake_point()   { psql_ctl -c "SELECT injection_points_wakeup('$1')"; }

# wait_for_backend_at EVENT [TIMEOUT] --- print the PID of a backend whose
# wait_event is EVENT, waiting for one to appear; rc 1 on timeout.
wait_for_backend_at()
{
	local ev=$1 timeout=${2:-20} i=0 got
	while :; do
		got=$(psql_ctl -c "SELECT pid FROM pg_stat_activity WHERE wait_event = '$ev' LIMIT 1")
		[ -n "$got" ] && { printf '%s\n' "$got"; return 0; }
		i=$((i + 1))
		[ $i -lt $((timeout * 10)) ] || return 1
		sleep 0.1
	done
}

# wait_for_pid_gone PID [TIMEOUT] --- until pg_stat_activity no longer lists PID
wait_for_pid_gone()
{
	local pid=$1 timeout=${2:-20} i=0
	while [ "$(psql_ctl -c "SELECT count(*) FROM pg_stat_activity WHERE pid = $pid")" != 0 ]; do
		i=$((i + 1))
		[ $i -lt $((timeout * 10)) ] || return 1
		sleep 0.1
	done
}

# log_for_pid PID --- every postmaster.log line for that backend
log_for_pid() { grep -E "\[$1\] " "$LOGFILE" 2>/dev/null; }

# lane_buffers OID [EXTRA-WHERE] --- shared buffers tagged with database OID
lane_buffers()
{
	psql_ctl -c "SELECT count(*) FROM pg_buffercache WHERE reldatabase = $1 ${2:-}"
}

# ===========================================================================
# S15 -- the authentication-time fence (plan §5 I2, fence 2 of 3)
#
# With contrib/memcow in shared_preload_libraries, its
# ClientAuthentication_hook reads the database name out of the startup packet,
# finds the lane by that name, and refuses an ARMED lane's stale or absent
# nonce at authentication -- before "connection authorized" is logged, before
# the database startup lock, before the backend advertises its database in
# the ProcArray.  An unarmed lane admits anyone.  The log has to say which
# fence fired: the DETAIL names it, and the refused PID has a "connection
# authenticated" line but no "connection authorized" line, because the FATAL
# came from inside PerformAuthentication().
# ===========================================================================

S15_auth_fence()
{
	EXTRA_GUCS=(shared_preload_libraries=memcow log_connections=authentication,authorization)
	restart || { EXTRA_GUCS=(); ck "server started" 1; return; }
	EXTRA_GUCS=()
	ensure_memcow
	local dboid out nonce pid lines
	dboid=$(lane_oid)

	# --- unarmed: anyone ---------------------------------------------------
	out=$(psql_ctl -c "SELECT memcow_lane_open($dboid, false)")
	ck_eq "lane opened unarmed" 0 "$out"
	out=$(psql -c "SELECT 1")
	ck_match "unarmed lane: a connection with no nonce is admitted" '^1$' "$out"

	# --- armed: the nonce, at auth -------------------------------------------
	nonce=$(psql_ctl -c "SELECT memcow_lane_open($dboid, true)")
	ck_match "lane opened armed with a nonce" '^[1-9][0-9]*$' "$nonce"

	out=$(PGOPTIONS="-c memcow.lane_nonce=$((nonce + 1))" psql -c "SELECT 1")
	ck_match "armed lane: a stale nonce is refused" 'FATAL:.*nonce mismatch' "$out"
	pid=$(grep -E 'FATAL:.*nonce mismatch' "$LOGFILE" | tail -1 | sed -n 's/.*\[\([0-9][0-9]*\)\].*/\1/p')
	ck_match "the refusal is in the log with a PID" '^[0-9]+$' "$pid"
	lines=$(log_for_pid "$pid")
	ck_match "the log names the fence: the memcow authentication fence" \
		'authentication fence' "$lines"
	ck_match "the PID was authenticated (auth proper completed first)" \
		'connection authenticated' "$lines"
	ck_nomatch "the PID was NEVER authorized: refused before PerformAuthentication returned, hence before the database lock and the ProcArray advertisement" \
		'connection authorized' "$lines"
	ck_nomatch "the admission fence (fence 3) never saw this connection" \
		'admission fence' "$lines"

	out=$(psql -c "SELECT 1")
	ck_match "armed lane: an absent nonce is refused" 'FATAL:.*nonce mismatch' "$out"
	pid=$(grep -E 'FATAL:.*nonce mismatch' "$LOGFILE" | tail -1 | sed -n 's/.*\[\([0-9][0-9]*\)\].*/\1/p')
	ck_match "absent nonce: refused by the authentication fence too" \
		'authentication fence' "$(log_for_pid "$pid")"

	out=$(PGOPTIONS="-c memcow.lane_nonce=$nonce" psql -c "SELECT 1")
	ck_match "armed lane: the current nonce passes both fences" '^1$' "$out"

	# --- armed and closed: refused at auth as well (plan §4.1) -----------------
	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid)")
	ck_eq "reset -> epoch 1 (lane now RESETTING, still armed)" 1 "$out"
	out=$(PGOPTIONS="-c memcow.lane_nonce=$nonce" psql -c "SELECT 1")
	ck_match "armed RESETTING lane: refused even with the current nonce" 'FATAL:.*not open' "$out"
	pid=$(grep -E 'FATAL:.*not open' "$LOGFILE" | tail -1 | sed -n 's/.*\[\([0-9][0-9]*\)\].*/\1/p')
	ck_match "... by the authentication fence" 'authentication fence' "$(log_for_pid "$pid")"

	# --- the control database is not a lane: never fenced ---------------------
	out=$(psql_ctl -c "SELECT 1")
	ck_match "the control database is not a lane and is never fenced" '^1$' "$out"

	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(PGOPTIONS="-c memcow.lane_nonce=$nonce -c event_triggers=off" psql -c "SELECT 'bypass'")
	ck_match "startup event_triggers=off cannot bypass the login fence" 'FATAL:.*requires event_triggers=on' "$out"

	out=$(PGOPTIONS="-c memcow.lane_nonce=$nonce" psql -c "ALTER EVENT TRIGGER memcow_admission DISABLE")
	ck_match "the seed admission trigger cannot be disabled" 'ERROR:.*cannot modify memcow' "$out"
	out=$(PGOPTIONS="-c memcow.lane_nonce=$nonce" psql -c "DROP EXTENSION memcow CASCADE")
	ck_match "the admission trigger cannot be dropped through its extension" 'ERROR:.*cannot modify memcow' "$out"
	ck_no_crash
}

# The sabotage disables only the authentication hook through an injection
# point. The storage manager remains registered, and fence 3 still catches it
# fence in the login event trigger, i.e. AFTER "connection authorized", and the log says
# so.  The case's "authentication fence, never authorized" assertions must
# therefore fail here.
nc_S15_auth_fence()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	ensure_injection_points "$CONTROL_DB"
	attach_point memcow-skip-auth notice >/dev/null
	local dboid out nonce pid lines
	dboid=$(lane_oid)
	nonce=$(psql_ctl -c "SELECT memcow_lane_open($dboid, true)")
	ck_match "every SQL function works with the auth hook disabled (open returned a nonce)" '^[1-9][0-9]*$' "$nonce"
	out=$(PGOPTIONS="-c memcow.lane_nonce=$((nonce + 1))" psql -c "SELECT 1")
	ck_match "a stale nonce is still refused" 'FATAL:.*nonce mismatch' "$out"
	pid=$(grep -E 'FATAL:.*nonce mismatch' "$LOGFILE" | tail -1 | sed -n 's/.*\[\([0-9][0-9]*\)\].*/\1/p')
	lines=$(log_for_pid "$pid")
	ck_match "sabotage detected: with the auth hook disabled the refusal comes from the admission fence" \
		'admission fence' "$lines"
	ck_nomatch "... and not from the authentication fence" 'authentication fence' "$lines"
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	detach_point memcow-skip-auth
	ck_no_crash
}

# ===========================================================================
# S16 -- the per-lane arena limit (CONCERN 4a): exhaustion is a named error
#
# memcow.lane_arena_limit bounds one lane-epoch's arena through
# dsa_set_size_limit(), bound when the lane is opened and at every reset.
# Filling it fails the WRITING STATEMENT with SQLSTATE 53MC1
# (ERRCODE_MEMCOW_ARENA_FULL) and a message that names memcow -- not dsa's
# generic "out of memory", which reads as backend memory pressure.  The lane
# survives the error, a reset gives it a fresh arena under the same limit,
# and the arena never exceeds the limit.
# ===========================================================================

S16_arena_limit()
{
	EXTRA_GUCS=(memcow.lane_arena_limit=4MB)
	restart || { EXTRA_GUCS=(); ck "server started" 1; return; }
	EXTRA_GUCS=()
	ensure_memcow
	local dboid out bytes
	dboid=$(lane_oid)

	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	ck_eq "the lane reports the limit in force (4 MB)" 4194304 "$(lane_status "$dboid" arena_limit)"

	out=$(psql -c '\set VERBOSITY verbose' \
		-c "CREATE TABLE s16_big AS SELECT i, repeat('x', 400) AS pad FROM generate_series(1, 60000) i")
	ck_match "a 25 MB write into a 4 MB arena fails with SQLSTATE 53MC1" '53MC1' "$out"
	ck_match "... with memcow's own message, not dsa's" 'memcow overlay for database [0-9]+ is full' "$out"
	ck_match "... naming the limit" 'memcow.lane_arena_limit is 4 MB' "$out"
	bytes=$(lane_status "$dboid" arena_bytes)
	if [ "${bytes:-0}" -le 4194304 ]; then
		ck "the arena never exceeded the limit ($bytes bytes)" 0
	else
		ck "the arena never exceeded the limit ($bytes bytes)" 1
	fi

	out=$(psql -c "SELECT 'rows', count(*) FROM public.events" \
		-c "UPDATE public.events SET kind = 's16' WHERE event_id = 1" \
		-c "SELECT 'kind', kind FROM public.events WHERE event_id = 1" \
		-c "SELECT 'big', count(*) FROM pg_class WHERE relname = 's16_big'")
	ck_match "the lane survives: reads work"            '^rows\|4000$' "$out"
	ck_match "the lane survives: a small write works"   '^kind\|s16$'  "$out"
	ck_match "the failed statement left no relation"    '^big\|0$'     "$out"

	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid)")
	ck_eq "reset -> epoch 1" 1 "$out"
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	ck_eq "the fresh arena carries the limit" 4194304 "$(lane_status "$dboid" arena_limit)"
	out=$(psql -c '\set VERBOSITY verbose' \
		-c "CREATE TABLE s16_small AS SELECT i FROM generate_series(1, 20000) i" \
		-c "SELECT 'small', count(*) FROM s16_small" \
		-c "CREATE TABLE s16_big AS SELECT i, repeat('x', 400) AS pad FROM generate_series(1, 60000) i")
	ck_match "epoch 1: a write that fits succeeds" '^small\|20000$' "$out"
	ck_match "epoch 1: a write that does not fit fails with 53MC1 again" '53MC1' "$out"
	ck_no_crash
}

# The sabotage: no limit.  The 25 MB write must then SUCCEED, i.e. the named
# error is what the limit produces, not what the write produces.
nc_S16_arena_limit()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	local dboid out
	dboid=$(lane_oid)
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	ck_eq "no limit in force" 0 "$(lane_status "$dboid" arena_limit)"
	out=$(psql -c "CREATE TABLE s16_big AS SELECT i, repeat('x', 400) AS pad FROM generate_series(1, 60000) i" \
		-c "SELECT 'big', count(*) FROM s16_big")
	ck_match "sabotage detected: without a limit the 25 MB write succeeds" '^big\|60000$' "$out"
	ck_nomatch "... and no 53MC1 is raised" '53MC1|is full' "$out"
	ck_no_crash
}

# ===========================================================================
# R1 -- §7.3 (a): a connection parked after authentication while a reset runs
#
# The window plan A.1.3 describes: ClientAuthentication has admitted the
# connection (it presented the current nonce), but the backend has not yet
# taken the database startup lock nor advertised its database in the
# ProcArray, so the reset's fence cannot see it.  The reset must complete
# past it, and when the backend resumes it must die at the admission fence
# in the login event trigger -- fence 3 of 3, the only one that can still catch it --
# before its first command is dispatched.  Parked at the memcow-lanes-post-auth
# injection point, which the preloaded auth hook fires for lane databases.
# ===========================================================================

R1_auth_window()
{
	R1_auth_window_protocol simple
	R1_auth_window_protocol extended
}

R1_auth_window_protocol()
{
	local protocol=$1
	EXTRA_GUCS=(shared_preload_libraries=memcow log_connections=authentication,authorization)
	restart || { EXTRA_GUCS=(); ck "server started" 1; return; }
	EXTRA_GUCS=()
	ensure_memcow
	ensure_injection_points "$CONTROL_DB"
	local dboid out nonce nonce2 pid_a parked bg lines
	dboid=$(lane_oid)
	psql_ctl -c "ALTER DATABASE \"$DB\" SET event_triggers=off" >/dev/null

	sess_open A 7
	pid_a=$(sess_query A 7 "SELECT pg_backend_pid()")
	psql_ctl -c "SELECT memcow_lane_register($dboid, $pid_a)" >/dev/null
	sess_query A 7 "UPDATE public.events SET kind = 'r1' WHERE event_id = 1" >/dev/null
	nonce=$(psql_ctl -c "SELECT memcow_lane_open($dboid, true)")
	ck_match "lane armed" '^[1-9][0-9]*$' "$nonce"

	attach_point memcow-lanes-post-auth wait >/dev/null
	# the escaped connection string: current nonce, so the auth fence admits it
	( PGOPTIONS="-c memcow.lane_nonce=$nonce -c session_replication_role=replica" PGHOST=$SOCKDIR PGPORT=$PORT \
	  python3 "$(dirname "$0")/startup_probe.py" --dbname "$DB" --protocol "$protocol" \
	  >"$OUTPUTDIR/r1.out" 2>&1; echo "rc=$?" >>"$OUTPUTDIR/r1.out" ) &
	bg=$!
	parked=$(wait_for_backend_at memcow-lanes-post-auth 20)
	ck_match "a connecting backend is parked after authentication" '^[0-9]+$' "$parked"
	out=$(psql_ctl -c "SELECT coalesce(datname, '<none>') FROM pg_stat_activity WHERE pid = ${parked:-0}")
	ck_eq "... and has no database yet, so the fence cannot see it" '<none>' "$out"

	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 5000)")
	ck_eq "a full reset completes past the parked backend -> epoch 1" 1 "$out"
	nonce2=$(psql_ctl -c "SELECT memcow_lane_open($dboid, true)")
	ck_match "lane reopened armed with a new nonce" '^[1-9][0-9]*$' "$nonce2"
	[ "$nonce2" != "$nonce" ] && ck "the new nonce differs from the one the parked backend presented" 0 \
		|| ck "the new nonce differs from the one the parked backend presented" 1
	out=$(sess_query A 7 "SELECT public.memcow_backend_reset()")
	ck_eq "the retained backend adopted epoch 1" 1 "$out"

	wake_point memcow-lanes-post-auth >/dev/null
	wait "$bg" 2>/dev/null
	out=$(cat "$OUTPUTDIR/r1.out")
	ck_match "resumed backend: FATAL before its first command" 'FATAL:.*nonce mismatch' "$out"
	ck_nomatch "resumed backend: the command never ran" 'r1-cmd-ran' "$out"
	lines=$(log_for_pid "$parked")
	ck_match "which fence: it had been AUTHORIZED (the auth fence admitted it)" 'connection authorized' "$lines"
	ck_match "which fence: the login event trigger admission fence (3 of 3) caught it" 'admission fence' "$lines"
	ck_nomatch "which fence: not the authentication fence" 'authentication fence' "$lines"

	# the park point stays attached until here: a later lane connection would
	# park too, and authentication_timeout would kill it after 60 s
	detach_point memcow-lanes-post-auth
	out=$(psql -c "SELECT 1")
	ck_match "afterwards a connection without the nonce is still refused" 'FATAL' "$out"
	out=$(PGOPTIONS="-c memcow.lane_nonce=$nonce2" psql -c "SELECT 'kind', kind FROM public.events WHERE event_id = 1")
	ck_match "and one with the new nonce sees the seed" '^kind\|logout$' "$out"

	psql_ctl -c "ALTER DATABASE \"$DB\" RESET event_triggers" >/dev/null
	sess_close A 7
	ck_no_crash
}

# The sabotage: fence 3 switched off (memcow-skip-admission).  The parked
# backend then resumes INTO epoch 1 with a stale nonce and its command runs
# -- the exact hazard, made visible: the case's "FATAL before first command"
# assertion fails.
nc_R1_auth_window()
{
	nc_R1_auth_window_protocol simple
	nc_R1_auth_window_protocol extended
}

nc_R1_auth_window_protocol()
{
	local protocol=$1
	EXTRA_GUCS=(shared_preload_libraries=memcow)
	restart || { EXTRA_GUCS=(); ck "server started" 1; return; }
	EXTRA_GUCS=()
	ensure_memcow
	ensure_injection_points "$CONTROL_DB"
	local dboid out nonce parked bg
	dboid=$(lane_oid)
	nonce=$(psql_ctl -c "SELECT memcow_lane_open($dboid, true)")
	attach_point memcow-skip-admission notice >/dev/null
	attach_point memcow-lanes-post-auth wait >/dev/null
	( PGOPTIONS="-c memcow.lane_nonce=$nonce" PGHOST=$SOCKDIR PGPORT=$PORT \
	  python3 "$(dirname "$0")/startup_probe.py" --dbname "$DB" --protocol "$protocol" \
	  >"$OUTPUTDIR/r1nc.out" 2>&1 ) &
	bg=$!
	parked=$(wait_for_backend_at memcow-lanes-post-auth 20)
	ck_match "backend parked" '^[0-9]+$' "$parked"
	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 5000)")
	ck_eq "reset -> epoch 1" 1 "$out"
	psql_ctl -c "SELECT memcow_lane_open($dboid, true)" >/dev/null
	wake_point memcow-lanes-post-auth >/dev/null
	wait "$bg" 2>/dev/null
	out=$(cat "$OUTPUTDIR/r1nc.out")
	ck_match "sabotage detected: with fence 3 off the stale-nonce backend is admitted into epoch 1 and its command runs" \
		'r1-cmd-ran' "$out"
	detach_point memcow-skip-admission
	detach_point memcow-lanes-post-auth
	ck_no_crash
}

# ===========================================================================
# R2 -- §7.3 (b): a straggler that is SIGSTOPped after the SIGTERM
#
# The fence terminates every unregistered backend in the lane and waits to
# OBSERVE each one dead.  A stopped process cannot die: the SIGTERM stays
# pending.  The reset must fail closed on its timeout -- lane still closed,
# epoch unchanged, NOTHING published (no reclaim pending, no old attachment)
# -- and once the straggler is continued the pending SIGTERM kills it and a
# retry succeeds.
# ===========================================================================

R2_stopped_straggler()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	local dboid out pid_a pid_s seq
	dboid=$(lane_oid)

	sess_open A 7
	pid_a=$(sess_query A 7 "SELECT pg_backend_pid()")
	psql_ctl -c "SELECT memcow_lane_register($dboid, $pid_a)" >/dev/null
	sess_query A 7 "UPDATE public.events SET kind = 'r2' WHERE event_id = 1" >/dev/null

	sess_open S 9
	pid_s=$(sess_query S 9 "SELECT pg_backend_pid()")
	seq=$(sess_send S 9 "BEGIN; UPDATE public.accounts SET balance = 0 WHERE account_id = 1; SELECT pg_sleep(60);")
	wait_for_wait_event "$pid_s" PgSleep 20 || ck "straggler is inside its query" 1
	kill -STOP "$pid_s" && ck "straggler SIGSTOPped" 0 || ck "straggler SIGSTOPped" 1

	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 1500)")
	ck_match "reset FAILS CLOSED on its timeout: the straggler did not exit" \
		'ERROR:.*straggler backend [0-9]+ did not exit within' "$out"
	ck_match "... and says the epoch is unchanged and nothing was published" 'nothing was published' "$out"
	ck_eq "epoch unchanged" 0 "$(lane_status "$dboid" epoch)"
	ck_eq "lane is closed (RESETTING), not retired" RESETTING "$(lane_status "$dboid" state)"
	ck_eq "no reclaim pending (never published)" f "$(lane_status "$dboid" reclaim_pending)"
	ck_eq "no old-epoch attachment" 0 "$(lane_status "$dboid" attached_old)"
	out=$(psql_ctl -c "SELECT count(*) FROM pg_stat_activity WHERE pid = $pid_s")
	ck_eq "the stopped straggler is still there" 1 "$out"

	kill -CONT "$pid_s"
	if wait_for_pid_gone "$pid_s" 20; then
		ck "continued: the pending SIGTERM killed the straggler" 0
	else
		ck "continued: the pending SIGTERM killed the straggler" 1
	fi
	sess_wait S "$seq" 5 || true
	ck_match "the straggler's client saw the termination" \
		'FATAL:.*terminating connection|server closed the connection|connection to server was lost' \
		"$(sess_output S "$seq")"

	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 5000)")
	ck_eq "retry succeeds -> epoch 1" 1 "$out"
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(sess_query A 7 "SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1; SELECT 'bal', balance FROM public.accounts WHERE account_id = 1")
	ck_match "retained backend adopted epoch 1" '^1$' "$out"
	ck_match "epoch 1: the committed epoch-0 write is reverted" '^kind\|logout$' "$out"
	ck_nomatch "epoch 1: the straggler's uncommitted write is not there" '^bal\|0$' "$out"

	sess_close S 9
	sess_close A 7
	ck_no_crash
}

# The sabotage: no SIGSTOP.  The straggler then dies of the SIGTERM at once
# and the very first reset SUCCEEDS -- if the case's "fails closed" assertion
# held here too, the fence would be timing out on live-and-killable
# stragglers, i.e. measuring the timeout rather than the stop.
nc_R2_stopped_straggler()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	local dboid out pid_s seq
	dboid=$(lane_oid)
	sess_open S 9
	pid_s=$(sess_query S 9 "SELECT pg_backend_pid()")
	seq=$(sess_send S 9 "BEGIN; UPDATE public.accounts SET balance = 0 WHERE account_id = 1; SELECT pg_sleep(60);")
	wait_for_wait_event "$pid_s" PgSleep 20 || ck "straggler is inside its query" 1
	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 1500)")
	ck_eq "sabotage detected: without the SIGSTOP the same reset succeeds at once" 1 "$out"
	sess_close S 9
	ck_no_crash
}

# ===========================================================================
# R3 -- §7.3 (c): cancel a query with an IO in flight; release + reset at once
#
# What "AIO in flight" can mean under memcow, stated exactly: memcow
# completes every read synthetically in the issuing backend, so no memcow
# IO ever reaches an IO worker (that is Phase 1's result).  The widest
# in-flight window that exists is the one inside pgaio_io_process_completion()
# -- handle COMPLETED_IO, target buffer BM_IO_IN_PROGRESS, owner holding the
# pin -- with io_method=worker configured, and that is where this parks the
# lane backend, on test_aio's completion-wait hook (the recipe test 005
# validated for synthetic completion).  A cancel arriving there is DEFERRED:
# the completion runs with interrupts held, so the backend stays parked, the
# IO completes when released, and only then does the statement error out.
# The pool then releases and resets immediately: the reset must not wait on
# anything (the backend is idle, the IO is done), the old arena that held the
# pages the cancelled query read is POISONED at reclaim (assert builds), and
# the retained backend's re-read at the new epoch is clean seed content --
# nothing reads the poisoned memory, which is what "no use-after-free" means
# here.  DropDatabaseBuffers()' wait on in-progress IO is exercised by R4,
# where a non-lane process (the checkpointer) really does hold a lane buffer's
# IO across the reset.
# ===========================================================================

R3_cancel_inflight_io()
{
	EXTRA_GUCS=(io_method=worker shared_preload_libraries=memcow,test_aio)
	restart || { EXTRA_GUCS=(); ck "server started" 1; return; }
	EXTRA_GUCS=()
	ensure_memcow
	ensure_pg_buffercache
	local dboid out pid_l seq relfilenode st
	dboid=$(lane_oid)
	psql_ctl -c "CREATE EXTENSION IF NOT EXISTS test_aio" >/dev/null 2>&1

	sess_open L 7
	pid_l=$(sess_query L 7 "SELECT pg_backend_pid()")
	psql_ctl -c "SELECT memcow_lane_register($dboid, $pid_l)" >/dev/null
	out=$(sess_query L 7 "UPDATE public.events SET kind = 'r3' WHERE event_id = 1; CHECKPOINT; SELECT pg_relation_filenode('public.events')")
	relfilenode=$(printf '%s' "$out" | tail -1)
	ck_match "epoch 0: events page written, relfilenode known" '^[0-9]+$' "$relfilenode"
	# evict the lane's buffers so the next read is a real (synthetic) IO
	out=$(psql_ctl -c "SELECT count(*) FROM (SELECT pg_buffercache_evict(bufferid) FROM pg_buffercache WHERE reldatabase = $dboid) s")
	ck_match "lane buffers evicted" '^[0-9]+$' "$out"

	psql_ctl -c "SELECT inj_io_completion_wait(pid => $pid_l, relfilenode => $relfilenode, blockno => 0)" >/dev/null
	seq=$(sess_send L 7 "SELECT count(*) FROM public.events")
	if wait_for_wait_event "$pid_l" completion_wait 20; then
		ck "lane backend parked inside pgaio_io_process_completion(): IO in flight" 0
	else
		ck "lane backend parked inside pgaio_io_process_completion(): IO in flight" 1
	fi
	out=$(psql_ctl -c "SELECT pg_cancel_backend($pid_l)")
	ck_eq "cancel sent" t "$out"
	sleep 0.5
	ck_eq "the cancel is deferred while the IO is in flight (still parked)" completion_wait \
		"$(psql_ctl -c "SELECT wait_event FROM pg_stat_activity WHERE pid = $pid_l")"

	psql_ctl -c "SELECT inj_io_completion_continue()" >/dev/null
	sess_wait L "$seq" 20 || ck "the statement finished after the IO completed" 1
	out=$(sess_output L "$seq")
	ck_match "the IO completed, then the cancel was processed: statement cancelled" \
		'ERROR:.*canceling statement' "$out"
	ck_nomatch "no crash, no invalid page" 'invalid page|server closed|PANIC' "$out"

	# release + reset immediately: the pool's drain, then the reset
	out=$(sess_query L 7 "ROLLBACK; DISCARD ALL;")
	ck_eq "released: backend idle" idle "$(psql_ctl -c "SELECT state FROM pg_stat_activity WHERE pid = $pid_l")"
	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 5000)")
	ck_eq "reset does not wait on anything and succeeds -> epoch 1" 1 "$out"
	st=$(psql_ctl -c "SELECT attached_old || '|' || reclaim_pending || '|' || poisoned_pages FROM memcow_lane_status($dboid)")
	ck_match "no old-arena attachment, reclaim done" '^0\|false\|' "$st"
	ck_match "the old arena was POISONED at reclaim (>= 1 page, assert build)" '\|[1-9][0-9]*$' "$st"

	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(sess_query L 7 "SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1; SELECT 'rows', count(*) FROM public.events")
	ck_match "retained backend adopted epoch 1" '^1$' "$out"
	ck_match "epoch 1: the re-read is seed content, not the poisoned old page" '^kind\|logout$' "$out"
	ck_match "epoch 1: the whole relation reads clean" '^rows\|4000$' "$out"
	ck_nomatch "no invalid page anywhere" 'invalid page|ERROR' "$out"

	sess_close L 7
	ck_no_crash
}

# The sabotage: the retained backend KEEPS its stale attachment
# (memcow-skip-stale-detach: it neither drops it at the barrier nor
# re-attaches on its next lookup).  That is a process with a live mapping of
# epoch 0's arena -- the use-after-free candidate -- and the reset's RECLAIM
# gate must refuse to free the arena under it: ERROR "still attached", epoch
# published but reclaim pending.  The case's "reset succeeds, poisoned" path
# is therefore what carries it.  Once the backend exits, a retry finishes.
nc_R3_cancel_inflight_io()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	ensure_injection_points "$CONTROL_DB"
	local dboid out pid_l
	dboid=$(lane_oid)
	sess_open L 7
	pid_l=$(sess_query L 7 "SELECT pg_backend_pid()")
	psql_ctl -c "SELECT memcow_lane_register($dboid, $pid_l)" >/dev/null
	sess_query L 7 "UPDATE public.events SET kind = 'r3' WHERE event_id = 1; CHECKPOINT;" >/dev/null
	attach_point memcow-skip-stale-detach notice >/dev/null
	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 2000)")
	ck_match "sabotage detected: a backend that keeps its stale attachment makes RECLAIM refuse" \
		'ERROR:.*still attached to epoch 0' "$out"
	ck_eq "epoch was published" 1 "$(lane_status "$dboid" epoch)"
	ck_eq "reclaim pending" t "$(lane_status "$dboid" reclaim_pending)"
	# The knob is global (IS_INJECTION_POINT_ATTACHED evaluates no PID
	# condition), so while it is set EVERY process -- the checkpointer too --
	# skips the barrier's detach, and a retry cannot recover the lane while it
	# is still attached: recovery is the POSITIVE case's job (R3 proper), not
	# this control's.  Detaching the knob and dropping the backend is enough
	# to leave nothing running; the next case restarts the postmaster.
	detach_point memcow-skip-stale-detach
	sess_close L 7
	wait_for_pid_gone "$pid_l" 20 || true
	ck_no_crash
}

# ===========================================================================
# R4 -- §7.3 (d): a checkpoint concurrent with a reset, the checkpointer
#      parked inside FlushBuffer before the write lands
#
# The checkpointer is the one process the fence cannot stop and that writes
# lane buffers.  Parked at memcow-checkpointer-writev -- inside FlushBuffer(),
# holding the buffer's pin, its content lock and BM_IO_IN_PROGRESS, with
# interrupts held (so it cannot absorb the barrier) -- while a reset runs:
# the reset PUBLISHES epoch 1 and then WAITS at the barrier (wait event
# ProcSignalBarrier) for the checkpointer.  Released, the checkpointer's
# write is of an epoch-0 buffer by a process now attached to epoch 1: the
# DISCARD WINDOW (finding 2 of 2026-09-01) drops it, counted in the lane's
# writes_discarded, and the sweep then removes the buffer.  Variant 2 releases
# the checkpointer BEFORE the reset: the write lands in the old arena and the
# reset discards the arena.  Either way the page is never in the new arena:
# after adopt every backend sees the seed's row.
# ===========================================================================

R4_checkpoint_discard()
{
	EXTRA_GUCS=(bgwriter_lru_maxpages=0)
	restart || { EXTRA_GUCS=(); ck "server started" 1; return; }
	EXTRA_GUCS=()
	ensure_memcow
	ensure_injection_points "$CONTROL_DB"
	ensure_pg_buffercache
	local dboid out pid_l pid_c seq seq2 ckpt st
	dboid=$(lane_oid)
	ckpt=$(checkpointer_pid)
	ck_match "checkpointer pid known" '^[0-9]+$' "$ckpt"

	sess_open L 7
	pid_l=$(sess_query L 7 "SELECT pg_backend_pid()")
	psql_ctl -c "SELECT memcow_lane_register($dboid, $pid_l)" >/dev/null
	sess_open C 9 "$CONTROL_DB"
	pid_c=$(sess_query C 9 "SELECT pg_backend_pid()")
	sess_open C2 10 "$CONTROL_DB"

	# --- variant 1: released AFTER publish -> discarded ----------------------
	# Two dirty lane relations, so the checkpointer has at least two lane
	# writes to make and parks on each in turn: the first one while the reset
	# waits at the BARRIER, the second one -- after the checkpointer has
	# absorbed the barrier between writes -- while the reset waits in the
	# SWEEP (DropDatabaseBuffers -> InvalidateBuffer -> WaitIO, wait event
	# BufferIo: plan Appendix B(a), "§4.7 waits").  Every write released
	# after PUBLISH is discarded; the count must match.
	psql_ctl -c "CHECKPOINT" >/dev/null
	sess_query L 7 "UPDATE public.events SET kind = 'r4' WHERE event_id = 1; UPDATE public.accounts SET balance = 0 WHERE account_id = 1" >/dev/null
	attach_point memcow-checkpointer-writev wait "$dboid" >/dev/null
	seq2=$(sess_send C2 10 "CHECKPOINT")
	if wait_for_wait_event "$ckpt" memcow-checkpointer-writev 30; then
		ck "checkpointer parked inside FlushBuffer on a lane buffer" 0
	else
		ck "checkpointer parked inside FlushBuffer on a lane buffer" 1
	fi
	out=$(lane_buffers "$dboid" "AND pinning_backends > 0 AND isdirty")
	ck_match "... holding a pinned dirty lane buffer (IO in progress)" '^[1-9]' "$out"

	seq=$(sess_send C 9 "SELECT memcow_lane_reset($dboid, 60000)")
	if wait_for_wait_event "$pid_c" ProcSignalBarrier 20; then
		ck "the reset waits at the BARRIER for the parked checkpointer" 0
	else
		ck "the reset waits at the BARRIER for the parked checkpointer" 1
	fi
	st=$(psql_ctl -c "SELECT epoch || '|' || reclaim_pending || '|' || writes_discarded FROM memcow_lane_status($dboid)")
	ck_eq "... having already PUBLISHED epoch 1, nothing discarded yet" '1|true|0' "$st"

	# release the checkpointer, one parked write at a time, until the reset
	# has returned; watch what the reset is waiting on meanwhile
	local wakes=0 sweep_waited=0 i=0 ev
	while ! sess_wait C "$seq" 1; do
		ev=$(psql_ctl -c "SELECT wait_event FROM pg_stat_activity WHERE pid = $ckpt")
		if [ "$ev" = memcow-checkpointer-writev ]; then
			ev=$(psql_ctl -c "SELECT wait_event FROM pg_stat_activity WHERE pid = $pid_c")
			[ "$ev" = BufferIo ] && sweep_waited=1
			wake_point memcow-checkpointer-writev >/dev/null
			wakes=$((wakes + 1))
		fi
		i=$((i + 1))
		[ $i -lt 60 ] || break
	done
	ck_eq "reset returned epoch 1 once the checkpointer's writes were all released" 1 "$(sess_output C "$seq")"
	sess_wait C2 "$seq2" 30 || ck "the checkpoint completed" 1
	if [ $wakes -ge 2 ]; then
		ck "the checkpointer parked on $wakes lane writes, one after absorbing the barrier" 0
	else
		ck "the checkpointer parked on at least two lane writes, got $wakes" 1
	fi
	ck_eq "the reset was seen waiting in the SWEEP (BufferIo) on a write the checkpointer held: DropDatabaseBuffers waits" 1 "$sweep_waited"
	st=$(psql_ctl -c "SELECT reclaim_pending || '|' || attached_old || '|' || writes_discarded FROM memcow_lane_status($dboid)")
	ck_eq "every write released after PUBLISH was DISCARDED (writes_discarded = $wakes), reclaim done" "false|0|$wakes" "$st"
	ck_eq "no lane buffer survives the sweep" 0 "$(lane_buffers "$dboid")"
	detach_point memcow-checkpointer-writev

	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(sess_query L 7 "SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1; SELECT 'bal', balance FROM public.accounts WHERE account_id = 1")
	ck_match "retained backend adopted epoch 1" '^1$' "$out"
	ck_match "epoch 1: the flushed events page is NOT in the new arena (seed row)" '^kind\|logout$' "$out"
	ck_nomatch "epoch 1: nor the accounts page" '^bal\|0$' "$out"
	out=$(psql -c "SELECT 'kind', kind FROM public.events WHERE event_id = 1")
	ck_match "fresh backend agrees" '^kind\|logout$' "$out"

	# --- variant 2: released BEFORE the reset -> lands in the old arena --------
	sess_query L 7 "UPDATE public.events SET kind = 'r4b' WHERE event_id = 1" >/dev/null
	attach_point memcow-checkpointer-writev wait "$dboid" >/dev/null
	seq2=$(sess_send C2 10 "CHECKPOINT")
	wait_for_wait_event "$ckpt" memcow-checkpointer-writev 30 || ck "variant 2: checkpointer parked" 1
	wake_until_done C2 "$seq2" memcow-checkpointer-writev 30 || ck "variant 2: checkpoint completed" 1
	detach_point memcow-checkpointer-writev
	st=$(psql_ctl -c "SELECT writes_discarded FROM memcow_lane_status($dboid)")
	ck_eq "variant 2: nothing more discarded (the write landed in epoch 1's arena)" "$wakes" "$st"
	sess_query L 7 "DISCARD ALL" >/dev/null
	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 5000)")
	ck_eq "variant 2: reset -> epoch 2 discards the arena" 2 "$out"
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(sess_query L 7 "SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1")
	ck_match "variant 2: epoch 2 sees the seed row" '^kind\|logout$' "$out"

	sess_close C2 10
	sess_close C 9
	sess_close L 7
	ck_no_crash
}

# The sabotage: the discard window switched off (memcow-writev-skip-discard).
# The checkpointer, released after PUBLISH and attached to epoch 1, then
# stores the epoch-0 page INTO THE NEW ARENA, and after adopt every backend
# reads 'r4' at epoch 1 -- the cross-epoch artifact finding 2 closed.  The
# case's "seed row after reset" assertion must fail here.
nc_R4_checkpoint_discard()
{
	EXTRA_GUCS=(bgwriter_lru_maxpages=0)
	restart || { EXTRA_GUCS=(); ck "server started" 1; return; }
	EXTRA_GUCS=()
	ensure_memcow
	ensure_injection_points "$CONTROL_DB"
	local dboid out pid_l pid_c seq seq2 ckpt
	dboid=$(lane_oid)
	ckpt=$(checkpointer_pid)
	sess_open L 7
	pid_l=$(sess_query L 7 "SELECT pg_backend_pid()")
	psql_ctl -c "SELECT memcow_lane_register($dboid, $pid_l)" >/dev/null
	sess_open C 9 "$CONTROL_DB"
	pid_c=$(sess_query C 9 "SELECT pg_backend_pid()")
	sess_open C2 10 "$CONTROL_DB"
	psql_ctl -c "CHECKPOINT" >/dev/null
	sess_query L 7 "UPDATE public.events SET kind = 'r4' WHERE event_id = 1" >/dev/null
	attach_point memcow-writev-skip-discard notice >/dev/null
	attach_point memcow-checkpointer-writev wait "$dboid" >/dev/null
	seq2=$(sess_send C2 10 "CHECKPOINT")
	wait_for_wait_event "$ckpt" memcow-checkpointer-writev 30 || ck "checkpointer parked" 1
	seq=$(sess_send C 9 "SELECT memcow_lane_reset($dboid, 60000)")
	wait_for_wait_event "$pid_c" ProcSignalBarrier 20 || ck "reset at the barrier" 1
	wake_until_done C "$seq" memcow-checkpointer-writev 60 || ck "reset completed" 1
	sess_wait C2 "$seq2" 30 || true
	detach_point memcow-checkpointer-writev
	detach_point memcow-writev-skip-discard
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(sess_query L 7 "SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1")
	ck_match "sabotage detected: without the discard window the flush landed in the NEW arena (cross-epoch artifact 'r4' at epoch 1)" \
		'^kind\|r4$' "$out"
	sess_close C2 10; sess_close C 9; sess_close L 7
	ck_no_crash
}

# ===========================================================================
# R5 -- §7.3 (e): sinval for a nailed catalog delivered to parked pool
#      backends between PUBLISH and the barrier (plan Appendix B(h))
#
# Two registered backends sit idle through a reset parked right after PUBLISH
# (memcow-lane-reset-after-publish).  A relcache invalidation for a nailed
# SHARED catalog is queued -- CREATE ROLE then VACUUM (ANALYZE) pg_authid
# changes its reltuples, an in-place pg_class update whose relcache inval
# carries dbId 0 (inval.c: relisshared -> InvalidOid), delivered to every
# database -- and a catchup interrupt is sent to both backends so they
# process it while idle.
#
# ONE FACT ABOUT THE ENGINE, LOAD-BEARING FOR THIS TEST: catchup MARKS the
# nailed entry invalid but does NOT read pg_class for it.  An UNUSED nailed
# relation (refcnt == 1) takes RelationInvalidateRelation() in
# RelationFlushRelation(), which only sets rd_isvalid = false; the pg_class
# read (RelationReloadNailed) is DEFERRED to the entry's next open.  So the
# sinval arms the reload and the backend's next catalog touch performs it.
# This test makes that touch happen deterministically, still inside the
# publish->barrier window, by asking each parked backend for the pg_authid
# count: that reopens pg_authid, RelationReloadNailed() reads the LANE's
# pg_class, and -- because the barrier has not run, the backend has not
# adopted -- it creates buffers tagged with the lane after PUBLISH.  Those
# buffers are the hazard.  Every lane buffer is evicted first, so their
# reappearance is unambiguous; then the reset is released (barrier, SWEEP)
# and NONE may survive the buffer-pool scan.  The negative control shows the
# CONTENT half: a pre-publish epoch-0 page left resident is read stale by a
# fresh backend when the sweep is skipped.
# ===========================================================================

R5_sinval_nailed()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	ensure_injection_points "$CONTROL_DB"
	ensure_pg_buffercache
	local dboid out pid_a pid_b pid_c seq n i
	dboid=$(lane_oid)

	sess_open A 7; sess_open B 8
	pid_a=$(sess_query A 7 "SELECT pg_backend_pid()")
	pid_b=$(sess_query B 8 "SELECT pg_backend_pid()")
	psql_ctl -c "SELECT memcow_lane_register($dboid, $pid_a), memcow_lane_register($dboid, $pid_b)" >/dev/null
	out=$(sess_query A 7 "UPDATE public.events SET kind = 'r5' WHERE event_id = 1; CREATE TABLE r5_tbl(x int); INSERT INTO r5_tbl VALUES (1); SELECT count(*) FROM pg_authid; CHECKPOINT; SELECT 'ok'")
	ck_match "epoch 0: catalog and data pages written and flushed" '^ok$' "$out"
	# both backends open pg_authid (a nailed SHARED catalog) so the sinval below
	# reaches them; reading pg_class warms their nailed pg_class too
	sess_query B 8 "SELECT count(*) FROM pg_authid; SELECT count(*) FROM pg_class; SELECT count(*) FROM public.events" >/dev/null
	sess_open C 9 "$CONTROL_DB"
	pid_c=$(sess_query C 9 "SELECT pg_backend_pid()")

	attach_point memcow-lane-reset-after-publish wait >/dev/null
	seq=$(sess_send C 9 "SELECT memcow_lane_reset($dboid, 60000)")
	if wait_for_wait_event "$pid_c" memcow-lane-reset-after-publish 20; then
		ck "reset parked after PUBLISH, before the barrier" 0
	else
		ck "reset parked after PUBLISH, before the barrier" 1
	fi
	ck_eq "epoch 1 is published, reclaim pending" '1|true' \
		"$(psql_ctl -c "SELECT epoch || '|' || reclaim_pending FROM memcow_lane_status($dboid)")"

	# Make the rebuild observable: evict EVERY lane buffer.  (pg_class is a
	# MAPPED catalog, so its buffer tag carries a relmap filenode, not its OID
	# 1259 -- filtering on 1259 would evict nothing and see nothing; the count
	# of all buffers tagged with the lane is the honest instrument.)  Any lane
	# buffer that appears after this, while the reset is parked, was created
	# after PUBLISH.
	psql_ctl -c "SELECT count(*) FROM (SELECT pg_buffercache_evict(bufferid) FROM pg_buffercache WHERE reldatabase = $dboid) s" >/dev/null
	ck_eq "every lane buffer evicted while the reset is parked" 0 "$(lane_buffers "$dboid")"

	# the sinval: change a nailed SHARED catalog's stats so a relcache inval
	# (dbId 0, delivered to every database) is queued for pg_authid
	out=$(psql_ctl -c "CREATE ROLE r5_role_a" -c "CREATE ROLE r5_role_b" -c "CREATE ROLE r5_role_c" \
		-c "VACUUM (ANALYZE) pg_authid" -c "SELECT 'sent'")
	ck_match "nailed-catalog invalidation queued" '^sent$' "$out"
	out=$(psql_ctl -c "SELECT memcow_lane_catchup($pid_a), memcow_lane_catchup($pid_b)")
	ck_nomatch "catchup interrupts delivered to both parked backends" 'ERROR' "$out"
	# catchup marks the nailed pg_authid invalid but defers the pg_class read
	# (unused nailed rel); still no lane buffers yet
	sleep 0.5
	ck_eq "catchup alone reads nothing (the nailed reload is deferred)" 0 "$(lane_buffers "$dboid")"
	# the parked backends' next catalog touch performs the deferred reload,
	# reading the LANE's pg_class in the publish->barrier window
	sess_query A 7 "SELECT count(*) FROM pg_authid" >/dev/null
	sess_query B 8 "SELECT count(*) FROM pg_authid" >/dev/null
	n=$(lane_buffers "$dboid")
	if [ "${n:-0}" -gt 0 ]; then
		ck "the nailed reload read the lane's pg_class: $n lane buffer(s) created after PUBLISH, before the barrier" 0
	else
		ck "the nailed reload read the lane's pg_class: lane buffers created after PUBLISH" 1
	fi

	wake_point memcow-lane-reset-after-publish >/dev/null
	sess_wait C "$seq" 60 || ck "the reset completed" 1
	ck_eq "reset returned epoch 1" 1 "$(sess_output C "$seq")"
	detach_point memcow-lane-reset-after-publish
	ck_eq "BUFFER-POOL SCAN: no buffer tagged with the lane survives the post-barrier sweep" 0 "$(lane_buffers "$dboid")"
	ck_eq "no old-arena attachment after the reset returned" 0 "$(lane_status "$dboid" attached_old)"

	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(sess_query A 7 "SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1; SELECT 'tbl', count(*) FROM pg_class WHERE relname = 'r5_tbl'")
	ck_match "A adopted epoch 1" '^1$' "$out"
	ck_match "A: the seed row is back" '^kind\|logout$' "$out"
	ck_match "A: the epoch-0 relation is gone" '^tbl\|0$' "$out"
	out=$(sess_query B 8 "SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1")
	ck_match "B adopted epoch 1 and sees the seed row" '^kind\|logout$' "$out"
	out=$(psql -c "SELECT 'kind', kind FROM public.events WHERE event_id = 1; SELECT 'tbl', count(*) FROM pg_class WHERE relname = 'r5_tbl'")
	ck_match "fresh backend: the seed row" '^kind\|logout$' "$out"
	ck_match "fresh backend: no epoch-0 relation" '^tbl\|0$' "$out"

	psql_ctl -c "DROP ROLE IF EXISTS r5_role_a, r5_role_b, r5_role_c" >/dev/null
	sess_close C 9; sess_close B 8; sess_close A 7
	ck_no_crash
}

# The sabotage: the SWEEP switched off (memcow-lane-skip-sweep).  Every
# buffer tagged with the lane survives the reset, the scan finds them, and
# the epoch-0 'events' page -- flushed clean by the CHECKPOINT and never
# evicted -- is a buffer hit for a fresh backend at epoch 1: it reads 'r5'.
# The case's scan assertion must fail here, and the artifact is visible.
nc_R5_sinval_nailed()
{
	restart || { ck "server started" 1; return; }
	ensure_memcow
	ensure_injection_points "$CONTROL_DB"
	ensure_pg_buffercache
	local dboid out pid_a
	dboid=$(lane_oid)
	sess_open A 7
	pid_a=$(sess_query A 7 "SELECT pg_backend_pid()")
	psql_ctl -c "SELECT memcow_lane_register($dboid, $pid_a)" >/dev/null
	sess_query A 7 "UPDATE public.events SET kind = 'r5' WHERE event_id = 1; CHECKPOINT;" >/dev/null
	attach_point memcow-lane-skip-sweep notice >/dev/null
	out=$(psql_ctl -c "SELECT memcow_lane_reset($dboid, 5000)")
	ck_eq "reset -> epoch 1 (sweep skipped)" 1 "$out"
	detach_point memcow-lane-skip-sweep
	ck_match "sabotage detected: lane buffers survived the reset" '^[1-9]' "$(lane_buffers "$dboid")"
	psql_ctl -c "SELECT memcow_lane_open($dboid, false)" >/dev/null
	out=$(psql -c "SELECT 'kind', kind FROM public.events WHERE event_id = 1")
	ck_match "sabotage detected: a fresh backend reads the epoch-0 page from a surviving buffer (cross-epoch artifact)" \
		'^kind\|r5$' "$out"
	sess_close A 7
	ck_no_crash
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
