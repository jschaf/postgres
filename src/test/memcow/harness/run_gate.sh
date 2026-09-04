#!/bin/sh
#
# run_gate.sh -- the phase-gate entry point that ci.sh (Phase 0c) invokes.
#
# Contract (fixed by src/test/memcow/build/ci.sh):
#     run_gate.sh --phase <N> --build-dir <abs> --source-dir <abs> [extra...]
#     exit 0 = gate PASS, non-zero = gate FAIL
#
# This adapter exists because the harness (0b) and the CI driver (0c) were
# written in parallel against interfaces that were never reconciled; 0c
# defined this contract, 0b implemented the gate itself as diff_engines.sh.
#
# Numbering: ci.sh's own "--phase 0" is a configure+build precheck that never
# reaches this script.  Here, phase 0 means the PLAN's Phase 0 gate -- "stock
# postgres passes the harness against itself", i.e. a stock-vs-stock
# differential run that must produce zero diffs.
#
# Phase 1 is the plan's falsification slice.  Phase 2 is the lane reset
# (plan §7.2).  Phase 3 is the pool, the races and the pool-driven soak
# (plan §3, §7.3).  Phase 4 is the benchmarks (plan §7.4) and the Appendix
# A.4 answers, run by harness/bench.sh over bench/; see PHASE 4 below.
#
# ---------------------------------------------------------------------------
# PHASE 4, and what it does and does not prove
# ---------------------------------------------------------------------------
#
# §7.4's gate is: "lease->first-parameterized-query p99 < 1 ms over 100k
# leases with ready capacity; reset (quiesce->ready, including warmup) p99
# < 25 ms at shared_buffers=512MB, including the global SMGRRELEASE barrier
# under concurrent busy lanes (absorption latency measured explicitly);
# zero leakage."  Held on the cassert build (progress.md open problem 2,
# option (a)).  So phase 4 runs, and requires all of:
#
#   (1) the harness's own negative controls, first: one cost term inflated
#       on purpose (the cycle, client-side, for the lease driver; the sweep
#       step, via the memcow-lane-reset-in-sweep injection point, for the
#       reset driver), and the driver must miss its threshold AND attribute
#       the miss to that term;
#   (2) bench/bench_lease.py: 100,000 leases, resets on resetter threads so
#       that a lease waits only when every lane is mid-reset (and every such
#       wait is recorded), plus the same at a fifth the length through the
#       DDL+DML workload and read-only, for A.4 (2);
#   (3) bench/bench_reset.py at 512MB: idle neighbours, six busy lanes on
#       the DDL+DML workload, six busy lanes running a tight plpgsql loop
#       (the CFI-starved case), each cycle attributed step by step from
#       memcow_lane_reset_timings(); and, informationally, a neighbour that
#       holds interrupts for 200 ms, which is the global barrier's worst
#       case;
#   (4) bench/a4_summary.py: the five Appendix A.4 triggers, each answered
#       from those numbers by a stated rule.
#
# Zero leakage is checked inside every run (DSM segment count after a
# warm-up, PGDATA-minus-WAL, pg_aios, pinned buffers, descriptors and DSM
# mappings of the long-lived processes, the cassert leak WARNINGs).
#
# ---------------------------------------------------------------------------
# PHASE 3, and what it does and does not prove
# ---------------------------------------------------------------------------
#
# §7.3's gate is the five deterministic races (a)-(e), each with a negative
# control, plus -- because the pool now exists -- §7.2's soak driven through
# it.  So phase 3 runs, and requires all of:
#
#   (1) slice/slice_tests.sh --phase 3: S15 (the authentication-time fence,
#       plan §5 I2 fence 2 of 3), S16 (the per-lane arena limit, CONCERN 4a)
#       and R1-R5, the §7.3 races (a)-(e) made deterministic with injection
#       points and SIGSTOP;
#   (2) the same seven under --negative-control;
#   (3) harness/pool_soak.sh, the §7.2 loop through pool/memcow_pool.py with
#       the same per-reset verifications as reset_soak.sh, MEMCOW_SOAK_ITERATIONS
#       resets (default 10000; fewer is a smoke run and the summary says so).
#
# It does NOT run phases 1-2 again.  Phase 3 changed the engine (auth fence,
# fence timeout leaves the lane closed, poison on reclaim, arena limit, the
# checkpointer injection point in writev), so both must be re-run after it;
# separate invocations on purpose, so that each verdict is attributable.
#
# ---------------------------------------------------------------------------
# PHASE 2, and what it does and does not prove
# ---------------------------------------------------------------------------
#
# §7.2's gate is: "memcow_lane_reset + memcow_backend_reset + minimal pool on
# one lane.  Loop 10,000 x {DDL+DML workload -> reset -> seed-hash verify +
# differential query}.  Verify per reset: attach-count(old epoch) == 0, DSM
# slot count and RAM-dir size flat, pg_filenode.map byte-stable,
# CountDBBackends gate exercised.  Fail = any cross-epoch artifact, any
# monotonic DSM/slot growth, any leaked AIO resource."  So phase 2 runs, and
# requires all of:
#
#   (1) slice/slice_tests.sh --phase 2: S11-S14, the reset's falsification
#       slice, written before the reset was;
#   (2) the same four under --negative-control, because a reset test that
#       has never failed is not known to measure anything;
#   (3) harness/reset_soak.sh, the §7.2 loop itself, with
#       MEMCOW_SOAK_ITERATIONS resets (default 10000; lower it for a smoke
#       run, but a gate result recorded with fewer than 10000 is not the
#       §7.2 gate and the summary says so).
#
# It does NOT run the phase 1 matrix again.  Phase 2 changed the engine
# (memcow_close detaches, smgrreleaseall calls memcow, writev has a discard
# window), so phase 1 must be re-run after it too; that is a separate gate
# invocation on purpose, so that each verdict is attributable.
#
# ---------------------------------------------------------------------------
# PHASE 1, and what it does and does not prove
# ---------------------------------------------------------------------------
#
# §7.1's gate is: "regression subset zero diffs; sync + worker (+ io_uring
# where available) x cold/hot x temp tables -- zero asserts, zero AIO/pin
# leaks", plus four memcow-specific tests with no md counterpart.  So phase 1
# runs two things and requires both:
#
#   (1) io_matrix.sh, with side A = stock md and side B = THE SAME BINARY with
#       memcow_enabled=on.  A runs on a PGDATA holding the seed's relation
#       files; B runs on one holding none, so a page B serves cannot have come
#       from md.
#   (2) slice/slice_tests.sh -- the memcow-specific cases.
#
# Two things this gate reports and must never hide:
#
#   * io_uring DOES NOT EXIST ON macOS.  Four of the twelve matrix cells are
#     enumerated as UNAVAILABLE with the reason and are neither passed nor
#     skipped.  A green phase 1 here therefore means "PASS on the macOS cells,
#     io_uring UNVERIFIED", and the summary says exactly that.  Pass
#     --require-io-uring on a Linux runner to turn the gap into a failure.
#
#   * autovacuum=off is a plan §6 precondition and it deterministically
#     diverges `cluster` from UPSTREAM EXPECTED OUTPUT --
#     index_update_stats() skips updating relpages/reltuples when
#     !AutoVacuumingActive() (catalog/index.c:2896-2908), so the planner
#     chooses differently.  This is handled with --allow-expected-failure
#     cluster, which relaxes only the comparison against expected/ (G3) and
#     NEVER the A-vs-B comparison (G1/G2) that is what memcow is actually being
#     judged on.
#
#     assemble_ramdir.sh's full_page_writes=off and synchronous_commit=off have
#     the same character and were found the same way (see the SEED_GUCS note
#     below); they are overridden rather than allowed, because unlike
#     autovacuum they are not preconditions of anything.
#
# Phase 1 needs a seed and an assembled RAM dir, which it will NOT build for
# you: they take minutes, they need a RAM disk, and silently rebuilding either
# one under a gate is how you end up testing a stale artifact.  Pass
# --seed/--pgdata (or set MEMCOW_SEED_DIR/MEMCOW_RAM_MOUNT) and build them with
#     src/test/memcow/seed/build_seed.sh -b <bindir> -o <seed> -f
#     src/test/memcow/seed/assemble_ramdir.sh -s <seed> -m <mount>
# NOTE that the seed fingerprint pins the postgres binary: build the seed with
# the binary the gate will run, and rebuild it after any rebuild.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
slice=$(CDPATH= cd -- "$here/../slice" && pwd)

