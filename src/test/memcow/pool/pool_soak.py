#!/usr/bin/env python3
"""
pool_soak.py --- plan §7.2's reset soak, driven through the pool.

The same loop and the same per-reset verifications as harness/reset_soak.sh
(which drives two psql sessions by hand), but every lane operation goes
through memcow_pool.LanePool: lease, workload on the wrapper, release --
which drains, resets, adopts, warms up and reopens armed -- and then the
checks:

  * lane status after the cycle: OPEN at the expected epoch, attached_old 0,
    reclaim not pending;
  * DSM segment count flat (counted as files under pg_dynshmem: needs
    dynamic_shared_memory_type=mmap, which the wrapper script sets);
  * PGDATA-minus-WAL flat within 2 MB;
  * the seed digest on a retained connection after every adopt, the
    cross-epoch artifact query on the other, and every --fresh-every
    iterations the digest from a FRESH connection that presents the current
    nonce (so both admission fences are exercised positively every time);
  * every --fence-every iterations the fence, both halves: a registered
    backend left busy (the reset must be REFUSED, then succeed on retry --
    the pool's own retry path) and an unregistered straggler holding an open
    transaction (killed by the reset; its PID must be gone).

Plus the two measurements plan §7 leaves open:

  --measure-tmp        the straggler is a query spilling to pgsql_tmp when the
                       fence kills it; base/pgsql_tmp is measured after every
                       reset and its peak and final size reported.
  --measure-shdepend   the lane connections run as a NON-PINNED superuser
                       role, so every relation the workload creates adds a
                       pg_shdepend owner row (a shared catalog: dbOid-0
                       overlay, never reset); the row count for the lane and
                       the shared arena's size are sampled every iteration
                       and at the end DROP ROLE / DROP OWNED are attempted,
                       so the §6 precondition can be confirmed or relaxed
                       from evidence.

Latencies (ms), all informational -- §7.4 owns the thresholds:
  reset      the memcow_lane_reset(D) call alone
  cycle      release -> ready: drain + reset + adopt + warmup + open
  lease      lease() -> first parameterized query returned

Exit status: 0 pass, 1 fail.  Started by harness/pool_soak.sh, which owns the
server; run it by hand only against a server that script would start.

Portions Copyright (c) 2026, PostgreSQL Global Development Group
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import memcow_pool as mp  # noqa: E402

DIGEST_SQL = ("SELECT md5(string_agg(relname || ':' || nrows || ':' || digest, ',' "
              "ORDER BY relname)) FROM public.memcow_seed_digest")
ARTIFACT_SQL = ("SELECT count(*) || '|' || (SELECT count(*) FROM pg_class WHERE relname "
                "LIKE 'soak%') FROM public.events")

WORKLOADS = [
    """CREATE TABLE soak_t{i} AS SELECT g AS id, repeat('x', 100) AS pad FROM generate_series(1, 5000) g;
CREATE INDEX ON soak_t{i} (id);
UPDATE public.events SET kind = 'soak' WHERE event_id % 7 = 0;
DELETE FROM public.ledger WHERE entry_no % 3 = 0;
INSERT INTO public.accounts SELECT * FROM public.accounts LIMIT 0;""",
    """DELETE FROM public.events;
VACUUM (TRUNCATE on) public.events;
CREATE TEMP TABLE soak_tmp AS SELECT * FROM public.accounts;
UPDATE soak_tmp SET balance = balance + 1;""",
    """DROP TABLE public.staging CASCADE;
ALTER TABLE public.documents ADD COLUMN soak int DEFAULT 1;
UPDATE public.documents SET soak = 2;
TRUNCATE public.ledger;
INSERT INTO public.ledger SELECT * FROM public.ledger LIMIT 0;""",
    """BEGIN;
