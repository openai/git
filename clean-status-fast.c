#include "git-compat-util.h"
#include "abspath.h"
#include "attr-fingerprint.h"
#include "clean-status.h"
#include "clean-status-index.h"
#include "clean-status-sidecar.h"
#include "dir.h"
#include "environment.h"
#include "exclude-source-proof.h"
#include "fsmonitor.h"
#include "fsmonitor-settings.h"
#include "object-name.h"
#include "path-namespace.h"
#include "repository.h"
#include "semantic-verify-internal.h"
#include "trace2.h"
#include "worktree.h"
#include "wrapper.h"

#if !EXCLUDE_SOURCE_PROOF_HAS_ANCHORED_OPEN

int clean_status_try_sidecar(
	struct repository *repo UNUSED,
	const struct clean_status_config_digest *config UNUSED,
	int *repository_inputs_changed)
{
	*repository_inputs_changed = 0;
	return 0;
}

#else

struct fast_exclude_context {
	int root_fd;
};

static void trace_miss(struct repository *repo, const char *reason)
{
	trace2_data_string("status", repo, "clean-proof/miss", reason);
}

static int open_exclude_parent(void *data, const char *path)
{
	struct fast_exclude_context *context = data;
	int flags = O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_CLOEXEC;

#ifdef O_NOFOLLOW
	flags |= O_NOFOLLOW;
#endif
	if (is_absolute_path(path))
		return open(path, flags);
	return openat(context->root_fd, path, flags);
}

static int capture_standard_excludes(
	struct repository *repo, struct fast_exclude_context *context,
	struct exclude_source_proof **proof, struct object_id *digest)
{
	struct dir_struct dir = DIR_INIT;
	int ret;

	*proof = exclude_source_proof_create(
		repo->index, context, open_exclude_parent,
		EXCLUDE_SOURCE_PROOF_NONBLOCKING);
	dir.internal.exclude_source_proof = *proof;
	setup_standard_excludes(&dir);
	ret = exclude_source_proof_digest(*proof, repo->hash_algo, digest);
	dir_clear(&dir);
	return ret;
}

static int attr_snapshot_still_matches(
	struct repository *repo, const struct attr_source_snapshot *snapshot)
{
	const struct attr_fingerprint *expected =
		attr_source_snapshot_fingerprint(snapshot);
	struct attr_fingerprint current;

	return expected &&
		!attr_fingerprint_repository(repo, &current) &&
		current.sources_present == expected->sources_present &&
		!memcmp(current.content_hash, expected->content_hash,
			repo->hash_algo->rawsz) &&
		!memcmp(current.namespace_hash, expected->namespace_hash,
			repo->hash_algo->rawsz);
}

static int hardlink_witnesses_still_match(
	struct repository *repo, const struct clean_status_sidecar *sidecar)
{
#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN && !defined(NO_NSEC)
	struct semantic_verify_root *root = NULL;
	struct semantic_verify_path *path = NULL;
	const unsigned char *cursor, *end;
	unsigned int namespace_unstable = 0;
	int ret = 0;

