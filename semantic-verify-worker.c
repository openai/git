#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "attr.h"
#include "convert.h"
#include "object.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "semantic-verify.h"
#include "semantic-verify-internal.h"

static void record_stat_update(struct semantic_verify_worker *worker,
			       uint32_t cache_pos,
			       const struct stat_data *stat_data)
{
	struct semantic_verify_stat_update *update;

	ALLOC_GROW(worker->updates, worker->updates_nr + 1,
		   worker->updates_alloc);
	update = &worker->updates[worker->updates_nr++];
	update->cache_pos = cache_pos;
	memcpy(&update->stat_data, stat_data, sizeof(*stat_data));
}

static void count_result(struct semantic_verify_worker *worker,
			 enum semantic_verify_kind kind)
{
	switch (kind) {
	case SEMANTIC_VERIFY_SKIPPED:
		worker->skipped++;
		break;
	case SEMANTIC_VERIFY_RAW_CLEAN:
		worker->raw_clean++;
		break;
	case SEMANTIC_VERIFY_RAW_MODIFIED:
		worker->raw_modified++;
		break;
	case SEMANTIC_VERIFY_SENSITIVE:
		worker->sensitive++;
		break;
	case SEMANTIC_VERIFY_STRUCTURAL:
		worker->structural++;
		break;
	case SEMANTIC_VERIFY_UNSTABLE:
		worker->unstable++;
		break;
	case SEMANTIC_VERIFY_ERROR:
		worker->errors++;
		break;
	case SEMANTIC_VERIFY_UNCHECKED:
		BUG("cannot count an unchecked semantic result");
	}
}

void semantic_verify_worker_run(struct semantic_verify_worker *worker)
{
	struct semantic_verify_path *path =
		semantic_verify_path_new(worker->root);
	struct attr_check *check = convert_attrs_check_alloc();
	void *buffer = xmalloc(SEMANTIC_VERIFY_HASH_BUFFER_SIZE);
	size_t unstable_from = SIZE_MAX;

	for (size_t i = worker->start; i < worker->end; i++) {
		struct cache_entry *ce = worker->istate->cache[i];
		struct semantic_verify_result *result = &worker->results[i];
		struct semantic_verify_file_result file;

		if (!semantic_verify_classify_entry(worker->istate, ce, check,
						    0,
						    &file)) {
			result->kind = file.kind;
			count_result(worker, result->kind);
			continue;
		}

		semantic_verify_file(worker->root, path, ce, i,
				     worker->istate->repo,
				     buffer, &file);
		result->kind = file.kind;
		result->error = file.error > UINT16_MAX ? EIO : file.error;
		worker->bytes_hashed += file.bytes_hashed;
		if (result->kind == SEMANTIC_VERIFY_RAW_CLEAN) {
			if (file.persistable)
				result->flags |= SEMANTIC_VERIFY_PERSISTABLE;
			else
				worker->hardlinks++;
			if (memcmp(&file.stat_data, &ce->ce_stat_data,
				   sizeof(file.stat_data)))
				record_stat_update(worker, i, &file.stat_data);
		}
		count_result(worker, result->kind);
	}

	semantic_verify_path_free(path, &worker->namespace_unstable,
				  &unstable_from);
	if (worker->namespace_unstable) {
		for (size_t i = unstable_from; i < worker->end; i++) {
			struct semantic_verify_result *result = &worker->results[i];

			if (result->kind != SEMANTIC_VERIFY_RAW_CLEAN)
				continue;
			result->kind = SEMANTIC_VERIFY_UNSTABLE;
			result->flags = 0;
			result->error = EAGAIN;
			worker->raw_clean--;
			worker->unstable++;
		}
	}

	free(buffer);
	attr_check_free(check);
}
