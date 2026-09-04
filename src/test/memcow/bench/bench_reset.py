#!/usr/bin/env python3
"""
bench_reset.py --- plan §7.4, the reset half, and the cost attribution:

    reset (quiesce -> ready, including warmup) p99 < 25 ms at
    shared_buffers=512MB, under CONCURRENT BUSY LANES, with the global
    SMGRRELEASE barrier's absorption latency measured explicitly.

This process measures; its neighbours are busy_driver.py subprocesses, one
per busy lane, each with its own pool (soak workload, a tight plpgsql loop,
or an interrupts-held backend, see busy_driver.py).  The measured lanes run
lease -> workload -> release INLINE, so each cycle is one measurement:
drain, memcow_lane_reset(D) round trip, status, adopt (per connection),
warmup, open, and every K epochs the backend recycle.  The engine's own
attribution of the reset comes back with each cycle
(memcow_lane_reset_timings: fence, prepare, publish, barrier, sweep_buffers,
sweep_files, reclaim_wait, poison, destroy, all microseconds) and so does
the adopt's server time, so every term of the cycle is either a server step
or a client round trip and the two sides have to add up.

The negative control (--negative-control --nc-sweep-wait-ms X) parks the
reset at the memcow-lane-reset-in-sweep injection point for X ms, inside
the sweep_buffers term: the run must then show sweep_buffers up by >= 0.9 X
against the baseline it measured first, every other server term unchanged
within 1 ms, and the threshold missed.  A harness that reports anything
else under it does not attribute.

Exit: 0 = threshold met and no leaks (or the control behaved), 1 = not,
2 = could not run.

Portions Copyright (c) 2026, PostgreSQL Global Development Group
"""

import argparse
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_common as bc  # noqa: E402
import memcow_pool as mp  # noqa: E402

SERVER_TERMS = ('fence_us', 'prepare_us', 'publish_us', 'barrier_us', 'sweep_buffers_us',
                'sweep_files_us', 'reclaim_wait_us', 'poison_us', 'destroy_us')
NC_POINT = 'memcow-lane-reset-in-sweep'


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


