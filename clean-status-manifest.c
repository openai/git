#include "git-compat-util.h"
#include "attr-fingerprint.h"
#include "attr.h"
#include "attr-manifest.h"
#include "bloom.h"
#include "clean-status-config.h"
#include "clean-status-index.h"
#include "clean-status-internal.h"
#include "clean-status-manifest.h"
#include "commit.h"
#include "commit-graph.h"
#include "dir.h"
#include "environment.h"
#include "fsmonitor.h"
#include "fsmonitor-clean-proof.h"
#include "fsmonitor-ll.h"
#include "hash-framing.h"
#include "object.h"
#include "object-name.h"
#include "odb.h"
#include "path-namespace.h"
#include "read-cache-ll.h"
#include "replace-object.h"
#include "repository.h"
#include "semantic-verify-internal.h"
#include "sparse-index.h"
#include "trace2.h"
#include "tree.h"
#include "tree-walk.h"
#include "worktree-attr-manifest.h"
#include "worktree-attr-source.h"
#include "wrapper.h"

struct invalidate_manifest_data {
	struct index_state *istate;
	const struct strbuf *baseline;
	const struct strbuf *current;
	int invalidated;
};

static int build_manifest(struct index_state *istate,
			  struct strbuf *manifest,
			  unsigned char *manifest_hash,
			  struct worktree_attr_manifest_stats *stats)
{
	struct clean_status_index_snapshot snapshot;
	struct index_state scratch = INDEX_STATE_INIT(istate->repo);
	int ret = -1;

	if (istate->sparse_index == INDEX_EXPANDED)
		return worktree_attr_manifest_build(
			istate, manifest, manifest_hash, stats);
	if (clean_status_index_snapshot_pin(&snapshot, istate))
		return -1;
	scratch.fsmonitor_has_run_once = 1;
	if (read_index_from(&scratch, istate->repo->index_file,
			    istate->repo->gitdir) < 0 ||
	    !clean_status_index_snapshot_still_matches(&snapshot, &scratch))
		goto done;
	ensure_full_index(&scratch);
	ret = worktree_attr_manifest_build(
		&scratch, manifest, manifest_hash, stats);
	if (ret ||
	    !clean_status_index_snapshot_still_matches(&snapshot, istate)) {
		strbuf_reset(manifest);
		ret = -1;
	}

done:
	release_index(&scratch);
	clean_status_index_snapshot_release(&snapshot);
	return ret;
}

void clean_status_manifest_init(struct clean_status_manifest_state *state)
{
	memset(state, 0, sizeof(*state));
	strbuf_init(&state->disk, 0);
	strbuf_init(&state->current, 0);
}

void clean_status_manifest_release(struct clean_status_manifest_state *state)
{
	strbuf_release(&state->disk);
	strbuf_release(&state->current);
}

int clean_status_manifest_load(struct clean_status_manifest_state *state,
			       const void *data, size_t len, uint32_t flags,
			       const struct git_hash_algo *algo)
{
	state->disk_valid = 0;
	state->disk_flags = 0;
	strbuf_reset(&state->disk);
	if (flags & ~FSMONITOR_CLEAN_PROOF_ALL ||
	    !attr_manifest_valid(data, len, algo))
		return -1;
	strbuf_add(&state->disk, data, len);
	hash_buffer_digest(algo, data, len, state->disk_hash);
	state->disk_flags = flags;
	state->disk_valid = 1;
	return 0;
}

void clean_status_manifest_adopt_disk(
	struct clean_status_manifest_state *state)
{
	if (!state->disk_valid)
		BUG("cannot adopt an invalid clean-status manifest");
	strbuf_reset(&state->current);
	strbuf_addbuf(&state->current, &state->disk);
	memcpy(state->current_hash, state->disk_hash,
	       sizeof(state->current_hash));
	state->current_flags = state->disk_flags;
	state->current_valid = 1;
	state->checked = 1;
	state->current_invalidated = 0;
}

