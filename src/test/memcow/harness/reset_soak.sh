#!/usr/bin/env bash
#
# reset_soak.sh --- plan §7.2: the lane-reset soak.
#
#   Loop N x { DDL+DML workload -> drain -> memcow_lane_reset(D) -> adopt ->
#              seed-hash verify + differential query }
#
# and, per reset, verify what §7.2 says must hold:
#
#   * attach-count(old epoch) == 0 and the reclaim completed
#     (memcow_lane_status: attached_old, reclaim_pending);
#   * the DSM segment count is FLAT -- the old arena's segments are gone
#     after every reset, none leak.  Measured from OUTSIDE the server: the
#     soak runs with dynamic_shared_memory_type=mmap, under which every
#     segment is a file in pg_dynshmem/, so this does not trust memcow's own
#     accounting.  It also runs with track_counts=off: cumulative statistics
#     are cluster-monotonic and exempt from reversion (plan §5 I1), and every
#     relation a workload creates leaves a stats entry behind when the reset
#     removes the relation without a DROP, so the stats DSA grows a segment
#     every few hundred relations and would make this count meaningless.
#     It also runs with max_parallel_workers_per_gather=0: a session keeps
#     its parallel-query DSM segment (~192 kB) until it exits -- measured on
#     a stock cluster, so it is not memcow's doing -- and the retained
#     sessions here never exit.  (memcow_lane_reset() additionally
#     verifies, in the engine, that the old arena's control segment is gone
#     after RECLAIM.)
#   * the RAM dir is flat: everything under PGDATA except pg_wal (whose size
#     is bounded by max_wal_size and recycles) must not grow;
#   * pg_filenode.map is byte-stable -- the reset itself verifies it against
#     the seed and retires the lane otherwise, which fails the soak;
#   * the fence is EXERCISED, not merely present: every --fence-every
#     iterations an unregistered straggler holding an open transaction is
#     left in the lane and must be terminated by the reset, and a registered
#     backend is left busy and the reset must REFUSE and then succeed on
#     retry once it is idle.
#
# Two lane connections stay open for the whole run, registered, exactly as
# pool connections would: they carry the workload, get drained (ROLLBACK,
# DISCARD ALL), sit idle through the reset, adopt with memcow_backend_reset()
# and run the differential query at the new epoch.  A fresh connection is
# also checked every --fresh-every iterations.
#
# Fail = any cross-epoch artifact (digest mismatch, a relation surviving a
# reset), any monotonic DSM/RAM-dir growth, any leaked AIO resource, assert or
# crash in the server log, any unexpected ERROR.
#
# Usage:
#   reset_soak.sh --seed DIR --pgdata DIR [--build-dir DIR] [options]
#     --iterations N      resets to perform (default 10000)
#     --fence-every K     exercise the straggler + busy fences every K (default 100)
#     --fresh-every K     check the seed digest from a fresh connection every K (default 50)
#     --db NAME           the lane (default memcow_lane_00)
#     --outputdir DIR     logs (default <pgdata>/../soak-out)
#     --ram-mount DIR     for re-assembly if the PGDATA needs recovery
#
# Exit status: 0 pass, 1 fail, 2 could not run.
#
# Portions Copyright (c) 2026, PostgreSQL Global Development Group

set -o pipefail

MC_PROG=reset_soak.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SEEDDIR_SCRIPTS=$(cd -- "$HERE/../seed" && pwd)
# shellcheck source=./common.sh
. "$HERE/common.sh"
# shellcheck source=./sessions.sh
. "$HERE/sessions.sh"

SEED= PGDATA= RAM_MOUNT= BUILD_DIR= OUTPUTDIR=
DB=memcow_lane_00
CONTROL_DB=${MEMCOW_CONTROL_DB:-memcow_control}
ITER=10000
FENCE_EVERY=100
FRESH_EVERY=50

while [ $# -gt 0 ]; do
	case $1 in
		--seed)        SEED=$2; shift 2 ;;
		--pgdata)      PGDATA=$2; shift 2 ;;
		--ram-mount)   RAM_MOUNT=$2; shift 2 ;;
		--build-dir)   BUILD_DIR=$2; shift 2 ;;
		--outputdir)   OUTPUTDIR=$2; shift 2 ;;
		--db)          DB=$2; shift 2 ;;
		--iterations)  ITER=$2; shift 2 ;;
		--fence-every) FENCE_EVERY=$2; shift 2 ;;
		--fresh-every) FRESH_EVERY=$2; shift 2 ;;
		-h|--help)     sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)             mc_die "unknown option: $1" ;;
	esac
