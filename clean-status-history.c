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
			FSMONITOR_CLEAN_PROOF_ALL &&
		!state->unsafe_filter;
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
		(state->disk_config_invalid || state->unsafe_filter ||
		 semantic_changed || attr_changed ||
		 (state->disk_config_valid && !state->current_attr_valid) ||
		 (!state->disk_semantic_valid &&
		  state->current_semantic_explicit) ||
		 (!state->disk_attr_valid &&
		  state->current_attr_sources_present));
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

void clean_status_copy_fsmonitor_history(struct index_state *dst,
					 const struct index_state *src)
{
	const struct clean_status_state *src_state = src->clean_status;
	struct clean_status_state *dst_state;

	if (!src_state || !src_state->disk_config_valid ||
	    src_state->disk_config_invalid || !src_state->disk_config_raw.len)
		return;
	dst_state = clean_status_get_state(dst);
	FREE_AND_NULL(dst_state->disk_config_token);
	strbuf_reset(&dst_state->disk_config_raw);
	dst_state->disk_config_token =
		xstrdup_or_null(src_state->disk_config_token);
	strbuf_addbuf(&dst_state->disk_config_raw,
		      &src_state->disk_config_raw);
	memcpy(dst_state->disk_config_hash, src_state->disk_config_hash,
	       dst->repo->hash_algo->rawsz);
	memcpy(dst_state->disk_semantic_hash, src_state->disk_semantic_hash,
	       dst->repo->hash_algo->rawsz);
	memcpy(dst_state->disk_attr_hash, src_state->disk_attr_hash,
	       dst->repo->hash_algo->rawsz);
	if (clean_status_manifest_load(
		&dst_state->manifest, src_state->manifest.disk.buf,
		src_state->manifest.disk.len, src_state->manifest.disk_flags,
		dst->repo->hash_algo))
		BUG("cannot copy validated clean-status manifest");
	dst_state->disk_config_seen = 1;
	dst_state->disk_config_valid = 1;
	dst_state->disk_semantic_valid = src_state->disk_semantic_valid;
	dst_state->disk_attr_valid = src_state->disk_attr_valid;
	dst_state->disk_config_invalid = 0;
}

static int same_persistent_index_contents(const struct index_state *a,
					  const struct index_state *b)
{
	const unsigned int semantic_flags =
		CE_STAGEMASK | CE_VALID | CE_EXTENDED_FLAGS;
	const unsigned int transient_flags =
		CE_UPDATE | CE_REMOVE | CE_ADDED | CE_WT_REMOVE |
		CE_CONFLICTED | CE_UNPACKED | CE_NEW_SKIP_WORKTREE |
		CE_MATCHED | CE_STRIP_NAME;
	unsigned int i;

	if (a->repo != b->repo || a->split_index || b->split_index ||
	    a->sparse_index || b->sparse_index ||
	    a->cache_nr != b->cache_nr)
		return 0;

	for (i = 0; i < a->cache_nr; i++) {
		const struct cache_entry *ce_a = a->cache[i];
		const struct cache_entry *ce_b = b->cache[i];

		if (ce_namelen(ce_a) != ce_namelen(ce_b) ||
		    memcmp(ce_a->name, ce_b->name, ce_namelen(ce_a) + 1) ||
		    ce_a->ce_mode != ce_b->ce_mode ||
		    !oideq(&ce_a->oid, &ce_b->oid) ||
		    ((ce_a->ce_flags ^ ce_b->ce_flags) & semantic_flags) ||
		    ((ce_a->ce_flags | ce_b->ce_flags) & transient_flags))
			return 0;
	}

	return 1;
}

int clean_status_transfer_current_proof_if_same_index(
	struct index_state *dst, const struct index_state *src)
{
	struct strbuf proof = STRBUF_INIT;
	int transferred;

	if (!current_proof_is_writable(src) ||
	    !src->fsmonitor_last_update ||
	    !dst->fsmonitor_last_update ||
	    strcmp(src->fsmonitor_last_update, dst->fsmonitor_last_update) ||
	    !same_persistent_index_contents(dst, src))
		return 0;

	/*
	 * Reparse the current proof as the destination's disk proof, then
	 * reattach the current command's digest. This copies only a proof
	 * which the destination's identical logical entries can support.
	 */
	clean_status_write_fsmonitor_config(&proof, src);
	dst->fsmonitor_token_valid = src->fsmonitor_token_valid;
	clean_status_read_fsmonitor_config(dst, proof.buf, proof.len);
	clean_status_attach_config(dst);
	clean_status_prepare_fsmonitor_config(dst);
	transferred = current_proof_is_writable(dst);
	strbuf_release(&proof);

	return transferred;
}
