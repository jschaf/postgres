#!/usr/bin/env bash
#
# io_matrix.sh --- the plan §7.1 matrix driver:
#                  io_method  ×  shared_buffers (cold/hot)  ×  temp tables.
#
# Every cell of the matrix is ENUMERATED and its disposition PRINTED before
# anything runs, and again in the summary.  A cell that cannot run on this host
# is reported as UNAVAILABLE with the reason; it is never silently dropped.
# That matters most for io_method=io_uring: the enum member only exists when
# the build defines IOMETHOD_IO_URING_ENABLED, which requires USE_LIBURING, and
# liburing is Linux-only.  On macOS the cell is unrunnable, so this script says
# so in as many words and reports the matrix coverage as INCOMPLETE.  Pass
# --require-io-uring on a platform where it should exist (CI on Linux) to turn
# that into a hard failure.
#
# The available methods are probed from the running server
# (SELECT enumvals FROM pg_settings WHERE name = 'io_method'), not assumed.
#
# THE AXES
#
#   io_method       Every value this build accepts.  memcow satisfies reads
#                   from memory via a synthetic AIO completion, so the method
#                   layer should never be reached (plan §1) -- which is exactly
#                   why every method has to produce identical output.
#
#   shared_buffers  cold = 1MB   -- 128 buffers; the working set never fits, so
#                                   pages are evicted and re-read constantly.
#                                   This is the smgrstartreadv-heavy corner.
#                   hot  = 512MB -- everything stays resident after first
#                                   touch; the write/extend paths dominate and
#                                   reads mostly never reach smgr.
#
#   temp tables     baseline = temp_buffers at its default.
#                   stress   = temp_buffers=100 (the minimum), which forces
#                              local-buffer eviction and therefore drives
#                              localbuf.c's write path (localbuf.c:208) rather
#                              than letting temp relations live entirely in
#                              local memory.  The subset's temp/copy2/truncate
#                              tests are what exercise it.
#
# PHASE 0 vs PHASE 1
#
#   Phase 0: both sides of every cell are stock md; the gate is that they are
#            byte-identical.  That validates the instrument.
#   Phase 1: add --b-guc memcow=on.  Nothing else about the invocation changes.
#
# A NOTE ON autovacuum (a real finding, not a nit)
#
#   Plan §6 requires autovacuum=off under memcow.  autovacuum=off is NOT
#   output-neutral for the core regression tests: index_update_stats()
#   (src/backend/catalog/index.c:2890-2908) deliberately skips updating a
#   heap's relpages/reltuples during CREATE INDEX when AutoVacuumingActive() is
#   false, so `cluster` gets a bitmap scan where expected/cluster.out has an
#   index scan.  This matrix therefore leaves autovacuum at its default.  When
#   Phase 1 turns it off, run with
#       --guc autovacuum=off --allow-expected-failure cluster
#   which keeps the A-vs-B gate intact while acknowledging the known,
#   engine-independent divergence from upstream expected output.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

# See check_leaks.sh for why there is no `set -u`.
set -o pipefail

MC_PROG=io_matrix.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
. "$HERE/common.sh"

usage()
{
	cat <<'EOF'
Usage: io_matrix.sh --outputdir DIR --pgdata-template DIR [options]

  --outputdir DIR           matrix results root (required)
  --pgdata-template DIR     PGDATA template every cell is copied from (required)
  --init                    initdb the template if it does not exist
  --subset NAME|FILE        default: phase0
  --build-dir DIR           meson build dir

  --cold-shared-buffers V   default 1MB
  --hot-shared-buffers V    default 512MB
  --stress-temp-buffers V   default 100 (the minimum, = 800kB)

  --guc NAME=VALUE          extra GUC for BOTH sides of every cell (repeatable)
  --b-guc NAME=VALUE        extra GUC for side B only (Phase 1: memcow=on)
  --allow-expected-failure T  passed through to diff_engines.sh (repeatable)

  --only GLOB               run only cells whose id matches GLOB, e.g.
                            'sync/*' or '*/cold/*'.  Non-matching cells are
                            still enumerated, as SKIPPED-BY-FILTER.
  --dry-run                 enumerate and print dispositions, run nothing
  --require-io-uring        fail if the io_uring cells cannot run here
  --keep-going              run every runnable cell even after one fails
                            (default: also keep going; use --stop-on-fail
                            for the opposite)
  --stop-on-fail            abort at the first failing cell

Exit status: 0 every runnable cell passed, 1 a cell failed (or io_uring was
required and unavailable), 2 could not run.
EOF
}

