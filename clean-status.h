#ifndef CLEAN_STATUS_H
#define CLEAN_STATUS_H

#include "clean-status-config.h"

struct index_state;
struct attr_source_snapshot;
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
void clean_status_attach_config(struct index_state *istate);
int clean_status_filter_scope_needs_validation(
	const struct index_state *istate);
int clean_status_capture_attr_snapshot(
	struct index_state *istate,
	struct attr_source_snapshot **snapshot);
int clean_status_fsmonitor_strong_mismatch(const struct index_state *istate);
void clean_status_record_source_identity(struct index_state *istate,
					 const struct stat *st);
int clean_status_verify_null_index(const struct index_state *istate,
				   const struct stat *st);

int clean_status_read_fsmonitor_config(struct index_state *istate,
				       const void *data, unsigned long size);
void clean_status_prepare_fsmonitor_config(struct index_state *istate);
void clean_status_invalidate_current_proof(struct index_state *istate);
void clean_status_advance_fsmonitor_config_token(
	struct index_state *istate, const char *next_token);
int clean_status_should_write_fsmonitor_config(
	const struct index_state *istate);
void clean_status_write_fsmonitor_config(struct strbuf *out,
					 const struct index_state *istate);
void clean_status_copy_fsmonitor_history(struct index_state *dst,
					 const struct index_state *src);
int clean_status_transfer_current_proof_if_same_index(
	struct index_state *dst, const struct index_state *src);

void clean_status_release(struct index_state *istate);

#endif /* CLEAN_STATUS_H */
