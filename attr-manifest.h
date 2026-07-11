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

struct attr_manifest_writer {
	struct strbuf *buf;
	const struct git_hash_algo *algo;
	size_t last_path_offset;
	uint32_t last_path_len;
	uint32_t nr;
};

void attr_manifest_writer_init(struct attr_manifest_writer *writer,
			       struct strbuf *buf,
			       const struct git_hash_algo *algo);
int attr_manifest_writer_add(struct attr_manifest_writer *writer,
			     const char *path,
			     enum attr_manifest_source source,
			     const unsigned char *hash);
#endif /* ATTR_MANIFEST_H */
