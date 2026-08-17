#include "git-compat-util.h"
#include "exclude-source-proof.h"
#include "hash-framing.h"
#include "object-file.h"
#include "path-namespace.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "strmap.h"
#include "trace2.h"

/*
 * Each entry describes one path/policy observation for replay or a stable
 * digest. Filesystem identities make capture and validation coherent; the
 * durable observation is the source's existence and bytes.
 */
struct exclude_source_proof_entry {
	char *path;
	size_t size;
	struct object_id oid;
	unsigned exists : 1;
	unsigned nofollow : 1;
};

struct exclude_source_proof {
	struct index_state *istate;
	void *open_data;
	exclude_source_open_parent_fn open_parent;
	struct exclude_source_proof_entry *entries;
	struct strintmap entries_by_path[2];
	size_t nr;
	size_t alloc;
	unsigned nonblocking : 1;
	unsigned invalid : 1;
};

struct exclude_source_capture {
	struct exclude_source_proof *proof;
	char *path;
	char *parent;
	char *relative;
	int parent_fd;
	struct stat parent_stat;
	unsigned nofollow : 1;
};

static char *source_parent(const char *path)
{
	const char *slash = strrchr(path, '/');

	if (!slash)
		return xstrdup(".");
	if (slash == path)
		return xstrdup("/");
	return xmemdupz(path, slash - path);
}

static char *source_relative(const char *path, const char *parent)
{
	const char *relative;
	size_t len;

	if (!strcmp(parent, "."))
		return xstrdup(path);
	if (!strcmp(parent, "/")) {
		relative = path + 1;
	} else {
		len = strlen(parent);
		if (strncmp(path, parent, len) || path[len] != '/')
			BUG("exclude source is not below its parent");
		relative = path + len + 1;
	}
	return xstrdup(*relative ? relative : ".");
}

static int parent_up(char *parent)
{
	char *slash;

	if (!strcmp(parent, ".") || !strcmp(parent, "/"))
		return 0;
	slash = strrchr(parent, '/');
	if (!slash) {
		parent[0] = '.';
		parent[1] = '\0';
	} else if (slash == parent) {
		parent[1] = '\0';
	} else {
		*slash = '\0';
	}
	return 1;
}

static int open_source_at(int parent_fd, const char *relative, int nofollow,
			  int nonblocking)
{
#if EXCLUDE_SOURCE_PROOF_HAS_ANCHORED_OPEN
	int flags = O_RDONLY | O_CLOEXEC;

	if (nofollow)
		flags |= O_NOFOLLOW;
	if (nonblocking)
		flags |= O_NONBLOCK;
	return openat(parent_fd, relative, flags);
#else
	(void)parent_fd;
	(void)relative;
	(void)nofollow;
	(void)nonblocking;
	errno = ENOSYS;
	return -1;
#endif
}

static int parent_identity_stable(
	struct exclude_source_proof *proof, const char *parent,
	int held_fd, const struct stat *expected, int regular_source)
{
	struct stat held, reopened;
	int fd = proof->open_parent(proof->open_data, parent);
	/*
	 * A regular source has its own held descriptor and repeated target
	 * identity checks. Absence and nonregular sources cannot distinguish a
	 * transient target change from harmless parent-directory churn.
	 */
	int stable = !fstat(held_fd, &held) &&
		fd >= 0 && !fstat(fd, &reopened) &&
		(regular_source ?
		 (path_namespace_directory_stat_equal(expected, &held) &&
		  path_namespace_directory_stat_equal(expected, &reopened)) :
		 (path_namespace_stat_equal(expected, &held) &&
		  path_namespace_stat_equal(expected, &reopened)));

	if (fd >= 0)
		close(fd);
	return stable;
}

static int parent_stable(struct exclude_source_capture *capture,
			 int regular_source)
{
	return parent_identity_stable(
		capture->proof, capture->parent, capture->parent_fd,
		&capture->parent_stat, regular_source);
}

static void capture_free(struct exclude_source_capture *capture)
{
	if (!capture)
		return;
	if (capture->parent_fd >= 0)
		close(capture->parent_fd);
	free(capture->path);
	free(capture->parent);
	free(capture->relative);
	free(capture);
}

static struct exclude_source_capture *capture_begin(
	struct exclude_source_proof *proof, const char *path,
	int nofollow, int invalidate)
{
	struct exclude_source_capture *capture;

	if (!proof || proof->invalid)
		return NULL;
	if (!path) {
		if (invalidate)
			proof->invalid = 1;
		return NULL;
	}
	CALLOC_ARRAY(capture, 1);
	capture->proof = proof;
	capture->nofollow = nofollow;
	capture->parent_fd = -1;
	capture->path = xstrdup(path);
	capture->parent = source_parent(path);
	for (;;) {
		capture->parent_fd = proof->open_parent(proof->open_data,
						       capture->parent);
		if (capture->parent_fd >= 0)
			break;
		if (!is_missing_file_error(errno) ||
		    !parent_up(capture->parent))
			break;
	}
	if (capture->parent_fd < 0 ||
	    fstat(capture->parent_fd, &capture->parent_stat) ||
	    !S_ISDIR(capture->parent_stat.st_mode)) {
		if (invalidate)
			proof->invalid = 1;
		capture_free(capture);
		return NULL;
	}
	capture->relative = source_relative(path, capture->parent);
	return capture;
}

