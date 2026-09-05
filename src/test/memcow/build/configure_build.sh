#!/usr/bin/env bash
#
# configure_build.sh --- create or update the dedicated meson build directory
# for the pgtest/memcow ephemeral test engine.
#
# Phase 0(c) scaffolding.  See src/test/memcow/build/README.md for the phase
# structure and the gates this build directory feeds.
#
# The build directory is `build-memcow` at the top of the working tree (or
# $MEMCOW_BUILD_DIR).  It is deliberately separate from any hand-rolled build
# dir (e.g. `build-fast`) so that the memcow gates always run against a build
# whose options are pinned by this script rather than by whatever the last
# interactive `meson configure` did.
#
# Mandatory, non-negotiable options (plan: fixed decisions):
#     -Dcassert=true -Dinjection_points=true
# The script re-verifies both by introspection after configuring and fails if
# either is not actually true.  Do not "fix" a red gate by editing them out.
#
# Idempotent: safe to re-run against an existing build directory; it reapplies
# the pinned options via `meson setup --reconfigure`.
#
# Environment overrides:
#   MEMCOW_BUILD_DIR   build directory path       (default <root>/build-memcow)
#   MEMCOW_BUILDTYPE   meson buildtype            (default debugoptimized)
#   MEMCOW_PREFIX      install prefix             (default <root>/../postgres-install-memcow)
#   MEMCOW_WERROR      true/false                 (default false)
#   MEMCOW_PERL        perl used for TAP tests    (default Homebrew perl, else `perl`)
#   MEMCOW_TAP_TESTS   enabled/disabled/auto      (default: enabled if this
#                      perl has the modules config/check_modules.pl wants,
#                      otherwise disabled + a loud warning)
#   MEMCOW_WIPE        1 to wipe a stale/foreign build dir instead of erroring
#   MESON              meson binary               (default `meson`)
#
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Repo root: prefer git (correct inside linked worktrees), fall back to the
# known depth of this script (<root>/src/test/memcow/build).
if ! root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null); then
	root=$(cd -- "$script_dir/../../../.." && pwd)
fi
root=$(cd -- "$root" && pwd -P)

if [ ! -f "$root/src/backend/storage/smgr/smgr.c" ]; then
	echo "configure_build.sh: $root does not look like a PostgreSQL source tree" >&2
	exit 1
fi

MESON=${MESON:-meson}
build_dir=${MEMCOW_BUILD_DIR:-$root/build-memcow}
buildtype=${MEMCOW_BUILDTYPE:-debugoptimized}
# Install prefix lives inside the build dir: self-contained, removed with the
# build dir, invisible to git, and it cannot collide with the shared
# /opt/p/postgres-install tree that build-fast installs into.
prefix=${MEMCOW_PREFIX:-$build_dir/install}
werror=${MEMCOW_WERROR:-false}

