#!/usr/bin/env python3
"""
bench.py --- plan §7.4, both halves, run under harness/with_server.sh:

  bench.py lease  --leases N --lanes A,B,... --resetters R [--workload W]
                  [--negative-control --resetter-delay-ms D]

    lease -> first parameterized query, p99 < 1 ms over 100,000 leases
    WITH READY CAPACITY, zero leakage.  A lease is timed from lease() to
    the return of the first parameterized query on the wrapper.  The pool
    runs its reset cycles on R resetter threads, so a lease waits only when
    every lane is mid-reset; the pool records that wait separately, and
    every lease over the threshold is attributed: if the wait alone
    explains the miss it is a STARVED-QUEUE miss (the pool had no ready
    capacity), otherwise a FIRST-QUERY miss (the round trip itself was
    slow).  The negative control inflates one cost term -- the cycle, by a
    client-side sleep of D ms -- and requires this driver to FAIL the
    threshold AND attribute the failure to the starved queue, with the wait
    p99 at least 0.9 D.

  bench.py reset  --resets N --lanes A,B [--busy-lanes ... --busy-mode soak|plpgsql]
                  [--negative-control --nc-sweep-wait-ms X]

    reset (quiesce -> ready, including warmup) p99 < 25 ms at
    shared_buffers=512MB under CONCURRENT BUSY LANES, with the global
    SMGRRELEASE barrier's absorption latency measured explicitly.  The
    measured lanes run lease -> workload -> release INLINE, so each cycle is
    one measurement: drain, memcow_lane_reset(D) round trip, status, adopt,
    warmup, open, and every K epochs the backend recycle.  The engine's own
    attribution (memcow_lane_reset_timings: fence, prepare, publish,
    barrier, sweep_buffers, sweep_files, reclaim_wait, poison, destroy) comes
    back with each cycle, so every term is either a server step or a client
    round trip.  The neighbours are busy_driver.py subprocesses, one per busy
    lane, each with its own pool over its own lanes (static partitioning,
    plan §1).  The negative control parks every reset at the
    memcow-lane-reset-in-sweep injection point for X ms, inside the
    sweep_buffers term: the run must show sweep_buffers up by >= 0.9 X
    against the baseline it measured first, every other server term
    unchanged within 1 ms, and the threshold missed.

Exit: 0 = thresholds met and no leaks (or, under --negative-control, the
control behaved), 1 = missed / misattributed / leaked, 2 = could not run.

Portions Copyright (c) 2026, PostgreSQL Global Development Group
"""

import argparse
import json
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import memcow_pool as mp  # noqa: E402
import testlib as tl  # noqa: E402

SERVER_TERMS = ('fence_us', 'prepare_us', 'publish_us', 'barrier_us', 'sweep_buffers_us',
                'sweep_files_us', 'reclaim_wait_us', 'poison_us', 'destroy_us')
NC_POINT = 'memcow-lane-reset-in-sweep'


