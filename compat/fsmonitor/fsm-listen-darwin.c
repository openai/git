#ifndef __clang__
#include <dispatch/dispatch.h>
#include "fsm-darwin-gcc.h"
#else
#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>

#ifndef AVAILABLE_MAC_OS_X_VERSION_10_13_AND_LATER
/*
 * This enum value was added in 10.13 to:
 *
 * /Applications/Xcode.app/Contents/Developer/Platforms/ \
 *    MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/ \
 *    Library/Frameworks/CoreServices.framework/Frameworks/ \
 *    FSEvents.framework/Versions/Current/Headers/FSEvents.h
 *
 * If we're compiling against an older SDK, this symbol won't be
 * present.  Silently define it here so that we don't have to ifdef
 * the logging or masking below.  This should be harmless since older
 * versions of macOS won't ever emit this FS event anyway.
 */
#define kFSEventStreamEventFlagItemCloned         0x00400000
#endif
#endif

#include "git-compat-util.h"
#include "fsmonitor.h"
#include "fsm-listen.h"
#include "fsmonitor--daemon.h"
#include "fsmonitor-path-utils.h"
#include "gettext.h"
#include "parse.h"
#include "simple-ipc.h"
#include "string-list.h"
#include "trace.h"
#include "trace2.h"

#define FSMONITOR_FLUSH_TIMEOUT_MS 1000

struct fsm_listen_data
{
	struct fsmonitor_daemon_state *state;
	CFStringRef cfsr_worktree_path;
	CFStringRef cfsr_gitdir_path;
	CFStringRef cfsr_event_path_key;
	CFStringRef cfsr_event_inode_key;

	CFArrayRef cfar_paths_to_watch;
	int nr_paths_watching;

	FSEventStreamRef stream;

	dispatch_queue_t dq;
	pthread_cond_t dq_finished;
	pthread_mutex_t dq_lock;

	pthread_t flush_thread;
	pthread_cond_t flush_requested_cond;
	pthread_cond_t flush_finished_cond;
	pthread_mutex_t flush_lock;
	uint64_t flush_requested;
	uint64_t flush_finished;
	enum flush_worker_state {
		FLUSH_WORKER_NOT_STARTED = 0,
		FLUSH_WORKER_RUNNING,
		FLUSH_WORKER_STOPPING,
		FLUSH_WORKER_FAILED,
		FLUSH_WORKER_STOPPED,
	} flush_state;
	unsigned long flush_timeout_ms;
	unsigned long test_flush_delay_ms;
	unsigned long test_flush_coalesce_delay_ms;
	char *test_defer_path;
	struct fsmonitor_batch *test_deferred_batch;
	uint64_t test_deferred_generation;
	unsigned long test_defer_delay_ms;

	enum shutdown_style {
		SHUTDOWN_EVENT = 0,
		FORCE_SHUTDOWN,
		FORCE_ERROR_STOP,
	} shutdown_style;

	unsigned int stream_scheduled:1;
	unsigned int stream_started:1;
	unsigned int dq_sync_initialized:1;
	unsigned int shutdown_requested:1;
	unsigned int flush_sync_initialized:1;
	unsigned int flush_thread_created:1;
	unsigned int test_deferred_published:1;
	unsigned int test_flush_bypass:1;
	unsigned int test_cookie_delayed:1;
	unsigned long test_cookie_delay_ms;
};

static void publish_test_deferred_batch(struct fsm_listen_data *data)
{
	struct fsmonitor_batch *batch;
	uint64_t generation;

	if (data->test_defer_delay_ms)
		sleep_millisec(data->test_defer_delay_ms);

	pthread_mutex_lock(&data->flush_lock);
	batch = data->test_deferred_batch;
	generation = data->test_deferred_generation;
	data->test_deferred_batch = NULL;
	data->test_deferred_generation = 0;
	if (batch)
		data->test_deferred_published = 1;
	pthread_mutex_unlock(&data->flush_lock);

	if (!batch)
		return;

	trace_printf_key(&trace_fsmonitor,
			 "test-publish-deferred-path-at-provider-fence");
	if (!fsmonitor_publish_if_current_generation(data->state, batch,
						     generation))
		trace_printf_key(&trace_fsmonitor,
				 "test-discard-deferred-path-after-token-reset");
}

static void discard_test_deferred_batch(struct fsm_listen_data *data)
{
	struct fsmonitor_batch *batch;

	pthread_mutex_lock(&data->flush_lock);
	batch = data->test_deferred_batch;
	data->test_deferred_batch = NULL;
	data->test_deferred_generation = 0;
	pthread_mutex_unlock(&data->flush_lock);

	fsmonitor_batch__free_list(batch);
}

static void drain_dispatch_queue(void *ctx UNUSED)
{
}

