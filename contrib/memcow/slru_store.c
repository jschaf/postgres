/*-------------------------------------------------------------------------
 *
 * slru_store.c
 *	  SLRU page storage for a volatile data directory.
 *
 * Under volatile_data_directory the SLRUs (pg_xact, pg_subtrans,
 * pg_multixact, pg_notify, pg_serial, pg_commit_ts) never write their segment
 * files.  A page evicted from an SLRU buffer, or written for any other
 * reason, is copied here instead; a read looks here first and falls back to
 * the data directory's own (read-only) segment file.  Deleting a segment
 * forgets its pages here.  See SlruStorage in access/slru.h.
 *
 * WHY FIXED SHARED MEMORY, NOT DSA.  The callbacks run with SLRU buffer locks
 * held and, on some paths, inside a critical section: RecordTransactionCommit
 * sets commit status inside one, and reading a CLOG page there can evict a
 * dirty victim.  An allocation, or an ereport(ERROR), inside a critical
 * section is a PANIC, and the first touch of a DSA segment another process
 * created attaches it with a palloc (the same trap memcow_truncate() documents
 * for the relation overlay).  So the store is one region of the main shared
 * memory segment, sized at postmaster start by memcow.slru_pages, and every
 * callback is a hash probe and a memcpy under one LWLock.  The region is
 * anonymous shared memory: pages the run never writes are never touched and
 * cost nothing but address space.
 *
 * A full store fails the write with ENOSPC, after a WARNING naming the
 * setting; the SLRU reports that against the segment file.  Nothing is ever
 * evicted from the store: an SLRU page must never be re-read stale.
 *
 * LAYOUT.  An open-addressing table of 2 * memcow.slru_pages entries, linear
 * probing with backward-shift deletion (so there are no tombstones to clean
 * up), each entry naming one slot of a page pool; a stack of free pool slots;
 * and the pool itself.  An SLRU is identified by its SlruShared pointer, which
 * lives in the main shared memory segment and is the same in every process.
 *
 * The postmaster lists and forgets pg_notify's segments while it initializes
 * shared memory, which can be before this module's region exists (store is
 * NULL); nothing is stored yet, so those calls find nothing.
 *
 * Portions Copyright (c) 2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  contrib/memcow/slru_store.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/slru.h"
#include "common/hashfn.h"
#include "common/int.h"
#include "lib/qunique.h"
#include "miscadmin.h"
#include "port/pg_bitutils.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "memcow.h"

/* GUC: pages the store can hold */
int			memcow_slru_pages = 4096;

typedef struct SlruStoreEntry
{
	SlruShared	slru;			/* NULL: the entry is empty */
	int64		pageno;
	int			page;			/* index into the page pool */
} SlruStoreEntry;

typedef struct SlruStoreState
{
	LWLock		lock;
	uint32		mask;			/* table size - 1; the size is a power of 2 */
	int			npages;			/* page pool size */
	int			nfree;			/* free pool slots on the stack */
} SlruStoreState;

static SlruStoreState *store;
static SlruStoreEntry *entries;
static int *free_pages;
static char *pages;

static uint32
table_size(void)
{
	return pg_nextpower2_32((uint32) memcow_slru_pages * 2);
}

Size
memcow_slru_shmem_size(void)
{
	Size		size;

	size = MAXALIGN(sizeof(SlruStoreState));
	size = add_size(size, MAXALIGN(mul_size(table_size(), sizeof(SlruStoreEntry))));
	size = add_size(size, MAXALIGN(mul_size(memcow_slru_pages, sizeof(int))));
	size = add_size(size, PG_IO_ALIGN_SIZE);
	size = add_size(size, mul_size(memcow_slru_pages, BLCKSZ));
	return size;
}

/* Called with AddinShmemInitLock held. */
void
memcow_slru_shmem_init(void)
{
	bool		found;
	char	   *p;

	store = ShmemInitStruct("memcow SLRU store", memcow_slru_shmem_size(),
							&found);
	p = (char *) store + MAXALIGN(sizeof(SlruStoreState));
	entries = (SlruStoreEntry *) p;
	p += MAXALIGN(table_size() * sizeof(SlruStoreEntry));
	free_pages = (int *) p;
	p += MAXALIGN(memcow_slru_pages * sizeof(int));
	pages = (char *) TYPEALIGN(PG_IO_ALIGN_SIZE, p);

	if (!found)
	{
		LWLockInitialize(&store->lock, LWLockNewTrancheId("MemcowSlruStore"));
		store->mask = table_size() - 1;
		store->npages = memcow_slru_pages;
		store->nfree = memcow_slru_pages;
		/* Only the index is initialized; the pool stays untouched. */
		memset(entries, 0, table_size() * sizeof(SlruStoreEntry));
		for (int i = 0; i < memcow_slru_pages; i++)
			free_pages[i] = memcow_slru_pages - 1 - i;
	}
}

static inline uint32
home_of(SlruShared slru, int64 pageno)
{
	return (uint32) (murmurhash64((uint64) pageno) ^
					 murmurhash64((uint64) (uintptr_t) slru)) & store->mask;
}

