#include "git-compat-util.h"
#include "abspath.h"
#include "clean-status.h"
#include "clean-status-history-store.h"
#include "clean-status-index.h"
#include "clean-status-internal.h"
#include "dir.h"
#include "environment.h"
#include "fsmonitor.h"
#include "fsmonitor-clean-proof.h"
#include "fsmonitor-ll.h"
#include "fsmonitor-settings.h"
#include "hash-framing.h"
#include "hex.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "strbuf.h"
#include "trace2.h"
#include "ewah/ewok.h"

#define CLEAN_STATUS_HISTORY_SCHEMA "builtin-fsmonitor-history-v2"

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

static int prepare_fsmonitor_config(struct index_state *istate, int trace)
{
	struct clean_status_state *state = istate->clean_status;
	const struct git_hash_algo *algo = istate->repo->hash_algo;
	int token_coherent, config_coherent, semantic_changed, attr_changed;
	int coherent;

	if (!state || !state->current_config_valid)
		return 0;
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
	if (trace) {
		trace2_data_intmax("fsmonitor", istate->repo,
				   "config/coherent", coherent);
		trace2_data_intmax("fsmonitor", istate->repo,
				   "semantic/initial-mismatch",
				   state->strong_mismatch);
	}
	return coherent;
}

void clean_status_prepare_fsmonitor_config(struct index_state *istate)
{
	prepare_fsmonitor_config(istate, 1);
}

int clean_status_probe_fsmonitor_config(struct index_state *istate)
{
	return prepare_fsmonitor_config(istate, 0);
}

int clean_status_has_persistent_fsmonitor_semantic_history(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->disk_config_valid &&
		!state->disk_config_invalid && state->disk_semantic_valid &&
		state->disk_attr_valid && state->manifest.disk_valid &&
		(state->manifest.disk_flags & FSMONITOR_CLEAN_PROOF_ALL) ==
			FSMONITOR_CLEAN_PROOF_ALL &&
		state->disk_config_raw.len;
}

int clean_status_has_worktree_manifest_history(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;
	uint32_t required = FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		FSMONITOR_CLEAN_PROOF_FULL_INDEX;

	return state && state->disk_config_valid &&
		!state->disk_config_invalid && state->manifest.disk_valid &&
		(state->manifest.disk_flags & required) == required;
}

int clean_status_fsmonitor_semantic_adoption_needed(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;
	int missing_history;

	if (!state || !state->current_config_valid || !state->config_enforced)
		return 0;
	if (state->semantic_baseline_pending)
		return 0;
	missing_history =
		!clean_status_has_persistent_fsmonitor_semantic_history(istate) &&
		!clean_status_has_worktree_manifest_history(istate);
	/*
	 * Keep missing history on the proof path until fsmonitor explicitly
	 * chooses the narrow forward-baseline lane for a valid legacy token.
	 */
	return state->strong_mismatch || missing_history ||
		clean_status_filter_scope_needs_validation(istate);
}

int clean_status_fsmonitor_semantic_baseline_needed(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;
	const struct repo_config_values *cfg;

	if (!state || !state->current_config_valid || !state->config_enforced ||
	    state->strong_mismatch || state->disk_config_seen ||
	    !istate->fsmonitor_token_valid ||
	    !istate->fsmonitor_last_update ||
	    !*istate->fsmonitor_last_update)
		return 0;
	/*
	 * This helper is exercised by isolated index-state unit fixtures,
	 * which are not the_repository. The config values are already
	 * initialized with the repository and need no lazy parsing here.
	 */
	cfg = &istate->repo->config_values_private_;
	if (!cfg->trust_ctime || !cfg->check_stat)
		return 0;
	return !clean_status_has_persistent_fsmonitor_semantic_history(istate) &&
		!clean_status_has_worktree_manifest_history(istate);
}

int clean_status_fsmonitor_semantic_baseline_pending(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->semantic_baseline_pending;
}

void clean_status_begin_fsmonitor_semantic_baseline(
	struct index_state *istate)
{
	struct clean_status_state *state = clean_status_get_state(istate);