OUTPUTDIR=
TEMPLATE=
DO_INIT=0
SUBSET=phase0
BUILD_DIR=
COLD_SB=1MB
HOT_SB=512MB
STRESS_TB=100
ONLY='*'
DRY_RUN=0
REQUIRE_URING=0
STOP_ON_FAIL=0
SHARED_GUCS=()
B_GUCS=()
ALLOW=()

while [ $# -gt 0 ]; do
	case $1 in
		--outputdir)        OUTPUTDIR=$2; shift 2 ;;
		--pgdata-template)  TEMPLATE=$2; shift 2 ;;
		--init)             DO_INIT=1; shift ;;
		--subset)           SUBSET=$2; shift 2 ;;
		--build-dir)        BUILD_DIR=$2; shift 2 ;;
		--cold-shared-buffers) COLD_SB=$2; shift 2 ;;
		--hot-shared-buffers)  HOT_SB=$2; shift 2 ;;
		--stress-temp-buffers) STRESS_TB=$2; shift 2 ;;
		--guc)              SHARED_GUCS[${#SHARED_GUCS[@]}]=$2; shift 2 ;;
		--b-guc)            B_GUCS[${#B_GUCS[@]}]=$2; shift 2 ;;
		--allow-expected-failure) ALLOW[${#ALLOW[@]}]=$2; shift 2 ;;
		--only)             ONLY=$2; shift 2 ;;
		--dry-run)          DRY_RUN=1; shift ;;
		--require-io-uring) REQUIRE_URING=1; shift ;;
		--keep-going)       STOP_ON_FAIL=0; shift ;;
		--stop-on-fail)     STOP_ON_FAIL=1; shift ;;
		-h|--help)          usage; exit 0 ;;
		*)                  usage >&2; mc_die "unknown option: $1" ;;
	esac
done

[ -n "$OUTPUTDIR" ] || { usage >&2; mc_die "--outputdir is required"; }
[ -n "$TEMPLATE" ]  || { usage >&2; mc_die "--pgdata-template is required"; }

[ -n "$BUILD_DIR" ] || BUILD_DIR=$(mc_default_build_dir) ||
	mc_die "cannot find a meson build dir; pass --build-dir or set MEMCOW_BUILD_DIR"
mc_resolve_build "$BUILD_DIR"

mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")

# ---------------------------------------------------------------------------
# probe: ask the server which io_methods it actually offers
# ---------------------------------------------------------------------------

TEMPLATE=$(mc_abspath "$TEMPLATE")
if [ ! -d "$TEMPLATE" ] && [ $DO_INIT -eq 1 ]; then
	mkdir -p "$(dirname -- "$TEMPLATE")"
	mc_initdb "$TEMPLATE"
fi
[ -f "$TEMPLATE/PG_VERSION" ] || mc_die "not a data directory: $TEMPLATE (pass --init)"

PROBE_DIR="$OUTPUTDIR/probe"
rm -rf "$PROBE_DIR"
mkdir -p "$PROBE_DIR"
cp -R "$TEMPLATE" "$PROBE_DIR/pgdata" || mc_die "cannot copy the template"
rm -f "$PROBE_DIR/pgdata/postmaster.pid"

PROBE_PORT=$(mc_free_port)
PROBE_SOCK=$(mc_make_sockdir)
mc_server_start "$PROBE_DIR/pgdata" "$PROBE_PORT" "$PROBE_SOCK" "$PROBE_DIR/postmaster.log" ||
	mc_die "probe postmaster would not start"

AVAILABLE_METHODS=$(mc_psql "$PROBE_SOCK" "$PROBE_PORT" postgres \
	"SELECT array_to_string(enumvals, ' ') FROM pg_settings WHERE name = 'io_method'")
SERVER_VERSION=$(mc_psql "$PROBE_SOCK" "$PROBE_PORT" postgres "SHOW server_version")
DEBUG_ASSERTIONS=$(mc_psql "$PROBE_SOCK" "$PROBE_PORT" postgres "SHOW debug_assertions")
DEFAULT_TB=$(mc_psql "$PROBE_SOCK" "$PROBE_PORT" postgres "SHOW temp_buffers")
HAS_MEMCOW=$(mc_psql "$PROBE_SOCK" "$PROBE_PORT" postgres \
	"SELECT count(*) FROM pg_settings WHERE name = 'memcow'")

mc_server_stop "$PROBE_DIR/pgdata" "$PROBE_DIR/postmaster.log"
rm -rf "$PROBE_SOCK" "$PROBE_DIR/pgdata"

