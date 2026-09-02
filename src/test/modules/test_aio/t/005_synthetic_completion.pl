# Copyright (c) 2025-2026, PostgreSQL Global Development Group
#
# TEMPORARY SCAFFOLDING for pgtest/memcow commit 1.2 - not for merge.
#
# Exercises pgaio_io_complete_synthetic() via
# test_aio.read_rel_block_synthetic(), which imitates what a memory-backed
# smgr's smgr_startreadv() does: put the page contents into the target
# buffers itself, then drive the AIO handle to completion by hand.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use TestAio;

my @methods = TestAio::supported_io_methods();

foreach my $method (@methods)
{
	my $node = PostgreSQL::Test::Cluster->new("synth_$method");

	$node->init();
	$node->append_conf('postgresql.conf', "io_method=$method");
	TestAio::configure($node);

	# Deliberately tiny, so that a handle leaked by the synthetic path
	# exhausts the pool almost immediately instead of hiding.
	$node->append_conf('postgresql.conf', 'io_max_concurrency=4');

	$node->start();
	test_synthetic($method, $node);
	test_concurrent_waiter($method, $node);
	test_backend_exit_churn($method, $node);

	# Same again at the minimum pool size, where a single unreclaimed
	# handle would already be fatal, and with batch mode on top of it.
	$node->append_conf('postgresql.conf', 'io_max_concurrency=1');
	$node->restart();
	test_min_concurrency($method, $node);

	$node->stop();
}

done_testing();


# Feed a query to a background psql WITHOUT waiting for it, so that the
# session can block somewhere and be observed from the outside.
sub issue_background
{
	my ($psql, $sql) = @_;

	$psql->{stdout} = '';
	$psql->{stderr} = '';
	$psql->{stdin} .= "$sql\n;\n";
	$psql->{run}->pump_nb();
	note "issued in background: $sql";
}

# Wait, with a HARD timeout, for a background session's stdout to match.
# Returns 1 on success and 0 on timeout or on the process dying; on timeout
# it also reports what the session was doing according to pg_stat_activity,
# which is the observation that matters when something hangs.  Match
# through the trailing newline so that nothing is left over for the next
# foreground query.
sub wait_for_stdout
{
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($node, $psql, $pid, $secs, $re, $name) = @_;

	# The session's timer is an IPC::Run::timeout: it throws from inside
	# pump() when it expires, which is what turns a hang into a failure.
	$psql->{timeout}->start($secs);
	my $ok = eval {
		pump_until($psql->{run}, $psql->{timeout}, \$psql->{stdout}, $re);
	};
	my $err = $@;
	if ($ok)
	{
		# consumed; the next foreground query must not see it
		$psql->{stdout} = '';
		$psql->{stderr} = '';
	}
	else
	{
		my $act = $node->safe_psql('postgres',
			qq(SELECT wait_event_type, wait_event, state, query
			   FROM pg_stat_activity WHERE pid = $pid));
		diag(
			"$name: no match for $re within ${secs}s; error: $err\n"
			  . "  stdout: $psql->{stdout}\n"
			  . "  stderr: $psql->{stderr}\n"
			  . "  pg_stat_activity for pid $pid: $act");
	}
	ok($ok, $name);
	return $ok;
}

sub pg_aios_row
{
	my ($psql, $pid) = @_;

	return $psql->query_safe(
		qq(SELECT operation, f_sync, length, state, handle_data_len, target
		   FROM pg_aios WHERE pid = $pid));
}

