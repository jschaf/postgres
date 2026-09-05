#!/bin/sh
#
# run_gate.sh -- the phase-gate entry point.
#
#     run_gate.sh --phase <1|2|4> --build-dir <abs> --seed <dir>
#                 (--pgdata <dir> | --ram-mount <dir>) [--subset NAME]
#                 [extra io_matrix.sh args, e.g. --require-io-uring]
#     exit 0 = gate PASS, non-zero = gate FAIL
#
# Phase 1 is the plan's falsification slice (§7.1): the differential
# matrix, A = stock md and B = THE SAME BINARY with memcow.enabled=on (A runs
# on a PGDATA holding the seed's relation files, B on one holding none, so a
# page B serves cannot have come from md), plus the memcow-specific slice
# cases S1-S10.  Two things it reports and must never hide: on a host with no
# io_uring, four of the twelve cells are UNAVAILABLE and the verdict is "PASS
# on the available cells, io_uring UNVERIFIED" (pass --require-io-uring on
# Linux); and autovacuum=off, a plan §6 precondition, deterministically
# diverges `cluster` from upstream expected output (index_update_stats()
# skips relpages/reltuples when !AutoVacuumingActive()), carried as
# --allow-expected-failure, which never relaxes the A-vs-B comparison.
#
# Phase 2 is the lane reset, the fences and the deterministic races (§4, §5
# I2, §7.2, §7.3): slice cases S11-S18 and R1-R5, the same under
# --negative-control (a test that has never failed is not known to measure
# anything), then the §7.2 soak driven through the pool (pool/pool_soak.py:
# per reset, status, DSM segment count flat, PGDATA-minus-WAL flat, seed
# digest on a retained and on a fresh connection, and every K iterations both
# halves of the fence).  MEMCOW_SOAK_ITERATIONS below 10,000 is a smoke run,
# not the §7.2 gate, and the summary says so.
#
# Phase 4 is the §7.4 benchmark (pool/bench.py under harness/with_server.sh):
# lease -> first parameterized query p99 < 1 ms over 100k leases with ready
# capacity, and reset (quiesce -> ready, including warmup) p99 < 25 ms at
# shared_buffers=512MB under concurrent busy lanes with the barrier's
# absorption latency attributed explicitly -- held on the cassert build
# (progress.md open problem 2, option (a)).  The harness's own negative
# controls run FIRST: one cost term inflated on purpose (the cycle,
# client-side, for the lease driver; the sweep step, through the
# memcow-lane-reset-in-sweep injection point, for the reset driver), and the
# driver must miss its threshold AND attribute the miss to that term.  Zero
# leakage is part of every PASS (DSM segments, PGDATA-minus-WAL, pg_aios,
# pinned buffers, descriptors and DSM mappings of the long-lived processes,
# the log scan).  MEMCOW_BENCH_LEASES below 100,000 is a smoke run.
#
# No phase re-runs another: an engine change needs every phase run again,
# separately, so that each verdict is attributable.  Phases need a seed and
# an assembled RAM dir and will NOT build them (build/ci.sh does, in order,
# and the seed fingerprint pins the binary: reseed after every rebuild).

set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
slice=$(CDPATH='' cd -- "$here/../slice" && pwd)
pool=$(CDPATH='' cd -- "$here/../pool" && pwd)

phase='' build_dir='' pgdata='' extra_args=''
seed=${MEMCOW_SEED_DIR:-}
ram_mount=${MEMCOW_RAM_MOUNT:-}
subset=phase0

