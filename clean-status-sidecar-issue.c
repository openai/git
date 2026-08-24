#include "git-compat-util.h"
#include "cache-tree.h"
#include "clean-status.h"
#include "clean-status-index.h"
#include "clean-status-internal.h"
#include "clean-status-sidecar.h"
#include "environment.h"
#include "fsmonitor-clean-proof.h"
#include "fsmonitor-ll.h"
#include "fsmonitor-settings.h"
#include "lockfile.h"
#include "object-file.h"
#include "object-name.h"
#include "path-namespace.h"
#include "preload-index.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "semantic-verify-internal.h"
#include "trace2.h"
#include "wt-status.h"

static void trace_miss(struct repository *repo, const char *reason)
{
	trace2_data_string("status", repo, "clean-proof/miss", reason);
}

static int issue_test_barrier(void)
{
	const char *ready =
		getenv("GIT_TEST_STATUS_CLEAN_SIDECAR_ISSUE_BARRIER_READY");
	const char *resume =
		getenv("GIT_TEST_STATUS_CLEAN_SIDECAR_ISSUE_BARRIER_RESUME");
	struct strbuf buf = STRBUF_INIT;
	int ret;

	if (!ready && !resume)
		return 0;
	if (!ready || !resume)
		return -1;
	write_file(ready, "ready");
	ret = strbuf_read_file(&buf, resume, 1) > 0 ? 0 : -1;
	strbuf_release(&buf);
	return ret;
}

static int output_is_certifiable(const struct wt_status *status,
				 int normal_clean_query)
{
	return (status->status_format == STATUS_FORMAT_PORCELAIN_V2 ||
		(normal_clean_query &&
		 status->status_format == STATUS_FORMAT_NONE)) &&
		!status->pathspec.nr && !status->show_branch &&
		(!status->show_stash || normal_clean_query) &&
		!status->show_ignored_mode &&
		!status->null_termination && !status->verbose &&
		status->show_untracked_files == SHOW_NORMAL_UNTRACKED_FILES &&
		!status->change.nr && !status->untracked.nr &&
		!status->ignored.nr;
}

static int history_is_certifiable(
	const struct index_state *istate,
	const struct clean_status_config_digest *config)
{
	const struct clean_status_state *state = istate->clean_status;

	/*
	 * The configured-filter proof domain requires an authenticated,
	 * fully classified inactive scope. A normalized disabled-filter
	 * override shares that digest and is never certifiable.
	 */
	return state &&
		state->filter_configured == config->filter_configured &&
		(!config->filter_configured ||
		 (!config->normalized_filter_disable &&
		  state->current_config_valid &&
		  state->current_semantic_valid &&
		  !memcmp(state->current_config_hash, config->hash,
			  istate->repo->hash_algo->rawsz) &&
		  !memcmp(state->current_semantic_hash, config->semantic_hash,
			  istate->repo->hash_algo->rawsz) &&
		  state->filter_scope_valid &&
		  !clean_status_filter_scope_needs_validation(istate))) &&
		clean_status_has_persistent_fsmonitor_semantic_history(istate) &&
		clean_status_revalidated_token_matches(istate) &&
		state->manifest.current_valid &&
		(state->manifest.current_flags & FSMONITOR_CLEAN_PROOF_ALL) ==
			FSMONITOR_CLEAN_PROOF_ALL;
}

static int fsmonitor_state_is_certifiable(
	struct repository *repo, const struct index_state *istate,
	uint32_t *hardlink_nr)
{
	return !istate->split_index &&
		istate->sparse_index == INDEX_EXPANDED &&
		fsm_settings__get_mode(repo) == FSMONITOR_MODE_IPC &&
		!fsmonitor_has_pending_token(istate) &&
		istate->fsmonitor_token_valid &&
		istate->fsmonitor_last_update &&
		strlen(istate->fsmonitor_last_update) <=
			FSMONITOR_CLEAN_PROOF_TOKEN_MAX &&
		clean_status_index_is_certifiable_with_hardlinks(
			istate, hardlink_nr);
}

static int capture_hardlink_witnesses(
	struct repository *repo, const struct index_state *istate,
	uint32_t expected, struct strbuf *witnesses)
{
#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN && !defined(NO_NSEC)
	struct semantic_verify_root *root = NULL;
	struct semantic_verify_path *path = NULL;
	unsigned int namespace_unstable = 0;
	uint32_t captured = 0, verified = 0;
	int ret = -1;

	if (!expected)
		return 0;
	if (!repo->config_values_private_.trust_ctime ||
	    !repo->config_values_private_.check_stat ||
	    semantic_verify_root_init(repo, &root))
		goto done;
	path = semantic_verify_path_new(root);
	if (!path)
		goto done;
	for (size_t i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];
		struct path_stat_identity identity;
		struct stat held, named;
		const char *basename;
		int parent_fd, fd;

		if (ce->ce_flags & CE_FSMONITOR_VALID)
			continue;
		if (semantic_verify_resolve_parent(
			    path, ce->name, i, &parent_fd, &basename))
			goto done;
		fd = semantic_verify_openat(
			parent_fd, basename,
			O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
		if (fd < 0)
			goto done;
		if (fstat(fd, &held) || !S_ISREG(held.st_mode) ||
		    held.st_nlink <= 1 || held.st_dev != root->stat.st_dev ||
		    match_stat_data(&ce->ce_stat_data, &held)) {
			close(fd);
			goto done;
		}
		if (ce->ce_stat_data.sd_ctime.nsec != ST_CTIME_NSEC(held) ||
		    ce->ce_stat_data.sd_mtime.nsec != ST_MTIME_NSEC(held)) {
			struct object_id observed;
			struct stat after;

			if (index_fd(repo->index, &observed, xdup(fd), &held,
				     OBJ_BLOB, ce->name, 0) ||
			    !oideq(&observed, &ce->oid) || fstat(fd, &after) ||
			    !path_namespace_stat_equal(&held, &after)) {
				close(fd);
				goto done;
			}
			verified++;
		}
		if (fstatat(parent_fd, basename, &named,
			    AT_SYMLINK_NOFOLLOW) ||
		    !path_namespace_stat_equal(&held, &named)) {
			close(fd);
			goto done;
		}
		path_stat_identity_init(&identity, &held);
		close(fd);
		if (clean_status_sidecar_append_hardlink(
			    witnesses, ce->name, &identity))
			goto done;
		captured++;
	}
	if (captured != expected || !semantic_verify_root_stable(root))
		goto done;
	if (verified)
		trace2_data_intmax("status", repo,
				   "clean-proof/hardlink-content-verified", verified);
	ret = 0;

done:
	semantic_verify_path_free(path, &namespace_unstable, NULL);
	if (namespace_unstable || (root && !semantic_verify_root_stable(root)))
		ret = -1;
	semantic_verify_root_clear(root);
	if (ret)
		strbuf_reset(witnesses);
	return ret;
#else
	(void)repo;
	(void)istate;
	(void)witnesses;
	return expected ? -1 : 0;
#endif
}

