/*
 * Copyright (C) 2008 Linus Torvalds
 */

#define DISABLE_SIGN_COMPARE_WARNINGS

#include "git-compat-util.h"
#include "pathspec.h"
#include "dir.h"
#include "environment.h"
#include "fsmonitor.h"
#include "gettext.h"
#include "parse.h"
#include "preload-index.h"
#ifdef HAVE_PRELOAD_INDEX_BULK
#include "preload-index-bulk.h"
#endif
#include "progress.h"
#include "read-cache.h"
#include "thread-utils.h"
#include "repository.h"
#include "symlinks.h"
#include "trace2.h"
#include "config.h"

/*
 * Mostly randomly chosen maximum thread counts: we
 * cap the parallelism to 20 threads, and we want
 * to have at least 500 lstat's per thread for it to
 * be worth starting a thread.
 */
#define MAX_PARALLEL (20)
#define THREAD_COST (500)
#define BULK_MAX_PARALLEL (32)
#define BULK_ENTRIES_PER_THREAD (5000)

struct progress_data {
	unsigned long n;
	struct progress *progress;
	pthread_mutex_t mutex;
};

struct thread_data {
	pthread_t pthread;
	struct index_state *index;
	struct pathspec pathspec;
	struct progress_data *progress;
#ifdef HAVE_PRELOAD_INDEX_BULK
	const unsigned char *bulk_state;
#endif
	int offset, nr;
	int t2_nr_lstat;
};

static int preload_entry_needs_stat(const struct cache_entry *ce)
{
	return !ce_stage(ce) &&
		!S_ISGITLINK(ce->ce_mode) &&
		!ce_uptodate(ce) &&
		!ce_skip_worktree(ce) &&
		!(ce->ce_flags & CE_FSMONITOR_VALID);
}

static void *preload_thread(void *_data)
{
	int nr, last_nr;
	struct thread_data *p = _data;
	struct index_state *index = p->index;
	struct cache_entry **cep = index->cache + p->offset;
	struct cache_def cache = CACHE_DEF_INIT;
#ifdef HAVE_PRELOAD_INDEX_BULK
	const unsigned char *bulk_state = p->bulk_state;
#endif

	nr = p->nr;
	if (nr + p->offset > index->cache_nr)
		nr = index->cache_nr - p->offset;
	last_nr = nr;

	do {
		struct cache_entry *ce = *cep++;
		struct stat st;
#ifdef HAVE_PRELOAD_INDEX_BULK
		unsigned char state = bulk_state ?
			*bulk_state++ : PRELOAD_BULK_TRACKED_UNSEEN;
#endif

		if (!preload_entry_needs_stat(ce))
			continue;
#ifdef HAVE_PRELOAD_INDEX_BULK
		if (state == PRELOAD_BULK_TRACKED_CONTENT_CHECK ||
		    state == PRELOAD_BULK_TRACKED_DEFINITIVE_MODIFIED ||
		    state == PRELOAD_BULK_TRACKED_DEFINITIVE_DELETED)
			continue;
#endif
		if (p->progress && !(nr & 31)) {
			struct progress_data *pd = p->progress;

			pthread_mutex_lock(&pd->mutex);
			pd->n += last_nr - nr;
			display_progress(pd->progress, pd->n);
			pthread_mutex_unlock(&pd->mutex);
			last_nr = nr;
		}
		if (!ce_path_match(index, ce, &p->pathspec, NULL))
			continue;
		if (threaded_has_symlink_leading_path(&cache, ce->name, ce_namelen(ce)))
			continue;
		p->t2_nr_lstat++;
		if (lstat(ce->name, &st))
			continue;
		if (ie_match_stat(index, ce, &st, CE_MATCH_RACY_IS_DIRTY|CE_MATCH_IGNORE_FSMONITOR))
			continue;
		ce_mark_uptodate(ce);
		if (fsmonitor_stat_can_be_valid(&st))
			mark_fsmonitor_valid(index, ce);
	} while (--nr > 0);
	if (p->progress) {
		struct progress_data *pd = p->progress;

		pthread_mutex_lock(&pd->mutex);
		display_progress(pd->progress, pd->n + last_nr);
		pthread_mutex_unlock(&pd->mutex);
	}
	cache_def_clear(&cache);
	return NULL;
}