static void *flush_worker_proc(void *ctx)
{
	struct fsm_listen_data *data = ctx;

	trace2_thread_start("fsm-flush");
	pthread_mutex_lock(&data->flush_lock);
	for (;;) {
		uint64_t requested;
		uint64_t previously_finished;

		while (data->flush_requested == data->flush_finished &&
		       data->flush_state == FLUSH_WORKER_RUNNING)
			pthread_cond_wait(&data->flush_requested_cond,
					  &data->flush_lock);
		if (data->flush_state != FLUSH_WORKER_RUNNING)
			break;
		if (data->test_flush_coalesce_delay_ms) {
			pthread_mutex_unlock(&data->flush_lock);
			sleep_millisec(data->test_flush_coalesce_delay_ms);
			pthread_mutex_lock(&data->flush_lock);
			if (data->flush_state != FLUSH_WORKER_RUNNING)
				break;
		}

		requested = data->flush_requested;
		previously_finished = data->flush_finished;
		pthread_mutex_unlock(&data->flush_lock);

		trace_printf_key(&trace_fsmonitor,
				 "Darwin provider fence begin request=%"PRIu64
				 " coalesced=%"PRIu64,
				 requested, requested - previously_finished);
		trace2_data_intmax("fsmonitor", NULL,
				   "darwin-fence/coalesced",
				   requested - previously_finished);
		trace2_data_intmax("fsmonitor", NULL,
				   "darwin-fence/count", 1);
		trace2_region_enter("fsmonitor", "darwin-flush-sync",
				    NULL);
		if (data->test_flush_delay_ms)
			sleep_millisec(data->test_flush_delay_ms);
		FSEventStreamFlushSync(data->stream);
		/*
		 * FlushSync guarantees that callbacks for earlier provider events
		 * have been invoked, but a callback dispatched onto our serial queue
		 * may still be running.  Queue a synchronous no-op behind those
		 * callbacks so that their batches are published before the fence is
		 * reported complete.
		 */
		dispatch_sync_f(data->dq, NULL, drain_dispatch_queue);
		trace2_region_leave("fsmonitor", "darwin-flush-sync",
				    NULL);
		publish_test_deferred_batch(data);
		trace_printf_key(&trace_fsmonitor,
				 "Darwin provider fence complete request=%"PRIu64,
				 requested);

		pthread_mutex_lock(&data->flush_lock);
		if (data->flush_finished < requested)
			data->flush_finished = requested;
		pthread_cond_broadcast(&data->flush_finished_cond);
	}
	if (data->flush_state == FLUSH_WORKER_STOPPING)
		data->flush_state = FLUSH_WORKER_STOPPED;
	pthread_cond_broadcast(&data->flush_finished_cond);
	pthread_mutex_unlock(&data->flush_lock);
	trace2_thread_exit();
	return NULL;
}

static int start_flush_worker(struct fsm_listen_data *data)
{
	pthread_mutex_lock(&data->flush_lock);
	if (data->flush_state != FLUSH_WORKER_NOT_STARTED)
		BUG("unexpected Darwin provider fence worker state");
	data->flush_state = FLUSH_WORKER_RUNNING;
	pthread_mutex_unlock(&data->flush_lock);

	if (pthread_create(&data->flush_thread, NULL,
			   flush_worker_proc, data)) {
		pthread_mutex_lock(&data->flush_lock);
		data->flush_state = FLUSH_WORKER_STOPPED;
		pthread_mutex_unlock(&data->flush_lock);
		return -1;
	}
	data->flush_thread_created = 1;
	return 0;
}

static int begin_flush_shutdown(struct fsm_listen_data *data)
{
	int in_flight;

	if (!data || !data->flush_sync_initialized)
		return 0;

	pthread_mutex_lock(&data->flush_lock);
	in_flight = data->flush_state == FLUSH_WORKER_FAILED;
	if (data->flush_state == FLUSH_WORKER_RUNNING) {
		in_flight = data->flush_finished < data->flush_requested;
		data->flush_state = in_flight ? FLUSH_WORKER_FAILED :
			FLUSH_WORKER_STOPPING;
	}
	pthread_cond_broadcast(&data->flush_requested_cond);
	pthread_cond_broadcast(&data->flush_finished_cond);
	pthread_mutex_unlock(&data->flush_lock);
	return in_flight;
}

static void stop_flush_worker(struct fsm_listen_data *data)
{
	if (!data->flush_thread_created)
		return;

	/*
	 * FlushSync has no cancellation API.  If shutdown races an in-flight
	 * fence, let the main thread fail-stop the process rather than joining
	 * a provider call which may never return or tearing down beneath it.
	 */
	if (begin_flush_shutdown(data)) {
		trace_printf_key(&trace_fsmonitor,
				 "Darwin provider fence abandoned during shutdown");
		return;
	}

	pthread_join(data->flush_thread, NULL);
	data->flush_thread_created = 0;
	pthread_mutex_lock(&data->flush_lock);
	if (data->flush_state != FLUSH_WORKER_STOPPED)
		BUG("Darwin provider fence worker did not stop cleanly");
	pthread_mutex_unlock(&data->flush_lock);
}

