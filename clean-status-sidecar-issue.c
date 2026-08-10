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
#include "object-name.h"
#include "preload-index.h"
#include "read-cache-ll.h"
#include "repository.h"
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
		!status->show_stash && !status->show_ignored_mode &&
		!status->null_termination && !status->verbose &&
		status->show_untracked_files == SHOW_NORMAL_UNTRACKED_FILES &&
		!status->change.nr && !status->untracked.nr &&
		!status->ignored.nr;
}

static int history_is_certifiable(const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state &&
		clean_status_has_persistent_fsmonitor_semantic_history(istate) &&
		clean_status_revalidated_token_matches(istate) &&
		state->manifest.current_valid &&
		(state->manifest.current_flags & FSMONITOR_CLEAN_PROOF_ALL) ==
			FSMONITOR_CLEAN_PROOF_ALL;
}

static int fsmonitor_state_is_certifiable(
	struct repository *repo, const struct index_state *istate)
{
	return !istate->split_index &&
		istate->sparse_index == INDEX_EXPANDED &&
		fsm_settings__get_mode(repo) == FSMONITOR_MODE_IPC &&
		!fsmonitor_has_pending_token(istate) &&
		istate->fsmonitor_token_valid &&
		istate->fsmonitor_last_update &&
		strlen(istate->fsmonitor_last_update) <=
			FSMONITOR_CLEAN_PROOF_TOKEN_MAX &&
		clean_status_index_is_certifiable(istate);
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
	struct object_id exclude_digest, head_tree;
	struct stat scanned_worktree;
	unsigned char repo_hash[GIT_MAX_RAWSZ];
	int installed = 0;

	if (!is_lock_file_locked(index_lock) ||
	    !config->finalized || config->filter_configured ||
	    !output_is_certifiable(status, normal_clean_query)) {
		trace_miss(repo, "issue-command-or-output");
		goto done;
	}
	if (!history_is_certifiable(istate)) {
		trace_miss(repo, "issue-coherent-history");
		goto done;
	}
	if (getenv(INDEX_ENVIRONMENT) ||
	    !fsmonitor_state_is_certifiable(repo, istate) ||
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
	    !istate->cache_tree || istate->cache_tree->entry_count < 0 ||
	    !oideq(&head_tree, &istate->cache_tree->oid)) {
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

	if (clean_status_sidecar_install(
		    repo->index_file, &sidecar, &index, repo->hash_algo)) {
		trace_miss(repo, "issue-sidecar-write");
		goto done;
	}
	rollback_lock_file(index_lock);
	trace2_data_intmax("status", repo, "clean-proof/sidecar", 1);
	installed = 1;

done:
	clean_status_index_snapshot_release(&index);
	return installed;
}
