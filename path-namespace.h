#ifndef PATH_NAMESPACE_H
#define PATH_NAMESPACE_H

struct git_hash_ctx;
struct path_namespace_snapshot;
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
int path_namespace_capture(const char *path,
			   struct path_namespace_snapshot **snapshot_out);
int path_namespace_equal(const struct path_namespace_snapshot *a,
			 const struct path_namespace_snapshot *b);
int path_namespace_target_present(
	const struct path_namespace_snapshot *snapshot);
void path_namespace_hash(struct git_hash_ctx *ctx,
			 const struct path_namespace_snapshot *snapshot);
void path_namespace_hash_stat(struct git_hash_ctx *ctx,
			      const struct stat *st);
int path_namespace_stat_equal(const struct stat *a, const struct stat *b);
int path_namespace_reopen_component(
	int parent_fd, const char *component, int flags,
	path_namespace_open_fn open_fn, const struct stat *expected);
void path_namespace_clear(struct path_namespace_snapshot *snapshot);

#endif /* PATH_NAMESPACE_H */
