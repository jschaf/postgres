#!/bin/bash
#
# src/test/memcow/seed/build_seed.sh
#
# Build the memcow ephemeral-test-engine SEED cluster (plan.md §1 "Seed",
# §3 step 1).
#
# The seed is an ORDINARY PGDATA, produced by the same fork binary that will
# later run in test mode, with the memcow GUC OFF so every relation file is
# written by stock md.c.  There is no packed seed format (Appendix A.3): the
# md-format segment files under base/<db>/ and global/ *are* the relation-block
# index that memcow mmaps read-only at runtime.
#
# Sequence:
#     1.  resolve + validate the build (bindir)
#     2.  preload memcow with memcow.enabled=off       <- named step, see below
#     3.  initdb
#     4.  start the postmaster
#     5.  apply schema.sql to template1
#     6.  create the lane databases + the control database from template1/0
#     7.  freeze + analyze every database
#     8.  CHECKPOINT, then a CLEAN shutdown             <- load-bearing, see below
#    8b.  prune pg_wal down to the REDO segment (+1 spare)
#     9.  strip pg_internal.init, emit the fingerprint file
#    10.  verify: pg_controldata says "shut down"
#
# ---------------------------------------------------------------------------
# Why the clean shutdown is load-bearing
# ---------------------------------------------------------------------------
# §3 step 2 copies only the seed's small NON-relation files into the RAM dir;
# the relation files stay behind and are mmapped PROT_READ.  Crash recovery
# would want to replay WAL *into relation files* -- which are read-only and not
# even in the running PGDATA.  So the seed's pg_control must say
# "shut down": startup then takes the no-recovery path and no relation write
# is ever attempted against the seed.  A crash-shutdown seed is unusable, and
# this script fails rather than emitting one.  (A clean shutdown also
# guarantees the UNLOGGED relation in schema.sql keeps its contents, instead of
# being reset from its init fork.)
#
# ---------------------------------------------------------------------------
# The fingerprint file
# ---------------------------------------------------------------------------
# Appendix A.3 deletes the manifest: the seed's identity check is
# "pg_control + PG_VERSION + one build-hash file checked in memcow init".
# pg_control validation is already done by core at startup and covers block
# size, segment size, WAL segment size, checksum version, MAXALIGN, float
# format, etc. -- against the *running* binary's compile-time constants.  What
# pg_control does NOT prove is that the seed was written by the *same build*.
# That is this file's only job:
#
#     <seed>/memcow_seed.fingerprint
#
# Format: ASCII, LF-terminated, one `key=value` per line, keys matching
# [a-z0-9_]+, values containing no whitespace, no comments, no blank lines,
# fixed key order, total size < 512 bytes.  That makes the C reader in
# memcow init a single read() into a stack buffer:
#
#     char        buf[512];
#     int         fd = OpenTransientFile(path, O_RDONLY | PG_BINARY);
#     int         n  = read(fd, buf, sizeof(buf) - 1);
#     buf[n] = '\0';
#     for (char *line = strtok(buf, "\n"); line; line = strtok(NULL, "\n"))
#     {
#         char *eq = strchr(line, '=');
#         ...  strncmp(line, "catalog_version_no", eq - line) ...
#     }
#
# Keys, and what memcow init is expected to do with them:
#
#     memcow_seed_fingerprint_version  must equal 1, else ERROR (format gate)
#     pg_version                       must equal PG_MAJORVERSION
#     pg_control_version               must equal PG_CONTROL_VERSION
#     catalog_version_no               must equal CATALOG_VERSION_NO
#     block_size                       must equal BLCKSZ
#     relseg_blocks                    must equal RELSEG_SIZE  (md segment math)
#     wal_block_size                   must equal XLOG_BLCKSZ
#     wal_segment_bytes                informational
#     data_page_checksum_version       must equal the running cluster's
#     postgres_binary_bytes            cheap pre-check via stat() on my_exec_path
#     postgres_binary_sha256           the actual build hash; compare against a
#                                      SHA-256 of my_exec_path
#
# catalog_version_no is the cheapest real "same build" signal -- it is a
# compile-time constant in catversion.h and changes on every catalog-affecting
# commit, so a stale seed against a rebuilt binary is caught with no I/O.  The
# binary SHA-256 catches the rest (a non-catalog code change that alters page
# contents or md layout).  Hashing the binary costs one sequential read of
# ~40 MB, once per postmaster start; if that ever shows up in service-start
# latency, gate it behind a GUC and keep catalog_version_no unconditional.
#
# The last three keys are BUILD-RECIPE inputs.  memcow ignores them; only this
# script reads them, to decide whether an existing seed is up to date:
#
#     seed_recipe_sha256               hash of build_seed.sh + schema.sql +
#                                      the normalized recipe parameters
#     seed_lane_count                  lanes this seed was built with
#     seed_superuser                   bootstrap superuser name
#
# They are deliberately NOT a manifest: nothing at runtime enumerates lanes
# from this file.  Lane discovery is a catalog query --
#     SELECT datname FROM pg_database WHERE datname LIKE 'memcow\_lane\_%'
# -- which is authoritative because the databases themselves are.
#
# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------
# The cluster is built in <seed>.build and renamed into place only after the
# clean shutdown succeeds, so an interrupted run never leaves a half-built
# seed at the published path.  A re-run with an existing seed whose
# fingerprint matches the current binary and recipe is a no-op; anything else
# rebuilds.  --force always rebuilds.  Nothing is ever rm -rf'd unless it
# looks like a PGDATA this script produced (PG_VERSION present, and either the
# fingerprint file or the .build suffix).
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   build_seed.sh [-b BINDIR] [-o SEEDDIR] [-l LANES] [-u SUPERUSER] [-f] [-q]
#
#   -b BINDIR     PostgreSQL bindir       (default $MEMCOW_BINDIR or
#                                          /opt/p/postgres-install/bin, i.e.
#                                          `ninja -C build-fast install`)
#   -o SEEDDIR    seed PGDATA to produce  (default $MEMCOW_SEED_DIR or
#                                          /opt/p/postgres-memcow/seed)
#   -l LANES      lane databases to create (default $MEMCOW_SEED_LANES or 8)
#   -u SUPERUSER  bootstrap superuser      (default $MEMCOW_SUPERUSER or postgres)
#   -f            force a rebuild even if the existing seed is up to date
#   -q            quiet
#
set -euo pipefail