static int find_manifest_entry(
	const struct strbuf *manifest, const char *path,
	const struct git_hash_algo *algo, struct attr_manifest_entry *found)
{
	struct attr_manifest_cursor cursor;
	struct attr_manifest_entry entry;
	size_t path_len = strlen(path);
	int ret;

	if (attr_manifest_cursor_init(&cursor, manifest->buf,
				      manifest->len, algo))
		return -1;
	while ((ret = attr_manifest_cursor_next(&cursor, &entry)) > 0) {
		if (entry.path_len == path_len &&
		    !memcmp(entry.path, path, path_len)) {
			*found = entry;
			return 0;
		}
	}
	return -1;
}

int clean_status_manifest_reconcile_deleted_attribute(
	struct index_state *istate, const char *name)
{
#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	struct clean_status_state *state = istate->clean_status;
	const struct git_hash_algo *algo = istate->repo->hash_algo;
	struct semantic_verify_root *root = NULL;
	struct semantic_verify_path *path = NULL;
	struct attr_fingerprint attrs;
	struct attr_manifest_cursor cursor;
	struct attr_manifest_writer writer;
	struct attr_manifest_entry old, entry;
	struct strbuf next = STRBUF_INIT;
	const struct cache_entry *ce;
	const char *base, *basename;
	unsigned char hash[GIT_MAX_RAWSZ];
	unsigned char indexed_hash[GIT_MAX_RAWSZ];
	unsigned char worktree_hash[GIT_MAX_RAWSZ];
	unsigned char observed_hash[GIT_MAX_RAWSZ];
	unsigned int namespace_unstable = 0;
	enum object_type type;
	struct stat st;
	void *content = NULL;
	size_t size;
	int pos, parent_fd, found = 0, next_entry, indexed, safe = 0;
	int worktree_found, observed_found, changed;

