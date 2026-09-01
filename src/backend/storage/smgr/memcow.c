/*-------------------------------------------------------------------------
 *
 * memcow.c
 *	  ephemeral (seed + copy-on-write overlay) storage manager.
 *
 * memcow is a test-mode storage manager.  When the memcow_enabled GUC is on,
 * smgropen() selects memcow instead of md for every relation, and relation
 * pages are served from a read-only PGDATA seed (memcow_seed_directory) plus
 * an in-memory copy-on-write overlay.  Everything that is not a relation --
 * WAL, SLRUs, the relation map, pg_control, temp file spills -- keeps going
 * through the ordinary paths into the running (RAM-backed) PGDATA.
 *
 * The seed and the running PGDATA are deliberately two different directory
 * trees, usually on two different filesystems, so memcow resolves seed paths
 * against memcow_seed_directory and never against DataDir.  That is why the
 * seed location is a GUC of its own rather than something derived from
 * DataDir the way md.c derives its paths.
 *
 * THE OVERLAY.  Writes never touch the seed.  Every page written -- an
 * extend, a buffer eviction, a hint-bit-dirtied page, a temp-table page --
 * is copied into a per-database DSA arena and indexed by a dshash keyed on
 * {tablespace, relfilenumber, backend, fork, block}.  A read resolves each
 * block independently: overlay first, then the seed, so a relation can be
 * half seed and half overlay and neither half knows about the other.  Pages
 * are stored exactly as the caller handed them over, which is after
 * PageSetChecksum() has run (bufmgr.c, localbuf.c), so the unmodified buffer
 * completion callbacks verify an overlay page on re-read exactly as they
 * verify a seed page.
 *
 * Relation-level operations that md performs on files are recorded as
 * overlay metadata instead: smgr_create and smgr_unlink are WHITEOUTS that
 * hide whatever the seed happens to hold for that relfilenumber, and
 * smgr_truncate lowers both the fork's size and the number of leading blocks
 * that may still fall through to the seed.  Nothing here can modify, unlink
 * or truncate a seed file; the seed tree is opened O_RDONLY, mapped
 * PROT_READ, and is byte-identical after any workload.
 *
 * NO EPOCHS YET.  This commit gives each database exactly one permanent
 * overlay.  Lanes, epochs, reset and reclamation are the next phase; the
 * shared directory below is a slot array precisely so that an epoch
 * dimension can be added to it without changing the key layout or the
 * lookup paths.
 *
 * SEED LAYOUT.  The seed is an ordinary md-format PGDATA, so the seed file for
 * a fork is memcow_seed_directory concatenated with the *relative* path
 * relpath() already computes ("base/16384/1259", "global/1213", ...), and
 * segment N > 0 is that path with ".N" appended, exactly as in md.c.  memcow
 * reuses md's segment arithmetic (RELSEG_SIZE) verbatim but never its path
 * root: the seed and the running PGDATA are two different trees, so anything
 * resolved against DataDir would silently read the wrong (or no) bytes.
 *
 * LAZINESS IS MANDATORY, not an optimization.  smgr_open cannot raise (see
 * memcow_open()), so a missing or corrupt seed file cannot be discovered
 * there.  All per-relation seed work -- path construction, open, mmap -- is
 * therefore deferred to the first smgr_nblocks / smgr_exists / smgr_readv /
 * smgr_startreadv on the fork, where ereport(ERROR) is legal.
 *
 * MAPPING LIFETIME.  Seed mappings are established once per fork per process
 * and then kept for the life of the process.  NOTHING tears them down -- not
 * memcow_close(), not memcow_unlink() -- which makes the whole seed side of
 * memcow write-once per process: resolved once, never revised, never freed.
 * Two reasons, both load-bearing.  First, correctness
 * costs nothing to give up: the seed is immutable for the lifetime of the
 * postmaster (memcow_enabled and memcow_seed_directory are both
 * PGC_POSTMASTER, and the mapping is PROT_READ over a file nothing in the
 * cluster may write), so a cached mapping can never go stale the way an md fd
 * can go stale across a relation drop.  Second, smgr_close is on the reset
 * hot path -- InvalidateSystemCaches() -> RelationCacheInvalidate() ->
 * smgrreleaseall() -- and unmapping every fork of every relation a backend has
 * touched, only to map them all again on the next query, would put an
 * unbounded number of munmap() calls inside an interrupt holdoff on the path
 * with the tightest latency budget in the design.  Doing nothing is both
 * cheaper and more obviously infallible.  Storage that IS epoch-scoped, i.e.
 * the overlay, is what memcow_close() will have to release in a later commit.
 *
 * SIGBUS, stated so it is a known trade rather than a surprise: reading a
 * block from a truncated mapping raises SIGBUS instead of returning short, so
 * where md would report "could not read block" memcow would take the whole
 * process down.  That is acceptable only because the seed is immutable by
 * contract; it is the price of serving pages with memcpy() instead of read().
 *
 * Several callbacks are deliberately not stubs, because they run on paths where
 * raising an error is not a loud failure but an unrecoverable one:
 *
 * - smgr_open and smgr_close must be INFALLIBLE, permanently.  See the
 *	 comments on memcow_open() and memcow_close() for the reaching paths.
 *
 * - smgr_unlink reports at WARNING, never ERROR, because the f_smgr contract
 *	 above the struct in smgr.c requires it: unlinks run during post-commit and
 *	 post-abort cleanup, where it is too late to raise an error.
 *
 * - smgr_registersync and smgr_immedsync are permanent no-ops.  memcow has no
 *	 durable storage to fsync, so it never enqueues a sync request, which is
 *	 in turn why sync.c needs no memcow-specific changes at all.
 *
 * - smgr_fd is assert-unreachable.  It exists only so that an AIO handle can
 *	 be re-opened in a process other than the one that issued it (an IO
 *	 worker).  memcow satisfies reads from memory and completes the handle
 *	 without ever submitting it to the IO method layer, so no other process
 *	 ever has a memcow handle to re-open.
 *
 * CRITICAL SECTIONS.  Exactly ONE memcow callback runs inside one, and it is
 * not the one you would guess: smgr_truncate.  RelationTruncate() (storage.c)
 * wraps smgrtruncate() in START_CRIT_SECTION() because the truncation is
 * WAL-logged first and must not be abandoned; smgr_redo repeats the shape.
 * So memcow_truncate() must be ALLOCATION-FREE -- every MemoryContextAlloc
 * asserts CritSectionCount == 0, and dsa/dshash reach one whenever they have
 * to map a segment this backend has not seen (dsa_get_address -> dsm_attach).
 * See memcow_truncate() for what that costs and why the rest of what it does
 * is safe.
 *
 * The others are NOT in a critical section, checked one by one at this commit
 * rather than assumed: smgr_create (RelationCreateStorage storage.c:151,
 * heapam_relation_set_new_filelocator, index_build, fill_seq_with_data --
 * whose START_CRIT_SECTION comes after the smgrcreate, not around it,
 * ExtendBufferedRelTo bufmgr.c:1064, index_copy_data),
 * smgr_extend / smgr_zeroextend (ExtendBufferedRelShared bufmgr.c:3032,
 * ExtendBufferedRelLocal localbuf.c:470, smgr_bulk_flush, _hash_alloc_buckets,
 * RelationCopyStorageUsingBuffer), smgr_writev (FlushBuffer bufmgr.c:4526,
 * FlushLocalBuffer localbuf.c:183) and smgr_unlink (smgrDoPendingDeletes
 * storage.c:673, RelationSetNewRelfilenumber relcache.c:3855, which hold
 * HOLD_INTERRUPTS but no critical section).  They may allocate, and do.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/storage/smgr/memcow.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "access/xlog.h"
#include "access/xlogutils.h"
#include "catalog/catversion.h"
#include "catalog/pg_control.h"
#include "lib/dshash.h"
#include "miscadmin.h"
#include "port/atomics.h"
#include "port/pg_iovec.h"
#include "storage/aio.h"
#include "storage/aio_internal.h"
#include "storage/bufmgr.h"
#include "storage/checksum.h"
#include "storage/fd.h"
#include "storage/lwlock.h"
#include "storage/memcow.h"
#include "storage/shmem.h"
#include "storage/subsystems.h"
#include "utils/dsa.h"
#include "utils/hsearch.h"
#include "utils/memutils.h"

/* GUC variables */
bool		memcow_enabled = false;
char	   *memcow_seed_directory = NULL;

/*
 * The fingerprint file is a few hundred bytes of ASCII key=value lines and the
 * seed builder asserts it stays under 512.  Read it into something with real
 * headroom instead: overrunning the builder's contract must be a clean error
 * naming the file, never a silently truncated parse that then reports a
 * "missing" key which is in fact present.
 */
#define MEMCOW_FINGERPRINT_BASENAME		"memcow_seed.fingerprint"
#define MEMCOW_FINGERPRINT_BUFSZ		4096
#define MEMCOW_FINGERPRINT_VERSION		1
/* longest value is a 64-char sha256; NAMEDATALEN covers the superuser name */
#define MEMCOW_FINGERPRINT_VALUE_MAX	128

/*
 * One mapped seed segment.  A segment holds at most RELSEG_SIZE blocks, the
 * same as md's, because the seed is an md-format PGDATA.
 *
 * base is NULL, with nblocks 0, for a zero-length segment file: mmap() rejects
 * a zero length, and an empty fork (a freshly created relation in the seed) is
 * perfectly ordinary.
 */
typedef struct MemcowSeedSeg
{
	char	   *base;			/* mmap base, or NULL for an empty segment */
	size_t		maplen;			/* bytes mapped; nblocks * BLCKSZ */
	BlockNumber nblocks;		/* blocks in this segment */
} MemcowSeedSeg;

/*
 * Per-fork seed state.  "resolved" distinguishes "we have not looked yet" from
 * "we looked and there is no such fork in the seed" (resolved && !exists),
 * which is the answer smgr_exists needs and must not recompute on every call.
 */
typedef struct MemcowForkSeed
{
	bool		resolved;		/* has the seed been consulted for this fork? */
	bool		exists;			/* does segment 0 exist in the seed? */
	BlockNumber nblocks;		/* total blocks across all segments */
	int			nsegs;			/* number of entries in segs[] */
	MemcowSeedSeg *segs;		/* mapped segments, ascending; NULL if none */
} MemcowForkSeed;

/*
 * Per-relation seed state.
 *
 * This lives in a memcow-local hash rather than in SMgrRelationData because
 * SMgrRelationData is smgr.h's, and memcow does not get to modify smgr.h.  The
 * key is exactly smgr's own key, so this table and SMgrRelationHash are
 * populated one-for-one and can be sized the same way.
 */
typedef struct MemcowRelSeed
{
	RelFileLocatorBackend key;	/* hash key -- must be first */
	MemcowForkSeed forks[MAX_FORKNUM + 1];
} MemcowRelSeed;

/* ----------------------------------------------------------------
 *		overlay data structures
 * ----------------------------------------------------------------
 */

/*
 * How many databases may hold an overlay at one time.
 *
 * There is no natural bound to take here -- a cluster may have any number of
 * databases -- so this is a budget, not a limit derived from something.  128
 * was chosen because it is comfortably above every population this design
 * actually has: the seed built by src/test/memcow/seed/ has 12 databases, and
 * the lane count the next phase will want is bounded by max_connections
 * divided by the per-lane connection count, i.e. tens.  The cost of being
 * generous is trivial and paid once: the whole directory is
 * 128 * sizeof(MemcowDbSlot), a few kilobytes of main shared memory, and a
 * slot costs nothing further until a database is actually written to (the
 * arena underneath it is created lazily).  Exhaustion is a clean ERROR naming
 * this constant rather than a corruption, and it can only be reached by a
 * cluster with more than 128 written-to databases, which test mode does not
 * have.
 *
 * The alternative -- one arena for the whole cluster, no directory, no limit
 * -- was rejected because reset discards a database's overlay by discarding
 * its arena.  Per-database arenas are the mechanism, not an optimization.
 */
#define MEMCOW_MAX_OVERLAY_DBS		128

/*
 * Key of the per-fork overlay record.
 *
 * dbOid is deliberately absent: it selects the arena, so carrying it in the
 * key as well would be redundant.  Everything else that distinguishes one
 * fork's storage from another's is here, including the owning backend, which
 * is what keeps two sessions' temp relations apart when they collide on a
 * relfilenumber (they can: temp relfilenumbers come from the same counter but
 * a temp relation's identity is the pair).
 *
 * The static assert is the whole reason the members are laid out as five
 * same-sized integers: dshash compares and hashes the leading key_size bytes
 * with memcmp/hash_bytes, so a padding hole would make two equal keys compare
 * unequal depending on what was in the caller's stack.  This is exactly the
 * property smgropen() relies on for HASH_BLOBS, made checkable.
 */
typedef struct MemcowRelKey
{
	Oid			spcOid;			/* tablespace */
	RelFileNumber relNumber;	/* relation */
	int32		backend;		/* ProcNumber, or INVALID_PROC_NUMBER */
	int32		forknum;		/* ForkNumber */
} MemcowRelKey;

StaticAssertDecl(sizeof(MemcowRelKey) == 4 * sizeof(uint32),
				 "MemcowRelKey must not contain padding");

/*
 * Per-fork overlay record.  Its absence is meaningful: a fork with no record
 * has never been written, so it has no overlay blocks either and is served
 * entirely from the seed.  That is the fast path, and it is why the read path
 * can skip the per-block lookups entirely for an untouched relation.
 *
 * seed_visible is the number of LEADING blocks that may still fall through to
 * the seed.  It starts equal to the seed's size for the fork and is only ever
 * lowered -- by truncate, and to zero by create and unlink.  It cannot be
 * derived from nblocks: truncating a 100-block seed relation to 10 and then
 * extending it back to 20 must leave blocks 10-19 served from the overlay,
 * not from the seed's copy of them.
 *
 * INVARIANT, relied on everywhere below: every block in [seed_visible,
 * nblocks) has a block entry.  Extend and write raise nblocks only after
 * storing the page.  This is what makes "a block inside the relation that
 * memcow cannot serve" unreachable rather than merely unlikely.
 *
 * blocks_high is a SEPARATE high-water mark over the block table: block
 * entries exist for [0, blocks_high) and nowhere above it.  It says nothing
 * about nblocks in either direction and must not be confused with it -- a
 * record created for a pure-seed fork starts with nblocks equal to the seed's
 * size and blocks_high zero, because the fork has a size but owns no pages.
 * It is only ever raised, by memcow_publish_nblocks(), and only ever zeroed by
 * unlink, which reclaims exactly this range.
 *
 * Two things need it.  Reclamation: truncate does NOT free the pages it drops
 * (memcow_truncate() runs inside the caller's critical section, where touching
 * the block table would allocate) and neither does create, which whites the
 * fork out down to zero blocks -- so nblocks is not a bound on what the fork
 * owns and unlink would orphan the rest.  Entries above nblocks are invisible
 * to every reader and are overwritten in place if the fork grows back, so
 * leaving them costs memory bounded by the fork's peak size and nothing else.
 * Reads: blocks_high == 0 is what tells memcow_lookup_fork() that a fork with
 * a record still has no pages of its own, which is what keeps a pure-seed
 * relation off the per-block lookup path now that memcow_nblocks() creates a
 * record for everything it sizes.
 */
