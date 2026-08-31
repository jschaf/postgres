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
 * THIS COMMIT IMPLEMENTS THE READ PATH ONLY.  Reads (smgr_nblocks,
 * smgr_exists, smgr_maxcombine, smgr_readv, smgr_startreadv, smgr_prefetch)
 * are served from the seed; every write callback (create, extend, zeroextend,
 * writev, truncate) still raises an error.  A server started with
 * memcow_enabled on is therefore a working READ-ONLY server: it boots, it
 * serves queries against seed relations, and it fails loudly on the first
 * attempt to modify one.  The copy-on-write overlay arrives in a later commit.
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
 * and then kept for the life of the process; memcow_close() deliberately does
 * not tear them down.  Two reasons, both load-bearing.  First, correctness
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
#include "miscadmin.h"
#include "port/pg_iovec.h"
#include "storage/aio.h"
#include "storage/aio_internal.h"
#include "storage/bufmgr.h"
#include "storage/checksum.h"
#include "storage/fd.h"
#include "storage/memcow.h"
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

/*
 * Per-process memcow state, established by memcow_init().  Both are NULL when
 * memcow is off, and memcow_open() asserts they are not NULL when it is: with
 * real state here, an smgropen() that beat smgrinit() would be a null deref
 * rather than the harmless no-op it used to be.
 */
static MemoryContext MemcowCxt = NULL;
static HTAB *MemcowSeedHash = NULL;

static void memcow_check_seed_directory(void);
static void memcow_check_fingerprint(void);
static MemcowForkSeed *memcow_resolve_fork(SMgrRelation reln, ForkNumber forknum,
										   bool missing_ok);
static const char *memcow_seed_block(MemcowForkSeed *fs, BlockNumber blocknum);

/*
 * Every storage-touching callback in this commit reports this.  ERROR (not
 * FATAL) matches md.c's habit of reporting storage failures as ordinary
 * errors, and matches mdstartreadv(), which raises before it stages anything.
 */
#define MEMCOW_NOT_IMPLEMENTED(cbname) \
	ereport(ERROR, \
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED), \
			 errmsg("memcow: %s not implemented", cbname)))

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
 * STILL A NO-OP AFTER THE READ PATH LANDED, and deliberately so.  The obvious
 * reading of "close" is "drop this fork's seed mappings", and this function
 * does not do that.  Seed state is not close-scoped state:
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
 * What memcow_close() WILL have to do is release epoch-scoped overlay state,
 * which is the thing plan §4.6's barrier exists to flush and the thing that
 * genuinely does go stale at a reset.  Entries whose relation is really gone
 * are reclaimed by memcow_unlink() instead, which is where "really gone" is
 * actually known.
 */