static void log_flags_set(const char *path, const FSEventStreamEventFlags flag)
{
	struct strbuf msg = STRBUF_INIT;

	if (flag & kFSEventStreamEventFlagMustScanSubDirs)
		strbuf_addstr(&msg, "MustScanSubDirs|");
	if (flag & kFSEventStreamEventFlagUserDropped)
		strbuf_addstr(&msg, "UserDropped|");
	if (flag & kFSEventStreamEventFlagKernelDropped)
		strbuf_addstr(&msg, "KernelDropped|");
	if (flag & kFSEventStreamEventFlagEventIdsWrapped)
		strbuf_addstr(&msg, "EventIdsWrapped|");
	if (flag & kFSEventStreamEventFlagHistoryDone)
		strbuf_addstr(&msg, "HistoryDone|");
	if (flag & kFSEventStreamEventFlagRootChanged)
		strbuf_addstr(&msg, "RootChanged|");
	if (flag & kFSEventStreamEventFlagMount)
		strbuf_addstr(&msg, "Mount|");
	if (flag & kFSEventStreamEventFlagUnmount)
		strbuf_addstr(&msg, "Unmount|");
	if (flag & kFSEventStreamEventFlagItemChangeOwner)
		strbuf_addstr(&msg, "ItemChangeOwner|");
	if (flag & kFSEventStreamEventFlagItemCreated)
		strbuf_addstr(&msg, "ItemCreated|");
	if (flag & kFSEventStreamEventFlagItemFinderInfoMod)
		strbuf_addstr(&msg, "ItemFinderInfoMod|");
	if (flag & kFSEventStreamEventFlagItemInodeMetaMod)
		strbuf_addstr(&msg, "ItemInodeMetaMod|");
	if (flag & kFSEventStreamEventFlagItemIsDir)
		strbuf_addstr(&msg, "ItemIsDir|");
	if (flag & kFSEventStreamEventFlagItemIsFile)
		strbuf_addstr(&msg, "ItemIsFile|");
	if (flag & kFSEventStreamEventFlagItemIsHardlink)
		strbuf_addstr(&msg, "ItemIsHardlink|");
	if (flag & kFSEventStreamEventFlagItemIsLastHardlink)
		strbuf_addstr(&msg, "ItemIsLastHardlink|");
	if (flag & kFSEventStreamEventFlagItemIsSymlink)
		strbuf_addstr(&msg, "ItemIsSymlink|");
	if (flag & kFSEventStreamEventFlagItemModified)
		strbuf_addstr(&msg, "ItemModified|");
	if (flag & kFSEventStreamEventFlagItemRemoved)
		strbuf_addstr(&msg, "ItemRemoved|");
	if (flag & kFSEventStreamEventFlagItemRenamed)
		strbuf_addstr(&msg, "ItemRenamed|");
	if (flag & kFSEventStreamEventFlagItemXattrMod)
		strbuf_addstr(&msg, "ItemXattrMod|");
	if (flag & kFSEventStreamEventFlagOwnEvent)
		strbuf_addstr(&msg, "OwnEvent|");
	if (flag & kFSEventStreamEventFlagItemCloned)
		strbuf_addstr(&msg, "ItemCloned|");

	trace_printf_key(&trace_fsmonitor, "fsevent: '%s', flags=0x%x %s",
			 path, flag, msg.buf);

	strbuf_release(&msg);
}

static int ef_is_root_changed(const FSEventStreamEventFlags ef)
{
	return (ef & kFSEventStreamEventFlagRootChanged);
}

static int ef_is_root_delete(const FSEventStreamEventFlags ef)
{
	return (ef & kFSEventStreamEventFlagItemIsDir &&
		ef & kFSEventStreamEventFlagItemRemoved);
}

static int ef_is_root_renamed(const FSEventStreamEventFlags ef)
{
	return (ef & kFSEventStreamEventFlagItemIsDir &&
		ef & kFSEventStreamEventFlagItemRenamed);
}

static int ef_is_dropped(const FSEventStreamEventFlags ef)
{
	return (ef & kFSEventStreamEventFlagMustScanSubDirs ||
		ef & kFSEventStreamEventFlagKernelDropped ||
		ef & kFSEventStreamEventFlagUserDropped);
}

static int ef_is_hardlink(const FSEventStreamEventFlags ef)
{
	return ef & (kFSEventStreamEventFlagItemIsHardlink |
		     kFSEventStreamEventFlagItemIsLastHardlink);
}

