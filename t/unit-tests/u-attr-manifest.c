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

void test_attr_manifest__reader_round_trips_entries(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA256];
	struct attr_manifest_writer writer;
	struct attr_manifest_cursor cursor;
	struct attr_manifest_entry entry;
	struct strbuf manifest = STRBUF_INIT;

	attr_manifest_writer_init(&writer, &manifest, algo);
	add_entry(&writer, ".gitattributes", ATTR_MANIFEST_INDEX, 1);
	add_entry(&writer, "a/.gitattributes", ATTR_MANIFEST_WORKTREE, 2);
	cl_assert(attr_manifest_valid(manifest.buf, manifest.len, algo));
	cl_assert_equal_i(attr_manifest_cursor_init(&cursor, manifest.buf,
						    manifest.len, algo), 0);
	cl_assert_equal_i(attr_manifest_cursor_next(&cursor, &entry), 1);
	cl_assert_equal_i(entry.source, ATTR_MANIFEST_INDEX);
	cl_assert_equal_i(entry.hash[0], 1);
	cl_assert_equal_i(attr_manifest_cursor_next(&cursor, &entry), 1);
	cl_assert_equal_i(entry.source, ATTR_MANIFEST_WORKTREE);
	cl_assert_equal_i(entry.hash[0], 2);
	cl_assert_equal_i(attr_manifest_cursor_next(&cursor, &entry), 0);
	strbuf_release(&manifest);
}

void test_attr_manifest__reader_rejects_corrupt_encoding(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct attr_manifest_writer writer;
	struct strbuf manifest = STRBUF_INIT;
	size_t metadata_offset = 2 * sizeof(uint32_t);
	unsigned char saved;

	attr_manifest_writer_init(&writer, &manifest, algo);
	add_entry(&writer, ".gitattributes", ATTR_MANIFEST_INDEX, 1);
	cl_assert(!attr_manifest_valid(manifest.buf, manifest.len - 1, algo));
	strbuf_addch(&manifest, 0);
	cl_assert(!attr_manifest_valid(manifest.buf, manifest.len, algo));
	strbuf_setlen(&manifest, manifest.len - 1);

	saved = manifest.buf[metadata_offset + 1];
	manifest.buf[metadata_offset + 1] = 1;
	cl_assert(!attr_manifest_valid(manifest.buf, manifest.len, algo));
	manifest.buf[metadata_offset + 1] = saved;
	put_be32(manifest.buf, 2);
	cl_assert(!attr_manifest_valid(manifest.buf, manifest.len, algo));
	strbuf_release(&manifest);
}

void test_attr_manifest__reader_accepts_empty_manifest(void)
{
	struct attr_manifest_writer writer;
	struct strbuf manifest = STRBUF_INIT;

	attr_manifest_writer_init(&writer, &manifest, &hash_algos[GIT_HASH_SHA1]);
	cl_assert(attr_manifest_valid(manifest.buf, manifest.len,
				      &hash_algos[GIT_HASH_SHA1]));
	strbuf_release(&manifest);
}