phase=
build_dir=
source_dir=
seed=${MEMCOW_SEED_DIR:-}
ram_mount=${MEMCOW_RAM_MOUNT:-}
pgdata=
subset=phase0
extra_args=

while [ $# -gt 0 ]; do
	case $1 in
	--phase)      phase=$2;      shift 2 ;;
	--phase=*)    phase=${1#*=};  shift ;;
	--build-dir)  build_dir=$2;  shift 2 ;;
	--build-dir=*) build_dir=${1#*=}; shift ;;
	--source-dir) source_dir=$2; shift 2 ;;
	--source-dir=*) source_dir=${1#*=}; shift ;;
	--seed)       seed=$2; shift 2 ;;
	--seed=*)     seed=${1#*=}; shift ;;
	--ram-mount)  ram_mount=$2; shift 2 ;;
	--ram-mount=*) ram_mount=${1#*=}; shift ;;
	--pgdata)     pgdata=$2; shift 2 ;;
	--pgdata=*)   pgdata=${1#*=}; shift ;;
	--subset)     subset=$2; shift 2 ;;
	--subset=*)   subset=${1#*=}; shift ;;
	--) shift; extra_args="$*"; break ;;
	*)  extra_args="${extra_args} $1"; shift ;;
	esac
done

[ -n "$phase" ] || { echo "run_gate.sh: --phase is required" >&2; exit 2; }
[ -n "$build_dir" ] || { echo "run_gate.sh: --build-dir is required" >&2; exit 2; }

