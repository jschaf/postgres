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
 * THIS COMMIT IS A STUB.  The GUCs, the smgrsw row and the smgropen selection
 * are real; the callbacks are not.  Every callback that would touch storage
 * raises an error, so turning memcow_enabled on gets a server through startup
 * GUC validation and then fails loudly at the first relation access rather
 * than silently reading or writing the wrong bytes.  The read path arrives in
 * a later commit.
 *
 * Two callbacks are deliberately not stubs:
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

#include <sys/stat.h>
#include <unistd.h>

#include "miscadmin.h"
#include "storage/memcow.h"

/* GUC variables */
bool		memcow_enabled = false;
char	   *memcow_seed_directory = NULL;

/*
 * Every storage-touching callback in this commit reports this.  ERROR (not
 * FATAL) matches md.c's habit of reporting storage failures as ordinary
 * errors, and matches mdstartreadv(), which raises before it stages anything.
 */
#define MEMCOW_NOT_IMPLEMENTED(cbname) \
	ereport(ERROR, \
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED), \
			 errmsg("memcow: %s not implemented", cbname)))

static void memcow_check_seed_directory(void);


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
	if (!memcow_enabled)
		return;

	memcow_check_seed_directory();
}

/*
 * Validate memcow_seed_directory.
 *
 * This commit does not read the seed, so all that is checked is that a seed
 * location was configured at all and that this process can traverse and read
 * it.  Later commits add the fingerprint check (pg_control, PG_VERSION and
 * the build hash) here.
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
 * memcow_open() -- Initialize newly-opened relation.
 */
void
memcow_open(SMgrRelation reln)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_open");
}

/*
 * memcow_close() -- Close the specified relation, if it isn't closed already.
 */
void
memcow_close(SMgrRelation reln, ForkNumber forknum)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_close");
}

/*
 * memcow_create() -- Create a new relation on memcow.
 */
void
memcow_create(SMgrRelation reln, ForkNumber forknum, bool isRedo)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_create");
}

/*
 * memcow_exists() -- Does the physical file exist?
 */
bool
memcow_exists(SMgrRelation reln, ForkNumber forknum)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_exists");
	return false;				/* keep compiler quiet */
}

/*
 * memcow_unlink() -- Unlink a relation.
 */
void
memcow_unlink(RelFileLocatorBackend rlocator, ForkNumber forknum, bool isRedo)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_unlink");
}

/*
 * memcow_extend() -- Add a block to the specified relation.
 */
void
memcow_extend(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
			  const void *buffer, bool skipFsync)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_extend");
}

/*
 * memcow_zeroextend() -- Add new zeroed out blocks to the specified relation.
 */
void
memcow_zeroextend(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
				  int nblocks, bool skipFsync)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_zeroextend");
}

/*
 * memcow_prefetch() -- Initiate asynchronous read of the specified blocks.
 */
bool
memcow_prefetch(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
				int nblocks)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_prefetch");
	return false;				/* keep compiler quiet */
}

/*
 * memcow_maxcombine() -- Return the number of bytes that can be combined into
 *						  a single IO starting at the given block.
 */
uint32
memcow_maxcombine(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_maxcombine");
	return 0;					/* keep compiler quiet */
}

/*
 * memcow_readv() -- Read the specified blocks synchronously.
 */
void
memcow_readv(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
			 void **buffers, BlockNumber nblocks)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_readv");
}

/*
 * memcow_startreadv() -- Asynchronous version of memcow_readv().
 */
void
memcow_startreadv(PgAioHandle *ioh,
				  SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
				  void **buffers, BlockNumber nblocks)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_startreadv");
}

/*
 * memcow_writev() -- Write the supplied blocks at the appropriate location.
 */
void
memcow_writev(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
			  const void **buffers, BlockNumber nblocks, bool skipFsync)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_writev");
}

/*
 * memcow_writeback() -- Tell the kernel to write pages back to storage.
 */
void
memcow_writeback(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
				 BlockNumber nblocks)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_writeback");
}

/*
 * memcow_nblocks() -- Get the number of blocks stored in a relation.
 */
BlockNumber
memcow_nblocks(SMgrRelation reln, ForkNumber forknum)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_nblocks");
	return InvalidBlockNumber;	/* keep compiler quiet */
}

/*
 * memcow_truncate() -- Truncate relation to specified number of blocks.
 */
void
memcow_truncate(SMgrRelation reln, ForkNumber forknum,
				BlockNumber old_blocks, BlockNumber nblocks)
{
	MEMCOW_NOT_IMPLEMENTED("smgr_truncate");
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
