/*-------------------------------------------------------------------------
 *
 * memcow.h
 *	  ephemeral (seed + copy-on-write overlay) storage manager declarations.
 *
 * memcow is a test-mode storage manager.  When memcow_enabled is on, it is
 * selected globally by smgropen() for every relation, and serves relation
 * pages from a read-only PGDATA seed plus an in-memory overlay instead of
 * from the running PGDATA via md.c.  See src/backend/storage/smgr/memcow.c.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/storage/memcow.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef MEMCOW_H
#define MEMCOW_H

#include "storage/aio_types.h"
#include "storage/block.h"
#include "storage/relfilelocator.h"
#include "storage/smgr.h"

/* GUC-backed variables */
extern PGDLLIMPORT bool memcow_enabled;
extern PGDLLIMPORT char *memcow_seed_directory;
extern PGDLLIMPORT int memcow_lane_nonce;

/* memcow storage manager functionality */
extern void memcow_init(void);
extern void memcow_open(SMgrRelation reln);
extern void memcow_close(SMgrRelation reln, ForkNumber forknum);
extern void memcow_create(SMgrRelation reln, ForkNumber forknum, bool isRedo);
extern bool memcow_exists(SMgrRelation reln, ForkNumber forknum);
extern void memcow_unlink(RelFileLocatorBackend rlocator, ForkNumber forknum,
						  bool isRedo);
extern void memcow_extend(SMgrRelation reln, ForkNumber forknum,
						  BlockNumber blocknum, const void *buffer,
						  bool skipFsync);
extern void memcow_zeroextend(SMgrRelation reln, ForkNumber forknum,
							  BlockNumber blocknum, int nblocks,
							  bool skipFsync);
extern bool memcow_prefetch(SMgrRelation reln, ForkNumber forknum,
							BlockNumber blocknum, int nblocks);
extern uint32 memcow_maxcombine(SMgrRelation reln, ForkNumber forknum,
								BlockNumber blocknum);
extern void memcow_readv(SMgrRelation reln, ForkNumber forknum,
						 BlockNumber blocknum,
						 void **buffers, BlockNumber nblocks);
extern void memcow_startreadv(PgAioHandle *ioh,
							  SMgrRelation reln, ForkNumber forknum,
							  BlockNumber blocknum,
							  void **buffers, BlockNumber nblocks);
extern void memcow_writev(SMgrRelation reln, ForkNumber forknum,
						  BlockNumber blocknum,
						  const void **buffers, BlockNumber nblocks,
						  bool skipFsync);
extern void memcow_writeback(SMgrRelation reln, ForkNumber forknum,
							 BlockNumber blocknum, BlockNumber nblocks);
extern BlockNumber memcow_nblocks(SMgrRelation reln, ForkNumber forknum);
extern void memcow_truncate(SMgrRelation reln, ForkNumber forknum,
							BlockNumber old_blocks, BlockNumber nblocks);
extern void memcow_immedsync(SMgrRelation reln, ForkNumber forknum);
extern void memcow_registersync(SMgrRelation reln, ForkNumber forknum);
extern int	memcow_fd(SMgrRelation reln, ForkNumber forknum,
					  BlockNumber blocknum, uint32 *off);

/* not an smgr callback: consulted by DropTableSpace() */
extern bool memcow_tablespace_in_use(Oid spcOid);

/* not an smgr callback: called by smgrreleaseall(), the SMGRRELEASE barrier */
extern void memcow_release_stale_epochs(void);

/* not an smgr callback: called by PostgresMain() after InitPostgres() */
extern void memcow_check_admission(void);

/*
 * Lanes and reset (plan §4).  The SQL surface is contrib/memcow_lanes.
 */
typedef enum MemcowLaneState
{
	MEMCOW_LANE_OPEN = 0,		/* zero, so a fresh slot is open */
	MEMCOW_LANE_RESETTING,
	MEMCOW_LANE_RETIRED
} MemcowLaneState;

typedef struct MemcowLaneStatus
{
	bool		is_lane;		/* false: the database has no slot at all */
	MemcowLaneState state;
	uint32		epoch;
	uint32		nonce;			/* 0: not armed */
	int			nregistered;
	int64		arena_bytes;	/* dsa total size of the published epoch */
	uint32		attached;		/* attachments to the published epoch */
	uint32		attached_old;	/* attachments to the previous epoch */
	bool		reclaim_pending;
} MemcowLaneStatus;

typedef struct MemcowBackendCounters
{
	uint64		attaches;
	uint64		detaches;
	uint64		nblocks_pin_refresh;
	uint64		truncate_pinned;
	uint64		truncate_traversed;
	uint64		truncate_allocated;
	uint64		writes_discarded;
} MemcowBackendCounters;

extern uint32 memcow_lane_reset(Oid dbOid, Oid spcOid, int timeout_ms);
extern uint32 memcow_lane_open(Oid dbOid, bool arm);
extern void memcow_lane_register(Oid dbOid, int pid, bool add);
extern void memcow_lane_status(Oid dbOid, MemcowLaneStatus *st);
extern uint32 memcow_backend_adopt(void);
extern void memcow_get_backend_counters(MemcowBackendCounters *out);
extern const char *memcow_lane_state_name(MemcowLaneState state);

#endif							/* MEMCOW_H */