static int ef_ignore_dir_metadata(const FSEventStreamEventFlags ef)
{
	static const FSEventStreamEventFlags required =
		kFSEventStreamEventFlagItemIsDir |
		kFSEventStreamEventFlagItemInodeMetaMod;
	static const FSEventStreamEventFlags allowed =
		kFSEventStreamEventFlagItemIsDir |
		kFSEventStreamEventFlagItemInodeMetaMod |
		kFSEventStreamEventFlagItemCreated |
		kFSEventStreamEventFlagItemXattrMod;

	return (ef & required) == required && !(ef & ~allowed);
}

/*
 * If an `xattr` change is the only reason we received this event,
 * then silently ignore it.  Git doesn't care about xattr's.  We
 * have to be careful here because the kernel can combine multiple
 * events for a single path.  And because events always have certain
 * bits set, such as `ItemIsFile` or `ItemIsDir`.
 *
 * Return 1 if we should ignore it.
 */
static int ef_ignore_xattr(const FSEventStreamEventFlags ef)
{
	static const FSEventStreamEventFlags mask =
		kFSEventStreamEventFlagItemChangeOwner |
		kFSEventStreamEventFlagItemCreated |
		kFSEventStreamEventFlagItemFinderInfoMod |
		kFSEventStreamEventFlagItemInodeMetaMod |
		kFSEventStreamEventFlagItemModified |
		kFSEventStreamEventFlagItemRemoved |
		kFSEventStreamEventFlagItemRenamed |
		kFSEventStreamEventFlagItemXattrMod |
		kFSEventStreamEventFlagItemCloned;

	return ((ef & mask) == kFSEventStreamEventFlagItemXattrMod);
}

/*
 * On MacOS we have to adjust for Unicode composition insensitivity
 * (where NFC and NFD spellings are not respected).  The different
 * spellings are essentially aliases regardless of how the path is
 * actually stored on the disk.
 *
 * This is related to "core.precomposeUnicode" (which wants to try
 * to hide NFD completely and treat everything as NFC).  Here, we
 * don't know what the value the client has (or will have) for this
 * config setting when they make a query, so assume the worst and
 * emit both when the OS gives us an NFD path.
 */
static void my_add_path(struct fsmonitor_batch *batch, const char *path)
{
	char *composed;

	/* add the NFC or NFD path as received from the OS */
	fsmonitor_batch__add_path(batch, path);

	/* if NFD, also add the corresponding NFC spelling */
	composed = (char *)precompose_string_if_needed(path);
	if (!composed || composed == path)
		return;

	fsmonitor_batch__add_path(batch, composed);
	free(composed);
}


