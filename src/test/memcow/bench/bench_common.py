#!/usr/bin/env python3
"""
bench_common.py --- what the plan §7.4 benchmark drivers share.

  * summarize(): p50/p90/p99/max/mean of a latency list, the same
    nearest-rank percentile as pool_soak.py so numbers are comparable.
  * WORKLOADS / run_workload(): the per-lease work a test does between its
    first query and its release.  'query' is nothing beyond the first
    parameterized query; 'light' is one small DML transaction; 'soak' is
    pool_soak.py's DDL+DML workload (two connections, one left in an open
    transaction for the drain to roll back).  A benchmark states which one
    it ran, because the cassert reclaim-poison walk scales with the overlay.
  * LeakProbe: the §7.4 "zero leakage" gate, sampled before and after a run:
    DSM segment files (dynamic_shared_memory_type=mmap), PGDATA-minus-WAL
    in one walk, in-flight AIO handles (pg_aios), pinned shared buffers
    (pg_buffercache), and the open-fd count of every long-lived server
    process (postmaster, checkpointer, background writer, walwriter, the
    IO workers) via lsof -- plus scan_log() for the cassert-only leak
    WARNINGs and any assert/crash.
  * A4: the plan's Appendix A.4 trigger list, so both drivers and the
    summary name the same five items the same way.

Portions Copyright (c) 2026, PostgreSQL Global Development Group
"""

import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'pool'))
import memcow_pool as mp  # noqa: E402

FIRST_QUERY = 'SELECT $1::int'


def percentile(values, p):
    return mp.percentile(values, p)


def summarize(values):
    if not values:
        return {'n': 0, 'p50': None, 'p90': None, 'p99': None, 'max': None, 'mean': None}
    return {'n': len(values),
            'p50': percentile(values, 0.5),
            'p90': percentile(values, 0.9),
            'p99': percentile(values, 0.99),
            'max': max(values),
            'mean': sum(values) / len(values)}


def fmt_ms(v):
    return '   -  ' if v is None else '%6.2f' % v


def fmt_row(name, s, unit='ms'):
    return '  %-22s n=%-7d p50=%s p90=%s p99=%s max=%s %s' % (
        name, s['n'], fmt_ms(s['p50']), fmt_ms(s['p90']), fmt_ms(s['p99']), fmt_ms(s['max']), unit)


# ---------------------------------------------------------------------------
# per-lease workloads
# ---------------------------------------------------------------------------

SOAK_WORKLOADS = [
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

LIGHT_WORKLOAD = [
    "BEGIN",
    "INSERT INTO public.events (event_id, account_id, kind, occurred_at) "
    "SELECT 100000 + g, 1 + g, 'bench', now() FROM generate_series(1, 20) g",
    "UPDATE public.accounts SET balance = balance + 1 WHERE account_id <= 10",
    "CREATE TABLE bench_t AS SELECT g FROM generate_series(1, 100) g",
    "COMMIT",
]

WORKLOAD_NAMES = ('query', 'light', 'soak')


def run_workload(w, name, i):
    """Run workload `name` on wrapper w for iteration i.  Statements go one
    per PQexec (VACUUM cannot run inside the implicit transaction of a
    multi-statement string)."""
    if name == 'query':
        return
    if name == 'light':
        for stmt in LIGHT_WORKLOAD:
            w.exec(stmt)
        return
    if name == 'soak':
        pairs = ((i, 0), (i + 2, 1)) if w.nconns > 1 else ((i, 0),)
        for k, cidx in pairs:
            block = SOAK_WORKLOADS[k % 4].format(i=k)
            for stmt in (x.strip() for x in block.split('\n')):
                if stmt:
                    w.exec(stmt, i=cidx)
        return
    raise ValueError('unknown workload %r' % name)


# ---------------------------------------------------------------------------
# leak probe
# ---------------------------------------------------------------------------

def du_kb(path, exclude=()):
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


def dsm_files(pgdata):
    d = os.path.join(pgdata, 'pg_dynshmem')
    try:
        return len([f for f in os.listdir(d) if f.startswith('mmap.')])
    except OSError:
        return -1


def fd_count(pid):
    """(open descriptors, [DSM segment files mapped], [fd:name]) of a process.

    Descriptors are the numeric entries of lsof's FD column (or /proc/PID/fd
    on Linux); lsof's txt/mem rows are mappings, not descriptors, and a
    memcow process maps every seed segment it reads read-only for good, so
    counting rows would report the seed being touched as a leak.  The
    mappings under pg_dynshmem are counted separately: an arena mapping
    that outlives its epoch is precisely the leak the reclaim's dsm_attach
    check exists to expose, and this counts it from outside the server."""
    procfd = '/proc/%d/fd' % pid
    nfd = -1
    if os.path.isdir(procfd):
        names = []
        try:
            for f in os.listdir(procfd):
                try:
                    names.append('%s:%s' % (f, os.readlink(os.path.join(procfd, f))))
                except OSError:
                    names.append(f)
            nfd = len(names)
        except OSError:
            pass
        maps = []
        try:
            for ln in open('/proc/%d/maps' % pid):
                if 'pg_dynshmem' in ln:
                    maps.append(os.path.basename(ln.split()[-1].replace(' (deleted)', '')))
        except OSError:
            pass
        return nfd, maps, names
    try:
        out = subprocess.run(['lsof', '-p', str(pid), '-n', '-P'], capture_output=True,
                             text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return -1, [], []
    nfd = 0
    maps = []
    names = []
    for ln in out.splitlines()[1:]:
        parts = ln.split()
        if len(parts) < 5:
            continue
        fd = parts[3]
        if fd[0].isdigit():
            nfd += 1
            names.append('%s:%s' % (fd, parts[-1]))
        if 'pg_dynshmem' in parts[-1]:
            maps.append(os.path.basename(parts[-1]))
    return nfd, maps, names


def rss_kb(pid):
    try:
        out = subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)], capture_output=True,
                             text=True, timeout=30).stdout.strip()
        return int(out) if out else -1
    except (OSError, ValueError, subprocess.SubprocessError):
        return -1


