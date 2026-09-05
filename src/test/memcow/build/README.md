# memcow build and gates

Operator entry points for building and gating the memcow ephemeral test
engine.  Plan of record: `.plans/pgtest/plan.md` (§N below).

| Path | Purpose |
| --- | --- |
| `build/configure_build.sh` | Create/update the meson build dir `build-memcow` with the pinned options `-Dcassert=true -Dinjection_points=true` (plan §7: assertion-enabled builds, injection points enabled) and verify they took effect.  Idempotent. |
| `build/ci.sh` | Configure → build → install → **reseed** → assemble → one gate. |
| `seed/build_seed.sh` | The seed: an ordinary PGDATA written by stock md with memcow preloaded but disabled, 8 lane databases cloned from template1 after `schema.sql` and `CREATE EXTENSION memcow`, frozen, cleanly shut down, fingerprinted. |
| `seed/assemble_ramdir.sh` | The RAM-backed runtime PGDATA: the seed's non-relation files plus the runtime settings block (macOS: hdiutil RAM disk; Linux: a tmpfs you mounted). |
| `harness/run_gate.sh` | The gates, `--phase 1`, `2`, `4` (see its header for what each proves). |
| `harness/io_matrix.sh` | §7.1: io_method × cold/hot × temp tables, stock md vs memcow, four gates per cell; `classify_diff.py` + `divergences.txt` are the registered, cited divergences. |
| `harness/with_server.sh` | Owns a memcow server for one Python driver (`pool/pool_soak.py`, `pool/bench.py`). |
| `slice/slice_tests.sh` | The memcow-specific cases S1–S18 and R1–R5, each with a negative control. |
| `pool/memcow_pool.py` | The minimal lane pool (plan §3), ctypes over the tree's libpq. |

## Quick start

```sh
./src/test/memcow/build/ci.sh --phase 1 --seed /opt/p/mc/seed --ram-mount /opt/p/mc/ram
./src/test/memcow/build/ci.sh --phase 2 --seed /opt/p/mc/seed --ram-mount /opt/p/mc/ram --skip-build
./src/test/memcow/build/ci.sh --phase 4 --seed /opt/p/mc/seed --ram-mount /opt/p/mc/ram --skip-build
```

`ci.sh` always reseeds and re-assembles: the seed fingerprint pins the
postgres binary's size and the module's size (and the builder's recipe hash
covers both SHA-256s), so a stale seed is a startup FATAL, not a subtle
failure. The build installs into its private prefix before staging
`tmp_install`; this also lets initdb/pg_regress subprocesses find libpq on
macOS when the system shell strips `DYLD_LIBRARY_PATH`. On Linux, mount the
tmpfs first (`sudo mount -t tmpfs -o size=3g tmpfs /mnt/ram`) and pass
`-- --require-io-uring` to phase 1.

## Gates in about three minutes

The defaults are the plan's acceptance gates (10,000 resets, 100,000
leases).  For a smoke run the summaries say so explicitly:

```sh
MEMCOW_SOAK_ITERATIONS=300 ./src/test/memcow/harness/run_gate.sh --phase 2 ...
MEMCOW_BENCH_LEASES=2000 MEMCOW_BENCH_RESETS=400 ./src/test/memcow/harness/run_gate.sh --phase 4 ...
./src/test/memcow/harness/run_gate.sh --phase 1 --subset smoke ...   # one test per §7.1 category
```

`run_gate.sh` needs `--build-dir`, `--seed` and `--pgdata` or `--ram-mount`;
`MEMCOW_GATE_WORKDIR` holds the artifacts.  It connects as the seed's
superuser (`postgres`) unless `PGUSER` is set.

## Build dir and options

`build-memcow` is deliberately not an interactive build dir: the gates run
against options pinned by a script.  `cassert` and `injection_points` are
non-negotiable; `buildtype=debugoptimized` (`-O2 -g`) so that the §7.4
latency thresholds mean something, `MEMCOW_BUILDTYPE=debug` for `-O0`.  The
prefix is `<build>/install`, so a `ninja install` here never overwrites
another build's binaries.  Homebrew pkg-config paths and krb5 includes are
added when present; `-Dliburing=enabled` on Linux.

The §7.4 thresholds apply to the cassert build as written. Run phase 4 on
a quiet host; a smoke sample does not establish the full acceptance gate.

## Not registered with meson

`meson test` expects a suite to run from a clean checkout; these need a
seed built by the exact binary under test and a mounted RAM disk, neither of
which meson can produce and neither of which should be produced silently.
The `test_aio` TAP suite (`005_synthetic_completion.pl`, the synthetic AIO
completion and its io_uring concurrent-waiter case) is a meson suite and runs
with `meson test -C build-memcow --suite test_aio`.


On macOS, inherited `LC_CTYPE=C.UTF-8` can fail test_aio's initdb case even
with `LC_ALL=C`: TAP clears `LC_ALL`. A reproducible invocation is:

