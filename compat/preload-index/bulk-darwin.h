#ifndef PRELOAD_INDEX_BULK_DARWIN_H
#define PRELOAD_INDEX_BULK_DARWIN_H

#ifdef __APPLE__

#include <sys/mount.h>

struct preload_bulk_scan;

struct preload_bulk_darwin_data {
	struct stat root_stat;
	fsid_t root_fsid;
};

/*
 * Exposed so that tests can validate kernel-supplied records directly.
 */
int preload_bulk_darwin_decode_record(const char *record, size_t len);
int preload_bulk_darwin_fd_on_root_mount(struct preload_bulk_scan *scan,
					 int fd, struct stat *st_out);
const char *preload_bulk_darwin_open_root(struct preload_bulk_scan *scan);
const char *preload_bulk_darwin_snapshot_root(struct preload_bulk_scan *scan);
const char *preload_bulk_darwin_validate_root(struct preload_bulk_scan *scan);
void preload_bulk_darwin_release(struct preload_bulk_scan *scan);

#endif /* __APPLE__ */

#endif /* PRELOAD_INDEX_BULK_DARWIN_H */