LOG_BAD = re.compile(r'TRAP: |PANIC:|was terminated by signal|leaked AIO handle|'
                     r'AIO handle was not submitted|buffer refcount leak|'
                     r'resource was not closed|open AIO batch at end|'
                     r'No space left on device|ENOSPC')


def scan_log(logfile):
    hits = []
    try:
        with open(logfile, errors='replace') as f:
            for n, line in enumerate(f, 1):
                if LOG_BAD.search(line):
                    hits.append('%d: %s' % (n, line.rstrip()))
    except OSError as e:
        hits.append('cannot read %s: %s' % (logfile, e))
    return hits


class LeakProbe:
    """Everything §7.4 calls leakage, sampled as a dict; diff() names what grew.
    Growth that is not a leak but worth seeing lands in LeakProbe.notes."""

    notes = []

    LONG_LIVED = ('checkpointer', 'background writer', 'walwriter', 'io worker')

    def __init__(self, pgdata, ctl):
        self.pgdata = pgdata
        self.ctl = ctl
        ctl.exec('CREATE EXTENSION IF NOT EXISTS pg_buffercache')
        self.pids = self._server_pids()

    def _server_pids(self):
        pids = {}
        try:
            with open(os.path.join(self.pgdata, 'postmaster.pid')) as f:
                pids['postmaster'] = int(f.readline().strip())
        except (OSError, ValueError):
            pass
        rows = self.ctl.query("SELECT pid, backend_type FROM pg_stat_activity "
                              "WHERE backend_type = ANY (%s) ORDER BY backend_type, pid"
                              % ("ARRAY['%s']" % "','".join(self.LONG_LIVED)))
        seen = {}
        for pid, bt in rows:
            seen[bt] = seen.get(bt, 0) + 1
            pids['%s#%d' % (bt, seen[bt])] = int(pid)
        pids['control backend'] = self.ctl.pid
        return pids

    def sample(self):
        s = {'dsm_segments': dsm_files(self.pgdata),
             'dsm_files': self._dsm_listing(),
             'arenas': self._arenas(),
             'pgdata_minus_wal_kb': du_kb(self.pgdata, exclude=('pg_wal',)),
             'wal_kb': du_kb(os.path.join(self.pgdata, 'pg_wal')),
             'aio_handles_in_flight': int(self.ctl.scalar('SELECT count(*) FROM pg_aios')),
             'pinned_buffers': int(self.ctl.scalar(
                 'SELECT coalesce(sum(pinning_backends), 0) FROM pg_buffercache')),
             'fds': {}, 'dsm_mappings': {}, 'fd_names': {}}
        for name, pid in self.pids.items():
            s['fds'][name], s['dsm_mappings'][name], s['fd_names'][name] = fd_count(pid)
        return s

    def _dsm_listing(self):
        d = os.path.join(self.pgdata, 'pg_dynshmem')
        out = {}
        try:
            for f in os.listdir(d):
                if f.startswith('mmap.'):
                    try:
                        out[f] = os.path.getsize(os.path.join(d, f))
                    except OSError:
                        out[f] = -1
        except OSError:
            pass
        return out

    def _arenas(self):
        """arena_bytes of every database that has an overlay slot: the lanes
        by name, the shared catalogs as 'shared', anything else by OID."""
        out = {}
        rows = self.ctl.query("SELECT d.datname, d.oid FROM pg_database d ORDER BY d.oid")
        try:
            out['shared'] = int(self.ctl.scalar('SELECT arena_bytes FROM memcow_lane_status(0)'))
        except mp.PGError:
            pass
        for name, oid in rows:
            try:
                v = self.ctl.scalar('SELECT arena_bytes FROM memcow_lane_status(%s)' % oid)
                if v is not None:
                    out[name] = int(v)
            except mp.PGError:
                pass
        return out

    @staticmethod
    def diff(before, after, pgdata_slack_kb=2048, warm=None, lanes=None):
        """The growth §7.4 forbids.

        DSM segments are compared between two moments at which every lane
        is fresh (just reset, one segment each): before the run and after
        its last cycle has finished.  The overlay of a database that is
        never reset -- the control database, the shared catalogs -- grows
        by copy-on-write as hint bits land on its catalog pages; that is
        bounded by those catalogs' size (plan Appendix C: excluded,
        benign) and can cross a segment boundary at any point of a run, so
        that growth is counted and explains as many new segments as it
        took doublings (DSA adds one segment per growth step).  A segment
        that no never-reset overlay's growth accounts for is a leak, and
        so is a DSM mapping to a segment file that no longer exists -- the
        leak the reclaim's dsm_attach() check exists to expose, counted
        here from outside.  The warm sample is informational.  PGDATA-
        minus-WAL gets the 2 MB slack pool_soak.py uses; everything else
        must be exactly flat."""
        import math
        bad = []
        extra = after['dsm_segments'] - before['dsm_segments']
        if extra != 0:
            explained = 0
            detail = []
            for name, v1 in after['arenas'].items():
                if lanes is not None and name in lanes:
                    continue
                v0 = before['arenas'].get(name, 0)
                if v1 > v0 > 0:
                    explained += int(math.ceil(math.log(v1 / float(v0), 2)))
                    detail.append('%s %dkB -> %dkB' % (name, v0 // 1024, v1 // 1024))
            if extra < 0 or extra > explained:
                bad.append('DSM segments %d -> %d, of which %d explained by never-reset overlay '
                           'growth (%s)' % (before['dsm_segments'], after['dsm_segments'], explained,
                                            ', '.join(detail) or 'none'))
        live = set(after['dsm_files'])
        for name, maps in after['dsm_mappings'].items():
            stale = [m for m in maps if m not in live]
            if stale:
                bad.append('%s maps %d DSM segment(s) whose file is gone: %s' % (name, len(stale), stale))
        if after['pgdata_minus_wal_kb'] > before['pgdata_minus_wal_kb'] + pgdata_slack_kb:
            bad.append('PGDATA-minus-WAL %dkB -> %dkB'
                       % (before['pgdata_minus_wal_kb'], after['pgdata_minus_wal_kb']))
        if after['aio_handles_in_flight'] != 0:
            bad.append('AIO handles in flight at the end: %d' % after['aio_handles_in_flight'])
        if after['pinned_buffers'] != 0:
            bad.append('pinned shared buffers at the end: %d' % after['pinned_buffers'])
        # Descriptors: a long-lived process's VFD cache fills as it first
        # touches things (the checkpointer keeps the WAL segment it last
        # wrote open, for one), so growth by a couple is the cache and
        # growth by more is a leak; either way the new names are printed,
        # so a reader sees WHAT was opened rather than a count.
        for name, n0 in before['fds'].items():
            n1 = after['fds'].get(name, -1)
            if n0 >= 0 and n1 > n0:
                new_names = sorted(set(after['fd_names'].get(name, [])) - set(before['fd_names'].get(name, [])))
                msg = 'fds of %s: %d -> %d, new: %s' % (name, n0, n1, new_names)
                if n1 - n0 > 2:
                    bad.append(msg)
                else:
                    LeakProbe.notes.append(msg)
        if bad:
            gone = sorted(set(before['dsm_files']) - set(after['dsm_files']))
            new = sorted(set(after['dsm_files']) - set(before['dsm_files']))
            bad.append('DSM files: %d before, %d after; new: %s; gone: %d; arenas before %s after %s'
                       % (len(before['dsm_files']), len(after['dsm_files']),
                          ', '.join('%s=%d' % (f, after['dsm_files'][f]) for f in new), len(gone),
                          before['arenas'], after['arenas']))
        return bad


# ---------------------------------------------------------------------------
# Appendix A.4
# ---------------------------------------------------------------------------

A4 = [
    ('buffertag_generation', 'BufferTag generation',
     'ready-queue exhaustion with the DropDatabaseBuffers header scan the dominant reset term'),
    ('test_vfs_wal_bypass', 'Test VFS / WAL bypass',
     'RAM-dir WAL/temp writes measurably move lease p99, or ENOSPC PANICs'),
    ('per_lane_barrier', 'Per-lane barrier alternative',
     "the global SMGRRELEASE barrier's absorption latency under load dominates reset p99"),
    ('selective_cache_invalidation', 'Selective cache invalidation',
     'post-reset warmup (adopt + warmup) dominates reset cost'),
    ('server_side_reset_workers', 'Server-side background reset workers',
     'client-driven reset bottlenecks on pool-thread round trips at target throughput'),
]


def arena_growth(before, after, lanes):
    """The never-reset overlays' sizes, before -> after, for the report."""
    out = {}
    for name, v1 in after['arenas'].items():
        if name in lanes:
            continue
        v0 = before['arenas'].get(name, 0)
        if v0 or v1:
            out[name] = (v0, v1)
    return out


def write_report(path, obj):
    if path:
        with open(path, 'w') as f:
            json.dump(obj, f, indent=1, default=str)


def stamp():
    return time.strftime('%Y-%m-%d %H:%M:%S')
