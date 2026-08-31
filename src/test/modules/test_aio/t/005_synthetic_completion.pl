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
	$node->stop();
}

done_testing();


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
