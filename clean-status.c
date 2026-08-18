#include "git-compat-util.h"
#include "attr-fingerprint.h"
#include "attr-manifest.h"
#include "clean-status.h"
#include "clean-status-index.h"
#include "clean-status-internal.h"
#include "convert.h"
#include "dir.h"
#include "environment.h"
#include "fsmonitor-clean-proof.h"
#include "fsmonitor-settings.h"
#include "progress.h"
#include "read-cache-ll.h"
#include "replace-object.h"
#include "repository.h"
#include "semantic-verify-internal.h"
#include "worktree-attr-source.h"
#include "thread-utils.h"
#include "trace2.h"

static struct repository *configured_repo;
static unsigned char configured_hash[GIT_MAX_RAWSZ];
static unsigned char configured_semantic_hash[GIT_MAX_RAWSZ];
static unsigned char configured_tracked_policy_hash[GIT_MAX_RAWSZ];
static struct repository *external_history_repo;
static struct repository *progress_repo;
static int configured_hash_valid;
static int configured_filter_configured;
static int configured_semantic_explicit;

struct clean_status_progress {
	struct progress *display;
	pthread_mutex_t mutex;
	uint64_t completed;
};

void clean_status_enable_external_history(struct repository *repo)
{
	external_history_repo = repo;
}

int clean_status_external_history_enabled(const struct index_state *istate)
{
	return istate && istate->repo == external_history_repo;
}

void clean_status_enable_progress(struct repository *repo)
{
	progress_repo = repo;
}

struct clean_status_progress *clean_status_start_progress(
	struct repository *repo, const char *title, uint64_t total)
{
	struct clean_status_progress *progress;

	if (repo != progress_repo)
		return NULL;
	CALLOC_ARRAY(progress, 1);
	if (HAVE_THREADS && pthread_mutex_init(&progress->mutex, NULL))
		BUG("could not initialize clean status progress mutex");
	progress->display = start_delayed_progress(repo, title, total);
	return progress;
}

void clean_status_update_progress(struct clean_status_progress *progress,
				  uint64_t completed)
{
	if (!progress || !completed)
		return;
	pthread_mutex_lock(&progress->mutex);
	progress->completed += completed;
	display_progress(progress->display, progress->completed);
	pthread_mutex_unlock(&progress->mutex);
}

void clean_status_stop_progress(struct clean_status_progress **progress)
{
	if (!progress || !*progress)
		return;
	stop_progress(&(*progress)->display);
	pthread_mutex_destroy(&(*progress)->mutex);
	FREE_AND_NULL(*progress);
}