UPDATE public.accounts SET balance = balance * 2;
CREATE TABLE soak_open AS SELECT 1 AS x;""",      # left open: the drain rolls it back
]

SPILL_SQL = ("SET work_mem = '64kB'; BEGIN; UPDATE public.accounts SET balance = 0 WHERE account_id = 1; "
             "SELECT count(*) FROM (SELECT g FROM generate_series(1, 4000000) g ORDER BY g DESC) s;")


def du_kb(path, exclude=()):
    """Directory size in kB from a SINGLE walk.  Names in `exclude` (matched
    on the immediate child of `path`) are skipped entirely -- used to leave
    out pg_wal.  Measuring pgdata and pg_wal in two separate walks and
    subtracting is racy: a 16 MB WAL segment recycled between the two walks
    makes the difference jump by a whole segment, which is not real growth."""
    total = 0
    exclude = set(exclude)
    for root, dirs, files in os.walk(path):
        if root == path:
            dirs[:] = [d for d in dirs if d not in exclude]
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total // 1024


def data_kb(pgdata):
    """PGDATA size excluding pg_wal, in one walk."""
    return du_kb(pgdata, exclude=('pg_wal',))


def wal_kb(pgdata):
    return du_kb(os.path.join(pgdata, 'pg_wal'))


def dsm_files(pgdata):
    d = os.path.join(pgdata, 'pg_dynshmem')
    try:
        return len([f for f in os.listdir(d) if f.startswith('mmap.')])
    except OSError:
        return -1


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
    ap.add_argument('--lanes', default='memcow_lane_00,memcow_lane_01')
    ap.add_argument('--conns', type=int, default=2)
    ap.add_argument('--pgdata', required=True)
    ap.add_argument('--iterations', type=int, default=10000)
    ap.add_argument('--fence-every', type=int, default=100)
    ap.add_argument('--fresh-every', type=int, default=50)
    ap.add_argument('--retire-after', type=int, default=50)
    ap.add_argument('--measure-tmp', action='store_true')
    ap.add_argument('--measure-shdepend', action='store_true')
    ap.add_argument('--report', default=None)
    ap.add_argument('--progress-every', type=int, default=100)
    args = ap.parse_args()

    pq = mp.LibPQ(mp.libpq_path(args.libdir))
    base = 'host=%s port=%d user=%s' % (args.host, args.port, args.user)
    fails = []

    def fail(msg):
        print('FAIL  %s' % msg)
        fails.append(msg)

    def log(msg):
        print('      [pool] %s' % msg)

    # a control connection of the soak's own, beside the pool's
    ctl = mp.Conn(pq, base + ' dbname=' + args.control_db)
    ctl.exec('CREATE EXTENSION IF NOT EXISTS memcow_lanes')

    role_user = args.user
    if args.measure_shdepend:
        # a superuser that is NOT the bootstrap superuser: not pinned, so its
        # objects get pg_shdepend owner rows (the §6 concern)
        ctl.exec("DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'memcow_soak_role') "
                 "THEN CREATE ROLE memcow_soak_role SUPERUSER LOGIN; END IF; END $$")
        role_user = 'memcow_soak_role'
        base_lane = 'host=%s port=%d user=%s' % (args.host, args.port, role_user)
    else:
        base_lane = base

    pool = mp.LanePool(pq, base_lane, args.lanes.split(','), conns_per_lane=args.conns,
                       control_db=args.control_db, retire_after_epochs=args.retire_after,
                       log=log)
    # the pool's control connection must be the bootstrap superuser
    pool.control_conninfo = lambda: base + ' dbname=' + args.control_db
    pool.open()

    lanes = list(pool.lanes.values())
    oids = {l.name: l.oid for l in lanes}

    # seed digest, from a fresh connection to the first lane at its fresh epoch
    l0 = lanes[0]
    c = mp.Conn(pq, pool.lane_conninfo(l0, l0.nonce))
    digest_seed = c.scalar(DIGEST_SQL)
    c.close()
    if not digest_seed or len(digest_seed) != 32:
        print('cannot take the seed digest: %r' % digest_seed)
        return 2
    print('seed digest: %s' % digest_seed)

    dsm_base = dsm_files(args.pgdata)
    data_base = data_kb(args.pgdata)
    print('baseline: dsm segments=%d  pgdata-minus-wal=%dkB  wal=%dkB  lanes=%s  conns/lane=%d'
          % (dsm_base, data_base, wal_kb(args.pgdata),
             ','.join(oids), args.conns))
    expected_epoch = {l.name: l.epoch for l in lanes}

    lat_reset, lat_cycle, lat_lease = [], [], []
    tmp_dir = os.path.join(args.pgdata, 'base', 'pgsql_tmp')
    tmp_samples = []
    shdep_samples = []
    straggler = None
    fence_refusals = 0
    stragglers_killed = 0
    t_start = time.monotonic()

    for i in range(1, args.iterations + 1):
        t_lease0 = time.monotonic()
        w = pool.lease()
        lane = w._lane
        try:
            w.exec_params('SELECT $1::int', ['1'])
        except mp.PGError as e:
            fail('iteration %d: first parameterized query: %s' % (i, e))
            break
        lat_lease.append((time.monotonic() - t_lease0) * 1000.0)
        expected_epoch[lane.name] = lane.epoch + 1

        # the workload, on two connections as in reset_soak.sh.  Each
        # statement goes as its own PQexec: a multi-statement PQexec runs in
        # one implicit transaction, and VACUUM cannot run in a transaction
        # block -- reset_soak.sh sends statements one at a time for the same
        # reason.  Workload 3 opens a transaction and leaves it open on
        # purpose (the drain must roll it back), which survives statement
        # splitting because the statements share the connection.
        for k, cidx in ((i, 0), (i + 2, 1)):
            block = WORKLOADS[k % 4].format(i=k)
            for stmt in (x.strip() for x in block.split('\n')):
                if not stmt:
                    continue
                try:
                    w.exec(stmt, i=cidx)
                except mp.PGError as e:
                    fail('iteration %d workload on conn %d: %s' % (i, cidx, e))
                    break

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
            # A refused reset leaves the lane CLOSED (RESETTING); reopen it so
            # the straggler can connect (unarmed, so it needs no nonce -- it is
            # exactly the connection string that escaped the pool).  The
            # release() below drains the registered backends and resets, and
            # that reset's fence must find and kill this straggler.
            ctl.exec('SELECT memcow_lane_open(%d, false)' % lane.oid)
            lane.nonce = 0
            # (b) an unregistered straggler in an open transaction, killed by the reset
            straggler = mp.Conn(pq, pool.lane_conninfo(lane, 0))
            if args.measure_tmp:
                straggler.send(SPILL_SQL)
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline and du_kb(tmp_dir) == 0:
                    time.sleep(0.05)
                tmp_samples.append(('spilling', i, du_kb(tmp_dir)))
            else:
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
            straggler.get_results(timeout=5) if straggler.alive() else None
            straggler.close()
            straggler = None
            if args.measure_tmp:
                tmp_samples.append(('after-kill', i, du_kb(tmp_dir)))

        # per-reset verifications
        st = pool.status(lane.name)
        if st['state'] != 'OPEN' or int(st['epoch']) != expected_epoch[lane.name] \
                or int(st['attached_old']) != 0 or st['reclaim_pending'] != 'f':
            fail('iteration %d: status after cycle: %r (expected epoch %d)'
                 % (i, st, expected_epoch[lane.name]))
        n = dsm_files(args.pgdata)
        if n != dsm_base:
            fail('iteration %d: DSM segment count %d != baseline %d' % (i, n, dsm_base))
        d = data_kb(args.pgdata)
        if d > data_base + 2048:
            fail('iteration %d: pgdata-minus-wal %dkB grew past baseline %dkB' % (i, d, data_base))
        try:
            dg = lane.conns[0].scalar(DIGEST_SQL)
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
                dg = fc.scalar(DIGEST_SQL)
                fc.close()
                if dg != digest_seed:
                    fail('iteration %d: digest on a fresh connection: %s' % (i, dg))
            except mp.PGError as e:
                fail('iteration %d: fresh connection with the current nonce refused: %s' % (i, e))
        if args.measure_shdepend:
            rows = ctl.scalar('SELECT count(*) FROM pg_shdepend WHERE dbid = %d' % lane.oid)
            shared = ctl.scalar('SELECT arena_bytes FROM memcow_lane_status(0)')
            shdep_samples.append((i, lane.name, int(rows), int(shared)))

        if i % args.progress_every == 0:
            print('iteration %d: %s epoch %d, dsm=%d, pgdata-minus-wal=%dkB, wal=%dkB, '
                  'reset %.0fms cycle %.0fms lease %.2fms%s'
                  % (i, lane.name, expected_epoch[lane.name], n, d,
                     wal_kb(args.pgdata),
                     t['reset_ms'], t['cycle_ms'], lat_lease[-1],
                     (' shdepend=%d shared=%dkB' % (shdep_samples[-1][2], shdep_samples[-1][3] // 1024))
                     if shdep_samples else ''))
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
        'reset_ms': {'p50': mp.percentile(lat_reset, 0.5), 'p99': mp.percentile(lat_reset, 0.99),
                     'max': max(lat_reset) if lat_reset else None},
        'cycle_ms': {'p50': mp.percentile(lat_cycle, 0.5), 'p99': mp.percentile(lat_cycle, 0.99),
                     'max': max(lat_cycle) if lat_cycle else None},
        'lease_first_query_ms': {'p50': mp.percentile(lat_lease, 0.5),
                                 'p99': mp.percentile(lat_lease, 0.99),
                                 'max': max(lat_lease) if lat_lease else None},
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

    if args.measure_tmp:
        peak = max((s[2] for s in tmp_samples), default=0)
        final = du_kb(tmp_dir)
        spilled = [s[2] for s in tmp_samples if s[0] == 'spilling']
        after = [s[2] for s in tmp_samples if s[0] == 'after-kill']
        print('pgsql_tmp: %d spilling stragglers killed; while spilling max=%dkB; after each kill max=%dkB; '
              'final=%dkB' % (len(spilled), max(spilled, default=0), max(after, default=0), final))
        summary['pgsql_tmp'] = {'kills': len(spilled), 'spilling_max_kb': max(spilled, default=0),
                                'after_kill_max_kb': max(after, default=0), 'final_kb': final}
        if final != 0 or max(after, default=0) != 0:
            fail('pgsql_tmp did not return to 0 after a killed straggler (orphaned temp files)')

    if args.measure_shdepend:
        first = shdep_samples[0] if shdep_samples else None
        last = shdep_samples[-1] if shdep_samples else None
        per_lane = {}
        for s in shdep_samples:
            per_lane.setdefault(s[1], []).append(s[2])
        print('pg_shdepend as a non-pinned role: rows for %s: first=%s last=%s; shared arena %s -> %s bytes'
              % (', '.join('%s %d->%d' % (k, v[0], v[-1]) for k, v in per_lane.items()),
                 first[2] if first else '?', last[2] if last else '?',
                 first[3] if first else '?', last[3] if last else '?'))
        summary['shdepend'] = {'per_lane': per_lane,
                               'shared_arena_first': first[3] if first else None,
                               'shared_arena_last': last[3] if last else None}
        # what the dangling rows do to role management
        try:
            ctl.exec('DROP ROLE memcow_soak_role')
            summary['shdepend']['drop_role'] = 'succeeded'
        except mp.PGError as e:
            summary['shdepend']['drop_role'] = str(e)
        print('DROP ROLE memcow_soak_role: %s' % summary['shdepend']['drop_role'])
        try:
            lc = mp.Conn(pq, pool.lane_conninfo(l0, l0.nonce))
            lc.exec('DROP OWNED BY memcow_soak_role')
            summary['shdepend']['drop_owned'] = 'succeeded'
            lc.close()
        except mp.PGError as e:
            summary['shdepend']['drop_owned'] = str(e)
        print('DROP OWNED BY memcow_soak_role (in %s): %s' % (l0.name, summary['shdepend']['drop_owned']))

    pool.close()
    ctl.close()
    if args.report:
        with open(args.report, 'w') as f:
            json.dump(summary, f, indent=1)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
