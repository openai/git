#include "unit-test.h"
#include "attr-manifest.h"
#include "dir.h"
#include "hash.h"
#include "odb.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "semantic-verify-internal.h"
#include "setup.h"
#include "strbuf.h"
#include "thread-utils.h"
#include "worktree-attr-manifest.h"
#include "wrapper.h"

#define ATTR_MANIFEST_TEST_THREADS "GIT_TEST_ATTR_MANIFEST_THREADS"
#define ATTR_MANIFEST_TEST_THREAD_FAIL_AT \
	"GIT_TEST_ATTR_MANIFEST_THREAD_FAIL_AT"
#define ATTR_MANIFEST_TEST_SOURCE_NR 257

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

#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
static char *create_worktree(void)
{
	const char *tmp = getenv("TMPDIR");
	char *path = xstrfmt("%s/attr-manifest.XXXXXX", tmp ? tmp : "/tmp");

	cl_assert(mkdtemp(path) != NULL);
	return path;
}

static void remove_worktree(char *worktree)
{
	struct strbuf path = STRBUF_INIT;

	strbuf_addstr(&path, worktree);
	cl_assert_equal_i(remove_dir_recursively(&path, 0), 0);
	strbuf_release(&path);
	free(worktree);
}

static struct cache_entry *add_index_path(struct index_state *istate,
					  size_t pos, const char *path,
					  unsigned int stage)
{
	size_t len = strlen(path);
	struct cache_entry *ce = make_empty_cache_entry(istate, len);

	ce->ce_mode = S_IFREG | 0644;
	ce->ce_flags = create_ce_flags(stage);
	ce->ce_namelen = len;
	memcpy(ce->name, path, len + 1);
	istate->cache[pos] = ce;
	return ce;
}

static void init_object_store(struct repository *repo, const char *worktree)
{
	struct strbuf object_dir = STRBUF_INIT;

	strbuf_addf(&object_dir, "%s/objects", worktree);
	repo->objects = odb_new(repo, object_dir.buf, "");
	strbuf_release(&object_dir);
}
#endif

void test_attr_manifest__builds_sources_for_tracked_scopes(void)
{
#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	cl_skip();
#else
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	char *worktree = create_worktree();
	struct repository repo = { .worktree = worktree, .hash_algo = algo };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct worktree_attr_manifest_stats stats;
	struct attr_manifest_cursor cursor;
	struct attr_manifest_entry entry;
	struct git_hash_ctx ctx;
	struct strbuf path = STRBUF_INIT, manifest = STRBUF_INIT;
	char root_source[] = "*.root text\n";
	unsigned char expected[GIT_MAX_RAWSZ], hash[GIT_MAX_RAWSZ];

	strbuf_addf(&path, "%s/a", worktree);
	cl_assert_equal_i(mkdir(path.buf, 0777), 0);
	strbuf_reset(&path);
	strbuf_addf(&path, "%s/b", worktree);
	cl_assert_equal_i(mkdir(path.buf, 0777), 0);
	strbuf_reset(&path);
	strbuf_addf(&path, "%s/.gitattributes", worktree);
	write_file_buf(path.buf, root_source, strlen(root_source));
	git_hash_init(&ctx, algo);
	git_hash_update(&ctx, root_source, strlen(root_source));
	git_hash_final(expected, &ctx);
	strbuf_reset(&path);
	strbuf_addf(&path, "%s/a/.gitattributes", worktree);
	write_file(path.buf, "*.dat -text\n");

	CALLOC_ARRAY(istate.cache, 2);
	istate.cache_alloc = istate.cache_nr = 2;
	add_index_path(&istate, 0, "a/file", 0);
	add_index_path(&istate, 1, "b/file", 0);
	cl_assert_equal_i(worktree_attr_manifest_build(
		&istate, &manifest, hash, &stats), 0);
	cl_assert_equal_i(stats.candidates, 3);
	cl_assert_equal_i(stats.worktree_sources, 2);
	cl_assert_equal_i(stats.index_sources, 0);
	cl_assert(attr_manifest_valid(manifest.buf, manifest.len, algo));

	cl_assert_equal_i(attr_manifest_cursor_init(
		&cursor, manifest.buf, manifest.len, algo), 0);
	cl_assert_equal_i(attr_manifest_cursor_next(&cursor, &entry), 1);
	cl_assert_equal_i(entry.source, ATTR_MANIFEST_WORKTREE);
	cl_assert_equal_i(entry.path_len, strlen(GITATTRIBUTES_FILE));
	cl_assert(!memcmp(entry.path, GITATTRIBUTES_FILE, entry.path_len));
	cl_assert(!memcmp(entry.hash, expected, algo->rawsz));
	cl_assert_equal_i(attr_manifest_cursor_next(&cursor, &entry), 1);
	cl_assert_equal_i(entry.source, ATTR_MANIFEST_WORKTREE);
	cl_assert_equal_i(attr_manifest_cursor_next(&cursor, &entry), 0);

	strbuf_release(&manifest);
	strbuf_release(&path);
	release_index(&istate);
	remove_worktree(worktree);
#endif
}

