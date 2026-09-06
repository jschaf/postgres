# Copyright (c) 2026, PostgreSQL Global Development Group
# Persistent-session slices. The shell entry point supplies the exact seed,
# verified RAM PGDATA, case identity and control selection.
use FindBin;
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use File::Copy ();
use File::Compare qw(compare);
use Time::HiRes qw(usleep);

my ($case, $negative, $pgdata, $seed, $db, $control, $user) = @ARGV;
my $node = PostgreSQL::Test::Cluster->new('memcow');
# Cluster owns server/session lifecycle; the assembled RAM data stays external.
symlink $pgdata, $node->data_dir or die "link RAM PGDATA: $!";
my $options = "-c memcow.enabled=on -c memcow.seed_directory=$seed"
  . " -c shared_preload_libraries=memcow -c listen_addresses=''"
  . " -c unix_socket_directories=" . $node->host . " -p " . $node->port
  . " -c fsync=off -c restart_after_crash=off -c log_min_messages=warning"
  . " -c log_statement=none";
$options .= ' -c dynamic_shared_memory_type=mmap' if $case eq 'S18_reset_retry';
$options .= ' -c bgwriter_lru_maxpages=0' if $case eq 'R4_checkpoint_discard';
$options .= ' -c io_method=worker -c shared_preload_libraries=memcow,test_aio' if $case eq 'R3_cancel_inflight_io' && !$negative;
$options .= ' -c log_connections=authentication,authorization' if $case eq 'R1_auth_window' && !$negative;
$node->start(options => $options);