	if (!name)
		goto done;
	base = find_last_dir_sep(name);
	base = base ? base + 1 : name;
	if (fspathcmp(base, GITATTRIBUTES_FILE) ||
	    !state || !state->config_revalidated ||
	    !state->current_attr_valid || state->filter_configured ||
	    !state->manifest.current_valid || !state->manifest.checked ||
	    state->manifest.current_invalidated ||
	    (state->manifest.current_flags & FSMONITOR_CLEAN_PROOF_ALL) !=
		FSMONITOR_CLEAN_PROOF_ALL ||
	    !istate->fsmonitor_token_valid ||
	    !istate->fsmonitor_last_update ||
	    !state->config_revalidated_token ||
	    strcmp(state->config_revalidated_token,
		   istate->fsmonitor_last_update))
		goto done;
	if (repo_has_replace_refs_uncached(istate->repo) ||
	    find_manifest_entry(&state->manifest.current,
				name, algo, &old) ||
	    (old.source != ATTR_MANIFEST_WORKTREE &&
	     old.source != ATTR_MANIFEST_INDEX) ||
	    attr_fingerprint_repository(istate->repo, &attrs) ||
	    attrs.sources_present != state->current_attr_sources_present ||
	    memcmp(attrs.content_hash, state->current_attr_hash,
		   algo->rawsz) ||
	    memcmp(attrs.namespace_hash,
		   state->current_attr_namespace_hash, algo->rawsz))
		goto done;
	pos = index_name_pos(istate, name, strlen(name));
	if (pos < 0)
		goto done;
	ce = istate->cache[pos];
	if (!S_ISREG(ce->ce_mode) || ce_stage(ce) ||
	    ce_skip_worktree(ce) || ce_intent_to_add(ce) ||
	    (ce->ce_flags & CE_VALID))
		goto done;
	indexed = old.source == ATTR_MANIFEST_INDEX;
	if (indexed && memcmp(old.hash, ce->oid.hash, algo->rawsz))
		goto done;
	content = odb_read_object(istate->repo->objects,
				  &ce->oid, &type, &size);
	if (!content || type != OBJ_BLOB || size >= ATTR_MAX_FILE_SIZE)
		goto done;
	hash_buffer_digest(algo, content, size, indexed_hash);
	if (!indexed && memcmp(old.hash, indexed_hash, algo->rawsz))
		goto done;
	if (semantic_verify_root_init(istate->repo, &root))
		goto done;
	path = semantic_verify_path_new(root);
	if (!path || worktree_attr_source_read(
	    path, name, pos, algo, worktree_hash, &worktree_found) ||
	    semantic_verify_resolve_parent(
		    path, name, pos, &parent_fd, &basename) ||
	    (!worktree_found &&
	     (!fstatat(parent_fd, basename, &st, AT_SYMLINK_NOFOLLOW) ||
	      errno != ENOENT)) ||
	    (worktree_found &&
	     memcmp(worktree_hash, indexed_hash, algo->rawsz)) ||
	    !semantic_verify_root_stable(root) ||
	    !attr_manifest_valid(state->manifest.current.buf,
				 state->manifest.current.len, algo) ||
	    attr_manifest_cursor_init(&cursor,
				      state->manifest.current.buf,
				      state->manifest.current.len, algo))
		goto done;
	attr_manifest_writer_init(&writer, &next, algo);
	while ((next_entry = attr_manifest_cursor_next(&cursor, &entry)) > 0) {
		char *entry_name = xmemdupz(entry.path, entry.path_len);
		int matches = !strcmp(entry_name, name);
		int invalid = attr_manifest_writer_add(
			&writer, entry_name,
			matches ?
				(worktree_found ? ATTR_MANIFEST_WORKTREE :
				 ATTR_MANIFEST_INDEX) :
				entry.source,
			matches ?
				(worktree_found ? worktree_hash : ce->oid.hash) :
				entry.hash);

		free(entry_name);
		if (invalid)
			goto done;
		found += matches;
	}
	if (next_entry < 0 || found != 1 ||
	    worktree_attr_source_read(
		    path, name, pos, algo, observed_hash, &observed_found) ||
	    observed_found != worktree_found ||
	    (!observed_found &&
	     (!fstatat(parent_fd, basename, &st, AT_SYMLINK_NOFOLLOW) ||
	      errno != ENOENT)) ||
	    (observed_found &&
	     memcmp(observed_hash, worktree_hash, algo->rawsz)))
		goto done;
	semantic_verify_path_free(path, &namespace_unstable, NULL);
	path = NULL;
	if (namespace_unstable || !semantic_verify_root_stable(root))
		goto done;
	changed = indexed == worktree_found;
	if (changed) {
		hash_buffer_digest(algo, next.buf, next.len, hash);
		strbuf_swap(&state->manifest.current, &next);
		memcpy(state->manifest.current_hash, hash, algo->rawsz);
		state->manifest.changed = 1;
		state->manifest.global_fallback = 0;
	}
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-reconciled", 1);
	safe = 1;

done:
	if (path)
		semantic_verify_path_free(path, NULL, NULL);
	semantic_verify_root_clear(root);
	strbuf_release(&next);
	free(content);
	return safe;
#else
	(void)istate;
	(void)name;
	return 0;
#endif
}

static int read_root_worktree_attributes(
	struct repository *repo, struct strbuf *out)
{
#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	struct semantic_verify_root *root = NULL;
	struct stat before, after, named;
	size_t size;
	int fd = -1, ret = -1;
	char extra;

	if (semantic_verify_root_init(repo, &root))
		goto done;
	fd = semantic_verify_openat(root->fd, GITATTRIBUTES_FILE,
				    O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
	if (fd < 0 || fstat(fd, &before) || !S_ISREG(before.st_mode) ||
	    before.st_nlink != 1 || before.st_dev != root->stat.st_dev ||
	    before.st_size < 0 || before.st_size >= ATTR_MAX_FILE_SIZE)
		goto done;
	size = xsize_t(before.st_size);
	strbuf_grow(out, size);
	strbuf_setlen(out, size);
	if ((size_t)read_in_full(fd, out->buf, size) != size ||
	    read(fd, &extra, 1) != 0 || fstat(fd, &after) ||
	    fstatat(root->fd, GITATTRIBUTES_FILE, &named,
		    AT_SYMLINK_NOFOLLOW) ||
	    !path_namespace_stat_equal(&before, &after) ||
	    !path_namespace_stat_equal(&after, &named) ||
	    !semantic_verify_root_stable(root))
		goto done;
	ret = 0;

done:
	if (fd >= 0)
		close(fd);
	semantic_verify_root_clear(root);
	if (ret)
		strbuf_reset(out);
	return ret;
#else
	(void)repo;
	(void)out;
	return -1;
#endif
}

static int find_previous_root_attributes(
	struct repository *repo, struct object_id *oid)
{
	struct bloom_filter_settings *settings;
	struct bloom_key key = { 0 };
	struct object_id head_oid;
	struct commit *commit;
	unsigned int visited = 0, bloom_hits = 0, tree_inspections = 0, limit;
	int found = 0;

