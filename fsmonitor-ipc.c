#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "abspath.h"
#include "config.h"
#include "environment.h"
#include "exec-cmd.h"
#include "gettext.h"
#include "hash.h"
#include "lockfile.h"
#include "parse.h"
#include "simple-ipc.h"
#include "fsmonitor-ipc.h"
#include "repository.h"
#include "run-command.h"
#include "strbuf.h"
#include "trace2.h"

int fsmonitor_ipc__get_worktree_identity(struct repository *r,
					 struct strbuf *identity)
{
	static const char hex[] = "0123456789abcdef";
	struct strbuf canonical = STRBUF_INIT;
	struct strbuf stable = STRBUF_INIT;
	git_SHA256_CTX ctx;
	unsigned char hash[GIT_SHA256_RAWSZ];
	struct stat st;
	const char *worktree = repo_get_work_tree(r);
	int ret = -1;

	if (!worktree ||
	    !strbuf_realpath(&canonical, worktree, 0) ||
	    stat(canonical.buf, &st))
		goto done;
	strbuf_addf(&stable, "v1\n%"PRIuMAX":", (uintmax_t)canonical.len);
	strbuf_addbuf(&stable, &canonical);
	strbuf_addf(&stable, "\n%"PRIuMAX"\n%"PRIuMAX,
		    (uintmax_t)st.st_dev, (uintmax_t)st.st_ino);
#ifdef __APPLE__
	strbuf_addf(&stable, "\n%"PRIdMAX"\n%ld\n%"PRIu32,
		    (intmax_t)st.st_birthtimespec.tv_sec,
		    st.st_birthtimespec.tv_nsec, st.st_gen);
#endif
	git_SHA256_Init(&ctx);
	git_SHA256_Update(&ctx, stable.buf, stable.len);
	git_SHA256_Final(hash, &ctx);
	strbuf_reset(identity);
	for (size_t i = 0; i < ARRAY_SIZE(hash); i++) {
		strbuf_addch(identity, hex[hash[i] >> 4]);
		strbuf_addch(identity, hex[hash[i] & 0xf]);
	}
	ret = 0;
done:
	strbuf_release(&stable);
	strbuf_release(&canonical);
	return ret;
}

#ifndef HAVE_FSMONITOR_DAEMON_BACKEND

/*
 * A trivial implementation of the fsmonitor_ipc__ API for unsupported
 * platforms.
 */

int fsmonitor_ipc__is_supported(void)
{
	return 0;
}

const char *fsmonitor_ipc__get_path(struct repository *r UNUSED)
{
	return NULL;
}

enum ipc_active_state fsmonitor_ipc__get_state(void)
{
	return IPC_STATE__OTHER_ERROR;
}

int fsmonitor_ipc__send_query(const char *since_token UNUSED,
			      struct strbuf *answer UNUSED)
{
	return -1;
}

int fsmonitor_ipc__send_command(const char *command UNUSED,
				struct strbuf *answer UNUSED)
{
	return -1;
}

#else

static void prepare_spawn_env(struct strvec *env)
{
	/* Let the child rediscover this repository from the worktree. */
	strvec_push(env, GIT_DIR_ENVIRONMENT);
	strvec_push(env, GIT_WORK_TREE_ENVIRONMENT);
	strvec_push(env, GIT_COMMON_DIR_ENVIRONMENT);
	strvec_push(env, GIT_PREFIX_ENVIRONMENT);
	strvec_push(env, GIT_IMPLICIT_WORK_TREE_ENVIRONMENT);
	strvec_push(env, INDEX_ENVIRONMENT);
}

int fsmonitor_ipc__is_supported(void)
{
	return 1;
}

enum ipc_active_state fsmonitor_ipc__get_state(void)
{
	return ipc_get_active_state(fsmonitor_ipc__get_path(the_repository));
}

#define FSMONITOR_START_TIMEOUT_KEY "fsmonitor.starttimeout"
#define FSMONITOR_START_TIMEOUT_DEFAULT 60
#define FSMONITOR_RESTART_ATTEMPTS 3

static unsigned int get_start_timeout(void)
{
	const char *value;
	int timeout;

	if (!repo_config_get_value(the_repository,
				   FSMONITOR_START_TIMEOUT_KEY, &value) &&
	    value && git_parse_int(value, &timeout) && timeout >= 0)
		return timeout;
	return FSMONITOR_START_TIMEOUT_DEFAULT;
}

static int spawn_wait_cb(const struct child_process *cmd UNUSED,
			 void *cb_data UNUSED)
{
	switch (fsmonitor_ipc__get_state()) {
	case IPC_STATE__LISTENING:
		return 0;
	case IPC_STATE__NOT_LISTENING:
	case IPC_STATE__PATH_NOT_FOUND:
		return 1;
	default:
	case IPC_STATE__INVALID_PATH:
	case IPC_STATE__OTHER_ERROR:
		return -1;
	}
}

