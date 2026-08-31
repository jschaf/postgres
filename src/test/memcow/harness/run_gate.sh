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
# Phases 1-4 are NOT implemented: their subjects (memcow smgr, lane reset,
# the pool, the benchmarks) do not exist yet.  They exit 3 with a clear
# message.  They must never be made to pass by stubbing.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

phase=
build_dir=
source_dir=
extra_args=

while [ $# -gt 0 ]; do
	case $1 in
	--phase)      phase=$2;      shift 2 ;;
	--phase=*)    phase=${1#*=};  shift ;;
	--build-dir)  build_dir=$2;  shift 2 ;;
	--build-dir=*) build_dir=${1#*=}; shift ;;
	--source-dir) source_dir=$2; shift 2 ;;
	--source-dir=*) source_dir=${1#*=}; shift ;;
	--) shift; extra_args="$*"; break ;;
	*)  extra_args="${extra_args} $1"; shift ;;
	esac
done

[ -n "$phase" ] || { echo "run_gate.sh: --phase is required" >&2; exit 2; }
[ -n "$build_dir" ] || { echo "run_gate.sh: --build-dir is required" >&2; exit 2; }

: "${MEMCOW_GATE_WORKDIR:=${TMPDIR:-/tmp}/memcow-gate}"

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
1|2|3|4)
	cat >&2 <<MSG
run_gate.sh: phase $phase is NOT IMPLEMENTED.

    Its subject does not exist yet in this tree.  Phase 1 needs the memcow
    smgr and the GUC; phase 2 needs memcow_lane_reset; phase 3 needs the
    client pool and the race tests; phase 4 needs the benchmarks.

    This is reported as a FAILURE on purpose.  Do not stub it, do not make
    it exit 0, and do not treat a green CI line for this phase as coverage.
MSG
	exit 3
	;;
*)
	echo "run_gate.sh: unknown phase '$phase' (expected 0-4)" >&2
	exit 2
	;;
esac
