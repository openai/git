#include "git-compat-util.h"
#include "convert.h"
#include "environment.h"
#include "object-file.h"
#include "path-namespace.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "semantic-verify.h"
#include "semantic-verify-internal.h"

#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
static int mode_matches_ce(struct repository *repo,
			   const struct cache_entry *ce,
			   const struct stat *st)
{
	if (!S_ISREG(st->st_mode))
		return 0;
	if (repo_trust_executable_bit(repo) &&
	    ((ce->ce_mode ^ st->st_mode) & 0100))
		return 0;
	return 1;
}

static int hash_raw_blob(int fd, size_t size,
			 const struct git_hash_algo *algo,
			 struct object_id *oid, void *buffer,
			 size_t *bytes_hashed)
{
	struct git_hash_ctx ctx;
	char header[MAX_HEADER_LEN];
	int header_len;
	size_t remaining = size;

	header_len = format_object_header(header, sizeof(header), OBJ_BLOB, size);
	git_hash_init(&ctx, algo);
	git_hash_update(&ctx, header, header_len);

	while (remaining) {
		size_t want = remaining < SEMANTIC_VERIFY_HASH_BUFFER_SIZE ?
			remaining : SEMANTIC_VERIFY_HASH_BUFFER_SIZE;
		ssize_t nr = xread(fd, buffer, want);

		if (nr < 0)
			return -1;
		if (!nr) {
			errno = EIO;
			return -1;
		}
		git_hash_update(&ctx, buffer, nr);
		remaining -= nr;
		*bytes_hashed += nr;
	}

	/* Do not silently omit an append which raced with the declared size. */
	{
		char extra;
		ssize_t nr = xread(fd, &extra, 1);

		if (nr < 0)
			return -1;
		if (nr) {
			errno = EAGAIN;
			return -1;
		}
	}

	git_hash_final_oid(oid, &ctx);
	return 0;
}

static unsigned int classify_resolve_error(int error)
{
	if (error == ENOENT)
		return SEMANTIC_VERIFY_RAW_MODIFIED;
	if (error == ELOOP || error == ENOTDIR || error == EXDEV ||
	    error == EINVAL)
		return SEMANTIC_VERIFY_STRUCTURAL;
	return SEMANTIC_VERIFY_ERROR;
}
#endif

int semantic_verify_classify_entry(struct index_state *istate,
				   const struct cache_entry *ce,
				   struct attr_check *check,
				   struct semantic_verify_file_result *result)
{
	memset(result, 0, sizeof(*result));
	if (ce_skip_worktree(ce) || (ce->ce_flags & CE_VALID)) {
		result->kind = SEMANTIC_VERIFY_SKIPPED;
		return 0;
	}
	if (ce_stage(ce) || ce_intent_to_add(ce) ||
	    S_ISSPARSEDIR(ce->ce_mode)) {
		result->kind = SEMANTIC_VERIFY_STRUCTURAL;
		return 0;
	}
	if (!S_ISREG(ce->ce_mode) ||
	    !convert_attrs_is_raw_safe(istate, ce->name, check)) {
		result->kind = SEMANTIC_VERIFY_SENSITIVE;
		return 0;
	}
	return 1;
}

#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
void semantic_verify_file_at(int parent_fd, const char *basename,
			     const struct stat *observed,
			     dev_t root_dev,
			     const struct cache_entry *ce,
			     struct repository *repo, void *buffer,
			     struct semantic_verify_file_result *result)
{
	struct stat path_before = *observed, fd_before, fd_after, path_after;
	struct object_id oid;
	int fd = -1;
	int saved_errno;

	memset(result, 0, sizeof(*result));
	if (!mode_matches_ce(repo, ce, &path_before)) {
		result->kind = SEMANTIC_VERIFY_RAW_MODIFIED;
		return;
	}
	if (path_before.st_size < 0 ||
	    (uintmax_t)path_before.st_size > (uintmax_t)SIZE_MAX) {
		result->kind = SEMANTIC_VERIFY_SENSITIVE;
		return;
	}

