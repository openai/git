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

static int open_parent(void *data UNUSED, const char *path)
{
	if (fail_open_parent) {
		errno = EACCES;
		return -1;
	}
	return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
}

static struct exclude_source_proof *new_proof(void)
{
	return exclude_source_proof_create(
		&istate, NULL, open_parent);
}

static char *make_path(const char *name)
{
	struct strbuf path = STRBUF_INIT;

	strbuf_addf(&path, "%s/%s", trash, name);
	return strbuf_detach(&path, NULL);
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
		exclude_source_proof_create(&istate, NULL, NULL);

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

	capture = exclude_source_capture_begin(proof, source, 1);
	cl_assert(capture != NULL);
	fd = exclude_source_capture_open(capture);
	cl_assert(fd < 0 && errno == ELOOP);
	exclude_source_capture_release(capture);

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
	struct exclude_source_proof *proof = new_proof();

	record_file(proof, "/dev/null");
	cl_assert(exclude_source_proof_validate(proof));
	exclude_source_proof_release(proof);
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

#else

#define EMPTY_TEST(name) void name(void) {}
#define SKIP_TEST(name) void name(void) { cl_skip(); }

EMPTY_TEST(test_exclude_source_proof__initialize)
EMPTY_TEST(test_exclude_source_proof__cleanup)
SKIP_TEST(test_exclude_source_proof__accepts_same_content_replacement)
SKIP_TEST(test_exclude_source_proof__rejects_different_content_replacement)
SKIP_TEST(test_exclude_source_proof__accepts_repeated_observation)
SKIP_TEST(test_exclude_source_proof__rejects_missing_source_buffer)
SKIP_TEST(test_exclude_source_proof__rejects_conflicting_observations)
SKIP_TEST(test_exclude_source_proof__rejects_open_failure)
SKIP_TEST(test_exclude_source_proof__fails_closed_without_parent_opener)
SKIP_TEST(test_exclude_source_proof__honors_nofollow)
SKIP_TEST(test_exclude_source_proof__opens_directory_sources)
SKIP_TEST(test_exclude_source_proof__accepts_same_content_parent_replacement)
SKIP_TEST(test_exclude_source_proof__reresolves_absent_source_parent)
SKIP_TEST(test_exclude_source_proof__accepts_dev_null)
SKIP_TEST(test_exclude_source_proof__accepts_empty_fifo_replacement)
SKIP_TEST(test_exclude_source_proof__rejects_nonempty_fifo_replacement)

#endif
