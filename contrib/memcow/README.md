# memcow

Ephemeral PostgreSQL relation storage: a read-only PGDATA seed and a DSA
copy-on-write arena per database epoch. This is a test engine, not durable
storage. WAL, SLRUs, relmapper files, and other non-relation storage still use
the running PGDATA, which the harness places on a RAM filesystem.

Build with Meson as a contrib module, or with installed server headers:

```
make USE_PGXS=1 PG_CONFIG=/path/to/pg_config
```

Supply `PG_CPPFLAGS` for dependencies in nonstandard locations when the server
headers require them (for example, Homebrew OpenSSL and Kerberos). No private
source-tree include path or engine object linked into postgres is required.
The server must carry only the generic interfaces documented below.

Preload and configure at postmaster startup:

```
-c shared_preload_libraries=memcow
-c memcow.enabled=on
-c memcow.seed_directory=/absolute/path/to/seed
```

`memcow.enabled` and `memcow.seed_directory` are POSTMASTER settings;
`memcow.lane_nonce` is BACKEND (present it through startup `options=-c`), and
`memcow.lane_arena_limit` is SIGHUP, in MB, applied on lane open/reset.
The former underscored GUC names are replaced by dotted custom names so the
postmaster can retain their values before loading the library.

Build seeds with `src/test/memcow/seed/build_seed.sh`. It preloads the module
with storage disabled, installs `CREATE EXTENSION memcow` in template1, and
then clones the lanes. Both SQL functions and the ALWAYS ON login admission
trigger therefore survive reset. The builder fingerprints the postgres binary
and folds the installed module hash into the seed recipe. Reseed after every
rebuild, including library-only builds. Backend startup also checks both file
sizes, alongside the existing catalog/control compatibility checks.

The authentication hook checks the startup nonce and refuses disabling event
triggers in the startup packet. It overrides role/database defaults that could
disable login triggers. The login trigger checks the lane again after startup
advertisement and before command dispatch. Extension admission/control objects
cannot be altered or dropped while enabled. Retained pool sockets must remain
private to the pool wrappers; a refused reset leaves the lane closed.

Keep `max_prepared_transactions=0`, `autovacuum=off`, and the bootstrap superuser.
Use only seed-built lanes, keep the control database read-mostly, and preserve
the plan's restrictions on database copying and mapped-catalog rewrites.

The core interfaces are:

- `RegisterStorageManager(f_smgr *, make_default)` during shared preload;
  selection is global, with a single default and at most 16 registered managers.
- Optional `f_smgr.smgr_releaseall`: runs even with no open relations and must
  not allocate. An idle checkpointer otherwise pins an old epoch past reset.
- `pgaio_io_complete_synthetic`: completes already-filled read buffers through
  the normal AIO stages, with no IO-method submission. Its synchronous flag is
  required for cross-backend io_uring waiters.

Relation records own their locks and remain stable until arena detach. The
truncate path locks its already-mapped, prewarmed record without a dshash walk;
close and barrier attachment bookkeeping uses a fixed array without allocation.
Injection-point cache refresh can still allocate or raise ERROR, so the strict
allocation-free release contract is not established. DSA/DSM detach also takes
locks and performs OS unmap. Main shared memory and DROP TABLESPACE checks use
existing extension hooks.
