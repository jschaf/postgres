#!/usr/bin/env bash
#
# check_leaks.sh --- assert zero AIO-handle leaks and zero buffer-pin leaks at
#                    backend exit, plus zero assertion failures / crashes.
#
# ===========================================================================
# WHAT THIS CHECK IS
# ===========================================================================
#
# It is a log scanner, deliberately.  Core PostgreSQL already instruments every
# leak class the plan (§7.1: "Fail = any assert, any diff, any AIO handle/pin
# leak at backend exit") cares about, provided the build has cassert on:
#
#   * Shared buffer pins.  bufmgr.c CheckForBufferLeaks() walks the backend's
#     private refcount array and hash at every transaction end
#     (AtEOXact_Buffers) and at proc exit (AtProcExit_Buffers), emits
#       WARNING:  buffer refcount leak: <buffer description>
#     for each survivor, then Assert()s that the count was zero.  The whole
#     function is #ifdef USE_ASSERT_CHECKING.
#
#   * Local (temp table) buffer pins.  localbuf.c CheckForLocalBufferLeaks(),
#     same structure, emits
#       WARNING:  local buffer refcount leak: <buffer description>
#
#   * AIO handles.  aio.c's ResourceOwner release callback fires at transaction
#     end and at resowner teardown for any handle still owned:
#       WARNING:  leaked AIO handle              (still PGAIO_HS_HANDED_OUT)
#       WARNING:  AIO handle was not submitted   (DEFINED or STAGED)
#     AtEOXact_Aio() additionally emits
#       WARNING:  open AIO batch at end of (sub-)transaction
#     and Assert()s num_staged_ios == 0.  pgaio_shutdown() Asserts that no
#     handle is handed out and then drains in_flight_ios.
#
#   * Any other ResourceOwner-tracked resource (files, relcache refs, DSM
#     segments, ...) via resowner.c:
#       WARNING:  resource was not closed: <resource description>
#
# Writing custom instrumentation on top of that would only add a second, less
# accurate copy.  So this script (a) forces the server config that makes those
# messages reach the log (log_min_messages=warning, set by common.sh), (b)
# greps for them, and (c) refuses to report "clean" on a build where the checks
# are compiled out.
#
# ===========================================================================
# WHAT IT CATCHES
# ===========================================================================
#
#  1. A buffer pin (shared or local) still held by a backend at the end of any
#     transaction, or at backend exit.  This is per-backend and includes the
#     auxiliary processes (checkpointer, bgwriter, autovacuum, IO workers),
#     because they run AtProcExit_Buffers too.
#  2. An AIO handle handed out, defined or staged but never submitted, still
#     owned by a ResourceOwner at transaction end or backend exit.
#  3. An AIO batch left open across a transaction boundary.
#  4. Any assertion failure ("TRAP:", "Assertion failed", "Failed Assert"),
#     including the Assert(RefCountErrors == 0) that follows a pin leak and the
#     Assert(!handed_out_io) in pgaio_shutdown().
#  5. A backend crash: PANIC, "was terminated by signal", "exited with exit
#     code", and (because the harness starts servers with
#     restart_after_crash=off) the resulting postmaster shutdown.
#  6. Core files left in PGDATA or the output directory.
#  7. A build with assertions compiled out being passed off as a clean run
#     (--engine-info / --require-asserts).
#
# ===========================================================================
# WHAT IT DOES *NOT* CATCH  (read this before trusting a green result)
# ===========================================================================
#
#  a. Leaks in a backend that neither commits/aborts a transaction nor exits.
#     A backend parked idle-in-transaction forever is never checked.  The
#     harness always shuts the server down with `pg_ctl -m fast`, which takes
#     every backend through proc exit, so this gap does not apply to harness
#     runs -- but it does apply if you point the script at some other log.
#  b. Balanced-but-wrong pin accounting: an extra PinBuffer paired with an
#     extra UnpinBuffer nets to zero and is invisible here.  Likewise an AIO
#     handle released on the wrong ResourceOwner.
#  c. Pins held by a *different* backend at the moment of interest.  The check
#     is per-backend and per-transaction-end, not a global "is any buffer
#     pinned right now" scan.  Phase 2's per-reset attach-count and
#     DropDatabaseBuffers gates are what cover that; they are not this script.
#  d. Memory leaks (palloc, DSA, dshash), dsm segment/slot leaks, file
#     descriptor leaks that resowner does not track, and mmap leaks.  Plan
#     §7.2 ("DSM slot count and RAM-dir size flat") needs its own instrument;
#     this is not it.
#  e. Use-after-free / wild writes into a freed arena.  That is an ASan or
#     poisoning job.
#  f. Anything at all on a build with cassert=false: CheckForBufferLeaks() and
#     CheckForLocalBufferLeaks() compile to nothing, so classes 1 and 4 vanish
#     entirely.  Classes 2, 3, 5 survive (those WARNINGs are unconditional),
#     but a "clean" verdict then means much less.  The script fails by default
#     if it can prove assertions are off, and warns if it cannot prove they are
#     on.
#  g. Leak WARNINGs that never reach the log because log_min_messages was
#     raised above `warning`, or because the log was rotated/truncated.  The
#     script sanity-checks that its input files exist and are readable, but it
#     cannot detect a lost prefix.
#  h. Leaks in processes that never write to this log (e.g. a server started
#     outside the harness with a different log destination), and leaks in
#     client-side code.
#
# Run with --explain to print the two lists above and exit.
# Run with --self-test to verify the scanner actually fires on each pattern.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

