#ifndef CLEAN_STATUS_INDEX_H
#define CLEAN_STATUS_INDEX_H

#include "clean-status-identity.h"
#include "hash.h"

struct index_state;

struct clean_status_index_snapshot {
	struct clean_status_identity identity;
	uint32_t version;
	uint32_t cache_nr;
	struct object_id checksum;
	int fd;
};

int clean_status_index_snapshot_open(
	struct clean_status_index_snapshot *snapshot, const char *path,
	const struct git_hash_algo *algo);
int clean_status_index_snapshot_still_matches_path(
	const struct clean_status_index_snapshot *snapshot, const char *path,
	const struct git_hash_algo *algo);
int clean_status_index_snapshot_pin(
	struct clean_status_index_snapshot *snapshot,
	struct index_state *istate);
int clean_status_index_snapshot_still_matches(
	const struct clean_status_index_snapshot *snapshot,
	const struct index_state *istate);
void clean_status_index_snapshot_release(
	struct clean_status_index_snapshot *snapshot);
int clean_status_index_logical_digest(const struct index_state *istate,
				      unsigned char *out);

#endif /* CLEAN_STATUS_INDEX_H */
