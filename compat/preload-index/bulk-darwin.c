#include "git-compat-util.h"

#include <sys/attr.h>
#include <sys/utsname.h>
#include <sys/vnode.h>

#include "compat/precompose_utf8.h"
#include "compat/preload-index/bulk-darwin.h"
#include "path-namespace.h"
#include "preload-index-bulk.h"

#ifndef SF_FIRMLINK
#define SF_FIRMLINK 0x00800000
#endif

#define PRELOAD_INDEX_BULK_BUFFER_SIZE (1024 * 1024)

static const attrgroup_t required_common =
	ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME |
	ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE |
	ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME |
	ATTR_CMN_OWNERID | ATTR_CMN_GRPID | ATTR_CMN_ACCESSMASK |
	ATTR_CMN_FLAGS | ATTR_CMN_FILEID;
static const attrgroup_t required_dir = ATTR_DIR_MOUNTSTATUS;
static const attrgroup_t required_file =
	ATTR_FILE_LINKCOUNT | ATTR_FILE_DATALENGTH;

static int valid_component(const char *component, size_t len)
{
	return len &&
		!(len == 1 && component[0] == '.') &&
		!(len == 2 && component[0] == '.' && component[1] == '.');
}

static int valid_relative_path(const char *path)
{
	const char *component = path;

	if (!strcmp(path, "."))
		return 1;
	if (!*path || *path == '/')
		return 0;
	for (;;) {
		const char *slash = strchr(component, '/');
		size_t len = slash ? (size_t)(slash - component) :
			strlen(component);

		if (!valid_component(component, len))
			return 0;
		if (!slash)
			return 1;
		component = slash + 1;
	}
}