void test_attr_manifest__falls_back_to_index_source(void)
{
#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	cl_skip();
#else
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	char *worktree = create_worktree();
	char source[] = "*.dat text\n";
	struct repository repo = { .worktree = worktree, .hash_algo = algo };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct worktree_attr_manifest_stats stats;
	struct attr_manifest_cursor cursor;
	struct attr_manifest_entry entry;
	struct cache_entry *attributes;
	struct strbuf manifest = STRBUF_INIT;
	unsigned char hash[GIT_MAX_RAWSZ];
	int have_repository, ret;

	init_object_store(&repo, worktree);
	CALLOC_ARRAY(istate.cache, 1);
	istate.cache_alloc = istate.cache_nr = 1;
	attributes = add_index_path(&istate, 0, GITATTRIBUTES_FILE, 0);
	cl_must_pass(odb_pretend_object(
		repo.objects, source, strlen(source), OBJ_BLOB,
		&attributes->oid));

	have_repository = startup_info->have_repository;
	startup_info->have_repository = 1;
	ret = worktree_attr_manifest_build(
		&istate, &manifest, hash, &stats);
	startup_info->have_repository = have_repository;
	cl_assert_equal_i(ret, 0);
	cl_assert_equal_i(stats.candidates, 1);
	cl_assert_equal_i(stats.worktree_sources, 0);
	cl_assert_equal_i(stats.index_sources, 1);
	cl_assert_equal_i(attr_manifest_cursor_init(
		&cursor, manifest.buf, manifest.len, algo), 0);
	cl_assert_equal_i(attr_manifest_cursor_next(&cursor, &entry), 1);
	cl_assert_equal_i(entry.source, ATTR_MANIFEST_INDEX);
	cl_assert_equal_i(entry.path_len, strlen(GITATTRIBUTES_FILE));
	cl_assert(!memcmp(entry.path, GITATTRIBUTES_FILE, entry.path_len));
	cl_assert(!memcmp(entry.hash, attributes->oid.hash, algo->rawsz));
	cl_assert_equal_i(attr_manifest_cursor_next(&cursor, &entry), 0);

	strbuf_release(&manifest);
	release_index(&istate);
	odb_free(repo.objects);
	remove_worktree(worktree);
#endif
}

void test_attr_manifest__rejects_hardlinked_source_over_index(void)
{
#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	cl_skip();
#else
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	char *worktree = create_worktree();
	char indexed_source[] = "*.dat text\n";
	struct repository repo = { .worktree = worktree, .hash_algo = algo };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct worktree_attr_manifest_stats stats;
	struct cache_entry *attributes;
	struct strbuf source = STRBUF_INIT, alias = STRBUF_INIT;
	struct strbuf manifest = STRBUF_INIT;
	unsigned char hash[GIT_MAX_RAWSZ];
	int have_repository, ret;

	init_object_store(&repo, worktree);
	strbuf_addf(&source, "%s/a", worktree);
	cl_assert_equal_i(mkdir(source.buf, 0777), 0);
	strbuf_addstr(&source, "/" GITATTRIBUTES_FILE);
	write_file(source.buf, "*.dat -text\n");
	strbuf_addf(&alias, "%s/attributes-alias", worktree);
	cl_assert_equal_i(link(source.buf, alias.buf), 0);

	CALLOC_ARRAY(istate.cache, 2);
	istate.cache_alloc = istate.cache_nr = 2;
	attributes = add_index_path(
		&istate, 0, "a/" GITATTRIBUTES_FILE, 0);
	add_index_path(&istate, 1, "a/file", 0);
	cl_must_pass(odb_pretend_object(
		repo.objects, indexed_source, strlen(indexed_source), OBJ_BLOB,
		&attributes->oid));

	have_repository = startup_info->have_repository;
	startup_info->have_repository = 1;
	ret = worktree_attr_manifest_build(
		&istate, &manifest, hash, &stats);
	startup_info->have_repository = have_repository;
	cl_assert_equal_i(ret, -1);
	cl_assert_equal_i(manifest.len, 0);
	cl_assert_equal_i(stats.worktree_sources, 0);
	cl_assert_equal_i(stats.index_sources, 0);

	strbuf_release(&manifest);
	strbuf_release(&alias);
	strbuf_release(&source);
	release_index(&istate);
	odb_free(repo.objects);
	remove_worktree(worktree);
#endif
}

