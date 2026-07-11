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

static int record_changed_path(const struct attr_manifest_entry *entry,
			       void *data)
{
	struct strbuf *paths = data;

	if (paths->len)
		strbuf_addch(paths, ' ');
	strbuf_add(paths, entry->path, entry->path_len);
	return 0;
}

void test_attr_manifest__iterates_added_removed_and_modified_entries(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct attr_manifest_writer old_writer, new_writer;
	struct strbuf old = STRBUF_INIT, new = STRBUF_INIT, changed = STRBUF_INIT;

	attr_manifest_writer_init(&old_writer, &old, algo);
	add_entry(&old_writer, ".gitattributes", ATTR_MANIFEST_INDEX, 1);
	add_entry(&old_writer, "a/.gitattributes", ATTR_MANIFEST_INDEX, 2);
	add_entry(&old_writer, "c/.gitattributes", ATTR_MANIFEST_INDEX, 3);
	attr_manifest_writer_init(&new_writer, &new, algo);
	add_entry(&new_writer, ".gitattributes", ATTR_MANIFEST_INDEX, 1);
	add_entry(&new_writer, "a/.gitattributes", ATTR_MANIFEST_WORKTREE, 2);
	add_entry(&new_writer, "b/.gitattributes", ATTR_MANIFEST_INDEX, 4);

	cl_assert_equal_i(attr_manifest_for_each_changed(
		old.buf, old.len, new.buf, new.len, algo,
		record_changed_path, &changed), 0);
	cl_assert_equal_s(changed.buf,
			  "a/.gitattributes b/.gitattributes c/.gitattributes");
	strbuf_release(&changed);
	strbuf_release(&new);
	strbuf_release(&old);
}

void test_attr_manifest__does_not_report_identical_entries(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct attr_manifest_writer old_writer, new_writer;
	struct strbuf old = STRBUF_INIT, new = STRBUF_INIT, changed = STRBUF_INIT;

	attr_manifest_writer_init(&old_writer, &old, algo);
	add_entry(&old_writer, ".gitattributes", ATTR_MANIFEST_INDEX, 1);
	attr_manifest_writer_init(&new_writer, &new, algo);
	add_entry(&new_writer, ".gitattributes", ATTR_MANIFEST_INDEX, 1);
	cl_assert_equal_i(attr_manifest_for_each_changed(
		old.buf, old.len, new.buf, new.len, algo,
		record_changed_path, &changed), 0);
	cl_assert_equal_i(changed.len, 0);
	strbuf_release(&changed);
	strbuf_release(&new);
	strbuf_release(&old);
}

void test_attr_manifest__rejects_malformed_tail_before_callbacks(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct attr_manifest_writer old_writer, new_writer;
	struct strbuf old = STRBUF_INIT, new = STRBUF_INIT, changed = STRBUF_INIT;

	attr_manifest_writer_init(&old_writer, &old, algo);
	add_entry(&old_writer, ".gitattributes", ATTR_MANIFEST_INDEX, 1);
	attr_manifest_writer_init(&new_writer, &new, algo);
	add_entry(&new_writer, ".gitattributes", ATTR_MANIFEST_INDEX, 2);
	strbuf_addch(&new, 0);

	cl_assert_equal_i(attr_manifest_for_each_changed(
		old.buf, old.len, new.buf, new.len, algo,
		record_changed_path, &changed), -1);
	cl_assert_equal_i(changed.len, 0);

	strbuf_release(&changed);
	strbuf_release(&new);
	strbuf_release(&old);
}
