#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "convert.h"
#include "fsmonitor.h"
#include "object.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "semantic-verify.h"
#include "semantic-verify-internal.h"
#include "trace2.h"

#define SEMANTIC_VERIFY_ENTRY_FLAGS \
	(CE_VALID | CE_STAGEMASK | CE_INTENT_TO_ADD | CE_SKIP_WORKTREE | \
	 CE_UPTODATE | CE_FSMONITOR_VALID | CE_CONTENT_CHECK_REQUIRED)
#define SEMANTIC_VERIFY_MAX_THREADS 32

static void *run_worker(void *data)
{
	semantic_verify_worker_run(data);
	return NULL;
}

static unsigned int select_thread_count(
	size_t cache_nr,
	const struct semantic_verify_options *options)
{
	unsigned int nr;

	if (!HAVE_THREADS)
		return 1;
	if (options && options->nr_threads) {
		nr = options->nr_threads;
	} else {
		unsigned int cpus = online_cpus();

		nr = cpus > SEMANTIC_VERIFY_MAX_THREADS / 2 ?
			SEMANTIC_VERIFY_MAX_THREADS : cpus * 2;
	}
	if (nr > SEMANTIC_VERIFY_MAX_THREADS)
		nr = SEMANTIC_VERIFY_MAX_THREADS;
	if (nr > cache_nr && cache_nr)
		nr = cache_nr;
	return nr;
}

static void combine_worker(struct semantic_verify_proof *proof,
			   struct semantic_verify_worker *worker)
{
	size_t base = proof->stat_updates_nr;

	if (worker->updates_nr)
		COPY_ARRAY(proof->stat_updates + base, worker->updates,
			   worker->updates_nr);
	for (size_t i = 0; i < worker->updates_nr; i++) {
		uint32_t cache_pos = worker->updates[i].cache_pos;

		proof->results[cache_pos].stat_update_index = base + i;
	}
	proof->stat_updates_nr += worker->updates_nr;
	proof->bytes_hashed += worker->bytes_hashed;
	proof->raw_clean += worker->raw_clean;
	proof->raw_modified += worker->raw_modified;
	proof->sensitive += worker->sensitive;
	proof->structural += worker->structural;
	proof->skipped += worker->skipped;
	proof->unstable += worker->unstable;
	proof->errors += worker->errors;
	proof->hardlinks += worker->hardlinks;
	proof->active_filters += worker->active_filters;
	proof->namespace_unstable |= worker->namespace_unstable;
	free(worker->updates);
}

int semantic_verify_prepare(struct index_state *istate,
			    const struct semantic_verify_options *options,
			    struct semantic_verify_proof **proof_out)
{
	struct semantic_verify_proof *proof;
	struct semantic_verify_worker *workers;
	unsigned int nr_threads;
	size_t updates_nr = 0;
	int create_threads = 1;

	if (!istate || !proof_out)
		BUG("semantic_verify_prepare requires an index and output");
	if (sizeof(struct semantic_verify_result) != 8)
		BUG("semantic verify result unexpectedly grew to %"PRIuMAX" bytes",
		    (uintmax_t)sizeof(struct semantic_verify_result));
	CALLOC_ARRAY(proof, 1);
	proof->istate = istate;
	proof->filter_scope_checked = options &&
		options->validate_filter_scope;
	proof->cache_nr = istate->cache_nr;
	CALLOC_ARRAY(proof->results, proof->cache_nr);
	CALLOC_ARRAY(proof->entry_identities, proof->cache_nr);
	for (size_t i = 0; i < proof->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];
		struct semantic_verify_entry_identity *identity =
			&proof->entry_identities[i];