static int untracked_scan_is_certifiable(
	struct wt_status *status, struct object_id *exclude_digest,
	struct stat *scanned_worktree)
{
	if (status->untracked_from_preload)
		return !preload_index_bulk_standard_excludes_digest(
			status->repo->index, exclude_digest,
			scanned_worktree);
	if (status->untracked_from_token_closure)
		return !wt_status_certified_excludes_digest(
			status, exclude_digest, scanned_worktree);
	return 0;
}

int clean_status_issue_sidecar(
	struct wt_status *status,
	const struct clean_status_config_digest *config,
	struct lock_file *index_lock,
	int normal_clean_query)
{
	struct repository *repo = status->repo;
	struct index_state *istate = repo->index;
	struct clean_status_index_snapshot index = { .fd = -1 };
	struct clean_status_sidecar sidecar = { 0 };
	struct strbuf hardlinks = STRBUF_INIT;
	struct object_id exclude_digest, head_tree;
	struct stat scanned_worktree;
	unsigned char repo_hash[GIT_MAX_RAWSZ];
	uint32_t hardlink_nr = 0;
	int installed = 0;

	if (!is_lock_file_locked(index_lock) ||
	    !config->finalized ||
	    !output_is_certifiable(status, normal_clean_query)) {
		trace_miss(repo, "issue-command-or-output");
		goto done;
	}
	if (!history_is_certifiable(istate, config)) {
		trace_miss(repo, "issue-coherent-history");
		goto done;
	}
	if (getenv(INDEX_ENVIRONMENT) ||
	    !fsmonitor_state_is_certifiable(repo, istate, &hardlink_nr) ||
	    !untracked_scan_is_certifiable(
		    status, &exclude_digest, &scanned_worktree)) {
		trace_miss(repo, "issue-scan-or-index-shape");
		goto done;
	}
	if (issue_test_barrier()) {
		trace_miss(repo, "issue-test-barrier");
		goto done;
	}
	if (!status->attr_source_snapshot ||
	    clean_status_index_snapshot_pin(&index, istate) ||
	    clean_status_repository_fingerprint(
		    repo, status->attr_source_snapshot, &index,
		    &scanned_worktree, repo_hash)) {
		trace_miss(repo, "issue-pinned-inputs");
		goto done;
	}
	if (repo_get_oid_tree(repo, "HEAD^{tree}", &head_tree) ||
	    ((!istate->cache_tree || istate->cache_tree->entry_count < 0) ?
	     !status->index_tree_verified :
	     !oideq(&head_tree, &istate->cache_tree->oid))) {
		trace_miss(repo, "issue-head-cache-tree");
		goto done;
	}

	sidecar.identity = index.identity;
	sidecar.proof.index_version = index.version;
	sidecar.proof.cache_nr = index.cache_nr;
	oidcpy(&sidecar.proof.index_checksum, &index.checksum);
	oidcpy(&sidecar.proof.head_tree, &head_tree);
	memcpy(sidecar.proof.config_hash, config->hash,
	       repo->hash_algo->rawsz);
	memcpy(sidecar.proof.repo_hash, repo_hash,
	       repo->hash_algo->rawsz);
	oidcpy(&sidecar.proof.exclude_source_digest, &exclude_digest);
	sidecar.token = (const unsigned char *)istate->fsmonitor_last_update;
	sidecar.token_len = strlen(istate->fsmonitor_last_update);
	if (capture_hardlink_witnesses(
		    repo, istate, hardlink_nr, &hardlinks)) {
		trace_miss(repo, "issue-hardlink-witness");
		goto done;
	}
	if (hardlink_nr) {
		sidecar.hardlinks = (const unsigned char *)hardlinks.buf;
		sidecar.hardlinks_len = hardlinks.len;
		sidecar.hardlink_nr = hardlink_nr;
	}

	if (clean_status_sidecar_install(
		    repo->index_file, &sidecar, &index, repo->hash_algo)) {
		trace_miss(repo, "issue-sidecar-write");
		goto done;
	}
	rollback_lock_file(index_lock);
	if (hardlink_nr)
		trace2_data_intmax("status", repo,
				   "clean-proof/hardlink-witnesses", hardlink_nr);
	trace2_data_intmax("status", repo, "clean-proof/sidecar", 1);
	installed = 1;

done:
	strbuf_release(&hardlinks);
	clean_status_index_snapshot_release(&index);
	return installed;
}