typedef struct MemcowRelEntry
{
	MemcowRelKey key;			/* hash key -- must be first */
	bool		exists;			/* false once the fork has been unlinked */
	BlockNumber nblocks;		/* current size of the fork */
	BlockNumber seed_visible;	/* blocks [0, seed_visible) may come from seed */
	BlockNumber blocks_high;	/* block entries exist only below this */
} MemcowRelEntry;

/*
 * Key of one overlay page.  Same rules, same reason, one more member.
 */
typedef struct MemcowBlockKey
{
	Oid			spcOid;
	RelFileNumber relNumber;
	int32		backend;
	int32		forknum;
	BlockNumber blocknum;
} MemcowBlockKey;

StaticAssertDecl(sizeof(MemcowBlockKey) == 5 * sizeof(uint32),
				 "MemcowBlockKey must not contain padding");

/*
 * One overlay page.
 *
 * The page is a separate BLCKSZ allocation rather than an inline array, and
 * that is a deliberate memory-footprint decision rather than a stylistic one.
 * dshash allocates an item as entry_size + MAXALIGN(sizeof(dshash_table_item))
 * (dshash.c), and dsa's largest small-object size class is 8192 bytes
 * (dsa.c).  An inline page would therefore make every item 8232 bytes, which
 * spills into dsa's large-object path and is rounded up to three 4 kB pages
 * -- 12 kB of arena for 8 kB of data, a 50% overhead on the single dominant
 * consumer of memory in this design.  Split, the page lands exactly on the
 * 8192 size class and the item lands on the 48-byte class: about 0.6%
 * overhead instead.
 */
typedef struct MemcowBlockEntry
{
	MemcowBlockKey key;			/* hash key -- must be first */
	dsa_pointer page;			/* BLCKSZ bytes of post-checksum page image */
} MemcowBlockEntry;

/*
 * One database's overlay, as published in main shared memory.
 *
 * in_use is a separate flag rather than "dbOid != InvalidOid" because
 * InvalidOid IS a legal dbOid here: shared catalogs live in global/ with
 * dbOid 0, they are written (pg_database's relfrozenxid, pg_shdepend rows),
 * and so they get an overlay like any other database.
 *
 * PHASE 2 will add {epoch, nonce} beside these three handles and make
 * publication a single versioned store of the whole slot.  The layout is
 * already a slot array of plain values for that reason.
 */
typedef struct MemcowDbSlot
{
	bool		in_use;
	Oid			dbOid;
	dsa_handle	area;
	dshash_table_handle rels;
	dshash_table_handle blocks;
} MemcowDbSlot;

typedef struct MemcowShmemState
{
	LWLock		lock;			/* serializes slot creation */

	/*
	 * Bumped whenever a slot is created.  A backend that looked for a
	 * database's overlay and did not find one caches that negative answer
	 * against this counter, so the common case -- a read of a relation in a
	 * database nobody has written to -- costs one unlocked atomic read rather
	 * than a locked scan of the slot array on every smgr_nblocks().
	 */
	pg_atomic_uint32 generation;

	int			dsa_tranche;	/* LWLock tranches, assigned in init_fn so */
	int			rel_tranche;	/* that every process agrees on them without */
	int			block_tranche;	/* re-registering names per backend */

	int			nslots;			/* slots[0 .. nslots) have been handed out */
	MemcowDbSlot slots[MEMCOW_MAX_OVERLAY_DBS];
} MemcowShmemState;

static MemcowShmemState *MemcowShmem = NULL;

/*
 * This process's attachment to one database's overlay.
 *
 * area == NULL means "as of generation absent_gen, this database had no
 * overlay".  Attachments are never dropped once made: see memcow_close().
 */
typedef struct MemcowDbLocal
{
	Oid			dbOid;			/* hash key -- must be first */
	dsa_area   *area;			/* NULL if there is no overlay (yet) */
	dshash_table *rels;
	dshash_table *blocks;
	uint32		absent_gen;		/* only meaningful while area == NULL */
} MemcowDbLocal;

/*
 * dshash needs the comparison, hash and copy functions supplied even when
 * attaching, because function pointers are not portable between processes.
 * The tranche id is the one field that is not known at compile time, so these
 * are templates that memcow_overlay_params() completes.
 */
static const dshash_parameters memcow_rel_params = {
	sizeof(MemcowRelKey),
	sizeof(MemcowRelEntry),
	dshash_memcmp,
	dshash_memhash,
	dshash_memcpy,
	-1							/* tranche id, filled in at run time */
};

static const dshash_parameters memcow_block_params = {
	sizeof(MemcowBlockKey),
	sizeof(MemcowBlockEntry),
	dshash_memcmp,
	dshash_memhash,
	dshash_memcpy,
	-1							/* tranche id, filled in at run time */
};

/*
 * Everything the read and write paths need to know about one fork, gathered
 * in one place by memcow_lookup_fork() so that no shared lock is held across
 * more than a single lookup.
 */
typedef struct MemcowFork
{
	MemcowDbLocal *db;			/* overlay, or NULL if the db has none */
	MemcowRelKey relkey;
	bool		have_overlay;	/* is there an overlay record for this fork? */
	bool		have_blocks;	/* can this fork have overlay pages at all? */
	bool		exists;
	BlockNumber nblocks;
	BlockNumber seed_visible;
	MemcowForkSeed *seed;		/* NULL if nothing can come from the seed */
} MemcowFork;

/*
 * Per-process memcow state, established by memcow_init().  All are NULL when
 * memcow is off, and memcow_open() asserts they are not NULL when it is: with
 * real state here, an smgropen() that beat smgrinit() would be a null deref
 * rather than the harmless no-op it used to be.
 */
static MemoryContext MemcowCxt = NULL;
static HTAB *MemcowSeedHash = NULL;
static HTAB *MemcowDbHash = NULL;

static void memcow_check_seed_directory(void);
static void memcow_check_fingerprint(void);
static MemcowForkSeed *memcow_resolve_fork(SMgrRelation reln, ForkNumber forknum,
										   bool missing_ok);
static const char *memcow_seed_block(MemcowForkSeed *fs, BlockNumber blocknum);
static MemcowDbLocal *memcow_overlay(Oid dbOid, bool create);
static void memcow_lookup_fork(SMgrRelation reln, ForkNumber forknum,
							   bool missing_ok, MemcowFork *f);
static MemcowRelEntry *memcow_relentry_lock(SMgrRelation reln,
											ForkNumber forknum,
											MemcowDbLocal **dbp,
											bool *created);
static void memcow_store_block(MemcowDbLocal *db, MemcowBlockKey *key,
							   const void *page);
static void memcow_discard_blocks(MemcowDbLocal *db, const MemcowRelKey *relkey,
								  BlockNumber from, BlockNumber to);
static bool memcow_copy_block(MemcowFork *f, MemcowBlockKey *key,
							  BlockNumber blocknum, void *dest);
static void memcow_publish_nblocks(MemcowDbLocal *db, const MemcowRelKey *relkey,
								   BlockNumber nblocks);
static void memcow_store_range(MemcowDbLocal *db, const MemcowRelKey *relkey,
							   BlockNumber cur, BlockNumber high,
							   BlockNumber blocknum, BlockNumber end,
							   const void *const *buffers);
pg_noreturn static void memcow_fork_missing(const RelFileLocatorBackend *rlocator,
											ForkNumber forknum);
pg_noreturn static void memcow_out_of_memory(BlockNumber blocknum, Oid spcOid,
											 RelFileNumber relNumber);

static void MemcowShmemRequest(void *arg);
static void MemcowShmemInit(void *arg);

/*
 * Registered from src/include/storage/subsystemlist.h.  memcow takes no main
 * shared memory at all when the GUC is off, so an unpatched-looking server is
 * unpatched down to the byte count in shared_memory_size.
 */
const ShmemCallbacks MemcowShmemCallbacks = {
	.request_fn = MemcowShmemRequest,
	.init_fn = MemcowShmemInit,
};

static void
MemcowShmemRequest(void *arg)
{
	if (!memcow_enabled)
		return;

	ShmemRequestStruct(.name = "memcow overlay directory",
					   .size = sizeof(MemcowShmemState),
					   .ptr = (void **) &MemcowShmem,
		);
}

/*
 * The tranche ids are allocated here, once, in the postmaster, and stored in
 * shared memory rather than in a static: LWLockNewTrancheId() allocates from
 * a shared counter, so calling it per backend would burn a tranche slot per
 * backend and give different processes different ids for the same lock.  This
 * runs after LWLockShmemInit() because LWLockCallbacks is the first entry in
 * subsystemlist.h and init callbacks run in registration order (shmem.c).
 *
 * DSM is NOT available yet -- dsm_postmaster_startup() runs after
 * ShmemInitRequested() (ipci.c) -- which is one of the reasons arenas are
 * created lazily, on first write, rather than here.
 */
static void
MemcowShmemInit(void *arg)
{
	if (!memcow_enabled)
		return;

	memset(MemcowShmem, 0, sizeof(*MemcowShmem));

	MemcowShmem->dsa_tranche = LWLockNewTrancheId("MemcowOverlayArena");
	MemcowShmem->rel_tranche = LWLockNewTrancheId("MemcowOverlayRelation");
	MemcowShmem->block_tranche = LWLockNewTrancheId("MemcowOverlayBlock");

	LWLockInitialize(&MemcowShmem->lock,
					 LWLockNewTrancheId("MemcowOverlayDirectory"));
	pg_atomic_init_u32(&MemcowShmem->generation, 1);
}

/*
 * memcow_init() -- Initialize private state for the memcow storage manager.
 *
 * Called from smgrinit(), i.e. once per backend from BaseInit(), for every
 * compiled-in storage manager whether or not it is the selected one.  So the
 * very first thing to do is to get out of the way when memcow is off: with
 * memcow_enabled off this function must be a perfect no-op, because that is
 * the configuration in which the seed itself is built and in which the
 * server is expected to behave exactly as an unpatched server does.
 *
 * When memcow is on, this is the earliest memcow-controlled code that runs in
 * a process, and it is therefore where the seed is validated.  A bad seed is
 * FATAL: falling back to md would silently serve the running PGDATA, which
 * for a test engine is a wrong answer dressed up as a working one.
 */
void
memcow_init(void)
{
	HASHCTL		ctl;

	if (!memcow_enabled)
		return;

	memcow_check_seed_directory();
	memcow_check_fingerprint();

	/*
	 * Everything memcow allocates per relation lives here, mirroring md.c's
	 * MdCxt.  It is never reset: seed mappings are process-lifetime (see the
	 * file header), and a context that is only ever appended to is one more
	 * thing memcow_close() cannot get wrong.
	 */
	MemcowCxt = AllocSetContextCreate(TopMemoryContext,
									  "MemcowSmgr",
									  ALLOCSET_DEFAULT_SIZES);

	/*
	 * 400 is smgr.c's own initial size for SMgrRelationHash.  That is not a
	 * coincidence to be tidied away: this table is keyed on the identical
	 * RelFileLocatorBackend and gains an entry only where smgr already has
	 * one, so the two grow together and any better number would be a better
	 * number for both.  HASH_BLOBS is safe here for exactly the reason it is
	 * safe in smgropen(): RelFileLocatorBackend is four uint32s and an int
	 * with no padding, so bitwise comparison of the key is exact.
	 */
	ctl.keysize = sizeof(RelFileLocatorBackend);
	ctl.entrysize = sizeof(MemcowRelSeed);
	ctl.hcxt = MemcowCxt;
	MemcowSeedHash = hash_create("memcow seed relation table", 400, &ctl,
								 HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

	/*
	 * This process's overlay attachments, keyed by dbOid.  An ordinary
	 * backend has at most two live entries (its own database and dbOid 0 for
	 * the shared catalogs); the checkpointer and bgwriter flush buffers for
	 * every database and so accumulate one per database they have written.
	 * 8 is therefore already generous as an initial size, and dynahash grows
	 * it if a process proves otherwise.
	 */
	ctl.keysize = sizeof(Oid);
	ctl.entrysize = sizeof(MemcowDbLocal);
	ctl.hcxt = MemcowCxt;
	MemcowDbHash = hash_create("memcow overlay attachment table", 8, &ctl,
							   HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

	Assert(MemcowShmem != NULL);
}

/*
 * Read one key out of the fingerprint image, copying its value into out[].
 *
 * Returns false if the key is absent, or if its value does not fit.  Matching
 * is anchored at a line start and requires the very next character to be '=',
 * so "pg_version" does not match "pg_control_version".  A trailing CR is
 * dropped so that a fingerprint that has been through a CRLF-mangling copy
 * still parses.
 *
 * The image is deliberately NOT modified.  An earlier version of this
 * NUL-terminated each line in place as it scanned, which works for the first
 * key and then makes every later key unfindable, because the scan for key N+1
 * stops at the NUL that the lookup of key N wrote.  That failure is silent in
 * the sense that matters: every key reports as "missing", i.e. as a seed
 * problem, which is the most misleading way this function could possibly be
 * wrong.
 */
static bool
memcow_fingerprint_get(const char *image, const char *key,
					   char *out, size_t outlen)
{
	size_t		keylen = strlen(key);
	const char *line = image;

	while (*line != '\0')
	{
		const char *eol = strchr(line, '\n');
		const char *end = (eol != NULL) ? eol : line + strlen(line);

		if (end > line && end[-1] == '\r')
			end--;

		if ((size_t) (end - line) > keylen &&
			strncmp(line, key, keylen) == 0 &&
			line[keylen] == '=')
		{
			const char *value = line + keylen + 1;
			size_t		vlen = end - value;

			if (vlen >= outlen)
				return false;
			memcpy(out, value, vlen);
			out[vlen] = '\0';
			return true;
		}

		if (eol == NULL)
			break;
		line = eol + 1;
	}

	return false;
}

/*
 * Compare one numeric fingerprint key against a value this binary knows.
 *
 * A mismatch is FATAL and names the key, because the key is the only part of
 * the message a human can act on: "this seed was built by a different server"
 * is useless, "catalog_version_no is 202508131 in the seed and 202508129 here"
 * is a rebuild instruction.  A missing or non-numeric key is equally FATAL --
 * a fingerprint memcow cannot fully parse proves nothing at all, and the whole
 * point of the file is to fail before the first wrong page is served.
 */
static void
memcow_fingerprint_expect(const char *image, const char *path, const char *key,
						  int64 expected)
{
	char		value[MEMCOW_FINGERPRINT_VALUE_MAX];
	char	   *endptr;
	int64		found;

	if (!memcow_fingerprint_get(image, key, value, sizeof(value)))
		ereport(FATAL,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow seed fingerprint \"%s\" has no usable \"%s\" key",
						path, key),
				 errhint("Rebuild the seed with this server binary.")));

	errno = 0;
	found = strtoi64(value, &endptr, 10);
	if (endptr == value || *endptr != '\0' || errno != 0)
		ereport(FATAL,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow seed fingerprint \"%s\" has a non-numeric \"%s\" value \"%s\"",
						path, key, value)));

	if (found != expected)
		ereport(FATAL,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow seed fingerprint mismatch on \"%s\": seed has " INT64_FORMAT ", this server has " INT64_FORMAT,
						key, found, expected),
				 errdetail("Fingerprint file is \"%s\".", path),
				 errhint("Rebuild the seed with this server binary.")));
}

