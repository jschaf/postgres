#!/usr/bin/env python3
"""
memcow_pool.py --- the minimal lane pool (plan §3), as a test-side library.

Not a product.  This is the client half of the reset protocol, written so
that the §7.2 soak, the §7.3 race cases and the §7.4 measurements can drive
lanes the way a test process would, and so that every rule the plan puts on
the pool is in one place where a test can see it being obeyed:

  * N lanes, statically partitioned per test process: a pool is constructed
    with an explicit lane list and never discovers lanes on its own, so two
    processes with disjoint lists share no pool state (plan §1).
  * M connections per lane plus ONE control connection, on which every
    memcow_lane_* call runs, never in the lane concerned (plan §4).
  * lease() hands out a Wrapper stamped {lane, epoch, nonce}; release()
    invalidates it IN PROCESS first (fence 1 of 3): every later use raises
    StaleWrapperError, deterministically, before anything is sent (plan §3.6).
  * drain (plan §3.7): ROLLBACK any open transaction, DISCARD ALL, then wait
    for ReadyForQuery 'I' on every lane connection -- libpq reports the RFQ
    status byte through PQtransactionStatus(), and the pool asserts PQTRANS_IDLE.
  * memcow_lane_reset(D) on the control connection (plan §3.8, §4); then
    memcow_backend_reset() on every lane connection, schema-qualified because
    DISCARD ALL reset search_path (plan §3.9); then the warmup query; then
    memcow_lane_open(D, arm => true), whose nonce is stamped into the next
    wrapper and into every connection string the pool hands out (plan §3.10).
  * A REFUSED reset leaves the lane CLOSED (plan Appendix B(i)); the pool
    re-drains and retries a bounded number of times, then retires the lane
    with memcow_lane_retire(D).  It never publishes anything itself.
  * retire-after-K-epochs (plan A.3, Appendix C): a lane's backends are
    replaced with fresh connections after serving K epochs, because PL
    globals, the session seed and the memory footprint are not reset by
    DISCARD ALL and never will be.

The libpq binding is ctypes over the tree's own libpq, so the pool has no
dependency the build does not already provide, and it sees exactly the
protocol state a real client would.  Python 3.9 (macOS's /usr/bin/python3).
Used by pool_soak.py (the §7.2 soak), bench.py and busy_driver.py (§7.4).

Portions Copyright (c) 2026, PostgreSQL Global Development Group
"""

import collections
import ctypes
import os
import platform
import queue
import re
import threading
import time

# ---------------------------------------------------------------------------
# libpq
# ---------------------------------------------------------------------------

CONNECTION_OK = 0

PGRES_EMPTY_QUERY = 0
PGRES_COMMAND_OK = 1
PGRES_TUPLES_OK = 2
PGRES_COPY_OUT = 3
PGRES_COPY_IN = 4
PGRES_BAD_RESPONSE = 5
PGRES_NONFATAL_ERROR = 6
PGRES_FATAL_ERROR = 7

PQTRANS_IDLE = 0
PQTRANS_ACTIVE = 1
PQTRANS_INTRANS = 2
PQTRANS_INERROR = 3
PQTRANS_UNKNOWN = 4

PG_DIAG_SQLSTATE = ord('C')
PG_DIAG_MESSAGE_PRIMARY = ord('M')
PG_DIAG_MESSAGE_DETAIL = ord('D')


def libpq_path(libdir):
    """The tree's libpq, by explicit path: /usr/bin/python3 is a system
    binary and macOS strips DYLD_LIBRARY_PATH from it."""
    if platform.system() == 'Darwin':
        cands = ['libpq.5.dylib', 'libpq.dylib']
    else:
        cands = ['libpq.so.5', 'libpq.so']
    for c in cands:
        p = os.path.join(libdir, c)
        if os.path.exists(p):
            return p
    raise RuntimeError('no libpq under %s' % libdir)