		proof->results[i].stat_update_index = UINT32_MAX;
		identity->entry = ce;
		oidcpy(&identity->oid, &ce->oid);
		identity->stat_data = ce->ce_stat_data;
		identity->name = xstrdup(ce->name);
		identity->mode = ce->ce_mode;
		identity->flags = ce->ce_flags & SEMANTIC_VERIFY_ENTRY_FLAGS;
	}
	*proof_out = proof;
	if (!proof->cache_nr)
		return 0;
	if (istate->sparse_index != INDEX_EXPANDED) {
		for (size_t i = 0; i < proof->cache_nr; i++) {
			proof->results[i].kind = SEMANTIC_VERIFY_STRUCTURAL;
			proof->structural++;
		}
		return 0;
	}
	if (semantic_verify_root_init(istate->repo, &proof->root)) {
		int saved_errno = errno;

		for (size_t i = 0; i < proof->cache_nr; i++) {
			proof->results[i].kind = SEMANTIC_VERIFY_ERROR;
			proof->results[i].error = saved_errno > UINT16_MAX ?
				EIO : saved_errno;
		}
		proof->errors = proof->cache_nr;
		return -1;
	}

	/* Initialize conversion config and default attribute state serially. */
	convert_attrs_prepare(istate);
	nr_threads = select_thread_count(proof->cache_nr, options);
	CALLOC_ARRAY(workers, nr_threads);
	trace2_region_enter("semantic_verify", "prepare", istate->repo);
	trace2_data_intmax("semantic_verify", istate->repo,
			   "threads", nr_threads);
	trace2_data_intmax("semantic_verify", istate->repo,
			   "result-bytes", sizeof(struct semantic_verify_result));

	for (unsigned int i = 0; i < nr_threads; i++) {
		struct semantic_verify_worker *worker = &workers[i];
		int err;

		worker->istate = istate;
		worker->root = proof->root;
		worker->results = proof->results;
		worker->start = st_mult(proof->cache_nr, i) / nr_threads;
		worker->end = st_mult(proof->cache_nr, i + 1) / nr_threads;
		worker->validate_filter_scope = proof->filter_scope_checked;
		if (nr_threads == 1 || !create_threads) {
			semantic_verify_worker_run(worker);
			continue;
		}
		err = pthread_create(&worker->pthread, NULL, run_worker, worker);
		if (!err) {
			worker->started = 1;
			continue;
		}
		create_threads = 0;
		trace2_data_intmax("semantic_verify", istate->repo,
				   "thread-failure", err);
		semantic_verify_worker_run(worker);
	}
	for (unsigned int i = 0; i < nr_threads; i++) {
		int err;

		if (!workers[i].started)
			continue;
		err = pthread_join(workers[i].pthread, NULL);
		if (err)
			die("could not join semantic verifier thread: %s",
			    strerror(err));
	}

	for (unsigned int i = 0; i < nr_threads; i++)
		updates_nr += workers[i].updates_nr;
	ALLOC_ARRAY(proof->stat_updates, updates_nr);
	for (unsigned int i = 0; i < nr_threads; i++)
		combine_worker(proof, &workers[i]);
	free(workers);

	trace2_data_intmax("semantic_verify", istate->repo,
			   "raw-clean", proof->raw_clean);
	trace2_data_intmax("semantic_verify", istate->repo,
			   "raw-modified", proof->raw_modified);
	trace2_data_intmax("semantic_verify", istate->repo,
			   "sensitive", proof->sensitive);
	trace2_data_intmax("semantic_verify", istate->repo,
			   "structural", proof->structural);
	trace2_data_intmax("semantic_verify", istate->repo,
			   "unstable", proof->unstable);
	trace2_data_intmax("semantic_verify", istate->repo,
			   "errors", proof->errors);
	trace2_data_intmax("semantic_verify", istate->repo,
			   "bytes-hashed", proof->bytes_hashed);
	trace2_data_intmax("semantic_verify", istate->repo,
			   "active-filters", proof->active_filters);
	trace2_data_intmax("semantic_verify", istate->repo,
			   "filter-scope-checked", proof->filter_scope_checked);
	trace2_region_leave("semantic_verify", "prepare", istate->repo);
	return 0;
}

int semantic_verify_root_is_stable(const struct semantic_verify_proof *proof)
{
	return proof && semantic_verify_root_stable(proof->root);
}

void semantic_verify_get_stats(const struct semantic_verify_proof *proof,
			       struct semantic_verify_stats *stats)
{
	if (!proof || !stats)
		BUG("semantic_verify_get_stats requires proof and output");
	stats->cache_nr = proof->cache_nr;
	stats->stat_updates_nr = proof->stat_updates_nr;
	stats->bytes_hashed = proof->bytes_hashed;
	stats->raw_clean = proof->raw_clean;
	stats->raw_modified = proof->raw_modified;
	stats->sensitive = proof->sensitive;
	stats->structural = proof->structural;
	stats->skipped = proof->skipped;
	stats->unstable = proof->unstable;
	stats->errors = proof->errors;
	stats->hardlinks = proof->hardlinks;
	stats->active_filters = proof->active_filters;
	stats->namespace_unstable = proof->namespace_unstable;
	stats->filter_scope_checked = proof->filter_scope_checked;
}

const struct semantic_verify_result *semantic_verify_result_at(
	const struct semantic_verify_proof *proof, size_t cache_pos)
{
	if (!proof || cache_pos >= proof->cache_nr)
		BUG("semantic verifier result position out of range");
	return &proof->results[cache_pos];
}