/*
 * Validate <seed>/memcow_seed.fingerprint against this binary.
 *
 * The pg_control validation core already performs does not cover the seed at
 * all: the seed is a second directory tree that nothing else in the server
 * looks at.  This file is what proves the two were produced by the same build,
 * and it is checked here, in memcow_init(), so that a stale seed is a startup
 * failure rather than a wrong answer discovered one page at a time.
 *
 * Deliberately NOT checked here: postgres_binary_sha256.  It is the strongest
 * signal in the file and it costs a full sequential read of the ~40 MB server
 * binary -- in every process, because smgrinit() runs from BaseInit(), which
 * includes processes that never touch a relation.  postgres_binary_bytes is
 * checked instead (one stat()), backed by catalog_version_no for the catalog
 * changes a size comparison could miss.  A sha256 check belongs somewhere that
 * runs once per cluster rather than once per backend.
 */
static void
memcow_check_fingerprint(void)
{
	char		path[MAXPGPATH];
	char		image[MEMCOW_FINGERPRINT_BUFSZ];
	char		value[MEMCOW_FINGERPRINT_VALUE_MAX];
	struct stat st;
	int			fd;
	size_t		total = 0;

	if (snprintf(path, sizeof(path), "%s/%s", memcow_seed_directory,
				 MEMCOW_FINGERPRINT_BASENAME) >= (int) sizeof(path))
		ereport(FATAL,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow seed directory path is too long: \"%s\"",
						memcow_seed_directory)));

	fd = OpenTransientFile(path, O_RDONLY | PG_BINARY);
	if (fd < 0)
		ereport(FATAL,
				(errcode_for_file_access(),
				 errmsg("could not open memcow seed fingerprint \"%s\": %m",
						path),
				 errhint("memcow_seed_directory must name a seed built by src/test/memcow/seed/build_seed.sh.")));

	/*
	 * Read defensively rather than trusting the builder's 512-byte assertion.
	 * A single read() can return short for reasons that have nothing to do
	 * with the file being small, and a file that does not fit is an error --
	 * not something to parse the first few KB of and then report a key as
	 * "missing" when it is merely past the end of the buffer.
	 */
	while (total < sizeof(image) - 1)
	{
		int			nread = read(fd, image + total, sizeof(image) - 1 - total);

		if (nread < 0)
		{
			if (errno == EINTR)
				continue;
			ereport(FATAL,
					(errcode_for_file_access(),
					 errmsg("could not read memcow seed fingerprint \"%s\": %m",
							path)));
		}
		if (nread == 0)
			break;
		total += nread;
	}
	image[total] = '\0';

	if (total == sizeof(image) - 1)
		ereport(FATAL,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow seed fingerprint \"%s\" is larger than %d bytes",
						path, MEMCOW_FINGERPRINT_BUFSZ - 1)));

	if (memchr(image, '\0', total) != NULL)
		ereport(FATAL,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow seed fingerprint \"%s\" is not plain text",
						path)));

	CloseTransientFile(fd);

	/*
	 * The format gate comes first: every other check below reads keys whose
	 * meaning is defined by this version number.
	 */
	if (!memcow_fingerprint_get(image, "memcow_seed_fingerprint_version",
								value, sizeof(value)) ||
		atoi(value) != MEMCOW_FINGERPRINT_VERSION)
		ereport(FATAL,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow seed fingerprint \"%s\" has unsupported \"memcow_seed_fingerprint_version\"",
						path),
				 errdetail("This server understands version %d.",
						   MEMCOW_FINGERPRINT_VERSION)));

	/* pg_version is the one non-numeric key, so it is compared as text */
	if (!memcow_fingerprint_get(image, "pg_version", value, sizeof(value)))
		ereport(FATAL,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow seed fingerprint \"%s\" has no usable \"pg_version\" key",
						path),
				 errhint("Rebuild the seed with this server binary.")));
	if (strcmp(value, PG_MAJORVERSION) != 0)
		ereport(FATAL,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow seed fingerprint mismatch on \"pg_version\": seed has \"%s\", this server has \"%s\"",
						value, PG_MAJORVERSION),
				 errdetail("Fingerprint file is \"%s\".", path),
				 errhint("Rebuild the seed with this server binary.")));

	memcow_fingerprint_expect(image, path, "pg_control_version",
							  PG_CONTROL_VERSION);
	memcow_fingerprint_expect(image, path, "catalog_version_no",
							  CATALOG_VERSION_NO);
	memcow_fingerprint_expect(image, path, "block_size", BLCKSZ);
	memcow_fingerprint_expect(image, path, "relseg_blocks", RELSEG_SIZE);
	memcow_fingerprint_expect(image, path, "wal_block_size", XLOG_BLCKSZ);

	/*
	 * data_page_checksum_version is the one key compared against a *runtime*
	 * value rather than a compile-time constant, and it has to be: whether the
	 * cluster verifies checksums is a property of its pg_control, not of the
	 * build.  It matters more here than anywhere else in this function,
	 * because the unmodified buffer completion callbacks run PageIsVerified()
	 * over every page memcow hands them, using the running cluster's setting
	 * against the seed's stored checksums.  A seed written without checksums,
	 * served to a cluster that expects them, fails verification on every page
	 * -- which would present as universal data corruption rather than as a
	 * configuration error.
	 */
	memcow_fingerprint_expect(image, path, "data_page_checksum_version",
							  data_checksums);

	/*
	 * Cheap "same build" pre-check.  A stat() of my_exec_path costs nothing
	 * and catches the common local failure: rebuild the server, forget to
	 * rebuild the seed, with no catalog change to give it away.
	 */
	if (my_exec_path[0] != '\0' && stat(my_exec_path, &st) == 0)
		memcow_fingerprint_expect(image, path, "postgres_binary_bytes",
								  (int64) st.st_size);
}

/*
 * Validate memcow_seed_directory.
 *
 * All this checks is that a seed location was configured at all and that this
 * process can traverse and read it.  The content checks -- pg_control,
 * PG_VERSION, the build hash -- are memcow_check_fingerprint()'s, which
 * memcow_init() calls immediately after this.
 *
 * The path must be absolute.  A backend's working directory is DataDir, so a
 * relative seed path would quietly resolve inside the running PGDATA -- the
 * one place the seed is guaranteed not to be -- and the failure would show up
 * much later as missing or wrong pages.
 */
static void
memcow_check_seed_directory(void)
{
	struct stat st;

	if (memcow_seed_directory == NULL || memcow_seed_directory[0] == '\0')
		ereport(FATAL,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow_enabled requires memcow_seed_directory to be set"),
				 errhint("Set memcow_seed_directory to the read-only PGDATA seed built for this server binary.")));

	if (!is_absolute_path(memcow_seed_directory))
		ereport(FATAL,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow_seed_directory must be an absolute path, not \"%s\"",
						memcow_seed_directory),
				 errhint("A relative path would be resolved inside the data directory.")));

	if (stat(memcow_seed_directory, &st) != 0)
		ereport(FATAL,
				(errcode_for_file_access(),
				 errmsg("could not stat memcow seed directory \"%s\": %m",
						memcow_seed_directory)));

	if (!S_ISDIR(st.st_mode))
		ereport(FATAL,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow seed directory \"%s\" is not a directory",
						memcow_seed_directory)));

	if (access(memcow_seed_directory, R_OK | X_OK) != 0)
		ereport(FATAL,
				(errcode_for_file_access(),
				 errmsg("could not read memcow seed directory \"%s\": %m",
						memcow_seed_directory)));
}

/*
 * Build the seed path of one segment of one fork.
 *
 * relpath() returns a path relative to a data directory ("base/16384/1259",
 * "global/1213", "pg_tblspc/.../t3_17000"), which is exactly what is needed
 * here: the seed is an ordinary PGDATA, so the same relative path names the
 * same relation inside it.  Only the root differs, and the root is the whole
 * point -- resolving against DataDir would name a file in the running
 * (RAM-backed) PGDATA, which for a seed relation does not exist at all.
 *
 * Segment numbering follows md.c: segment 0 is the bare path, segment N is
 * "<path>.N".
 */
static void
memcow_seed_path(const RelFileLocatorBackend *rlocator, ForkNumber forknum,
				 int segno, char *buf, size_t buflen)
{
	RelPathStr	rel = relpath(*rlocator, forknum);
	int			len;

	if (segno == 0)
		len = snprintf(buf, buflen, "%s/%s", memcow_seed_directory, rel.str);
	else
		len = snprintf(buf, buflen, "%s/%s.%d", memcow_seed_directory,
					   rel.str, segno);

	if (len < 0 || (size_t) len >= buflen)
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("memcow seed path for relation %s is too long",
						rel.str)));
}

/*
 * Map one seed segment.
 *
 * Returns false, leaving *seg untouched, if the segment file does not exist.
 * Any other failure is an ERROR: a seed we can see but cannot read is a
 * broken seed, and quietly treating it as end-of-relation would turn it into
 * silently missing rows.
 *
 * The fd is closed as soon as the mapping exists.  A mapping keeps its own
 * reference to the underlying file, so the descriptor is dead weight from
 * that moment on, and this process may end up mapping several thousand
 * relation files against a max_files_per_process of 1000.
 */
static bool
memcow_map_segment(const char *path, MemcowSeedSeg *seg)
{
	struct stat st;
	int			fd;
	BlockNumber nblocks;
	void	   *base;

	fd = OpenTransientFile(path, O_RDONLY | PG_BINARY);
	if (fd < 0)
	{
		if (FILE_POSSIBLY_DELETED(errno))
			return false;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open memcow seed file \"%s\": %m", path)));
	}

	if (fstat(fd, &st) != 0)
	{
		int			save_errno = errno;

		CloseTransientFile(fd);
		errno = save_errno;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not stat memcow seed file \"%s\": %m", path)));
	}

	/*
	 * A trailing partial block is ignored, exactly as md does it: mdnblocks()
	 * divides the file size by BLCKSZ and rounds down.  Mapping only the whole
	 * blocks also means no code below can ever hand out a pointer into a torn
	 * final page.
	 */
	nblocks = (BlockNumber) (st.st_size / BLCKSZ);

	if (nblocks == 0)
	{
		/* an empty fork is ordinary; mmap() would reject a zero length */
		CloseTransientFile(fd);
		seg->base = NULL;
		seg->maplen = 0;
		seg->nblocks = 0;
		return true;
	}

	/*
	 * PROT_READ is the enforcement of "the seed is read-only": a stray write
	 * to a seed page is a segfault here rather than corruption of the one
	 * artifact every test in the system shares.  MAP_SHARED so that the pages
	 * are the kernel's page cache pages, shared by every backend that maps the
	 * same seed file instead of copied per process.
	 */
	base = mmap(NULL, (size_t) nblocks * BLCKSZ, PROT_READ, MAP_SHARED, fd, 0);
	if (base == MAP_FAILED)
	{
		int			save_errno = errno;

		CloseTransientFile(fd);
		errno = save_errno;
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not map memcow seed file \"%s\": %m", path)));
	}

	CloseTransientFile(fd);

	seg->base = (char *) base;
	seg->maplen = (size_t) nblocks * BLCKSZ;
	seg->nblocks = nblocks;
	return true;
}

/*
 * Find, and on first use establish, the seed state for one fork.
 *
 * This is the function §L of the interface contract is about.  It is called
 * from smgr_nblocks / smgr_exists / smgr_readv / smgr_startreadv -- never from
 * smgr_open, which cannot raise -- so an unreadable or malformed seed surfaces
 * here, as an ordinary error, on the first access that actually needs the
 * bytes.
 *
 * If the fork has no segment 0 in the seed: missing_ok callers get a resolved
 * entry with exists = false, everyone else gets the same "could not open file"
 * error md would have produced, because that is what every caller of
 * smgrnblocks() is already written to expect from a fork that is not there.
 */
static MemcowForkSeed *
memcow_resolve_fork(SMgrRelation reln, ForkNumber forknum, bool missing_ok)
{
	MemcowRelSeed *rel;
	MemcowForkSeed *fs;
	MemcowSeedSeg *segs;
	char		path[MAXPGPATH];
	int			nsegs;
	int			capacity;
	bool		found;
	MemoryContext oldcxt;

	Assert(MemcowSeedHash != NULL);
	Assert(forknum >= 0 && forknum <= MAX_FORKNUM);

	rel = (MemcowRelSeed *) hash_search(MemcowSeedHash,
										&reln->smgr_rlocator,
										HASH_ENTER, &found);
	if (!found)
		memset(rel->forks, 0, sizeof(rel->forks));

	fs = &rel->forks[forknum];

	if (fs->resolved)
	{
		if (!fs->exists && !missing_ok)
		{
			memcow_seed_path(&reln->smgr_rlocator, forknum, 0,
							 path, sizeof(path));
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not open memcow seed file \"%s\": No such file or directory",
							path)));
		}
		return fs;
	}

	/*
	 * This is where the seed is actually opened, and therefore where
	 * Assert(!InRecovery) belongs.  It is vacuous in memcow_init(): smgrinit()
	 * runs from BaseInit(), before StartupXLOG() has decided whether recovery
	 * is needed.  Here it is a real check.  Recovery would want to replay WAL
	 * into relation files, and memcow's relation files are a read-only tree
	 * that is not even the running PGDATA; the seed is required to be cleanly
	 * shut down precisely so that this never happens.  (Note that recovery
	 * reaches relation files by paths that bypass smgr entirely as well --
	 * reinit.c walks base/<db>/ with raw unlink() and copy_file() -- so this
	 * assert is a tripwire, not a defence.)
	 */
	Assert(!InRecovery);

	/*
	 * Walk segments the way mdnblocks() does: keep going while each segment is
	 * exactly RELSEG_SIZE blocks, stop at the first short or absent one.  With
	 * the current seed this loop always ends after segment 0 (the largest seed
	 * relation is a couple of megabytes against a 1 GB segment size), so the
	 * multi-segment path is present for correctness but unexercised; see the
	 * commit message.
	 */
	nsegs = 0;
	capacity = 0;
	segs = NULL;

	for (;;)
	{
		MemcowSeedSeg seg;

		memcow_seed_path(&reln->smgr_rlocator, forknum, nsegs,
						 path, sizeof(path));

		if (!memcow_map_segment(path, &seg))
			break;

		if (nsegs == capacity)
		{
			/*
			 * The switch is deliberately this narrow.  segs[] has to outlive
			 * the caller's context -- it is per-process state -- but nothing
			 * else in this loop should land in MemcowCxt, which is never
			 * reset.
			 */
			oldcxt = MemoryContextSwitchTo(MemcowCxt);
			capacity = (capacity == 0) ? 4 : capacity * 2;
			segs = (segs == NULL)
				? (MemcowSeedSeg *) palloc(capacity * sizeof(MemcowSeedSeg))
				: (MemcowSeedSeg *) repalloc(segs, capacity * sizeof(MemcowSeedSeg));
			MemoryContextSwitchTo(oldcxt);
		}
		segs[nsegs++] = seg;

		if (seg.nblocks < (BlockNumber) RELSEG_SIZE)
			break;
		if (seg.nblocks > (BlockNumber) RELSEG_SIZE)
			elog(FATAL, "memcow seed segment \"%s\" is too big", path);
	}

	/*
	 * Publish the resolution in one go, after every fallible step is behind
	 * us.  An ERROR out of the loop above therefore leaves the entry
	 * unresolved rather than half-resolved, and the next access retries
	 * cleanly.  (The segments mapped before the failure are leaked into
	 * MemcowCxt for the life of the process.  That is the right trade: the
	 * alternative is unwinding a mapping list from an error path, and a
	 * process that has just found a broken seed is not going to get much
	 * further anyway.)
	 */
	fs->nsegs = nsegs;
	fs->segs = segs;
	fs->exists = (nsegs > 0);
	fs->nblocks = 0;
	for (int i = 0; i < nsegs; i++)
		fs->nblocks += segs[i].nblocks;
	fs->resolved = true;

	if (!fs->exists && !missing_ok)
	{
		memcow_seed_path(&reln->smgr_rlocator, forknum, 0, path, sizeof(path));
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open memcow seed file \"%s\": No such file or directory",
						path)));
	}

	return fs;
}

