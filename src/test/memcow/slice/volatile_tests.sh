#!/usr/bin/env bash
#
# volatile_tests.sh --- slice tests for volatile_data_directory.
#
# A volatile_data_directory postmaster runs with the immutable seed itself as
# its data directory and writes nothing below it: relation pages live in the
# memcow overlay, WAL and SLRU pages in memory, pg_control in shared memory,
# and there is no lock file, so any number of postmasters can share one seed.
# Each case below drives such a server (harness/common.sh mc_volatile_start)
# against the seed built by seed/build_seed.sh.
#
#   V0  prerequisites          the mode refuses every setting that would write
#   V1  no relation WAL        DML, DDL and index builds log only commits
#   V2  volatile WAL           WAL crosses segments; pg_wal never changes
#   V3  no checkpoints         CHECKPOINT and shutdown leave pg_control alone
#   V4  memory SLRUs           evicted SLRU pages survive; no segment changes
#   V5  shared image           four postmasters on one seed, no file written
#   V6  temp files, refusals   spills and DataDir-writing commands are errors
#
# Every case has a negative control (--negative-control).  Where the property
# is "the mode prevents a write", the control runs the same workload on an
# ordinary memcow server over a writable copy of the seed and requires the
# write to happen, proving the instrument can see it.
#
# Usage:
#   volatile_tests.sh --seed DIR [--build-dir DIR] [--outputdir DIR]
#                     [--case NAME ...] [--negative-control] [--stop-on-fail]
#   volatile_tests.sh --list
#
# The seed may be on a read-only filesystem (see volatile_readonly.sh); cases
# that need a writable copy take it from --outputdir.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

# Cases and their helper functions are dispatched by name in the driver.
# shellcheck disable=SC2329
set -o pipefail

MC_PROG=volatile_tests.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HARNESS=$(cd -- "$HERE/../harness" && pwd)
# shellcheck source=../harness/common.sh
. "$HARNESS/common.sh"

ALL_CASES="V0_prerequisites V1_no_relation_wal V2_volatile_wal V3_no_checkpoints V4_memory_slrus V5_shared_image V6_refusals"

SEED=
BUILD_DIR=
OUTPUTDIR=
DB=memcow_lane_00
CASES=()
NEGATIVE=0
STOP_ON_FAIL=0

while [ $# -gt 0 ]; do
	case $1 in
		--seed)        SEED=$2; shift 2 ;;
		--build-dir)   BUILD_DIR=$2; shift 2 ;;
		--outputdir)   OUTPUTDIR=$2; shift 2 ;;
		--case)        CASES[${#CASES[@]}]=$2; shift 2 ;;
		--list)        printf '%s\n' "$ALL_CASES" | tr ' ' '\n'; exit 0 ;;
		--negative-control) NEGATIVE=1; shift ;;
		--stop-on-fail) STOP_ON_FAIL=1; shift ;;
		-h|--help)     sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)             mc_die "unknown option: $1" ;;
	esac
done

[ -n "$SEED" ] || mc_die "--seed is required"
SEED=$(mc_abspath "$SEED")
[ -f "$SEED/memcow_seed.fingerprint" ] ||
	mc_die "no memcow_seed.fingerprint in $SEED -- not a seed built by build_seed.sh"

[ -n "$BUILD_DIR" ] || BUILD_DIR=$(mc_default_build_dir) ||
	mc_die "cannot find a meson build dir; pass --build-dir or set MEMCOW_BUILD_DIR"
mc_resolve_build "$BUILD_DIR"

