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
#include "path.h"
#include "simple-ipc.h"
#include "fsmonitor-ipc.h"
#include "repository.h"
#include "run-command.h"
#include "strbuf.h"
#include "trace2.h"

#ifdef __APPLE__
#include <libproc.h>
#include <sys/un.h>
#endif

#ifdef __linux__
#include <sys/sysmacros.h>
#endif

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

void fsmonitor_ipc__record_watch_limit_failure(
	const char *worktree_identity UNUSED)
{
}

void fsmonitor_ipc__clear_watch_limit_failure(void)
{
}

int fsmonitor_ipc__watch_limit_backoff(struct repository *r UNUSED)
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
			      struct strbuf *answer UNUSED,
			      int *legacy_worktree_authenticated UNUSED)
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

#if defined(__linux__) || defined(__APPLE__)
#define FSMONITOR_WATCH_LIMIT_MARKER "fsmonitor--daemon.inotify-limit"
#define FSMONITOR_WATCH_LIMIT_MAGIC "inotify-limit-v1\n"
#define FSMONITOR_WATCH_LIMIT_BACKOFF_SECONDS 60

static int watch_limit_backoff_enabled(void)
{
#ifdef __linux__
	return 1;
#else
	return git_env_bool("GIT_TEST_FSMONITOR_INOTIFY_BACKOFF", 0);
#endif
}

static int read_inotify_watch_limit(unsigned long *limit)
{
#ifdef __linux__
	struct strbuf value = STRBUF_INIT;
	int ret = -1;

	if (strbuf_read_file(&value,
			     "/proc/sys/fs/inotify/max_user_watches", 64) < 0)
		goto done;
	strbuf_trim(&value);
	if (git_parse_ulong(value.buf, limit))
		ret = 0;
done:
	strbuf_release(&value);
	return ret;
#else
	*limit = 0;
	return 0;
#endif
}

void fsmonitor_ipc__record_watch_limit_failure(const char *worktree_identity)
{
	struct lock_file lock = LOCK_INIT;
	struct strbuf contents = STRBUF_INIT;
	unsigned long limit;
	char *path;
	int fd;

	if (!watch_limit_backoff_enabled() || !worktree_identity ||
	    strlen(worktree_identity) != FSMONITOR_IPC_WORKTREE_ID_HEX ||
	    read_inotify_watch_limit(&limit))
		return;
	path = repo_git_path(the_repository, FSMONITOR_WATCH_LIMIT_MARKER);
	fd = hold_lock_file_for_update(&lock, path, LOCK_NO_DEREF);
	if (fd < 0)
		goto done;
	strbuf_addf(&contents, "%s%s\n%lu\n",
		    FSMONITOR_WATCH_LIMIT_MAGIC, worktree_identity, limit);
	if (fchmod(fd, 0600) ||
	    write_in_full(fd, contents.buf, contents.len) !=
		(ssize_t)contents.len ||
	    commit_lock_file(&lock))
		rollback_lock_file(&lock);
done:
	strbuf_release(&contents);
	free(path);
}

void fsmonitor_ipc__clear_watch_limit_failure(void)
{
	char *path;

	if (!watch_limit_backoff_enabled())
		return;
	path = repo_git_path(the_repository, FSMONITOR_WATCH_LIMIT_MARKER);
	unlink(path);
	free(path);
}

