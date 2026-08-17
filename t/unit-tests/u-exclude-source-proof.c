#include "unit-test.h"

#include "dir.h"
#include "exclude-source-proof.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "wrapper.h"

#if EXCLUDE_SOURCE_PROOF_HAS_ANCHORED_OPEN

static struct repository repo = {
	.hash_algo = &hash_algos[GIT_HASH_SHA1],
};
static struct index_state istate = {
	.repo = &repo,
};
static char *trash;
static int fail_open_parent;
static void (*mutate_before_open_parent)(const char *parent);
static unsigned int mutate_before_open_parent_after;

static int open_parent(void *data UNUSED, const char *path)
{
	if (fail_open_parent) {
		errno = EACCES;
		return -1;
	}
	if (mutate_before_open_parent &&
	    !--mutate_before_open_parent_after) {
		void (*mutate)(const char *) = mutate_before_open_parent;

		mutate_before_open_parent = NULL;
		mutate(path);
	}
	return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
}

static struct exclude_source_proof *new_proof(void)
{
	return exclude_source_proof_create(
		&istate, NULL, open_parent, 0);
}

static char *make_path(const char *name)
{
	struct strbuf path = STRBUF_INIT;

	strbuf_addf(&path, "%s/%s", trash, name);
	return strbuf_detach(&path, NULL);
}

static void create_sibling_entries(const char *parent)
{
	char *file = xstrfmt("%s/sibling", parent);
	char *directory = xstrfmt("%s/sibling-directory", parent);

	write_file_buf(file, "noise", 5);
	cl_must_pass(mkdir(directory, 0700));
	free(directory);
	free(file);
}

static void replace_parent_with_same_source(const char *parent)
{
	char *previous = xstrfmt("%s-old", parent);
	char *source = xstrfmt("%s/source", parent);

	cl_must_pass(rename(parent, previous));
	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	free(source);
	free(previous);
}

static void replace_parent_with_symlink(const char *parent)
{
	char *previous = xstrfmt("%s-old", parent);

	cl_must_pass(rename(parent, previous));
	cl_must_pass(symlink(previous, parent));
	free(previous);
}

static void create_and_remove_absent_source(const char *parent)
{
	char *source = xstrfmt("%s/missing", parent);
	char *directory = xstrfmt("%s/sibling-directory", parent);

	write_file_buf(source, "briefly present", 15);
	cl_must_pass(unlink(source));
	cl_must_pass(mkdir(directory, 0700));
	free(directory);
	free(source);
}

static void replace_source_during_parent_churn(const char *parent)
{
	char *source = xstrfmt("%s/source", parent);
	char *replacement = xstrfmt("%s/replacement", parent);

	write_file_buf(replacement, "changed", 7);
	cl_must_pass(rename(replacement, source));
	create_sibling_entries(parent);
	free(replacement);
	free(source);
}

static void record_file(struct exclude_source_proof *proof, const char *path)
{
	struct exclude_source_capture *capture =
		exclude_source_capture_begin(proof, path, 0);
	struct stat before, after;
	char *buf;
	size_t size;
	ssize_t read_size;
	int fd;

	cl_assert(capture != NULL);
	fd = exclude_source_capture_open(capture);
	cl_must_pass(fd);
	cl_must_pass(fstat(fd, &before));
	cl_assert(before.st_size >= 0);
	size = xsize_t(before.st_size);
	buf = xmalloc(size ? size : 1);
	read_size = read_in_full(fd, buf, size);
	cl_assert(read_size >= 0 && (size_t)read_size == size);
	cl_must_pass(fstat(fd, &after));
	exclude_source_capture_record(capture, fd, &after, buf, size);
	exclude_source_capture_release(capture);
	free(buf);
	cl_must_pass(close(fd));
}

static void record_absence(struct exclude_source_proof *proof,
			   const char *path)
{
	struct exclude_source_capture *capture =
		exclude_source_capture_begin(proof, path, 0);

	cl_assert(capture != NULL);
	cl_assert(exclude_source_capture_absent(capture));
	exclude_source_capture_record(capture, -1, NULL, NULL, 0);
	exclude_source_capture_release(capture);
}

void test_exclude_source_proof__initialize(void)
{
	char template[] = "/tmp/exclude-source-proof-XXXXXX";

	fail_open_parent = 0;
	mutate_before_open_parent = NULL;
	mutate_before_open_parent_after = 0;
	cl_assert(mkdtemp(template) != NULL);
	trash = xstrdup(template);
}

