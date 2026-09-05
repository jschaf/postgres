# common.sh --- shared helpers for the memcow test harness
#
# Sourced, never executed.  Every function is prefixed mc_.
#
# The harness drives an *already built* PostgreSQL.  It never builds, and it
# never touches the core source tree.  Everything it needs is derived from a
# meson build directory (preferred) or from explicit --bindir/--regress-src
# overrides.
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

# mc_default_build_dir --- best guess at the meson build dir
#
# Honors $MEMCOW_BUILD_DIR.  Otherwise looks for a directory named build-fast
# (the cassert + injection_points build this project standardises on) next to
# the source root that owns this harness.  Because the harness may live in a
# git worktree while the build lives in the main checkout, we also probe the
# common-dir of the repository.
mc_default_build_dir()
{
	local here root candidate

	if [ -n "${MEMCOW_BUILD_DIR:-}" ]; then
		printf '%s\n' "$MEMCOW_BUILD_DIR"
		return 0
	fi

	here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
	# harness lives at <root>/src/test/memcow/harness
	root=$(cd -- "$here/../../../.." && pwd)

	for candidate in "$root/build-fast" "$root/build"; do
		if [ -e "$candidate/meson-info/meson-info.json" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done

	# Worktree case: find the main checkout via git and look there.
	if command -v git >/dev/null 2>&1; then
		local common main
		common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
		if [ -n "$common" ]; then
			main=$(dirname -- "$common")
			for candidate in "$main/build-fast" "$main/build"; do
				if [ -e "$candidate/meson-info/meson-info.json" ]; then
					printf '%s\n' "$candidate"
					return 0
				fi
			done
		fi
	fi

	return 1
}

# mc_resolve_build BUILD_DIR
#
# Sets, unless already set by an explicit override:
#   MC_BUILD_DIR   the meson build directory
#   MC_SRC_DIR     the source directory that build was configured from
#   MC_BINDIR      directory holding postgres/initdb/pg_ctl/psql (tmp_install)
#   MC_LIBDIR      shared library dir matching MC_BINDIR
#   MC_PG_REGRESS  the pg_regress binary
#   MC_REGRESS_SRC source dir holding sql/, expected/, parallel_schedule
#   MC_DLPATH      directory holding regress.so/.dylib (pg_regress --dlpath)
#
# IMPORTANT: MC_REGRESS_SRC defaults to the source tree the *build* came from,
# not to the tree this script lives in.  Regression inputs and server binaries
# must be from the same commit or the diffs are meaningless.
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
src = mi['directories']['source']
prefix = None
libdir = 'lib'
with open(os.path.join(bd, 'meson-info', 'intro-buildoptions.json')) as f:
    for o in json.load(f):
        if o['name'] == 'prefix':
            prefix = o['value']
        elif o['name'] == 'libdir':
            # 'lib' on macOS, 'lib/<multiarch>' on Debian-family Linux;
            # tmp_install mirrors whatever meson was told.
            libdir = o['value']
        elif o['name'] == 'cassert':
            print('MC_BUILD_CASSERT=%s' % ('yes' if o['value'] else 'no'))
        elif o['name'] == 'injection_points':
            print('MC_BUILD_INJECTION_POINTS=%s' % ('yes' if o['value'] else 'no'))
print('MC_SRC_DIR=%s' % src)
print('MC_PREFIX=%s' % prefix)
print('MC_LIBDIR_REL=%s' % libdir)
PY
	) || mc_die "cannot read meson introspection data from $MC_BUILD_DIR"
	eval "$info"

	: "${MC_BINDIR:=$MC_BUILD_DIR/tmp_install$MC_PREFIX/bin}"
	: "${MC_LIBDIR:=$MC_BUILD_DIR/tmp_install$MC_PREFIX/$MC_LIBDIR_REL}"
	: "${MC_PG_REGRESS:=$MC_BUILD_DIR/src/test/regress/pg_regress}"
	: "${MC_REGRESS_SRC:=$MC_SRC_DIR/src/test/regress}"
	: "${MC_DLPATH:=$MC_BUILD_DIR/src/test/regress}"

	[ -x "$MC_BINDIR/postgres" ] ||
		mc_die "no postgres binary at $MC_BINDIR/postgres
  (run: meson test -C $MC_BUILD_DIR --suite setup   to populate tmp_install)"
	[ -x "$MC_BINDIR/pg_ctl" ] || mc_die "no pg_ctl at $MC_BINDIR/pg_ctl"
	[ -x "$MC_BINDIR/psql" ]   || mc_die "no psql at $MC_BINDIR/psql"
	[ -x "$MC_PG_REGRESS" ]    || mc_die "no pg_regress at $MC_PG_REGRESS"
	[ -f "$MC_REGRESS_SRC/parallel_schedule" ] ||
		mc_die "no parallel_schedule under $MC_REGRESS_SRC"

	if [ "${MC_BUILD_CASSERT:-no}" != yes ]; then
		mc_warn "build $MC_BUILD_DIR has cassert=false; the leak check is nearly vacuous"
	fi

	# The tmp_install binaries were linked against an install prefix that does
	# not exist; point the dynamic loader at the staged libdir.  (On Linux the
	# RUNPATH names that prefix, so without this psql cannot find libpq.)
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

