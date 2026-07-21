#ifndef PRELOAD_INDEX_BULK_H
#define PRELOAD_INDEX_BULK_H

#include "git-compat-util.h"
#include "preload-index.h"
#include "strbuf.h"
#include "string-list.h"
#include "thread-utils.h"

struct dir_struct;
struct preload_bulk_untracked_root;

struct preload_bulk_dir_identity {
	struct stat stat;
	uint64_t platform_id;
	unsigned complete : 1;
};

struct preload_bulk_task {
	struct preload_bulk_task *next;
	struct preload_bulk_dir_identity parent_identity;
	struct preload_bulk_dir_identity child_identity;
	struct preload_bulk_untracked_root *untracked_root;
	int fd;
	unsigned reserved_fd : 1;
	unsigned has_parent_identity : 1;
	unsigned has_child_identity : 1;
	char path[FLEX_ARRAY];
};

struct preload_bulk_queue {
	pthread_mutex_t mutex;
	pthread_cond_t cond;
	struct preload_bulk_task *head;
	/*
	 * pending includes queued and in-flight tasks. open_fds counts only
	 * descriptor reservations held by tasks.
	 */
	size_t pending;
	size_t open_fds;
	size_t open_fd_limit;
	int failed;
	unsigned untracked_invalid : 1;
};

struct preload_bulk_scan;

struct preload_bulk_worker {
	struct preload_bulk_scan *scan;
	pthread_t thread;
	void *buffer;
	struct strbuf path;
	uint64_t dirs;
	uint64_t entries;
	uint64_t bulk_calls;
	uint64_t changed_dirs;
	uint64_t malformed;
	unsigned started : 1;
};

struct preload_bulk_backend {
	unsigned collects_untracked : 1;
	const char *(*start)(struct preload_bulk_scan *scan);
	const char *(*finish)(struct preload_bulk_scan *scan);
	void (*release)(struct preload_bulk_scan *scan);
	int (*open_proof_parent)(struct preload_bulk_scan *scan,
				 const char *path);
	int (*open_dir_at)(struct preload_bulk_worker *worker, int parent_fd,
			   const char *name);
	/*
	 * Consume task->fd when it is non-negative, and close it before
	 * returning.
	 */
	int (*scan_directory)(struct preload_bulk_worker *worker,
			      struct preload_bulk_task *task);
};

struct preload_bulk_scan {
	struct repository *repo;
	struct index_state *istate;
	const struct preload_bulk_backend *backend;
	void *platform_data;
	const char *test_barrier_path;
	const char *test_barrier_ready;
	const char *test_barrier_resume;
	struct preload_bulk_queue queue;
	struct preload_bulk_worker *workers;
	unsigned char *tracked_state;
	struct dir_struct *exclude_dir;
	pthread_mutex_t exclude_mutex;
	struct preload_bulk_untracked_root *untracked_roots;
	struct string_list untracked;
	int root_fd;
	int threads;
	unsigned collect_untracked : 1;
	unsigned case_insensitive : 1;
	unsigned can_skip_unseen_preload : 1;
};

struct preload_bulk_run_result {
	uint64_t dirs;
	uint64_t entries;
	uint64_t bulk_calls;
	uint64_t changed_dirs;
	uint64_t malformed;
	int threads;
	unsigned untracked_complete : 1;
};

struct preload_bulk_result {
	unsigned char *tracked_state;
	size_t nr;
	const char *outcome;
	const char *reason;
	const char *untracked_reason;
	struct preload_bulk_run_result run;
	unsigned can_skip_unseen_preload : 1;
	struct string_list untracked;
	unsigned untracked_complete : 1;
};

void preload_bulk_schedule_directory(
	struct preload_bulk_worker *worker, int parent_fd,
	const struct preload_bulk_dir_identity *parent_identity,
	const struct preload_bulk_dir_identity *child_identity,
	struct preload_bulk_untracked_root *untracked_root,
	const char *name, const char *path, size_t path_len);
int preload_bulk_index_position(struct preload_bulk_scan *scan,
				const char *path, size_t path_len);
int preload_bulk_index_pos_has_tracked_descendants(
	struct preload_bulk_scan *scan, const char *path, size_t path_len,
	int pos);
int preload_bulk_index_entry_is_gitlink(struct preload_bulk_scan *scan,
					int pos);
void preload_bulk_record_tracked(
	struct preload_bulk_worker *worker, int pos, const struct stat *st);
void preload_bulk_record_tracked_fallback(
	struct preload_bulk_worker *worker, int pos);
void preload_bulk_record_tracked_descendants_fallback(
	struct preload_bulk_worker *worker, const char *path,
	size_t path_len);
int preload_bulk_record_tracked_alias_fallback(
	struct preload_bulk_worker *worker, const char *path,
	size_t path_len);
int preload_bulk_path_is_excluded(struct preload_bulk_worker *worker,
				  const char *path, int dtype);
void preload_bulk_invalidate_untracked(
	struct preload_bulk_worker *worker);
int preload_bulk_untracked_is_invalid(
	struct preload_bulk_worker *worker);
struct preload_bulk_untracked_root *preload_bulk_untracked_root_new(
	struct preload_bulk_worker *worker, const char *path,
	size_t path_len);
int preload_bulk_untracked_root_is_visible(
	struct preload_bulk_worker *worker,
	const struct preload_bulk_untracked_root *root);
void preload_bulk_record_untracked(
	struct preload_bulk_worker *worker,
	struct preload_bulk_untracked_root *root,
	const char *path);
int preload_bulk_run_scan(struct preload_bulk_scan *scan,
			  struct preload_bulk_run_result *result);
const struct preload_bulk_backend *preload_bulk_platform_backend(void);
int preload_bulk_collect(struct index_state *istate, int threads,
			 struct preload_bulk_result *result);
int preload_bulk_available(void);
int preload_bulk_test_barrier(struct preload_bulk_scan *scan,
			      const char *path);
void preload_bulk_result_release(struct preload_bulk_result *result);

#endif /* PRELOAD_INDEX_BULK_H */
