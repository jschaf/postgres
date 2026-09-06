# Slice coverage after the TAP migration

`slice_tests.sh --case NAME [--negative-control]` remains the direct entry
point. `run_gate.sh` still runs complete phases. Persistent sessions and
server lifecycle for the nine migrated cases use PostgreSQL::Test::Cluster
and PostgreSQL::Test::BackgroundPsql in `t/001_reset.pl`. The other cases
remain in `slice_tests.sh`. There is no FIFO, file-based sequence counter,
output-marker parser, or replacement session protocol in the shell harness.

A control passes when it detects its named sabotage symptom or the specified
boundary behavior. This is sensitivity evidence for that intervention, not
proof that every possible implementation defect would fail the test.

| Invariant or race | Case | Negative control |
| --- | --- | --- |
| Per-block seed/overlay identity | S1_mixed_vectors | Shift expected block IDs by one |
| Page verification and zero_damaged_pages | S2_overlay_corruption | Valid page returns exactly 4000 rows without unrelated errors |
| Tablespace move preserves content | S3_set_tablespace | Changed content has a different valid digest |
| Read, buffer, prefetch block counts | S4_pg_prewarm | Empty relation yields zero; distinguish heap and index |
| Clean past-EOF errors for synthetic and direct reads | S5_past_eof | In-range reads have no EOF or unrelated error |
| Fingerprint rejection | S6_fingerprint | Matching fingerprint starts |
| Seed bytes immutable; no runtime relation files before/after | S7_seed_immutable | Mutate a byte in a copied seed file |
| Crash recovery refused | S8_crash_refuses | Clean stop permits restart |
| Exact documented size/tablespace divergences | S9_documented_divergences | Zero size is observed; empty tablespace drops |
| Warmed critical truncate uses pinned record | S10_truncate_crit_section | Same workload in one warmed backend |
| I1 reset reversion; I2 retained adoption, nonce admission; init/map handling | S11_reset_reverts (TAP) | Omit reset: old write persists |
| Old arena/DSM reclamation | S12_reset_reclaims | Omit second reset: segments remain |
| Epoch-invalidated truncate pin is refreshed; no unwarmed fallback | S13_reset_invalidates_pin (TAP) | Omit reset: refresh counter stays flat, pinned truncate still occurs |
| Registered active refusal; unkillable critical-section straggler; closed lane and retry | S14_reset_vs_truncate (TAP) | No pause: idle registered backend allows reset |
| Authentication-time nonce and startup options precedence | S15_auth_fence | Bypass auth; later admission fence still rejects |
| Bounded arena with named 53MC1 refusal | S16_arena_limit | Unlimited arena accepts workload |
| RETIRED state through API and relmapper mismatch | S17_retired | Intact map and no retirement permit reset/open/query |
| Post-publication error and same-epoch retry | S18_reset_retry (TAP) | Omit sweep error: another reset publishes another epoch |
| Auth-to-database-lock window, simple and extended protocols | R1_auth_window (TAP + raw startup_probe.py) | Skip admission: stale-nonce pipelined command executes |
| SIGSTOPped straggler; no publication on timeout; retry after death | R2_stopped_straggler (TAP) | Omit SIGSTOP: first reset succeeds |
| Deferred cancel at synthetic COMPLETED_IO; poison/reclaim; clean retained reread | R3_cancel_inflight_io (TAP) | Skip stale detach: named attachment refusal; remove sabotage, exit backend, retry same epoch; checkpointer must detach too |
| Checkpointer held across barrier and BufferIo sweep; post-publish discard and pre-reset write | R4_checkpoint_discard (TAP) | Skip discard: old r4 page enters new arena |
| Shared nailed-catalog invalidation; deferred reload after publish; sweep all lane buffers | R5_sinval_nailed (TAP) | Skip sweep: buffers survive and fresh backend reads r5 |

The TAP cases retain the injection pauses and server-side reset timeouts:
S14 uses 2000/1500 ms refusals and 5000 ms retries; R2 uses 1500/5000 ms;
R3 uses 5000 ms and its control 2000 ms; concurrent R4/R5 resets use
60000 ms. Wait-event polling remains at 100 ms with the original 20 or
30 second bounds. Repeated checkpointer wakeups retain one-second polling,
including observation of both ProcSignalBarrier and BufferIo. R3 and R5
retain their 500 ms deferred-interrupt observations. Query timers restart
per command, using the previous 30-second default and explicit 20/60-second
completion/workload bounds. PostgreSQL's TAP facilities provide session
output, query text and timeout diagnostics; the shell still applies its
shared crash/leak classifier to each server log, including after clean stop.
The raw probe retains its 40-second socket timeout and sends startup plus
Q or Parse/Bind/Execute/Sync in one packet stream, before ReadyForQuery.

## Evidence limits that this migration does not change

- I3 file checks are before/after observations, not syscall-level confinement.
  Matrix PGDATA copies are on ordinary storage; slices use verified RAM.
- R3 parks synthetic completion at COMPLETED_IO, not a worker SUBMITTED read.
- S10/S13 pin counters do not prove an allocation-free close/barrier path.
  Injection-point cache refresh can allocate/load a callback or raise ERROR.
- DSA/DSM detach still uses locks and OS unmap; this is not lock-free.
- R4 checks particular deterministic barrier/sweep orders, not all lock orders.
- S18 and nc_R3 cover named failed-finish/reclaim retry points, not arbitrary
  failures after arena destruction.
- The standalone test_aio TAP suite remains responsible for synthetic AIO
  handle behavior, including io_uring's synchronous flag and concurrent waiter.
- Pool wrapper invalidation, busy refusal, straggler termination, digest/DSM
  stability, lease/reset thresholds, starvation/sweep attribution and their
  controls remain in pool_soak.py and bench.py. Their smoke runs do not replace
  the unrun 10,000-reset or 100,000-lease gates.
