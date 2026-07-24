#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "abspath.h"
#include "config.h"
#include "environment.h"
#include "exec-cmd.h"
#include "gettext.h"
#include "parse.h"
#include "simple-ipc.h"
#include "fsmonitor-ipc.h"
#include "repository.h"
#include "run-command.h"
#include "strbuf.h"
#include "trace2.h"

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

int fsmonitor_ipc__send_query(const char *since_token,
			      struct strbuf *answer)
{
	int ret = -1;
	int tried_to_spawn = 0;
	enum ipc_active_state state = IPC_STATE__OTHER_ERROR;
	struct ipc_client_connection *connection = NULL;
	struct ipc_client_connect_options options
		= IPC_CLIENT_CONNECT_OPTIONS_INIT;
	const char *tok = since_token ? since_token : "";
	size_t tok_len = since_token ? strlen(since_token) : 0;

	options.wait_if_busy = 1;
	options.wait_if_not_found = 0;

	trace2_region_enter("fsm_client", "query", NULL);
	trace2_data_string("fsm_client", NULL, "query/command", tok);

try_again:
	state = ipc_client_try_connect(fsmonitor_ipc__get_path(the_repository),
						&options, &connection);

	switch (state) {
	case IPC_STATE__LISTENING:
		ret = ipc_client_send_command_to_connection(
			connection, tok, tok_len, answer);
		ipc_client_close_connection(connection);

		trace2_data_intmax("fsm_client", NULL,
				   "query/response-length", answer->len);
		goto done;

	case IPC_STATE__NOT_LISTENING:
	case IPC_STATE__PATH_NOT_FOUND:
		if (tried_to_spawn)
			goto done;

		tried_to_spawn++;
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

	return ret;
}

int fsmonitor_ipc__send_command(const char *command,
				struct strbuf *answer)
{
	struct ipc_client_connection *connection = NULL;
	struct ipc_client_connect_options options
		= IPC_CLIENT_CONNECT_OPTIONS_INIT;
	int ret;
	enum ipc_active_state state;
	const char *c = command ? command : "";
	size_t c_len = command ? strlen(command) : 0;

	strbuf_reset(answer);

	options.wait_if_busy = 1;
	options.wait_if_not_found = 0;

	state = ipc_client_try_connect(fsmonitor_ipc__get_path(the_repository),
						&options, &connection);
	if (state != IPC_STATE__LISTENING) {
		die(_("fsmonitor--daemon is not running"));
		return -1;
	}

	ret = ipc_client_send_command_to_connection(connection, c, c_len,
						    answer);
	ipc_client_close_connection(connection);

	if (ret == -1) {
		die(_("could not send '%s' command to fsmonitor--daemon"), c);
		return -1;
	}

	return 0;
}

#endif
