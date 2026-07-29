#ifndef CLEAN_STATUS_HISTORY_STORE_H
#define CLEAN_STATUS_HISTORY_STORE_H

#include "hash.h"
#include "strbuf.h"

struct clean_status_index_snapshot;

struct clean_status_history_checkpoint {
	unsigned char index_hash[GIT_MAX_RAWSZ];
	const unsigned char *fsmonitor;
	size_t fsmonitor_len;
	const unsigned char *untracked_cache;
	size_t untracked_cache_len;
	const unsigned char *fsmonitor_config;
	size_t fsmonitor_config_len;
	const unsigned char *fsmonitor_untracked;
	size_t fsmonitor_untracked_len;
};

struct clean_status_history_store_record {
	struct clean_status_history_checkpoint checkpoint;
	struct strbuf storage;
};

#define CLEAN_STATUS_HISTORY_STORE_RECORD_INIT { \
	.storage = STRBUF_INIT, \
}

int clean_status_history_checkpoint_parse(
	struct clean_status_history_checkpoint *checkpoint,
	const char *proof_namespace, const void *data, size_t len,
	const struct git_hash_algo *algo);
int clean_status_history_checkpoint_write(
	struct strbuf *out, const char *proof_namespace,
	const struct clean_status_history_checkpoint *checkpoint,
	const struct git_hash_algo *algo);
int clean_status_history_store_load(
	const char *index_path, const char *proof_namespace,
	const struct git_hash_algo *algo,
	struct clean_status_history_store_record *record);
void clean_status_history_store_record_release(
	struct clean_status_history_store_record *record);
int clean_status_history_store_install(
	const char *index_path, const char *proof_namespace,
	const struct clean_status_history_checkpoint *checkpoint,
	const struct clean_status_index_snapshot *snapshot,
	const struct git_hash_algo *algo);

#endif /* CLEAN_STATUS_HISTORY_STORE_H */
