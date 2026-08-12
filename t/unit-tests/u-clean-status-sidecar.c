#include "unit-test.h"
#include "clean-status-sidecar.h"
#include "fsmonitor-clean-proof.h"
#include "hash-framing.h"
#include "strbuf.h"

struct sidecar_fixture {
	struct clean_status_sidecar sidecar;
	struct strbuf encoded;
};

static void fill_oid(struct object_id *oid, unsigned char value,
		     const struct git_hash_algo *algo)
{
	unsigned char hash[GIT_MAX_RAWSZ];

	memset(hash, value, algo->rawsz);
	oidread(oid, hash, algo);
}

static void fixture_init(struct sidecar_fixture *fixture,
			 const struct git_hash_algo *algo)
{
	static const unsigned char token[] = "builtin:1:2";
	struct clean_status_proof *proof;

	memset(fixture, 0, sizeof(*fixture));
	fixture->encoded = (struct strbuf)STRBUF_INIT;
	fixture->sidecar.identity.stat.fields[0] = 1;
	fixture->sidecar.identity.stat.fields[1] = 2;
	proof = &fixture->sidecar.proof;
	proof->index_version = 4;
	proof->cache_nr = 5;
	fill_oid(&proof->index_checksum, 2, algo);
	fill_oid(&proof->head_tree, 3, algo);
	memset(proof->config_hash, 4, algo->rawsz);
	memset(proof->repo_hash, 5, algo->rawsz);
	fill_oid(&proof->exclude_source_digest, 6, algo);
	fixture->sidecar.token = token;
	fixture->sidecar.token_len = sizeof(token) - 1;
}

static void fixture_encode(struct sidecar_fixture *fixture,
			   const struct git_hash_algo *algo)
{
	cl_assert_equal_i(clean_status_sidecar_write(
		&fixture->encoded, &fixture->sidecar, algo), 0);
}

static void fixture_release(struct sidecar_fixture *fixture)
{
	strbuf_release(&fixture->encoded);
}

static void replace_checksum(struct strbuf *encoded,
			     const struct git_hash_algo *algo)
{
	strbuf_setlen(encoded, encoded->len - algo->rawsz);
	hash_append_checksum(encoded, algo);
}

static size_t flags_offset(void)
{
	return 4 + sizeof(uint32_t);
}

static size_t proof_offset(void)
{
	return 4 + 2 * sizeof(uint32_t) + CLEAN_STATUS_IDENTITY_SIZE;
}

static size_t index_checksum_offset(void)
{
	return proof_offset() + 2 * sizeof(uint32_t);
}

static size_t head_tree_offset(const struct git_hash_algo *algo)
{
	return index_checksum_offset() + algo->rawsz;
}

static size_t exclude_digest_offset(const struct git_hash_algo *algo)
{
	return index_checksum_offset() + 4 * algo->rawsz;
}

static size_t token_length_offset(const struct git_hash_algo *algo)
{
	return index_checksum_offset() + 5 * algo->rawsz;
}

static size_t token_offset(const struct git_hash_algo *algo)
{
	return token_length_offset(algo) + sizeof(uint32_t);
}

static void assert_parse_fails(struct sidecar_fixture *fixture,
			       const struct git_hash_algo *algo)
{
	struct clean_status_sidecar parsed;

	replace_checksum(&fixture->encoded, algo);
	cl_assert_equal_i(clean_status_sidecar_parse(
		&parsed, fixture->encoded.buf, fixture->encoded.len, algo), -1);
}