/*
 * Return a pointer to blocknum's image in the seed, or NULL if the seed does
 * not have that block.
 *
 * NULL is "cannot serve", and every caller has to turn it into an
 * ereport(ERROR) or a deliberate zero-fill.  It is never a short read.
 */
static const char *
memcow_seed_block(MemcowForkSeed *fs, BlockNumber blocknum)
{
	BlockNumber segno = blocknum / ((BlockNumber) RELSEG_SIZE);
	BlockNumber segoff = blocknum % ((BlockNumber) RELSEG_SIZE);

	if (segno >= (BlockNumber) fs->nsegs)
		return NULL;
	if (segoff >= fs->segs[segno].nblocks)
		return NULL;

	return fs->segs[segno].base + (size_t) segoff * BLCKSZ;
}

/* ----------------------------------------------------------------
 *		overlay: attaching
 * ----------------------------------------------------------------
 */

/*
 * Complete one of the dshash_parameters templates with the tranche id that
 * was assigned in MemcowShmemInit().
 */
static dshash_parameters
memcow_overlay_params(const dshash_parameters *template, int tranche_id)
{
	dshash_parameters params = *template;

	params.tranche_id = tranche_id;
	return params;
}

/*
 * Attach this process to one database's overlay, creating the overlay if this
 * is the first write anywhere in that database and create is true.
 *
 * Returns NULL, without creating anything, when create is false and the
 * database has no overlay.  That is the answer the read paths want: a
 * database nobody has written to is served entirely from the seed, and asking
 * for it must not cause a DSM segment to be created in, say, a read-only
 * backend or the checkpointer.
 *
 * ONE READ PATH DOES CREATE, DELIBERATELY: memcow_nblocks()'s warm-up.  It is
 * the exception that keeps memcow_truncate() out of dsa_create() inside the
 * caller's critical section; see the argument there.  Nothing else on a read
 * path may pass create = true.
 *
 * THE ATTACHMENT IS SESSION-SCOPED, NOT RESOURCE-OWNER-SCOPED, and that is
 * required rather than convenient.  A dsa_area is owned by CurrentResourceOwner
 * by default, and on the abort path all three ResourceOwnerRelease() phases
 * run BEFORE AtEOXact_SMgr() (xact.c), so a resowner-tracked mapping is
 * already gone by the time smgr_close() runs -- and gone again after every
 * aborted transaction, which would make the next statement re-attach.
 * dsa_pin_mapping() clears area->resowner, which also makes every segment
 * this area maps LATER be attached with a NULL resource owner (dsa.c sets
 * CurrentResourceOwner = area->resowner around its dsm_attach()), so the
 * property holds for segments that do not exist yet.  The area is also
 * dsa_pin()ned, so it survives every process detaching from it.
 *
 * Attachments are made in MemcowCxt, never in the caller's context: dsa_attach
 * and dshash_attach palloc their per-process bookkeeping in
 * CurrentMemoryContext, and a per-transaction context would leave dangling
 * pointers in the table below at the end of the statement.
 */
static MemcowDbLocal *
memcow_overlay(Oid dbOid, bool create)
{
	MemcowDbLocal *db;
	MemcowDbSlot *slot = NULL;
	MemoryContext oldcxt;
	uint32		gen;
	bool		found;
	dsa_area   *area;
	dshash_table *rels;
	dshash_table *blocks;
	dshash_parameters params;

	Assert(MemcowDbHash != NULL);
	Assert(MemcowShmem != NULL);

	db = (MemcowDbLocal *) hash_search(MemcowDbHash, &dbOid, HASH_FIND, NULL);
	if (db != NULL && db->area != NULL)
		return db;

	/*
	 * Either we have never looked, or we looked and found nothing.  A cached
	 * "nothing" is good until somebody creates a slot, which bumps the
	 * generation; the unlocked read is safe because the only way this process
	 * can observe a page written through a newly created overlay is via
	 * bufmgr, whose own locking has already ordered that write ahead of this
	 * read.
	 */
	gen = pg_atomic_read_u32(&MemcowShmem->generation);
	if (db != NULL && db->absent_gen == gen && !create)
		return NULL;

	LWLockAcquire(&MemcowShmem->lock, create ? LW_EXCLUSIVE : LW_SHARED);

	for (int i = 0; i < MemcowShmem->nslots; i++)
	{
		if (MemcowShmem->slots[i].in_use && MemcowShmem->slots[i].dbOid == dbOid)
		{
			slot = &MemcowShmem->slots[i];
			break;
		}
	}

	if (slot == NULL && !create)
	{
		/*
		 * Remember the absence against the generation we read before taking
		 * the lock, never against a fresher one: a slot created between the
		 * read and here must invalidate this cache entry.
		 */
		LWLockRelease(&MemcowShmem->lock);

		db = (MemcowDbLocal *) hash_search(MemcowDbHash, &dbOid,
										   HASH_ENTER, &found);
		if (!found)
		{
			db->area = NULL;
			db->rels = NULL;
			db->blocks = NULL;
		}
		db->absent_gen = gen;
		return NULL;
	}

	oldcxt = MemoryContextSwitchTo(MemcowCxt);

	if (slot == NULL)
	{
		if (MemcowShmem->nslots >= MEMCOW_MAX_OVERLAY_DBS)
		{
			MemoryContextSwitchTo(oldcxt);
			LWLockRelease(&MemcowShmem->lock);
			ereport(ERROR,
					(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
					 errmsg("memcow cannot hold overlays for more than %d databases",
							MEMCOW_MAX_OVERLAY_DBS)));
		}

		/*
		 * Create, then publish.  Everything up to the store into slots[] is
		 * fallible, and an ERROR out of it must leave the directory exactly
		 * as it was -- LWLockReleaseAll() during abort drops the lock, and
		 * nslots has not moved, so the next attempt starts clean.  The only
		 * casualty is the arena we may have created and not published, and
		 * only if dshash_create() failed after dsa_create() succeeded.
		 */
		area = dsa_create(MemcowShmem->dsa_tranche);
		dsa_pin(area);
		dsa_pin_mapping(area);

		params = memcow_overlay_params(&memcow_rel_params,
									   MemcowShmem->rel_tranche);
		rels = dshash_create(area, &params, NULL);

		params = memcow_overlay_params(&memcow_block_params,
									   MemcowShmem->block_tranche);
		blocks = dshash_create(area, &params, NULL);

		slot = &MemcowShmem->slots[MemcowShmem->nslots];
		slot->dbOid = dbOid;
		slot->area = dsa_get_handle(area);
		slot->rels = dshash_get_hash_table_handle(rels);
		slot->blocks = dshash_get_hash_table_handle(blocks);
		slot->in_use = true;

		pg_write_barrier();
		MemcowShmem->nslots++;
		pg_atomic_fetch_add_u32(&MemcowShmem->generation, 1);
	}
	else
	{
		area = dsa_attach(slot->area);
		dsa_pin_mapping(area);

		params = memcow_overlay_params(&memcow_rel_params,
									   MemcowShmem->rel_tranche);
		rels = dshash_attach(area, &params, slot->rels, NULL);

		params = memcow_overlay_params(&memcow_block_params,
									   MemcowShmem->block_tranche);
		blocks = dshash_attach(area, &params, slot->blocks, NULL);
	}

	MemoryContextSwitchTo(oldcxt);
	LWLockRelease(&MemcowShmem->lock);

	db = (MemcowDbLocal *) hash_search(MemcowDbHash, &dbOid, HASH_ENTER, NULL);
	db->area = area;
	db->rels = rels;
	db->blocks = blocks;
	db->absent_gen = 0;

	return db;
}

/* ----------------------------------------------------------------
 *		overlay: lookup and mutation
 * ----------------------------------------------------------------
 */

static inline void
memcow_rel_key(MemcowRelKey *key, const RelFileLocatorBackend *rlocator,
			   ForkNumber forknum)
{
	key->spcOid = rlocator->locator.spcOid;
	key->relNumber = rlocator->locator.relNumber;
	key->backend = (int32) rlocator->backend;
	key->forknum = (int32) forknum;
}

static inline void
memcow_block_key(MemcowBlockKey *key, const MemcowRelKey *relkey,
				 BlockNumber blocknum)
{
	key->spcOid = relkey->spcOid;
	key->relNumber = relkey->relNumber;
	key->backend = relkey->backend;
	key->forknum = relkey->forknum;
	key->blocknum = blocknum;
}

/*
 * The error md would have produced for a fork that is not there.  Callers of
 * smgrnblocks()/smgrreadv() are already written to expect exactly this.
 */
pg_noreturn static void
memcow_fork_missing(const RelFileLocatorBackend *rlocator, ForkNumber forknum)
{
	char		path[MAXPGPATH];

	memcow_seed_path(rlocator, forknum, 0, path, sizeof(path));
	ereport(ERROR,
			(errcode_for_file_access(),
			 errmsg("could not open memcow seed file \"%s\": No such file or directory",
					path)));
}

/*
 * Gather everything the caller needs to resolve blocks of one fork.
 *
 * The overlay record is read once, into f, and the partition lock is dropped
 * before returning.  Holding it across the caller's loop would be both
 * unnecessary (the values are stable for as long as this backend holds the
 * relation lock that let it get here) and a deadlock hazard, because dshash
 * resize takes every partition lock in index order and a caller that held two
 * of them in the other order would close the cycle.
 */
static void
memcow_lookup_fork(SMgrRelation reln, ForkNumber forknum, bool missing_ok,
				   MemcowFork *f)
{
	MemcowRelEntry *re;

	memset(f, 0, sizeof(*f));
	memcow_rel_key(&f->relkey, &reln->smgr_rlocator, forknum);
	f->db = memcow_overlay(reln->smgr_rlocator.locator.dbOid, false);

	if (f->db != NULL)
		re = (MemcowRelEntry *) dshash_find(f->db->rels, &f->relkey, false);
	else
		re = NULL;

	if (re == NULL)
	{
		/*
		 * No overlay record means no overlay blocks either (see the invariant
		 * on MemcowRelEntry), so this fork is pure seed and the per-block
		 * lookups below can be skipped entirely.
		 */
		f->have_overlay = false;
		f->have_blocks = false;
		f->seed = memcow_resolve_fork(reln, forknum, missing_ok);
		f->exists = f->seed->exists;
		f->nblocks = f->seed->nblocks;
		f->seed_visible = f->seed->nblocks;
		return;
	}

	f->have_overlay = true;

	/*
	 * The record's existence and its OWNING PAGES are two different things,
	 * and the read path cares about the second.  blocks_high == 0 means this
	 * fork has never had a page stored, so the per-block lookups are provably
	 * useless and are skipped exactly as they are for a fork with no record at
	 * all.  That is what keeps a pure-seed relation on the fast path even
	 * though memcow_nblocks() now creates a record for it -- see the warm-up
	 * there, which exists so that memcow_truncate() never has to.
	 */
	f->have_blocks = (re->blocks_high > 0);
	f->exists = re->exists;
	f->nblocks = re->nblocks;
	f->seed_visible = re->seed_visible;
	dshash_release_lock(f->db->rels, re);

	if (!f->exists && !missing_ok)
		memcow_fork_missing(&reln->smgr_rlocator, forknum);

	/*
	 * The seed is still needed for the leading blocks the overlay has not
	 * displaced.  missing_ok is true here unconditionally: the fork's
	 * existence has already been settled by the overlay record, so a seed
	 * file that is simply not there (a relation created since the seed was
	 * built) is the normal case, not an error.
	 */
	if (f->seed_visible > 0)
		f->seed = memcow_resolve_fork(reln, forknum, true);
}

/*
 * The one message for "the overlay could not grow".
 *
 * SURVIVABLE, on every path that can reach it.  extend and zeroextend run
 * inside a transaction and fail the statement.  writev runs from
 * FlushBuffer(), where AbortBufferIO() puts the buffer back dirty and valid,
 * so the page is not lost -- the eviction or the checkpoint fails, not the
 * data.  The checkpointer's own sigsetjmp handler logs and retries.  What is
 * NOT survivable is the arena filling up and memcow noticing later: hence
 * NO_OOM everywhere and one clear message instead of dsa's generic one, which
 * would read as ordinary backend memory pressure.
 */
pg_noreturn static void
memcow_out_of_memory(BlockNumber blocknum, Oid spcOid, RelFileNumber relNumber)
{
	ereport(ERROR,
			(errcode(ERRCODE_OUT_OF_MEMORY),
			 errmsg("memcow overlay could not allocate shared memory"),
			 errdetail("Failed while storing block %u of relation %u/%u.",
					   blocknum, spcOid, relNumber),
			 errhint("The overlay holds every page written since the server started; it is reclaimed only by DROP and TRUNCATE until lane reset exists.")));
}

/*
 * Find, or create, the overlay record for one fork, returning it with its
 * partition lock held exclusively.  The caller must release it.
 *
 * *created says whether the record was made by this call, which is what
 * memcow_create() needs in order to tell "the fork is new" from "the fork was
 * already here".
 *
 * The seed is resolved BEFORE the record is inserted, and deliberately so: a
 * new record's baseline is the seed's size for the fork, and resolving the
 * seed both allocates and can raise, neither of which may happen under a
 * dshash partition lock.
 */