# SQL with expected errors returns stderr as well as stdout, just as the
# original slices did. Multiple arguments remain separate commands (VACUUM).
sub sql
{
    my ($database, @commands) = @_;
    my ($out, $err) = ('', '');
    $node->psql($database, '', stdout => \$out, stderr => \$err,
        on_error_stop => 0, extra_params => [ '-U', $user,
            map { ('-c', $_) } @commands ]);
    return $out . ($out ne '' && $err ne '' ? "\n" : '') . $err;
}
sub ctl { return sql($control, @_); }
sub lane { return sql($db, @_); }
sub status { return ctl("SELECT $_[1] FROM memcow_lane_status($_[0])"); }
sub background
{
    my ($database, $timeout) = @_;
    my $p = $node->background_psql($database // $db, on_error_stop => 0,
        timeout => $timeout // 30, extra_params => ['-U', $user]);
    $p->set_query_timer_restart;
    return $p;
}
sub wait_event
{
    my ($pid, $event, $timeout) = @_;
    local $PostgreSQL::Test::Utils::timeout_default = $timeout // 20;
    local $ENV{PGUSER} = $user;
    return $node->poll_query_until($control,
        "SELECT wait_event FROM pg_stat_activity WHERE pid = $pid", $event);
}
sub gone
{
    my ($pid) = @_;
    local $PostgreSQL::Test::Utils::timeout_default = 20;
    local $ENV{PGUSER} = $user;
    return $node->poll_query_until($control,
        "SELECT count(*) FROM pg_stat_activity WHERE pid = $pid", '0');
}
sub attach
{
    my ($point, $action, $condition) = @_;
    return ctl("SELECT injection_points_attach('$point', '$action'"
        . (defined $condition ? ", '$condition'" : '') . ')');
}
sub detach { ctl("SELECT injection_points_detach('$_[0]')"); }
sub wake { ctl("SELECT injection_points_wakeup('$_[0]')"); }
sub buffers { return ctl("SELECT count(*) FROM pg_buffercache WHERE reldatabase = $_[0] " . ($_[1] // '')); }
sub dsm_files { my @files = glob "$pgdata/pg_dynshmem/mmap.*"; return scalar @files; }

ctl('CREATE EXTENSION IF NOT EXISTS memcow');
my $oid = ctl("SELECT oid FROM pg_database WHERE datname = '$db'");
like($oid, qr/^[0-9]+$/, 'lane database oid resolved');

sub S11_reset_reverts
{
    if ($negative)
    {
        lane("UPDATE public.events SET kind = 'epoch-zero' WHERE event_id = 1; CHECKPOINT;");
        ctl("SELECT memcow_lane_open($oid, false)");
        like(lane("SELECT 'kind', kind FROM public.events WHERE event_id = 1"),
            qr/^kind\|epoch-zero$/m, 'sabotage detected: without a reset the epoch-0 write persists');
        return;
    }
    my $digest_query = "SELECT md5(string_agg(relname || ':' || nrows || ':' || digest, ',' ORDER BY relname)) FROM public.memcow_seed_digest";
    my $digest = lane($digest_query);
    like($digest, qr/^[0-9a-f]{32}$/, 'seed digest taken before the workload');
    my $out = lane(q{
UPDATE public.events SET kind = 'epoch-zero' WHERE event_id = 1;
CREATE TABLE s11_new AS SELECT 42 AS x;
DROP TABLE public.staging CASCADE;
CHECKPOINT;
SELECT 'kind', kind FROM public.events WHERE event_id = 1;
SELECT 'new', count(*) FROM pg_class WHERE relname = 's11_new';
SELECT 'staging', count(*) FROM pg_class WHERE relname = 'staging';
});
    like($out, qr/^kind\|epoch-zero$/m, 'epoch 0: the updated row is visible');
    like($out, qr/^new\|1$/m, 'epoch 0: the created relation exists');
    like($out, qr/^staging\|0$/m, 'epoch 0: the dropped seed relation is gone');
    my $a = background();
    my $pid = $a->query_safe('SELECT pg_backend_pid()');
    like($pid, qr/^[0-9]+$/, 'retained session A connected');
    like($a->query_safe("SELECT 'kind', kind FROM public.events WHERE event_id = 1"),
        qr/^kind\|epoch-zero$/m, 'session A saw the epoch-0 page (so its caches are warm)');
    unlike(ctl("SELECT memcow_lane_register($oid, $pid)"), qr/ERROR/, 'session A registered with the lane');
    is(ctl("SELECT memcow_lane_reset($oid)"), '1', 'memcow_lane_reset(D) returned epoch 1');
    ok(!-e "$pgdata/base/$oid/pg_internal.init", 'reset removed base/<D>/pg_internal.init');
    is(compare("$pgdata/base/$oid/pg_filenode.map", "$seed/base/$oid/pg_filenode.map"), 0,
        "base/<D>/pg_filenode.map is byte-identical to the seed's");
    is(status($oid, 'state'), 'RESETTING', 'lane state after reset is RESETTING (admission closed)');
    like(lane('SELECT 1'), qr/FATAL:.*lane.*not open/, 'a new connection is refused while the lane is RESETTING');
    is(ctl("SELECT memcow_lane_open($oid, false)"), '0', 'memcow_lane_open(D, arm => false) returns nonce 0');
    is(status($oid, 'state'), 'OPEN', 'lane state is OPEN');
    my $contents = q{
SELECT 'kind', kind FROM public.events WHERE event_id = 1;
SELECT 'new', count(*) FROM pg_class WHERE relname = 's11_new';
SELECT 'staging', count(*) FROM public.staging;
};
    $out = lane($contents, "SELECT 'events', count(*) FROM public.events");
    like($out, qr/^kind\|logout$/m, 'fresh backend: the seed row is back');
    like($out, qr/^new\|0$/m, 'fresh backend: the epoch-0 relation is gone');
    like($out, qr/^staging\|1000$/m, 'fresh backend: the dropped seed relation is back');
    like($out, qr/^events\|4000$/m, "fresh backend: events has the seed's 4000 rows");
    is(lane($digest_query), $digest, "fresh backend: seed digest equals the seed's own");
    is($a->query_safe('SELECT public.memcow_backend_reset()'), '1', 'session A: memcow_backend_reset() adopted epoch 1');
    $out = $a->query_safe($contents);
    like($out, qr/^kind\|logout$/m, 'session A: the seed row is back');
    like($out, qr/^new\|0$/m, 'session A: the epoch-0 relation is gone');
    like($out, qr/^staging\|1000$/m, 'session A: the dropped seed relation is back');
    unlike($out, qr/ERROR|FATAL/, 'session A: no error while adopting');
    my $nonce = ctl("SELECT memcow_lane_open($oid, true)");
    like($nonce, qr/^[1-9][0-9]*$/, 'memcow_lane_open(D, arm => true) returns a nonce');
    like(lane('SELECT 1'), qr/FATAL:.*nonce/, 'armed lane: a connection without the nonce is refused');
    {
        local $ENV{PGOPTIONS} = '-c memcow.lane_nonce=' . ($nonce + 1);
        like(lane('SELECT 1'), qr/FATAL:.*nonce/, 'armed lane: a connection with a stale nonce is refused');
        $ENV{PGOPTIONS} = "-c memcow.lane_nonce=$nonce";
        like(lane('SELECT 1'), qr/^1$/, 'armed lane: a connection with the current nonce is admitted');
    }
    is($a->query_safe('SELECT 1'), '1', 'retained session A is unaffected by arming');
    $a->quit;
}

sub S13_reset_invalidates_pin
{
    my $a = background();
    my $pid = $a->query_safe('SELECT pg_backend_pid()');
    ctl("SELECT memcow_lane_register($oid, $pid)") unless $negative;
    lane('CREATE EXTENSION IF NOT EXISTS pg_prewarm');
    like($a->query_safe("SELECT 'rows', count(*) FROM public.events"), qr/^rows\|4000$/m,
        'session A sized public.events at epoch 0');
    my $before = $a->query_safe("SELECT value FROM public.memcow_backend_counters() WHERE name = 'nblocks_pin_refresh'");
    like($before, qr/^[0-9]+$/, 'counter readable');
    unless ($negative)
    {
        is(ctl("SELECT memcow_lane_reset($oid)"), '1', 'reset -> epoch 1');
        ctl("SELECT memcow_lane_open($oid, false)");
        is($a->query_safe('SELECT public.memcow_backend_reset()'), '1', 'session A adopted epoch 1');
    }
    $a->{timeout}->interval(60);
    my $out = $a->query(q{
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
DELETE FROM public.events;
VACUUM (TRUNCATE on) public.events;
SELECT 'nblocks', pg_prewarm('public.events', 'prefetch', 'main');
SELECT name || '=' || value FROM public.memcow_backend_counters()
 WHERE name IN ('nblocks_pin_refresh', 'truncate_pinned', 'truncate_unpinned');
});
    $a->{timeout}->interval(30);
    $out .= "\n" . $a->{stderr};
    $a->{stderr} = '';
    unlike($out, qr/ERROR|FATAL|server closed/, 'session A: DELETE + VACUUM raised no error and did not crash');
    like($out, qr/^nblocks\|0$/m, 'session A: the fork is 0 blocks after the truncate');
    my ($after) = $out =~ /^nblocks_pin_refresh=(\d+)$/m;
    if ($negative)
    {
        is($after, $before, 'sabotage detected: without a reset the pin is not refreshed');
        like($out, qr/^truncate_pinned=[1-9]/m, '... while the truncate still used the pin');
    }
    else
    {
        cmp_ok($after, '>', $before, "the stale epoch-0 pin was detected and refreshed ($before -> " . ($after // '?') . ')');
        like($out, qr/^truncate_pinned=[1-9]/m, 'the truncate went through the (fresh) pinned record');
        like($out, qr/^truncate_unpinned=0$/m, 'the truncate never needed the unwarmed fallback');
        like(lane("SELECT 'rows', count(*) FROM public.events"), qr/^rows\|0$/m, 'a fresh backend sees the epoch-1 truncate');
        is(ctl("SELECT memcow_lane_reset($oid)"), '2', 'reset -> epoch 2');
        ctl("SELECT memcow_lane_open($oid, false)");
        like(lane("SELECT 'rows', count(*) FROM public.events"), qr/^rows\|4000$/m, 'epoch 2: the truncate is reverted');
    }
    $a->quit;
}

# A command may park repeatedly on the same injection point. Observe server
# state while waking it, then let background_psql consume its completion.
sub wake_until_idle
{
    my ($pid, $point, $timeout) = @_;
    for (1 .. $timeout)
    {
        return 1 if ctl("SELECT count(*) FROM pg_stat_activity WHERE pid = $pid AND state <> 'idle'") eq '0';
        wake($point);
        usleep(1_000_000);
    }
    diag("timeout after ${timeout}s releasing $point for backend $pid");
    return 0;
}

sub S14_reset_vs_truncate
{
    lane('CREATE EXTENSION IF NOT EXISTS injection_points');
    ctl('CREATE EXTENSION IF NOT EXISTS injection_points');
    my $b = background();
    my $pid = $b->query_safe('SELECT pg_backend_pid()');
    ctl("SELECT memcow_lane_register($oid, $pid)");
    if ($negative)
    {
        $b->{timeout}->interval(60);
        $b->query_safe('DELETE FROM public.events; VACUUM (TRUNCATE on) public.events;');
        $b->{timeout}->interval(30);
        is(ctl("SELECT memcow_lane_reset($oid, 2000)"), '1',
            'sabotage detected: with nothing in flight the reset is NOT refused');
        $b->quit;
        return;
    }
    my $arm = q{
CREATE EXTENSION IF NOT EXISTS injection_points;
SELECT injection_points_set_local();
SELECT injection_points_attach('memcow-truncate-before-whiteout', 'wait');
SELECT injection_points_load('memcow-truncate-before-whiteout');
DELETE FROM public.events;
};
    my $out = $b->query($arm);
    unlike($b->{stderr}, qr/ERROR/, 'session B armed the injection point and emptied events');
    $b->{stderr} = '';
    $b->query_until(qr/truncate started/, "\\echo truncate started\nVACUUM (TRUNCATE on) public.events;\n");
    ok(wait_event($pid, 'memcow-truncate-before-whiteout', 20), 'session B is parked inside memcow_truncate()');
    like(ctl("SELECT memcow_lane_reset($oid, 2000)"), qr/ERROR:.*(not idle|active)/,
        'reset REFUSED: a registered backend is not idle');
    is(status($oid, 'epoch'), '0', 'epoch unchanged after the refusal');
    is(status($oid, 'state'), 'RESETTING', 'lane is closed (RESETTING) after the refusal');
    ok(wake_until_idle($pid, 'memcow-truncate-before-whiteout', 30), "session B's truncate completed after wakeup");
    $out = $b->query("SELECT injection_points_detach('memcow-truncate-before-whiteout'); SELECT 'rows', count(*) FROM public.events");
    like($out, qr/^rows\|0$/m, 'epoch 0 now holds the truncated relation');
    is(ctl("SELECT memcow_lane_reset($oid, 5000)"), '1', 'retry succeeds once B is idle -> epoch 1');
    ctl("SELECT memcow_lane_open($oid, false)");
    $out = $b->query_safe("SELECT public.memcow_backend_reset(); SELECT 'rows', count(*) FROM public.events");
    like($out, qr/^1$/m, 'session B adopted epoch 1');
    like($out, qr/^rows\|4000$/m, 'session B: the epoch-0 truncate is gone');
    like(lane("SELECT 'rows', count(*) FROM public.events"), qr/^rows\|4000$/m, 'fresh backend: the epoch-0 truncate is gone');

    ctl("SELECT memcow_lane_unregister($oid, $pid)");
    lane('CREATE EXTENSION IF NOT EXISTS injection_points');
    $b->query($arm);
    unlike($b->{stderr}, qr/ERROR/, 'session B re-armed the injection point at epoch 1');
    $b->{stderr} = '';
    $b->query_until(qr/truncate started/, "\\echo truncate started\nVACUUM (TRUNCATE on) public.events;\n");
    ok(wait_event($pid, 'memcow-truncate-before-whiteout', 20), 'session B is parked again');
    like(ctl("SELECT memcow_lane_reset($oid, 1500)"), qr/ERROR:.*(straggler|did not exit|timed out)/,
        'reset FAILS CLOSED: the straggler did not exit within the timeout');
    is(status($oid, 'epoch'), '1', 'epoch unchanged after the timeout');
    is(status($oid, 'state'), 'RESETTING', 'lane stays CLOSED (RESETTING) after the timeout, not retired');
    is(status($oid, 'reclaim_pending'), 'f', 'nothing was published (no reclaim pending)');
    wake_until_idle($pid, 'memcow-truncate-before-whiteout', 30);
    $b->{timeout}->interval(10);
    $b->{timeout}->start;
    $b->{run}->finish;
    like($b->{stderr}, qr/FATAL:.*terminating connection|server closed the connection|connection to server was lost/,
        'the straggler died of the SIGTERM once it left the critical section');
    ok(gone($pid), 'the straggler is gone from pg_stat_activity');
    is(ctl("SELECT memcow_lane_reset($oid, 5000)"), '2', 'retry succeeds once the straggler is gone -> epoch 2');
    ctl("SELECT memcow_lane_open($oid, false)");
    like(lane("SELECT 'rows', count(*) FROM public.events"), qr/^rows\|4000$/m, "epoch 2: the straggler's epoch-1 truncate is gone");
}

sub S18_reset_retry
{
    if ($negative)
    {
        is(ctl("SELECT memcow_lane_reset($oid)"), '1', 'control: first reset succeeds');
        is(status($oid, 'reclaim_pending'), 'f', 'control: no reclaim pending');
        is(ctl("SELECT memcow_lane_reset($oid)"), '2', 'control: another call publishes a new epoch');
        return;
    }
    ctl('CREATE EXTENSION IF NOT EXISTS injection_points');
    ctl("SELECT memcow_lane_reset($oid); SELECT memcow_lane_open($oid, false)");
    my $a = background();
    my $pid = $a->query_safe('SELECT pg_backend_pid()');
    ctl("SELECT memcow_lane_register($oid, $pid)");
    my $baseline = dsm_files();
    $a->query("UPDATE public.events SET kind = 'retry-old' WHERE event_id = 1; CHECKPOINT;");
    unlike($a->{stderr}, qr/ERROR/, 'old epoch workload succeeded');
    attach('memcow-lane-reset-in-sweep', 'error');
    like(ctl("SELECT memcow_lane_reset($oid)"), qr/ERROR:.*memcow-lane-reset-in-sweep/, 'failure names only the injected sweep error');
    is(status($oid, 'epoch'), '2', 'publication already advanced to epoch 2');
    is(status($oid, 'state'), 'RESETTING', 'failure leaves the lane closed');
    is(status($oid, 'reclaim_pending'), 't', 'old arena still awaits reclaim');
    like(ctl("SELECT memcow_lane_open($oid, false)"), qr/ERROR:.*did not complete/, 'cannot reopen an unfinished reset');
    detach('memcow-lane-reset-in-sweep');
    is(ctl("SELECT memcow_lane_reset($oid)"), '2', 'retry finishes the same epoch, without another publish');
    is(status($oid, 'attached_old'), '0', 'retry drained old attachments');
    is(status($oid, 'reclaim_pending'), 'f', 'retry finished reclaim');
    is(dsm_files(), $baseline, 'retry destroyed the old DSM segments');
    is($a->query_safe('SELECT public.memcow_backend_reset()'), '2', 'retained backend adopts epoch 2');
    is($a->query_safe('SELECT kind FROM public.events WHERE event_id = 1'), 'logout', 'retained backend reads seed content');
    ctl("SELECT memcow_lane_open($oid, false)");
    is(lane('SELECT kind FROM public.events WHERE event_id = 1'), 'logout', 'fresh backend reads seed content');
    $a->quit;
}

sub R2_stopped_straggler
{
    my $a;
    unless ($negative)
    {
        $a = background();
        my $pid = $a->query_safe('SELECT pg_backend_pid()');
        ctl("SELECT memcow_lane_register($oid, $pid)");
        $a->query_safe("UPDATE public.events SET kind = 'r2' WHERE event_id = 1");
    }
    my $s = background();
    my $pid = $s->query_safe('SELECT pg_backend_pid()');
    $s->query_until(qr/straggler started/, "\\echo straggler started\nBEGIN; UPDATE public.accounts SET balance = 0 WHERE account_id = 1; SELECT pg_sleep(60);\n");
    ok(wait_event($pid, 'PgSleep', 20), 'straggler is inside its query');
    if ($negative)
    {
        is(ctl("SELECT memcow_lane_reset($oid, 1500)"), '1',
            'sabotage detected: without the SIGSTOP the same reset succeeds at once');
        $s->{run}->finish;
        return;
    }
    ok(kill('STOP', $pid), 'straggler SIGSTOPped');
    # Always resume this child even if an assertion or SQL operation dies.
    my $out = eval { ctl("SELECT memcow_lane_reset($oid, 1500)") };
    my $error = $@;
    kill 'CONT', $pid if $error;
    die $error if $error;
    like($out, qr/ERROR:.*straggler backend [0-9]+ did not exit within/, 'reset FAILS CLOSED on its timeout: the straggler did not exit');
    like($out, qr/nothing was published/, '... and says the epoch is unchanged and nothing was published');
    is(status($oid, 'epoch'), '0', 'epoch unchanged');
    is(status($oid, 'state'), 'RESETTING', 'lane is closed (RESETTING), not retired');
    is(status($oid, 'reclaim_pending'), 'f', 'no reclaim pending (never published)');
    is(status($oid, 'attached_old'), '0', 'no old-epoch attachment');
    is(ctl("SELECT count(*) FROM pg_stat_activity WHERE pid = $pid"), '1', 'the stopped straggler is still there');
    kill 'CONT', $pid;
    ok(gone($pid), 'continued: the pending SIGTERM killed the straggler');
    $s->{timeout}->interval(5);
    $s->{timeout}->start;
    $s->{run}->finish;
    like($s->{stderr}, qr/FATAL:.*terminating connection|server closed the connection|connection to server was lost/,
        "the straggler's client saw the termination");
    is(ctl("SELECT memcow_lane_reset($oid, 5000)"), '1', 'retry succeeds -> epoch 1');
    ctl("SELECT memcow_lane_open($oid, false)");
    $out = $a->query_safe("SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1; SELECT 'bal', balance FROM public.accounts WHERE account_id = 1");
    like($out, qr/^1$/m, 'retained backend adopted epoch 1');
    like($out, qr/^kind\|logout$/m, 'epoch 1: the committed epoch-0 write is reverted');
    unlike($out, qr/^bal\|0$/m, "epoch 1: the straggler's uncommitted write is not there");
    $a->quit;
}

sub R3_cancel_inflight_io
{
    ctl('CREATE EXTENSION IF NOT EXISTS injection_points');
    my $l = background();
    my $pid = $l->query_safe('SELECT pg_backend_pid()');
    ctl("SELECT memcow_lane_register($oid, $pid)");
    if ($negative)
    {
        $l->query_safe("UPDATE public.events SET kind = 'r3' WHERE event_id = 1; CHECKPOINT;");
        attach('memcow-skip-stale-detach', 'notice');
        like(ctl("SELECT memcow_lane_reset($oid, 2000)"), qr/ERROR:.*still attached to epoch 0/,
            'sabotage detected: a backend that keeps its stale attachment makes RECLAIM refuse');
        is(status($oid, 'epoch'), '1', 'epoch was published');
        is(status($oid, 'reclaim_pending'), 't', 'reclaim pending');
        detach('memcow-skip-stale-detach');
        $l->quit;
        ok(gone($pid), 'retained backend exited');
        is(ctl("SELECT memcow_lane_reset($oid, 2000)"), '1', 'retry after removing sabotage finishes the same epoch');
        is(status($oid, 'attached_old'), '0', 'retry drained every old attachment, including the checkpointer');
        is(status($oid, 'reclaim_pending'), 'f', 'retry finished reclaim');
        ctl("SELECT memcow_lane_open($oid, false)");
        is(lane('SELECT kind FROM public.events WHERE event_id = 1'), 'logout', 'reopened lane reads seed content');
        return;
    }
    ctl('CREATE EXTENSION IF NOT EXISTS pg_buffercache');
    ctl('CREATE EXTENSION IF NOT EXISTS test_aio');
    my $rel = $l->query_safe("UPDATE public.events SET kind = 'r3' WHERE event_id = 1; CHECKPOINT; SELECT pg_relation_filenode('public.events')");
    like($rel, qr/^[0-9]+$/, 'epoch 0: events page written, relfilenode known');
    like(ctl("SELECT count(*) FROM (SELECT pg_buffercache_evict(bufferid) FROM pg_buffercache WHERE reldatabase = $oid) s"),
        qr/^[0-9]+$/, 'lane buffers evicted');
    ctl("SELECT inj_io_completion_wait(pid => $pid, relfilenode => $rel, blockno => 0)");
    $l->query_until(qr/read started/, "\\echo read started\nSELECT count(*) FROM public.events;\n");
    ok(wait_event($pid, 'completion_wait', 20), 'lane backend parked inside pgaio_io_process_completion(): IO in flight');
    is(ctl("SELECT pg_cancel_backend($pid)"), 't', 'cancel sent');
    usleep(500_000);
    is(ctl("SELECT wait_event FROM pg_stat_activity WHERE pid = $pid"), 'completion_wait',
        'the cancel is deferred while the IO is in flight (still parked)');
    ctl('SELECT inj_io_completion_continue()');
    $l->{timeout}->interval(20);
    my $out = $l->query('');
    $l->{timeout}->interval(30);
    $out .= $l->{stderr};
    pass('the statement finished after the IO completed');
    like($out, qr/ERROR:.*canceling statement/, 'the IO completed, then the cancel was processed: statement cancelled');
    unlike($out, qr/invalid page|server closed|PANIC/, 'no crash, no invalid page');
    $l->{stderr} = '';
    $l->query('ROLLBACK; DISCARD ALL;');
    is(ctl("SELECT state FROM pg_stat_activity WHERE pid = $pid"), 'idle', 'released: backend idle');
    is(ctl("SELECT memcow_lane_reset($oid, 5000)"), '1', 'reset does not wait on anything and succeeds -> epoch 1');
    my $st = ctl("SELECT attached_old || '|' || reclaim_pending || '|' || poisoned_pages FROM memcow_lane_status($oid)");
    like($st, qr/^0\|false\|/, 'no old-arena attachment, reclaim done');
    like($st, qr/\|[1-9][0-9]*$/, 'the old arena was POISONED at reclaim (>= 1 page, assert build)');
    ctl("SELECT memcow_lane_open($oid, false)");
    $l->{stderr} = '';
    $out = $l->query_safe("SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1; SELECT 'rows', count(*) FROM public.events");
    like($out, qr/^1$/m, 'retained backend adopted epoch 1');
    like($out, qr/^kind\|logout$/m, 'epoch 1: the re-read is seed content, not the poisoned old page');
    like($out, qr/^rows\|4000$/m, 'epoch 1: the whole relation reads clean');
    unlike($out, qr/invalid page|ERROR/, 'no invalid page anywhere');
    $l->quit;
}

sub R4_checkpoint_discard
{
    ctl('CREATE EXTENSION IF NOT EXISTS injection_points');
    ctl('CREATE EXTENSION IF NOT EXISTS pg_buffercache');
    my $ckpt = ctl("SELECT pid FROM pg_stat_activity WHERE backend_type = 'checkpointer'");
    like($ckpt, qr/^[0-9]+$/, 'checkpointer pid known');
    my $l = background();
    my $pid_l = $l->query_safe('SELECT pg_backend_pid()');
    ctl("SELECT memcow_lane_register($oid, $pid_l)");
    my $c = background($control, 60);
    my $pid_c = $c->query_safe('SELECT pg_backend_pid()');
    my $c2 = background($control, 30);
    my $pid_c2 = $c2->query_safe('SELECT pg_backend_pid()');
    ctl('CHECKPOINT');
    $l->query_safe("UPDATE public.events SET kind = 'r4' WHERE event_id = 1;"
        . ($negative ? '' : ' UPDATE public.accounts SET balance = 0 WHERE account_id = 1;'));
    attach('memcow-writev-skip-discard', 'notice') if $negative;
    attach('memcow-checkpointer-writev', 'wait', $oid);
    $c2->query_until(qr/checkpoint started/, "\\echo checkpoint started\nCHECKPOINT;\n");
    ok(wait_event($ckpt, 'memcow-checkpointer-writev', 30), 'checkpointer parked inside FlushBuffer on a lane buffer');
    like(buffers($oid, 'AND pinning_backends > 0 AND isdirty'), qr/^[1-9]/,
        '... holding a pinned dirty lane buffer (IO in progress)') unless $negative;
    $c->query_until(qr/reset started/, "\\echo reset started\nSELECT memcow_lane_reset($oid, 60000);\n");
    ok(wait_event($pid_c, 'ProcSignalBarrier', 20), 'the reset waits at the BARRIER for the parked checkpointer');
    is(ctl("SELECT epoch || '|' || reclaim_pending || '|' || writes_discarded FROM memcow_lane_status($oid)"),
        '1|true|0', '... having already PUBLISHED epoch 1, nothing discarded yet') unless $negative;

    my ($wakes, $sweep_waited, $completed) = (0, 0, 0);
    for (1 .. 60)
    {
        # Keep the original one-second observation interval. Checkpointer
        # writes can park repeatedly, including after absorbing the barrier.
        usleep(1_000_000);
        if (ctl("SELECT state FROM pg_stat_activity WHERE pid = $pid_c") eq 'idle')
        {
            $completed = 1;
            last;
        }
        if (ctl("SELECT wait_event FROM pg_stat_activity WHERE pid = $ckpt") eq 'memcow-checkpointer-writev')
        {
            $sweep_waited = 1 if ctl("SELECT wait_event FROM pg_stat_activity WHERE pid = $pid_c") eq 'BufferIo';
            wake('memcow-checkpointer-writev');
            $wakes++;
        }
    }
    die 'reset did not complete within 60 wake attempts' unless $completed;
    is($c->query_safe(''), '1', "reset returned epoch 1 once the checkpointer's writes were all released");
    $c2->query_safe('');
    pass('the checkpoint completed');
    if ($negative)
    {
        detach('memcow-checkpointer-writev');
        detach('memcow-writev-skip-discard');
        ctl("SELECT memcow_lane_open($oid, false)");
        my $out = $l->query("SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1");
        unlike($l->{stderr}, qr/ERROR|FATAL/, 'discard sabotage produced no unrelated error');
        like($out,
            qr/^kind\|r4$/m, "sabotage detected: without the discard window the flush landed in the NEW arena (cross-epoch artifact 'r4' at epoch 1)");
    }
    else
    {
        cmp_ok($wakes, '>=', 2, "the checkpointer parked on $wakes lane writes, one after absorbing the barrier");
        is($sweep_waited, 1, 'the reset was seen waiting in the SWEEP (BufferIo) on a write the checkpointer held: DropDatabaseBuffers waits');
        is(ctl("SELECT reclaim_pending || '|' || attached_old || '|' || writes_discarded FROM memcow_lane_status($oid)"),
            "false|0|$wakes", "every write released after PUBLISH was DISCARDED (writes_discarded = $wakes), reclaim done");
        is(buffers($oid), '0', 'no lane buffer survives the sweep');
        detach('memcow-checkpointer-writev');
        ctl("SELECT memcow_lane_open($oid, false)");
        my $out = $l->query_safe("SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1; SELECT 'bal', balance FROM public.accounts WHERE account_id = 1");
        like($out, qr/^1$/m, 'retained backend adopted epoch 1');
        like($out, qr/^kind\|logout$/m, 'epoch 1: the flushed events page is NOT in the new arena (seed row)');
        unlike($out, qr/^bal\|0$/m, 'epoch 1: nor the accounts page');
        like(lane("SELECT 'kind', kind FROM public.events WHERE event_id = 1"), qr/^kind\|logout$/m, 'fresh backend agrees');

        # Second variant: release the write before reset; it belongs to the
        # current arena and must not increase the discard count.
        $l->query_safe("UPDATE public.events SET kind = 'r4b' WHERE event_id = 1");
        attach('memcow-checkpointer-writev', 'wait', $oid);
        $c2->query_until(qr/checkpoint started/, "\\echo checkpoint started\nCHECKPOINT;\n");
        ok(wait_event($ckpt, 'memcow-checkpointer-writev', 30), 'variant 2: checkpointer parked');
        ok(wake_until_idle($pid_c2, 'memcow-checkpointer-writev', 30), 'variant 2: checkpoint completed');
        $c2->query_safe('');
        detach('memcow-checkpointer-writev');
        is(status($oid, 'writes_discarded'), "$wakes", "variant 2: nothing more discarded (the write landed in epoch 1's arena)");
        $l->query_safe('DISCARD ALL');
        is(ctl("SELECT memcow_lane_reset($oid, 5000)"), '2', 'variant 2: reset -> epoch 2 discards the arena');
        ctl("SELECT memcow_lane_open($oid, false)");
        like($l->query_safe("SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1"),
            qr/^kind\|logout$/m, 'variant 2: epoch 2 sees the seed row');
    }
    $c2->quit;
    $c->quit;
    $l->quit;
}

sub R5_sinval_nailed
{
    ctl('CREATE EXTENSION IF NOT EXISTS injection_points');
    ctl('CREATE EXTENSION IF NOT EXISTS pg_buffercache');
    my $a = background();
    my $pid_a = $a->query_safe('SELECT pg_backend_pid()');
    ctl("SELECT memcow_lane_register($oid, $pid_a)");
    if ($negative)
    {
        $a->query_safe("UPDATE public.events SET kind = 'r5' WHERE event_id = 1; CHECKPOINT;");
        attach('memcow-lane-skip-sweep', 'notice');
        is(ctl("SELECT memcow_lane_reset($oid, 5000)"), '1', 'reset -> epoch 1 (sweep skipped)');
        detach('memcow-lane-skip-sweep');
        like(buffers($oid), qr/^[1-9]/, 'sabotage detected: lane buffers survived the reset');
        ctl("SELECT memcow_lane_open($oid, false)");
        like(lane("SELECT 'kind', kind FROM public.events WHERE event_id = 1"), qr/^kind\|r5$/m,
            'sabotage detected: a fresh backend reads the epoch-0 page from a surviving buffer (cross-epoch artifact)');
        $a->quit;
        return;
    }
    my $b = background();
    my $pid_b = $b->query_safe('SELECT pg_backend_pid()');
    ctl("SELECT memcow_lane_register($oid, $pid_b)");
    my $out = $a->query_safe("UPDATE public.events SET kind = 'r5' WHERE event_id = 1; CREATE TABLE r5_tbl(x int); INSERT INTO r5_tbl VALUES (1); SELECT count(*) FROM pg_authid; CHECKPOINT; SELECT 'ok'");
    like($out, qr/^ok$/m, 'epoch 0: catalog and data pages written and flushed');
    $b->query_safe('SELECT count(*) FROM pg_authid; SELECT count(*) FROM pg_class; SELECT count(*) FROM public.events');
    my $c = background($control, 60);
    my $pid_c = $c->query_safe('SELECT pg_backend_pid()');
    attach('memcow-lane-reset-after-publish', 'wait');
    $c->query_until(qr/reset started/, "\\echo reset started\nSELECT memcow_lane_reset($oid, 60000);\n");
    ok(wait_event($pid_c, 'memcow-lane-reset-after-publish', 20), 'reset parked after PUBLISH, before the barrier');
    is(ctl("SELECT epoch || '|' || reclaim_pending FROM memcow_lane_status($oid)"), '1|true', 'epoch 1 is published, reclaim pending');
    ctl("SELECT count(*) FROM (SELECT pg_buffercache_evict(bufferid) FROM pg_buffercache WHERE reldatabase = $oid) s");
    is(buffers($oid), '0', 'every lane buffer evicted while the reset is parked');
    $out = ctl('CREATE ROLE r5_role_a', 'CREATE ROLE r5_role_b', 'CREATE ROLE r5_role_c',
        'VACUUM (ANALYZE) pg_authid', "SELECT 'sent'");
    like($out, qr/^sent$/m, 'nailed-catalog invalidation queued');
    unlike(ctl("SELECT memcow_lane_catchup($pid_a), memcow_lane_catchup($pid_b)"), qr/ERROR/,
        'catchup interrupts delivered to both parked backends');
    usleep(500_000);
    is(buffers($oid), '0', 'catchup alone reads nothing (the nailed reload is deferred)');
    $a->query_safe('SELECT count(*) FROM pg_authid');
    $b->query_safe('SELECT count(*) FROM pg_authid');
    my $n = buffers($oid);
    cmp_ok($n, '>', 0, "the nailed reload read the lane's pg_class: $n lane buffer(s) created after PUBLISH, before the barrier");
    wake('memcow-lane-reset-after-publish');
    is($c->query_safe(''), '1', 'reset returned epoch 1');
    pass('the reset completed');
    detach('memcow-lane-reset-after-publish');
    is(buffers($oid), '0', 'BUFFER-POOL SCAN: no buffer tagged with the lane survives the post-barrier sweep');
    is(status($oid, 'attached_old'), '0', 'no old-arena attachment after the reset returned');
    ctl("SELECT memcow_lane_open($oid, false)");
    $out = $a->query_safe("SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1; SELECT 'tbl', count(*) FROM pg_class WHERE relname = 'r5_tbl'");
    like($out, qr/^1$/m, 'A adopted epoch 1');
    like($out, qr/^kind\|logout$/m, 'A: the seed row is back');
    like($out, qr/^tbl\|0$/m, 'A: the epoch-0 relation is gone');
    like($b->query_safe("SELECT public.memcow_backend_reset(); SELECT 'kind', kind FROM public.events WHERE event_id = 1"),
        qr/^kind\|logout$/m, 'B adopted epoch 1 and sees the seed row');
    $out = lane("SELECT 'kind', kind FROM public.events WHERE event_id = 1; SELECT 'tbl', count(*) FROM pg_class WHERE relname = 'r5_tbl'");
    like($out, qr/^kind\|logout$/m, 'fresh backend: the seed row');
    like($out, qr/^tbl\|0$/m, 'fresh backend: no epoch-0 relation');
    ctl('DROP ROLE IF EXISTS r5_role_a, r5_role_b, r5_role_c');
    $c->quit;
    $b->quit;
    $a->quit;
}

sub R1_auth_window
{
    for my $protocol ('simple', 'extended')
    {
        if ($protocol eq 'extended')
        {
            $node->stop;
            $node->start(options => $options);
        }
        ctl('CREATE EXTENSION IF NOT EXISTS memcow');
        ctl('CREATE EXTENSION IF NOT EXISTS injection_points');
        my $a;
        unless ($negative)
        {
            ctl(qq{ALTER DATABASE "$db" SET event_triggers=off});
            $a = background();
            my $pid = $a->query_safe('SELECT pg_backend_pid()');
            ctl("SELECT memcow_lane_register($oid, $pid)");
            $a->query_safe("UPDATE public.events SET kind = 'r1' WHERE event_id = 1");
        }
        my $nonce = ctl("SELECT memcow_lane_open($oid, true)");
        like($nonce, qr/^[1-9][0-9]*$/, "$protocol: lane armed");
        attach('memcow-skip-admission', 'notice') if $negative;
        attach('memcow-lanes-post-auth', 'wait');
        my ($out, $err) = ('', '');
        my $probe;
        {
            local $ENV{PGOPTIONS} = "-c memcow.lane_nonce=$nonce"
                . ($negative ? '' : ' -c session_replication_role=replica');
            local $ENV{PGHOST} = $node->host;
            local $ENV{PGPORT} = $node->port;
            local $ENV{PGUSER} = $user;
            $probe = IPC::Run::start(['python3', "$FindBin::RealBin/../startup_probe.py",
                '--dbname', $db, '--protocol', $protocol], '>', \$out, '2>', \$err,
                IPC::Run::timeout(40));
        }
        {
            local $PostgreSQL::Test::Utils::timeout_default = 20;
            local $ENV{PGUSER} = $user;
            ok($node->poll_query_until($control,
                "SELECT count(*) > 0 FROM pg_stat_activity WHERE wait_event = 'memcow-lanes-post-auth'"),
                "$protocol: a connecting backend is parked after authentication");
        }
        my $parked = ctl("SELECT pid FROM pg_stat_activity WHERE wait_event = 'memcow-lanes-post-auth' LIMIT 1");
        like($parked, qr/^[0-9]+$/, "$protocol: backend parked");
        is(ctl("SELECT coalesce(datname, '<none>') FROM pg_stat_activity WHERE pid = $parked"),
            '<none>', '... and has no database yet, so the fence cannot see it') unless $negative;
        is(ctl("SELECT memcow_lane_reset($oid, 5000)"), '1', "$protocol: a full reset completes past the parked backend -> epoch 1");
        my $nonce2 = ctl("SELECT memcow_lane_open($oid, true)");
        unless ($negative)
        {
            like($nonce2, qr/^[1-9][0-9]*$/, 'lane reopened armed with a new nonce');
            isnt($nonce2, $nonce, 'the new nonce differs from the one the parked backend presented');
            is($a->query_safe('SELECT public.memcow_backend_reset()'), '1', 'the retained backend adopted epoch 1');
        }
        wake('memcow-lanes-post-auth');
        $probe->finish;
        $out .= "\n" . $err;
        if ($negative)
        {
            like($out, qr/r1-cmd-ran/, "$protocol: sabotage detected: with fence 3 off the stale-nonce backend is admitted into epoch 1 and its command runs");
            detach('memcow-skip-admission');
        }
        else
        {
            like($out, qr/FATAL:.*nonce mismatch/, "$protocol: resumed backend: FATAL before its first command");
            unlike($out, qr/r1-cmd-ran/, 'resumed backend: the command never ran');
            my $lines = join "\n", grep { /\[$parked\] / } split /\n/, slurp_file($node->logfile);
            like($lines, qr/connection authorized/, 'which fence: it had been AUTHORIZED (the auth fence admitted it)');
            like($lines, qr/admission fence/, 'which fence: the login event trigger admission fence (3 of 3) caught it');
            unlike($lines, qr/authentication fence/, 'which fence: not the authentication fence');
        }
        detach('memcow-lanes-post-auth');
        unless ($negative)
        {
            like(lane('SELECT 1'), qr/FATAL/, 'afterwards a connection without the nonce is still refused');
            {
                local $ENV{PGOPTIONS} = "-c memcow.lane_nonce=$nonce2";
                like(lane("SELECT 'kind', kind FROM public.events WHERE event_id = 1"), qr/^kind\|logout$/m,
                    'and one with the new nonce sees the seed');
            }
            ctl(qq{ALTER DATABASE "$db" RESET event_triggers});
            $a->quit;
        }
    }
}

my %cases = (
    R1_auth_window => \&R1_auth_window,
    S11_reset_reverts => \&S11_reset_reverts,
    S13_reset_invalidates_pin => \&S13_reset_invalidates_pin,
    S14_reset_vs_truncate => \&S14_reset_vs_truncate,
    S18_reset_retry => \&S18_reset_retry,
    R2_stopped_straggler => \&R2_stopped_straggler,
    R3_cancel_inflight_io => \&R3_cancel_inflight_io,
    R4_checkpoint_discard => \&R4_checkpoint_discard,
    R5_sinval_nailed => \&R5_sinval_nailed);
die "unknown TAP case $case" unless exists $cases{$case};
eval { subtest $case . ($negative ? ' negative control' : '') => $cases{$case}; };
my $error = $@;
$node->stop;
# The shell uses the shared crash/leak classifier on this exact server log.
File::Copy::copy($node->logfile, $ENV{MEMCOW_TAP_SERVER_LOG}) or die "copy server log: $!";
die $error if $error;
done_testing();