#ifdef HAVE_PRELOAD_INDEX_BULK
static int stat_data_is_zero(const struct stat_data *sd)
{
	return !sd->sd_ctime.sec &&
		!sd->sd_ctime.nsec &&
		!sd->sd_mtime.sec &&
		!sd->sd_mtime.nsec &&
		!sd->sd_dev &&
		!sd->sd_ino &&
		!sd->sd_uid &&
		!sd->sd_gid &&
		!sd->sd_size;
}

static int preload_bulk_entry_is_useful(const struct cache_entry *ce)
{
	return preload_entry_needs_stat(ce) &&
		!ce_intent_to_add(ce) &&
		!(ce->ce_flags & (CE_VALID | CE_REMOVE)) &&
		(S_ISREG(ce->ce_mode) || S_ISLNK(ce->ce_mode)) &&
		!stat_data_is_zero(&ce->ce_stat_data);
}

static size_t preload_bulk_useful_candidates(struct index_state *index)
{
	size_t useful = 0;

	for (size_t i = 0; i < index->cache_nr; i++)
		if (preload_bulk_entry_is_useful(index->cache[i]))
			useful++;
	return useful;
}

static size_t preload_bulk_apply_result(
	struct index_state *index,
	struct preload_bulk_result *result,
	int *has_deferred)
{
	size_t applied = 0;

	if (result->nr != index->cache_nr)
		BUG("bulk preload result does not match the index");

	for (size_t i = 0; i < result->nr; i++) {
		struct cache_entry *ce = index->cache[i];
		unsigned char state = result->tracked_state[i];

		/*
		 * A complete scan which did not observe a useful entry proves
		 * that the entry is absent. Avoid repeating the same lookup in
		 * speculative preload. A status consumer may use this result
		 * directly; other callers retain the authoritative refresh.
		 */
		if (result->can_skip_unseen_preload &&
		    state == PRELOAD_BULK_TRACKED_UNSEEN &&
		    preload_bulk_entry_is_useful(ce)) {
			state = PRELOAD_BULK_TRACKED_DEFINITIVE_DELETED;
			result->tracked_state[i] = state;
		}
		if ((state == PRELOAD_BULK_TRACKED_CONTENT_CHECK ||
		     state == PRELOAD_BULK_TRACKED_DEFINITIVE_MODIFIED ||
		     state == PRELOAD_BULK_TRACKED_DEFINITIVE_DELETED) &&
		    preload_entry_needs_stat(ce))
			*has_deferred = 1;
		if (state != PRELOAD_BULK_TRACKED_CLEAN)
			continue;
		if (!preload_bulk_entry_is_useful(ce))
			continue;
		ce_mark_uptodate(ce);
		mark_fsmonitor_valid(index, ce);
		applied++;
	}
	return applied;
}

static int preload_bulk_threads(size_t useful)
{
	int cpus = online_cpus();
	int threads = DIV_ROUND_UP(useful, BULK_ENTRIES_PER_THREAD);

	if (threads < 1)
		threads = 1;
	if (cpus > 0) {
		int cpu_limit = cpus > BULK_MAX_PARALLEL / 2 ?
			BULK_MAX_PARALLEL : cpus * 2;

		if (threads > cpu_limit)
			threads = cpu_limit;
	}
	if (threads > BULK_MAX_PARALLEL)
		threads = BULK_MAX_PARALLEL;
	return threads;
}

