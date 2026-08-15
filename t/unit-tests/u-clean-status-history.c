#include "unit-test.h"
#include "attr-manifest.h"
#include "clean-status.h"
#include "clean-status-internal.h"
#include "fsmonitor-clean-proof.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "strbuf.h"

struct history_fixture {
	struct repository repo;
	struct index_state istate;
	struct strbuf manifest;
	struct strbuf encoded;
	unsigned char config_hash[GIT_MAX_RAWSZ];
	unsigned char semantic_hash[GIT_MAX_RAWSZ];
	unsigned char attr_hash[GIT_MAX_RAWSZ];
};

static void fixture_init(struct history_fixture *fixture,
			 const struct git_hash_algo *algo)
{
	static const unsigned char token[] = "builtin:1:2";
	struct attr_manifest_writer writer;
	struct fsmonitor_clean_proof proof;
	unsigned char hash[GIT_MAX_RAWSZ];

	memset(fixture, 0, sizeof(*fixture));
	fixture->repo.hash_algo = algo;
	repo_config_values_init(&fixture->repo.config_values_private_);
	index_state_init(&fixture->istate, &fixture->repo);
	fixture->manifest = (struct strbuf)STRBUF_INIT;
	fixture->encoded = (struct strbuf)STRBUF_INIT;
	memset(hash, 1, algo->rawsz);
	memset(fixture->config_hash, 2, algo->rawsz);
	memset(fixture->semantic_hash, 3, algo->rawsz);
	memset(fixture->attr_hash, 4, algo->rawsz);
	attr_manifest_writer_init(&writer, &fixture->manifest, algo);
	cl_assert_equal_i(attr_manifest_writer_add(
		&writer, ".gitattributes", ATTR_MANIFEST_INDEX, hash), 0);
	memset(&proof, 0, sizeof(proof));
	proof.flags = FSMONITOR_CLEAN_PROOF_ALL;
	proof.token = token;
	proof.token_len = sizeof(token) - 1;
	proof.config_hash = fixture->config_hash;
	proof.semantic_hash = fixture->semantic_hash;
	proof.attr_hash = fixture->attr_hash;
	proof.attr_manifest = (const unsigned char *)fixture->manifest.buf;
	proof.attr_manifest_len = fixture->manifest.len;
	cl_assert_equal_i(fsmonitor_clean_proof_write(
		&fixture->encoded, &proof, algo), 0);
}

static void fixture_release(struct history_fixture *fixture)
{
	clean_status_release(&fixture->istate);
	free(fixture->istate.fsmonitor_last_update);
	repo_config_values_clear(&fixture->repo.config_values_private_);
	strbuf_release(&fixture->encoded);
	strbuf_release(&fixture->manifest);
}

static struct clean_status_state *install_current(
	struct history_fixture *fixture)
{
	struct clean_status_state *state =
		clean_status_get_state(&fixture->istate);
	const struct git_hash_algo *algo = fixture->repo.hash_algo;

	memcpy(state->current_config_hash, fixture->config_hash, algo->rawsz);
	memcpy(state->current_semantic_hash, fixture->semantic_hash, algo->rawsz);
	memcpy(state->current_attr_hash, fixture->attr_hash, algo->rawsz);
	state->current_config_valid = 1;
	state->current_semantic_valid = 1;
	state->current_attr_valid = 1;
	state->config_enforced = 1;
	FREE_AND_NULL(fixture->istate.fsmonitor_last_update);
	fixture->istate.fsmonitor_last_update = xstrdup("builtin:1:2");
	fixture->istate.fsmonitor_token_valid = 1;
	return state;
}

