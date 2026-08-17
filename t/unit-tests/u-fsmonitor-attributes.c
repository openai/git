#define USE_THE_REPOSITORY_VARIABLE

#include "unit-test.h"
#include "fsmonitor.h"
#include "fsmonitor-ll.h"
#include "fsmonitor-settings.h"
#include "read-cache-ll.h"
#include "repository.h"

static void add_entry(struct index_state *istate, size_t pos,
		      const char *path)
{
	size_t len = strlen(path);
	struct cache_entry *ce = make_empty_cache_entry(istate, len);

	ce->ce_mode = S_IFREG | 0644;
	ce->ce_namelen = len;
	ce->ce_flags = CE_FSMONITOR_VALID | CE_UPTODATE;
	memset(&ce->ce_stat_data, 1, sizeof(ce->ce_stat_data));
	memcpy(ce->name, path, len + 1);
	istate->cache[pos] = ce;
}

static int stat_data_is_zero(const struct cache_entry *ce)
{
	struct stat_data zero = { 0 };

	return !memcmp(&ce->ce_stat_data, &zero, sizeof(zero));
}

void test_fsmonitor_attributes__invalidates_only_the_affected_scope(void)
{
	struct repository repo = { .hash_algo = &hash_algos[GIT_HASH_SHA1] };
	struct index_state istate = INDEX_STATE_INIT(&repo);

	CALLOC_ARRAY(istate.cache, 3);
	istate.cache_alloc = istate.cache_nr = 3;
	add_entry(&istate, 0, "a/file");
	add_entry(&istate, 1, "a/sub/file");
	add_entry(&istate, 2, "b/file");

	cl_assert(!fsmonitor_invalidate_attributes_path(
		&istate, "a/not-attributes"));
	cl_assert(istate.cache[0]->ce_flags & CE_FSMONITOR_VALID);
	cl_assert(fsmonitor_invalidate_attributes_path(
		&istate, "a/.gitattributes"));
	for (size_t i = 0; i < 2; i++) {
		cl_assert(!(istate.cache[i]->ce_flags & CE_FSMONITOR_VALID));
		cl_assert(!(istate.cache[i]->ce_flags & CE_UPTODATE));
		cl_assert(istate.cache[i]->ce_flags & CE_CONTENT_CHECK_REQUIRED);
		cl_assert(stat_data_is_zero(istate.cache[i]));
	}
	cl_assert(istate.cache[2]->ce_flags & CE_FSMONITOR_VALID);
	cl_assert(istate.cache[2]->ce_flags & CE_UPTODATE);
	cl_assert(!stat_data_is_zero(istate.cache[2]));
	cl_assert(istate.cache_changed & FSMONITOR_CHANGED);
	release_index(&istate);
}

void test_fsmonitor_attributes__root_source_invalidates_every_entry(void)
{
	struct repository repo = { .hash_algo = &hash_algos[GIT_HASH_SHA1] };
	struct index_state istate = INDEX_STATE_INIT(&repo);

	CALLOC_ARRAY(istate.cache, 2);
	istate.cache_alloc = istate.cache_nr = 2;
	add_entry(&istate, 0, "a/file");
	add_entry(&istate, 1, "b/file");
	cl_assert(fsmonitor_invalidate_attributes_path(
		&istate, ".gitattributes"));
	for (size_t i = 0; i < istate.cache_nr; i++) {
		cl_assert(!(istate.cache[i]->ce_flags & CE_FSMONITOR_VALID));
		cl_assert(istate.cache[i]->ce_flags & CE_CONTENT_CHECK_REQUIRED);
	}
	release_index(&istate);
}

void test_fsmonitor_attributes__bounds_middle_and_final_nested_cones(void)
{
	struct repository repo = { .hash_algo = &hash_algos[GIT_HASH_SHA1] };
	struct index_state istate = INDEX_STATE_INIT(&repo);

	CALLOC_ARRAY(istate.cache, 6);
	istate.cache_alloc = istate.cache_nr = 6;
	add_entry(&istate, 0, "before/tracked");
	add_entry(&istate, 1, "middle/first");
	add_entry(&istate, 2, "middle/nested/tracked");
	add_entry(&istate, 3, "middle/second");
	add_entry(&istate, 4, "middle0-sibling/tracked");
	add_entry(&istate, 5, "zzz/tracked");

	cl_assert(fsmonitor_invalidate_attributes_path(
		&istate, "middle/nested/.gitattributes"));
	cl_assert(istate.cache[0]->ce_flags & CE_FSMONITOR_VALID);
	cl_assert(istate.cache[1]->ce_flags & CE_FSMONITOR_VALID);
	cl_assert(!(istate.cache[2]->ce_flags & CE_FSMONITOR_VALID));
	cl_assert(istate.cache[3]->ce_flags & CE_FSMONITOR_VALID);
	cl_assert(istate.cache[4]->ce_flags & CE_FSMONITOR_VALID);
	cl_assert(istate.cache[5]->ce_flags & CE_FSMONITOR_VALID);

	cl_assert(fsmonitor_invalidate_attributes_path(
		&istate, "zzz/.gitattributes"));
	cl_assert(!(istate.cache[5]->ce_flags & CE_FSMONITOR_VALID));
	cl_assert(istate.cache[4]->ce_flags & CE_FSMONITOR_VALID);
	release_index(&istate);
}