def dominant_terms(cycles, terms, p=0.99):
    """Among the cycles at or above the p-quantile of cycle time, which
    term is the largest, and how often."""
    cyc = [c['cycle_ms'] for c in cycles]
    if not cyc:
        return {}
    cut = bc.percentile(cyc, p)
    names = [k for k in terms if k not in ('cycle', 'server total')]
    counts = {}
    for idx, c in enumerate(cycles):
        if c['cycle_ms'] < cut:
            continue
        best = max(names, key=lambda k: terms[k][idx])
        counts[best] = counts.get(best, 0) + 1
    return counts


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
    ap.add_argument('--workdir', required=True)
    ap.add_argument('--lanes', default='memcow_lane_00,memcow_lane_01')
    ap.add_argument('--conns', type=int, default=2)
    ap.add_argument('--resets', type=int, default=3000)
    ap.add_argument('--workload', choices=bc.WORKLOAD_NAMES, default='soak')
    ap.add_argument('--retire-after', type=int, default=50)
    ap.add_argument('--busy-lanes', default='')
    ap.add_argument('--busy-mode', choices=('soak', 'plpgsql', 'hold'), default='soak')
    ap.add_argument('--hold-ms', type=int, default=200)
    ap.add_argument('--threshold-ms', type=float, default=25.0)
    ap.add_argument('--negative-control', action='store_true')
    ap.add_argument('--nc-sweep-wait-ms', type=float, default=40.0)
    ap.add_argument('--label', default='')
    ap.add_argument('--progress-every', type=int, default=500)
    ap.add_argument('--report', default=None)
    args = ap.parse_args()

    pq = mp.LibPQ(mp.libpq_path(args.libdir))
    base = 'host=%s port=%d user=%s' % (args.host, args.port, args.user)
    lanes = args.lanes.split(',')
    busy_lanes = [x for x in args.busy_lanes.split(',') if x]
    os.makedirs(args.workdir, exist_ok=True)

    ctl = mp.Conn(pq, base + ' dbname=' + args.control_db)
    ctl.exec('CREATE EXTENSION IF NOT EXISTS memcow_lanes')
    ctl.exec('CREATE EXTENSION IF NOT EXISTS injection_points')
    probe = bc.LeakProbe(args.pgdata, ctl)

    # --- the neighbours -----------------------------------------------------
    stop_file = os.path.join(args.workdir, 'stop')
    go_file = os.path.join(args.workdir, 'go')
    for f in (stop_file, go_file):
        if os.path.exists(f):
            os.unlink(f)
    procs = []
    here = os.path.dirname(os.path.abspath(__file__))
    for k, bl in enumerate(busy_lanes):
        ready = os.path.join(args.workdir, 'busy%d.ready' % k)
        rep = os.path.join(args.workdir, 'busy%d.json' % k)
        for f in (ready, rep):
            if os.path.exists(f):
                os.unlink(f)
        cmd = [sys.executable, os.path.join(here, 'busy_driver.py'),
               '--libdir', args.libdir, '--host', args.host, '--port', str(args.port),
               '--user', args.user, '--control-db', args.control_db, '--lanes', bl,
               '--conns', str(args.conns), '--mode', args.busy_mode,
               '--hold-ms', str(args.hold_ms), '--retire-after', str(args.retire_after),
               '--stop-file', stop_file, '--ready-file', ready, '--go-file', go_file, '--report', rep]
        log = open(os.path.join(args.workdir, 'busy%d.log' % k), 'w')
        procs.append((subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT), ready, rep, log))
    deadline = time.monotonic() + 180
    for p, ready, rep, log in procs:
        while not os.path.exists(ready):
            if p.poll() is not None or time.monotonic() > deadline:
                print('busy driver for %s did not become ready; see %s' % (rep, log.name))
                return 2
            time.sleep(0.05)
    pool = mp.LanePool(pq, base, lanes, conns_per_lane=args.conns,
                       control_db=args.control_db, retire_after_epochs=args.retire_after,
                       resetters=0, capture_timings=True,
                       log=lambda m: print('      [pool] %s' % m))
    pool.open()

    print('%s reset benchmark%s: %d resets on %d lane(s) x %d conns, workload=%s, retire-after=%d; '
          'busy neighbours: %d lane(s) in %s mode%s; threshold %.1f ms%s'
          % (bc.stamp(), ' [%s]' % args.label if args.label else '', args.resets, len(lanes),
             args.conns, args.workload, args.retire_after, len(busy_lanes), args.busy_mode,
             ' (hold %d ms)' % args.hold_ms if args.busy_mode == 'hold' else '', args.threshold_ms,
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

    warm = [None]

    def run(n, tag):
        cycles = []
        t0 = time.monotonic()
        warm_at = max(100, n // 10)
        for i in range(1, n + 1):
            if i == warm_at and tag == 'reset':
                warm[0] = probe.sample()
            try:
                w = pool.lease()
                w.exec_params(bc.FIRST_QUERY, ['1'])
                bc.run_workload(w, args.workload, i)
                rec = pool.release(w)
            except (mp.PGError, mp.PoolError, mp.LaneRetired) as e:
                fails.append('%s reset %d: %s' % (tag, i, e))
                break
            if rec.get('server') is None:
                fails.append('%s reset %d: no server timings' % (tag, i))
                break
            cycles.append(rec)
            if i % args.progress_every == 0:
                s = bc.summarize([c['cycle_ms'] for c in cycles])
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
        waker_ctl = mp.Conn(pq, base + ' dbname=' + args.control_db)
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
        waker_stop.set()
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
            import json
            busy_reports.append(json.load(open(rep)))
        except Exception as e:  # noqa: BLE001
            busy_reports.append({'error': str(e)})
    time.sleep(0.2)
    after = probe.sample()
    leaks = bc.LeakProbe.diff(before, after, warm=warm[0], lanes=set(lanes) | set(busy_lanes))
    log_hits = bc.scan_log(args.logfile) if args.logfile else []
    growth = bc.arena_growth(before, after, set(lanes) | set(busy_lanes))

    # --- attribution ----------------------------------------------------------------
    terms = attribute(cycles)
    summ = dict((k, bc.summarize(v)) for k, v in terms.items())
    dom = dominant_terms(cycles, terms)
    cyc = summ['cycle']
    cyc_plain = bc.summarize([c['cycle_ms'] for c in cycles if not c['recycled']])
    srv_total_p99 = summ['server total']['p99'] or 0.0

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
    print(bc.fmt_row('cycle (all)', cyc))
    print(bc.fmt_row('cycle (no recycle)', cyc_plain))
    print('server steps (memcow_lane_reset_timings):')
    for k in [t[:-3] for t in SERVER_TERMS] + ['server other', 'server total']:
        print(bc.fmt_row(k, summ[k]))
    print('client terms:')
    for k in ('drain', 'reset rtt overhead', 'status rtt', 'adopt server (conn 0)',
              'adopt rtts (all conns)', 'warmup', 'open rtt', 'recycle'):
        print(bc.fmt_row(k, summ[k]))
    print('  polls: fence %d, reclaim %d (10 ms sleeps); stragglers killed %d; poisoned pages p50 %d'
          % (sum(c['server']['fence_polls'] for c in cycles),
             sum(c['server']['reclaim_polls'] for c in cycles),
             sum(c['server']['stragglers'] for c in cycles),
             bc.percentile([c['server']['poisoned_pages'] for c in cycles], 0.5) or 0))
    print('  largest term in the cycles at/above the cycle p99: %s'
          % ', '.join('%s x%d' % kv for kv in sorted(dom.items(), key=lambda kv: -kv[1])))
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
    print('leaks: %s' % (leaks if leaks else 'none (dsm %d -> %d -> %d initial/warm/final, aio 0, pins 0, fds flat, '
                         'no mapping to a gone segment)'
                         % (before['dsm_segments'], warm[0]['dsm_segments'] if warm[0] else -1,
                            after['dsm_segments'])))
    for n in bc.LeakProbe.notes:
        print('note: %s' % n)
    print('never-reset overlays (bounded hint-bit copy-on-write, plan Appendix C): %s'
          % ', '.join('%s %dkB -> %dkB' % (k, v[0] // 1024, v[1] // 1024) for k, v in sorted(growth.items())))
    for h in log_hits[:10]:
        print('server log: ' + h)
    for f in fails:
        print('FAIL  %s' % f)

    threshold_ok = cyc['p99'] is not None and cyc['p99'] < args.threshold_ms and len(cycles) == args.resets
    ok = threshold_ok and not leaks and not fails and not log_hits
    summary = {
        'driver': 'bench_reset', 'label': args.label, 'when': bc.stamp(), 'resets': args.resets,
        'completed': len(cycles), 'lanes': lanes, 'conns': args.conns, 'workload': args.workload,
        'retire_after': args.retire_after, 'busy_lanes': busy_lanes, 'busy_mode': args.busy_mode,
        'hold_ms': args.hold_ms if args.busy_mode == 'hold' else None,
        'threshold_ms': args.threshold_ms, 'negative_control': args.negative_control,
        'cycle_ms': cyc, 'cycle_ms_no_recycle': cyc_plain, 'terms': summ, 'dominant_at_p99': dom,
        'share_at_p99': dict((k, share_at_p99(k)) for k in terms if k not in ('cycle',)),
        'server_total_p99_ms': srv_total_p99,
        'polls': {'fence': sum(c['server']['fence_polls'] for c in cycles),
                  'reclaim': sum(c['server']['reclaim_polls'] for c in cycles)},
        'busy_reports': busy_reports, 'leaks': leaks, 'log_hits': log_hits, 'fails': fails,
        'probe_before': before, 'probe_warm': warm[0], 'probe_after': after, 'arena_growth': growth,
        'threshold_ok': threshold_ok, 'pass': ok,
    }
    if args.negative_control:
        bterms = attribute(baseline)
        bsumm = dict((k, bc.summarize(v)) for k, v in bterms.items())
        moved = {}
        for k in [t[:-3] for t in SERVER_TERMS]:
            moved[k] = (summ[k]['p50'] or 0) - (bsumm[k]['p50'] or 0)
        inflated = moved['sweep_buffers'] >= 0.9 * args.nc_sweep_wait_ms
        others_flat = all(abs(v) < 1.0 for k, v in moved.items() if k != 'sweep_buffers')
        behaved = inflated and others_flat and not threshold_ok
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
                 args.threshold_ms, 'none' if not leaks else len(leaks), len(fails) + len(log_hits)))
        rc = 0 if ok else 1
    bc.write_report(args.report, summary)
    pool.close()
    ctl.close()
    return rc


if __name__ == '__main__':
    sys.exit(main())