: "${MEMCOW_GATE_WORKDIR:=${TMPDIR:-/tmp}/memcow-gate}"

need_seed_and_pgdata()
{
	[ -n "$seed" ] || {
		cat >&2 <<'MSG'
run_gate.sh: phase $phase needs a seed.

    Pass --seed DIR (or set MEMCOW_SEED_DIR).  Build it with the SAME binary
    the gate will run -- the seed fingerprint pins the postgres binary's size
    and SHA-256, and a stale seed is a startup FATAL, not a subtle failure:

        src/test/memcow/seed/build_seed.sh -b <bindir> -o <seed> -f
MSG
		exit 2
	}
	[ -d "$seed" ] || { echo "run_gate.sh: no such seed directory: $seed" >&2; exit 2; }

	# The harness connects as $PGUSER, or as the OS user when it is unset,
	# and neither slice_tests.sh nor the matrix passes -U.  The seed's
	# bootstrap superuser is whatever build_seed.sh -u said (default
	# "postgres"), recorded in the fingerprint; default to it, so that a
	# mismatch can only come from someone asking for a different user on
	# purpose.  Without this every case fails with 'role "..." does not
	# exist', which looks like an engine failure and is not.
	if [ -z "${PGUSER:-}" ] && [ -f "$seed/memcow_seed.fingerprint" ]; then
		PGUSER=$(sed -n 's/^seed_superuser=//p' "$seed/memcow_seed.fingerprint")
		if [ -n "$PGUSER" ]; then
			export PGUSER
			echo "run_gate.sh: connecting as the seed's superuser: $PGUSER"
		fi
	fi

	if [ -z "$pgdata" ]; then
		[ -n "$ram_mount" ] || {
			cat >&2 <<'MSG'
run_gate.sh: phase $phase needs an assembled runtime PGDATA.

    Pass --pgdata DIR, or --ram-mount DIR (or set MEMCOW_RAM_MOUNT) and the
    PGDATA is taken to be <mount>/pgdata.  Assemble it with:

        src/test/memcow/seed/assemble_ramdir.sh -s <seed> -m <mount>
MSG
			exit 2
		}
		pgdata="$ram_mount/pgdata"
	fi
	[ -n "$ram_mount" ] || ram_mount=$(dirname -- "$pgdata")
	[ -f "$pgdata/PG_VERSION" ] ||
		{ echo "run_gate.sh: not a data directory: $pgdata" >&2; exit 2; }

}

case $phase in
0)
	# Plan Phase 0 gate: the harness must show stock md agreeing with itself.
	echo "run_gate.sh: phase 0 -- stock-vs-stock differential (must be zero diffs)"
	mkdir -p "$MEMCOW_GATE_WORKDIR"
	# shellcheck disable=SC2086
	exec "$here/diff_engines.sh" \
		--outputdir "$MEMCOW_GATE_WORKDIR/phase0" \
		--pgdata-template "$MEMCOW_GATE_WORKDIR/phase0-template" --init \
		--build-dir "$build_dir" \
		--subset phase0 \
		$extra_args
	;;