void test_clean_status_history__reads_valid_history_once(void)
{
	struct history_fixture fixture;
	struct clean_status_state *state;

	fixture_init(&fixture, &hash_algos[GIT_HASH_SHA1]);
	cl_assert_equal_i(clean_status_read_fsmonitor_config(
		&fixture.istate, fixture.encoded.buf, fixture.encoded.len), 0);
	state = fixture.istate.clean_status;
	cl_assert(state->disk_config_valid);
	cl_assert(state->manifest.disk_valid);
	cl_assert_equal_s(state->disk_config_token, "builtin:1:2");

	cl_assert_equal_i(clean_status_read_fsmonitor_config(
		&fixture.istate, fixture.encoded.buf, fixture.encoded.len), 0);
	cl_assert(state->disk_config_invalid);
	cl_assert(!state->disk_config_valid);
	cl_assert(!state->manifest.disk_valid);
	fixture_release(&fixture);
}

static void check_existing_proof_is_replaced(
	const struct git_hash_algo *algo, int semantic)
{
	struct history_fixture fixture;
	struct index_state dst;
	struct clean_status_state *src_state, *dst_state;
	struct stat st;
	int source_fd;

	fixture_init(&fixture, algo);
	index_state_init(&dst, &fixture.repo);
	clean_status_read_fsmonitor_config(
		&fixture.istate, fixture.encoded.buf, fixture.encoded.len);
	src_state = install_current(&fixture);
	clean_status_prepare_fsmonitor_config(&fixture.istate);
	cl_assert(src_state->config_revalidated);

	clean_status_read_fsmonitor_config(
		&dst, fixture.encoded.buf, fixture.encoded.len);
	dst_state = dst.clean_status;
	memcpy(dst_state->current_config_hash,
	       src_state->current_config_hash, algo->rawsz);
	memcpy(dst_state->current_semantic_hash,
	       src_state->current_semantic_hash, algo->rawsz);
	memcpy(dst_state->current_attr_hash,
	       src_state->current_attr_hash, algo->rawsz);
	dst_state->current_config_valid = 1;
	dst_state->current_semantic_valid = 1;
	dst_state->current_attr_valid = 1;
	dst_state->config_enforced = 1;
	dst.fsmonitor_last_update = xstrdup("builtin:1:2");
	dst.fsmonitor_token_valid = 1;
	clean_status_prepare_fsmonitor_config(&dst);
	clean_status_invalidate_current_proof(&dst);
	cl_assert(dst_state->disk_config_seen);
	cl_assert(dst_state->disk_config_valid);

	source_fd = dup(1);
	cl_assert(source_fd >= 0);
	dst_state->source_index_fd = source_fd;
	dst_state->source_logical_hash_valid = 1;
	dst_state->external_history_restored = 1;
	memset(dst_state->source_logical_hash, 0x5a, algo->rawsz);

	if (semantic)
		cl_assert(clean_status_transfer_current_proof_if_semantically_same_index(
			&dst, &fixture.istate));
	else
		cl_assert(clean_status_transfer_current_proof_if_same_index(
			&dst, &fixture.istate));
	cl_assert(dst.clean_status == dst_state);
	cl_assert(dst_state->disk_config_seen);
	cl_assert(dst_state->disk_config_valid);
	cl_assert(!dst_state->disk_config_invalid);
	cl_assert(dst_state->config_revalidated);
	cl_assert_equal_s(dst_state->disk_config_token, "builtin:1:2");
	cl_assert_equal_i(dst_state->source_index_fd, source_fd);
	cl_assert_equal_i(fstat(source_fd, &st), 0);
	cl_assert(dst_state->source_logical_hash_valid);
	cl_assert_equal_i(dst_state->source_logical_hash[0], 0x5a);
	cl_assert(dst_state->external_history_restored);

	clean_status_read_fsmonitor_config(
		&dst, fixture.encoded.buf, fixture.encoded.len);
	cl_assert(dst_state->disk_config_invalid);
	cl_assert(!dst_state->disk_config_valid);

	clean_status_release(&dst);
	free(dst.fsmonitor_last_update);
	fixture_release(&fixture);
}

