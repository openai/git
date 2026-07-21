#include "unit-test.h"
#include "attr-manifest.h"
#include "clean-status.h"
#include "clean-status-internal.h"
#include "clean-status-manifest.h"
#include "dir.h"
#include "fsmonitor-clean-proof.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "semantic-verify-internal.h"
#include "wrapper.h"

static void make_manifest(struct strbuf *manifest,
			  const struct git_hash_algo *algo)
{
	struct attr_manifest_writer writer;
	unsigned char hash[GIT_MAX_RAWSZ];

	memset(hash, 1, algo->rawsz);
	attr_manifest_writer_init(&writer, manifest, algo);
	cl_assert_equal_i(attr_manifest_writer_add(
		&writer, ".gitattributes", ATTR_MANIFEST_INDEX, hash), 0);
}

void test_clean_status_manifest__loads_and_adopts_valid_history(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct clean_status_manifest_state state;
	struct strbuf manifest = STRBUF_INIT;

	clean_status_manifest_init(&state);
	make_manifest(&manifest, algo);
	cl_assert_equal_i(clean_status_manifest_load(
		&state, manifest.buf, manifest.len,
		FSMONITOR_CLEAN_PROOF_ALL, algo), 0);
	cl_assert(state.disk_valid);
	clean_status_manifest_adopt_disk(&state);
	cl_assert(state.current_valid);
	cl_assert(state.checked);
	cl_assert_equal_i(state.current_flags, FSMONITOR_CLEAN_PROOF_ALL);
	cl_assert_equal_i(state.current.len, manifest.len);
	cl_assert(!memcmp(state.current.buf, manifest.buf, manifest.len));
	clean_status_manifest_invalidate(&state);
	cl_assert(!state.current_valid);
	cl_assert(state.current_invalidated);
	cl_assert_equal_i(state.current_flags, 0);
	clean_status_manifest_release(&state);
	strbuf_release(&manifest);
}

void test_clean_status_manifest__rejects_invalid_history(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct clean_status_manifest_state state;
	struct strbuf manifest = STRBUF_INIT;
	size_t valid_len;

	clean_status_manifest_init(&state);
	make_manifest(&manifest, algo);
	valid_len = manifest.len;
	cl_assert_equal_i(clean_status_manifest_load(
		&state, manifest.buf, manifest.len,
		FSMONITOR_CLEAN_PROOF_ALL, algo), 0);
	cl_assert(state.disk_valid);
	cl_assert_equal_i(state.disk_flags, FSMONITOR_CLEAN_PROOF_ALL);
	cl_assert_equal_i(state.disk.len, valid_len);
	cl_assert(!memcmp(state.disk.buf, manifest.buf, valid_len));

	strbuf_addch(&manifest, 0);
	cl_assert_equal_i(clean_status_manifest_load(
		&state, manifest.buf, manifest.len,
		FSMONITOR_CLEAN_PROOF_ALL, algo), -1);
	cl_assert(!state.disk_valid);
	cl_assert_equal_i(state.disk_flags, 0);
	cl_assert_equal_i(state.disk.len, 0);
	clean_status_manifest_release(&state);
	strbuf_release(&manifest);
}

void test_clean_status_manifest__requires_complete_full_index(void)
{
	const char *current_token = "builtin:1:2";
	const char *closed_token = "builtin:1:3";
	struct repository repo = { .hash_algo = &hash_algos[GIT_HASH_SHA1] };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct clean_status_state *state = clean_status_get_state(&istate);

	istate.fsmonitor_last_update = xstrdup(current_token);
	istate.fsmonitor_token_valid = 1;
	state->current_config_valid = 1;
	state->current_semantic_valid = 1;
	state->current_attr_valid = 1;
	state->config_enforced = 1;
	state->manifest.current_valid = 1;
	state->manifest.checked = 1;
	state->manifest.current_flags =
		FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE;

	clean_status_mark_fsmonitor_config_valid(&istate, closed_token);
	cl_assert(!state->config_revalidated);
	cl_assert(!state->config_revalidated_token);
	cl_assert(!clean_status_should_write_fsmonitor_config(&istate));
	cl_assert_equal_i(state->manifest.current_flags,
			  FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE);

	state->manifest.current_flags |= FSMONITOR_CLEAN_PROOF_FULL_INDEX;
	clean_status_mark_fsmonitor_config_valid(&istate, closed_token);
	cl_assert(state->config_revalidated);
	cl_assert_equal_s(state->config_revalidated_token, closed_token);
	cl_assert(!clean_status_revalidated_token_matches(&istate));
	cl_assert(!clean_status_should_write_fsmonitor_config(&istate));

	FREE_AND_NULL(istate.fsmonitor_last_update);
	istate.fsmonitor_last_update = xstrdup(closed_token);
	cl_assert(clean_status_revalidated_token_matches(&istate));
	cl_assert(clean_status_should_write_fsmonitor_config(&istate));
	cl_assert_equal_i(state->manifest.current_flags,
			  FSMONITOR_CLEAN_PROOF_ALL);

	clean_status_release(&istate);
	FREE_AND_NULL(istate.fsmonitor_last_update);
}

