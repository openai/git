#include "git-compat-util.h"
#include "abspath.h"
#include "dir.h"
#include "exclude-source-proof.h"
#include "name-hash.h"
#include "parse.h"
#include "preload-index-bulk.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "trace2.h"

struct preload_bulk_untracked_root {
	struct preload_bulk_untracked_root *next;
	/*
	 * Normal-mode status reports an untracked directory after finding
	 * one visible descendant.  Share that decision among workers below
	 * the directory.
	 */
	unsigned visible : 1;
	char path[FLEX_ARRAY];
};

static int backend_available(const struct preload_bulk_backend *backend)
{
	return backend && backend->start && backend->finish &&
		backend->release && backend->open_dir_at &&
		backend->scan_directory;
}

static int open_exclude_parent(void *data, const char *path)
{
	struct preload_bulk_scan *scan = data;

	if (is_absolute_path(path))
		return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	return scan->backend->open_proof_parent(scan, path);
}

int preload_bulk_available(void)
{
	return backend_available(preload_bulk_platform_backend());
}

int preload_bulk_test_barrier(struct preload_bulk_scan *scan,
			      const char *path)
{
	struct strbuf buf = STRBUF_INIT;
	int fd;
	int result;

	if (!scan->test_barrier_path ||
	    strcmp(scan->test_barrier_path, path))
		return 0;
	if (!scan->test_barrier_ready || !scan->test_barrier_resume)
		return -1;

	fd = open(scan->test_barrier_resume, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	write_file(scan->test_barrier_ready, "ready");
	result = strbuf_read(&buf, fd, 1) > 0 ? 0 : -1;
	close(fd);
	strbuf_release(&buf);
	return result;
}

int preload_bulk_path_is_excluded(struct preload_bulk_worker *worker,
				  const char *path, int dtype)
{
	struct preload_bulk_scan *scan = worker->scan;
	int result;

	if (!scan->exclude_dir)
		BUG("bulk preload has no exclude state");
	pthread_mutex_lock(&scan->exclude_mutex);
	result = is_excluded(scan->exclude_dir, scan->istate, path, &dtype);
	pthread_mutex_unlock(&scan->exclude_mutex);
	return result;
}

void preload_bulk_invalidate_untracked(
	struct preload_bulk_worker *worker)
{
	struct preload_bulk_queue *queue = &worker->scan->queue;

	pthread_mutex_lock(&queue->mutex);
	queue->untracked_invalid = 1;
	pthread_mutex_unlock(&queue->mutex);
}

int preload_bulk_untracked_is_invalid(
	struct preload_bulk_worker *worker)
{
	struct preload_bulk_queue *queue = &worker->scan->queue;
	int invalid;

	pthread_mutex_lock(&queue->mutex);
	invalid = queue->untracked_invalid;
	pthread_mutex_unlock(&queue->mutex);
	return invalid;
}

struct preload_bulk_untracked_root *preload_bulk_untracked_root_new(
	struct preload_bulk_worker *worker, const char *path,
	size_t path_len)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct preload_bulk_untracked_root *root;

	FLEX_ALLOC_MEM(root, path, path, path_len + 1);
	root->path[path_len] = '/';
	root->path[path_len + 1] = '\0';

	pthread_mutex_lock(&scan->queue.mutex);
	root->next = scan->untracked_roots;
	scan->untracked_roots = root;
	pthread_mutex_unlock(&scan->queue.mutex);
	return root;
}

int preload_bulk_untracked_root_is_visible(
	struct preload_bulk_worker *worker MAYBE_UNUSED,
	const struct preload_bulk_untracked_root *root)
{
	int visible;

	if (!root)
		return 0;
	pthread_mutex_lock(&worker->scan->queue.mutex);
	visible = root->visible;
	pthread_mutex_unlock(&worker->scan->queue.mutex);
	return visible;
}

void preload_bulk_record_untracked(
	struct preload_bulk_worker *worker,
	struct preload_bulk_untracked_root *root,
	const char *path)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct preload_bulk_queue *queue = &scan->queue;
	int record = 1;

	pthread_mutex_lock(&queue->mutex);
	if (queue->untracked_invalid)
		record = 0;
	else if (root) {
		if (root->visible)
			record = 0;
		else
			root->visible = 1;
	}
	if (record)
		string_list_append(&scan->untracked,
				   root ? root->path : path);
	pthread_mutex_unlock(&queue->mutex);
}

static int collect_untracked_paths(struct preload_bulk_scan *scan,
				   struct preload_bulk_result *result)
{
	/*
	 * Do not publish provisional output until all closing validations
	 * have succeeded.
	 */
	string_list_sort(&scan->untracked);
	for (size_t i = 1; i < scan->untracked.nr; i++)
		if (!strcmp(scan->untracked.items[i - 1].string,
			    scan->untracked.items[i].string))
			return -1;
	result->untracked = scan->untracked;
	scan->untracked = (struct string_list)STRING_LIST_INIT_DUP;
	return 0;
}

