#include "git-compat-util.h"
#include "attr-manifest.h"
#include "clean-status-index.h"
#include "clean-status-manifest.h"
#include "dir.h"
#include "fsmonitor-clean-proof.h"
#include "fsmonitor-ll.h"
#include "hash-framing.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "sparse-index.h"
#include "trace2.h"
#include "worktree-attr-manifest.h"

struct invalidate_manifest_data {
	struct index_state *istate;
	int invalidated;
};

static int build_manifest(struct index_state *istate,
			  struct strbuf *manifest,
			  unsigned char *manifest_hash,
			  struct worktree_attr_manifest_stats *stats)
{
	struct clean_status_index_snapshot snapshot;
	struct index_state scratch = INDEX_STATE_INIT(istate->repo);
	int ret = -1;

	if (istate->sparse_index == INDEX_EXPANDED)
		return worktree_attr_manifest_build(
			istate, manifest, manifest_hash, stats);
	if (clean_status_index_snapshot_pin(&snapshot, istate))
		return -1;
	scratch.fsmonitor_has_run_once = 1;
	if (read_index_from(&scratch, istate->repo->index_file,
			    istate->repo->gitdir) < 0 ||
	    !clean_status_index_snapshot_still_matches(&snapshot, &scratch))
		goto done;
	ensure_full_index(&scratch);
	ret = worktree_attr_manifest_build(
		&scratch, manifest, manifest_hash, stats);
	if (ret ||
	    !clean_status_index_snapshot_still_matches(&snapshot, istate)) {
		strbuf_reset(manifest);
		ret = -1;
	}

done:
	release_index(&scratch);
	clean_status_index_snapshot_release(&snapshot);
	return ret;
}

void clean_status_manifest_init(struct clean_status_manifest_state *state)
{
	memset(state, 0, sizeof(*state));
	strbuf_init(&state->disk, 0);
	strbuf_init(&state->current, 0);
}

void clean_status_manifest_release(struct clean_status_manifest_state *state)
{
	strbuf_release(&state->disk);
	strbuf_release(&state->current);
}

int clean_status_manifest_load(struct clean_status_manifest_state *state,
			       const void *data, size_t len, uint32_t flags,
			       const struct git_hash_algo *algo)
{
	state->disk_valid = 0;
	state->disk_flags = 0;
	strbuf_reset(&state->disk);
	if (flags & ~FSMONITOR_CLEAN_PROOF_ALL ||
	    !attr_manifest_valid(data, len, algo))
		return -1;
	strbuf_add(&state->disk, data, len);
	hash_buffer_digest(algo, data, len, state->disk_hash);
	state->disk_flags = flags;
	state->disk_valid = 1;
	return 0;
}

void clean_status_manifest_adopt_disk(
	struct clean_status_manifest_state *state)
{
	if (!state->disk_valid)
		BUG("cannot adopt an invalid clean-status manifest");
	strbuf_reset(&state->current);
	strbuf_addbuf(&state->current, &state->disk);
	memcpy(state->current_hash, state->disk_hash,
	       sizeof(state->current_hash));
	state->current_flags = state->disk_flags;
	state->current_valid = 1;
	state->checked = 1;
	state->current_invalidated = 0;
}

static int invalidate_manifest_path(const struct attr_manifest_entry *entry,
				    void *cb_data)
{
	struct invalidate_manifest_data *data = cb_data;
	char *path = xmemdupz(entry->path, entry->path_len);

	untracked_cache_invalidate_trimmed_path(data->istate, path, 0);
	data->invalidated +=
		fsmonitor_invalidate_attributes_path(data->istate, path);
	free(path);
	return 0;
}

int clean_status_manifest_refresh(struct index_state *istate,
				  struct clean_status_manifest_state *state)
{
	struct worktree_attr_manifest_stats stats;
	struct invalidate_manifest_data invalidation = { .istate = istate };
	const struct git_hash_algo *algo = istate->repo->hash_algo;
	const struct strbuf *baseline = NULL;
	struct strbuf next = STRBUF_INIT;
	unsigned char next_hash[GIT_MAX_RAWSZ];

	state->scan_count++;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-scan-count", state->scan_count);
	if (attr_manifest_valid(state->current.buf, state->current.len, algo))
		baseline = &state->current;
	else if (state->disk_valid)
		baseline = &state->disk;
	state->checked = 1;
	state->changed = 0;
	state->global_fallback = 0;
	state->current_valid = 0;
	state->current_flags = 0;
	if (build_manifest(istate, &next, next_hash, &stats)) {
		state->global_fallback = !!baseline;
		trace2_data_intmax("fsmonitor", istate->repo,
				   "semantic/manifest-scan-failed", 1);
		strbuf_release(&next);
		return -1;
	}
	if (baseline) {
		if (attr_manifest_for_each_changed(
			baseline->buf, baseline->len,
			next.buf, next.len, algo,
			invalidate_manifest_path, &invalidation)) {
			state->global_fallback = 1;
			strbuf_release(&next);
			return -1;
		}
		state->changed = baseline->len != next.len ||
			memcmp(baseline->buf, next.buf, next.len);
	}
	strbuf_swap(&state->current, &next);
	strbuf_release(&next);
	memcpy(state->current_hash, next_hash, algo->rawsz);
	state->current_valid = 1;
	state->current_flags = FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		FSMONITOR_CLEAN_PROOF_FULL_INDEX;
	state->current_invalidated = 0;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-candidates", stats.candidates);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-threads", stats.threads);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-thread-failures",
			   stats.thread_failures);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-worktree-sources",
			   stats.worktree_sources);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-index-sources", stats.index_sources);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-bytes", state->current.len);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-changed", state->changed);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-invalidated",
			   invalidation.invalidated);
	return invalidation.invalidated;
}

void clean_status_manifest_invalidate(
	struct clean_status_manifest_state *state)
{
	if (state->current_valid)
		state->current_invalidated = 1;
	state->current_valid = 0;
	state->current_flags = 0;
}