command -v "$MESON" >/dev/null 2>&1 || {
	echo "configure_build.sh: meson not found (set \$MESON)" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Option set.
#
# The dependency-discovery and tool-name options below are carried over from
# the pre-existing `build-fast` dir because they are what makes a build work at
# all on this machine (Homebrew kegs, GNU sed), not because they are memcow
# policy.  Everything memcow actually cares about is in the "pinned" block.
# ---------------------------------------------------------------------------

# Which perl, and can it run TAP tests?  `-Dtap_tests=enabled` is a hard
# configure error when the Perl modules are missing, so probe first with the
# exact script meson uses and degrade explicitly and loudly rather than dying.
perl_bin=${MEMCOW_PERL:-}
if [ -z "$perl_bin" ]; then
	if [ -x /opt/homebrew/opt/perl/bin/perl ]; then
		perl_bin=/opt/homebrew/opt/perl/bin/perl
	else
		perl_bin=$(command -v perl || true)
	fi
fi

tap_tests=${MEMCOW_TAP_TESTS:-}
if [ -z "$tap_tests" ]; then
	if [ -n "$perl_bin" ] && [ -f "$root/config/check_modules.pl" ] &&
		"$perl_bin" "$root/config/check_modules.pl" >/dev/null 2>&1; then
		tap_tests=enabled
	else
		tap_tests=disabled
		tap_warning=1
	fi
fi

opts=(
	# --- pinned by the plan; never relax these ---
	"-Dcassert=true"
	"-Dinjection_points=true"

	# --- gates run pg_regress and (where available) TAP suites ---
	"-Dtap_tests=$tap_tests"

	# --- build shape (see README: divergence from build-fast) ---
	"--buildtype=$buildtype"
	"--prefix=$prefix"
	"-Dwerror=$werror"

	# --- keep the build lean and deterministic; no gate needs these ---
	"-Dllvm=disabled"
	"-Ddtrace=disabled"
	"-Ddocs=disabled"
	"-Ddocs_pdf=disabled"
)

# io_uring is the only io_method with wait_one/check_one, i.e. the only one
# that can tell whether pgaio_io_complete_synthetic()'s PGAIO_HF_SYNCHRONOUS
# flag is live.  It needs liburing, which exists only on Linux; make it a
# hard requirement there so a Linux gate build cannot silently lose the four
# io_uring matrix cells.  Elsewhere leave it to meson's auto-detection
# (which finds nothing), so this script keeps working on macOS.
if [ "$(uname -s)" = Linux ]; then
	opts+=("-Dliburing=enabled")
fi

# pkg-config search path: the same Homebrew kegs build-fast uses, minus any
# that are not installed here.  A caller-supplied PKG_CONFIG_PATH is appended.
pkg_paths=()
for p in \
	/opt/homebrew/opt/icu4c@78/lib/pkgconfig \
	/opt/homebrew/opt/openssl@3/lib/pkgconfig \
	/opt/homebrew/opt/lz4/lib/pkgconfig \
	/opt/homebrew/opt/zstd/lib/pkgconfig \
	/opt/homebrew/opt/readline/lib/pkgconfig \
	/opt/homebrew/opt/krb5/lib/pkgconfig
do
	[ -d "$p" ] && pkg_paths+=("$p")
done
if [ -n "${PKG_CONFIG_PATH:-}" ]; then
	IFS=':' read -r -a extra_pkg <<<"$PKG_CONFIG_PATH"
	for p in "${extra_pkg[@]}"; do
		if [ -n "$p" ] && [ -d "$p" ]; then
			pkg_paths+=("$p")
		fi
	done
fi
if [ "${#pkg_paths[@]}" -gt 0 ]; then
	joined=$(printf ",'%s'" "${pkg_paths[@]}")
	opts+=("-Dpkg_config_path=[${joined:1}]")
fi

# krb5 headers are not on the default include path under Homebrew.
if [ -d /opt/homebrew/opt/krb5/include ]; then
	opts+=("-Dextra_include_dirs=['/opt/homebrew/opt/krb5/include']")
fi

# PostgreSQL's build wants GNU sed and a reasonably modern perl on macOS.
if command -v gsed >/dev/null 2>&1; then
	opts+=("-DSED=$(command -v gsed)")
fi
if [ -n "$perl_bin" ]; then
	opts+=("-DPERL=$perl_bin")
	prove_bin=$(dirname -- "$perl_bin")/prove
	if [ -x "$prove_bin" ]; then
		opts+=("-DPROVE=$prove_bin")
	fi
fi

# ---------------------------------------------------------------------------
# Configure (fresh) or reconfigure (existing).
# ---------------------------------------------------------------------------

existing_source=""
if [ -f "$build_dir/meson-info/meson-info.json" ]; then
	existing_source=$(python3 - "$build_dir/meson-info/meson-info.json" <<'PY'
import json, os, sys
with open(sys.argv[1]) as f:
    info = json.load(f)
src = info.get("directories", {}).get("source", "")
print(os.path.realpath(src) if src else "")
PY
) || existing_source=""
fi

if [ -n "$existing_source" ] && [ "$existing_source" != "$root" ]; then
	echo "configure_build.sh: $build_dir was configured for a different source tree:" >&2
	echo "    existing: $existing_source" >&2
	echo "    wanted:   $root" >&2
	if [ "${MEMCOW_WIPE:-0}" = "1" ]; then
		echo "configure_build.sh: MEMCOW_WIPE=1, removing $build_dir" >&2
		rm -rf "$build_dir"
	else
		echo "    re-run with MEMCOW_WIPE=1, or point MEMCOW_BUILD_DIR elsewhere" >&2
		exit 1
	fi
fi

if [ -f "$build_dir/meson-private/coredata.dat" ]; then
	action="reconfigure"
	echo "configure_build.sh: reconfiguring existing build dir $build_dir"
	"$MESON" setup --reconfigure "${opts[@]}" "$build_dir" "$root"
else
	action="setup"
	echo "configure_build.sh: creating build dir $build_dir"
	"$MESON" setup "${opts[@]}" "$build_dir" "$root"
fi

# Keep the build tree out of `git status` without touching any tracked file or
# the repo-wide exclude list.
if [ -d "$build_dir" ] && [ ! -e "$build_dir/.gitignore" ]; then
	printf '*\n' >"$build_dir/.gitignore"
fi

# ---------------------------------------------------------------------------
# Verify the pinned options really took effect.
# ---------------------------------------------------------------------------

echo "configure_build.sh: effective options in $build_dir"
introspect_json=$(mktemp "${TMPDIR:-/tmp}/memcow-buildopts.XXXXXX")
trap 'rm -f "$introspect_json"' EXIT
"$MESON" introspect "$build_dir" --buildoptions >"$introspect_json"
rc=0
python3 - "$introspect_json" <<'PY' || rc=$?
import json, sys

want = {"cassert": True, "injection_points": True}
with open(sys.argv[1]) as f:
    opts = {o["name"]: o["value"] for o in json.load(f)}
show = ["cassert", "injection_points", "buildtype", "optimization", "debug",
        "b_ndebug", "werror", "tap_tests", "prefix"]
for k in show:
    if k in opts:
        print(f"    {k:18} {opts[k]!r}")

bad = []
for k, v in want.items():
    if k not in opts:
        bad.append(f"{k}: MISSING from this tree's meson options")
    elif opts[k] != v:
        bad.append(f"{k}: is {opts[k]!r}, must be {v!r}")
if bad:
    print("configure_build.sh: PINNED-OPTION CHECK FAILED:", file=sys.stderr)
    for b in bad:
        print("    " + b, file=sys.stderr)
    sys.exit(1)
PY
if [ "$rc" -ne 0 ]; then
	echo "configure_build.sh: pinned-option verification FAILED ($action)" >&2
	exit 1
fi

if [ "${tap_warning:-0}" = "1" ]; then
	cat >&2 <<-EOF

	configure_build.sh: WARNING --- TAP tests are DISABLED in $build_dir.
	    $perl_bin cannot run config/check_modules.pl (missing IPC::Run,
	    Test::More or Time::HiRes).  pg_regress-based gates still run; any
	    memcow gate that needs a TAP suite (notably the phase 3 injection-point
	    race tests) will NOT be runnable until this is fixed:
	        cpan IPC::Run          # or: cpanm IPC::Run Test::More Time::HiRes
	    Then re-run this script.  Do not treat a TAP-less run as a green gate.

	EOF
fi

echo "configure_build.sh: OK ($action) -> $build_dir"
echo "configure_build.sh: next: ninja -C $build_dir"
