#!/usr/bin/env bash
#
# diff_engines.sh --- run one regression subset against two engine
#                     configurations and require the outputs to be identical.
#
# An "engine configuration" is { bindir, PGDATA (or PGDATA template), extra
# GUCs }.  In Phase 0 both configurations are stock md, so the required result
# is a byte-identical results/ tree -- that is the Phase 0 gate, and it is a
# real test of the harness rather than of the engine: it proves that nothing in
# this harness (ports, socket dirs, output paths, PGDATA reuse, run order)
# injects a difference of its own.  In Phase 1, configuration B becomes the
# same binary with the memcow GUC on:
#
#     diff_engines.sh --pgdata-template $SEED --b-guc memcow=on ...
#
# and nothing else about the invocation changes.
#
# The gate has four parts, and none of them is optional:
#
#   G1  results/ trees identical between A and B (after normalising the two
#       runs' own absolute paths, which are the only legitimate difference)
#   G2  per-test pass/fail disposition identical between A and B
#   G3  neither side has a failure against src/test/regress/expected/, except
#       for tests explicitly named with --allow-expected-failure
#   G4  neither side's server log shows a pin leak, AIO handle leak, assert or
#       crash (check_leaks.sh, run by run_regress_subset.sh)
#
# --allow-expected-failure names a test that is permitted to differ from
# *upstream expected output* -- it never permits an A-vs-B difference.  Use it
# only for a test whose output is known to depend on a GUC the matrix is
# deliberately setting (see the autovacuum/cluster note in io_matrix.sh).
#
# --allow-engine-divergence is the OTHER, much stronger flag, added for Phase 1.
# It names a test whose results/ file is permitted to differ BETWEEN ENGINES --
# but only in a way that some rule in divergences.txt explains.  The diff is
# still computed, still printed in full, and every hunk of it has to be matched
# by a registered rule (classify_diff.py); a hunk that matches nothing fails the
# gate exactly as before, and so does an allowance whose test ran without
# diverging.  It exists because memcow has exactly one known output divergence
# from md -- pg_relation_size() and friends stat() the runtime PGDATA instead of
# asking smgr (dbsize.c:326-348) -- and the honest way to carry that is a named
# allowance with a citation, not a subset that avoids the subject.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

# See check_leaks.sh for why there is no `set -u`.
set -o pipefail

MC_PROG=diff_engines.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
. "$HERE/common.sh"

usage()
{
	cat <<'EOF'
Usage: diff_engines.sh --outputdir DIR --pgdata-template DIR [options]

Shared:
  --outputdir DIR            results go to DIR/a and DIR/b (required)
  --pgdata-template DIR      PGDATA template both sides are copied from
  --init                     initdb the template if it does not exist
  --subset NAME|FILE         default: phase0
  --guc NAME=VALUE           GUC applied to BOTH sides (repeatable)
  --build-dir DIR            meson build dir for both sides
  --allow-expected-failure T test allowed to differ from upstream expected
                             output (repeatable).  Never relaxes A-vs-B.
  --allow-engine-divergence T  test allowed to differ BETWEEN ENGINES, but only
                             in ways divergences.txt explains (repeatable).
                             Implies --allow-expected-failure for T on side B.
  --divergences FILE         rules file (default: harness/divergences.txt)

Per side (A is the reference, B is the engine under test):
  --a-label / --b-label NAME       default: "a-stock" / "b-stock"
  --a-guc / --b-guc NAME=VALUE     extra GUC for that side only (repeatable)
  --a-bindir / --b-bindir DIR      different binaries per side
  --a-build-dir / --b-build-dir D
  --a-pgdata-template / --b-pgdata-template DIR   different template per side

Exit status: 0 gate passed, 1 gate failed, 2 could not run.
EOF
}

OUTPUTDIR=
TEMPLATE=
A_TEMPLATE=
B_TEMPLATE=
DO_INIT=0
SUBSET=phase0
BUILD_DIR=
A_BUILD_DIR=
B_BUILD_DIR=
A_BINDIR=
B_BINDIR=
A_LABEL=a-stock
B_LABEL=b-stock
SHARED_GUCS=()
A_GUCS=()
B_GUCS=()
ALLOW=()
EDIV=()
DIVERGENCES=