while [ $# -gt 0 ]; do
	case $1 in
	--phase)      phase=$2;      shift 2 ;;
	--phase=*)    phase=${1#*=};  shift ;;
	--build-dir)  build_dir=$2;  shift 2 ;;
	--build-dir=*) build_dir=${1#*=}; shift ;;
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

if [ "$phase" != 1 ] && [ -n "$extra_args" ]; then
	echo "run_gate.sh: extra matrix arguments are only supported in phase 1: $extra_args" >&2
	exit 2
fi

[ -n "$phase" ] || { echo "run_gate.sh: --phase is required" >&2; exit 2; }
[ -n "$build_dir" ] || { echo "run_gate.sh: --build-dir is required" >&2; exit 2; }
[ -n "$seed" ] || { echo "run_gate.sh: --seed DIR (or MEMCOW_SEED_DIR) is required; build it with seed/build_seed.sh -b <bindir> -o <seed> -f" >&2; exit 2; }
[ -d "$seed" ] || { echo "run_gate.sh: no such seed directory: $seed" >&2; exit 2; }
if [ -z "$pgdata" ]; then
	[ -n "$ram_mount" ] || { echo "run_gate.sh: --pgdata DIR or --ram-mount DIR (or MEMCOW_RAM_MOUNT) is required; assemble it with seed/assemble_ramdir.sh -s <seed> -m <mount>" >&2; exit 2; }
	pgdata="$ram_mount/pgdata"
fi
[ -n "$ram_mount" ] || ram_mount=$(dirname -- "$pgdata")
[ -f "$pgdata/PG_VERSION" ] || { echo "run_gate.sh: not a data directory: $pgdata" >&2; exit 2; }

# The harness connects as $PGUSER, or as the OS user when it is unset.  The
# seed's bootstrap superuser is whatever build_seed.sh -u said, recorded in
# the fingerprint; default to it, so a mismatch ('role "..." does not exist'
# on every case, which looks like an engine failure and is not) can only
# come from asking for a different user on purpose.
if [ -z "${PGUSER:-}" ]; then
	PGUSER=$(sed -n 's/^seed_superuser=//p' "$seed/memcow_seed.fingerprint")
	[ -n "$PGUSER" ] && export PGUSER && echo "run_gate.sh: connecting as the seed's superuser: $PGUSER"
fi

: "${MEMCOW_GATE_WORKDIR:=${TMPDIR:-/tmp}/memcow-gate}"
work="$MEMCOW_GATE_WORKDIR/phase$phase"
mkdir -p "$work"
common="--seed $seed --pgdata $pgdata --ram-mount $ram_mount --build-dir $build_dir"
rc=0

case $phase in
1)
	echo "run_gate.sh: phase 1 -- the plan's falsification slice"
	echo "run_gate.sh: building the A (stock md) and B (memcow) templates"
	if ! "$slice/make_templates.sh" --seed "$seed" --ramdir "$pgdata" \
		--outdir "$work/templates" >"$work/make_templates.log" 2>&1
	then
		echo "run_gate.sh: could not build the PGDATA templates:" >&2
		cat "$work/make_templates.log" >&2
		exit 2
	fi
	sed -n 's/^MEMCOW_TPL_/TPL_/p' "$work/make_templates.log" >"$work/templates.env"
	# shellcheck disable=SC1090,SC1091
	. "$work/templates.env"

	# assemble_ramdir.sh writes full_page_writes=off and synchronous_commit=off
	# into the RAM dir for speed.  Both change core regression output in ways
	# that have nothing to do with memcow (synchronous_commit=off: `sequence`
	# sees page_lsn > pg_current_wal_lsn(); full_page_writes=off: `temp` fails
	# "no empty local buffer available"), so the gate turns them back on for
	# BOTH sides rather than lowering the bar.  autovacuum stays off (a §6
	# precondition) and `cluster` gets the G3-only allowance.
	#
	# The --allow-engine-divergence list is DERIVED: the phase0 tests whose
	# SQL calls one of the smgr-bypassing size functions
	#     grep -lE 'pg_(relation|table|indexes|total_relation|database)_size' src/test/regress/sql/*.sql
	# intersected with subsets/phase0.txt.  Every hunk in those must be matched
	# by a rule in divergences.txt, and an allowance whose test runs WITHOUT
	# diverging fails the gate, so the list cannot rot in either direction.
	# shellcheck disable=SC2086
	if "$here/io_matrix.sh" \
		--outputdir "$work/matrix" \
		--a-pgdata-template "$TPL_MD" --b-pgdata-template "$TPL_MEMCOW" \
		--build-dir "$build_dir" --subset "$subset" \
		--b-guc memcow.enabled=on --b-guc "memcow.seed_directory=$seed" \
		--guc synchronous_commit=on --guc full_page_writes=on --guc autovacuum=off \
		--allow-expected-failure cluster \
		--allow-engine-divergence insert --allow-engine-divergence temp \
		--allow-engine-divergence vacuum --allow-engine-divergence vacuum_parallel \
		$extra_args
	then matrix=PASS; else matrix=FAIL; rc=1; fi

	# shellcheck disable=SC2086
	if "$slice/slice_tests.sh" $common --outputdir "$work/slice" --phase 1
	then slice_result=PASS; else slice_result=FAIL; rc=1; fi

	if grep -q '^MATRIX COVERAGE: COMPLETE' "$work/matrix/summary.txt" 2>/dev/null; then
		uring="all 12 matrix cells ran on $(uname -s) $(uname -r); io_uring COVERED.  These are
             the only cells on which pgaio_io_complete_synthetic()'s PGAIO_HF_SYNCHRONOUS
             flag is live; the flag itself is pinned by
             src/test/modules/test_aio/t/005_synthetic_completion.pl (concurrent waiter)."
		verdict="all 12 matrix cells; io_uring COVERED"
	else
		uring="this build offers no io_uring io_method, so 4 of the 12 cells are UNAVAILABLE
             and unrun.  Phase 1 here is at best \"PASS on the available cells, io_uring
             UNVERIFIED\"; run --require-io-uring on Linux with liburing."
		verdict="available cells only; io_uring UNVERIFIED"
	fi
	cat <<MSG