static void fsevent_callback(ConstFSEventStreamRef streamRef UNUSED,
			     void *ctx,
			     size_t num_of_events,
			     void *event_paths,
			     const FSEventStreamEventFlags event_flags[],
			     const FSEventStreamEventId event_ids[] UNUSED)
{
	struct fsmonitor_daemon_state *state = ctx;
	struct fsm_listen_data *data = state->listen_data;
	CFArrayRef events = event_paths;
	struct fsmonitor_batch *batch = NULL;
	struct string_list cookie_list = STRING_LIST_INIT_DUP;
	const char *path_k;
	const char *slash;
	char *resolved = NULL;
	struct strbuf tmp = STRBUF_INIT;
	struct strbuf event_path = STRBUF_INIT;
	enum fsmonitor_path_type path_type;

	/*
	 * Build a list of all filesystem changes into a private/local
	 * list and without holding any locks.
	 */
	for (size_t k = 0; k < num_of_events; k++) {
		CFDictionaryRef event = CFArrayGetValueAtIndex(events, k);
		CFStringRef path = event ?
			CFDictionaryGetValue(event, data->cfsr_event_path_key) :
			NULL;
		CFNumberRef inode = event ?
			CFDictionaryGetValue(event, data->cfsr_event_inode_key) :
			NULL;
		CFIndex path_size;
		int64_t file_id = 0;

		/*
		 * Extended events retain their inode even when their pathname has
		 * already been removed by the time this callback runs.
		 */
		if (!path)
			goto invalid_event;
		path_size = CFStringGetMaximumSizeForEncoding(
			CFStringGetLength(path), kCFStringEncodingUTF8);
		if (path_size < 0)
			goto invalid_event;
		strbuf_reset(&event_path);
		strbuf_grow(&event_path, path_size + 1);
		if (!CFStringGetCString(path, event_path.buf, path_size + 1,
					kCFStringEncodingUTF8))
			goto invalid_event;
		strbuf_setlen(&event_path, strlen(event_path.buf));

		free(resolved);
		resolved = fsmonitor__resolve_alias(event_path.buf, &state->alias);
		if (resolved)
			path_k = resolved;
		else
			path_k = event_path.buf;

		/*
		 * If you want to debug FSEvents, log them to GIT_TRACE_FSMONITOR.
		 * Please don't log them to Trace2.
		 *
		 * trace_printf_key(&trace_fsmonitor, "Path: '%s'", path_k);
		 */

		/*
		 * If event[k] is marked as dropped, we assume that we have
		 * lost sync with the filesystem and should flush our cached
		 * data.  We need to:
		 *
		 * [1] Abort/wake any client threads waiting for a cookie and
		 *     flush the cached state data (the current token), and
		 *     create a new token.
		 *
		 * [2] Discard the batch that we were locally building (since
		 *     they are conceptually relative to the just flushed
		 *     token).
		 */
		if (ef_is_dropped(event_flags[k])) {
			if (trace_pass_fl(&trace_fsmonitor))
				log_flags_set(path_k, event_flags[k]);

			fsmonitor_force_resync(state);
			fsmonitor_batch__free_list(batch);
			discard_test_deferred_batch(data);
			string_list_clear(&cookie_list, 0);
			batch = NULL;

			/*
			 * We assume that any events that we received
			 * in this callback after this dropped event
			 * may still be valid, so we continue rather
			 * than break.  (And just in case there is a
			 * delete of ".git" hiding in there.)
			 */
			continue;
		}

		if (ef_is_root_changed(event_flags[k])) {
			/*
			 * The spelling of the pathname of the root directory
			 * has changed.  This includes the name of the root
			 * directory itself or of any parent directory in the
			 * path.
			 *
			 * (There may be other conditions that throw this,
			 * but I couldn't find any information on it.)
			 *
			 * Force a shutdown now and avoid things getting
			 * out of sync.  The Unix domain socket is inside
			 * the .git directory and a spelling change will make
			 * it hard for clients to rendezvous with us.
			 */
			trace_printf_key(&trace_fsmonitor,
					 "event: root changed");
			goto force_shutdown;
		}

		if (ef_ignore_xattr(event_flags[k])) {
			trace_printf_key(&trace_fsmonitor,
					 "ignore-xattr: '%s', flags=0x%x",
					 path_k, event_flags[k]);
			continue;
		}

		path_type = fsmonitor_classify_path_absolute(state, path_k);
		if (ef_is_hardlink(event_flags[k]) &&
		    path_type == IS_WORKDIR_PATH) {
			/*
			 * The daemon never reads the index. Let an inode-aware client
			 * invalidate every tracked alias without disturbing unrelated
			 * ignored hardlinks. Missing inode data must remain fail-closed.
			 */
			if (trace_pass_fl(&trace_fsmonitor))
				log_flags_set(path_k, event_flags[k]);
			if (!batch)
				batch = fsmonitor_batch__new();
			if (!inode || !CFNumberGetValue(inode, kCFNumberSInt64Type,
						 &file_id) || !file_id) {
				my_add_path(batch, FSMONITOR_PATH_GLOBAL_INVALIDATE);
			} else {
				strbuf_reset(&tmp);
				strbuf_addf(&tmp, "%s%016"PRIx64,
					    FSMONITOR_PATH_HARDLINK_INODE_PREFIX,
					    (uint64_t)file_id);
				my_add_path(batch, tmp.buf);
			}
		}

		switch (path_type) {

		case IS_INSIDE_DOT_GIT_WITH_COOKIE_PREFIX:
		case IS_INSIDE_GITDIR_WITH_COOKIE_PREFIX:
			/* special case cookie files within .git or gitdir */

			/* Use just the filename of the cookie file. */
			slash = find_last_dir_sep(path_k);
			string_list_append(&cookie_list,
					   slash ? slash + 1 : path_k);
			break;

		case IS_INSIDE_DOT_GIT:
		case IS_INSIDE_GITDIR:
			/* ignore all other paths inside of .git or gitdir */
			break;

		case IS_DOT_GIT:
		case IS_GITDIR:
			/*
			 * If .git directory is deleted or renamed away,
			 * we have to quit.
			 */
			if (ef_is_root_delete(event_flags[k])) {
				trace_printf_key(&trace_fsmonitor,
						 "event: gitdir removed");
				goto force_shutdown;
			}
			if (ef_is_root_renamed(event_flags[k])) {
				trace_printf_key(&trace_fsmonitor,
						 "event: gitdir renamed");
				goto force_shutdown;
			}
			break;

		case IS_WORKDIR_PATH:
			/* try to queue normal pathnames */

			if (trace_pass_fl(&trace_fsmonitor))
				log_flags_set(path_k, event_flags[k]);
			if (ef_ignore_dir_metadata(event_flags[k])) {
				trace_printf_key(&trace_fsmonitor,
						 "ignore-dir-metadata: '%s', flags=0x%x",
						 path_k, event_flags[k]);
				break;
			}

			/*
			 * Because of the implicit "binning" (the
			 * kernel calls us at a given frequency) and
			 * de-duping (the kernel is free to combine
			 * multiple events for a given pathname), an
			 * individual fsevent could be marked as both
			 * a file and directory.  Add it to the queue
			 * with both spellings so that the client will
			 * know how much to invalidate/refresh.
			 */

			fsmonitor_format_worktree_paths(
				&tmp, path_k, state->path_worktree_watch.len,
				!!(event_flags[k] &
				   (kFSEventStreamEventFlagItemIsFile |
				    kFSEventStreamEventFlagItemIsSymlink)),
				!!(event_flags[k] &
				   kFSEventStreamEventFlagItemIsDir));
			for (const char *relative = tmp.buf;
			     relative < tmp.buf + tmp.len;
			     relative += strlen(relative) + 1) {
				int defer_for_test = 0;

				if (data->test_defer_path &&
				    !strcmp(relative, data->test_defer_path)) {
					uint64_t generation;

					pthread_mutex_lock(&state->main_lock);
					generation = state->token_generation;
					pthread_mutex_unlock(&state->main_lock);
					pthread_mutex_lock(&data->flush_lock);
					if (!data->test_deferred_published) {
						if (data->test_deferred_batch &&
						    data->test_deferred_generation !=
							generation) {
							fsmonitor_batch__free_list(
								data->test_deferred_batch);
							data->test_deferred_batch = NULL;
						}
						if (!data->test_deferred_batch) {
							data->test_deferred_batch =
								fsmonitor_batch__new();
							data->test_deferred_generation =
								generation;
						}
						my_add_path(data->test_deferred_batch,
							    relative);
						defer_for_test = 1;
					}
					pthread_mutex_unlock(&data->flush_lock);
				}
				if (defer_for_test) {
					trace_printf_key(&trace_fsmonitor,
							 "test-defer-path: '%s'",
							 relative);
				} else {
					if (!batch)
						batch = fsmonitor_batch__new();
					my_add_path(batch, relative);
				}
			}

			break;

		case IS_OUTSIDE_CONE:
		default:
			trace_printf_key(&trace_fsmonitor,
					 "ignoring '%s'", path_k);
			break;
		}
		continue;

invalid_event:
		fsmonitor_force_resync(state);
		fsmonitor_batch__free_list(batch);
		discard_test_deferred_batch(data);
		string_list_clear(&cookie_list, 0);
		batch = NULL;
	}

	free(resolved);
	if (cookie_list.nr && data->test_cookie_delay_ms &&
	    !data->test_cookie_delayed) {
		data->test_cookie_delayed = 1;
		sleep_millisec(data->test_cookie_delay_ms);
	}
	fsmonitor_publish(state, batch, &cookie_list);
	string_list_clear(&cookie_list, 0);
	strbuf_release(&tmp);
	strbuf_release(&event_path);
	return;

force_shutdown:
	free(resolved);
	fsmonitor_batch__free_list(batch);
	discard_test_deferred_batch(data);
	string_list_clear(&cookie_list, 0);
	strbuf_release(&tmp);
	strbuf_release(&event_path);

	pthread_mutex_lock(&data->dq_lock);
	data->shutdown_style = FORCE_SHUTDOWN;
	data->shutdown_requested = 1;
	pthread_cond_broadcast(&data->dq_finished);
	pthread_mutex_unlock(&data->dq_lock);

	strbuf_release(&tmp);
	return;
}

