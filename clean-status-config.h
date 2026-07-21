#ifndef CLEAN_STATUS_CONFIG_H
#define CLEAN_STATUS_CONFIG_H

#include "hash.h"

struct config_context;
struct repository;

struct clean_status_config_digest {
	struct git_hash_ctx ctx;
	struct git_hash_ctx semantic_ctx;
	unsigned char hash[GIT_MAX_RAWSZ];
	unsigned char semantic_hash[GIT_MAX_RAWSZ];
	unsigned initialized : 1;
	unsigned finalized : 1;
	unsigned filter_configured : 1;
	unsigned semantic_config_explicit : 1;
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

#endif /* CLEAN_STATUS_CONFIG_H */
