#include "unit-test.h"

#include "dir.h"
#include "hash.h"
#include "repository.h"
#include "semantic-verify-internal.h"
#include "strbuf.h"
#include "worktree-attr-source.h"
#include "wrapper.h"

#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
struct worktree_attr_source_fixture {
	char *worktree;
	struct repository repo;
	struct semantic_verify_root *root;
	struct semantic_verify_path *path;
};

static void source_fixture_init(struct worktree_attr_source_fixture *fixture)
{
	const char *tmp = getenv("TMPDIR");

	memset(fixture, 0, sizeof(*fixture));
	fixture->worktree = xstrfmt(
		"%s/worktree-attr-source.XXXXXX", tmp ? tmp : "/tmp");
	cl_assert(mkdtemp(fixture->worktree) != NULL);
	fixture->repo.worktree = fixture->worktree;
	fixture->repo.hash_algo = &hash_algos[GIT_HASH_SHA1];
	cl_must_pass(semantic_verify_root_init(
		&fixture->repo, &fixture->root));
	fixture->path = semantic_verify_path_new(fixture->root);
	cl_assert(fixture->path != NULL);
}

static void source_fixture_release(
	struct worktree_attr_source_fixture *fixture,
	unsigned int *namespace_unstable,
	size_t *namespace_unstable_from)
{
	struct strbuf worktree = STRBUF_INIT;

	semantic_verify_path_free(
		fixture->path, namespace_unstable, namespace_unstable_from);
	semantic_verify_root_clear(fixture->root);
	strbuf_addstr(&worktree, fixture->worktree);
	cl_must_pass(remove_dir_recursively(&worktree, 0));
	strbuf_release(&worktree);
	free(fixture->worktree);
}

static void make_directory(struct worktree_attr_source_fixture *fixture,
			   const char *name)
{
	struct strbuf path = STRBUF_INIT;

	strbuf_addf(&path, "%s/%s", fixture->worktree, name);
	cl_must_pass(mkdir(path.buf, 0777));
	strbuf_release(&path);
}
#endif

void test_worktree_attr_source__hashes_large_regular_file(void)
{
#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	cl_skip();
#else
	struct worktree_attr_source_fixture fixture;
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct git_hash_ctx ctx;
	struct strbuf contents = STRBUF_INIT;
	struct strbuf source = STRBUF_INIT;
	unsigned char actual[GIT_MAX_RAWSZ], expected[GIT_MAX_RAWSZ];
	unsigned int namespace_unstable;
	int found;

	source_fixture_init(&fixture);
	make_directory(&fixture, "a");
	strbuf_addchars(&contents, 'x', 64 * 1024 + 17);
	strbuf_addf(&source, "%s/a/.gitattributes", fixture.worktree);
	write_file_buf(source.buf, contents.buf, contents.len);
	git_hash_init(&ctx, algo);
	git_hash_update(&ctx, contents.buf, contents.len);
	git_hash_final(expected, &ctx);
	git_hash_discard(&ctx);

	cl_must_pass(worktree_attr_source_read(
		fixture.path, "a/.gitattributes", 7, algo, actual, &found));
	cl_assert_equal_i(found, 1);
	cl_assert(!memcmp(actual, expected, algo->rawsz));

	source_fixture_release(&fixture, &namespace_unstable, NULL);
	cl_assert_equal_i(namespace_unstable, 0);
	strbuf_release(&source);
	strbuf_release(&contents);
#endif
}

void test_worktree_attr_source__reports_missing_and_non_regular_files(void)
{
#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	cl_skip();
#else
	struct worktree_attr_source_fixture fixture;
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	unsigned char hash[GIT_MAX_RAWSZ];
	unsigned int namespace_unstable;
	int found;

	source_fixture_init(&fixture);
	cl_must_pass(worktree_attr_source_read(
		fixture.path, ".gitattributes", 0, algo, hash, &found));
	cl_assert_equal_i(found, 0);
	cl_must_pass(worktree_attr_source_read(
		fixture.path, "missing/.gitattributes", 1,
		algo, hash, &found));
	cl_assert_equal_i(found, 0);

	make_directory(&fixture, "attributes-directory");
	cl_must_pass(worktree_attr_source_read(
		fixture.path, "attributes-directory", 2, algo, hash, &found));
	cl_assert_equal_i(found, 0);

	source_fixture_release(&fixture, &namespace_unstable, NULL);
	cl_assert_equal_i(namespace_unstable, 0);
#endif
}

void test_worktree_attr_source__rejects_hardlinked_file(void)
{
#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	cl_skip();
#else
	struct worktree_attr_source_fixture fixture;
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct strbuf alias = STRBUF_INIT, source = STRBUF_INIT;
	unsigned char hash[GIT_MAX_RAWSZ];
	unsigned int namespace_unstable;
	int found;

	source_fixture_init(&fixture);
	make_directory(&fixture, "a");
	strbuf_addf(&source, "%s/a/.gitattributes", fixture.worktree);
	strbuf_addf(&alias, "%s/attributes-alias", fixture.worktree);
	write_file(source.buf, "*.dat text\n");
	cl_must_pass(link(source.buf, alias.buf));

	cl_assert_equal_i(worktree_attr_source_read(
		fixture.path, "a/.gitattributes", 3, algo, hash, &found), -1);
	cl_assert_equal_i(found, 0);

	source_fixture_release(&fixture, &namespace_unstable, NULL);
	cl_assert_equal_i(namespace_unstable, 0);
	strbuf_release(&source);
	strbuf_release(&alias);
#endif
}

void test_worktree_attr_source__detects_replaced_cached_parent(void)
{
#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	cl_skip();
#else
	struct worktree_attr_source_fixture fixture;
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct strbuf old_parent = STRBUF_INIT, parent = STRBUF_INIT;
	struct strbuf source = STRBUF_INIT;
	unsigned char hash[GIT_MAX_RAWSZ];
	size_t namespace_unstable_from;
	unsigned int namespace_unstable;
	int found;

	source_fixture_init(&fixture);
	make_directory(&fixture, "a");
	strbuf_addf(&parent, "%s/a", fixture.worktree);
	strbuf_addf(&old_parent, "%s/a-old", fixture.worktree);
	strbuf_addf(&source, "%s/.gitattributes", parent.buf);
	write_file(source.buf, "*.dat text\n");
	cl_must_pass(worktree_attr_source_read(
		fixture.path, "a/.gitattributes", 17, algo, hash, &found));
	cl_assert_equal_i(found, 1);

	cl_must_pass(rename(parent.buf, old_parent.buf));
	cl_must_pass(mkdir(parent.buf, 0777));
	source_fixture_release(
		&fixture, &namespace_unstable, &namespace_unstable_from);
	cl_assert_equal_i(namespace_unstable, 1);
	cl_assert_equal_i(namespace_unstable_from, 17);

	strbuf_release(&source);
	strbuf_release(&old_parent);
	strbuf_release(&parent);
#endif
}
