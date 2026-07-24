#ifndef CLEAN_STATUS_INTERNAL_H
#define CLEAN_STATUS_INTERNAL_H

#include "clean-status-identity.h"
#include "clean-status-manifest.h"

struct index_state;

struct clean_status_state {
	struct clean_status_identity source_identity;
	struct clean_status_manifest_state manifest;
	struct strbuf disk_config_raw;
	char *disk_config_token;
	char *config_revalidated_token;
	unsigned char current_config_hash[GIT_MAX_RAWSZ];
	unsigned char disk_config_hash[GIT_MAX_RAWSZ];
	unsigned char current_semantic_hash[GIT_MAX_RAWSZ];
	unsigned char disk_semantic_hash[GIT_MAX_RAWSZ];
	unsigned char current_attr_hash[GIT_MAX_RAWSZ];
	unsigned char current_attr_namespace_hash[GIT_MAX_RAWSZ];
	unsigned char disk_attr_hash[GIT_MAX_RAWSZ];
	unsigned current_config_valid : 1;
	unsigned current_semantic_valid : 1;
	unsigned current_attr_valid : 1;
	unsigned current_semantic_explicit : 1;
	unsigned current_attr_sources_present : 1;
	unsigned config_enforced : 1;
	unsigned filter_configured : 1;
	unsigned filter_scope_valid : 1;
	unsigned config_mismatch : 1;
	unsigned strong_mismatch : 1;
	unsigned config_revalidated : 1;
	unsigned initial_coherent : 1;
	unsigned source_identity_valid : 1;
	unsigned disk_config_valid : 1;
	unsigned disk_semantic_valid : 1;
	unsigned disk_attr_valid : 1;
	unsigned disk_config_seen : 1;
	unsigned disk_config_invalid : 1;
};

struct clean_status_state *clean_status_get_state(struct index_state *istate);
int clean_status_revalidated_token_matches(
	const struct index_state *istate);

#endif /* CLEAN_STATUS_INTERNAL_H */
