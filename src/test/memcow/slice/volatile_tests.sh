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
#   V2  volatile WAL           WAL crosses segments; pg_wal never changes
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

ALL_CASES="V0_prerequisites V2_volatile_wal"

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
# the stock control: the same workload, the mode off
#
# An ordinary memcow server over a writable copy of the seed, laid out the way
# assemble_ramdir.sh lays out a runtime: relation pages still come from the
# seed, everything else goes to the copy.  A negative control proves its
# instrument by watching the copy change.
# ---------------------------------------------------------------------------

STOCK=$OUTPUTDIR/stock

stock_start()
{
	vstop
	stock_stop
	rm -rf "$STOCK" && cp -Rp "$SEED" "$STOCK" && chmod -R u+w "$STOCK" || return 1
	: >"$LOGFILE"
	"$MC_BINDIR/pg_ctl" -D "$STOCK" -l "$LOGFILE" -w -t 120 -o "-c port=$PORT \
		-c listen_addresses=127.0.0.1 -c unix_socket_directories= \
		-c shared_preload_libraries=memcow -c memcow.enabled=on \
		-c memcow.seed_directory=$SEED -c wal_level=minimal -c max_wal_senders=0 \
		-c max_prepared_transactions=0 -c fsync=off -c log_min_messages=warning \
		$*" start >/dev/null
}

stock_stop()
{
	[ -f "$STOCK/postmaster.pid" ] || return 0
	"$MC_BINDIR/pg_ctl" -D "$STOCK" -m "${1:-fast}" -w -t 120 stop >/dev/null 2>&1
}

# manifest DIR SUBTREE... --- the lines of mc_seed_manifest under SUBTREEs.
manifest()
{
	local dir=$1 all
	shift
	all=$(mktemp "$OUTPUTDIR/manifest.XXXXXX")
	mc_seed_manifest "$dir" "$all"
	if [ $# -eq 0 ]; then
		cat "$all"
	else
		local sub
		for sub in "$@"; do
			grep -E " $sub(/|\$)" "$all"
		done
	fi
	rm -f "$all"
}

control_value() # control_value DIR LABEL --- one pg_controldata field
{
	LC_ALL=C "$MC_BINDIR/pg_controldata" -D "$1" | sed -n "s/^$2: *//p"
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
# V2 --- volatile WAL
#
# Commits and segment switches drive the insert position several segments
# past the seed's WAL.  Nothing in pg_wal may change, the flush position must
# still advance (the WAL writer "writes" by moving it), and reading WAL back
# is refused because it exists only in the WAL buffers.  The server is
# stopped with SIGQUIT so no shutdown path can hide a write.
# ===========================================================================

V2_WORKLOAD="
CREATE TABLE v2 (i int, t text);
DO \$\$ BEGIN FOR i IN 1..500 LOOP INSERT INTO v2 VALUES (i, repeat('x', 200)); COMMIT; END LOOP; END \$\$;
SELECT pg_switch_wal() IS NOT NULL;
INSERT INTO v2 VALUES (-1, 'after one switch');
SELECT pg_switch_wal() IS NOT NULL;
INSERT INTO v2 VALUES (-2, 'after two switches');
SELECT pg_switch_wal() IS NOT NULL;
INSERT INTO v2 VALUES (-3, 'after three switches');
"

# segments_past DIR PORT --- how many WAL segments the insert position is
# past the segment holding the image's checkpoint.
segments_past()
{
	local seg ckpt
	seg=$(control_value "$1" 'Bytes per WAL segment')
	ckpt=$(control_value "$1" 'Latest checkpoint location')
	vpsql -p "$2" -c "SELECT (floor((pg_current_wal_insert_lsn() - '0/0') / $seg)
		- floor(('$ckpt'::pg_lsn - '0/0') / $seg))::int"
}

V2_volatile_wal()
{
	local before after out i past flushed
	before=$(manifest "$SEED" pg_wal)
	vstart
	ck "server starts" $?
	out=$(printf "%s" "$V2_WORKLOAD" | vpsql)
	ck_nomatch "the workload runs" 'ERROR' "$out"
	past=$(segments_past "$SEED" "$PORT")
	ck "the insert position is 3+ segments past the image ($past)" "$([ "${past:-0}" -ge 3 ]; echo $?)"
	ck_eq "the rows are there" 503 "$(vpsql -c 'SELECT count(*) FROM v2')"

	flushed=f
	for ((i = 0; i < 50; i++)); do
		flushed=$(vpsql -c "SELECT pg_current_wal_flush_lsn() >= '$(vpsql -c 'SELECT pg_current_wal_insert_lsn()')'::pg_lsn - 8192")
		[ "$flushed" = t ] && break
		sleep 0.1
	done
	ck_eq "the WAL writer advances the flush position" t "$flushed"

	out=$(vpsql -c 'CREATE EXTENSION pg_walinspect' \
		-c "SELECT count(*) FROM pg_get_wal_records_info(pg_current_wal_flush_lsn() - 64, pg_current_wal_flush_lsn())")
	ck_match "reading WAL is refused" 'reading WAL is not supported when "volatile_data_directory" is enabled' "$out"

	vstop QUIT
	after=$(manifest "$SEED" pg_wal)
	ck_eq "pg_wal is unchanged" "$(printf '%s' "$before" | shasum)" "$(printf '%s' "$after" | shasum)"
	ck_no_crash
}

nc_V2_volatile_wal()
{
	local before after out
	stock_start
	ck "stock server starts" $?
	before=$(manifest "$STOCK" pg_wal)
	out=$(printf "%s" "$V2_WORKLOAD" | vpsql)
	ck_nomatch "the workload runs" 'ERROR' "$out"
	stock_stop immediate
	after=$(manifest "$STOCK" pg_wal)
	ck "the stock server writes pg_wal" "$([ "$before" != "$after" ]; echo $?)"
}

# ===========================================================================
# driver
# ===========================================================================

trap 'vstop INT; stock_stop immediate' EXIT INT TERM

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
