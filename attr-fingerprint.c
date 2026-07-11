#include "git-compat-util.h"
#include "abspath.h"
#include "attr-fingerprint.h"
#include "attr.h"
#include "hash-framing.h"
#include "path-namespace.h"
#include "strbuf.h"
#include "wrapper.h"

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
		       const struct attr_fingerprint_source *source,
		       int *present)
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

	hash_optional_cstring(content_ctx, source->path);
	hash_optional_cstring(namespace_ctx, source->path);
	put_be32(&state, source->enabled);
	hash_length_delimited(content_ctx, &state, sizeof(state));
	hash_length_delimited(namespace_ctx, &state, sizeof(state));
	*present = 0;
	if (!source->enabled || !source->path)
		return 0;

	absolute = absolute_pathdup(source->path);
	strbuf_addstr(&normalized, absolute);
	if (strbuf_normalize_path(&normalized) ||
	    path_namespace_capture(normalized.buf, &before))
		goto done;
	*present = path_namespace_target_present(before);
	if (!*present) {
		if (path_namespace_capture(normalized.buf, &after) ||
		    !path_namespace_equal(before, after))
			goto done;
		state = 0;
		hash_length_delimited(content_ctx, &state, sizeof(state));
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
	path_namespace_hash(namespace_ctx, before);
	path_namespace_hash_stat(namespace_ctx, &opened_after);
	hash_length_delimited(content_ctx, buf, size);
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
	const struct git_hash_algo *algo, struct attr_fingerprint *result)
{
	struct git_hash_ctx content_ctx, namespace_ctx;
	uint32_t count;

	memset(result, 0, sizeof(*result));
	git_hash_init(&content_ctx, algo);
	git_hash_init(&namespace_ctx, algo);
	hash_optional_cstring(&content_ctx, "attribute-source-content-v1");
	hash_optional_cstring(&namespace_ctx,
			      "attribute-source-namespace-v1");
	if (nr > UINT32_MAX)
		return -1;
	put_be32(&count, nr);
	hash_length_delimited(&content_ctx, &count, sizeof(count));
	hash_length_delimited(&namespace_ctx, &count, sizeof(count));
	for (size_t i = 0; i < nr; i++) {
		int present;

		if (hash_source(&content_ctx, &namespace_ctx, &sources[i],
				&present))
			return -1;
		result->sources_present |= present;
	}
	git_hash_final(result->content_hash, &content_ctx);
	git_hash_final(result->namespace_hash, &namespace_ctx);
	return 0;
}

int attr_fingerprint_sources(
	const struct attr_fingerprint_source *sources, size_t nr,
	const struct git_hash_algo *algo, struct attr_fingerprint *result)
{
	return fingerprint_sources(sources, nr, algo, result);
}