# ---------------------------------------------------------------------
# A backend that finds a buffer BM_IO_IN_PROGRESS because of a synthetic
# completion in progress in ANOTHER backend must wait for that IO the way
# pgaio_io_complete_synthetic() promises: via the handle's condition
# variable, never via the IO method's wait_one().  The flag that makes
# that happen is PGAIO_HF_SYNCHRONOUS, and pg_aios exposes it as f_sync.
#
# Session A parks inside pgaio_io_process_completion() -- test_aio's hook
# on the "aio-process-completion-before-shared" injection point -- with its
# synthetic handle past HANDED_OUT and visible to every other backend.
# Session C then reads the handle out of pg_aios from the outside: that is
# the assertion that the flag is really on a live handle, and it is also
# the iov_byte_length() sanity check for a handle whose op_data was reset
# to an empty iovec.  Session B reads the same block and must block in
# WaitIO -> pgaio_io_wait() on the condition variable (AioIoCompletion);
# after C releases A, B has to finish with the right answer.
#
# Note what the injection point CAN and CANNOT show.  It fires after the
# handle has already been moved to COMPLETED_IO, and pgaio_io_wait() only
# consults PGAIO_HF_SYNCHRONOUS while the handle is SUBMITTED, so a waiter
# arriving here takes the condition-variable path with or without the
# flag.  The window the flag actually protects is the one between
# pgaio_io_prepare_submit() and pgaio_io_process_completion(), and it has
# no injection point.  This test therefore proves that the flag is SET on
# a synthetic handle and that the cross-backend wait completes; it does
# not, by itself, prove that removing the flag would hang io_uring.
# ---------------------------------------------------------------------
sub test_concurrent_waiter
{
	my ($io_method, $node) = @_;
	my $t = "$io_method: concurrent waiter";

	my $psql_a = $node->background_psql('postgres', on_error_stop => 0);
	my $psql_b = $node->background_psql('postgres', on_error_stop => 0);
	my $psql_c = $node->background_psql('postgres', on_error_stop => 0);

	$psql_c->query_safe(
		qq(
CREATE TABLE tbl_synth_wait(data int not null) WITH (AUTOVACUUM_ENABLED = false);
INSERT INTO tbl_synth_wait SELECT generate_series(1, 1000);
CHECKPOINT;
SELECT evict_rel('tbl_synth_wait');
));

	my $pid_a = $psql_a->query_safe('SELECT pg_backend_pid()');
	my $pid_b = $psql_b->query_safe('SELECT pg_backend_pid()');

	# A: park in the completion hook of the next IO on block 0 of the table.
	$psql_a->query_safe(
		qq/SELECT inj_io_completion_wait(pid => $pid_a,
		   relfilenode => pg_relation_filenode('tbl_synth_wait'),
		   blockno => 0)/);

	issue_background($psql_a,
		q(SELECT read_rel_block_synthetic('tbl_synth_wait', 0, nblocks => 1, result_blocks => 1);
SELECT 'A_DONE'));
	$node->poll_query_until('postgres',
		qq(SELECT wait_event FROM pg_stat_activity WHERE pid = $pid_a),
		'completion_wait')
	  or die "A never reached the completion injection point";
	ok(1, "$t: A parked inside pgaio_io_process_completion()");

	# C: the handle, seen from a different backend.
	my $row = pg_aios_row($psql_c, $pid_a);
	is( $row,
		'readv|t|0|COMPLETED_IO|1|smgr',
		"$t: pg_aios shows A's synthetic handle with op=readv, f_sync=t, length=0"
	);
	note "$t: pg_aios row for A's handle: $row";

	# Every column, including target_desc, must be readable mid-flight.
	is( $psql_c->query_safe(
			qq(SELECT count(*) FROM pg_aios
			   WHERE pid = $pid_a AND target_desc IS NOT NULL
			     AND f_localmem = false)),
		'1',
		"$t: full pg_aios row is readable while A is mid-flight");

	# B: touch the same block; it must find it BM_IO_IN_PROGRESS and wait.
	issue_background($psql_b, 'SELECT count(*) FROM tbl_synth_wait');
	$node->poll_query_until('postgres',
		qq(SELECT wait_event FROM pg_stat_activity WHERE pid = $pid_b),
		'AioIoCompletion')
	  or die "B never blocked on A's IO";
	ok(1,
		"$t: B blocked in AioIoCompletion (the condition variable, not wait_one)"
	);

	# Still parked, still exactly one handle, still flagged.
	is(pg_aios_row($psql_c, $pid_a),
		'readv|t|0|COMPLETED_IO|1|smgr',
		"$t: handle unchanged while B waits on it");
	# Nothing of B's was ever submitted: B waits in WaitIO() before it
	# defines an IO of its own.
	is( $psql_c->query_safe(
			qq(SELECT count(*) FROM pg_aios
			   WHERE pid <> $pid_a AND state <> 'HANDED_OUT')),
		'0', "$t: no handle of B's is past HANDED_OUT");
	note "$t: pg_aios rows for B: "
	  . $psql_c->query_safe(
		qq(SELECT state, operation FROM pg_aios WHERE pid = $pid_b));

	# C: release A.
	$psql_c->query_safe('SELECT inj_io_completion_continue()');

	wait_for_stdout($node, $psql_a, $pid_a, 60, qr/^A_DONE\n/m,
		"$t: A's synthetic read returned after wakeup");
	wait_for_stdout($node, $psql_b, $pid_b, 60, qr/^1000\n/m,
		"$t: B completed with the right answer within the timeout");

	is( $psql_c->query_safe('SELECT count(*) FROM pg_aios'),
		'0', "$t: no handle left in flight");
	is( $psql_a->query_safe('SELECT sum(data) FROM tbl_synth_wait'),
		'500500', "$t: A sees the right contents afterwards");

	$psql_a->quit();
	$psql_b->quit();
	$psql_c->quit();
}