done

[ -n "$SEED" ]   || mc_die "--seed is required"
[ -n "$PGDATA" ] || mc_die "--pgdata is required"
SEED=$(mc_abspath "$SEED"); PGDATA=$(mc_abspath "$PGDATA")
[ -f "$SEED/memcow_seed.fingerprint" ] || mc_die "not a seed: $SEED"
[ -f "$PGDATA/PG_VERSION" ] || mc_die "not a data directory: $PGDATA"
: "${RAM_MOUNT:=$(dirname -- "$PGDATA")}"
[ -n "$BUILD_DIR" ] || BUILD_DIR=$(mc_default_build_dir) || mc_die "pass --build-dir"
mc_resolve_build "$BUILD_DIR"
: "${OUTPUTDIR:=$(dirname -- "$PGDATA")/soak-out}"
mkdir -p "$OUTPUTDIR" || mc_die "cannot create $OUTPUTDIR"
OUTPUTDIR=$(mc_abspath "$OUTPUTDIR")
SOCKDIR=$(mc_make_sockdir) || mc_die "cannot create a socket directory"
PORT=$(mc_free_port) || mc_die "cannot find a free port"
LOGFILE="$OUTPUTDIR/postmaster.log"

pg_start()
{
	"$MC_BINDIR/pg_ctl" -D "$PGDATA" -l "$LOGFILE" -p "$MC_BINDIR/postgres" \
		-o "-c shared_preload_libraries=memcow -c memcow.enabled=on -c memcow.seed_directory=$SEED \
		    -c listen_addresses= -c unix_socket_directories=$SOCKDIR \
		    -c log_min_messages=warning -c log_statement=none \
		    -c restart_after_crash=off -c dynamic_shared_memory_type=mmap \
		    -c track_counts=off -c max_parallel_workers_per_gather=0 \
		    -c max_prepared_transactions=0 -c autovacuum=off \
		    -c max_wal_size=256MB -p $PORT" \
		-w -t 60 start >>"$LOGFILE.pg_ctl" 2>&1
}
pg_stop() { "$MC_BINDIR/pg_ctl" -D "$PGDATA" -m "${1:-fast}" -w -t 60 stop >>"$LOGFILE.pg_ctl" 2>&1; }
pg_running() { "$MC_BINDIR/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; }
cluster_state() { "$MC_BINDIR/pg_controldata" -D "$PGDATA" 2>/dev/null | sed -n 's/^Database cluster state: *//p'; }

psql()     { PGHOST=$SOCKDIR PGPORT=$PORT "$MC_BINDIR/psql" -X -q -A -t -d "$DB" -v ON_ERROR_STOP=0 "$@" 2>&1; }
psql_ctl() { PGHOST=$SOCKDIR PGPORT=$PORT "$MC_BINDIR/psql" -X -q -A -t -d "$CONTROL_DB" -v ON_ERROR_STOP=0 "$@" 2>&1; }

dsm_files()   { find "$PGDATA/pg_dynshmem" -name 'mmap.*' 2>/dev/null | wc -l | tr -d ' '; }
pgwal_kb()    { du -sk "$PGDATA/pg_wal" 2>/dev/null | awk '{print $1}'; }
# PGDATA size excluding pg_wal, in ONE traversal.  Measuring the whole PGDATA
# and pg_wal in two separate du passes and subtracting is racy: a 16 MB WAL
# segment recycled between the two passes makes the difference jump by a whole
# segment, which reads as spurious growth.  perl is already required (now_ms).
data_minus_wal_kb() {
	perl -MFile::Find -e '
		my $root = shift; my $wal = "$root/pg_wal"; my $sum = 0;
		find({ wanted => sub {
			if ($File::Find::name eq $wal) { $File::Find::prune = 1; return; }
			$sum += -s $_ if -f $_;
		}, no_chdir => 1 }, $root);
		print int($sum / 1024), "
";
	' "$PGDATA"
}
now_ms()      { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

FAIL=0
fail() { printf 'FAIL  %s\n' "$*"; FAIL=1; }

cleanup()
{
	sess_close A 7 2>/dev/null
	sess_close B 8 2>/dev/null
	pg_running && { pg_stop fast || pg_stop immediate; }
	rm -rf "$SOCKDIR"
}
trap cleanup EXIT INT TERM

case $(cluster_state) in
	"shut down"|"shut down in recovery") ;;
	*) mc_warn "PGDATA needs recovery; re-assembling"
	   bash "$SEEDDIR_SCRIPTS/assemble_ramdir.sh" -s "$SEED" -m "$RAM_MOUNT" -b "$MC_BINDIR" -f \
	       >"$OUTPUTDIR/reassemble.log" 2>&1 || mc_die "re-assembly failed" ;;
