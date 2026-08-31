#!/usr/bin/env bash
#
# ci.sh --- one-shot memcow CI driver: configure, build, run one phase gate,
# print exactly one PASS/FAIL summary line.
#
# Phase 0(c) scaffolding.  See src/test/memcow/build/README.md.
#
#   ./src/test/memcow/build/ci.sh [--phase N] [options] [-- harness args...]
#
# Phases (plan §7; phase 0 is this scaffolding's own gate):
#   0    build gate: configure + full build clean, pinned options verified.
#        Needs no harness.  This is the only gate runnable before Phase 1 lands.
#   1    memcow smgr + GUC + smgrsw row + pgaio_io_complete_synthetic()
#   2    memcow_lane_reset / memcow_backend_reset loop (10k iterations)
#   3    deterministic races via injection points / SIGSTOP
#   4    benchmark: lease p99 < 1 ms, reset p99 < 25 ms, zero leakage
#   all  1..4 in order, stopping at the first failure
#
# Gates 1..4 are delegated in full to the memcow test harness, which is a
# separate deliverable.  The contract this script relies on:
#
#     src/test/memcow/harness/run_gate.sh --phase <N> \
#         --build-dir <abs build dir> --source-dir <abs source root>
#     exit 0 = gate PASS, non-zero = gate FAIL
#
# plus the environment: MEMCOW_BUILD_DIR, MEMCOW_SOURCE_DIR, MEMCOW_TAP_TESTS.
# Anything after `--` on ci.sh's command line is appended to the harness call.
# If the harness is absent, ci.sh FAILs and says so; it never stubs, skips or
# fakes a gate.
#
# Options:
#   --phase N | all     which gate to run (default 0)
#   --jobs N            ninja parallelism (default: ninja's own default)
#   --skip-configure    do not run configure_build.sh (build dir must exist)
#   --skip-build        do not run ninja (implies the build is already current)
#   -h, --help          this text
#
set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if ! root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null); then
	root=$(cd -- "$script_dir/../../../.." && pwd)
fi
root=$(cd -- "$root" && pwd -P)

build_dir=${MEMCOW_BUILD_DIR:-$root/build-memcow}
harness_dir=$root/src/test/memcow/harness
harness_entry=$harness_dir/run_gate.sh

phase=0
jobs=""
do_configure=1
do_build=1
harness_args=()

while [ $# -gt 0 ]; do
	case "$1" in
	--phase)
		phase=${2:-}
		shift 2
		;;
	--phase=*)
		phase=${1#*=}
		shift
		;;
	--jobs)
		jobs=${2:-}
		shift 2
		;;
	--jobs=*)
		jobs=${1#*=}
		shift
		;;
	--skip-configure)
		do_configure=0
		shift
		;;
	--skip-build)
		do_build=0
		shift
		;;
	-h | --help)
		awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' \
			"${BASH_SOURCE[0]}"
		exit 0
		;;
	--)
		shift
		harness_args=("$@")
		break
		;;
	*)
		echo "ci.sh: unknown argument: $1 (try --help)" >&2
		exit 2
		;;
	esac
done

case "$phase" in
0 | 1 | 2 | 3 | 4 | all) ;;
*)
	echo "ci.sh: --phase must be one of 0 1 2 3 4 all (got '$phase')" >&2
	exit 2
	;;
esac

# ---------------------------------------------------------------------------
# Single-summary-line machinery.  Exactly one MEMCOW-CI: line is printed, on
# every exit path including an unexpected one.
# ---------------------------------------------------------------------------

start_ts=$(date +%s)
result=FAIL
stage=startup
reason="ci.sh exited before reaching a gate"
summary_printed=0

summarize()
{
	[ "$summary_printed" = "1" ] && return
	summary_printed=1
	local elapsed=$(( $(date +%s) - start_ts ))
	local tap=${tap_state:-unknown}
	echo
	printf 'MEMCOW-CI: %s phase=%s stage=%s tap=%s elapsed=%ss build-dir=%s reason=%s\n' \
		"$result" "$phase" "$stage" "$tap" "$elapsed" "$build_dir" "\"$reason\""
}
trap summarize EXIT

fail()
{
	result=FAIL
	reason=$1
	echo "ci.sh: FAIL ($stage): $reason" >&2
	exit 1
}

banner()
{
	echo
	echo "=== ci.sh: $* ==="
}

# ---------------------------------------------------------------------------
# Stage: configure
# ---------------------------------------------------------------------------

stage=configure
if [ "$do_configure" = "1" ]; then
	banner "configure ($build_dir)"
	MEMCOW_BUILD_DIR=$build_dir "$script_dir/configure_build.sh" ||
		fail "configure_build.sh failed"