# NB: no `set -u`.  bash 3.2 (the system bash on macOS) errors on "${arr[@]}"
# for an empty array under nounset, and this harness passes optional arrays
# around constantly.  Every variable below is initialised explicitly instead.
set -o pipefail

MC_PROG=check_leaks.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
. "$HERE/common.sh"

usage()
{
	cat <<'EOF'
Usage: check_leaks.sh [options]

  --log FILE            server log to scan (repeatable; required unless
                        --explain/--self-test)
  --pgdata DIR          also scan DIR for core files (repeatable)
  --outputdir DIR       also scan DIR for core files (repeatable)
  --engine-info FILE    key=value file produced by run_regress_subset.sh;
                        debug_assertions is read from it
  --require-asserts     fail (not warn) unless debug_assertions=on is proven
  --strict-fatal        treat any FATAL: line as a failure.  Off by default:
                        some core regression tests provoke FATALs on purpose.
  --explain             print the catches / does-not-catch lists and exit 0
  --self-test           verify the scanner fires on every pattern, and passes a
                        clean log; exit 0 on success
  --quiet               only print the verdict line

Exit status: 0 clean, 1 leak/assert/crash found, 2 usage or environment error.
EOF
}

# --- the pattern table ------------------------------------------------------
#
# Each entry: <severity>|<extended regex>|<human label>
# severity: LEAK (a resource survived), CRASH (assert/panic/signal),
#           SOFT (reported, only fatal under --strict-fatal)
#
# Fixed strings from the tree at 2fb8da5a245:
#   src/backend/storage/buffer/bufmgr.c:4302,4318   "buffer refcount leak: %s"
#   src/backend/storage/buffer/localbuf.c:1010      "local buffer refcount leak: %s"
#   src/backend/storage/aio/aio.c:293               "leaked AIO handle"
#   src/backend/storage/aio/aio.c:301               "AIO handle was not submitted"
#   src/backend/storage/aio/aio.c:1216              "open AIO batch at end of (sub-)transaction"
#   src/backend/utils/resowner/resowner.c:395       "resource was not closed: %s"
PATTERNS=(
	'LEAK|buffer refcount leak:|shared buffer pin leak (bufmgr.c CheckForBufferLeaks)'
	'LEAK|local buffer refcount leak:|local buffer pin leak (localbuf.c CheckForLocalBufferLeaks)'
	'LEAK|leaked AIO handle|AIO handle still HANDED_OUT at resowner release (aio.c)'
	'LEAK|AIO handle was not submitted|AIO handle DEFINED/STAGED but never submitted (aio.c)'
	'LEAK|open AIO batch at end of \(sub-\)transaction|AIO batch mode left open (AtEOXact_Aio)'
	'LEAK|resource was not closed:|ResourceOwner-tracked resource leaked (resowner.c)'
	'CRASH|TRAP: |assertion failure'
	'CRASH|Failed [Aa]ssert|assertion failure'
	'CRASH|Assertion failed|assertion failure'
	'CRASH|PANIC:|PANIC'
	'CRASH|was terminated by signal|backend killed by signal'
	'CRASH|server process \(PID [0-9]+\) exited with exit code|backend exited abnormally'
	'CRASH|terminating any other active server processes|postmaster crash recovery triggered'
	'SOFT|FATAL:|FATAL message'
)