[ -n "$AVAILABLE_METHODS" ] || mc_die "could not probe io_method enumvals"

# The full universe of io_method values PostgreSQL knows about
# (src/include/storage/aio.h: IOMETHOD_SYNC, IOMETHOD_WORKER, IOMETHOD_IO_URING).
ALL_METHODS="sync worker io_uring"

method_available()
{
	case " $AVAILABLE_METHODS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

method_unavailable_reason()
{
	case $1 in
		io_uring)
			echo "not offered by this build: IOMETHOD_IO_URING_ENABLED needs USE_LIBURING (aio.h:26), and liburing is Linux-only; this host is $(uname -s)" ;;
		*)
			echo "not in pg_settings.enumvals for io_method on this build" ;;
	esac
}

# ---------------------------------------------------------------------------
# enumerate the matrix
# ---------------------------------------------------------------------------

CELL_ID=()
CELL_METHOD=()
CELL_SB=()
CELL_TB=()
CELL_DISP=()
CELL_REASON=()

for m in $ALL_METHODS; do
	for sbname in cold hot; do
		case $sbname in
			cold) sb=$COLD_SB ;;
			hot)  sb=$HOT_SB ;;
		esac
		for tbname in baseline stress; do
			case $tbname in
				baseline) tb=; tbshow="$DEFAULT_TB (default)" ;;
				stress)   tb=$STRESS_TB; tbshow="$STRESS_TB blocks" ;;
			esac

			id="$m/$sbname/$tbname"
			disp=RUN
			reason=

			if ! method_available "$m"; then
				disp=UNAVAILABLE
				reason=$(method_unavailable_reason "$m")
			else
				case $id in
					$ONLY) ;;
					*) disp=SKIPPED-BY-FILTER; reason="does not match --only '$ONLY'" ;;
				esac
			fi

			i=${#CELL_ID[@]}
			CELL_ID[$i]=$id
			CELL_METHOD[$i]=$m
			CELL_SB[$i]=$sb
			CELL_TB[$i]=$tbshow
			CELL_DISP[$i]=$disp
			CELL_REASON[$i]=$reason
		done
	done
done

print_enumeration()
{
	local title=$1 i
	mc_banner "$title" \
		"build:            $MC_BUILD_DIR" \
		"server_version:   $SERVER_VERSION   debug_assertions: $DEBUG_ASSERTIONS" \
		"io_method values this build accepts: $AVAILABLE_METHODS" \
		"io_method values PostgreSQL defines: $ALL_METHODS" \
		"memcow GUC present: $([ "${HAS_MEMCOW:-0}" -gt 0 ] && echo yes || echo 'no (Phase 0: A and B are both stock md)')" \
		"subset:           $SUBSET" \
		"shared_buffers:   cold=$COLD_SB  hot=$HOT_SB" \
		"temp_buffers:     baseline=$DEFAULT_TB  stress=$STRESS_TB" \
		"cells:            ${#CELL_ID[@]} enumerated"

	printf '%-26s %-9s %-9s %-16s %s\n' CELL io_method shared_buf temp_buffers DISPOSITION
	printf '%-26s %-9s %-9s %-16s %s\n' -------------------------- --------- --------- ---------------- -----------
	for i in $(seq 0 $(( ${#CELL_ID[@]} - 1 ))); do
		printf '%-26s %-9s %-9s %-16s %s\n' \
			"${CELL_ID[$i]}" "${CELL_METHOD[$i]}" "${CELL_SB[$i]}" "${CELL_TB[$i]}" \
			"${CELL_DISP[$i]}${CELL_REASON[$i]:+  <- ${CELL_REASON[$i]}}"
	done
	printf '\n'
}

print_enumeration "MATRIX ENUMERATION (before running anything)"

n_unavail=0
for i in $(seq 0 $(( ${#CELL_ID[@]} - 1 ))); do
	[ "${CELL_DISP[$i]}" = UNAVAILABLE ] && n_unavail=$((n_unavail + 1))
done

if [ $n_unavail -gt 0 ]; then
	mc_banner \
		"!!  MATRIX COVERAGE IS INCOMPLETE ON THIS HOST  !!" \
		"" \
		"$n_unavail of ${#CELL_ID[@]} cells CANNOT be run here.  They are listed above as" \
		"UNAVAILABLE with the reason.  This host is $(uname -s) $(uname -r)." \
		"" \
		"These cells are NOT skipped, NOT passed and NOT failed -- they are" \
		"unrun.  The plan §7.1 matrix is only fully discharged on a host where" \
		"every io_method this tree defines is compiled in (i.e. Linux with" \
		"liburing, configured -Dliburing=enabled).  Re-run there, or run with" \
		"--require-io-uring to make this a hard failure."
fi

if [ $DRY_RUN -eq 1 ]; then
	mc_log "--dry-run: stopping after enumeration"
	[ $REQUIRE_URING -eq 1 ] && [ $n_unavail -gt 0 ] && exit 1
	exit 0
fi

# ---------------------------------------------------------------------------
# run the runnable cells
# ---------------------------------------------------------------------------

CELL_RESULT=()
RC=0

for i in $(seq 0 $(( ${#CELL_ID[@]} - 1 ))); do
	id=${CELL_ID[$i]}
	if [ "${CELL_DISP[$i]}" != RUN ]; then
		CELL_RESULT[$i]=${CELL_DISP[$i]}
		continue
	fi

	celldir="$OUTPUTDIR/$(echo "$id" | tr '/' '_')"
	mc_banner "CELL $id" "-> $celldir"

	cellgucs=("io_method=${CELL_METHOD[$i]}" "shared_buffers=${CELL_SB[$i]}")
	case ${CELL_ID[$i]} in
		*/stress) cellgucs[${#cellgucs[@]}]="temp_buffers=$STRESS_TB" ;;
	esac

	args=(--outputdir "$celldir" --pgdata-template "$TEMPLATE" --subset "$SUBSET"
	      --a-label "a-stock[$id]" --b-label "b-under-test[$id]")
	[ -n "$BUILD_DIR" ] && { args[${#args[@]}]=--build-dir; args[${#args[@]}]=$BUILD_DIR; }
	for g in "${cellgucs[@]}" ${SHARED_GUCS[@]+"${SHARED_GUCS[@]}"}; do
		args[${#args[@]}]=--guc; args[${#args[@]}]=$g
	done
	for g in ${B_GUCS[@]+"${B_GUCS[@]}"}; do
		args[${#args[@]}]=--b-guc; args[${#args[@]}]=$g
	done
	for t in ${ALLOW[@]+"${ALLOW[@]}"}; do
		args[${#args[@]}]=--allow-expected-failure; args[${#args[@]}]=$t
	done

	if bash "$HERE/diff_engines.sh" "${args[@]}"; then
		CELL_RESULT[$i]=PASS
	else
		CELL_RESULT[$i]=FAIL
		RC=1
		[ $STOP_ON_FAIL -eq 1 ] && { mc_warn "--stop-on-fail: aborting after $id"; break; }
	fi
done

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

mc_banner "MATRIX SUMMARY"
printf '%-26s %-9s %-9s %-16s %s\n' CELL io_method shared_buf temp_buffers RESULT
printf '%-26s %-9s %-9s %-16s %s\n' -------------------------- --------- --------- ---------------- ------
n_pass=0; n_fail=0; n_skip=0
for i in $(seq 0 $(( ${#CELL_ID[@]} - 1 ))); do
	r=${CELL_RESULT[$i]:-NOT-RUN}
	case $r in
		PASS) n_pass=$((n_pass + 1)) ;;
		FAIL) n_fail=$((n_fail + 1)) ;;
		SKIPPED-BY-FILTER) n_skip=$((n_skip + 1)) ;;
	esac
	printf '%-26s %-9s %-9s %-16s %s\n' \
		"${CELL_ID[$i]}" "${CELL_METHOD[$i]}" "${CELL_SB[$i]}" "${CELL_TB[$i]}" \
		"$r${CELL_REASON[$i]:+  <- ${CELL_REASON[$i]}}"
done
printf '\n%d passed, %d failed, %d skipped by --only, %d UNAVAILABLE on this host\n' \
	"$n_pass" "$n_fail" "$n_skip" "$n_unavail"

if [ $n_unavail -gt 0 ]; then
	printf 'MATRIX COVERAGE: INCOMPLETE (%d unrun cells -- see the enumeration above)\n' "$n_unavail"
	if [ $REQUIRE_URING -eq 1 ]; then
		printf '--require-io-uring was given: treating unavailable cells as a failure\n'
		RC=1
	fi
else
	printf 'MATRIX COVERAGE: COMPLETE\n'
fi

[ $RC -eq 0 ] && printf 'MATRIX RESULT: PASS\n' || printf 'MATRIX RESULT: FAIL\n'
exit $RC