else
	banner "configure skipped (--skip-configure)"
	[ -f "$build_dir/meson-private/coredata.dat" ] ||
		fail "--skip-configure given but $build_dir is not a meson build dir"
fi

# Record the TAP state for the summary line and for the harness: a gate that
# needs a TAP suite must not be reported green on a build that cannot run one.
tap_state=$(python3 - "$build_dir" <<'PY' 2>/dev/null || echo unknown
import json, os, sys
path = os.path.join(sys.argv[1], "meson-info", "intro-buildoptions.json")
try:
    with open(path) as f:
        opts = {o["name"]: o["value"] for o in json.load(f)}
    print(opts.get("tap_tests", "unknown"))
except Exception:
    print("unknown")
PY
)

# Re-assert the pinned options here too, so that --skip-configure cannot be
# used to sneak a gate run past an unpinned build dir.
python3 - "$build_dir" <<'PY'
import json, os, sys
path = os.path.join(sys.argv[1], "meson-info", "intro-buildoptions.json")
with open(path) as f:
    opts = {o["name"]: o["value"] for o in json.load(f)}
bad = [f"{k}={opts.get(k)!r}" for k, v in
       (("cassert", True), ("injection_points", True)) if opts.get(k) is not v]
if bad:
    print("ci.sh: pinned options are not set: " + ", ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
[ $? -eq 0 ] || fail "build dir does not have cassert=true and injection_points=true"

# ---------------------------------------------------------------------------
# Stage: build
# ---------------------------------------------------------------------------

stage=build
if [ "$do_build" = "1" ]; then
	banner "build (ninja -C $build_dir)"
	ninja_cmd=(ninja -C "$build_dir")
	[ -n "$jobs" ] && ninja_cmd+=(-j "$jobs")
	"${ninja_cmd[@]}" || fail "ninja build failed"
else
	banner "build skipped (--skip-build)"
fi

if [ "$phase" = "0" ]; then
	stage=gate-phase-0
	banner "phase 0 gate: scaffolding builds clean"
	result=PASS
	reason="configure+build clean with cassert=true injection_points=true"
	exit 0
fi

# ---------------------------------------------------------------------------
# Stage: gate (delegated to the harness)
# ---------------------------------------------------------------------------

stage=harness-check
if [ ! -d "$harness_dir" ]; then
	cat >&2 <<-EOF

	ci.sh: the memcow test harness is missing.

	    expected directory: $harness_dir
	    expected entry:     $harness_entry

	Phase 0(c) provides only the build scaffolding (configure_build.sh, ci.sh,
	README.md).  The harness that implements the plan §7 phase gates is a
	separate deliverable and is not present in this tree.  ci.sh will not stub,
	skip, or fake a gate: without the harness, phases 1-4 cannot be run.

	Runnable today:  ./src/test/memcow/build/ci.sh --phase 0
	EOF
	fail "harness directory not found: $harness_dir"
fi

if [ ! -f "$harness_entry" ]; then
	{
		echo
		echo "ci.sh: the harness directory exists but has no gate entry point."
		echo "    expected: $harness_entry"
		echo "    invoked as: run_gate.sh --phase <N> --build-dir <dir> --source-dir <dir>"
		echo "    contents of $harness_dir:"
		ls -1A "$harness_dir" 2>/dev/null | sed 's/^/        /'
		echo
	} >&2
	fail "harness entry point not found: $harness_entry"
fi

run_one_gate()
{
	local n=$1
	stage=gate-phase-$n
	banner "phase $n gate: $harness_entry"

	local cmd=()
	if [ -x "$harness_entry" ]; then
		cmd=("$harness_entry")
	else
		echo "ci.sh: note: $harness_entry is not executable; running it with bash" >&2
		cmd=(bash "$harness_entry")
	fi
	cmd+=(--phase "$n" --build-dir "$build_dir" --source-dir "$root")
	[ "${#harness_args[@]}" -gt 0 ] && cmd+=("${harness_args[@]}")

	MEMCOW_BUILD_DIR=$build_dir \
		MEMCOW_SOURCE_DIR=$root \
		MEMCOW_TAP_TESTS=$tap_state \
		"${cmd[@]}"
}

if [ "$phase" = "all" ]; then
	for n in 1 2 3 4; do
		run_one_gate "$n" || fail "phase $n gate failed (harness exit $?)"
	done
	phase=all
	result=PASS
	reason="phases 1-4 gates passed"
	stage=gate-all
else
	run_one_gate "$phase" || fail "phase $phase gate failed (harness exit $?)"
	result=PASS
	reason="phase $phase gate passed"
fi

exit 0
