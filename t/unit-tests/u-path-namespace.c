#include "unit-test.h"

#include "dir.h"
#include "hash.h"
#include "path-namespace.h"
#include "strbuf.h"
#include "tempfile.h"
#include "wrapper.h"

#define ASSERT_STAT_FIELD_MATTERS(base, changed, field) do { \
	(changed) = (base); \
	(changed).field = !(base).field; \
	cl_assert(!path_namespace_stat_equal(&(base), &(changed))); \
} while (0)

void test_path_namespace__stat_identity(void)
{
	struct stat st = { 0 };
	struct path_stat_identity first, second;
	size_t i;

	st.st_dev = 1;
	st.st_ino = 2;
	st.st_mode = S_IFREG | 0644;
	st.st_nlink = 3;
	st.st_uid = 4;
	st.st_gid = 5;
	st.st_size = 6;
	st.st_mtime = 7;
	st.st_ctime = 8;

	path_stat_identity_init(&first, &st);
	path_stat_identity_init(&second, &st);
	cl_assert(path_stat_identity_equal(&first, &second));
	cl_assert(path_namespace_stat_equal(&st, &st));

	for (i = 0; i < PATH_STAT_IDENTITY_FIELDS; i++) {
		second = first;
		second.fields[i]++;
		cl_assert(!path_stat_identity_equal(&first, &second));
	}
}

void test_path_namespace__stat_fields(void)
{
	struct stat st, changed;

	cl_must_pass(stat(".", &st));
	changed = st;
	cl_assert(path_namespace_stat_equal(&st, &changed));
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_dev);
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_ino);
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_mode);
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_nlink);
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_uid);
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_gid);
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_size);
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_mtime);
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_ctime);
#ifndef NO_NSEC
#ifdef USE_ST_TIMESPEC
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_mtimespec.tv_nsec);
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_ctimespec.tv_nsec);
#else
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_mtim.tv_nsec);
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_ctim.tv_nsec);
#endif
#endif
#ifdef __APPLE__
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_birthtimespec.tv_sec);
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_birthtimespec.tv_nsec);
	ASSERT_STAT_FIELD_MATTERS(st, changed, st_gen);
#endif
}

void test_path_namespace__directory_identity_ignores_unrelated_entries(void)
{
	struct stat original, changed;

	cl_must_pass(stat(".", &original));
	cl_assert(S_ISDIR(original.st_mode));
	cl_assert(path_namespace_directory_stat_equal(&original, &original));

	changed = original;
	changed.st_nlink++;
	changed.st_size++;
	changed.st_mtime++;
	changed.st_ctime++;
	cl_assert(!path_namespace_stat_equal(&original, &changed));
	cl_assert(path_namespace_directory_stat_equal(&original, &changed));

	changed = original;
	changed.st_dev++;
	cl_assert(!path_namespace_directory_stat_equal(&original, &changed));
	changed = original;
	changed.st_ino++;
	cl_assert(!path_namespace_directory_stat_equal(&original, &changed));
	changed = original;
	changed.st_mode ^= S_IXGRP;
	cl_assert(!path_namespace_directory_stat_equal(&original, &changed));
	changed = original;
	changed.st_uid++;
	cl_assert(!path_namespace_directory_stat_equal(&original, &changed));
	changed = original;
	changed.st_gid++;
	cl_assert(!path_namespace_directory_stat_equal(&original, &changed));
#ifdef __APPLE__
	changed = original;
	changed.st_birthtimespec.tv_sec++;
	cl_assert(!path_namespace_directory_stat_equal(&original, &changed));
	changed = original;
	changed.st_gen++;
	cl_assert(!path_namespace_directory_stat_equal(&original, &changed));
#endif

	changed = original;
	changed.st_mode = S_IFREG | 0600;
	cl_assert(!path_namespace_directory_stat_equal(&original, &changed));
	cl_assert(!path_namespace_directory_stat_equal(&changed, &changed));
}

static int source_fd = -1;

static int reopen_source(int dirfd UNUSED, const char *path, int flags UNUSED)
{
	if (strcmp(path, "source")) {
		errno = ENOENT;
		return -1;
	}
	return dup(source_fd);
}

