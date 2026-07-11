#ifndef WORKTREE_ATTR_SOURCE_H
#define WORKTREE_ATTR_SOURCE_H

struct git_hash_algo;
struct semantic_verify_path;

int worktree_attr_source_read(struct semantic_verify_path *path,
			      const char *name, size_t position,
			      const struct git_hash_algo *algo,
			      unsigned char *hash, int *found);

#endif /* WORKTREE_ATTR_SOURCE_H */