	if (repo_get_oid(repo, "HEAD", &head_oid) ||
	    !(commit = lookup_commit_reference_gently(
		      repo, &head_oid, 1)))
		return -1;
	settings = get_bloom_filter_settings(repo);
	limit = settings ? 8192 : 128;
	if (settings)
		bloom_key_fill(&key, GITATTRIBUTES_FILE,
			       strlen(GITATTRIBUTES_FILE), settings);
	while (commit && visited < limit) {
		struct bloom_filter *filter = NULL;
		struct commit *parent;
		struct tree *current_tree, *parent_tree;
		struct object_id current_oid, parent_oid;
		unsigned short current_mode, parent_mode;

		visited++;
		if (repo_parse_commit_gently(repo, commit, 1) ||
		    !commit->parents)
			break;
		parent = commit->parents->item;
		if (settings)
			filter = get_bloom_filter(repo, commit);
		if (filter && filter->version >= 0 &&
		    (uint32_t)filter->version == settings->hash_version &&
		    bloom_filter_contains(filter, &key, settings) == 0) {
			bloom_hits++;
			commit = parent;
			continue;
		}
		if (tree_inspections >= 512)
			break;
		tree_inspections++;
		if (repo_parse_commit_gently(repo, parent, 1) ||
		    !(current_tree = repo_get_commit_tree(repo, commit)) ||
		    !(parent_tree = repo_get_commit_tree(repo, parent)) ||
		    get_tree_entry(repo, &current_tree->object.oid,
				   GITATTRIBUTES_FILE,
				   &current_oid, &current_mode) ||
		    get_tree_entry(repo, &parent_tree->object.oid,
				   GITATTRIBUTES_FILE,
				   &parent_oid, &parent_mode) ||
		    !S_ISREG(current_mode) || !S_ISREG(parent_mode))
			break;
		if (!oideq(&current_oid, &parent_oid)) {
			oidcpy(oid, &parent_oid);
			found = 1;
			break;
		}
		commit = parent;
	}
	if (settings)
		bloom_key_clear(&key);
	trace2_data_intmax("fsmonitor", repo,
			   "semantic/attribute-history-commits", visited);
	trace2_data_intmax("fsmonitor", repo,
			   "semantic/attribute-history-bloom-skips", bloom_hits);
	trace2_data_intmax("fsmonitor", repo,
			   "semantic/attribute-history-tree-inspections",
			   tree_inspections);
	return found ? 0 : -1;
}

static void *read_authenticated_attribute_blob(
	struct index_state *istate,
	const struct attr_manifest_entry *old,
	const struct object_id *oid, size_t *size)
{
	const struct git_hash_algo *algo = istate->repo->hash_algo;
	unsigned char hash[GIT_MAX_RAWSZ];
	enum object_type type;
	void *content;

	if (old->source == ATTR_MANIFEST_INDEX &&
	    memcmp(old->hash, oid->hash, algo->rawsz))
		return NULL;
	content = odb_read_object(istate->repo->objects,
				  oid, &type, size);
	if (!content || type != OBJ_BLOB ||
	    *size >= ATTR_MAX_FILE_SIZE) {
		free(content);
		return NULL;
	}
	if (old->source == ATTR_MANIFEST_WORKTREE) {
		hash_buffer_digest(algo, content, *size, hash);
		if (memcmp(old->hash, hash, algo->rawsz)) {
			free(content);
			return NULL;
		}
	} else if (old->source != ATTR_MANIFEST_INDEX) {
		free(content);
		return NULL;
	}
	return content;
}

static void *read_authenticated_old_attributes(
	struct index_state *istate,
	const struct attr_manifest_entry *old,
	const struct cache_entry *current, size_t *size)
{
	struct object_id parent_oid, historical_oid;
	const struct object_id *candidates[2];
	void *content;
	size_t nr = 1;

	candidates[0] = &current->oid;
	if (!repo_get_oid_blob(istate->repo,
				   "HEAD^:" GITATTRIBUTES_FILE, &parent_oid) &&
	    !oideq(&current->oid, &parent_oid))
		candidates[nr++] = &parent_oid;
	for (size_t i = 0; i < nr; i++) {
		content = read_authenticated_attribute_blob(
			istate, old, candidates[i], size);
		if (content)
			return content;
	}
	if (find_previous_root_attributes(istate->repo, &historical_oid))
		return NULL;
	return read_authenticated_attribute_blob(
		istate, old, &historical_oid, size);
}

int clean_status_manifest_reconcile_display_only_attribute(
	struct index_state *istate, const char *path)
{
#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	struct clean_status_state *state = istate->clean_status;
	const struct git_hash_algo *algo = istate->repo->hash_algo;
	struct clean_status_config_digest config;
	struct attr_fingerprint attrs;
	struct attr_manifest_cursor cursor;
	struct attr_manifest_writer writer;
	struct attr_manifest_entry old, entry;
	struct strbuf worktree = STRBUF_INIT;
	struct strbuf observed = STRBUF_INIT;
	struct strbuf next = STRBUF_INIT;
	const struct cache_entry *ce;
	unsigned char worktree_hash[GIT_MAX_RAWSZ];
	unsigned char indexed_hash[GIT_MAX_RAWSZ];
	unsigned char manifest_hash[GIT_MAX_RAWSZ];
	enum object_type type;
	void *previous = NULL, *indexed = NULL;
	size_t previous_len, indexed_len;
	int pos, found = 0, next_entry, safe = 0;