# Deterministic collation and message text: pg_controldata field labels are
# parsed below, and step_prune_wal string-compares hex WAL segment names.
export LC_ALL=C
export PGCLIENTENCODING=UTF8

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------

PG_BINDIR=${MEMCOW_BINDIR:-/opt/p/postgres-install/bin}
SEED_DIR=${MEMCOW_SEED_DIR:-/opt/p/postgres-memcow/seed}
LANES=${MEMCOW_SEED_LANES:-8}
SUPERUSER=${MEMCOW_SUPERUSER:-postgres}
FORCE=0
QUIET=0

# The PGC_POSTMASTER bool from plan.md §2, defined by contrib/memcow.
MEMCOW_GUC_NAME=memcow.enabled

# Lane database naming convention.  Two decimal digits, zero padded, from 00.
LANE_DB_PREFIX=${MEMCOW_LANE_DB_PREFIX:-memcow_lane_}
CONTROL_DB=${MEMCOW_CONTROL_DB:-memcow_control}

# A port number is required even though the seed build is unix-socket-only:
# the socket file name embeds it.  Collisions are impossible because the
# socket lives in a private mktemp directory.
BUILD_PORT=${MEMCOW_SEED_BUILD_PORT:-61432}

FINGERPRINT_BASENAME=memcow_seed.fingerprint
FINGERPRINT_VERSION=1

while getopts 'b:o:l:u:fqh' opt; do
	case $opt in
		b) PG_BINDIR=$OPTARG ;;
		o) SEED_DIR=$OPTARG ;;
		l) LANES=$OPTARG ;;
		u) SUPERUSER=$OPTARG ;;
		f) FORCE=1 ;;
		q) QUIET=1 ;;
		h) awk '/^set -euo pipefail/{exit} NR>1' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "usage: $0 [-b BINDIR] [-o SEEDDIR] [-l LANES] [-u SUPERUSER] [-f] [-q]" >&2
		   exit 2 ;;
	esac
done

