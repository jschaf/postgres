# shellcheck shell=bash
# common.sh --- shared helpers for the memcow test harness
#
# Sourced, never executed.  Every function is prefixed mc_.
#
# The harness drives an *already built* PostgreSQL.  It never builds, and it
# never touches the core source tree.  Everything it needs is derived from a
# meson build directory.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------

MC_PROG=${MC_PROG:-$(basename -- "${BASH_SOURCE[1]:-harness}")}

mc_log()  { printf '[%s] %s\n' "$MC_PROG" "$*" >&2; }
mc_warn() { printf '[%s] WARNING: %s\n' "$MC_PROG" "$*" >&2; }
mc_die()  { printf '[%s] ERROR: %s\n' "$MC_PROG" "$*" >&2; exit 2; }

mc_banner()
{
	local line
	printf '\n'
	printf '========================================================================\n'
	for line in "$@"; do
		printf '%s\n' "$line"
	done
	printf '========================================================================\n\n'
}

# ---------------------------------------------------------------------------
# build resolution
# ---------------------------------------------------------------------------

# mc_default_build_dir --- $MEMCOW_BUILD_DIR, else build-memcow/ or build/
# next to the source root that owns this harness.
mc_default_build_dir()
{
	local here root candidate

	if [ -n "${MEMCOW_BUILD_DIR:-}" ]; then
		printf '%s\n' "$MEMCOW_BUILD_DIR"
		return 0
	fi
	here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
	root=$(cd -- "$here/../../../.." && pwd)
	for candidate in "$root/build-memcow" "$root/build"; do
		if [ -e "$candidate/meson-info/meson-info.json" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

# mc_resolve_build BUILD_DIR
#
# Sets:
#   MC_BUILD_DIR   the meson build directory
#   MC_SRC_DIR     the source directory that build was configured from
#   MC_BINDIR      directory holding postgres/initdb/pg_ctl/psql (tmp_install)
#   MC_LIBDIR      shared library dir matching MC_BINDIR
#   MC_PG_REGRESS  the pg_regress binary
#   MC_REGRESS_SRC source dir holding sql/, expected/, parallel_schedule
#   MC_DLPATH      directory holding regress.so/.dylib (pg_regress --dlpath)
#   MC_BUILD_CASSERT yes/no
#
# MC_REGRESS_SRC is the source tree the *build* came from, not the tree this
# script lives in: regression inputs and server binaries must be from the
# same commit or the diffs are meaningless.
mc_resolve_build()
{
	MC_BUILD_DIR=$1

	[ -n "$MC_BUILD_DIR" ] || mc_die "no build directory; pass --build-dir or set MEMCOW_BUILD_DIR"
	[ -e "$MC_BUILD_DIR/meson-info/meson-info.json" ] ||
		mc_die "not a meson build directory: $MC_BUILD_DIR"
	MC_BUILD_DIR=$(cd -- "$MC_BUILD_DIR" && pwd)

	local info
	info=$(python3 - "$MC_BUILD_DIR" <<'PY'
import json, sys, os
bd = sys.argv[1]
with open(os.path.join(bd, 'meson-info', 'meson-info.json')) as f:
    mi = json.load(f)
prefix = None
libdir = 'lib'
with open(os.path.join(bd, 'meson-info', 'intro-buildoptions.json')) as f:
    for o in json.load(f):
        if o['name'] == 'prefix':
            prefix = o['value']
        elif o['name'] == 'libdir':
            # 'lib' on macOS, 'lib/<multiarch>' on Debian-family Linux
            libdir = o['value']
        elif o['name'] == 'cassert':
            print('MC_BUILD_CASSERT=%s' % ('yes' if o['value'] else 'no'))
print('MC_SRC_DIR=%s' % mi['directories']['source'])
print('MC_PREFIX=%s' % prefix)
print('MC_LIBDIR_REL=%s' % libdir)
PY
	) || mc_die "cannot read meson introspection data from $MC_BUILD_DIR"
	eval "$info"

	MC_BINDIR=$MC_BUILD_DIR/tmp_install$MC_PREFIX/bin
	MC_LIBDIR=$MC_BUILD_DIR/tmp_install$MC_PREFIX/$MC_LIBDIR_REL
	MC_PG_REGRESS=$MC_BUILD_DIR/src/test/regress/pg_regress
	# Used by scripts sourcing common.sh.
	# shellcheck disable=SC2034
	MC_REGRESS_SRC=$MC_SRC_DIR/src/test/regress
	# Used by scripts sourcing common.sh.
	# shellcheck disable=SC2034
	MC_DLPATH=$MC_BUILD_DIR/src/test/regress

	[ -x "$MC_BINDIR/postgres" ] ||
		mc_die "no postgres binary at $MC_BINDIR/postgres
  (run: meson test -C $MC_BUILD_DIR --suite setup   to populate tmp_install)"
	[ -x "$MC_BINDIR/pg_ctl" ] || mc_die "no pg_ctl at $MC_BINDIR/pg_ctl"
	[ -x "$MC_BINDIR/psql" ]   || mc_die "no psql at $MC_BINDIR/psql"
	[ -x "$MC_PG_REGRESS" ]    || mc_die "no pg_regress at $MC_PG_REGRESS"

	if [ "${MC_BUILD_CASSERT:-no}" != yes ]; then
		mc_warn "build $MC_BUILD_DIR has cassert=false; the pin-leak checks are compiled out"
	fi

	# The tmp_install binaries were linked against an install prefix that does
	# not exist; point the dynamic loader at the staged libdir.
	case "$(uname -s)" in
		Darwin) export DYLD_LIBRARY_PATH="$MC_LIBDIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" ;;
		*)      export LD_LIBRARY_PATH="$MC_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
	esac
}