static MemcowRelEntry *
memcow_relentry_lock(SMgrRelation reln, ForkNumber forknum,
					 MemcowDbLocal **dbp, bool *created)
{
	MemcowDbLocal *db;
	MemcowRelEntry *re;
	MemcowRelKey key;
	MemcowForkSeed *fs;
	bool		found;

	db = memcow_overlay(reln->smgr_rlocator.locator.dbOid, true);
	*dbp = db;
	memcow_rel_key(&key, &reln->smgr_rlocator, forknum);

	re = (MemcowRelEntry *) dshash_find(db->rels, &key, true);
	if (re != NULL)
	{
		*created = false;
		return re;
	}

	fs = memcow_resolve_fork(reln, forknum, true);

	re = (MemcowRelEntry *) dshash_find_or_insert_extended(db->rels, &key,
														  &found,
														  DSHASH_INSERT_NO_OOM);
	if (re == NULL)
		memcow_out_of_memory(InvalidBlockNumber, key.spcOid, key.relNumber);

	if (!found)
	{
		re->exists = fs->exists;
		re->nblocks = fs->nblocks;
		re->seed_visible = fs->nblocks;
		re->blocks_high = 0;	/* a new record owns no block entries yet */
	}
	*created = !found;
	return re;
}

/*
 * Store one page into the overlay, replacing whatever was there.
 *
 * page == NULL means a page of zeroes, which is what smgr_zeroextend wants
 * and which the allocator can produce for free.
 *
 * Out of arena memory is an ordinary ERROR with a message that names memcow,
 * not dsa's generic "out of memory".  Every caller is on a path where ERROR
 * is legal: extend and zeroextend run inside a transaction, and writev runs
 * from FlushBuffer(), where the failure is absorbed by AbortBufferIO() and
 * costs the statement rather than the cluster.
 */
static void
memcow_store_block(MemcowDbLocal *db, MemcowBlockKey *key, const void *page)
{
	MemcowBlockEntry *be;
	bool		found;

	/*
	 * DSHASH_INSERT_NO_OOM, and DSA_ALLOC_NO_OOM below, so that BOTH ways the
	 * arena can be exhausted -- the item and the page -- report the same
	 * memcow-specific error rather than dsa's generic "out of memory", which
	 * would be indistinguishable from backend memory pressure.
	 */
	be = (MemcowBlockEntry *) dshash_find_or_insert_extended(db->blocks, key,
															 &found,
															 DSHASH_INSERT_NO_OOM);
	if (be == NULL)
		memcow_out_of_memory(key->blocknum, key->spcOid, key->relNumber);

	if (!found)
	{
		be->page = dsa_allocate_extended(db->area, BLCKSZ,
										 DSA_ALLOC_NO_OOM |
										 (page == NULL ? DSA_ALLOC_ZERO : 0));
		if (!DsaPointerIsValid(be->page))
		{
			dshash_delete_entry(db->blocks, be);	/* also releases the lock */
			memcow_out_of_memory(key->blocknum, key->spcOid, key->relNumber);
		}
		if (page == NULL)
		{
			dshash_release_lock(db->blocks, be);
			return;				/* DSA_ALLOC_ZERO already did the work */
		}
	}

	if (page != NULL)
		memcpy(dsa_get_address(db->area, be->page), page, BLCKSZ);
	else
		memset(dsa_get_address(db->area, be->page), 0, BLCKSZ);

	dshash_release_lock(db->blocks, be);
}

/*
 * Raise a fork's published size to at least nblocks, and its reclamation bound
 * with it.  Never lowers either; lowering nblocks is memcow_truncate()'s job
 * and lowering blocks_high is memcow_unlink()'s.
 *
 * INFALLIBLE, and that is why it exists rather than a second
 * memcow_relentry_lock() call: it is used from an error path (see
 * memcow_store_range()), where raising a fresh error would replace the real
 * one.  dshash_find() only traverses and takes a lock; it neither allocates
 * nor errors.  A record that is not there is left alone -- the only way that
 * can happen is a concurrent unlink, and the whiteout it published is the
 * newer truth.
 */
static void
memcow_publish_nblocks(MemcowDbLocal *db, const MemcowRelKey *relkey,
					   BlockNumber nblocks)
{
	MemcowRelEntry *re;

	re = (MemcowRelEntry *) dshash_find(db->rels, relkey, true);
	if (re == NULL)
		return;

	if (re->nblocks < nblocks)
		re->nblocks = nblocks;
	if (re->blocks_high < nblocks)
		re->blocks_high = nblocks;

	dshash_release_lock(db->rels, re);
}

/*
 * Store blocks [Min(cur, blocknum), end) of one fork and then publish the new
 * size, where `cur` is the size the fork had when the caller last looked.
 *
 * The single implementation of "grow a fork", shared by memcow_do_extend() and
 * memcow_writev() so that the fork invariant cannot hold on one path and not
 * the other.  Blocks below `blocknum` -- the gap between where the fork
 * currently ends and where the caller's data starts -- are stored as zero
 * pages; blocks from `blocknum` on come from buffers[], or are zero pages too
 * when buffers is NULL (smgr_zeroextend).
 *
 * THE GAP FILL IS THE POINT.  The MemcowRelEntry invariant says every block in
 * [seed_visible, nblocks) has a block entry, and it is what makes "a block
 * inside the relation that memcow cannot serve" unreachable -- a case the read
 * path has no legal way to report, because a short AIO result is not an error
 * signal (see memcow_startreadv()).  md would leave a hole in a sparse file
 * and read zeroes back out of it; memcow has no sparseness to lean on, so the
 * hole has to be materialized.  bufmgr never extends or writes
 * discontiguously, so in practice this loop starts at `blocknum` and the fill
 * runs zero times; it costs one comparison to be certain, and "in practice"
 * is not the standard an invariant is held to.
 *
 * Order matters: pages are stored first, the size is published second.  A
 * fork is therefore never allowed to claim blocks it cannot produce, in the
 * ordinary case OR when a store fails part way through -- which is what the
 * PG_CATCH() is for.  Without it the pages already stored would sit above the
 * published nblocks, where neither memcow_unlink() (which reclaims [0,
 * re->nblocks)) nor memcow_truncate() (which reclaims [nblocks,
 * Max(re->nblocks, curnblk))) can ever see them: a leak on the one path that
 * reaches here, arena exhaustion, i.e. exactly when the arena can least afford
 * it.  Publishing the high-water mark of what was actually stored keeps the
 * invariant (every block below it has an entry) and makes the pages
 * reclaimable.  `b` is volatile because it is read after the longjmp.
 *
 * `cur` and `high` are the record's nblocks and blocks_high as the caller read
 * them, under the one lock it already had to take.  BOTH are needed and it is
 * a correctness bug to guess either from the other: the record's lock is
 * re-taken only when this call actually moved a high-water mark, and a write
 * that does not grow the fork (end <= cur, i.e. every ordinary FlushBuffer)
 * can still be the FIRST page a pure-seed fork ever owned, which moves
 * blocks_high from 0 and must be published or the read path keeps serving that
 * block from the seed.  An earlier version guarded only on `end > cur` and did
 * exactly that; it corrupted heap pages under memory pressure, where the
 * eviction that produced the write is common.
 */
static void
memcow_store_range(MemcowDbLocal *db, const MemcowRelKey *relkey,
				   BlockNumber cur, BlockNumber high,
				   BlockNumber blocknum, BlockNumber end,
				   const void *const *buffers)
{
	MemcowBlockKey key;
	BlockNumber start = Min(cur, blocknum);
	volatile BlockNumber b = start;

	memcow_block_key(&key, relkey, start);

	PG_TRY();
	{
		for (; b < end; b++)
		{
			key.blocknum = b;
			if (buffers == NULL || b < blocknum)
				memcow_store_block(db, &key, NULL);
			else
				memcow_store_block(db, &key, buffers[b - blocknum]);
		}
	}
	PG_CATCH();
	{
		if (b > cur || b > high)
			memcow_publish_nblocks(db, relkey, b);
		PG_RE_THROW();
	}
	PG_END_TRY();

	if (end > cur || end > high)
		memcow_publish_nblocks(db, relkey, end);
}

/*
 * Drop overlay pages for blocks [from, to) of one fork.
 *
 * INFALLIBLE AND ALLOCATION-FREE, which is what lets memcow_unlink() call it:
 * dshash_find only traverses, dshash_delete_entry only unlinks and frees, and
 * dsa_free has no failure mode.  It does take partition locks, so it can
 * wait -- that is acceptable here (unlink and truncate are not on the
 * SMGRRELEASE barrier path) and is the reason this is NOT called from
 * memcow_close().
 *
 * The cost is one lookup per block in the range rather than one pass over the
 * table, which is the right trade: a seq scan would be O(every page in the
 * database) per dropped relation, and a regression run drops a lot of small
 * relations.  It does mean dropping a very large relation costs a lookup per
 * block; that is bounded by the relation's own size and is paid once.
 *
 * THE FREE IS SAFE AGAINST A CONCURRENT READER, and it has to be argued from
 * the lock rather than from relation locking: memcow_unlink() reaches here
 * holding no relation lock at all.  The order below is what makes it work.
 * dshash_delete_entry() requires the partition lock exclusively, so it cannot
 * run while any reader holds that partition shared; and memcow_copy_block()
 * finishes copying a page out before it releases that shared lock.  So by the
 * time the dsa_free() below can run, no reader can still be looking at the
 * page, and any reader that arrives afterwards does not find the entry at all.
 * The reader must never hold the page address past the lock -- see
 * memcow_copy_block(), where it used to.
 */
static void
memcow_discard_blocks(MemcowDbLocal *db, const MemcowRelKey *relkey,
					  BlockNumber from, BlockNumber to)
{
	MemcowBlockKey key;

	if (db == NULL)
		return;

	memcow_block_key(&key, relkey, from);

	for (BlockNumber b = from; b < to; b++)
	{
		MemcowBlockEntry *be;
		dsa_pointer page;

		key.blocknum = b;
		be = (MemcowBlockEntry *) dshash_find(db->blocks, &key, true);
		if (be == NULL)
			continue;

		/* read the payload pointer before the entry is freed under us */
		page = be->page;
		dshash_delete_entry(db->blocks, be);	/* also releases the lock */

		if (DsaPointerIsValid(page))
			dsa_free(db->area, page);
	}
}

/*
 * Copy one block's page image into dest, or return false if memcow cannot
 * serve it.  `key` is scratch owned by the caller so that the constant part of
 * the key is built once per request rather than once per block.
 *
 * OVERLAY FIRST, THEN SEED, and the order is not interchangeable: a written
 * block below seed_visible exists in both places, and the overlay copy is the
 * current one.  false is "cannot serve" and every caller has to turn it into
 * an ereport(ERROR) or a deliberate zero-fill; it is never a short read.
 *
 * THE COPY HAPPENS UNDER THE PARTITION LOCK, and this function deliberately
 * does not hand an overlay page address back to its caller.  An earlier
 * version did, on the argument that the only things that free a page are
 * truncate and unlink and that both hold AccessExclusiveLock on a relation the
 * reader also holds a lock on.  Half of that is false: smgr_unlink holds NO
 * relation lock at all.  smgrDoPendingDeletes(true) runs from
 * CommitTransaction() *after* ResourceOwnerRelease(RESOURCE_RELEASE_LOCKS)
 * ("Since this may take many seconds, also delay until after releasing
 * locks", xact.c), and the abort path is ordered the same way.  So
 * memcow_unlink() -> memcow_discard_blocks() -> dsa_free() can run
 * concurrently with any reader, the freed page goes straight back onto the
 * arena's free lists, and another backend's memcow_store_block() can be
 * writing 8 kB of some other relation into it while this backend copies out.
 * DropRelationsAllBuffers() (smgr.c) narrows that window but does not close
 * it: a reader that installs its buffer tag after the dropper's scan has
 * passed that slot proceeds into smgrstartreadv() unimpeded.
 *
 * Copying under the lock closes it completely, and by construction rather than
 * by an argument about who holds what.  memcow_discard_blocks() frees a page
 * only after dshash_delete_entry() has unlinked its item, and
 * dshash_delete_entry() requires the partition lock exclusively; so a page
 * whose entry this function found under a shared partition lock cannot be
 * freed until this function has released that lock, by which point the bytes
 * are already in dest.  If the dropper wins the race instead, dshash_find()
 * simply does not find the entry and the block is reported unservable, which
 * is the correct answer for a relation that has been dropped.
 *
 * The remaining reason the old comment gave IS true and is still relied on for
 * the seed half: a dshash resize relinks items by dsa_pointer and reallocates
 * only the bucket array (dshash.c), so items never move.  It just was not
 * enough on its own.
 *
 * Costs one 8 kB memcpy inside a shared LWLock.  That is cheap and it is not a
 * scalability hazard: readers take the partition lock in share mode, so they
 * do not exclude each other, and there are 128 partitions.  It is also still
 * ONE partition lock at a time -- the constraint that matters, because dshash
 * resize takes all 128 in index order and a caller holding two of them in the
 * other order would close a deadlock cycle.
 *
 * The seed half needs no lock: seed mappings are PROT_READ, established once
 * per process, and never torn down (see memcow_close() and memcow_unlink()).
 */
static bool
memcow_copy_block(MemcowFork *f, MemcowBlockKey *key, BlockNumber blocknum,
				  void *dest)
{
	if (f->have_blocks)
	{
		MemcowBlockEntry *be;

		key->blocknum = blocknum;
		be = (MemcowBlockEntry *) dshash_find(f->db->blocks, key, false);
		if (be != NULL)
		{
			memcpy(dest, dsa_get_address(f->db->area, be->page), BLCKSZ);
			dshash_release_lock(f->db->blocks, be);
			return true;
		}
	}

	if (blocknum < f->seed_visible)
	{
		const char *page;

		Assert(f->seed != NULL);
		page = memcow_seed_block(f->seed, blocknum);
		if (page == NULL)
			return false;
		memcpy(dest, page, BLCKSZ);
		return true;
	}

	return false;
}

