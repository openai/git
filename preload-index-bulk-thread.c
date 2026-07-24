#include "git-compat-util.h"

#include <sys/resource.h>

#include "preload-index-bulk.h"

#define PRELOAD_INDEX_BULK_OPEN_FD_CAP 128
#define PRELOAD_INDEX_BULK_OPEN_FD_RESERVE 16

static void queue_set_failed(struct preload_bulk_queue *queue)
{
	pthread_mutex_lock(&queue->mutex);
	queue->failed = 1;
	pthread_mutex_unlock(&queue->mutex);
}

static void enqueue_task(struct preload_bulk_scan *scan,
			 struct preload_bulk_task *task)
{
	struct preload_bulk_queue *queue = &scan->queue;

	pthread_mutex_lock(&queue->mutex);
	task->next = queue->head;
	queue->head = task;
	queue->pending++;
	pthread_cond_signal(&queue->cond);
	pthread_mutex_unlock(&queue->mutex);
}

static int reserve_open_fd(struct preload_bulk_queue *queue)
{
	int reserved = 0;

	pthread_mutex_lock(&queue->mutex);
	if (queue->open_fds < queue->open_fd_limit) {
		queue->open_fds++;
		reserved = 1;
	}
	pthread_mutex_unlock(&queue->mutex);
	return reserved;
}

static void release_open_fd(struct preload_bulk_queue *queue)
{
	pthread_mutex_lock(&queue->mutex);
	if (!queue->open_fds)
		BUG("bulk preload open-fd count underflow");
	queue->open_fds--;
	pthread_mutex_unlock(&queue->mutex);
}

void preload_bulk_schedule_directory(
	struct preload_bulk_worker *worker, int parent_fd,
	const struct preload_bulk_dir_identity *parent_identity,
	const struct preload_bulk_dir_identity *child_identity,
	const char *name, const char *path, size_t path_len)
{
	struct preload_bulk_scan *scan = worker->scan;
	struct preload_bulk_task *task;

	FLEX_ALLOC_MEM(task, path, path, path_len);
	if (parent_identity) {
		task->parent_identity = *parent_identity;
		task->has_parent_identity = 1;
	}
	if (child_identity) {
		task->child_identity = *child_identity;
		task->has_child_identity = 1;
	}
	task->fd = -1;
	if (reserve_open_fd(&scan->queue)) {
		task->reserved_fd = 1;
		task->fd = scan->backend->open_dir_at(worker, parent_fd, name);
		if (task->fd < 0) {
			int saved_errno = errno;

			task->reserved_fd = 0;
			release_open_fd(&scan->queue);
			if (saved_errno == EXDEV) {
				free(task);
				return;
			}
			if (saved_errno != EMFILE && saved_errno != ENFILE) {
				free(task);
				queue_set_failed(&scan->queue);
				return;
			}
		}
	}
	enqueue_task(scan, task);
}

static size_t preload_bulk_open_fd_limit(void)
{
	struct rlimit limit;
	rlim_t value;

	if (getrlimit(RLIMIT_NOFILE, &limit))
		return 1;
	if (limit.rlim_cur == RLIM_INFINITY)
		return PRELOAD_INDEX_BULK_OPEN_FD_CAP;
	if (limit.rlim_cur <= PRELOAD_INDEX_BULK_OPEN_FD_RESERVE)
		return 1;
	value = limit.rlim_cur - PRELOAD_INDEX_BULK_OPEN_FD_RESERVE;
	if (value > PRELOAD_INDEX_BULK_OPEN_FD_CAP)
		value = PRELOAD_INDEX_BULK_OPEN_FD_CAP;
	return value;
}

static int queue_init(struct preload_bulk_queue *queue)
{
	memset(queue, 0, sizeof(*queue));
#if HAVE_THREADS
	if (pthread_mutex_init(&queue->mutex, NULL))
		return -1;
	if (pthread_cond_init(&queue->cond, NULL)) {
		pthread_mutex_destroy(&queue->mutex);
		return -1;
	}
#endif
	queue->open_fd_limit = preload_bulk_open_fd_limit();
	return 0;
}

static void queue_release(struct preload_bulk_queue *queue)
{
	if (queue->head || queue->pending || queue->open_fds)
		BUG("releasing non-empty bulk preload queue");
#if HAVE_THREADS
	pthread_cond_destroy(&queue->cond);
	pthread_mutex_destroy(&queue->mutex);
#endif
	memset(queue, 0, sizeof(*queue));
}

static void *preload_bulk_worker_main(void *data)
{
	struct preload_bulk_worker *worker = data;
	struct preload_bulk_queue *queue = &worker->scan->queue;

	for (;;) {
		struct preload_bulk_task *task;
		int failed, reserved_fd;

		pthread_mutex_lock(&queue->mutex);
		while (!queue->head && queue->pending)
			pthread_cond_wait(&queue->cond, &queue->mutex);
		if (!queue->pending) {
			pthread_mutex_unlock(&queue->mutex);
			break;
		}
		task = queue->head;
		queue->head = task->next;
		pthread_mutex_unlock(&queue->mutex);

		failed =
			worker->scan->backend->scan_directory(worker, task);
		reserved_fd = task->reserved_fd;
		free(task);

		pthread_mutex_lock(&queue->mutex);
		if (failed)
			queue->failed = 1;
		if (reserved_fd) {
			if (!queue->open_fds)
				BUG("bulk preload open-fd count underflow");
			queue->open_fds--;
		}
		if (!queue->pending)
			BUG("bulk preload task count underflow");
		queue->pending--;
		if (!queue->pending)
			pthread_cond_broadcast(&queue->cond);
		pthread_mutex_unlock(&queue->mutex);
	}
	return NULL;
}

int preload_bulk_run_scan(struct preload_bulk_scan *scan,
			  struct preload_bulk_run_result *result)
{
	struct preload_bulk_task *root_task;
	int failed, started_threads = 1;

	if (scan->threads < 1)
		BUG("bulk preload scan requires at least one worker");
	memset(result, 0, sizeof(*result));
	if (queue_init(&scan->queue))
		return -1;
	CALLOC_ARRAY(scan->workers, scan->threads);
	for (int i = 0; i < scan->threads; i++)
		scan->workers[i].scan = scan;

	FLEX_ALLOC_STR(root_task, path, ".");
	if (!reserve_open_fd(&scan->queue))
		BUG("bulk preload queue cannot reserve its root descriptor");
	root_task->reserved_fd = 1;
	root_task->fd = fcntl(scan->root_fd, F_DUPFD_CLOEXEC, 0);
	if (root_task->fd < 0) {
		release_open_fd(&scan->queue);
		free(root_task);
		free(scan->workers);
		scan->workers = NULL;
		queue_release(&scan->queue);
		return -1;
	}
	enqueue_task(scan, root_task);

	for (int i = 1; i < scan->threads; i++) {
		int err = pthread_create(&scan->workers[i].thread, NULL,
					 preload_bulk_worker_main,
					 &scan->workers[i]);

		if (err)
			break;
		scan->workers[i].started = 1;
		started_threads++;
	}
	preload_bulk_worker_main(&scan->workers[0]);
	for (int i = 1; i < scan->threads; i++)
		if (scan->workers[i].started &&
		    pthread_join(scan->workers[i].thread, NULL))
			BUG("unable to join bulk preload worker");

	result->threads = started_threads;
	failed = scan->queue.failed;

	free(scan->workers);
	scan->workers = NULL;
	queue_release(&scan->queue);
	return failed ? -1 : 0;
}
