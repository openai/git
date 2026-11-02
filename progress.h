#ifndef PROGRESS_H
#define PROGRESS_H
#include "gettext.h"

struct progress;
struct repository;

#ifdef GIT_TEST_PROGRESS_ONLY

extern int progress_testing;
extern uint64_t progress_test_ns;
void progress_test_force_update(void);

#endif

void display_throughput(struct progress *progress, uint64_t total);
/* Update throughput for the next display_progress_with_status() call. */
void display_throughput_with_rate(struct progress *progress, uint64_t total,
				  bool show_rate);
void clear_progress(struct progress *progress);
void display_progress(struct progress *progress, uint64_t n);
/*
 * Display up to three newline-separated status rows if they fit.
 * A NULL status clears the rows before the next render.
 */
void display_progress_with_status(struct progress *progress, uint64_t n,
				  const char *status);
struct progress *start_progress(struct repository *r,
				const char *title, uint64_t total);
struct progress *start_sparse_progress(struct repository *r,
				       const char *title, uint64_t total);
struct progress *start_delayed_progress(struct repository *r,
					const char *title, uint64_t total);
struct progress *start_delayed_sparse_progress(struct repository *r,
					       const char *title,
					       uint64_t total);
void stop_progress_msg(struct progress **p_progress, const char *msg);
static inline void stop_progress(struct progress **p_progress)
{
	stop_progress_msg(p_progress, _("done"));
}
#endif
