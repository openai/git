#include "git-compat-util.h"

#ifdef __linux__

#include <sys/syscall.h>

#include "compat/preload-index/bulk-linux.h"
#include "preload-index-bulk.h"

#if defined(SYS_getdents64) && defined(SYS_statx)

static int valid_component(const char *component, size_t len)
{
	return len &&
		!(len == 1 && component[0] == '.') &&
		!(len == 2 && component[0] == '.' && component[1] == '.');
}

static int verify_mount(struct preload_bulk_scan *scan, int fd)
{
	struct preload_bulk_linux_data *data = scan->platform_data;
	struct preload_linux_statx stx;

	if (preload_bulk_linux_statx_raw(fd, "", PRELOAD_AT_EMPTY_PATH,
					 &stx))
		return -1;
	if (!preload_bulk_linux_statx_complete(&stx)) {
		errno = EOPNOTSUPP;
		return -1;
	}
	if (stx.mnt_id != data->root_mnt_id) {
		errno = EXDEV;
		return -1;
	}
	return 0;
}

#ifdef SYS_openat2
int preload_bulk_linux_openat2_raw(int dirfd, const char *path)
{
	struct preload_linux_open_how how = {
		.flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
		.resolve = PRELOAD_RESOLVE_BENEATH |
			PRELOAD_RESOLVE_NO_SYMLINKS |
			PRELOAD_RESOLVE_NO_MAGICLINKS |
			PRELOAD_RESOLVE_NO_XDEV,
	};

	return syscall(SYS_openat2, dirfd, path, &how, sizeof(how));
}
#endif

static int open_one_fallback(struct preload_bulk_scan *scan, int parent_fd,
			     const char *name, int check_mount)
{
	int fd = openat(parent_fd, name,
			O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);

	if (fd < 0)
		return -1;
	if (check_mount && verify_mount(scan, fd)) {
		int saved_errno = errno;

		close(fd);
		errno = saved_errno;
		return -1;
	}
	return fd;
}

int preload_bulk_linux_open_dir_at(
	struct preload_bulk_worker *worker, int parent_fd,
	const char *name)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct preload_bulk_linux_data *data = scan->platform_data;

	if (!valid_component(name, strlen(name)) || strchr(name, '/')) {
		errno = EINVAL;
		return -1;
	}
#ifdef SYS_openat2
	if (data->use_openat2)
		return preload_bulk_linux_openat2_raw(parent_fd, name);
#else
	(void)data;
#endif
	/* scan_directory() verifies the opened descriptor's mount ID. */
	return open_one_fallback(scan, parent_fd, name, 0);
}

int preload_bulk_linux_open_relative(struct preload_bulk_scan *scan,
				     const char *path)
{
	struct preload_bulk_linux_data *data = scan->platform_data;
	const char *component = path;
	int fd;

	if (!*path || *path == '/' || path[strlen(path) - 1] == '/') {
		errno = EINVAL;
		return -1;
	}
#ifdef SYS_openat2
	if (data->use_openat2)
		return preload_bulk_linux_openat2_raw(scan->root_fd, path);
#else
	(void)data;
#endif
	fd = fcntl(scan->root_fd, F_DUPFD_CLOEXEC, 0);
	if (fd < 0)
		return -1;
	if (verify_mount(scan, fd)) {
		int saved_errno = errno;

		close(fd);
		errno = saved_errno;
		return -1;
	}
	if (!strcmp(path, "."))
		return fd;
	while (*component) {
		const char *slash = strchr(component, '/');
		size_t len = slash ? (size_t)(slash - component) :
			strlen(component);
		char *name;
		int next;

		if (!valid_component(component, len)) {
			close(fd);
			errno = EINVAL;
			return -1;
		}
		name = xmemdupz(component, len);
		next = open_one_fallback(scan, fd, name, 1);
		free(name);
		close(fd);
		if (next < 0)
			return -1;
		fd = next;
		if (!slash)
			break;
		component = slash + 1;
	}
	return fd;
}

#endif /* SYS_getdents64 && SYS_statx */

#endif /* __linux__ */
