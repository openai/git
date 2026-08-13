#ifndef FSMONITOR_CLEAN_PROOF_H
#define FSMONITOR_CLEAN_PROOF_H

#include "hash.h"

struct strbuf;

#define FSMONITOR_CLEAN_PROOF_VERSION_LEGACY 1
#define FSMONITOR_CLEAN_PROOF_VERSION 2
#define FSMONITOR_CLEAN_PROOF_TOKEN_MAX 4096

#define FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE (1u << 0)
#define FSMONITOR_CLEAN_PROOF_TOKEN_BOUND       (1u << 1)
#define FSMONITOR_CLEAN_PROOF_STAT_BOUND        (1u << 2)
#define FSMONITOR_CLEAN_PROOF_FULL_INDEX        (1u << 3)
#define FSMONITOR_CLEAN_PROOF_ALL \
	(FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE | \
	 FSMONITOR_CLEAN_PROOF_TOKEN_BOUND | \
	 FSMONITOR_CLEAN_PROOF_STAT_BOUND | \
	 FSMONITOR_CLEAN_PROOF_FULL_INDEX)

struct fsmonitor_clean_proof {
	uint32_t version;
	uint32_t flags;
	const unsigned char *token;
	size_t token_len;
	const unsigned char *config_hash;
	const unsigned char *semantic_hash;
	const unsigned char *attr_hash;
	const unsigned char *tracked_policy_hash;
	const unsigned char *attr_manifest;
	size_t attr_manifest_len;
};

int fsmonitor_clean_proof_parse(struct fsmonitor_clean_proof *proof,
				const void *data, size_t len,
				const struct git_hash_algo *algo);
int fsmonitor_clean_proof_write(struct strbuf *out,
				const struct fsmonitor_clean_proof *proof,
				const struct git_hash_algo *algo);
int fsmonitor_clean_proof_copy_without_bindings(
	struct strbuf *out, const void *data, size_t len,
	const struct git_hash_algo *algo);

#endif /* FSMONITOR_CLEAN_PROOF_H */