int fsmonitor_ipc__watch_limit_backoff(struct repository *r)
{
	struct strbuf contents = STRBUF_INIT;
	struct strbuf identity = STRBUF_INIT;
	struct stat st;
	const char *recorded_identity, *recorded_limit;
	unsigned long limit, current_limit;
	time_t now;
	char *path, *identity_end, *limit_end;
	int fd, ret = 0;

	if (!watch_limit_backoff_enabled())
		return 0;
	path = repo_git_path(r, FSMONITOR_WATCH_LIMIT_MARKER);
	fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		goto done;
	if (fstat(fd, &st) || !S_ISREG(st.st_mode) ||
	    st.st_uid != geteuid() || st.st_nlink != 1 ||
	    (st.st_mode & 077) || st.st_size < 0 || st.st_size > 256)
		goto close_fd;
	now = time(NULL);
	if (now < st.st_mtime ||
	    now - st.st_mtime > FSMONITOR_WATCH_LIMIT_BACKOFF_SECONDS)
		goto clear_marker;
	if (strbuf_read(&contents, fd, st.st_size) != st.st_size ||
	    !skip_prefix(contents.buf, FSMONITOR_WATCH_LIMIT_MAGIC,
			 &recorded_identity) ||
	    !(identity_end = strchr(contents.buf +
				    strlen(FSMONITOR_WATCH_LIMIT_MAGIC), '\n')))
		goto close_fd;
	*identity_end = '\0';
	recorded_limit = identity_end + 1;
	if (!(limit_end = strchr(identity_end + 1, '\n')) || limit_end[1])
		goto close_fd;
	*limit_end = '\0';
	if (!git_parse_ulong(recorded_limit, &limit) ||
	    read_inotify_watch_limit(&current_limit))
		goto close_fd;
	if (limit != current_limit)
		goto clear_marker;
	if (fsmonitor_ipc__get_worktree_identity(r, &identity))
		goto close_fd;
	if (strcmp(recorded_identity, identity.buf)) {
#ifndef __linux__
		if (!git_env_bool("GIT_TEST_FSMONITOR_INOTIFY_BACKOFF", 0) ||
		    strcmp(recorded_identity, "test-worktree"))
#endif
			goto close_fd;
	}
	if (fsmonitor_ipc__get_state() == IPC_STATE__LISTENING)
		goto clear_marker;
	ret = 1;
	goto close_fd;

clear_marker:
	unlink(path);
close_fd:
	close(fd);
done:
	strbuf_release(&identity);
	strbuf_release(&contents);
	free(path);
	return ret;
}
#else
void fsmonitor_ipc__record_watch_limit_failure(
	const char *worktree_identity UNUSED)
{
}

void fsmonitor_ipc__clear_watch_limit_failure(void)
{
}

int fsmonitor_ipc__watch_limit_backoff(struct repository *r UNUSED)
{
	return 0;
}
#endif

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
			    enum ipc_active_state *state_out, int quietly)
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
		if (quietly)
			ret = ipc_client_send_command_to_connection_gently(
				connection, command, strlen(command), answer);
		else
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
				&answer, NULL, 1) &&
		has_capability(&answer, FSMONITOR_IPC_QUERY_VERSION);
	strbuf_release(&answer);
	return ret;
}

static int server_supports_required_capabilities(void)
{
#ifdef __APPLE__
	struct strbuf answer = STRBUF_INIT;
	int ret;

	ret = !try_send_command(FSMONITOR_IPC_CAPABILITY_COMMAND,
				&answer, NULL, 1) &&
		has_capability(&answer, FSMONITOR_IPC_QUERY_VERSION) &&
		has_capability(&answer,
			       FSMONITOR_IPC_DIR_METADATA_CAPABILITY);
	strbuf_release(&answer);
	return ret;
#else
	return server_supports_bound_queries();
#endif
}

#ifdef __APPLE__
static int query_identifies_filtered_daemon(const char *token,
					   const struct strbuf *answer)
{
	static const char prefix[] =
		"builtin:" FSMONITOR_IPC_DIR_METADATA_TOKEN_PREFIX;
	const char *end = memchr(answer->buf, '\0', answer->len);

	return starts_with(token, prefix) && end &&
		(size_t)(end - answer->buf) >= sizeof(prefix) - 1 &&
		!memcmp(answer->buf, prefix, sizeof(prefix) - 1);
}
#endif

#if defined(__APPLE__) || defined(__linux__)
static int legacy_peer_credentials(
	struct ipc_client_connection *connection, pid_t *pid)
{
#ifdef __APPLE__
	uid_t uid;
	gid_t gid;
	socklen_t size = sizeof(*pid);

	if (getpeereid(connection->fd, &uid, &gid) ||
	    uid != geteuid() ||
	    getsockopt(connection->fd, SOL_LOCAL, LOCAL_PEERPID,
		       pid, &size) || size != sizeof(*pid))
		return 0;
#else
	struct ucred peer;
	socklen_t size = sizeof(peer);

	if (getsockopt(connection->fd, SOL_SOCKET, SO_PEERCRED,
		       &peer, &size) || size != sizeof(peer) ||
	    peer.uid != geteuid())
		return 0;
	*pid = peer.pid;
#endif
	return *pid > 0;
}

static int legacy_peer_start_identity(pid_t pid, struct strbuf *identity)
{
#ifdef __APPLE__
	struct proc_bsdinfo info;

	if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0,
			 &info, sizeof(info)) != sizeof(info) ||
	    info.pbi_pid != (uint32_t)pid ||
	    info.pbi_uid != geteuid())
		return 0;
	strbuf_addf(identity, "%"PRIu64".%"PRIu64,
		    info.pbi_start_tvsec, info.pbi_start_tvusec);
