#include "git-compat-util.h"

#ifdef __linux__

#include <sys/statfs.h>
#include <sys/syscall.h>

#include "compat/preload-index/bulk-linux.h"
#include "preload-index-bulk.h"
#include "repository.h"
#include "trace2.h"

#ifndef EXT_FAMILY_SUPER_MAGIC
#define EXT_FAMILY_SUPER_MAGIC 0xef53
#endif
#ifndef XFS_SUPER_MAGIC
#define XFS_SUPER_MAGIC 0x58465342
#endif

#if defined(SYS_getdents64) && defined(SYS_statx)

static int read_mountinfo(struct strbuf *out)
{
	int fd = open("/proc/self/mountinfo", O_RDONLY | O_CLOEXEC);
	int ret = -1;

	if (fd < 0)
		return -1;
	strbuf_reset(out);
	if (strbuf_read(out, fd, 0) >= 0)
		ret = 0;
	if (close(fd))
		ret = -1;
	return ret;
}

const char *preload_bulk_linux_start(struct preload_bulk_scan *scan)
{
	struct preload_bulk_linux_data *data;
	struct statfs fs;
	const char *fs_name;

	CALLOC_ARRAY(data, 1);
	strbuf_init(&data->mountinfo, 0);
	scan->platform_data = data;
	scan->root_fd = open(repo_get_work_tree(scan->repo),
			     O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (scan->root_fd < 0 || fstatfs(scan->root_fd, &fs))
		return "unsupported-filesystem";
	if ((unsigned long)fs.f_type == EXT_FAMILY_SUPER_MAGIC)
		fs_name = "ext-family";
	else if ((unsigned long)fs.f_type == XFS_SUPER_MAGIC)
		fs_name = "xfs";
	else
		return "unsupported-filesystem";
	trace2_data_string("index", scan->repo, "preload/bulk_filesystem",
			   fs_name);
	if (preload_bulk_linux_statx_raw(
		    scan->root_fd, "", PRELOAD_AT_EMPTY_PATH,
		    &data->root_statx) ||
	    !preload_bulk_linux_statx_complete(&data->root_statx) ||
	    !S_ISDIR(data->root_statx.mode))
		return "statx-unavailable";
	data->root_mnt_id = data->root_statx.mnt_id;
	if (read_mountinfo(&data->mountinfo))
		return "namespace-check-unavailable";
#ifdef SYS_openat2
	{
		int fd = preload_bulk_linux_openat2_raw(scan->root_fd, ".");

		if (fd >= 0) {
			struct preload_linux_statx probe;

			if (!preload_bulk_linux_statx_raw(
				    fd, "", PRELOAD_AT_EMPTY_PATH, &probe) &&
			    preload_bulk_linux_statx_complete(&probe) &&
			    probe.mnt_id == data->root_mnt_id)
				data->use_openat2 = 1;
			close(fd);
		}
	}
#endif
	trace2_data_intmax("index", scan->repo, "preload/bulk_openat2",
			   data->use_openat2);
	return NULL;
}

const char *preload_bulk_linux_finish(struct preload_bulk_scan *scan)
{
	struct preload_bulk_linux_data *data = scan->platform_data;
	struct strbuf after = STRBUF_INIT;
	struct preload_linux_statx root_after;
	const char *result = NULL;
	int fd;

	if (read_mountinfo(&after)) {
		result = "namespace-check-unavailable";
		goto out;
	}
	if (strbuf_cmp(&data->mountinfo, &after)) {
		trace2_data_intmax(
			"index", scan->repo,
			"preload/bulk_namespace_churn", 1);
		result = "namespace-churn";
		goto out;
	}
	fd = open(repo_get_work_tree(scan->repo),
		  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0) {
		result = "namespace-race";
		goto out;
	}
	if (preload_bulk_linux_statx_raw(
		    fd, "", PRELOAD_AT_EMPTY_PATH, &root_after) ||
	    !preload_bulk_linux_statx_same(
		    &data->root_statx, &root_after))
		result = "namespace-race";
	close(fd);

out:
	strbuf_release(&after);
	return result;
}

void preload_bulk_linux_release(struct preload_bulk_scan *scan)
{
	struct preload_bulk_linux_data *data = scan->platform_data;

	if (scan->root_fd >= 0) {
		close(scan->root_fd);
		scan->root_fd = -1;
	}
	if (!data)
		return;
	strbuf_release(&data->mountinfo);
	free(data);
	scan->platform_data = NULL;
}

#endif /* SYS_getdents64 && SYS_statx */

#endif /* __linux__ */