/*
 * In the call to `FSEventStreamCreate()` to setup our watch, the
 * `latency` argument determines the frequency of calls to our callback
 * with new FS events.  Too slow and events get dropped; too fast and
 * we burn CPU unnecessarily.  Since it is rather obscure, I don't
 * think this needs to be a config setting.  I've done extensive
 * testing on my systems and chosen the value below.  It gives good
 * results and I've not seen any dropped events.
 *
 * With a latency of 0.1, I was seeing lots of dropped events during
 * the "touch 100000" files test within t/perf/p7519, but with a
 * latency of 0.001 I did not see any dropped events.  So I'm going
 * to assume that this is the "correct" value.
 *
 * https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate
 */

int fsm_listen__ctor(struct fsmonitor_daemon_state *state)
{
	FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagNoDefer |
		kFSEventStreamCreateFlagWatchRoot |
		kFSEventStreamCreateFlagFileEvents |
		kFSEventStreamCreateFlagUseCFTypes |
		kFSEventStreamCreateFlagUseExtendedData;
	FSEventStreamContext ctx = {
		0,
		state,
		NULL,
		NULL,
		NULL
	};
	struct fsm_listen_data *data;
	const void *dir_array[2];

	CALLOC_ARRAY(data, 1);
	state->listen_data = data;
	data->state = state;
	data->test_cookie_delay_ms = git_env_ulong(
		"GIT_TEST_FSMONITOR_COOKIE_DELAY_MS", 0);
	data->test_flush_delay_ms = git_env_ulong(
		"GIT_TEST_FSMONITOR_FLUSH_SYNC_DELAY_MS", 0);
	data->test_flush_coalesce_delay_ms = git_env_ulong(
		"GIT_TEST_FSMONITOR_FLUSH_COALESCE_DELAY_MS", 0);
	data->test_flush_bypass = git_env_bool(
		"GIT_TEST_FSMONITOR_FLUSH_SYNC_BYPASS", 0);
	data->flush_timeout_ms = git_env_ulong(
		"GIT_TEST_FSMONITOR_FLUSH_SYNC_TIMEOUT_MS",
		FSMONITOR_FLUSH_TIMEOUT_MS);
	data->test_defer_path = xstrdup_or_null(getenv(
		"GIT_TEST_FSMONITOR_DEFER_PATH"));
	data->test_defer_delay_ms = git_env_ulong(
		"GIT_TEST_FSMONITOR_DEFER_PATH_DELAY_MS", 0);

	data->cfsr_event_path_key = CFStringCreateWithCString(
		NULL, "path", kCFStringEncodingUTF8);
	data->cfsr_event_inode_key = CFStringCreateWithCString(
		NULL, "fileID", kCFStringEncodingUTF8);
	if (!data->cfsr_event_path_key || !data->cfsr_event_inode_key)
		goto failed;

	data->cfsr_worktree_path = CFStringCreateWithCString(
		NULL, state->path_worktree_watch.buf, kCFStringEncodingUTF8);
	dir_array[data->nr_paths_watching++] = data->cfsr_worktree_path;

	if (state->nr_paths_watching > 1) {
		data->cfsr_gitdir_path = CFStringCreateWithCString(
			NULL, state->path_gitdir_watch.buf,
			kCFStringEncodingUTF8);
		dir_array[data->nr_paths_watching++] = data->cfsr_gitdir_path;
	}

	data->cfar_paths_to_watch = CFArrayCreate(NULL, dir_array,
						  data->nr_paths_watching,
						  NULL);
	data->stream = FSEventStreamCreate(NULL, fsevent_callback, &ctx,
					   data->cfar_paths_to_watch,
					   kFSEventStreamEventIdSinceNow,
					   0.001, flags);
	if (!data->stream)
		goto failed;

	pthread_mutex_init(&data->flush_lock, NULL);
	pthread_cond_init(&data->flush_requested_cond, NULL);
	pthread_cond_init(&data->flush_finished_cond, NULL);
	data->flush_sync_initialized = 1;
	pthread_mutex_init(&data->dq_lock, NULL);
	pthread_cond_init(&data->dq_finished, NULL);
	data->dq_sync_initialized = 1;

	return 0;

failed:
	error(_("Unable to create FSEventStream."));

	free(data->test_defer_path);
	FREE_AND_NULL(state->listen_data);
	return -1;
}

