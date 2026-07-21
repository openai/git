#ifndef CLEAN_STATUS_SIDECAR_H
#define CLEAN_STATUS_SIDECAR_H

#include "clean-status-identity.h"
#include "hash.h"

struct strbuf;

#define CLEAN_STATUS_SIDECAR_VERSION 1

struct clean_status_proof {
	uint32_t index_version;
	uint32_t cache_nr;
	struct object_id index_checksum;
	struct object_id head_tree;
	unsigned char config_hash[GIT_MAX_RAWSZ];
	unsigned char repo_hash[GIT_MAX_RAWSZ];
	struct object_id exclude_source_digest;
};

struct clean_status_sidecar {
	struct clean_status_identity identity;
	struct clean_status_proof proof;
	const unsigned char *token;
	size_t token_len;
};

int clean_status_sidecar_parse(struct clean_status_sidecar *sidecar,
			       const void *data, size_t len,
			       const struct git_hash_algo *algo);
int clean_status_sidecar_write(struct strbuf *out,
			       const struct clean_status_sidecar *sidecar,
			       const struct git_hash_algo *algo);

#endif /* CLEAN_STATUS_SIDECAR_H */