static int spawn_daemon(void)
{
	struct child_process cmd = CHILD_PROCESS_INIT;
	struct strbuf canonical_worktree = STRBUF_INIT;
	enum start_bg_result result;
	unsigned int timeout = get_start_timeout();
	const char *git = git_executable_path();
	const char *worktree = repo_get_work_tree(the_repository);
	int ret = -1;

	if (!worktree ||
	    !strbuf_realpath(&canonical_worktree, worktree, 0)) {
		error(_("cannot start fsmonitor daemon without a work tree"));
		goto done;
	}

	prepare_spawn_env(&cmd.env);
	cmd.dir = canonical_worktree.buf;
	if (git)
		strvec_push(&cmd.args, git);
	else
		cmd.git_cmd = 1;
	cmd.no_stdin = 1;
	cmd.no_stdout = 1;
	cmd.no_stderr = 1;
	cmd.close_fd_above_stderr = 1;
	cmd.trace2_child_class = "fsmonitor";
	strvec_pushl(&cmd.args, "fsmonitor--daemon", "run", "--detach", NULL);

	result = start_bg_command(&cmd, spawn_wait_cb, NULL, timeout);
	if (result == SBGR_READY ||
	    fsmonitor_ipc__get_state() == IPC_STATE__LISTENING)
		ret = 0;
done:
	strbuf_release(&canonical_worktree);
	return ret;
}

static int try_send_command(const char *command, struct strbuf *answer,
			    enum ipc_active_state *state_out)
{
	struct ipc_client_connection *connection = NULL;
	struct ipc_client_connect_options options
		= IPC_CLIENT_CONNECT_OPTIONS_INIT;
	enum ipc_active_state state;
	int ret = -1;

	strbuf_reset(answer);
	options.wait_if_busy = 1;
	options.wait_if_not_found = 0;

	state = ipc_client_try_connect(fsmonitor_ipc__get_path(the_repository),
				       &options, &connection);
	if (state == IPC_STATE__LISTENING) {
		ret = ipc_client_send_command_to_connection(
			connection, command, strlen(command), answer);
		ipc_client_close_connection(connection);
	}

	if (state_out)
		*state_out = state;
	return ret;
}

static int is_trivial_response(const struct strbuf *answer)
{
	const char *nul = memchr(answer->buf, '\0', answer->len);

	return nul && nul != answer->buf &&
		answer->len == (size_t)(nul - answer->buf) + 3 &&
		nul[1] == '/' && nul[2] == '\0';
}

static int has_capability(const struct strbuf *answer,
			  const char *capability)
{
	const char *p = answer->buf;
	const char *end = answer->buf + answer->len;
	size_t capability_len = strlen(capability);

	while (p < end) {
		const char *eol = memchr(p, '\n', end - p);
		const char *line_end = eol ? eol : end;

		if ((size_t)(line_end - p) == capability_len &&
		    !memcmp(p, capability, capability_len))
			return 1;
		if (!eol)
			break;
		p = eol + 1;
	}
	return 0;
}

static int server_supports_bound_queries(void)
{
	struct strbuf answer = STRBUF_INIT;
	int ret;

	ret = !try_send_command(FSMONITOR_IPC_CAPABILITY_COMMAND,
				&answer, NULL) &&
		has_capability(&answer, FSMONITOR_IPC_QUERY_VERSION);
	strbuf_release(&answer);
	return ret;
}

static int wait_for_daemon_exit(void)
{
	uintmax_t elapsed_ms = 0;
	uintmax_t timeout_ms = (uintmax_t)get_start_timeout() * 1000;

	while (fsmonitor_ipc__get_state() == IPC_STATE__LISTENING) {
		if (elapsed_ms >= timeout_ms)
			return -1;
		sleep_millisec(50);
		elapsed_ms += 50;
	}
	return 0;
}

static int restart_incompatible_daemon(void)
{
	struct strbuf answer = STRBUF_INIT;
	struct strbuf lock_path = STRBUF_INIT;
	struct lock_file restart_lock = LOCK_INIT;
	uintmax_t timeout_ms = (uintmax_t)get_start_timeout() * 1000;
	long lock_timeout_ms = timeout_ms > LONG_MAX ?
		LONG_MAX : (long)timeout_ms;
	int have_lock = 0;
	int ret = -1;

	/*
	 * Serialize the re-probe, quit, wait, and spawn sequence.  This uses a
	 * different lock from the one used briefly while binding the socket.
	 */
	strbuf_addf(&lock_path, "%s.restart",
		    fsmonitor_ipc__get_path(the_repository));
	if (hold_lock_file_for_update_timeout(&restart_lock, lock_path.buf,
					      LOCK_NO_DEREF,
					      lock_timeout_ms) < 0) {
		if (server_supports_bound_queries())
			ret = 0;
		goto done;
	}
	have_lock = 1;

	/* Another client may have replaced the daemon while we waited. */
	if (server_supports_bound_queries())
		goto success;

	trace2_data_intmax("fsm_client", NULL,
			   "query/incompatible-daemon", 1);
	if (try_send_command("quit", &answer, NULL)) {
		/*
		 * The connection state describes the failed attempt, not
		 * necessarily the state after the failure.  Re-read it before
		 * deciding whether there is still a daemon to replace.
		 */
		if (fsmonitor_ipc__get_state() == IPC_STATE__LISTENING) {
			if (server_supports_bound_queries())
				ret = 0;
			goto done;
		}
	}

	if (wait_for_daemon_exit())
		goto done;

	/*
	 * A concurrent client may already have started a replacement.
	 * The retried bound query will verify its capability if needed.
	 */
	if (fsmonitor_ipc__get_state() != IPC_STATE__LISTENING &&
	    spawn_daemon())
		goto done;

success:
	ret = 0;

done:
	if (have_lock)
		rollback_lock_file(&restart_lock);
	strbuf_release(&lock_path);
	strbuf_release(&answer);
	return ret;
}