static int preload_bulk_darwin_open_dir_at(
	struct preload_bulk_worker *worker UNUSED,
	int parent_fd, const char *name)
{
	if (!valid_component(name, strlen(name)) || strchr(name, '/')) {
		errno = EINVAL;
		return -1;
	}
	return openat(parent_fd, name,
		      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

int preload_bulk_darwin_supports_nofollow_any(void)
{
#ifdef O_NOFOLLOW_ANY
	struct utsname uts;
	char *end;
	unsigned long major;

	/*
	 * O_NOFOLLOW_ANY arrived in Darwin 20. Older kernels accept the
	 * same bit as O_ALERT without enforcing no-follow semantics.
	 */
	if (uname(&uts) || !isdigit((unsigned char)uts.release[0]))
		return 0;
	errno = 0;
	major = strtoul(uts.release, &end, 10);
	return !errno && end != uts.release && *end == '.' && major >= 20;
#else
	return 0;
#endif
}

static int preload_bulk_darwin_open_relative(struct preload_bulk_scan *scan,
					     const char *path)
{
	if (!valid_relative_path(path)) {
		errno = EINVAL;
		return -1;
	}

#ifdef O_NOFOLLOW_ANY
	return openat(scan->root_fd, path,
		      O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC);
#else
	errno = ENOTSUP;
	return -1;
#endif
}

static mode_t vnode_mode(fsobj_type_t type)
{
	switch (type) {
	case VREG:
		return S_IFREG;
	case VLNK:
		return S_IFLNK;
	default:
		return 0;
	}
}

static int fill_file_stat(struct stat *st, dev_t dev, uint64_t fileid,
			  fsobj_type_t type, struct timespec mtime,
			  struct timespec ctime, uid_t uid, gid_t gid,
			  uint32_t access, uint32_t linkcount, off_t size)
{
	mode_t mode = vnode_mode(type);

	if (!mode || size < 0 ||
	    ((access & S_IFMT) && (access & S_IFMT) != mode) ||
	    (access & ~(S_IFMT | 07777)))
		return -1;
	memset(st, 0, sizeof(*st));
	st->st_dev = dev;
	st->st_ino = fileid;
	st->st_mode = mode | (access & 07777);
	st->st_uid = uid;
	st->st_gid = gid;
	st->st_nlink = linkcount;
	st->st_size = size;
	st->st_mtimespec = mtime;
	st->st_ctimespec = ctime;
	return 0;
}

struct preload_bulk_darwin_entry {
	const char *name;
	uint32_t record_len;
	dev_t dev;
	fsobj_type_t type;
	struct timespec birthtime;
	struct timespec mtime;
	struct timespec ctime;
	uid_t uid;
	gid_t gid;
	uint32_t access;
	uint32_t flags;
	uint32_t linkcount;
	uint32_t mountstatus;
	uint64_t fileid;
	off_t size;
};

static int decode_entry(const char *record, size_t remaining,
			struct preload_bulk_darwin_entry *entry)
{
	uint32_t entry_error = 0;
	attribute_set_t returned;
	attrreference_t name_ref;
	const char *p, *end, *name_ref_at;
	size_t name_ref_offset, name_offset, name_remaining;

	if (remaining < sizeof(entry->record_len) + sizeof(returned))
		return -1;
	memcpy(&entry->record_len, record, sizeof(entry->record_len));
	if ((entry->record_len % sizeof(uint64_t)) ||
	    entry->record_len < sizeof(entry->record_len) + sizeof(returned) ||
	    entry->record_len > remaining)
		return -1;

	p = record + sizeof(entry->record_len);
	end = record + entry->record_len;
	memcpy(&returned, p, sizeof(returned));
	p += sizeof(returned);
	if (returned.commonattr != required_common ||
	    returned.volattr || returned.forkattr)
		return -1;

#define TAKE_ATTR(value) do { \
	if ((size_t)(end - p) < sizeof(value)) \
		return -1; \
	memcpy(&(value), p, sizeof(value)); \
	p += sizeof(value); \
} while (0)
	TAKE_ATTR(entry_error);
	if (entry_error)
		return -1;
	name_ref_at = p;
	TAKE_ATTR(name_ref);
	TAKE_ATTR(entry->dev);
	TAKE_ATTR(entry->type);
	TAKE_ATTR(entry->birthtime);
	TAKE_ATTR(entry->mtime);
	TAKE_ATTR(entry->ctime);
	TAKE_ATTR(entry->uid);
	TAKE_ATTR(entry->gid);
	TAKE_ATTR(entry->access);
	TAKE_ATTR(entry->flags);
	TAKE_ATTR(entry->fileid);

	if (entry->type == VDIR) {
		if (returned.dirattr != required_dir ||
		    returned.fileattr)
			return -1;
		TAKE_ATTR(entry->mountstatus);
	} else {
		if (returned.dirattr ||
		    (returned.fileattr & ~required_file))
			return -1;
		TAKE_ATTR(entry->linkcount);
		TAKE_ATTR(entry->size);
		if ((entry->type == VREG || entry->type == VLNK) &&
		    returned.fileattr != required_file)
			return -1;
	}
#undef TAKE_ATTR

	if (name_ref.attr_dataoffset < 0 ||
	    (name_ref.attr_dataoffset % (int32_t)sizeof(uint32_t)))
		return -1;
	name_ref_offset = name_ref_at - record;
	if ((uint32_t)name_ref.attr_dataoffset >
	    entry->record_len - name_ref_offset)
		return -1;
	name_offset = name_ref_offset + name_ref.attr_dataoffset;
	name_remaining = entry->record_len - name_offset;
	entry->name = record + name_offset;
	if (!name_ref.attr_length ||
	    name_ref.attr_length > name_remaining ||
	    entry->name < p)
		return -1;
	if (entry->name[name_ref.attr_length - 1] ||
	    memchr(entry->name, '\0', name_ref.attr_length - 1) ||
	    !valid_component(entry->name, name_ref.attr_length - 1) ||
	    memchr(entry->name, '/', name_ref.attr_length - 1))
		return -1;
	return 0;
}

int preload_bulk_darwin_decode_record(const char *record, size_t len)
{
	struct preload_bulk_darwin_entry entry;

	return decode_entry(record, len, &entry);
}

static struct preload_bulk_dir_identity directory_identity(
	const struct stat *st)
{
	struct preload_bulk_dir_identity result = {
		.stat = *st,
		.complete = 1,
	};

	return result;
}

static int directory_identity_matches(
	const struct preload_bulk_dir_identity *before,
	const struct stat *after)
{
	if (before->complete)
		return path_namespace_stat_equal(&before->stat, after);
	return S_ISDIR(after->st_mode) &&
		before->stat.st_dev == after->st_dev &&
		before->stat.st_ino == after->st_ino &&
		before->stat.st_birthtimespec.tv_sec ==
			after->st_birthtimespec.tv_sec &&
		before->stat.st_birthtimespec.tv_nsec ==
			after->st_birthtimespec.tv_nsec &&
		before->stat.st_mtimespec.tv_sec == after->st_mtimespec.tv_sec &&
		before->stat.st_mtimespec.tv_nsec ==
			after->st_mtimespec.tv_nsec &&
		before->stat.st_ctimespec.tv_sec == after->st_ctimespec.tv_sec &&
		before->stat.st_ctimespec.tv_nsec ==
			after->st_ctimespec.tv_nsec;
}

static int enumerate_directory(struct preload_bulk_worker *worker,
			       const struct preload_bulk_task *task, int fd,
			       const struct preload_bulk_dir_identity *parent_identity)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct preload_bulk_darwin_data *data = scan->platform_data;
	struct attrlist attrs = { 0 };
	char *buf = worker->buffer;
	size_t path_prefix_len;

	if (!buf) {
		buf = xmalloc(PRELOAD_INDEX_BULK_BUFFER_SIZE);
		worker->buffer = buf;
	}

	attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
	attrs.commonattr = required_common;
	attrs.dirattr = required_dir;
	attrs.fileattr = required_file;
	worker->dirs++;
	strbuf_reset(&worker->path);
	if (strcmp(task->path, ".")) {
		strbuf_addstr(&worker->path, task->path);
		strbuf_addch(&worker->path, '/');
	}
	path_prefix_len = worker->path.len;

	for (;;) {
		int nr = getattrlistbulk(fd, &attrs, buf,
					 PRELOAD_INDEX_BULK_BUFFER_SIZE,
					 FSOPT_NOFOLLOW |
					 FSOPT_PACK_INVAL_ATTRS);
		char *record = buf;

		worker->bulk_calls++;
		if (nr < 0)
			return -1;
		if (!nr)
			return 0;

		for (int i = 0; i < nr; i++) {
			struct preload_bulk_darwin_entry entry;
			struct stat st;
			const char *path_name;
			size_t remaining;
			int pos;

			remaining = buf + PRELOAD_INDEX_BULK_BUFFER_SIZE - record;
			if (decode_entry(record, remaining, &entry))
				goto malformed;
			worker->entries++;

			/*
			 * The caller prepares the repository's Unicode policy
			 * before starting workers, so this is read-only here.
			 */
			path_name = repo_precompose_string_if_needed(scan->repo,
								     entry.name);
			strbuf_setlen(&worker->path, path_prefix_len);
			strbuf_addstr(&worker->path, path_name);
			if (path_name != entry.name)
				free((char *)path_name);

			pos = preload_bulk_index_position(scan, worker->path.buf,
						     worker->path.len);
			if (entry.type == VDIR) {
				struct preload_bulk_dir_identity child_identity = {
					.stat = {
						.st_dev = entry.dev,
						.st_ino = entry.fileid,
						.st_birthtimespec =
							entry.birthtime,
						.st_mtimespec = entry.mtime,
						.st_ctimespec = entry.ctime,
					},
				};

				if (pos >= 0) {
					preload_bulk_record_tracked_fallback(
						worker, pos);
					goto next_record;
				}
				if (!preload_bulk_index_pos_has_tracked_descendants(
					    scan, worker->path.buf,
					    worker->path.len, pos)) {
					preload_bulk_record_tracked_alias_fallback(
						worker, worker->path.buf,
						worker->path.len);
					goto next_record;
				}
				if (((entry.access & S_IFMT) &&
				     (entry.access & S_IFMT) != S_IFDIR) ||
				    (entry.access & ~(S_IFMT | 07777)))
					goto malformed_record;
				if (entry.dev != data->root_stat.st_dev ||
				    entry.mountstatus ||
				    (entry.flags & SF_FIRMLINK)) {
					preload_bulk_record_tracked_descendants_fallback(
						worker, worker->path.buf,
						worker->path.len);
					goto next_record;
				}
				preload_bulk_schedule_directory(
					worker, fd, parent_identity,
					&child_identity, entry.name,
					worker->path.buf,
					worker->path.len);
				goto next_record;
			}

			if (pos < 0) {
				preload_bulk_record_tracked_alias_fallback(
					worker, worker->path.buf,
					worker->path.len);
				goto next_record;
			}
			if (entry.dev != data->root_stat.st_dev) {
				preload_bulk_record_tracked_fallback(
					worker, pos);
				goto next_record;
			}
			if (entry.type != VREG && entry.type != VLNK) {
				preload_bulk_record_tracked_fallback(
					worker, pos);
				goto next_record;
			}
			if (entry.linkcount != 1) {
				preload_bulk_record_tracked_fallback(
					worker, pos);
				goto next_record;
			}
			if (fill_file_stat(&st, entry.dev, entry.fileid,
					   entry.type, entry.mtime, entry.ctime,
					   entry.uid, entry.gid, entry.access,
					   entry.linkcount, entry.size))
				goto malformed_record;
			preload_bulk_record_tracked(worker, pos, &st);

next_record:
			record += entry.record_len;
			continue;

malformed_record:
			worker->malformed++;
			goto next_record;
		}
	}

malformed:
	worker->malformed++;
	return -1;
}