========================================================================
PHASE 1 GATE (subset=$subset)
------------------------------------------------------------------------
  differential matrix (io_method x cold/hot x temp, A=md B=memcow) : $matrix
  memcow slice tests S1-S10                                        : $slice_result
------------------------------------------------------------------------
  io_uring:  $uring
  artifacts: $work
========================================================================
MSG
	[ $rc -eq 0 ] && echo "GATE PASS (phase 1, $verdict)" || echo "GATE FAIL (phase 1)"
	exit $rc
	;;
2)
	echo "run_gate.sh: phase 2 -- lane reset, fences, races, and the pool-driven soak"
	# shellcheck disable=SC2086
	if "$slice/slice_tests.sh" $common --outputdir "$work/slice" --phase 2
	then slice_result=PASS; else slice_result=FAIL; rc=1; fi
	# shellcheck disable=SC2086
	if "$slice/slice_tests.sh" $common --outputdir "$work/slice-nc" --phase 2 --negative-control
	then nc_result=PASS; else nc_result=FAIL; rc=1; fi

	iterations=${MEMCOW_SOAK_ITERATIONS:-10000}
	# shellcheck disable=SC2086
	if "$here/with_server.sh" $common --outputdir "$work/pool-soak" -- \
		python3 "$pool/pool_soak.py" --iterations "$iterations" --report "$work/pool-soak/report.json"
	then soak_result=PASS; else soak_result=FAIL; rc=1; fi
	latency=$(grep '^resets:' "$work/pool-soak/driver.log" 2>/dev/null | tail -1)
	[ "$iterations" -lt 10000 ] && smoke="SMOKE: $iterations resets, not the §7.2 gate" || smoke="$iterations resets"
	cat <<MSG

========================================================================
PHASE 2 GATE
------------------------------------------------------------------------
  reset, fence and race cases S11-S18, R1-R5                       : $slice_result
  their negative controls (expected sabotage symptoms)            : $nc_result
  reset soak through the pool, $smoke : $soak_result
------------------------------------------------------------------------
  latency (informational; §7.4 owns the thresholds): $latency
  not re-run here: phase 1.  A green phase 2 alone is not a green phase 1.
  artifacts: $work
========================================================================
MSG
	[ $rc -eq 0 ] && echo "GATE PASS (phase 2, $smoke)" || echo "GATE FAIL (phase 2)"
	exit $rc
	;;
