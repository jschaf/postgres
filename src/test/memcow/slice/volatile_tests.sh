#!/usr/bin/env bash
#
# volatile_tests.sh --- slice tests for volatile_data_directory.
#
# A volatile_data_directory postmaster runs with the immutable seed itself as
# its data directory and writes nothing below it: relation pages live in the
# memcow overlay, WAL and SLRU pages in memory, pg_control in shared memory,
# and there is no lock file, so any number of postmasters can share one seed.
# Each case below drives such a server (harness/common.sh mc_volatile_start)
# against the seed built by seed/build_seed.sh.
#
#   V0  prerequisites          the mode refuses every setting that would write
#
# Every case has a negative control (--negative-control).  Where the property
# is "the mode prevents a write", the control runs the same workload on an
# ordinary memcow server over a writable copy of the seed and requires the
# write to happen, proving the instrument can see it.
#
# Usage:
#   volatile_tests.sh --seed DIR [--build-dir DIR] [--outputdir DIR]
#                     [--case NAME ...] [--negative-control] [--stop-on-fail]
#   volatile_tests.sh --list
#
# The seed may be on a read-only filesystem (see volatile_readonly.sh); cases
# that need a writable copy take it from --outputdir.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

# Cases and their helper functions are dispatched by name in the driver.
# shellcheck disable=SC2329
set -o pipefail

MC_PROG=volatile_tests.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HARNESS=$(cd -- "$HERE/../harness" && pwd)
# shellcheck source=../harness/common.sh
. "$HARNESS/common.sh"

ALL_CASES="V0_prerequisites"

SEED=
BUILD_DIR=
OUTPUTDIR=
DB=memcow_lane_00
CASES=()
NEGATIVE=0
STOP_ON_FAIL=0

while [ $# -gt 0 ]; do
	case $1 in
		--seed)        SEED=$2; shift 2 ;;
		--build-dir)   BUILD_DIR=$2; shift 2 ;;
		--outputdir)   OUTPUTDIR=$2; shift 2 ;;
		--case)        CASES[${#CASES[@]}]=$2; shift 2 ;;
		--list)        printf '%s\n' "$ALL_CASES" | tr ' ' '\n'; exit 0 ;;
		--negative-control) NEGATIVE=1; shift ;;
		--stop-on-fail) STOP_ON_FAIL=1; shift ;;
		-h|--help)     sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)             mc_die "unknown option: $1" ;;
	esac
done

[ -n "$SEED" ] || mc_die "--seed is required"
SEED=$(mc_abspath "$SEED")
[ -f "$SEED/memcow_seed.fingerprint" ] ||
	mc_die "no memcow_seed.fingerprint in $SEED -- not a seed built by build_seed.sh"

[ -n "$BUILD_DIR" ] || BUILD_DIR=$(mc_default_build_dir) ||
	mc_die "cannot find a meson build dir; pass --build-dir or set MEMCOW_BUILD_DIR"
mc_resolve_build "$BUILD_DIR"

