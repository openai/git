#ifndef FSMONITOR_H
#define FSMONITOR_H

#include "fsmonitor-ll.h"
#include "dir.h"
#include "fsmonitor-settings.h"
#include "object.h"
#include "read-cache-ll.h"
#include "strbuf.h"
#include "trace.h"

/*
 * Force the next stat-aware caller to verify this entry's content. Wider
 * invalidation, such as attributes or untracked-cache state, is the caller's
 * responsibility.
 */
void fsmonitor_invalidate_cache_entry(struct cache_entry *ce);

enum fsmonitor_query_outcome {
	FSMONITOR_QUERY_ERROR = 0,
	FSMONITOR_QUERY_DELTA,
	FSMONITOR_QUERY_TRIVIAL,
};

struct fsmonitor_query_result {
	enum fsmonitor_query_outcome outcome;
	struct strbuf token;
	struct strbuf paths;
};

#define FSMONITOR_QUERY_RESULT_INIT { \
	.outcome = FSMONITOR_QUERY_ERROR, \
	.token = STRBUF_INIT, \
	.paths = STRBUF_INIT, \
}

void fsmonitor_query_result_release(struct fsmonitor_query_result *result);
enum fsmonitor_query_outcome fsmonitor_parse_builtin_response(
	const struct strbuf *raw, struct fsmonitor_query_result *result);

/*
 * A pathname monitor cannot prove that every name for a multiply-linked
 * inode is inside its watch cone. When the platform reports real link
 * counts, keep such regular files out of the persistent valid bitmap so
 * that every new process checks their stat data. Platforms that synthesize
 * link counts retain their existing fsmonitor behavior. The in-process
 * CE_UPTODATE bit is still safe after the caller's lstat().
 */
static inline int fsmonitor_stat_can_be_valid(const struct stat *st)
{
	return !S_ISREG(st->st_mode) || st->st_nlink <= 1;
}

void fsmonitor_invalidate_semantics(struct index_state *istate);

/*
 * Check if refresh_fsmonitor has been called at least once.
 * refresh_fsmonitor is idempotent. Returns true if fsmonitor is
 * not enabled (since the state will be "fresh" w/ CE_FSMONITOR_VALID unset)
 * This version is useful for assertions
 */
static inline int is_fsmonitor_refreshed(const struct index_state *istate)
{
	enum fsmonitor_mode fsm_mode = fsm_settings__get_mode(istate->repo);

	return fsm_mode <= FSMONITOR_MODE_DISABLED ||
		istate->fsmonitor_has_run_once;
}

/*
 * Set the given cache entries CE_FSMONITOR_VALID bit. This should be
 * called any time the cache entry has been updated to reflect the
 * current state of the file on disk.
 *
 * However, never mark submodules as valid.  When commands like "git
 * status" run they might need to recurse into the submodule (using a
 * child process) to get a summary of the submodule state.  We don't
 * have (and don't want to create) the facility to translate every
 * FS event that we receive and that happens to be deep inside of a
 * submodule back to the submodule root, so we cannot correctly keep
 * track of this bit on the gitlink directory.  Therefore, we never
 * set it on submodules.
 */
static inline void mark_fsmonitor_valid(struct index_state *istate, struct cache_entry *ce)
{
	enum fsmonitor_mode fsm_mode = fsm_settings__get_mode(istate->repo);

	if (fsm_mode > FSMONITOR_MODE_DISABLED &&
	    !(ce->ce_flags & CE_FSMONITOR_VALID)) {
		if (S_ISGITLINK(ce->ce_mode))
			return;
		istate->cache_changed |= FSMONITOR_CHANGED;
		ce->ce_flags |= CE_FSMONITOR_VALID;
		trace_printf_key(&trace_fsmonitor, "mark_fsmonitor_clean '%s'", ce->name);
	}
}

/*
 * Clear the given cache entry's CE_FSMONITOR_VALID bit and invalidate
 * any corresponding untracked cache directory structures. This should
 * be called any time git creates or modifies a file that should
 * trigger an lstat() or invalidate the untracked cache for the
 * corresponding directory
 */
static inline void mark_fsmonitor_invalid(struct index_state *istate, struct cache_entry *ce)
{
	enum fsmonitor_mode fsm_mode = fsm_settings__get_mode(istate->repo);

	if (fsm_mode > FSMONITOR_MODE_DISABLED) {
		ce->ce_flags &= ~CE_FSMONITOR_VALID;
		untracked_cache_invalidate_path(istate, ce->name, 1);
		trace_printf_key(&trace_fsmonitor, "mark_fsmonitor_invalid '%s'", ce->name);
	}
}

#endif
