#include "unit-test.h"
#include "fsmonitor-ll.h"
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