class LibPQ:
    def __init__(self, path):
        self.path = path
        lib = ctypes.CDLL(path)
        self.lib = lib
        P = ctypes.c_void_p
        S = ctypes.c_char_p
        I = ctypes.c_int

        def f(name, restype, *argtypes):
            fn = getattr(lib, name)
            fn.restype = restype
            fn.argtypes = list(argtypes)
            setattr(self, name, fn)

        f('PQconnectdb', P, S)
        f('PQstatus', I, P)
        f('PQerrorMessage', S, P)
        f('PQfinish', None, P)
        f('PQexec', P, P, S)
        f('PQexecParams', P, P, S, I, P, P, P, P, I)
        f('PQresultStatus', I, P)
        f('PQresultErrorMessage', S, P)
        f('PQresultErrorField', S, P, I)
        f('PQntuples', I, P)
        f('PQnfields', I, P)
        f('PQgetvalue', S, P, I, I)
        f('PQgetisnull', I, P, I, I)
        f('PQclear', None, P)
        f('PQtransactionStatus', I, P)
        f('PQbackendPID', I, P)
        f('PQsendQuery', I, P, S)
        f('PQgetResult', P, P)
        f('PQconsumeInput', I, P)
        f('PQisBusy', I, P)
        f('PQcancelCreate', P, P)
        f('PQcancelBlocking', I, P)
        f('PQcancelErrorMessage', S, P)
        f('PQcancelFinish', None, P)


class PGError(Exception):
    def __init__(self, message, sqlstate=None, detail=None):
        Exception.__init__(self, message)
        self.message = message
        self.sqlstate = sqlstate
        self.detail = detail

    def __str__(self):
        return self.message.strip()


def _s(b):
    return b.decode('utf-8', 'replace') if b is not None else None


class Result:
    __slots__ = ('status', 'rows', 'error', 'sqlstate', 'detail')

    def __init__(self, status, rows, error=None, sqlstate=None, detail=None):
        self.status = status
        self.rows = rows
        self.error = error
        self.sqlstate = sqlstate
        self.detail = detail

    def scalar(self):
        return self.rows[0][0] if self.rows else None


class Conn:
    """One libpq connection.  Every method is synchronous except send() /
    get_results(), which the fence exercises use to leave a command running."""

    def __init__(self, pq, conninfo):
        self.pq = pq
        self.conninfo = conninfo
        self.h = pq.PQconnectdb(conninfo.encode())
        if not self.h or pq.PQstatus(self.h) != CONNECTION_OK:
            msg = _s(pq.PQerrorMessage(self.h)) if self.h else 'PQconnectdb returned NULL'
            if self.h:
                pq.PQfinish(self.h)
            self.h = None
            raise PGError(msg, sqlstate=_sqlstate_from_message(msg))
        self.pid = pq.PQbackendPID(self.h)

    def _result(self, res):
        pq = self.pq
        if not res:
            msg = _s(pq.PQerrorMessage(self.h)) or 'no result'
            raise PGError(msg)
        try:
            st = pq.PQresultStatus(res)
            if st in (PGRES_TUPLES_OK, PGRES_COMMAND_OK, PGRES_EMPTY_QUERY):
                rows = []
                if st == PGRES_TUPLES_OK:
                    nt = pq.PQntuples(res)
                    nf = pq.PQnfields(res)
                    for i in range(nt):
                        row = []
                        for j in range(nf):
                            if pq.PQgetisnull(res, i, j):
                                row.append(None)
                            else:
                                row.append(_s(pq.PQgetvalue(res, i, j)))
                        rows.append(tuple(row))
                return Result(st, rows)
            msg = _s(pq.PQresultErrorMessage(res)) or ''
            sqlstate = _s(pq.PQresultErrorField(res, PG_DIAG_SQLSTATE))
            detail = _s(pq.PQresultErrorField(res, PG_DIAG_MESSAGE_DETAIL))
            return Result(st, [], error=msg, sqlstate=sqlstate, detail=detail)
        finally:
            pq.PQclear(res)

    def exec(self, sql):
        """PQexec: returns after ReadyForQuery.  Raises PGError on an error
        result (the last result of a multi-statement string)."""
        r = self._result(self.pq.PQexec(self.h, sql.encode()))
        if r.error is not None:
            raise PGError(r.error, r.sqlstate, r.detail)
        return r

    def exec_params(self, sql, params):
        """PQexecParams with text parameters: the 'first parameterized
        query' of plan §3.4."""
        n = len(params)
        arr = (ctypes.c_char_p * n)(*[p.encode() if p is not None else None for p in params])
        res = self.pq.PQexecParams(self.h, sql.encode(), n, None,
                                   ctypes.cast(arr, ctypes.c_void_p), None, None, 0)
        r = self._result(res)
        if r.error is not None:
            raise PGError(r.error, r.sqlstate, r.detail)
        return r

    def query(self, sql):
        return self.exec(sql).rows

    def scalar(self, sql):
        return self.exec(sql).scalar()

    def send(self, sql):
        if not self.pq.PQsendQuery(self.h, sql.encode()):
            raise PGError(_s(self.pq.PQerrorMessage(self.h)))

    def is_busy(self):
        self.pq.PQconsumeInput(self.h)
        return bool(self.pq.PQisBusy(self.h))

    def get_results(self, timeout=60.0):
        """Collect every result of a send(), waiting up to timeout seconds.
        Returns the list of Result; never raises on an error result."""
        out = []
        deadline = time.monotonic() + timeout
        while True:
            while self.is_busy():
                if time.monotonic() > deadline:
                    raise PGError('timeout waiting for results of: %s' % self.conninfo)
                time.sleep(0.005)
            res = self.pq.PQgetResult(self.h)
            if not res:
                break
            out.append(self._result(res))
        return out

    def txn_status(self):
        return self.pq.PQtransactionStatus(self.h)

    def cancel(self):
        cc = self.pq.PQcancelCreate(self.h)
        try:
            if not self.pq.PQcancelBlocking(cc):
                raise PGError(_s(self.pq.PQcancelErrorMessage(cc)))
        finally:
            self.pq.PQcancelFinish(cc)

    def alive(self):
        return self.h is not None and self.pq.PQstatus(self.h) == CONNECTION_OK

    def close(self):
        if self.h:
            self.pq.PQfinish(self.h)
            self.h = None