static void assert_round_trip(const struct git_hash_algo *algo)
{
	struct sidecar_fixture fixture;
	struct clean_status_sidecar parsed;

	fixture_init(&fixture, algo);
	fixture_encode(&fixture, algo);
	cl_assert_equal_i(clean_status_sidecar_parse(
		&parsed, fixture.encoded.buf, fixture.encoded.len, algo), 0);
	cl_assert_equal_i(get_be32(fixture.encoded.buf + 4),
			  CLEAN_STATUS_SIDECAR_VERSION);
	cl_assert(clean_status_identity_equal(&parsed.identity,
					      &fixture.sidecar.identity));
	cl_assert_equal_i(parsed.proof.index_version,
			  fixture.sidecar.proof.index_version);
	cl_assert_equal_i(parsed.proof.cache_nr,
			  fixture.sidecar.proof.cache_nr);
	cl_assert(oideq(&parsed.proof.index_checksum,
			&fixture.sidecar.proof.index_checksum));
	cl_assert(oideq(&parsed.proof.head_tree,
			&fixture.sidecar.proof.head_tree));
	cl_assert(!memcmp(parsed.proof.config_hash,
			  fixture.sidecar.proof.config_hash, algo->rawsz));
	cl_assert(!memcmp(parsed.proof.repo_hash,
			  fixture.sidecar.proof.repo_hash, algo->rawsz));
	cl_assert(oideq(&parsed.proof.exclude_source_digest,
			&fixture.sidecar.proof.exclude_source_digest));
	cl_assert_equal_i(parsed.token_len, fixture.sidecar.token_len);
	cl_assert(!memcmp(parsed.token, fixture.sidecar.token,
			  parsed.token_len));
	cl_assert_equal_i(parsed.hardlink_nr, 0);
	fixture_release(&fixture);
}

void test_clean_status_sidecar__round_trips_both_object_formats(void)
{
	assert_round_trip(&hash_algos[GIT_HASH_SHA1]);
	assert_round_trip(&hash_algos[GIT_HASH_SHA256]);
}

static void assert_hardlink_round_trip(const struct git_hash_algo *algo)
{
	struct sidecar_fixture fixture;
	struct clean_status_sidecar parsed;
	struct path_stat_identity expected = { 0 }, actual;
	struct strbuf witnesses = STRBUF_INIT;
	const unsigned char *cursor, *path;
	size_t path_len;

	fixture_init(&fixture, algo);
	expected.fields[0] = 11;
	expected.fields[1] = 12;
	expected.fields[2] = S_IFREG | 0644;
	expected.fields[3] = 2;
	expected.fields[10] = 123456789;
	cl_assert_equal_i(clean_status_sidecar_append_hardlink(
		&witnesses, "tracked/file", &expected), 0);
	fixture.sidecar.hardlinks = (unsigned char *)witnesses.buf;
	fixture.sidecar.hardlinks_len = witnesses.len;
	fixture.sidecar.hardlink_nr = 1;
	fixture_encode(&fixture, algo);
	cl_assert_equal_i(get_be32(fixture.encoded.buf + 4),
			  CLEAN_STATUS_SIDECAR_HARDLINK_VERSION);
	cl_assert_equal_i(clean_status_sidecar_parse(
		&parsed, fixture.encoded.buf, fixture.encoded.len, algo), 0);
	cl_assert_equal_i(parsed.hardlink_nr, 1);
	cursor = parsed.hardlinks;
	cl_assert_equal_i(clean_status_sidecar_next_hardlink(
		&cursor, parsed.hardlinks + parsed.hardlinks_len,
		&path, &path_len, &actual), 0);
	cl_assert_equal_i(path_len, strlen("tracked/file"));
	cl_assert(!memcmp(path, "tracked/file", path_len));
	cl_assert(path_stat_identity_equal(&expected, &actual));
	cl_assert(cursor == parsed.hardlinks + parsed.hardlinks_len);
	strbuf_release(&witnesses);
	fixture_release(&fixture);
}

void test_clean_status_sidecar__round_trips_hardlinks_in_both_formats(void)
{
	assert_hardlink_round_trip(&hash_algos[GIT_HASH_SHA1]);
	assert_hardlink_round_trip(&hash_algos[GIT_HASH_SHA256]);
}

void test_clean_status_sidecar__accepts_hardlink_payloads_over_old_limit(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct sidecar_fixture fixture;
	struct clean_status_sidecar parsed;
	struct path_stat_identity identity = { 0 };
	struct strbuf witnesses = STRBUF_INIT;
	char path[32];

	fixture_init(&fixture, algo);
	identity.fields[2] = S_IFREG | 0644;
	identity.fields[3] = 2;
	for (uint32_t i = 0; i < 80; i++) {
		xsnprintf(path, sizeof(path), "tracked/%04"PRIu32, i);
		cl_assert_equal_i(clean_status_sidecar_append_hardlink(
			&witnesses, path, &identity), 0);
	}
	fixture.sidecar.hardlinks = (unsigned char *)witnesses.buf;
	fixture.sidecar.hardlinks_len = witnesses.len;
	fixture.sidecar.hardlink_nr = 80;
	fixture_encode(&fixture, algo);
	cl_assert(fixture.encoded.len > 8192);
	cl_assert_equal_i(clean_status_sidecar_parse(
		&parsed, fixture.encoded.buf, fixture.encoded.len, algo), 0);
	cl_assert_equal_i(parsed.hardlink_nr, 80);
	strbuf_release(&witnesses);
	fixture_release(&fixture);
}

