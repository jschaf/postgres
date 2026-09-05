#!/usr/bin/env python3
"""
bench_lease.py --- plan §7.4, the lease half:

    lease -> first parameterized query, p99 < 1 ms over 100,000 leases
    WITH READY CAPACITY (measured floor 0.12 ms), zero leakage.

What "with ready capacity" means here, and how this driver keeps itself
honest about it.  A lease is timed from lease() to the return of the first
parameterized query on the wrapper.  The pool runs its reset cycles on
resetter threads (memcow_pool.LanePool, resetters=R), so a lease waits only
when every lane is mid-reset; the pool records that wait separately.  Every
lease over the threshold is then attributed: if the wait alone explains the
miss it is a STARVED-QUEUE miss (the pool had no ready capacity: more lanes,
more resetters, or a cheaper cycle are the fixes), otherwise a FIRST-QUERY
miss (the round trip itself was slow: the engine's or the client's problem).
The verdict line names the attribution, and so does report.json.

The negative control (--negative-control --resetter-delay-ms D) inflates one
cost term -- the cycle, by a client-side sleep -- and requires this driver to
FAIL the threshold AND attribute the failure to the starved queue, with the
wait p99 at least 0.9 D.  A driver that passes under it is not measuring.

Also measured, for the retire-after-K choice: the recycle (fresh backends)
cost per occurrence, how many of them 100k leases at K cost, and the RSS of
a lane backend against the epochs it has served, so K can be chosen from
what a recycle costs against what it buys.

Exit: 0 = thresholds met (or, under --negative-control, the control behaved),
1 = missed / misattributed, 2 = could not run.

Portions Copyright (c) 2026, PostgreSQL Global Development Group
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_common as bc  # noqa: E402
import memcow_pool as mp  # noqa: E402


def main():
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument('--libdir', required=True)
    ap.add_argument('--host', required=True)
    ap.add_argument('--port', required=True, type=int)
    ap.add_argument('--user', default=os.environ.get('PGUSER', 'postgres'))
    ap.add_argument('--control-db', default='memcow_control')
    ap.add_argument('--pgdata', required=True)
    ap.add_argument('--logfile', default=None)
    ap.add_argument('--lanes', default='memcow_lane_00,memcow_lane_01,memcow_lane_02,memcow_lane_03')
    ap.add_argument('--conns', type=int, default=2)
    ap.add_argument('--leases', type=int, default=100000)
    ap.add_argument('--resetters', type=int, default=1)
    ap.add_argument('--retire-after', type=int, default=50)
    ap.add_argument('--workload', choices=bc.WORKLOAD_NAMES, default='soak')
    ap.add_argument('--threshold-ms', type=float, default=1.0)
    ap.add_argument('--resetter-delay-ms', type=float, default=0.0)
    ap.add_argument('--negative-control', action='store_true')
    ap.add_argument('--switch-interval', type=float, default=0.0002)
    ap.add_argument('--rate', type=float, default=0.0,
                    help='cap the lease rate (leases/s); 0 = as fast as the pool allows')
    ap.add_argument('--footprint-every', type=int, default=50)
    ap.add_argument('--progress-every', type=int, default=5000)
    ap.add_argument('--report', default=None)
    ap.add_argument('--miss-log', default=None,
                    help='append one line per lease over the threshold: wall-clock time, lease ms, wait ms, lane')
    args = ap.parse_args()

    # The GIL: a resetter thread holds it only between its libpq calls, but
    # the leasing thread waits for it after every PQexec() returns; the
    # default 5 ms switch interval is exactly the size of a p99 miss.
    sys.setswitchinterval(args.switch_interval)

    pq = mp.LibPQ(mp.libpq_path(args.libdir))
    base = 'host=%s port=%d user=%s' % (args.host, args.port, args.user)
    lanes = args.lanes.split(',')

    ctl = mp.Conn(pq, base + ' dbname=' + args.control_db)
    ctl.exec('CREATE EXTENSION IF NOT EXISTS memcow')
    probe = bc.LeakProbe(args.pgdata, ctl)

    cycles = []
    pool = mp.LanePool(pq, base, lanes, conns_per_lane=args.conns,
                       control_db=args.control_db, retire_after_epochs=args.retire_after,
                       resetters=args.resetters, capture_timings=True,
                       resetter_delay_ms=args.resetter_delay_ms,
                       on_cycle=cycles.append, log=lambda m: print('      [pool] %s' % m))
    pool.open()
    lane_objs = list(pool.lanes.values())

    before = probe.sample()
    print('%s lease benchmark: %d leases, workload=%s, lanes=%d x %d conns, resetters=%d, '
          'retire-after=%d epochs, threshold %.2f ms%s%s'
          % (bc.stamp(), args.leases, args.workload, len(lanes), args.conns, args.resetters,
             args.retire_after, args.threshold_ms,
             ', paced at %.0f leases/s' % args.rate if args.rate > 0 else ', unpaced',
             ' [NEGATIVE CONTROL: resetter delay %.0f ms]' % args.resetter_delay_ms
             if args.negative_control else ''))
    print('baseline: dsm=%d pgdata-minus-wal=%dkB aio=%d pinned=%d fds=%s'
          % (before['dsm_segments'], before['pgdata_minus_wal_kb'], before['aio_handles_in_flight'],
             before['pinned_buffers'], before['fds']))

    miss_log = open(args.miss_log, 'w') if args.miss_log else None
    lease_ms, wait_ms, query_ms, depths, ages = [], [], [], [], []
    over = []                   # (i, lease_ms, wait_ms, depth)
    fp_samples = []             # (lane, epochs_served, memory-context kB, rss kB)
    fails = []
    warm = None
    warm_at = max(500, args.leases // 10)
    t_start = time.monotonic()
    i = 0
    period = 1.0 / args.rate if args.rate > 0 else 0.0
    next_at = time.monotonic()
    for i in range(1, args.leases + 1):
        if i == warm_at:
            warm = probe.sample()
        if period:
            # paced: a lease every 1/rate s, never bunching up after a stall
            now = time.monotonic()
            if now < next_at:
                time.sleep(next_at - now)
            next_at = max(next_at + period, time.monotonic())
        t0 = time.monotonic()
        try:
            w = pool.lease()
        except mp.PoolError as e:
            fails.append('lease %d: %s' % (i, e))
            break
        t_l = time.monotonic()
        try:
            w.exec_params(bc.FIRST_QUERY, ['1'])
        except mp.PGError as e:
            fails.append('lease %d: first parameterized query: %s' % (i, e))
            break
        t1 = time.monotonic()
        lm = (t1 - t0) * 1000.0
        lease_ms.append(lm)
        wait_ms.append(pool.last_lease_wait_ms)
        query_ms.append((t1 - t_l) * 1000.0)
        depths.append(pool.last_ready_depth)
        ages.append(pool.last_ready_age_ms)
        if lm > args.threshold_ms:
            over.append((i, lm, pool.last_lease_wait_ms, pool.last_ready_depth))
            if miss_log is not None:
                miss_log.write('%.3f %d %.3f %.3f %s\n' % (time.time(), i, lm, pool.last_lease_wait_ms, w.lane_name))
        lane = w._lane
        try:
            bc.run_workload(w, args.workload, i)
        except mp.PGError as e:
            fails.append('lease %d: workload: %s' % (i, e))
            break
        if args.footprint_every and i % args.footprint_every == 0 and lane.conns:
            # The backend's private footprint against the epochs it has
            # served, for the retire-after-K decision: the sum of its memory
            # contexts (what DISCARD ALL does not free: caches, PL state),
            # asked of the backend itself, AFTER the lease was timed and
            # BEFORE the workload.  ps RSS is kept beside it but counts
            # touched shared_buffers and arena pages too, so it says
            # nothing about the backend's own growth.
            try:
                mc = int(w.conn(0).scalar('SELECT sum(total_bytes) FROM pg_backend_memory_contexts')) // 1024
            except mp.PGError:
                mc = -1
            fp_samples.append((lane.name, lane.epochs_served, mc, bc.rss_kb(lane.conns[0].pid)))
        pool.release(w)
        if pool.failures:
            fails.append('resetter failure: %s' % (pool.failures,))
            break
        if i % args.progress_every == 0:
            s = bc.summarize(lease_ms)
            print('lease %d: p50=%.3f p99=%.3f max=%.3f ms; over-threshold=%d; waits=%d; '
                  'cycles=%d; elapsed=%ds'
                  % (i, s['p50'], s['p99'], s['max'], len(over), pool.lease_waits,
                     len(cycles), int(time.monotonic() - t_start)))

    # let the resetters finish what is queued, so the leak probe sees a quiet server
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        live = [l for l in lane_objs if l.state != 'RETIRED']
        if pool.nresetters == 0 or pool.ready.qsize() >= len(live) or pool.failures:
            break
        time.sleep(0.01)
    t_end = time.monotonic()
    if miss_log is not None:
        miss_log.close()
    time.sleep(0.2)
    after = probe.sample()
    leaks = bc.LeakProbe.diff(before, after, warm=warm, lanes=set(lanes))
    log_hits = bc.scan_log(args.logfile) if args.logfile else []
    growth = bc.arena_growth(before, after, set(lanes))

    # --- attribution of the misses ----------------------------------------------
    starved = [o for o in over if o[2] >= o[1] - args.threshold_ms]
    slow_query = [o for o in over if o[2] < o[1] - args.threshold_ms]
    if not over:
        attribution = 'none'
    elif len(starved) >= len(slow_query):
        attribution = 'starved-queue'
    else:
        attribution = 'first-query'

    ls, ws, qs = bc.summarize(lease_ms), bc.summarize(wait_ms), bc.summarize(query_ms)
    cyc = bc.summarize([c['cycle_ms'] for c in cycles])
    cyc_plain = bc.summarize([c['cycle_ms'] for c in cycles if not c['recycled']])
    rst = bc.summarize([c['reset_ms'] for c in cycles])
    srv = bc.summarize([c['server']['total_us'] / 1000.0 for c in cycles if c.get('server')])
    rec = bc.summarize([c['recycle_ms'] for c in cycles if c['recycled']])
    n_recycled = sum(1 for c in cycles if c['recycled'])
    wall = t_end - t_start
    busy = sum(c['cycle_ms'] for c in cycles) / 1000.0

    # footprint against epochs served: per lane, the memory-context total's
    # first/last sample and slope (kB per epoch), RSS beside it
    def fit(pts):
        pts = sorted(pts)
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        n = len(pts)
        slope = None
        if n >= 2 and max(xs) > min(xs):
            mx, my = sum(xs) / n, sum(ys) / n
            den = sum((x - mx) ** 2 for x in xs)
            slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else None
        return {'samples': n, 'min_kb': min(ys), 'max_kb': max(ys), 'kb_per_epoch': slope,
                'first': pts[0], 'last': pts[-1]}
    fp = {}
    for name, served, mc, r in fp_samples:
        fp.setdefault(name, {'contexts': [], 'rss': []})
        if mc >= 0:
            fp[name]['contexts'].append((served, mc))
        if r > 0:
            fp[name]['rss'].append((served, r))
    rss_report = {}
    for name, d in fp.items():
        rss_report[name] = {'contexts': fit(d['contexts']) if d['contexts'] else None,
                            'rss': fit(d['rss']) if d['rss'] else None}

    print()
    print('lease -> first parameterized query (%d leases, workload=%s):' % (len(lease_ms), args.workload))
    print(bc.fmt_row('lease->first query', ls))
    print(bc.fmt_row('  of which: queue wait', ws))
    print(bc.fmt_row('  of which: the query', qs))
    print('  leases that found the ready queue EMPTY: %d of %d; ready depth at lease: min %d mean %.2f; '
          'lane had been ready for p50 %.1f ms'
          % (pool.lease_waits, len(lease_ms), min(depths) if depths else -1,
             (sum(depths) / len(depths)) if depths else 0, bc.percentile(ages, 0.5) or 0))
    print('  over %.2f ms: %d (starved queue: %d, slow first query: %d) -> attribution: %s'
          % (args.threshold_ms, len(over), len(starved), len(slow_query), attribution))
    print('reset cycles (release -> ready, on %d resetter thread(s)):' % args.resetters)
    print(bc.fmt_row('cycle (all)', cyc))
    print(bc.fmt_row('cycle (no recycle)', cyc_plain))
    print(bc.fmt_row('  memcow_lane_reset rtt', rst))
    print(bc.fmt_row('  server total', srv))
    print(bc.fmt_row('  recycle (K=%d)' % args.retire_after, rec))
    print('  recycles: %d in %d cycles (%.1f%% of cycle time); throughput %.0f leases/s; '
          'resetter utilisation %.0f%%'
          % (n_recycled, len(cycles), 100.0 * sum(c.get('recycle_ms', 0) for c in cycles) /
             max(1e-9, sum(c['cycle_ms'] for c in cycles)),
             len(lease_ms) / wall if wall else 0, 100.0 * busy / (wall * max(1, args.resetters))))
    for name, r in sorted(rss_report.items()):
        for kind in ('contexts', 'rss'):
            f = r[kind]
            if f is None:
                continue
            print('  %s backend %s: %d samples, %d..%d kB, %s kB/epoch (first (epochs, kB) %s, last %s)%s'
                  % (name, 'memory contexts' if kind == 'contexts' else 'RSS', f['samples'], f['min_kb'],
                     f['max_kb'], '%.1f' % f['kb_per_epoch'] if f['kb_per_epoch'] is not None else '?',
                     f['first'], f['last'], '' if kind == 'contexts' else ' [includes touched shared pages]'))
    print('leaks: %s' % (leaks if leaks else 'none (dsm %d -> %d -> %d initial/warm/final, pgdata-minus-wal '
                         '%dkB -> %dkB, aio 0, pins 0, fds flat, no mapping to a gone segment)'
                         % (before['dsm_segments'], warm['dsm_segments'] if warm else -1, after['dsm_segments'],
                            before['pgdata_minus_wal_kb'], after['pgdata_minus_wal_kb'])))
    for n in bc.LeakProbe.notes:
        print('note: %s' % n)
    print('never-reset overlays (bounded hint-bit copy-on-write, plan Appendix C): %s'
          % ', '.join('%s %dkB -> %dkB' % (k, v[0] // 1024, v[1] // 1024) for k, v in sorted(growth.items())))
    if log_hits:
        print('server log: %d hit(s):' % len(log_hits))
        for h in log_hits[:10]:
            print('   ' + h)
    for f in fails:
        print('FAIL  %s' % f)

    threshold_ok = ls['p99'] is not None and ls['p99'] < args.threshold_ms and len(lease_ms) == args.leases
    ok = threshold_ok and not leaks and not fails and not log_hits
    summary = {
        'driver': 'bench_lease', 'when': bc.stamp(), 'leases': args.leases, 'completed': len(lease_ms),
        'workload': args.workload, 'lanes': lanes, 'conns': args.conns, 'resetters': args.resetters,
        'retire_after': args.retire_after, 'threshold_ms': args.threshold_ms, 'rate': args.rate,
        'negative_control': args.negative_control, 'resetter_delay_ms': args.resetter_delay_ms,
        'lease_ms': ls, 'wait_ms': ws, 'query_ms': qs, 'lease_waits': pool.lease_waits,
        'ready_depth_min': min(depths) if depths else None,
        'over_threshold': len(over), 'over_starved': len(starved), 'over_slow_query': len(slow_query),
        'attribution': attribution, 'cycle_ms': cyc, 'cycle_ms_no_recycle': cyc_plain,
        'reset_rtt_ms': rst, 'server_total_ms': srv, 'recycle_ms': rec, 'recycles': n_recycled,
        'cycles': len(cycles), 'wall_s': wall, 'leases_per_s': len(lease_ms) / wall if wall else None,
        'footprint': rss_report, 'leaks': leaks, 'log_hits': log_hits, 'fails': fails,
        'probe_before': before, 'probe_warm': warm, 'probe_after': after, 'arena_growth': growth,
        'threshold_ok': threshold_ok, 'pass': ok,
    }
    if args.negative_control:
        behaved = (not threshold_ok and attribution == 'starved-queue' and
                   ws['p99'] is not None and ws['p99'] >= 0.9 * args.resetter_delay_ms)
        summary['negative_control_behaved'] = behaved
        print('NEGATIVE CONTROL %s: cycle inflated by %.0f ms client-side -> threshold %s, '
              'attribution %s, wait p99 %.2f ms'
              % ('BEHAVED' if behaved else 'DID NOT BEHAVE', args.resetter_delay_ms,
                 'missed' if not threshold_ok else 'MET (wrong)', attribution, ws['p99'] or 0))
        rc = 0 if behaved else 1
    else:
        print('VERDICT: %s -- lease p99 %.3f ms %s %.2f ms; leaks %s; failures %d'
              % ('PASS' if ok else 'FAIL', ls['p99'] or 0, '<' if threshold_ok else '>=',
                 args.threshold_ms, 'none' if not leaks else len(leaks), len(fails) + len(log_hits)))
        rc = 0 if ok else 1
    bc.write_report(args.report, summary)
    pool.close()
    ctl.close()
    return rc


if __name__ == '__main__':
    sys.exit(main())