	if (!path || strcmp(path, GITATTRIBUTES_FILE) || !state ||
	    !state->config_enforced || !state->config_revalidated ||
	    !state->current_config_valid || !state->current_semantic_valid ||
	    !state->current_attr_valid || state->current_attr_sources_present ||
	    state->filter_configured || !state->disk_config_valid ||
	    state->disk_config_invalid || !state->disk_config_raw.len ||
	    !state->manifest.disk_valid || !state->manifest.current_valid ||
	    !state->manifest.checked || state->manifest.current_invalidated ||
	    (state->manifest.disk_flags & FSMONITOR_CLEAN_PROOF_ALL) !=
		FSMONITOR_CLEAN_PROOF_ALL ||
	    (state->manifest.current_flags & FSMONITOR_CLEAN_PROOF_ALL) !=
		FSMONITOR_CLEAN_PROOF_ALL ||
	    !istate->fsmonitor_token_valid ||
	    !istate->fsmonitor_last_update ||
	    !state->config_revalidated_token ||
	    strcmp(state->config_revalidated_token,
		   istate->fsmonitor_last_update) ||
	    repo_has_replace_refs_uncached(istate->repo) ||
	    find_manifest_entry(&state->manifest.current,
				path, algo, &old) ||
	    old.source != ATTR_MANIFEST_WORKTREE ||
	    attr_fingerprint_repository(istate->repo, &attrs) ||
	    attrs.sources_present ||
	    memcmp(attrs.content_hash, state->current_attr_hash,
		   algo->rawsz) ||
	    memcmp(attrs.namespace_hash,
		   state->current_attr_namespace_hash, algo->rawsz) ||
	    clean_status_config_read_repository(istate->repo, &config) ||
	    !config.finalized || config.filter_configured ||
	    memcmp(config.hash, state->current_config_hash, algo->rawsz) ||
	    memcmp(config.semantic_hash,
		   state->current_semantic_hash, algo->rawsz))
		goto done;
	pos = index_name_pos(istate, path, strlen(path));
	if (pos < 0)
		goto done;
	ce = istate->cache[pos];
	if (!S_ISREG(ce->ce_mode) || ce_stage(ce) ||
	    ce_skip_worktree(ce) || ce_intent_to_add(ce) ||
	    (ce->ce_flags & CE_VALID))
		goto done;
	previous = read_authenticated_old_attributes(
		istate, &old, ce, &previous_len);
	if (!previous ||
	    read_root_worktree_attributes(istate->repo, &worktree))
		goto done;
	indexed = odb_read_object(istate->repo->objects,
				  &ce->oid, &type, &indexed_len);
	if (!indexed || type != OBJ_BLOB ||
	    indexed_len >= ATTR_MAX_FILE_SIZE)
		goto done;
	hash_buffer_digest(algo, indexed, indexed_len, indexed_hash);
	hash_buffer_digest(algo, worktree.buf, worktree.len, worktree_hash);
	if ((memcmp(indexed_hash, worktree_hash, algo->rawsz) &&
	     (indexed_len != previous_len ||
	      memcmp(indexed, previous, indexed_len))) ||
	    !attr_manifest_only_linguist_generated_changed(
		previous, previous_len, worktree.buf, worktree.len) ||
	    !attr_manifest_valid(state->manifest.current.buf,
				 state->manifest.current.len, algo) ||
	    attr_manifest_cursor_init(&cursor,
				      state->manifest.current.buf,
				      state->manifest.current.len, algo))
		goto done;
	attr_manifest_writer_init(&writer, &next, algo);
	while ((next_entry = attr_manifest_cursor_next(&cursor, &entry)) > 0) {
		char *entry_path = xmemdupz(entry.path, entry.path_len);
		int matches = !strcmp(entry_path, path);
		int invalid = attr_manifest_writer_add(
			&writer, entry_path,
			matches ? ATTR_MANIFEST_WORKTREE : entry.source,
			matches ? worktree_hash : entry.hash);

		free(entry_path);
		if (invalid)
			goto done;
		found += matches;
	}
	if (next_entry < 0 || found != 1 ||
	    read_root_worktree_attributes(istate->repo, &observed) ||
	    observed.len != worktree.len ||
	    memcmp(observed.buf, worktree.buf, worktree.len))
		goto done;
	hash_buffer_digest(algo, next.buf, next.len, manifest_hash);
	strbuf_swap(&state->manifest.current, &next);
	memcpy(state->manifest.current_hash,
	       manifest_hash, algo->rawsz);
	state->manifest.changed = 1;
	state->manifest.global_fallback = 0;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/nonconversion-attributes", 1);
	safe = 1;

done:
	free(previous);
	free(indexed);
	strbuf_release(&worktree);
	strbuf_release(&observed);
	strbuf_release(&next);
	return safe;
#else
	(void)istate;
	(void)path;
	return 0;
#endif
}

int clean_status_manifest_accept_current_display_only_attribute(
	struct index_state *istate, const char *path)
{
#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	struct clean_status_state *state = istate->clean_status;
	const struct git_hash_algo *algo = istate->repo->hash_algo;
	struct clean_status_config_digest config;
	struct attr_fingerprint attrs;
	struct attr_manifest_entry current;
	struct strbuf worktree = STRBUF_INIT;
	struct strbuf observed = STRBUF_INIT;
	const struct cache_entry *ce;
	unsigned char worktree_hash[GIT_MAX_RAWSZ];
	enum object_type type;
	void *indexed = NULL;
	size_t indexed_len;
	int pos, safe = 0;