def _sqlstate_from_message(msg):
    m = re.search(r'\b([0-9A-Z]{5})\b:', msg or '')
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# the pool
# ---------------------------------------------------------------------------

class StaleWrapperError(Exception):
    """The wrapper was released; fence 1 of 3 (plan §5 I2 (a))."""


class LaneRetired(Exception):
    pass


class LaneRefused(Exception):
    pass


class PoolError(Exception):
    pass


class Wrapper:
    """What a test holds while it has a lane.  Every method checks the
    wrapper is still valid BEFORE touching a socket: after release() the
    failure is in-process and deterministic, never a server round trip."""

    def __init__(self, pool, lane):
        self._pool = pool
        self._lane = lane
        self.lane_name = lane.name
        self.dboid = lane.oid
        self.epoch = lane.epoch
        self.nonce = lane.nonce
        self._valid = True

    def _check(self):
        if not self._valid:
            raise StaleWrapperError('wrapper for lane %s epoch %d was released'
                                    % (self.lane_name, self.epoch))

    def send(self, sql, i=0):
        self._check()
        return self._lane.conns[i].send(sql)

    def get_results(self, timeout=30, i=0):
        self._check()
        return self._lane.conns[i].get_results(timeout=timeout)

    @property
    def nconns(self):
        self._check()
        return len(self._lane.conns)

    def exec(self, sql, i=0):
        self._check()
        return self._lane.conns[i].exec(sql)

    def exec_params(self, sql, params, i=0):
        self._check()
        return self._lane.conns[i].exec_params(sql, params)

    def invalidate(self):
        self._valid = False


class Lane:
    def __init__(self, name, oid):
        self.name = name
        self.oid = oid
        self.epoch = None
        self.nonce = 0
        self.conns = []
        self.state = 'NEW'          # NEW READY LEASED CLOSED RETIRED
        self.epochs_served = 0      # by the current set of backends
        self.recycles = 0
        self.resets = 0
        self.refusals = 0
        self.ready_at = 0.0
        self.released_at = 0.0