void fsm_listen__dtor(struct fsmonitor_daemon_state *state)
{
	struct fsm_listen_data *data;

	if (!state || !state->listen_data)
		return;

	data = state->listen_data;

	if (data->flush_thread_created)
		BUG("releasing FSEventStream with provider fence worker alive");
	if (data->stream) {
		if (data->stream_started)
			FSEventStreamStop(data->stream);
		if (data->stream_scheduled)
			FSEventStreamInvalidate(data->stream);
		/*
		 * Invalidation prevents new callbacks from being submitted.  A
		 * synchronous no-op on our serial queue then waits for every
		 * callback that was already submitted to finish before state owned
		 * by the daemon is released.
		 */
		if (data->dq)
			dispatch_sync_f(data->dq, NULL, drain_dispatch_queue);
		FSEventStreamRelease(data->stream);
	}

	if (data->dq)
		dispatch_release(data->dq);
	fsmonitor_batch__free_list(data->test_deferred_batch);
	free(data->test_defer_path);
	if (data->flush_sync_initialized) {
		pthread_cond_destroy(&data->flush_finished_cond);
		pthread_cond_destroy(&data->flush_requested_cond);
		pthread_mutex_destroy(&data->flush_lock);
	}
	if (data->dq_sync_initialized) {
		pthread_cond_destroy(&data->dq_finished);
		pthread_mutex_destroy(&data->dq_lock);
	}

	FREE_AND_NULL(state->listen_data);
}

void fsm_listen__stop_async(struct fsmonitor_daemon_state *state)
{
	struct fsm_listen_data *data;

	data = state->listen_data;

	pthread_mutex_lock(&data->dq_lock);
	data->shutdown_style = SHUTDOWN_EVENT;
	data->shutdown_requested = 1;
	pthread_cond_broadcast(&data->dq_finished);
	pthread_mutex_unlock(&data->dq_lock);
	begin_flush_shutdown(data);
}

enum fsm_listen_flush_result fsm_listen__flush_sync(
	struct fsmonitor_daemon_state *state)
{
	struct fsm_listen_data *data;
	struct timeval now;
	struct timespec deadline;
	uint64_t requested;
	int err = 0;
	enum fsm_listen_flush_result result = FSM_LISTEN_FLUSH_OK;

	if (!state || !(data = state->listen_data) ||
	    !data->flush_sync_initialized)
		return FSM_LISTEN_FLUSH_SHUTDOWN;