void test_attr_manifest__rejects_missing_index_source(void)
{
#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	cl_skip();
#else
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	char *worktree = create_worktree();
	struct repository repo = { .worktree = worktree, .hash_algo = algo };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct worktree_attr_manifest_stats stats;
	struct cache_entry *attributes;
	struct strbuf manifest = STRBUF_INIT;
	unsigned char hash[GIT_MAX_RAWSZ];
	unsigned char missing[GIT_MAX_RAWSZ];

	init_object_store(&repo, worktree);
	CALLOC_ARRAY(istate.cache, 1);
	istate.cache_alloc = istate.cache_nr = 1;
	attributes = add_index_path(&istate, 0, GITATTRIBUTES_FILE, 0);
	fill_hash(missing, 0x42, algo);
	oidread(&attributes->oid, missing, algo);
	strbuf_addstr(&manifest, "discard me");

	cl_assert_equal_i(worktree_attr_manifest_build(
		&istate, &manifest, hash, &stats), -1);
	cl_assert_equal_i(manifest.len, 0);

	strbuf_release(&manifest);
	release_index(&istate);
	odb_free(repo.objects);
	remove_worktree(worktree);
#endif
}

#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
struct many_sources_fixture {
	const struct git_hash_algo *algo;
	char *worktree;
	struct repository repo;
	struct index_state istate;
};

static void many_sources_fixture_init(struct many_sources_fixture *fixture)
{
	struct strbuf path = STRBUF_INIT;
	size_t i;

	memset(fixture, 0, sizeof(*fixture));
	fixture->algo = &hash_algos[GIT_HASH_SHA1];
	fixture->worktree = create_worktree();
	fixture->repo.worktree = fixture->worktree;
	fixture->repo.hash_algo = fixture->algo;
	index_state_init(&fixture->istate, &fixture->repo);
	CALLOC_ARRAY(fixture->istate.cache, ATTR_MANIFEST_TEST_SOURCE_NR);
	fixture->istate.cache_alloc = fixture->istate.cache_nr =
		ATTR_MANIFEST_TEST_SOURCE_NR;

	for (i = 0; i < ATTR_MANIFEST_TEST_SOURCE_NR; i++) {
		strbuf_reset(&path);
		strbuf_addf(&path, "%s/d%03" PRIuMAX,
			    fixture->worktree, (uintmax_t)i);
		cl_assert_equal_i(mkdir(path.buf, 0777), 0);
		strbuf_addstr(&path, "/" GITATTRIBUTES_FILE);
		write_file(path.buf, "source %" PRIuMAX "\n", (uintmax_t)i);
		strbuf_reset(&path);
		strbuf_addf(&path, "d%03" PRIuMAX "/file", (uintmax_t)i);
		add_index_path(&fixture->istate, i, path.buf, 0);
	}
	strbuf_release(&path);
}

static void many_sources_fixture_release(struct many_sources_fixture *fixture)
{
	release_index(&fixture->istate);
	remove_worktree(fixture->worktree);
}

static void clear_attr_manifest_thread_env(void *unused UNUSED)
{
	unsetenv(ATTR_MANIFEST_TEST_THREADS);
	unsetenv(ATTR_MANIFEST_TEST_THREAD_FAIL_AT);
}
#endif

