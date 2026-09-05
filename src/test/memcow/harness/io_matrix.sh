#!/usr/bin/env bash
#
# io_matrix.sh --- the plan §7.1 differential gate:
#     io_method  x  shared_buffers (cold/hot)  x  temp tables,
# every cell run once on stock md (side A) and once on memcow (side B), and
# the outputs required to be identical.
#
# Every cell of the matrix is ENUMERATED and its disposition PRINTED before
# anything runs, and again in the summary.  A cell that cannot run on this
# host is reported as UNAVAILABLE with the reason; it is never silently
# dropped.  That matters most for io_method=io_uring: the enum member only
# exists when the build has liburing, which is Linux-only, so on macOS four of
# the twelve cells are unrunnable and the matrix reports its coverage as
# INCOMPLETE.  Pass --require-io-uring on a Linux runner to make that a hard
# failure.  The available methods are probed from a running server, not
# assumed.
#
# THE AXES
#
#   io_method       Every value this build accepts.  memcow satisfies reads
#                   from memory via a synthetic AIO completion, so the method
#                   layer should never be reached (plan §1) -- which is exactly
#                   why every method has to produce identical output.
#   shared_buffers  cold = 1MB: the working set never fits, so pages are
#                   evicted and re-read constantly (the smgrstartreadv-heavy
#                   corner).  hot = 512MB: everything stays resident; the
#                   write/extend paths dominate.
#   temp tables     baseline = temp_buffers at its default.
#                   stress   = temp_buffers=100 (the minimum), which forces
#                   local-buffer eviction and drives localbuf.c's write path.
#
# THE GATE, per cell, none of it optional:
#
#   G1  results/ trees identical between A and B after normalising each
#       run's own absolute paths -- or differing ONLY in hunks that a rule in
#       divergences.txt explains, for tests named by
#       --allow-engine-divergence (classify_diff.py; a stale allowance, i.e. a
#       named test that ran and did NOT differ, fails the gate too)
#   G2  per-test pass/fail disposition identical between A and B
#   G3  neither side fails against src/test/regress/expected/, except tests
#       named by --allow-expected-failure (never relaxes A-vs-B)
#   G4  neither side's server log shows a pin leak, AIO handle leak, assert
#       or crash (mc_check_log, run by run_regress_subset.sh)
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

set -o pipefail

MC_PROG=io_matrix.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
. "$HERE/common.sh"

usage()
{
	cat <<'USAGE'
Usage: io_matrix.sh --outputdir DIR --a-pgdata-template DIR --b-pgdata-template DIR [options]

  --outputdir DIR           matrix results root (required)
  --a-pgdata-template DIR   side A (stock md) template: the seed's relation
                            files present (slice/make_templates.sh)
  --b-pgdata-template DIR   side B (memcow) template: NO relation files, so a
                            page B serves demonstrably came from the seed
                            mapping or the overlay
  --subset NAME|FILE        default: phase0
  --build-dir DIR           meson build dir
  --guc NAME=VALUE          extra GUC for BOTH sides of every cell (repeatable)
  --a-guc / --b-guc N=V     extra GUC for one side only (repeatable)
  --a-name / --b-name NAME  label prefix for each side
  --allow-expected-failure T  test allowed to differ from upstream expected
                            output (repeatable).  Never relaxes A-vs-B.
  --allow-engine-divergence T test allowed to differ BETWEEN ENGINES, but only
                            in ways divergences.txt explains (repeatable).
                            Implies --allow-expected-failure for T.
  --only GLOB               run only cells whose id matches GLOB, e.g.
                            'sync/*'; non-matching cells are still enumerated
  --dry-run                 enumerate and print dispositions, run nothing
  --require-io-uring        fail if the io_uring cells cannot run here
  --stop-on-fail            abort at the first failing cell

Exit status: 0 every runnable cell passed, 1 a cell failed (or io_uring was
required and unavailable), 2 could not run.
USAGE
}

OUTPUTDIR= A_TEMPLATE= B_TEMPLATE= BUILD_DIR=
A_NAME=a-md B_NAME=b-memcow
SUBSET=phase0
COLD_SB=1MB HOT_SB=512MB STRESS_TB=100
ONLY='*' DRY_RUN=0 REQUIRE_URING=0 STOP_ON_FAIL=0
SHARED_GUCS=() A_GUCS=() B_GUCS=() ALLOW=() EDIV=()