1)
	echo "run_gate.sh: phase 1 -- the plan's falsification slice"

	need_seed_and_pgdata

	work="$MEMCOW_GATE_WORKDIR/phase1"
	mkdir -p "$work"

	# --- templates ------------------------------------------------------
	echo "run_gate.sh: phase 1 -- building the A (stock md) and B (memcow) templates"
	if ! "$slice/make_templates.sh" --seed "$seed" --ramdir "$pgdata" \
		--outdir "$work/templates" >"$work/make_templates.log" 2>&1
	then
		echo "run_gate.sh: could not build the PGDATA templates:" >&2
		cat "$work/make_templates.log" >&2
		exit 2
	fi
	sed -n 's/^MEMCOW_TPL_/TPL_/p' "$work/make_templates.log" >"$work/templates.env"
	# shellcheck disable=SC1090
	. "$work/templates.env"

	rc=0

	# --- (1) the differential matrix ------------------------------------
	#
	# SEED_GUCS: assemble_ramdir.sh writes full_page_writes=off and
	# synchronous_commit=off into the RAM dir for speed.  Both change core
	# regression output in ways that have nothing to do with memcow and would
	# otherwise have to be waved through as allowances on BOTH sides:
	#   synchronous_commit=off -> `sequence` sees page_lsn > pg_current_wal_lsn()
	#   full_page_writes=off   -> `temp` fails "no empty local buffer available"
	# Both were bisected, both are deterministic, and both are free to undo on
	# a cluster that already has fsync=off, so the gate turns them back on for
	# BOTH sides rather than lowering the bar.
	#
	# autovacuum stays off: it IS a §6 precondition, so `cluster` gets the
	# named G3-only allowance instead.
	#
	# The --allow-engine-divergence list is DERIVED, not guessed.  It is
	# exactly the phase0 tests whose SQL calls one of the smgr-bypassing size
	# functions:
	#     grep -lE 'pg_(relation|table|indexes|total_relation|database)_size' \
	#         src/test/regress/sql/*.sql
	# intersected with subsets/phase0.txt -> insert, temp, vacuum,
	# vacuum_parallel.  `tablespace` used to be a fifth, for a different and
	# more serious reason: DROP TABLESPACE decided emptiness by scanning the
	# tablespace directory, which under memcow never holds a relation file, so
	# the DROP succeeded where md refuses.  DropTableSpace() now consults
	# memcow_tablespace_in_use() first, the regress `tablespace` test is
	# byte-identical between engines again, and the allowance is gone -- the
	# stale-allowance check below would fail the gate if it were still here.
	# Slice case S9 pins the refusal.
	#
	# Every hunk in those four still has to be matched by a rule in
	# divergences.txt, and an allowance whose test runs WITHOUT diverging
	# fails the gate, so the list cannot rot silently in either direction.
	# Re-derive it if the subset changes.
	set -- \
		--outputdir "$work/matrix" \
		--a-pgdata-template "$TPL_MD" \
		--b-pgdata-template "$TPL_MEMCOW" \
		--build-dir "$build_dir" \
		--subset "$subset" \
		--a-name a-md --b-name b-memcow \
		--b-guc memcow_enabled=on \
		--b-guc "memcow_seed_directory=$seed" \
		--guc synchronous_commit=on \
		--guc full_page_writes=on \
		--guc autovacuum=off \
		--allow-expected-failure cluster \
		--allow-engine-divergence insert \
		--allow-engine-divergence temp \
		--allow-engine-divergence vacuum \
		--allow-engine-divergence vacuum_parallel
	# shellcheck disable=SC2086
	if "$here/io_matrix.sh" "$@" $extra_args; then
		matrix=PASS
	else
		matrix=FAIL
		rc=1
	fi

	# --- (2) the memcow-specific slice tests -----------------------------
	if "$slice/slice_tests.sh" \
		--seed "$seed" --pgdata "$pgdata" --ram-mount "$ram_mount" \
		--build-dir "$build_dir" --outputdir "$work/slice"
	then
		slice_result=PASS
	else
		slice_result=FAIL
		rc=1
	fi

	uring=UNVERIFIED
	case " $extra_args " in *" --require-io-uring "*) uring=REQUIRED ;; esac
	if grep -q '^MATRIX COVERAGE: COMPLETE' "$work/matrix/summary.txt" 2>/dev/null; then
		uring=COVERED
	fi

	# The io_uring paragraph is written from what the matrix REPORTED, not
	# from uname: a Linux build without liburing is as incomplete as macOS,
	# and only "MATRIX COVERAGE: COMPLETE" in summary.txt means all twelve
	# cells ran.
	if [ "$uring" = COVERED ]; then
		uring_text="  io_uring:  all 12 matrix cells ran on $(uname -s) $(uname -r); the
             io_uring cells are included in the matrix verdict above.
             Note what that does and does not show: io_uring is the only
             io_method with wait_one/check_one, so these cells are the
             only ones on which pgaio_io_complete_synthetic()'s
             PGAIO_HF_SYNCHRONOUS flag is live at all -- but a green cell
             is still only evidence that nothing raced into the window
             the flag guards.  The flag itself is pinned by
             src/test/modules/test_aio/t/005_synthetic_completion.pl
             (concurrent-waiter subtest); run that suite on this host too."
	else
		uring_text="  io_uring:  this build offers no io_uring io_method ($(uname -s): no
             liburing), so 4 of the 12 matrix cells are ENUMERATED AS
             UNAVAILABLE and were not run.  Phase 1 on this host is
             therefore, at best,
                 \"PASS on the available cells, io_uring UNVERIFIED\"
             and must not be recorded as a full Phase 1 pass.  In
             particular pgaio_io_complete_synthetic()'s
             PGAIO_HF_SYNCHRONOUS flag is dead code here: io_uring is the
             only io_method with wait_one/check_one, so every green cell
             above is equally consistent with that flag being absent.
             See progress.md open problem 3 for what a Linux runner owes."
	fi

	cat <<MSG

