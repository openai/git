#include "git-compat-util.h"
#include "path-namespace.h"

void path_stat_identity_init(struct path_stat_identity *identity,
			     const struct stat *st)
{
	memset(identity, 0, sizeof(*identity));
	identity->fields[0] = st->st_dev;
	identity->fields[1] = st->st_ino;
	identity->fields[2] = st->st_mode;
	identity->fields[3] = st->st_nlink;
	identity->fields[4] = st->st_uid;
	identity->fields[5] = st->st_gid;
	identity->fields[6] = st->st_size;
	identity->fields[7] = st->st_mtime;
#ifdef __APPLE__
	identity->fields[8] = st->st_mtimespec.tv_nsec;
#else
	identity->fields[8] = ST_MTIME_NSEC(*st);
#endif
	identity->fields[9] = st->st_ctime;
#ifdef __APPLE__
	identity->fields[10] = st->st_ctimespec.tv_nsec;
#else
	identity->fields[10] = ST_CTIME_NSEC(*st);
#endif
#ifdef __APPLE__
	identity->fields[11] = st->st_birthtimespec.tv_sec;
	identity->fields[12] = st->st_birthtimespec.tv_nsec;
	identity->fields[13] = st->st_gen;
#endif
}

int path_stat_identity_equal(const struct path_stat_identity *a,
			     const struct path_stat_identity *b)
{
	return !memcmp(a, b, sizeof(*a));
}

int path_namespace_stat_equal(const struct stat *a, const struct stat *b)
{
	struct path_stat_identity first, second;

	path_stat_identity_init(&first, a);
	path_stat_identity_init(&second, b);
	return path_stat_identity_equal(&first, &second);
}

int path_namespace_reopen_component(
	int parent_fd, const char *component, int flags,
	path_namespace_open_fn open_fn, const struct stat *expected)
{
	struct stat reopened;
	int fd, saved_errno;

	if (!open_fn || !component || !*component ||
	    !strcmp(component, ".") || !strcmp(component, "..")) {
		errno = EINVAL;
		return -1;
	}
	for (const char *p = component; *p; p++) {
		if (is_dir_sep(*p)) {
			errno = EINVAL;
			return -1;
		}
	}
	if (!fstat_is_reliable()) {
		errno = EAGAIN;
		return -1;
	}

	fd = open_fn(parent_fd, component, flags);
	if (fd < 0)
		return -1;
	if (fstat(fd, &reopened)) {
		saved_errno = errno;
		goto error;
	}
	if (!path_namespace_stat_equal(expected, &reopened)) {
		saved_errno = EAGAIN;
		goto error;
	}
	return close(fd);

error:
	close(fd);
	errno = saved_errno;
	return -1;
}
