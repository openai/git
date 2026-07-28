#ifndef PRELOAD_INDEX_H
#define PRELOAD_INDEX_H

struct index_state;
struct object_id;
struct pathspec;
struct repository;
struct stat;

enum preload_bulk_tracked_state {
	PRELOAD_BULK_TRACKED_UNSEEN = 0,
	PRELOAD_BULK_TRACKED_CLEAN,
	PRELOAD_BULK_TRACKED_DEFINITIVE_MODIFIED,
	PRELOAD_BULK_TRACKED_DEFINITIVE_DELETED,
	PRELOAD_BULK_TRACKED_CONTENT_CHECK,
	PRELOAD_BULK_TRACKED_FALLBACK,
};

void preload_index(struct index_state *index,
		   const struct pathspec *pathspec,
		   unsigned int refresh_flags);
int repo_read_index_preload(struct repository *,
			    const struct pathspec *pathspec,
			    unsigned refresh_flags);
void preload_index_bulk_result_clear(struct index_state *index);
void preload_index_bulk_result_consume(struct index_state *index);
int preload_index_bulk_can_close_provider(struct index_state *index);
int preload_index_bulk_result_accept(struct index_state *index);
int preload_index_bulk_standard_excludes_digest(
	const struct index_state *index, struct object_id *digest,
	struct stat *scanned_worktree);

#endif /* PRELOAD_INDEX_H */
