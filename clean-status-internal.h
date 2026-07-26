#ifndef CLEAN_STATUS_INTERNAL_H
#define CLEAN_STATUS_INTERNAL_H

#include "hash.h"

struct index_state;

struct clean_status_state {
	unsigned char current_config_hash[GIT_MAX_RAWSZ];
	unsigned char current_semantic_hash[GIT_MAX_RAWSZ];
	unsigned char current_attr_hash[GIT_MAX_RAWSZ];
	unsigned char current_attr_namespace_hash[GIT_MAX_RAWSZ];
	unsigned current_config_valid : 1;
	unsigned current_semantic_valid : 1;
	unsigned current_attr_valid : 1;
	unsigned current_semantic_explicit : 1;
	unsigned current_attr_sources_present : 1;
	unsigned config_enforced : 1;
	unsigned unsafe_filter : 1;
};

struct clean_status_state *clean_status_get_state(struct index_state *istate);

#endif /* CLEAN_STATUS_INTERNAL_H */