/*
 * memcow_open() -- Initialize newly-opened relation.
 *
 * MUST BE INFALLIBLE.  This is a permanent constraint on memcow, not an
 * artifact of the stub, and it is a property of how smgropen() is written:
 * smgropen() does hash_search(..., HASH_ENTER, &found), fully initializes the
 * entry and pushes it onto unpinned_relns, and only then calls smgr_open()
 * as the last step.  So if smgr_open() raises,
 *
 *	 - the hash entry survives the unwind, and smgrdestroyall() will later call
 *	   smgr_close() on a relation that was never opened; and
 *	 - the next smgropen() for the same locator returns found = true and
 *	   therefore NEVER calls smgr_open() again -- the relation is permanently
 *	   half-initialized, silently.
 *
 * Making this fallible would require a second modified-in-place edit inside
 * smgropen() to reorder the entry insertion, which the patch budget does not
 * permit and which would be a change to core semantics for one test-mode smgr.
 * Being infallible is much the cheaper contract to keep.
 *
 * What it actually does is zero md's private per-fork open-segment counters,
 * exactly as mdopen() does.  This is defence in depth, and it costs nothing.
 * SMgrRelationData embeds md's private md_num_open_segs[] and md_seg_fds[]
 * arrays; smgropen() does not zero them and dynahash does not zero the entry
 * payload, so on a memcow-created relation they hold whatever was in that
 * memory before.  Every md_seg_fds[] access in md.c is gated on
 * md_num_open_segs[] being nonzero, so zeroing the counters (and only the
 * counters, which is precisely what mdopen() zeroes) is sufficient: any future
 * path that reached md on a memcow relation then finds it cleanly closed
 * instead of reading a garbage segment count and closing a garbage fd pointer.
 * A clean "not open" beats memory corruption.
 */
void
memcow_open(SMgrRelation reln)
{
	/*
	 * memcow_init() must already have run in this process.  Until this commit
	 * that was merely true; now it is load-bearing, because memcow_init()
	 * establishes state that everything below dereferences.  smgrinit() is
	 * called from BaseInit() in every process type that can smgropen(), so
	 * this holds -- but it holds by an ordering nothing in smgr.c enforces,
	 * and a violation would present as a null dereference somewhere else
	 * entirely.  Assert it where the ordering is actually required.
	 */
	Assert(MemcowSeedHash != NULL);

	/* mark it not open, so md can never trip over uninitialized state */
	for (int forknum = 0; forknum <= MAX_FORKNUM; forknum++)
		reln->md_num_open_segs[forknum] = 0;
}

/*
 * memcow_close() -- Close the specified relation, if it isn't closed already.
 *
 * MUST BE INFALLIBLE, for the same reason and then some: every path that
 * reaches smgr_close() is one on which an error cannot be handled.
 *
 *	 - AtEOXact_SMgr() -> smgrdestroyall(), reached from AbortTransaction().
 *	   An ereport(ERROR) here re-enters abort processing and recurses until
 *	   PANIC: ERRORDATA_STACK_SIZE exceeded, which the postmaster answers with
 *	   an unbounded crash-restart loop.
 *	 - proc_exit() -> ShutdownPostgres() -> AbortOutOfAnyTransaction(), i.e.
 *	   the same thing during process exit.
 *	 - ProcessBarrierSmgrRelease() -> smgrreleaseall(), the
 *	   PROCSIGNAL_BARRIER_SMGRRELEASE barrier.  This is the barrier the reset
 *	   design depends on: it drives every process in the cluster through
 *	   smgr_close(), so a failure here is a cluster-wide failure.
 *	 - InvalidateSystemCaches() -> RelationCacheInvalidate() ->
 *	   smgrreleaseall(), which is the reset's own adopt call.
 *
 * The real implementation must therefore also not allocate in a way that can
 * fail, and must not block indefinitely.  Detaching a not-yet-published epoch
 * has to be a pointer swap, not something that can error out.
 *
 * STILL A NO-OP AFTER THE OVERLAY LANDED.  This deserves an argument rather
 * than an assumption, because the expectation was that the overlay would give
 * this function work to do.  It does not, and the reason is a property that
 * has to be enforced rather than assumed: MEMCOW KEEPS NO BACKEND-LOCAL CACHE
 * OF MUTABLE OVERLAY STATE.  Every overlay fact -- does this fork exist, how
 * big is it, how much of the seed still shows through, where is block N -- is
 * read out of shared memory under a partition lock at the point of use and is
 * never held past the callback that read it.  There is therefore nothing that
 * can go stale and nothing to invalidate.
 *
 * IT IS AN ENFORCED PROPERTY, NOT A DESCRIPTION.  memcow_unlink() falsified it
 * once, by recording "this relation has been dropped" as a whiteout in this
 * backend's MemcowSeedHash entry -- a mutable, overlay-scoped fact cached in
 * exactly one process, which reset could not discard and which this function's
 * doing nothing then made permanent.  It now records that in the arena
 * instead; see the argument there.  Anything added to memcow that caches a
 * mutable overlay fact process-locally either has to be invalidated here, on
 * a path where no failure can be reported, or it must not exist.  Prefer the
 * second.
 *
 * WHAT REMAINS PROCESS-LOCAL, exhaustively, and why each is exempt:
 *
 *	 - The dsa_area / dshash attachments in MemcowDbHash.  Pinned
 *	   (dsa_pin_mapping) precisely so that they are NOT resource-owner scoped,
 *	   because on the abort path all three ResourceOwnerRelease() phases run
 *	   before AtEOXact_SMgr(); dropping them here would mean re-attaching, and
 *	   re-mapping every segment, on the next query.  They name an arena, not a
 *	   fact about a relation, so nothing about them can be stale until Phase 2
 *	   gives a database more than one arena -- which is why the note below
 *	   exists.
 *	 - MemcowSeedHash and the mappings it points at.  Immutable once resolved,
 *	   over an immutable tree; see MAPPING LIFETIME in the file header.
 *	   Write-once state cannot go stale.
 *
 * Neither is a cache of anything the overlay can change, and that is the
 * distinction the property is actually about.
 *
 * WHAT PHASE 2 WILL PUT HERE, so that it is not rediscovered: with lanes and
 * epochs, a process may hold an attachment to an arena that is no longer the
 * published one for its database, and the old arena's memory cannot be
 * reclaimed until every such attachment is dropped.  The loop is over
 * MemcowDbHash -- bounded by the number of databases this process has
 * touched, and allocation-free -- detaching any entry whose epoch is not the
 * published epoch.  TWO WARNINGS FOR WHOEVER WRITES IT.  First, dsa_detach()
 * takes the area's control lock, so that loop is not wait-free in the strict
 * sense that this comment's contract asks for; it is only ever a short,
 * uncontended lock, but §4.6's barrier must not be able to reach it while
 * anything holds that lock and blocks.  Second, detaching invalidates every
 * dshash_table attached to that arena, so the dshash handles in the same
 * entry must be dropped in the same step.
 *
 * The seed half stays out of this entirely.  The obvious reading of "close"
 * is "drop this fork's seed mappings", and this function does not do that.
 * Seed state is not close-scoped state:
 *
 *	 - It cannot go stale.  memcow_enabled and memcow_seed_directory are both
 *	   PGC_POSTMASTER and the mapping is PROT_READ over a tree nothing in the
 *	   cluster may write, so the bytes behind a mapping are the same bytes for
 *	   as long as the process lives.  The reason md must close on smgr_close --
 *	   an fd surviving the unlink or truncation of the file it names -- has no
 *	   analogue here.
 *	 - Dropping it would be expensive exactly where cheapness is required.
 *	   Path 4 above is a cluster-wide barrier and path 5 is inside the reset's
 *	   25 ms budget; both walk every open relation.  Unmapping every fork a
 *	   backend has touched, only to map them all again on its next query, puts
 *	   an unbounded number of munmap() calls inside an interrupt holdoff on the
 *	   most latency-sensitive path in the design.
 *	 - Doing nothing is the strongest possible form of infallible.  There is no
 *	   hash lookup to get wrong, no free list to corrupt, and no partially
 *	   closed fork for a later call to trip over, which also makes the
 *	   idempotency smgrdestroy() requires (it calls this for all MAX_FORKNUM+1
 *	   forks) trivially true.
 *
 * Storage whose relation is really gone is reclaimed by memcow_unlink()
 * instead, which is where "really gone" is actually known.
 */
void
memcow_close(SMgrRelation reln, ForkNumber forknum)
{
}

/*
 * memcow_create() -- Create a new relation on memcow.
 *
 * A WHITEOUT, not a file creation.  The new fork is empty and, crucially,
 * seed_visible drops to zero, so nothing the seed happens to hold under this
 * relfilenumber can show through.  Today that cannot arise -- relfilenumbers
 * come from a cluster-wide counter persisted in pg_control and are never
 * reused, so a freshly created relation never collides with a seed file -- but
 * the alternative to whiting out is "a brand new relation is born containing
 * somebody else's rows", and the cost of not depending on the counter is one
 * assignment.
 *
 * mdcreate() errors when the file already exists and !isRedo.  This does not,
 * for two reasons.  Every in-tree caller checks smgrexists() first
 * (fsm_extend, vm_extend) or is creating a fresh relfilenumber, so a create
 * on an existing fork is either a redo or a retry; and there is no file to
 * be surprised by, so the failure that error protects md against -- silently
 * adopting an unrelated file -- has no memcow analogue.
 */
void
memcow_create(SMgrRelation reln, ForkNumber forknum, bool isRedo)
{
	MemcowDbLocal *db;
	MemcowRelEntry *re;
	bool		created;

	re = memcow_relentry_lock(reln, forknum, &db, &created);

	if (created || !re->exists)
	{
		re->exists = true;
		re->nblocks = 0;
		re->seed_visible = 0;
		/*
		 * blocks_high is deliberately left alone.  Any block entries an
		 * earlier incarnation of this fork left behind are now above nblocks
		 * and therefore invisible, but they are still this fork's to free, and
		 * blocks_high is the only record of how far they reach.  Zeroing it
		 * would orphan them until reset.
		 */
	}

	dshash_release_lock(db->rels, re);
}

/*
 * memcow_unlink() -- Unlink a relation.
 *
 * CANNOT FAIL, AT ALL.  Not "reports at WARNING instead of ERROR" -- that is
 * the letter of the f_smgr contract ("smgr_unlink should use elog(WARNING),
 * rather than erroring out, because we normally unlink relations during
 * post-commit/abort cleanup, and so it's too late to raise an error", the
 * comment above the f_smgr struct in smgr.c) but not its consequence.  Nothing
 * reads that WARNING: smgrDoPendingDeletes() -> smgrdounlinkall() is called
 * from AbortTransaction() a handful of lines before AtEOXact_SMgr(), so an
 * ereport(ERROR) here re-enters AbortTransaction() and recurses to
 * PANIC: ERRORDATA_STACK_SIZE exceeded, and a WARNING is simply lost.  So
 * every step below is one that cannot fail, and anything that could fail is
 * omitted rather than attempted-and-reported.  A dropped relation whose
 * overlay memcow declines to reclaim costs bounded memory that the next
 * phase's reset discards; there is never a file to leak, because the overlay
 * is memory and the seed is read-only.
 *
 * NOTE, because it is easy to misread the loop below: smgrdounlinkall()
 * (smgr.c) calls this once per fork, 0 .. MAX_FORKNUM, and never with
 * InvalidForkNumber.  The InvalidForkNumber branches are mdunlink()'s
 * convention, kept for contract parity, but unreached in this tree.
 *
 * THE WHITEOUT IS SHARED AND EPOCH-SCOPED, AND THAT IS THE WHOLE POINT OF THE
 * SHAPE OF THIS FUNCTION.  "Relation R has been dropped" is recorded by
 * clearing the MemcowRelEntry in the arena -- exists = false, nblocks = 0,
 * seed_visible = 0 -- and NOT by deleting the record and not by touching
 * anything process-local.  An earlier version did the opposite: it deleted the
 * overlay record, so the fact lived nowhere in shared memory, and then wrote a
 * whiteout into this backend's MemcowSeedHash entry, so the fact lived only
 * here.  That is a backend-local cache of a mutable overlay-scoped fact, and
 * it is fatal to the next phase.  Walk it: a test drops a seed relation in
 * epoch N (DROP TABLE, or the old relfilenumber of a TRUNCATE / VACUUM FULL /
 * CLUSTER, all of which route through smgrdounlinkall()).  Backend A's seed
 * entry becomes {resolved, !exists} permanently.  Reset publishes epoch N+1,
 * discards the arena and reverts the catalogs, so the relation exists again at
 * the same relfilenumber -- relfilenumbers are cluster-monotonic and
 * pg_control is not reverted.  Backend A is a retained pool backend, and its
 * memcow_close() does nothing to help, correctly.  It then finds no overlay
 * record, falls through to memcow_resolve_fork(), sees resolved && !exists,
 * and raises "could not open memcow seed file" -- which on a first touch
 * during relcache load is FATAL.  The relation is permanently unreadable in
 * that backend at every future epoch.
 *
 * Recording the whiteout in the arena instead makes all of that go away: it is
 * visible to every backend at once, and reset discards it along with the arena
 * that holds it.  It also makes memcow_close()'s "memcow keeps no
 * backend-local cache of mutable overlay state" TRUE rather than merely
 * asserted.
 *
 * The cost is one un-reclaimed MemcowRelEntry per dropped fork until reset,
 * about 40 bytes.  Its pages, which are the part that actually matters, are
 * still reclaimed below.  That is the same trade the infallible-DROP path
 * already makes when this backend is not attached to the overlay.
 *
 * NOTHING IN MemcowSeedHash IS MUTATED HERE, and that is deliberate: the seed
 * table is write-once, resolved once per fork per process and never revised.
 * Not unmapping the segments of a dropped relation costs address space until
 * the process exits and leaves the table growing with the number of distinct
 * relations a process has touched.  Both are already recorded as Phase 2's to
 * bound, along with the rest of the reclamation work; neither can produce a
 * wrong answer, whereas mutating the table demonstrably can.
 *
 * The overlay reclamation below is infallible, but it is NOT wait-free -- it
 * takes dshash partition locks.  That is the one property this function does
 * not share with memcow_close(), and it is fine here and only here:
 * smgr_unlink is not one of the callbacks the SMGRRELEASE barrier drives, so
 * a short wait costs a transaction's cleanup rather than stalling a
 * cluster-wide barrier.  Do not copy this code into memcow_close().
 *
 * Freeing the pages is safe even though this function holds NO relation lock
 * -- smgrDoPendingDeletes() runs after ResourceOwnerRelease(LOCKS) on both the
 * commit and the abort path.  It is safe because memcow_copy_block() copies a
 * page out under the same partition lock that memcow_discard_blocks() must
 * hold exclusively before it can free it; see the argument there.  It was NOT
 * safe when the read path returned page addresses that outlived that lock.
 *
 * Note what is deliberately NOT done here: no RegisterSyncRequest().  memcow
 * never enqueues a sync or unlink request, and that -- not the smgr_which
 * dispatch, which does not gate sync.c at all -- is the entire reason sync.c
 * needs no memcow changes.  Anything added here that talks to sync.c would
 * silently route through SYNC_HANDLER_MD and reactivate md.
 */
