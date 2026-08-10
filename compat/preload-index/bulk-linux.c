#include "git-compat-util.h"

#ifdef __linux__

#include <sys/syscall.h>

#include "compat/preload-index/bulk-linux.h"
#include "preload-index-bulk.h"

#if defined(SYS_getdents64) && defined(SYS_statx)

static const struct preload_bulk_backend linux_backend = {
	.collects_untracked = 1,
	.max_threads = 16,
	.start = preload_bulk_linux_start,
	.finish = preload_bulk_linux_finish,
	.release = preload_bulk_linux_release,
	.open_proof_parent = preload_bulk_linux_open_relative,
	.open_dir_at = preload_bulk_linux_open_dir_at,
	.scan_directory = preload_bulk_linux_scan_directory,
};

const struct preload_bulk_backend *preload_bulk_platform_backend(void)
{
	return &linux_backend;
}

#else /* !SYS_getdents64 || !SYS_statx */

const struct preload_bulk_backend *preload_bulk_platform_backend(void)
{
	return NULL;
}

#endif

#endif /* __linux__ */
