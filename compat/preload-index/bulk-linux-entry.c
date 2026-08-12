#include "git-compat-util.h"

#ifdef __linux__

#include <dirent.h>
#include <sys/syscall.h>

#include "compat/preload-index/bulk-linux.h"
#include "dir.h"
#include "preload-index-bulk.h"

#define PRELOAD_INDEX_BULK_LINUX_BUFFER_SIZE (1024 * 1024)

struct preload_linux_dirent64 {
	uint64_t ino;
	int64_t off;
	uint16_t reclen;
	uint8_t type;
	char name[FLEX_ARRAY];
};

#if defined(SYS_getdents64) && defined(SYS_statx)

static void record_foreign_entry(struct preload_bulk_worker *worker,
				 const char *path, size_t path_len,
				 int pos, mode_t mode)
{
	if (pos >= 0)
		preload_bulk_record_tracked_fallback(worker, pos);
	if (S_ISDIR(mode))
		preload_bulk_record_tracked_descendants_fallback(
			worker, path, path_len);
	if (worker->scan->collect_untracked)
		preload_bulk_invalidate_untracked(worker);
}

static void handle_directory(
	struct preload_bulk_worker *worker,
	const struct preload_bulk_task *task, int fd,
	const struct preload_bulk_dir_identity *parent_identity,
	const char *name, int pos)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct preload_bulk_untracked_root *untracked_root =
		task->untracked_root;
	int has_tracked_descendants;

	if (pos >= 0) {
		if (scan->collect_untracked &&
		    preload_bulk_index_entry_is_gitlink(scan, pos))
			return;
		preload_bulk_record_tracked_fallback(worker, pos);
		return;
	}
	has_tracked_descendants =
		preload_bulk_index_pos_has_tracked_descendants(
			scan, worker->path.buf, worker->path.len, pos);
	if (!has_tracked_descendants &&
	    preload_bulk_record_tracked_alias_fallback(
		    worker, worker->path.buf, worker->path.len)) {
		if (scan->collect_untracked)
			preload_bulk_invalidate_untracked(worker);
		return;
	}
	if (!has_tracked_descendants) {
		if (!scan->collect_untracked ||
		    preload_bulk_untracked_is_invalid(worker) ||
		    preload_bulk_untracked_root_is_visible(
			    worker, untracked_root) ||
		    preload_bulk_path_is_excluded(
			    worker, worker->path.buf, DT_DIR))
			return;
		if (!untracked_root)
			untracked_root = preload_bulk_untracked_root_new(
				worker, worker->path.buf, worker->path.len);
	}
	preload_bulk_schedule_directory(
		worker, fd, parent_identity, NULL, untracked_root,
		name, worker->path.buf, worker->path.len);
}

static void record_untracked(struct preload_bulk_worker *worker,
			     const struct preload_bulk_task *task,
			     int dtype)
{
	struct preload_bulk_scan *scan = worker->scan;

	if (!scan->collect_untracked ||
	    preload_bulk_untracked_is_invalid(worker))
		return;
	if (preload_bulk_record_tracked_alias_fallback(
		    worker, worker->path.buf, worker->path.len)) {
		preload_bulk_invalidate_untracked(worker);
		return;
	}
	if (!preload_bulk_path_is_excluded(
		    worker, worker->path.buf, dtype))
		preload_bulk_record_untracked(
			worker, task->untracked_root, worker->path.buf);
}