case $SEED_DIR in
	/*) ;;
	*)  SEED_DIR=$PWD/$SEED_DIR ;;
esac
case $PG_BINDIR in
	/*) ;;
	*)  PG_BINDIR=$PWD/$PG_BINDIR ;;
esac

SCRIPT_PATH=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
SCHEMA_SQL=$(dirname "$SCRIPT_PATH")/schema.sql

# Optional embedder hook, run once against template1 after schema.sql and the
# memcow extension, and BEFORE the lane databases are cloned from it --
# so whatever it creates is inherited byte-identically by every lane, exactly
# as schema.sql is.  It exists because an embedder's schema is not always a
# static .sql file: Takeoffs applies its migration ledger through a TypeScript
# runner, which needs a live connection rather than a psql -f.
#
#   MEMCOW_SEED_SCHEMA_HOOK    command line, run through `sh -c` with PGHOST,
#                              PGPORT, PGUSER and PGDATABASE=template1 exported.
#                              A non-zero exit fails the build.
#   MEMCOW_SEED_SCHEMA_RECIPE  opaque string folded into seed_recipe_sha256, so
#                              the caller can make the seed rebuild when ITS
#                              inputs change (the hook command line alone does
#                              not describe the schema the hook applies).
SCHEMA_HOOK=${MEMCOW_SEED_SCHEMA_HOOK:-}
SCHEMA_HOOK_RECIPE=${MEMCOW_SEED_SCHEMA_RECIPE:-}
# Optional embedder validation after lane creation, before accepting the seed.
# Receives the same connection environment, PGDATABASE=postgres and lane count.
VERIFY_HOOK=${MEMCOW_SEED_VERIFY_HOOK:-}

BUILD_DIR=$SEED_DIR.build
BUILD_LOG=$SEED_DIR.build.log
SOCK_DIR=

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

log()  { [ "$QUIET" = 1 ] || printf '[build_seed] %s\n' "$*" >&2; }
die()  { printf '[build_seed] ERROR: %s\n' "$*" >&2; exit 1; }

sha256_of()
{
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		# macOS
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

sha256_of_stdin()
{
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	else
		shasum -a 256 | awk '{print $1}'
	fi
}

file_bytes()
{
	# BSD stat and GNU stat disagree, and "try BSD first" is not safe: on
	# GNU stat -f means --file-system, which prints a multi-line report to
	# stdout before failing on the "%z" operand, so the fallback's number
	# would be appended to garbage.  Detect GNU (only it has --version).
	if stat --version >/dev/null 2>&1; then
		stat -c %s "$1"
	else
		stat -f %z "$1"
	fi
}

lane_db_name()
{
	printf '%s%02d' "$LANE_DB_PREFIX" "$1"
}

# Read one `key=value` out of a fingerprint file.  Empty output if absent.
fingerprint_get()
{
	[ -r "$1" ] || return 0
	awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }' "$1"
}

# pg_controldata field lookup, LC_ALL=C so the labels are the untranslated ones.
controldata_get()
{
	LC_ALL=C "$PG_BINDIR/pg_controldata" -D "$1" \
		| sed -n "s/^$2: *//p" | head -1
}

