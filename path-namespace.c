#include "git-compat-util.h"
#include "abspath.h"
#include "hash.h"
#include "hash-framing.h"
#include "path-namespace.h"
#include "strbuf.h"

enum namespace_entry_state {
	NAMESPACE_ENTRY_MISSING = 0,
	NAMESPACE_ENTRY_PRESENT = 1,
};

struct stat_fingerprint {
	struct path_stat_identity identity;
	unsigned int state;
};

struct path_namespace_snapshot {
	struct stat_fingerprint *entries;
	size_t nr;
	size_t alloc;
};

void path_stat_identity_init(struct path_stat_identity *identity,
			     const struct stat *st)
{
	memset(identity, 0, sizeof(*identity));
	identity->fields[0] = st->st_dev;
	identity->fields[1] = st->st_ino;
	identity->fields[2] = st->st_mode;
	identity->fields[3] = st->st_nlink;
	identity->fields[4] = st->st_uid;
	identity->fields[5] = st->st_gid;
	identity->fields[6] = st->st_size;
	identity->fields[7] = st->st_mtime;
#ifdef __APPLE__
	identity->fields[8] = st->st_mtimespec.tv_nsec;
#else
	identity->fields[8] = ST_MTIME_NSEC(*st);
#endif
	identity->fields[9] = st->st_ctime;
#ifdef __APPLE__
	identity->fields[10] = st->st_ctimespec.tv_nsec;
#else
	identity->fields[10] = ST_CTIME_NSEC(*st);
#endif
#ifdef __APPLE__
	identity->fields[11] = st->st_birthtimespec.tv_sec;
	identity->fields[12] = st->st_birthtimespec.tv_nsec;
	identity->fields[13] = st->st_gen;
#endif
}

int path_stat_identity_equal(const struct path_stat_identity *a,
			     const struct path_stat_identity *b)
{
	return !memcmp(a, b, sizeof(*a));
}

static void stat_fingerprint_init(struct stat_fingerprint *fingerprint,
				  const struct stat *st)
{
	memset(fingerprint, 0, sizeof(*fingerprint));
	fingerprint->state = NAMESPACE_ENTRY_PRESENT;
	path_stat_identity_init(&fingerprint->identity, st);
	if (S_ISDIR(st->st_mode)) {
		/* Unrelated children do not change which object a path names. */
		fingerprint->identity.fields[3] = 0;
		fingerprint->identity.fields[6] = 0;
		for (size_t i = 7; i <= 10; i++)
			fingerprint->identity.fields[i] = 0;
	}
}

static int stat_fingerprint_equal(const struct stat_fingerprint *a,
				  const struct stat_fingerprint *b)
{
	return a->state == b->state &&
		path_stat_identity_equal(&a->identity, &b->identity);
}

static int capture_entry(const char *path,
			 struct path_namespace_snapshot *snapshot)
{
	struct stat st;
	struct stat_fingerprint *entry;

	ALLOC_GROW(snapshot->entries, snapshot->nr + 1, snapshot->alloc);
	entry = &snapshot->entries[snapshot->nr++];
	memset(entry, 0, sizeof(*entry));
	if (!lstat(path, &st)) {
		stat_fingerprint_init(entry, &st);
		return 0;
	}
	if (errno == ENOENT || errno == ENOTDIR) {
		entry->state = NAMESPACE_ENTRY_MISSING;
		return 0;
	}
	return -1;
}

int path_namespace_capture(const char *path,
			   struct path_namespace_snapshot **snapshot_out)
{
	struct path_namespace_snapshot *snapshot;
	struct strbuf prefix = STRBUF_INIT;
	size_t root_len, pos;
	int ret = -1;

	if (!fstat_is_reliable()) {
		errno = EAGAIN;
		return -1;
	}

	CALLOC_ARRAY(snapshot, 1);
	root_len = offset_1st_component(path);
	if (!root_len)
		goto done;
	strbuf_add(&prefix, path, root_len);
	if (capture_entry(prefix.buf, snapshot))
		goto done;
	pos = root_len;
	while (path[pos]) {
		size_t start, end;

		while (path[pos] && is_dir_sep(path[pos]))
			pos++;
		if (!path[pos])
			break;
		start = pos;
		while (path[pos] && !is_dir_sep(path[pos]))
			pos++;
		end = pos;
		strbuf_complete(&prefix, '/');
		strbuf_add(&prefix, path + start, end - start);
		if (capture_entry(prefix.buf, snapshot))
			goto done;
	}
	*snapshot_out = snapshot;
	snapshot = NULL;
	ret = 0;
done:
	path_namespace_clear(snapshot);
	strbuf_release(&prefix);
	return ret;
}

int path_namespace_equal(const struct path_namespace_snapshot *a,
			 const struct path_namespace_snapshot *b)
{
	if (a->nr != b->nr)
		return 0;
	for (size_t i = 0; i < a->nr; i++)
		if (!stat_fingerprint_equal(&a->entries[i], &b->entries[i]))
			return 0;
	return 1;
}

int path_namespace_target_present(
	const struct path_namespace_snapshot *snapshot)
{
	return snapshot->nr &&
		snapshot->entries[snapshot->nr - 1].state ==
			NAMESPACE_ENTRY_PRESENT;
}

void path_namespace_hash(struct git_hash_ctx *ctx,
			 const struct path_namespace_snapshot *snapshot)
{
	uint32_t value;
	uint64_t field;

	put_be32(&value, snapshot->nr);
	hash_length_delimited(ctx, &value, sizeof(value));
	for (size_t i = 0; i < snapshot->nr; i++) {
		put_be32(&value, snapshot->entries[i].state);
		hash_length_delimited(ctx, &value, sizeof(value));
		for (size_t j = 0;
		     j < ARRAY_SIZE(snapshot->entries[i].identity.fields); j++) {
			put_be64(&field,
				 snapshot->entries[i].identity.fields[j]);
			hash_length_delimited(ctx, &field, sizeof(field));
		}
	}
}

int path_namespace_stat_equal(const struct stat *a, const struct stat *b)
{
	struct path_stat_identity first, second;

	path_stat_identity_init(&first, a);
	path_stat_identity_init(&second, b);
	return path_stat_identity_equal(&first, &second);
}

int path_namespace_reopen_component(
	int parent_fd, const char *component, int flags,
	path_namespace_open_fn open_fn, const struct stat *expected)
{
	struct stat reopened;
	int fd, saved_errno;

	if (!open_fn || !component || !*component ||
	    !strcmp(component, ".") || !strcmp(component, "..")) {
		errno = EINVAL;
		return -1;
	}
	for (const char *p = component; *p; p++) {
		if (is_dir_sep(*p)) {
			errno = EINVAL;
			return -1;
		}
	}
	if (!fstat_is_reliable()) {
		errno = EAGAIN;
		return -1;
	}

	fd = open_fn(parent_fd, component, flags);
	if (fd < 0)
		return -1;
	if (fstat(fd, &reopened)) {
		saved_errno = errno;
		goto error;
	}
	if (!path_namespace_stat_equal(expected, &reopened)) {
		saved_errno = EAGAIN;
		goto error;
	}
	return close(fd);

error:
	close(fd);
	errno = saved_errno;
	return -1;
}

void path_namespace_clear(struct path_namespace_snapshot *snapshot)
{
	if (!snapshot)
		return;
	free(snapshot->entries);
	free(snapshot);
}