struct exclude_source_proof *exclude_source_proof_create(
	struct index_state *istate, void *open_data,
	exclude_source_open_parent_fn open_parent, unsigned flags)
{
	struct exclude_source_proof *proof;

	CALLOC_ARRAY(proof, 1);
	proof->istate = istate;
	proof->open_data = open_data;
	proof->open_parent = open_parent;
	proof->nonblocking =
		!!(flags & EXCLUDE_SOURCE_PROOF_NONBLOCKING);
	strintmap_init_with_options(&proof->entries_by_path[0], -1,
				    NULL, 0);
	strintmap_init_with_options(&proof->entries_by_path[1], -1,
				    NULL, 0);
	if (!EXCLUDE_SOURCE_PROOF_HAS_ANCHORED_OPEN ||
	    !istate || !istate->repo || !istate->repo->hash_algo ||
	    !open_parent ||
	    (flags & ~EXCLUDE_SOURCE_PROOF_NONBLOCKING))
		proof->invalid = 1;
	return proof;
}

struct exclude_source_capture *exclude_source_capture_begin(
	struct exclude_source_proof *proof, const char *path,
	int nofollow)
{
	return capture_begin(proof, path, nofollow, 1);
}

int exclude_source_capture_open(struct exclude_source_capture *capture)
{
	if (!capture) {
		errno = EINVAL;
		return -1;
	}
	return open_source_at(capture->parent_fd, capture->relative,
			      capture->nofollow,
			      capture->proof->nonblocking);
}

int exclude_source_capture_absent(struct exclude_source_capture *capture)
{
#if EXCLUDE_SOURCE_PROOF_HAS_ANCHORED_OPEN
	struct stat st;

	if (!capture)
		return 0;
	if (!fstatat(capture->parent_fd, capture->relative, &st,
		     AT_SYMLINK_NOFOLLOW))
		return 0;
	return is_missing_file_error(errno);
#else
	(void)capture;
	return 0;
#endif
}

static int source_matches(struct exclude_source_capture *capture,
			  const struct stat *expected)
{
	struct stat st;
	int fd = open_source_at(capture->parent_fd, capture->relative,
				capture->nofollow, 1);
	int ret = fd >= 0 && !fstat(fd, &st) &&
		path_namespace_stat_equal(expected, &st);

	if (fd >= 0)
		close(fd);
	return ret;
}

static int source_matches_after_read(struct exclude_source_capture *capture,
				     const struct stat *expected)
{
#if EXCLUDE_SOURCE_PROOF_HAS_ANCHORED_OPEN
	if (S_ISREG(expected->st_mode)) {
		struct stat named;
		int flags = capture->nofollow ? AT_SYMLINK_NOFOLLOW : 0;

		/* The final reopened descriptor still proves readability. */
		return !fstatat(capture->parent_fd, capture->relative,
				&named, flags) &&
			path_namespace_stat_equal(expected, &named);
	}
#endif
	return source_matches(capture, expected);
}

static int same_observation(
	const struct exclude_source_proof_entry *entry,
	int exists, size_t size, const struct object_id *oid)
{
	return entry->exists == exists &&
		(!exists ||
		 (entry->size == size && oideq(&entry->oid, oid)));
}

static void record_observation(
	struct exclude_source_capture *capture, int exists,
	size_t size, const struct object_id *oid)
{
	struct exclude_source_proof *proof = capture->proof;
	struct strintmap *map =
		&proof->entries_by_path[!!capture->nofollow];
	struct exclude_source_proof_entry *entry;
	int index = strintmap_get(map, capture->path);

	if (index >= 0) {
		if (!same_observation(&proof->entries[index],
				      exists, size, oid))
			proof->invalid = 1;
		return;
	}

	ALLOC_GROW(proof->entries, proof->nr + 1, proof->alloc);
	entry = &proof->entries[proof->nr];
	memset(entry, 0, sizeof(*entry));
	entry->path = xstrdup(capture->path);
	entry->nofollow = capture->nofollow;
	entry->exists = exists;
	if (exists) {
		entry->size = size;
		oidcpy(&entry->oid, oid);
	}
	strintmap_set(map, entry->path, proof->nr);
	proof->nr++;
}

