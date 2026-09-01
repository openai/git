#ifndef CLEAN_STATUS_SIDECAR_H
#define CLEAN_STATUS_SIDECAR_H

#include "clean-status-identity.h"
#include "hash.h"
#include "strbuf.h"

struct clean_status_index_snapshot;
struct attr_source_snapshot;
struct repository;
struct stat;

#define CLEAN_STATUS_SIDECAR_VERSION 1
#define CLEAN_STATUS_SIDECAR_HARDLINK_VERSION 2
#define CLEAN_STATUS_HARDLINK_WITNESS_MAX 4096
#define CLEAN_STATUS_SIDECAR_MAX_SIZE (1024 * 1024)

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
	const unsigned char *hardlinks;
	size_t hardlinks_len;
	uint32_t hardlink_nr;
};

struct clean_status_sidecar_record {
	struct clean_status_sidecar sidecar;
	struct strbuf storage;
};

#define CLEAN_STATUS_SIDECAR_RECORD_INIT { \
	.storage = STRBUF_INIT, \
}

int clean_status_sidecar_parse(struct clean_status_sidecar *sidecar,
			       const void *data, size_t len,
			       const struct git_hash_algo *algo);
int clean_status_sidecar_write(struct strbuf *out,
			       const struct clean_status_sidecar *sidecar,
			       const struct git_hash_algo *algo);
int clean_status_sidecar_append_hardlink(
	struct strbuf *out, const char *path,
	const struct path_stat_identity *identity);
int clean_status_sidecar_next_hardlink(
	const unsigned char **cursor, const unsigned char *end,
	const unsigned char **path, size_t *path_len,
	struct path_stat_identity *identity);
int clean_status_sidecar_load(
	const char *index_path, const struct git_hash_algo *algo,
	struct clean_status_sidecar_record *record);
void clean_status_sidecar_record_release(
	struct clean_status_sidecar_record *record);
int clean_status_sidecar_pin_source(
	const char *index_path, const struct clean_status_sidecar *sidecar,
	const struct git_hash_algo *algo,
	struct clean_status_index_snapshot *snapshot);
int clean_status_sidecar_install(
	const char *index_path, const struct clean_status_sidecar *sidecar,
	const struct clean_status_index_snapshot *snapshot,
	const struct git_hash_algo *algo);
int clean_status_worktree_shape_supported(struct repository *repo);
int clean_status_repository_fingerprint(
	struct repository *repo,
	const struct attr_source_snapshot *attrs,
	const struct clean_status_index_snapshot *index,
	const struct stat *scanned_worktree,
	unsigned char *out);

#endif /* CLEAN_STATUS_SIDECAR_H */