void
memcow_unlink(RelFileLocatorBackend rlocator, ForkNumber forknum, bool isRedo)
{
	MemcowDbLocal *db;

	Assert(MemcowSeedHash != NULL);

	/*
	 * Reclaim the overlay first.
	 *
	 * The lookup is deliberately the non-creating one, and this function
	 * NEVER attaches to an overlay it is not already attached to.  Attaching
	 * allocates and can fail, and smgr_unlink cannot report failure at all --
	 * it is called from AbortTransaction() a few lines before AtEOXact_SMgr(),
	 * where even a WARNING has no reader, so anything that can fail here has
	 * to be omitted rather than reported.  A process that has written to a
	 * relation has necessarily attached to its database's overlay already, so
	 * in practice the attachment is there; when it is not, the overlay pages
	 * are simply left for the next phase's reset to discard, which is the
	 * sanctioned answer for an infallible DROP path.
	 *
	 * When db is NULL there is also no whiteout to record, and that is not a
	 * gap: no overlay for the database means nothing in it has ever been
	 * written, so every backend's answer for this fork comes from the seed --
	 * the same answer, everywhere, which is exactly the property the whiteout
	 * exists to preserve.  It is a stale answer for the rest of this epoch, on
	 * a relfilenumber the catalogs no longer name and which is never reissued;
	 * and it is the RIGHT answer after reset, which brings the relation back.
	 */
	db = memcow_overlay(rlocator.locator.dbOid, false);
	if (db == NULL)
		return;

	for (int f = 0; f <= MAX_FORKNUM; f++)
	{
		MemcowRelKey relkey;
		MemcowRelEntry *re;
		BlockNumber n;

		/* mdunlink()'s convention: InvalidForkNumber means every fork */
		if (forknum != InvalidForkNumber && forknum != f)
			continue;

		memcow_rel_key(&relkey, &rlocator, f);
		re = (MemcowRelEntry *) dshash_find(db->rels, &relkey, true);
		if (re == NULL)
			continue;

		/*
		 * The whiteout.  Not dshash_delete_entry(): the record IS where "this
		 * fork is gone" is published, and it has to outlive this backend and
		 * die with the arena.  Clearing seed_visible matters as much as
		 * clearing exists -- a record that says the fork does not exist but
		 * still lets the seed show through would serve stale pages the moment
		 * anything reached past the exists check.
		 *
		 * The reclaim below runs to blocks_high, not nblocks: truncate and
		 * create both lower nblocks without freeing anything (truncate cannot
		 * -- it is inside a critical section), so nblocks is not the bound on
		 * what this fork actually owns.  This is where those pages are
		 * collected, and it is safe to collect them here because smgr_unlink
		 * is not in a critical section: smgrDoPendingDeletes() holds no
		 * critical section on either the commit or the abort path.
		 */
		n = re->blocks_high;
		re->exists = false;
		re->nblocks = 0;
		re->seed_visible = 0;
		re->blocks_high = 0;
		dshash_release_lock(db->rels, re);

		memcow_discard_blocks(db, &relkey, 0, n);
	}
}

/*
 * Grow a fork to at least `nblocks`, filling any gap below `blocknum` with
 * zero pages and then storing the caller's pages.
 *
 * All of that is memcow_store_range()'s, which memcow_writev() shares; see
 * there for why the gap fill and the store-then-publish order are not
 * optional.  What is left here is the one thing extend does and write does
 * not: it brings the fork into existence, exactly as mdextend() would have
 * created the file.
 */
static void
memcow_do_extend(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
				 const void *const *buffers, int nblocks)
{
	MemcowDbLocal *db;
	MemcowRelEntry *re;
	MemcowRelKey relkey;
	BlockNumber cur;
	BlockNumber high;
	BlockNumber end = blocknum + (BlockNumber) nblocks;
	bool		created;

	re = memcow_relentry_lock(reln, forknum, &db, &created);
	re->exists = true;			/* md would create the file here */
	cur = re->nblocks;
	high = re->blocks_high;
	dshash_release_lock(db->rels, re);

	memcow_rel_key(&relkey, &reln->smgr_rlocator, forknum);
	memcow_store_range(db, &relkey, cur, high, blocknum, end, buffers);
}

/*
 * memcow_extend() -- Add a block to the specified relation.
 */
void
memcow_extend(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
			  const void *buffer, bool skipFsync)
{
	/*
	 * Refuse to create block number InvalidBlockNumber, exactly as mdextend()
	 * does; upstream checks in bufmgr.c make this unreachable, but the number
	 * is a sentinel everywhere else in the system.
	 */
	if (blocknum == InvalidBlockNumber)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("cannot extend file \"%s\" beyond %u blocks",
						relpath(reln->smgr_rlocator, forknum).str,
						InvalidBlockNumber)));

	memcow_do_extend(reln, forknum, blocknum, &buffer, 1);
}

/*
 * memcow_zeroextend() -- Add new zeroed out blocks to the specified relation.
 */
void
memcow_zeroextend(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
				  int nblocks, bool skipFsync)
{
	Assert(nblocks > 0);

	if ((uint64) blocknum + nblocks >= (uint64) InvalidBlockNumber)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("cannot extend file \"%s\" beyond %u blocks",
						relpath(reln->smgr_rlocator, forknum).str,
						InvalidBlockNumber)));

	memcow_do_extend(reln, forknum, blocknum, NULL, nblocks);
}

/*
 * memcow_exists() -- Does the fork exist?
 *
 * The overlay is asked first and its answer is final: it is the only place
 * that knows about forks created since the seed was built and about forks
 * that have been unlinked since.  Only when the overlay has never heard of
 * the fork does the seed decide.
 *
 * Unlike mdexists(), this does not close the fork first.  mdexists() has to,
 * because an md fd can outlive the file it names; a memcow seed mapping
 * cannot, because the seed is immutable while the postmaster runs.  The
 * seed's negative answer stays cached for the same reason -- a fork absent
 * from the seed is absent from it permanently -- and is now a statement about
 * the seed alone rather than about the relation.
 */
bool
memcow_exists(SMgrRelation reln, ForkNumber forknum)
{
	MemcowFork	f;

	memcow_lookup_fork(reln, forknum, true, &f);

	return f.exists;
}

/*
 * memcow_prefetch() -- Initiate asynchronous read of the specified blocks.
 *
 * A no-op that reports success, which is the honest answer rather than a
 * shortcut.  Prefetching exists to overlap a read with other work; memcow's
 * "read" is a memcpy() out of a mapping that is already established, so there
 * is no latency to hide and nothing to start early.  Issuing madvise() here
 * would add a syscall to a path whose entire purpose is to avoid one, and
 * would still be a hint the kernel is free to ignore.
 *
 * The range guard is md's, kept because callers use the false return to mean
 * "the request was nonsense", not "the data is cold".
 */
bool
memcow_prefetch(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
				int nblocks)
{
	if ((uint64) blocknum + nblocks > (uint64) MaxBlockNumber + 1)
		return false;

	return true;
}

/*
 * memcow_maxcombine() -- Return the number of blocks that can be combined into
 *						  a single IO starting at the given block.
 *
 * Identical to mdmaxcombine(), and identical on purpose rather than by
 * inheritance.  Three reasons:
 *
 * - It makes bufmgr form exactly the same IO shapes under memcow as under md.
 *	 The first gate this work has to pass is a zero-diff comparison against
 *	 stock output, and an smgr that answers this question differently makes
 *	 different read requests, which is one more variable in every diff.
 * - It guarantees that no smgr_readv/smgr_startreadv request memcow receives
 *	 from bufmgr ever spans two seed segments, so the copy below is always out
 *	 of a single mapping.  memcow could in principle stitch mappings together
 *	 and offer an unbounded combine limit, but that would be memcow being
 *	 cleverer than md for no measurable gain: the cost this limit exists to
 *	 amortize is a syscall, and memcow does not make one.
 * - It is pure arithmetic and touches no seed state, so it cannot fail and
 *	 cannot do I/O.  bufmgr calls it inside its buffer-lookup loop.
 */
uint32
memcow_maxcombine(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum)
{
	BlockNumber segoff = blocknum % ((BlockNumber) RELSEG_SIZE);

	return RELSEG_SIZE - segoff;
}

/*
 * memcow_readv() -- Read the specified blocks synchronously.
 *
 * The synchronous path: RelationCopyStorage() (storage.c) and pg_prewarm are
 * the two real callers.  Unlike smgr_startreadv there is no AIO handle to keep
 * consistent, so this can behave exactly as mdreadv() does, including
 * mdreadv()'s zero_damaged_pages special case -- reproduced here rather than
 * simplified away, because behavioural parity with md is what the differential
 * gate measures.  (md's own Assert(false) in that branch is reproduced too:
 * upstream believes the path is unreachable and wants to hear about it if it
 * is not.  What makes it unreachable for memcow is the MemcowRelEntry
 * invariant, NOT anything about the overlay not existing yet: every block in
 * [0, nblocks) is servable, from the overlay or from the seed, so a block
 * memcow cannot serve is one at or past the end of the fork, which is a read
 * past EOF and not something bufmgr issues.  The invariant is why
 * memcow_do_extend() and memcow_writev() both zero-fill the gap below the
 * block they were handed.)
 */
void
memcow_readv(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
			 void **buffers, BlockNumber nblocks)
{
	MemcowFork	f;
	MemcowBlockKey key;

	memcow_lookup_fork(reln, forknum, false, &f);
	memcow_block_key(&key, &f.relkey, blocknum);

	for (BlockNumber i = 0; i < nblocks; i++)
	{
		if (!memcow_copy_block(&f, &key, blocknum + i, buffers[i]))
		{
			RelPathStr	rel;

			if (zero_damaged_pages || InRecovery)
			{
				Assert(false);	/* see mdreadv() */
				memset(buffers[i], 0, BLCKSZ);
				continue;
			}

			rel = relpath(reln->smgr_rlocator, forknum);

			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("memcow could not read block %u of relation %s: block is outside the seed and the overlay",
							blocknum + i, rel.str),
					 errdetail("The fork has %u block(s), of which the first %u may come from the seed.",
							   f.nblocks, f.seed_visible)));
		}
	}
}

/*
 * memcow_startreadv() -- Asynchronous version of memcow_readv().
 *
 * memcow has no asynchrony to offer: the data is already in this process's
 * address space, so the read is done before the "IO" is started.  What this
 * function has to get right is not the read but the AIO handle, which bufmgr
 * has already set up with its completion callbacks and which something is
 * going to wait on.  pgaio_io_complete_synthetic() walks it through the legal
 * state sequence with the data treated as already transferred.
 *
 * THE LOOP IS TWO-PHASE, AND THAT IS A HARD REQUIREMENT, not a style choice.
 * memcow registers no completion callback of its own, so the block count
 * passed to pgaio_io_complete_synthetic() reaches bufmgr's buffer_readv
 * callback raw, and bufmgr reads a short count as "the tail buffers failed" --
 * it skips PageIsVerified() for them, terminates them not-valid, and the
 * caller re-issues the identical read, which returns the identical short
 * count, forever.  A short result is therefore not a weaker error report than
 * an ERROR; it is not an error report at all.  There is likewise no way to
 * signal failure through the result, since PGAIO_RS_ERROR can only originate
 * inside a complete_shared callback.
 *
 * So: phase 1 serves every block in the request and raises on the first one
 * that cannot be served, before the handle has been touched at all; phase 2
 * completes the handle, and nothing in it can fail.  The count handed to the
 * helper is always the full nblocks.
 *
 * (Raising in phase 1 is safe for the handle: it is still PGAIO_HS_HANDED_OUT,
 * so the resource owner releases it during unwind.  Raising after the helper
 * would not be -- but nothing after the helper can raise.)
 *
 * PHASE 1 NOW COPIES AS IT RESOLVES, which is a deliberate weakening of an
 * earlier form of this comment ("before a single buffer has been written").
 * It has to: memcow_copy_block() cannot hand back an overlay page address that
 * outlives its partition lock without reintroducing a use-after-free against
 * concurrent DROP, which holds no relation lock at all -- see the argument
 * there.  So a request whose block k cannot be served leaves buffers 0..k-1
 * already filled.  That is harmless and is not new behaviour to bufmgr: an
 * ERROR out of smgrstartreadv() unwinds with the buffers still
 * BM_IO_IN_PROGRESS, the resource owner's AbortBufferIO() terminates them
 * NOT valid, and their contents are never read.  md leaves partially filled
 * buffers behind on exactly the same paths (a short mdreadv() writes what it
 * got and then raises).  What phase 1 must NOT do, and does not, is touch the
 * AIO handle before every fallible step is behind it.
 */
void
memcow_startreadv(PgAioHandle *ioh,
				  SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
				  void **buffers, BlockNumber nblocks)
{
	MemcowFork	f;
	MemcowBlockKey key;

	Assert(nblocks > 0);

	/*
	 * mdstartreadv() refuses a request that spans segments, and so does this,
	 * for the same reason: memcow_maxcombine() promised the caller it would
	 * not ask for one.  A request that arrives anyway means the promise was
	 * not kept, which is a bug rather than an I/O condition.
	 */
	if (nblocks > memcow_maxcombine(reln, forknum, blocknum))
		elog(ERROR, "read crossing segment boundary");

	/*
	 * bufmgr caps a combined read at io_combine_limit <= MAX_IO_COMBINE_LIMIT
	 * == PG_IOV_MAX, which is what mdstartreadv() relies on when it sizes its
	 * iovec array.  memcow no longer has a stack array for the bound to guard,
	 * but keeping the check keeps memcow's contract with bufmgr identical to
	 * md's, and a request that violates it is a bufmgr bug worth hearing about
	 * rather than something to serve quietly.
	 */
	if (nblocks > PG_IOV_MAX)
		elog(ERROR, "memcow read of %u blocks exceeds the %d block limit",
			 nblocks, PG_IOV_MAX);

	memcow_lookup_fork(reln, forknum, false, &f);
	memcow_block_key(&key, &f.relkey, blocknum);

	/*
	 * Phase 1: serve every block.  Raises here or not at all.
	 *
	 * Both fallible steps live HERE: the overlay lookup, which can wait on a
	 * partition lock and can fail to find what it is looking for, and the copy
	 * itself, which must happen while that lock is still held.  Nothing below
	 * this loop can fail.
	 *
	 * No HOLD_INTERRUPTS() of our own: smgrstartreadv() already wraps this
	 * callback in one, so no CHECK_FOR_INTERRUPTS() can run between here and
	 * the return -- which matters, because absorbing a SMGRRELEASE barrier
	 * mid-copy would run smgr_close() over the memory being copied out of.
	 * Nor a critical section: pgaio_io_complete_synthetic() opens its own,
	 * narrowly, around the one call that needs it, so that the ereport(ERROR)
	 * below stays an ordinary error instead of becoming a PANIC.
	 */
	for (BlockNumber i = 0; i < nblocks; i++)
	{
		if (!memcow_copy_block(&f, &key, blocknum + i, buffers[i]))
		{
			RelPathStr	rel = relpath(reln->smgr_rlocator, forknum);

			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("memcow could not read block %u of relation %s: block is outside the seed and the overlay",
							blocknum + i, rel.str),
					 errdetail("The fork has %u block(s), of which the first %u may come from the seed.",
							   f.nblocks, f.seed_visible)));
		}
	}

	/*
	 * Phase 2: complete the handle.  Nothing below here may fail.
	 *
	 * The target is memcow's to set (bufmgr sets the handle data and the
	 * callbacks, md sets the target).  No callback is registered on purpose:
	 * PGAIO_HCB_{SHARED,LOCAL}_BUFFER_READV is already on the handle and, with
	 * nothing of ours in between, receives this block count directly -- which
	 * is exactly what md_readv_complete() would have distilled for md, and is
	 * why the count is in blocks rather than bytes.
	 */
	pgaio_io_set_target_smgr(ioh, reln, forknum, blocknum, nblocks, false);

	pgaio_io_complete_synthetic(ioh, nblocks);
}

