#!/usr/bin/env bash
#
# make_templates.sh --- build the two PGDATA templates the Phase 1 differential
#                       gate compares.
#
# The Phase 1 gate runs the same regression subset twice against the SAME data,
# once on stock md and once on memcow, and requires the outputs to match.  For
# that to mean anything, both sides have to start from the same cluster
# contents and differ ONLY in the engine -- which takes two templates, not one:
#
#   tpl-md      the seed's non-relation files (with assemble_ramdir.sh's
#               runtime settings applied) PLUS every relation file from the
#               seed.  This is a perfectly ordinary, startable PGDATA and it is
#               what side A runs on.
#
#   tpl-memcow  the same thing with NO relation files at all -- literally the
#               assembled RAM dir.  Side B runs on this with memcow.enabled=on
#               and memcow.seed_directory pointing at the seed.
#
# Giving side B a PGDATA with zero relation files is the point of the exercise
# and not an optimisation: it is what turns "memcow produced the right answer"
# into "memcow produced the right answer and md had nothing on disk it could
# have produced it from".  Handing both sides the same populated template would
# have been simpler and would have quietly weakened invariant I3's evidence to
# nothing.
#
# The RAM disk is deliberately NOT involved.  run_regress_subset.sh copies a
# template into its own output directory before running, so the template's
# filesystem never carries any load; only its CONTENTS matter.  Keeping the
# templates on ordinary storage means the gate does not need a second RAM disk
# and does not compete with the running cluster for the first one.
#
# Usage:
#   make_templates.sh --seed DIR --ramdir DIR --outdir DIR
#
#     --seed DIR    the read-only seed (build_seed.sh -o)
#     --ramdir DIR  an assembled runtime PGDATA (assemble_ramdir.sh, no -R)
#     --outdir DIR  where tpl-md/ and tpl-memcow/ are written (recreated)
#
# Exit status: 0 both templates written, 2 could not run.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

set -o pipefail

MC_PROG=make_templates.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../harness/common.sh
. "$(cd -- "$HERE/../harness" && pwd)/common.sh"

SEED=
RAMDIR=
OUTDIR=

while [ $# -gt 0 ]; do
	case $1 in
		--seed)   SEED=$2; shift 2 ;;
		--ramdir) RAMDIR=$2; shift 2 ;;
		--outdir) OUTDIR=$2; shift 2 ;;
		-h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) mc_die "unknown option: $1" ;;
	esac
done

[ -n "$SEED" ]   || mc_die "--seed is required"
[ -n "$RAMDIR" ] || mc_die "--ramdir is required"
[ -n "$OUTDIR" ] || mc_die "--outdir is required"
SEED=$(mc_abspath "$SEED")
RAMDIR=$(mc_abspath "$RAMDIR")
OUTDIR=$(mc_abspath "$OUTDIR")

[ -f "$SEED/PG_VERSION" ]   || mc_die "not a seed PGDATA: $SEED"
[ -f "$RAMDIR/PG_VERSION" ] || mc_die "not a data directory: $RAMDIR"

# A live postmaster on the RAM dir would give both templates a stale
# postmaster.pid at best and a torn copy at worst.
if [ -f "$RAMDIR/postmaster.pid" ]; then
	mc_die "a postmaster.pid exists in $RAMDIR; stop the server before copying it"
fi

command -v rsync >/dev/null 2>&1 ||
	mc_die "rsync is required (used with --ignore-existing to add the seed's
  relation files WITHOUT overwriting the RAM dir's own postgresql.conf)"

MD="$OUTDIR/tpl-md"
MEMCOW="$OUTDIR/tpl-memcow"

mkdir -p "$OUTDIR" || mc_die "cannot create $OUTDIR"
rm -rf "$MD" "$MEMCOW"

mc_log "copying $RAMDIR -> $MEMCOW (no relation files)"
cp -R "$RAMDIR" "$MEMCOW" || mc_die "copy failed"

mc_log "copying $RAMDIR -> $MD, then adding the seed's relation files"
cp -R "$RAMDIR" "$MD" || mc_die "copy failed"
# --ignore-existing is load-bearing: everything assemble_ramdir.sh already
# placed (notably postgresql.conf, with its runtime settings block appended)
# must win over the seed's copy of the same file.  What is left to add is
# exactly the set of files assemble_ramdir.sh left behind, i.e. the relation
# forks.
rsync -a --ignore-existing "$SEED/" "$MD/" || mc_die "rsync failed"

# The fingerprint is meaningless in a running PGDATA and would only confuse
# someone who found it there; the pid files must not travel.
rm -f "$MD/memcow_seed.fingerprint" "$MEMCOW/memcow_seed.fingerprint"
rm -f "$MD/postmaster.pid" "$MEMCOW/postmaster.pid"

relcount()
{
	find "$1/base" "$1/global" -type f 2>/dev/null |
		grep -cE '/[0-9]+(_fsm|_vm|_init)?(\.[0-9]+)?$'
}

n_md=$(relcount "$MD")
n_mc=$(relcount "$MEMCOW")

mc_log "tpl-md:     $MD  ($n_md relation files)"
mc_log "tpl-memcow: $MEMCOW  ($n_mc relation files)"

# Both of these are gates, not diagnostics.  A tpl-memcow with relation files in
# it would let md serve pages on the side under test; a tpl-md without them
# would not start at all.
[ "${n_mc:-1}" -eq 0 ] ||
	mc_die "tpl-memcow has $n_mc relation files; it must have none"
[ "${n_md:-0}" -gt 0 ] ||
	mc_die "tpl-md has no relation files; stock md cannot run on it"

printf 'MEMCOW_TPL_MD=%s\n' "$MD"
printf 'MEMCOW_TPL_MEMCOW=%s\n' "$MEMCOW"
exit 0