: "${OUTPUTDIR:=$(dirname -- "$SEED")/volatile-out}"
mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")
case $OUTPUTDIR/ in
	"$SEED"/*) mc_die "--outputdir must not be inside the seed" ;;
esac

[ ${#CASES[@]} -gt 0 ] || read -r -a CASES <<<"$ALL_CASES"
for c in "${CASES[@]}"; do
	case " $ALL_CASES " in
		*" $c "*) ;;
		*) mc_die "unknown case: $c (see --list)" ;;
	esac
done

LOGFILE="$OUTPUTDIR/postmaster.log"
PIDFILE="$OUTPUTDIR/postmaster.pid"
PORT=$(mc_free_port) || mc_die "cannot find a free port"

# ---------------------------------------------------------------------------
# server control
# ---------------------------------------------------------------------------

# vstart [GUC=VAL ...] --- (re)start the volatile server on the seed.
vstart()
{
	vstop
	: >"$LOGFILE"
	mc_volatile_start "$SEED" "$PORT" "$LOGFILE" "$PIDFILE" "$@"
}
vstop() { mc_volatile_stop "$PIDFILE" "${1:-INT}"; }

# vpsql [-p PORT] [-d DB] SQL... --- tuples-only, errors folded into stdout.
vpsql()
{
	local port=$PORT db=$DB
	while :; do
		case $1 in
			-p) port=$2; shift 2 ;;
			-d) db=$2; shift 2 ;;
			*) break ;;
		esac
	done
	"$MC_BINDIR/psql" -X -q -A -t -h 127.0.0.1 -p "$port" -d "$db" -U "${PGUSER:-postgres}" \
		-v ON_ERROR_STOP=0 "$@" 2>&1
}

# vfails GUC=VAL... --- start with the given settings, which must be refused.
# Prints the server's log; returns 0 if the postmaster exited without ever
# accepting connections.
vfails()
{
	vstop
	: >"$LOGFILE"
	if mc_volatile_start "$SEED" "$PORT" "$LOGFILE" "$PIDFILE" "$@"; then
		vstop
		return 1
	fi
	rm -f "$PIDFILE"
	cat "$LOGFILE"
	return 0
}

# ---------------------------------------------------------------------------
# assertion helpers (as in slice_tests.sh)
# ---------------------------------------------------------------------------

CASE_FAIL=0

ck()
{
	if [ "$2" -eq 0 ]; then
		printf '    ok      %s\n' "$1"
	else
		printf '    NOT OK  %s\n' "$1"
		CASE_FAIL=1
	fi
}

ck_eq()
{
	if [ "$2" = "$3" ]; then
		printf '    ok      %s (= %s)\n' "$1" "$2"
	else
		printf '    NOT OK  %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
		CASE_FAIL=1
	fi
}

ck_match()
{
	if printf '%s' "$3" | grep -Eq "$2"; then
		printf '    ok      %s\n' "$1"
	else
		printf '    NOT OK  %s: no match for /%s/ in:\n' "$1" "$2"
		printf '%s\n' "$3" | tail -20 | sed 's/^/              /'
		CASE_FAIL=1
	fi
}

ck_nomatch()
{
	if printf '%s' "$3" | grep -Eq "$2"; then
		printf '    NOT OK  %s: unexpected match for /%s/ in:\n' "$1" "$2"
		printf '%s\n' "$3" | tail -20 | sed 's/^/              /'
		CASE_FAIL=1
	else
		printf '    ok      %s\n' "$1"
	fi
}

ck_no_crash()
{
	local hits
	if hits=$(mc_check_log "$LOGFILE"); then
		printf '    ok      no asserts, PANICs, signal deaths or leaks in the server log\n'
	else
		printf '    NOT OK  server log shows an assert/crash/leak:\n'
		printf '%s\n' "$hits" | sed 's/^/              /'
		CASE_FAIL=1
	fi
}

# ===========================================================================
# V0 --- prerequisites
#
# Each setting below would make a volatile server write below DataDir or
# outside memory, so the postmaster must refuse it before creating anything.
# The control starts with the baseline settings, which must be accepted.
# ===========================================================================

V0_REFUSALS=(
	'memcow.enabled=off|a volatile default storage manager'
	'wal_level=replica|"wal_level" = minimal'
	'max_prepared_transactions=2|"max_prepared_transactions" = 0'
	'shared_memory_type=sysv|"shared_memory_type" = mmap'
	'dynamic_shared_memory_type=mmap|"dynamic_shared_memory_type" other than mmap'
	"unix_socket_directories=$OUTPUTDIR|empty \"unix_socket_directories\""
	'logging_collector=on|"logging_collector" = off'
	"external_pid_file=$OUTPUTDIR/external.pid|\"external_pid_file\" to be unset"
)

V0_prerequisites()
{
	local entry setting want out
	for entry in "${V0_REFUSALS[@]}"; do
		setting=${entry%%|*}
		want=${entry#*|}
		if out=$(vfails "$setting"); then
			ck_match "$setting is refused" "FATAL: +\"volatile_data_directory\" requires $want" "$out"
		else
			ck "$setting is refused" 1
		fi
	done

	out=$(LC_ALL=C "$MC_BINDIR/postgres" --single -D "$SEED" \
		-c volatile_data_directory=on postgres </dev/null 2>&1)
	ck_match "single-user mode is refused" 'requires a postmaster' "$out"

	vstart
	ck "the baseline settings are accepted" $?
	ck_eq "the server answers" 1 "$(vpsql -c 'SELECT 1')"
	vstop
	ck_no_crash
}

nc_V0_prerequisites()
{
	# Without the mode the same settings start an ordinary server.
	vstop
	: >"$LOGFILE"
	local copy=$OUTPUTDIR/stock
	rm -rf "$copy" && cp -Rp "$SEED" "$copy"
	if "$MC_BINDIR/pg_ctl" -D "$copy" -l "$LOGFILE" -w -t 120 \
		-o "-c port=$PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories= -c wal_level=replica -c max_wal_senders=0" \
		start >/dev/null 2>&1; then
		ck "wal_level=replica starts without the mode" 0
		"$MC_BINDIR/pg_ctl" -D "$copy" -m fast -w stop >/dev/null 2>&1
	else
		ck "wal_level=replica starts without the mode" 1
	fi
	rm -rf "$copy"
}

# ===========================================================================
# driver
# ===========================================================================

trap 'vstop INT' EXIT INT TERM

mc_banner "memcow volatile_data_directory slice tests" \
	"seed:     $SEED" \
	"bindir:   $MC_BINDIR" \
	"cases:    ${CASES[*]}" \
	"mode:     $([ $NEGATIVE -eq 1 ] && echo 'NEGATIVE CONTROL' || echo normal)"

PASSED=0
FAILED=0
FAILED_NAMES=

for c in "${CASES[@]}"; do
	CASE_FAIL=0
	if [ $NEGATIVE -eq 1 ]; then
		printf '\n--- %s [negative control] ---\n' "$c"
		"nc_$c"
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
if [ $RC -eq 0 ]; then
	mc_banner "VOLATILE TESTS PASS -- $PASSED case(s), 0 failed"
else
	mc_banner "VOLATILE TESTS FAIL -- $PASSED passed, $FAILED failed:${FAILED_NAMES}" \
		"logs: $OUTPUTDIR"
fi
exit $RC