========================================================================
PHASE 1 GATE
------------------------------------------------------------------------
  differential matrix (io_method x cold/hot x temp, A=md B=memcow) : $matrix
  memcow slice tests (plan §7.1 items 1-4 plus the findings)       : $slice_result
------------------------------------------------------------------------
$uring_text
  autovacuum=off (plan §6) diverges \`cluster\` from upstream expected
             output by way of index_update_stats() (index.c:2896-2908);
             carried as --allow-expected-failure, which never relaxes the
             A-vs-B comparison.
  artifacts: $work
========================================================================
MSG

	if [ $rc -eq 0 ]; then
		if [ "$uring" = COVERED ]; then
			echo "GATE PASS (phase 1, all 12 matrix cells; io_uring $uring)"
		else
			echo "GATE PASS (phase 1, available cells only; io_uring $uring)"
		fi
	else
		echo "GATE FAIL (phase 1)"
	fi
	exit $rc
	;;
2)
	echo "run_gate.sh: phase 2 -- lane reset (plan §7.2)"
	need_seed_and_pgdata

	work="$MEMCOW_GATE_WORKDIR/phase2"
	mkdir -p "$work"
	rc=0

	# --- (1) the reset slice cases -------------------------------------
	if "$slice/slice_tests.sh" \
		--seed "$seed" --pgdata "$pgdata" --ram-mount "$ram_mount" \
		--build-dir "$build_dir" --outputdir "$work/slice" --phase 2
	then
		slice_result=PASS
	else
		slice_result=FAIL
		rc=1
	fi

	# --- (2) their negative controls -----------------------------------
	if "$slice/slice_tests.sh" \
		--seed "$seed" --pgdata "$pgdata" --ram-mount "$ram_mount" \
		--build-dir "$build_dir" --outputdir "$work/slice-nc" --phase 2 \
		--negative-control
	then
		nc_result=PASS
	else
		nc_result=FAIL
		rc=1
	fi

	# --- (3) the soak --------------------------------------------------
	iterations=${MEMCOW_SOAK_ITERATIONS:-10000}
	if "$here/reset_soak.sh" \
		--seed "$seed" --pgdata "$pgdata" --ram-mount "$ram_mount" \
		--build-dir "$build_dir" --outputdir "$work/soak" \
		--iterations "$iterations"
	then
		soak_result=PASS
	else
		soak_result=FAIL
		rc=1
	fi
	if [ "$iterations" -lt 10000 ]; then
		soak_note="  NOTE: MEMCOW_SOAK_ITERATIONS=$iterations is below §7.2's 10,000.
             This run is a smoke run, not the §7.2 gate."
	else
		soak_note=
	fi

	cat <<MSG

========================================================================
PHASE 2 GATE
------------------------------------------------------------------------
  reset slice cases S11-S14                                        : $slice_result
  their negative controls (each case must FAIL when sabotaged)     : $nc_result
  reset soak, $iterations resets (plan §7.2)                          : $soak_result
------------------------------------------------------------------------
${soak_note:+$soak_note
}  not re-run here: the phase 1 matrix.  Phase 2 changed the engine, so
             run --phase 1 again after it; a green phase 2 alone is not a
             green phase 1.
  artifacts: $work
========================================================================
MSG

	if [ $rc -eq 0 ]; then
		if [ "$iterations" -lt 10000 ]; then
			echo "GATE PASS (phase 2, SMOKE: $iterations resets, not the §7.2 gate)"
		else
			echo "GATE PASS (phase 2, $iterations resets)"
		fi
	else
		echo "GATE FAIL (phase 2)"
	fi
	exit $rc
	;;
3)
	echo "run_gate.sh: phase 3 -- pool, races (plan §7.3), pool-driven soak"
	need_seed_and_pgdata

	work="$MEMCOW_GATE_WORKDIR/phase3"
	mkdir -p "$work"
	rc=0

	# --- (1) the auth fence, the arena limit, the five races ---------------
	if "$slice/slice_tests.sh" \
		--seed "$seed" --pgdata "$pgdata" --ram-mount "$ram_mount" \
		--build-dir "$build_dir" --outputdir "$work/slice" --phase 3
	then
		slice_result=PASS
	else
		slice_result=FAIL
		rc=1
	fi

	# --- (2) their negative controls -------------------------------------
	if "$slice/slice_tests.sh" \
		--seed "$seed" --pgdata "$pgdata" --ram-mount "$ram_mount" \
		--build-dir "$build_dir" --outputdir "$work/slice-nc" --phase 3 \
		--negative-control
	then
		nc_result=PASS
	else
		nc_result=FAIL
		rc=1
	fi

	# --- (3) the soak, through the pool ------------------------------------
	iterations=${MEMCOW_SOAK_ITERATIONS:-10000}
	if "$here/pool_soak.sh" \
		--seed "$seed" --pgdata "$pgdata" --ram-mount "$ram_mount" \
		--build-dir "$build_dir" --outputdir "$work/pool-soak" \
		--iterations "$iterations"
	then
		soak_result=PASS
	else
		soak_result=FAIL
		rc=1
	fi
	if [ "$iterations" -lt 10000 ]; then
		soak_note="  NOTE: MEMCOW_SOAK_ITERATIONS=$iterations is below §7.2's 10,000.
             This run is a smoke run, not the §7.2 gate."
	else
		soak_note=
	fi
	latency=$(grep '^resets:' "$work/pool-soak/"*.log 2>/dev/null | tail -1)
	[ -n "$latency" ] || latency=$(python3 -c "
import json,sys
try:
    r=json.load(open('$work/pool-soak/report.json'))
    print('reset p50=%.1fms p99=%.1fms; cycle p50=%.1fms p99=%.1fms; lease->first query p50=%.2fms p99=%.2fms' % (
        r['reset_ms']['p50'], r['reset_ms']['p99'], r['cycle_ms']['p50'], r['cycle_ms']['p99'],
        r['lease_first_query_ms']['p50'], r['lease_first_query_ms']['p99']))
except Exception as e:
    print('(no report: %s)' % e)
" 2>/dev/null)

	cat <<MSG

========================================================================
PHASE 3 GATE
------------------------------------------------------------------------
  auth fence, arena limit, races R1-R5 (slice --phase 3)          : $slice_result
  their negative controls (each case must FAIL when sabotaged)     : $nc_result
  reset soak through the pool, $iterations resets (plan §7.2 via §3)  : $soak_result
------------------------------------------------------------------------
${soak_note:+$soak_note
}  latency (informational; §7.4 owns the thresholds, and this is the
             cassert build): $latency
  not re-run here: phases 1 and 2.  Phase 3 changed the engine, so run
             both again after it; a green phase 3 alone is not a green
             phase 1 or 2.
  artifacts: $work
========================================================================
MSG

	if [ $rc -eq 0 ]; then
		if [ "$iterations" -lt 10000 ]; then
			echo "GATE PASS (phase 3, SMOKE: $iterations resets, not the §7.2 gate)"
		else
			echo "GATE PASS (phase 3, $iterations resets through the pool)"
		fi
	else
		echo "GATE FAIL (phase 3)"
	fi
	exit $rc
	;;
4)
	echo "run_gate.sh: phase 4 -- the benchmarks (plan §7.4) and Appendix A.4"
	need_seed_and_pgdata

	work="$MEMCOW_GATE_WORKDIR/phase4"
	mkdir -p "$work"
	rc=0

	# The pool configuration the gate holds the thresholds at.  Chosen from
	# measurement (progress.md 2026-09-03, the lanes x resetters x K matrix,
	# 5000 light leases per cell on this cassert build), not from taste:
	#   1 resetter thread starves the ready queue at full lease rate (4 or
	#     8 lanes: ~4600 of 5000 leases found it empty, p99 4.2-4.5 ms,
	#     every miss attributed to the queue, 85% resetter utilisation);
	#   2 threads pass but are marginal (8 lanes: 32-45 waits, p99
	#     0.36-0.64 ms across two runs);
	#   3 threads on 8 lanes: 0-7 waits, p99 0.25-0.33 ms, ~37% utilised;
	#     a 4th adds nothing (p99 0.27).
	#   K: a backend's memory contexts are flat across epochs (2120 kB), so
	#     K is set by the recycle's tail alone: at K=50 recycles are 2% of
	#     cycles and sit inside the cycle p99 (7.6 vs 4.5 ms at K=200); at
	#     K=200 they are 0.5% and outside it.  100k leases at K=200 is ~500
	#     reconnects.
	# Override to re-measure, never to pass.
	lanes8=memcow_lane_00,memcow_lane_01,memcow_lane_02,memcow_lane_03,memcow_lane_04,memcow_lane_05,memcow_lane_06,memcow_lane_07
	lease_lanes=${MEMCOW_BENCH_LANES:-$lanes8}
	resetters=${MEMCOW_BENCH_RESETTERS:-3}
	retire_after=${MEMCOW_BENCH_RETIRE_AFTER:-200}
	leases=${MEMCOW_BENCH_LEASES:-100000}
	resets=${MEMCOW_BENCH_RESETS:-3000}
	sb=${MEMCOW_BENCH_SHARED_BUFFERS:-512MB}
	bench="$here/bench.sh --seed $seed --pgdata $pgdata --ram-mount $ram_mount --build-dir $build_dir --shared-buffers $sb"

	# --- (1) the negative controls FIRST: a benchmark that cannot fail ----
	# measures nothing.  Each inflates exactly one cost term and must FAIL
	# its threshold AND attribute the failure to that term.
	if $bench --outputdir "$work/nc-lease" --driver lease -- \
		--leases 3000 --lanes "$lease_lanes" --resetters "$resetters" \
		--retire-after "$retire_after" --workload light \
		--negative-control --resetter-delay-ms 30
	then nc_lease=BEHAVED; else nc_lease="DID NOT BEHAVE"; rc=1; fi
	if $bench --outputdir "$work/nc-reset" --driver reset -- \
		--resets 400 --lanes memcow_lane_00,memcow_lane_01 \
		--busy-lanes memcow_lane_02,memcow_lane_03 --busy-mode soak \
		--negative-control --nc-sweep-wait-ms 40
	then nc_reset=BEHAVED; else nc_reset="DID NOT BEHAVE"; rc=1; fi

	# --- (2) lease -> first parameterized query, 100k, with ready capacity -
	if $bench --outputdir "$work/lease-light" --driver lease -- \
		--leases "$leases" --lanes "$lease_lanes" --resetters "$resetters" \
		--retire-after "$retire_after" --workload light
	then lease_light=PASS; else lease_light=FAIL; rc=1; fi
	# the same through the soak (DDL+DML) workload, and read-only, for A.4 (2)
	if $bench --outputdir "$work/lease-soak" --driver lease -- \
		--leases $((leases / 5)) --lanes "$lease_lanes" --resetters "$resetters" \
		--retire-after "$retire_after" --workload soak
	then lease_soak=PASS; else lease_soak=FAIL; rc=1; fi
	# read-only, PACED: with no work at all between the first query and the
	# release, an unpaced driver leases at whatever rate the resetters can
	# recycle lanes and measures nothing but that rate (1199 leases/s, 435
	# of 1000 leases waited, in the first run).  Paced at 500/s -- below the
	# ~650/s the light run sustains -- it measures the lease path without
	# writes, which is what A.4 (2) compares against.
	if $bench --outputdir "$work/lease-query" --driver lease -- \
		--leases $((leases / 5)) --lanes "$lease_lanes" --resetters "$resetters" \
		--retire-after "$retire_after" --workload query --rate 500
	then lease_query=PASS; else lease_query=FAIL; rc=1; fi
	# and the writing workload at the SAME pace, so that A.4 (2) compares
	# writes against no writes and nothing else.  (The first gate run
	# compared the unpaced runs against the paced read-only one and the
	# rule fired on a +0.3..0.57 ms delta that three controlled repeats put
	# at -0.02 ms: the delta was rate and run-to-run tail, not writes.)
	if $bench --outputdir "$work/lease-light-paced" --driver lease -- \
		--leases $((leases / 5)) --lanes "$lease_lanes" --resetters "$resetters" \
		--retire-after "$retire_after" --workload light --rate 500
	then lease_light_paced=PASS; else lease_light_paced=FAIL; rc=1; fi

	# --- (3) reset p99 at 512MB under concurrent busy lanes ---------------
	busy6=memcow_lane_02,memcow_lane_03,memcow_lane_04,memcow_lane_05,memcow_lane_06,memcow_lane_07
	if $bench --outputdir "$work/reset-idle" --driver reset -- \
		--resets "$resets" --lanes memcow_lane_00,memcow_lane_01 \
		--retire-after "$retire_after" --label idle
	then reset_idle=PASS; else reset_idle=FAIL; rc=1; fi
	if $bench --outputdir "$work/reset-busy-soak" --driver reset -- \
		--resets "$resets" --lanes memcow_lane_00,memcow_lane_01 \
		--retire-after "$retire_after" --busy-lanes "$busy6" --busy-mode soak --label busy-soak
	then reset_soak=PASS; else reset_soak=FAIL; rc=1; fi
	if $bench --outputdir "$work/reset-busy-plpgsql" --driver reset -- \
		--resets "$resets" --lanes memcow_lane_00,memcow_lane_01 \
		--retire-after "$retire_after" --busy-lanes "$busy6" --busy-mode plpgsql --label busy-plpgsql
	then reset_plpgsql=PASS; else reset_plpgsql=FAIL; rc=1; fi
	# informational: a neighbour that holds interrupts is the global
	# barrier's worst case; reported, not gated (see A.4 item 3)
	if $bench --outputdir "$work/reset-hold" --driver reset -- \
		--resets 300 --lanes memcow_lane_00,memcow_lane_01 \
		--retire-after "$retire_after" --busy-lanes memcow_lane_02 --busy-mode hold \
		--hold-ms 200 --threshold-ms 100000 --label hold
	then reset_hold=MEASURED; else reset_hold=FAILED; fi

	# --- (4) Appendix A.4, from the numbers ---------------------------------
	a4="$work/a4"
	mkdir -p "$a4"
	cp "$work/lease-soak/report.json" "$a4/lease_soak.json" 2>/dev/null
	cp "$work/lease-query/report.json" "$a4/lease_query.json" 2>/dev/null
	cp "$work/lease-light/report.json" "$a4/lease_light.json" 2>/dev/null
	cp "$work/lease-light-paced/report.json" "$a4/lease_light_paced.json" 2>/dev/null
	cp "$work/reset-idle/report.json" "$a4/reset_idle.json" 2>/dev/null
	cp "$work/reset-busy-soak/report.json" "$a4/reset_busy_soak.json" 2>/dev/null
	cp "$work/reset-busy-plpgsql/report.json" "$a4/reset_busy_plpgsql.json" 2>/dev/null
	cp "$work/reset-hold/report.json" "$a4/reset_hold.json" 2>/dev/null
	python3 "$here/../bench/a4_summary.py" "$a4" || rc=1

	lat() { python3 -c "
import json
try:
    r=json.load(open('$1'))
    k='lease_ms' if 'lease_ms' in r else 'cycle_ms'
    print('p50 %.3f p99 %.3f max %.2f ms over %d%s' % (r[k]['p50'], r[k]['p99'], r[k]['max'], r['completed'],
          '; waits %d' % r['lease_waits'] if 'lease_waits' in r else ''))
except Exception as e:
    print('(no report: %s)' % e)
" 2>/dev/null; }

	cat <<MSG

========================================================================
PHASE 4 GATE  (cassert build, shared_buffers=$sb; open problem 2: option (a))
------------------------------------------------------------------------
  negative control, lease: cycle inflated 30 ms client-side          : $nc_lease
  negative control, reset: 40 ms parked in the sweep step            : $nc_reset
  lease->first query p99 < 1 ms, $leases leases, light, ready capacity : $lease_light
             $(lat "$work/lease-light/report.json")
  lease->first query p99 < 1 ms, $((leases / 5)) leases, soak workload   : $lease_soak
             $(lat "$work/lease-soak/report.json")
  lease->first query p99 < 1 ms, $((leases / 5)) leases, read-only, 500/s : $lease_query
             $(lat "$work/lease-query/report.json")
  lease->first query p99 < 1 ms, $((leases / 5)) leases, light DML, 500/s : $lease_light_paced
             $(lat "$work/lease-light-paced/report.json")
  reset p99 < 25 ms, $resets resets, idle neighbours                   : $reset_idle
             $(lat "$work/reset-idle/report.json")
  reset p99 < 25 ms, $resets resets, 6 busy lanes (DDL+DML)            : $reset_soak
             $(lat "$work/reset-busy-soak/report.json")
  reset p99 < 25 ms, $resets resets, 6 busy lanes (tight plpgsql loop) : $reset_plpgsql
             $(lat "$work/reset-busy-plpgsql/report.json")
  barrier vs an interrupts-held neighbour (informational)            : $reset_hold
             $(lat "$work/reset-hold/report.json")
------------------------------------------------------------------------
  pool: $resetters resetter thread(s), $(echo "$lease_lanes" | tr ',' '\n' | wc -l | tr -d ' ') lanes, retire after $retire_after epochs
  zero leakage is part of every PASS above (DSM, PGDATA-minus-WAL, AIO
             handles, pins, fds, mappings to gone segments, log scan).
  Appendix A.4 answers: $a4/a4_summary.txt
  not re-run here: phases 1-3.  Phase 4 changed the engine (reset
             timings, the sweep injection point, adopt timing, the
             interrupt-hold helper), so run all three again after it.
  artifacts: $work
========================================================================
MSG

	if [ $rc -eq 0 ]; then
		if [ "$leases" -lt 100000 ]; then
			echo "GATE PASS (phase 4, SMOKE: $leases leases, not the §7.4 gate)"
		else
			echo "GATE PASS (phase 4, $leases leases, $resets resets per load)"
		fi
	else
		echo "GATE FAIL (phase 4)"
	fi
	exit $rc
	;;
*)
	echo "run_gate.sh: unknown phase '$phase' (expected 0-4)" >&2
	exit 2
	;;
esac
