#ifndef PATH_NAMESPACE_H
#define PATH_NAMESPACE_H

struct stat;

typedef int (*path_namespace_open_fn)(int dirfd, const char *path, int flags);

#define PATH_STAT_IDENTITY_FIELDS 14

struct path_stat_identity {
	uint64_t fields[PATH_STAT_IDENTITY_FIELDS];
};

void path_stat_identity_init(struct path_stat_identity *identity,
			     const struct stat *st);
int path_stat_identity_equal(const struct path_stat_identity *a,
			     const struct path_stat_identity *b);
int path_namespace_stat_equal(const struct stat *a, const struct stat *b);
int path_namespace_reopen_component(
	int parent_fd, const char *component, int flags,
	path_namespace_open_fn open_fn, const struct stat *expected);

#endif /* PATH_NAMESPACE_H */
