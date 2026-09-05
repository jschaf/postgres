# memcow build scaffolding (Phase 0(c))

Operator entry point for building and gating the pgtest/memcow ephemeral test
engine. Plan of record:
`/Users/joe/.local/state/sync/postgres/plans/pgtest/plan.md` (sections
referenced below as §N).

This directory contains **only** build/CI scaffolding:

| File | Purpose |
| --- | --- |
| `configure_build.sh` | Create/update the dedicated meson build dir `build-memcow` with the pinned options. Idempotent. |
| `ci.sh` | One shot: configure → build → run one phase gate → print exactly one `MEMCOW-CI:` PASS/FAIL line. |
| `README.md` | This file. |

Nothing here implements a gate. Gates 1–4 live in the memcow **harness**
(`src/test/memcow/harness/`), a separate deliverable. As of this commit the
harness does not exist, so **only the phase 0 build gate is runnable** — see
[Status](#status-what-actually-runs-today).

## Quick start

```sh
# from anywhere inside the working tree
./src/test/memcow/build/configure_build.sh      # creates <root>/build-memcow
ninja -C build-memcow                           # ~6 min cold, 1929 targets

./src/test/memcow/build/ci.sh --phase 0         # the only gate runnable today
```

`ci.sh --help` prints the full option list.

## The build directory

`build-memcow` at the top of the working tree (override with
`$MEMCOW_BUILD_DIR`). It is deliberately *not* `build-fast`: the gates must run
against options pinned by a script, not against whatever the last interactive
`meson configure` left behind.

### Pinned, non-negotiable

```
-Dcassert=true -Dinjection_points=true
```

Fixed decisions of the plan (§7: "Assertion-enabled builds; injection points
enabled"). `configure_build.sh` re-verifies both by `meson introspect` after
configuring and exits non-zero if either is not actually true; `ci.sh` re-checks
them again before running any gate, so `--skip-configure` cannot smuggle an
unpinned build dir past a gate. Do not turn either off to get a gate green.

### Settings carried over from `build-fast`, and why

`build-fast` was inspected with `meson introspect build-fast --buildoptions`.

| Setting | Carried? | Reason |
| --- | --- | --- |
| `cassert=true`, `injection_points=true` | yes | Plan-pinned anyway. |
| `pkg_config_path` (Homebrew icu4c@78, openssl@3, lz4, zstd, readline, krb5) | yes | Pure dependency discovery — without it this tree does not configure with ICU/SSL. Entries that do not exist on the machine are dropped, and `$PKG_CONFIG_PATH` is appended. |
| `extra_include_dirs=[/opt/homebrew/opt/krb5/include]` | yes | Same reason (GSSAPI headers). |
| `SED=gsed`, `PERL`/`PROVE` from Homebrew perl | yes | PostgreSQL's build wants GNU sed on macOS; perl is picked up dynamically rather than hardcoded. |
| `llvm=disabled`, `dtrace=disabled` | yes | JIT and dtrace are irrelevant to every §7 gate; enabling them only adds build time and moving parts under the memcow storage path. |
| `tap_tests=enabled` | conditionally | See [TAP tests](#tap-tests-currently-disabled-on-this-machine). |
| `prefix=/opt/p/postgres-install` | **no** | Diverged: `build-memcow` installs into `build-memcow/install`. A shared prefix means a memcow `ninja install` silently replaces the binaries any other build dir installed — exactly the confusion that makes a gate result unattributable. Self-contained, removed with the build dir, invisible to git. |
| `buildtype=debug` / `optimization=0` | **no** | Diverged: `debugoptimized` (`-O2 -g`, `debug=true`, `b_ndebug=false`). See below. |
| `docs`/`docs_pdf` (auto) | **no** | Explicitly `disabled`; no gate reads the docs and they are slow. |

### Divergence: `debugoptimized` instead of `-O0`

`build-fast` is an interactive edit/debug dir; `-O0` is right for it.
`build-memcow` also has to produce §7.4's numbers — lease→first-query p99 < 1 ms
and reset p99 < 25 ms. Those thresholds are meaningless on an `-O0` build, and
an operator who benchmarks the `-O0` build and reports a miss has produced no
information. `-O2` with `-g` and asserts still on keeps every correctness gate
(1–3) honest while making gate 4 interpretable.

Tradeoff, accepted knowingly: inlining makes stepping through `memcow.c` in
lldb worse, and `-O2` exercises different UB behaviour than `-O0`. Both are
recoverable:

```sh
MEMCOW_BUILDTYPE=debug ./src/test/memcow/build/configure_build.sh   # -O0, same pins
```

Running the correctness gates at both `-O0` and `-O2` is cheap and is worth
doing at least once per phase, since the mmapped-seed / DSA-arena code is
exactly the kind of pointer-aliasing code where the two differ.

Caveat to raise before gate 4 is scored: **`cassert=true` is itself a large,
uncontrolled tax on the very latencies §7.4 puts hard thresholds on.** §7 pins
asserts on for the falsification slice, and the fixed decisions pin them for all
builds, so this scaffolding does not deviate — but the measured floor quoted in
§7.4 (0.12 ms) does not come from an assert-enabled build, and a p99 miss on an
assert build is not by itself evidence the design missed. See
[Open questions](#open-questions-for-the-plan-owner).

### `werror`

Default `false` (as in `build-fast`), overridable with `MEMCOW_WERROR=true`.
Evidence for the record: a full cold build of this tree at this commit with
`debugoptimized` + cassert produced **zero** compiler warnings (1929/1929
targets), so `werror=true` is viable today and is a reasonable thing to turn on
for the memcow phases. It is not the default only because an unrelated
compiler/SDK upgrade would then block memcow work rather than warn about it.

### TAP tests: currently disabled on this machine

`-Dtap_tests=enabled` is a hard *configure* error when Perl's TAP prerequisites
are missing, so `configure_build.sh` probes with the exact script meson uses
(`config/check_modules.pl`) and picks `enabled`/`disabled` accordingly, printing
a loud warning when it degrades.

On this machine both `/usr/bin/perl` and `/opt/homebrew/opt/perl/bin/perl`
(5.44) are currently **missing `IPC::Run`**, so `build-memcow` is configured
with `tap_tests=disabled`. `ci.sh` propagates the state as `MEMCOW_TAP_TESTS`
and prints `tap=disabled` in its summary line, so no TAP-less run can be
mistaken for a full green.

Fix before running gates that need TAP suites (phase 3's injection-point/SIGSTOP
races almost certainly do):

```sh
cpan IPC::Run          # or: cpanm IPC::Run Test::More Time::HiRes
./src/test/memcow/build/configure_build.sh    # re-probe; should flip to enabled
```

Force it either way with `MEMCOW_TAP_TESTS=enabled|disabled`.

### Environment overrides

| Variable | Default |
| --- | --- |
| `MEMCOW_BUILD_DIR` | `<root>/build-memcow` |
| `MEMCOW_BUILDTYPE` | `debugoptimized` |
| `MEMCOW_PREFIX` | `<build dir>/install` |
| `MEMCOW_WERROR` | `false` |
| `MEMCOW_PERL` | Homebrew perl if present, else `perl` |
| `MEMCOW_TAP_TESTS` | auto-probed |
| `MEMCOW_WIPE` | unset; `1` wipes a build dir configured from another source tree |
| `MESON` | `meson` |

The scripts resolve the source root with `git rev-parse --show-toplevel`, so
they work unchanged inside linked worktrees.

## Phases and gates (plan §7)

§7 is the falsification slice: four steps, each with a binary gate. Phase 0 is
this scaffolding's own gate, added here so there is something to run before
Phase 1 lands; phases 1–4 are §7.1–§7.4 verbatim.

### Phase 0 — build gate (scaffolding)

Configure `build-memcow` with the pinned options and build the whole tree clean.

```sh
./src/test/memcow/build/ci.sh --phase 0
```

**Pass:** meson reports `cassert=true` and `injection_points=true`, and
`ninja` exits 0. **Fail:** anything else.

### Phase 1 — memcow smgr slice (§7.1)

memcow + GUC + the `smgrsw` row + `pgaio_io_complete_synthetic()`; no lanes, no
reset. Boot a tiny seed, one DB. Matrix: `io_method` ∈ {sync, worker, io_uring
where available} × shared_buffers hot/cold × temp tables. Run a core regression
subset (DDL, DML, vacuum, sequences, temp tables, COPY, index builds) diffed
against stock output, plus mixed seed/overlay vectors (dirty odd blocks,
rescan), a corrupted overlay page (expect an "invalid page" ERROR, with
`zero_damaged_pages` honouring the zero path), `ALTER TABLE SET TABLESPACE`
(the direct `smgrread` path) and `pg_prewarm`.

**Fail = any assert, any diff, any AIO handle/pin leak at backend exit.**

```sh
./src/test/memcow/build/ci.sh --phase 1
```

Note for this machine: `io_uring` is Linux-only and `liburing` is not available
here, so the matrix legitimately reduces to `sync` × `worker` on macOS. That is
a platform limitation to record in the gate's own output, not a cell to quietly
drop — the io_uring cell still has to run somewhere before the slice is
considered falsified.

### Phase 2 — lane reset loop (§7.2)

`memcow_lane_reset` + `memcow_backend_reset` + a minimal pool on one lane. Loop
10,000 × {DDL+DML workload → reset → seed-hash verify + differential query}.
Verify per reset: attach-count(old epoch) == 0; DSM slot count and RAM-dir size
flat (macOS POSIX DSM churn); `pg_filenode.map` byte-stable; the
`CountDBBackends` gate exercised.

**Fail = any cross-epoch artifact, any monotonic DSM/slot growth, any leaked AIO
resource.**

```sh
./src/test/memcow/build/ci.sh --phase 2
```

### Phase 3 — deterministic races (§7.3)

Injection points / SIGSTOP:

- (a) pause a connecting backend between `PerformAuthentication` and
  `LockSharedObject`; run a full reset; resume → must FATAL before the first
  command dispatch.
- (b) SIGSTOP a straggler after SIGTERM → reset must block/fail closed, never
  publish; resume → completes.
- (c) cancel a query with worker-method AIO in flight, release + reset
  immediately → `DropDatabaseBuffers` must wait; no use-after-free.
- (d) force a checkpoint concurrent with reset; pause checkpointer inside
  `FlushBuffer` before memcow `smgr_writev` → reset waits, the write lands in
  the old arena and is discarded.
- (e) send sinval for a nailed catalog to parked pool backends between publish
  and adopt → no epoch-N buffer survives the post-barrier sweep.

**Fail = any acknowledged command executing in the wrong epoch, any old-arena
attachment after reset returns.**

```sh
./src/test/memcow/build/ci.sh --phase 3
```

Requires `injection_points=true` (pinned) and, in all likelihood, working TAP
tests — see above.

### Phase 4 — benchmark (§7.4)

**Pass thresholds:** lease → first parameterized query p99 < 1 ms over 100k
leases with ready capacity (measured floor 0.12 ms); reset (quiesce → ready,
including warmup) p99 < 25 ms at `shared_buffers=512MB`, including the global
SMGRRELEASE barrier under concurrent busy lanes (absorption latency measured
explicitly); zero leakage.

Folded-in measurements: barrier absorption latency under a CFI-starved backend
(tight plpgsql loop); orphaned `pgsql_tmp` growth from killed stragglers;
`pg_shdepend` growth when run as a non-pinned role.

```sh
./src/test/memcow/build/ci.sh --phase 4
```

### All gates

```sh
./src/test/memcow/build/ci.sh --phase all     # 1..4, stops at the first failure
```

## Status: what actually runs today

| Gate | Runnable at this commit? | Blocker |
| --- | --- | --- |
| Phase 0 (build) | **yes** | — |
| Phase 1 (§7.1) | no | `memcow.c`, the GUC, the `smgrsw` row and `pgaio_io_complete_synthetic()` do not exist (plan §2); harness absent |
| Phase 2 (§7.2) | no | Phase 1, plus `contrib/memcow/`; harness absent |
| Phase 3 (§7.3) | no | Phase 2; harness absent; TAP tests currently disabled on this machine |
| Phase 4 (§7.4) | no | Phase 2; harness absent |

`ci.sh --phase 1..4` today fails at the `harness-check` stage with an explicit
message naming the missing path. That is the designed behaviour — a gate with
no implementation must read FAIL, never "skipped" and never green.

## Harness contract

`ci.sh` delegates gates 1–4 in full. It expects:

```
src/test/memcow/harness/run_gate.sh --phase <N> \
    --build-dir <absolute build dir> --source-dir <absolute source root>
```

- exit 0 = gate PASS; any non-zero = gate FAIL (the code is reported).
- Environment also provided: `MEMCOW_BUILD_DIR`, `MEMCOW_SOURCE_DIR`,
  `MEMCOW_TAP_TESTS` (`enabled`/`disabled`/`unknown`).
- Anything after `--` on the `ci.sh` command line is appended to the harness
  argv, e.g. `ci.sh --phase 1 -- --io-method worker`.
- If `run_gate.sh` is present but not executable, `ci.sh` runs it with `bash`
  and says so.

`ci.sh` prints exactly one summary line, on every exit path:

```
MEMCOW-CI: PASS phase=0 stage=gate-phase-0 tap=disabled elapsed=3s build-dir=... reason="..."
MEMCOW-CI: FAIL phase=1 stage=harness-check tap=disabled elapsed=3s build-dir=... reason="..."
```

## Not in this phase

- **No meson wiring.** `src/test/memcow/` is not in `src/test/meson.build`, and
  nothing under `src/backend/`, `src/include/` or `contrib/` was touched. The
  scripts here need no meson integration (they are invoked by path), and
  `memcow.c` / `contrib/memcow/` do not exist yet, so there is nothing
  legitimate to register.
- Meson integration that Phase 1 **will** need is listed below so it can be
  briefed, not so it can be done here.

### Meson work Phase 1 will need

1. `src/backend/storage/smgr/meson.build` — add `'memcow.c'` to the
   `backend_sources += files(...)` list. One line; no conditional, since the
   plan compiles memcow in unconditionally and selects it with a
   `PGC_POSTMASTER` GUC (§2, §A.3 "md stays compiled").
2. **No meson change for the GUC.** `guc_parameters.dat` is already an
   `input:` of the `guc_tables` custom target
   (`src/include/utils/meson.build`, generating `guc_tables.inc.c`), so the new
   `PGC_POSTMASTER` bool is picked up and correctly re-generated on incremental
   builds. Nothing to add.
3. `contrib/meson.build` — add `subdir('memcow')`, plus a new
   `contrib/memcow/meson.build` following the shape of an existing
   contrib module with a `_PG_init` and SQL functions: `shared_module(...,
   kwargs: contrib_mod_args)` + `contrib_targets += ...` (see
   `contrib/auth_delay/meson.build` for the hook-only minimum), plus
   `install_data` of the `.control`/`.sql` files with `kwargs:
   contrib_data_args` and a `tests += {...}` entry with `regress`/`tap` keys
   (see `contrib/pg_prewarm/meson.build` for the full shape). Note the extension is
   `shared_preload_libraries`-loaded (it installs
   `ClientAuthentication_hook` and requests shmem), so its tests need
   `regress` / `tap` entries that set that in the temp instance, not a plain
   `CREATE EXTENSION` regress run.
4. `src/test/meson.build` — add `subdir('memcow')` once the harness has
   meson-registered suites, together with a `src/test/memcow/meson.build`
   defining them. Whether the harness wants to be meson-registered at all
   (`meson test --suite memcow`) or stay a standalone script driven by `ci.sh`
   is a harness decision; `ci.sh` supports either, since it invokes
   `run_gate.sh` by path.
5. If the phase-1 matrix is to run under `meson test`, the `io_method` /
   `shared_buffers` matrix cells are environment variations, not build options —
   they belong in the harness's temp-instance config, not in new meson options.
   Resist adding meson options for them.

## Open questions for the plan owner

1. **`cassert` vs. the §7.4 thresholds.** All builds are pinned to
   `cassert=true`, but §7.4's p99 numbers (1 ms lease, 25 ms reset) and the
   0.12 ms measured floor come from assert-free measurement. Either the
   thresholds need an assert-build allowance, or gate 4 needs its own
   `cassert=false` build dir — which would contradict the fixed decision. Not
   resolved here; `configure_build.sh` keeps asserts on.
2. **io_uring coverage.** §7.1's matrix says "io_uring where available", and it
   is not available on this macOS host. If the io_uring cell is load-bearing for
   the AIO synthetic-completion argument (§A.1.2 claims identical behaviour
   because the method layer is never reached), it needs a Linux runner; if it is
   not, say so explicitly so the matrix is not silently two-thirds run.
3. **Phase 0 gate.** §7 defines gates 1–4 only. The build gate numbered 0 here
   is scaffolding's own invention so that something is verifiable before
   Phase 1; rename or drop it if that numbering collides with the plan's own
   Phase 0 (design study) language.