void test_clean_status_sidecar__rejects_invalid_hardlink_witnesses(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct sidecar_fixture fixture;
	struct path_stat_identity identity = { 0 };
	struct strbuf witnesses = STRBUF_INIT;
	size_t count_offset, first_path, second_path;

	fixture_init(&fixture, algo);
	identity.fields[2] = S_IFREG | 0644;
	identity.fields[3] = 2;
	cl_assert_equal_i(clean_status_sidecar_append_hardlink(
		&witnesses, "a/file", &identity), 0);
	cl_assert_equal_i(clean_status_sidecar_append_hardlink(
		&witnesses, "z/file", &identity), 0);
	fixture.sidecar.hardlinks = (unsigned char *)witnesses.buf;
	fixture.sidecar.hardlinks_len = witnesses.len;
	fixture.sidecar.hardlink_nr = 2;
	fixture_encode(&fixture, algo);
	count_offset = token_offset(algo) + fixture.sidecar.token_len;
	first_path = count_offset + 2 * sizeof(uint32_t);
	second_path = first_path + strlen("a/file") +
		CLEAN_STATUS_IDENTITY_SIZE + sizeof(uint32_t);

	put_be32(fixture.encoded.buf + count_offset, 0);
	assert_parse_fails(&fixture, algo);
	put_be32(fixture.encoded.buf + count_offset,
		 CLEAN_STATUS_HARDLINK_WITNESS_MAX + 1);
	assert_parse_fails(&fixture, algo);
	put_be32(fixture.encoded.buf + count_offset, 2);

	fixture.encoded.buf[first_path] = '/';
	assert_parse_fails(&fixture, algo);
	fixture.encoded.buf[first_path] = 'a';
	fixture.encoded.buf[second_path] = 'a';
	assert_parse_fails(&fixture, algo);
	fixture.encoded.buf[second_path] = 'z';

	put_be64(fixture.encoded.buf + first_path + strlen("a/file") +
		 3 * sizeof(uint64_t), 1);
	assert_parse_fails(&fixture, algo);
	strbuf_release(&witnesses);
	fixture_release(&fixture);
}

void test_clean_status_sidecar__rejects_bad_envelopes(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct sidecar_fixture fixture;
	struct clean_status_sidecar parsed;

	fixture_init(&fixture, algo);
	fixture_encode(&fixture, algo);

	cl_assert_equal_i(clean_status_sidecar_parse(
		&parsed, fixture.encoded.buf, fixture.encoded.len - 1, algo), -1);

	fixture.encoded.buf[0] ^= 1;
	assert_parse_fails(&fixture, algo);
	fixture.encoded.buf[0] ^= 1;

	put_be32(fixture.encoded.buf + 4, CLEAN_STATUS_SIDECAR_VERSION + 1);
	assert_parse_fails(&fixture, algo);
	put_be32(fixture.encoded.buf + 4, CLEAN_STATUS_SIDECAR_VERSION);

	put_be32(fixture.encoded.buf + flags_offset(), 1);
	assert_parse_fails(&fixture, algo);
	put_be32(fixture.encoded.buf + flags_offset(), 0);

	fixture.encoded.buf[fixture.encoded.len - 1] ^= 1;
	cl_assert_equal_i(clean_status_sidecar_parse(
		&parsed, fixture.encoded.buf, fixture.encoded.len, algo), -1);
	fixture_release(&fixture);
}

void test_clean_status_sidecar__rejects_invalid_proofs(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct sidecar_fixture fixture;

	fixture_init(&fixture, algo);
	fixture_encode(&fixture, algo);

	put_be32(fixture.encoded.buf + proof_offset(), 1);
	assert_parse_fails(&fixture, algo);
	put_be32(fixture.encoded.buf + proof_offset(), 4);

	memset(fixture.encoded.buf + head_tree_offset(algo), 0, algo->rawsz);
	assert_parse_fails(&fixture, algo);
	memset(fixture.encoded.buf + head_tree_offset(algo), 3, algo->rawsz);

	memset(fixture.encoded.buf + exclude_digest_offset(algo), 0,
	       algo->rawsz);
	assert_parse_fails(&fixture, algo);
	fixture_release(&fixture);
}

