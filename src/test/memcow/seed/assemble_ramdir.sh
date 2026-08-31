#!/bin/bash
#
# src/test/memcow/seed/assemble_ramdir.sh
#
# Assemble the RAM-backed runtime PGDATA for the memcow ephemeral test engine
# (plan.md §3 step 2).
#
# Given a seed built by build_seed.sh, this:
#
#     1. attaches a RAM disk and mounts it            (macOS: hdiutil + newfs_hfs)
#     2. mirrors the seed's directory tree into <mount>/pgdata
#     3. copies every NON-relation file across; relation-fork segment files are
#        left behind in the seed, where memcow will mmap them PROT_READ
#     4. appends the runtime settings block: fsync=off, bounded max_wal_size,
#        temp_file_limit, plus the plan.md §6 preconditions
#
# It does NOT start a postmaster and it does NOT turn the memcow GUC on --
# both belong to the harness.
#
# ---------------------------------------------------------------------------
# What counts as a "relation file"
# ---------------------------------------------------------------------------
# md.c names relation forks <relnumber>[_fsm|_vm|_init][.segno].  Those names
# only mean that inside base/<db>/, global/, and a tablespace's version
# directory; elsewhere in PGDATA the same shapes are ordinary data (pg_xact
# segments are literally named "0000").  So the skip rule is scoped to those
# directories, and everything else -- pg_control, pg_filenode.map, PG_VERSION,
# the confs, pg_wal, pg_xact, pg_multixact, pg_subtrans, pg_commit_ts,
# pg_logical, pg_stat -- is copied.
#
# ---------------------------------------------------------------------------
# macOS RAM disk
# ---------------------------------------------------------------------------
# There is no tmpfs on macOS and /tmp is on the boot APFS volume, i.e. it is
# NOT RAM-backed.  The mechanism used here is the standard one:
#
#     hdiutil attach -nomount ram://<sectors>   -> /dev/diskN, 512-byte sectors
#     newfs_hfs -v <volname> /dev/diskN         -> non-journaled HFS+
#     diskutil mount -mountPoint <dir> /dev/diskN
#     hdiutil detach /dev/diskN                 -> unmount + free the memory
#
# None of that needs sudo.  `diskutil mount -mountPoint` is used instead of
# letting it auto-mount under /Volumes so the path is short (the unix socket
# lives in PGDATA and macOS caps sockaddr_un at 104 bytes) and so the volume
# does not show up in Finder.
#
# The RAM-backing is PROVABLE, not assumed: `hdiutil info` prints
# `image-path : ram://<sectors>` for exactly these devices, and --status (and
# the assemble path itself) verifies the mounted device appears under a
# ram:// image before it will use it.  If that check fails the script exits
# non-zero rather than quietly writing to disk.
#
# Non-journaled HFS+ is deliberate: journaling on a volume whose entire point
# is to be volatile is pure overhead.
#
# ---------------------------------------------------------------------------
# Sizing
# ---------------------------------------------------------------------------
# Default 1024 MB.  Budget:
#     non-relation copy from the seed        ~40 MB (dominated by pg_wal)
#     WAL steady state                       <= max_wal_size (256 MB) + slack
#     temp spills                            <= temp_file_limit (256 MB)/session
#     pgsql_tmp orphaned by killed stragglers  slack (plan.md §7 open item)
# The overlay arenas do NOT live here: they are DSA over dynamic shared
# memory, and dynamic_shared_memory_type is pinned to posix below so they
# stay in kernel shm rather than becoming files under pg_dynshmem.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   assemble_ramdir.sh [-s SEEDDIR] [-m MOUNT] [-z MB] [-p PORT] [-b BINDIR] [-R] [-f]
#   assemble_ramdir.sh --detach [-m MOUNT] [-f]
#   assemble_ramdir.sh --status [-m MOUNT]
#
#   -s SEEDDIR   seed PGDATA        (default $MEMCOW_SEED_DIR    or /opt/p/postgres-memcow/seed)
#   -m MOUNT     RAM-disk mount pt  (default $MEMCOW_RAM_MOUNT   or /opt/p/postgres-memcow/ram)
#   -z MB        RAM-disk size, MB  (default $MEMCOW_RAMDISK_MB  or 1024)
#   -p PORT      port to write into postgresql.conf (default $MEMCOW_PORT or 5599)
#   -b BINDIR    bindir, for pg_controldata         (default $MEMCOW_BINDIR or
#                                                    /opt/p/postgres-install/bin)
#   -R, --with-relations
#                ALSO copy the relation files in, producing a startable stock
#                cluster in RAM.  Phase 0 only: until memcow exists nothing
#                serves relation blocks out of the seed, so this is the only
#                way to boot the assembled directory.  Costs the seed's full
#                size in RAM.
#   -f           force: re-assemble over an existing ram dir, and on --detach
#                stop a postmaster that is still running on it
#   --detach     unmount and free the RAM disk
#   --status     report whether the mount point is a live, RAM-backed volume
#
# Idempotent: a second assemble reuses an already-attached RAM disk of the
# right size at the same mount point and rebuilds <mount>/pgdata inside it.
#
set -euo pipefail