psql_do()
{
	local db=$1; shift
	PGOPTIONS='' "$PG_BINDIR/psql" \
		--no-psqlrc --quiet --no-align --tuples-only \
		-v ON_ERROR_STOP=1 \
		-h "$SOCK_DIR" -p "$BUILD_PORT" -U "$SUPERUSER" -d "$db" "$@"
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

server_running=0

# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup()
{
	local rc=$?

	if [ "$server_running" = 1 ]; then
		log "cleanup: stopping postmaster (immediate)"
		"$PG_BINDIR/pg_ctl" -D "$BUILD_DIR" -m immediate -w stop \
			>/dev/null 2>&1 || true
		server_running=0
	fi
	[ -n "$SOCK_DIR" ] && [ -d "$SOCK_DIR" ] && rm -rf "$SOCK_DIR"

	if [ "$rc" != 0 ]; then
		printf '[build_seed] failed (exit %s); build log: %s\n' \
			"$rc" "$BUILD_LOG" >&2
	fi
	return "$rc"
}
trap cleanup EXIT

# Refuse to rm -rf anything that is not recognisably ours.
safe_rmtree()
{
	local d=$1

	[ -e "$d" ] || return 0
	case $d in
		/|/*/..|*/..|.|..) die "refusing to remove suspicious path '$d'" ;;
		/*) ;;
		*) die "refusing to remove non-absolute path '$d'" ;;
	esac
	if [ ! -f "$d/PG_VERSION" ] && [ ! -f "$d/$FINGERPRINT_BASENAME" ]; then
		case $d in
			*.build) ;;   # our own scratch dir, may be a stump
			*) die "refusing to remove '$d': not a PGDATA this script made" ;;
		esac
	fi
	chmod -R u+w "$d" 2>/dev/null || true
	rm -rf "$d"
}

# ---------------------------------------------------------------------------
# Step 1: resolve and validate the build
# ---------------------------------------------------------------------------

step_validate_build()
{
	local prog

	[ -d "$PG_BINDIR" ] || die "bindir '$PG_BINDIR' does not exist (build it: ninja -C build-fast install)"
	for prog in initdb postgres pg_ctl psql pg_controldata createdb; do
		[ -x "$PG_BINDIR/$prog" ] || \
			die "missing $PG_BINDIR/$prog (build it: ninja -C build-fast install)"
	done
	[ -r "$SCHEMA_SQL" ] || die "missing schema file '$SCHEMA_SQL'"

	case $LANES in
		''|*[!0-9]*) die "lane count must be a non-negative integer, got '$LANES'" ;;
	esac
	[ "$LANES" -le 99 ] || die "lane count > 99 does not fit the %02d naming convention"

	PG_BINARY=$PG_BINDIR/postgres
	PG_BINARY_SHA256=$(sha256_of "$PG_BINARY")
	PG_BINARY_BYTES=$(file_bytes "$PG_BINARY")

	MEMCOW_MODULE_BYTES=0
	MEMCOW_MODULE_SHA256=
	for suffix in so dylib dll; do
		module="$("$PG_BINDIR/pg_config" --pkglibdir)/memcow.$suffix"
		if [ -f "$module" ]; then
			MEMCOW_MODULE_BYTES=$(file_bytes "$module")
			MEMCOW_MODULE_SHA256=$(sha256_of "$module")
			break
		fi
	done
	[ -n "$MEMCOW_MODULE_SHA256" ] || die "no memcow module under $("$PG_BINDIR/pg_config" --pkglibdir); install contrib/memcow first"

	# The recipe hash: everything that changes what the seed contains.
	RECIPE_SHA256=$(
		{
			printf 'fingerprint_version=%s\n' "$FINGERPRINT_VERSION"
			printf 'lanes=%s\n' "$LANES"
			printf 'superuser=%s\n' "$SUPERUSER"
			printf 'lane_prefix=%s\n' "$LANE_DB_PREFIX"
			printf 'control_db=%s\n' "$CONTROL_DB"
			printf 'script=%s\n'  "$(sha256_of "$SCRIPT_PATH")"
			printf 'module=%s\n' "$MEMCOW_MODULE_SHA256"
			printf 'schema=%s\n'  "$(sha256_of "$SCHEMA_SQL")"
			printf 'schema_hook=%s\n' "$SCHEMA_HOOK"
			printf 'schema_hook_recipe=%s\n' "$SCHEMA_HOOK_RECIPE"
			printf 'verify_hook=%s\n' "$VERIFY_HOOK"
		} | sha256_of_stdin
	)

	log "bindir      $PG_BINDIR"
	log "postgres    $("$PG_BINARY" --version) sha256=${PG_BINARY_SHA256:0:16}..."
	log "seed        $SEED_DIR"
	log "lanes       $LANES ($(lane_db_name 0) .. $(lane_db_name $((LANES - 1)))), control $CONTROL_DB"
}

# ---------------------------------------------------------------------------
# Step 2: memcow preloaded but OFF  (NAMED STEP -- see plan.md §1, §3.1)
#
# The seed must be written by stock md.c, so the module is preloaded (its
# GUCs must exist for CREATE EXTENSION and for the lane databases to inherit
# the extension) with memcow.enabled=off on the postmaster command line.
# initdb has no way to pass a GUC without also writing it into the seed's
# postgresql.conf, which assemble_ramdir.sh would then copy into the RAM
# dir; the GUC's boot default is off, which is what initdb's bootstrap
# backend uses.
# ---------------------------------------------------------------------------

MEMCOW_GUC_OFF_OPTS=

step_force_memcow_guc_off()
{
	[ -f "$("$PG_BINDIR/pg_config" --sharedir)/extension/memcow.control" ] ||
		die "memcow.control not found beside $PG_BINDIR: install contrib/memcow first (ninja / meson test --suite setup)"
	MEMCOW_GUC_OFF_OPTS="-c shared_preload_libraries=memcow -c $MEMCOW_GUC_NAME=off"
	log "guc-off: preloading memcow with $MEMCOW_GUC_NAME=off for the seed"
}

# ---------------------------------------------------------------------------
# Freshness check
# ---------------------------------------------------------------------------

seed_is_current()
{
	local fp=$SEED_DIR/$FINGERPRINT_BASENAME
	local state

	[ -f "$SEED_DIR/PG_VERSION" ] || return 1
	[ -f "$fp" ] || return 1

	[ "$(fingerprint_get "$fp" memcow_seed_fingerprint_version)" = "$FINGERPRINT_VERSION" ] || return 1
	[ "$(fingerprint_get "$fp" postgres_binary_sha256)" = "$PG_BINARY_SHA256" ] || return 1
	[ "$(fingerprint_get "$fp" postgres_binary_bytes)"  = "$PG_BINARY_BYTES"  ] || return 1
	[ "$(fingerprint_get "$fp" seed_recipe_sha256)"     = "$RECIPE_SHA256"    ] || return 1
	[ "$(fingerprint_get "$fp" seed_lane_count)"        = "$LANES"            ] || return 1
	[ "$(fingerprint_get "$fp" seed_superuser)"         = "$SUPERUSER"        ] || return 1

	state=$(controldata_get "$SEED_DIR" 'Database cluster state') || return 1
	[ "$state" = "shut down" ] || return 1

	# Has anything STARTED this cluster since it was built?  Nothing in the
	# normal workflow should: the seed is a read-only artifact that
	# assemble_ramdir.sh copies from and memcow mmaps PROT_READ.  A run
	# leaves fingerprints of its own -- regenerated pg_internal.init files,
	# a postmaster.opts, and pg_wal grown back past the pruned set -- and
	# those extra WAL segments would then be copied into the RAM disk at
	# 16 MB apiece.  Treat it as stale and rebuild.
	[ -f "$SEED_DIR/postmaster.opts" ] && return 1
	[ -n "$(find "$SEED_DIR" -name pg_internal.init -print -quit)" ] && return 1
	[ "$(find "$SEED_DIR/pg_wal" -maxdepth 1 -type f | wc -l | tr -d ' ')" -le "${MEMCOW_SEED_WAL_KEEP:-2}" ] || return 1

	return 0
}

# ---------------------------------------------------------------------------
# Step 3: initdb
# ---------------------------------------------------------------------------

step_initdb()
{
	log "initdb $BUILD_DIR"

	# --no-sync: the seed is a rebuildable build artifact; the shutdown
	# checkpoint in step 8 runs with fsync=on, which is what makes
	# pg_control itself durable.
	# --locale=C / --encoding=UTF8 / --data-checksums: pinned, not inherited
	# from the environment, because the seed must be reproducible and
	# because memcow's overlay pages are post-PageSetChecksum images
	# (plan.md §1) -- checksums have to be on for that to mean anything.
	"$PG_BINDIR/initdb" \
		--pgdata="$BUILD_DIR" \
		--username="$SUPERUSER" \
		--auth=trust \
		--encoding=UTF8 \
		--locale=C \
		--data-checksums \
		--no-sync \
		--no-instructions \
		>>"$BUILD_LOG" 2>&1 \
		|| die "initdb failed; see $BUILD_LOG"
}

# ---------------------------------------------------------------------------
# Step 4: start the postmaster
# ---------------------------------------------------------------------------

step_start_server()
{
	local opts

	SOCK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/memcow_seed.XXXXXX")

	# fsync=on here, deliberately: the whole point of the build is to leave
	# a durable, cleanly-shut-down cluster on disk.  The RAM-dir settings
	# (fsync=off etc.) belong to assemble_ramdir.sh, not to the seed.
	opts="-c listen_addresses='' -c unix_socket_directories=$SOCK_DIR"
	opts="$opts -c fsync=on -c autovacuum=off -c max_prepared_transactions=0"
	opts="$opts -c max_connections=20 -c shared_buffers=128MB"
	opts="$opts -c maintenance_work_mem=128MB -c log_min_messages=warning"
	opts="$opts $MEMCOW_GUC_OFF_OPTS"

	log "starting postmaster (socket $SOCK_DIR, port $BUILD_PORT)"
	"$PG_BINDIR/pg_ctl" -D "$BUILD_DIR" -l "$BUILD_LOG" -w -t 120 \
		-o "$opts -p $BUILD_PORT" start \
		|| die "postmaster failed to start; see $BUILD_LOG"
	server_running=1
}

# ---------------------------------------------------------------------------
# Step 5: schema
# ---------------------------------------------------------------------------

step_apply_schema()
{
	# Applied to template1, so that every lane database created below is a
	# byte-identical clone.  Applying it N times to N separately-created
	# databases would be N times slower and would not guarantee identical
	# physical layout.
	log "applying schema.sql to template1"
	psql_do template1 -f "$SCHEMA_SQL" >>"$BUILD_LOG" 2>&1 \
		|| die "schema.sql failed; see $BUILD_LOG"

	# The lane half of contrib/memcow (memcow_backend_reset, the login
	# admission trigger) has to exist in every lane database, and anything
	# created in a lane at run time is overlay content that the next reset
	# discards -- the extension's own pg_proc rows included.  So it goes into
	# the seed, through template1, and it is part of the seed recipe.
	log "creating extension memcow in template1"
	psql_do template1 -c "CREATE EXTENSION memcow;" >>"$BUILD_LOG" 2>&1 \
		|| die "CREATE EXTENSION memcow failed; see $BUILD_LOG"

	if [ -n "$SCHEMA_HOOK" ]; then
		log "running MEMCOW_SEED_SCHEMA_HOOK against template1"
		PGHOST=$SOCK_DIR PGPORT=$BUILD_PORT PGUSER=$SUPERUSER PGDATABASE=template1 \
			sh -c "$SCHEMA_HOOK" >>"$BUILD_LOG" 2>&1 \
			|| die "MEMCOW_SEED_SCHEMA_HOOK failed; see $BUILD_LOG"
	fi
}

# ---------------------------------------------------------------------------
# Step 6: lane databases
# ---------------------------------------------------------------------------

step_create_databases()
{
	local i name

	# template1 must be frozen and analyzed BEFORE cloning, so the lanes
	# inherit frozen pages and planner stats instead of each needing their
	# own pass.
	log "freezing template1 before cloning"
	psql_do template1 -c 'VACUUM (FREEZE, ANALYZE);' >>"$BUILD_LOG" 2>&1 \
		|| die "vacuum of template1 failed; see $BUILD_LOG"

	# Default strategy (WAL_LOG).  FILE_COPY is forbidden at run time
	# (plan.md §6) because it bypasses smgr, but here the GUC is off and md
	# is doing the work anyway; using the default keeps the seed build on
	# the same code path a normal cluster uses.
	for i in $(seq 0 $((LANES - 1))); do
		name=$(lane_db_name "$i")
		log "creating lane database $name"
		psql_do postgres -c "CREATE DATABASE \"$name\" TEMPLATE template1;" \
			>>"$BUILD_LOG" 2>&1 || die "CREATE DATABASE $name failed; see $BUILD_LOG"
	done

	# The control database (plan.md §4: memcow_lane_reset runs on a control
	# connection that is never connected to the lane being reset; §6: its
	# database is read-mostly, because its overlay is never reset).  Cloned
	# from template0 so it carries none of the test schema -- there is
	# nothing in it for a test to accidentally depend on.
	log "creating control database $CONTROL_DB"
	psql_do postgres -c "CREATE DATABASE \"$CONTROL_DB\" TEMPLATE template0;" \
		>>"$BUILD_LOG" 2>&1 || die "CREATE DATABASE $CONTROL_DB failed; see $BUILD_LOG"
}

# ---------------------------------------------------------------------------
# Step 7: freeze everything
# ---------------------------------------------------------------------------

step_freeze()
{
	local db

	# plan.md §6 requires "autovacuum off AND a frozen seed with test
	# lifetime << autovacuum_freeze_max_age".  Freezing here is what makes
	# that precondition true; DISABLE_PAGE_SKIPPING makes it exhaustive
	# rather than visibility-map-guided.  The pass also creates the fsm and
	# vm forks, so the seed exercises more than FORKNUM main.
	for db in $(psql_do postgres -c \
		"SELECT datname FROM pg_database WHERE datallowconn ORDER BY oid;"); do
		log "vacuum (freeze, analyze) $db"
		psql_do "$db" -c \
			'VACUUM (FREEZE, ANALYZE, DISABLE_PAGE_SKIPPING);' \
			>>"$BUILD_LOG" 2>&1 || die "vacuum of $db failed; see $BUILD_LOG"
	done
}

# ---------------------------------------------------------------------------
# Step 8: checkpoint + CLEAN shutdown
# ---------------------------------------------------------------------------

step_clean_shutdown()
{
	log "checkpoint"
	psql_do postgres -c 'CHECKPOINT;' >>"$BUILD_LOG" 2>&1 \
		|| die "checkpoint failed; see $BUILD_LOG"

	log "clean shutdown (-m fast)"
	"$PG_BINDIR/pg_ctl" -D "$BUILD_DIR" -m fast -w -t 120 stop \
		>>"$BUILD_LOG" 2>&1 || die "clean shutdown failed; see $BUILD_LOG"
	server_running=0

	rm -rf "$SOCK_DIR"; SOCK_DIR=
}

# ---------------------------------------------------------------------------
# Step 8b: prune pg_wal
#
# assemble_ramdir.sh copies pg_wal into the RAM disk, so every segment the
# seed keeps is 16 MB of RAM spent at every service start.  A freshly built
# seed keeps ~8 of them: CREATE DATABASE (WAL_LOG strategy) writes a lot of
# WAL, and the shutdown checkpoint recycles rather than deletes, up to
# min_wal_size.
#
# After a CLEAN shutdown the only segment startup actually needs is the one
# holding the latest checkpoint's REDO location, which pg_control names
# outright.  Everything before it is history; everything after it is a
# recycled spare full of garbage that the server would treat as end-of-WAL
# anyway.  So keep the REDO segment plus MEMCOW_SEED_WAL_KEEP-1 following
# spares (default: one spare, so a segment switch early in a run does not
# have to create a file first) and delete the rest.  The server creates more
# on demand.
#
# This is verified, not assumed: step_verify below re-reads pg_control and
# asserts the REDO segment survived, and the seed is started and cleanly
# stopped again by the harness/proof runs.
# ---------------------------------------------------------------------------

WAL_KEEP=${MEMCOW_SEED_WAL_KEEP:-2}

step_prune_wal()
{
	local redo f base kept=0 removed=0

	redo=$(controldata_get "$BUILD_DIR" "Latest checkpoint's REDO WAL file")
	[ -n "$redo" ] || die "pg_control has no REDO WAL file; refusing to prune pg_wal"

	for f in "$BUILD_DIR"/pg_wal/*; do
		[ -f "$f" ] || continue
		base=${f##*/}
		# WAL segment file names are exactly 24 hex characters.
		[ ${#base} -eq 24 ] || continue
		case $base in
			*[!0-9A-F]*) continue ;;
		esac
		if [[ ! $base < $redo ]] && [ "$kept" -lt "$WAL_KEEP" ]; then
			kept=$((kept + 1))
			continue
		fi
		rm -f "$f"
		removed=$((removed + 1))
	done

	[ "$kept" -ge 1 ] || die "pg_wal prune would have removed the REDO segment $redo"
	log "pruned pg_wal: kept $kept segment(s) from $redo, removed $removed"
}

