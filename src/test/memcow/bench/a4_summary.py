#!/usr/bin/env python3
"""
a4_summary.py --- answer plan Appendix A.4 from the §7.4 reports.

Each of the five evidence-triggered additions has a trigger the plan states
in words; this turns each into a rule over the numbers the two drivers
measured and prints the number beside the verdict, so that "triggered or
not" is never an opinion.  The rules (all at the p99 of the run they read):

  1. BufferTag generation      TRIGGERED iff the full-rate lease run saw
                               ready-queue exhaustion (a lease found the
                               queue empty)
                               AND sweep_buffers is the largest term of the
                               busy reset run's slowest cycles.
  2. Test VFS / WAL bypass     TRIGGERED iff lease p99 with the writing
                               workload exceeds lease p99 with the read-only
                               workload AT THE SAME PACE by more than a
                               quarter of the 1 ms budget (0.25 ms), or any
                               ENOSPC in the log.
  3. Per-lane barrier          TRIGGERED iff barrier absorption is more than
                               half of the reset cycle at its p99 under busy
                               lanes (soak or plpgsql).  The interrupts-held
                               run is reported beside it as the worst case
                               the global barrier admits.
  4. Selective cache inval.    TRIGGERED iff adopt + warmup are more than
                               half of the cycle at its p99.
  5. Server-side reset workers TRIGGERED iff client round trips are more
                               than half of the cycle at its p99, or the
                               lease run at the gate's configuration saw
                               ready-queue exhaustion (client-driven resets
                               could not keep up with the lease rate).

Usage: a4_summary.py DIR   (reads lease_soak.json, lease_query.json,
       reset_busy_soak.json, reset_busy_plpgsql.json, reset_idle.json,
       reset_hold.json from DIR; missing ones are reported as missing).

Portions Copyright (c) 2026, PostgreSQL Global Development Group
"""

import json
import os
import sys


def load(d, name):
    p = os.path.join(d, name)
    try:
        return json.load(open(p))
    except Exception:  # noqa: BLE001
        return None


def p99(rep, key):
    try:
        return rep[key]['p99']
    except (KeyError, TypeError):
        return None