while [ $# -gt 0 ]; do
	case $1 in
		--outputdir)        OUTPUTDIR=$2; shift 2 ;;
		--a-pgdata-template) A_TEMPLATE=$2; shift 2 ;;
		--b-pgdata-template) B_TEMPLATE=$2; shift 2 ;;
		--a-name)           A_NAME=$2; shift 2 ;;
		--b-name)           B_NAME=$2; shift 2 ;;
		--subset)           SUBSET=$2; shift 2 ;;
		--build-dir)        BUILD_DIR=$2; shift 2 ;;
		--guc)              SHARED_GUCS[${#SHARED_GUCS[@]}]=$2; shift 2 ;;
		--a-guc)            A_GUCS[${#A_GUCS[@]}]=$2; shift 2 ;;
		--b-guc)            B_GUCS[${#B_GUCS[@]}]=$2; shift 2 ;;
		--allow-expected-failure) ALLOW[${#ALLOW[@]}]=$2; shift 2 ;;
		--allow-engine-divergence) EDIV[${#EDIV[@]}]=$2; ALLOW[${#ALLOW[@]}]=$2; shift 2 ;;
		--only)             ONLY=$2; shift 2 ;;
		--dry-run)          DRY_RUN=1; shift ;;
		--require-io-uring) REQUIRE_URING=1; shift ;;
		--stop-on-fail)     STOP_ON_FAIL=1; shift ;;
		-h|--help)          usage; exit 0 ;;
		*)                  usage >&2; mc_die "unknown option: $1" ;;
	esac
done

[ -n "$OUTPUTDIR" ] || { usage >&2; mc_die "--outputdir is required"; }
[ -n "$A_TEMPLATE" ] && [ -n "$B_TEMPLATE" ] ||
	{ usage >&2; mc_die "both --a-pgdata-template and --b-pgdata-template are required"; }
[ -n "$BUILD_DIR" ] || BUILD_DIR=$(mc_default_build_dir) ||
	mc_die "cannot find a meson build dir; pass --build-dir or set MEMCOW_BUILD_DIR"
mc_resolve_build "$BUILD_DIR"
DIVERGENCES="$HERE/divergences.txt"
[ -f "$DIVERGENCES" ] || mc_die "no divergence rules file: $DIVERGENCES"

mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")
A_TEMPLATE=$(mc_abspath "$A_TEMPLATE")
B_TEMPLATE=$(mc_abspath "$B_TEMPLATE")
[ -f "$A_TEMPLATE/PG_VERSION" ] || mc_die "not a data directory: $A_TEMPLATE"
[ -f "$B_TEMPLATE/PG_VERSION" ] || mc_die "not a data directory: $B_TEMPLATE"

# ---------------------------------------------------------------------------
# probe: ask the server which io_methods it actually offers.  Stock md, no
# extra GUCs, so it has to use side A's template.
# ---------------------------------------------------------------------------

PROBE_DIR="$OUTPUTDIR/probe"
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
cp -R "$A_TEMPLATE" "$PROBE_DIR/pgdata" || mc_die "cannot copy the template"
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
mc_server_stop "$PROBE_DIR/pgdata" "$PROBE_DIR/postmaster.log"
rm -rf "$PROBE_SOCK" "$PROBE_DIR/pgdata"
[ -n "$AVAILABLE_METHODS" ] || mc_die "could not probe io_method enumvals"

# the full universe (src/include/storage/aio.h)
ALL_METHODS="sync worker io_uring"

# ---------------------------------------------------------------------------
# enumerate the matrix
# ---------------------------------------------------------------------------

