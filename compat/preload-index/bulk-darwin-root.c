#include "git-compat-util.h"

#include <sys/mount.h>

#include "compat/preload-index/bulk-darwin.h"
#include "path-namespace.h"
#include "repository.h"
#include "preload-index-bulk.h"

static int same_fsid(const fsid_t *a, const fsid_t *b)
{
	return !memcmp(a, b, sizeof(*a));
}

static int stat_local_apfs(int fd, struct stat *st, struct statfs *fs)
{
	if (fstat(fd, st) || fstatfs(fd, fs))
		return -1;
	if (!S_ISDIR(st->st_mode) || !(fs->f_flags & MNT_LOCAL) ||
	    strcmp(fs->f_fstypename, "apfs")) {
		errno = EXDEV;
		return -1;
	}
	return 0;
}

int preload_bulk_darwin_fd_on_root_mount(struct preload_bulk_scan *scan,
					 int fd, struct stat *st_out)
{
	struct preload_bulk_darwin_data *data = scan->platform_data;
	struct statfs fs;
	struct stat st;

	if (stat_local_apfs(fd, &st, &fs))
		return -1;
	if (st.st_dev != data->root_stat.st_dev ||
	    !same_fsid(&fs.f_fsid, &data->root_fsid)) {
		errno = EXDEV;
		return -1;
	}
	if (st_out)
		*st_out = st;
	return 0;
}

const char *preload_bulk_darwin_open_root(struct preload_bulk_scan *scan)
{
	struct preload_bulk_darwin_data *data;
	struct statfs fs;
	struct stat st;

	CALLOC_ARRAY(data, 1);
	scan->platform_data = data;
	scan->root_fd = open(repo_get_work_tree(scan->repo),
			     O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (scan->root_fd < 0 ||
	    stat_local_apfs(scan->root_fd, &st, &fs))
		return "unsupported-filesystem";
	return NULL;
}

const char *preload_bulk_darwin_snapshot_root(struct preload_bulk_scan *scan)
{
	struct preload_bulk_darwin_data *data = scan->platform_data;
	struct statfs fs;
	struct stat st;

	if (stat_local_apfs(scan->root_fd, &st, &fs))
		return "unsupported-filesystem";
	data->root_stat = st;
	data->root_fsid = fs.f_fsid;
	return NULL;
}

const char *preload_bulk_darwin_validate_root(struct preload_bulk_scan *scan)
{
	struct preload_bulk_darwin_data *data = scan->platform_data;
	struct stat root_after;
	int fd = open(repo_get_work_tree(scan->repo),
		      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);

	if (fd < 0 ||
	    preload_bulk_darwin_fd_on_root_mount(scan, fd, &root_after) ||
	    !path_namespace_stat_equal(&data->root_stat, &root_after)) {
		if (fd >= 0)
			close(fd);
		return "namespace-race";
	}
	close(fd);
	return NULL;
}

void preload_bulk_darwin_release(struct preload_bulk_scan *scan)
{
	if (scan->root_fd >= 0) {
		close(scan->root_fd);
		scan->root_fd = -1;
	}
	FREE_AND_NULL(scan->platform_data);
}
