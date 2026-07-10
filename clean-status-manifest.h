#ifndef CLEAN_STATUS_MANIFEST_H
#define CLEAN_STATUS_MANIFEST_H

#include "hash.h"
#include "strbuf.h"

struct clean_status_manifest_state {
	struct strbuf disk;
	struct strbuf current;
	unsigned char disk_hash[GIT_MAX_RAWSZ];
	unsigned char current_hash[GIT_MAX_RAWSZ];
	uint32_t disk_flags;
	uint32_t current_flags;
	unsigned disk_valid : 1;
	unsigned current_valid : 1;
	unsigned checked : 1;
};

void clean_status_manifest_init(struct clean_status_manifest_state *state);
void clean_status_manifest_release(struct clean_status_manifest_state *state);
int clean_status_manifest_load(struct clean_status_manifest_state *state,
			       const void *data, size_t len, uint32_t flags,
			       const struct git_hash_algo *algo);
void clean_status_manifest_adopt_disk(
	struct clean_status_manifest_state *state);
void clean_status_manifest_invalidate(
	struct clean_status_manifest_state *state);

#endif /* CLEAN_STATUS_MANIFEST_H */
