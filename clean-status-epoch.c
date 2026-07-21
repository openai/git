#include "git-compat-util.h"
#include "attr-fingerprint.h"
#include "clean-status.h"
#include "clean-status-index.h"
#include "clean-status-internal.h"
#include "fsmonitor-clean-proof.h"
#include "fsmonitor-ll.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "trace2.h"

/*
 * State captured before a worktree scan. Every recorded input must still
 * match after the closing provider query before scan results are accepted.
 */
struct clean_status_proof_epoch {
	struct index_state *istate;
	struct clean_status_index_snapshot index;
	char *scan_start_token;
	unsigned char config_hash[GIT_MAX_RAWSZ];
	unsigned char semantic_hash[GIT_MAX_RAWSZ];
	unsigned char attr_hash[GIT_MAX_RAWSZ];
	unsigned char attr_namespace_hash[GIT_MAX_RAWSZ];
	unsigned char manifest_hash[GIT_MAX_RAWSZ];
	uint32_t manifest_flags;
	unsigned semantic_explicit : 1;
	unsigned attr_sources_present : 1;
	unsigned filter_configured : 1;
	unsigned filter_scope_valid : 1;
	unsigned strong_mismatch : 1;
	unsigned config_mismatch : 1;
};

static int config_matches_epoch(
	struct index_state *istate,
	const struct clean_status_proof_epoch *epoch)
{
	struct clean_status_state *state = istate->clean_status;
	struct clean_status_config_digest digest;
	const struct git_hash_algo *algo = istate->repo->hash_algo;

	if (clean_status_config_read_repository(istate->repo, &digest))
		return 0;
	return digest.finalized &&
		digest.filter_configured == epoch->filter_configured &&
		digest.semantic_config_explicit == epoch->semantic_explicit &&
		!memcmp(digest.hash, epoch->config_hash, algo->rawsz) &&
		!memcmp(digest.semantic_hash, epoch->semantic_hash, algo->rawsz) &&
		state && state->current_config_valid &&
		state->current_semantic_valid &&
		!memcmp(state->current_config_hash, epoch->config_hash,
			algo->rawsz) &&
		!memcmp(state->current_semantic_hash, epoch->semantic_hash,
			algo->rawsz);
}

struct clean_status_proof_epoch *clean_status_capture_proof_epoch(
	struct index_state *istate,
	const struct attr_source_snapshot *attrs,
	int validate_filter_scope)
{
	struct clean_status_state *state = istate->clean_status;
	struct clean_status_proof_epoch *epoch;
	struct clean_status_config_digest digest;
	struct clean_status_index_snapshot index;
	const struct attr_fingerprint *fingerprint =
		attr_source_snapshot_fingerprint(attrs);
	uint32_t manifest_requirements =
		FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		FSMONITOR_CLEAN_PROOF_FULL_INDEX;

	if (istate->split_index || !state || !state->current_config_valid ||
	    !state->config_enforced ||
	    !state->current_semantic_valid || !state->current_attr_valid ||
	    !state->manifest.current_valid || !state->manifest.checked ||
	    state->manifest.global_fallback ||
	    (clean_status_filter_scope_needs_validation(istate) &&
	     !validate_filter_scope) ||
	    (state->manifest.current_flags & manifest_requirements) !=
		manifest_requirements ||
	    !fsmonitor_pending_token_from_provider(istate) ||
	    !istate->fsmonitor_last_update_pending || !fingerprint ||
	    memcmp(fingerprint->content_hash, state->current_attr_hash,
		   istate->repo->hash_algo->rawsz) ||
	    memcmp(fingerprint->namespace_hash,
		   state->current_attr_namespace_hash,
		   istate->repo->hash_algo->rawsz) ||
	    fingerprint->sources_present !=
		state->current_attr_sources_present)
		return NULL;
	if (clean_status_config_read_repository(istate->repo, &digest) ||
	    !digest.finalized ||
	    digest.filter_configured != state->filter_configured ||
	    digest.semantic_config_explicit !=
		state->current_semantic_explicit ||
	    memcmp(digest.hash, state->current_config_hash,
		   istate->repo->hash_algo->rawsz) ||
	    memcmp(digest.semantic_hash, state->current_semantic_hash,
		   istate->repo->hash_algo->rawsz) ||
	    clean_status_index_snapshot_pin_proof_epoch(&index, istate))
		return NULL;

	CALLOC_ARRAY(epoch, 1);
	epoch->istate = istate;
	epoch->index = index;
	epoch->scan_start_token = xstrdup(istate->fsmonitor_last_update_pending);
	memcpy(epoch->config_hash, state->current_config_hash,
	       istate->repo->hash_algo->rawsz);
	memcpy(epoch->semantic_hash, state->current_semantic_hash,
	       istate->repo->hash_algo->rawsz);
	memcpy(epoch->attr_hash, state->current_attr_hash,
	       istate->repo->hash_algo->rawsz);
	memcpy(epoch->attr_namespace_hash,
	       state->current_attr_namespace_hash,
	       istate->repo->hash_algo->rawsz);
	memcpy(epoch->manifest_hash, state->manifest.current_hash,
	       istate->repo->hash_algo->rawsz);
	epoch->manifest_flags = state->manifest.current_flags;
	epoch->semantic_explicit = state->current_semantic_explicit;
	epoch->attr_sources_present = state->current_attr_sources_present;
	epoch->filter_configured = state->filter_configured;
	epoch->filter_scope_valid = state->filter_scope_valid;
	epoch->strong_mismatch = state->strong_mismatch;
	epoch->config_mismatch = state->config_mismatch;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/proof-epoch-captured", 1);
	return epoch;
}