void test_path_namespace__reopen_component(void)
{
	struct tempfile *first = mks_tempfile_t("path-namespace-one-XXXXXX");
	struct tempfile *second = mks_tempfile_t("path-namespace-two-XXXXXX");
	struct stat expected;

	cl_assert(first != NULL);
	cl_assert(second != NULL);
	cl_must_pass(fstat(get_tempfile_fd(first), &expected));

	source_fd = get_tempfile_fd(first);
	if (!fstat_is_reliable()) {
		cl_assert(path_namespace_reopen_component(
				  -1, "source", O_RDONLY,
				  reopen_source, &expected) < 0);
		cl_assert_equal_i(errno, EAGAIN);
		goto invalid_component;
	}
	cl_must_pass(path_namespace_reopen_component(
		-1, "source", O_RDONLY, reopen_source, &expected));

	source_fd = get_tempfile_fd(second);
	cl_assert(path_namespace_reopen_component(
			  -1, "source", O_RDONLY, reopen_source, &expected) < 0);
	cl_assert_equal_i(errno, EAGAIN);

invalid_component:
	cl_assert(path_namespace_reopen_component(
			  -1, "../source", O_RDONLY, reopen_source, &expected) < 0);
	cl_assert_equal_i(errno, EINVAL);

	source_fd = -1;
	cl_must_pass(delete_tempfile(&first));
	cl_must_pass(delete_tempfile(&second));
}

static char *create_namespace(void)
{
	const char *tmp = getenv("TMPDIR");
	char *path = xstrfmt("%s/path-namespace.XXXXXX", tmp ? tmp : "/tmp");

	cl_assert(mkdtemp(path) != NULL);
	return path;
}

static void remove_namespace(char *path)
{
	struct strbuf root = STRBUF_INIT;

	strbuf_addstr(&root, path);
	cl_must_pass(remove_dir_recursively(&root, 0));
	strbuf_release(&root);
	free(path);
}

static void hash_namespace(const struct path_namespace_snapshot *snapshot,
			   unsigned char *hash)
{
	struct git_hash_ctx ctx;

	git_hash_init(&ctx, &hash_algos[GIT_HASH_SHA1]);
	path_namespace_hash(&ctx, snapshot);
	git_hash_final(hash, &ctx);
	git_hash_discard(&ctx);
}

void test_path_namespace__equal_snapshots_have_equal_hashes(void)
{
	struct path_namespace_snapshot *first = NULL, *second = NULL;
	struct strbuf directory = STRBUF_INIT, target = STRBUF_INIT;
	unsigned char first_hash[GIT_MAX_RAWSZ], second_hash[GIT_MAX_RAWSZ];
	char *root;

	if (!fstat_is_reliable())
		cl_skip();
	root = create_namespace();

	strbuf_addf(&directory, "%s/a", root);
	cl_must_pass(mkdir(directory.buf, 0777));
	strbuf_addf(&target, "%s/target", directory.buf);
	write_file(target.buf, "contents\n");

	cl_must_pass(path_namespace_capture(target.buf, &first));
	cl_must_pass(path_namespace_capture(target.buf, &second));
	cl_assert(path_namespace_target_present(first));
	cl_assert(path_namespace_target_present(second));
	cl_assert(path_namespace_equal(first, second));
	hash_namespace(first, first_hash);
	hash_namespace(second, second_hash);
	cl_assert(!memcmp(first_hash, second_hash,
			  hash_algos[GIT_HASH_SHA1].rawsz));

	path_namespace_clear(second);
	path_namespace_clear(first);
	strbuf_release(&target);
	strbuf_release(&directory);
	remove_namespace(root);
}

