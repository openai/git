#include "git-compat-util.h"
#include "name-hash.h"
#include "parse.h"
#include "preload-index-bulk.h"
#include "read-cache-ll.h"

static int backend_available(const struct preload_bulk_backend *backend)
{
	return backend && backend->start && backend->finish &&
		backend->release && backend->open_dir_at &&
		backend->scan_directory;
}

int preload_bulk_available(void)
{
	return backend_available(preload_bulk_platform_backend());
}

int preload_bulk_test_barrier(struct preload_bulk_scan *scan,
			      const char *path)
{
	struct strbuf buf = STRBUF_INIT;
	int result;

	if (!scan->test_barrier_path ||
	    strcmp(scan->test_barrier_path, path))
		return 0;
	if (!scan->test_barrier_ready || !scan->test_barrier_resume)
		return -1;

	write_file(scan->test_barrier_ready, "ready");
	result = strbuf_read_file(&buf, scan->test_barrier_resume, 1) > 0 ?
		0 : -1;
	strbuf_release(&buf);
	return result;
}

int preload_bulk_collect(struct index_state *istate, int threads,
			 struct preload_bulk_result *result)
{
	const struct preload_bulk_backend *backend =
		preload_bulk_platform_backend();
	struct preload_bulk_scan scan = {
		.repo = istate->repo,
		.istate = istate,
		.backend = backend,
		.root_fd = -1,
		.threads = threads,
	};
	struct preload_bulk_run_result run_result = { 0 };
	const char *start_error, *finish_error = NULL;
	int scan_error = -1;
	int clean;

	memset(result, 0, sizeof(*result));
	result->outcome = "start-fallback";
	result->reason = "backend-unavailable";
	if (!backend_available(backend))
		return -1;
	if (istate->sparse_index == INDEX_EXPANDED) {
		/*
		 * Workers may need case-folding lookups for names returned by
		 * the filesystem. Build the lazy hash before they start.
		 *
		 * A collapsed sparse index cannot expand itself concurrently
		 * from the worker threads. Leave its unseen entries to the
		 * existing preload path, which expands them on the main thread.
		 */
		scan.case_insensitive = prepare_index_casefolding(istate);
		scan.can_skip_unseen_preload = 1;
	}

	if (git_env_bool("GIT_TEST_PRELOAD_INDEX_BULK", 0)) {
		scan.test_barrier_path = getenv(
			"GIT_TEST_PRELOAD_INDEX_BULK_BARRIER_PATH");
		scan.test_barrier_ready = getenv(
			"GIT_TEST_PRELOAD_INDEX_BULK_BARRIER_READY");
		scan.test_barrier_resume = getenv(
			"GIT_TEST_PRELOAD_INDEX_BULK_BARRIER_RESUME");
	}

	CALLOC_ARRAY(scan.tracked_state, istate->cache_nr);
	start_error = backend->start(&scan);
	if (!start_error) {
		scan_error = preload_bulk_run_scan(&scan, &run_result);
		if (!scan_error)
			scan_error = preload_bulk_test_barrier(&scan, "");
		finish_error = backend->finish(&scan);
	}

	clean = !start_error && !scan_error && !finish_error &&
		!run_result.changed_dirs &&
		!run_result.malformed;
	result->run = run_result;
	if (start_error) {
		result->outcome = "start-fallback";
		result->reason = start_error;
	} else if (run_result.changed_dirs) {
		result->outcome = "scan-fallback";
		result->reason = "filesystem-race";
	} else if (run_result.malformed) {
		result->outcome = "scan-fallback";
		result->reason = "malformed-record";
	} else if (scan_error) {
		result->outcome = "scan-fallback";
		result->reason = "scan-error";
	} else if (finish_error) {
		result->outcome = "finish-fallback";
		result->reason = finish_error;
	} else {
		result->outcome = "complete";
		result->reason = NULL;
	}
	if (clean) {
		result->tracked_state = scan.tracked_state;
		result->nr = istate->cache_nr;
		result->can_skip_unseen_preload =
			scan.can_skip_unseen_preload;
		scan.tracked_state = NULL;
	}

	backend->release(&scan);
	free(scan.tracked_state);
	return clean ? 0 : -1;
}

void preload_bulk_result_release(struct preload_bulk_result *result)
{
	FREE_AND_NULL(result->tracked_state);
	memset(result, 0, sizeof(*result));
}