# ---------------------------------------------------------------------------
# ports and sockets
# ---------------------------------------------------------------------------

mc_free_port()
{
	python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
}

# Unix socket paths are capped at ~104 bytes on macOS, so the socket directory
# has to be short.  Override the root with MEMCOW_SOCKDIR_ROOT.
mc_make_sockdir()
{
	mktemp -d "${MEMCOW_SOCKDIR_ROOT:-/tmp}/pgmcw.XXXXXX"
}

# ---------------------------------------------------------------------------
# server lifecycle
# ---------------------------------------------------------------------------

# mc_initdb PGDATA
mc_initdb()
{
	local pgdata=$1
	mc_log "initdb $pgdata"
	"$MC_BINDIR/initdb" -D "$pgdata" --auth=trust --no-sync \
		--no-instructions --lc-messages=C -E UTF8 >"$pgdata.initdb.log" 2>&1 ||
		{ cat "$pgdata.initdb.log" >&2; mc_die "initdb failed"; }
}

# mc_server_start PGDATA PORT SOCKDIR LOGFILE [GUC=VAL ...]
#
# Baseline GUCs the harness always forces, and why:
#   shared_preload_libraries=memcow  the module registers its smgr and hooks
#                                at preload; memcow.enabled is the caller's
#   listen_addresses=''          unix sockets only
#   unix_socket_directories      per-run private directory
#   fsync=off                    the RAM-backed PGDATA is fsync=off; the stock
#                                side of a differential run matches it
#   log_min_messages=warning     MANDATORY: every leak signal mc_check_log
#                                greps for is a WARNING
#   restart_after_crash=off      a crashed backend must abort the run loudly
mc_server_start()
{
	local pgdata=$1 port=$2 sockdir=$3 logfile=$4
	shift 4
	local opts g
	opts="-c shared_preload_libraries=memcow -c listen_addresses="
	opts="$opts -c unix_socket_directories=$sockdir -c fsync=off"
	opts="$opts -c log_min_messages=warning -c log_statement=none"
	opts="$opts -c restart_after_crash=off"
	for g in "$@"; do
		opts="$opts -c $g"
	done

	mc_log "starting postmaster: pgdata=$pgdata port=$port gucs: $*"
	if ! "$MC_BINDIR/pg_ctl" -D "$pgdata" -l "$logfile" -p "$MC_BINDIR/postgres" \
		-o "$opts -p $port" -w -t 120 start >>"$logfile.pg_ctl" 2>&1
	then
		mc_warn "pg_ctl start failed; tail of $logfile:"
		tail -40 "$logfile" >&2 || true
		return 1
	fi
	return 0
}

# mc_server_stop PGDATA LOGFILE [MODE]
#
# "fast" by default: backends exit through the normal proc-exit path, so
# AtProcExit_Buffers()/pgaio_shutdown() actually run and can complain.
mc_server_stop()
{
	"$MC_BINDIR/pg_ctl" -D "$1" -m "${3:-fast}" -w -t 120 stop >>"$2.pg_ctl" 2>&1
}

