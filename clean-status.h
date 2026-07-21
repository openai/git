#ifndef CLEAN_STATUS_H
#define CLEAN_STATUS_H

#include "clean-status-config.h"

struct index_state;
struct attr_source_snapshot;
struct clean_status_proof_epoch;
struct repository;
struct stat;
struct strbuf;

enum clean_status_attr_change {
	CLEAN_STATUS_ATTR_CONTENT_CHANGED = 1 << 0,
	CLEAN_STATUS_ATTR_NAMESPACE_CHANGED = 1 << 1,
};

void clean_status_set_config_digest(
	struct repository *repo,
	const struct clean_status_config_digest *digest);
void clean_status_enable_external_history(struct repository *repo);
int clean_status_external_history_enabled(const struct index_state *istate);
void clean_status_attach_config(struct index_state *istate);
int clean_status_filter_scope_needs_validation(
	const struct index_state *istate);
void clean_status_mark_filter_scope_valid(struct index_state *istate);

int clean_status_capture_attr_snapshot(
	struct index_state *istate,
	struct attr_source_snapshot **snapshot);
struct clean_status_proof_epoch *clean_status_capture_proof_epoch(
	struct index_state *istate,
	const struct attr_source_snapshot *attrs,
	int validate_filter_scope);
int clean_status_proof_epoch_start_token_matches(
	struct index_state *istate,
	const struct clean_status_proof_epoch *epoch);
int clean_status_proof_epoch_matches(
	struct index_state *istate,
	const struct clean_status_proof_epoch *epoch);
void clean_status_release_proof_epoch(
	struct clean_status_proof_epoch *epoch);

int clean_status_fsmonitor_config_mismatch(const struct index_state *istate);
int clean_status_fsmonitor_strong_mismatch(const struct index_state *istate);

int clean_status_has_persistent_fsmonitor_semantic_history(
	const struct index_state *istate);
int clean_status_has_worktree_manifest_history(
	const struct index_state *istate);
int clean_status_fsmonitor_semantic_adoption_needed(
	const struct index_state *istate);
int clean_status_fsmonitor_semantic_baseline_needed(
	const struct index_state *istate);
int clean_status_fsmonitor_semantic_baseline_pending(
	const struct index_state *istate);
void clean_status_begin_fsmonitor_semantic_baseline(
	struct index_state *istate);

int clean_status_refresh_worktree_manifest(struct index_state *istate);
int clean_status_manifest_global_fallback(const struct index_state *istate);

void clean_status_mark_fsmonitor_config_valid(
	struct index_state *istate, const char *closed_token);

void clean_status_record_source_identity(struct index_state *istate,
					 const struct stat *st);
/* Takes ownership of fd only when it returns 1. */
int clean_status_retain_source_index_fd(struct index_state *istate, int fd,
					const struct stat *st);
int clean_status_verify_null_index(const struct index_state *istate,
				   const struct stat *st);

int clean_status_read_fsmonitor_config(struct index_state *istate,
				       const void *data, unsigned long size);
void clean_status_prepare_fsmonitor_config(struct index_state *istate);
int clean_status_probe_fsmonitor_config(struct index_state *istate);
void clean_status_invalidate_current_proof(struct index_state *istate);
void clean_status_advance_fsmonitor_config_token(
	struct index_state *istate, const char *next_token);
int clean_status_should_write_fsmonitor_config(
	const struct index_state *istate);
void clean_status_write_fsmonitor_config(struct strbuf *out,
					 const struct index_state *istate);
int clean_status_restore_external_history(struct index_state *istate);
int clean_status_external_history_was_restored(
	const struct index_state *istate);
int clean_status_save_external_history(struct index_state *istate);
void clean_status_copy_fsmonitor_history(struct index_state *dst,
					 const struct index_state *src);
int clean_status_transfer_current_proof_if_same_index(
	struct index_state *dst, const struct index_state *src);

void clean_status_release(struct index_state *istate);

#endif /* CLEAN_STATUS_H */
