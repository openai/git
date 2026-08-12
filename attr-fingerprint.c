#include "git-compat-util.h"
#include "abspath.h"
#include "attr-fingerprint.h"
#include "attr.h"
#include "environment.h"
#include "hash-framing.h"
#include "path.h"
#include "path-namespace.h"
#include "repository.h"
#include "strbuf.h"
#include "wrapper.h"

struct attr_source_snapshot_entry {
	char *path;
	char *buf;
	size_t len;
};

struct attr_source_snapshot {
	struct attr_fingerprint fingerprint;
	struct attr_source_snapshot_entry sources[ATTR_SOURCE_SNAPSHOT_NR];
};

static int open_attr_source(const char *path)
{
#ifdef O_NONBLOCK
	return git_open_cloexec(path, O_RDONLY | O_NONBLOCK);
#else
	(void)path;
	errno = ENOSYS;
	return -1;
#endif
}

static int hash_source(struct git_hash_ctx *content_ctx,
		       struct git_hash_ctx *namespace_ctx,
		       struct git_hash_ctx *portable_namespace_ctx,
		       const struct attr_fingerprint_source *source,
		       int *present,
		       struct attr_source_snapshot_entry *snapshot)
{
	struct path_namespace_snapshot *before = NULL, *after = NULL;
	struct stat opened_before, opened_after, named;
	struct strbuf normalized = STRBUF_INIT;
	char *absolute = NULL;
	char *buf = NULL;
	ssize_t got;
	size_t size;
	uint32_t state;
	int fd = -1, ret = -1;
	char extra;

	hash_optional_cstring(namespace_ctx, source->path);
	put_be32(&state, source->enabled);
	hash_length_delimited(namespace_ctx, &state, sizeof(state));
	hash_length_delimited(portable_namespace_ctx, &state, sizeof(state));
	*present = 0;
	if (!source->enabled || !source->path) {
		hash_optional_cstring(content_ctx, NULL);
		hash_length_delimited(content_ctx, &state, sizeof(state));
		state = 0;
		hash_length_delimited(content_ctx, &state, sizeof(state));
		hash_length_delimited(portable_namespace_ctx, &state,
				      sizeof(state));
		return 0;
	}

	absolute = absolute_pathdup(source->path);
	strbuf_addstr(&normalized, absolute);
	if (strbuf_normalize_path(&normalized) ||
	    path_namespace_capture(normalized.buf, &before))
		goto done;
	*present = path_namespace_target_present(before);
	hash_optional_cstring(content_ctx,
			      *present ? source->path : NULL);
	put_be32(&state, source->enabled);
	hash_length_delimited(content_ctx, &state, sizeof(state));
	if (!*present) {
		if (path_namespace_capture(normalized.buf, &after) ||
		    !path_namespace_equal(before, after))
			goto done;
		state = 0;
		hash_length_delimited(content_ctx, &state, sizeof(state));
		hash_length_delimited(portable_namespace_ctx, &state,
				      sizeof(state));
		path_namespace_hash(namespace_ctx, before);
		ret = 0;
		goto done;
	}

	fd = open_attr_source(normalized.buf);
	if (fd < 0 || fstat(fd, &opened_before) ||
	    !S_ISREG(opened_before.st_mode) || opened_before.st_nlink != 1 ||
	    opened_before.st_size < 0 ||
	    opened_before.st_size >= ATTR_MAX_FILE_SIZE)
		goto done;
	size = xsize_t(opened_before.st_size);
	buf = xmalloc(size ? size : 1);
	got = read_in_full(fd, buf, size);
	if (got < 0 || (size_t)got != size || read(fd, &extra, 1) != 0 ||
	    fstat(fd, &opened_after) || stat(normalized.buf, &named) ||
	    !path_namespace_stat_equal(&opened_before, &opened_after) ||
	    !path_namespace_stat_equal(&opened_after, &named) ||
	    path_namespace_capture(normalized.buf, &after) ||
	    !path_namespace_equal(before, after))
		goto done;
	state = 1;
	hash_length_delimited(content_ctx, &state, sizeof(state));
	hash_length_delimited(portable_namespace_ctx, &state,
			      sizeof(state));
	hash_optional_cstring(portable_namespace_ctx, source->path);
	path_namespace_hash(namespace_ctx, before);
	path_namespace_hash(portable_namespace_ctx, before);
	path_namespace_hash_stat(namespace_ctx, &opened_after);
	path_namespace_hash_stat(portable_namespace_ctx, &opened_after);
	hash_length_delimited(content_ctx, buf, size);
	hash_length_delimited(portable_namespace_ctx, buf, size);
	if (snapshot) {
		snapshot->path = xstrdup(source->path);
		snapshot->buf = buf;
		snapshot->len = size;
		buf = NULL;
	}
	ret = 0;
done:
	if (fd >= 0)
		close(fd);
	free(buf);
	free(absolute);
	path_namespace_clear(before);
	path_namespace_clear(after);
	strbuf_release(&normalized);
	return ret;
}

static int fingerprint_sources(
	const struct attr_fingerprint_source *sources, size_t nr,
	const struct git_hash_algo *algo, struct attr_fingerprint *result,
	struct attr_source_snapshot *snapshot)
{
	struct git_hash_ctx content_ctx, namespace_ctx, portable_namespace_ctx;
	uint32_t count;

