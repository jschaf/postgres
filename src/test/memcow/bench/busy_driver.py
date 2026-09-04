#!/usr/bin/env python3
"""
busy_driver.py --- a neighbour for the reset benchmark: one process, its own
LanePool over its own lanes (statically partitioned, plan §1), looping
lease -> work -> release inline until --stop-file appears.  Three kinds of
work, chosen by --mode:

  soak      pool_soak.py's DDL+DML workload: the lane is a busy test.
  plpgsql   a tight plpgsql loop on one connection (plus a light DML txn on
            the other): a backend that CHECK_FOR_INTERRUPTS()s only once per
            plpgsql statement, plan §7's "CFI-starved backend".
  hold      memcow_lane_starve_interrupts(--hold-ms) on one connection: a
            backend that CANNOT absorb a barrier for that long, which is the
            deterministic worst case for the global SMGRRELEASE barrier.

It writes --ready-file once its lanes are open and --report when told to
stop, with its own cycle latencies, so the measuring process can show what
the neighbours were doing.

Portions Copyright (c) 2026, PostgreSQL Global Development Group
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_common as bc  # noqa: E402
import memcow_pool as mp  # noqa: E402

PLPGSQL_LOOP = ("DO $$ DECLARE i int := 0; BEGIN WHILE i < %d LOOP i := i + 1; END LOOP; END $$")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--libdir', required=True)
    ap.add_argument('--host', required=True)
    ap.add_argument('--port', required=True, type=int)
    ap.add_argument('--user', default=os.environ.get('PGUSER', 'postgres'))
    ap.add_argument('--control-db', default='memcow_control')
    ap.add_argument('--lanes', required=True)
    ap.add_argument('--conns', type=int, default=2)
    ap.add_argument('--mode', choices=('soak', 'plpgsql', 'hold'), default='soak')
    ap.add_argument('--hold-ms', type=int, default=200)
    ap.add_argument('--loop-iterations', type=int, default=1000000)
    ap.add_argument('--retire-after', type=int, default=50)
    ap.add_argument('--stop-file', required=True)
    ap.add_argument('--ready-file', required=True)
    ap.add_argument('--go-file', default=None)
    ap.add_argument('--report', required=True)
    args = ap.parse_args()

    pq = mp.LibPQ(mp.libpq_path(args.libdir))
    base = 'host=%s port=%d user=%s' % (args.host, args.port, args.user)
    pool = mp.LanePool(pq, base, args.lanes.split(','), conns_per_lane=args.conns,
                       control_db=args.control_db, retire_after_epochs=args.retire_after,
                       capture_timings=False)
    pool.open()
    with open(args.ready_file, 'w') as f:
        f.write('%d\n' % os.getpid())
    # the measuring process samples its leak baseline while every lane is
    # fresh, then says go
    while args.go_file and not os.path.exists(args.go_file) and not os.path.exists(args.stop_file):
        time.sleep(0.01)

    cycles, work_ms, fails = [], [], []
    n = 0
    t0 = time.monotonic()
    while not os.path.exists(args.stop_file):
        n += 1
        try:
            w = pool.lease()
            tw = time.monotonic()
            if args.mode == 'soak':
                bc.run_workload(w, 'soak', n)
            elif args.mode == 'plpgsql':
                w.exec(PLPGSQL_LOOP % args.loop_iterations)
                if w.nconns > 1:
                    for stmt in bc.LIGHT_WORKLOAD:
                        w.exec(stmt, i=1)
            else:
                w.exec('SELECT public.memcow_lane_starve_interrupts(%d)' % args.hold_ms)
                if w.nconns > 1:
                    for stmt in bc.LIGHT_WORKLOAD:
                        w.exec(stmt, i=1)
            work_ms.append((time.monotonic() - tw) * 1000.0)
            t = pool.release(w)
            cycles.append(t['cycle_ms'])
        except (mp.PGError, mp.PoolError, mp.LaneRetired) as e:
            fails.append('iteration %d: %s' % (n, e))
            if len(fails) > 5:
                break
            time.sleep(0.1)
    wall = time.monotonic() - t0
    rep = {'mode': args.mode, 'lanes': args.lanes, 'iterations': len(cycles), 'wall_s': wall,
           'hold_ms': args.hold_ms if args.mode == 'hold' else None,
           'work_ms': bc.summarize(work_ms), 'cycle_ms': bc.summarize(cycles), 'fails': fails}
    pool.close()
    bc.write_report(args.report, rep)
    return 0 if not fails else 1


if __name__ == '__main__':
    sys.exit(main())