SEED_DIR=${MEMCOW_SEED_DIR:-/opt/p/postgres-memcow/seed}
RAM_MOUNT=${MEMCOW_RAM_MOUNT:-/opt/p/postgres-memcow/ram}
RAMDISK_MB=${MEMCOW_RAMDISK_MB:-1024}
PG_BINDIR=${MEMCOW_BINDIR:-/opt/p/postgres-install/bin}
PGPORT_SETTING=${MEMCOW_PORT:-5599}
VOLNAME=${MEMCOW_RAM_VOLNAME:-memcow_ram}
FORCE=0
MODE=assemble
WITH_RELATIONS=0

# Runtime settings knobs (see the generated block for what each is for).
MAX_WAL_SIZE=${MEMCOW_MAX_WAL_SIZE:-256MB}
MIN_WAL_SIZE=${MEMCOW_MIN_WAL_SIZE:-64MB}
TEMP_FILE_LIMIT=${MEMCOW_TEMP_FILE_LIMIT:-256MB}
SHARED_BUFFERS=${MEMCOW_SHARED_BUFFERS:-128MB}
MAX_CONNECTIONS=${MEMCOW_MAX_CONNECTIONS:-200}
WAL_LEVEL=${MEMCOW_WAL_LEVEL:-replica}

MEMCOW_GUC_NAME=${MEMCOW_GUC_NAME:-memcow_enabled}

MARKER_BASENAME=.memcow_ramdir
CONF_BEGIN='# --- BEGIN memcow runtime settings (assemble_ramdir.sh; generated) ---'
CONF_END='# --- END memcow runtime settings ---'

# --detach / --status are long options; peel them off before getopts.
args=()
for a in "$@"; do
	case $a in
		--detach) MODE=detach ;;
		--status) MODE=status ;;
		--with-relations) WITH_RELATIONS=1 ;;
		--help)   awk '/^set -euo pipefail/{exit} NR>1' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)        args+=("$a") ;;
	esac
done
set -- ${args+"${args[@]}"}

while getopts 's:m:z:p:b:Rfh' opt; do
	case $opt in
		s) SEED_DIR=$OPTARG ;;
		m) RAM_MOUNT=$OPTARG ;;
		z) RAMDISK_MB=$OPTARG ;;
		p) PGPORT_SETTING=$OPTARG ;;
		b) PG_BINDIR=$OPTARG ;;
		R) WITH_RELATIONS=1 ;;
		f) FORCE=1 ;;
		h) awk '/^set -euo pipefail/{exit} NR>1' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "usage: $0 [-s SEEDDIR] [-m MOUNT] [-z MB] [-p PORT] [-b BINDIR] [-R] [-f] [--detach|--status]" >&2
		   exit 2 ;;
	esac
