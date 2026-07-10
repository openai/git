#include "unit-test.h"
#include "attr-manifest.h"
#include "clean-status-manifest.h"
#include "fsmonitor-clean-proof.h"

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