void test_fsmonitor_attributes__missing_cone_preserves_every_entry(void)
{
	struct repository repo = { .hash_algo = &hash_algos[GIT_HASH_SHA1] };
	struct index_state istate = INDEX_STATE_INIT(&repo);

	CALLOC_ARRAY(istate.cache, 2);
	istate.cache_alloc = istate.cache_nr = 2;
	add_entry(&istate, 0, "before/tracked");
	add_entry(&istate, 1, "later/tracked");

	cl_assert(!fsmonitor_invalidate_attributes_path(
		&istate, "between/.gitattributes"));
	cl_assert(istate.cache[0]->ce_flags & CE_FSMONITOR_VALID);
	cl_assert(istate.cache[1]->ce_flags & CE_FSMONITOR_VALID);
	release_index(&istate);
}

void test_fsmonitor_attributes__does_not_expand_sparse_directory(void)
{
	struct repository repo = { .hash_algo = &hash_algos[GIT_HASH_SHA1] };
	struct index_state istate = INDEX_STATE_INIT(&repo);

	CALLOC_ARRAY(istate.cache, 2);
	istate.cache_alloc = istate.cache_nr = 2;
	istate.sparse_index = INDEX_COLLAPSED;
	add_entry(&istate, 0, "cone/");
	istate.cache[0]->ce_mode = S_IFDIR;
	add_entry(&istate, 1, "outside/tracked");

	cl_assert(fsmonitor_invalidate_attributes_path(
		&istate, "cone/.gitattributes"));
	cl_assert_equal_i(istate.sparse_index, INDEX_COLLAPSED);
	cl_assert_equal_i(istate.cache_nr, 2);
	cl_assert(!(istate.cache[0]->ce_flags & CE_FSMONITOR_VALID));
	cl_assert(istate.cache[1]->ce_flags & CE_FSMONITOR_VALID);
	release_index(&istate);
}

void test_fsmonitor_attributes__casefolded_cones_keep_full_fallback(void)
{
	struct repository repo = { .hash_algo = &hash_algos[GIT_HASH_SHA1] };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	int previous_ignore_case =
		the_repository->config_values_private_.ignore_case;
	int previously_initialized = the_repository->initialized;

	CALLOC_ARRAY(istate.cache, 3);
	istate.cache_alloc = istate.cache_nr = 3;
	add_entry(&istate, 0, "A/first");
	add_entry(&istate, 1, "M/untouched");
	add_entry(&istate, 2, "a/second");
	the_repository->initialized = 1;
	the_repository->config_values_private_.ignore_case = 1;

	cl_assert(fsmonitor_invalidate_attributes_path(
		&istate, "a/.gitattributes"));
	cl_assert(!(istate.cache[0]->ce_flags & CE_FSMONITOR_VALID));
	cl_assert(istate.cache[1]->ce_flags & CE_FSMONITOR_VALID);
	cl_assert(!(istate.cache[2]->ce_flags & CE_FSMONITOR_VALID));

	the_repository->config_values_private_.ignore_case =
		previous_ignore_case;
	the_repository->initialized = previously_initialized;
	release_index(&istate);
}

void test_fsmonitor_attributes__windows_separator_keeps_full_fallback(void)
{
#if !defined(GIT_WINDOWS_NATIVE) && !defined(__CYGWIN__)
	cl_skip();
#else
	struct repository repo = { .hash_algo = &hash_algos[GIT_HASH_SHA1] };
	struct index_state istate = INDEX_STATE_INIT(&repo);

	CALLOC_ARRAY(istate.cache, 2);
	istate.cache_alloc = istate.cache_nr = 2;
	add_entry(&istate, 0, "alpha/tracked");
	add_entry(&istate, 1, "beta/tracked");

	cl_assert(fsmonitor_invalidate_attributes_path(
		&istate, "alpha\\.gitattributes"));
	cl_assert(!(istate.cache[0]->ce_flags & CE_FSMONITOR_VALID));
	cl_assert(istate.cache[1]->ce_flags & CE_FSMONITOR_VALID);
	release_index(&istate);
#endif
}

void test_fsmonitor_attributes__disabled_provider_preserves_skipped_stat(void)
{
	struct repository repo = { .hash_algo = &hash_algos[GIT_HASH_SHA1] };
	struct index_state istate = INDEX_STATE_INIT(&repo);

	fsm_settings__set_disabled(&repo);
	CALLOC_ARRAY(istate.cache, 2);
	istate.cache_alloc = istate.cache_nr = 2;
	add_entry(&istate, 0, "skipped");
	add_entry(&istate, 1, "tracked");
	istate.cache[0]->ce_flags |= CE_SKIP_WORKTREE;

	fsmonitor_invalidate_semantics(&istate);

	cl_assert(!(istate.cache[0]->ce_flags & CE_FSMONITOR_VALID));
	cl_assert(!(istate.cache[0]->ce_flags & CE_CONTENT_CHECK_REQUIRED));
	cl_assert(!stat_data_is_zero(istate.cache[0]));
	cl_assert(!(istate.cache[1]->ce_flags & CE_FSMONITOR_VALID));
	cl_assert(istate.cache[1]->ce_flags & CE_CONTENT_CHECK_REQUIRED);
	cl_assert(stat_data_is_zero(istate.cache[1]));

	release_index(&istate);
	FREE_AND_NULL(repo.settings.fsmonitor);
}
