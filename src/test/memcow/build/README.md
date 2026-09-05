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
| `slice/slice_tests.sh` | The memcow-specific cases S1–S16 and R1–R5, each with a negative control. |
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
failure.  On Linux, mount the tmpfs first (`sudo mount -t tmpfs -o size=3g
tmpfs /mnt/ram`), export `LD_LIBRARY_PATH` to the tmp_install multiarch
libdir before `build_seed.sh`, and pass `-- --require-io-uring` to phase 1.

## Gates in about three minutes

The defaults are the plan's acceptance gates (10,000 resets, 100,000
leases).  For a smoke run the summaries say so explicitly:

```sh
MEMCOW_SOAK_ITERATIONS=100 ./src/test/memcow/harness/run_gate.sh --phase 2 ...
MEMCOW_BENCH_LEASES=2000 MEMCOW_BENCH_RESETS=200 ./src/test/memcow/harness/run_gate.sh --phase 4 ...
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

The §7.4 thresholds are held on the cassert build as written (progress.md
open problem 2, option (a)).

## Not registered with meson

`meson test` expects a suite to run from a clean checkout; these need a
seed built by the exact binary under test and a mounted RAM disk, neither of
which meson can produce and neither of which should be produced silently.
The `test_aio` TAP suite (`005_synthetic_completion.pl`, the synthetic AIO
completion and its io_uring concurrent-waiter case) is a meson suite and runs
with `meson test -C build-memcow --suite test_aio`.