static int scan_directory(struct preload_bulk_worker *worker,
			  struct preload_bulk_task *task)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct preload_bulk_dir_identity before_identity;
	struct stat before, after;
	size_t path_len;
	int fd = task->fd;
	int ret = -1;

	if (fd < 0)
		fd = preload_bulk_darwin_open_relative(scan, task->path);
	if (fd < 0)
		goto out;
	if (preload_bulk_test_barrier(scan, task->path))
		goto out;
	if (preload_bulk_darwin_fd_on_root_mount(scan, fd, &before)) {
		if (errno != EXDEV)
			goto out;
		path_len = strlen(task->path);
		preload_bulk_record_tracked_descendants_fallback(
			worker, task->path, path_len);
		ret = 0;
		goto out;
	}
	/*
	 * A child may have been replaced after its parent returned the bulk
	 * record, or while this task waited in the queue.
	 */
	if (task->has_child_identity &&
	    !directory_identity_matches(&task->child_identity, &before)) {
		worker->changed_dirs++;
		ret = 0;
		goto out;
	}
	before_identity = directory_identity(&before);
	if (enumerate_directory(worker, task, fd, &before_identity))
		goto out;
	if (fstat(fd, &after))
		goto out;
	if (!directory_identity_matches(&before_identity, &after))
		worker->changed_dirs++;
	ret = 0;

