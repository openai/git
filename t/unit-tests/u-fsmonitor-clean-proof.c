#include "unit-test.h"
#include "attr-manifest.h"
#include "fsmonitor-clean-proof.h"
#include "strbuf.h"

struct proof_fixture {
	struct strbuf manifest;
	struct strbuf encoded;
	unsigned char config_hash[GIT_MAX_RAWSZ];
	unsigned char semantic_hash[GIT_MAX_RAWSZ];
	unsigned char attr_hash[GIT_MAX_RAWSZ];
	unsigned char tracked_policy_hash[GIT_MAX_RAWSZ];
	struct fsmonitor_clean_proof proof;
};

static void fixture_init(struct proof_fixture *fixture,
			 const struct git_hash_algo *algo)
{
	struct attr_manifest_writer writer;
	unsigned char hash[GIT_MAX_RAWSZ];
	static const unsigned char token[] = "builtin:1:2";

	memset(fixture, 0, sizeof(*fixture));
	fixture->manifest = (struct strbuf)STRBUF_INIT;
	fixture->encoded = (struct strbuf)STRBUF_INIT;
	memset(hash, 1, algo->rawsz);
	memset(fixture->config_hash, 2, algo->rawsz);
	memset(fixture->semantic_hash, 3, algo->rawsz);
	memset(fixture->attr_hash, 4, algo->rawsz);
	memset(fixture->tracked_policy_hash, 5, algo->rawsz);
	attr_manifest_writer_init(&writer, &fixture->manifest, algo);
	cl_assert_equal_i(attr_manifest_writer_add(
		&writer, ".gitattributes", ATTR_MANIFEST_INDEX, hash), 0);
	fixture->proof.flags = FSMONITOR_CLEAN_PROOF_ALL;
	fixture->proof.token = token;
	fixture->proof.token_len = sizeof(token) - 1;
	fixture->proof.config_hash = fixture->config_hash;
	fixture->proof.semantic_hash = fixture->semantic_hash;
	fixture->proof.attr_hash = fixture->attr_hash;
	fixture->proof.attr_manifest =
		(const unsigned char *)fixture->manifest.buf;
	fixture->proof.attr_manifest_len = fixture->manifest.len;
}

static void fixture_release(struct proof_fixture *fixture)
{
	strbuf_release(&fixture->encoded);
	strbuf_release(&fixture->manifest);
}

static void assert_round_trip(const struct git_hash_algo *algo)
{
	struct proof_fixture fixture;
	struct fsmonitor_clean_proof parsed;

	fixture_init(&fixture, algo);
	cl_assert_equal_i(fsmonitor_clean_proof_write(
		&fixture.encoded, &fixture.proof, algo), 0);
	cl_assert_equal_i(fsmonitor_clean_proof_parse(
		&parsed, fixture.encoded.buf, fixture.encoded.len, algo), 0);
	cl_assert_equal_i(parsed.version,
		FSMONITOR_CLEAN_PROOF_VERSION_LEGACY);
	cl_assert_equal_p(parsed.tracked_policy_hash, NULL);
	cl_assert_equal_i(parsed.flags, fixture.proof.flags);
	cl_assert_equal_i(parsed.token_len, fixture.proof.token_len);
	cl_assert(!memcmp(parsed.token, fixture.proof.token, parsed.token_len));
	cl_assert(!memcmp(parsed.config_hash, fixture.config_hash, algo->rawsz));
	cl_assert(!memcmp(parsed.attr_manifest, fixture.manifest.buf,
			  parsed.attr_manifest_len));
	fixture_release(&fixture);
}

static void assert_rejected(struct fsmonitor_clean_proof *parsed,
			    const struct strbuf *encoded,
			    const struct git_hash_algo *algo)
{
	memset(parsed, 0xff, sizeof(*parsed));
	cl_assert_equal_i(fsmonitor_clean_proof_parse(
		parsed, encoded->buf, encoded->len, algo), -1);
	cl_assert_equal_i(parsed->flags, 0);
	cl_assert_equal_p(parsed->token, NULL);
	cl_assert_equal_i(parsed->token_len, 0);
	cl_assert_equal_p(parsed->config_hash, NULL);
	cl_assert_equal_p(parsed->semantic_hash, NULL);
	cl_assert_equal_p(parsed->attr_hash, NULL);
	cl_assert_equal_p(parsed->tracked_policy_hash, NULL);
	cl_assert_equal_p(parsed->attr_manifest, NULL);
	cl_assert_equal_i(parsed->attr_manifest_len, 0);
}

void test_fsmonitor_clean_proof__round_trips_both_object_formats(void)
{
	assert_round_trip(&hash_algos[GIT_HASH_SHA1]);
	assert_round_trip(&hash_algos[GIT_HASH_SHA256]);
}

