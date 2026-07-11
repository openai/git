#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "convert.h"
#include "object.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "semantic-verify.h"
#include "semantic-verify-internal.h"
#include "trace2.h"

static void combine_worker(struct semantic_verify_proof *proof,
			   struct semantic_verify_worker *worker)
{
	size_t base = proof->stat_updates_nr;

	if (worker->updates_nr)
		COPY_ARRAY(proof->stat_updates + base, worker->updates,
			   worker->updates_nr);
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
	proof->namespace_unstable |= worker->namespace_unstable;
	free(worker->updates);
}

int semantic_verify_prepare(struct index_state *istate,
			    struct semantic_verify_proof **proof_out)
{
	struct semantic_verify_proof *proof;
	struct semantic_verify_worker worker = { 0 };

	if (!istate || !proof_out)
		BUG("semantic_verify_prepare requires an index and output");

	CALLOC_ARRAY(proof, 1);
	proof->istate = istate;
	proof->cache_nr = istate->cache_nr;
	CALLOC_ARRAY(proof->results, proof->cache_nr);
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
	trace2_region_enter("semantic_verify", "prepare", istate->repo);
	trace2_data_intmax("semantic_verify", istate->repo, "threads", 1);
	trace2_data_intmax("semantic_verify", istate->repo,
			   "result-bytes", sizeof(struct semantic_verify_result));

	worker.istate = istate;
	worker.root = proof->root;
	worker.results = proof->results;
	worker.end = proof->cache_nr;
	semantic_verify_worker_run(&worker);
	ALLOC_ARRAY(proof->stat_updates, worker.updates_nr);
	combine_worker(proof, &worker);

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
	stats->namespace_unstable = proof->namespace_unstable;
}

const struct semantic_verify_result *semantic_verify_result_at(
	const struct semantic_verify_proof *proof, size_t cache_pos)
{
	if (!proof || cache_pos >= proof->cache_nr)
		BUG("semantic verifier result position out of range");
	return &proof->results[cache_pos];
}

void semantic_verify_proof_clear(struct semantic_verify_proof *proof)
{
	if (!proof)
		return;
	semantic_verify_root_clear(proof->root);
	free(proof->stat_updates);
	free(proof->results);
	free(proof);
}
