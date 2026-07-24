#include "git-compat-util.h"
#include "attr-fingerprint.h"
#include "clean-status.h"
#include "clean-status-internal.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "trace2.h"

static struct repository *configured_repo;
static unsigned char configured_hash[GIT_MAX_RAWSZ];
static unsigned char configured_semantic_hash[GIT_MAX_RAWSZ];
static int configured_hash_valid;
static int configured_filter_configured;
static int configured_semantic_explicit;

struct clean_status_state *clean_status_get_state(struct index_state *istate)
{
	if (!istate->clean_status) {
		CALLOC_ARRAY(istate->clean_status, 1);
		clean_status_manifest_init(&istate->clean_status->manifest);
		strbuf_init(&istate->clean_status->disk_config_raw, 0);
	}
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

int clean_status_revalidated_token_matches(const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->config_revalidated &&
		state->config_revalidated_token &&
		istate->fsmonitor_last_update &&
		!strcmp(state->config_revalidated_token,
			istate->fsmonitor_last_update);
}

void clean_status_invalidate_current_proof(struct index_state *istate)
{
	if (!istate->clean_status)
		return;
	istate->clean_status->config_revalidated = 0;
	istate->clean_status->initial_coherent = 0;
	istate->clean_status->filter_scope_valid = 0;
	istate->clean_status->semantic_baseline_pending = 0;
}

int clean_status_capture_attr_snapshot(
	struct index_state *istate,
	struct attr_source_snapshot **snapshot)
{
	struct clean_status_state *state = istate->clean_status;
	struct attr_source_snapshot *captured = NULL;
	const struct attr_fingerprint *attrs;
	int valid, changed = 0;

	if (!snapshot)
		BUG("clean_status_capture_attr_snapshot requires an output");
	*snapshot = NULL;
	if (!fstat_is_reliable() || !state || !state->current_config_valid ||
	    !state->config_enforced)
		return 0;
	valid = !attr_source_snapshot_repository(istate->repo, &captured);
	attrs = attr_source_snapshot_fingerprint(captured);
	if (!valid || !state->current_attr_valid) {
		changed = CLEAN_STATUS_ATTR_CONTENT_CHANGED |
			CLEAN_STATUS_ATTR_NAMESPACE_CHANGED;
	} else {
		if (memcmp(attrs->content_hash, state->current_attr_hash,
			   istate->repo->hash_algo->rawsz))
			changed |= CLEAN_STATUS_ATTR_CONTENT_CHANGED;
		if (memcmp(attrs->namespace_hash,
			   state->current_attr_namespace_hash,
			   istate->repo->hash_algo->rawsz))
			changed |= CLEAN_STATUS_ATTR_NAMESPACE_CHANGED;
	}
	if (valid) {
		memcpy(state->current_attr_hash, attrs->content_hash,
		       istate->repo->hash_algo->rawsz);
		memcpy(state->current_attr_namespace_hash, attrs->namespace_hash,
		       istate->repo->hash_algo->rawsz);
		state->current_attr_valid = 1;
		state->current_attr_sources_present = attrs->sources_present;
	} else {
		state->current_attr_valid = 0;
	}
	if (changed) {
		clean_status_invalidate_current_proof(istate);
		state->config_mismatch = 1;
		state->strong_mismatch = 1;
	}
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/rechecked", 1);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/mismatch", state->strong_mismatch);
	if (!valid)
		return -1;
	*snapshot = captured;
	return changed;
}

int clean_status_fsmonitor_config_mismatch(const struct index_state *istate)
{
	return istate->clean_status &&
		istate->clean_status->current_config_valid &&
		istate->clean_status->config_mismatch;
}

int clean_status_fsmonitor_strong_mismatch(const struct index_state *istate)
{
	return istate->clean_status &&
		istate->clean_status->current_config_valid &&
		istate->clean_status->strong_mismatch;
}

int clean_status_refresh_worktree_manifest(struct index_state *istate)
{
	struct clean_status_state *state = clean_status_get_state(istate);

	return clean_status_manifest_refresh(istate, &state->manifest);
}

int clean_status_manifest_global_fallback(const struct index_state *istate)
{
	return istate->clean_status &&
		istate->clean_status->manifest.global_fallback;
}

void clean_status_release(struct index_state *istate)
{
	if (!istate->clean_status)
		return;
	clean_status_manifest_release(&istate->clean_status->manifest);
	strbuf_release(&istate->clean_status->disk_config_raw);
	free(istate->clean_status->disk_config_token);
	free(istate->clean_status->config_revalidated_token);
	FREE_AND_NULL(istate->clean_status);
}
