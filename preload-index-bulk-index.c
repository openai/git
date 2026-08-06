#include "git-compat-util.h"
#include "name-hash.h"
#include "object.h"
#include "preload-index-bulk.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "semantic-verify.h"
#include "semantic-verify-internal.h"

#ifndef __has_builtin
#define __has_builtin(x) 0
#endif

int preload_bulk_index_position(struct preload_bulk_scan *scan,
				const char *path, size_t path_len)
{
	if (path_len > INT_MAX)
		return -1;
	return index_name_pos_sparse(scan->istate, path, path_len);
}

static int first_tracked_descendant(struct index_state *istate,
				    const char *path, size_t path_len,
				    int pos)
{
	while ((unsigned int)pos < istate->cache_nr) {
		const struct cache_entry *ce = istate->cache[pos];

		if (ce_namelen(ce) <= path_len ||
		    memcmp(ce->name, path, path_len))
			return -1;
		if (ce->name[path_len] == '/')
			return pos;
		if ((unsigned char)ce->name[path_len] > '/')
			return -1;
		pos++;
	}
	return -1;
}

int preload_bulk_index_pos_has_tracked_descendants(
	struct preload_bulk_scan *scan, const char *path, size_t path_len,
	int pos)
{
	struct index_state *istate = scan->istate;

	if (pos >= 0)
		return 0;
	pos = -pos - 1;
	return first_tracked_descendant(istate, path, path_len, pos) >= 0;
}

static int record_tracked_state(struct preload_bulk_worker *worker, int pos,
				unsigned char state)
{
	struct preload_bulk_scan *scan = worker->scan;
	int recorded = 1;

#if GIT_GNUC_PREREQ(4, 7) || \
	(__has_builtin(__atomic_compare_exchange_n) && \
	 __has_builtin(__atomic_store_n))
	unsigned char expected = PRELOAD_BULK_TRACKED_UNSEEN;

	if (!__atomic_compare_exchange_n(&scan->tracked_state[pos], &expected,
					 state, 0, __ATOMIC_RELAXED,
					 __ATOMIC_RELAXED)) {
		__atomic_store_n(&scan->tracked_state[pos],
				 PRELOAD_BULK_TRACKED_FALLBACK,
				 __ATOMIC_RELAXED);
		recorded = 0;
	}
#else
	pthread_mutex_lock(&scan->queue.mutex);
	if (scan->tracked_state[pos] != PRELOAD_BULK_TRACKED_UNSEEN) {
		state = PRELOAD_BULK_TRACKED_FALLBACK;
		recorded = 0;
	}
	scan->tracked_state[pos] = state;
	pthread_mutex_unlock(&scan->queue.mutex);
#endif
	return recorded;
}

static void record_stat_update(struct preload_bulk_worker *worker, int pos,
			       const struct stat_data *stat_data)
{
	struct preload_bulk_stat_update *update;

	ALLOC_GROW(worker->stat_updates, worker->stat_updates_nr + 1,
		   worker->stat_updates_alloc);
	update = &worker->stat_updates[worker->stat_updates_nr++];
	update->cache_pos = pos;
	memcpy(&update->stat_data, stat_data, sizeof(update->stat_data));
}

static int tracked_entry_is_eligible(const struct cache_entry *ce)
{
	return !ce_stage(ce) &&
		!ce_intent_to_add(ce) &&
		!ce_skip_worktree(ce) &&
		!(ce->ce_flags & (CE_VALID | CE_REMOVE)) &&
		(S_ISREG(ce->ce_mode) || S_ISLNK(ce->ce_mode));
}

/*
 * Match ie_modified(): a nonzero cached size mismatch is a conclusive
 * content change. Zero sizes and the historical Windows symlink sentinel
 * still require an ordinary content check. Recompute the stat-data match
 * because CE_MATCH_RACY_IS_DIRTY may make ie_match_stat() report a data
 * change without a size mismatch.
 */
static int size_change_is_definitive(const struct cache_entry *ce,
				     const struct stat *st,
				     unsigned int changed)
{
	if (changed & (MODE_CHANGED | TYPE_CHANGED))
		return 0;
#ifdef GIT_WINDOWS_NATIVE
	if (S_ISLNK(st->st_mode) && ce->ce_stat_data.sd_size == MAX_PATH)
		return 0;
#endif
	return ce->ce_stat_data.sd_size &&
		(match_stat_data(&ce->ce_stat_data, (struct stat *)st) &
		 DATA_CHANGED);
}