esac

: >"$LOGFILE"; : >"$LOGFILE.pg_ctl"
pg_start || mc_die "server did not start; see $LOGFILE"

mc_banner "memcow reset soak (plan §7.2)" \
	"seed:       $SEED" "pgdata:     $PGDATA" "lane:       $DB" \
	"iterations: $ITER   fence every: $FENCE_EVERY   fresh every: $FRESH_EVERY" \
	"logs:       $OUTPUTDIR"

psql_ctl -c "CREATE EXTENSION IF NOT EXISTS memcow" >/dev/null
DBOID=$(psql_ctl -c "SELECT oid FROM pg_database WHERE datname = '$DB'")
[ -n "$DBOID" ] || mc_die "cannot resolve the lane's oid"

DIGEST_SQL="SELECT md5(string_agg(relname || ':' || nrows || ':' || digest, ',' ORDER BY relname)) FROM public.memcow_seed_digest"
DIGEST_SEED=$(psql -c "$DIGEST_SQL")
[[ $DIGEST_SEED =~ ^[0-9a-f]{32}$ ]] || mc_die "cannot take the seed digest: $DIGEST_SEED"
echo "seed digest: $DIGEST_SEED"

# the two retained lane connections
sess_open A 7; sess_open B 8
PID_A=$(sess_query A 7 "SELECT pg_backend_pid()")
PID_B=$(sess_query B 8 "SELECT pg_backend_pid()")
psql_ctl -c "SELECT memcow_lane_register($DBOID, $PID_A), memcow_lane_register($DBOID, $PID_B)" >/dev/null

# reset once to get to "a lane at a fresh epoch", which is the baseline
out=$(psql_ctl -c "SELECT memcow_lane_reset($DBOID)"); [ "$out" = 1 ] || mc_die "reset 0 failed: $out"
psql_ctl -c "SELECT memcow_lane_open($DBOID, false)" >/dev/null
sess_query A 7 "SELECT public.memcow_backend_reset()" >/dev/null
sess_query B 8 "SELECT public.memcow_backend_reset()" >/dev/null
DSM_BASE=$(dsm_files)
DATA_BASE=$(data_minus_wal_kb)
echo "baseline: dsm segments=$DSM_BASE  pgdata-minus-wal=${DATA_BASE}kB  wal=$(pgwal_kb)kB"

workload()	# workload SESSION FD ITER
{
	local s=$1 fd=$2 i=$3 out
	case $((i % 4)) in
	0) out=$(sess_query "$s" "$fd" "
CREATE TABLE soak_t$i AS SELECT g AS id, repeat('x', 100) AS pad FROM generate_series(1, 5000) g;
CREATE INDEX ON soak_t$i (id);
UPDATE public.events SET kind = 'soak' WHERE event_id % 7 = 0;
DELETE FROM public.ledger WHERE entry_no % 3 = 0;
INSERT INTO public.accounts SELECT * FROM public.accounts LIMIT 0;
" 120) ;;
	1) out=$(sess_query "$s" "$fd" "
DELETE FROM public.events;
VACUUM (TRUNCATE on) public.events;
CREATE TEMP TABLE soak_tmp AS SELECT * FROM public.accounts;
UPDATE soak_tmp SET balance = balance + 1;
" 120) ;;
	2) out=$(sess_query "$s" "$fd" "
DROP TABLE public.staging CASCADE;
ALTER TABLE public.documents ADD COLUMN soak int DEFAULT 1;
UPDATE public.documents SET soak = 2;
TRUNCATE public.ledger;
INSERT INTO public.ledger SELECT * FROM public.ledger LIMIT 0;
" 120) ;;
	3) out=$(sess_query "$s" "$fd" "
BEGIN;
UPDATE public.accounts SET balance = balance * 2;
CREATE TABLE soak_open AS SELECT 1 AS x;
" 120) ;;			# left open on purpose: the drain must roll it back
	esac
	case $out in *ERROR*|*FATAL*|*TIMEOUT*) fail "iteration $i workload: $out" ;; esac
}