def main():
    d = sys.argv[1]
    ls = load(d, 'lease_soak.json')
    lq = load(d, 'lease_query.json')
    ll = load(d, 'lease_light.json') or ls    # the full-rate run: where the queue would starve
    lp = load(d, 'lease_light_paced.json')    # writes at the read-only run's pace: A.4 (2)'s partner
    rs = load(d, 'reset_busy_soak.json')
    rp = load(d, 'reset_busy_plpgsql.json')
    ri = load(d, 'reset_idle.json')
    rh = load(d, 'reset_hold.json')
    out = []
    verdicts = {}

    def line(s=''):
        out.append(s)

    line('Appendix A.4, answered from the §7.4 runs in %s' % d)
    line()

    # 1
    if ll and rs:
        waits = ll['lease_waits']
        dom = rs['dominant_at_p99']
        top = max(dom.items(), key=lambda kv: kv[1])[0] if dom else '?'
        sb = rs['terms']['sweep_buffers']
        trig = waits > 0 and top == 'sweep_buffers'
        verdicts['buffertag_generation'] = trig
        line('1. BufferTag generation: %s' % ('TRIGGERED' if trig else 'NOT TRIGGERED'))
        line('   ready-queue exhaustion in the %d-lease %s run at full rate: %d lease(s) found the queue empty'
             % (ll['completed'], ll['workload'], waits))
        line('   DropDatabaseBuffers (sweep_buffers) under busy lanes: p50 %.3f p99 %.3f max %.3f ms, '
             '%.0f%% of the cycle at its p99; largest term of the slowest cycles: %s'
             % (sb['p50'], sb['p99'], sb['max'], 100 * rs['share_at_p99']['sweep_buffers'], top))
    else:
        line('1. BufferTag generation: NO DATA (need lease_soak.json and reset_busy_soak.json)')
    line()

    # 2
    if lq and (lp or ls):
        w = lp or ls
        a, b = p99(w, 'lease_ms'), p99(lq, 'lease_ms')
        enospc = [h for h in w.get('log_hits', []) + lq.get('log_hits', []) if 'space' in h or 'ENOSPC' in h]
        trig = (a is not None and b is not None and a - b > 0.25) or bool(enospc)
        verdicts['test_vfs_wal_bypass'] = trig
        line('2. Test VFS / WAL bypass: %s' % ('TRIGGERED' if trig else 'NOT TRIGGERED'))
        line('   lease p99 with writes (%s workload%s) %.3f ms vs read-only (query, paced %.0f/s) %.3f ms: '
             'delta %+.3f ms (trigger: > 0.25 ms); ENOSPC/PANIC hits: %d'
             % (w['workload'], ', paced %.0f/s' % w['rate'] if w.get('rate') else '', a or 0,
                lq.get('rate') or 0, b or 0, (a or 0) - (b or 0), len(enospc)))
        if lp and ls:
            line('   (the unpaced DDL+DML soak run, for reference: p99 %.3f ms, delta %+.3f ms -- a different '
                 'rate and workload, not a like-for-like comparison)'
                 % (p99(ls, 'lease_ms') or 0, (p99(ls, 'lease_ms') or 0) - (b or 0)))
    else:
        line('2. Test VFS / WAL bypass: NO DATA (need lease_query.json and lease_light_paced.json)')
    line()

    # 3
    if rs or rp:
        shares = []
        for name, r in (('soak', rs), ('plpgsql', rp)):
            if r:
                shares.append((name, r['share_at_p99']['barrier'], r['terms']['barrier'], r['cycle_ms']))
        trig = any(s[1] > 0.5 for s in shares)
        verdicts['per_lane_barrier'] = trig
        line('3. Per-lane barrier alternative: %s' % ('TRIGGERED' if trig else 'NOT TRIGGERED'))
        for name, sh, b, c in shares:
            line('   busy %-7s: barrier absorption p50 %.3f p99 %.3f max %.3f ms = %.0f%% of the cycle at its '
                 'p99 (cycle p99 %.2f ms)' % (name, b['p50'], b['p99'], b['max'], 100 * sh, c['p99']))
        if ri:
            b = ri['terms']['barrier']
            line('   idle neighbours: barrier p50 %.3f p99 %.3f max %.3f ms' % (b['p50'], b['p99'], b['max']))
        if rh:
            b = rh['terms']['barrier']
            line('   a neighbour holding interrupts for %d ms: barrier p50 %.1f p99 %.1f max %.1f ms, '
                 'cycle p99 %.1f ms -- the global barrier is hostage to the slowest process; '
                 'informational, not gated'
                 % (rh['hold_ms'] or 0, b['p50'], b['p99'], b['max'], rh['cycle_ms']['p99']))
    else:
        line('3. Per-lane barrier alternative: NO DATA')
    line()

    # 4
    if rs:
        sh = (rs['share_at_p99']['adopt server (conn 0)'] + rs['share_at_p99']['adopt rtts (all conns)'] +
              rs['share_at_p99']['warmup'])
        trig = sh > 0.5
        verdicts['selective_cache_invalidation'] = trig
        t = rs['terms']
        line('4. Selective cache invalidation: %s' % ('TRIGGERED' if trig else 'NOT TRIGGERED'))
        line('   adopt (InvalidateSystemCaches, server) p50 %.3f p99 %.3f ms; adopt round trips p99 %.3f ms; '
             'warmup p99 %.3f ms; together %.0f%% of the cycle at its p99'
             % (t['adopt server (conn 0)']['p50'], t['adopt server (conn 0)']['p99'],
                t['adopt rtts (all conns)']['p99'], t['warmup']['p99'], 100 * sh))
    else:
        line('4. Selective cache invalidation: NO DATA')
    line()

    # 5
    if rs and ll:
        sh = (rs['share_at_p99']['reset rtt overhead'] + rs['share_at_p99']['status rtt'] +
              rs['share_at_p99']['adopt rtts (all conns)'] + rs['share_at_p99']['open rtt'] +
              rs['share_at_p99']['drain'])
        trig = sh > 0.5 or ll['lease_waits'] > 0
        verdicts['server_side_reset_workers'] = trig
        line('5. Server-side background reset workers: %s' % ('TRIGGERED' if trig else 'NOT TRIGGERED'))
        line('   client round trips (drain, reset, status, adopt, open) = %.0f%% of the cycle at its p99 '
             'under busy lanes; full-rate %s run: %.0f leases/s on %d resetter thread(s) with %d lane(s), '
             '%d of %d lease(s) waited for a lane'
             % (100 * sh, ll['workload'], ll['leases_per_s'] or 0, ll['resetters'], len(ll['lanes']),
                ll['lease_waits'], ll['completed']))
    else:
        line('5. Server-side background reset workers: NO DATA')
    line()

    line('§7.4 thresholds:')
    if ll and ll is not ls:
        line('  lease -> first parameterized query p99 %.3f ms (< %.2f ms: %s) over %d leases, workload %s, '
             'full rate; leaks: %s' % (p99(ll, 'lease_ms') or 0, ll['threshold_ms'],
                                       'MET' if ll['threshold_ok'] else 'MISSED', ll['completed'],
                                       ll['workload'], 'none' if not ll['leaks'] else ll['leaks']))
    if ls:
        line('  lease -> first parameterized query p99 %.3f ms (< %.2f ms: %s) over %d leases, workload %s; '
             'leaks: %s' % (p99(ls, 'lease_ms') or 0, ls['threshold_ms'],
                            'MET' if ls['threshold_ok'] else 'MISSED', ls['completed'], ls['workload'],
                            'none' if not ls['leaks'] else ls['leaks']))
    for name, r in (('busy soak', rs), ('busy plpgsql', rp), ('idle', ri)):
        if r:
            line('  reset cycle p99 %.2f ms (< %.1f ms: %s) over %d resets, %s neighbours; leaks: %s'
                 % (r['cycle_ms']['p99'] or 0, r['threshold_ms'], 'MET' if r['threshold_ok'] else 'MISSED',
                    r['completed'], name, 'none' if not r['leaks'] else r['leaks']))
    print('\n'.join(out))
    with open(os.path.join(d, 'a4_summary.txt'), 'w') as f:
        f.write('\n'.join(out) + '\n')
    with open(os.path.join(d, 'a4_verdicts.json'), 'w') as f:
        json.dump(verdicts, f, indent=1)
    return 0


if __name__ == '__main__':
    sys.exit(main())