```sh
LANG=C LC_CTYPE=C LC_COLLATE=C LC_ALL=C meson test -C build-memcow --suite test_aio --print-errorlogs
```

## Manual options and gate ownership

These are supported diagnostic entry points, not additional acceptance gates.
All scripts also accept their documented help option. An override of a
threshold, divergence allow-list, subset or build type is an experiment and
must be reported as such; it does not replace the plan's gate.

| Entry point | Gate-owned options | Manual use of the remaining options |
| --- | --- | --- |
| `build/ci.sh` | `--phase`, `--seed`, `--ram-mount`, `--skip-build`, `--` gate arguments | `MEMCOW_BUILD_DIR` isolates another build; configure's documented environment overrides select local tools, dependencies, prefix and build type. `MEMCOW_WIPE=1` explicitly replaces an incompatible build directory. |
| `seed/build_seed.sh` | `-b`, `-o`, `-f` | Without `-f`, reuse only a matching recipe/binary seed. `-l` sizes a manual pool, `-u` selects its bootstrap role, `-q` suppresses progress for scripting. Rebuild/reseed after changing the binary. |
| `seed/assemble_ramdir.sh` | `-s`, `-m`, `-b`, `-f` | `-z` sizes the macOS RAM disk; Linux mount size is chosen when mounting tmpfs. `-p` sets the port for a manually started server (gate owners override it). `--status` verifies the mount and prints the marker's assembly metadata. The marker is diagnostic; kernel mount information proves RAM backing. `--detach` tears down the assembled runtime. |
| `harness/run_gate.sh` | `--phase`, `--build-dir`, `--seed`, `--ram-mount`/`--pgdata`, `--subset`, phase-1 matrix arguments | Only phase 1 accepts matrix arguments. `--only` and `--dry-run` are rejected here because they omit required matrix cells; invoke the matrix directly for diagnosis. |
| `harness/io_matrix.sh` | Build/output paths, A/B templates/names/GUCs, shared `--guc`, `--subset`, divergence allowances and `--require-io-uring` | `--only worker_cold_baseline` reproduces one cell. `--dry-run` prints planned cells without running them. `--stop-on-fail` stops a diagnostic batch at its first failed cell. |
| `slice/make_templates.sh` | `--seed`, `--ramdir`, `--outdir` | Recreate A/B templates for a direct matrix run. |
| `harness/run_regress_subset.sh` | Template/build/output paths, `--label`, repeated `--guc`, `--subset` | Run one side of a matrix cell to inspect raw pg_regress output. |
| `harness/gen_schedule.py` | `--regress-src`, `--subset`, `--out`, `--print-groups` | Print schedule groups before a manual regression run. |
| `harness/classify_diff.py` | `--a`, `--b`, `--rules`, repeated `--allow`/`--ran`, `--report` | Reclassify saved A/B outputs; never widen rules to turn a failed gate green. |
| `slice/slice_tests.sh` | Seed/runtime/build/output paths, `--phase`, `--negative-control` | `--list` discovers cases; repeated `--case` isolates one or more cases; `--db` chooses a seeded lane; `--keep-going` collects all failures and `--stop-on-fail` stops at the first one. |
| `harness/with_server.sh` | Seed/runtime/build/output paths, `--shared-buffers`, repeated `--guc`, `--` driver command | Own a server for a focused Python-driver experiment. |
| `pool/pool_soak.py` | `--iterations`, `--report`; defaults for lanes, connections, fence/fresh/recycle cadence and progress | `--lanes`, `--conns`, `--fence-every`, `--fresh-every`, `--retire-after`, `--progress-every` change a diagnostic workload's shape. Report the values and completed samples. |
| `pool/bench.py` | `lease`/`reset`, lanes/connections, workloads, sample counts, resetter/busy settings, labels, reports, negative controls | `--threshold-ms` is for threshold-sensitivity experiments only. `--resetter-delay-ms`, `--retire-after`, `--progress-every` and `--nc-sweep-wait-ms` tune reproducible diagnostic load/control duration. Full option definitions live in its argparse block. |
| `pool/busy_driver.py` | Lanes/connections, `--mode`, recycle cadence, stop/ready/go files and report | `--loop-iterations` changes the PL/pgSQL loop length for interrupt-latency experiments. The parent benchmark owns the handshake files. |
| `slice/startup_probe.py` | `--dbname`, `--protocol`, repeated `--guc` | R1 and S15 use raw startup/command packets to test both wire protocols and nonce precedence. |

For example, after a gate has assembled the runtime:

```sh
src/test/memcow/seed/assemble_ramdir.sh --status -m /opt/p/mc/ram
PGUSER=postgres src/test/memcow/slice/slice_tests.sh --build-dir build-memcow --seed /opt/p/mc/seed --pgdata /opt/p/mc/ram/pgdata --case S18_reset_retry
```
