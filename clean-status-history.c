#include "git-compat-util.h"
#include "abspath.h"
#include "attr-fingerprint.h"
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
#include "replace-object.h"
#include "repository.h"
#include "semantic-verify-internal.h"
#include "strbuf.h"
#include "trace2.h"
#include "ewah/ewok.h"

#define CLEAN_STATUS_HISTORY_SCHEMA "builtin-fsmonitor-history-v2"

static struct repository *external_history_source_repo;

static void invalidate_disk_history(struct clean_status_state *state)
{
	state->disk_config_seen = 1;
	state->disk_config_invalid = 1;
	state->disk_config_valid = 0;
	state->disk_semantic_valid = 0;
	state->disk_tracked_policy_valid = 0;
	memset(state->disk_tracked_policy_hash, 0,
	       sizeof(state->disk_tracked_policy_hash));
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
	if (proof.tracked_policy_hash) {
		memcpy(state->disk_tracked_policy_hash,
		       proof.tracked_policy_hash,
		       istate->repo->hash_algo->rawsz);
		state->disk_tracked_policy_valid = 1;
	} else {
		state->disk_tracked_policy_valid = 0;
		memset(state->disk_tracked_policy_hash, 0,
		       sizeof(state->disk_tracked_policy_hash));
	}
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
	int token_coherent, config_coherent, tracked_policy_coherent;
	int semantic_changed, attr_changed;
	int legacy_empty_attributes = 0;
	int manifest_reusable;
	int coherent;

	istate->fsmonitor_untracked_revalidation_authenticated = 0;
	if (!state || !state->current_config_valid)
		return 0;
	token_coherent = state->disk_config_valid &&
		!state->disk_config_invalid && istate->fsmonitor_token_valid &&
		istate->fsmonitor_last_update && state->disk_config_token &&
		!strcmp(state->disk_config_token, istate->fsmonitor_last_update);
	tracked_policy_coherent = !state->disk_tracked_policy_valid ||
		(state->current_tracked_policy_valid &&
		 !memcmp(state->disk_tracked_policy_hash,
			 state->current_tracked_policy_hash, algo->rawsz));
	config_coherent = state->disk_config_valid &&
		tracked_policy_coherent &&
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
	if (attr_changed && token_coherent && state->disk_semantic_valid &&
	    state->current_semantic_valid && !semantic_changed &&
	    state->disk_attr_valid && state->current_attr_valid &&
	    !state->current_attr_sources_present && !state->filter_configured &&
	    state->manifest.disk_valid &&
	    (state->manifest.disk_flags & FSMONITOR_CLEAN_PROOF_ALL) ==
		FSMONITOR_CLEAN_PROOF_ALL &&
	    !getenv(INDEX_ENVIRONMENT) &&
	    !getenv(GIT_WORK_TREE_ENVIRONMENT) &&
	    !getenv(GIT_COMMON_DIR_ENVIRONMENT) &&
	    !getenv(ALTERNATE_DB_ENVIRONMENT) &&
	    istate == istate->repo->index && !istate->split_index &&
	    istate->sparse_index == INDEX_EXPANDED &&
	    fsm_settings__get_mode(istate->repo) == FSMONITOR_MODE_IPC &&
	    !repo_has_replace_refs_uncached(istate->repo) &&
	    attr_fingerprint_matches_legacy_absent_sources(
		istate->repo, state->disk_attr_hash)) {
		attr_changed = 0;
		legacy_empty_attributes = 1;
	}
	coherent = token_coherent && config_coherent &&
		state->disk_semantic_valid && state->current_semantic_valid &&
		!semantic_changed && state->disk_attr_valid &&
		state->current_attr_valid && !attr_changed &&
		state->manifest.disk_valid &&
		(state->manifest.disk_flags & FSMONITOR_CLEAN_PROOF_ALL) ==
			FSMONITOR_CLEAN_PROOF_ALL;
	istate->fsmonitor_untracked_revalidation_authenticated =
		token_coherent && config_coherent &&
		state->disk_semantic_valid && state->current_semantic_valid &&
		!semantic_changed && state->disk_attr_valid &&
		state->current_attr_valid && !attr_changed &&
		state->disk_tracked_policy_valid &&
		state->current_tracked_policy_valid &&
		state->manifest.disk_valid &&
		state->manifest.disk_flags ==
			(FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
			 FSMONITOR_CLEAN_PROOF_FULL_INDEX) &&
		!getenv(INDEX_ENVIRONMENT) &&
		!getenv(GIT_COMMON_DIR_ENVIRONMENT) &&
		!getenv(ALTERNATE_DB_ENVIRONMENT) &&
		istate == istate->repo->index && !istate->split_index &&
		istate->sparse_index == INDEX_EXPANDED && fstat_is_reliable() &&
		istate->repo->config_values_private_.trust_ctime &&
		istate->repo->config_values_private_.check_stat &&
		fsm_settings__get_mode(istate->repo) == FSMONITOR_MODE_IPC &&
		istate->untracked && istate->untracked->root &&
		istate->untracked->root->valid &&
		istate->untracked->fsmonitor_revalidation &&
		istate->fsmonitor_untracked_extension_seen &&
		!istate->fsmonitor_untracked_extension_invalid &&
		!istate->fsmonitor_untracked_valid &&
		istate->fsmonitor_untracked_token &&
		starts_with(istate->fsmonitor_last_update, "builtin:") &&
		istate->fsmonitor_last_update[strlen("builtin:")] &&
		strcmp(istate->fsmonitor_last_update, "builtin:fake") &&
		starts_with(istate->fsmonitor_untracked_token, "pending:") &&
		!strcmp(istate->fsmonitor_last_update + strlen("builtin:"),
			istate->fsmonitor_untracked_token + strlen("pending:"));
	manifest_reusable = token_coherent && !config_coherent &&
		state->disk_semantic_valid && state->current_semantic_valid &&
		!semantic_changed && state->disk_attr_valid &&
		state->current_attr_valid && !attr_changed &&
		!state->filter_configured && state->manifest.disk_valid &&
		(state->manifest.disk_flags & FSMONITOR_CLEAN_PROOF_ALL) ==
			FSMONITOR_CLEAN_PROOF_ALL;
	state->filter_scope_valid =
		(coherent || istate->fsmonitor_untracked_revalidation_authenticated) &&
		state->filter_configured;
	state->config_revalidated = coherent;
	state->initial_coherent = coherent;
	FREE_AND_NULL(state->config_revalidated_token);
	if (coherent) {
		state->config_revalidated_token =
			xstrdup(istate->fsmonitor_last_update);
		clean_status_manifest_adopt_disk(&state->manifest);
	} else if (manifest_reusable) {
		clean_status_manifest_adopt_disk(&state->manifest);
		if (trace)
			trace2_data_intmax("fsmonitor", istate->repo,
					   "semantic/manifest-reused", 1);
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
		if (legacy_empty_attributes)
			trace2_data_intmax("fsmonitor", istate->repo,
					   "semantic/legacy-empty-attributes", 1);
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

int clean_status_pending_revalidation_manifest_unchanged(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;
	const uint32_t required = FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		FSMONITOR_CLEAN_PROOF_FULL_INDEX;

	return state && istate->fsmonitor_untracked_revalidation_authenticated &&
		state->manifest.disk_valid && state->manifest.current_valid &&
		state->manifest.checked && !state->manifest.current_invalidated &&
		!state->manifest.global_fallback && !state->manifest.changed &&
		(state->manifest.disk_flags & required) == required &&
		(state->manifest.current_flags & required) == required &&
		!memcmp(state->manifest.disk_hash, state->manifest.current_hash,
			istate->repo->hash_algo->rawsz);
}

int clean_status_try_preserve_tracked_config_epoch(
	struct index_state *istate)
{
	struct clean_status_state *state = istate->clean_status;
	const struct git_hash_algo *algo;
	int attr_matches;

	if (!state || !istate->repo || istate != istate->repo->index)
		return 0;
	algo = istate->repo->hash_algo;
	attr_matches = state->disk_attr_valid &&
		state->current_attr_valid &&
		(!memcmp(state->disk_attr_hash, state->current_attr_hash,
			 algo->rawsz) ||
		 attr_fingerprint_matches_legacy_absent_sources(
			 istate->repo, state->disk_attr_hash));
	if (!state->config_enforced || !state->config_mismatch ||
	    state->strong_mismatch || !state->disk_config_valid ||
	    state->disk_config_invalid || !state->disk_config_raw.len ||
	    !state->current_config_valid || !state->disk_semantic_valid ||
	    !state->current_semantic_valid ||
	    memcmp(state->disk_semantic_hash, state->current_semantic_hash,
		   algo->rawsz) || !attr_matches ||
	    (!state->disk_tracked_policy_valid &&
	     state->current_attr_sources_present) ||
	    state->filter_configured ||
	    !state->manifest.disk_valid || !state->manifest.current_valid ||
	    !state->manifest.checked || state->manifest.current_invalidated ||
	    state->manifest.global_fallback ||
	    (state->manifest.disk_flags & FSMONITOR_CLEAN_PROOF_ALL) !=
		FSMONITOR_CLEAN_PROOF_ALL ||
	    (state->manifest.current_flags & FSMONITOR_CLEAN_PROOF_ALL) !=
		FSMONITOR_CLEAN_PROOF_ALL ||
	    !istate->fsmonitor_token_valid ||
	    !istate->fsmonitor_last_update || !state->disk_config_token ||
	    strcmp(state->disk_config_token, istate->fsmonitor_last_update) ||
	    istate->split_index || istate->sparse_index != INDEX_EXPANDED ||
	    fsm_settings__get_mode(istate->repo) != FSMONITOR_MODE_IPC ||
	    repo_has_replace_refs_uncached(istate->repo) ||
	    !state->current_tracked_policy_valid ||
	    (state->disk_tracked_policy_valid ?
		memcmp(state->disk_tracked_policy_hash,
		       state->current_tracked_policy_hash, algo->rawsz) :
		!clean_status_config_tracked_sources_predate_index(istate)))
		return 0;
	clean_status_mark_fsmonitor_config_valid(
		istate, istate->fsmonitor_last_update);
	if (!clean_status_revalidated_token_matches(istate))
		return 0;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "config/tracked-epoch-valid", 1);
	return 1;
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
	if (strcmp(istate->fsmonitor_last_update, next_token))
		clean_status_clear_authenticated_new_directories(istate);
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
			.tracked_policy_hash =
				state->current_tracked_policy_valid ?
				state->current_tracked_policy_hash : NULL,
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
	hash_length_delimited(&ctx,
			      state->current_attr_portable_namespace_hash,
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

void clean_status_require_external_history_source(struct repository *repo)
{
	external_history_source_repo = repo;
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

static enum fsmonitor_query_outcome external_token_query_outcome(
	const char *token)
{
	struct fsmonitor_query_result result =
		FSMONITOR_QUERY_RESULT_INIT;
	enum fsmonitor_query_outcome outcome =
		query_builtin_fsmonitor(token, &result);

	fsmonitor_query_result_release(&result);
	return outcome;
}

static int missing_fsmonitor_token_is_replayable(
	struct index_state *istate, struct index_state *parsed)
{
	struct fsmonitor_query_result result =
		FSMONITOR_QUERY_RESULT_INIT;
	const char *token = parsed->fsmonitor_last_update;
	const char *path, *end;
	int replayable = 0;

	if (!token || !starts_with(token, "builtin:") ||
	    !strcmp(token, "builtin:fake") ||
	    query_builtin_fsmonitor(token, &result) !=
		FSMONITOR_QUERY_DELTA)
		goto done;
	path = result.paths.buf;
	end = result.paths.buf + result.paths.len;
	while (path < end) {
		size_t len = strlen(path);
		const char *base = find_last_dir_sep(path);

		base = base ? base + 1 : path;
		if (!strcmp(path, FSMONITOR_PATH_GLOBAL_INVALIDATE) ||
		    starts_with(path, FSMONITOR_PATH_HARDLINK_INODE_PREFIX))
			goto done;
		if (!fspathcmp(base, ".gitattributes")) {
			struct index_state witness = *istate;

			witness.clean_status = parsed->clean_status;
			witness.fsmonitor_last_update =
				parsed->fsmonitor_last_update;
			witness.fsmonitor_token_valid =
				parsed->fsmonitor_token_valid;
			if (!clean_status_manifest_reconcile_deleted_attribute(
				    &witness, path)) {
				struct clean_status_state *state =
					parsed->clean_status;
				struct strbuf proof = STRBUF_INIT;

				if (!clean_status_manifest_reconcile_display_only_attribute(
					    &witness, path))
					goto done;
				clean_status_write_fsmonitor_config(
					&proof, parsed);
				strbuf_reset(&state->disk_config_raw);
				strbuf_addbuf(&state->disk_config_raw, &proof);
				strbuf_reset(&state->manifest.disk);
				strbuf_addbuf(&state->manifest.disk,
					      &state->manifest.current);
				memcpy(state->manifest.disk_hash,
				       state->manifest.current_hash,
				       parsed->repo->hash_algo->rawsz);
				state->manifest.disk_flags =
					state->manifest.current_flags;
				strbuf_release(&proof);
			}
		}
		path += len + 1;
	}
	replayable = path == end;

done:
	fsmonitor_query_result_release(&result);
	return replayable;
}

static void invalidate_unwatched_recovered_entry(size_t pos, void *data)
{
	struct index_state *istate = data;

	if (pos >= istate->cache_nr)
		BUG("recovered fsmonitor entry is outside the index");
	fsmonitor_invalidate_cache_entry(istate->cache[pos]);
}

#ifdef __APPLE__
static int external_semantic_delta_is_safe(
	const struct strbuf *paths, struct index_state *old_index,
	struct index_state *new_index)
{
	const char *path = paths->buf;
	const char *end = paths->buf + paths->len;

	while (path < end) {
		size_t len = strlen(path);
		const char *base = find_last_dir_sep(path);

		base = base ? base + 1 : path;
		if (!len ||
		    starts_with(path, FSMONITOR_PATH_HARDLINK_INODE_PREFIX) ||
		    !fspathcmp(base, ".gitattributes") ||
		    !fspathcmp(base, ".gitignore"))
			return 0;
		if (path[len - 1] == '/') {
			int old_pos = index_name_pos(old_index, path, len);
			int new_pos = index_name_pos(new_index, path, len);
			const struct cache_entry *entry;

			old_pos = old_pos < 0 ? -old_pos - 1 : old_pos;
			new_pos = new_pos < 0 ? -new_pos - 1 : new_pos;
			if ((unsigned int)old_pos < old_index->cache_nr &&
			    starts_with(old_index->cache[old_pos]->name, path))
				return 0;
			if ((unsigned int)new_pos >= new_index->cache_nr ||
			    !starts_with(new_index->cache[new_pos]->name, path)) {
				path += len + 1;
				continue;
			}
			entry = new_index->cache[new_pos];
			if (!clean_status_index_entry_is_semantically_safe(
				    old_index, NULL, entry))
				return 0;
		}
		path += len + 1;
	}
	return path == end;
}

static void invalidate_external_checkpoint_entry(size_t pos, void *data)
{
	struct index_state *istate = data;

	if (pos < istate->cache_nr)
		istate->cache[pos]->ce_flags &= ~CE_FSMONITOR_VALID;
}

static int external_checkpoint_path_was_replayed(
	const char *name, const struct strbuf *paths)
{
	const char *path = paths->buf;
	const char *end = paths->buf + paths->len;

	while (path < end) {
		size_t len = strlen(path);

		if (!fspathcmp(name, path) ||
		    (path[len - 1] == '/' && !fspathncmp(name, path, len)))
			return 1;
		path += len + 1;
	}
	return 0;
}

static void restore_external_tracked_history(
	struct index_state *istate, struct index_state *witness,
	const struct clean_status_history_checkpoint *checkpoint,
	const struct strbuf *paths, const struct fsmonitor_clean_proof *proof)
{
	struct index_state parsed = INDEX_STATE_INIT(istate->repo);
	const struct stat_data empty_stat = { 0 };
	unsigned int old_pos = 0, new_pos = 0, restored = 0, i;
	const unsigned int unsafe_flags = CE_VALID | CE_SKIP_WORKTREE |
		CE_INTENT_TO_ADD | CE_CONTENT_CHECK_REQUIRED | CE_STAGEMASK;

	if (!checkpoint->fsmonitor_len || !istate->fsmonitor_dirty)
		return;
	parsed.cache_nr = witness->cache_nr;
	if (read_fsmonitor_extension(&parsed, checkpoint->fsmonitor,
				     checkpoint->fsmonitor_len) ||
	    !parsed.fsmonitor_token_valid || !parsed.fsmonitor_dirty ||
	    !parsed.fsmonitor_last_update ||
	    strlen(parsed.fsmonitor_last_update) != proof->token_len ||
	    memcmp(parsed.fsmonitor_last_update, proof->token,
		   proof->token_len))
		goto done;
	for (i = 0; i < witness->cache_nr; i++)
		if (!S_ISGITLINK(witness->cache[i]->ce_mode))
			witness->cache[i]->ce_flags |= CE_FSMONITOR_VALID;
	ewah_each_bit(parsed.fsmonitor_dirty,
		      invalidate_external_checkpoint_entry, witness);
	for (i = 0; i < istate->cache_nr; i++)
		if (!S_ISGITLINK(istate->cache[i]->ce_mode))
			istate->cache[i]->ce_flags |= CE_FSMONITOR_VALID;
	ewah_each_bit(istate->fsmonitor_dirty,
		      invalidate_external_checkpoint_entry, istate);
	while (old_pos < witness->cache_nr && new_pos < istate->cache_nr) {
		const struct cache_entry *old_entry = witness->cache[old_pos];
		struct cache_entry *new_entry = istate->cache[new_pos];
		int cmp = strcmp(old_entry->name, new_entry->name);
		int recover_stat;

		if (cmp < 0) {
			old_pos++;
			continue;
		}
		if (cmp > 0) {
			new_pos++;
			continue;
		}
		old_pos++;
		new_pos++;
		if ((new_entry->ce_flags & CE_FSMONITOR_VALID) ||
		    !(old_entry->ce_flags & CE_FSMONITOR_VALID) ||
		    ((old_entry->ce_flags | new_entry->ce_flags) & unsafe_flags) ||
		    (!S_ISREG(new_entry->ce_mode) &&
		     !S_ISLNK(new_entry->ce_mode)) ||
		    old_entry->ce_mode != new_entry->ce_mode ||
		    !oideq(&old_entry->oid, &new_entry->oid) ||
		    external_checkpoint_path_was_replayed(
			new_entry->name, paths))
			continue;
		recover_stat = !memcmp(&new_entry->ce_stat_data, &empty_stat,
				       sizeof(empty_stat));
		if (memcmp(&old_entry->ce_stat_data, &new_entry->ce_stat_data,
			   sizeof(old_entry->ce_stat_data)) &&
		    (!recover_stat ||
		     !memcmp(&old_entry->ce_stat_data, &empty_stat,
			     sizeof(empty_stat)) ||
		     is_racy_timestamp(witness, old_entry)))
			continue;
		if (recover_stat)
			new_entry->ce_stat_data = old_entry->ce_stat_data;
		if (is_racy_timestamp(istate, new_entry)) {
			if (recover_stat)
				new_entry->ce_stat_data = empty_stat;
			continue;
		}
		if (recover_stat) {
			new_entry->ce_flags |= CE_UPDATE_IN_BASE;
			istate->cache_changed |= CE_ENTRY_CHANGED;
			istate->clean_status->recovered_tracked_stat = 1;
		}
		new_entry->ce_flags |= CE_FSMONITOR_VALID;
		restored++;
	}
	if (restored) {
		ewah_free(istate->fsmonitor_dirty);
		istate->fsmonitor_dirty = NULL;
		fill_fsmonitor_bitmap(istate);
		trace2_data_intmax("fsmonitor", istate->repo,
				   "history/external-tracked-restored", restored);
	}

done:
	if (parsed.fsmonitor_dirty)
		ewah_free(parsed.fsmonitor_dirty);
	parsed.fsmonitor_dirty = NULL;
	parsed.cache_nr = 0;
	release_index(&parsed);
}

static int external_index_has_other_tracked_sibling(
	struct index_state *istate, const char *name, size_t parent_len)
{
	const unsigned int unsafe_flags =
		CE_STAGEMASK | CE_SKIP_WORKTREE | CE_INTENT_TO_ADD;
	int pos = index_name_pos(istate, name, parent_len);

	if (pos < 0)
		pos = -pos - 1;
	for (; (unsigned int)pos < istate->cache_nr; pos++) {
		const struct cache_entry *entry = istate->cache[pos];

		if (ce_namelen(entry) <= parent_len ||
		    memcmp(entry->name, name, parent_len))
			break;
		if (!strcmp(entry->name, name))
			continue;
		if ((entry->ce_flags & unsafe_flags) ||
		    (!S_ISREG(entry->ce_mode) && !S_ISLNK(entry->ce_mode)))
			continue;
		return 1;
	}
	return 0;
}

static int external_untracked_membership_needs_root_invalidation(
	struct index_state *istate, struct index_state *witness,
	const char *name)
{
	const char *slash = find_last_dir_sep(name);
	size_t parent_len;

	if (!slash || istate->sparse_index || witness->sparse_index)
		return 1;
	parent_len = slash - name + 1;
	return !external_index_has_other_tracked_sibling(
		       witness, name, parent_len) ||
		!external_index_has_other_tracked_sibling(
			istate, name, parent_len);
}

static void restore_external_untracked_history(
	struct index_state *istate, struct index_state *witness,
	const struct clean_status_history_checkpoint *checkpoint,
	const struct strbuf *paths, const struct fsmonitor_clean_proof *proof,
	int persist_recovered_proof)
{
	struct index_state parsed = INDEX_STATE_INIT(istate->repo);
	const char *path = paths->buf;
	const char *end = paths->buf + paths->len;
	unsigned int old_pos = 0, new_pos = 0;
	unsigned int targeted_membership = 0, rooted_membership = 0;
	if (istate->fsmonitor_untracked_valid ||
	    !checkpoint->untracked_cache_len ||
	    !checkpoint->fsmonitor_untracked_len)
		return;
	parsed.untracked = read_untracked_extension(
		checkpoint->untracked_cache,
		checkpoint->untracked_cache_len);
	if (!parsed.untracked ||
	    read_fsmonitor_untracked_extension(
		&parsed, checkpoint->fsmonitor_untracked,
		checkpoint->fsmonitor_untracked_len) ||
	    parsed.fsmonitor_untracked_extension_invalid ||
	    !parsed.fsmonitor_untracked_token ||
	    strlen(parsed.fsmonitor_untracked_token) != proof->token_len ||
	    memcmp(parsed.fsmonitor_untracked_token,
		   proof->token, proof->token_len))
		goto done;
	free_untracked_cache(istate->untracked);
	istate->untracked = parsed.untracked;
	parsed.untracked = NULL;
	istate->untracked->use_fsmonitor = 1;
	FREE_AND_NULL(istate->fsmonitor_untracked_token);
	istate->fsmonitor_untracked_token =
		xstrdup(istate->fsmonitor_last_update);
	istate->fsmonitor_untracked_extension_seen = 1;
	istate->fsmonitor_untracked_extension_invalid = 0;
	istate->fsmonitor_untracked_valid = 1;
	if (persist_recovered_proof) {
		istate->cache_changed |= UNTRACKED_CHANGED;
		istate->fsmonitor_untracked_must_persist = 1;
	}
	while (old_pos < witness->cache_nr || new_pos < istate->cache_nr) {
		const struct cache_entry *old_entry =
			old_pos < witness->cache_nr ?
			witness->cache[old_pos] : NULL;
		const struct cache_entry *new_entry =
			new_pos < istate->cache_nr ?
			istate->cache[new_pos] : NULL;
		int cmp = !old_entry ? 1 : !new_entry ? -1 :
			strcmp(old_entry->name, new_entry->name);

		if (cmp < 0) {
			int rooted =
				external_untracked_membership_needs_root_invalidation(
					istate, witness, old_entry->name);

			untracked_cache_invalidate_path(
				istate, old_entry->name, rooted);
			rooted ? rooted_membership++ : targeted_membership++;
			old_pos++;
		} else if (cmp > 0) {
			int rooted =
				external_untracked_membership_needs_root_invalidation(
					istate, witness, new_entry->name);

			untracked_cache_invalidate_path(
				istate, new_entry->name, rooted);
			rooted ? rooted_membership++ : targeted_membership++;
			new_pos++;
		} else {
			old_pos++;
			new_pos++;
		}
	}
	while (path < end) {
		size_t len = strlen(path);

		untracked_cache_invalidate_trimmed_path(istate, path, 0);
		path += len + 1;
	}
	trace2_data_intmax("fsmonitor", istate->repo,
			   "history/external-untracked-restored", 1);
	if (targeted_membership)
		trace2_data_intmax("fsmonitor", istate->repo,
				   "history/untracked-membership-targeted",
				   targeted_membership);
	if (rooted_membership)
		trace2_data_intmax("fsmonitor", istate->repo,
				   "history/untracked-membership-rooted",
				   rooted_membership);

done:
	release_index(&parsed);
}
#endif

static int restore_external_semantic_history(
	struct index_state *istate,
	const struct clean_status_history_checkpoint *checkpoint,
	const char *proof_namespace,
	const struct clean_status_index_snapshot *snapshot)
{
#ifdef __APPLE__
	struct index_state witness = INDEX_STATE_INIT(istate->repo);
	struct fsmonitor_query_result old = FSMONITOR_QUERY_RESULT_INIT;
	struct fsmonitor_query_result current = FSMONITOR_QUERY_RESULT_INIT;
	struct fsmonitor_clean_proof proof;
	struct clean_status_identity before_identity, after_identity;
	struct stat before, after;
	unsigned char witness_hash[GIT_MAX_RAWSZ];
	struct clean_status_state *state = istate->clean_status;
	char *path = NULL;
	int fd = -1, transferred = 0;
	int missing_current = 0, seeded_current = 0;
	int persist_recovered_proof =
		!istate->fsmonitor_untracked_extension_seen && state &&
		state->initial_coherent &&
		clean_status_has_persistent_fsmonitor_semantic_history(istate);

	if (!checkpoint->source_alias_valid ||
	    fsm_settings__get_mode(istate->repo) != FSMONITOR_MODE_IPC)
		goto done;
	if (!has_usable_on_index_builtin_token(istate)) {
		if (!state || istate != istate->repo->index ||
		    istate->split_index ||
		    istate->sparse_index != INDEX_EXPANDED ||
		    istate->fsmonitor_extension_seen ||
		    istate->fsmonitor_token_valid ||
		    istate->fsmonitor_last_update ||
		    istate->fsmonitor_last_update_pending ||
		    istate->fsmonitor_dirty ||
		    istate->fsmonitor_untracked_extension_seen ||
		    istate->fsmonitor_untracked_token ||
		    istate->fsmonitor_untracked_valid ||
		    state->disk_config_seen || state->disk_config_invalid ||
		    state->filter_configured ||
		    state->current_attr_sources_present ||
		    !istate->repo->config_values_private_.trust_ctime ||
		    !istate->repo->config_values_private_.check_stat)
			goto done;
		missing_current = 1;
	}
	path = clean_status_history_store_witness_path(
		istate->repo->index_file, proof_namespace,
		istate->repo->hash_algo);
	fd = open_nofollow(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0 || fstat(fd, &before) || !S_ISREG(before.st_mode) ||
	    before.st_nlink != 1 || before.st_uid != geteuid() ||
	    clean_status_identity_from_stat(&before_identity, &before) ||
	    lstat(path, &after) || before.st_dev != after.st_dev ||
	    before.st_ino != after.st_ino)
		goto done;
	do_read_index(&witness, path, 1);
	if (fstat(fd, &after) || after.st_nlink != 1 ||
	    after.st_uid != geteuid() ||
	    clean_status_identity_from_stat(&after_identity, &after) ||
	    !clean_status_identity_equal(&before_identity, &after_identity) ||
	    before.st_size != after.st_size ||
	    lstat(path, &after) || before.st_dev != after.st_dev ||
	    before.st_ino != after.st_ino ||
	    witness.version != checkpoint->source_version ||
	    witness.cache_nr != checkpoint->source_cache_nr ||
	    !oideq(&witness.oid, &checkpoint->source_checksum) ||
	    clean_status_index_logical_digest(&witness, witness_hash) ||
	    memcmp(witness_hash, checkpoint->index_hash,
		   istate->repo->hash_algo->rawsz) ||
	    fsmonitor_clean_proof_parse(
		&proof, checkpoint->fsmonitor_config,
		checkpoint->fsmonitor_config_len,
		istate->repo->hash_algo))
		goto done;
	if (missing_current &&
	    ((proof.flags & FSMONITOR_CLEAN_PROOF_ALL) !=
		FSMONITOR_CLEAN_PROOF_ALL || !checkpoint->fsmonitor_len ||
	     !checkpoint->untracked_cache_len ||
	     !checkpoint->fsmonitor_untracked_len))
		goto done;
	clean_status_release(&witness);
	clean_status_attach_config(&witness);
	clean_status_read_fsmonitor_config(
		&witness, checkpoint->fsmonitor_config,
		checkpoint->fsmonitor_config_len);
	free(witness.fsmonitor_last_update);
	witness.fsmonitor_last_update =
		xmemdupz(proof.token, proof.token_len);
	witness.fsmonitor_token_valid = 1;
	clean_status_prepare_fsmonitor_config(&witness);
	if (!current_proof_is_writable(&witness) ||
	    query_builtin_fsmonitor(witness.fsmonitor_last_update, &old) !=
		FSMONITOR_QUERY_DELTA)
		goto done;
	if (!missing_current) {
		if (query_builtin_fsmonitor(istate->fsmonitor_last_update,
					    &current) != FSMONITOR_QUERY_DELTA ||
		    strcmp(old.token.buf, current.token.buf) ||
		    !external_semantic_delta_is_safe(&old.paths,
						    &witness, istate) ||
		    !clean_status_index_snapshot_still_matches_proof_epoch(
			    snapshot, istate))
			goto done;
	}
	if (missing_current) {
		const char *changed = old.paths.buf;
		const char *end = old.paths.buf + old.paths.len;

		if (!has_usable_on_index_builtin_token(&witness) ||
		    !old.token.len ||
		    !starts_with(old.token.buf, "builtin:") ||
		    !strcmp(old.token.buf, "builtin:fake") ||
		    !external_semantic_delta_is_safe(&old.paths,
						    &witness, istate) ||
		    !clean_status_index_snapshot_still_matches_proof_epoch(
			    snapshot, istate))
			goto done;
		while (changed < end) {
			if (!strcmp(changed, FSMONITOR_PATH_GLOBAL_INVALIDATE))
				goto done;
			changed += strlen(changed) + 1;
		}
		if (changed != end)
			goto done;
		for (size_t i = 0; i < istate->cache_nr; i++)
			if (istate->cache[i]->ce_flags & CE_FSMONITOR_VALID)
				goto done;
		istate->fsmonitor_last_update =
			xstrdup(witness.fsmonitor_last_update);
		istate->fsmonitor_token_valid = 1;
		istate->fsmonitor_extension_seen = 1;
		fill_fsmonitor_bitmap(istate);
		seeded_current = 1;
	}
	if (strcmp(witness.fsmonitor_last_update,
		   istate->fsmonitor_last_update)) {
		clean_status_advance_fsmonitor_config_token(
			&witness, istate->fsmonitor_last_update);
		free(witness.fsmonitor_last_update);
		witness.fsmonitor_last_update =
			xstrdup(istate->fsmonitor_last_update);
	}
	transferred =
		clean_status_transfer_current_proof_if_semantically_same_index(
			istate, &witness);
	if (transferred) {
		clean_status_set_authenticated_new_directories(
			istate, &witness, &old.paths);
		restore_external_tracked_history(
			istate, &witness, checkpoint, &old.paths, &proof);
		if (missing_current && istate->fsmonitor_dirty)
			ewah_each_bit(istate->fsmonitor_dirty,
				      invalidate_unwatched_recovered_entry, istate);
		restore_external_untracked_history(
			istate, &witness, checkpoint, &old.paths, &proof,
			persist_recovered_proof);
		trace2_data_intmax("fsmonitor", istate->repo,
				   "history/external-semantic-restored", 1);
		if (missing_current)
			trace2_data_intmax("fsmonitor", istate->repo,
					   "history/external-fsmn-recovered", 1);
	}

done:
	if (seeded_current && !transferred) {
		FREE_AND_NULL(istate->fsmonitor_last_update);
		istate->fsmonitor_token_valid = 0;
		istate->fsmonitor_extension_seen = 0;
		if (istate->fsmonitor_dirty)
			ewah_free(istate->fsmonitor_dirty);
		istate->fsmonitor_dirty = NULL;
		for (size_t i = 0; i < istate->cache_nr; i++)
			istate->cache[i]->ce_flags &= ~CE_FSMONITOR_VALID;
		clean_status_release(istate);
		clean_status_attach_config(istate);
	}
	if (fd >= 0)
		close(fd);
	free(path);
	fsmonitor_query_result_release(&old);
	fsmonitor_query_result_release(&current);
	release_index(&witness);
	return transferred;
#else
	(void)istate;
	(void)checkpoint;
	(void)proof_namespace;
	(void)snapshot;
	return 0;
#endif
}

static int restore_external_bootstrap_manifest(
	struct index_state *istate,
	const struct clean_status_history_checkpoint *checkpoint,
	const char *proof_namespace,
	const struct clean_status_index_snapshot *snapshot)
{
#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	const unsigned int semantic_flags =
		CE_STAGEMASK | CE_VALID | CE_EXTENDED_FLAGS;
	const unsigned int transient_flags =
		CE_UPDATE | CE_REMOVE | CE_ADDED | CE_WT_REMOVE |
		CE_CONFLICTED | CE_UNPACKED | CE_NEW_SKIP_WORKTREE |
		CE_MATCHED | CE_STRIP_NAME | CE_CONTENT_CHECK_REQUIRED;
	struct clean_status_state *state = istate->clean_status;
	struct index_state witness = INDEX_STATE_INIT(istate->repo);
	struct clean_status_identity before_identity, after_identity;
	struct fsmonitor_query_result changes =
		FSMONITOR_QUERY_RESULT_INIT;
	struct fsmonitor_clean_proof proof;
	struct strbuf rewritten = STRBUF_INIT;
	struct stat before, after;
	unsigned char witness_hash[GIT_MAX_RAWSZ];
	char *path = NULL;
	int fd = -1, attr_pos = -1, transferred = 0;

	if (!checkpoint->source_alias_valid || !state ||
	    state->disk_config_invalid || state->filter_configured ||
	    state->current_attr_sources_present || istate->split_index ||
	    istate->sparse_index != INDEX_EXPANDED ||
	    fsm_settings__get_mode(istate->repo) != FSMONITOR_MODE_IPC ||
	    fsmonitor_clean_proof_parse(&proof, checkpoint->fsmonitor_config,
		checkpoint->fsmonitor_config_len,
		istate->repo->hash_algo) ||
	    (proof.flags & FSMONITOR_CLEAN_PROOF_ALL) !=
		FSMONITOR_CLEAN_PROOF_ALL)
		goto done;
	path = clean_status_history_store_witness_path(
		istate->repo->index_file, proof_namespace,
		istate->repo->hash_algo);
	fd = open_nofollow(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0 || fstat(fd, &before) || !S_ISREG(before.st_mode) ||
	    before.st_nlink != 1 || before.st_uid != geteuid() ||
	    clean_status_identity_from_stat(&before_identity, &before) ||
	    lstat(path, &after) || before.st_dev != after.st_dev ||
	    before.st_ino != after.st_ino)
		goto done;
	do_read_index(&witness, path, 1);
	if (fstat(fd, &after) || after.st_nlink != 1 ||
	    after.st_uid != geteuid() ||
	    clean_status_identity_from_stat(&after_identity, &after) ||
	    !clean_status_identity_equal(&before_identity, &after_identity) ||
	    before.st_size != after.st_size ||
	    lstat(path, &after) || before.st_dev != after.st_dev ||
	    before.st_ino != after.st_ino ||
	    witness.version != checkpoint->source_version ||
	    witness.cache_nr != checkpoint->source_cache_nr ||
	    witness.cache_nr != istate->cache_nr ||
	    !oideq(&witness.oid, &checkpoint->source_checksum) ||
	    clean_status_index_logical_digest(&witness, witness_hash) ||
	    memcmp(witness_hash, checkpoint->index_hash,
		   istate->repo->hash_algo->rawsz))
		goto done;
	for (size_t i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *old = witness.cache[i];
		const struct cache_entry *current = istate->cache[i];

		if (ce_namelen(old) != ce_namelen(current) ||
		    memcmp(old->name, current->name, ce_namelen(old) + 1) ||
		    old->ce_mode != current->ce_mode ||
		    ((old->ce_flags ^ current->ce_flags) & semantic_flags) ||
		    ((old->ce_flags | current->ce_flags) & transient_flags))
			goto done;
		if (oideq(&old->oid, &current->oid))
			continue;
		if (attr_pos >= 0 || strcmp(current->name, ".gitattributes") ||
		    !S_ISREG(current->ce_mode))
			goto done;
		attr_pos = i;
	}
	if (attr_pos < 0 ||
	    !clean_status_index_snapshot_still_matches_proof_epoch(
		    snapshot, istate))
		goto done;
	clean_status_release(&witness);
	clean_status_attach_config(&witness);
	clean_status_read_fsmonitor_config(
		&witness, checkpoint->fsmonitor_config,
		checkpoint->fsmonitor_config_len);
	free(witness.fsmonitor_last_update);
	witness.fsmonitor_last_update =
		xmemdupz(proof.token, proof.token_len);
	witness.fsmonitor_token_valid = 1;
	clean_status_prepare_fsmonitor_config(&witness);
	if (!current_proof_is_writable(&witness))
		goto done;
	{
		struct index_state current = *istate;

		current.clean_status = witness.clean_status;
		current.fsmonitor_last_update =
			witness.fsmonitor_last_update;
		current.fsmonitor_token_valid = 1;
		if (!clean_status_manifest_reconcile_display_only_attribute(
			    &current, ".gitattributes"))
			goto done;
	}
	if (!clean_status_index_snapshot_still_matches_proof_epoch(
		    snapshot, istate))
		goto done;
	if (query_builtin_fsmonitor(witness.fsmonitor_last_update,
				      &changes) != FSMONITOR_QUERY_DELTA)
		goto done;
	for (const char *changed = changes.paths.buf,
			 *end = changes.paths.buf + changes.paths.len;
	     changed < end; changed += strlen(changed) + 1) {
		size_t len = strlen(changed);
		const char *base = find_last_dir_sep(changed);

		base = base ? base + 1 : changed;
		if (!len ||
		    !strcmp(changed, FSMONITOR_PATH_GLOBAL_INVALIDATE) ||
		    starts_with(changed, FSMONITOR_PATH_HARDLINK_INODE_PREFIX) ||
		    changed[len - 1] == '/' ||
		    (!fspathcmp(base, ".gitattributes") &&
		     strcmp(changed, ".gitattributes")))
			goto done;
	}
	if (!clean_status_index_snapshot_still_matches_proof_epoch(
		    snapshot, istate))
		goto done;
	clean_status_write_fsmonitor_config(&rewritten, &witness);
	clean_status_release(istate);
	clean_status_attach_config(istate);
	clean_status_read_fsmonitor_config(
		istate, rewritten.buf, rewritten.len);
	state = istate->clean_status;
	state->config_mismatch = 0;
	state->strong_mismatch = 0;
	state->initial_coherent = 0;
	state->config_revalidated = 0;
	clean_status_manifest_adopt_disk(&state->manifest);
	state->manifest.checked = 1;
	state->manifest.global_fallback = 0;
	state->manifest.current_invalidated = 0;
	state->authenticated_bootstrap_manifest = 1;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "history/external-bootstrap-manifest", 1);
	transferred = 1;

done:
	if (fd >= 0)
		close(fd);
	free(path);
	fsmonitor_query_result_release(&changes);
	strbuf_release(&rewritten);
	release_index(&witness);
	return transferred;
#else
	(void)istate;
	(void)checkpoint;
	(void)proof_namespace;
	(void)snapshot;
	return 0;
#endif
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
	int missing_fsmonitor_recovery = 0;
	int owned_index = 0;
	int preserve_witness = 0;
	int provider_reset_recovery = 0;
	int restored = 0;

	if (!clean_status_external_history_enabled(istate) || !state ||
	    state->disk_config_invalid ||
	    !state->config_enforced ||
	    !state->current_config_valid || !state->current_semantic_valid ||
	    !state->current_attr_valid || getenv(INDEX_ENVIRONMENT) ||
	    istate != istate->repo->index ||
	    on_index_history_is_coherent(istate) ||
	    clean_status_index_snapshot_pin_proof_epoch(&snapshot, istate))
		goto done;
	/*
	 * An unbound proof for the current configuration records deliberate
	 * invalidation. A legacy writer removes FSCF entirely, while a proof
	 * from another configuration must not hide this namespace's checkpoint.
	 */
	if (state->disk_config_valid &&
	    !memcmp(state->disk_config_hash, state->current_config_hash,
		    istate->repo->hash_algo->rawsz) &&
	    !clean_status_has_persistent_fsmonitor_semantic_history(istate)) {
		missing_fsmonitor_recovery =
			!istate->fsmonitor_extension_seen &&
			!istate->fsmonitor_token_valid &&
			!istate->fsmonitor_last_update &&
			fsm_settings__get_mode(istate->repo) ==
				FSMONITOR_MODE_IPC &&
			istate->repo->config_values_private_.trust_ctime &&
			istate->repo->config_values_private_.check_stat;
		if (!missing_fsmonitor_recovery) {
			trace2_data_intmax("fsmonitor", istate->repo,
					   "history/external-proof-invalidated", 1);
			goto done;
		}
	}
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
	if (!record_loaded && external_history_source_repo != istate->repo) {
		if (missing_fsmonitor_recovery)
			trace2_data_intmax("fsmonitor", istate->repo,
					   "history/external-proof-invalidated", 1);
		goto done;
	}
	if (clean_status_index_logical_digest(istate, index_hash))
		goto done;

have_index_hash:
	memcpy(state->source_logical_hash, index_hash,
	       istate->repo->hash_algo->rawsz);
	state->source_logical_hash_valid = 1;
	if (!record_loaded) {
		if (missing_fsmonitor_recovery)
			trace2_data_intmax("fsmonitor", istate->repo,
					   "history/external-proof-invalidated", 1);
		goto done;
	}
	if (memcmp(index_hash, record.checkpoint.index_hash,
		   istate->repo->hash_algo->rawsz)) {
		if (missing_fsmonitor_recovery) {
			if (restore_external_bootstrap_manifest(
				    istate, &record.checkpoint, proof_namespace,
				    &snapshot))
				goto done;
			trace2_data_intmax("fsmonitor", istate->repo,
					   "history/external-proof-invalidated", 1);
			goto done;
		}
		restored = restore_external_semantic_history(
			istate, &record.checkpoint, proof_namespace, &snapshot);
		goto done;
	}
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
	if (missing_fsmonitor_recovery &&
	    (!parsed.untracked ||
	     !missing_fsmonitor_token_is_replayable(istate, &parsed))) {
		trace2_data_intmax("fsmonitor", istate->repo,
				   "history/external-proof-invalidated", 1);
		goto done;
	}
	/*
	 * Provider tokens are opaque.  A logical-index match says that the
	 * checkpoint names the same staged entries; it does not say that its
	 * token can still replay the interval which the named index already
	 * crossed.  Probe a differing checkpoint token before replacing a
	 * usable on-index boundary when builtin IPC can answer that question.
	 * A successful delta is queried again by the normal refresh path; a
	 * failed probe leaves the named index intact. If both tokens receive a
	 * trivial response, neither boundary can be replayed: a complete,
	 * authenticated checkpoint can still seed the existing forward
	 * baseline and parallel untracked-directory revalidation.
	 */
	if (fsm_settings__get_mode(istate->repo) == FSMONITOR_MODE_IPC &&
	    has_usable_on_index_builtin_token(istate) &&
	    starts_with(parsed.fsmonitor_last_update, "builtin:") &&
	    strcmp(istate->fsmonitor_last_update,
		   parsed.fsmonitor_last_update)) {
		enum fsmonitor_query_outcome outcome =
			external_token_query_outcome(
				parsed.fsmonitor_last_update);

		if (outcome != FSMONITOR_QUERY_DELTA) {
			if (outcome != FSMONITOR_QUERY_TRIVIAL ||
			    !fstat_is_reliable() ||
			    !record.checkpoint.source_alias_valid ||
			    istate->split_index ||
			    istate->sparse_index != INDEX_EXPANDED ||
			    !parsed.untracked || !parsed.untracked->root ||
			    !parsed.untracked->root->valid ||
			    !parsed.untracked->root->valid_recursive ||
			    !parsed.fsmonitor_untracked_valid ||
			    !parsed.fsmonitor_untracked_extension_seen ||
			    parsed.fsmonitor_untracked_extension_invalid ||
			    !istate->repo->config_values_private_.trust_ctime ||
			    !istate->repo->config_values_private_.check_stat ||
			    external_token_query_outcome(
				    istate->fsmonitor_last_update) !=
					FSMONITOR_QUERY_TRIVIAL) {
				trace2_data_intmax(
					"fsmonitor", istate->repo,
					"history/external-token-unreplayable", 1);
				goto done;
			}
			provider_reset_recovery = 1;
		}
	}
	if (!clean_status_index_snapshot_still_matches_proof_epoch(
		    &snapshot, istate))
		goto done;
	owned_index = !getenv(GIT_WORK_TREE_ENVIRONMENT) &&
		!getenv(GIT_COMMON_DIR_ENVIRONMENT) &&
		!istate->split_index &&
		!state->current_attr_sources_present &&
		istate->sparse_index == INDEX_EXPANDED &&
		!state->disk_config_invalid &&
		((!state->disk_config_seen && !state->disk_config_valid &&
		  fsm_settings__get_mode(istate->repo) == FSMONITOR_MODE_IPC &&
		  has_usable_on_index_builtin_token(istate) &&
		  has_usable_on_index_builtin_token(&parsed) &&
		  !strcmp(istate->fsmonitor_last_update,
			  parsed.fsmonitor_last_update)) ||
		 (state->disk_config_seen && state->disk_config_valid &&
		  state->disk_semantic_valid && state->disk_attr_valid &&
		  state->manifest.disk_valid &&
		  (((state->manifest.disk_flags & FSMONITOR_CLEAN_PROOF_ALL) ==
			FSMONITOR_CLEAN_PROOF_ALL) ||
		   (missing_fsmonitor_recovery &&
		    clean_status_has_worktree_manifest_history(istate))) &&
		  !memcmp(state->disk_config_hash,
			  state->current_config_hash,
			  istate->repo->hash_algo->rawsz) &&
		  !memcmp(state->disk_semantic_hash,
			  state->current_semantic_hash,
			  istate->repo->hash_algo->rawsz) &&
		  !memcmp(state->disk_attr_hash,
			  state->current_attr_hash,
			  istate->repo->hash_algo->rawsz)));
	preserve_witness = !state->disk_config_seen &&
		!istate->fsmonitor_untracked_valid &&
		has_usable_on_index_builtin_token(istate);
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
	if (missing_fsmonitor_recovery)
		ewah_each_bit(istate->fsmonitor_dirty,
			      invalidate_unwatched_recovered_entry, istate);
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
	if (provider_reset_recovery)
		trace2_data_intmax("fsmonitor", istate->repo,
				   "history/external-reset-restored", 1);
	if (missing_fsmonitor_recovery)
		trace2_data_intmax("fsmonitor", istate->repo,
				   "history/external-fsmn-recovered", 1);
	state->external_history_restored = 1;
	state->external_history_owned_index = owned_index;
	state->external_history_preserve_witness = preserve_witness;
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

int clean_status_external_history_needs_witness_preservation(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->external_history_restored &&
		state->external_history_preserve_witness &&
		!state->external_history_owned_index &&
		istate == istate->repo->index &&
		current_proof_is_writable(istate);
}

int clean_status_has_recovered_tracked_stat(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->recovered_tracked_stat &&
		(istate->cache_changed & CE_ENTRY_CHANGED) &&
		istate == istate->repo->index &&
		current_proof_is_writable(istate);
}

int clean_status_has_authenticated_bootstrap_manifest(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->authenticated_bootstrap_manifest &&
		state->manifest.current_valid && state->manifest.checked &&
		!state->manifest.current_invalidated &&
		(state->manifest.current_flags &
			(FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
			 FSMONITOR_CLEAN_PROOF_FULL_INDEX)) ==
			(FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
			 FSMONITOR_CLEAN_PROOF_FULL_INDEX);
}

int clean_status_external_history_owns_index(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->external_history_restored &&
		state->external_history_owned_index &&
		istate == istate->repo->index &&
		!getenv(INDEX_ENVIRONMENT) && !istate->split_index &&
		istate->sparse_index == INDEX_EXPANDED;
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
	memcpy(dst_state->disk_tracked_policy_hash,
	       src_state->disk_tracked_policy_hash,
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
	dst_state->disk_tracked_policy_valid =
		src_state->disk_tracked_policy_valid;
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

static int replace_current_fsmonitor_proof(struct index_state *dst,
					   const struct index_state *src)
{
	struct index_state replacement = INDEX_STATE_INIT(dst->repo);
	struct strbuf proof = STRBUF_INIT;
	int transferred = 0;

	/* Preserve the destination's source identity and retained index fd. */
	clean_status_write_fsmonitor_config(&proof, src);
	clean_status_read_fsmonitor_config(&replacement, proof.buf, proof.len);
	if (replacement.clean_status &&
	    replacement.clean_status->disk_config_valid &&
	    !replacement.clean_status->disk_config_invalid) {
		dst->fsmonitor_token_valid = src->fsmonitor_token_valid;
		clean_status_copy_fsmonitor_history(dst, &replacement);
		clean_status_attach_config(dst);
		clean_status_prepare_fsmonitor_config(dst);
		transferred = current_proof_is_writable(dst);
	}
	clean_status_release(&replacement);
	strbuf_release(&proof);

	return transferred;
}

int clean_status_transfer_current_proof_if_same_index(
	struct index_state *dst, const struct index_state *src)
{
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
	return replace_current_fsmonitor_proof(dst, src);
}

int clean_status_transfer_current_proof_if_semantically_same_index(
	struct index_state *dst, const struct index_state *src)
{
	const unsigned int semantic_flags =
		CE_STAGEMASK | CE_VALID | CE_EXTENDED_FLAGS;
	unsigned int src_pos = 0, dst_pos = 0;
	int transferred;

	if (!current_proof_is_writable(src) ||
	    src->repo != dst->repo || src->split_index || dst->split_index ||
	    src->sparse_index || dst->sparse_index ||
	    (src->cache_changed & RESOLVE_UNDO_CHANGED) ||
	    src->resolve_undo ||
	    !src->fsmonitor_last_update || !dst->fsmonitor_last_update ||
	    strcmp(src->fsmonitor_last_update, dst->fsmonitor_last_update))
		return 0;

	while (src_pos < src->cache_nr || dst_pos < dst->cache_nr) {
		const struct cache_entry *old = src_pos < src->cache_nr ?
			src->cache[src_pos] : NULL;
		const struct cache_entry *new_entry = dst_pos < dst->cache_nr ?
			dst->cache[dst_pos] : NULL;
		int cmp;

		if (!old)
			cmp = 1;
		else if (!new_entry)
			cmp = -1;
		else
			cmp = strcmp(old->name, new_entry->name);
		if (cmp < 0) {
			if (!clean_status_index_entry_is_semantically_safe(
				    src, old, NULL))
				return 0;
			src_pos++;
		} else if (cmp > 0) {
			if (!clean_status_index_entry_is_semantically_safe(
				    src, NULL, new_entry))
				return 0;
			dst_pos++;
		} else {
			if ((old->ce_mode != new_entry->ce_mode ||
			     !oideq(&old->oid, &new_entry->oid) ||
			     ((old->ce_flags ^ new_entry->ce_flags) & semantic_flags)) &&
			    !clean_status_index_entry_is_semantically_safe(
				    src, old, new_entry))
				return 0;
			src_pos++;
			dst_pos++;
		}
	}

	if (current_proof_is_writable(dst)) {
		const struct clean_status_state *src_state = src->clean_status;
		const struct clean_status_state *dst_state = dst->clean_status;
		size_t rawsz = dst->repo->hash_algo->rawsz;

		if (memcmp(src_state->current_config_hash,
			   dst_state->current_config_hash, rawsz) ||
		    memcmp(src_state->current_semantic_hash,
			   dst_state->current_semantic_hash, rawsz) ||
		    memcmp(src_state->current_attr_hash,
			   dst_state->current_attr_hash, rawsz) ||
		    src_state->manifest.current_flags !=
			    dst_state->manifest.current_flags ||
		    src_state->manifest.current.len !=
			    dst_state->manifest.current.len ||
		    memcmp(src_state->manifest.current.buf,
			   dst_state->manifest.current.buf,
			   src_state->manifest.current.len))
			return 0;
		trace2_data_intmax("fsmonitor", dst->repo,
				   "history/semantic-transferred", 1);
		return 1;
	}

	transferred = replace_current_fsmonitor_proof(dst, src);
	if (transferred)
		trace2_data_intmax("fsmonitor", dst->repo,
				   "history/semantic-transferred", 1);

	return transferred;
}