static void preload_bulk_trace_result(
	struct index_state *index,
	const struct preload_bulk_result *result,
	size_t applied)
{
	uint64_t content_check = 0, definitive_modified = 0;
	uint64_t definitive_deleted = 0, fallback = 0;

	for (size_t i = 0; i < result->nr; i++) {
		switch (result->tracked_state[i]) {
		case PRELOAD_BULK_TRACKED_DEFINITIVE_MODIFIED:
			definitive_modified++;
			break;
		case PRELOAD_BULK_TRACKED_DEFINITIVE_DELETED:
			definitive_deleted++;
			break;
		case PRELOAD_BULK_TRACKED_CONTENT_CHECK:
			content_check++;
			break;
		case PRELOAD_BULK_TRACKED_FALLBACK:
			fallback++;
			break;
		default:
			break;
		}
	}
	trace2_data_string("index", index->repo, "preload/bulk_result",
			   result->outcome);
	if (result->reason)
		trace2_data_string("index", index->repo,
				   "preload/bulk_reason", result->reason);
	trace2_data_intmax("index", index->repo, "preload/bulk_applied",
			   applied);
	trace2_data_intmax("index", index->repo, "preload/bulk_dirs",
			   result->run.dirs);
	trace2_data_intmax("index", index->repo, "preload/bulk_entries",
			   result->run.entries);
	trace2_data_intmax("index", index->repo, "preload/bulk_calls",
			   result->run.bulk_calls);
	trace2_data_intmax("index", index->repo, "preload/bulk_workers",
			   result->run.threads);
	trace2_data_intmax("index", index->repo,
			   "preload/bulk_definitive_modified",
			   definitive_modified);
	trace2_data_intmax("index", index->repo,
			   "preload/bulk_definitive_deleted",
			   definitive_deleted);
	trace2_data_intmax("index", index->repo,
			   "preload/bulk_content_check", content_check);
	trace2_data_intmax("index", index->repo,
			   "preload/bulk_fallback", fallback);
}

static unsigned char *preload_bulk_try(struct index_state *index)
{
	struct preload_bulk_result result = { 0 };
	unsigned char *tracked_state = NULL;
	size_t useful;
	size_t applied = 0;
	int has_deferred = 0;
	int enabled = 0;
	int control, threads;

	/*
	 * Let the test variable override configuration without bypassing
	 * any of the proof checks.
	 */
	control = git_env_bool("GIT_TEST_PRELOAD_INDEX_BULK", -1);
	if (control < 0)
		repo_config_get_bool(index->repo, "core.preloadindexbulk",
				     &enabled);
	else
		enabled = control;
	if (!enabled ||
	    fsm_settings__get_mode(index->repo) != FSMONITOR_MODE_DISABLED ||
	    !preload_bulk_available())
		return NULL;
	useful = preload_bulk_useful_candidates(index);
	trace2_data_intmax("index", index->repo, "preload/bulk_useful",
			   useful);
	trace2_data_intmax("index", index->repo, "preload/bulk_cache_nr",
			   index->cache_nr);
	if (!useful)
		return NULL;
	threads = preload_bulk_threads(useful);
	trace2_region_enter("index", "preload/bulk", index->repo);
	if (!preload_bulk_collect(index, threads, &result)) {
		applied = preload_bulk_apply_result(index, &result,
						    &has_deferred);
	}
	preload_bulk_trace_result(index, &result, applied);
	if (has_deferred) {
		tracked_state = result.tracked_state;
		result.tracked_state = NULL;
	}
	trace2_region_leave("index", "preload/bulk", index->repo);
	preload_bulk_result_release(&result);
	return tracked_state;
}

static void preload_bulk_finish_state(struct index_state *index,
				      unsigned char **state,
				      unsigned int refresh_flags)
{
	if ((refresh_flags & REFRESH_DEFER_BULK_DIRTY) && *state) {
		index->preload_bulk_tracked_state = *state;
		index->preload_bulk_tracked_nr = index->cache_nr;
		*state = NULL;
	}
	FREE_AND_NULL(*state);
}
#endif

