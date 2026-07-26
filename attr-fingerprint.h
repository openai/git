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

int attr_fingerprint_sources(
	const struct attr_fingerprint_source *sources, size_t nr,
	const struct git_hash_algo *algo, struct attr_fingerprint *result);
int attr_fingerprint_repository(struct repository *repo,
				struct attr_fingerprint *result);

#endif /* ATTR_FINGERPRINT_H */
