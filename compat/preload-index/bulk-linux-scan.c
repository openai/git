#include "git-compat-util.h"

#ifdef __linux__

#include <sys/syscall.h>

#include "compat/preload-index/bulk-linux.h"
#include "path-namespace.h"
#include "preload-index-bulk.h"

#if defined(SYS_getdents64) && defined(SYS_statx)

static struct preload_bulk_dir_identity directory_identity(
	const struct preload_linux_statx *stx, const struct stat *st)
{
	struct preload_bulk_dir_identity result = {
		.stat = *st,
		.platform_id = stx->mnt_id,
		.complete = 1,
	};

	return result;
}

static int directory_identity_matches(
	const struct preload_bulk_dir_identity *before,
	const struct preload_linux_statx *stx, const struct stat *after)
{
	return S_ISDIR(after->st_mode) &&
		path_namespace_stat_equal(&before->stat, after) &&
		before->platform_id == stx->mnt_id;
}

int preload_bulk_linux_scan_directory(struct preload_bulk_worker *worker,
				      struct preload_bulk_task *task)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct preload_linux_statx before_stx, after_stx;
	struct preload_bulk_dir_identity before_identity;
	struct stat before, after;
	size_t path_len;
	int fd = task->fd;
	int ret = -1;

	if (fd < 0)
		fd = preload_bulk_linux_open_relative(scan, task->path);
	if (fd < 0)
		goto out;
	if (preload_bulk_test_barrier(scan, task->path))
		goto out;
	if (preload_bulk_linux_fd_stat(
		    worker, fd, &before_stx, &before) ||
	    !S_ISDIR(before.st_mode)) {
		if (errno != EXDEV)
			goto out;
		path_len = strlen(task->path);
		preload_bulk_record_tracked_descendants_fallback(
			worker, task->path, path_len);
		if (scan->collect_untracked)
			preload_bulk_invalidate_untracked(worker);
		ret = 0;
		goto out;
	}
	before_identity = directory_identity(&before_stx, &before);
	if ((!scan->collect_untracked ||
	     !preload_bulk_untracked_root_is_visible(
		     worker, task->untracked_root)) &&
	    preload_bulk_linux_enumerate(
		    worker, task, fd, &before_identity))
		goto out;
	if (preload_bulk_linux_fd_stat(
		    worker, fd, &after_stx, &after))
		goto out;
	if (!preload_bulk_linux_statx_same(&before_stx, &after_stx) ||
	    !directory_identity_matches(
		    &before_identity, &after_stx, &after))
		worker->changed_dirs++;
	ret = 0;

out:
	if (task->has_parent_identity) {
		struct preload_linux_statx parent_stx;
		struct stat parent_after;
		int parent_changed = fd < 0;

		/*
		 * Resolve ".." through the held child descriptor so a move
		 * cannot redirect the parent check to the old path.
		 */
		if (!parent_changed)
			parent_changed = preload_bulk_linux_entry_stat(
				worker, fd, "..", &parent_stx,
				&parent_after);
		if (parent_changed ||
		    !directory_identity_matches(
			    &task->parent_identity, &parent_stx,
			    &parent_after))
			worker->changed_dirs++;
	}
	if (fd >= 0)
		close(fd);
	return ret;
}

#endif /* SYS_getdents64 && SYS_statx */

#endif /* __linux__ */