void exclude_source_capture_record(
	struct exclude_source_capture *capture,
	int source_fd,
	const struct stat *source_stat,
	const void *buf, size_t size)
{
	struct exclude_source_proof *proof;
	struct object_id oid;
	struct stat final;

	if (!capture)
		return;
	proof = capture->proof;
	if (proof->invalid)
		return;

	if (!source_stat) {
		if (!exclude_source_capture_absent(capture) ||
		    !parent_stable(capture, 0) ||
		    !exclude_source_capture_absent(capture)) {
			proof->invalid = 1;
			return;
		}
		record_observation(capture, 0, 0, NULL);
		return;
	}

	if (source_fd < 0 || source_stat->st_size < 0 ||
	    (!buf && size) ||
	    xsize_t(source_stat->st_size) != size ||
	    fstat(source_fd, &final) ||
	    !path_namespace_stat_equal(source_stat, &final) ||
	    !parent_stable(capture, S_ISREG(final.st_mode)) ||
	    fstat(source_fd, &final) ||
	    !path_namespace_stat_equal(source_stat, &final) ||
	    !source_matches(capture, &final)) {
		proof->invalid = 1;
		return;
	}
	hash_object_file(proof->istate->repo->hash_algo, buf, size,
			 OBJ_BLOB, &oid);
	record_observation(capture, 1, size, &oid);
}

void exclude_source_capture_error(struct exclude_source_capture *capture)
{
	if (capture)
		capture->proof->invalid = 1;
}

void exclude_source_capture_release(struct exclude_source_capture *capture)
{
	capture_free(capture);
}

static int proof_entry_matches(
	struct exclude_source_proof *proof,
	const struct exclude_source_proof_entry *entry)
{
	struct exclude_source_capture *capture =
		capture_begin(proof, entry->path, entry->nofollow, 0);
	struct object_id oid;
	struct stat before, after, final;
	char *buf = NULL;
	size_t size;
	int fd = -1;
	int ret = 0;

	if (!capture)
		goto done;
	if (!entry->exists) {
		ret = exclude_source_capture_absent(capture) &&
			parent_stable(capture, 0) &&
			exclude_source_capture_absent(capture);
		goto done;
	}

	fd = open_source_at(capture->parent_fd, capture->relative,
			    entry->nofollow, 1);
	if (fd < 0 || fstat(fd, &before) || before.st_size < 0 ||
	    xsize_t(before.st_size) != entry->size)
		goto done;
	size = entry->size;
	buf = xmalloc(size ? size : 1);
	if ((size_t)read_in_full(fd, buf, size) != size ||
	    fstat(fd, &after) ||
	    !path_namespace_stat_equal(&before, &after) ||
	    !source_matches_after_read(capture, &after))
		goto done;
	hash_object_file(proof->istate->repo->hash_algo, buf, size,
			 OBJ_BLOB, &oid);
	if (!oideq(&oid, &entry->oid) ||
	    !parent_stable(capture, S_ISREG(after.st_mode)) ||
	    fstat(fd, &final) ||
	    !path_namespace_stat_equal(&after, &final) ||
	    !source_matches(capture, &final))
		goto done;
	ret = 1;
done:
	free(buf);
	if (fd >= 0)
		close(fd);
	capture_free(capture);
	return ret;
}

int exclude_source_proof_validate(struct exclude_source_proof *proof)
{
	int valid;

	if (!proof)
		return 0;
	valid = !proof->invalid;
	for (size_t i = 0; valid && i < proof->nr; i++)
		valid = proof_entry_matches(proof, &proof->entries[i]);
	if (proof->istate && proof->istate->repo) {
		trace2_data_intmax("exclude", proof->istate->repo,
				   "proof_entries", proof->nr);
		trace2_data_intmax("exclude", proof->istate->repo,
				   "proof_valid", valid);
	}
	return valid;
}

int exclude_source_proof_digest(
	struct exclude_source_proof *proof,
	const struct git_hash_algo *algo,
	struct object_id *oid)
{
	static const char domain[] = "git-exclude-source-proof-digest-v1";
	const struct git_hash_algo *source_algo;
	struct git_hash_ctx ctx;
	unsigned char count[sizeof(uint64_t)];
	unsigned char format[sizeof(uint32_t)];

	if (!proof || !algo || !oid ||
	    !exclude_source_proof_validate(proof))
		return -1;
	source_algo = proof->istate->repo->hash_algo;
	git_hash_init(&ctx, algo);
	hash_length_delimited(&ctx, domain, sizeof(domain) - 1);
	put_be32(format, source_algo->format_id);
	hash_length_delimited(&ctx, format, sizeof(format));
	put_be64(count, proof->nr);
	hash_length_delimited(&ctx, count, sizeof(count));
	for (size_t i = 0; i < proof->nr; i++) {
		const struct exclude_source_proof_entry *entry =
			&proof->entries[i];
		unsigned char policy[] = {
			entry->nofollow,
			entry->exists,
		};

		hash_length_delimited(&ctx, entry->path,
				      strlen(entry->path));
		hash_length_delimited(&ctx, policy, sizeof(policy));
		hash_length_delimited(&ctx, entry->oid.hash,
				      entry->exists ? source_algo->rawsz : 0);
	}
	git_hash_final_oid(oid, &ctx);
	return 0;
}

void exclude_source_proof_release(struct exclude_source_proof *proof)
{
	if (!proof)
		return;
	strintmap_clear(&proof->entries_by_path[0]);
	strintmap_clear(&proof->entries_by_path[1]);
	for (size_t i = 0; i < proof->nr; i++)
		free(proof->entries[i].path);
	free(proof->entries);
	free(proof);
}
