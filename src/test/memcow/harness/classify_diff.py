#!/usr/bin/env python3
"""classify_diff.py --- decide whether an A-vs-B results/ difference is a
registered, documented memcow divergence or an unexplained one.

Gate G1 in diff_engines.sh used to be "the two results/ trees are byte
identical".  That is still what is required of every test the caller has not
explicitly named, and it is still the only interesting question.  What this
script adds is a way to say "test X is allowed to differ, but ONLY in the
specific way rule R describes", so that the one known memcow divergence --
pg_relation_size() and friends reading the runtime PGDATA rather than smgr --
appears in the gate output as a named, justified allowance instead of as a
diff someone has to re-investigate every time.

The rules are deliberately NOT patterns over the changed lines.  A changed
line under memcow is usually just "t" becoming "f"; matching on that would
accept literally any boolean regression.  The rules match the whole hunk,
context included, so what actually has to be present is the SQL that produced
the differing answer -- e.g. a pg_relation_size() call.  A hunk that changes
something else is not explained by the rule even if it happens to sit in a
file that also calls pg_relation_size().

Three things fail:

  * a hunk in a file nobody allowed to differ            (unexplained diff)
  * a hunk in an allowed file that no rule matches       (unexplained hunk)
  * an allowance for a test that ran and did NOT differ  (stale allowance)

The last one matters as much as the other two.  An allowance list that is
never checked for staleness is how a gate stops testing anything without
anyone noticing.

Usage:
    classify_diff.py --a DIR --b DIR --rules FILE
                     [--allow TEST]... [--ran TEST]... [--report FILE]

Exit status: 0 everything explained, 1 something was not, 2 could not run.

Portions Copyright (c) 2026, PostgreSQL Global Development Group
"""

import argparse
import difflib
import os
import re
import sys


def load_rules(path):
    rules = []
    try:
        with open(path, encoding='utf-8') as f:
            for lineno, line in enumerate(f, 1):
                line = line.rstrip('\n')
                if not line.strip() or line.lstrip().startswith('#'):
                    continue
                parts = line.split('\t')
                parts = [p for p in parts if p != '']
                if len(parts) < 3:
                    sys.stderr.write(
                        '%s:%d: expected three TAB-separated fields\n'
                        % (path, lineno))
                    sys.exit(2)
                name, pattern, why = parts[0], parts[1], '\t'.join(parts[2:])
                try:
                    rules.append((name, re.compile(pattern), why))
                except re.error as e:
                    sys.stderr.write('%s:%d: bad regex for rule %s: %s\n'
                                     % (path, lineno, name, e))
                    sys.exit(2)
    except OSError as e:
        sys.stderr.write('cannot read rules file %s: %s\n' % (path, e))
        sys.exit(2)
    return rules


def read(path):
    with open(path, 'rb') as f:
        return f.read().decode('utf-8', 'replace').splitlines(keepends=True)


# How much context each hunk carries.
#
# diff's usual 3 is too little here and that is not a guess: the
# vacuum_parallel divergence puts the pg_relation_size() call FOUR lines above
# the changed line, so at n=3 a hunk with an entirely ordinary cause looked
# unexplainable.  The cost of widening it is that a rule can be satisfied by
# SQL up to CONTEXT lines away from the change it is meant to explain, which is
# why every classified hunk is printed in full: the mechanism narrows what a
# human has to read, it does not replace reading it.
CONTEXT = 10


def hunks(a_lines, b_lines, a_name, b_name):
    """Split a unified diff into individual hunks (list of text blocks)."""
    out = []
    cur = None
    for line in difflib.unified_diff(a_lines, b_lines,
                                     fromfile=a_name, tofile=b_name,
                                     n=CONTEXT):
        if line.startswith('@@'):
            if cur is not None:
                out.append(''.join(cur))
            cur = [line if line.endswith('\n') else line + '\n']
        elif cur is not None:
            cur.append(line if line.endswith('\n') else line + '\n')
    if cur is not None:
        out.append(''.join(cur))
    return out


def test_name_of(relpath):
    """results/foo.out -> foo; anything else keeps its path."""
    base = os.path.basename(relpath)
    if base.endswith('.out'):
        return base[:-4]
    return relpath


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--a', required=True)
    ap.add_argument('--b', required=True)
    ap.add_argument('--rules', required=True)
    ap.add_argument('--allow', action='append', default=[])
    ap.add_argument('--ran', action='append', default=[])
    ap.add_argument('--report')
    args = ap.parse_args()

    rules = load_rules(args.rules)
    allow = set(args.allow)
    ran = set(args.ran)

    lines = []

    def say(s=''):
        lines.append(s)

    a_files = set()
    for root, _dirs, files in os.walk(args.a):
        for n in files:
            a_files.add(os.path.relpath(os.path.join(root, n), args.a))
    b_files = set()
    for root, _dirs, files in os.walk(args.b):
        for n in files:
            b_files.add(os.path.relpath(os.path.join(root, n), args.b))

    rc = 0
    differing = set()
    explained_counts = {}

    only_a = sorted(a_files - b_files)
    only_b = sorted(b_files - a_files)
    for n in only_a:
        say('UNEXPLAINED  present only in A: %s' % n)
        rc = 1
    for n in only_b:
        say('UNEXPLAINED  present only in B: %s' % n)
        rc = 1

    for rel in sorted(a_files & b_files):
        al = read(os.path.join(args.a, rel))
        bl = read(os.path.join(args.b, rel))
        if al == bl:
            continue
        test = test_name_of(rel)
        differing.add(test)
        hs = hunks(al, bl, 'A/' + rel, 'B/' + rel)
        if test not in allow:
            say('UNEXPLAINED  %s differs between engines and is not named by '
                '--allow-engine-divergence (%d hunk(s))' % (rel, len(hs)))
            for h in hs[:5]:
                say(''.join('    ' + x for x in h.splitlines(keepends=True))
                    .rstrip('\n'))
            if len(hs) > 5:
                say('    ... %d more hunk(s)' % (len(hs) - 5))
            rc = 1
            continue
        for h in hs:
            hit = None
            for name, rx, _why in rules:
                if rx.search(h):
                    hit = name
                    break
            if hit is None:
                say('UNEXPLAINED  %s: hunk matches no rule in %s'
                    % (rel, os.path.basename(args.rules)))
                say(''.join('    ' + x for x in h.splitlines(keepends=True))
                    .rstrip('\n'))
                rc = 1
            else:
                explained_counts[hit] = explained_counts.get(hit, 0) + 1
                say('EXPLAINED    %s: hunk classified as [%s]' % (rel, hit))
                say(''.join('    ' + x for x in h.splitlines(keepends=True))
                    .rstrip('\n'))

    # A named allowance for a test that ran and did not differ is stale.
    for test in sorted(allow):
        if ran and test not in ran:
            say('SKIPPED      allowance for %s: that test did not run in this '
                'subset' % test)
            continue
        if test not in differing:
            say('STALE        allowance for %s: the test ran and produced NO '
                'A-vs-B difference; remove the allowance' % test)
            rc = 1

    if explained_counts:
        say()
        say('registered divergences that fired:')
        for name, rx, why in rules:
            if name in explained_counts:
                say('  [%s] x%d' % (name, explained_counts[name]))
                say('      %s' % why)

    text = '\n'.join(lines)
    if text:
        print(text)
    if args.report:
        with open(args.report, 'w', encoding='utf-8') as f:
            f.write(text + ('\n' if text else ''))
    return rc


if __name__ == '__main__':
    sys.exit(main())
