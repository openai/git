#include "unit-test.h"

#include "path-namespace.h"
#include "tempfile.h"

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