int clean_status_proof_epoch_start_token_matches(
	struct index_state *istate,
	const struct clean_status_proof_epoch *epoch)
{
	return epoch && epoch->istate == istate && epoch->scan_start_token &&
		fsmonitor_pending_token_from_provider(istate) &&
		istate->fsmonitor_last_update_pending &&
		!strcmp(epoch->scan_start_token,
			istate->fsmonitor_last_update_pending);
}

int clean_status_proof_epoch_matches(
	struct index_state *istate,
	const struct clean_status_proof_epoch *epoch)
{
	struct clean_status_state *state;
	struct attr_fingerprint attrs;
	const struct git_hash_algo *algo = istate->repo->hash_algo;
	int matched = 0;

	if (!epoch || epoch->istate != istate ||
	    !fsmonitor_pending_token_from_provider(istate) ||
	    !istate->fsmonitor_last_update_pending)
		goto done;
	state = istate->clean_status;
	if (!state || !state->current_config_valid || !state->config_enforced ||
	    !state->current_semantic_valid || !state->current_attr_valid ||
	    !state->manifest.current_valid || !state->manifest.checked ||
	    state->manifest.global_fallback ||
	    state->manifest.current_flags != epoch->manifest_flags ||
	    state->current_semantic_explicit != epoch->semantic_explicit ||
	    state->current_attr_sources_present != epoch->attr_sources_present ||
	    state->filter_configured != epoch->filter_configured ||
	    state->filter_scope_valid != epoch->filter_scope_valid ||
	    state->strong_mismatch != epoch->strong_mismatch ||
	    state->config_mismatch != epoch->config_mismatch)
		goto done;
	if (attr_fingerprint_repository(istate->repo, &attrs) ||
	    memcmp(attrs.content_hash, epoch->attr_hash, algo->rawsz) ||
	    memcmp(attrs.namespace_hash, epoch->attr_namespace_hash,
		   algo->rawsz) ||
	    attrs.sources_present != epoch->attr_sources_present ||
	    memcmp(state->manifest.current_hash, epoch->manifest_hash,
		   algo->rawsz) ||
	    !config_matches_epoch(istate, epoch) ||
	    !clean_status_index_snapshot_still_matches_proof_epoch(
		    &epoch->index, istate))
		goto done;
	matched = 1;
done:
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/proof-epoch-matched", matched);
	return matched;
}

void clean_status_release_proof_epoch(
	struct clean_status_proof_epoch *epoch)
{
	if (!epoch)
		return;
	clean_status_index_snapshot_release(&epoch->index);
	free(epoch->scan_start_token);
	free(epoch);
}