	state->semantic_baseline_pending = 1;
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

struct clean_status_external_checkpoint {
	char proof_namespace[GIT_MAX_HEXSZ + 1];
	struct clean_status_history_checkpoint checkpoint;
	struct strbuf fsmonitor;
	struct strbuf untracked_cache;
	struct strbuf fsmonitor_config;
	struct strbuf fsmonitor_untracked;
};

static void clean_status_release_external_history(
	struct clean_status_external_checkpoint *checkpoint);

static int external_history_namespace(struct index_state *istate, char *out)
{
	static const char domain[] = "git-clean-status-history-key-v2";
	struct clean_status_state *state = istate->clean_status;
	struct git_hash_ctx ctx;
	unsigned char hash[GIT_MAX_RAWSZ];
	char *worktree = NULL, *gitdir = NULL, *commondir = NULL;
	int ret = -1;

	if (!state || !state->current_config_valid ||
	    !state->current_semantic_valid || !state->current_attr_valid ||
	    !repo_get_work_tree(istate->repo))
		return -1;
	worktree = real_pathdup(repo_get_work_tree(istate->repo), 0);
	gitdir = real_pathdup(repo_get_git_dir(istate->repo), 0);
	commondir = real_pathdup(repo_get_common_dir(istate->repo), 0);
	if (!worktree || !gitdir || !commondir)
		goto done;
	git_hash_init(&ctx, istate->repo->hash_algo);
	hash_length_delimited(&ctx, domain, sizeof(domain) - 1);
	hash_length_delimited(&ctx, CLEAN_STATUS_HISTORY_SCHEMA,
			      strlen(CLEAN_STATUS_HISTORY_SCHEMA));
	hash_length_delimited(&ctx, state->current_config_hash,
			      istate->repo->hash_algo->rawsz);
	hash_length_delimited(&ctx, state->current_semantic_hash,
			      istate->repo->hash_algo->rawsz);
	hash_length_delimited(&ctx, state->current_attr_namespace_hash,
			      istate->repo->hash_algo->rawsz);
	hash_length_delimited(&ctx, worktree, strlen(worktree));
	hash_length_delimited(&ctx, gitdir, strlen(gitdir));
	hash_length_delimited(&ctx, commondir, strlen(commondir));
	git_hash_final(hash, &ctx);
	hash_to_hex_algop_r(out, hash, istate->repo->hash_algo);
	ret = 0;

done:
	free(worktree);
	free(gitdir);
	free(commondir);
	return ret;
}

void clean_status_capture_external_history_source(
	struct index_state *istate)
{
	struct clean_status_history_store_record record =
		CLEAN_STATUS_HISTORY_STORE_RECORD_INIT;
	struct clean_status_index_snapshot snapshot = { .fd = -1 };
	struct clean_status_state *state = istate->clean_status;
	char proof_namespace[GIT_MAX_HEXSZ + 1];

