#include "git-compat-util.h"
#include "attr-manifest.h"
#include "clean-status.h"
#include "dir.h"
#include "environment.h"
#include "gettext.h"
#include "hash-framing.h"
#include "object.h"
#include "odb.h"
#include "parse.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "semantic-verify-internal.h"
#include "string-list.h"
#include "strbuf.h"
#include "thread-utils.h"
#include "worktree-attr-manifest.h"
#include "worktree-attr-source.h"

#define ATTR_MANIFEST_FILES_PER_THREAD 256
#define ATTR_MANIFEST_MAX_THREADS 32
#define ATTR_MANIFEST_PROGRESS_BATCH 128

struct attr_manifest_candidate {
	unsigned char worktree_hash[GIT_MAX_RAWSZ];
	unsigned char index_hash[GIT_MAX_RAWSZ];
	unsigned int index_present : 1;
	unsigned int worktree_present : 1;
	unsigned int error : 1;
};

struct attr_manifest_probe_data {
	struct string_list *candidates;
	struct semantic_verify_root *root;
	const struct git_hash_algo *algo;
	struct clean_status_progress *progress;
	size_t start;
	size_t end;
	unsigned int namespace_unstable;
};

struct attr_manifest_thread {
	struct attr_manifest_probe_data probe;
	pthread_t pthread;
	unsigned int started : 1;
};

static int collect_candidates(struct index_state *istate,
			      struct string_list *candidates)
{
	struct strbuf candidate = STRBUF_INIT;
	const char *previous = NULL;
	size_t previous_len = 0;
	unsigned int i;
	int ret = -1;

	string_list_append(candidates, GITATTRIBUTES_FILE);
	for (i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];
		const char *slash = ce->name;

		if (ce_stage(ce) || S_ISSPARSEDIR(ce->ce_mode))
			goto done;
		while ((slash = strchr(slash, '/')) != NULL) {
			size_t len = slash - ce->name;

			if (!previous || previous_len <= len ||
			    !is_dir_sep(previous[len]) ||
			    fspathncmp(previous, ce->name, len)) {
				strbuf_reset(&candidate);
				strbuf_add(&candidate, ce->name, len + 1);
				strbuf_addstr(&candidate, GITATTRIBUTES_FILE);
				string_list_append(candidates, candidate.buf);
			}
			slash++;
		}
		previous = ce->name;
		previous_len = ce->ce_namelen;
	}
	string_list_sort(candidates);
	string_list_remove_duplicates(candidates, 0);
	ret = candidates->nr <= UINT32_MAX ? 0 : -1;
done:
	strbuf_release(&candidate);
	return ret;
}

static int collect_index_sources(struct index_state *istate,
				 struct string_list *candidates)
{
	struct strbuf candidate = STRBUF_INIT;
	unsigned int i;
	int ret = 0;

	for (i = 0; i < candidates->nr; i++) {
		struct attr_manifest_candidate *state;

		CALLOC_ARRAY(state, 1);
		candidates->items[i].util = state;
	}
	for (i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];
		const char *base = strrchr(ce->name, '/');
		struct string_list_item *item;
		struct attr_manifest_candidate *state;

		base = base ? base + 1 : ce->name;
		if (fspathcmp(base, GITATTRIBUTES_FILE))
			continue;
		strbuf_reset(&candidate);
		if (base != ce->name)
			strbuf_add(&candidate, ce->name, base - ce->name);
		strbuf_addstr(&candidate, GITATTRIBUTES_FILE);
		item = string_list_lookup(candidates, candidate.buf);
		if (!item)
			BUG("tracked attribute source lacks manifest candidate");
		state = item->util;
		if ((S_ISREG(ce->ce_mode) || S_ISLNK(ce->ce_mode)) &&
		    odb_has_object(istate->repo->objects, &ce->oid, 0)) {
			state->index_present = 1;
			memcpy(state->index_hash, ce->oid.hash,
			       istate->repo->hash_algo->rawsz);
		} else if (S_ISREG(ce->ce_mode) || S_ISLNK(ce->ce_mode)) {
			ret = -1;
			break;
		}
	}
	strbuf_release(&candidate);
	return ret;
}

static void *probe_attr_manifest_candidates(void *cb_data)
{
	struct attr_manifest_probe_data *data = cb_data;
	struct semantic_verify_path *path =
		semantic_verify_path_new(data->root);
	size_t i, completed = 0;

	for (i = data->start; i < data->end; i++) {
		struct string_list_item *item = &data->candidates->items[i];
		struct attr_manifest_candidate *candidate = item->util;
		int found;

		if (worktree_attr_source_read(path, item->string, i, data->algo,
					      candidate->worktree_hash, &found))
			candidate->error = 1;
		else
			candidate->worktree_present = found;
		if (++completed == ATTR_MANIFEST_PROGRESS_BATCH) {
			clean_status_update_progress(data->progress, completed);
			completed = 0;
		}
	}
	clean_status_update_progress(data->progress, completed);
	semantic_verify_path_free(path, &data->namespace_unstable, NULL);
	return NULL;
}