	if (!path || strcmp(path, GITATTRIBUTES_FILE) || !state ||
	    !state->config_enforced || !state->config_revalidated ||
	    !state->current_config_valid || !state->current_semantic_valid ||
	    !state->current_attr_valid || state->current_attr_sources_present ||
	    state->filter_configured || !state->disk_config_valid ||
	    state->disk_config_invalid || !state->disk_config_raw.len ||
	    !state->manifest.disk_valid || !state->manifest.current_valid ||
	    !state->manifest.checked || state->manifest.current_invalidated ||
	    (state->manifest.disk_flags & FSMONITOR_CLEAN_PROOF_ALL) !=
		FSMONITOR_CLEAN_PROOF_ALL ||
	    (state->manifest.current_flags & FSMONITOR_CLEAN_PROOF_ALL) !=
		FSMONITOR_CLEAN_PROOF_ALL ||
	    !istate->fsmonitor_token_valid ||
	    !istate->fsmonitor_last_update ||
	    !state->config_revalidated_token ||
	    strcmp(state->config_revalidated_token,
		   istate->fsmonitor_last_update) ||
	    repo_has_replace_refs_uncached(istate->repo) ||
	    find_manifest_entry(&state->manifest.current,
				path, algo, &current) ||
	    current.source != ATTR_MANIFEST_WORKTREE ||
	    attr_fingerprint_repository(istate->repo, &attrs) ||
	    attrs.sources_present ||
	    memcmp(attrs.content_hash, state->current_attr_hash,
		   algo->rawsz) ||
	    memcmp(attrs.namespace_hash,
		   state->current_attr_namespace_hash, algo->rawsz) ||
	    clean_status_config_read_repository(istate->repo, &config) ||
	    !config.finalized || config.filter_configured ||
	    memcmp(config.hash, state->current_config_hash, algo->rawsz) ||
	    memcmp(config.semantic_hash,
		   state->current_semantic_hash, algo->rawsz))
		goto done;
	pos = index_name_pos(istate, path, strlen(path));
	if (pos < 0)
		goto done;
	ce = istate->cache[pos];
	if (!S_ISREG(ce->ce_mode) || ce_stage(ce) ||
	    ce_skip_worktree(ce) || ce_intent_to_add(ce) ||
	    (ce->ce_flags & CE_VALID) ||
	    read_root_worktree_attributes(istate->repo, &worktree))
		goto done;
	hash_buffer_digest(algo, worktree.buf, worktree.len, worktree_hash);
	if (memcmp(current.hash, worktree_hash, algo->rawsz))
		goto done;
	indexed = odb_read_object(istate->repo->objects,
				  &ce->oid, &type, &indexed_len);
	if (!indexed || type != OBJ_BLOB ||
	    indexed_len >= ATTR_MAX_FILE_SIZE ||
	    !attr_manifest_only_linguist_generated_changed(
		indexed, indexed_len, worktree.buf, worktree.len) ||
	    read_root_worktree_attributes(istate->repo, &observed) ||
	    observed.len != worktree.len ||
	    memcmp(observed.buf, worktree.buf, worktree.len))
		goto done;
	safe = 1;

done:
	free(indexed);
	strbuf_release(&worktree);
	strbuf_release(&observed);
	return safe;
#else
	(void)istate;
	(void)path;
	return 0;
#endif
}

static int root_attributes_only_affect_display(
	const struct invalidate_manifest_data *data, const char *path,
	int *index_pos)
{
	struct index_state *istate = data->istate;
	struct clean_status_state *state = istate->clean_status;
	const struct git_hash_algo *algo = istate->repo->hash_algo;
	struct clean_status_config_digest config;
	struct attr_fingerprint attrs;
	struct attr_manifest_entry old, current;
	struct strbuf worktree = STRBUF_INIT;
	const struct cache_entry *ce;
	unsigned char hash[GIT_MAX_RAWSZ];
	void *staged = NULL;
	size_t staged_len;
	int pos, safe = 0;

	if (strcmp(path, GITATTRIBUTES_FILE) || !data->baseline ||
	    !data->current || !state ||
	    (state->current_attr_valid && state->current_attr_sources_present) ||
	    state->filter_configured ||
	    repo_has_replace_refs_uncached(istate->repo) ||
	    find_manifest_entry(data->baseline, path, algo, &old) ||
	    find_manifest_entry(data->current, path, algo, &current) ||
	    current.source != ATTR_MANIFEST_WORKTREE ||
	    attr_fingerprint_repository(istate->repo, &attrs) ||
	    attrs.sources_present ||
	    (state->current_attr_valid &&
	     memcmp(attrs.content_hash, state->current_attr_hash, algo->rawsz)) ||
	    clean_status_config_read_repository(istate->repo, &config) ||
	    !config.finalized || config.filter_configured)
		goto done;
	pos = index_name_pos(istate, path, strlen(path));
	if (pos < 0)
		goto done;
	ce = istate->cache[pos];
	if (!S_ISREG(ce->ce_mode) || ce_stage(ce) ||
	    ce_skip_worktree(ce) || ce_intent_to_add(ce) ||
	    (ce->ce_flags & CE_VALID))
		goto done;
	staged = read_authenticated_old_attributes(
		istate, &old, ce, &staged_len);
	if (!staged)
		goto done;
	if (read_root_worktree_attributes(istate->repo, &worktree))
		goto done;
	hash_buffer_digest(algo, worktree.buf, worktree.len, hash);
	if (memcmp(current.hash, hash, algo->rawsz) ||
	    !attr_manifest_only_linguist_generated_changed(
		staged, staged_len, worktree.buf, worktree.len))
		goto done;
	*index_pos = pos;
	safe = 1;

done:
	free(staged);
	strbuf_release(&worktree);
	return safe;
}

static int invalidate_manifest_path(const struct attr_manifest_entry *entry,
				    void *cb_data)
{
	struct invalidate_manifest_data *data = cb_data;
	char *path = xmemdupz(entry->path, entry->path_len);
	int pos;

	untracked_cache_invalidate_trimmed_path(data->istate, path, 0);
	if (root_attributes_only_affect_display(data, path, &pos)) {
		git_attr_invalidate_all();
		fsmonitor_invalidate_cache_entry(data->istate->cache[pos]);
		data->istate->cache_changed |= FSMONITOR_CHANGED;
		trace2_data_intmax("fsmonitor", data->istate->repo,
				   "semantic/nonconversion-attributes", 1);
	} else {
		data->invalidated +=
			fsmonitor_invalidate_attributes_path(data->istate, path);
	}
	free(path);
	return 0;
}

int clean_status_manifest_refresh(struct index_state *istate,
				  struct clean_status_manifest_state *state)
{
	struct worktree_attr_manifest_stats stats;
	struct invalidate_manifest_data invalidation = { .istate = istate };
	const struct git_hash_algo *algo = istate->repo->hash_algo;
	const struct strbuf *baseline = NULL;
	struct strbuf next = STRBUF_INIT;
	unsigned char next_hash[GIT_MAX_RAWSZ];