class LanePool:
    """
    Two ways to run the reset cycle, chosen by `resetters`:

      resetters=0   release() runs the whole cycle INLINE -- drain, reset,
                    adopt, warm up, open -- and returns its timings.  The
                    caller pays for the reset; lease() never waits.  This is
                    plan §3 read literally and what the §7.2/§7.3 soaks use.

      resetters=R   release() hands the lane to one of R resetter THREADS,
                    each with a control connection of its own, and returns
                    at once; a lane re-enters the ready queue when its cycle
                    is done.  lease() blocks on that queue.  This is what
                    "ready capacity" (plan §7.4) means operationally: a
                    lease waits only if every lane is mid-reset, and the
                    pool records every such wait (last_lease_wait_ms,
                    last_ready_depth, lease_waits) so a benchmark can tell
                    a slow query from a starved queue.

    libpq calls go through ctypes, which drops the GIL for the duration of
    the C call, so a resetter blocked in PQexec() does not stall the leasing
    thread; a driver that measures sub-millisecond latencies should still
    lower sys.setswitchinterval(), because the default 5 ms is the worst
    case a thread waits for the GIL after its C call returns.

    Per-cycle records (the dict release() returns in inline mode, or what
    on_cycle(record) receives from a resetter) carry the client-side terms
    in ms -- drain, reset (the round trip), adopt, warmup_open, recycle,
    cycle -- and, with capture_timings, the server's own attribution of the
    reset (memcow_lane_reset_timings: fence, prepare, publish, barrier,
    sweep_buffers, sweep_files, reclaim_wait, poison, destroy, all us) and
    the adopt's server time (adopt_server_us), fetched AFTER the cycle so
    that the fetch is not in it.

    resetter_delay_ms is a NEGATIVE-CONTROL knob for the §7.4 harness: a
    pure client-side sleep at the head of every cycle, which inflates one
    cost term (the cycle) and nothing else.  A harness that cannot attribute
    a lease p99 miss to the starved queue under it is not measuring.
    """

    def __init__(self, pq, conninfo, lanes, conns_per_lane=2,
                 control_db='memcow_control', retire_after_epochs=50,
                 reset_timeout_ms=5000, reset_retries=3, log=None,
                 resetters=0, capture_timings=False,
                 resetter_delay_ms=0, on_cycle=None):
        self.pq = pq
        self.base_conninfo = conninfo
        self.lane_names = list(lanes)
        self.M = conns_per_lane
        self.control_db = control_db
        self.retire_after = retire_after_epochs
        self.reset_timeout_ms = reset_timeout_ms
        self.reset_retries = reset_retries
        self.log = log or (lambda *a: None)
        self.ctl = None
        self.lanes = collections.OrderedDict()
        self.last_cycle = None
        # asynchronous resetting
        self.nresetters = int(resetters)
        self.lease_timeout = 60.0
        self.capture_timings = capture_timings
        self.resetter_delay_ms = resetter_delay_ms
        self.on_cycle = on_cycle
        self._threads = []
        self._reset_q = None
        self.failures = []          # (lane name, exception text) from resetters
        self.last_lease_wait_ms = 0.0
        self.last_ready_depth = 0
        self.last_ready_age_ms = 0.0
        self.lease_waits = 0        # leases that found the ready queue empty
        self.leases = 0
        self.ready = queue.Queue()

    # --- connection strings ------------------------------------------------

    def lane_conninfo(self, lane, nonce):
        opts = "options='-c memcow.lane_nonce=%d'" % nonce if nonce else ''
        return '%s dbname=%s %s' % (self.base_conninfo, lane.name, opts)

    def control_conninfo(self):
        return '%s dbname=%s' % (self.base_conninfo, self.control_db)

    # --- lifecycle ----------------------------------------------------------

    def open(self):
        self.ctl = Conn(self.pq, self.control_conninfo())
        self.ctl.exec('CREATE EXTENSION IF NOT EXISTS memcow')
        for name in self.lane_names:
            oid = self.ctl.scalar("SELECT oid FROM pg_database WHERE datname = '%s'" % name)
            if oid is None:
                raise PoolError('no such lane database: %s' % name)
            lane = Lane(name, int(oid))
            self.lanes[name] = lane
            self._open_lane(lane)
            self._make_ready(lane)
        if self.nresetters > 0:
            self._reset_q = queue.Queue()
            for i in range(self.nresetters):
                th = threading.Thread(target=self._resetter_main, args=(i,),
                                      name='memcow-resetter-%d' % i, daemon=True)
                th.start()
                self._threads.append(th)

    def _make_ready(self, lane):
        lane.state = 'READY'
        lane.ready_at = time.monotonic()
        self.ready.put(lane)

    def _open_lane(self, lane):
        """Plan §3.3: open M connections, register them, then bring the lane
        to a fresh epoch, so every lease starts from a known state."""
        lane.nonce = int(self.ctl.scalar('SELECT memcow_lane_open(%d, true)' % lane.oid))
        lane.epoch = int(self._status(lane)['epoch'])
        self._connect_backends(lane, self.ctl)
        self._drain(lane)
        self._reset_cycle(lane, self.ctl)

    def _connect_backends(self, lane, ctl):
        lane.conns = []
        for i in range(self.M):
            c = Conn(self.pq, self.lane_conninfo(lane, lane.nonce))
            lane.conns.append(c)
            ctl.exec('SELECT memcow_lane_register(%d, %d)' % (lane.oid, c.pid))
        lane.epochs_served = 0

    def _disconnect_backends(self, lane, ctl):
        for c in lane.conns:
            try:
                ctl.exec('SELECT memcow_lane_unregister(%d, %d)' % (lane.oid, c.pid))
            except PGError:
                pass
            c.close()
        lane.conns = []

    def close(self):
        if self._reset_q is not None:
            for th in self._threads:
                self._reset_q.put(None)
            for th in self._threads:
                th.join(timeout=120)
            self._threads = []
        for lane in self.lanes.values():
            if lane.state != 'RETIRED':
                self._disconnect_backends(lane, self.ctl)
        if self.ctl:
            self.ctl.close()
            self.ctl = None

    # --- lease / release ------------------------------------------------------

    def lease(self):
        self.leases += 1
        blocking = self.nresetters > 0
        t0 = time.monotonic()
        depth = self.ready.qsize()
        try:
            lane = self.ready.get(block=blocking, timeout=self.lease_timeout)
        except queue.Empty:
            if not blocking:
                raise PoolError('no ready lane')
            raise PoolError('no lane became ready within %.0fs (%d resetter failure(s): %s)'
                            % (self.lease_timeout, len(self.failures), self.failures[:3]))
        now = time.monotonic()
        self.last_lease_wait_ms = (now - t0) * 1000.0 if blocking else 0.0
        self.last_ready_depth = depth
        self.last_ready_age_ms = (now - lane.ready_at) * 1000.0
        if blocking and depth == 0:
            self.lease_waits += 1
        lane.state = 'LEASED'
        return Wrapper(self, lane)

    def release(self, w):
        """Plan §3.6-§3.10.  Inline mode: runs the cycle and returns its
        timings (ms).  Resetter mode: queues the lane and returns None."""
        w.invalidate()                      # fence 1, in process, first
        lane = w._lane
        lane.state = 'RESETTING'
        lane.released_at = time.monotonic()
        if self.nresetters > 0:
            self._reset_q.put(lane)
            return None
        timings = self._run_cycle(lane, self.ctl)
        self._make_ready(lane)
        self.last_cycle = timings
        return timings

    def _run_cycle(self, lane, ctl):
        """drain + reset cycle on the given control connection; returns the
        record.  Raises LaneRetired / PoolError / PGError."""
        t0 = time.monotonic()
        if self.resetter_delay_ms:
            time.sleep(self.resetter_delay_ms / 1000.0)
        t_drain = time.monotonic()
        self._drain(lane)
        t1 = time.monotonic()
        timings = self._reset_cycle(lane, ctl)
        t2 = time.monotonic()
        timings['drain_ms'] = (t1 - t_drain) * 1000.0
        timings['cycle_ms'] = (t2 - t0) * 1000.0
        timings['lane'] = lane.name
        timings['epoch'] = lane.epoch
        if self.capture_timings:
            timings['server'] = self._server_timings(lane, ctl)
            try:
                v = lane.conns[0].scalar("SELECT value FROM public.memcow_backend_counters() "
                                         "WHERE name = 'adopt_last_us'")
                timings['adopt_server_us'] = int(v) if v is not None else None
            except PGError:
                timings['adopt_server_us'] = None
        return timings

    def _resetter_main(self, idx):
        ctl = Conn(self.pq, self.control_conninfo())
        try:
            while True:
                lane = self._reset_q.get()
                if lane is None:
                    break
                try:
                    rec = self._run_cycle(lane, ctl)
                except Exception as e:      # noqa: BLE001 -- reported, not hidden
                    self.failures.append((lane.name, '%s: %s' % (type(e).__name__, e)))
                    self.log('resetter %d: lane %s failed: %s' % (idx, lane.name, e))
                    if lane.state != 'RETIRED':
                        try:
                            self.retire(lane, reason=str(e), ctl=ctl)
                        except Exception:   # noqa: BLE001
                            lane.state = 'RETIRED'
                    continue
                rec['resetter'] = idx
                self.last_cycle = rec
                if self.on_cycle is not None:
                    self.on_cycle(rec)
                self._make_ready(lane)
        finally:
            ctl.close()

    # --- the protocol -------------------------------------------------------------

    def _drain(self, lane):
        """Plan §3.7.  A connection a test left mid-command is cancelled and
        its results collected first; then ROLLBACK if in a transaction,
        DISCARD ALL, and the ReadyForQuery status must be 'I'."""
        for c in lane.conns:
            if c.txn_status() == PQTRANS_ACTIVE:
                try:
                    c.cancel()
                except PGError:
                    pass
                c.get_results(timeout=60.0)
            st = c.txn_status()
            if st in (PQTRANS_INTRANS, PQTRANS_INERROR):
                c.exec('ROLLBACK')
            c.exec('DISCARD ALL')
            if c.txn_status() != PQTRANS_IDLE:
                raise PoolError('lane %s pid %d not idle after drain (status %d)'
                                % (lane.name, c.pid, c.txn_status()))

    STATUS_KEYS = ('state', 'epoch', 'nonce', 'registered', 'arena_bytes', 'attached',
                   'attached_old', 'reclaim_pending', 'writes_discarded', 'poisoned_pages',
                   'arena_limit')

    def _status(self, lane, ctl=None):
        r = (ctl or self.ctl).exec(
            'SELECT state, epoch, nonce, registered, arena_bytes, attached, '
            'attached_old, reclaim_pending, writes_discarded, poisoned_pages, '
            'arena_limit FROM memcow_lane_status(%d)' % lane.oid)
        return dict(zip(self.STATUS_KEYS, r.rows[0]))

    def status(self, name):
        return self._status(self.lanes[name])

    TIMING_KEYS = ('epoch', 'total_us', 'fence_us', 'prepare_us', 'publish_us', 'barrier_us',
                   'sweep_buffers_us', 'sweep_files_us', 'reclaim_wait_us', 'poison_us',
                   'destroy_us', 'fence_polls', 'reclaim_polls', 'stragglers', 'poisoned_pages')

    def _server_timings(self, lane, ctl=None):
        """memcow_lane_reset_timings(D): the server's attribution of the
        lane's last completed reset, as a dict of ints (us / counts)."""
        r = (ctl or self.ctl).exec('SELECT %s FROM memcow_lane_reset_timings(%d)'
                                   % (', '.join(self.TIMING_KEYS), lane.oid))
        row = r.rows[0]
        if row[0] is None:
            return None
        return dict((k, int(v)) for k, v in zip(self.TIMING_KEYS, row))

    def server_timings(self, name):
        return self._server_timings(self.lanes[name])

    def reset_lane_raw(self, lane, timeout_ms=None, ctl=None):
        """memcow_lane_reset(D) alone, for tests that want to see it refused.
        Returns the new epoch or raises LaneRefused with the server's text."""
        try:
            r = (ctl or self.ctl).exec('SELECT memcow_lane_reset(%d, %d)'
                                       % (lane.oid, timeout_ms or self.reset_timeout_ms))
        except PGError as e:
            lane.refusals += 1
            raise LaneRefused(str(e))
        lane.resets += 1
        return int(r.scalar())

    def _reset_cycle(self, lane, ctl):
        timings = {}
        attempt = 0
        while True:
            attempt += 1
            t0 = time.monotonic()
            try:
                new_epoch = self.reset_lane_raw(lane, ctl=ctl)
                break
            except LaneRefused as e:
                self.log('lane %s: reset refused (attempt %d): %s' % (lane.name, attempt, e))
                if attempt > self.reset_retries:
                    self.retire(lane, reason=str(e), ctl=ctl)
                    raise LaneRetired('lane %s retired after %d refused resets: %s'
                                      % (lane.name, attempt, e))
                # a refused reset leaves the lane CLOSED; re-drain and retry
                time.sleep(0.05 * attempt)
                self._drain(lane)
        timings['reset_ms'] = (time.monotonic() - t0) * 1000.0
        timings['attempts'] = attempt

        st = self._status(lane, ctl)
        if st['state'] != 'RESETTING' or int(st['epoch']) != new_epoch or \
                int(st['attached_old']) != 0 or st['reclaim_pending'] != 'f':
            raise PoolError('lane %s: unexpected status after reset: %r' % (lane.name, st))
        timings['status_ms'] = (time.monotonic() - t0) * 1000.0 - timings['reset_ms']

        # adopt (plan §3.9), schema-qualified: DISCARD ALL reset search_path
        t1 = time.monotonic()
        for c in lane.conns:
            e = int(c.scalar('SELECT public.memcow_backend_reset()'))
            if e != new_epoch:
                raise PoolError('lane %s pid %d adopted epoch %d, expected %d'
                                % (lane.name, c.pid, e, new_epoch))
        timings['adopt_ms'] = (time.monotonic() - t1) * 1000.0
        lane.epoch = new_epoch
        lane.epochs_served += 1

        # warmup (plan §3.10), then OPEN armed; the nonce goes into the next wrapper
        t2 = time.monotonic()
        self._warmup(lane)
        t3 = time.monotonic()
        lane.nonce = int(ctl.scalar('SELECT memcow_lane_open(%d, true)' % lane.oid))
        timings['warmup_ms'] = (t3 - t2) * 1000.0
        timings['open_ms'] = (time.monotonic() - t3) * 1000.0
        timings['warmup_open_ms'] = timings['warmup_ms'] + timings['open_ms']

        # retire-after-K-epochs: fresh backends, admitted with the new nonce
        timings['recycled'] = False
        if self.retire_after and lane.epochs_served >= self.retire_after:
            t4 = time.monotonic()
            self._disconnect_backends(lane, ctl)
            self._connect_backends(lane, ctl)
            self._warmup(lane)
            lane.recycles += 1
            timings['recycle_ms'] = (time.monotonic() - t4) * 1000.0
            timings['recycled'] = True
        return timings

    def _warmup(self, lane):
        for c in lane.conns:
            # quiet the per-workload NOTICE stream (DROP ... CASCADE etc.);
            # DISCARD ALL in the next drain resets it, so it is re-set here
            # every cycle, after adopt, before the lane is handed back.
            c.exec('SET client_min_messages = warning')
            c.exec('SELECT 1')

    def retire(self, lane, reason='', ctl=None):
        self.log('lane %s: retiring (%s)' % (lane.name, reason))
        ctl = ctl or self.ctl
        try:
            ctl.exec('SELECT memcow_lane_retire(%d)' % lane.oid)
        finally:
            self._disconnect_backends(lane, ctl)
            lane.state = 'RETIRED'

# ---------------------------------------------------------------------------
# small helpers for drivers
# ---------------------------------------------------------------------------

def percentile(values, p):
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round((len(s) - 1) * p))))
    return s[k]
