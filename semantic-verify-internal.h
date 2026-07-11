#ifndef SEMANTIC_VERIFY_INTERNAL_H
#define SEMANTIC_VERIFY_INTERNAL_H

#include "statinfo.h"

#ifdef __linux__
#include <sys/syscall.h>
#if !defined(SYS_openat2) && defined(__NR_openat2)
#define SYS_openat2 __NR_openat2
#elif !defined(SYS_openat2) && \
	(defined(__x86_64__) || defined(__i386__))
#define SYS_openat2 437
#endif
#endif

#if defined(__APPLE__) && defined(O_NONBLOCK) && \
	defined(O_NOFOLLOW) && defined(O_DIRECTORY) && \
	defined(AT_SYMLINK_NOFOLLOW)
#define SEMANTIC_VERIFY_HAS_ANCHORED_OPEN 1
#elif defined(__linux__) && defined(SYS_openat2) && \
	defined(O_CLOEXEC) && defined(O_NONBLOCK) && \
	defined(O_NOFOLLOW) && defined(O_DIRECTORY) && \
	defined(AT_SYMLINK_NOFOLLOW)
#define SEMANTIC_VERIFY_HAS_ANCHORED_OPEN 1
#else
#define SEMANTIC_VERIFY_HAS_ANCHORED_OPEN 0
#endif

struct attr_check;
struct repository;
struct cache_entry;
struct git_hash_algo;
struct index_state;
struct semantic_verify_result;
struct semantic_verify_path;

#define SEMANTIC_VERIFY_HASH_BUFFER_SIZE (256 * 1024)

struct semantic_verify_root {
	int fd;
	char *path;
	struct stat stat;
};

int semantic_verify_root_init(struct repository *repo,
			      struct semantic_verify_root **root_out);
void semantic_verify_root_clear(struct semantic_verify_root *root);

int semantic_verify_openat(int dirfd, const char *path, int flags);

struct semantic_verify_path *semantic_verify_path_new(
	struct semantic_verify_root *root);
int semantic_verify_resolve_parent(struct semantic_verify_path *path,
				   const char *name, size_t cache_pos,
				   int *parent_fd, const char **basename);
void semantic_verify_path_free(struct semantic_verify_path *path,
			       unsigned int *namespace_unstable,
			       size_t *namespace_unstable_from);

struct semantic_verify_file_result {
	struct stat_data stat_data;
	size_t bytes_hashed;
	int error;
	unsigned int kind;
	unsigned int persistable;
	unsigned int active_filter;
};

int semantic_verify_classify_entry(struct index_state *istate,
				   const struct cache_entry *ce,
				   struct attr_check *check,
				   int validate_filter_scope,
				   struct semantic_verify_file_result *result);
void semantic_verify_file(struct semantic_verify_root *root,
			  struct semantic_verify_path *path,
			  const struct cache_entry *ce, size_t cache_pos,
			  struct repository *repo, void *buffer,
			  struct semantic_verify_file_result *result);
void semantic_verify_file_at(int parent_fd, const char *basename,
			     const struct stat *observed,
			     dev_t root_dev,
			     const struct cache_entry *ce,
			     struct repository *repo, void *buffer,
			     struct semantic_verify_file_result *result);

struct semantic_verify_stat_update {
	uint32_t cache_pos;
	struct stat_data stat_data;
};

struct semantic_verify_worker {
	struct index_state *istate;
	struct semantic_verify_root *root;
	struct semantic_verify_result *results;
	size_t start;
	size_t end;
	struct semantic_verify_stat_update *updates;
	size_t updates_nr;
	size_t updates_alloc;
	size_t bytes_hashed;
	size_t raw_clean;
	size_t raw_modified;
	size_t sensitive;
	size_t structural;
	size_t skipped;
	size_t unstable;
	size_t errors;
	size_t hardlinks;
	unsigned int namespace_unstable;
};

void semantic_verify_worker_run(struct semantic_verify_worker *worker);

#endif /* SEMANTIC_VERIFY_INTERNAL_H */