def report_common(before, after, growth, leaks, fails):
    for n in tl.LeakProbe.notes:
        print('note: %s' % n)
    print('leaks: %s' % (leaks if leaks else 'none (dsm %d -> %d, pgdata-minus-wal %dkB -> %dkB, '
                         'aio 0, pins 0, fds flat, no mapping to a gone segment)'
                         % (before['dsm_segments'], after['dsm_segments'],
                            before['pgdata_minus_wal_kb'], after['pgdata_minus_wal_kb'])))
    print('never-reset overlays (bounded hint-bit copy-on-write, plan Appendix C): %s'
          % ', '.join('%s %dkB -> %dkB' % (k, v[0] // 1024, v[1] // 1024) for k, v in sorted(growth.items())))
    for f in fails:
        print('FAIL  %s' % f)


# ---------------------------------------------------------------------------
# lease
# ---------------------------------------------------------------------------

def run_lease(args, pq, base, ctl, probe):
    # The GIL: a resetter thread holds it only between its libpq calls, but
    # the leasing thread waits for it after every PQexec() returns; the
    # default 5 ms switch interval is exactly the size of a p99 miss.
    sys.setswitchinterval(0.0002)
    lanes = args.lanes.split(',')
    cycles = []
    pool = mp.LanePool(pq, base, lanes, conns_per_lane=args.conns,
                       control_db=tl.control_db(), retire_after_epochs=args.retire_after,
                       resetters=args.resetters, capture_timings=True,
                       resetter_delay_ms=args.resetter_delay_ms,
                       on_cycle=cycles.append, log=lambda m: print('      [pool] %s' % m))
    pool.open()
    lane_objs = list(pool.lanes.values())

    before = probe.sample()
    print('%s lease benchmark: %d leases, workload=%s, lanes=%d x %d conns, resetters=%d, '
          'retire-after=%d epochs, threshold %.2f ms%s'
          % (tl.stamp(), args.leases, args.workload, len(lanes), args.conns, args.resetters,
             args.retire_after, args.threshold_ms,
             ' [NEGATIVE CONTROL: resetter delay %.0f ms]' % args.resetter_delay_ms
             if args.negative_control else ''))
    print('baseline: dsm=%d pgdata-minus-wal=%dkB aio=%d pinned=%d fds=%s'
          % (before['dsm_segments'], before['pgdata_minus_wal_kb'], before['aio_handles_in_flight'],
             before['pinned_buffers'], before['fds']))

    lease_ms, wait_ms, query_ms, depths = [], [], [], []
    over = []                   # (i, lease_ms, wait_ms, depth)
    fails = []
    t_start = time.monotonic()
    for i in range(1, args.leases + 1):
        t0 = time.monotonic()
        try:
            w = pool.lease()
        except mp.PoolError as e:
            fails.append('lease %d: %s' % (i, e))
            break
        t_l = time.monotonic()
        try:
            w.exec_params(tl.FIRST_QUERY, ['1'])
        except mp.PGError as e:
            fails.append('lease %d: first parameterized query: %s' % (i, e))
            break
        t1 = time.monotonic()
        lm = (t1 - t0) * 1000.0
        lease_ms.append(lm)
        wait_ms.append(pool.last_lease_wait_ms)
        query_ms.append((t1 - t_l) * 1000.0)
        depths.append(pool.last_ready_depth)
        if lm > args.threshold_ms:
            over.append((i, lm, pool.last_lease_wait_ms, pool.last_ready_depth))
        try:
            tl.run_workload(w, args.workload, i)
        except mp.PGError as e:
            fails.append('lease %d: workload: %s' % (i, e))
            break
        pool.release(w)
        if pool.failures:
            fails.append('resetter failure: %s' % (pool.failures,))
            break
        if i % args.progress_every == 0:
            s = tl.summarize(lease_ms)
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
    time.sleep(0.2)
    after = probe.sample()
    leaks = tl.LeakProbe.diff(before, after, lanes=set(lanes))
    growth = tl.arena_growth(before, after, set(lanes))

    starved = [o for o in over if o[2] >= o[1] - args.threshold_ms]
    slow_query = [o for o in over if o[2] < o[1] - args.threshold_ms]
    if not over:
        attribution = 'none'
    elif len(starved) >= len(slow_query):
        attribution = 'starved-queue'
    else:
        attribution = 'first-query'

    ls, ws, qs = tl.summarize(lease_ms), tl.summarize(wait_ms), tl.summarize(query_ms)
    cyc = tl.summarize([c['cycle_ms'] for c in cycles])
    rst = tl.summarize([c['reset_ms'] for c in cycles])
    srv = tl.summarize([c['server']['total_us'] / 1000.0 for c in cycles if c.get('server')])
    rec = tl.summarize([c['recycle_ms'] for c in cycles if c['recycled']])
    wall = t_end - t_start
    busy = sum(c['cycle_ms'] for c in cycles) / 1000.0

    print()
    print('lease -> first parameterized query (%d leases, workload=%s):' % (len(lease_ms), args.workload))
    print(tl.fmt_row('lease->first query', ls))
    print(tl.fmt_row('  of which: queue wait', ws))
    print(tl.fmt_row('  of which: the query', qs))
    print('  leases that found the ready queue EMPTY: %d of %d; ready depth at lease: min %d mean %.2f'
          % (pool.lease_waits, len(lease_ms), min(depths) if depths else -1,
             (sum(depths) / len(depths)) if depths else 0))
    print('  over %.2f ms: %d (starved queue: %d, slow first query: %d) -> attribution: %s'
          % (args.threshold_ms, len(over), len(starved), len(slow_query), attribution))
    print('reset cycles (release -> ready, on %d resetter thread(s)):' % args.resetters)
    print(tl.fmt_row('cycle', cyc))
    print(tl.fmt_row('  memcow_lane_reset rtt', rst))
    print(tl.fmt_row('  server total', srv))
    print(tl.fmt_row('  recycle (K=%d)' % args.retire_after, rec))
    print('  throughput %.0f leases/s; resetter utilisation %.0f%%'
          % (len(lease_ms) / wall if wall else 0, 100.0 * busy / (wall * max(1, args.resetters))))
    report_common(before, after, growth, leaks, fails)

    threshold_ok = ls['p99'] is not None and ls['p99'] < args.threshold_ms and len(lease_ms) == args.leases
    ok = threshold_ok and not leaks and not fails
    summary = {
        'driver': 'lease', 'when': tl.stamp(), 'leases': args.leases, 'completed': len(lease_ms),
        'workload': args.workload, 'lanes': lanes, 'conns': args.conns, 'resetters': args.resetters,
        'retire_after': args.retire_after, 'threshold_ms': args.threshold_ms,
        'negative_control': args.negative_control, 'resetter_delay_ms': args.resetter_delay_ms,
        'lease_ms': ls, 'wait_ms': ws, 'query_ms': qs, 'lease_waits': pool.lease_waits,
        'over_threshold': len(over), 'over_starved': len(starved), 'over_slow_query': len(slow_query),
        'attribution': attribution, 'cycle_ms': cyc, 'reset_rtt_ms': rst, 'server_total_ms': srv,
        'recycle_ms': rec, 'cycles': len(cycles), 'wall_s': wall,
        'leases_per_s': len(lease_ms) / wall if wall else None,
        'leaks': leaks, 'fails': fails, 'probe_before': before, 'probe_after': after,
        'arena_growth': growth, 'threshold_ok': threshold_ok, 'pass': ok,
    }
    if args.negative_control:
        behaved = (not threshold_ok and attribution == 'starved-queue' and
                   ws['p99'] is not None and ws['p99'] >= 0.9 * args.resetter_delay_ms and
                   len(lease_ms) == args.leases and not leaks and not fails)
        summary['negative_control_behaved'] = behaved
        print('NEGATIVE CONTROL %s: cycle inflated by %.0f ms client-side -> threshold %s, '
              'attribution %s, wait p99 %.2f ms'
              % ('BEHAVED' if behaved else 'DID NOT BEHAVE', args.resetter_delay_ms,
                 'missed' if not threshold_ok else 'MET (wrong)', attribution, ws['p99'] or 0))
        rc = 0 if behaved else 1
    else:
        print('VERDICT: %s -- lease p99 %.3f ms %s %.2f ms; leaks %s; failures %d'
              % ('PASS' if ok else 'FAIL', ls['p99'] or 0, '<' if threshold_ok else '>=',
                 args.threshold_ms, 'none' if not leaks else len(leaks), len(fails)))
        rc = 0 if ok else 1
    tl.write_report(args.report, summary)
    pool.close()
    return rc


# ---------------------------------------------------------------------------
# reset
# ---------------------------------------------------------------------------

def attribute(cycles):
    """Per-term latency lists (ms) from the cycle records."""
    terms = {}

    def add(k, v):
        terms.setdefault(k, []).append(v)
    for c in cycles:
        s = c.get('server') or {}
        server_sum = 0
        for k in SERVER_TERMS:
            v = s.get(k, 0) / 1000.0
            add(k[:-3], v)
            server_sum += v
        total = s.get('total_us', 0) / 1000.0
        add('server other', max(0.0, total - server_sum))
        add('server total', total)
        add('drain', c['drain_ms'])
        add('reset rtt overhead', max(0.0, c['reset_ms'] - total))
        add('status rtt', c.get('status_ms', 0.0))
        asrv = (c.get('adopt_server_us') or 0) / 1000.0
        add('adopt server (conn 0)', asrv)
        add('adopt rtts (all conns)', max(0.0, c['adopt_ms'] - asrv))
        add('warmup', c.get('warmup_ms', 0.0))
        add('open rtt', c.get('open_ms', 0.0))
        add('recycle', c.get('recycle_ms', 0.0))
        add('cycle', c['cycle_ms'])
    return terms


def run_reset(args, pq, base, ctl, probe):
    lanes = args.lanes.split(',')
    busy_lanes = [x for x in args.busy_lanes.split(',') if x]
    workdir = os.path.join(os.environ.get('MEMCOW_OUTPUTDIR', '.'), 'work')
    os.makedirs(workdir, exist_ok=True)

    # --- the neighbours -----------------------------------------------------
    stop_file = os.path.join(workdir, 'stop')
    go_file = os.path.join(workdir, 'go')
    for f in (stop_file, go_file):
        if os.path.exists(f):
            os.unlink(f)
    procs = []
    here = os.path.dirname(os.path.abspath(__file__))
    for k, bl in enumerate(busy_lanes):
        ready = os.path.join(workdir, 'busy%d.ready' % k)
        rep = os.path.join(workdir, 'busy%d.json' % k)
        for f in (ready, rep):
            if os.path.exists(f):
                os.unlink(f)
        cmd = [sys.executable, os.path.join(here, 'busy_driver.py'), '--lanes', bl,
               '--conns', str(args.conns), '--mode', args.busy_mode,
               '--retire-after', str(args.retire_after),
               '--stop-file', stop_file, '--ready-file', ready, '--go-file', go_file, '--report', rep]
        log = open(os.path.join(workdir, 'busy%d.log' % k), 'w')
        procs.append((subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT), ready, rep, log))
    deadline = time.monotonic() + 180
    for p, ready, rep, log in procs:
        while not os.path.exists(ready):
            if p.poll() is not None or time.monotonic() > deadline:
                print('busy driver for %s did not become ready; see %s' % (rep, log.name))
                return 2
            time.sleep(0.05)
    pool = mp.LanePool(pq, base, lanes, conns_per_lane=args.conns,
                       control_db=tl.control_db(), retire_after_epochs=args.retire_after,
                       resetters=0, capture_timings=True,
                       log=lambda m: print('      [pool] %s' % m))
    pool.open()

    print('%s reset benchmark%s: %d resets on %d lane(s) x %d conns, workload=%s, retire-after=%d; '
          'busy neighbours: %d lane(s) in %s mode; threshold %.1f ms%s'
          % (tl.stamp(), ' [%s]' % args.label if args.label else '', args.resets, len(lanes),
             args.conns, args.workload, args.retire_after, len(busy_lanes), args.busy_mode,
             args.threshold_ms,
             ' [NEGATIVE CONTROL: park %.0f ms in the sweep]' % args.nc_sweep_wait_ms
             if args.negative_control else ''))
    # every lane is fresh now: the neighbours have opened (and reset) theirs
    # and are waiting for the go-file; sample the leak baseline, then go
    before = probe.sample()
    print('baseline: dsm=%d pgdata-minus-wal=%dkB aio=%d pinned=%d'
          % (before['dsm_segments'], before['pgdata_minus_wal_kb'],
             before['aio_handles_in_flight'], before['pinned_buffers']))
    if procs:
        with open(go_file, 'w') as f:
            f.write('go\n')
        time.sleep(1.0)     # let them reach steady state

    fails = []

    def run(n, tag):
        cycles = []
        t0 = time.monotonic()
        for i in range(1, n + 1):
            try:
                w = pool.lease()
                w.exec_params(tl.FIRST_QUERY, ['1'])
                tl.run_workload(w, args.workload, i)
                rec = pool.release(w)
            except (mp.PGError, mp.PoolError, mp.LaneRetired) as e:
                fails.append('%s reset %d: %s' % (tag, i, e))
                break
            if rec.get('server') is None:
                fails.append('%s reset %d: no server timings' % (tag, i))
                break
            cycles.append(rec)
            if i % args.progress_every == 0:
                s = tl.summarize([c['cycle_ms'] for c in cycles])
                print('%s %d: cycle p50=%.2f p99=%.2f max=%.2f ms; elapsed %ds'
                      % (tag, i, s['p50'], s['p99'], s['max'], int(time.monotonic() - t0)))
        return cycles

    # --- the measurement ------------------------------------------------------
    baseline = None
    waker_stop = None
    if args.negative_control:
        nb = max(100, args.resets // 4)
        print('negative control: %d baseline resets first, without the park' % nb)
        baseline = run(nb, 'baseline')
        # park every reset at the sweep point for X ms: attach 'wait', and a
        # waker thread that fires wakeups after X ms until the cycle is over
        # (a wakeup before the waiter arrives is lost, so it repeats).
        ctl.exec("SELECT injection_points_attach('%s', 'wait')" % NC_POINT)
        waker_ctl = mp.Conn(pq, base + ' dbname=' + tl.control_db())
        waker_stop = threading.Event()
        cycle_gate = threading.Event()

        def waker():
            while not waker_stop.is_set():
                if not cycle_gate.wait(0.05):
                    continue
                time.sleep(args.nc_sweep_wait_ms / 1000.0)
                while cycle_gate.is_set() and not waker_stop.is_set():
                    try:
                        waker_ctl.exec("SELECT injection_points_wakeup('%s')" % NC_POINT)
                    except mp.PGError:
                        pass
                    time.sleep(0.002)
        th = threading.Thread(target=waker, name='nc-waker', daemon=True)
        th.start()
        orig_reset = pool.reset_lane_raw

        def gated_reset(lane, timeout_ms=None, ctl=None):
            cycle_gate.set()
            try:
                return orig_reset(lane, timeout_ms=timeout_ms, ctl=ctl)
            finally:
                cycle_gate.clear()
        pool.reset_lane_raw = gated_reset

    cycles = run(args.resets, 'reset')

    if waker_stop is not None:
        # Detaching prevents new waits but does not release parked neighbours:
        # keep waking them until their current reset and shutdown complete.
        cycle_gate.set()
        try:
            ctl.exec("SELECT injection_points_detach('%s')" % NC_POINT)
        except mp.PGError:
            pass

    # --- stop the neighbours ------------------------------------------------------
    with open(stop_file, 'w') as f:
        f.write('stop\n')
    busy_reports = []
    for p, ready, rep, log in procs:
        try:
            p.wait(timeout=120)
        except subprocess.TimeoutExpired:
            p.kill()
        log.close()
        try:
            busy_reports.append(json.load(open(rep)))
        except Exception as e:  # noqa: BLE001
            busy_reports.append({'error': str(e)})
    if waker_stop is not None:
        waker_stop.set()
        th.join()
        waker_ctl.close()
    time.sleep(0.2)
    after = probe.sample()
    all_lanes = set(lanes) | set(busy_lanes)
    leaks = tl.LeakProbe.diff(before, after, lanes=all_lanes)
    growth = tl.arena_growth(before, after, all_lanes)

    # --- attribution ----------------------------------------------------------------
    terms = attribute(cycles)
    summ = dict((k, tl.summarize(v)) for k, v in terms.items())
    cyc = summ['cycle']

    def share_at_p99(name):
        """Mean share of term `name` in the cycles at/above the cycle p99."""
        cut = cyc['p99']
        num = den = 0.0
        for idx, c in enumerate(cycles):
            if c['cycle_ms'] >= cut:
                num += terms[name][idx]
                den += c['cycle_ms']
        return num / den if den else 0.0

    print()
    print('reset cycle (quiesce -> ready incl. warmup), %d cycles, lanes %s:' % (len(cycles), ','.join(lanes)))
    print(tl.fmt_row('cycle', cyc))
    print('server steps (memcow_lane_reset_timings):')
    for k in [t[:-3] for t in SERVER_TERMS] + ['server other', 'server total']:
        print(tl.fmt_row(k, summ[k]))
    print('client terms:')
    for k in ('drain', 'reset rtt overhead', 'status rtt', 'adopt server (conn 0)',
              'adopt rtts (all conns)', 'warmup', 'open rtt', 'recycle'):
        print(tl.fmt_row(k, summ[k]))
    print('  polls: fence %d, reclaim %d (10 ms sleeps); stragglers killed %d; poisoned pages p50 %d'
          % (sum(c['server']['fence_polls'] for c in cycles),
             sum(c['server']['reclaim_polls'] for c in cycles),
             sum(c['server']['stragglers'] for c in cycles),
             tl.percentile([c['server']['poisoned_pages'] for c in cycles], 0.5) or 0))
    print('  shares at the cycle p99: barrier %.0f%%, sweep_buffers %.0f%%, adopt+warmup %.0f%%, '
          'client rtts %.0f%%, recycle %.0f%%'
          % (100 * share_at_p99('barrier'), 100 * share_at_p99('sweep_buffers'),
             100 * (share_at_p99('adopt server (conn 0)') + share_at_p99('adopt rtts (all conns)') +
                    share_at_p99('warmup')),
             100 * (share_at_p99('reset rtt overhead') + share_at_p99('status rtt') +
                    share_at_p99('adopt rtts (all conns)') + share_at_p99('open rtt') +
                    share_at_p99('drain')),
             100 * share_at_p99('recycle')))
    print('  barrier absorption (emit -> every process absorbed): p50 %.3f p99 %.3f max %.3f ms'
          % (summ['barrier']['p50'], summ['barrier']['p99'], summ['barrier']['max']))
    for r in busy_reports:
        if 'error' in r:
            print('  neighbour: %s' % r['error'])
        else:
            print('  neighbour %s (%s): %d cycles in %.0fs, work p50 %.0f ms, cycle p50 %.1f p99 %.1f ms%s'
                  % (r['lanes'], r['mode'], r['iterations'], r['wall_s'], r['work_ms']['p50'] or 0,
                     r['cycle_ms']['p50'] or 0, r['cycle_ms']['p99'] or 0,
                     '; FAILS %s' % r['fails'] if r.get('fails') else ''))
    report_common(before, after, growth, leaks, fails)

    threshold_ok = cyc['p99'] is not None and cyc['p99'] < args.threshold_ms and len(cycles) == args.resets
    ok = threshold_ok and not leaks and not fails
    summary = {
        'driver': 'reset', 'label': args.label, 'when': tl.stamp(), 'resets': args.resets,
        'completed': len(cycles), 'lanes': lanes, 'conns': args.conns, 'workload': args.workload,
        'retire_after': args.retire_after, 'busy_lanes': busy_lanes, 'busy_mode': args.busy_mode,
        'threshold_ms': args.threshold_ms, 'negative_control': args.negative_control,
        'cycle_ms': cyc, 'terms': summ,
        'share_at_p99': dict((k, share_at_p99(k)) for k in terms if k != 'cycle'),
        'polls': {'fence': sum(c['server']['fence_polls'] for c in cycles),
                  'reclaim': sum(c['server']['reclaim_polls'] for c in cycles)},
        'busy_reports': busy_reports, 'leaks': leaks, 'fails': fails,
        'probe_before': before, 'probe_after': after, 'arena_growth': growth,
        'threshold_ok': threshold_ok, 'pass': ok,
    }
    if args.negative_control:
        bsumm = dict((k, tl.summarize(v)) for k, v in attribute(baseline).items())
        moved = {}
        for k in [t[:-3] for t in SERVER_TERMS]:
            moved[k] = (summ[k]['p50'] or 0) - (bsumm[k]['p50'] or 0)
        inflated = moved['sweep_buffers'] >= 0.9 * args.nc_sweep_wait_ms
        others_flat = all(abs(v) < 1.0 for k, v in moved.items() if k != 'sweep_buffers')
        behaved = (inflated and others_flat and not threshold_ok and
                   len(cycles) == args.resets and len(baseline) == nb and
                   not leaks and not fails)
        summary['negative_control'] = {'sweep_wait_ms': args.nc_sweep_wait_ms, 'moved_p50_ms': moved,
                                       'baseline_cycle_ms': bsumm['cycle'], 'behaved': behaved}
        print('NEGATIVE CONTROL %s: %.0f ms parked in the sweep -> sweep_buffers p50 moved %+.2f ms, '
              'other server terms moved at most %.2f ms, cycle p99 %.2f -> %.2f ms, threshold %s'
              % ('BEHAVED' if behaved else 'DID NOT BEHAVE', args.nc_sweep_wait_ms,
                 moved['sweep_buffers'],
                 max(abs(v) for k, v in moved.items() if k != 'sweep_buffers'),
                 bsumm['cycle']['p99'] or 0, cyc['p99'] or 0,
                 'missed' if not threshold_ok else 'MET (wrong)'))
        rc = 0 if behaved else 1
    else:
        print('VERDICT: %s -- reset cycle p99 %.2f ms %s %.1f ms at this load; leaks %s; failures %d'
              % ('PASS' if ok else 'FAIL', cyc['p99'] or 0, '<' if threshold_ok else '>=',
                 args.threshold_ms, 'none' if not leaks else len(leaks), len(fails)))
        rc = 0 if ok else 1
    tl.write_report(args.report, summary)
    pool.close()
    return rc


def main():
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument('driver', choices=('lease', 'reset'))
    ap.add_argument('--lanes', default='memcow_lane_00,memcow_lane_01')
    ap.add_argument('--conns', type=int, default=2)
    ap.add_argument('--retire-after', type=int, default=50)
    ap.add_argument('--workload', choices=tl.WORKLOAD_NAMES, default=None,
                    help='per-lease work (default: light for lease, soak for reset)')
    ap.add_argument('--threshold-ms', type=float, default=None,
                    help='default: 1.0 for lease, 25.0 for reset')
    ap.add_argument('--negative-control', action='store_true')
    ap.add_argument('--progress-every', type=int, default=None)
    ap.add_argument('--report', default=None)
    # lease
    ap.add_argument('--leases', type=int, default=100000)
    ap.add_argument('--resetters', type=int, default=1)
    ap.add_argument('--resetter-delay-ms', type=float, default=0.0)
    # reset
    ap.add_argument('--resets', type=int, default=3000)
    ap.add_argument('--busy-lanes', default='')
    ap.add_argument('--busy-mode', choices=('soak', 'plpgsql'), default='soak')
    ap.add_argument('--nc-sweep-wait-ms', type=float, default=40.0)
    ap.add_argument('--label', default='')
    args = ap.parse_args()
    if args.driver == 'lease':
        args.workload = args.workload or 'light'
        args.threshold_ms = args.threshold_ms or 1.0
        args.progress_every = args.progress_every or 5000
    else:
        args.workload = args.workload or 'soak'
        args.threshold_ms = args.threshold_ms or 25.0
        args.progress_every = args.progress_every or 500

    pq, base, ctl = tl.connect()
    if args.negative_control and args.driver == 'reset':
        ctl.exec('CREATE EXTENSION IF NOT EXISTS injection_points')
    probe = tl.LeakProbe(tl.pgdata(), ctl)
    if args.driver == 'lease':
        rc = run_lease(args, pq, base, ctl, probe)
    else:
        rc = run_reset(args, pq, base, ctl, probe)
    ctl.close()
    return rc


if __name__ == '__main__':
    sys.exit(main())