#if SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
static char *create_worktree(void)
{
	const char *tmp = getenv("TMPDIR");
	char *path = xstrfmt("%s/status-manifest.XXXXXX",
				 tmp ? tmp : "/tmp");

	cl_assert(mkdtemp(path) != NULL);
	return path;
}

static void add_index_path(struct index_state *istate, size_t pos,
			   const char *path)
{
	size_t len = strlen(path);
	struct cache_entry *ce = make_empty_cache_entry(istate, len);

	ce->ce_mode = S_IFREG | 0644;
	ce->ce_namelen = len;
	memcpy(ce->name, path, len + 1);
	istate->cache[pos] = ce;
}
#endif

void test_clean_status_manifest__invalidates_only_changed_scopes(void)
{
#if !SEMANTIC_VERIFY_HAS_ANCHORED_OPEN
	cl_skip();
#else
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	char *worktree = create_worktree();
	struct repository repo = { .worktree = worktree, .hash_algo = algo };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct clean_status_manifest_state state;
	struct strbuf path = STRBUF_INIT, old = STRBUF_INIT, cleanup = STRBUF_INIT;

	strbuf_addf(&path, "%s/a", worktree);
	cl_assert_equal_i(mkdir(path.buf, 0777), 0);
	strbuf_reset(&path);
	strbuf_addf(&path, "%s/b", worktree);
	cl_assert_equal_i(mkdir(path.buf, 0777), 0);
	strbuf_reset(&path);
	strbuf_addf(&path, "%s/a/.gitattributes", worktree);
	write_file(path.buf, "*.txt text\n");

	CALLOC_ARRAY(istate.cache, 2);
	istate.cache_alloc = istate.cache_nr = 2;
	add_index_path(&istate, 0, "a/file");
	add_index_path(&istate, 1, "b/file");
	clean_status_manifest_init(&state);
	cl_assert_equal_i(clean_status_manifest_refresh(&istate, &state), 0);
	strbuf_addbuf(&old, &state.current);
	cl_assert_equal_i(clean_status_manifest_load(
		&state, old.buf, old.len, FSMONITOR_CLEAN_PROOF_ALL, algo), 0);

	write_file(path.buf, "*.txt -text\n");
	for (size_t i = 0; i < istate.cache_nr; i++) {
		istate.cache[i]->ce_flags = CE_FSMONITOR_VALID | CE_UPTODATE;
		memset(&istate.cache[i]->ce_stat_data, 1,
		       sizeof(istate.cache[i]->ce_stat_data));
	}
	cl_assert_equal_i(clean_status_manifest_refresh(&istate, &state), 1);
	cl_assert(state.changed);
	cl_assert(!state.current_invalidated);
	cl_assert(!(istate.cache[0]->ce_flags & CE_FSMONITOR_VALID));
	cl_assert(istate.cache[0]->ce_flags & CE_CONTENT_CHECK_REQUIRED);
	cl_assert(istate.cache[1]->ce_flags & CE_FSMONITOR_VALID);

	/*
	 * Preserve the last complete in-process value when a rebuild fails,
	 * then return to the on-disk value. The final comparison must use
	 * the preserved value, not the matching on-disk history.
	 */
	strbuf_reset(&old);
	strbuf_addbuf(&old, &state.current);
	clean_status_manifest_invalidate(&state);
	cl_assert(state.current_invalidated);
	istate.cache[0]->ce_flags = create_ce_flags(1);
	cl_assert_equal_i(clean_status_manifest_refresh(&istate, &state), -1);
	cl_assert(!state.current_valid);
	cl_assert(state.global_fallback);
	cl_assert_equal_i(strbuf_cmp(&state.current, &old), 0);

	write_file(path.buf, "*.txt text\n");
	for (size_t i = 0; i < istate.cache_nr; i++) {
		istate.cache[i]->ce_flags = CE_FSMONITOR_VALID | CE_UPTODATE;
		memset(&istate.cache[i]->ce_stat_data, 1,
		       sizeof(istate.cache[i]->ce_stat_data));
	}
	cl_assert_equal_i(clean_status_manifest_refresh(&istate, &state), 1);
	cl_assert(state.changed);
	cl_assert(!state.current_invalidated);
	cl_assert(!(istate.cache[0]->ce_flags & CE_FSMONITOR_VALID));
	cl_assert(istate.cache[0]->ce_flags & CE_CONTENT_CHECK_REQUIRED);
	cl_assert(istate.cache[1]->ce_flags & CE_FSMONITOR_VALID);

	clean_status_manifest_release(&state);
	strbuf_release(&old);
	strbuf_release(&path);
	release_index(&istate);
	strbuf_addstr(&cleanup, worktree);
	cl_assert_equal_i(remove_dir_recursively(&cleanup, 0), 0);
	strbuf_release(&cleanup);
	free(worktree);
#endif
}