while [ $# -gt 0 ]; do
	case $1 in
		--outputdir)          OUTPUTDIR=$2; shift 2 ;;
		--pgdata-template)    TEMPLATE=$2; shift 2 ;;
		--a-pgdata-template)  A_TEMPLATE=$2; shift 2 ;;
		--b-pgdata-template)  B_TEMPLATE=$2; shift 2 ;;
		--init)               DO_INIT=1; shift ;;
		--subset)             SUBSET=$2; shift 2 ;;
		--guc)                SHARED_GUCS[${#SHARED_GUCS[@]}]=$2; shift 2 ;;
		--a-guc)              A_GUCS[${#A_GUCS[@]}]=$2; shift 2 ;;
		--b-guc)              B_GUCS[${#B_GUCS[@]}]=$2; shift 2 ;;
		--build-dir)          BUILD_DIR=$2; shift 2 ;;
		--a-build-dir)        A_BUILD_DIR=$2; shift 2 ;;
		--b-build-dir)        B_BUILD_DIR=$2; shift 2 ;;
		--a-bindir)           A_BINDIR=$2; shift 2 ;;
		--b-bindir)           B_BINDIR=$2; shift 2 ;;
		--a-label)            A_LABEL=$2; shift 2 ;;
		--b-label)            B_LABEL=$2; shift 2 ;;
		--allow-expected-failure) ALLOW[${#ALLOW[@]}]=$2; shift 2 ;;
		--allow-engine-divergence)
			EDIV[${#EDIV[@]}]=$2
			ALLOW[${#ALLOW[@]}]=$2
			shift 2 ;;
		--divergences)        DIVERGENCES=$2; shift 2 ;;
		-h|--help)            usage; exit 0 ;;
		*)                    usage >&2; mc_die "unknown option: $1" ;;
	esac
done

[ -n "$OUTPUTDIR" ] || { usage >&2; mc_die "--outputdir is required"; }
: "${A_TEMPLATE:=$TEMPLATE}"
: "${B_TEMPLATE:=$TEMPLATE}"
[ -n "$A_TEMPLATE" ] && [ -n "$B_TEMPLATE" ] ||
	{ usage >&2; mc_die "--pgdata-template (or both --a-/--b-pgdata-template) is required"; }
: "${A_BUILD_DIR:=$BUILD_DIR}"
: "${B_BUILD_DIR:=$BUILD_DIR}"
: "${DIVERGENCES:=$HERE/divergences.txt}"
[ -f "$DIVERGENCES" ] || mc_die "no divergence rules file: $DIVERGENCES"

mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")

A_OUT="$OUTPUTDIR/a"
B_OUT="$OUTPUTDIR/b"
rm -rf "$A_OUT" "$B_OUT"

# ---------------------------------------------------------------------------
# run one side
# ---------------------------------------------------------------------------

run_side()
{
	local out=$1 label=$2 template=$3 builddir=$4 bindir=$5
	shift 5
	local -a args
	args=(--pgdata-template "$template" --outputdir "$out" --label "$label"
	      --subset "$SUBSET")
	[ $DO_INIT -eq 1 ] && args[${#args[@]}]=--init
	[ -n "$builddir" ] && { args[${#args[@]}]=--build-dir; args[${#args[@]}]=$builddir; }
	[ -n "$bindir" ]   && { args[${#args[@]}]=--bindir;    args[${#args[@]}]=$bindir; }
	local g
	for g in "$@"; do
		args[${#args[@]}]=--guc
		args[${#args[@]}]=$g
	done

	mc_banner "engine $label"
	bash "$HERE/run_regress_subset.sh" "${args[@]}"
	return $?
}

run_side "$A_OUT" "$A_LABEL" "$A_TEMPLATE" "$A_BUILD_DIR" "$A_BINDIR" \
	${SHARED_GUCS[@]+"${SHARED_GUCS[@]}"} ${A_GUCS[@]+"${A_GUCS[@]}"}
A_RC=$?

run_side "$B_OUT" "$B_LABEL" "$B_TEMPLATE" "$B_BUILD_DIR" "$B_BINDIR" \
	${SHARED_GUCS[@]+"${SHARED_GUCS[@]}"} ${B_GUCS[@]+"${B_GUCS[@]}"}
B_RC=$?

for f in "$A_OUT/status.txt" "$B_OUT/status.txt"; do
	[ -f "$f" ] || mc_die "a side did not produce $f; see the logs above"
done

getstat() { sed -n "s/^$2=//p" "$1" | tail -1; }

# ---------------------------------------------------------------------------
# normalise: the only legitimate difference between the two results/ trees is
# each run's own absolute paths (outputdir, pgdata).  Rewrite both to the same
# placeholder, symmetrically, and diff the copies.  Nothing else is touched --
# a normalisation that hid real differences would be a hole in the gate.
# ---------------------------------------------------------------------------

normalise()
{
	local src=$1 dst=$2 out=$3 pgdata=$4
	rm -rf "$dst"
	mkdir -p "$dst"
	[ -d "$src" ] || return 0
	python3 - "$src" "$dst" "$out" "$pgdata" <<'PY'
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
            if needle:
                data = data.replace(needle, repl)
        with open(os.path.join(target, name), 'wb') as f:
            f.write(data)
PY
}

A_PGDATA=$(getstat "$A_OUT/engine.txt" pgdata)
B_PGDATA=$(getstat "$B_OUT/engine.txt" pgdata)

normalise "$A_OUT/results" "$OUTPUTDIR/a.norm" "$A_OUT" "$A_PGDATA"
normalise "$B_OUT/results" "$OUTPUTDIR/b.norm" "$B_OUT" "$B_PGDATA"

DIFF_FILE="$OUTPUTDIR/engines.diff"
diff -ru "$OUTPUTDIR/a.norm" "$OUTPUTDIR/b.norm" >"$DIFF_FILE" 2>&1
DIFF_RC=$?

# ---------------------------------------------------------------------------
# classify the difference (G1) -- see classify_diff.py and divergences.txt
# ---------------------------------------------------------------------------

CLASSIFY_ARGS=(--a "$OUTPUTDIR/a.norm" --b "$OUTPUTDIR/b.norm"
               --rules "$DIVERGENCES"
               --report "$OUTPUTDIR/divergences.report")
for t in ${EDIV[@]+"${EDIV[@]}"}; do
	CLASSIFY_ARGS[${#CLASSIFY_ARGS[@]}]=--allow
	CLASSIFY_ARGS[${#CLASSIFY_ARGS[@]}]=$t
done
# Tell the classifier which tests actually ran, so that an allowance for a test
# this subset never executes is reported as skipped rather than as stale.
while read -r t _; do
	[ -n "$t" ] || continue
	CLASSIFY_ARGS[${#CLASSIFY_ARGS[@]}]=--ran
	CLASSIFY_ARGS[${#CLASSIFY_ARGS[@]}]=$t
done <"$A_OUT/tap_status.txt"

CLASSIFY_OUT=$(python3 "$HERE/classify_diff.py" "${CLASSIFY_ARGS[@]}" 2>&1)
CLASSIFY_RC=$?

# ---------------------------------------------------------------------------
# G2: dispositions.  A test named by --allow-engine-divergence is allowed to
# flip disposition (its content already diverges by construction), so compare
# the other tests exactly and report the named ones separately.
# ---------------------------------------------------------------------------

ediv_re=
for t in ${EDIV[@]+"${EDIV[@]}"}; do
	ediv_re="${ediv_re:+$ediv_re|}^$t "
done
STATUS_DIFF="$OUTPUTDIR/tap_status.diff"
if [ -n "$ediv_re" ]; then
	grep -Ev "$ediv_re" "$A_OUT/tap_status.txt" >"$OUTPUTDIR/a.status.cmp"
	grep -Ev "$ediv_re" "$B_OUT/tap_status.txt" >"$OUTPUTDIR/b.status.cmp"
else
	cp "$A_OUT/tap_status.txt" "$OUTPUTDIR/a.status.cmp"
	cp "$B_OUT/tap_status.txt" "$OUTPUTDIR/b.status.cmp"
fi
diff -u "$OUTPUTDIR/a.status.cmp" "$OUTPUTDIR/b.status.cmp" >"$STATUS_DIFF" 2>&1
STATUS_RC=$?

# ---------------------------------------------------------------------------
# verdict
# ---------------------------------------------------------------------------

RC=0

mc_banner "GATE" \
	"subset:  $SUBSET" \
	"shared:  ${SHARED_GUCS[*]-<none>}" \
	"A [$A_LABEL]: ${A_GUCS[*]-<none>}" \
	"B [$B_LABEL]: ${B_GUCS[*]-<none>}"

# G1 --------------------------------------------------------------------
n_files_a=$(find "$OUTPUTDIR/a.norm" -type f 2>/dev/null | wc -l | tr -d ' ')
n_tests=$(grep . "$A_OUT/tap_status.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "${n_files_a:-0}" -eq 0 ] || [ "${n_tests:-0}" -eq 0 ]; then
	echo "G1 FAIL  engine A produced no results at all ($n_files_a files, $n_tests tests)"
	RC=1
elif [ "$DIFF_RC" -eq 0 ] && [ "$CLASSIFY_RC" -eq 0 ]; then
	echo "G1 PASS  results/ identical between engines ($n_files_a files, $n_tests tests)"
elif [ "$CLASSIFY_RC" -eq 0 ]; then
	echo "G1 PASS  results/ differ between engines ONLY in registered, documented"
	echo "         ways -- every hunk classified.  See $OUTPUTDIR/divergences.report"
	echo "         ($n_files_a files, $n_tests tests)"
	printf '%s\n' "$CLASSIFY_OUT" | sed 's/^/         /'
elif [ "$CLASSIFY_RC" -eq 2 ]; then
	echo "G1 FAIL  the divergence classifier could not run"
	printf '%s\n' "$CLASSIFY_OUT" | sed 's/^/         /'
	RC=1
else
	echo "G1 FAIL  results/ differ between engines in ways nothing explains --"
	echo "         see $DIFF_FILE and $OUTPUTDIR/divergences.report"
	printf '%s\n' "$CLASSIFY_OUT" | sed 's/^/         /'
	RC=1
fi

# G2 --------------------------------------------------------------------
for t in ${EDIV[@]+"${EDIV[@]}"}; do
	echo "G2 note  $t is named by --allow-engine-divergence:" \
	     "[$A_LABEL] $(awk -v t="$t" '$1==t{print $2}' "$A_OUT/tap_status.txt")" \
	     "[$B_LABEL] $(awk -v t="$t" '$1==t{print $2}' "$B_OUT/tap_status.txt")"
done
if [ "$STATUS_RC" -eq 0 ]; then
	echo "G2 PASS  per-test disposition identical between engines" \
	     "(${#EDIV[@]} test(s) exempt and reported above)"
else
	echo "G2 FAIL  per-test disposition differs -- see $STATUS_DIFF"
	cat "$STATUS_DIFF"
	RC=1
fi

# G3 --------------------------------------------------------------------
allowed=" ${ALLOW[*]-} "
check_expected()
{
	local out=$1 label=$2 bad=0 t
	for t in $(awk '$2 == "not-ok" { print $1 }' "$out/tap_status.txt"); do
		case $allowed in
			*" $t "*)
				echo "G3 note  [$label] $t differs from upstream expected output"
				echo "         (explicitly allowed via --allow-expected-failure)"
				;;
			*)
				echo "G3 FAIL  [$label] $t differs from upstream expected output"
				bad=1
				;;
		esac
	done
	return $bad
}
G3=0
check_expected "$A_OUT" "$A_LABEL" || G3=1
check_expected "$B_OUT" "$B_LABEL" || G3=1
if [ $G3 -eq 0 ]; then
	echo "G3 PASS  both engines match src/test/regress/expected/ (modulo ${#ALLOW[@]} allowance(s))"
else
	echo "G3 FAIL  see $A_OUT/regression.diffs and $B_OUT/regression.diffs"
	RC=1
fi

# G4 --------------------------------------------------------------------
A_LEAK=$(getstat "$A_OUT/status.txt" leakcheck_rc)
B_LEAK=$(getstat "$B_OUT/status.txt" leakcheck_rc)
if [ "${A_LEAK:-1}" -eq 0 ] && [ "${B_LEAK:-1}" -eq 0 ]; then
	echo "G4 PASS  no pin/AIO-handle leaks, asserts or crashes on either engine"
else
	echo "G4 FAIL  leak check: [$A_LABEL] rc=$A_LEAK  [$B_LABEL] rc=$B_LEAK"
	RC=1
fi

{
	echo "subset=$SUBSET"
	echo "a_label=$A_LABEL"
	echo "b_label=$B_LABEL"
	echo "shared_gucs=${SHARED_GUCS[*]-}"
	echo "a_gucs=${A_GUCS[*]-}"
	echo "b_gucs=${B_GUCS[*]-}"
	echo "a_rc=$A_RC"
	echo "b_rc=$B_RC"
	echo "engine_divergence_allowances=${EDIV[*]-}"
	echo "results_diff_rc=$DIFF_RC"
	echo "classify_rc=$CLASSIFY_RC"
	echo "status_diff_rc=$STATUS_RC"
	echo "gate_rc=$RC"
} >"$OUTPUTDIR/gate.txt"

if [ $RC -eq 0 ] && [ "$DIFF_RC" -eq 0 ]; then
	mc_banner "GATE PASS -- zero diffs between [$A_LABEL] and [$B_LABEL]"
elif [ $RC -eq 0 ]; then
	mc_banner "GATE PASS -- [$A_LABEL] vs [$B_LABEL] differ ONLY in registered," \
		"documented divergences; every hunk classified." \
		"See $OUTPUTDIR/divergences.report"
else
	mc_banner "GATE FAIL -- see $OUTPUTDIR/gate.txt"
fi
exit $RC
