#include "git-compat-util.h"
#include "path-namespace.h"
#include "repository.h"
#include "semantic-verify-internal.h"
#include "wrapper.h"

#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN && defined(__linux__)
struct semantic_open_how {
	uint64_t flags;
	uint64_t mode;
	uint64_t resolve;
};

#define SEMANTIC_RESOLVE_NO_XDEV       0x01
#define SEMANTIC_RESOLVE_NO_MAGICLINKS 0x02
#define SEMANTIC_RESOLVE_NO_SYMLINKS   0x04
#define SEMANTIC_RESOLVE_BENEATH       0x08
#endif

#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN && !defined(__linux__)
static int set_fd_cloexec(int fd)
{
#if defined(F_GETFD) && defined(F_SETFD) && defined(FD_CLOEXEC)
	int flags = fcntl(fd, F_GETFD);

	if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0)
		return -1;
#endif
	return 0;
}
#endif

#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
int semantic_verify_openat(int dirfd, const char *path, int flags)
{
#ifdef __linux__
	struct semantic_open_how how = {
		.flags = flags | O_CLOEXEC,
		.resolve = SEMANTIC_RESOLVE_BENEATH |
			SEMANTIC_RESOLVE_NO_SYMLINKS |
			SEMANTIC_RESOLVE_NO_MAGICLINKS |
			SEMANTIC_RESOLVE_NO_XDEV,
	};

	return syscall(SYS_openat2, dirfd, path, &how, sizeof(how));
#else
	int fd;
	int saved_errno;

#ifdef O_CLOEXEC
	fd = openat(dirfd, path, flags | O_CLOEXEC);
	if (fd >= 0)
		return fd;
	if (errno != EINVAL)
		return -1;
#endif
	fd = openat(dirfd, path, flags);
	if (fd < 0)
		return -1;
	if (!set_fd_cloexec(fd))
		return fd;
	saved_errno = errno;
	close(fd);
	errno = saved_errno;
	return -1;
#endif
}
#else
int semantic_verify_openat(int dirfd UNUSED, const char *path UNUSED,
			   int flags UNUSED)
{
	errno = ENOSYS;
	return -1;
}
#endif

#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
int semantic_verify_root_init(struct repository *repo,
			      struct semantic_verify_root **root_out)
{
	struct semantic_verify_root *root;
	const char *path = repo_get_work_tree(repo);

	if (!path) {
		errno = ENOENT;
		return -1;
	}
	CALLOC_ARRAY(root, 1);
	root->fd = -1;
	root->path = xstrdup(path);
	root->fd = git_open_cloexec(root->path,
				    O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
	if (root->fd < 0 || fstat(root->fd, &root->stat) ||
	    !S_ISDIR(root->stat.st_mode)) {
		int saved_errno = errno ? errno : ENOTDIR;

		semantic_verify_root_clear(root);
		errno = saved_errno;
		return -1;
	}
#ifdef __linux__
	{
		struct stat probe_stat;
		int probe_fd = semantic_verify_openat(
			root->fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
		int saved_errno;

		if (probe_fd < 0) {
			saved_errno = errno;
			semantic_verify_root_clear(root);
			errno = saved_errno;
			return -1;
		}
		if (fstat(probe_fd, &probe_stat)) {
			saved_errno = errno;
			close(probe_fd);
			semantic_verify_root_clear(root);
			errno = saved_errno;
			return -1;
		}
		if (!path_namespace_stat_equal(&root->stat, &probe_stat)) {
			close(probe_fd);
			semantic_verify_root_clear(root);
			errno = EAGAIN;
			return -1;
		}
		if (close(probe_fd)) {
			saved_errno = errno;
			semantic_verify_root_clear(root);
			errno = saved_errno;
			return -1;
		}
	}
#endif
	*root_out = root;
	return 0;
}
#else
int semantic_verify_root_init(struct repository *repo UNUSED,
			      struct semantic_verify_root **root_out UNUSED)
{
	errno = ENOSYS;
	return -1;
}
#endif

int semantic_verify_root_stable(const struct semantic_verify_root *root)
{
	struct stat fd_stat, path_stat;

	if (!root || root->fd < 0)
		return 0;
	if (fstat(root->fd, &fd_stat) || lstat(root->path, &path_stat) ||
	    !S_ISDIR(path_stat.st_mode))
		return 0;
	return path_namespace_stat_equal(&root->stat, &fd_stat) &&
		path_namespace_stat_equal(&fd_stat, &path_stat);
}

void semantic_verify_root_clear(struct semantic_verify_root *root)
{
	if (!root)
		return;
	if (root->fd >= 0)
		close(root->fd);
	free(root->path);
	free(root);
}
