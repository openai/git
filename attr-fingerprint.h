#ifndef ATTR_FINGERPRINT_H
#define ATTR_FINGERPRINT_H

#include "hash.h"

struct repository;

struct attr_fingerprint_source {
	const char *path;
	unsigned int enabled : 1;
};

struct attr_fingerprint {
	unsigned char content_hash[GIT_MAX_RAWSZ];
	unsigned char namespace_hash[GIT_MAX_RAWSZ];
	unsigned int sources_present : 1;
};

enum attr_source_snapshot_kind {
	ATTR_SOURCE_SNAPSHOT_SYSTEM,
	ATTR_SOURCE_SNAPSHOT_GLOBAL,
	ATTR_SOURCE_SNAPSHOT_INFO,
	ATTR_SOURCE_SNAPSHOT_NR,
};

struct attr_source_snapshot;

int attr_fingerprint_sources(
	const struct attr_fingerprint_source *sources, size_t nr,
	const struct git_hash_algo *algo, struct attr_fingerprint *result);
int attr_fingerprint_repository(struct repository *repo,
				struct attr_fingerprint *result);
int attr_source_snapshot_repository(struct repository *repo,
				    struct attr_source_snapshot **result);
const struct attr_fingerprint *attr_source_snapshot_fingerprint(
	const struct attr_source_snapshot *snapshot);
int attr_source_snapshot_read(
	const struct attr_source_snapshot *snapshot,
	enum attr_source_snapshot_kind kind,
	const char **path, const char **buf, size_t *len);
void attr_source_snapshot_free(struct attr_source_snapshot *snapshot);

#endif /* ATTR_FINGERPRINT_H */