/* The entry holding the page, or -1.  Caller holds the lock. */
static int
find(SlruShared slru, int64 pageno)
{
	for (uint32 i = home_of(slru, pageno);; i = (i + 1) & store->mask)
	{
		if (entries[i].slru == NULL)
			return -1;
		if (entries[i].slru == slru && entries[i].pageno == pageno)
			return (int) i;
	}
}

/* Empty entry i, returning its page to the pool.  Caller holds the lock. */
static void
remove_entry(uint32 i)
{
	uint32		j = i;

	free_pages[store->nfree++] = entries[i].page;
	for (;;)
	{
		uint32		k;

		j = (j + 1) & store->mask;
		if (entries[j].slru == NULL)
			break;
		k = home_of(entries[j].slru, entries[j].pageno);
		/* Entry j stays if its home lies cyclically in (i, j]. */
		if (i <= j ? (i < k && k <= j) : (i < k || k <= j))
			continue;
		entries[i] = entries[j];
		i = j;
	}
	entries[i].slru = NULL;
}

static bool
store_read_page(SlruDesc *ctl, int64 pageno, char *buffer)
{
	int			i;

	if (store == NULL)
		return false;
	LWLockAcquire(&store->lock, LW_SHARED);
	i = find(ctl->shared, pageno);
	if (i >= 0)
		memcpy(buffer, pages + (Size) entries[i].page * BLCKSZ, BLCKSZ);
	LWLockRelease(&store->lock);
	return i >= 0;
}

static bool
store_write_page(SlruDesc *ctl, int64 pageno, const char *buffer)
{
	int			i;
	int			page;

	if (store == NULL)
	{
		errno = EIO;
		return false;
	}
	LWLockAcquire(&store->lock, LW_EXCLUSIVE);
	i = find(ctl->shared, pageno);
	if (i >= 0)
		page = entries[i].page;
	else if (store->nfree == 0)
	{
		LWLockRelease(&store->lock);
		ereport(WARNING,
				(errmsg("memcow SLRU store is full (%d pages)", store->npages),
				 errhint("Raise \"memcow.slru_pages\".")));
		errno = ENOSPC;
		return false;
	}
	else
	{
		uint32		e;

		page = free_pages[--store->nfree];
		for (e = home_of(ctl->shared, pageno); entries[e].slru != NULL;
			 e = (e + 1) & store->mask)
			;
		entries[e].slru = ctl->shared;
		entries[e].pageno = pageno;
		entries[e].page = page;
	}
	memcpy(pages + (Size) page * BLCKSZ, buffer, BLCKSZ);
	LWLockRelease(&store->lock);
	return true;
}

static bool
store_page_exists(SlruDesc *ctl, int64 pageno)
{
	bool		exists;

	if (store == NULL)
		return false;
	LWLockAcquire(&store->lock, LW_SHARED);
	exists = find(ctl->shared, pageno) >= 0;
	LWLockRelease(&store->lock);
	return exists;
}

static int
cmp_int64(const void *a, const void *b)
{
	return pg_cmp_s64(*(const int64 *) a, *(const int64 *) b);
}

static int64 *
store_list_segments(SlruDesc *ctl, int *nsegs)
{
	int64	   *segnos;
	int			n = 0;

	if (store == NULL)
	{
		*nsegs = 0;
		return palloc_array(int64, 1);
	}
	LWLockAcquire(&store->lock, LW_SHARED);
	/* At most one segment per stored page; plus one so it is never empty. */
	segnos = palloc_array(int64, store->npages - store->nfree + 1);
	for (uint32 i = 0; i <= store->mask; i++)
		if (entries[i].slru == ctl->shared)
			segnos[n++] = entries[i].pageno / SLRU_PAGES_PER_SEGMENT;
	LWLockRelease(&store->lock);

	if (n > 1)
	{
		qsort(segnos, n, sizeof(int64), cmp_int64);
		n = qunique(segnos, n, sizeof(int64), cmp_int64);
	}
	*nsegs = n;
	return segnos;
}

static void
store_forget_segment(SlruDesc *ctl, int64 segno)
{
	int64		first = segno * SLRU_PAGES_PER_SEGMENT;

	if (store == NULL)
		return;
	LWLockAcquire(&store->lock, LW_EXCLUSIVE);
	for (int64 pageno = first; pageno < first + SLRU_PAGES_PER_SEGMENT; pageno++)
	{
		int			i = find(ctl->shared, pageno);

		if (i >= 0)
			remove_entry((uint32) i);
	}
	LWLockRelease(&store->lock);
}

static const SlruStorage memcow_slru_storage = {
	.read_page = store_read_page,
	.write_page = store_write_page,
	.page_exists = store_page_exists,
	.list_segments = store_list_segments,
	.forget_segment = store_forget_segment,
};

void
memcow_slru_register(void)
{
	RegisterSlruStorage(&memcow_slru_storage);
}
