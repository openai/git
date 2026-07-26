#include "git-compat-util.h"
#include "attr-fingerprint.h"
#include "clean-status.h"
#include "clean-status-internal.h"
#include "read-cache-ll.h"
#include "repository.h"

static struct repository *configured_repo;
static unsigned char configured_hash[GIT_MAX_RAWSZ];
static unsigned char configured_semantic_hash[GIT_MAX_RAWSZ];
static int configured_hash_valid;
static int configured_filter_configured;
static int configured_semantic_explicit;

struct clean_status_state *clean_status_get_state(struct index_state *istate)
{
	if (!istate->clean_status)
		CALLOC_ARRAY(istate->clean_status, 1);
	return istate->clean_status;
}

void clean_status_set_config_digest(
	struct repository *repo,
	const struct clean_status_config_digest *digest)
{
	configured_repo = repo;
	configured_hash_valid = digest && digest->finalized;
	configured_filter_configured = configured_hash_valid &&
		digest->filter_configured;
	configured_semantic_explicit = configured_hash_valid &&
		digest->semantic_config_explicit;
	if (!configured_hash_valid)
		return;
	memcpy(configured_hash, digest->hash, repo->hash_algo->rawsz);
	memcpy(configured_semantic_hash, digest->semantic_hash,
	       repo->hash_algo->rawsz);
}

void clean_status_attach_config(struct index_state *istate)
{
	struct clean_status_state *state = istate->clean_status;
	struct attr_fingerprint attrs;

	if (state && state->current_config_valid)
		return;
	if (!configured_hash_valid || configured_repo != istate->repo)
		return;
	state = clean_status_get_state(istate);
	memcpy(state->current_config_hash, configured_hash,
	       istate->repo->hash_algo->rawsz);
	memcpy(state->current_semantic_hash, configured_semantic_hash,
	       istate->repo->hash_algo->rawsz);
	state->current_config_valid = 1;
	state->current_semantic_valid = 1;
	state->current_semantic_explicit = configured_semantic_explicit;
	state->config_enforced = 1;
	state->filter_configured = configured_filter_configured;
	if (!attr_fingerprint_repository(istate->repo, &attrs)) {
		memcpy(state->current_attr_hash, attrs.content_hash,
		       istate->repo->hash_algo->rawsz);
		memcpy(state->current_attr_namespace_hash, attrs.namespace_hash,
		       istate->repo->hash_algo->rawsz);
		state->current_attr_valid = 1;
		state->current_attr_sources_present = attrs.sources_present;
	}
}

int clean_status_filter_scope_needs_validation(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->current_config_valid && state->config_enforced &&
		state->filter_configured && !state->filter_scope_valid;
}

void clean_status_release(struct index_state *istate)
{
	if (!istate->clean_status)
		return;
	FREE_AND_NULL(istate->clean_status);
}