4)
	echo "run_gate.sh: phase 4 -- the benchmarks (plan §7.4)"
	# The pool configuration the gate holds the thresholds at, chosen from
	# measurement (progress.md 2026-09-03, the lanes x resetters x K matrix):
	# 1 resetter thread starves the ready queue at full lease rate; 2 are
	# marginal; 3 on 8 lanes leave 0-7 waits in 5000 leases and a 4th adds
	# nothing.  K=200: recycles are 0.5% of cycles and outside the cycle p99.
	# Override to re-measure, never to pass.
	lanes8=memcow_lane_00,memcow_lane_01,memcow_lane_02,memcow_lane_03,memcow_lane_04,memcow_lane_05,memcow_lane_06,memcow_lane_07
	busy6=memcow_lane_02,memcow_lane_03,memcow_lane_04,memcow_lane_05,memcow_lane_06,memcow_lane_07
	resetters=${MEMCOW_BENCH_RESETTERS:-3}
	retire_after=${MEMCOW_BENCH_RETIRE_AFTER:-200}
	leases=${MEMCOW_BENCH_LEASES:-100000}
	resets=${MEMCOW_BENCH_RESETS:-3000}
	sb=${MEMCOW_BENCH_SHARED_BUFFERS:-512MB}
	bench() (	# bench OUTDIR-NAME driver args...
		name=$1; shift
		# shellcheck disable=SC2086
		time -p "$here/with_server.sh" $common --shared-buffers "$sb" --outputdir "$work/$name" -- \
			python3 "$pool/bench.py" --retire-after "$retire_after" --report "$work/$name/report.json" "$@"
	)
	lat() {	# lat REPORT -> one summary line
		python3 -c "
import json
try:
    r=json.load(open('$1')); k='lease_ms' if 'lease_ms' in r else 'cycle_ms'
    print('p50 %.3f p99 %.3f max %.2f ms over %d%s' % (r[k]['p50'], r[k]['p99'], r[k]['max'], r['completed'],
          '; waits %d' % r['lease_waits'] if 'lease_waits' in r else ''))
except Exception as e:
    print('(no report: %s)' % e)
" 2>/dev/null
	}

	# (1) the negative controls FIRST: a benchmark that cannot fail measures nothing
	if bench nc-lease lease --leases 3000 --lanes "$lanes8" --resetters "$resetters" \
		--negative-control --resetter-delay-ms 30
	then nc_lease=BEHAVED; else nc_lease="DID NOT BEHAVE"; rc=1; fi
	if bench nc-reset reset --resets 400 --lanes memcow_lane_00,memcow_lane_01 \
		--busy-lanes memcow_lane_02,memcow_lane_03 --negative-control --nc-sweep-wait-ms 40
	then nc_reset=BEHAVED; else nc_reset="DID NOT BEHAVE"; rc=1; fi
	# (2) lease -> first parameterized query, with ready capacity
	if bench lease-light lease --leases "$leases" --lanes "$lanes8" --resetters "$resetters"
	then lease_light=PASS; else lease_light=FAIL; rc=1; fi
	# (3) reset p99 at 512MB: idle neighbours (the baseline), six busy DDL+DML
	# lanes (the gated number), six tight-plpgsql lanes (the CFI-starved case)
	if bench reset-idle reset --resets "$resets" --lanes memcow_lane_00,memcow_lane_01 --label idle
	then reset_idle=PASS; else reset_idle=FAIL; rc=1; fi
	if bench reset-busy-soak reset --resets "$resets" --lanes memcow_lane_00,memcow_lane_01 \
		--busy-lanes "$busy6" --busy-mode soak --label busy-soak
	then reset_busy_soak=PASS; else reset_busy_soak=FAIL; rc=1; fi
	if bench reset-busy-plpgsql reset --resets "$resets" --lanes memcow_lane_00,memcow_lane_01 \
		--busy-lanes "$busy6" --busy-mode plpgsql --label busy-plpgsql
	then reset_plpgsql=PASS; else reset_plpgsql=FAIL; rc=1; fi

	[ "$leases" -lt 100000 ] && smoke="SMOKE: $leases leases, not the §7.4 gate" || smoke="$leases leases, $resets resets per load"
	cat <<MSG

========================================================================
PHASE 4 GATE  (cassert build, shared_buffers=$sb; open problem 2: option (a))
------------------------------------------------------------------------
  negative control, lease: cycle inflated 30 ms client-side          : $nc_lease
  negative control, reset: 40 ms parked in the sweep step            : $nc_reset
  lease->first query p99 < 1 ms, $leases leases, light, ready capacity : $lease_light
             $(lat "$work/lease-light/report.json")
  reset p99 < 25 ms, $resets resets, idle neighbours                   : $reset_idle
             $(lat "$work/reset-idle/report.json")
  reset p99 < 25 ms, $resets resets, 6 busy lanes (DDL+DML)            : $reset_busy_soak
             $(lat "$work/reset-busy-soak/report.json")
  reset p99 < 25 ms, $resets resets, 6 busy lanes (tight plpgsql loop) : $reset_plpgsql
             $(lat "$work/reset-busy-plpgsql/report.json")
------------------------------------------------------------------------
  pool: $resetters resetter thread(s), 8 lanes, retire after $retire_after epochs
  zero leakage is part of every PASS above; the barrier's absorption latency
             is the barrier term of each reset report (terms.barrier).
  not re-run here: phases 1-2.
  artifacts: $work
========================================================================
MSG
	[ $rc -eq 0 ] && echo "GATE PASS (phase 4, $smoke)" || echo "GATE FAIL (phase 4)"
	exit $rc
	;;
*)
	echo "run_gate.sh: unknown phase '$phase' (expected 1, 2 or 4; the former phase 3 is part of phase 2)" >&2
	exit 2
	;;
esac