void test_path_namespace__captures_missing_and_replaced_components(void)
{
	struct path_namespace_snapshot *missing = NULL, *created = NULL;
	struct path_namespace_snapshot *replaced = NULL;
	struct strbuf directory = STRBUF_INIT, old_directory = STRBUF_INIT;
	struct strbuf target = STRBUF_INIT;
	unsigned char missing_hash[GIT_MAX_RAWSZ], created_hash[GIT_MAX_RAWSZ];
	unsigned char replaced_hash[GIT_MAX_RAWSZ];
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	char *root;

	if (!fstat_is_reliable()) {
		cl_assert(path_namespace_capture(".", &missing) < 0);
		cl_assert_equal_i(errno, EAGAIN);
		return;
	}
	root = create_namespace();

	strbuf_addf(&directory, "%s/a", root);
	strbuf_addf(&old_directory, "%s/a-old", root);
	cl_must_pass(mkdir(directory.buf, 0777));
	strbuf_addf(&target, "%s/target", directory.buf);

	cl_must_pass(path_namespace_capture(target.buf, &missing));
	cl_assert(!path_namespace_target_present(missing));
	hash_namespace(missing, missing_hash);

	write_file(target.buf, "contents\n");
	cl_must_pass(path_namespace_capture(target.buf, &created));
	cl_assert(path_namespace_target_present(created));
	cl_assert(!path_namespace_equal(missing, created));
	hash_namespace(created, created_hash);
	cl_assert(memcmp(missing_hash, created_hash, algo->rawsz));

	cl_must_pass(rename(directory.buf, old_directory.buf));
	cl_must_pass(mkdir(directory.buf, 0777));
	write_file(target.buf, "contents\n");
	cl_must_pass(path_namespace_capture(target.buf, &replaced));
	cl_assert(path_namespace_target_present(replaced));
	cl_assert(!path_namespace_equal(created, replaced));
	hash_namespace(replaced, replaced_hash);
	cl_assert(memcmp(created_hash, replaced_hash, algo->rawsz));

	path_namespace_clear(replaced);
	path_namespace_clear(created);
	path_namespace_clear(missing);
	strbuf_release(&target);
	strbuf_release(&old_directory);
	strbuf_release(&directory);
	remove_namespace(root);
}

void test_path_namespace__unrelated_ancestor_entries_leave_target_unchanged(void)
{
	struct path_namespace_snapshot *first = NULL, *second = NULL;
	struct path_namespace_snapshot *modified = NULL, *permissions = NULL;
	struct strbuf directory = STRBUF_INIT, target = STRBUF_INIT;
	struct strbuf unrelated = STRBUF_INIT;
	unsigned char first_hash[GIT_MAX_RAWSZ], second_hash[GIT_MAX_RAWSZ];
	unsigned char modified_hash[GIT_MAX_RAWSZ];
	struct stat st;
	char *root;

	if (!fstat_is_reliable())
		cl_skip();
	root = create_namespace();

	strbuf_addf(&directory, "%s/a", root);
	cl_must_pass(mkdir(directory.buf, 0777));
	strbuf_addf(&target, "%s/target", directory.buf);
	write_file(target.buf, "contents\n");
	cl_must_pass(path_namespace_capture(target.buf, &first));
	hash_namespace(first, first_hash);

	strbuf_addf(&unrelated, "%s/unrelated", root);
	write_file(unrelated.buf, "unrelated\n");
	cl_must_pass(path_namespace_capture(target.buf, &second));
	hash_namespace(second, second_hash);
	cl_assert(path_namespace_equal(first, second));
	cl_assert(!memcmp(first_hash, second_hash,
			  hash_algos[GIT_HASH_SHA1].rawsz));

	write_file(target.buf, "changed contents\n");
	cl_must_pass(path_namespace_capture(target.buf, &modified));
	hash_namespace(modified, modified_hash);
	cl_assert(!path_namespace_equal(second, modified));
	cl_assert(memcmp(second_hash, modified_hash,
			 hash_algos[GIT_HASH_SHA1].rawsz));

	cl_must_pass(stat(directory.buf, &st));
	cl_must_pass(chmod(directory.buf, st.st_mode ^ S_IXGRP));
	cl_must_pass(path_namespace_capture(target.buf, &permissions));
	cl_assert(!path_namespace_equal(modified, permissions));

	path_namespace_clear(permissions);
	path_namespace_clear(modified);
	path_namespace_clear(second);
	path_namespace_clear(first);
	strbuf_release(&unrelated);
	strbuf_release(&target);
	strbuf_release(&directory);
	remove_namespace(root);
}