: "${OUTPUTDIR:=$(dirname -- "$SEED")/volatile-out}"
mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")
case $OUTPUTDIR/ in
	"$SEED"/*) mc_die "--outputdir must not be inside the seed" ;;
esac

[ ${#CASES[@]} -gt 0 ] || read -r -a CASES <<<"$ALL_CASES"
for c in "${CASES[@]}"; do
	case " $ALL_CASES " in
		*" $c "*) ;;
		*) mc_die "unknown case: $c (see --list)" ;;
	esac
done

LOGFILE="$OUTPUTDIR/postmaster.log"
PIDFILE="$OUTPUTDIR/postmaster.pid"
PORT=$(mc_free_port) || mc_die "cannot find a free port"

# ---------------------------------------------------------------------------
# server control
# ---------------------------------------------------------------------------

# vstart [GUC=VAL ...] --- (re)start the volatile server on the seed.
vstart()
{
	vstop
	: >"$LOGFILE"
	mc_volatile_start "$SEED" "$PORT" "$LOGFILE" "$PIDFILE" "$@"
}
vstop() { mc_volatile_stop "$PIDFILE" "${1:-INT}"; }

# vpsql [-p PORT] [-d DB] SQL... --- tuples-only, errors folded into stdout.
vpsql()
{
	local port=$PORT db=$DB
	while :; do
		case $1 in
			-p) port=$2; shift 2 ;;
			-d) db=$2; shift 2 ;;
			*) break ;;
		esac
	done
	"$MC_BINDIR/psql" -X -q -A -t -h 127.0.0.1 -p "$port" -d "$db" -U "${PGUSER:-postgres}" \
		-v ON_ERROR_STOP=0 "$@" 2>&1
}

# vfails GUC=VAL... --- start with the given settings, which must be refused.
# Prints the server's log; returns 0 if the postmaster exited without ever
# accepting connections.
vfails()
{
	vstop
	: >"$LOGFILE"
	if mc_volatile_start "$SEED" "$PORT" "$LOGFILE" "$PIDFILE" "$@"; then
		vstop
		return 1
	fi
	rm -f "$PIDFILE"
	cat "$LOGFILE"
	return 0
}

# ---------------------------------------------------------------------------
# the stock control: the same workload, the mode off
#
# An ordinary memcow server over a writable copy of the seed, laid out the way
# assemble_ramdir.sh lays out a runtime: relation pages still come from the
# seed, everything else goes to the copy.  A negative control proves its
# instrument by watching the copy change.
# ---------------------------------------------------------------------------

STOCK=$OUTPUTDIR/stock

stock_start()
{
	vstop
	stock_stop
	rm -rf "$STOCK" && cp -Rp "$SEED" "$STOCK" && chmod -R u+w "$STOCK" || return 1
	: >"$LOGFILE"
	"$MC_BINDIR/pg_ctl" -D "$STOCK" -l "$LOGFILE" -w -t 120 -o "-c port=$PORT \
		-c listen_addresses=127.0.0.1 -c unix_socket_directories= \
		-c shared_preload_libraries=memcow -c memcow.enabled=on \
		-c memcow.seed_directory=$SEED -c wal_level=minimal -c max_wal_senders=0 \
		-c max_prepared_transactions=0 -c fsync=off -c log_min_messages=warning \
		$*" start >/dev/null
}

stock_stop()
{
	[ -f "$STOCK/postmaster.pid" ] || return 0
	"$MC_BINDIR/pg_ctl" -D "$STOCK" -m "${1:-fast}" -w -t 120 stop >/dev/null 2>&1
}

# manifest DIR SUBTREE... --- the lines of mc_seed_manifest under SUBTREEs.
manifest()
{
	local dir=$1 all
	shift
	all=$(mktemp "$OUTPUTDIR/manifest.XXXXXX")
	mc_seed_manifest "$dir" "$all"
	if [ $# -eq 0 ]; then
		cat "$all"
	else
		local sub
		for sub in "$@"; do
			grep -E " $sub(/|\$)" "$all"
		done
	fi
	rm -f "$all"
}

control_value() # control_value DIR LABEL --- one pg_controldata field
{
	LC_ALL=C "$MC_BINDIR/pg_controldata" -D "$1" | sed -n "s/^$2: *//p"
}

# ---------------------------------------------------------------------------
# assertion helpers (as in slice_tests.sh)
# ---------------------------------------------------------------------------

CASE_FAIL=0

ck()
{
	if [ "$2" -eq 0 ]; then
		printf '    ok      %s\n' "$1"
	else
		printf '    NOT OK  %s\n' "$1"
		CASE_FAIL=1
	fi
}

ck_eq()
{
	if [ "$2" = "$3" ]; then
		printf '    ok      %s (= %s)\n' "$1" "$2"
	else
		printf '    NOT OK  %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
		CASE_FAIL=1
	fi
}

ck_match()
{
	if printf '%s' "$3" | grep -Eq "$2"; then
		printf '    ok      %s\n' "$1"
	else
		printf '    NOT OK  %s: no match for /%s/ in:\n' "$1" "$2"
		printf '%s\n' "$3" | tail -20 | sed 's/^/              /'
		CASE_FAIL=1
	fi
}

ck_nomatch()
{
	if printf '%s' "$3" | grep -Eq "$2"; then
		printf '    NOT OK  %s: unexpected match for /%s/ in:\n' "$1" "$2"
		printf '%s\n' "$3" | tail -20 | sed 's/^/              /'
		CASE_FAIL=1
	else
		printf '    ok      %s\n' "$1"
	fi
}

ck_no_crash()
{
	local hits
	if hits=$(mc_check_log "$LOGFILE"); then
		printf '    ok      no asserts, PANICs, signal deaths or leaks in the server log\n'
	else
		printf '    NOT OK  server log shows an assert/crash/leak:\n'
		printf '%s\n' "$hits" | sed 's/^/              /'
		CASE_FAIL=1
	fi
}

# ===========================================================================
# V0 --- prerequisites
#
# Each setting below would make a volatile server write below DataDir or
# outside memory, so the postmaster must refuse it before creating anything.
# The control starts with the baseline settings, which must be accepted.
# ===========================================================================