# mc_make_sockdir
#
# Unix socket paths are capped at ~104 bytes on macOS, so the socket directory
# has to be short.  Scratch/output directories in this project routinely exceed
# that, hence a deliberately short prefix.  Override with MEMCOW_SOCKDIR_ROOT.
mc_make_sockdir()
{
	local root=${MEMCOW_SOCKDIR_ROOT:-/tmp}
	mktemp -d "$root/pgmcw.XXXXXX"
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
#   listen_addresses=''          unix sockets only; no port collisions with
#                                anything else on the host
#   unix_socket_directories      per-run private directory
#   fsync=off                    the plan's RAM-backed PGDATA is fsync=off; the
#                                harness matches so A/B timing is comparable
#   log_min_messages=warning     MANDATORY: every leak signal the check greps
#                                for is a WARNING.  Raising this blinds it.
#   log_statement=none           keeps postmaster.log scannable
#   restart_after_crash=off      a crashed backend must abort the run loudly
#                                instead of being papered over by a restart
mc_server_start()
{
	local pgdata=$1 port=$2 sockdir=$3 logfile=$4
	shift 4

	local opts
	opts="-c shared_preload_libraries=memcow -c listen_addresses="
	opts="$opts -c unix_socket_directories=$sockdir"
	opts="$opts -c fsync=off"
	opts="$opts -c log_min_messages=warning"
	opts="$opts -c log_statement=none"
	opts="$opts -c restart_after_crash=off"

	local g
	for g in "$@"; do
		opts="$opts -c $g"
	done

	mc_log "starting postmaster: pgdata=$pgdata port=$port"
	mc_log "  extra GUCs: $*"

	if ! "$MC_BINDIR/pg_ctl" -D "$pgdata" -l "$logfile" -p "$MC_BINDIR/postgres" \
		-o "$opts -p $port" -w -t 120 start >>"$logfile.pg_ctl" 2>&1
	then
		mc_warn "pg_ctl start failed; tail of $logfile:"
		tail -40 "$logfile" >&2 || true
		return 1
	fi
	return 0
}

# mc_server_stop PGDATA LOGFILE
#
# "fast" shutdown: backends exit through the normal proc-exit path, so
# AtProcExit_Buffers()/pgaio_shutdown() actually run and can complain.  An
# immediate shutdown would skip exactly the checks we are relying on.
mc_server_stop()
{
	local pgdata=$1 logfile=$2
	"$MC_BINDIR/pg_ctl" -D "$pgdata" -m fast -w -t 120 stop >>"$logfile.pg_ctl" 2>&1
}

mc_server_running()
{
	"$MC_BINDIR/pg_ctl" -D "$1" status >/dev/null 2>&1
}

# mc_psql SOCKDIR PORT DB SQL  -> tuples-only, unaligned
mc_psql()
{
	local sockdir=$1 port=$2 db=$3 sql=$4
	PGHOST=$sockdir PGPORT=$port "$MC_BINDIR/psql" -X -q -A -t \
		-v ON_ERROR_STOP=1 -d "$db" -c "$sql"
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