# ---------------------------------------------------------------------
# Backends that issue synthetic reads and then exit, repeatedly: the
# per-backend AIO state (in-flight list, handle pool, io_uring ring) has
# to be torn down cleanly each time.
# ---------------------------------------------------------------------
sub test_backend_exit_churn
{
	my ($io_method, $node) = @_;
	my $t = "$io_method: backend exit churn";

	my $log_before = -s $node->logfile;

	for my $i (1 .. 10)
	{
		my $out = $node->safe_psql(
			'postgres', qq(
SELECT evict_rel('tbl_synth');
SELECT read_rel_block_synthetic('tbl_synth', 0, nblocks => 4, result_blocks => 4);
SELECT read_rel_block_synthetic('tbl_synth', 4, nblocks => 2, result_blocks => 1);
SELECT sum(data) FROM tbl_synth;
));
		$out =~ s/^\s+//;
		is($out, '50005000', "$t: iteration $i") or last;
	}

	is($node->safe_psql('postgres', 'SELECT count(*) FROM pg_aios'),
		'0', "$t: no handle in flight after all backends exited");

	my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_before);
	unlike(
		$log,
		qr/(TRAP|PANIC|leak|not reclaimed|still in flight)/i,
		"$t: no assertion, PANIC or leak report in the server log");
}

# ---------------------------------------------------------------------
# io_max_concurrency=1: the pool holds a single handle, so the synthetic
# path has to reclaim it before the next acquisition or the second call
# blocks forever in pgaio_io_acquire().  Batch mode on top: the
# completion must not depend on an eventual pgaio_submit_staged().
# ---------------------------------------------------------------------
sub test_min_concurrency
{
	my ($io_method, $node) = @_;
	my $t = "$io_method: io_max_concurrency=1";

	my $psql = $node->background_psql('postgres', on_error_stop => 0);
	my $pid = $psql->query_safe('SELECT pg_backend_pid()');

	is($psql->query_safe('SHOW io_max_concurrency'), '1', "$t: in effect");

	issue_background(
		$psql, q(
SELECT evict_rel('tbl_synth');
SELECT read_rel_block_synthetic('tbl_synth', 0, nblocks => 4, result_blocks => 4);
SELECT read_rel_block_synthetic('tbl_synth', 4, nblocks => 4, result_blocks => 4);
SELECT sum(data) FROM tbl_synth));
	wait_for_stdout($node, $psql, $pid, 60, qr/^50005000\n/m,
		"$t: two consecutive synthetic reads");

	# An AIO batch cannot outlive the statement that opened it (the
	# end-of-statement cleanup warns and closes it), so the explicit batch
	# has to live inside one statement.
	issue_background(
		$psql, q(
SELECT evict_rel('tbl_synth');
DO $$
BEGIN
  PERFORM batch_start();
  PERFORM read_rel_block_synthetic('tbl_synth', 0, nblocks => 4, result_blocks => 4);
  PERFORM read_rel_block_synthetic('tbl_synth', 4, nblocks => 4, result_blocks => 4);
  PERFORM batch_end();
END $$;
SELECT sum(data) FROM tbl_synth));
	wait_for_stdout($node, $psql, $pid, 60, qr/^50005000\n/m,
		"$t: two synthetic reads inside one explicit batch");

	issue_background(
		$psql, q(
DO $$
BEGIN
  FOR i IN 1..200 LOOP
    PERFORM evict_rel('tbl_synth');
    PERFORM read_rel_block_synthetic('tbl_synth', 0, nblocks => 4, result_blocks => 4, batchmode => true);
  END LOOP;
END $$;
SELECT sum(data) FROM tbl_synth));
	wait_for_stdout($node, $psql, $pid, 120, qr/^50005000\n/m,
		"$t: 200 batchmode synthetic reads");

	is($psql->query_safe('SELECT count(*) FROM pg_aios'),
		'0', "$t: no handle in flight");
	like($psql->{stderr}, qr/^\s*$/, "$t: no errors on stderr");

	$psql->quit();
}


sub psql_like
{
	local $Test::Builder::Level = $Test::Builder::Level + 1;
	my ($io_method, $psql, $name, $sql, $expected_stdout, $expected_stderr) =
	  @_;
	my ($cmdret, $output);

	($output, $cmdret) = $psql->query($sql);

	like($output, $expected_stdout, "$io_method: $name: expected stdout");
	like($psql->{stderr}, $expected_stderr,
		"$io_method: $name: expected stderr");
	$psql->{stderr} = '';

	return $output;
}