done

case $RAM_MOUNT in /*) ;; *) RAM_MOUNT=$PWD/$RAM_MOUNT ;; esac
case $SEED_DIR  in /*) ;; *) SEED_DIR=$PWD/$SEED_DIR ;; esac
RAM_MOUNT=${RAM_MOUNT%/}

PGDATA_DIR=$RAM_MOUNT/pgdata
MARKER=$RAM_MOUNT/$MARKER_BASENAME

log() { printf '[assemble_ramdir] %s\n' "$*" >&2; }
die() { printf '[assemble_ramdir] ERROR: %s\n' "$*" >&2; exit 1; }

case $(uname -s) in
	Darwin) ;;
	*) die "this script implements the macOS RAM-disk path only (uname=$(uname -s)); on Linux use tmpfs and skip the attach/detach steps" ;;
esac

# ---------------------------------------------------------------------------
# RAM-disk primitives
# ---------------------------------------------------------------------------

# Print the /dev/diskN currently mounted at $1, but ONLY if hdiutil says that
# device belongs to a ram:// image.  Empty output means "not a RAM disk of
# ours" -- which is the fail-closed answer everywhere it is used.
ram_dev_for_mount()
{
	hdiutil info 2>/dev/null | awk -v mp="$1" '
		/^=+$/            { isram = 0; next }
		/^image-path/     { isram = ($0 ~ /ram:\/\//); next }
		isram && /^\/dev\// {
			dev = $1
			n = split($0, f, "\t")
			mnt = ""
			for (i = n; i >= 1; i--)
				if (f[i] != "") { mnt = f[i]; break }
			if (mnt == dev)
				mnt = ""
			if (mnt == mp) { print dev; exit }
		}'
}

ramdisk_size_mb()
{
	# $1 = /dev/diskN
	hdiutil info 2>/dev/null | awk -v want="$1" '
		/^=+$/        { sectors = 0; isram = 0; next }
		/^image-path/ { isram = ($0 ~ /ram:\/\//); next }
		/^blockcount/ { sectors = $3; next }
		isram && $1 == want { printf "%d\n", sectors / 2048; exit }'
}

ramdisk_attach()
{
	local sectors dev

	sectors=$((RAMDISK_MB * 2048))    # 512-byte sectors
	log "attaching ram://$sectors (${RAMDISK_MB} MB)"
	dev=$(hdiutil attach -nomount "ram://$sectors" | awk 'NR==1 {print $1}')
	[ -n "$dev" ] || die "hdiutil attach failed"

	# Non-journaled HFS+.  A journal on a volatile volume is pure overhead.
	newfs_hfs -v "$VOLNAME" "$dev" >/dev/null \
		|| { hdiutil detach "$dev" >/dev/null 2>&1 || true; die "newfs_hfs failed on $dev"; }

	mkdir -p "$RAM_MOUNT"
	diskutil mount -mountPoint "$RAM_MOUNT" "$dev" >/dev/null \
		|| { hdiutil detach "$dev" >/dev/null 2>&1 || true; die "diskutil mount failed for $dev at $RAM_MOUNT"; }

	# Fail closed: only proceed if the thing we just mounted really is a
	# ram:// image at the path we expect.
	[ "$(ram_dev_for_mount "$RAM_MOUNT")" = "$dev" ] \
		|| die "mounted $dev at $RAM_MOUNT but hdiutil does not report it as RAM-backed"

	RAM_DEV=$dev
	log "attached $dev at $RAM_MOUNT (RAM-backed, verified via hdiutil info)"
}

postmaster_pid_on_ramdir()
{
	local pid
	[ -f "$PGDATA_DIR/postmaster.pid" ] || return 1
	pid=$(head -1 "$PGDATA_DIR/postmaster.pid" 2>/dev/null || true)
	case $pid in ''|*[!0-9]*) return 1 ;; esac
	kill -0 "$pid" 2>/dev/null || return 1
	printf '%s\n' "$pid"
}

# ---------------------------------------------------------------------------
# --status
# ---------------------------------------------------------------------------

do_status()
{
	local dev

	dev=$(ram_dev_for_mount "$RAM_MOUNT")
	if [ -z "$dev" ]; then
		log "no RAM-backed volume mounted at $RAM_MOUNT"
		if mount | grep -q " on $RAM_MOUNT "; then
			log "WARNING: something IS mounted there, but it is not a ram:// image:"
			mount | grep " on $RAM_MOUNT " >&2
		fi
		return 1
	fi

	printf 'device     %s\n' "$dev"
	printf 'mount      %s\n' "$RAM_MOUNT"
	printf 'pgdata     %s\n' "$PGDATA_DIR"
	printf 'ram_backed yes (hdiutil image-path is ram://)\n'
	printf 'size_mb    %s\n' "$(ramdisk_size_mb "$dev")"
	df -h "$RAM_MOUNT" | sed 's/^/df         /'
	mount | grep " on $RAM_MOUNT " | sed 's/^/mount      /'
	[ -f "$MARKER" ] && sed 's/^/marker     /' "$MARKER"
	return 0
}

# ---------------------------------------------------------------------------
# --detach
# ---------------------------------------------------------------------------

do_detach()
{
	local dev pid

	dev=$(ram_dev_for_mount "$RAM_MOUNT")
	if [ -z "$dev" ]; then
		log "nothing RAM-backed mounted at $RAM_MOUNT; nothing to detach"
		[ -d "$RAM_MOUNT" ] && rmdir "$RAM_MOUNT" 2>/dev/null || true
		return 0
	fi

	if pid=$(postmaster_pid_on_ramdir); then
		if [ "$FORCE" = 1 ]; then
			log "stopping postmaster pid $pid (-f)"
			"$PG_BINDIR/pg_ctl" -D "$PGDATA_DIR" -m immediate -w stop >/dev/null 2>&1 || true
		else
			die "a postmaster (pid $pid) is still running on $PGDATA_DIR; stop it or re-run with -f"
		fi
	fi

	log "detaching $dev"
	if ! hdiutil detach "$dev" >/dev/null 2>&1; then
		log "clean detach failed, retrying with -force"
		hdiutil detach -force "$dev" >/dev/null || die "could not detach $dev"
	fi
	rmdir "$RAM_MOUNT" 2>/dev/null || true
	log "detached; RAM released"
}

# ---------------------------------------------------------------------------
# assemble
# ---------------------------------------------------------------------------

check_seed()
{
	local state

	[ -d "$SEED_DIR" ]                || die "seed '$SEED_DIR' does not exist (run build_seed.sh)"
	[ -f "$SEED_DIR/PG_VERSION" ]     || die "seed '$SEED_DIR' is not a PGDATA"
	[ -f "$SEED_DIR/memcow_seed.fingerprint" ] \
		|| die "seed '$SEED_DIR' has no memcow_seed.fingerprint (build it with build_seed.sh)"
	[ -x "$PG_BINDIR/pg_controldata" ] || die "missing $PG_BINDIR/pg_controldata"

	# Fail closed on a crash-shutdown seed: at run time the relation files
	# are mmapped read-only out of the seed and are not even present in the
	# RAM dir, so a cluster that wanted to redo WAL into them could not.
	state=$(LC_ALL=C "$PG_BINDIR/pg_controldata" -D "$SEED_DIR" \
		| sed -n 's/^Database cluster state: *//p' | head -1)
	[ "$state" = "shut down" ] \
		|| die "seed cluster state is '$state', not 'shut down'; rebuild it with build_seed.sh"

	[ -f "$SEED_DIR/postmaster.pid" ] && die "seed '$SEED_DIR' has a postmaster.pid; it is in use"
	return 0
}

