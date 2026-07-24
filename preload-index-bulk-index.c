#include "git-compat-util.h"
#include "preload-index-bulk.h"
#include "read-cache-ll.h"

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

int preload_bulk_index_has_tracked_descendants(struct preload_bulk_scan *scan,
					       const char *path,
					       size_t path_len)
{
	int pos;

	if (path_len > INT_MAX)
		return 0;
	pos = index_name_pos_sparse(scan->istate, path, path_len);
	return preload_bulk_index_pos_has_tracked_descendants(
		scan, path, path_len, pos);
}

int preload_bulk_index_pos_has_tracked_descendants(
	struct preload_bulk_scan *scan, const char *path, size_t path_len,
	int pos)
{
	struct index_state *istate = scan->istate;
	const struct cache_entry *ce;

	if (pos >= 0)
		return 0;
	pos = -pos - 1;
	while ((unsigned int)pos < istate->cache_nr) {
		ce = istate->cache[pos];
		if (ce_namelen(ce) < path_len ||
		    memcmp(ce->name, path, path_len))
			return 0;
		if (ce_namelen(ce) == path_len) {
			pos++;
			continue;
		}
		if (ce->name[path_len] == '/')
			return 1;
		if ((unsigned char)ce->name[path_len] > '/')
			return 0;
		pos++;
	}
	return 0;
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

static int tracked_entry_is_eligible(const struct cache_entry *ce)
{
	return !ce_stage(ce) &&
		!ce_intent_to_add(ce) &&
		!ce_skip_worktree(ce) &&
		!(ce->ce_flags & (CE_VALID | CE_REMOVE)) &&
		(S_ISREG(ce->ce_mode) || S_ISLNK(ce->ce_mode));
}

void preload_bulk_record_tracked(
	struct preload_bulk_worker *worker, int pos, const struct stat *st)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct cache_entry *ce = scan->istate->cache[pos];
	unsigned int changed;
	unsigned char state;

	if (!tracked_entry_is_eligible(ce))
		return;
	changed = ie_match_stat(
		scan->istate, ce, (struct stat *)st,
		CE_MATCH_RACY_IS_DIRTY | CE_MATCH_IGNORE_FSMONITOR);
	state = changed ? PRELOAD_BULK_TRACKED_CONTENT_CHECK :
			  PRELOAD_BULK_TRACKED_CLEAN;
	record_tracked_state(worker, pos, state);
}