CELL_ID=() CELL_METHOD=() CELL_SB=() CELL_TB=() CELL_DISP=() CELL_REASON=()
for m in $ALL_METHODS; do
	for sbname in cold hot; do
		[ $sbname = cold ] && sb=$COLD_SB || sb=$HOT_SB
		for tbname in baseline stress; do
			[ $tbname = baseline ] && tbshow="$DEFAULT_TB (default)" || tbshow="$STRESS_TB blocks"
			id="$m/$sbname/$tbname"
			disp=RUN; reason=
			case " $AVAILABLE_METHODS " in
				*" $m "*)
					case $id in
						$ONLY) ;;
						*) disp=SKIPPED-BY-FILTER; reason="does not match --only '$ONLY'" ;;
					esac ;;
				*)
					disp=UNAVAILABLE
					if [ "$m" = io_uring ]; then
						reason="not offered by this build: IOMETHOD_IO_URING_ENABLED needs USE_LIBURING, and liburing is Linux-only; this host is $(uname -s)"
					else
						reason="not in pg_settings.enumvals for io_method on this build"
					fi ;;
			esac
			i=${#CELL_ID[@]}
			CELL_ID[$i]=$id; CELL_METHOD[$i]=$m; CELL_SB[$i]=$sb; CELL_TB[$i]=$tbshow
			CELL_DISP[$i]=$disp; CELL_REASON[$i]=$reason
		done
	done
done

print_cells()	# print_cells TITLE COLUMN-HEADER RESULT-ARRAY-NAME
{
	local title=$1 col=$2 arr=$3 i r
	mc_banner "$title" \
		"build:            $MC_BUILD_DIR" \
		"server_version:   $SERVER_VERSION   debug_assertions: $DEBUG_ASSERTIONS" \
		"io_method values this build accepts: $AVAILABLE_METHODS (PostgreSQL defines: $ALL_METHODS)" \
		"A template:       $A_TEMPLATE" \
		"B template:       $B_TEMPLATE" \
		"B-only GUCs:      ${B_GUCS[*]-<none>}" \
		"subset:           $SUBSET" \
		"shared_buffers:   cold=$COLD_SB  hot=$HOT_SB   temp_buffers: baseline=$DEFAULT_TB stress=$STRESS_TB"
	printf '%-26s %-9s %-9s %-16s %s\n' CELL io_method shared_buf temp_buffers "$col"
	printf '%-26s %-9s %-9s %-16s %s\n' -------------------------- --------- --------- ---------------- -----------
	for i in $(seq 0 $(( ${#CELL_ID[@]} - 1 ))); do
		eval "r=\${$arr[$i]:-NOT-RUN}"
		printf '%-26s %-9s %-9s %-16s %s\n' \
			"${CELL_ID[$i]}" "${CELL_METHOD[$i]}" "${CELL_SB[$i]}" "${CELL_TB[$i]}" \
			"$r${CELL_REASON[$i]:+  <- ${CELL_REASON[$i]}}"
	done
	printf '\n'
}

print_cells "MATRIX ENUMERATION (before running anything)" DISPOSITION CELL_DISP

n_unavail=0
for i in $(seq 0 $(( ${#CELL_ID[@]} - 1 ))); do
	[ "${CELL_DISP[$i]}" = UNAVAILABLE ] && n_unavail=$((n_unavail + 1))
done
if [ $n_unavail -gt 0 ]; then
	mc_banner "!!  MATRIX COVERAGE IS INCOMPLETE ON THIS HOST  !!" "" \
		"$n_unavail of ${#CELL_ID[@]} cells CANNOT be run here; they are listed above as" \
		"UNAVAILABLE with the reason.  They are neither passed nor failed: unrun." \
		"The plan §7.1 matrix is only fully discharged on Linux with liburing" \
		"(-Dliburing=enabled).  Re-run there, or pass --require-io-uring to make" \
		"this a hard failure."
fi
if [ $DRY_RUN -eq 1 ]; then
	[ $REQUIRE_URING -eq 1 ] && [ $n_unavail -gt 0 ] && exit 1
	exit 0
fi

# ---------------------------------------------------------------------------
# one cell: run both sides, then G1-G4
# ---------------------------------------------------------------------------

getstat() { sed -n "s/^$2=//p" "$1" | tail -1; }

run_side()	# run_side OUT LABEL TEMPLATE GUC...
{
	local out=$1 label=$2 template=$3 g
	shift 3
	local -a args=(--pgdata-template "$template" --outputdir "$out" --label "$label"
	               --subset "$SUBSET" --build-dir "$MC_BUILD_DIR")
	for g in "$@"; do
		args[${#args[@]}]=--guc; args[${#args[@]}]=$g
	done
	mc_banner "engine $label"
	bash "$HERE/run_regress_subset.sh" "${args[@]}"
}

# The only legitimate difference between the two results/ trees is each run's
# own absolute paths (outputdir, pgdata).  Rewrite both to the same
# placeholder, symmetrically, and diff the copies.  Nothing else is touched.
normalise()	# normalise SRC DST OUTDIR PGDATA
{
	rm -rf "$2"; mkdir -p "$2"
	[ -d "$1" ] || return 0
	python3 - "$1" "$2" "$3" "$4" <<'PY'
import os, sys
src, dst, out, pgdata = sys.argv[1:5]
subs = [(pgdata.encode(), b'@PGDATA@'), (out.encode(), b'@OUTPUTDIR@')]
for root, _dirs, files in os.walk(src):
    rel = os.path.relpath(root, src)
    target = dst if rel == '.' else os.path.join(dst, rel)
    os.makedirs(target, exist_ok=True)
    for name in files:
        with open(os.path.join(root, name), 'rb') as f:
            data = f.read()
        for needle, repl in subs:
            data = data.replace(needle, repl)
        with open(os.path.join(target, name), 'wb') as f:
            f.write(data)
PY
}

diff_cell()	# diff_cell CELLDIR A_LABEL B_LABEL CELLGUC...   -> 0 pass, 1 fail
{
	local dir=$1 a_label=$2 b_label=$3 rc=0 t
	shift 3
	local a="$dir/a" b="$dir/b"
	rm -rf "$a" "$b"
	run_side "$a" "$a_label" "$A_TEMPLATE" "$@" ${SHARED_GUCS[@]+"${SHARED_GUCS[@]}"} ${A_GUCS[@]+"${A_GUCS[@]}"}
	run_side "$b" "$b_label" "$B_TEMPLATE" "$@" ${SHARED_GUCS[@]+"${SHARED_GUCS[@]}"} ${B_GUCS[@]+"${B_GUCS[@]}"}
	for t in "$a/status.txt" "$b/status.txt"; do
		[ -f "$t" ] || { echo "GATE FAIL  a side did not produce $t"; return 1; }
	done

	normalise "$a/results" "$dir/a.norm" "$a" "$(getstat "$a/engine.txt" pgdata)"
	normalise "$b/results" "$dir/b.norm" "$b" "$(getstat "$b/engine.txt" pgdata)"
	diff -ru "$dir/a.norm" "$dir/b.norm" >"$dir/engines.diff" 2>&1
	local diff_rc=$?

	# G1: classify the difference (classify_diff.py, divergences.txt).  The
	# classifier is told which tests ran, so an allowance for a test this
	# subset never executes is reported as skipped rather than as stale.
	local -a cargs=(--a "$dir/a.norm" --b "$dir/b.norm" --rules "$DIVERGENCES"
	                --report "$dir/divergences.report")
	for t in ${EDIV[@]+"${EDIV[@]}"}; do cargs[${#cargs[@]}]=--allow; cargs[${#cargs[@]}]=$t; done
	while read -r t _; do
		[ -n "$t" ] && { cargs[${#cargs[@]}]=--ran; cargs[${#cargs[@]}]=$t; }
	done <"$a/tap_status.txt"
	local classify_out classify_rc
	classify_out=$(python3 "$HERE/classify_diff.py" "${cargs[@]}" 2>&1)
	classify_rc=$?

	mc_banner "GATE $dir" "A [$a_label]: ${A_GUCS[*]-<none>}   B [$b_label]: ${B_GUCS[*]-<none>}   shared: $* ${SHARED_GUCS[*]-}"
	local n_tests
	n_tests=$(grep -c . "$a/tap_status.txt" 2>/dev/null | tr -d ' ')
	if [ "${n_tests:-0}" -eq 0 ]; then
		echo "G1 FAIL  engine A produced no results at all"; rc=1
	elif [ $diff_rc -eq 0 ] && [ $classify_rc -eq 0 ]; then
		echo "G1 PASS  results/ identical between engines ($n_tests tests)"
	elif [ $classify_rc -eq 0 ]; then
		echo "G1 PASS  results/ differ between engines ONLY in registered, documented ways; every hunk classified ($n_tests tests)"
		printf '%s\n' "$classify_out" | sed 's/^/         /'
	else
		echo "G1 FAIL  results/ differ between engines in ways nothing explains -- see $dir/engines.diff"
		printf '%s\n' "$classify_out" | sed 's/^/         /'
		rc=1
	fi

	# G2: dispositions.  A test named by --allow-engine-divergence may flip
	# disposition (its content already diverges by construction).
	local ediv_re=
	for t in ${EDIV[@]+"${EDIV[@]}"}; do
		ediv_re="${ediv_re:+$ediv_re|}^$t "
		echo "G2 note  $t is named by --allow-engine-divergence: [$a_label] $(awk -v t="$t" '$1==t{print $2}' "$a/tap_status.txt") [$b_label] $(awk -v t="$t" '$1==t{print $2}' "$b/tap_status.txt")"
	done
	if [ -n "$ediv_re" ]; then
		grep -Ev "$ediv_re" "$a/tap_status.txt" >"$dir/a.status.cmp"
		grep -Ev "$ediv_re" "$b/tap_status.txt" >"$dir/b.status.cmp"
	else
		cp "$a/tap_status.txt" "$dir/a.status.cmp"; cp "$b/tap_status.txt" "$dir/b.status.cmp"
	fi
	if diff -u "$dir/a.status.cmp" "$dir/b.status.cmp" >"$dir/tap_status.diff" 2>&1; then
		echo "G2 PASS  per-test disposition identical between engines (${#EDIV[@]} exempt)"
	else
		echo "G2 FAIL  per-test disposition differs:"; cat "$dir/tap_status.diff"; rc=1
	fi

	# G3: expected output, modulo the named allowances.
	local allowed=" ${ALLOW[*]-} " g3=0 side label
	for side in a b; do
		[ $side = a ] && label=$a_label || label=$b_label
		for t in $(awk '$2 == "not-ok" { print $1 }' "$dir/$side/tap_status.txt"); do
			case $allowed in
				*" $t "*) echo "G3 note  [$label] $t differs from upstream expected output (allowed)" ;;
				*)        echo "G3 FAIL  [$label] $t differs from upstream expected output"; g3=1 ;;
			esac
		done
	done
	if [ $g3 -eq 0 ]; then
		echo "G3 PASS  both engines match src/test/regress/expected/ (modulo ${#ALLOW[@]} allowance(s))"
	else
		echo "G3 FAIL  see $a/regression.diffs and $b/regression.diffs"; rc=1
	fi

	# G4: the leak/crash scan of each side.
	local a_leak b_leak
	a_leak=$(getstat "$a/status.txt" leakcheck_rc); b_leak=$(getstat "$b/status.txt" leakcheck_rc)
	if [ "${a_leak:-1}" -eq 0 ] && [ "${b_leak:-1}" -eq 0 ]; then
		echo "G4 PASS  no pin/AIO-handle leaks, asserts or crashes on either engine"
	else
		echo "G4 FAIL  leak check: [$a_label] rc=$a_leak  [$b_label] rc=$b_leak"; rc=1
	fi

	{
		echo "a_label=$a_label"; echo "b_label=$b_label"; echo "cell_gucs=$*"
		echo "results_diff_rc=$diff_rc"; echo "classify_rc=$classify_rc"; echo "gate_rc=$rc"
	} >"$dir/gate.txt"
	return $rc
}

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
	case $id in */stress) cellgucs[${#cellgucs[@]}]="temp_buffers=$STRESS_TB" ;; esac
	if diff_cell "$celldir" "$A_NAME[$id]" "$B_NAME[$id]" "${cellgucs[@]}"; then
		CELL_RESULT[$i]=PASS
	else
		CELL_RESULT[$i]=FAIL
		RC=1
		[ $STOP_ON_FAIL -eq 1 ] && { mc_warn "--stop-on-fail: aborting after $id"; break; }
	fi
done

# ---------------------------------------------------------------------------
# summary, printed and written to summary.txt for run_gate.sh to read back
# ---------------------------------------------------------------------------

SUMMARY="$OUTPUTDIR/summary.txt"
n_pass=0; n_fail=0
for i in $(seq 0 $(( ${#CELL_ID[@]} - 1 ))); do
	case ${CELL_RESULT[$i]:-} in PASS) n_pass=$((n_pass + 1)) ;; FAIL) n_fail=$((n_fail + 1)) ;; esac
done
# Set the exit status outside the tee pipeline's subshell.
if [ "$REQUIRE_URING" -eq 1 ] && [ "$n_unavail" -gt 0 ]; then
	RC=1
fi
{
	print_cells "MATRIX SUMMARY" RESULT CELL_RESULT
	printf '%d passed, %d failed, %d UNAVAILABLE on this host\n' "$n_pass" "$n_fail" "$n_unavail"
	if [ $n_unavail -gt 0 ]; then
		printf 'MATRIX COVERAGE: INCOMPLETE (%d unrun cells)\n' "$n_unavail"
		if [ $REQUIRE_URING -eq 1 ]; then
			printf -- '--require-io-uring was given: treating unavailable cells as a failure\n'
		fi
	else
		printf 'MATRIX COVERAGE: COMPLETE\n'
	fi
	[ $RC -eq 0 ] && printf 'MATRIX RESULT: PASS\n' || printf 'MATRIX RESULT: FAIL\n'
} | tee "$SUMMARY"
exit $RC