	if (data->test_flush_bypass) {
		trace_printf_key(&trace_fsmonitor,
				 "test-bypass-darwin-flush-sync");
		return FSM_LISTEN_FLUSH_OK;
	}

	pthread_mutex_lock(&data->flush_lock);
	if (data->flush_state == FLUSH_WORKER_FAILED) {
		result = FSM_LISTEN_FLUSH_TIMEOUT;
		goto done;
	}
	if (data->flush_state != FLUSH_WORKER_RUNNING) {
		result = FSM_LISTEN_FLUSH_SHUTDOWN;
		goto done;
	}

	requested = ++data->flush_requested;
	trace_printf_key(&trace_fsmonitor,
			 "Darwin provider fence requested request=%"PRIu64,
			 requested);
	trace2_data_intmax("fsmonitor", NULL,
			   "darwin-fence/request", requested);
	pthread_cond_signal(&data->flush_requested_cond);

	gettimeofday(&now, NULL);
	deadline.tv_sec = now.tv_sec + data->flush_timeout_ms / 1000;
	deadline.tv_nsec = now.tv_usec * 1000 +
		(data->flush_timeout_ms % 1000) * 1000000;
	if (deadline.tv_nsec >= 1000000000) {
		deadline.tv_sec++;
		deadline.tv_nsec -= 1000000000;
	}

	trace2_region_enter("fsmonitor", "darwin-fence-wait", NULL);
	while (data->flush_finished < requested &&
	       data->flush_state == FLUSH_WORKER_RUNNING && !err)
		err = pthread_cond_timedwait(&data->flush_finished_cond,
					     &data->flush_lock, &deadline);
	trace2_region_leave("fsmonitor", "darwin-fence-wait", NULL);

	if (data->flush_state == FLUSH_WORKER_FAILED) {
		result = FSM_LISTEN_FLUSH_TIMEOUT;
	} else if (data->flush_state != FLUSH_WORKER_RUNNING) {
		result = FSM_LISTEN_FLUSH_SHUTDOWN;
	} else if (data->flush_finished >= requested) {
		result = FSM_LISTEN_FLUSH_OK;
	} else if (err) {
		data->flush_state = FLUSH_WORKER_FAILED;
		pthread_cond_broadcast(&data->flush_requested_cond);
		pthread_cond_broadcast(&data->flush_finished_cond);
		trace2_data_intmax("fsmonitor", NULL,
				   "darwin-fence/timeout", 1);
		result = FSM_LISTEN_FLUSH_TIMEOUT;
	}

done:
	pthread_mutex_unlock(&data->flush_lock);
	return result;
}

int fsm_listen__flush_failed(struct fsmonitor_daemon_state *state)
{
	struct fsm_listen_data *data;
	int timed_out;

	if (!state || !(data = state->listen_data) ||
	    !data->flush_sync_initialized)
		return 0;

	pthread_mutex_lock(&data->flush_lock);
	timed_out = data->flush_state == FLUSH_WORKER_FAILED;
	pthread_mutex_unlock(&data->flush_lock);
	return timed_out;
}

void fsm_listen__loop(struct fsmonitor_daemon_state *state)
{
	struct fsm_listen_data *data;

	data = state->listen_data;

	data->dq = dispatch_queue_create("FSMonitor", NULL);

	FSEventStreamSetDispatchQueue(data->stream, data->dq);
	data->stream_scheduled = 1;

	pthread_mutex_lock(&data->dq_lock);
	if (data->shutdown_requested) {
		pthread_mutex_unlock(&data->dq_lock);
		return;
	}

	if (!FSEventStreamStart(data->stream)) {
		pthread_mutex_unlock(&data->dq_lock);
		error(_("Failed to start the FSEventStream"));
		goto force_error_stop_without_loop;
	}
	data->stream_started = 1;
	if (start_flush_worker(data)) {
		pthread_mutex_unlock(&data->dq_lock);
		error(_("Failed to start the FSEvents flush worker"));
		goto force_error_stop_without_loop;
	}

	/*
	 * Our fs event listener is now running, so it's safe to start
	 * serving client requests.
	 */
	ipc_server_start_async(state->ipc_server_data);

	while (!data->shutdown_requested)
		pthread_cond_wait(&data->dq_finished, &data->dq_lock);
	pthread_mutex_unlock(&data->dq_lock);

	stop_flush_worker(data);

	switch (data->shutdown_style) {
	case FORCE_ERROR_STOP:
		state->listen_error_code = -1;
		/* fall thru */
	case FORCE_SHUTDOWN:
		ipc_server_stop_async(state->ipc_server_data);
		/* fall thru */
	case SHUTDOWN_EVENT:
	default:
		break;
	}
	return;

force_error_stop_without_loop:
	state->listen_error_code = -1;
	ipc_server_stop_async(state->ipc_server_data);
	return;
}