	if (snapshot && nr != ARRAY_SIZE(snapshot->sources))
		BUG("attribute snapshot source count mismatch");
	memset(result, 0, sizeof(*result));
	git_hash_init(&content_ctx, algo);
	git_hash_init(&namespace_ctx, algo);
	git_hash_init(&portable_namespace_ctx, algo);
	hash_optional_cstring(&content_ctx, "attribute-source-content-v1");
	hash_optional_cstring(&namespace_ctx,
			      "attribute-source-namespace-v1");
	hash_optional_cstring(&portable_namespace_ctx,
			      "attribute-source-portable-namespace-v1");
	if (nr > UINT32_MAX)
		return -1;
	put_be32(&count, nr);
	hash_length_delimited(&content_ctx, &count, sizeof(count));
	hash_length_delimited(&namespace_ctx, &count, sizeof(count));
	hash_length_delimited(&portable_namespace_ctx, &count, sizeof(count));
	for (size_t i = 0; i < nr; i++) {
		int present;
		struct attr_source_snapshot_entry *entry =
			snapshot ? &snapshot->sources[i] : NULL;

		if (hash_source(&content_ctx, &namespace_ctx,
				&portable_namespace_ctx, &sources[i], &present,
				entry))
			return -1;
		result->sources_present |= present;
	}
	git_hash_final(result->content_hash, &content_ctx);
	git_hash_final(result->namespace_hash, &namespace_ctx);
	git_hash_final(result->portable_namespace_hash,
		       &portable_namespace_ctx);
	return 0;
}

int attr_fingerprint_sources(
	const struct attr_fingerprint_source *sources, size_t nr,
	const struct git_hash_algo *algo, struct attr_fingerprint *result)
{
	return fingerprint_sources(sources, nr, algo, result, NULL);
}

static int repository_sources(struct repository *repo,
			      struct attr_fingerprint_source *sources,
			      char **info_attributes)
{
	if (getenv(GIT_ATTR_SOURCE_ENVIRONMENT))
		return -1;
	sources[0].path = git_attr_system_file();
	sources[0].enabled = git_attr_system_is_enabled();
	sources[1].path = git_attr_global_file();
	sources[1].enabled = 1;
	*info_attributes = repo_git_path(repo, INFOATTRIBUTES_FILE);
	sources[2].path = *info_attributes;
	sources[2].enabled = 1;
	return 0;
}

int attr_fingerprint_repository(struct repository *repo,
				struct attr_fingerprint *result)
{
	struct attr_fingerprint_source sources[ATTR_SOURCE_SNAPSHOT_NR];
	char *info_attributes = NULL;
	int ret;

	memset(result, 0, sizeof(*result));
	if (repository_sources(repo, sources, &info_attributes))
		return -1;
	ret = attr_fingerprint_sources(sources, ARRAY_SIZE(sources),
				       repo->hash_algo, result);
	free(info_attributes);
	return ret;
}

int attr_source_snapshot_repository(struct repository *repo,
				    struct attr_source_snapshot **result)
{
	struct attr_fingerprint_source sources[ATTR_SOURCE_SNAPSHOT_NR];
	struct attr_source_snapshot *snapshot;
	char *info_attributes = NULL;

	if (!result)
		BUG("attr_source_snapshot_repository requires an output");
	*result = NULL;
	if (repository_sources(repo, sources, &info_attributes))
		return -1;
	CALLOC_ARRAY(snapshot, 1);
	if (fingerprint_sources(sources, ARRAY_SIZE(sources), repo->hash_algo,
				&snapshot->fingerprint, snapshot)) {
		attr_source_snapshot_free(snapshot);
		free(info_attributes);
		return -1;
	}
	free(info_attributes);
	*result = snapshot;
	return 0;
}

int attr_source_snapshot_matches_repository(
	struct repository *repo,
	const struct attr_source_snapshot *snapshot)
{
	struct attr_fingerprint current;

	return snapshot &&
		!attr_fingerprint_repository(repo, &current) &&
		current.sources_present ==
			snapshot->fingerprint.sources_present &&
		!memcmp(current.content_hash,
			snapshot->fingerprint.content_hash,
			repo->hash_algo->rawsz);
}

const struct attr_fingerprint *attr_source_snapshot_fingerprint(
	const struct attr_source_snapshot *snapshot)
{
	return snapshot ? &snapshot->fingerprint : NULL;
}

int attr_source_snapshot_read(
	const struct attr_source_snapshot *snapshot,
	enum attr_source_snapshot_kind kind,
	const char **path, const char **buf, size_t *len)
{
	const struct attr_source_snapshot_entry *source;

	if (!snapshot || kind >= ATTR_SOURCE_SNAPSHOT_NR ||
	    !path || !buf || !len)
		BUG("invalid attribute snapshot read");
	source = &snapshot->sources[kind];
	if (!source->buf)
		return 0;
	*path = source->path;
	*buf = source->buf;
	*len = source->len;
	return 1;
}

void attr_source_snapshot_free(struct attr_source_snapshot *snapshot)
{
	if (!snapshot)
		return;
	for (size_t i = 0; i < ARRAY_SIZE(snapshot->sources); i++) {
		free(snapshot->sources[i].path);
		free(snapshot->sources[i].buf);
	}
	free(snapshot);
}
