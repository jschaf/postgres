#!/usr/bin/env python3
"""
pool_soak.py --- plan §7.2's reset soak, driven through the pool.

Loop N x { lease -> DDL+DML workload -> release }, where release drains,
resets, adopts, warms up and reopens armed (memcow_pool.LanePool), and
after every cycle verify what §7.2 says must hold:

  * lane status: OPEN at the expected epoch, attached_old 0, reclaim not
    pending (the pool itself checked RESETTING/epoch/attached_old right
    after memcow_lane_reset returned);
  * the DSM segment count is FLAT -- the old arena's segments are gone
    after every reset, none leak -- counted as files under pg_dynshmem,
    which does not trust memcow's own accounting (with_server.sh sets
    dynamic_shared_memory_type=mmap, track_counts=off and no parallel query
    so nothing else creates segments);
  * PGDATA-minus-WAL flat within 2 MB (pg_wal is bounded by max_wal_size
    and recycles);
  * pg_filenode.map byte-stable: the reset verifies it against the seed and
    retires the lane otherwise, which fails the soak;
  * the seed digest on a retained connection after every adopt, the
    cross-epoch artifact query on the other, and every --fresh-every
    iterations the digest from a FRESH connection that presents the current
    nonce (so both admission fences are exercised positively);
  * every --fence-every iterations the fence, both halves: a registered
    backend left busy (the reset must be REFUSED, then succeed on retry --
    the pool's own retry path) and an unregistered straggler holding an open
    transaction (killed by the reset; its PID must be gone);
  * a released wrapper is dead in process (fence 1 of 3).

Fail = any cross-epoch artifact, any monotonic DSM/RAM-dir growth, any
refusal or straggler the fence got wrong, any unexpected ERROR; the server
log is scanned by with_server.sh afterwards.

Latencies (ms) are informational; §7.4 owns the thresholds.  Exit status:
0 pass, 1 fail.

Portions Copyright (c) 2026, PostgreSQL Global Development Group
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import memcow_pool as mp  # noqa: E402
import testlib as tl  # noqa: E402

ARTIFACT_SQL = ("SELECT count(*) || '|' || (SELECT count(*) FROM pg_class WHERE relname "
                "LIKE 'soak%') FROM public.events")


def main():
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument('--lanes', default='memcow_lane_00,memcow_lane_01')
    ap.add_argument('--conns', type=int, default=2)
    ap.add_argument('--iterations', type=int, default=10000)
    ap.add_argument('--fence-every', type=int, default=100)
    ap.add_argument('--fresh-every', type=int, default=50)
    ap.add_argument('--retire-after', type=int, default=50)
    ap.add_argument('--report', default=None)
    ap.add_argument('--progress-every', type=int, default=100)
    args = ap.parse_args()

    pq, base, ctl = tl.connect()
    pgdata = tl.pgdata()
    fails = []

    def fail(msg):
        print('FAIL  %s' % msg)
        fails.append(msg)

    pool = mp.LanePool(pq, base, args.lanes.split(','), conns_per_lane=args.conns,
                       control_db=tl.control_db(), retire_after_epochs=args.retire_after,
                       log=lambda m: print('      [pool] %s' % m))
    pool.open()
    lanes = list(pool.lanes.values())

    # seed digest, from a fresh connection to the first lane at its fresh epoch
    l0 = lanes[0]
    c = mp.Conn(pq, pool.lane_conninfo(l0, l0.nonce))
    digest_seed = c.scalar(tl.DIGEST_SQL)
    c.close()
    if not digest_seed or len(digest_seed) != 32:
        print('cannot take the seed digest: %r' % digest_seed)
        return 2
    print('seed digest: %s' % digest_seed)

    dsm_base = tl.dsm_files(pgdata)
    data_base = tl.data_kb(pgdata)
    print('baseline: dsm segments=%d  pgdata-minus-wal=%dkB  wal=%dkB  lanes=%s  conns/lane=%d'
          % (dsm_base, data_base, tl.wal_kb(pgdata), ','.join(l.name for l in lanes), args.conns))
    expected_epoch = {l.name: l.epoch for l in lanes}

    lat_reset, lat_cycle, lat_lease = [], [], []
    straggler = None
    fence_refusals = 0
    stragglers_killed = 0
    t_start = time.monotonic()

    for i in range(1, args.iterations + 1):
        t_lease0 = time.monotonic()
        w = pool.lease()
        lane = w._lane
        try:
            w.exec_params(tl.FIRST_QUERY, ['1'])
        except mp.PGError as e:
            fail('iteration %d: first parameterized query: %s' % (i, e))
            break
        lat_lease.append((time.monotonic() - t_lease0) * 1000.0)
        expected_epoch[lane.name] = lane.epoch + 1

        try:
            tl.run_workload(w, 'soak', i)
        except mp.PGError as e:
            fail('iteration %d workload: %s' % (i, e))

        fence_iter = args.fence_every > 0 and i % args.fence_every == 0
        if fence_iter:
            # (a) a busy registered backend: the reset must be refused
            w.conn(0).send('SELECT pg_sleep(1.0)')
            time.sleep(0.2)
            try:
                pool.reset_lane_raw(lane, timeout_ms=500)
                fail('iteration %d: reset with a busy registered backend was not refused' % i)
            except mp.LaneRefused as e:
                if 'not idle' not in str(e):
                    fail('iteration %d: refusal text unexpected: %s' % (i, e))
                fence_refusals += 1
            w.conn(0).get_results(timeout=30)
            # A refused reset leaves the lane CLOSED (RESETTING); reopen it
            # unarmed so the straggler can connect with no nonce -- exactly
            # the connection string that escaped the pool.  The release()
            # below drains the registered backends and resets, and that
            # reset's fence must find and kill this straggler.
            ctl.exec('SELECT memcow_lane_open(%d, false)' % lane.oid)
            lane.nonce = 0
            # (b) an unregistered straggler in an open transaction, killed by the reset
            straggler = mp.Conn(pq, pool.lane_conninfo(lane, 0))
            straggler.send('BEGIN; UPDATE public.accounts SET balance = 0 WHERE account_id = 1; '
                           'SELECT pg_sleep(30);')
            time.sleep(0.2)

        # release: drain, reset, adopt, warmup, open -- the pool does all of it
        try:
            t = pool.release(w)
        except mp.LaneRetired as e:
            fail('iteration %d: %s' % (i, e))
            break
        lat_reset.append(t['reset_ms'])
        lat_cycle.append(t['cycle_ms'])

        # the wrapper is dead, in process
        try:
            w.exec('SELECT 1')
            fail('iteration %d: released wrapper still usable' % i)
        except mp.StaleWrapperError:
            pass

        if fence_iter:
            alive = ctl.scalar('SELECT count(*) FROM pg_stat_activity WHERE pid = %d' % straggler.pid)
            if alive != '0':
                fail('iteration %d: straggler %d survived the reset' % (i, straggler.pid))
            else:
                stragglers_killed += 1
            if straggler.alive():
                straggler.get_results(timeout=5)
            straggler.close()
            straggler = None

        # per-reset verifications
        st = pool.status(lane.name)
        if st['state'] != 'OPEN' or int(st['epoch']) != expected_epoch[lane.name] \
                or int(st['attached_old']) != 0 or st['reclaim_pending'] != 'f':
            fail('iteration %d: status after cycle: %r (expected epoch %d)'
                 % (i, st, expected_epoch[lane.name]))
        n = tl.dsm_files(pgdata)
        if n != dsm_base:
            fail('iteration %d: DSM segment count %d != baseline %d' % (i, n, dsm_base))
        d = tl.data_kb(pgdata)
        if d > data_base + 2048:
            fail('iteration %d: pgdata-minus-wal %dkB grew past baseline %dkB' % (i, d, data_base))
        try:
            dg = lane.conns[0].scalar(tl.DIGEST_SQL)
            if dg != digest_seed:
                fail('iteration %d: digest on retained conn 0 of %s: %s' % (i, lane.name, dg))
            if i % 2 == 0:
                a = lane.conns[1].scalar(ARTIFACT_SQL)
                if a != '4000|0':
                    fail('iteration %d: cross-epoch artifact on retained conn 1: %s' % (i, a))
        except mp.PGError as e:
            fail('iteration %d: verification query: %s' % (i, e))
        if args.fresh_every > 0 and i % args.fresh_every == 0:
            try:
                fc = mp.Conn(pq, pool.lane_conninfo(lane, lane.nonce))
                dg = fc.scalar(tl.DIGEST_SQL)
                fc.close()
                if dg != digest_seed:
                    fail('iteration %d: digest on a fresh connection: %s' % (i, dg))
            except mp.PGError as e:
                fail('iteration %d: fresh connection with the current nonce refused: %s' % (i, e))

        if i % args.progress_every == 0:
            print('iteration %d: %s epoch %d, dsm=%d, pgdata-minus-wal=%dkB, wal=%dkB, '
                  'reset %.0fms cycle %.0fms lease %.2fms'
                  % (i, lane.name, expected_epoch[lane.name], n, d, tl.wal_kb(pgdata),
                     t['reset_ms'], t['cycle_ms'], lat_lease[-1]))
        if fails:
            break

    t_end = time.monotonic()
    summary = {
        'iterations': args.iterations,
        'completed': len(lat_reset),
        'lanes': args.lanes,
        'conns_per_lane': args.conns,
        'dsm_base': dsm_base,
        'fence_refusals': fence_refusals,
        'stragglers_killed': stragglers_killed,
        'recycles': sum(l.recycles for l in lanes),
        'reset_ms': tl.summarize(lat_reset),
        'cycle_ms': tl.summarize(lat_cycle),
        'lease_first_query_ms': tl.summarize(lat_lease),
        'wall_s': t_end - t_start,
        'fails': fails,
    }
    if lat_reset:
        print('resets: %d   reset p50=%.1fms p99=%.1fms   cycle(release->ready) p50=%.1fms p99=%.1fms   '
              'lease->first param query p50=%.2fms p99=%.2fms   wall=%ds   backend recycles=%d'
              % (len(lat_reset), summary['reset_ms']['p50'], summary['reset_ms']['p99'],
                 summary['cycle_ms']['p50'], summary['cycle_ms']['p99'],
                 summary['lease_first_query_ms']['p50'], summary['lease_first_query_ms']['p99'],
                 int(t_end - t_start), summary['recycles']))
        print('fence: %d refusals of a busy registered backend, %d stragglers killed'
              % (fence_refusals, stragglers_killed))
    pool.close()
    ctl.close()
    tl.write_report(args.report, summary)
    if fails:
        print('POOL SOAK FAIL')
        return 1
    print('POOL SOAK PASS -- %d resets through the pool, DSM flat at %d segments, digest stable'
          % (len(lat_reset), dsm_base))
    return 0


if __name__ == '__main__':
    sys.exit(main())
