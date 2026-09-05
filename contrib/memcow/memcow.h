/*-------------------------------------------------------------------------
 *
 * memcow.h
 *	  ephemeral (seed + copy-on-write overlay) storage manager declarations.
 *
 * memcow is a test-mode storage manager.  When memcow.enabled is on, it is
 * selected globally by smgropen() for every relation, and serves relation
 * pages from a read-only PGDATA seed plus an in-memory overlay instead of
 * from the running PGDATA via md.c.  See contrib/memcow/memcow.c; lanes.c
 * holds the preload hooks and the SQL wrappers that need catalog access.
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

/* not an smgr callback: consulted by the object-access hook for DROP TABLESPACE */
extern bool memcow_tablespace_in_use(Oid spcOid);

/* optional smgr release-all callback, including the SMGRRELEASE barrier */
extern void memcow_release_stale_epochs(void);

/*
 * Lanes and reset (plan §4).  The SQL surface and the hooks are in lanes.c;
 * the status/timings/counters projections live beside the slot in memcow.c.
 */
extern uint32 memcow_lane_reset(Oid dbOid, Oid spcOid, int timeout_ms);
extern uint32 memcow_lane_open(Oid dbOid, bool arm, const char *datname);
extern void memcow_lane_retire(Oid dbOid);
extern void memcow_lane_register(Oid dbOid, int pid, bool add);
extern bool memcow_lane_auth_check(const char *datname, uint32 presented);
extern void memcow_check_admission(void);
extern uint32 memcow_backend_adopt(void);

#endif							/* MEMCOW_H */
