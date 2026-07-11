#ifndef CLEAN_STATUS_H
#define CLEAN_STATUS_H

#include "clean-status-config.h"

struct index_state;
struct repository;
struct stat;

void clean_status_set_config_digest(
	struct repository *repo,
	const struct clean_status_config_digest *digest);
void clean_status_attach_config(struct index_state *istate);
int clean_status_filter_scope_needs_validation(
	const struct index_state *istate);
void clean_status_record_source_identity(struct index_state *istate,
					 const struct stat *st);
int clean_status_verify_null_index(const struct index_state *istate,
				   const struct stat *st);
void clean_status_release(struct index_state *istate);

#endif /* CLEAN_STATUS_H */