# ---------------------------------------------------------------------------
# Step 9: strip caches, emit the fingerprint
# ---------------------------------------------------------------------------

step_write_fingerprint()
{
	local fp=$BUILD_DIR/$FINGERPRINT_BASENAME

	# pg_internal.init is a per-database relcache cache file.  Appendix C
	# has reset unlink it because a stale one can seed a connection with a
	# previous epoch's nailed-catalog state; removing it from the seed as
	# well keeps the seed byte-reproducible (its contents depend on cache
	# eviction order) and costs one relcache build per fresh database.
	find "$BUILD_DIR" -name pg_internal.init -type f -delete

	# pg_ctl leaves postmaster.opts behind after a clean shutdown.  It
	# records this build's command line, which is meaningless at run time --
	# and removing it here is what lets seed_is_current() use its presence
	# as the "someone started this seed" signal.
	rm -f "$BUILD_DIR/postmaster.opts"

	log "writing $FINGERPRINT_BASENAME"
	{
		printf 'memcow_seed_fingerprint_version=%s\n' "$FINGERPRINT_VERSION"
		printf 'pg_version=%s\n'                "$(cat "$BUILD_DIR/PG_VERSION")"
		printf 'pg_control_version=%s\n'        "$(controldata_get "$BUILD_DIR" 'pg_control version number')"
		printf 'catalog_version_no=%s\n'        "$(controldata_get "$BUILD_DIR" 'Catalog version number')"
		printf 'block_size=%s\n'                "$(controldata_get "$BUILD_DIR" 'Database block size')"
		printf 'relseg_blocks=%s\n'             "$(controldata_get "$BUILD_DIR" 'Blocks per segment of large relation')"
		printf 'wal_block_size=%s\n'            "$(controldata_get "$BUILD_DIR" 'WAL block size')"
		printf 'wal_segment_bytes=%s\n'         "$(controldata_get "$BUILD_DIR" 'Bytes per WAL segment')"
		printf 'data_page_checksum_version=%s\n' "$(controldata_get "$BUILD_DIR" 'Data page checksum version')"
		printf 'memcow_module_bytes=%s\n' "$MEMCOW_MODULE_BYTES"
		printf 'postgres_binary_bytes=%s\n'     "$PG_BINARY_BYTES"
		printf 'postgres_binary_sha256=%s\n'    "$PG_BINARY_SHA256"
		printf 'seed_recipe_sha256=%s\n'        "$RECIPE_SHA256"
		printf 'seed_lane_count=%s\n'           "$LANES"
		printf 'seed_superuser=%s\n'            "$SUPERUSER"
	} >"$fp"
	chmod 0600 "$fp"

	# The C reader reads it into a fixed stack buffer; make that safe.
	[ "$(file_bytes "$fp")" -lt 512 ] || die "fingerprint file exceeds the 512-byte contract"
}