	if (!sidecar->hardlink_nr)
		return 1;
	cursor = sidecar->hardlinks;
	end = cursor + sidecar->hardlinks_len;
	if (!repo->config_values_private_.trust_ctime ||
	    !repo->config_values_private_.check_stat ||
	    semantic_verify_root_init(repo, &root))
		goto done;
	path = semantic_verify_path_new(root);
	if (!path)
		goto done;
	for (uint32_t i = 0; i < sidecar->hardlink_nr; i++) {
		struct path_stat_identity expected, observed;
		const unsigned char *raw_path;
		const char *basename;
		struct stat held, named;
		size_t path_len;
		char *name;
		int parent_fd, fd;

		if (clean_status_sidecar_next_hardlink(
			    &cursor, end, &raw_path, &path_len, &expected) ||
		    !path_len || memchr(raw_path, '\0', path_len))
			goto done;
		name = xmemdupz(raw_path, path_len);
		if (semantic_verify_resolve_parent(
			    path, name, i, &parent_fd, &basename)) {
			free(name);
			goto done;
		}
		fd = semantic_verify_openat(
			parent_fd, basename,
			O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
		if (fd < 0) {
			free(name);
			goto done;
		}
		if (fstat(fd, &held) || !S_ISREG(held.st_mode) ||
		    held.st_nlink <= 1 || held.st_dev != root->stat.st_dev ||
		    fstatat(parent_fd, basename, &named,
			    AT_SYMLINK_NOFOLLOW) ||
		    !path_namespace_stat_equal(&held, &named)) {
			close(fd);
			free(name);
			goto done;
		}
		path_stat_identity_init(&observed, &held);
		close(fd);
		free(name);
		if (!path_stat_identity_equal(&expected, &observed))
			goto done;
	}
	if (cursor != end || !semantic_verify_root_stable(root))
		goto done;
	ret = 1;

done:
	semantic_verify_path_free(path, &namespace_unstable, NULL);
	if (namespace_unstable || (root && !semantic_verify_root_stable(root)))
		ret = 0;
	semantic_verify_root_clear(root);
	return ret;
#else
	(void)repo;
	return !sidecar->hardlink_nr;
#endif
}

static int fast_path_test_barrier(void)
{
	const char *ready =
		getenv("GIT_TEST_STATUS_CLEAN_SIDECAR_BARRIER_READY");
	const char *resume =
		getenv("GIT_TEST_STATUS_CLEAN_SIDECAR_BARRIER_RESUME");
	struct strbuf buf = STRBUF_INIT;
	int fd;
	int ret;

	if (!ready && !resume)
		return 0;
	if (!ready || !resume)
		return -1;
	fd = open(resume, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	write_file(ready, "ready");
	ret = strbuf_read(&buf, fd, 1) > 0 ? 0 : -1;
	close(fd);
	strbuf_release(&buf);
	return ret;
}

static int current_worktree_is_main(struct repository *repo)
{
	struct worktree *worktree = get_current_worktree(repo);
	int ret = worktree && is_main_worktree(worktree);

	free_worktree(worktree);
	return ret;
}

int clean_status_try_sidecar(
	struct repository *repo,
	const struct clean_status_config_digest *config,
	int *repository_inputs_changed)
{
	struct clean_status_sidecar_record record =
		CLEAN_STATUS_SIDECAR_RECORD_INIT;
	struct clean_status_index_snapshot index = { .fd = -1 };
	struct attr_source_snapshot *attrs = NULL;
	struct exclude_source_proof *excludes = NULL;
	struct fast_exclude_context exclude_context = { .root_fd = -1 };
	struct fsmonitor_query_result query = FSMONITOR_QUERY_RESULT_INIT;
	struct clean_status_config_digest fresh_config;
	struct object_id exclude_digest, head_tree;
	struct stat scanned_worktree;
	unsigned char repo_hash[GIT_MAX_RAWSZ];
	char *query_token = NULL;
	int ret = 0;

	*repository_inputs_changed = 0;
	if (!config->finalized ||
	    (config->filter_configured && config->normalized_filter_disable) ||
	    getenv(INDEX_ENVIRONMENT) || is_bare_repository(repo) ||
	    !repo_get_work_tree(repo) ||
	    !current_worktree_is_main(repo) ||
	    fsm_settings__get_mode(repo) != FSMONITOR_MODE_IPC) {
		trace_miss(repo, "fast-repository-shape");
		goto done;
	}
	if (clean_status_sidecar_load(
		    repo->index_file, repo->hash_algo, &record)) {
		trace_miss(repo, "fast-sidecar-missing-or-corrupt");
		goto done;
	}
	if (clean_status_sidecar_pin_source(
		    repo->index_file, &record.sidecar, repo->hash_algo,
		    &index)) {
		trace_miss(repo, "fast-index-mismatch");
		goto done;
	}
	if (memcmp(config->hash, record.sidecar.proof.config_hash,
		   repo->hash_algo->rawsz)) {
		trace_miss(repo, "fast-config-changed");
		goto done;
	}
	if (attr_source_snapshot_repository(repo, &attrs)) {
		trace_miss(repo, "fast-attributes");
		goto done;
	}
	exclude_context.root_fd = open_nofollow(
		repo_get_work_tree(repo),
		O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_CLOEXEC);
	if (exclude_context.root_fd < 0 ||
	    fstat(exclude_context.root_fd, &scanned_worktree) ||
	    capture_standard_excludes(
		    repo, &exclude_context, &excludes, &exclude_digest) ||
	    !oideq(&exclude_digest,
		    &record.sidecar.proof.exclude_source_digest)) {
		trace_miss(repo, "fast-excludes");
		goto done;
	}
	if (clean_status_repository_fingerprint(
		    repo, attrs, &index, &scanned_worktree, repo_hash)) {
		trace_miss(repo, "fast-repository-unavailable");
		goto done;
	}
	if (memcmp(repo_hash, record.sidecar.proof.repo_hash,
		   repo->hash_algo->rawsz)) {
		*repository_inputs_changed = 1;
		trace_miss(repo, "fast-repository-input");
		goto done;
	}
	if (repo_get_oid_tree(repo, "HEAD^{tree}", &head_tree) ||
	    !oideq(&head_tree, &record.sidecar.proof.head_tree)) {
		trace_miss(repo, "fast-head-changed");
		goto done;
	}
	if (!hardlink_witnesses_still_match(repo, &record.sidecar)) {
		trace_miss(repo, "fast-hardlink-changed");
		goto done;
	}

	query_token = xmemdupz(
		record.sidecar.token, record.sidecar.token_len);
	if (query_builtin_fsmonitor(query_token, &query) !=
		    FSMONITOR_QUERY_DELTA ||
	    query.paths.len) {
		trace_miss(repo, "fast-provider-changed");
		goto done;
	}
	if (fast_path_test_barrier()) {
		trace_miss(repo, "fast-test-barrier");
		goto done;
	}

	if (clean_status_config_read_repository(repo, &fresh_config) ||
	    fresh_config.filter_configured != config->filter_configured ||
	    (fresh_config.filter_configured &&
	     fresh_config.normalized_filter_disable) ||
	    memcmp(fresh_config.hash, config->hash,
		   repo->hash_algo->rawsz)) {
		trace_miss(repo, "fast-config-raced");
		goto done;
	}
	if (repo_get_oid_tree(repo, "HEAD^{tree}", &head_tree) ||
	    !oideq(&head_tree, &record.sidecar.proof.head_tree)) {
		trace_miss(repo, "fast-head-raced");
		goto done;
	}
	if (clean_status_repository_fingerprint(
		    repo, attrs, &index, &scanned_worktree, repo_hash) ||
	    memcmp(repo_hash, record.sidecar.proof.repo_hash,
		   repo->hash_algo->rawsz)) {
		trace_miss(repo, "fast-repository-raced");
		goto done;
	}
	if (!attr_snapshot_still_matches(repo, attrs)) {
		trace_miss(repo, "fast-attributes-raced");
		goto done;
	}
	if (!exclude_source_proof_validate(excludes)) {
		trace_miss(repo, "fast-excludes-raced");
		goto done;
	}
	if (!clean_status_index_snapshot_still_matches_path(
		    &index, repo->index_file, repo->hash_algo)) {
		trace_miss(repo, "fast-index-raced");
		goto done;
	}
	if (!hardlink_witnesses_still_match(repo, &record.sidecar)) {
		trace_miss(repo, "fast-hardlink-raced");
		goto done;
	}

	if (record.sidecar.hardlink_nr)
		trace2_data_intmax("status", repo,
				   "clean-proof/hardlink-validated",
				   record.sidecar.hardlink_nr);
	trace2_data_intmax("status", repo, "clean-proof/hit", 1);
	ret = 1;

done:
	free(query_token);
	fsmonitor_query_result_release(&query);
	if (exclude_context.root_fd >= 0)
		close(exclude_context.root_fd);
	exclude_source_proof_release(excludes);
	attr_source_snapshot_free(attrs);
	clean_status_index_snapshot_release(&index);
	clean_status_sidecar_record_release(&record);
	return ret;
}

#endif /* EXCLUDE_SOURCE_PROOF_HAS_ANCHORED_OPEN */