sub test_synthetic
{
	my $io_method = shift;
	my $node = shift;

	my $psql = $node->background_psql('postgres', on_error_stop => 0);

	$psql->query_safe(
		qq(
CREATE EXTENSION test_aio;
CREATE TABLE tbl_synth(data int not null) WITH (AUTOVACUUM_ENABLED = false);
INSERT INTO tbl_synth SELECT generate_series(1, 10000);
CREATE TABLE tbl_synth_corr(data int not null) WITH (AUTOVACUUM_ENABLED = false);
INSERT INTO tbl_synth_corr SELECT generate_series(1, 10000);
CREATE TEMPORARY TABLE tbl_synth_temp(data int not null) WITH (AUTOVACUUM_ENABLED = false);
INSERT INTO tbl_synth_temp SELECT generate_series(1, 5000);
CHECKPOINT;
));

	# Baseline: what the relation actually contains.
	my $expected = $psql->query_safe(q(SELECT sum(data) FROM tbl_synth));
	is($expected, '50005000', "$io_method: baseline sum");

	# ---------------------------------------------------------------
	# The happy path: a multi-block synthetic completion has to leave
	# the buffers valid and holding the right contents.
	# ---------------------------------------------------------------
	psql_like(
		$io_method,
		$psql,
		"synthetic read, 4 blocks",
		qq(
SELECT evict_rel('tbl_synth');
SELECT read_rel_block_synthetic('tbl_synth', 0, nblocks => 4, result_blocks => 4);
),
		qr/^$/,
		qr/^$/);

	psql_like(
		$io_method,
		$psql,
		"contents after synthetic read",
		qq(SELECT sum(data) FROM tbl_synth),
		qr/^50005000$/,
		qr/^$/);

	# The handle must have been reclaimed before the function returned.
	psql_like(
		$io_method, $psql,
		"no handle left in flight",
		qq(SELECT count(*) FROM pg_aios),
		qr/^0$/, qr/^$/);

	# ---------------------------------------------------------------
	# Same, inside an open AIO batch. The synthetic completion is
	# expected to ignore batching entirely.
	# ---------------------------------------------------------------
	psql_like(
		$io_method,
		$psql,
		"synthetic read in batchmode",
		qq(
SELECT evict_rel('tbl_synth');
SELECT read_rel_block_synthetic('tbl_synth', 0, nblocks => 4, result_blocks => 4, batchmode => true);
SELECT sum(data) FROM tbl_synth;
),
		qr/50005000/,
		qr/^$/);

	# ---------------------------------------------------------------
	# Local buffers: the other pre-registered completion callback.
	# ---------------------------------------------------------------
	psql_like(
		$io_method,
		$psql,
		"synthetic read of temp rel",
		qq(
SELECT evict_rel('tbl_synth_temp');
SELECT read_rel_block_synthetic('tbl_synth_temp', 0, nblocks => 2, result_blocks => 2);
SELECT sum(data) FROM tbl_synth_temp;
),
		qr/12502500/,
		qr/^$/);

	# ---------------------------------------------------------------
	# Many iterations with io_max_concurrency=4: a handle that is not
	# reclaimed, or an in-flight list that is not maintained, cannot
	# survive this.
	# ---------------------------------------------------------------
	psql_like(
		$io_method,
		$psql,
		"synthetic read repeated 500x",
		qq(
DO \$\$
BEGIN
  FOR i IN 1..500 LOOP
    PERFORM evict_rel('tbl_synth');
    PERFORM read_rel_block_synthetic('tbl_synth', 0, nblocks => 4, result_blocks => 4);
  END LOOP;
END \$\$;
SELECT sum(data) FROM tbl_synth;
),
		qr/50005000/,
		qr/^$/);

	# ---------------------------------------------------------------
	# Proof that the completion callbacks really ran: a page that fails
	# verification has to be reported, exactly as for a real md read.
	# ---------------------------------------------------------------
	psql_like(
		$io_method,
		$psql,
		"corrupt page detected through synthetic completion",
		qq(
SELECT modify_rel_block('tbl_synth_corr', 3, corrupt_checksum => true);
SELECT read_rel_block_synthetic('tbl_synth_corr', 3, nblocks => 1, result_blocks => 1);
),
		qr/^$/,
		qr/ERROR:.*invalid page in block 3 of relation/);

	# ---------------------------------------------------------------
	# A short synthetic result is interpreted in BLOCKS: with
	# result_blocks => 2 of 4, blocks 0 and 1 are treated as read and
	# blocks 2 and 3 are simply left invalid for the caller to
	# re-issue (buffer_readv_complete(): failed = result <= buf_off).
	# It must not error, corrupt anything, or unbalance the pins.
	# ---------------------------------------------------------------
	psql_like(
		$io_method,
		$psql,
		"short synthetic result counted in blocks",
		qq(
SELECT evict_rel('tbl_synth');
SELECT read_rel_block_synthetic('tbl_synth', 0, nblocks => 4, result_blocks => 2);
SELECT sum(data) FROM tbl_synth;
),
		qr/50005000/,
		qr/^$/);

	# No leak reported at transaction end, and the pool is still healthy.
	psql_like(
		$io_method,
		$psql,
		"no leak after all of the above",
		qq(BEGIN; SELECT count(*) FROM pg_aios; COMMIT;),
		qr/^0$/,
		qr/^$/);

	$psql->quit();
}