explain()
{
	sed -n '/^# ====/,/^# Run with --explain/p' "${BASH_SOURCE[0]}" |
		sed -e 's/^# \{0,1\}//'
}

self_test()
{
	local tmp rc=0
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/mcw-selftest.XXXXXX") || return 2

	# 1. a clean log must pass.
	cat >"$tmp/clean.log" <<'EOF'
2026-08-31 12:00:00.000 UTC [1] LOG:  starting PostgreSQL 20devel
2026-08-31 12:00:00.001 UTC [1] LOG:  database system is ready to accept connections
2026-08-31 12:00:01.000 UTC [7] WARNING:  there is no transaction in progress
2026-08-31 12:00:02.000 UTC [7] ERROR:  division by zero
2026-08-31 12:00:03.000 UTC [1] LOG:  database system is shut down
EOF
	if ! scan_logs "$tmp/clean.log" >"$tmp/clean.out" 2>&1; then
		echo "self-test FAILED: clean log was reported dirty" >&2
		cat "$tmp/clean.out" >&2
		rc=1
	else
		echo "self-test: clean log -> clean            ok"
	fi

	# 2. every pattern must fire.  Sample lines are the real message texts.
	local -a samples=(
		'WARNING:  buffer refcount leak: [1234] (rel=base/5/16384, blockNum=0, flags=0x93, refcount=1 1)'
		'WARNING:  local buffer refcount leak: [-2] (rel=base/5/16385, blockNum=3, flags=0x0, refcount=1 1)'
		'WARNING:  leaked AIO handle'
		'WARNING:  AIO handle was not submitted'
		'WARNING:  open AIO batch at end of (sub-)transaction'
		'WARNING:  resource was not closed: File 42 (t.c:1)'
		'TRAP: failed Assert("RefCountErrors == 0"), File: "bufmgr.c", Line: 4321, PID: 99'
		'TRAP: Failed Assert("!pgaio_my_backend->handed_out_io")'
		'Assertion failed: (RefCountErrors == 0), function CheckForBufferLeaks'
		'PANIC:  could not write to log file'
		'LOG:  server process (PID 123) was terminated by signal 11: Segmentation fault'
		'LOG:  server process (PID 123) exited with exit code 1'
		'LOG:  terminating any other active server processes'
	)
	local s i=0
	for s in "${samples[@]}"; do
		i=$((i + 1))
		printf '2026-08-31 12:00:00.000 UTC [7] %s\n' "$s" >"$tmp/case$i.log"
		if scan_logs "$tmp/case$i.log" >"$tmp/case$i.out" 2>&1; then
			echo "self-test FAILED: pattern not detected: $s" >&2
			rc=1
		fi
	done
	[ $rc -eq 0 ] && echo "self-test: ${#samples[@]} leak/crash patterns -> all detected   ok"

	# 3. FATAL is soft by default, hard under --strict-fatal.
	printf '2026-08-31 12:00:00.000 UTC [7] FATAL:  terminating connection\n' >"$tmp/fatal.log"
	if ! scan_logs "$tmp/fatal.log" >/dev/null 2>&1; then
		echo "self-test FAILED: FATAL should be soft by default" >&2
		rc=1
	fi
	STRICT_FATAL=1
	if scan_logs "$tmp/fatal.log" >/dev/null 2>&1; then
		echo "self-test FAILED: FATAL should be hard under --strict-fatal" >&2
		rc=1
	fi
	STRICT_FATAL=0
	[ $rc -eq 0 ] && echo "self-test: FATAL soft/strict handling                          ok"

	rm -rf "$tmp"
	return $rc
}

