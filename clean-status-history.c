#include "git-compat-util.h"
#include "clean-status.h"
#include "clean-status-internal.h"
#include "fsmonitor-clean-proof.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "strbuf.h"
#include "trace2.h"

static void invalidate_disk_history(struct clean_status_state *state)
{
	state->disk_config_seen = 1;
	state->disk_config_invalid = 1;
	state->disk_config_valid = 0;
	state->disk_semantic_valid = 0;
	state->disk_attr_valid = 0;
	FREE_AND_NULL(state->disk_config_token);
	strbuf_reset(&state->disk_config_raw);
	state->manifest.disk_valid = 0;
	state->manifest.disk_flags = 0;
	strbuf_reset(&state->manifest.disk);
}

int clean_status_read_fsmonitor_config(struct index_state *istate,
				       const void *data, unsigned long size)
{
	struct clean_status_state *state = clean_status_get_state(istate);
	struct fsmonitor_clean_proof proof;

	if (state->disk_config_seen ||
	    fsmonitor_clean_proof_parse(&proof, data, size,
					istate->repo->hash_algo) ||
	    clean_status_manifest_load(&state->manifest,
				       proof.attr_manifest,
				       proof.attr_manifest_len,
				       proof.flags,
				       istate->repo->hash_algo)) {
		invalidate_disk_history(state);
		trace2_data_intmax("fsmonitor", istate->repo,
				   "config/invalid-extension", 1);
		return 0;
	}

	state->disk_config_seen = 1;
	state->disk_config_token = xmemdupz(proof.token, proof.token_len);
	memcpy(state->disk_config_hash, proof.config_hash,
	       istate->repo->hash_algo->rawsz);
	memcpy(state->disk_semantic_hash, proof.semantic_hash,
	       istate->repo->hash_algo->rawsz);
	memcpy(state->disk_attr_hash, proof.attr_hash,
	       istate->repo->hash_algo->rawsz);
	strbuf_add(&state->disk_config_raw, data, size);
	state->disk_config_valid = 1;
	state->disk_semantic_valid = 1;
	state->disk_attr_valid = 1;
	return 0;
}

void clean_status_prepare_fsmonitor_config(struct index_state *istate)
{
	struct clean_status_state *state = istate->clean_status;
	const struct git_hash_algo *algo = istate->repo->hash_algo;
	int token_coherent, config_coherent, semantic_changed, attr_changed;
	int coherent;

	if (!state || !state->current_config_valid)
		return;
	token_coherent = state->disk_config_valid &&
		!state->disk_config_invalid && istate->fsmonitor_token_valid &&
		istate->fsmonitor_last_update && state->disk_config_token &&
		!strcmp(state->disk_config_token, istate->fsmonitor_last_update);
	config_coherent = state->disk_config_valid &&
		!memcmp(state->disk_config_hash, state->current_config_hash,
			algo->rawsz);
	semantic_changed = state->disk_semantic_valid &&
		state->current_semantic_valid &&
		memcmp(state->disk_semantic_hash, state->current_semantic_hash,
		       algo->rawsz);
	attr_changed = (state->disk_attr_valid && !state->current_attr_valid) ||
		(state->disk_attr_valid && state->current_attr_valid &&
		 memcmp(state->disk_attr_hash, state->current_attr_hash,
			algo->rawsz));
	coherent = token_coherent && config_coherent &&
		state->disk_semantic_valid && state->current_semantic_valid &&
		!semantic_changed && state->disk_attr_valid &&
		state->current_attr_valid && !attr_changed &&
		state->manifest.disk_valid &&
		(state->manifest.disk_flags & FSMONITOR_CLEAN_PROOF_ALL) ==
			FSMONITOR_CLEAN_PROOF_ALL;
	state->filter_scope_valid = coherent && state->filter_configured;
	state->config_revalidated = coherent;
	state->initial_coherent = coherent;
	FREE_AND_NULL(state->config_revalidated_token);
	if (coherent) {
		state->config_revalidated_token =
			xstrdup(istate->fsmonitor_last_update);
		clean_status_manifest_adopt_disk(&state->manifest);
	}
	state->config_mismatch = state->config_enforced && !coherent;
	state->strong_mismatch = state->config_enforced &&
		(state->disk_config_invalid ||
		 semantic_changed || attr_changed ||
		 (state->disk_config_valid && !state->current_attr_valid) ||
		 (!state->disk_semantic_valid &&
		  state->current_semantic_explicit) ||
		 (!state->disk_attr_valid &&
		  state->current_attr_sources_present) ||
		 clean_status_filter_scope_needs_validation(istate));
	trace2_data_intmax("fsmonitor", istate->repo,
			   "config/coherent", coherent);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/initial-mismatch", state->strong_mismatch);
}

static int current_proof_is_writable(const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && istate->fsmonitor_token_valid &&
		istate->fsmonitor_last_update &&
		state->config_enforced && state->current_config_valid &&
		state->current_semantic_valid && state->current_attr_valid &&
		state->manifest.current_valid &&
		(state->manifest.current_flags & FSMONITOR_CLEAN_PROOF_ALL) ==
			FSMONITOR_CLEAN_PROOF_ALL &&
		!clean_status_filter_scope_needs_validation(istate) &&
		clean_status_revalidated_token_matches(istate);
}

void clean_status_advance_fsmonitor_config_token(
	struct index_state *istate, const char *next_token)
{
	struct clean_status_state *state = istate->clean_status;

	if (!next_token || !current_proof_is_writable(istate))
		return;
	FREE_AND_NULL(state->config_revalidated_token);
	state->config_revalidated_token = xstrdup(next_token);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "config/token-advanced", 1);
}

int clean_status_should_write_fsmonitor_config(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return current_proof_is_writable(istate) ||
		(state && state->disk_config_valid &&
		 !state->disk_config_invalid && state->disk_config_raw.len);
}

void clean_status_write_fsmonitor_config(struct strbuf *out,
					 const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;
	const struct git_hash_algo *algo = istate->repo->hash_algo;

	if (current_proof_is_writable(istate)) {
		struct fsmonitor_clean_proof proof = {
			.flags = state->manifest.current_flags,
			.token = (const unsigned char *)istate->fsmonitor_last_update,
			.token_len = strlen(istate->fsmonitor_last_update),
			.config_hash = state->current_config_hash,
			.semantic_hash = state->current_semantic_hash,
			.attr_hash = state->current_attr_hash,
			.attr_manifest =
				(const unsigned char *)state->manifest.current.buf,
			.attr_manifest_len = state->manifest.current.len,
		};

		if (fsmonitor_clean_proof_write(out, &proof, algo))
			BUG("cannot serialize validated fsmonitor clean proof");
		return;
	}
	if (fsmonitor_clean_proof_copy_without_bindings(
		out, state->disk_config_raw.buf, state->disk_config_raw.len, algo))
		BUG("cannot preserve validated fsmonitor clean proof");
}
