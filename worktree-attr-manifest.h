#ifndef WORKTREE_ATTR_MANIFEST_H
#define WORKTREE_ATTR_MANIFEST_H

struct index_state;
struct strbuf;

struct worktree_attr_manifest_stats {
	size_t candidates;
	size_t worktree_sources;
	size_t index_sources;
};

int worktree_attr_manifest_build(
	struct index_state *istate,
	struct strbuf *manifest,
	unsigned char *manifest_hash,
	struct worktree_attr_manifest_stats *stats);

#endif /* WORKTREE_ATTR_MANIFEST_H */
