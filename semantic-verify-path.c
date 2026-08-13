#include "git-compat-util.h"
#include "path-namespace.h"
#include "semantic-verify-internal.h"
#include "strbuf.h"

#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
struct anchored_dir {
	char *component;
	int fd;
	struct stat stat;
	size_t first_cache_pos;
};

struct semantic_verify_path {
	struct semantic_verify_root *root;
	struct anchored_dir *dirs;
	size_t dirs_nr;
	size_t dirs_alloc;
	size_t namespace_unstable_from;
	unsigned int namespace_unstable;
	struct strbuf component;
};

static void note_namespace_unstable(struct semantic_verify_path *path,
				    size_t from)
{
	path->namespace_unstable = 1;
	if (from < path->namespace_unstable_from)
		path->namespace_unstable_from = from;
}

static void pop_anchored_dir(struct semantic_verify_path *path)
{
	struct anchored_dir *dir = &path->dirs[path->dirs_nr - 1];
	int parent_fd = path->dirs_nr == 1 ? path->root->fd :
		path->dirs[path->dirs_nr - 2].fd;
	int named_fd;
	struct stat named_stat;

	named_fd = semantic_verify_openat(parent_fd, dir->component,
				      O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
	if (named_fd < 0 || fstat(named_fd, &named_stat) ||
	    !path_namespace_stat_equal(&dir->stat, &named_stat))
		note_namespace_unstable(path, dir->first_cache_pos);
	if (named_fd >= 0)
		close(named_fd);
	close(dir->fd);
	free(dir->component);
	path->dirs_nr--;
}

struct semantic_verify_path *semantic_verify_path_new(
	struct semantic_verify_root *root)
{
	struct semantic_verify_path *path;

	CALLOC_ARRAY(path, 1);
	path->root = root;
	path->namespace_unstable_from = SIZE_MAX;
	path->component = (struct strbuf)STRBUF_INIT;
	return path;
}

int semantic_verify_resolve_parent(struct semantic_verify_path *path,
				   const char *name, size_t cache_pos,
				   int *parent_fd, const char **basename)
{
	const char *slash = strrchr(name, '/');
	size_t parent_len = slash ? (size_t)(slash - name) : 0;
	size_t begin = 0, depth = 0;

	*basename = slash ? slash + 1 : name;
	if (!**basename) {
		errno = EINVAL;
		return -1;
	}

	/* Find the component-aligned prefix already pinned by this worker. */
	while (begin < parent_len && depth < path->dirs_nr) {
		size_t end = begin;
		struct anchored_dir *dir = &path->dirs[depth];

		while (end < parent_len && name[end] != '/')
			end++;
		if (strlen(dir->component) != end - begin ||
		    memcmp(dir->component, name + begin, end - begin))
			break;
		depth++;
		begin = end + 1;
	}
	while (path->dirs_nr > depth)
		pop_anchored_dir(path);

	while (begin < parent_len) {
		size_t end = begin;
		struct anchored_dir *dir;
		int dirfd, fd;
		struct stat st;

		while (end < parent_len && name[end] != '/')
			end++;
		if (end == begin ||
		    (end - begin == 1 && name[begin] == '.') ||
		    (end - begin == 2 && name[begin] == '.' &&
		     name[begin + 1] == '.')) {
			errno = EINVAL;
			return -1;
		}
		strbuf_reset(&path->component);
		strbuf_add(&path->component, name + begin, end - begin);
		dirfd = path->dirs_nr ? path->dirs[path->dirs_nr - 1].fd :
			path->root->fd;
		fd = semantic_verify_openat(dirfd, path->component.buf,
					    O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
		if (fd < 0)
			return -1;
		if (fstat(fd, &st)) {
			int saved_errno = errno;

			close(fd);
			errno = saved_errno;
			return -1;
		}
		if (!S_ISDIR(st.st_mode) || st.st_dev != path->root->stat.st_dev) {
			close(fd);
			errno = EXDEV;
			return -1;
		}
		ALLOC_GROW(path->dirs, path->dirs_nr + 1, path->dirs_alloc);
		dir = &path->dirs[path->dirs_nr++];
		dir->component = xstrdup(path->component.buf);
		dir->fd = fd;
		memcpy(&dir->stat, &st, sizeof(st));
		dir->first_cache_pos = cache_pos;
		begin = end + 1;
	}

	*parent_fd = path->dirs_nr ? path->dirs[path->dirs_nr - 1].fd :
		path->root->fd;
	return 0;
}

void semantic_verify_path_free(struct semantic_verify_path *path,
			       unsigned int *namespace_unstable,
			       size_t *namespace_unstable_from)
{
	if (!path)
		return;
	while (path->dirs_nr)
		pop_anchored_dir(path);
	if (namespace_unstable)
		*namespace_unstable = path->namespace_unstable;
	if (namespace_unstable_from)
		*namespace_unstable_from = path->namespace_unstable_from;
	free(path->dirs);
	strbuf_release(&path->component);
	free(path);
}
#else
struct semantic_verify_path *semantic_verify_path_new(
	struct semantic_verify_root *root UNUSED)
{
	errno = ENOSYS;
	return NULL;
}

int semantic_verify_resolve_parent(
	struct semantic_verify_path *path UNUSED,
	const char *name UNUSED, size_t cache_pos UNUSED,
	int *parent_fd UNUSED, const char **basename UNUSED)
{
	errno = ENOSYS;
	return -1;
}

void semantic_verify_path_free(
	struct semantic_verify_path *path UNUSED,
	unsigned int *namespace_unstable,
	size_t *namespace_unstable_from)
{
	if (namespace_unstable)
		*namespace_unstable = 0;
	if (namespace_unstable_from)
		*namespace_unstable_from = SIZE_MAX;
}
#endif