static size_t select_thread_count(size_t candidates)
{
	size_t cpus, test_threads, threads;

	if (!HAVE_THREADS)
		return 1;
	threads = DIV_ROUND_UP(candidates, ATTR_MANIFEST_FILES_PER_THREAD);
	cpus = online_cpus();
	if (threads > cpus * 2)
		threads = cpus * 2;
	test_threads = git_env_ulong("GIT_TEST_ATTR_MANIFEST_THREADS", 0);
	if (test_threads)
		threads = test_threads;
	if (threads > ATTR_MANIFEST_MAX_THREADS)
		threads = ATTR_MANIFEST_MAX_THREADS;
	if (threads > candidates)
		threads = candidates;
	return threads ? threads : 1;
}

static int create_probe_thread(struct attr_manifest_thread *worker,
			       size_t thread_id)
{
	if (git_env_ulong("GIT_TEST_ATTR_MANIFEST_THREAD_FAIL_AT",
			  ULONG_MAX) == thread_id)
		return EAGAIN;
	return pthread_create(&worker->pthread, NULL,
			      probe_attr_manifest_candidates, &worker->probe);
}

static int probe_candidates(struct string_list *candidates,
			    struct repository *repo,
			    struct semantic_verify_root *root,
			    const struct git_hash_algo *algo,
			    struct worktree_attr_manifest_stats *stats)
{
	struct attr_manifest_thread *workers;
	struct clean_status_progress *progress;
	size_t thread_id, threads = select_thread_count(candidates->nr);
	int create_threads = HAVE_THREADS;
	int ret = 0;

	progress = clean_status_start_progress(
		repo, _("Refreshing worktree metadata"), candidates->nr);
	CALLOC_ARRAY(workers, threads);
	for (thread_id = 0; thread_id < threads; thread_id++) {
		struct attr_manifest_thread *worker = &workers[thread_id];
		struct attr_manifest_probe_data *data = &worker->probe;
		int err;

		data->candidates = candidates;
		data->root = root;
		data->algo = algo;
		data->progress = progress;
		data->start = st_mult(candidates->nr, thread_id) / threads;
		data->end = st_mult(candidates->nr, thread_id + 1) / threads;
		if (threads == 1 || !create_threads) {
			probe_attr_manifest_candidates(data);
			continue;
		}
		err = create_probe_thread(worker, thread_id);
		if (!err) {
			worker->started = 1;
			continue;
		}
		stats->thread_failures++;
		create_threads = 0;
		probe_attr_manifest_candidates(data);
	}
	for (thread_id = 0; thread_id < threads; thread_id++) {
		struct attr_manifest_thread *worker = &workers[thread_id];

		if (worker->started && pthread_join(worker->pthread, NULL))
			die("unable to join attribute manifest thread");
		ret |= worker->probe.namespace_unstable;
	}
	stats->threads = threads;
	clean_status_stop_progress(&progress);
	free(workers);
	return ret ? -1 : 0;
}

int worktree_attr_manifest_build(
	struct index_state *istate,
	struct strbuf *manifest,
	unsigned char *manifest_hash,
	struct worktree_attr_manifest_stats *stats)
{
	struct string_list candidates = STRING_LIST_INIT_DUP;
	struct semantic_verify_root *root = NULL;
	struct attr_manifest_writer writer;
	const struct git_hash_algo *algo = istate->repo->hash_algo;
	unsigned int i;
	int ret = -1;

	memset(stats, 0, sizeof(*stats));
	if (istate->sparse_index != INDEX_EXPANDED ||
	    semantic_verify_root_init(istate->repo, &root) ||
	    collect_candidates(istate, &candidates) ||
	    collect_index_sources(istate, &candidates))
		goto done;
	stats->candidates = candidates.nr;
	if (probe_candidates(&candidates, istate->repo, root, algo, stats))
		goto done;
	attr_manifest_writer_init(&writer, manifest, algo);
	for (i = 0; i < candidates.nr; i++) {
		const char *name = candidates.items[i].string;
		struct attr_manifest_candidate *state = candidates.items[i].util;
		enum attr_manifest_source source;
		const unsigned char *hash;

		if (state->error)
			goto done;
		if (state->worktree_present) {
			source = ATTR_MANIFEST_WORKTREE;
			hash = state->worktree_hash;
			stats->worktree_sources++;
		} else if (state->index_present) {
			source = ATTR_MANIFEST_INDEX;
			hash = state->index_hash;
			stats->index_sources++;
		} else {
			continue;
		}
		if (attr_manifest_writer_add(&writer, name, source, hash))
			goto done;
	}
	if (!semantic_verify_root_stable(root))
		goto done;
	if (!attr_manifest_valid(manifest->buf, manifest->len, algo))
		BUG("newly built attribute manifest is invalid");
	hash_buffer_digest(algo, manifest->buf, manifest->len, manifest_hash);
	ret = 0;
done:
	semantic_verify_root_clear(root);
	string_list_clear(&candidates, 1);
	if (ret)
		strbuf_reset(manifest);
	return ret;
}