int fsmonitor_ipc__send_query(const char *since_token,
			      struct strbuf *answer)
{
	struct strbuf command = STRBUF_INIT;
	struct strbuf identity = STRBUF_INIT;
	int ret = -1;
	int lifecycle_attempts = 0;
	enum ipc_active_state state = IPC_STATE__OTHER_ERROR;
	struct ipc_client_connection *connection = NULL;
	struct ipc_client_connect_options options
		= IPC_CLIENT_CONNECT_OPTIONS_INIT;
	const char *tok = since_token ? since_token : "";

	trace2_region_enter("fsm_client", "query", NULL);
	if (fsmonitor_ipc__get_worktree_identity(the_repository, &identity)) {
		trace2_data_intmax("fsm_client", NULL,
				   "query/worktree-identity-error", 1);
		goto done;
	}
	strbuf_addstr(&command, FSMONITOR_IPC_QUERY_PREFIX);
	strbuf_addbuf(&command, &identity);
	strbuf_addch(&command, '\n');
	strbuf_addstr(&command, tok);

	options.wait_if_busy = 1;
	options.wait_if_not_found = 0;

	trace2_data_string("fsm_client", NULL, "query/command", tok);

try_again:
	strbuf_reset(answer);
	state = ipc_client_try_connect(fsmonitor_ipc__get_path(the_repository),
						&options, &connection);

	switch (state) {
	case IPC_STATE__LISTENING:
		ret = ipc_client_send_command_to_connection(
			connection, command.buf, command.len, answer);
		ipc_client_close_connection(connection);
		connection = NULL;

		trace2_data_intmax("fsm_client", NULL,
				   "query/response-length", answer->len);
		if (!ret && is_trivial_response(answer) &&
		    !server_supports_bound_queries()) {
			/*
			 * A daemon predating bound queries treats query-v1 as
			 * garbage and returns a valid trivial response.  Never
			 * accept that unbound result.  Replace the daemon with
			 * the invoking Git executable and retry instead.
			 */
			strbuf_reset(answer);
			ret = -1;
			if (lifecycle_attempts++ >= FSMONITOR_RESTART_ATTEMPTS ||
			    restart_incompatible_daemon())
				goto done;
			options.wait_if_not_found = 1;
			goto try_again;
		}
		goto done;

	case IPC_STATE__NOT_LISTENING:
	case IPC_STATE__PATH_NOT_FOUND:
		if (lifecycle_attempts++ >= FSMONITOR_RESTART_ATTEMPTS)
			goto done;

		if (spawn_daemon())
			goto done;

		/*
		 * Try again, but this time give the daemon a chance to
		 * actually create the pipe/socket.
		 *
		 * Granted, the daemon just started so it can't possibly have
		 * any FS cached yet, so we'll always get a trivial answer.
		 * BUT the answer should include a new token that can serve
		 * as the basis for subsequent requests.
		 */
		options.wait_if_not_found = 1;
		goto try_again;

	case IPC_STATE__INVALID_PATH:
		ret = error(_("fsmonitor_ipc__send_query: invalid path '%s'"),
			    fsmonitor_ipc__get_path(the_repository));
		goto done;

	case IPC_STATE__OTHER_ERROR:
	default:
		ret = error(_("fsmonitor_ipc__send_query: unspecified error on '%s'"),
			    fsmonitor_ipc__get_path(the_repository));
		goto done;
	}

done:
	trace2_region_leave("fsm_client", "query", NULL);
	strbuf_release(&identity);
	strbuf_release(&command);

	return ret;
}

int fsmonitor_ipc__send_command(const char *command,
				struct strbuf *answer)
{
	enum ipc_active_state state;
	const char *c = command ? command : "";
	int ret = try_send_command(c, answer, &state);

	if (state != IPC_STATE__LISTENING) {
		die(_("fsmonitor--daemon is not running"));
		return -1;
	}

	if (ret == -1) {
		die(_("could not send '%s' command to fsmonitor--daemon"), c);
		return -1;
	}

	return 0;
}

#endif