	state->scan_count++;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-scan-count", state->scan_count);
	if (attr_manifest_valid(state->current.buf, state->current.len, algo))
		baseline = &state->current;
	else if (state->disk_valid)
		baseline = &state->disk;
	state->checked = 1;
	state->changed = 0;
	state->global_fallback = 0;
	state->current_valid = 0;
	state->current_flags = 0;
	if (build_manifest(istate, &next, next_hash, &stats)) {
		state->global_fallback = !!baseline;
		trace2_data_intmax("fsmonitor", istate->repo,
				   "semantic/manifest-scan-failed", 1);
		strbuf_release(&next);
		return -1;
	}
	if (baseline) {
		invalidation.baseline = baseline;
		invalidation.current = &next;
		if (attr_manifest_for_each_changed(
			baseline->buf, baseline->len,
			next.buf, next.len, algo,
			invalidate_manifest_path, &invalidation)) {
			state->global_fallback = 1;
			strbuf_release(&next);
			return -1;
		}
		state->changed = baseline->len != next.len ||
			memcmp(baseline->buf, next.buf, next.len);
	}
	strbuf_swap(&state->current, &next);
	strbuf_release(&next);
	memcpy(state->current_hash, next_hash, algo->rawsz);
	state->current_valid = 1;
	state->current_flags = FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		FSMONITOR_CLEAN_PROOF_FULL_INDEX;
	state->current_invalidated = 0;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-candidates", stats.candidates);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-threads", stats.threads);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-thread-failures",
			   stats.thread_failures);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-worktree-sources",
			   stats.worktree_sources);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-index-sources", stats.index_sources);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-bytes", state->current.len);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-changed", state->changed);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/manifest-invalidated",
			   invalidation.invalidated);
	return invalidation.invalidated;
}

void clean_status_manifest_invalidate(
	struct clean_status_manifest_state *state)
{
	if (state->current_valid)
		state->current_invalidated = 1;
	state->current_valid = 0;
	state->current_flags = 0;
}