int preload_bulk_linux_enumerate(
	struct preload_bulk_worker *worker,
	struct preload_bulk_task *task, int fd,
	const struct preload_bulk_dir_identity *parent_identity)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct preload_bulk_linux_data *data = scan->platform_data;
	char *buf = worker->buffer;
	size_t path_prefix_len;

	if (!buf) {
		buf = xmalloc(PRELOAD_INDEX_BULK_LINUX_BUFFER_SIZE);
		worker->buffer = buf;
	}
	worker->dirs++;
	strbuf_reset(&worker->path);
	if (strcmp(task->path, ".")) {
		strbuf_addstr(&worker->path, task->path);
		strbuf_addch(&worker->path, '/');
	}
	path_prefix_len = worker->path.len;

	for (;;) {
		long bytes = syscall(SYS_getdents64, fd, buf,
				     PRELOAD_INDEX_BULK_LINUX_BUFFER_SIZE);
		size_t offset = 0;

		worker->bulk_calls++;
		if (bytes < 0)
			return -1;
		if (!bytes)
			return 0;
		while (offset < (size_t)bytes) {
			struct preload_linux_dirent64 *de =
				(void *)(buf + offset);
			size_t minimum =
				offsetof(struct preload_linux_dirent64, name) + 1;
			size_t name_space;
			struct preload_linux_statx stx;
			struct stat st;
			char *nul;
			unsigned char dtype;
			int has_tracked_descendants = 0, pos;

			if (scan->collect_untracked &&
			    preload_bulk_untracked_root_is_visible(
				    worker, task->untracked_root))
				return 0;
			if ((size_t)bytes - offset < minimum ||
			    de->reclen < minimum ||
			    de->reclen > (size_t)bytes - offset)
				goto malformed;
			name_space = de->reclen -
				offsetof(struct preload_linux_dirent64, name);
			nul = memchr(de->name, '\0', name_space);
			if (!nul || nul == de->name ||
			    memchr(de->name, '/', nul - de->name))
				goto malformed;
			offset += de->reclen;
			if (is_dot_or_dotdot(de->name))
				continue;
			worker->entries++;
			if (!fspathcmp(de->name, ".git")) {
				if (strcmp(task->path, ".") &&
				    scan->collect_untracked)
					preload_bulk_invalidate_untracked(
						worker);
				continue;
			}

			strbuf_setlen(&worker->path, path_prefix_len);
			strbuf_addstr(&worker->path, de->name);
			if (worker->path.len > INT_MAX)
				goto malformed;
			pos = preload_bulk_index_position(
				scan, worker->path.buf, worker->path.len);
			dtype = de->type;
			if (data->test_dirent_path &&
			    !strcmp(data->test_dirent_path, worker->path.buf))
				dtype = data->test_dirent_type;

			/*
			 * Exact tracked paths always reach statx. A directory
			 * which may contain tracked descendants can be
			 * scheduled directly: the O_DIRECTORY open and
			 * descriptor statx remain authoritative.
			 *
			 * A hint cannot classify a wholly untracked entry:
			 * file-versus-directory changes exclude matching and
			 * result shape. Force those entries through statx before
			 * taking either shortcut.
			 */
			if (pos < 0 && dtype != DT_UNKNOWN)
				has_tracked_descendants =
					preload_bulk_index_pos_has_tracked_descendants(
						scan, worker->path.buf,
						worker->path.len, pos);
			if (scan->collect_untracked && pos < 0 &&
			    !has_tracked_descendants)
				dtype = DT_UNKNOWN;
			if (dtype == DT_DIR && pos < 0) {
				handle_directory(worker, task, fd,
						 parent_identity,
						 de->name, pos);
				continue;
			}
			if (pos < 0 && !has_tracked_descendants &&
			    (dtype == DT_REG || dtype == DT_LNK)) {
				record_untracked(
					worker, task,
					dtype == DT_LNK ? DT_LNK : DT_REG);
				continue;
			}
			if (pos < 0 && !has_tracked_descendants &&
			    dtype != DT_UNKNOWN) {
				preload_bulk_record_tracked_alias_fallback(
					worker, worker->path.buf,
					worker->path.len);
				continue;
			}
			if (preload_bulk_linux_entry_stat(
				    worker, fd, de->name, &stx, &st)) {
				if (errno == EXDEV) {
					record_foreign_entry(
						worker, worker->path.buf,
						worker->path.len, pos,
						stx.mode);
					continue;
				}
				goto malformed;
			}
			if (S_ISDIR(st.st_mode)) {
				handle_directory(worker, task, fd,
						 parent_identity,
						 de->name, pos);
				continue;
			}
			if (pos < 0) {
				if (S_ISREG(st.st_mode))
					record_untracked(worker, task, DT_REG);
				else if (S_ISLNK(st.st_mode))
					record_untracked(worker, task, DT_LNK);
				else
					preload_bulk_record_tracked_alias_fallback(
						worker, worker->path.buf,
						worker->path.len);
				continue;
			}
			if ((!S_ISREG(st.st_mode) && !S_ISLNK(st.st_mode)) ||
			    st.st_nlink != 1) {
				preload_bulk_record_tracked_fallback(
					worker, pos);
				continue;
			}
			preload_bulk_record_tracked(
				worker, pos, fd, de->name, &st, 0);
		}
	}

malformed:
	worker->malformed++;
	return -1;
}

#endif /* SYS_getdents64 && SYS_statx */

#endif /* __linux__ */