static void assert_tracked_policy_round_trip(
	const struct git_hash_algo *algo)
{
	struct proof_fixture fixture;
	struct fsmonitor_clean_proof parsed;
	struct strbuf unbound = STRBUF_INIT;
	size_t policy_offset;
	unsigned char saved;

	fixture_init(&fixture, algo);
	fixture.proof.tracked_policy_hash = fixture.tracked_policy_hash;
	cl_assert_equal_i(fsmonitor_clean_proof_write(
		&fixture.encoded, &fixture.proof, algo), 0);
	cl_assert_equal_i(fsmonitor_clean_proof_parse(
		&parsed, fixture.encoded.buf, fixture.encoded.len, algo), 0);
	cl_assert_equal_i(parsed.version, FSMONITOR_CLEAN_PROOF_VERSION);
	cl_assert(!memcmp(parsed.tracked_policy_hash,
		fixture.tracked_policy_hash, algo->rawsz));
	cl_assert_equal_i(fsmonitor_clean_proof_copy_without_bindings(
		&unbound, fixture.encoded.buf, fixture.encoded.len, algo), 0);
	cl_assert_equal_i(fsmonitor_clean_proof_parse(
		&parsed, unbound.buf, unbound.len, algo), 0);
	cl_assert_equal_i(parsed.version, FSMONITOR_CLEAN_PROOF_VERSION);
	cl_assert(!memcmp(parsed.tracked_policy_hash,
		fixture.tracked_policy_hash, algo->rawsz));
	cl_assert_equal_i(parsed.flags,
		FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		FSMONITOR_CLEAN_PROOF_FULL_INDEX);
	policy_offset = 5 * sizeof(uint32_t) + fixture.proof.token_len +
		3 * algo->rawsz;
	saved = fixture.encoded.buf[policy_offset];
	fixture.encoded.buf[policy_offset] ^= 1;
	assert_rejected(&parsed, &fixture.encoded, algo);
	fixture.encoded.buf[policy_offset] = saved;
	fixture.encoded.len--;
	assert_rejected(&parsed, &fixture.encoded, algo);
	strbuf_release(&unbound);
	fixture_release(&fixture);
}

void test_fsmonitor_clean_proof__binds_tracked_policy_in_both_formats(void)
{
	assert_tracked_policy_round_trip(&hash_algos[GIT_HASH_SHA1]);
	assert_tracked_policy_round_trip(&hash_algos[GIT_HASH_SHA256]);
}

void test_fsmonitor_clean_proof__rejects_corrupt_records(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct proof_fixture fixture;
	struct fsmonitor_clean_proof parsed;
	size_t token_offset = 5 * sizeof(uint32_t);
	uint32_t saved;
	unsigned char byte;

	fixture_init(&fixture, algo);
	cl_assert_equal_i(fsmonitor_clean_proof_write(
		&fixture.encoded, &fixture.proof, algo), 0);
	fixture.encoded.len--;
	assert_rejected(&parsed, &fixture.encoded, algo);
	fixture.encoded.len++;
	saved = get_be32(fixture.encoded.buf + 2 * sizeof(uint32_t));
	put_be32(fixture.encoded.buf + 2 * sizeof(uint32_t), 1u << 31);
	assert_rejected(&parsed, &fixture.encoded, algo);
	put_be32(fixture.encoded.buf + 2 * sizeof(uint32_t), saved);
	byte = fixture.encoded.buf[token_offset];
	fixture.encoded.buf[token_offset] = '\0';
	assert_rejected(&parsed, &fixture.encoded, algo);
	fixture.encoded.buf[token_offset] = byte;
	fixture.encoded.buf[fixture.encoded.len - 1] ^= 1;
	assert_rejected(&parsed, &fixture.encoded, algo);
	fixture_release(&fixture);
}

void test_fsmonitor_clean_proof__clears_only_epoch_bindings(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA256];
	struct proof_fixture fixture;
	struct fsmonitor_clean_proof parsed;
	struct strbuf unbound = STRBUF_INIT;

	fixture_init(&fixture, algo);
	cl_assert_equal_i(fsmonitor_clean_proof_write(
		&fixture.encoded, &fixture.proof, algo), 0);
	cl_assert_equal_i(fsmonitor_clean_proof_copy_without_bindings(
		&unbound, fixture.encoded.buf, fixture.encoded.len, algo), 0);
	cl_assert_equal_i(fsmonitor_clean_proof_parse(
		&parsed, unbound.buf, unbound.len, algo), 0);
	cl_assert_equal_i(parsed.flags,
		FSMONITOR_CLEAN_PROOF_MANIFEST_COMPLETE |
		FSMONITOR_CLEAN_PROOF_FULL_INDEX);
	cl_assert_equal_i(parsed.token_len, fixture.proof.token_len);
	cl_assert(!memcmp(parsed.attr_manifest, fixture.manifest.buf,
			  fixture.manifest.len));
	strbuf_release(&unbound);
	fixture_release(&fixture);
}
