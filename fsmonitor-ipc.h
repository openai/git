#ifndef FSMONITOR_IPC_H
#define FSMONITOR_IPC_H

#include "simple-ipc.h"

struct repository;

#define FSMONITOR_IPC_QUERY_VERSION "query-v1"
#define FSMONITOR_IPC_QUERY_PREFIX FSMONITOR_IPC_QUERY_VERSION " "
#define FSMONITOR_IPC_HARDLINK_QUERY_VERSION "query-v2"
#define FSMONITOR_IPC_HARDLINK_QUERY_PREFIX \
	FSMONITOR_IPC_HARDLINK_QUERY_VERSION " "
#define FSMONITOR_IPC_CAPABILITY_COMMAND "get-capabilities"
#define FSMONITOR_IPC_DIR_METADATA_CAPABILITY "dir-metadata-filter-v1"
#define FSMONITOR_IPC_DIR_METADATA_TOKEN_PREFIX "dirmeta-v1."
#define FSMONITOR_IPC_HARDLINK_INODE_CAPABILITY "hardlink-inode-v1"
#define FSMONITOR_IPC_HARDLINK_INODE_TOKEN_PREFIX \
	FSMONITOR_IPC_DIR_METADATA_TOKEN_PREFIX "inode-v1."
#define FSMONITOR_IPC_COOKIE_TOKEN_RETIREMENT_CAPABILITY \
	"cookie-token-retirement-v1"
#define FSMONITOR_IPC_COOKIE_TOKEN_RETIREMENT_PREFIX "cookie-v1."
#define FSMONITOR_IPC_WORKTREE_ID_HEX 64

#ifdef __APPLE__
#define FSMONITOR_IPC_PLATFORM_TOKEN_PREFIX \
	FSMONITOR_IPC_HARDLINK_INODE_TOKEN_PREFIX
#define FSMONITOR_IPC_HAS_DIR_METADATA 1
#elif defined(__linux__)
#define FSMONITOR_IPC_PLATFORM_TOKEN_PREFIX \
	FSMONITOR_IPC_DIR_METADATA_TOKEN_PREFIX
#define FSMONITOR_IPC_HAS_DIR_METADATA 1
#else
#define FSMONITOR_IPC_PLATFORM_TOKEN_PREFIX ""
#define FSMONITOR_IPC_HAS_DIR_METADATA 0
#endif

/* Hash the canonical worktree root and its stable filesystem identity. */
int fsmonitor_ipc__get_worktree_identity(struct repository *r,
					 struct strbuf *identity);

/* Remember a bounded, worktree-specific inotify watch-limit failure. */
void fsmonitor_ipc__record_watch_limit_failure(const char *worktree_identity);
void fsmonitor_ipc__clear_watch_limit_failure(void);
int fsmonitor_ipc__watch_limit_backoff(struct repository *r);

/*
 * Returns true if built-in file system monitor daemon is defined
 * for this platform.
 */
int fsmonitor_ipc__is_supported(void);

/*
 * Returns the pathname to the IPC named pipe or Unix domain socket
 * where a `git-fsmonitor--daemon` process will listen.  This is a
 * per-worktree value.
 *
 * Returns NULL if the daemon is not supported on this platform.
 */
const char *fsmonitor_ipc__get_path(struct repository *r);

/*
 * Try to determine whether there is a `git-fsmonitor--daemon` process
 * listening on the IPC pipe/socket.
 */
enum ipc_active_state fsmonitor_ipc__get_state(void);

/*
 * Connect to a `git-fsmonitor--daemon` process via simple-ipc
 * and ask for the set of changed files since the given token.
 *
 * Spawn a daemon process in the background if necessary.
 *
 * Returns -1 on error; 0 on success.
 */
int fsmonitor_ipc__send_query(const char *since_token,
			      struct strbuf *answer,
			      int *legacy_worktree_authenticated);

/*
 * Connect to a `git-fsmonitor--daemon` process via simple-ipc and
 * send a command verb.  If no daemon is available, we DO NOT try to
 * start one.
 *
 * Returns -1 on error; 0 on success.
 */
int fsmonitor_ipc__send_command(const char *command,
				struct strbuf *answer);

#endif /* FSMONITOR_IPC_H */
