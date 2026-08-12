#include "unit-test.h"
#include "attr-fingerprint.h"
#include "dir.h"
#include "path.h"
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
	cl_assert(memcmp(initial.portable_namespace_hash,
			 metadata.portable_namespace_hash, algo->rawsz));
	write_file(path.buf, "*.txt -text\n");
	fingerprint(path.buf, 1, algo, &changed);
	cl_assert(memcmp(metadata.content_hash, changed.content_hash,
			 algo->rawsz));
	cl_assert(memcmp(metadata.portable_namespace_hash,
			 changed.portable_namespace_hash, algo->rawsz));

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
	cl_assert(!memcmp(before.portable_namespace_hash,
			  after.portable_namespace_hash, algo->rawsz));

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
	cl_assert(!memcmp(before.portable_namespace_hash,
			  after.portable_namespace_hash, algo->rawsz));

	strbuf_release(&path);
	remove_directory(directory);
}

void test_attr_fingerprint__equates_distinct_absent_source_paths(void)
{
#ifndef O_NONBLOCK
	cl_skip();
#else
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA256];
	char *directory;
	struct strbuf absent_a = STRBUF_INIT;
	struct strbuf absent_b = STRBUF_INIT;
	struct strbuf present = STRBUF_INIT;
	struct attr_fingerprint_source first[2], second[2];
	struct attr_fingerprint before, after, changed;

	if (!fstat_is_reliable())
		cl_skip();
	directory = create_directory();
	strbuf_addf(&absent_a, "%s/system-a/attributes", directory);
	strbuf_addf(&absent_b, "%s/system-b/attributes", directory);
	strbuf_addf(&present, "%s/global-attributes", directory);
	write_file(present.buf, "*.txt text\n");

	first[0] = (struct attr_fingerprint_source) {
		.path = absent_a.buf,
		.enabled = 1,
	};
	first[1] = (struct attr_fingerprint_source) {
		.path = present.buf,
		.enabled = 1,
	};
	second[0] = first[0];
	second[0].path = absent_b.buf;
	second[1] = first[1];

	cl_assert_equal_i(attr_fingerprint_sources(
		first, ARRAY_SIZE(first), algo, &before), 0);
	cl_assert_equal_i(attr_fingerprint_sources(
		second, ARRAY_SIZE(second), algo, &after), 0);
	cl_assert(before.sources_present);
	cl_assert(after.sources_present);
	cl_assert(!memcmp(before.content_hash, after.content_hash,
			  algo->rawsz));
	cl_assert(!memcmp(before.portable_namespace_hash,
			  after.portable_namespace_hash, algo->rawsz));
	cl_assert(memcmp(before.namespace_hash, after.namespace_hash,
			 algo->rawsz));

	second[0].enabled = 0;
	cl_assert_equal_i(attr_fingerprint_sources(
		second, ARRAY_SIZE(second), algo, &changed), 0);
	cl_assert(memcmp(before.content_hash, changed.content_hash,
			 algo->rawsz));
	cl_assert(memcmp(before.portable_namespace_hash,
			 changed.portable_namespace_hash, algo->rawsz));

	first[0].enabled = 0;
	cl_assert_equal_i(attr_fingerprint_sources(
		first, ARRAY_SIZE(first), algo, &before), 0);
	cl_assert(!memcmp(before.content_hash, changed.content_hash,
			  algo->rawsz));
	cl_assert(!memcmp(before.portable_namespace_hash,
			  changed.portable_namespace_hash, algo->rawsz));
	cl_assert(memcmp(before.namespace_hash, changed.namespace_hash,
			 algo->rawsz));

	first[0].enabled = 1;
	first[0].path = present.buf;
	first[1].path = absent_a.buf;
	second[0].enabled = 1;
	cl_assert_equal_i(attr_fingerprint_sources(
		first, ARRAY_SIZE(first), algo, &before), 0);
	cl_assert_equal_i(attr_fingerprint_sources(
		second, ARRAY_SIZE(second), algo, &after), 0);
	cl_assert(memcmp(before.content_hash, after.content_hash,
			 algo->rawsz));
	cl_assert(memcmp(before.portable_namespace_hash,
			 after.portable_namespace_hash, algo->rawsz));

	write_file(present.buf, "*.txt -text\n");
	cl_assert_equal_i(attr_fingerprint_sources(
		second, ARRAY_SIZE(second), algo, &changed), 0);
	cl_assert(memcmp(after.content_hash, changed.content_hash,
			 algo->rawsz));
	cl_assert(memcmp(after.portable_namespace_hash,
			 changed.portable_namespace_hash, algo->rawsz));

	cl_assert_equal_i(
		safe_create_leading_directories_no_share(absent_b.buf), 0);
	write_file(absent_b.buf, "*.system text\n");
	cl_assert_equal_i(attr_fingerprint_sources(
		second, ARRAY_SIZE(second), algo, &before), 0);
	cl_assert(memcmp(changed.content_hash, before.content_hash,
			 algo->rawsz));
	cl_assert(memcmp(changed.portable_namespace_hash,
			 before.portable_namespace_hash, algo->rawsz));
	write_file(absent_b.buf, "*.system -text\n");
	cl_assert_equal_i(attr_fingerprint_sources(
		second, ARRAY_SIZE(second), algo, &after), 0);
	cl_assert(memcmp(before.content_hash, after.content_hash,
			 algo->rawsz));
	cl_assert(memcmp(before.portable_namespace_hash,
			 after.portable_namespace_hash, algo->rawsz));

	strbuf_release(&present);
	strbuf_release(&absent_b);
	strbuf_release(&absent_a);
	remove_directory(directory);
#endif
}
