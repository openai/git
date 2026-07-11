#ifndef CLEAN_STATUS_H
#define CLEAN_STATUS_H

#include "clean-status-config.h"

struct index_state;
struct repository;
struct stat;
struct strbuf;

void clean_status_set_config_digest(
	struct repository *repo,
	const struct clean_status_config_digest *digest);
void clean_status_attach_config(struct index_state *istate);

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

void clean_status_release(struct index_state *istate);

#endif /* CLEAN_STATUS_H */