void preload_index_bulk_result_clear(struct index_state *index)
{
	FREE_AND_NULL(index->preload_bulk_tracked_state);
	index->preload_bulk_tracked_nr = 0;
}

void preload_index(struct index_state *index,
		   const struct pathspec *pathspec,
		   unsigned int refresh_flags)
{
	int threads, i, work, offset;
	struct thread_data data[MAX_PARALLEL];
	struct progress_data pd;
#ifdef HAVE_PRELOAD_INDEX_BULK
	unsigned char *bulk_state = NULL;
#endif
	int t2_sum_lstat = 0;
	int core_preload_index = 1;

	preload_index_bulk_result_clear(index);
	repo_config_get_bool(index->repo, "core.preloadindex", &core_preload_index);

	if (!core_preload_index)
		return;

#ifdef HAVE_PRELOAD_INDEX_BULK
	if (!pathspec || !pathspec->nr)
		bulk_state = preload_bulk_try(index);
#endif
	if (!HAVE_THREADS) {
#ifdef HAVE_PRELOAD_INDEX_BULK
		preload_bulk_finish_state(index, &bulk_state, refresh_flags);
#endif
		return;
	}

	threads = index->cache_nr / THREAD_COST;
	if ((index->cache_nr > 1) && (threads < 2) && git_env_bool("GIT_TEST_PRELOAD_INDEX", 0))
		threads = 2;
	if (threads < 2) {
#ifdef HAVE_PRELOAD_INDEX_BULK
		preload_bulk_finish_state(index, &bulk_state, refresh_flags);
#endif
		return;
	}

	trace2_region_enter("index", "preload", NULL);

	trace_performance_enter();
	if (threads > MAX_PARALLEL)
		threads = MAX_PARALLEL;
	offset = 0;
	work = DIV_ROUND_UP(index->cache_nr, threads);
	memset(&data, 0, sizeof(data));

	memset(&pd, 0, sizeof(pd));
	if (refresh_flags & REFRESH_PROGRESS && isatty(2)) {
		pd.progress = start_delayed_progress(index->repo,
						     _("Refreshing index"),
						     index->cache_nr);
		pthread_mutex_init(&pd.mutex, NULL);
	}

	for (i = 0; i < threads; i++) {
		struct thread_data *p = data+i;
		int err;

		p->index = index;
#ifdef HAVE_PRELOAD_INDEX_BULK
		p->bulk_state = bulk_state ? bulk_state + offset : NULL;
#endif
		if (pathspec)
			copy_pathspec(&p->pathspec, pathspec);
		p->offset = offset;
		p->nr = work;
		if (pd.progress)
			p->progress = &pd;
		offset += work;
		err = pthread_create(&p->pthread, NULL, preload_thread, p);

		if (err)
			die(_("unable to create threaded lstat: %s"), strerror(err));
	}
	for (i = 0; i < threads; i++) {
		struct thread_data *p = data+i;
		if (pthread_join(p->pthread, NULL))
			die("unable to join threaded lstat");
		t2_sum_lstat += p->t2_nr_lstat;
	}
	stop_progress(&pd.progress);
#ifdef HAVE_PRELOAD_INDEX_BULK
	preload_bulk_finish_state(index, &bulk_state, refresh_flags);
#endif

	if (pathspec) {
		/* earlier we made deep copies for each thread to work with */
		for (i = 0; i < threads; i++)
			clear_pathspec(&data[i].pathspec);
	}

	trace_performance_leave("preload index");

	trace2_data_intmax("index", NULL, "preload/sum_lstat", t2_sum_lstat);
	trace2_region_leave("index", "preload", NULL);
}

int repo_read_index_preload(struct repository *repo,
			    const struct pathspec *pathspec,
			    unsigned int refresh_flags)
{
	int retval = repo_read_index(repo);

	preload_index(repo->index, pathspec, refresh_flags);
	return retval;
}