# scan_logs FILE...  -> 0 clean, 1 dirty
scan_logs()
{
	local dirty=0 entry sev re label hits f
	local -a logs=("$@")

	for entry in "${PATTERNS[@]}"; do
		sev=${entry%%|*}
		re=${entry#*|}; re=${re%%|*}
		label=${entry##*|}

		hits=$(grep -h -E -c -- "$re" "${logs[@]}" 2>/dev/null | awk '{s+=$1} END {print s+0}')
		[ "${hits:-0}" -gt 0 ] || continue

		case $sev in
			SOFT)
				if [ "$STRICT_FATAL" -eq 1 ]; then
					printf 'LEAKCHECK FAIL  %-6s %4s  %s\n' "$sev" "$hits" "$label"
					dirty=1
				else
					printf 'LEAKCHECK note  %-6s %4s  %s (not a failure without --strict-fatal)\n' \
						"$sev" "$hits" "$label"
					continue
				fi
				;;
			*)
				printf 'LEAKCHECK FAIL  %-6s %4s  %s\n' "$sev" "$hits" "$label"
				dirty=1
				;;
		esac
		for f in "${logs[@]}"; do
			grep -h -E -n -- "$re" "$f" 2>/dev/null | head -5 | sed "s|^|    $(basename -- "$f"):|"
		done
	done

	return $dirty
}

# --- argument parsing -------------------------------------------------------

declare -a LOGS=() COREDIRS=()
ENGINE_INFO=
REQUIRE_ASSERTS=0
STRICT_FATAL=0
QUIET=0
MODE=scan

while [ $# -gt 0 ]; do
	case $1 in
		--log)          LOGS+=("$2"); shift 2 ;;
		--pgdata|--outputdir) COREDIRS+=("$2"); shift 2 ;;
		--engine-info)  ENGINE_INFO=$2; shift 2 ;;
		--require-asserts) REQUIRE_ASSERTS=1; shift ;;
		--strict-fatal) STRICT_FATAL=1; shift ;;
		--explain)      MODE=explain; shift ;;
		--self-test)    MODE=selftest; shift ;;
		--quiet)        QUIET=1; shift ;;
		-h|--help)      usage; exit 0 ;;
		*)              usage >&2; mc_die "unknown option: $1" ;;
	esac
done

case $MODE in
	explain)  explain; exit 0 ;;
	selftest) self_test; exit $? ;;
esac

[ ${#LOGS[@]} -gt 0 ] || { usage >&2; mc_die "at least one --log is required"; }

rc=0
for f in "${LOGS[@]}"; do
	[ -r "$f" ] || mc_die "cannot read log: $f"
done

# --- assertion-build gate ---------------------------------------------------

asserts=unknown
if [ -n "$ENGINE_INFO" ] && [ -r "$ENGINE_INFO" ]; then
	asserts=$(sed -n 's/^debug_assertions=//p' "$ENGINE_INFO" | tail -1)
	[ -n "$asserts" ] || asserts=unknown
fi

case $asserts in
	on)
		[ $QUIET -eq 1 ] || echo "LEAKCHECK info  debug_assertions=on (pin-leak checks are compiled in)"
		;;
	off)
		echo "LEAKCHECK FAIL  build has debug_assertions=off: CheckForBufferLeaks() and" >&2
		echo "                CheckForLocalBufferLeaks() are compiled out, so a clean" >&2
		echo "                result here would not mean 'no pin leaks'." >&2
		rc=1
		;;
	*)
		if [ $REQUIRE_ASSERTS -eq 1 ]; then
			echo "LEAKCHECK FAIL  could not prove debug_assertions=on (--require-asserts)" >&2
			rc=1
		else
			echo "LEAKCHECK warn  debug_assertions not proven on; pin-leak coverage unverified" >&2
		fi
		;;
esac

# --- the scan ---------------------------------------------------------------

scan_out=$(scan_logs "${LOGS[@]}") || rc=1
[ -n "$scan_out" ] && printf '%s\n' "$scan_out"

# --- core files -------------------------------------------------------------

for d in "${COREDIRS[@]:-}"; do
	[ -n "$d" ] && [ -d "$d" ] || continue
	cores=$(find "$d" \( -name 'core' -o -name 'core.*' -o -name '*.core' \) -type f 2>/dev/null)
	if [ -n "$cores" ]; then
		echo "LEAKCHECK FAIL  CRASH        core file(s) under $d:"
		printf '    %s\n' $cores
		rc=1
	fi
done

# --- verdict ----------------------------------------------------------------

if [ $rc -eq 0 ]; then
	echo "LEAKCHECK CLEAN  no pin leaks, no AIO handle leaks, no asserts, no crashes in ${#LOGS[@]} log(s)"
else
	echo "LEAKCHECK DIRTY  see findings above"
fi
exit $rc