# Is $1 (a path relative to PGDATA, e.g. ./base/16729/1259_vm) an md relation
# fork segment?
is_relation_file()
{
	local rel=$1 base

	case $rel in
		./base/*/*|./global/*|./pg_tblspc/*/*/*/*) ;;
		*) return 1 ;;
	esac
	base=${rel##*/}
	[[ $base =~ ^[0-9]+(_fsm|_vm|_init)?(\.[0-9]+)?$ ]]
}

# Phase 0 escape hatch.  Until memcow exists there is nothing to serve the
# relation blocks out of the seed, so the assembled directory is not a
# startable cluster.  --with-relations copies them in too, producing an
# ordinary stock cluster that happens to live in RAM.  That is what makes the
# assembled tree and the generated postgresql.conf testable today; it is NOT
# how the engine runs (plan.md §3.2 leaves the relation files in the seed and
# mmaps them PROT_READ), and it costs the size of the whole seed in RAM.
copy_relation_files()
{
	local rel copied=0

	log "--with-relations: copying relation files too (Phase 0 smoke-test mode)"
	while IFS= read -r rel; do
		is_relation_file "$rel" || continue
		cp -p "$SEED_DIR/${rel#./}" "$PGDATA_DIR/${rel#./}"
		copied=$((copied + 1))
	done < <(cd "$SEED_DIR" && find . -type f -print)
	log "--with-relations: copied $copied relation files"
}