#else
	struct strbuf path = STRBUF_INIT;
	struct strbuf stat = STRBUF_INIT;
	const char *value, *end;
	int valid = 0;

	strbuf_addf(&path, "/proc/%"PRIuMAX"/stat", (uintmax_t)pid);
	if (strbuf_read_file(&stat, path.buf, 4096) < 0 ||
	    !(value = strrchr(stat.buf, ')')) ||
	    value[1] != ' ')
		goto done;
	value += 2;
	for (int field = 3; field < 22; field++) {
		value = strchr(value, ' ');
		if (!value)
			goto done;
		while (*value == ' ')
			value++;
	}
	end = strchr(value, ' ');
	if (!end || end == value)
		goto done;
	for (const char *p = value; p < end; p++)
		if (!isdigit(*p))
			goto done;
	strbuf_add(identity, value, end - value);
	valid = 1;
done:
	strbuf_release(&path);
	strbuf_release(&stat);
	return valid;
#endif
	return 1;
}

#ifdef __APPLE__
static int legacy_peer_watches_worktree(
	pid_t pid, const char *worktree, const struct stat *root)
{
	struct proc_fdinfo *fds = NULL;
	int size, bytes, matches = 0;

	size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
	if (size <= 0 || size > 1024 * 1024 -
			      16 * (int)sizeof(*fds))
		return 0;
	size += 16 * sizeof(*fds);
	fds = xmalloc(size);
	bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, size);
	if (bytes < 0 || bytes % sizeof(*fds))
		goto done;
	for (int i = 0; i < bytes / (int)sizeof(*fds); i++) {
		struct vnode_fdinfowithpath vnode;
		const struct vinfo_stat *stat;

		if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE ||
		    proc_pidfdinfo(pid, fds[i].proc_fd,
				   PROC_PIDFDVNODEPATHINFO,
				   &vnode, sizeof(vnode)) != sizeof(vnode))
			continue;
		stat = &vnode.pvip.vip_vi.vi_stat;
		if ((uintmax_t)stat->vst_dev == (uintmax_t)root->st_dev &&
		    (uintmax_t)stat->vst_ino == (uintmax_t)root->st_ino &&
		    !strcmp(vnode.pvip.vip_path, worktree)) {
			matches = 1;
			break;
		}
	}
done:
	free(fds);
	return matches;
}
#else
static int legacy_peer_watches_worktree(
	pid_t pid, const char *worktree UNUSED, const struct stat *root)
{
	struct strbuf directory = STRBUF_INIT;
	struct strbuf path = STRBUF_INIT;
	struct strbuf target = STRBUF_INIT;
	struct strbuf line = STRBUF_INIT;
	uintmax_t device = ((uintmax_t)major(root->st_dev) << 20) |
		(uintmax_t)minor(root->st_dev);
	DIR *fds = NULL;
	struct dirent *entry;
	int matches = 0;

	strbuf_addf(&directory, "/proc/%"PRIuMAX"/fd", (uintmax_t)pid);
	fds = opendir(directory.buf);
	if (!fds)
		goto done;
	while ((entry = readdir(fds)) != NULL) {
		FILE *info;

		if (!strcmp(entry->d_name, ".") ||
		    !strcmp(entry->d_name, ".."))
			continue;
		strbuf_reset(&path);
		strbuf_addf(&path, "%s/%s", directory.buf, entry->d_name);
		strbuf_reset(&target);
		if (strbuf_readlink(&target, path.buf, 32) < 0 ||
		    strcmp(target.buf, "anon_inode:inotify"))
			continue;
		strbuf_reset(&path);
		strbuf_addf(&path, "/proc/%"PRIuMAX"/fdinfo/%s",
			    (uintmax_t)pid, entry->d_name);
		info = fopen(path.buf, "r");
		if (!info)
			continue;
		while (!strbuf_getline_lf(&line, info)) {
			uintmax_t inode, source_device;
			unsigned int watch;

			if (!starts_with(line.buf, "inotify wd:1 "))
				continue;
			if (sscanf(line.buf,
				   "inotify wd:%x ino:%"SCNxMAX" sdev:%"SCNxMAX,
				   &watch, &inode, &source_device) == 3 &&
			    watch == 1 && inode == (uintmax_t)root->st_ino &&
			    source_device == device)
				matches = 1;
			break;
		}
		fclose(info);
		if (matches)
			break;
	}
done:
	if (fds)
		closedir(fds);
	strbuf_release(&directory);
	strbuf_release(&path);
	strbuf_release(&target);
	strbuf_release(&line);
	return matches;
}
#endif

