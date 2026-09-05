/*-------------------------------------------------------------------------
 *
 * memcow.h
 *	  ephemeral (seed + copy-on-write overlay) storage manager declarations.
 *
 * memcow is a test-mode storage manager.  When memcow.enabled is on, it is
 * selected globally by smgropen() for every relation, and serves relation
 * pages from a read-only PGDATA seed plus an in-memory overlay instead of
 * from the running PGDATA via md.c.  See contrib/memcow/memcow.c.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * contrib/memcow/memcow.h
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
extern bool memcow_enabled;
extern char *memcow_seed_directory;
extern int memcow_lane_nonce;
extern int memcow_lane_arena_limit;

/*
 * The SQLSTATE raised when a lane's overlay arena reaches
 * memcow.lane_arena_limit: class 53 (insufficient resources), with an
 * implementation-defined subclass so that a caller can tell it from every
 * other out-of-memory condition without parsing the message.
 */
#define ERRCODE_MEMCOW_ARENA_FULL	MAKE_SQLSTATE('5','3','M','C','1')

/* memcow storage manager functionality */
extern void memcow_init(void);
extern void memcow_shmem_setup(void);
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

/* optional smgr release-all callback, including the SMGRRELEASE barrier */
extern void memcow_release_stale_epochs(void);

/* called by the seed-backed login event trigger, before command dispatch */
extern void memcow_check_admission(void);

/*
 * Lanes and reset (plan §4).  The SQL surface is contrib/memcow.
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
	int64		arena_limit;	/* dsa_set_size_limit in force, 0 = none */
	uint32		attached;		/* attachments to the published epoch */
	uint32		attached_old;	/* attachments to the previous epoch */
	bool		reclaim_pending;
	uint64		writes_discarded;	/* writes dropped in discard windows, all time */
	uint32		poisoned_pages; /* old-arena pages poisoned by the last reclaim */
} MemcowLaneStatus;

/*
 * What the authentication-time fence (contrib/memcow, plan §5 I2 fence
 * 2 of 3) is told about a connection that names a database.
 */
typedef enum MemcowAuthVerdict
{
	MEMCOW_AUTH_NOT_A_LANE,		/* no slot was ever opened under that name */
	MEMCOW_AUTH_ADMIT,			/* unarmed lane, or armed and the nonce matches */
	MEMCOW_AUTH_REFUSE_NOT_OPEN,	/* armed lane that is RESETTING or RETIRED */
	MEMCOW_AUTH_REFUSE_NONCE	/* armed lane, nonce absent or stale */
} MemcowAuthVerdict;

/*
 * Where the last memcow_lane_reset() of a lane spent its time (plan §7.4 cost
 * attribution).  Microseconds, measured with instr_time around each step;
 * total_us is CLOSE to return.  Polls are iterations of the bounded waits
 * (each one a 10 ms sleep), stragglers the PIDs the fence terminated.  Written
 * under the lane lock when a reset returns; a reset that raises leaves the
 * previous record in place, so epoch says which reset the record is of.
 */
typedef struct MemcowLaneResetTimings
{
	uint32		epoch;			/* the epoch that reset published */
	int64		total_us;
	int64		fence_us;		/* step 3: idle check + straggler kills */
	int64		prepare_us;		/* step 4: dsa_create + dshash tables */
	int64		publish_us;		/* step 5: the locked store */
	int64		barrier_us;		/* step 6: emit -> every process absorbed */
	int64		sweep_buffers_us;	/* step 7a: DropDatabaseBuffers */
	int64		sweep_files_us; /* step 7b: pg_internal.init + pg_filenode.map */
	int64		reclaim_wait_us;	/* step 8a: attach count -> 0 */
	int64		poison_us;		/* step 8b: old-arena poison walk (cassert) */
	int64		destroy_us;		/* step 8c: unpin + detach + verify gone */
	int32		fence_polls;
	int32		reclaim_polls;
	int32		stragglers;
	uint32		poisoned_pages;
} MemcowLaneResetTimings;

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
extern uint32 memcow_lane_open(Oid dbOid, bool arm, const char *datname);
extern void memcow_lane_retire(Oid dbOid);
extern void memcow_lane_register(Oid dbOid, int pid, bool add);
extern void memcow_lane_status(Oid dbOid, MemcowLaneStatus *st);
extern bool memcow_lane_reset_timings(Oid dbOid, MemcowLaneResetTimings *t);
extern MemcowAuthVerdict memcow_lane_auth_check(const char *datname,
												uint32 presented,
												Oid *dbOid, uint32 *nonce,
												MemcowLaneState *state);
extern uint32 memcow_backend_adopt(void);
extern void memcow_get_backend_counters(MemcowBackendCounters *out);
extern const char *memcow_lane_state_name(MemcowLaneState state);

#endif							/* MEMCOW_H */