void test_clean_status_history__replaces_existing_identical_index_proofs(void)
{
	check_existing_proof_is_replaced(&hash_algos[GIT_HASH_SHA1], 0);
	check_existing_proof_is_replaced(&hash_algos[GIT_HASH_SHA256], 0);
}

void test_clean_status_history__replaces_existing_semantic_index_proofs(void)
{
	check_existing_proof_is_replaced(&hash_algos[GIT_HASH_SHA1], 1);
	check_existing_proof_is_replaced(&hash_algos[GIT_HASH_SHA256], 1);
}

void test_clean_status_history__adopts_only_coherent_proofs(void)
{
	struct history_fixture fixture;
	struct clean_status_state *state;

	fixture_init(&fixture, &hash_algos[GIT_HASH_SHA256]);
	clean_status_read_fsmonitor_config(
		&fixture.istate, fixture.encoded.buf, fixture.encoded.len);
	state = install_current(&fixture);
	clean_status_prepare_fsmonitor_config(&fixture.istate);
	cl_assert(state->initial_coherent);
	cl_assert(state->manifest.current_valid);
	cl_assert_equal_i(state->manifest.current.len, fixture.manifest.len);

	state->current_semantic_hash[0] ^= 1;
	clean_status_prepare_fsmonitor_config(&fixture.istate);
	cl_assert(clean_status_fsmonitor_strong_mismatch(&fixture.istate));
	cl_assert(!state->initial_coherent);
	fixture_release(&fixture);
}

void test_clean_status_history__distinguishes_available_history(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct history_fixture fixture;
	struct clean_status_state *state;
	struct strbuf manifest_only = STRBUF_INIT;

	fixture_init(&fixture, algo);
	clean_status_read_fsmonitor_config(
		&fixture.istate, fixture.encoded.buf, fixture.encoded.len);
	cl_assert(clean_status_has_persistent_fsmonitor_semantic_history(
		&fixture.istate));
	cl_assert(clean_status_has_worktree_manifest_history(&fixture.istate));
	state = install_current(&fixture);
	cl_assert(!clean_status_fsmonitor_semantic_adoption_needed(
		&fixture.istate));
	cl_assert(!clean_status_fsmonitor_semantic_baseline_needed(
		&fixture.istate));
	state->strong_mismatch = 1;
	cl_assert(clean_status_fsmonitor_semantic_adoption_needed(
		&fixture.istate));
	cl_assert(!clean_status_fsmonitor_semantic_baseline_needed(
		&fixture.istate));
	fixture_release(&fixture);

	fixture_init(&fixture, algo);
	cl_assert_equal_i(fsmonitor_clean_proof_copy_without_bindings(
		&manifest_only, fixture.encoded.buf, fixture.encoded.len,
		algo), 0);
	clean_status_read_fsmonitor_config(
		&fixture.istate, manifest_only.buf, manifest_only.len);
	cl_assert(!clean_status_has_persistent_fsmonitor_semantic_history(
		&fixture.istate));
	cl_assert(clean_status_has_worktree_manifest_history(&fixture.istate));
	install_current(&fixture);
	cl_assert(!clean_status_fsmonitor_semantic_adoption_needed(
		&fixture.istate));
	cl_assert(!clean_status_fsmonitor_semantic_baseline_needed(
		&fixture.istate));
	fixture_release(&fixture);

	fixture_init(&fixture, algo);
	state = install_current(&fixture);
	fixture.istate.fsmonitor_token_valid = 1;
	FREE_AND_NULL(fixture.istate.fsmonitor_last_update);
	fixture.istate.fsmonitor_last_update = xstrdup("builtin:test:1");
	cl_assert(clean_status_fsmonitor_semantic_adoption_needed(
		&fixture.istate));
	cl_assert(clean_status_fsmonitor_semantic_baseline_needed(
		&fixture.istate));
	clean_status_begin_fsmonitor_semantic_baseline(&fixture.istate);
	cl_assert(!clean_status_fsmonitor_semantic_adoption_needed(
		&fixture.istate));
	state->semantic_baseline_pending = 0;
	state->disk_config_seen = 1;
	cl_assert(clean_status_fsmonitor_semantic_adoption_needed(
		&fixture.istate));
	cl_assert(!clean_status_fsmonitor_semantic_baseline_needed(
		&fixture.istate));
	state->disk_config_seen = 0;
	fixture.repo.config_values_private_.trust_ctime = 0;
	cl_assert(clean_status_fsmonitor_semantic_adoption_needed(
		&fixture.istate));
	cl_assert(!clean_status_fsmonitor_semantic_baseline_needed(
		&fixture.istate));
	fixture.repo.config_values_private_.trust_ctime = 1;
	state->strong_mismatch = 1;
	cl_assert(clean_status_fsmonitor_semantic_adoption_needed(
		&fixture.istate));
	cl_assert(!clean_status_fsmonitor_semantic_baseline_needed(
		&fixture.istate));
	fixture_release(&fixture);
	strbuf_release(&manifest_only);
}