void test_clean_status_sidecar__accepts_null_checksum_with_durable_identity(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct sidecar_fixture fixture;
	struct clean_status_sidecar parsed;

	fixture_init(&fixture, algo);
	oidclr(&fixture.sidecar.proof.index_checksum, algo);
	cl_assert_equal_i(clean_status_sidecar_write(
		&fixture.encoded, &fixture.sidecar, algo),
		clean_status_identity_is_durable() ? 0 : -1);
	if (clean_status_identity_is_durable()) {
		cl_assert_equal_i(clean_status_sidecar_parse(
			&parsed, fixture.encoded.buf,
			fixture.encoded.len, algo), 0);
		cl_assert(is_null_oid(&parsed.proof.index_checksum));
	}
	fixture_release(&fixture);
}

void test_clean_status_sidecar__rejects_invalid_tokens(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct sidecar_fixture fixture;
	size_t token_len_offset = token_length_offset(algo);
	size_t token_start = token_offset(algo);

	fixture_init(&fixture, algo);
	fixture_encode(&fixture, algo);

	put_be32(fixture.encoded.buf + token_len_offset, 0);
	assert_parse_fails(&fixture, algo);
	put_be32(fixture.encoded.buf + token_len_offset,
		 fixture.sidecar.token_len);

	fixture.encoded.buf[token_start] = 'x';
	assert_parse_fails(&fixture, algo);
	fixture.encoded.buf[token_start] = 'b';

	fixture.encoded.buf[token_start + fixture.sidecar.token_len - 1] = '\0';
	assert_parse_fails(&fixture, algo);
	fixture.encoded.buf[token_start + fixture.sidecar.token_len - 1] = '2';

	put_be32(fixture.encoded.buf + token_len_offset,
		 FSMONITOR_CLEAN_PROOF_TOKEN_MAX + 1);
	assert_parse_fails(&fixture, algo);
	fixture_release(&fixture);
}

void test_clean_status_sidecar__accepts_the_maximum_token(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct sidecar_fixture fixture;
	struct clean_status_sidecar parsed;
	unsigned char *token;

	fixture_init(&fixture, algo);
	token = xmalloc(FSMONITOR_CLEAN_PROOF_TOKEN_MAX);
	memset(token, 'x', FSMONITOR_CLEAN_PROOF_TOKEN_MAX);
	memcpy(token, "builtin:", strlen("builtin:"));
	fixture.sidecar.token = token;
	fixture.sidecar.token_len = FSMONITOR_CLEAN_PROOF_TOKEN_MAX;
	fixture_encode(&fixture, algo);
	cl_assert_equal_i(clean_status_sidecar_parse(
		&parsed, fixture.encoded.buf, fixture.encoded.len, algo), 0);
	cl_assert_equal_i(parsed.token_len, FSMONITOR_CLEAN_PROOF_TOKEN_MAX);
	free(token);
	fixture_release(&fixture);
}

void test_clean_status_sidecar__rejects_trailing_payload(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct sidecar_fixture fixture;

	fixture_init(&fixture, algo);
	fixture_encode(&fixture, algo);
	strbuf_setlen(&fixture.encoded, fixture.encoded.len - algo->rawsz);
	strbuf_addch(&fixture.encoded, 'x');
	hash_append_checksum(&fixture.encoded, algo);
	cl_assert_equal_i(clean_status_sidecar_parse(
		&fixture.sidecar, fixture.encoded.buf, fixture.encoded.len, algo),
		-1);
	fixture_release(&fixture);
}

void test_clean_status_sidecar__rejects_invalid_writes(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct sidecar_fixture fixture;
	unsigned char *token;

	fixture_init(&fixture, algo);
	token = xmalloc(FSMONITOR_CLEAN_PROOF_TOKEN_MAX + 1);
	memset(token, 'x', FSMONITOR_CLEAN_PROOF_TOKEN_MAX + 1);
	memcpy(token, "builtin:", strlen("builtin:"));
	fixture.sidecar.token = token;
	fixture.sidecar.token_len = FSMONITOR_CLEAN_PROOF_TOKEN_MAX + 1;
	cl_assert_equal_i(clean_status_sidecar_write(
		&fixture.encoded, &fixture.sidecar, algo), -1);
	free(token);
	fixture_release(&fixture);
}
