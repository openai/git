#include "unit-test.h"
#include "attr-fingerprint.h"
#include "dir.h"
#include "strbuf.h"
#include "wrapper.h"

static char *create_directory(void)
{
	const char *tmp = getenv("TMPDIR");
	char *path = xstrfmt("%s/attr-fingerprint.XXXXXX",
				 tmp ? tmp : "/tmp");

	cl_assert(mkdtemp(path) != NULL);
	return path;
}

static void remove_directory(char *path)
{
	struct strbuf cleanup = STRBUF_INIT;

	strbuf_addstr(&cleanup, path);
	cl_assert_equal_i(remove_dir_recursively(&cleanup, 0), 0);
	strbuf_release(&cleanup);
	free(path);
}

static void fingerprint(const char *path, int enabled,
			const struct git_hash_algo *algo,
			struct attr_fingerprint *result)
{
	struct attr_fingerprint_source source = {
		.path = path,
		.enabled = enabled,
	};

	cl_assert_equal_i(attr_fingerprint_sources(
		&source, 1, algo, result), 0);
}

void test_attr_fingerprint__separates_contents_from_namespace(void)
{
#ifndef O_NONBLOCK
	cl_skip();
#else
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	char *directory = create_directory();
	struct strbuf path = STRBUF_INIT;
	struct attr_fingerprint initial, metadata, changed;
	struct stat st;

	strbuf_addf(&path, "%s/attributes", directory);
	write_file(path.buf, "*.txt text\n");
	fingerprint(path.buf, 1, algo, &initial);
	cl_assert(initial.sources_present);
	cl_assert_equal_i(stat(path.buf, &st), 0);
	cl_assert_equal_i(chmod(path.buf, st.st_mode ^ S_IXUSR), 0);
	fingerprint(path.buf, 1, algo, &metadata);
	cl_assert(!memcmp(initial.content_hash, metadata.content_hash,
			  algo->rawsz));
	cl_assert(memcmp(initial.namespace_hash, metadata.namespace_hash,
			 algo->rawsz));
	write_file(path.buf, "*.txt -text\n");
	fingerprint(path.buf, 1, algo, &changed);
	cl_assert(memcmp(metadata.content_hash, changed.content_hash,
			 algo->rawsz));

	strbuf_release(&path);
	remove_directory(directory);
#endif
}

void test_attr_fingerprint__records_missing_parent_namespaces(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA256];
	char *directory;
	struct strbuf path = STRBUF_INIT;
	struct attr_fingerprint before, after;
	struct stat st;

	if (!fstat_is_reliable()) {
		struct attr_fingerprint_source source = {
			.path = "missing/attributes",
			.enabled = 1,
		};

		cl_assert(attr_fingerprint_sources(
			&source, 1, algo, &before) < 0);
		cl_assert_equal_i(errno, EAGAIN);
		return;
	}
	directory = create_directory();

	strbuf_addf(&path, "%s/missing/attributes", directory);
	fingerprint(path.buf, 1, algo, &before);
	cl_assert(!before.sources_present);
	cl_assert_equal_i(stat(directory, &st), 0);
	cl_assert_equal_i(chmod(directory, st.st_mode ^ S_IXGRP), 0);
	fingerprint(path.buf, 1, algo, &after);
	cl_assert(!after.sources_present);
	cl_assert(!memcmp(before.content_hash, after.content_hash, algo->rawsz));
	cl_assert(memcmp(before.namespace_hash, after.namespace_hash,
			 algo->rawsz));

	strbuf_release(&path);
	remove_directory(directory);
}

void test_attr_fingerprint__does_not_observe_disabled_sources(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	char *directory = create_directory();
	struct strbuf path = STRBUF_INIT;
	struct attr_fingerprint before, after;

	strbuf_addf(&path, "%s/attributes", directory);
	fingerprint(path.buf, 0, algo, &before);
	write_file(path.buf, "*.txt text\n");
	fingerprint(path.buf, 0, algo, &after);
	cl_assert(!before.sources_present);
	cl_assert(!after.sources_present);
	cl_assert(!memcmp(before.content_hash, after.content_hash, algo->rawsz));
	cl_assert(!memcmp(before.namespace_hash, after.namespace_hash,
			  algo->rawsz));

	strbuf_release(&path);
	remove_directory(directory);
}