V0_REFUSALS=(
	'memcow.enabled=off|a volatile default storage manager'
	'wal_level=replica|"wal_level" = minimal'
	'max_prepared_transactions=2|"max_prepared_transactions" = 0'
	'shared_memory_type=sysv|"shared_memory_type" = mmap'
	'dynamic_shared_memory_type=mmap|"dynamic_shared_memory_type" other than mmap'
	"unix_socket_directories=$OUTPUTDIR|empty \"unix_socket_directories\""
	'logging_collector=on|"logging_collector" = off'
	"external_pid_file=$OUTPUTDIR/external.pid|\"external_pid_file\" to be unset"
)

V0_prerequisites()
{
	local entry setting want out
	for entry in "${V0_REFUSALS[@]}"; do
		setting=${entry%%|*}
		want=${entry#*|}
		if out=$(vfails "$setting"); then
			ck_match "$setting is refused" "FATAL: +\"volatile_data_directory\" requires $want" "$out"
		else
			ck "$setting is refused" 1
		fi
	done

	out=$(LC_ALL=C "$MC_BINDIR/postgres" --single -D "$SEED" \
		-c volatile_data_directory=on postgres </dev/null 2>&1)
	ck_match "single-user mode is refused" 'requires a postmaster' "$out"

	vstart
	ck "the baseline settings are accepted" $?
	ck_eq "the server answers" 1 "$(vpsql -c 'SELECT 1')"
	vstop
	ck_no_crash
}

nc_V0_prerequisites()
{
	# Without the mode the same settings start an ordinary server.
	vstop
	: >"$LOGFILE"
	local copy=$OUTPUTDIR/stock
	rm -rf "$copy" && cp -Rp "$SEED" "$copy"
	if "$MC_BINDIR/pg_ctl" -D "$copy" -l "$LOGFILE" -w -t 120 \
		-o "-c port=$PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories= -c wal_level=replica -c max_wal_senders=0" \
		start >/dev/null 2>&1; then
		ck "wal_level=replica starts without the mode" 0
		"$MC_BINDIR/pg_ctl" -D "$copy" -m fast -w stop >/dev/null 2>&1
	else
		ck "wal_level=replica starts without the mode" 1
	fi
	rm -rf "$copy"
}

# ===========================================================================
# V1 --- no relation WAL
#
# DDL, DML, every index AM's build and insert paths, a sequence, VACUUM and
# hint-bit setting on existing pages run one statement per transaction.  The
# WAL they generate must be commit records only: at most V1_BYTES_PER_XACT
# per statement plus a page of slack.  The control shows the same workload
# writing megabytes on an ordinary server.  GiST, which orders page splits by
# LSN, must still answer correctly with fake LSNs, which start past the
# image's WAL; amcheck verifies the B-tree.
# ===========================================================================

V1_BYTES_PER_XACT=128
V1_SETUP="
CREATE EXTENSION IF NOT EXISTS amcheck;
CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE TABLE v1 (i int PRIMARY KEY, t text, p point, a int[], r int4range);
CREATE SEQUENCE v1_seq;
"
V1_WORKLOAD=(
	"INSERT INTO v1 SELECT g, md5(g::text), point(g % 97, g % 89), ARRAY[g % 7, g % 11], int4range(g, g + 10) FROM generate_series(1, 20000) g"
	"CREATE INDEX v1_gist ON v1 USING gist (p)"
	"CREATE INDEX v1_hash ON v1 USING hash (t)"
	"CREATE INDEX v1_brin ON v1 USING brin (i)"
	"CREATE INDEX v1_gin ON v1 USING gin (a)"
	"CREATE INDEX v1_spgist ON v1 USING spgist (r)"
	"INSERT INTO v1 SELECT g, md5(g::text), point(g % 97, g % 89), ARRAY[g % 7], int4range(g, g + 1) FROM generate_series(20001, 30000) g"
	"UPDATE v1 SET t = t || 'x' WHERE i % 3 = 0"
	"DELETE FROM v1 WHERE i % 5 = 0"
	"SELECT count(*) FROM v1"
	"VACUUM v1"
	"SELECT count(nextval('v1_seq')) FROM generate_series(1, 1000)"
	"ALTER SEQUENCE v1_seq RESTART"
	"CREATE TABLE v1_copy AS SELECT * FROM v1"
	"ALTER TABLE v1_copy ADD COLUMN z int DEFAULT 7"
	"CLUSTER v1 USING v1_pkey"
	"INSERT INTO v1 SELECT g, 'far', point(g, g), ARRAY[g], int4range(g, g + 1) FROM generate_series(40001, 42000) g"
)
V1_GIST_COUNT="SELECT count(*) FROM v1 WHERE p <@ box '((10,10),(20,20))'"

# v1_run PORT --- the workload; prints the WAL bytes it generated.
v1_run()
{
	local port=$1 start end stmt out
	vpsql -p "$port" -c "$V1_SETUP" >/dev/null
	start=$(vpsql -p "$port" -c 'SELECT pg_current_wal_insert_lsn()')
	for stmt in "${V1_WORKLOAD[@]}"; do
		out=$(vpsql -p "$port" -c "$stmt")
		case $out in
			*ERROR*) printf 'statement failed: %s\n%s\n' "$stmt" "$out" >&2 ;;
		esac
	done
	end=$(vpsql -p "$port" -c 'SELECT pg_current_wal_insert_lsn()')
	vpsql -p "$port" -c "SELECT '$end'::pg_lsn - '$start'::pg_lsn"
}

