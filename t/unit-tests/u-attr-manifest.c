#include "unit-test.h"
#include "attr-manifest.h"
#include "strbuf.h"

static void fill_hash(unsigned char *hash, unsigned char value,
		      const struct git_hash_algo *algo)
{
	memset(hash, value, algo->rawsz);
}

static void add_entry(struct attr_manifest_writer *writer, const char *path,
		      enum attr_manifest_source source, unsigned char value)
{
	unsigned char hash[GIT_MAX_RAWSZ];

	fill_hash(hash, value, writer->algo);
	cl_assert_equal_i(attr_manifest_writer_add(writer, path, source, hash), 0);
}

void test_attr_manifest__writer_serializes_sorted_entries(void)
{
	struct attr_manifest_writer writer;
	struct strbuf manifest = STRBUF_INIT;

	attr_manifest_writer_init(&writer, &manifest, &hash_algos[GIT_HASH_SHA256]);
	add_entry(&writer, ".gitattributes", ATTR_MANIFEST_INDEX, 1);
	add_entry(&writer, "a/.gitattributes", ATTR_MANIFEST_WORKTREE, 2);
	cl_assert_equal_i(get_be32(manifest.buf), 2);
	cl_assert_equal_i(writer.nr, 2);
	strbuf_release(&manifest);
}

void test_attr_manifest__writer_rejects_invalid_or_unsorted_paths(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct attr_manifest_writer writer;
	struct strbuf manifest = STRBUF_INIT;
	unsigned char hash[GIT_MAX_RAWSZ];

	fill_hash(hash, 1, algo);
	attr_manifest_writer_init(&writer, &manifest, algo);
	add_entry(&writer, "b/.gitattributes", ATTR_MANIFEST_INDEX, 1);
	cl_assert_equal_i(attr_manifest_writer_add(&writer, "a/.gitattributes",
						    ATTR_MANIFEST_INDEX, hash), -1);
	cl_assert_equal_i(attr_manifest_writer_add(&writer, "b/.gitattributes",
						    ATTR_MANIFEST_INDEX, hash), -1);
	cl_assert_equal_i(attr_manifest_writer_add(&writer, "/.gitattributes",
						    ATTR_MANIFEST_INDEX, hash), -1);
	cl_assert_equal_i(attr_manifest_writer_add(&writer, "b/not-attributes",
						    ATTR_MANIFEST_INDEX, hash), -1);
	cl_assert_equal_i(writer.nr, 1);
	strbuf_release(&manifest);
}