struct clean_status_state *clean_status_get_state(struct index_state *istate)
{
	if (!istate->clean_status) {
		CALLOC_ARRAY(istate->clean_status, 1);
		istate->clean_status->source_index_fd = -1;
		clean_status_manifest_init(&istate->clean_status->manifest);
		strbuf_init(&istate->clean_status->disk_config_raw, 0);
		strbuf_init(&istate->clean_status->authenticated_new_directories,
			    0);
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
	memcpy(configured_tracked_policy_hash,
	       digest->tracked_policy_hash, repo->hash_algo->rawsz);
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
	memcpy(state->current_tracked_policy_hash,
	       configured_tracked_policy_hash,
	       istate->repo->hash_algo->rawsz);
	state->current_config_valid = 1;
	state->current_semantic_valid = 1;
	state->current_tracked_policy_valid = 1;
	state->current_semantic_explicit = configured_semantic_explicit;
	state->config_enforced = 1;
	state->filter_configured = configured_filter_configured;
	if (!attr_fingerprint_repository(istate->repo, &attrs)) {
		memcpy(state->current_attr_hash, attrs.content_hash,
		       istate->repo->hash_algo->rawsz);
		memcpy(state->current_attr_namespace_hash, attrs.namespace_hash,
		       istate->repo->hash_algo->rawsz);
		memcpy(state->current_attr_portable_namespace_hash,
		       attrs.portable_namespace_hash,
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

void clean_status_mark_filter_scope_valid(struct index_state *istate)
{
	struct clean_status_state *state = istate->clean_status;

	if (!state || !state->current_config_valid || !state->config_enforced ||
	    !state->filter_configured)
		return;
	state->filter_scope_valid = 1;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "filter-scope/valid", 1);
}

int clean_status_revalidated_token_matches(const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && !state->backoff_token && state->config_revalidated &&
		state->config_revalidated_token &&
		istate->fsmonitor_last_update &&
		!strcmp(state->config_revalidated_token,
			istate->fsmonitor_last_update);
}

void clean_status_invalidate_current_proof(struct index_state *istate)
{
	if (!istate->clean_status)
		return;
	clean_status_clear_authenticated_new_directories(istate);
	istate->clean_status->config_revalidated = 0;
	istate->clean_status->initial_coherent = 0;
	istate->clean_status->filter_scope_valid = 0;
	istate->clean_status->semantic_baseline_pending = 0;
	istate->clean_status->backoff_suspended = 0;
}

int clean_status_fsmonitor_backoff_suspended(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->backoff_suspended && state->backoff_token &&
		istate->fsmonitor_token_valid && istate->fsmonitor_last_update &&
		!strcmp(state->backoff_token, istate->fsmonitor_last_update) &&
		fsm_settings__is_watch_limit_backoff(istate->repo);
}

int clean_status_suspend_fsmonitor_for_backoff(struct index_state *istate)
{
	struct clean_status_state *state = istate->clean_status;
	struct clean_status_index_snapshot source = { .fd = -1 };
	const struct git_hash_algo *algo;
	const struct untracked_cache *uc = istate->untracked;
	const char *suffix, *pending;
	const uint32_t historical = FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		FSMONITOR_CLEAN_PROOF_FULL_INDEX;
	int paired, suspended = 0;

	/* Never revive an epoch which an earlier mutation has invalidated. */
	if (state && state->backoff_token)
		return clean_status_fsmonitor_backoff_suspended(istate);
	if (!state || !istate->repo || !istate->repo->worktree ||
	    !fsm_settings__is_watch_limit_backoff(istate->repo) ||
	    !fstat_is_reliable() || istate != istate->repo->index ||
	    getenv(INDEX_ENVIRONMENT) || getenv(GIT_WORK_TREE_ENVIRONMENT) ||
	    getenv(GIT_COMMON_DIR_ENVIRONMENT) || getenv(DB_ENVIRONMENT) ||
	    getenv(ALTERNATE_DB_ENVIRONMENT) || istate->split_index ||
	    istate->sparse_index != INDEX_EXPANDED ||
	    repo_config_values(istate->repo)->apply_sparse_checkout ||
	    !istate->repo->config_values_private_.trust_ctime ||
	    !istate->repo->config_values_private_.check_stat ||
	    repo_has_replace_refs_uncached(istate->repo) ||
	    !state->config_enforced || !state->current_config_valid ||
	    !state->current_semantic_valid || !state->current_attr_valid ||
	    !state->current_tracked_policy_valid || state->filter_configured ||
	    state->external_history_restored || !state->disk_config_valid ||
	    state->disk_config_invalid || !state->disk_config_raw.len ||
	    !state->disk_semantic_valid || !state->disk_attr_valid ||
	    !state->disk_tracked_policy_valid || !state->manifest.disk_valid ||
	    !istate->fsmonitor_extension_seen || !istate->fsmonitor_token_valid ||
	    !istate->fsmonitor_last_update ||
	    !skip_prefix(istate->fsmonitor_last_update, "builtin:", &suffix) ||
	    !*suffix || !strcmp(suffix, "fake") ||
	    !state->disk_config_token ||
	    strcmp(state->disk_config_token, istate->fsmonitor_last_update) ||
	    istate->fsmonitor_last_update_pending ||
	    istate->fsmonitor_pending_token_from_provider ||
	    istate->fsmonitor_legacy_untracked_fallback ||
	    !uc || !uc->root || !uc->root->valid ||
	    uc->fsmonitor_dirty_paths.len ||
	    !istate->fsmonitor_untracked_extension_seen ||
	    istate->fsmonitor_untracked_extension_invalid ||
	    !istate->fsmonitor_untracked_token)
		return 0;
	algo = istate->repo->hash_algo;
	if (memcmp(state->disk_config_hash, state->current_config_hash,
		   algo->rawsz) ||
	    memcmp(state->disk_semantic_hash, state->current_semantic_hash,
		   algo->rawsz) ||
	    memcmp(state->disk_attr_hash, state->current_attr_hash, algo->rawsz) ||
	    memcmp(state->disk_tracked_policy_hash,
		   state->current_tracked_policy_hash, algo->rawsz))
		return 0;

	paired = state->manifest.disk_flags == FSMONITOR_CLEAN_PROOF_ALL &&
		clean_status_has_current_full_fsmonitor_proof(istate) &&
		!memcmp(state->manifest.disk_hash, state->manifest.current_hash,
			algo->rawsz) &&
		istate->fsmonitor_untracked_valid && uc->root->valid_recursive &&
		!strcmp(istate->fsmonitor_last_update,
			istate->fsmonitor_untracked_token);
	if (!paired &&
	    !(state->manifest.disk_flags == historical &&
	      !istate->fsmonitor_untracked_valid && uc->fsmonitor_revalidation &&
	      skip_prefix(istate->fsmonitor_untracked_token, "pending:", &pending) &&
	      !strcmp(suffix, pending)))
		return 0;
	if (clean_status_index_snapshot_pin_proof_epoch(&source, istate))
		return 0;
	if (!untracked_cache_preserve_for_revalidation(istate) ||
	    !clean_status_index_snapshot_still_matches_proof_epoch(&source, istate))
		goto done;

	/* Only historical path semantics survive. Nothing is currently clean. */
	clean_status_manifest_adopt_disk(&state->manifest);
	state->manifest.current_flags = historical;
	clean_status_clear_authenticated_new_directories(istate);
	state->authenticated_bootstrap_manifest = 0;
	state->config_revalidated = 0;
	state->initial_coherent = 0;
	state->config_mismatch = 1;
	state->filter_scope_valid = 0;
	FREE_AND_NULL(state->config_revalidated_token);
	state->backoff_token = xstrdup(istate->fsmonitor_last_update);
	state->backoff_suspended = 1;
	state->semantic_baseline_pending = 1;
	suspended = 1;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "history/watch-limit-suspended", 1);
done:
	clean_status_index_snapshot_release(&source);
	return suspended;
}

static int path_has_no_new_attribute_sources(
	const struct index_state *istate, const char *name,
	int allow_removed_parent)
{
	const struct clean_status_manifest_state *manifest =
		&istate->clean_status->manifest;
	struct semantic_verify_root *root = NULL;
	struct semantic_verify_path *path = NULL;
	struct strbuf candidate = STRBUF_INIT;
	const char *slash = name;
	unsigned char hash[GIT_MAX_RAWSZ];
	unsigned int namespace_unstable = 0;
	size_t position = 0;
	int safe = 0;

	if (!strchr(name, '/'))
		return 1;
	if (semantic_verify_root_init(istate->repo, &root))
		goto done;
	path = semantic_verify_path_new(root);
	while ((slash = strchr(slash, '/')) != NULL) {
		struct attr_manifest_cursor cursor;
		struct attr_manifest_entry entry;
		const struct cache_entry *source = NULL;
		const char *basename;
		unsigned int low = 0, high = istate->cache_nr;
		int parent_fd, found, matched = 0, missing_parent = 0;

		strbuf_reset(&candidate);
		strbuf_add(&candidate, name, slash - name + 1);
		strbuf_addstr(&candidate, ".gitattributes");
		if (semantic_verify_resolve_parent(path, candidate.buf,
						 position, &parent_fd,
						 &basename)) {
			if (!allow_removed_parent || errno != ENOENT)
				goto done;
			missing_parent = 1;
			found = 0;
		} else if (worktree_attr_source_read(path, candidate.buf,
						     position,
						     istate->repo->hash_algo,
						     hash, &found)) {
			goto done;
		}
		position++;
		while (low < high) {
			unsigned int middle = low + (high - low) / 2;
			const struct cache_entry *ce = istate->cache[middle];
			int cmp = strcmp(ce->name, candidate.buf);

			if (!cmp) {
				source = ce;
				break;
			}
			if (cmp < 0)
				low = middle + 1;
			else
				high = middle;
		}
		if (!source && !found && !missing_parent) {
			slash++;
			continue;
		}
		if (!manifest->current_valid || manifest->current_invalidated ||
		    (manifest->current_flags &
		     (FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		      FSMONITOR_CLEAN_PROOF_FULL_INDEX)) !=
			    (FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
			     FSMONITOR_CLEAN_PROOF_FULL_INDEX))
			goto done;
		if (attr_manifest_cursor_init(&cursor, manifest->current.buf,
					      manifest->current.len,
					      istate->repo->hash_algo))
			goto done;
		if (missing_parent) {
			if (source)
				goto done;
			while (attr_manifest_cursor_next(&cursor, &entry) > 0)
				if (entry.path_len == candidate.len &&
				    !memcmp(entry.path, candidate.buf, candidate.len))
					goto done;
			slash++;
			continue;
		}
		if (!source || !S_ISREG(source->ce_mode) || ce_stage(source) ||
		    ce_skip_worktree(source) || ce_intent_to_add(source) ||
		    (source->ce_flags & CE_VALID))
			goto done;
		while (attr_manifest_cursor_next(&cursor, &entry) > 0) {
			if (entry.path_len != candidate.len ||
			    memcmp(entry.path, candidate.buf, candidate.len))
				continue;
			matched = found ?
				entry.source == ATTR_MANIFEST_WORKTREE &&
				!memcmp(entry.hash, hash,
					istate->repo->hash_algo->rawsz) :
				entry.source == ATTR_MANIFEST_INDEX &&
				!memcmp(entry.hash, source->oid.hash,
					istate->repo->hash_algo->rawsz);
			break;
		}
		if (!matched)
			goto done;
		slash++;
	}
	semantic_verify_path_free(path, &namespace_unstable, NULL);
	path = NULL;
	safe = !namespace_unstable && semantic_verify_root_stable(root);

done:
	if (path)
		semantic_verify_path_free(path, &namespace_unstable, NULL);
	semantic_verify_root_clear(root);
	strbuf_release(&candidate);
	return safe;
}

int clean_status_index_entry_is_semantically_safe(
	const struct index_state *istate,
	const struct cache_entry *old,
	const struct cache_entry *new_entry)
{
	const struct clean_status_state *state = istate->clean_status;
	const struct cache_entry *entry = old ? old : new_entry;
	struct conv_attrs attrs;
	const char *base;
	int suspended = clean_status_fsmonitor_backoff_suspended(istate);

	if (!state ||
	    (!suspended && !clean_status_revalidated_token_matches(istate)) ||
	    (state->filter_configured && !state->filter_scope_valid) ||
	    istate->split_index ||
	    istate->sparse_index || !entry)
		return 0;
	if ((old && (!S_ISREG(old->ce_mode) && !S_ISLNK(old->ce_mode))) ||
	    (new_entry && (!S_ISREG(new_entry->ce_mode) &&
			   !S_ISLNK(new_entry->ce_mode))))
		return 0;
	if ((old && (ce_stage(old) || ce_skip_worktree(old) ||
		     ce_intent_to_add(old) || (old->ce_flags & CE_VALID))) ||
	    (new_entry && (ce_stage(new_entry) ||
			   ce_skip_worktree(new_entry) ||
			   ce_intent_to_add(new_entry) ||
			   (new_entry->ce_flags & CE_VALID))))
		return 0;
	base = strrchr(entry->name, '/');
	base = base ? base + 1 : entry->name;
	if (!fspathcmp(base, ".gitattributes") ||
	    !fspathcmp(base, ".gitignore"))
		return 0;
	if (suspended &&
	    (!old || !new_entry || !S_ISREG(old->ce_mode) ||
	     !S_ISREG(new_entry->ce_mode) ||
	     !clean_status_manifest_path_attributes_unchanged(istate, entry->name)))
		return 0;
	if (state->filter_configured) {
		convert_attrs((struct index_state *)istate, &attrs, entry->name);
		if (convert_attrs_has_clean_filter(&attrs))
			return 0;
	}
	if (!old || !new_entry)
		return path_has_no_new_attribute_sources(istate, entry->name,
							 old && !new_entry);
	return ce_namelen(old) == ce_namelen(new_entry) &&
		!memcmp(old->name, new_entry->name, ce_namelen(old)) &&
		old->ce_mode == new_entry->ce_mode;
}

void clean_status_clear_authenticated_new_directories(
	struct index_state *istate)
{
	struct clean_status_state *state = istate->clean_status;

	if (!state)
		return;
	strbuf_reset(&state->authenticated_new_directories);
	FREE_AND_NULL(state->authenticated_new_directories_token);
}

static unsigned int clean_status_directory_lower_bound(
	const struct index_state *istate, const char *name)
{
	unsigned int low = 0, high = istate->cache_nr;

	while (low < high) {
		unsigned int middle = low + (high - low) / 2;

		if (strcmp(istate->cache[middle]->name, name) < 0)
			low = middle + 1;
		else
			high = middle;
	}
	return low;
}

static int clean_status_changed_directory_is_semantically_safe(
	const struct index_state *istate, const char *name)
{
	const struct clean_status_state *state = istate->clean_status;
	struct semantic_verify_root *root = NULL;
	struct semantic_verify_path *path = NULL;
	struct attr_manifest_cursor cursor;
	struct attr_manifest_entry entry;
	struct strbuf candidate = STRBUF_INIT;
	const char *basename;
	unsigned int first, i, namespace_unstable = 0;
	size_t len;
	int parent_fd, next, removed, safe = 0;

	if (!state || !fstat_is_reliable() ||
	    !state->current_config_valid || !state->current_attr_valid ||
	    !state->config_enforced || !state->config_revalidated ||
	    !clean_status_revalidated_token_matches(istate) ||
	    !state->manifest.current_valid || !state->manifest.checked ||
	    state->manifest.current_invalidated ||
	    (state->manifest.current_flags & FSMONITOR_CLEAN_PROOF_ALL) !=
		FSMONITOR_CLEAN_PROOF_ALL ||
	    (state->filter_configured && !state->filter_scope_valid) ||
	    istate->split_index || istate->sparse_index ||
	    !istate->repo->config_values_private_.trust_ctime ||
	    !istate->repo->config_values_private_.check_stat)
		return 0;

	len = strlen(name);
	if (!len || name[len - 1] != '/')
		return 0;
	first = clean_status_directory_lower_bound(istate, name);
	if (first >= istate->cache_nr ||
	    !starts_with(istate->cache[first]->name, name))
		return 0;
	/* Each descendant independently authenticates its attribute ancestry. */
	if (istate->cache_nr - first > 64 &&
	    starts_with(istate->cache[first + 64]->name, name))
		return 0;

	if (attr_manifest_cursor_init(&cursor,
				      state->manifest.current.buf,
				      state->manifest.current.len,
				      istate->repo->hash_algo))
		return 0;
	while ((next = attr_manifest_cursor_next(&cursor, &entry)) > 0)
		if (entry.path_len >= len &&
		    !memcmp(entry.path, name, len))
			return 0;
	if (next < 0 || semantic_verify_root_init(istate->repo, &root))
		return 0;

	path = semantic_verify_path_new(root);
	strbuf_addstr(&candidate, name);
	strbuf_addstr(&candidate, ".gitattributes");
	if (semantic_verify_resolve_parent(path, candidate.buf, 0,
					   &parent_fd, &basename)) {
		if (errno != ENOENT)
			goto done;
		removed = 1;
	} else {
		removed = 0;
	}

	for (i = first; i < istate->cache_nr &&
	     starts_with(istate->cache[i]->name, name); i++)
		if (!clean_status_index_entry_is_semantically_safe(
				istate, removed ? istate->cache[i] : NULL,
				removed ? NULL : istate->cache[i]))
			goto done;

	semantic_verify_path_free(path, &namespace_unstable, NULL);
	path = NULL;
	safe = !namespace_unstable && semantic_verify_root_stable(root);
	if (safe)
		trace2_data_intmax("fsmonitor", istate->repo,
				   removed ?
				   "semantic/authenticated-removed-directory" :
				   "semantic/authenticated-restored-directory", 1);

done:
	if (path)
		semantic_verify_path_free(path, &namespace_unstable, NULL);
	semantic_verify_root_clear(root);
	strbuf_release(&candidate);
	return safe;
}

void clean_status_set_authenticated_new_directories(
	struct index_state *istate, const struct index_state *old_index,
	const struct strbuf *paths)
{
	struct clean_status_state *state = istate->clean_status;
	const char *path = paths->buf, *end = paths->buf + paths->len;

	clean_status_clear_authenticated_new_directories(istate);
	if (!state || !state->manifest.current_valid ||
	    state->manifest.current_invalidated ||
	    (state->manifest.current_flags &
	     (FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
	      FSMONITOR_CLEAN_PROOF_FULL_INDEX)) !=
		    (FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		     FSMONITOR_CLEAN_PROOF_FULL_INDEX) ||
	    !clean_status_revalidated_token_matches(istate))
		return;
	while (path < end) {
		size_t len = strlen(path);
		unsigned int old_pos, new_pos;

		if (!len || path[len - 1] != '/')
			goto next;
		old_pos = clean_status_directory_lower_bound(old_index, path);
		new_pos = clean_status_directory_lower_bound(istate, path);
		if ((old_pos < old_index->cache_nr &&
		     starts_with(old_index->cache[old_pos]->name, path)) ||
		    new_pos >= istate->cache_nr ||
		    !starts_with(istate->cache[new_pos]->name, path) ||
		    !clean_status_index_entry_is_semantically_safe(
			    old_index, NULL, istate->cache[new_pos]))
			goto next;
		strbuf_add(&state->authenticated_new_directories, path,
			   len + 1);
next:
		path += len + 1;
	}
	if (state->authenticated_new_directories.len)
		state->authenticated_new_directories_token =
			xstrdup(istate->fsmonitor_last_update);
}

int clean_status_directory_event_is_semantically_safe(
	const struct index_state *istate, const char *name)
{
	const struct clean_status_state *state = istate->clean_status;
	const char *path, *end;

	if (!state || !clean_status_revalidated_token_matches(istate))
		return 0;
	if (state->authenticated_new_directories_token &&
	    !strcmp(state->authenticated_new_directories_token,
		    istate->fsmonitor_last_update)) {
		path = state->authenticated_new_directories.buf;
		end = path + state->authenticated_new_directories.len;
		while (path < end) {
			if (!strcmp(path, name)) {
				trace2_data_intmax("fsmonitor", istate->repo,
					"semantic/authenticated-new-directory", 1);
				return 1;
			}
			path += strlen(path) + 1;
		}
	}
	return clean_status_changed_directory_is_semantically_safe(
		istate, name);
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
		memcpy(state->current_attr_portable_namespace_hash,
		       attrs->portable_namespace_hash,
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
		(istate->clean_status->config_mismatch ||
		 !istate->clean_status->config_revalidated);
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

int clean_status_has_authenticated_worktree_manifest(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->disk_config_valid &&
		!state->disk_config_invalid && istate->fsmonitor_token_valid &&
		istate->fsmonitor_last_update && state->disk_config_token &&
		!strcmp(state->disk_config_token,
			istate->fsmonitor_last_update) &&
		state->manifest.disk_valid &&
		(state->manifest.disk_flags & FSMONITOR_CLEAN_PROOF_ALL) ==
			FSMONITOR_CLEAN_PROOF_ALL &&
		state->manifest.current_valid && state->manifest.checked &&
		!state->manifest.current_invalidated &&
		(state->manifest.current_flags & FSMONITOR_CLEAN_PROOF_ALL) ==
			FSMONITOR_CLEAN_PROOF_ALL;
}

int clean_status_worktree_manifest_needs_refresh(
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->config_enforced &&
		state->manifest.current_invalidated;
}

void clean_status_invalidate_current_manifest(struct index_state *istate)
{
	if (!istate->clean_status)
		return;
	clean_status_manifest_invalidate(&istate->clean_status->manifest);
	clean_status_invalidate_current_proof(istate);
}

void clean_status_mark_fsmonitor_config_valid(struct index_state *istate,
					      const char *closed_token)
{
	struct clean_status_state *state = istate->clean_status;

	if (!state || !state->current_config_valid)
		return;
	if (!closed_token || clean_status_filter_scope_needs_validation(istate) ||
	    !state->manifest.current_valid || !state->manifest.checked ||
	    (state->manifest.current_flags &
	     (FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
	      FSMONITOR_CLEAN_PROOF_FULL_INDEX)) !=
		    (FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		     FSMONITOR_CLEAN_PROOF_FULL_INDEX)) {
		clean_status_invalidate_current_proof(istate);
		FREE_AND_NULL(state->config_revalidated_token);
		trace2_data_intmax("fsmonitor", istate->repo,
				   "config/manifest-unbound", 1);
		return;
	}
	state->config_mismatch = 0;
	state->strong_mismatch = 0;
	state->semantic_baseline_pending = 0;
	state->backoff_suspended = 0;
	FREE_AND_NULL(state->backoff_token);
	state->manifest.current_flags = FSMONITOR_CLEAN_PROOF_ALL;
	state->config_revalidated = state->current_semantic_valid &&
		state->current_attr_valid && state->manifest.current_valid;
	state->initial_coherent = state->config_revalidated;
	FREE_AND_NULL(state->config_revalidated_token);
	if (state->config_revalidated)
		state->config_revalidated_token = xstrdup(closed_token);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "config/revalidated", 1);
}

void clean_status_release(struct index_state *istate)
{
	if (!istate->clean_status)
		return;
	if (istate->clean_status->source_index_fd >= 0)
		close(istate->clean_status->source_index_fd);
	clean_status_manifest_release(&istate->clean_status->manifest);
	strbuf_release(&istate->clean_status->disk_config_raw);
	strbuf_release(&istate->clean_status->authenticated_new_directories);
	free(istate->clean_status->disk_config_token);
	free(istate->clean_status->config_revalidated_token);
	free(istate->clean_status->backoff_token);
	free(istate->clean_status->authenticated_new_directories_token);
	FREE_AND_NULL(istate->clean_status);
}