int semantic_verify_apply_after_closure(
	struct index_state *istate,
	const struct semantic_verify_proof *proof)
{
	int applied = 0;
	int poisoned = 0;
	size_t validated_updates = 0;

	if (!istate || !proof || proof->istate != istate ||
	    proof->cache_nr != istate->cache_nr ||
	    proof->namespace_unstable ||
	    !semantic_verify_root_is_stable(proof))
		return -1;
	if (proof->active_filters) {
		trace2_data_intmax("semantic_verify", istate->repo,
				   "filter-scope-rejected", 1);
		return -1;
	}

	for (size_t i = 0; i < proof->cache_nr; i++) {
		const struct semantic_verify_entry_identity *identity =
			&proof->entry_identities[i];
		const struct cache_entry *ce = istate->cache[i];

		if (ce != identity->entry ||
		    !oideq(&ce->oid, &identity->oid) ||
		    memcmp(&ce->ce_stat_data, &identity->stat_data,
			   sizeof(ce->ce_stat_data)) ||
		    strcmp(ce->name, identity->name) ||
		    ce->ce_mode != identity->mode ||
		    (ce->ce_flags & SEMANTIC_VERIFY_ENTRY_FLAGS) !=
			    identity->flags)
			return -1;
	}

	/* Validate the complete proof before changing any cache entry. */
	for (size_t i = 0; i < proof->cache_nr; i++) {
		const struct semantic_verify_result *result = &proof->results[i];

		if (result->kind > SEMANTIC_VERIFY_ERROR ||
		    (result->flags & ~(SEMANTIC_VERIFY_PERSISTABLE |
				      SEMANTIC_VERIFY_ACTIVE_FILTER)))
			return -1;
		if (result->kind == SEMANTIC_VERIFY_UNCHECKED ||
		    result->kind == SEMANTIC_VERIFY_STRUCTURAL ||
		    result->kind == SEMANTIC_VERIFY_UNSTABLE ||
		    result->kind == SEMANTIC_VERIFY_ERROR)
			return -1;
		if (result->kind != SEMANTIC_VERIFY_RAW_CLEAN) {
			if (result->flags ||
			    result->stat_update_index != UINT32_MAX)
				return -1;
			continue;
		}
		if (result->stat_update_index != UINT32_MAX) {
			const struct semantic_verify_stat_update *update;

			if (result->stat_update_index >= proof->stat_updates_nr)
				return -1;
			update = &proof->stat_updates[result->stat_update_index];
			if (update->cache_pos != i)
				return -1;
			validated_updates++;
		}
	}
	if (validated_updates != proof->stat_updates_nr)
		return -1;

	for (size_t i = 0; i < proof->cache_nr; i++) {
		const struct semantic_verify_result *result = &proof->results[i];
		struct cache_entry *ce = istate->cache[i];

		/* Force the ordinary refresh tail to preserve mismatches. */
		if (result->kind == SEMANTIC_VERIFY_RAW_MODIFIED ||
		    (result->kind == SEMANTIC_VERIFY_RAW_CLEAN &&
		     !(result->flags & SEMANTIC_VERIFY_PERSISTABLE))) {
			fsmonitor_invalidate_cache_entry(ce);
			mark_fsmonitor_invalid(istate, ce);
			ce->ce_flags |= CE_UPDATE_IN_BASE;
			istate->cache_changed |= CE_ENTRY_CHANGED;
			poisoned++;
			if (result->kind == SEMANTIC_VERIFY_RAW_CLEAN)
				applied++;
			continue;
		}
		if (result->kind != SEMANTIC_VERIFY_RAW_CLEAN)
			continue;
		if (result->stat_update_index != UINT32_MAX) {
			const struct semantic_verify_stat_update *update =
				&proof->stat_updates[result->stat_update_index];

			memcpy(&ce->ce_stat_data, &update->stat_data,
			       sizeof(ce->ce_stat_data));
			ce->ce_flags |= CE_UPDATE_IN_BASE;
			istate->cache_changed |= CE_ENTRY_CHANGED;
		}
		ce_mark_uptodate(ce);
		if (result->flags & SEMANTIC_VERIFY_PERSISTABLE)
			mark_fsmonitor_valid(istate, ce);
		applied++;
	}
	trace2_data_intmax("semantic_verify", istate->repo,
			   "applied", applied);
	trace2_data_intmax("semantic_verify", istate->repo,
			   "poisoned-for-tail", poisoned);
	return applied;
}

void semantic_verify_proof_clear(struct semantic_verify_proof *proof)
{
	if (!proof)
		return;
	semantic_verify_root_clear(proof->root);
	for (size_t i = 0; i < proof->cache_nr; i++)
		free(proof->entry_identities[i].name);
	free(proof->entry_identities);
	free(proof->stat_updates);
	free(proof->results);
	free(proof);
}