	fd = semantic_verify_openat(parent_fd, basename,
				    O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
	if (fd < 0) {
		result->error = errno;
		result->kind = errno == ENOENT || errno == ENOTDIR ||
			errno == ELOOP ?
			SEMANTIC_VERIFY_UNSTABLE : SEMANTIC_VERIFY_ERROR;
		return;
	}
	if (fstat(fd, &fd_before))
		goto unstable;
	if (fd_before.st_dev != root_dev ||
	    !path_namespace_stat_equal(&path_before, &fd_before)) {
		errno = EAGAIN;
		goto unstable;
	}
	if (hash_raw_blob(fd, (size_t)fd_before.st_size, repo->hash_algo, &oid,
			  buffer, &result->bytes_hashed))
		goto unstable;
	if (fstat(fd, &fd_after))
		goto unstable;
	if (fstatat(parent_fd, basename, &path_after, AT_SYMLINK_NOFOLLOW))
		goto unstable;
	if (!path_namespace_stat_equal(&fd_before, &fd_after) ||
	    !path_namespace_stat_equal(&fd_after, &path_after)) {
		errno = EAGAIN;
		goto unstable;
	}
	if (path_namespace_reopen_component(
		    parent_fd, basename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW,
		    semantic_verify_openat, &fd_after))
		goto unstable;
	close(fd);

	if (!oideq(&oid, &ce->oid)) {
		result->kind = SEMANTIC_VERIFY_RAW_MODIFIED;
		return;
	}
	result->kind = SEMANTIC_VERIFY_RAW_CLEAN;
	result->persistable = fd_after.st_nlink == 1;
	fill_stat_data(&result->stat_data, &fd_after);
	return;

unstable:
	saved_errno = errno;
	close(fd);
	result->kind = SEMANTIC_VERIFY_UNSTABLE;
	result->error = saved_errno;
}

void semantic_verify_file(struct semantic_verify_root *root,
			  struct semantic_verify_path *path,
			  const struct cache_entry *ce, size_t cache_pos,
			  struct repository *repo, void *buffer,
			  struct semantic_verify_file_result *result)
{
	struct stat path_before;
	const char *basename;
	int parent_fd;

	memset(result, 0, sizeof(*result));
	if (semantic_verify_resolve_parent(path, ce->name, cache_pos,
					   &parent_fd, &basename)) {
		result->error = errno;
		result->kind = classify_resolve_error(errno);
		return;
	}
	if (fstatat(parent_fd, basename, &path_before, AT_SYMLINK_NOFOLLOW)) {
		result->error = errno;
		result->kind = errno == ENOENT || errno == ENOTDIR ?
			SEMANTIC_VERIFY_RAW_MODIFIED : SEMANTIC_VERIFY_ERROR;
		return;
	}
	semantic_verify_file_at(parent_fd, basename, &path_before,
				root->stat.st_dev, ce, repo, buffer, result);
}
#else
static void semantic_verify_file_unavailable(
	struct semantic_verify_file_result *result)
{
	memset(result, 0, sizeof(*result));
	result->kind = SEMANTIC_VERIFY_ERROR;
	result->error = ENOSYS;
}

void semantic_verify_file_at(
	int parent_fd UNUSED, const char *basename UNUSED,
	const struct stat *observed UNUSED,
	dev_t root_dev UNUSED,
	const struct cache_entry *ce UNUSED,
	struct repository *repo UNUSED, void *buffer UNUSED,
	struct semantic_verify_file_result *result)
{
	semantic_verify_file_unavailable(result);
}

void semantic_verify_file(
	struct semantic_verify_root *root UNUSED,
	struct semantic_verify_path *path UNUSED,
	const struct cache_entry *ce UNUSED, size_t cache_pos UNUSED,
	struct repository *repo UNUSED, void *buffer UNUSED,
	struct semantic_verify_file_result *result)
{
	semantic_verify_file_unavailable(result);
}
#endif
