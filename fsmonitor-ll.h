#ifndef FSMONITOR_LL_H
#define FSMONITOR_LL_H

struct index_state;
struct strbuf;

/* A provider-only marker; worktree-relative paths cannot begin with '/'. */
#define FSMONITOR_PATH_GLOBAL_INVALIDATE "//"

enum fsmonitor_token_result {
	FSMONITOR_TOKEN_NOT_PENDING = 0,
	FSMONITOR_TOKEN_CLEAN,
	FSMONITOR_TOKEN_CHANGED,
	FSMONITOR_TOKEN_TRIVIAL,
	FSMONITOR_TOKEN_ERROR,
};

extern struct trace_key trace_fsmonitor;

/*
 * Read the fsmonitor index extension and (if configured) restore the
 * CE_FSMONITOR_VALID state.
 */
int read_fsmonitor_extension(struct index_state *istate, const void *data, unsigned long sz);

int read_fsmonitor_untracked_extension(struct index_state *istate,
				       const void *data, unsigned long sz);
void write_fsmonitor_untracked_extension(struct strbuf *sb,
					 struct index_state *istate);
void prepare_fsmonitor_untracked(struct index_state *istate);

/*
 * Fill the fsmonitor_dirty ewah bits with their state from the index,
 * before it is split during writing.
 */
void fill_fsmonitor_bitmap(struct index_state *istate);

/*
 * Write the CE_FSMONITOR_VALID state into the fsmonitor index
 * extension.  Reads from the fsmonitor_dirty ewah in the index.
 */
void write_fsmonitor_extension(struct strbuf *sb, struct index_state *istate);

/*
 * Add/remove the fsmonitor index extension
 */
void add_fsmonitor(struct index_state *istate);
void remove_fsmonitor(struct index_state *istate);

/*
 * Add/remove the fsmonitor index extension as necessary based on the current
 * core.fsmonitor setting.
 */
void tweak_fsmonitor(struct index_state *istate);

/*
 * Run the configured fsmonitor integration script and clear the
 * CE_FSMONITOR_VALID bit for any files returned as dirty.  Also invalidate
 * any corresponding untracked cache directory structures. Optimized to only
 * run the first time it is called.
 */
void refresh_fsmonitor(struct index_state *istate);

int fsmonitor_invalidate_attributes_path(struct index_state *istate,
					 const char *name);

/* Close a provider token which was obtained before a required scan. */
int fsmonitor_has_pending_token(const struct index_state *istate);
int fsmonitor_pending_token_from_provider(const struct index_state *istate);
enum fsmonitor_token_result fsmonitor_query_pending_token(
	struct index_state *istate, int untracked_ready);
void fsmonitor_accept_pending_token(struct index_state *istate,
				    int untracked_ready);
void fsmonitor_reject_pending_token(struct index_state *istate);
void fsmonitor_mark_untracked_cache_valid(struct index_state *istate);

/*
 * Does the received result contain the "trivial" response?
 */
int fsmonitor_is_trivial_response(const struct strbuf *query_result);

#endif /* FSMONITOR_LL_H */
