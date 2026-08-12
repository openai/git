#include "git-compat-util.h"

#ifdef __linux__

#include <sys/syscall.h>
#include <sys/sysmacros.h>

#include "compat/preload-index/bulk-linux.h"
#include "preload-index-bulk.h"

#if defined(SYS_getdents64) && defined(SYS_statx)

int preload_bulk_linux_statx_raw(int dirfd, const char *path, int flags,
				 struct preload_linux_statx *stx)
{
	memset(stx, 0, sizeof(*stx));
	return syscall(SYS_statx, dirfd, path, flags,
		       PRELOAD_STATX_BASIC_STATS | PRELOAD_STATX_MNT_ID, stx);
}

int preload_bulk_linux_statx_complete(
	const struct preload_linux_statx *stx)
{
	return (stx->mask &
		(PRELOAD_STATX_BASIC_STATS | PRELOAD_STATX_MNT_ID)) ==
		(PRELOAD_STATX_BASIC_STATS | PRELOAD_STATX_MNT_ID) &&
		stx->mtime.tv_nsec < 1000000000 &&
		stx->ctime.tv_nsec < 1000000000;
}

int preload_bulk_linux_statx_same(const struct preload_linux_statx *a,
				  const struct preload_linux_statx *b)
{
	return preload_bulk_linux_statx_complete(a) &&
		preload_bulk_linux_statx_complete(b) &&
		a->mnt_id == b->mnt_id &&
		a->dev_major == b->dev_major &&
		a->dev_minor == b->dev_minor &&
		a->ino == b->ino && a->mode == b->mode &&
		a->nlink == b->nlink && a->uid == b->uid &&
		a->gid == b->gid && a->size == b->size &&
		a->mtime.tv_sec == b->mtime.tv_sec &&
		a->mtime.tv_nsec == b->mtime.tv_nsec &&
		a->ctime.tv_sec == b->ctime.tv_sec &&
		a->ctime.tv_nsec == b->ctime.tv_nsec;
}

static int statx_to_stat(const struct preload_linux_statx *stx,
			 struct stat *st)
{
	dev_t dev;

	if (!preload_bulk_linux_statx_complete(stx))
		return -1;
	memset(st, 0, sizeof(*st));
	dev = makedev(stx->dev_major, stx->dev_minor);
	if (major(dev) != stx->dev_major || minor(dev) != stx->dev_minor)
		return -1;
	st->st_dev = dev;
	st->st_ino = stx->ino;
	if ((uint64_t)st->st_ino != stx->ino)
		return -1;
	st->st_mode = stx->mode;
	st->st_nlink = stx->nlink;
	if ((uint64_t)st->st_nlink != stx->nlink)
		return -1;
	st->st_uid = stx->uid;
	st->st_gid = stx->gid;
	if ((uint64_t)st->st_uid != stx->uid ||
	    (uint64_t)st->st_gid != stx->gid)
		return -1;
	st->st_size = stx->size;
	if (st->st_size < 0 || (uint64_t)st->st_size != stx->size)
		return -1;
	st->st_mtim.tv_sec = stx->mtime.tv_sec;
	st->st_mtim.tv_nsec = stx->mtime.tv_nsec;
	st->st_ctim.tv_sec = stx->ctime.tv_sec;
	st->st_ctim.tv_nsec = stx->ctime.tv_nsec;
	if ((int64_t)st->st_mtim.tv_sec != stx->mtime.tv_sec ||
	    (int64_t)st->st_ctim.tv_sec != stx->ctime.tv_sec)
		return -1;
	return 0;
}

int preload_bulk_linux_entry_stat(struct preload_bulk_worker *worker,
				  int dirfd, const char *name,
				  struct preload_linux_statx *stx,
				  struct stat *st)
{
	struct preload_bulk_linux_data *data =
		worker->scan->platform_data;

	if (preload_bulk_linux_statx_raw(
		    dirfd, name,
		    PRELOAD_AT_SYMLINK_NOFOLLOW | PRELOAD_AT_NO_AUTOMOUNT,
		    stx))
		return -1;
	if (!preload_bulk_linux_statx_complete(stx)) {
		errno = EOPNOTSUPP;
		return -1;
	}
	if (stx->mnt_id != data->root_mnt_id) {
		errno = EXDEV;
		return -1;
	}
	if (statx_to_stat(stx, st)) {
		errno = EOVERFLOW;
		return -1;
	}
	return 0;
}

int preload_bulk_linux_fd_stat(struct preload_bulk_worker *worker, int fd,
			       struct preload_linux_statx *stx,
			       struct stat *st)
{
	struct preload_bulk_linux_data *data =
		worker->scan->platform_data;

	if (preload_bulk_linux_statx_raw(fd, "", PRELOAD_AT_EMPTY_PATH,
					 stx))
		return -1;
	if (!preload_bulk_linux_statx_complete(stx)) {
		errno = EOPNOTSUPP;
		return -1;
	}
	if (stx->mnt_id != data->root_mnt_id) {
		errno = EXDEV;
		return -1;
	}
	if (statx_to_stat(stx, st)) {
		errno = EOVERFLOW;
		return -1;
	}
	return 0;
}

#endif /* SYS_getdents64 && SYS_statx */

#endif /* __linux__ */
