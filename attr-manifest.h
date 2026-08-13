#ifndef ATTR_MANIFEST_H
#define ATTR_MANIFEST_H

#include "hash.h"

struct strbuf;

enum attr_manifest_source {
	ATTR_MANIFEST_WORKTREE = 1,
	ATTR_MANIFEST_INDEX = 2,
};

struct attr_manifest_entry {
	const unsigned char *path;
	uint32_t path_len;
	enum attr_manifest_source source;
	const unsigned char *hash;
};

struct attr_manifest_cursor {
	const unsigned char *p;
	const unsigned char *end;
	const unsigned char *last_path;
	const struct git_hash_algo *algo;
	uint32_t last_path_len;
	uint32_t remaining;
};

struct attr_manifest_writer {
	struct strbuf *buf;
	const struct git_hash_algo *algo;
	size_t last_path_offset;
	uint32_t last_path_len;
	uint32_t nr;
};

typedef int (*attr_manifest_change_fn)(const struct attr_manifest_entry *entry,
				       void *data);

void attr_manifest_writer_init(struct attr_manifest_writer *writer,
			       struct strbuf *buf,
			       const struct git_hash_algo *algo);
int attr_manifest_writer_add(struct attr_manifest_writer *writer,
			     const char *path,
			     enum attr_manifest_source source,
			     const unsigned char *hash);
int attr_manifest_cursor_init(struct attr_manifest_cursor *cursor,
			      const void *data, size_t len,
			      const struct git_hash_algo *algo);
int attr_manifest_cursor_next(struct attr_manifest_cursor *cursor,
			      struct attr_manifest_entry *entry);
int attr_manifest_valid(const void *data, size_t len,
			const struct git_hash_algo *algo);
int attr_manifest_for_each_changed(const void *old_data, size_t old_len,
				   const void *new_data, size_t new_len,
				   const struct git_hash_algo *algo,
				   attr_manifest_change_fn fn, void *data);
int attr_manifest_only_linguist_generated_changed(
	const char *old_data, size_t old_len,
	const char *new_data, size_t new_len);

#endif /* ATTR_MANIFEST_H */