mc_server_running()
{
	"$MC_BINDIR/pg_ctl" -D "$1" status >/dev/null 2>&1
}

# mc_server_cleanup PGDATA LOGFILE SOCKDIR --- for an EXIT trap: fast stop,
# immediate if that fails, then drop the socket directory.
mc_server_cleanup()
{
	if mc_server_running "$1"; then
		mc_server_stop "$1" "$2" fast || mc_server_stop "$1" "$2" immediate
	fi
	rm -rf "$3"
}

# mc_ensure_startable PGDATA SEED RAM_MOUNT LOGDIR
#
# A memcow PGDATA that needs recovery cannot be started at all (slice case S8
# is about exactly that), so a run that finds one left behind re-assembles the
# RAM dir instead of reporting every case as "server would not start".
mc_ensure_startable()
{
	local pgdata=$1 seed=$2 mount=$3 logdir=$4 st
	st=$("$MC_BINDIR/pg_controldata" -D "$pgdata" 2>/dev/null |
		sed -n 's/^Database cluster state: *//p')
	case $st in
		"shut down"|"shut down in recovery") return 0 ;;
		"")	mc_warn "cannot read pg_controldata for $pgdata"; return 1 ;;
	esac
	mc_warn "PGDATA is in state '$st' (needs recovery); re-assembling"
	mc_server_running "$pgdata" && mc_server_stop "$pgdata" "$logdir/postmaster.log" immediate
	bash "$(mc_harness_dir)/../seed/assemble_ramdir.sh" -s "$seed" -m "$mount" \
		-b "$MC_BINDIR" -f >"$logdir/reassemble.log" 2>&1
}

# mc_psql SOCKDIR PORT DB SQL  -> tuples-only, unaligned
mc_psql()
{
	local sockdir=$1 port=$2 db=$3 sql=$4
	PGHOST=$sockdir PGPORT=$port "$MC_BINDIR/psql" -X -q -A -t \
		-v ON_ERROR_STOP=1 -d "$db" -c "$sql"
}

# ---------------------------------------------------------------------------
# the leak / crash scan
# ---------------------------------------------------------------------------

# mc_check_log LOGFILE [COREDIR ...]  -> 0 clean, 1 dirty (hits printed)
#
# A log scanner, deliberately.  Core already instruments every leak class the
# plan cares about, provided cassert is on and log_min_messages is at most
# warning (mc_server_start forces the latter):
#
#   bufmgr.c   CheckForBufferLeaks()      "buffer refcount leak: ..."
#   localbuf.c CheckForLocalBufferLeaks() "local buffer refcount leak: ..."
#   aio.c      resowner release           "leaked AIO handle",
#                                         "AIO handle was not submitted"
#   aio.c      AtEOXact_Aio()             "open AIO batch at end of ..."
#   resowner.c                            "resource was not closed: ..."
#
# plus assertion failures, PANICs, signal deaths, abnormal exits, the
# postmaster's crash-recovery line, and ENOSPC on the RAM dir.  What it does
# NOT catch: a backend parked forever without a transaction end (the harness
# always stops with -m fast, which takes every backend through proc exit);
# balanced-but-wrong pin accounting; DSM/dsa leaks -- the per-reset DSM count
# in pool_soak.py and the bench probes are that instrument.
MC_LOG_BAD='buffer refcount leak:|leaked AIO handle|AIO handle was not submitted|open AIO batch at end|resource was not closed:|TRAP: |Failed [Aa]ssert|Assertion failed|PANIC:|was terminated by signal|server process \(PID [0-9]+\) exited with exit code|terminating any other active server processes|No space left on device'

