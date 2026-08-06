#include "git-compat-util.h"
#include "attr.h"
#include "hash.h"
#include "path-namespace.h"
#include "semantic-verify-internal.h"
#include "worktree-attr-source.h"

#define WORKTREE_ATTR_HASH_BUFFER_SIZE (64 * 1024)

#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN

int worktree_attr_source_read(
	struct semantic_verify_path *path UNUSED,
	const char *name UNUSED, size_t position UNUSED,
	const struct git_hash_algo *algo UNUSED,
	unsigned char *hash UNUSED, int *found)
{
	*found = 0;
	return -1;
}

#else

int worktree_attr_source_read(struct semantic_verify_path *path,
			      const char *name, size_t position,
			      const struct git_hash_algo *algo,
			      unsigned char *hash, int *found)
{
	struct git_hash_ctx ctx = { 0 };
	struct stat before, after, named;
	unsigned char buffer[WORKTREE_ATTR_HASH_BUFFER_SIZE];
	const char *basename;
	ssize_t got;
	size_t remaining, size;
	int parent_fd, fd = -1, ret = -1;
	char extra;

	*found = 0;
	if (semantic_verify_resolve_parent(path, name, position,
					   &parent_fd, &basename)) {
		if (errno == ENOENT || errno == ENOTDIR || errno == ELOOP ||
		    errno == EXDEV)
			return 0;
		return -1;
	}
	if (fstatat(parent_fd, basename, &before, AT_SYMLINK_NOFOLLOW))
		return errno == ENOENT || errno == ENOTDIR ? 0 : -1;
	if (!S_ISREG(before.st_mode) ||
	    before.st_size < 0 || before.st_size >= ATTR_MAX_FILE_SIZE)
		return 0;
	if (before.st_nlink != 1)
		return -1;

	fd = semantic_verify_openat(parent_fd, basename,
				    O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
	if (fd < 0)
		return -1;
	if (fstat(fd, &after) ||
	    !path_namespace_stat_equal(&before, &after))
		goto done;
	size = xsize_t(before.st_size);
	remaining = size;
	git_hash_init(&ctx, algo);
	while (remaining) {
		size_t want = remaining < sizeof(buffer) ?
			remaining : sizeof(buffer);

		got = xread(fd, buffer, want);
		if (got <= 0)
			goto done;
		git_hash_update(&ctx, buffer, got);
		remaining -= got;
	}
	got = xread(fd, &extra, 1);
	if (got != 0 ||
	    fstat(fd, &after) ||
	    fstatat(parent_fd, basename, &named, AT_SYMLINK_NOFOLLOW) ||
	    !path_namespace_stat_equal(&before, &after) ||
	    !path_namespace_stat_equal(&after, &named) ||
	    path_namespace_reopen_component(
		    parent_fd, basename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW,
		    semantic_verify_openat, &after))
		goto done;
	git_hash_final(hash, &ctx);
	*found = 1;
	ret = 0;
done:
	git_hash_discard(&ctx);
	close(fd);
	return ret;
}

#endif /* SEMANTIC_VERIFY_HAS_ANCHORED_OPEN */
