#include "git-compat-util.h"
#include "attr-manifest.h"
#include "environment.h"
#include "read-cache-ll.h"
#include "strbuf.h"

/*
 * A manifest begins with a 32-bit entry count. Each entry contains a 32-bit
 * path length, four bytes of source metadata, an object-format hash, and the
 * unterminated path. Paths are strictly increasing.
 */
static int attr_manifest_path_valid(const unsigned char *path, size_t len)
{
	const char *base;
	char *copy;
	int valid;

	if (!len || path[0] == '/' || memchr(path, '\0', len))
		return 0;
	copy = xmemdupz(path, len);
	base = strrchr(copy, '/');
	base = base ? base + 1 : copy;
	valid = !strcmp(base, GITATTRIBUTES_FILE) &&
		verify_path(copy, S_IFREG | 0644);
	free(copy);
	return valid;
}

static int attr_manifest_entry_cmp(const struct attr_manifest_entry *a,
				   const struct attr_manifest_entry *b)
{
	size_t common = a->path_len < b->path_len ? a->path_len : b->path_len;
	int cmp = memcmp(a->path, b->path, common);

	if (cmp)
		return cmp;
	return a->path_len < b->path_len ? -1 : a->path_len > b->path_len;
}

void attr_manifest_writer_init(struct attr_manifest_writer *writer,
			       struct strbuf *buf,
			       const struct git_hash_algo *algo)
{
	uint32_t count;

	if (!algo)
		BUG("attribute manifest requires a hash algorithm");
	memset(writer, 0, sizeof(*writer));
	writer->buf = buf;
	writer->algo = algo;
	strbuf_reset(buf);
	put_be32(&count, 0);
	strbuf_add(buf, &count, sizeof(count));
}

int attr_manifest_writer_add(struct attr_manifest_writer *writer,
			     const char *path,
			     enum attr_manifest_source source,
			     const unsigned char *hash)
{
	struct attr_manifest_entry previous, current;
	unsigned char metadata[4] = { source, 0, 0, 0 };
	uint32_t path_len_be;
	size_t entry_offset, path_len = strlen(path);

	if (!writer->buf || !writer->algo || !hash || !path_len ||
	    path_len > UINT32_MAX || writer->nr == UINT32_MAX ||
	    (source != ATTR_MANIFEST_WORKTREE &&
	     source != ATTR_MANIFEST_INDEX) ||
	    !attr_manifest_path_valid((const unsigned char *)path, path_len))
		return -1;

	current.path = (const unsigned char *)path;
	current.path_len = path_len;
	if (writer->nr) {
		previous.path = (const unsigned char *)writer->buf->buf +
			writer->last_path_offset;
		previous.path_len = writer->last_path_len;
		if (attr_manifest_entry_cmp(&previous, &current) >= 0)
			return -1;
	}

	entry_offset = writer->buf->len;
	put_be32(&path_len_be, path_len);
	strbuf_add(writer->buf, &path_len_be, sizeof(path_len_be));
	strbuf_add(writer->buf, metadata, sizeof(metadata));
	strbuf_add(writer->buf, hash, writer->algo->rawsz);
	strbuf_add(writer->buf, path, path_len);
	writer->last_path_offset = entry_offset + sizeof(path_len_be) +
		sizeof(metadata) + writer->algo->rawsz;
	writer->last_path_len = path_len;
	put_be32(writer->buf->buf, ++writer->nr);
	return 0;
}

int attr_manifest_cursor_init(struct attr_manifest_cursor *cursor,
			      const void *data, size_t len,
			      const struct git_hash_algo *algo)
{
	const unsigned char *bytes = data;
	size_t minimum_entry_size;

	if (!algo)
		BUG("attribute manifest requires a hash algorithm");
	if (len < sizeof(uint32_t))
		return -1;
	minimum_entry_size = sizeof(uint32_t) + 4 + algo->rawsz + 1;
	cursor->p = bytes + sizeof(uint32_t);
	cursor->end = bytes + len;
	cursor->last_path = NULL;
	cursor->algo = algo;
	cursor->last_path_len = 0;
	cursor->remaining = get_be32(bytes);
	if (cursor->remaining >
	    (len - sizeof(uint32_t)) / minimum_entry_size)
		return -1;
	return 0;
}

int attr_manifest_cursor_next(struct attr_manifest_cursor *cursor,
			      struct attr_manifest_entry *entry)
{
	struct attr_manifest_entry previous;
	uint32_t path_len;
	size_t available;

	if (!cursor->remaining)
		return cursor->p == cursor->end ? 0 : -1;
	available = cursor->end - cursor->p;
	if (available < sizeof(uint32_t) + 4 + cursor->algo->rawsz)
		return -1;
	path_len = get_be32(cursor->p);
	cursor->p += sizeof(uint32_t);
	entry->source = cursor->p[0];
	if ((entry->source != ATTR_MANIFEST_WORKTREE &&
	     entry->source != ATTR_MANIFEST_INDEX) ||
	    cursor->p[1] || cursor->p[2] || cursor->p[3])
		return -1;
	cursor->p += 4;
	entry->hash = cursor->p;
	cursor->p += cursor->algo->rawsz;
	available = cursor->end - cursor->p;
	if (!path_len || available < path_len ||
	    !attr_manifest_path_valid(cursor->p, path_len))
		return -1;
	entry->path = cursor->p;
	entry->path_len = path_len;
	if (cursor->last_path) {
		previous.path = cursor->last_path;
		previous.path_len = cursor->last_path_len;
		if (attr_manifest_entry_cmp(&previous, entry) >= 0)
			return -1;
	}
	cursor->last_path = entry->path;
	cursor->last_path_len = entry->path_len;
	cursor->p += path_len;
	cursor->remaining--;
	return 1;
}

int attr_manifest_valid(const void *data, size_t len,
			const struct git_hash_algo *algo)
{
	struct attr_manifest_cursor cursor;
	struct attr_manifest_entry entry;
	int ret;

	if (attr_manifest_cursor_init(&cursor, data, len, algo))
		return 0;
	while ((ret = attr_manifest_cursor_next(&cursor, &entry)) > 0)
		;
	return !ret;
}