void
memcow_close(SMgrRelation reln, ForkNumber forknum)
{
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
 * memcow_unlink() -- Unlink a relation.
 *
 * Still not implemented, but reported at WARNING and returning normally, which
 * the f_smgr contract requires of smgr_unlink specifically: "smgr_unlink should
 * use elog(WARNING), rather than erroring out, because we normally unlink
 * relations during post-commit/abort cleanup, and so it's too late to raise an
 * error" (the comment above the f_smgr struct in smgr.c).  mdunlink() honours
 * this throughout.
 *
 * Concretely: smgrDoPendingDeletes() -> smgrdounlinkall() is called from
 * AbortTransaction() a handful of lines before AtEOXact_SMgr(), so an
 * ereport(ERROR) here re-enters AbortTransaction() and recurses to
 * PANIC: ERRORDATA_STACK_SIZE exceeded -- the same failure mode as an error out
 * of memcow_close(), and just as unrecoverable.  A dropped relation that memcow
 * cannot yet unlink costs nothing: the overlay is discarded at reset and the
 * seed is read-only, so there is no file to leak.
 *
 * There is one thing to do, though, and it is the counterpart of
 * memcow_close() doing nothing: because seed mappings are process-lifetime,
 * unlink is the only point at which memcow ever learns that a relation is
 * genuinely gone and its mappings can never be wanted again.  Dropping the
 * entry here is what keeps the table from growing without bound in a process
 * that creates and drops many relations.  Every step is infallible --
 * hash_search(HASH_FIND / HASH_REMOVE) only ever traverses and unlinks, never
 * allocates; munmap() of a base/length pair this process got from mmap() has
 * no failure mode worth a message nobody reads; pfree() cannot fail.  The
 * whole thing is also wait-free, which matters because §4.6's barrier reaches
 * smgr_close() and this function shares its constraints.
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
	MemcowRelSeed *rel;

	Assert(MemcowSeedHash != NULL);

	rel = (MemcowRelSeed *) hash_search(MemcowSeedHash, &rlocator,
										HASH_FIND, NULL);
	if (rel == NULL)
		return;

	for (int f = 0; f <= MAX_FORKNUM; f++)
	{
		MemcowForkSeed *fs = &rel->forks[f];

		/* mdunlink()'s convention: InvalidForkNumber means every fork */
		if (forknum != InvalidForkNumber && forknum != f)
			continue;

		for (int i = 0; i < fs->nsegs; i++)
		{
			if (fs->segs[i].base != NULL)
				(void) munmap(fs->segs[i].base, fs->segs[i].maplen);
		}
		if (fs->segs != NULL)
			pfree(fs->segs);

		memset(fs, 0, sizeof(*fs));

		/*
		 * Leave it resolved-and-absent rather than unresolved.  The relation
		 * is gone; a later smgr_exists() on it must answer false without going
		 * back to the seed, where a same-numbered file could in principle
		 * still be sitting.
		 */
		fs->resolved = true;
	}

	if (forknum == InvalidForkNumber)
		(void) hash_search(MemcowSeedHash, &rlocator, HASH_REMOVE, NULL);
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
 * memcow_exists() -- Does the fork exist in the seed?
 *
 * Unlike mdexists(), this does not close the fork first.  mdexists() has to,
 * because an md fd can outlive the file it names; a memcow seed mapping
 * cannot, because the seed is immutable while the postmaster runs.  The
 * negative answer is cached for the same reason -- a fork absent from the seed
 * is absent from it permanently.
 */
bool
memcow_exists(SMgrRelation reln, ForkNumber forknum)
{
	MemcowForkSeed *fs = memcow_resolve_fork(reln, forknum, true);

	return fs->exists;
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
 * is not.  For memcow in this commit it genuinely cannot be reached, since
 * nothing can extend a relation past the seed's EOF until the overlay exists.)
 */
void
memcow_readv(SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
			 void **buffers, BlockNumber nblocks)
{
	MemcowForkSeed *fs = memcow_resolve_fork(reln, forknum, false);

	for (BlockNumber i = 0; i < nblocks; i++)
	{
		const char *src = memcow_seed_block(fs, blocknum + i);

		if (src == NULL)
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
					 errmsg("memcow could not read block %u of relation %s: block is past the end of the seed",
							blocknum + i, rel.str),
					 errdetail("The seed has %u block(s) in this fork.",
							   fs->nblocks)));
		}

		memcpy(buffers[i], src, BLCKSZ);
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
 * So: phase 1 resolves every block in the request and raises on the first one
 * that cannot be served, before a single buffer has been written and before
 * the handle has been touched; phase 2 copies and completes, and nothing in it
 * can fail.  The count handed to the helper is always the full nblocks.
 *
 * (Raising in phase 1 is safe for the handle: it is still PGAIO_HS_HANDED_OUT,
 * so the resource owner releases it during unwind.  Raising after the helper
 * would not be -- but nothing after the helper can raise.)
 */
void
memcow_startreadv(PgAioHandle *ioh,
				  SMgrRelation reln, ForkNumber forknum, BlockNumber blocknum,
				  void **buffers, BlockNumber nblocks)
{
	const char *srcs[PG_IOV_MAX];
	MemcowForkSeed *fs;

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
	 * iovec array.  Check rather than assert: this bound guards a stack array,
	 * and the whole function is about not letting a bad count through.
	 */
	if (nblocks > lengthof(srcs))
		elog(ERROR, "memcow read of %u blocks exceeds the %zu block limit",
			 nblocks, lengthof(srcs));

	fs = memcow_resolve_fork(reln, forknum, false);

	/* Phase 1: resolve every block.  Raises here or not at all. */
	for (BlockNumber i = 0; i < nblocks; i++)
	{
		srcs[i] = memcow_seed_block(fs, blocknum + i);

		if (srcs[i] == NULL)
		{
			RelPathStr	rel = relpath(reln->smgr_rlocator, forknum);

			ereport(ERROR,
					(errcode(ERRCODE_DATA_CORRUPTED),
					 errmsg("memcow could not read block %u of relation %s: block is past the end of the seed",
							blocknum + i, rel.str),
					 errdetail("The seed has %u block(s) in this fork.",
							   fs->nblocks)));
		}
	}

	/*
	 * Phase 2: serve.  Nothing below here may fail.
	 *
	 * No HOLD_INTERRUPTS() of our own: smgrstartreadv() already wraps this
	 * callback in one, so no CHECK_FOR_INTERRUPTS() can run between here and
	 * the return -- which matters, because absorbing a SMGRRELEASE barrier
	 * mid-copy would run smgr_close() over the memory being copied out of.
	 * Nor a critical section: pgaio_io_complete_synthetic() opens its own,
	 * narrowly, around the one call that needs it, so that the ereport(ERROR)s
	 * above stay ordinary errors instead of becoming PANICs.
	 */
	for (BlockNumber i = 0; i < nblocks; i++)
		memcpy(buffers[i], srcs[i], BLCKSZ);

	/*
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
 *
 * Errors on a fork that is not in the seed, matching mdnblocks(), which
 * reaches mdopenfork() with EXTENSION_FAIL.  Callers that are not sure the
 * fork exists are already written to ask smgrexists() first.
 *
 * The count is the seed's, and the seed's size never changes, so unlike md
 * this needs no re-stat: the value computed when the fork was first resolved
 * stays correct for the life of the process.  Once the overlay exists, the
 * answer becomes seed size extended by whatever the overlay added, and that
 * part will have to be recomputed per call -- the seed half will not.
 */
BlockNumber
memcow_nblocks(SMgrRelation reln, ForkNumber forknum)
{
	MemcowForkSeed *fs = memcow_resolve_fork(reln, forknum, false);

	return fs->nblocks;
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