static int legacy_identity_cache_matches(
	const char *path, const struct strbuf *expected)
{
	struct strbuf actual = STRBUF_INIT;
	struct stat st;
	int fd, matches = 0;

	fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return 0;
	if (!fstat(fd, &st) && S_ISREG(st.st_mode) &&
	    st.st_uid == geteuid() && !(st.st_mode & 022) &&
	    st.st_size >= 0 && (uintmax_t)st.st_size == expected->len &&
	    strbuf_read(&actual, fd, expected->len) == (ssize_t)expected->len)
		matches = !strbuf_cmp(&actual, expected);
	close(fd);
	strbuf_release(&actual);
	return matches;
}

static void cache_legacy_peer_identity(
	const char *path, const struct strbuf *identity)
{
	struct lock_file lock = LOCK_INIT;
	int fd = hold_lock_file_for_update(&lock, path, LOCK_NO_DEREF);

	if (fd < 0)
		return;
	if (fchmod(fd, 0600) ||
	    write_in_full(fd, identity->buf, identity->len) !=
		(ssize_t)identity->len ||
	    commit_lock_file(&lock))
		rollback_lock_file(&lock);
}

static int try_send_attested_legacy_query(
	const char *token, const struct strbuf *identity,
	struct strbuf *answer)
{
	struct ipc_client_connect_options options =
		IPC_CLIENT_CONNECT_OPTIONS_INIT;
	struct ipc_client_connection *connection = NULL;
	struct strbuf worktree = STRBUF_INIT;
	struct strbuf path = STRBUF_INIT;
	struct strbuf expected = STRBUF_INIT;
	struct strbuf peer_start = STRBUF_INIT;
	struct stat root, socket;
	pid_t pid;
	int cached, ret = -1;

	if (!token || !starts_with(token, "builtin:") ||
	    !repo_get_work_tree(the_repository) ||
	    !strbuf_realpath(&worktree,
			     repo_get_work_tree(the_repository), 0) ||
	    stat(worktree.buf, &root) || !S_ISDIR(root.st_mode))
		goto done;
	options.wait_if_busy = 1;
	if (ipc_client_try_connect(
		    fsmonitor_ipc__get_path(the_repository),
		    &options, &connection) != IPC_STATE__LISTENING ||
	    !legacy_peer_credentials(connection, &pid) ||
	    !legacy_peer_start_identity(pid, &peer_start) ||
	    lstat(fsmonitor_ipc__get_path(the_repository), &socket) ||
	    !S_ISSOCK(socket.st_mode))
		goto done;
	strbuf_addf(&path, "%s.legacy-identity",
		    fsmonitor_ipc__get_path(the_repository));
	strbuf_addf(&expected,
		    "v1\n%s\n%"PRIuMAX"\n%"PRIuMAX"\n%s\n%"PRIuMAX"\n%"PRIuMAX"\n",
		    identity->buf, (uintmax_t)geteuid(), (uintmax_t)pid,
		    peer_start.buf,
		    (uintmax_t)socket.st_dev, (uintmax_t)socket.st_ino);
	cached = legacy_identity_cache_matches(path.buf, &expected);
	if (!cached &&
	    !legacy_peer_watches_worktree(pid, worktree.buf, &root))
		goto done;
	if (!cached)
		cache_legacy_peer_identity(path.buf, &expected);
	trace2_data_intmax("fsm_client", NULL,
			   cached ? "query/legacy-peer-cached" :
				    "query/legacy-peer-authenticated", 1);
	ret = ipc_client_send_command_to_connection_gently(
		connection, token, strlen(token), answer);
done:
	ipc_client_close_connection(connection);
	strbuf_release(&worktree);
	strbuf_release(&path);
	strbuf_release(&expected);
	strbuf_release(&peer_start);
	return ret;
}
#else
static int try_send_attested_legacy_query(
	const char *token UNUSED, const struct strbuf *identity UNUSED,
	struct strbuf *answer UNUSED)
{
	return -1;
}
#endif