int preload_bulk_collect(struct index_state *istate, int threads,
			 struct preload_bulk_result *result)
{
	struct dir_struct exclude_dir = DIR_INIT;
	struct exclude_source_proof *exclude_proof = NULL;
	const struct preload_bulk_backend *backend =
		preload_bulk_platform_backend();
	struct preload_bulk_scan scan = {
		.repo = istate->repo,
		.istate = istate,
		.backend = backend,
		.proof_epoch = istate->preload_bulk_proof_epoch,
		.root_fd = -1,
		.threads = threads,
		.untracked = STRING_LIST_INIT_DUP,
	};
	struct preload_bulk_run_result run_result = { 0 };
	struct object_id standard_excludes_digest;
	struct stat root_stat;
	const char *start_error, *finish_error = NULL;
	const char *untracked_reason = NULL;
	int standard_excludes_digest_valid = 0;
	int scan_error = -1;
	int clean;

	memset(result, 0, sizeof(*result));
	result->untracked.strdup_strings = 1;
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
	scan.collect_untracked =
		!!istate->preload_untracked &&
		backend->collects_untracked &&
		backend->open_proof_parent;
	if (istate->preload_untracked && !scan.collect_untracked)
		untracked_reason = "backend-unsupported";
	if (backend->max_threads > 0 &&
	    scan.threads > backend->max_threads)
		scan.threads = backend->max_threads;
	if (scan.collect_untracked) {
		scan.exclude_dir = &exclude_dir;
#if HAVE_THREADS
		if (pthread_mutex_init(&scan.exclude_mutex, NULL)) {
			return -1;
		}
#endif
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
	if (!start_error && (scan.proof_epoch || scan.collect_untracked) &&
	    (scan.root_fd < 0 || fstat(scan.root_fd, &root_stat)))
		start_error = "root-stat";
	if (!start_error && scan.proof_epoch)
		scan.root_dev = root_stat.st_dev;
	if (!start_error) {
		if (scan.collect_untracked) {
			exclude_proof = exclude_source_proof_create(
				istate, &scan, open_exclude_parent, 0);
			exclude_dir.internal.exclude_source_proof =
				exclude_proof;
			setup_standard_excludes(&exclude_dir);
			standard_excludes_digest_valid =
				!exclude_source_proof_digest(
					exclude_proof,
					istate->repo->hash_algo,
					&standard_excludes_digest);
		}
		scan_error = preload_bulk_run_scan(&scan, &run_result);
		if (!scan_error)
			scan_error = preload_bulk_test_barrier(&scan, "");
		finish_error = backend->finish(&scan);
		if (!scan_error && !finish_error &&
		    run_result.untracked_complete) {
			int exclude_proof_valid;

			trace2_region_enter(
				"index", "preload/bulk_excludes", istate->repo);
			exclude_proof_valid =
				exclude_source_proof_validate(exclude_proof);
			if (!standard_excludes_digest_valid ||
			    !exclude_proof_valid) {
				run_result.untracked_complete = 0;
				untracked_reason = "exclude-race";
			}
			trace2_region_leave(
				"index", "preload/bulk_excludes", istate->repo);
		}
	}

	clean = !start_error && !scan_error && !finish_error &&
		!run_result.changed_dirs &&
		!run_result.malformed;
	if (clean && run_result.untracked_complete &&
	    collect_untracked_paths(&scan, result)) {
		run_result.untracked_complete = 0;
		untracked_reason = "duplicate-path";
	}
	result->run = run_result;
	result->untracked_reason = untracked_reason;
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
		result->stat_updates = scan.stat_updates;
		result->stat_updates_nr = scan.stat_updates_nr;
		result->nr = istate->cache_nr;
		result->can_skip_unseen_preload =
			scan.can_skip_unseen_preload;
		result->untracked_complete = run_result.untracked_complete;
		if (result->untracked_complete) {
			result->standard_excludes_digest_valid = 1;
			oidcpy(&result->standard_excludes_digest,
			       &standard_excludes_digest);
			result->scanned_worktree = root_stat;
		}
		scan.tracked_state = NULL;
		scan.stat_updates = NULL;
		scan.stat_updates_nr = 0;
	}

	backend->release(&scan);
	while (scan.untracked_roots) {
		struct preload_bulk_untracked_root *next =
			scan.untracked_roots->next;

		free(scan.untracked_roots);
		scan.untracked_roots = next;
	}
	string_list_clear(&scan.untracked, 0);
	if (scan.exclude_dir) {
#if HAVE_THREADS
		pthread_mutex_destroy(&scan.exclude_mutex);
#endif
		dir_clear(&exclude_dir);
		exclude_source_proof_release(exclude_proof);
	}
	free(scan.tracked_state);
	free(scan.stat_updates);
	return clean ? 0 : -1;
}

void preload_bulk_result_release(struct preload_bulk_result *result)
{
	FREE_AND_NULL(result->tracked_state);
	FREE_AND_NULL(result->stat_updates);
	string_list_clear(&result->untracked, 0);
	memset(result, 0, sizeof(*result));
}