/*
 * memcow_writev() -- Write the supplied blocks at the appropriate location.
 *
 * This is the callback the whole commit exists for.  Every dirty shared or
 * local buffer that is evicted or checkpointed arrives here, including the
 * hint-bit-dirtied pages of otherwise read-only seed relations -- which is
 * why a clean shutdown was impossible before this function did something.
 *
 * The pages are stored EXACTLY as handed over.  bufmgr and localbuf compute
 * the checksum into the very buffer passed here, so what lands in the overlay
 * is a complete, self-verifying page image and PageIsVerified() passes on
 * re-read without memcow being involved in verification at all.  Anything
 * "helpful" done to the bytes here -- re-checksumming, zeroing a field,
 * normalizing -- would break that, so nothing is.
 *
 * A write past the current end of the fork extends it.  mdwritev() would
 * refuse (its _mdfd_getseg() uses EXTENSION_FAIL outside recovery) and no
 * in-tree caller does it: FlushBuffer() and FlushLocalBuffer() can only write
 * a block that was previously extended, and bulk_write.c routes anything at or
 * past the relation size to smgrextend().  But a write that grows the fork
 * goes through memcow_store_range() exactly as extend does, gap fill included,
 * and NOT through a shortcut that stores only [blocknum, end).
 *
 * An earlier version of this function took that shortcut, on the grounds that
 * growing is "impossible to get wrong here".  That is backwards.  A write at a
 * blocknum above the current end would have left [nblocks, blocknum) with no
 * block entry while sitting inside the fork -- a block memcow cannot serve and
 * has no legal way to report, which is an infinite bufmgr retry rather than an
 * error.  The invariant is the thing the whole design leans on; a path that
 * maintains it only because no caller currently exercises the path is not
 * maintaining it.
 */
void
memcow_writev(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
			  const void **buffers, BlockNumber nblocks, bool skipFsync)
{
	MemcowDbLocal *db;
	MemcowRelEntry *re;
	MemcowRelKey relkey;
	BlockNumber cur;
	BlockNumber high;
	BlockNumber end = blocknum + nblocks;
	bool		created;

	Assert(nblocks > 0);

	re = memcow_relentry_lock(reln, forknum, &db, &created);
	if (!re->exists)
	{
		dshash_release_lock(db->rels, re);
		memcow_fork_missing(&reln->smgr_rlocator, forknum);
	}
	cur = re->nblocks;
	high = re->blocks_high;
	dshash_release_lock(db->rels, re);

	/*
	 * cur < blocknum is the gap-fill case, i.e. a write past EOF.  Nothing in
	 * this tree reaches it (see the header comment), so leave a tripwire
	 * rather than a silent success: if it ever does start happening, the
	 * assumption that write and extend are interchangeable deserves a look
	 * before the fill quietly papers over it.  On a non-assert build the fill
	 * runs and the invariant holds either way, which is the point.
	 */
	Assert(cur >= blocknum);

	memcow_rel_key(&relkey, &reln->smgr_rlocator, forknum);
	memcow_store_range(db, &relkey, cur, high, blocknum, end,
					   (const void *const *) buffers);
}

/*
 * memcow_writeback() -- Tell the kernel to write pages back to storage.
 *
 * Permanent no-op.  mdwriteback() exists to give the kernel a hint about
 * pages that are already in its page cache and will have to reach a disk
 * eventually; the overlay has no disk behind it and the seed is never
 * written, so there is nothing to write back and nothing to hint about.
 * Raising here would break the checkpointer, which calls this unconditionally
 * for every batch it flushes.
 */
void
memcow_writeback(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
				 BlockNumber nblocks)
{
}

/*
 * memcow_nblocks() -- Get the number of blocks stored in a relation.
 *
 * Errors on a fork that is not in the seed, matching mdnblocks(), which
 * reaches mdopenfork() with EXTENSION_FAIL.  Callers that are not sure the
 * fork exists are already written to ask smgrexists() first.
 *
 * The two halves of the answer have opposite caching rules, which is the
 * whole subtlety here.  The SEED half is immutable -- the seed is a frozen
 * tree behind two PGC_POSTMASTER GUCs -- so it is computed once, when the
 * fork is first resolved, and never recomputed.  The OVERLAY half is shared,
 * mutable state that another backend can grow between two calls, so it is
 * read from shared memory on every call and is never cached anywhere.  Once a
 * fork has an overlay record the record's nblocks IS the answer; the seed
 * contributed its size to that record when the record was created.
 *
 * This is still cheaper than mdnblocks(), which lseeks.
 *
 * IT ALSO WARMS THE OVERLAY RECORD, and that is not an optimization -- it is
 * what makes memcow_truncate() safe.  smgrtruncate()'s contract (smgr.c) is
 * that "the current size must be checked outside the critical section, and no
 * interrupts or smgr functions relating to this relation should be called in
 * between", so this function is guaranteed to have run on the fork about to be
 * truncated, outside the critical section that smgr_truncate runs inside.
 * Creating the record here means memcow_truncate() only ever has to FIND one,
 * which allocates nothing; creating one from in there allocates, and
 * deterministically trips AssertNotInCriticalSection through
 * dshash_find_or_insert -> dsa_allocate -> dsa_get_address -> dsm_attach.
 * This is the same shape as md: mdnblocks() opens the segments that make
 * mdtruncate()'s _mdfd_getseg() a pure lookup.
 *
 * It costs one dshash insert per fork per CLUSTER lifetime -- the record is
 * shared, so only the first process to size a fork pays -- and it does not
 * move a pure-seed relation off the read fast path, because that path keys on
 * blocks_high rather than on the record existing (see memcow_lookup_fork).
 *
 * THE WARM-UP CREATES THE DATABASE'S OVERLAY IF IT HAS NONE, which is a
 * deliberate softening of memcow_overlay()'s "a read must never cause a DSM
 * segment to be created".  It has to be: a truncate can be the first write of
 * any kind in a database -- DELETE from a seed relation and VACUUM it, and
 * nothing has extended anything -- and then memcow_truncate() would reach
 * dsa_create() inside the critical section.  Measured; it is not theoretical.
 * The cost is one arena per database that is merely read rather than written,
 * which is bounded, is discarded by reset like any other, and only counts
 * against MEMCOW_MAX_OVERLAY_DBS.  The alternative was a reachable crash.
 *
 * Guarded on CritSectionCount so the warm-up can never itself become the
 * problem it exists to solve: nothing in this tree calls smgr_nblocks from
 * inside a critical section (DropRelationBuffers, which smgrtruncate() calls
 * from inside one, uses smgrnblocks_cached and never reaches this callback),
 * but a future caller that did would get the un-warmed answer rather than an
 * assert failure.
 */
BlockNumber
memcow_nblocks(SMgrRelation reln, ForkNumber forknum)
{
	MemcowFork	f;

	memcow_lookup_fork(reln, forknum, false, &f);

	if (!f.have_overlay && f.exists && CritSectionCount == 0)
	{
		MemcowDbLocal *db;
		MemcowRelEntry *re;
		bool		created;

		re = memcow_relentry_lock(reln, forknum, &db, &created);
		dshash_release_lock(db->rels, re);
	}

	return f.nblocks;
}

/*
 * memcow_truncate() -- Truncate relation to specified number of blocks.
 *
 * A PURE WHITEOUT, never a file truncation and -- deliberately -- never a
 * reclaim: the seed is PROT_READ and immutable, so the discarded tail is
 * expressed by lowering how much of the seed remains visible.  Lowering
 * seed_visible is not the same as lowering nblocks and both are needed -- see
 * the invariant on MemcowRelEntry: truncating a seed relation to N and then
 * extending it back past N must serve the re-extended blocks from the
 * overlay, not from the seed's stale copy of them.
 *
 * THIS RUNS INSIDE THE CALLER'S CRITICAL SECTION, which is the constraint
 * that shapes everything below.  RelationTruncate() (storage.c) does
 * START_CRIT_SECTION(), WAL-logs the truncation, calls smgrtruncate() and only
 * then END_CRIT_SECTION(); the redo path repeats the shape.  So this callback
 * MUST NOT ALLOCATE: MemoryContextAlloc and friends assert CritSectionCount ==
 * 0 (mcxt.c), and on an assert-less build the ereport out of a failed
 * allocation is a PANIC rather than an error.
 *
 * That rules out freeing the pages this drops, which is what an earlier
 * version did and which crashed.  dsa_free() and dshash_delete_entry() both
 * reach dsa_get_address(), which maps a segment this backend has not seen yet
 * by calling dsm_attach() -> MemoryContextAllocZero().  It needs two backends
 * to show up (the segment has to be unmapped *here*), which is exactly why it
 * presented as an intermittent crash:
 *
 *	   TRAP: failed Assert("CritSectionCount == 0 || allowInCritSection")
 *		 MemoryContextAllocZero <- dsm_attach <- dsa_get_address <- dsa_free
 *		 <- dshash_delete_entry <- memcow_truncate <- smgrtruncate
 *
 * Not freeing costs nothing but memory, and bounded memory at that.  Entries
 * above nblocks are invisible to every reader (memcow_lookup_fork() hands out
 * nblocks and nothing asks past it), and if the fork grows back into that
 * range memcow_store_range() overwrites the pages in place instead of
 * allocating new ones -- so a truncate/refill cycle reuses the same memory
 * rather than accumulating.  What is retained is bounded by the fork's peak
 * size, which is the same bound the design already accepts for written pages.
 * re->blocks_high carries the range forward so memcow_unlink() still reclaims
 * it, and it does so from a path that is NOT in a critical section.
 *
 * WHAT REMAINS IS SAFE BECAUSE THE CALLER WARMED IT, and that is core's own
 * documented contract rather than an assumption.  smgrtruncate()'s header
 * (smgr.c) requires that "the current size must be checked outside the
 * critical section, and no interrupts or smgr functions relating to this
 * relation should be called in between" -- i.e. smgr_nblocks has just run on
 * this exact fork, outside the critical section.  It is the same warming that
 * makes mdtruncate() safe (its _mdfd_getseg() finds the segments already
 * open).  For memcow that smgr_nblocks call ran memcow_lookup_fork(), which
 * attached this backend to the overlay and did this very dshash_find() on
 * db->rels.  So both lookups below are pure traversals of already-mapped
 * memory: memcow_overlay(create = false) returns on its first line from
 * MemcowDbHash, and dshash_find() walks buckets it has already touched.
 *
 * The record itself is warmed the same way -- memcow_nblocks() creates it if
 * it is missing, precisely so that this function only ever has to FIND one.
 * See the argument there.  Finding allocates nothing; creating allocates and
 * trips the assert deterministically:
 *
 *	   dshash_find_or_insert -> dsa_allocate -> alloc_object
 *		 -> dsa_get_address -> dsm_attach -> MemoryContextAllocZero
 *
 * The fallback below is therefore belt-and-braces rather than a live path, and
 * it MUST create the record rather than give up, because a fork with no record
 * reports the SEED's size -- so losing the truncation does not merely lose a
 * size, it RESURRECTS DATA.  Measured, not reasoned about: an earlier draft of
 * this fix returned instead, and DELETE 3500 rows from a 4000-row seed
 * relation followed by VACUUM brought 3460 of them back, because
 * smgrtruncate() drops the dirty buffers above the new size without writing
 * them and the reads then fall through to the seed's untouched copy.  Given
 * the choice between a crash and silent resurrection, take the crash.
 */
void
memcow_truncate(SMgrRelation reln, ForkNumber forknum,
				BlockNumber curnblk, BlockNumber nblocks)
{
	MemcowDbLocal *db;
	MemcowRelEntry *re;
	MemcowRelKey relkey;
	bool		created;

	/* mdtruncate()'s guards, verbatim in effect */
	if (nblocks > curnblk)
	{
		if (InRecovery)
			return;
		ereport(ERROR,
				(errmsg("could not truncate file \"%s\" to %u blocks: it's only %u blocks now",
						relpath(reln->smgr_rlocator, forknum).str,
						nblocks, curnblk)));
	}
	if (nblocks == curnblk)
		return;					/* no work */

	db = memcow_overlay(reln->smgr_rlocator.locator.dbOid, false);
	if (db != NULL)
	{
		memcow_rel_key(&relkey, &reln->smgr_rlocator, forknum);
		re = (MemcowRelEntry *) dshash_find(db->rels, &relkey, true);
	}
	else
		re = NULL;

	/* the allocating fallback; belt-and-braces, see the header comment */
	if (re == NULL)
		re = memcow_relentry_lock(reln, forknum, &db, &created);

	if (!re->exists)
	{
		dshash_release_lock(db->rels, re);
		memcow_fork_missing(&reln->smgr_rlocator, forknum);
	}

	re->nblocks = nblocks;
	if (re->seed_visible > nblocks)
		re->seed_visible = nblocks;
	/* blocks_high is deliberately NOT lowered: the pages are still there */
	dshash_release_lock(db->rels, re);
}

/*
 * memcow_immedsync() -- Immediately sync a relation to stable storage.
 *
 * Permanent no-op, not a stub: memcow has no stable storage.  The overlay
 * lives in memory and the seed is read-only, so there is nothing an fsync
 * could make more durable.
 */
void
memcow_immedsync(SMgrRelation reln, ForkNumber forknum)
{
}

/*
 * memcow_registersync() -- Request a sync of the relation at the next
 *							checkpoint.
 *
 * Permanent no-op, for the same reason as memcow_immedsync().  Because memcow
 * never enqueues a sync (or unlink) request, sync.c and its request queue are
 * simply never involved in test mode, and need no memcow-specific handling.
 */
void
memcow_registersync(SMgrRelation reln, ForkNumber forknum)
{
}

/*
 * memcow_fd() -- Return an fd for the specified block, for AIO re-open.
 *
 * Assert-unreachable, by construction rather than by omission.  smgrfd() is
 * called only from smgr_aio_reopen(), which runs when an AIO handle has to be
 * executed in a process other than the one that issued it.  memcow serves
 * reads out of memory and drives the handle to completion itself, so a memcow
 * handle is never handed to the IO method layer and never reaches a re-open.
 * Reaching here means the read path escaped memcow's control, which is not
 * something to paper over with an fd into the running PGDATA.
 */
int
memcow_fd(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
		  uint32 *off)
{
	Assert(false);
	elog(ERROR, "memcow: smgr_fd reached; a memcow IO escaped to the IO method layer");
	return -1;					/* keep compiler quiet */
}