void test_exclude_source_proof__cleanup(void)
{
	struct strbuf path = STRBUF_INIT;

	strbuf_addstr(&path, trash);
	cl_must_pass(remove_dir_recursively(
		&path, REMOVE_DIR_PURGE_ORIGINAL_CWD));
	strbuf_release(&path);
	FREE_AND_NULL(trash);
}

void test_exclude_source_proof__accepts_same_content_replacement(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	record_file(proof, source);
	cl_assert(exclude_source_proof_validate(proof));
	cl_must_pass(unlink(source));
	write_file_buf(source, "content", 7);
	cl_assert(exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__accepts_sibling_churn_during_regular_capture(void)
{
	struct exclude_source_proof *proof = new_proof();
	struct exclude_source_capture *capture;
	struct stat source_stat;
	char *parent = make_path("parent");
	char *source = make_path("parent/source");
	int fd;

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	capture = exclude_source_capture_begin(proof, source, 0);
	cl_assert(capture != NULL);
	fd = exclude_source_capture_open(capture);
	cl_must_pass(fd);
	cl_must_pass(fstat(fd, &source_stat));
	create_sibling_entries(parent);
	exclude_source_capture_record(capture, fd, &source_stat, "content", 7);
	exclude_source_capture_release(capture);
	cl_must_pass(close(fd));
	cl_assert(exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__accepts_sibling_churn_during_regular_validation(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	record_file(proof, source);
	mutate_before_open_parent = create_sibling_entries;
	mutate_before_open_parent_after = 2;
	cl_assert(exclude_source_proof_validate(proof));
	cl_assert(mutate_before_open_parent == NULL);

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_parent_replacement_during_regular_capture(void)
{
	struct exclude_source_proof *proof = new_proof();
	struct exclude_source_capture *capture;
	struct stat source_stat;
	char *parent = make_path("parent");
	char *source = make_path("parent/source");
	int fd;

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	capture = exclude_source_capture_begin(proof, source, 0);
	cl_assert(capture != NULL);
	fd = exclude_source_capture_open(capture);
	cl_must_pass(fd);
	cl_must_pass(fstat(fd, &source_stat));
	replace_parent_with_same_source(parent);
	exclude_source_capture_record(capture, fd, &source_stat, "content", 7);
	exclude_source_capture_release(capture);
	cl_must_pass(close(fd));
	cl_assert(!exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_parent_replacement_during_regular_validation(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	record_file(proof, source);
	mutate_before_open_parent = replace_parent_with_same_source;
	mutate_before_open_parent_after = 2;
	cl_assert(!exclude_source_proof_validate(proof));
	cl_assert(mutate_before_open_parent == NULL);

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_symlinked_parent_during_regular_validation(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	record_file(proof, source);
	mutate_before_open_parent = replace_parent_with_symlink;
	mutate_before_open_parent_after = 2;
	cl_assert(!exclude_source_proof_validate(proof));
	cl_assert(mutate_before_open_parent == NULL);

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_target_replacement_during_parent_churn(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	record_file(proof, source);
	mutate_before_open_parent = replace_source_during_parent_churn;
	mutate_before_open_parent_after = 2;
	cl_assert(!exclude_source_proof_validate(proof));
	cl_assert(mutate_before_open_parent == NULL);

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_sibling_churn_during_absent_capture(void)
{
	struct exclude_source_proof *proof = new_proof();
	struct exclude_source_capture *capture;
	char *parent = make_path("parent");
	char *source = make_path("parent/missing");

	cl_must_pass(mkdir(parent, 0700));
	capture = exclude_source_capture_begin(proof, source, 0);
	cl_assert(capture != NULL);
	cl_assert(exclude_source_capture_absent(capture));
	create_sibling_entries(parent);
	exclude_source_capture_record(capture, -1, NULL, NULL, 0);
	exclude_source_capture_release(capture);
	cl_assert(!exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_sibling_churn_during_fifo_capture(void)
{
	struct exclude_source_proof *proof =
		exclude_source_proof_create(&istate, NULL, open_parent,
					    EXCLUDE_SOURCE_PROOF_NONBLOCKING);
	struct exclude_source_capture *capture;
	struct stat source_stat;
	char *parent = make_path("parent");
	char *source = make_path("parent/source");
	int fd;

	cl_must_pass(mkdir(parent, 0700));
	cl_must_pass(mkfifo(source, 0600));
	capture = exclude_source_capture_begin(proof, source, 0);
	cl_assert(capture != NULL);
	fd = exclude_source_capture_open(capture);
	cl_must_pass(fd);
	cl_must_pass(fstat(fd, &source_stat));
	cl_assert(S_ISFIFO(source_stat.st_mode));
	create_sibling_entries(parent);
	exclude_source_capture_record(capture, fd, &source_stat, NULL, 0);
	exclude_source_capture_release(capture);
	cl_must_pass(close(fd));
	cl_assert(!exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_transient_absent_source_during_validation(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *source = make_path("parent/missing");

	cl_must_pass(mkdir(parent, 0700));
	record_absence(proof, source);
	mutate_before_open_parent = create_and_remove_absent_source;
	mutate_before_open_parent_after = 2;
	cl_assert(!exclude_source_proof_validate(proof));
	cl_assert(mutate_before_open_parent == NULL);

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_parent_permission_change_during_capture(void)
{
	struct exclude_source_proof *proof = new_proof();
	struct exclude_source_capture *capture;
	struct stat source_stat;
	char *parent = make_path("parent");
	char *source = make_path("parent/source");
	int fd;

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	capture = exclude_source_capture_begin(proof, source, 0);
	cl_assert(capture != NULL);
	fd = exclude_source_capture_open(capture);
	cl_must_pass(fd);
	cl_must_pass(fstat(fd, &source_stat));
	cl_must_pass(chmod(parent, 0500));
	exclude_source_capture_record(capture, fd, &source_stat, "content", 7);
	exclude_source_capture_release(capture);
	cl_must_pass(close(fd));
	cl_must_pass(chmod(parent, 0700));
	cl_assert(!exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_different_content_replacement(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	record_file(proof, source);
	cl_assert(exclude_source_proof_validate(proof));
	cl_must_pass(unlink(source));
	cl_assert(!exclude_source_proof_validate(proof));
	write_file_buf(source, "changed", 7);
	cl_assert(!exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__accepts_repeated_observation(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	record_file(proof, source);
	record_file(proof, source);
	cl_assert(exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_missing_source_buffer(void)
{
	struct exclude_source_proof *proof = new_proof();
	struct exclude_source_capture *capture;
	struct stat st;
	char *parent = make_path("parent");
	char *source = make_path("parent/source");
	int fd;

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	capture = exclude_source_capture_begin(proof, source, 0);
	cl_assert(capture != NULL);
	fd = exclude_source_capture_open(capture);
	cl_must_pass(fd);
	cl_must_pass(fstat(fd, &st));
	exclude_source_capture_record(capture, fd, &st, NULL, 7);
	cl_assert(!exclude_source_proof_validate(proof));

	cl_must_pass(close(fd));
	exclude_source_capture_release(capture);
	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_conflicting_observations(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	record_file(proof, source);
	write_file_buf(source, "changed", 7);
	record_file(proof, source);
	cl_assert(!exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__digest_deduplicates_and_ignores_identity(void)
{
	struct exclude_source_proof *first_proof =
		exclude_source_proof_create(&istate, NULL, open_parent, 0);
	struct exclude_source_proof *second_proof;
	struct object_id first, second;
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	record_file(first_proof, source);
	cl_must_pass(exclude_source_proof_digest(
		first_proof, repo.hash_algo, &first));

	cl_must_pass(unlink(source));
	write_file_buf(source, "content", 7);
	second_proof =
		exclude_source_proof_create(&istate, NULL, open_parent, 0);
	record_file(second_proof, source);
	record_file(second_proof, source);
	cl_must_pass(exclude_source_proof_digest(
		second_proof, repo.hash_algo, &second));
	cl_assert(oideq(&first, &second));

	exclude_source_proof_release(second_proof);
	exclude_source_proof_release(first_proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_open_failure(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	record_file(proof, source);
	fail_open_parent = 1;
	cl_assert(!exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__fails_closed_without_parent_opener(void)
{
	struct exclude_source_proof *proof =
		exclude_source_proof_create(&istate, NULL, NULL, 0);

	cl_assert(!exclude_source_capture_begin(proof, "/dev/null", 0));
	cl_assert(!exclude_source_proof_validate(proof));
	exclude_source_proof_release(proof);
}

void test_exclude_source_proof__honors_nofollow(void)
{
	struct exclude_source_proof *proof = new_proof();
	struct exclude_source_capture *capture;
	char *parent = make_path("parent");
	char *source = make_path("parent/source");
	char *target = make_path("parent/target");
	char *replacement = make_path("parent/replacement");
	int fd;

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(target, "content", 7);
	cl_must_pass(symlink("target", source));

	capture = exclude_source_capture_begin(proof, source, 0);
	cl_assert(capture != NULL);
	fd = exclude_source_capture_open(capture);
	cl_must_pass(fd);
	cl_must_pass(close(fd));
	exclude_source_capture_release(capture);
	record_file(proof, source);
	cl_assert(exclude_source_proof_validate(proof));
	write_file_buf(replacement, "content", 7);
	cl_must_pass(unlink(source));
	cl_must_pass(symlink("replacement", source));
	cl_assert(exclude_source_proof_validate(proof));

	capture = exclude_source_capture_begin(proof, source, 1);
	cl_assert(capture != NULL);
	fd = exclude_source_capture_open(capture);
	cl_assert(fd < 0 && errno == ELOOP);
	exclude_source_capture_release(capture);
	write_file_buf(replacement, "changed", 7);
	cl_assert(!exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(replacement);
	free(target);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_nofollow_symlink_replacement(void)
{
	struct exclude_source_proof *proof = new_proof();
	struct exclude_source_capture *capture;
	char *parent = make_path("parent");
	char *source = make_path("parent/source");
	char *target = make_path("parent/target");
	struct stat st;
	int fd;

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	write_file_buf(target, "content", 7);
	capture = exclude_source_capture_begin(proof, source, 1);
	cl_assert(capture != NULL);
	fd = exclude_source_capture_open(capture);
	cl_must_pass(fd);
	cl_must_pass(fstat(fd, &st));
	exclude_source_capture_record(capture, fd, &st, "content", 7);
	exclude_source_capture_release(capture);
	cl_must_pass(close(fd));
	cl_assert(exclude_source_proof_validate(proof));

	cl_must_pass(unlink(source));
	cl_must_pass(symlink("target", source));
	cl_assert(!exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(target);
	free(source);
	free(parent);
}

void test_exclude_source_proof__opens_directory_sources(void)
{
	struct exclude_source_proof *proof = new_proof();
	struct exclude_source_capture *capture;
	struct stat st;
	char *parent = make_path("parent");
	char *source = make_path("parent/source/");
	int fd;

	cl_must_pass(mkdir(parent, 0700));
	cl_must_pass(mkdir(source, 0700));
	capture = exclude_source_capture_begin(proof, source, 0);
	cl_assert(capture != NULL);
	fd = exclude_source_capture_open(capture);
	cl_must_pass(fd);
	cl_must_pass(fstat(fd, &st));
	cl_assert(S_ISDIR(st.st_mode));
	cl_must_pass(close(fd));
	exclude_source_capture_release(capture);

	capture = exclude_source_capture_begin(proof, "/", 0);
	cl_assert(capture != NULL);
	fd = exclude_source_capture_open(capture);
	cl_must_pass(fd);
	cl_must_pass(fstat(fd, &st));
	cl_assert(S_ISDIR(st.st_mode));
	cl_must_pass(close(fd));
	exclude_source_capture_release(capture);
	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__accepts_same_content_parent_replacement(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *old_parent = make_path("old-parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	record_file(proof, source);
	cl_must_pass(rename(parent, old_parent));
	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	cl_assert(exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(old_parent);
	free(parent);
}

void test_exclude_source_proof__reresolves_absent_source_parent(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *missing = make_path("parent/missing");
	char *source = make_path("parent/missing/source");

	cl_must_pass(mkdir(parent, 0700));
	cl_must_pass(mkdir(missing, 0700));
	record_absence(proof, source);
	cl_must_pass(rmdir(missing));
	cl_assert(exclude_source_proof_validate(proof));
	cl_must_pass(mkdir(missing, 0700));
	cl_assert(exclude_source_proof_validate(proof));
	write_file_buf(source, "content", 7);
	cl_assert(!exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(missing);
	free(parent);
}

void test_exclude_source_proof__accepts_dev_null(void)
{
	int valid = 0;

	for (int attempt = 0; attempt < 16 && !valid; attempt++) {
		struct exclude_source_proof *proof = new_proof();

		record_file(proof, "/dev/null");
		valid = exclude_source_proof_validate(proof);
		exclude_source_proof_release(proof);
	}
	cl_assert(valid);
}

void test_exclude_source_proof__accepts_empty_fifo_replacement(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "", 0);
	record_file(proof, source);
	cl_must_pass(unlink(source));
	cl_must_pass(mkfifo(source, 0600));
	cl_assert(exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__rejects_nonempty_fifo_replacement(void)
{
	struct exclude_source_proof *proof = new_proof();
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	write_file_buf(source, "content", 7);
	record_file(proof, source);
	cl_must_pass(unlink(source));
	cl_must_pass(mkfifo(source, 0600));
	cl_assert(!exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

void test_exclude_source_proof__captures_fifo_without_blocking(void)
{
	struct exclude_source_proof *proof =
		exclude_source_proof_create(
			&istate, NULL, open_parent,
			EXCLUDE_SOURCE_PROOF_NONBLOCKING);
	char *parent = make_path("parent");
	char *source = make_path("parent/source");

	cl_must_pass(mkdir(parent, 0700));
	cl_must_pass(mkfifo(source, 0600));
	record_file(proof, source);
	cl_assert(exclude_source_proof_validate(proof));

	exclude_source_proof_release(proof);
	free(source);
	free(parent);
}

#else

#define EMPTY_TEST(name) void name(void) {}
#define SKIP_TEST(name) void name(void) { cl_skip(); }

EMPTY_TEST(test_exclude_source_proof__initialize)
EMPTY_TEST(test_exclude_source_proof__cleanup)
SKIP_TEST(test_exclude_source_proof__accepts_same_content_replacement)
SKIP_TEST(test_exclude_source_proof__accepts_sibling_churn_during_regular_capture)
SKIP_TEST(test_exclude_source_proof__accepts_sibling_churn_during_regular_validation)
SKIP_TEST(test_exclude_source_proof__rejects_parent_replacement_during_regular_capture)
SKIP_TEST(test_exclude_source_proof__rejects_parent_replacement_during_regular_validation)
SKIP_TEST(test_exclude_source_proof__rejects_symlinked_parent_during_regular_validation)
SKIP_TEST(test_exclude_source_proof__rejects_target_replacement_during_parent_churn)
SKIP_TEST(test_exclude_source_proof__rejects_sibling_churn_during_absent_capture)
SKIP_TEST(test_exclude_source_proof__rejects_sibling_churn_during_fifo_capture)
SKIP_TEST(test_exclude_source_proof__rejects_transient_absent_source_during_validation)
SKIP_TEST(test_exclude_source_proof__rejects_parent_permission_change_during_capture)
SKIP_TEST(test_exclude_source_proof__rejects_different_content_replacement)
SKIP_TEST(test_exclude_source_proof__accepts_repeated_observation)
SKIP_TEST(test_exclude_source_proof__rejects_missing_source_buffer)
SKIP_TEST(test_exclude_source_proof__rejects_conflicting_observations)
SKIP_TEST(test_exclude_source_proof__digest_deduplicates_and_ignores_identity)
SKIP_TEST(test_exclude_source_proof__rejects_open_failure)
SKIP_TEST(test_exclude_source_proof__fails_closed_without_parent_opener)
SKIP_TEST(test_exclude_source_proof__honors_nofollow)
SKIP_TEST(test_exclude_source_proof__rejects_nofollow_symlink_replacement)
SKIP_TEST(test_exclude_source_proof__opens_directory_sources)
SKIP_TEST(test_exclude_source_proof__accepts_same_content_parent_replacement)
SKIP_TEST(test_exclude_source_proof__reresolves_absent_source_parent)
SKIP_TEST(test_exclude_source_proof__accepts_dev_null)
SKIP_TEST(test_exclude_source_proof__accepts_empty_fifo_replacement)
SKIP_TEST(test_exclude_source_proof__rejects_nonempty_fifo_replacement)
SKIP_TEST(test_exclude_source_proof__captures_fifo_without_blocking)

#endif