mc_check_log()
{
	local log=$1 hits cores d
	shift
	hits=$(grep -nE "$MC_LOG_BAD" "$log" 2>/dev/null)
	for d in "$@"; do
		[ -d "$d" ] || continue
		cores=$(find "$d" \( -name 'core' -o -name 'core.*' -o -name '*.core' \) -type f 2>/dev/null)
		[ -z "$cores" ] || hits="$hits${hits:+$'\n'}core file(s) under $d: $cores"
	done
	if [ -n "$hits" ]; then
		printf 'LEAKCHECK DIRTY  %s:\n' "$log"
		printf '%s\n' "$hits" | head -20 | sed 's/^/    /'
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# misc
# ---------------------------------------------------------------------------

mc_abspath()
{
	python3 - "$1" <<'PY'
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
}

mc_harness_dir()
{
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
}

# ---------------------------------------------------------------------------
# volatile_data_directory servers
# ---------------------------------------------------------------------------

# mc_volatile_start SEED PORT LOGFILE PIDFILE [GUC=VAL ...]
#
# A postmaster whose data directory IS the immutable seed.  pg_ctl cannot own
# it: pg_ctl reads postmaster.pid, which a volatile server never writes.  The
# caller owns the PID recorded in PIDFILE (outside the seed) and readiness is
# a TCP connection, the only kind of listener the mode allows.  Another server
# may hold the port while this one has not bound it yet, so readiness also
# requires this start's cluster_name.  Callers' GUCs come last and so override
# the baseline.
mc_volatile_start()
{
	local seed=$1 port=$2 logfile=$3 pidfile=$4 pid i g name
	shift 4
	name=mcvol-$$-$RANDOM$RANDOM
	local args=(-D "$seed" -c volatile_data_directory=on -c "port=$port"
		-c "cluster_name=$name"
		-c listen_addresses=127.0.0.1 -c unix_socket_directories=
		-c shared_preload_libraries=memcow -c memcow.enabled=on
		-c "memcow.seed_directory=$seed" -c wal_level=minimal
		-c max_wal_senders=0 -c max_prepared_transactions=0 -c fsync=off
		-c log_min_messages=warning -c log_statement=none
		-c restart_after_crash=off)
	for g in "$@"; do
		args+=(-c "$g")
	done

	"$MC_BINDIR/postgres" "${args[@]}" >>"$logfile" 2>&1 &
	pid=$!
	echo "$pid" >"$pidfile"
	for ((i = 0; i < 1200; i++)); do
		if [ "$("$MC_BINDIR/psql" -X -A -t -h 127.0.0.1 -p "$port" -U "${PGUSER:-postgres}" \
			-d postgres -c 'SHOW cluster_name' 2>/dev/null)" = "$name" ]; then
			return 0
		fi
		if ! kill -0 "$pid" 2>/dev/null; then
			wait "$pid" 2>/dev/null
			return 1
		fi
		sleep 0.1
	done
	mc_warn "volatile postmaster $pid not ready on port $port after 120s"
	return 1
}

# mc_volatile_stop PIDFILE [SIGNAL]  --- INT is a fast shutdown, QUIT an
# immediate one, KILL a crash.  Waits for the postmaster to exit.
mc_volatile_stop()
{
	local pidfile=$1 sig=${2:-INT} pid i
	[ -f "$pidfile" ] || return 0
	pid=$(cat "$pidfile")
	rm -f "$pidfile"
	kill -0 "$pid" 2>/dev/null || return 0
	kill -"$sig" "$pid" 2>/dev/null
	for ((i = 0; i < 1200; i++)); do
		kill -0 "$pid" 2>/dev/null || return 0
		sleep 0.1
	done
	mc_warn "volatile postmaster $pid did not exit on SIG$sig; killing"
	kill -KILL "$pid" 2>/dev/null
	return 1
}

# mc_seed_manifest SEED OUT --- every path below SEED with its type, mode,
# size and (for regular files) SHA-256.  Two equal manifests mean nothing was
# created, removed, rewritten or re-permissioned; access times are ignored.
mc_seed_manifest()
{
	local seed=$1 out=$2
	python3 - "$seed" >"$out" <<'PY'
import hashlib, os, stat, sys
root = sys.argv[1]
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    st = os.lstat(dirpath)
    print('d %o %s' % (stat.S_IMODE(st.st_mode), os.path.relpath(dirpath, root)))
    for name in sorted(filenames) + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]:
        path = os.path.join(dirpath, name)
        st = os.lstat(path)
        rel = os.path.relpath(path, root)
        if stat.S_ISREG(st.st_mode):
            with open(path, 'rb') as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            print('f %o %d %s %s' % (stat.S_IMODE(st.st_mode), st.st_size, digest, rel))
        else:
            print('o %o %s -> %s' % (stat.S_IMODE(st.st_mode), rel,
                                     os.readlink(path) if stat.S_ISLNK(st.st_mode) else ''))
PY
}
