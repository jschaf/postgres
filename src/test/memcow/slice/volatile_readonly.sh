#!/usr/bin/env bash
#
# volatile_readonly.sh --- run volatile_tests.sh with the seed on a read-only
# filesystem, so a write path the mode missed fails with EROFS instead of
# passing silently.
#
#   volatile_readonly.sh --seed DIR [--outputdir DIR] [-- volatile_tests.sh args...]
#
# macOS: the seed is copied into a read-only disk image (hdiutil UDRO) and
# attached read-only with ownership honored.  Linux: the seed is bind-mounted
# read-only inside an unprivileged user and mount namespace, keeping the
# caller's uid (PostgreSQL refuses to run as root).  Either way the tests see
# the same seed at a read-only path.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

set -euo pipefail

MC_PROG=volatile_readonly.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../harness/common.sh
. "$HERE/../harness/common.sh"

SEED=
OUTPUTDIR=
PASS=()
while [ $# -gt 0 ]; do
	case $1 in
		--seed)      SEED=$2; shift 2 ;;
		--outputdir) OUTPUTDIR=$2; shift 2 ;;
		--)          shift; PASS=("$@"); break ;;
		-h|--help)   sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)           mc_die "unknown option: $1" ;;
	esac
done
[ -n "$SEED" ] || mc_die "--seed is required"
SEED=$(mc_abspath "$SEED")
: "${OUTPUTDIR:=$(dirname -- "$SEED")/volatile-ro-out}"
mkdir -p "$OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")
MNT=$OUTPUTDIR/seed-ro

case $(uname -s) in
Darwin)
	image=$OUTPUTDIR/seed-ro.dmg
	rm -f "$image"
	mkdir -p "$MNT"
	mc_log "imaging $SEED read-only"
	hdiutil create -quiet -srcfolder "$SEED" -format UDRO -volname memcow-seed "$image"
	hdiutil attach -quiet -readonly -nobrowse -owners on -mountpoint "$MNT" "$image"
	trap 'hdiutil detach -quiet "$MNT" || hdiutil detach -quiet -force "$MNT"' EXIT
	if touch "$MNT/.probe" 2>/dev/null; then
		mc_die "$MNT is writable"
	fi
	"$HERE/volatile_tests.sh" --seed "$MNT" --outputdir "$OUTPUTDIR/tests" ${PASS[@]+"${PASS[@]}"}
	;;
Linux)
	mkdir -p "$MNT"
	# The mounts exist only inside the namespace and vanish with it.
	unshare --user --map-current-user --mount -- bash -euo pipefail -c '
		mount --bind "$1" "$2"
		mount -o remount,bind,ro "$2"
		if touch "$2/.probe" 2>/dev/null; then
			echo "volatile_readonly.sh: $2 is writable" >&2
			exit 2
		fi
		shift 2
		exec "$@"' _ "$SEED" "$MNT" \
		"$HERE/volatile_tests.sh" --seed "$MNT" --outputdir "$OUTPUTDIR/tests" ${PASS[@]+"${PASS[@]}"}
	;;
*)
	mc_die "unsupported platform: $(uname -s)"
	;;
esac