void test_clean_status_history__preserves_unbound_manifests(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct history_fixture fixture;
	struct clean_status_state *state;
	struct fsmonitor_clean_proof parsed;
	struct strbuf rewritten = STRBUF_INIT;

	fixture_init(&fixture, algo);
	clean_status_read_fsmonitor_config(
		&fixture.istate, fixture.encoded.buf, fixture.encoded.len);
	state = install_current(&fixture);
	clean_status_prepare_fsmonitor_config(&fixture.istate);
	cl_assert(clean_status_should_write_fsmonitor_config(&fixture.istate));
	clean_status_write_fsmonitor_config(&rewritten, &fixture.istate);
	cl_assert_equal_i(fsmonitor_clean_proof_parse(
		&parsed, rewritten.buf, rewritten.len, algo), 0);
	cl_assert_equal_i(parsed.flags, FSMONITOR_CLEAN_PROOF_ALL);

	FREE_AND_NULL(fixture.istate.fsmonitor_last_update);
	fixture.istate.fsmonitor_last_update = xstrdup("builtin:1:3");
	clean_status_write_fsmonitor_config(&rewritten, &fixture.istate);
	cl_assert_equal_i(fsmonitor_clean_proof_parse(
		&parsed, rewritten.buf, rewritten.len, algo), 0);
	cl_assert_equal_i(parsed.flags,
		FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		FSMONITOR_CLEAN_PROOF_FULL_INDEX);

	FREE_AND_NULL(fixture.istate.fsmonitor_last_update);
	fixture.istate.fsmonitor_last_update = xstrdup("builtin:1:2");
	state->current_config_valid = 0;
	clean_status_write_fsmonitor_config(&rewritten, &fixture.istate);
	cl_assert_equal_i(fsmonitor_clean_proof_parse(
		&parsed, rewritten.buf, rewritten.len, algo), 0);
	cl_assert_equal_i(parsed.flags,
		FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		FSMONITOR_CLEAN_PROOF_FULL_INDEX);
	strbuf_release(&rewritten);
	fixture_release(&fixture);
}
void test_clean_status_history__advances_only_current_proofs(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct history_fixture fixture;
	struct clean_status_state *state;
	struct fsmonitor_clean_proof parsed;
	struct strbuf rewritten = STRBUF_INIT;

	fixture_init(&fixture, algo);
	clean_status_read_fsmonitor_config(
		&fixture.istate, fixture.encoded.buf, fixture.encoded.len);
	state = install_current(&fixture);
	clean_status_prepare_fsmonitor_config(&fixture.istate);

	clean_status_advance_fsmonitor_config_token(
		&fixture.istate, "builtin:1:3");
	cl_assert_equal_s(state->config_revalidated_token, "builtin:1:3");
	FREE_AND_NULL(fixture.istate.fsmonitor_last_update);
	fixture.istate.fsmonitor_last_update = xstrdup("builtin:1:3");
	cl_assert(clean_status_should_write_fsmonitor_config(&fixture.istate));

	clean_status_invalidate_current_proof(&fixture.istate);
	cl_assert(!state->config_revalidated);
	cl_assert(!state->initial_coherent);
	clean_status_advance_fsmonitor_config_token(
		&fixture.istate, "builtin:1:4");
	cl_assert_equal_s(state->config_revalidated_token, "builtin:1:3");
	FREE_AND_NULL(fixture.istate.fsmonitor_last_update);
	fixture.istate.fsmonitor_last_update = xstrdup("builtin:1:4");
	clean_status_write_fsmonitor_config(&rewritten, &fixture.istate);
	cl_assert_equal_i(fsmonitor_clean_proof_parse(
		&parsed, rewritten.buf, rewritten.len, algo), 0);
	cl_assert_equal_i(parsed.flags,
		FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		FSMONITOR_CLEAN_PROOF_FULL_INDEX);

	strbuf_release(&rewritten);
	fixture_release(&fixture);
}