drain()		# drain SESSION FD
{
	local out
	out=$(sess_query "$1" "$2" "ROLLBACK; DISCARD ALL;" 60)
	case $out in *FATAL*|*TIMEOUT*) fail "drain $1: $out" ;; esac
}

# SOAK_TRACE=1 prints the DSM segment count after every step, for finding
# out which step created a segment that should not be there.
trace() { [ "${SOAK_TRACE:-0}" = 1 ] && printf '      [trace] %s: dsm=%s\n' "$*" "$(dsm_files)"; return 0; }

declare -a LAT=()
t_start=$(now_ms)
for ((i = 1; i <= ITER; i++)); do
	epoch_expected=$((i + 1))

	workload A 7 $i;          trace "iter $i workload A"
	workload B 8 $((i + 2));  trace "iter $i workload B"

	# every K: exercise the fence, both halves
	if [ $FENCE_EVERY -gt 0 ] && [ $((i % FENCE_EVERY)) -eq 0 ]; then
		# (a) a busy registered backend: reset must refuse, then succeed
		seq=$(sess_send A 7 "SELECT pg_sleep(1.5)")
		sleep 0.2
		out=$(psql_ctl -c "SELECT memcow_lane_reset($DBOID, 500)")
		case $out in
			*"not idle"*) ;;
			*) fail "iteration $i: reset with a busy registered backend was not refused: $out" ;;
		esac
		sess_wait A "$seq" 30 || fail "iteration $i: busy session did not finish"
		# A refused reset leaves the lane CLOSED (plan Appendix B(i): before
		# the commit point the lane is unchanged and closed; the caller
		# retries or retires).  A pool would reopen it; so does this.
		psql_ctl -c "SELECT memcow_lane_open($DBOID, false)" >/dev/null
		# (b) an unregistered straggler with an open transaction: killed
		sess_open S 9
		PID_S=$(sess_query S 9 "SELECT pg_backend_pid()")
		seq=$(sess_send S 9 "BEGIN; UPDATE public.accounts SET balance = 0 WHERE account_id = 1; SELECT pg_sleep(30);")
		sleep 0.2
	fi

	drain A 7; drain B 8;     trace "iter $i drained"

	t0=$(now_ms)
	out=$(psql_ctl -c "SELECT memcow_lane_reset($DBOID)")
	t1=$(now_ms);             trace "iter $i reset"
	if [ "$out" != "$epoch_expected" ]; then
		fail "iteration $i: reset returned [$out], expected epoch $epoch_expected"
		break
	fi
	LAT[${#LAT[@]}]=$((t1 - t0))

	if [ $FENCE_EVERY -gt 0 ] && [ $((i % FENCE_EVERY)) -eq 0 ]; then
		alive=$(psql_ctl -c "SELECT count(*) FROM pg_stat_activity WHERE pid = $PID_S")
		[ "$alive" = 0 ] || fail "iteration $i: straggler $PID_S survived the reset"
		sess_close S 9
	fi

	st=$(psql_ctl -c "SELECT state || '|' || epoch || '|' || attached_old || '|' || reclaim_pending FROM memcow_lane_status($DBOID)")
	[ "$st" = "RESETTING|$epoch_expected|0|false" ] || fail "iteration $i: status after reset: $st"

	n=$(dsm_files)
	if [ "$n" != "$DSM_BASE" ]; then
		fail "iteration $i: DSM segment count $n != baseline $DSM_BASE"
		# what is there, and who memcow thinks is attached to what
		ls -la "$PGDATA/pg_dynshmem" | sed 's/^/    /'
		for db in 0 $(psql_ctl -c "SELECT oid FROM pg_database ORDER BY oid"); do
			psql_ctl -c "SELECT '    slot $db: ' || state || ' epoch=' || epoch || ' bytes=' || arena_bytes || ' attached=' || attached || ' old=' || attached_old || ' reclaim=' || reclaim_pending FROM memcow_lane_status($db)"
		done | grep -v 'OPEN epoch=0 bytes=0 '
		sess_query A 7 "SELECT '    A ' || string_agg(name || '=' || value, ' ') FROM public.memcow_backend_counters()"
		sess_query B 8 "SELECT '    B ' || string_agg(name || '=' || value, ' ') FROM public.memcow_backend_counters()"
	fi
	d=$(data_minus_wal_kb)
	[ "$d" -le $((DATA_BASE + 2048)) ] || fail "iteration $i: pgdata-minus-wal ${d}kB grew past baseline ${DATA_BASE}kB"

	psql_ctl -c "SELECT memcow_lane_open($DBOID, false)" >/dev/null
	ea=$(sess_query A 7 "SELECT public.memcow_backend_reset()")
	eb=$(sess_query B 8 "SELECT public.memcow_backend_reset()")
	trace "iter $i adopted"
	[ "$ea" = "$epoch_expected" ] || fail "iteration $i: A adopted [$ea]"
	[ "$eb" = "$epoch_expected" ] || fail "iteration $i: B adopted [$eb]"

	dg=$(sess_query A 7 "$DIGEST_SQL")
	[ "$dg" = "$DIGEST_SEED" ] || fail "iteration $i: digest on retained A: $dg"
	if [ $((i % 2)) -eq 0 ]; then
		dg=$(sess_query B 8 "SELECT count(*) || '|' || (SELECT count(*) FROM pg_class WHERE relname LIKE 'soak%') FROM public.events")
		[ "$dg" = "4000|0" ] || fail "iteration $i: cross-epoch artifact on retained B: $dg"
	fi
	if [ $FRESH_EVERY -gt 0 ] && [ $((i % FRESH_EVERY)) -eq 0 ]; then
		dg=$(psql -c "$DIGEST_SQL")
		[ "$dg" = "$DIGEST_SEED" ] || fail "iteration $i: digest on a fresh connection: $dg"
	fi
	trace "iter $i verified"

	if [ $((i % 100)) -eq 0 ]; then
		printf 'iteration %d: epoch %d, dsm=%s, pgdata-minus-wal=%skB, wal=%skB, last reset %sms\n' \
			"$i" "$epoch_expected" "$n" "$d" "$(pgwal_kb)" "$((t1 - t0))"
	fi
	[ $FAIL -eq 0 ] || break
done
t_end=$(now_ms)

# leak / crash scan, as in the slice tests
hits=$(grep -nE 'TRAP: |PANIC:|was terminated by signal|leaked AIO handle|AIO handle was not submitted|refcount leak|resource was not closed|open AIO batch at end' "$LOGFILE" 2>/dev/null)
[ -z "$hits" ] || fail "server log shows an assert/crash/leak:"$'\n'"$hits"

# latency summary (informational here; §7.4 owns the thresholds)
if [ ${#LAT[@]} -gt 0 ]; then
	sorted=$(printf '%s\n' "${LAT[@]}" | sort -n)
	cnt=${#LAT[@]}
	p50=$(printf '%s\n' "$sorted" | sed -n "$(( (cnt + 1) / 2 ))p")
	p99=$(printf '%s\n' "$sorted" | sed -n "$(( (cnt * 99 + 99) / 100 ))p")
	printf 'resets: %d   reset latency p50=%sms p99=%sms   wall=%ss\n' "$cnt" "$p50" "$p99" "$(( (t_end - t_start) / 1000 ))"
fi

{
	echo "iterations=$ITER"; echo "completed=${#LAT[@]}"; echo "rc=$FAIL"
} >"$OUTPUTDIR/soak_status.txt"

if [ $FAIL -eq 0 ]; then
	mc_banner "RESET SOAK PASS -- $ITER resets, DSM flat at $DSM_BASE segments, digest stable"
else
	mc_banner "RESET SOAK FAIL" "logs: $OUTPUTDIR"
fi
exit $FAIL
