#ifndef PRELOAD_INDEX_H
#define PRELOAD_INDEX_H

struct index_state;
struct pathspec;
struct repository;

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

#endif /* PRELOAD_INDEX_H */