V1_no_relation_wal()
{
	local bytes bound ckpt out
	vstart
	ck "server starts" $?
	bytes=$(v1_run "$PORT")
	bound=$(( ${#V1_WORKLOAD[@]} * V1_BYTES_PER_XACT + 8192 ))
	ck "the workload wrote $bytes WAL bytes, at most $bound" \
		"$([ "${bytes:-999999999}" -le "$bound" ]; echo $?)"

	out=$(vpsql -c "SET enable_indexscan = off" -c "SET enable_bitmapscan = off" -c "$V1_GIST_COUNT")
	ck_eq "GiST answers as a heap scan does" "$out" \
		"$(vpsql -c "SET enable_seqscan = off" -c "$V1_GIST_COUNT")"
	ck_eq "the far inserts are found through GiST" 2000 \
		"$(vpsql -c "SET enable_seqscan = off" -c "SELECT count(*) FROM v1 WHERE p <@ box '((40001,40001),(42000,42000))'")"
	ckpt=$(control_value "$SEED" 'Latest checkpoint location')
	ck_eq "the GiST root carries a fake LSN past the image's WAL" t \
		"$(vpsql -c "SELECT lsn > '$ckpt'::pg_lsn FROM page_header(get_raw_page('v1_gist', 0))")"
	out=$(vpsql -c "SELECT bt_index_check('v1_pkey', true)")
	ck_nomatch "amcheck verifies the B-tree" 'ERROR' "$out"
	vstop
	ck_no_crash
}

nc_V1_no_relation_wal()
{
	local bytes
	stock_start
	ck "stock server starts" $?
	bytes=$(v1_run "$PORT")
	ck "the stock server logged $bytes bytes, more than 1MB" \
		"$([ "${bytes:-0}" -gt 1048576 ]; echo $?)"
	stock_stop
}

# ===========================================================================
# V2 --- volatile WAL
#
# Commits and segment switches drive the insert position several segments
# past the seed's WAL.  Nothing in pg_wal may change, the flush position must
# still advance (the WAL writer "writes" by moving it), and reading WAL back
# is refused because it exists only in the WAL buffers.  The server is
# stopped with SIGQUIT so no shutdown path can hide a write.
# ===========================================================================

V2_WORKLOAD="
CREATE TABLE v2 (i int, t text);
DO \$\$ BEGIN FOR i IN 1..500 LOOP INSERT INTO v2 VALUES (i, repeat('x', 200)); COMMIT; END LOOP; END \$\$;
SELECT pg_switch_wal() IS NOT NULL;
INSERT INTO v2 VALUES (-1, 'after one switch');
SELECT pg_switch_wal() IS NOT NULL;
INSERT INTO v2 VALUES (-2, 'after two switches');
SELECT pg_switch_wal() IS NOT NULL;
INSERT INTO v2 VALUES (-3, 'after three switches');
"

# segments_past DIR PORT --- how many WAL segments the insert position is
# past the segment holding the image's checkpoint.
segments_past()
{
	local seg ckpt
	seg=$(control_value "$1" 'Bytes per WAL segment')
	ckpt=$(control_value "$1" 'Latest checkpoint location')
	vpsql -p "$2" -c "SELECT (floor((pg_current_wal_insert_lsn() - '0/0') / $seg)
		- floor(('$ckpt'::pg_lsn - '0/0') / $seg))::int"
}

V2_volatile_wal()
{
	local before after out i past flushed
	before=$(manifest "$SEED" pg_wal)
	vstart
	ck "server starts" $?
	out=$(printf "%s" "$V2_WORKLOAD" | vpsql)
	ck_nomatch "the workload runs" 'ERROR' "$out"
	past=$(segments_past "$SEED" "$PORT")
	ck "the insert position is 3+ segments past the image ($past)" "$([ "${past:-0}" -ge 3 ]; echo $?)"
	ck_eq "the rows are there" 503 "$(vpsql -c 'SELECT count(*) FROM v2')"

	flushed=f
	for ((i = 0; i < 50; i++)); do
		flushed=$(vpsql -c "SELECT pg_current_wal_flush_lsn() >= '$(vpsql -c 'SELECT pg_current_wal_insert_lsn()')'::pg_lsn - 8192")
		[ "$flushed" = t ] && break
		sleep 0.1
	done
	ck_eq "the WAL writer advances the flush position" t "$flushed"

	out=$(vpsql -c 'CREATE EXTENSION pg_walinspect' \
		-c "SELECT count(*) FROM pg_get_wal_records_info(pg_current_wal_flush_lsn() - 64, pg_current_wal_flush_lsn())")
	ck_match "reading WAL is refused" 'reading WAL is not supported when "volatile_data_directory" is enabled' "$out"

	vstop QUIT
	after=$(manifest "$SEED" pg_wal)
	ck_eq "pg_wal is unchanged" "$(printf '%s' "$before" | shasum)" "$(printf '%s' "$after" | shasum)"
	ck_no_crash
}

nc_V2_volatile_wal()
{
	local before after out
	stock_start
	ck "stock server starts" $?
	before=$(manifest "$STOCK" pg_wal)
	out=$(printf "%s" "$V2_WORKLOAD" | vpsql)
	ck_nomatch "the workload runs" 'ERROR' "$out"
	stock_stop immediate
	after=$(manifest "$STOCK" pg_wal)
	ck "the stock server writes pg_wal" "$([ "$before" != "$after" ]; echo $?)"
}

# ===========================================================================
# V3 --- no checkpoints, no control-file writes
#
# CHECKPOINT, a fast shutdown and a crash all leave the image's pg_control
# byte-identical, so every later start is a start from the image's own clean
# shutdown: no recovery, and the same checkpoint the image was built with.
# pg_control_checkpoint() reads the file, not shared memory.
# ===========================================================================

V3_no_checkpoints()
{
	local before ckpt out i started
	before=$(manifest "$SEED" global/pg_control)
	ckpt=$(control_value "$SEED" 'Latest checkpoint location')
	vstart log_min_messages=log
	ck "server starts" $?
	out=$(vpsql -c 'CREATE TABLE v3 AS SELECT generate_series(1, 1000) i' -c CHECKPOINT \
		-c 'SELECT checkpoint_lsn FROM pg_control_checkpoint()')
	ck_eq "CHECKPOINT leaves the file's checkpoint alone" "$ckpt" "$(printf '%s\n' "$out" | tail -1)"
	ck_nomatch "no checkpoint ran" 'checkpoint (starting|complete)' "$(cat "$LOGFILE")"

	vstop INT
	ck_eq "a fast shutdown leaves pg_control unchanged" "$before" "$(manifest "$SEED" global/pg_control)"

	vstart log_min_messages=log
	ck "the server restarts" $?
	ck_match "the restart starts from the image's shutdown" 'database system was shut down at' "$(cat "$LOGFILE")"
	ck_eq "the restart sees the image, not the previous run" 0 \
		"$(vpsql -c "SELECT count(*) FROM pg_class WHERE relname = 'v3'")"

	vstop KILL
	started=1
	for ((i = 0; i < 20; i++)); do
		if vstart log_min_messages=log 2>/dev/null; then
			started=0
			break
		fi
		sleep 0.5
	done
	ck "a crashed server restarts" $started
	ck_nomatch "without recovery" 'was interrupted|redo starts|automatic recovery' "$(cat "$LOGFILE")"
	vstop INT
	ck_eq "pg_control is unchanged" "$before" "$(manifest "$SEED" global/pg_control)"
	ck_no_crash
}

nc_V3_no_checkpoints()
{
	local before out
	stock_start
	ck "stock server starts" $?
	before=$(manifest "$STOCK" global/pg_control)
	out=$(vpsql -c 'CREATE TABLE v3 AS SELECT generate_series(1, 1000) i' -c CHECKPOINT)
	ck_nomatch "the workload runs" 'ERROR' "$out"
	ck "the stock server's CHECKPOINT rewrites pg_control" \
		"$([ "$before" != "$(manifest "$STOCK" global/pg_control)" ]; echo $?)"
	stock_stop
}

# ===========================================================================
# V4 --- memory-backed SLRUs
#
# With the SLRUs at their minimum of 16 buffers, a million consumed XIDs and
# 40000 subtransaction-created multixacts evict dirty pg_xact, pg_subtrans
# and pg_multixact pages, which the mode writes to the SLRU store instead of
# a segment file.  400 page-sized notifications do the same to pg_notify and
# then truncate it, which forgets stored segments instead of unlinking.  Commit status written before the eviction must read back
# correctly afterwards, and no SLRU directory of the image may change.  A
# store too small for the run fails the write loudly instead of dropping a
# page.
# ===========================================================================

V4_GUCS=(transaction_buffers=16 subtransaction_buffers=16
	multixact_offset_buffers=16 multixact_member_buffers=16 notify_buffers=16)
V4_SLRUS='pg_xact pg_subtrans pg_multixact pg_notify pg_serial pg_commit_ts'
V4_SETUP="
CREATE EXTENSION IF NOT EXISTS xid_wraparound;
CREATE TABLE v4 (i int, x xid8);
CREATE TABLE v4m (id int PRIMARY KEY);
INSERT INTO v4m VALUES (1);
"
V4_MULTIXACTS="
DO \$\$ BEGIN
	FOR i IN 1..40000 LOOP
		PERFORM 1 FROM v4m WHERE id = 1 FOR KEY SHARE;
		BEGIN
			PERFORM 1 FROM v4m WHERE id = 1 FOR SHARE;
		EXCEPTION WHEN OTHERS THEN RAISE;	-- a subtransaction
		END;
		COMMIT;
	END LOOP;
END \$\$;
"
# One page of pg_notify per notification, read only after the loop: the
# queue grows past its buffers.  Once read, later notifications advance its
# tail, which truncates it.
V4_NOTIFY="
LISTEN v4;
DO \$\$ BEGIN
	FOR i IN 1..400 LOOP
		PERFORM pg_notify('v4', repeat('x', 7000));
		COMMIT;
	END LOOP;
END \$\$;
SELECT 1;
DO \$\$ BEGIN
	FOR i IN 1..8 LOOP
		PERFORM pg_notify('v4', repeat('y', 7000));
		COMMIT;
	END LOOP;
END \$\$;
SELECT 1;
"

# v4_run PORT --- the workload; prints the aborted XID.
v4_run()
{
	local port=$1 i aborted
	vpsql -p "$port" -c "$V4_SETUP" >/dev/null
	for ((i = 1; i <= 50; i++)); do
		vpsql -p "$port" -c "INSERT INTO v4 VALUES ($i, pg_current_xact_id())" >/dev/null
	done
	aborted=$(vpsql -p "$port" -c BEGIN -c 'SELECT pg_current_xact_id()' -c ROLLBACK)
	vpsql -p "$port" -c 'SELECT consume_xids(1100000)' >/dev/null
	printf '%s' "$V4_MULTIXACTS" | vpsql -p "$port" >/dev/null
	printf '%s' "$V4_NOTIFY" | vpsql -p "$port" >/dev/null
	printf '%s' "$aborted"
}

V4_memory_slrus()
{
	local before after aborted out
	before=$(manifest "$SEED" $V4_SLRUS)

	vstart "${V4_GUCS[@]}" memcow.slru_pages=16
	ck "server starts with a 16-page store" $?
	vpsql -c "$V4_SETUP" >/dev/null
	out=$(vpsql -c 'SELECT consume_xids(1100000)')
	ck_match "a full store fails the SLRU write" 'could not write to file.*No space left on device' "$out"
	ck_match "and names the setting" 'memcow SLRU store is full' "$(cat "$LOGFILE")"
	vstop

	vstart "${V4_GUCS[@]}"
	ck "server starts" $?
	aborted=$(v4_run "$PORT")
	ck_eq "every committed row is visible" 50 "$(vpsql -c 'SELECT count(*) FROM v4')"
	ck_eq "every early commit reads back as committed" 50 \
		"$(vpsql -c "SELECT count(*) FROM v4 WHERE pg_xact_status(x) = 'committed'")"
	ck_eq "the early abort reads back as aborted" aborted \
		"$(vpsql -c "SELECT pg_xact_status('$aborted')")"
	ck_eq "16+ pages of each of pg_xact, pg_subtrans and pg_multixact were stored" 4 \
		"$(vpsql -c "SELECT count(*) FROM pg_stat_slru WHERE blks_written >= 16 AND name IN ('transaction', 'subtransaction', 'multixact_offset', 'multixact_member')")"
	ck_eq "evicted pg_xact pages were read back" t \
		"$(vpsql -c "SELECT blks_read > 0 FROM pg_stat_slru WHERE name = 'transaction'")"
	ck_eq "pg_notify was stored and truncated" t \
		"$(vpsql -c "SELECT blks_written >= 16 AND truncates > 0 FROM pg_stat_slru WHERE name = 'notify'")"
	out=$(vpsql -c 'UPDATE v4m SET id = id' -c 'SELECT count(*) FROM v4m')
	ck_eq "the multixact-locked row reads and updates" 1 "$(printf '%s\n' "$out" | tail -1)"
	vstop
	after=$(manifest "$SEED" $V4_SLRUS)
	ck_eq "no SLRU directory changed" "$(printf '%s' "$before" | shasum)" \
		"$(printf '%s' "$after" | shasum)"
	ck_nomatch "no store overflow" 'store is full' "$(cat "$LOGFILE")"
	ck_no_crash
}

nc_V4_memory_slrus()
{
	local before
	stock_start "$(printf -- '-c %s ' "${V4_GUCS[@]}")"
	ck "stock server starts" $?
	before=$(manifest "$STOCK" $V4_SLRUS)
	v4_run "$PORT" >/dev/null
	ck "the stock server writes SLRU segments" \
		"$([ "$before" != "$(manifest "$STOCK" $V4_SLRUS)" ]; echo $?)"
	stock_stop
}

# ===========================================================================
# V5 --- startup and shutdown files; many postmasters on one image
#
# Four postmasters start on the same seed at once, which needs no lock file
# and no shared-memory interlock.  Each sees only its own writes.  A SIGKILL
# of one leaves the others serving, and it restarts at once.  Relcache init
# files, stats and the rest are never written: the whole seed is identical
# afterwards.  The control shows an ordinary server writing its lock file,
# options file and relcache init files.
# ===========================================================================

V5_SERVERS=4
V5_WORKLOAD="CREATE TABLE v5 (i int); INSERT INTO v5 SELECT generate_series(1, 100); SELECT count(*) FROM pg_class; ANALYZE v5; CHECKPOINT"

V5_shared_image()
{
	local before i n ports=() pids=() out
	before=$(manifest "$SEED")
	vstop
	: >"$LOGFILE"
	for ((n = 0; n < V5_SERVERS; n++)); do
		ports[n]=$(mc_free_port)
		: >"$LOGFILE.$n"
		mc_volatile_start "$SEED" "${ports[n]}" "$LOGFILE.$n" "$PIDFILE.$n" &
		pids[n]=$!
	done
	for ((n = 0; n < V5_SERVERS; n++)); do
		wait "${pids[n]}"
		ck "postmaster $n starts on the shared image" $?
	done
	for ((n = 0; n < V5_SERVERS; n++)); do
		vpsql -p "${ports[n]}" -c "$V5_WORKLOAD" -c "INSERT INTO v5 VALUES ($((1000 + n)))" >/dev/null
	done
	for ((n = 0; n < V5_SERVERS; n++)); do
		ck_eq "postmaster $n sees only its own rows" "101 $((1000 + n))" \
			"$(vpsql -p "${ports[n]}" -c 'SELECT count(*), max(i) FROM v5' | tr '|' ' ')"
	done
	ck_eq "a new connection sees the catalogs (no init file)" t \
		"$(vpsql -p "${ports[0]}" -c "SELECT count(*) > 0 FROM pg_class WHERE relname = 'v5'")"
	for f in postmaster.pid postmaster.opts global/pg_internal.init; do
		ck "no $f in the image" "$([ ! -e "$SEED/$f" ]; echo $?)"
	done

	mc_volatile_stop "$PIDFILE.0" KILL
	for ((n = 1; n < V5_SERVERS; n++)); do
		ck_eq "postmaster $n survives a SIGKILL of postmaster 0" 101 \
			"$(vpsql -p "${ports[n]}" -c 'SELECT count(*) FROM v5')"
	done
	mc_volatile_start "$SEED" "${ports[0]}" "$LOGFILE.0" "$PIDFILE.0"
	ck "postmaster 0 restarts beside the others" $?
	ck_eq "and starts from the image" 0 \
		"$(vpsql -p "${ports[0]}" -c "SELECT count(*) FROM pg_class WHERE relname = 'v5'")"

	for ((n = 0; n < V5_SERVERS; n++)); do
		mc_volatile_stop "$PIDFILE.$n" INT
		cat "$LOGFILE.$n" >>"$LOGFILE"
	done
	out=$(manifest "$SEED")
	ck_eq "the seed is byte-identical" "$(printf '%s' "$before" | shasum)" "$(printf '%s' "$out" | shasum)"
	[ "$before" = "$out" ] || diff <(printf '%s\n' "$before") <(printf '%s\n' "$out") | head -20
	ck_no_crash
}

nc_V5_shared_image()
{
	stock_start
	ck "stock server starts" $?
	vpsql -c "$V5_WORKLOAD" >/dev/null
	for f in postmaster.pid postmaster.opts global/pg_internal.init; do
		ck "the stock server writes $f" "$([ -e "$STOCK/$f" ]; echo $?)"
	done
	stock_stop
}

# ===========================================================================
# V6 --- temporary files and the commands that would write the directory
#
# A sort, a hash join and an index build that exceed their memory budget
# fail with a named error and a work_mem hint instead of creating
# base/pgsql_tmp; given the memory, the same statements succeed.  Commands
# whose whole effect is a file below DataDir are refused by name.  The
# control shows an ordinary server spilling and running ALTER SYSTEM.
# ===========================================================================

V6_SETUP="SET work_mem = '64MB'; CREATE TABLE v6 AS SELECT g AS i, md5(g::text) AS t FROM generate_series(1, 200000) g"
V6_SPILLS=(
	"SET work_mem = '64kB'; SELECT count(*) FROM (SELECT t FROM v6 ORDER BY t) s"
	"SET work_mem = '64kB'; SET enable_mergejoin = off; SET enable_nestloop = off; SELECT count(*) FROM v6 a JOIN v6 b USING (t)"
	"SET maintenance_work_mem = '1MB'; SET max_parallel_maintenance_workers = 0; CREATE INDEX v6_t ON v6 (t)"
)
V6_REFUSALS=(
	'CREATE DATABASE v6db|CREATE DATABASE'
	'DROP DATABASE memcow_lane_07|DROP DATABASE'
	'ALTER DATABASE memcow_lane_07 SET TABLESPACE pg_default|ALTER DATABASE SET TABLESPACE'
	"CREATE TABLESPACE v6ts LOCATION '/nonexistent'|CREATE TABLESPACE"
	'DROP TABLESPACE IF EXISTS v6ts|DROP TABLESPACE'
	"ALTER SYSTEM SET work_mem = '1MB'|ALTER SYSTEM"
	'BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT pg_export_snapshot(); COMMIT|exporting a snapshot'
	'VACUUM FULL pg_class|rewriting a mapped catalog'
)

V6_refusals()
{
	local stmt entry want out
	vstart
	ck "server starts" $?
	printf "%s;\n" "$V6_SETUP" | vpsql >/dev/null
	for stmt in "${V6_SPILLS[@]}"; do
		out=$(printf '%s;\n' "$stmt" | vpsql)
		ck_match "spill refused: ${stmt##*; }" \
			'temporary files are not supported when "volatile_data_directory" is enabled' "$out"
	done
	ck_match "the refusal names the fix" 'HINT: +Raise "work_mem" or "maintenance_work_mem"' "$out"
	out=$(printf '%s;\n' "SET work_mem = '256MB'" "${V6_SPILLS[0]#*; }" \
		"SET maintenance_work_mem = '256MB'" "SET max_parallel_maintenance_workers = 4" \
		"SET min_parallel_table_scan_size = 0" "CREATE INDEX v6_t ON v6 (t)" | vpsql)
	# Parallel workers hand sorted runs over in files; the planner uses none.
	ck_nomatch "with the memory, the sort and a parallel-eligible index build run" 'ERROR' "$out"

	for entry in "${V6_REFUSALS[@]}"; do
		out=$(printf '%s;\n' "${entry%%|*}" | vpsql)
		want=${entry#*|}
		ck_match "refused: $want" "ERROR: +$want is not supported when \"volatile_data_directory\" is enabled" "$out"
	done
	ck "no pgsql_tmp in the image" "$([ ! -e "$SEED/base/pgsql_tmp" ]; echo $?)"
	vstop
	ck_no_crash
}

nc_V6_refusals()
{
	local out
	stock_start
	ck "stock server starts" $?
	printf "%s;\n" "$V6_SETUP" | vpsql >/dev/null
	out=$(printf '%s;\n' "${V6_SPILLS[0]}" | vpsql)
	ck_nomatch "the stock server spills" 'ERROR' "$out"
	ck "and creates base/pgsql_tmp" "$([ -d "$STOCK/base/pgsql_tmp" ]; echo $?)"
	out=$(vpsql -c "ALTER SYSTEM SET work_mem = '1MB'")
	ck_nomatch "the stock server runs ALTER SYSTEM" 'ERROR' "$out"
	ck_match "and writes postgresql.auto.conf" "work_mem = '1MB'" "$(cat "$STOCK/postgresql.auto.conf")"
	stock_stop
}

# ===========================================================================
# driver
# ===========================================================================

trap 'vstop INT; stock_stop immediate' EXIT INT TERM

mc_banner "memcow volatile_data_directory slice tests" \
	"seed:     $SEED" \
	"bindir:   $MC_BINDIR" \
	"cases:    ${CASES[*]}" \
	"mode:     $([ $NEGATIVE -eq 1 ] && echo 'NEGATIVE CONTROL' || echo normal)"

PASSED=0
FAILED=0
FAILED_NAMES=

# The standing invariant: no case, positive or control, changes the seed.
mc_seed_manifest "$SEED" "$OUTPUTDIR/seed.before"

for c in "${CASES[@]}"; do
	CASE_FAIL=0
	if [ $NEGATIVE -eq 1 ]; then
		printf '\n--- %s [negative control] ---\n' "$c"
		"nc_$c"
	else
		printf '\n--- %s ---\n' "$c"
		"$c"
	fi
	if [ $CASE_FAIL -eq 0 ]; then
		printf '  PASS  %s\n' "$c"
		PASSED=$((PASSED + 1))
	else
		printf '  FAIL  %s\n' "$c"
		FAILED=$((FAILED + 1))
		FAILED_NAMES="$FAILED_NAMES $c"
		[ $STOP_ON_FAIL -eq 1 ] && break
	fi
done

mc_seed_manifest "$SEED" "$OUTPUTDIR/seed.after"
if cmp -s "$OUTPUTDIR/seed.before" "$OUTPUTDIR/seed.after"; then
	printf '\n  ok      the seed is byte-identical after every case\n'
else
	printf '\n  NOT OK  the seed changed:\n'
	diff "$OUTPUTDIR/seed.before" "$OUTPUTDIR/seed.after" | head -20 | sed 's/^/          /'
	FAILED=$((FAILED + 1))
	FAILED_NAMES="$FAILED_NAMES seed-manifest"
fi

RC=0
[ $FAILED -eq 0 ] || RC=1
if [ $RC -eq 0 ]; then
	mc_banner "VOLATILE TESTS PASS -- $PASSED case(s), 0 failed"
else
	mc_banner "VOLATILE TESTS FAIL -- $PASSED passed, $FAILED failed:${FAILED_NAMES}" \
		"logs: $OUTPUTDIR"
fi
exit $RC