out:
	if (task->has_parent_identity) {
		struct stat parent_after;
		int parent_changed = fd < 0;

		/*
		 * Resolve ".." through the child descriptor, not the worktree
		 * path, so a rename cannot redirect this parent check.
		 */
		if (!parent_changed)
			parent_changed = fstatat(fd, "..", &parent_after,
						 AT_SYMLINK_NOFOLLOW);
		if (parent_changed ||
		    !directory_identity_matches(&task->parent_identity,
						&parent_after))
			worker->changed_dirs++;
	}
	if (fd >= 0)
		close(fd);
	return ret;
}

static const char *start_scan(struct preload_bulk_scan *scan)
{
	const char *error;

	repo_precompose_utf8_prepare(scan->repo);
	error = preload_bulk_darwin_open_root(scan);
	if (error)
		return error;
	return preload_bulk_darwin_snapshot_root(scan);
}

static const char *finish_scan(struct preload_bulk_scan *scan)
{
	return preload_bulk_darwin_validate_root(scan);
}

static const struct preload_bulk_backend darwin_backend = {
	.start = start_scan,
	.finish = finish_scan,
	.release = preload_bulk_darwin_release,
	.open_dir_at = preload_bulk_darwin_open_dir_at,
	.scan_directory = scan_directory,
};

const struct preload_bulk_backend *preload_bulk_platform_backend(void)
{
#ifdef O_NOFOLLOW_ANY
	if (preload_bulk_darwin_supports_nofollow_any())
		return &darwin_backend;
#endif
	return NULL;
}
