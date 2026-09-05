#!/usr/bin/env bash
#
# ci.sh --- configure, build, install, reseed, assemble the RAM dir, run one
# phase gate.  The order is the point: the seed fingerprint pins the postgres
# binary and the memcow module, so every rebuild must be followed by a reseed
# and a re-assembly before any gate is trusted.
#
#   ci.sh --phase 1|2|4 --seed DIR --ram-mount DIR [--skip-build] [-- gate args...]
#
#   --phase N        which gate (run_gate.sh); 'all' runs 1, 2, 4 in order,
#                    stopping at the first failure
#   --seed DIR       seed PGDATA to (re)build (build_seed.sh -o)
#   --ram-mount DIR  RAM disk mount point (assemble_ramdir.sh -m)
#   --skip-build     do not configure/build; still reinstall, reseed, assemble
#   MEMCOW_BUILD_DIR the meson build dir (default <root>/build-memcow)
#
# Anything after -- is passed to run_gate.sh (e.g. --require-io-uring).
# Exit status is the gate's.
#
set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$script_dir/../../../.." && pwd -P)
build_dir=${MEMCOW_BUILD_DIR:-$root/build-memcow}
harness=$root/src/test/memcow/harness
seedsh=$root/src/test/memcow/seed

phase= seed= ram_mount= do_build=1
gate_args=()
while [ $# -gt 0 ]; do
	case $1 in
	--phase)      phase=$2; shift 2 ;;
	--seed)       seed=$2; shift 2 ;;
	--ram-mount)  ram_mount=$2; shift 2 ;;
	--skip-build) do_build=0; shift ;;
	--)           shift; gate_args=("$@"); break ;;
	-h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)            echo "ci.sh: unknown argument: $1" >&2; exit 2 ;;
	esac
done
case $phase in 1|2|4|all) ;; *) echo "ci.sh: --phase must be 1, 2, 4 or all" >&2; exit 2 ;; esac
[ -n "$seed" ] && [ -n "$ram_mount" ] || { echo "ci.sh: --seed and --ram-mount are required" >&2; exit 2; }

step() { echo; echo "=== ci.sh: $* ($(date '+%H:%M:%S')) ==="; }

if [ "$do_build" = 1 ]; then
	step "configure $build_dir"
	MEMCOW_BUILD_DIR=$build_dir "$script_dir/configure_build.sh" || exit 1
	step "ninja"
	ninja -C "$build_dir" || exit 1
fi
step "install"
# On macOS, system shells/interpreters strip DYLD_LIBRARY_PATH in the
# pg_regress and TAP subprocess chains. Install the libraries at their
# compiled-in paths too; the configured prefix is private to this build.
ninja -C "$build_dir" install || exit 1
step "install into tmp_install"
meson test -C "$build_dir" --suite setup >/dev/null || { echo "ci.sh: tmp_install failed" >&2; exit 1; }

bindir=$(python3 - "$build_dir" <<'PY'
import json, sys
bd = sys.argv[1]
prefix = [o['value'] for o in json.load(open(bd + '/meson-info/intro-buildoptions.json')) if o['name'] == 'prefix'][0]
print('%s/tmp_install%s/bin' % (bd, prefix))
PY
)
step "seed (the fingerprint pins the binary and the module: always rebuilt)"
"$seedsh/build_seed.sh" -b "$bindir" -o "$seed" -f || exit 1
step "assemble the RAM dir"
"$seedsh/assemble_ramdir.sh" -s "$seed" -m "$ram_mount" -b "$bindir" -f || exit 1

[ "$phase" = all ] && phases="1 2 4" || phases=$phase
for p in $phases; do
	step "gate: phase $p"
	"$harness/run_gate.sh" --phase "$p" --build-dir "$build_dir" --seed "$seed" \
		--ram-mount "$ram_mount" ${gate_args[@]+"${gate_args[@]}"} || exit $?
done