static unsigned char verify_content_at(
	struct preload_bulk_worker *worker, int pos, int parent_fd,
	const char *basename, const struct stat *st,
	int observed_has_platform_identity, struct stat_data *stat_data,
	int *has_stat_update)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct cache_entry *ce = scan->istate->cache[pos];
	struct semantic_verify_file_result file;

	*has_stat_update = 0;
	if (!scan->verify_content ||
	    !semantic_verify_classify_entry(
		    scan->istate, ce, worker->attr_check, &file))
		return PRELOAD_BULK_TRACKED_CONTENT_CHECK;
	semantic_verify_file_at(
		parent_fd, basename, st, observed_has_platform_identity,
		scan->root_dev, ce, scan->istate->repo,
		worker->hash_buffer, &file);
	worker->bytes_hashed += file.bytes_hashed;
	if (file.kind == SEMANTIC_VERIFY_RAW_MODIFIED)
		return PRELOAD_BULK_TRACKED_DEFINITIVE_MODIFIED;
	if (file.kind != SEMANTIC_VERIFY_RAW_CLEAN || !file.persistable)
		return PRELOAD_BULK_TRACKED_CONTENT_CHECK;
	if (memcmp(&file.stat_data, &ce->ce_stat_data,
		   sizeof(file.stat_data))) {
		memcpy(stat_data, &file.stat_data, sizeof(*stat_data));
		*has_stat_update = 1;
	}
	return PRELOAD_BULK_TRACKED_CLEAN;
}

int preload_bulk_index_entry_is_gitlink(struct preload_bulk_scan *scan,
					int pos)
{
	return pos >= 0 && S_ISGITLINK(scan->istate->cache[pos]->ce_mode);
}

void preload_bulk_record_tracked(
	struct preload_bulk_worker *worker, int pos, int parent_fd,
	const char *basename, const struct stat *st,
	int observed_has_platform_identity)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct cache_entry *ce = scan->istate->cache[pos];
	struct stat_data stat_data;
	unsigned int changed;
	unsigned char state;
	int has_stat_update = 0;

	if (!tracked_entry_is_eligible(ce))
		return;
	changed = ie_match_stat(
		scan->istate, ce, (struct stat *)st,
		CE_MATCH_RACY_IS_DIRTY | CE_MATCH_IGNORE_FSMONITOR);
	if (!changed)
		state = PRELOAD_BULK_TRACKED_CLEAN;
	else if (size_change_is_definitive(ce, st, changed))
		state = PRELOAD_BULK_TRACKED_DEFINITIVE_MODIFIED;
	else
		state = verify_content_at(
			worker, pos, parent_fd, basename, st,
			observed_has_platform_identity, &stat_data,
			&has_stat_update);
	if (record_tracked_state(worker, pos, state) && has_stat_update)
		record_stat_update(worker, pos, &stat_data);
}

void preload_bulk_record_tracked_fallback(
	struct preload_bulk_worker *worker, int pos)
{
	if (!tracked_entry_is_eligible(worker->scan->istate->cache[pos]))
		return;
	record_tracked_state(worker, pos,
			     PRELOAD_BULK_TRACKED_FALLBACK);
}

void preload_bulk_record_tracked_descendants_fallback(
	struct preload_bulk_worker *worker, const char *path,
	size_t path_len)
{
	struct index_state *istate = worker->scan->istate;
	int pos = preload_bulk_index_position(worker->scan, path, path_len);

	if (pos < 0)
		pos = -pos - 1;
	else
		pos++;
	while ((pos = first_tracked_descendant(istate, path, path_len, pos)) >= 0) {
		preload_bulk_record_tracked_fallback(worker, pos);
		pos++;
	}
}

int preload_bulk_record_tracked_alias_fallback(
	struct preload_bulk_worker *worker, const char *path,
	size_t path_len)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct index_state *istate = scan->istate;
	struct cache_entry *ce;
	struct strbuf canonical = STRBUF_INIT;
	int found = 0;
	int pos;

	if (!scan->case_insensitive || path_len > INT_MAX)
		return 0;
	if (index_dir_find(istate, path, path_len, &canonical)) {
		found = 1;
		preload_bulk_record_tracked_descendants_fallback(
			worker, canonical.buf, canonical.len);
		goto out;
	}
	ce = index_file_exists(istate, path, path_len, 1);
	if (!ce)
		goto out;
	found = 1;
	pos = index_name_pos_sparse(istate, ce->name, ce_namelen(ce));
	if (pos >= 0)
		preload_bulk_record_tracked_fallback(worker, pos);

out:
	strbuf_release(&canonical);
	return found;
}