void test_clean_status_history__expires_invalidated_proofs(void)
{
	struct history_fixture fixture;
	struct clean_status_state *state;

	fixture_init(&fixture, &hash_algos[GIT_HASH_SHA1]);
	clean_status_read_fsmonitor_config(
		&fixture.istate, fixture.encoded.buf, fixture.encoded.len);
	state = install_current(&fixture);
	clean_status_prepare_fsmonitor_config(&fixture.istate);
	cl_assert(state->manifest.current_valid);
	cl_assert(state->config_revalidated);
	cl_assert(state->initial_coherent);

	clean_status_invalidate_current_manifest(&fixture.istate);
	cl_assert(!state->manifest.current_valid);
	cl_assert(!state->config_revalidated);
	cl_assert(!state->initial_coherent);
	cl_assert(clean_status_fsmonitor_config_mismatch(&fixture.istate));
	fixture_release(&fixture);
}

void test_clean_status_history__copies_validated_history(void)
{
	struct history_fixture fixture;
	struct repository dst_repo = {
		.hash_algo = &hash_algos[GIT_HASH_SHA1],
	};
	struct index_state dst = INDEX_STATE_INIT(&dst_repo);
	struct index_state invalid_dst = INDEX_STATE_INIT(&dst_repo);
	struct clean_status_state *dst_state;

	fixture_init(&fixture, &hash_algos[GIT_HASH_SHA1]);
	clean_status_read_fsmonitor_config(
		&fixture.istate, fixture.encoded.buf, fixture.encoded.len);
	move_index_extensions(&dst, &fixture.istate);
	dst_state = dst.clean_status;
	cl_assert(dst_state != NULL);
	cl_assert(dst_state->disk_config_valid);
	cl_assert(!dst_state->disk_config_invalid);
	cl_assert(dst_state->disk_semantic_valid);
	cl_assert(dst_state->disk_attr_valid);
	cl_assert(dst_state->manifest.disk_valid);
	cl_assert_equal_i(dst_state->manifest.disk_flags,
			  FSMONITOR_CLEAN_PROOF_ALL);
	cl_assert_equal_i(dst_state->disk_config_raw.len,
			  fixture.encoded.len);

	clean_status_read_fsmonitor_config(
		&fixture.istate, fixture.encoded.buf, fixture.encoded.len);
	move_index_extensions(&invalid_dst, &fixture.istate);
	cl_assert(!invalid_dst.clean_status);
	cl_assert(dst_state->disk_config_valid);
	cl_assert_equal_i(dst_state->disk_config_raw.len,
			  fixture.encoded.len);

	release_index(&invalid_dst);
	release_index(&dst);
	fixture_release(&fixture);
}