void test_attr_manifest__parallel_probes_match_serial_output(void)
{
#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	cl_skip();
#else
	struct many_sources_fixture fixture;
	struct worktree_attr_manifest_stats serial_stats, parallel_stats;
	struct strbuf serial = STRBUF_INIT, parallel = STRBUF_INIT;
	unsigned char serial_hash[GIT_MAX_RAWSZ];
	unsigned char parallel_hash[GIT_MAX_RAWSZ];

	if (!HAVE_THREADS)
		return;
	cl_set_cleanup(clear_attr_manifest_thread_env, NULL);
	many_sources_fixture_init(&fixture);

	xsetenv(ATTR_MANIFEST_TEST_THREADS, "1", 1);
	cl_assert_equal_i(worktree_attr_manifest_build(
		&fixture.istate, &serial, serial_hash, &serial_stats), 0);
	cl_assert_equal_i(serial_stats.candidates,
			  ATTR_MANIFEST_TEST_SOURCE_NR + 1);
	cl_assert_equal_i(serial_stats.threads, 1);
	cl_assert_equal_i(serial_stats.worktree_sources,
			  ATTR_MANIFEST_TEST_SOURCE_NR);

	xsetenv(ATTR_MANIFEST_TEST_THREADS, "2", 1);
	cl_assert_equal_i(worktree_attr_manifest_build(
		&fixture.istate, &parallel, parallel_hash, &parallel_stats), 0);
	cl_assert_equal_i(parallel_stats.candidates,
			  ATTR_MANIFEST_TEST_SOURCE_NR + 1);
	cl_assert_equal_i(parallel_stats.threads, 2);
	cl_assert_equal_i(parallel_stats.thread_failures, 0);
	cl_assert_equal_i(parallel_stats.worktree_sources,
			  ATTR_MANIFEST_TEST_SOURCE_NR);
	cl_assert_equal_i(serial.len, parallel.len);
	cl_assert(!memcmp(serial.buf, parallel.buf, serial.len));
	cl_assert(!memcmp(serial_hash, parallel_hash, fixture.algo->rawsz));

	strbuf_release(&parallel);
	strbuf_release(&serial);
	many_sources_fixture_release(&fixture);
	clear_attr_manifest_thread_env(NULL);
#endif
}

void test_attr_manifest__thread_failure_completes_remaining_ranges(void)
{
#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	cl_skip();
#else
	struct many_sources_fixture fixture;
	struct worktree_attr_manifest_stats serial_stats, fallback_stats;
	struct strbuf serial = STRBUF_INIT, fallback = STRBUF_INIT;
	unsigned char serial_hash[GIT_MAX_RAWSZ];
	unsigned char fallback_hash[GIT_MAX_RAWSZ];

	if (!HAVE_THREADS)
		return;
	cl_set_cleanup(clear_attr_manifest_thread_env, NULL);
	many_sources_fixture_init(&fixture);

	xsetenv(ATTR_MANIFEST_TEST_THREADS, "1", 1);
	cl_assert_equal_i(worktree_attr_manifest_build(
		&fixture.istate, &serial, serial_hash, &serial_stats), 0);
	xsetenv(ATTR_MANIFEST_TEST_THREADS, "2", 1);
	xsetenv(ATTR_MANIFEST_TEST_THREAD_FAIL_AT, "1", 1);
	cl_assert_equal_i(worktree_attr_manifest_build(
		&fixture.istate, &fallback, fallback_hash, &fallback_stats), 0);
	cl_assert_equal_i(fallback_stats.candidates,
			  ATTR_MANIFEST_TEST_SOURCE_NR + 1);
	cl_assert_equal_i(fallback_stats.threads, 2);
	cl_assert_equal_i(fallback_stats.thread_failures, 1);
	cl_assert_equal_i(fallback_stats.worktree_sources,
			  ATTR_MANIFEST_TEST_SOURCE_NR);
	cl_assert_equal_i(serial.len, fallback.len);
	cl_assert(!memcmp(serial.buf, fallback.buf, serial.len));
	cl_assert(!memcmp(serial_hash, fallback_hash, fixture.algo->rawsz));

	strbuf_release(&fallback);
	strbuf_release(&serial);
	many_sources_fixture_release(&fixture);
	clear_attr_manifest_thread_env(NULL);
#endif
}

void test_attr_manifest__builder_rejects_structural_indexes(void)
{
#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	cl_skip();
#else
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	char *worktree = create_worktree();
	struct repository repo = { .worktree = worktree, .hash_algo = algo };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct worktree_attr_manifest_stats stats;
	struct strbuf manifest = STRBUF_INIT;
	unsigned char hash[GIT_MAX_RAWSZ];

	CALLOC_ARRAY(istate.cache, 1);
	istate.cache_alloc = istate.cache_nr = 1;
	add_index_path(&istate, 0, "file", 1);
	cl_assert_equal_i(worktree_attr_manifest_build(
		&istate, &manifest, hash, &stats), -1);
	cl_assert_equal_i(manifest.len, 0);
	istate.cache[0]->ce_flags = create_ce_flags(0);
	istate.sparse_index = INDEX_COLLAPSED;
	cl_assert_equal_i(worktree_attr_manifest_build(
		&istate, &manifest, hash, &stats), -1);
	cl_assert_equal_i(manifest.len, 0);

	strbuf_release(&manifest);
	release_index(&istate);
	remove_worktree(worktree);
#endif
}
