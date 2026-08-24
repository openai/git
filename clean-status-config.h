#ifndef CLEAN_STATUS_CONFIG_H
#define CLEAN_STATUS_CONFIG_H

#include "hash.h"

struct config_context;
struct index_state;
struct repository;
struct clean_status_pending_filter;

struct clean_status_config_digest {
	struct git_hash_ctx ctx;
	struct git_hash_ctx semantic_ctx;
	struct git_hash_ctx tracked_policy_ctx;
	unsigned char hash[GIT_MAX_RAWSZ];
	unsigned char semantic_hash[GIT_MAX_RAWSZ];
	unsigned char tracked_policy_hash[GIT_MAX_RAWSZ];
	struct clean_status_pending_filter *pending_filter;
	unsigned initialized : 1;
	unsigned finalized : 1;
	unsigned filter_configured : 1;
	unsigned normalized_filter_disable : 1;
	unsigned semantic_config_explicit : 1;
	unsigned attribute_tree_configured : 1;
	unsigned fsmonitor_value_seen : 1;
	unsigned fsmonitor_value_boolean : 1;
	unsigned fsmonitor_value_enabled : 1;
	unsigned submodule_recurse_seen : 1;
	unsigned submodule_recurse_known_false : 1;
};

void clean_status_config_init(struct clean_status_config_digest *digest,
			      const struct git_hash_algo *algo);
void clean_status_config_add(struct clean_status_config_digest *digest,
			     const char *key, const char *value,
			     const struct config_context *ctx);
void clean_status_config_final(struct clean_status_config_digest *digest);
int clean_status_config_read_repository(
	struct repository *repo,
	struct clean_status_config_digest *digest);
int clean_status_config_tracked_sources_predate_index(
	struct index_state *istate);

#endif /* CLEAN_STATUS_CONFIG_H */
