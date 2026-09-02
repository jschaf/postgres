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

#endif							/* MEMCOW_H */