	if (!clean_status_external_history_enabled(istate) ||
	    getenv(INDEX_ENVIRONMENT) || istate != istate->repo->index ||
	    !state)
		goto done;
	if (state->source_logical_hash_valid)
		goto done;
	if (!clean_status_has_persistent_fsmonitor_semantic_history(istate))
		goto done;
	if (clean_status_index_snapshot_pin_proof_epoch(&snapshot, istate))
		goto done;
	if (!external_history_namespace(istate, proof_namespace) &&
	    !clean_status_history_store_load(
		    istate->repo->index_file, proof_namespace,
		    istate->repo->hash_algo, &record) &&
	    clean_status_index_can_reuse_source_logical_hash(istate) &&
	    clean_status_history_checkpoint_source_matches(
		    istate->repo->index_file, &record.checkpoint,
		    &snapshot, istate->repo->hash_algo)) {
		memcpy(state->source_logical_hash,
		       record.checkpoint.index_hash,
		       istate->repo->hash_algo->rawsz);
	} else if (clean_status_index_logical_digest(
			   istate, state->source_logical_hash)) {
		goto done;
	}
	if (!clean_status_index_snapshot_still_matches_proof_epoch(
		    &snapshot, istate))
		goto done;
	state->source_logical_hash_valid = 1;

done:
	clean_status_index_snapshot_release(&snapshot);
	clean_status_history_store_record_release(&record);
}

static struct clean_status_external_checkpoint *
clean_status_prepare_external_history(struct index_state *istate)
{
	struct clean_status_external_checkpoint *checkpoint;
	struct clean_status_state *state = istate->clean_status;
	const unsigned int acceleration_changes =
		CE_ENTRY_CHANGED | FSMONITOR_CHANGED | UNTRACKED_CHANGED;

	if (!clean_status_external_history_enabled(istate) ||
	    getenv(INDEX_ENVIRONMENT) || istate != istate->repo->index)
		return NULL;
	if (!state || !state->source_logical_hash_valid) {
		trace2_data_string("fsmonitor", istate->repo,
				   "history/external-save-reject", "missing-source");
		return NULL;
	}
	if (!current_proof_is_writable(istate)) {
		trace2_data_string("fsmonitor", istate->repo,
				   "history/external-save-reject", "unwritable-proof");
		return NULL;
	}
	if (istate->cache_changed & ~acceleration_changes) {
		trace2_data_string("fsmonitor", istate->repo,
				   "history/external-save-reject", "logical-flags");
		return NULL;
	}
	if (has_racy_timestamp(istate)) {
		trace2_data_string("fsmonitor", istate->repo,
				   "history/external-save-reject", "racy-index");
		return NULL;
	}
	CALLOC_ARRAY(checkpoint, 1);
	checkpoint->fsmonitor = (struct strbuf)STRBUF_INIT;
	checkpoint->untracked_cache = (struct strbuf)STRBUF_INIT;
	checkpoint->fsmonitor_config = (struct strbuf)STRBUF_INIT;
	checkpoint->fsmonitor_untracked = (struct strbuf)STRBUF_INIT;
	if (external_history_namespace(
		    istate, checkpoint->proof_namespace)) {
		trace2_data_string("fsmonitor", istate->repo,
				   "history/external-save-reject", "namespace");
		goto fail;
	}
	if (clean_status_index_can_reuse_source_logical_hash(istate)) {
		memcpy(checkpoint->checkpoint.index_hash,
		       state->source_logical_hash,
		       istate->repo->hash_algo->rawsz);
	} else if (clean_status_index_logical_digest_after_status(
			   istate, checkpoint->checkpoint.index_hash)) {
		trace2_data_string("fsmonitor", istate->repo,
				   "history/external-save-reject", "logical-flags");
		goto fail;
	}
	if (memcmp(checkpoint->checkpoint.index_hash,
		   state->source_logical_hash,
		   istate->repo->hash_algo->rawsz)) {
		trace2_data_string("fsmonitor", istate->repo,
				   "history/external-save-reject", "logical-change");
		goto fail;
	}
	snapshot_fsmonitor_extension(&checkpoint->fsmonitor, istate);
	clean_status_write_fsmonitor_config(
		&checkpoint->fsmonitor_config, istate);
	if (istate->untracked) {
		if (!istate->fsmonitor_untracked_valid ||
		    !istate->fsmonitor_untracked_token ||
		    strcmp(istate->fsmonitor_untracked_token,
			   istate->fsmonitor_last_update)) {
			trace2_data_string(
				"fsmonitor", istate->repo,
				"history/external-save-reject", "untracked-token");
			goto fail;
		}
		write_untracked_extension(
			&checkpoint->untracked_cache, istate->untracked);
		write_fsmonitor_untracked_extension(
			&checkpoint->fsmonitor_untracked, istate);
	}
	checkpoint->checkpoint.fsmonitor =
		(const unsigned char *)checkpoint->fsmonitor.buf;
	checkpoint->checkpoint.fsmonitor_len = checkpoint->fsmonitor.len;
	checkpoint->checkpoint.untracked_cache =
		checkpoint->untracked_cache.len ?
			(const unsigned char *)checkpoint->untracked_cache.buf :
			NULL;
	checkpoint->checkpoint.untracked_cache_len =
		checkpoint->untracked_cache.len;
	checkpoint->checkpoint.fsmonitor_config =
		(const unsigned char *)checkpoint->fsmonitor_config.buf;
	checkpoint->checkpoint.fsmonitor_config_len =
		checkpoint->fsmonitor_config.len;
	checkpoint->checkpoint.fsmonitor_untracked =
		checkpoint->fsmonitor_untracked.len ?
			(const unsigned char *)checkpoint->fsmonitor_untracked.buf :
			NULL;
	checkpoint->checkpoint.fsmonitor_untracked_len =
		checkpoint->fsmonitor_untracked.len;
	return checkpoint;

fail:
	clean_status_release_external_history(checkpoint);
	return NULL;
}

static int clean_status_install_external_history(
	struct index_state *istate,
	struct clean_status_external_checkpoint *checkpoint)
{
	struct clean_status_index_snapshot snapshot = { .fd = -1 };
	int installed = 0;

