#ifndef PRELOAD_INDEX_BULK_LINUX_H
#define PRELOAD_INDEX_BULK_LINUX_H

#ifdef __linux__

#include <sys/syscall.h>

#include "strbuf.h"

#define PRELOAD_AT_NO_AUTOMOUNT 0x800
#define PRELOAD_AT_EMPTY_PATH 0x1000
#define PRELOAD_AT_SYMLINK_NOFOLLOW 0x100
#define PRELOAD_STATX_BASIC_STATS 0x000007ffU
#define PRELOAD_STATX_MNT_ID 0x00001000U
#define PRELOAD_RESOLVE_NO_XDEV 0x01
#define PRELOAD_RESOLVE_NO_MAGICLINKS 0x02
#define PRELOAD_RESOLVE_NO_SYMLINKS 0x04
#define PRELOAD_RESOLVE_BENEATH 0x08

struct preload_linux_statx_timestamp {
	int64_t tv_sec;
	uint32_t tv_nsec;
	int32_t reserved;
};

struct preload_linux_statx {
	uint32_t mask;
	uint32_t blksize;
	uint64_t attributes;
	uint32_t nlink;
	uint32_t uid;
	uint32_t gid;
	uint16_t mode;
	uint16_t spare0;
	uint64_t ino;
	uint64_t size;
	uint64_t blocks;
	uint64_t attributes_mask;
	struct preload_linux_statx_timestamp atime;
	struct preload_linux_statx_timestamp btime;
	struct preload_linux_statx_timestamp ctime;
	struct preload_linux_statx_timestamp mtime;
	uint32_t rdev_major;
	uint32_t rdev_minor;
	uint32_t dev_major;
	uint32_t dev_minor;
	uint64_t mnt_id;
	uint32_t dio_mem_align;
	uint32_t dio_offset_align;
	uint64_t spare3[12];
};

struct preload_linux_open_how {
	uint64_t flags;
	uint64_t mode;
	uint64_t resolve;
};

struct preload_bulk_linux_data {
	struct preload_linux_statx root_statx;
	struct strbuf mountinfo;
	uint64_t root_mnt_id;
	char *test_dirent_path;
	unsigned char test_dirent_type;
	int use_openat2;
};

struct preload_bulk_scan;
struct preload_bulk_task;
struct preload_bulk_worker;
struct preload_bulk_dir_identity;

#if defined(SYS_getdents64) && defined(SYS_statx)

int preload_bulk_linux_statx_raw(int dirfd, const char *path, int flags,
				 struct preload_linux_statx *stx);
int preload_bulk_linux_statx_complete(
	const struct preload_linux_statx *stx);
int preload_bulk_linux_statx_same(const struct preload_linux_statx *a,
				  const struct preload_linux_statx *b);
int preload_bulk_linux_entry_stat(struct preload_bulk_worker *worker,
				  int dirfd, const char *name,
				  struct preload_linux_statx *stx,
				  struct stat *st);
int preload_bulk_linux_fd_stat(struct preload_bulk_worker *worker, int fd,
			       struct preload_linux_statx *stx,
			       struct stat *st);

#ifdef SYS_openat2
int preload_bulk_linux_openat2_raw(int dirfd, const char *path);
#endif
int preload_bulk_linux_open_dir_at(struct preload_bulk_worker *worker,
				   int parent_fd, const char *name);
int preload_bulk_linux_open_relative(struct preload_bulk_scan *scan,
				     const char *path);

int preload_bulk_linux_enumerate(
	struct preload_bulk_worker *worker,
	struct preload_bulk_task *task, int fd,
	const struct preload_bulk_dir_identity *parent_identity);
int preload_bulk_linux_scan_directory(struct preload_bulk_worker *worker,
				      struct preload_bulk_task *task);

const char *preload_bulk_linux_start(struct preload_bulk_scan *scan);
const char *preload_bulk_linux_finish(struct preload_bulk_scan *scan);
void preload_bulk_linux_release(struct preload_bulk_scan *scan);

#endif /* SYS_getdents64 && SYS_statx */

#endif /* __linux__ */

#endif /* PRELOAD_INDEX_BULK_LINUX_H */
