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

/*
 * An opt-in receipt for a canonical index write. Only the index writer may
 * record it, after committing its lockfile and before running hooks. The
 * caller must initialize and release it, even if no write was performed.
 */
struct clean_status_index_write_receipt {
	struct clean_status_index_snapshot snapshot;
	struct clean_status_identity source_identity;
	const struct index_state *istate;
	unsigned int recorded : 1;
};

#define CLEAN_STATUS_INDEX_WRITE_RECEIPT_INIT \
	{ .snapshot = { .fd = -1 } }

/* Writer-only lifecycle: prepare duplicates lock_fd; record fails closed. */
int clean_status_index_prepare_write_receipt(
	struct index_state *istate, int lock_fd,
	struct clean_status_index_write_receipt *receipt);
void clean_status_index_record_write_receipt(
	struct index_state *istate,
	struct clean_status_index_write_receipt *receipt);

/* Consumes the receipt and returns whether the written source was adopted. */
int clean_status_index_adopt_write_receipt(
	struct index_state *istate,
	struct clean_status_index_write_receipt *receipt);
void clean_status_index_write_receipt_release(
	struct clean_status_index_write_receipt *receipt);

int clean_status_index_snapshot_open(
	struct clean_status_index_snapshot *snapshot, const char *path,
	const struct git_hash_algo *algo);
/*
 * Callers which accept a null trailer must separately require a durable
 * source identity before trusting the snapshot.
 */
int clean_status_index_snapshot_open_allow_null_checksum(
	struct clean_status_index_snapshot *snapshot, const char *path,
	const struct git_hash_algo *algo);
int clean_status_index_snapshot_still_matches_path(
	const struct clean_status_index_snapshot *snapshot, const char *path,
	const struct git_hash_algo *algo);
int clean_status_index_snapshot_pin(
	struct clean_status_index_snapshot *snapshot,
	struct index_state *istate);
int clean_status_index_snapshot_pin_proof_epoch(
	struct clean_status_index_snapshot *snapshot,
	struct index_state *istate);
int clean_status_index_snapshot_still_matches(
	const struct clean_status_index_snapshot *snapshot,
	const struct index_state *istate);
int clean_status_index_snapshot_still_matches_proof_epoch(
	const struct clean_status_index_snapshot *snapshot,
	const struct index_state *istate);
void clean_status_index_snapshot_release(
	struct clean_status_index_snapshot *snapshot);
int clean_status_index_entries_are_certifiable(
	const struct index_state *istate);
int clean_status_index_is_certifiable(const struct index_state *istate);
int clean_status_index_is_certifiable_with_hardlinks(
	const struct index_state *istate, uint32_t *hardlink_nr);
int clean_status_index_logical_digest(const struct index_state *istate,
				      unsigned char *out);
int clean_status_index_logical_digest_after_status(
	const struct index_state *istate, unsigned char *out);
int clean_status_index_can_reuse_source_logical_hash(
	const struct index_state *istate);

#endif /* CLEAN_STATUS_INDEX_H */