	if (!checkpoint ||
	    clean_status_index_snapshot_pin_proof_epoch(&snapshot, istate) ||
	    clean_status_history_store_install(
		    istate->repo->index_file, checkpoint->proof_namespace,
		    &checkpoint->checkpoint, &snapshot,
		    istate->repo->hash_algo))
		goto done;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "history/external-stored", 1);
	installed = 1;

done:
	clean_status_index_snapshot_release(&snapshot);
	return installed;
}

static void clean_status_release_external_history(
	struct clean_status_external_checkpoint *checkpoint)
{
	if (!checkpoint)
		return;
	strbuf_release(&checkpoint->fsmonitor);
	strbuf_release(&checkpoint->untracked_cache);
	strbuf_release(&checkpoint->fsmonitor_config);
	strbuf_release(&checkpoint->fsmonitor_untracked);
	free(checkpoint);
}

int clean_status_save_external_history(struct index_state *istate)
{
	struct clean_status_external_checkpoint *checkpoint =
		clean_status_prepare_external_history(istate);
	int saved = clean_status_install_external_history(
		istate, checkpoint);

	clean_status_release_external_history(checkpoint);
	return saved;
}

static int on_index_history_is_coherent(struct index_state *istate)
{
	struct clean_status_state *state = istate->clean_status;

	if (!state || !state->disk_config_seen)
		return 0;
	clean_status_probe_fsmonitor_config(istate);
	prepare_fsmonitor_untracked(istate);
	return state->initial_coherent &&
		(!istate->untracked || istate->fsmonitor_untracked_valid);
}

static int has_usable_on_index_builtin_token(
	const struct index_state *istate)
{
	return istate->fsmonitor_token_valid &&
		istate->fsmonitor_last_update &&
		*istate->fsmonitor_last_update &&
		starts_with(istate->fsmonitor_last_update, "builtin:") &&
		strcmp(istate->fsmonitor_last_update, "builtin:fake");
}

static int external_token_is_replayable(const char *token)
{
	struct fsmonitor_query_result result =
		FSMONITOR_QUERY_RESULT_INIT;
	int replayable =
		query_builtin_fsmonitor(token, &result) ==
			FSMONITOR_QUERY_DELTA;

	fsmonitor_query_result_release(&result);
	return replayable;
}

