#ifndef CLEAN_STATUS_MANIFEST_H
#define CLEAN_STATUS_MANIFEST_H

#include "hash.h"
#include "strbuf.h"

struct index_state;
struct semantic_verify_proof;

struct clean_status_manifest_state {
	struct strbuf disk;
	struct strbuf current;
	unsigned char disk_hash[GIT_MAX_RAWSZ];
	unsigned char current_hash[GIT_MAX_RAWSZ];
	uint32_t disk_flags;
	uint32_t current_flags;
	uint32_t scan_count;
	unsigned disk_valid : 1;
	unsigned current_valid : 1;
	unsigned checked : 1;
	unsigned changed : 1;
	unsigned global_fallback : 1;
	unsigned current_invalidated : 1;
};

void clean_status_manifest_init(struct clean_status_manifest_state *state);
void clean_status_manifest_release(struct clean_status_manifest_state *state);
int clean_status_manifest_load(struct clean_status_manifest_state *state,
			       const void *data, size_t len, uint32_t flags,
			       const struct git_hash_algo *algo);
void clean_status_manifest_adopt_disk(
	struct clean_status_manifest_state *state);
int clean_status_manifest_refresh(struct index_state *istate,
				  struct clean_status_manifest_state *state);
void clean_status_manifest_begin_directory_delta(
	struct index_state *istate, const struct semantic_verify_proof *proof);
int clean_status_manifest_end_directory_delta(struct index_state *istate);
/* Recheck one path's attribute ancestry for suspended backoff history. */
int clean_status_manifest_path_attributes_unchanged(
	const struct index_state *istate, const char *path);
/* Recheck each distinct attribute source below an indexed directory. */
int clean_status_manifest_directory_sources_unchanged(
	const struct index_state *istate, const char *directory);
int clean_status_manifest_directory_unchanged(
	struct index_state *istate, const char *directory);
int clean_status_manifest_reconcile_deleted_attribute(
	struct index_state *istate, const char *path);
int clean_status_manifest_reconcile_display_only_attribute(
	struct index_state *istate, const char *path);
int clean_status_manifest_accept_current_display_only_attribute(
	struct index_state *istate, const char *path);
void clean_status_manifest_invalidate(
	struct clean_status_manifest_state *state);

#endif /* CLEAN_STATUS_MANIFEST_H */