copy_nonrelation_files()
{
	local rel dst copied=0 skipped=0 bytes=0

	log "mirroring directory tree"
	while IFS= read -r rel; do
		mkdir -p "$PGDATA_DIR/${rel#./}"
	done < <(cd "$SEED_DIR" && find . -type d -print)

	log "copying non-relation files"
	while IFS= read -r rel; do
		case ${rel##*/} in
			postmaster.pid|postmaster.opts|pg_internal.init|current_logfiles)
				skipped=$((skipped + 1)); continue ;;
		esac
		if is_relation_file "$rel"; then
			skipped=$((skipped + 1))
			continue
		fi
		dst=$PGDATA_DIR/${rel#./}
		cp -p "$SEED_DIR/${rel#./}" "$dst"
		copied=$((copied + 1))
	done < <(cd "$SEED_DIR" && find . -type f -print)

	chmod 0700 "$PGDATA_DIR"
	chmod -R go-rwx "$PGDATA_DIR"

	bytes=$(du -sk "$PGDATA_DIR" | awk '{print $1}')
	log "copied $copied files (${bytes} KB), left $skipped relation/cache files in the seed"
}

write_runtime_conf()
{
	local conf=$PGDATA_DIR/postgresql.conf
	local senders=10

	# The seed's postgresql.conf must not be able to turn memcow off (or on):
	# that is the harness's decision, made on the postmaster command line.
	if grep -qE "^[[:space:]]*$MEMCOW_GUC_NAME[[:space:]]*=" "$conf" 2>/dev/null; then
		log "neutralising a $MEMCOW_GUC_NAME setting inherited from the seed's postgresql.conf"
		sed -i.memcowbak -E "s/^([[:space:]]*$MEMCOW_GUC_NAME[[:space:]]*=)/#inherited-from-seed# \\1/" "$conf"
		rm -f "$conf.memcowbak"
	fi

	# wal_level = minimal is incompatible with walsenders.
	[ "$WAL_LEVEL" = minimal ] && senders=0

	log "appending runtime settings block to postgresql.conf"
	cat >>"$conf" <<EOF

$CONF_BEGIN
# plan.md §3.2: RAM-backed PGDATA, fsync off, bounded WAL and temp files.
# Everything here is regenerated on every assemble; edit the script, not this.

# --- durability: irrelevant, the whole volume is volatile ---
fsync = off
full_page_writes = off
synchronous_commit = off
wal_recycle = off			# no point recycling on a RAM disk
wal_init_zero = off			# ... or pre-zeroing 16 MB of it

# --- bounded RAM consumers (plan.md A.3: WAL write failure is a PANIC, so
# --- these bounds are what keep the RAM disk from filling) ---
wal_level = $WAL_LEVEL
max_wal_senders = $senders
max_wal_size = $MAX_WAL_SIZE
min_wal_size = $MIN_WAL_SIZE
temp_file_limit = '$TEMP_FILE_LIMIT'

# --- plan.md §6 preconditions, fail-closed where the GUC allows ---
max_prepared_transactions = 0
autovacuum = off
restart_after_crash = off		# a crash must not silently re-enter
					# recovery against a read-only seed

# --- keep the overlay arenas in kernel shm, not in files under pg_dynshmem
# --- on this RAM disk (plan.md §7.2 watches DSM slot churn on macOS) ---
dynamic_shared_memory_type = posix

# --- sizing / connectivity ---
shared_buffers = $SHARED_BUFFERS
max_connections = $MAX_CONNECTIONS
listen_addresses = ''
unix_socket_directories = '$PGDATA_DIR'
port = $PGPORT_SETTING

# --- logging: stderr, captured by whoever starts the postmaster ---
logging_collector = off
log_destination = 'stderr'
log_min_messages = warning
log_checkpoints = on
log_line_prefix = '%m [%p] %q%u@%d '
$CONF_END
EOF
}

write_marker()
{
	cat >"$MARKER" <<EOF
seed=$SEED_DIR
pgdata=$PGDATA_DIR
device=$RAM_DEV
size_mb=$RAMDISK_MB
port=$PGPORT_SETTING
assembled_by=$0
EOF
}

do_assemble()
{
	local dev existing_mb pid

	check_seed

	dev=$(ram_dev_for_mount "$RAM_MOUNT")
	if [ -n "$dev" ]; then
		if pid=$(postmaster_pid_on_ramdir); then
			[ "$FORCE" = 1 ] || die "a postmaster (pid $pid) is running on $PGDATA_DIR; stop it or re-run with -f"
			log "stopping postmaster pid $pid (-f)"
			"$PG_BINDIR/pg_ctl" -D "$PGDATA_DIR" -m immediate -w stop >/dev/null 2>&1 || true
		fi
		existing_mb=$(ramdisk_size_mb "$dev")
		if [ "$existing_mb" != "$RAMDISK_MB" ]; then
			log "existing RAM disk at $RAM_MOUNT is ${existing_mb} MB, want ${RAMDISK_MB} MB; recreating"
			do_detach
			ramdisk_attach
		else
			log "reusing RAM disk $dev at $RAM_MOUNT (${existing_mb} MB)"
			RAM_DEV=$dev
			rm -rf "${PGDATA_DIR:?}"
		fi
	else
		if mount | grep -q " on $RAM_MOUNT "; then
			die "$RAM_MOUNT has something mounted on it that is not a ram:// image; refusing to use it"
		fi
		if [ -d "$RAM_MOUNT" ] && [ -n "$(ls -A "$RAM_MOUNT" 2>/dev/null)" ]; then
			die "$RAM_MOUNT exists, is not a mount point, and is not empty; refusing to use it"
		fi
		ramdisk_attach
	fi

	mkdir -p "$PGDATA_DIR"
	copy_nonrelation_files
	[ "$WITH_RELATIONS" = 1 ] && copy_relation_files
	write_runtime_conf
	write_marker

	log "ram dir ready"
	printf 'MEMCOW_SEED_DIR=%s\n'  "$SEED_DIR"
	printf 'MEMCOW_RAM_MOUNT=%s\n' "$RAM_MOUNT"
	printf 'PGDATA=%s\n'           "$PGDATA_DIR"
	printf 'PGHOST=%s\n'           "$PGDATA_DIR"
	printf 'PGPORT=%s\n'           "$PGPORT_SETTING"
}

RAM_DEV=

case $MODE in
	status)   do_status ;;
	detach)   do_detach ;;
	assemble) do_assemble ;;
esac