int clean_status_restore_external_history(struct index_state *istate)
{
	struct clean_status_history_store_record record =
		CLEAN_STATUS_HISTORY_STORE_RECORD_INIT;
	struct clean_status_index_snapshot snapshot = { .fd = -1 };
	struct clean_status_state *state = istate->clean_status;
	struct index_state parsed = INDEX_STATE_INIT(istate->repo);
	unsigned char index_hash[GIT_MAX_RAWSZ];
	char proof_namespace[GIT_MAX_HEXSZ + 1];
	int record_loaded = 0;
	int restored = 0;

	if (!clean_status_external_history_enabled(istate) || !state ||
	    !state->config_enforced ||
	    !state->current_config_valid || !state->current_semantic_valid ||
	    !state->current_attr_valid || getenv(INDEX_ENVIRONMENT) ||
	    istate != istate->repo->index ||
	    on_index_history_is_coherent(istate) ||
	    clean_status_index_snapshot_pin_proof_epoch(&snapshot, istate))
		goto done;
	if (external_history_namespace(istate, proof_namespace))
		goto done;
	if (!clean_status_history_store_load(
		    istate->repo->index_file, proof_namespace,
		    istate->repo->hash_algo, &record)) {
		record_loaded = 1;
		if (clean_status_index_can_reuse_source_logical_hash(istate) &&
		    clean_status_history_checkpoint_source_matches(
			    istate->repo->index_file, &record.checkpoint,
			    &snapshot, istate->repo->hash_algo)) {
			memcpy(index_hash, record.checkpoint.index_hash,
			       istate->repo->hash_algo->rawsz);
			trace2_data_intmax("fsmonitor", istate->repo,
					   "history/external-physical-alias", 1);
			goto have_index_hash;
		}
	}
	if (clean_status_index_logical_digest(istate, index_hash))
		goto done;

have_index_hash:
	memcpy(state->source_logical_hash, index_hash,
	       istate->repo->hash_algo->rawsz);
	state->source_logical_hash_valid = 1;
	if (!record_loaded ||
	    memcmp(index_hash, record.checkpoint.index_hash,
		   istate->repo->hash_algo->rawsz))
		goto done;
	parsed.cache_nr = istate->cache_nr;
	if (read_fsmonitor_extension(
		    &parsed, record.checkpoint.fsmonitor,
		    record.checkpoint.fsmonitor_len) ||
	    !parsed.fsmonitor_token_valid || !parsed.fsmonitor_last_update ||
	    !parsed.fsmonitor_dirty)
		goto done;
	if (record.checkpoint.untracked_cache_len) {
		parsed.untracked = read_untracked_extension(
			record.checkpoint.untracked_cache,
			record.checkpoint.untracked_cache_len);
		read_fsmonitor_untracked_extension(
			&parsed, record.checkpoint.fsmonitor_untracked,
			record.checkpoint.fsmonitor_untracked_len);
		if (!parsed.untracked ||
		    parsed.fsmonitor_untracked_extension_invalid ||
		    !parsed.fsmonitor_untracked_token ||
		    strcmp(parsed.fsmonitor_untracked_token,
			   parsed.fsmonitor_last_update))
			goto done;
	}
	clean_status_attach_config(&parsed);
	clean_status_read_fsmonitor_config(
		&parsed, record.checkpoint.fsmonitor_config,
		record.checkpoint.fsmonitor_config_len);
	prepare_fsmonitor_untracked(&parsed);
	clean_status_probe_fsmonitor_config(&parsed);
	if (!current_proof_is_writable(&parsed) ||
	    (!!parsed.untracked && !parsed.fsmonitor_untracked_valid))
		goto done;
	/*
	 * Provider tokens are opaque.  A logical-index match says that the
	 * checkpoint names the same staged entries; it does not say that its
	 * token can still replay the interval which the named index already
	 * crossed.  Probe a differing checkpoint token before replacing a
	 * usable on-index boundary when builtin IPC can answer that question.
	 * A successful delta is queried again by the normal refresh path; a
	 * trivial or failed probe leaves the named index intact so its token
	 * can take the forward-baseline fallback.
	 */
	if (fsm_settings__get_mode(istate->repo) == FSMONITOR_MODE_IPC &&
	    has_usable_on_index_builtin_token(istate) &&
	    starts_with(parsed.fsmonitor_last_update, "builtin:") &&
	    strcmp(istate->fsmonitor_last_update,
		   parsed.fsmonitor_last_update) &&
	    !external_token_is_replayable(parsed.fsmonitor_last_update)) {
		trace2_data_intmax("fsmonitor", istate->repo,
				   "history/external-token-unreplayable", 1);
		goto done;
	}
	if (!clean_status_index_snapshot_still_matches_proof_epoch(
		    &snapshot, istate))
		goto done;
	clean_status_invalidate_current_proof(istate);
	clean_status_copy_fsmonitor_history(istate, &parsed);
	FREE_AND_NULL(istate->fsmonitor_last_update);
	FREE_AND_NULL(istate->fsmonitor_last_update_pending);
	istate->fsmonitor_pending_token_from_provider = 0;
	if (istate->fsmonitor_dirty)
		ewah_free(istate->fsmonitor_dirty);
	istate->fsmonitor_last_update = parsed.fsmonitor_last_update;
	parsed.fsmonitor_last_update = NULL;
	istate->fsmonitor_dirty = parsed.fsmonitor_dirty;
	parsed.fsmonitor_dirty = NULL;
	istate->fsmonitor_token_valid = 1;
	istate->fsmonitor_extension_seen = 1;
	free_untracked_cache(istate->untracked);
	istate->untracked = parsed.untracked;
	parsed.untracked = NULL;
	FREE_AND_NULL(istate->fsmonitor_untracked_token);
	istate->fsmonitor_untracked_token =
		parsed.fsmonitor_untracked_token;
	parsed.fsmonitor_untracked_token = NULL;
	istate->fsmonitor_untracked_extension_seen =
		parsed.fsmonitor_untracked_extension_seen;
	istate->fsmonitor_untracked_extension_invalid = 0;
	istate->fsmonitor_untracked_valid =
		parsed.fsmonitor_untracked_valid;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "history/external-restored", 1);
	state->external_history_restored = 1;
	restored = 1;

done:
	if (parsed.fsmonitor_dirty)
		ewah_free(parsed.fsmonitor_dirty);
	parsed.fsmonitor_dirty = NULL;
	parsed.cache_nr = 0;
	release_index(&parsed);
	clean_status_index_snapshot_release(&snapshot);
	clean_status_history_store_record_release(&record);
	return restored;
}

int clean_status_external_history_was_restored(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->external_history_restored;
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