# ---------------------------------------------------------------------------
# Step 10: verify
# ---------------------------------------------------------------------------

step_verify()
{
	local state

	local redo

	state=$(controldata_get "$BUILD_DIR" 'Database cluster state')
	[ "$state" = "shut down" ] || \
		die "seed cluster state is '$state', expected 'shut down' (see the clean-shutdown note at the top of this script)"
	log "verified: pg_control state = 'shut down'"

	redo=$(controldata_get "$BUILD_DIR" "Latest checkpoint's REDO WAL file")
	[ -f "$BUILD_DIR/pg_wal/$redo" ] || \
		die "pg_wal is missing the REDO segment $redo after pruning"
	log "verified: REDO segment $redo present"

	[ -f "$BUILD_DIR/global/pg_filenode.map" ] || \
		die "seed has no global/pg_filenode.map"
	log "verified: pg_filenode.map present ($(find "$BUILD_DIR" -name pg_filenode.map | wc -l | tr -d ' ') copies, one per database + global)"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

step_validate_build

if [ "$FORCE" = 0 ] && seed_is_current; then
	log "seed at $SEED_DIR is up to date (binary + recipe fingerprint match, cleanly shut down); nothing to do"
	log "use -f to rebuild"
	exit 0
fi

if [ -e "$SEED_DIR" ]; then
	log "existing seed is stale or -f given; removing $SEED_DIR"
	safe_rmtree "$SEED_DIR"
fi
safe_rmtree "$BUILD_DIR"

mkdir -p "$(dirname "$SEED_DIR")"
: >"$BUILD_LOG"

step_force_memcow_guc_off
step_initdb
step_start_server
step_apply_schema
step_create_databases
if [ -n "$VERIFY_HOOK" ]; then
	PGHOST=$SOCK_DIR PGPORT=$BUILD_PORT PGUSER=$SUPERUSER PGDATABASE=postgres \
		MEMCOW_SEED_LANES=$LANES sh -c "$VERIFY_HOOK" >>"$BUILD_LOG" 2>&1 \
		|| die "MEMCOW_SEED_VERIFY_HOOK failed; see $BUILD_LOG"
fi
step_freeze
step_clean_shutdown
step_prune_wal
step_write_fingerprint
step_verify

# Publish atomically: a reader either sees no seed or sees a complete one.
mv "$BUILD_DIR" "$SEED_DIR"

log "seed ready: $SEED_DIR ($(du -sh "$SEED_DIR" | awk '{print $1}'))"
[ "$QUIET" = 1 ] || sed 's/^/[build_seed]   /' "$SEED_DIR/$FINGERPRINT_BASENAME" >&2
exit 0