static int wait_for_daemon_exit(const struct stat *original_socket)
{
	uintmax_t elapsed_ms = 0;
	uintmax_t timeout_ms = (uintmax_t)get_start_timeout() * 1000;

	while (fsmonitor_ipc__get_state() == IPC_STATE__LISTENING) {
		if (original_socket) {
			struct stat current_socket;

			if (!lstat(fsmonitor_ipc__get_path(the_repository),
				   &current_socket) &&
			    (current_socket.st_dev != original_socket->st_dev ||
			     current_socket.st_ino != original_socket->st_ino))
				return 1;
		}
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
	unsigned int restart_attempts = 0;
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
		if (server_supports_required_capabilities())
			ret = 0;
		goto done;
	}
	have_lock = 1;

	trace2_data_intmax("fsm_client", NULL,
			   "query/incompatible-daemon", 1);
	while (restart_attempts++ < 32) {
		struct stat socket_stat;
		const struct stat *original_socket = NULL;
		int wait_result;

		/* Another client may have replaced the daemon while we waited. */
		if (server_supports_required_capabilities())
			goto success;
		if (!lstat(fsmonitor_ipc__get_path(the_repository),
			   &socket_stat))
			original_socket = &socket_stat;
		if (try_send_command("quit", &answer, NULL, 1)) {
			/*
			 * The failed connection may already have been replaced.
			 * Re-read its state before abandoning the upgrade.
			 */
			if (fsmonitor_ipc__get_state() == IPC_STATE__LISTENING) {
				if (server_supports_required_capabilities())
					ret = 0;
				goto done;
			}
		}

		wait_result = wait_for_daemon_exit(original_socket);
		if (wait_result < 0)
			goto done;
		if (wait_result > 0) {
			trace2_data_intmax("fsm_client", NULL,
					   "query/restart-raced", 1);
			continue;
		}

		/* The retried bound query still verifies any raced replacement. */
		if (fsmonitor_ipc__get_state() != IPC_STATE__LISTENING &&
		    spawn_daemon())
			goto done;
		goto success;
	}
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

#ifdef __APPLE__
static int spawn_daemon_serialized(void)
{
	struct strbuf lock_path = STRBUF_INIT;
	struct lock_file restart_lock = LOCK_INIT;
	uintmax_t timeout_ms = (uintmax_t)get_start_timeout() * 1000;
	long lock_timeout_ms = timeout_ms > LONG_MAX ?
		LONG_MAX : (long)timeout_ms;
	int have_lock = 0;
	int ret = -1;

	strbuf_addf(&lock_path, "%s.restart",
		    fsmonitor_ipc__get_path(the_repository));
	if (hold_lock_file_for_update_timeout(&restart_lock, lock_path.buf,
					      LOCK_NO_DEREF,
					      lock_timeout_ms) < 0) {
		if (fsmonitor_ipc__get_state() == IPC_STATE__LISTENING)
			ret = 0;
		goto done;
	}
	have_lock = 1;
	if (fsmonitor_ipc__get_state() == IPC_STATE__LISTENING ||
	    !spawn_daemon())
		ret = 0;

done:
	if (have_lock)
		rollback_lock_file(&restart_lock);
	strbuf_release(&lock_path);
	return ret;
}
#endif

int fsmonitor_ipc__send_query(const char *since_token,
			      struct strbuf *answer,
			      int *legacy_worktree_authenticated)
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

	if (legacy_worktree_authenticated)
		*legacy_worktree_authenticated = 0;
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
		ret = ipc_client_send_command_to_connection_gently(
			connection, command.buf, command.len, answer);
		ipc_client_close_connection(connection);
		connection = NULL;
		if (ret && lifecycle_attempts++ < FSMONITOR_RESTART_ATTEMPTS) {
			trace2_data_intmax("fsm_client", NULL,
					   "query/reconnect-after-failed-send", 1);
			/* Let a missing daemon enter normal startup without polling. */
			options.wait_if_not_found = 0;
			goto try_again;
		}

		trace2_data_intmax("fsm_client", NULL,
				   "query/response-length", answer->len);
#ifdef __APPLE__
		if (!ret && !query_identifies_filtered_daemon(tok, answer) &&
		    !server_supports_required_capabilities()) {
			strbuf_reset(answer);
			ret = -1;
			if (lifecycle_attempts++ >= FSMONITOR_RESTART_ATTEMPTS ||
			    restart_incompatible_daemon())
				goto done;
			options.wait_if_not_found = 1;
			goto try_again;
		}
#endif
		if (!ret && is_trivial_response(answer) &&
		    !server_supports_bound_queries()) {
			if (!try_send_attested_legacy_query(
				    tok, &identity, answer)) {
				if (legacy_worktree_authenticated)
					*legacy_worktree_authenticated = 1;
				ret = 0;
				goto done;
			}
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

#ifdef __APPLE__
		if (spawn_daemon_serialized())
#else
		if (spawn_daemon())
#endif
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
	int ret = try_send_command(c, answer, &state, 0);

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
