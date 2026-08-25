#include "git-compat-util.h"
#include "attr-manifest.h"
#include "fsmonitor-clean-proof.h"
#include "hash-framing.h"
#include "strbuf.h"

#define FSMONITOR_CLEAN_PROOF_MAGIC 0x46534331 /* "FSC1" */
#define FSMONITOR_CLEAN_PROOF_HEADER_WORDS 5

int fsmonitor_clean_proof_parse(struct fsmonitor_clean_proof *proof,
				const void *data, size_t len,
				const struct git_hash_algo *algo)
{
	struct fsmonitor_clean_proof parsed = { 0 };
	const unsigned char *p = data;
	const unsigned char *end = p + len;
	unsigned char checksum[GIT_MAX_RAWSZ];
	size_t hashes_len = 4 * algo->rawsz;
	uint32_t token_len, manifest_len;

	memset(proof, 0, sizeof(*proof));
	if (len < FSMONITOR_CLEAN_PROOF_HEADER_WORDS * sizeof(uint32_t) +
		  hashes_len + 1)
		return -1;
	parsed.version = get_be32(p);
	if (parsed.version != FSMONITOR_CLEAN_PROOF_VERSION_LEGACY &&
	    parsed.version != FSMONITOR_CLEAN_PROOF_VERSION)
		return -1;
	if (parsed.version == FSMONITOR_CLEAN_PROOF_VERSION)
		hashes_len += algo->rawsz;
	p += sizeof(uint32_t);
	if (get_be32(p) != FSMONITOR_CLEAN_PROOF_MAGIC)
		return -1;
	p += sizeof(uint32_t);
	parsed.flags = get_be32(p);
	p += sizeof(uint32_t);
	token_len = get_be32(p);
	p += sizeof(uint32_t);
	manifest_len = get_be32(p);
	p += sizeof(uint32_t);
	if (parsed.flags & ~FSMONITOR_CLEAN_PROOF_ALL || !token_len ||
	    token_len > FSMONITOR_CLEAN_PROOF_TOKEN_MAX ||
	    manifest_len < sizeof(uint32_t) ||
	    (size_t)(end - p) < token_len || memchr(p, '\0', token_len))
		return -1;
	parsed.token = p;
	parsed.token_len = token_len;
	p += token_len;
	if ((size_t)(end - p) < hashes_len ||
	    (size_t)(end - p) - hashes_len != manifest_len)
		return -1;
	parsed.config_hash = p;
	p += algo->rawsz;
	parsed.semantic_hash = p;
	p += algo->rawsz;
	parsed.attr_hash = p;
	p += algo->rawsz;
	if (parsed.version == FSMONITOR_CLEAN_PROOF_VERSION) {
		parsed.tracked_policy_hash = p;
		p += algo->rawsz;
	}
	parsed.attr_manifest = p;
	parsed.attr_manifest_len = manifest_len;
	p += manifest_len;
	if (!attr_manifest_valid(parsed.attr_manifest,
				 parsed.attr_manifest_len, algo))
		return -1;
	hash_buffer_digest(algo, data, len - algo->rawsz, checksum);
	if (memcmp(checksum, p, algo->rawsz))
		return -1;
	*proof = parsed;
	return 0;
}

int fsmonitor_clean_proof_write(struct strbuf *out,
				const struct fsmonitor_clean_proof *proof,
				const struct git_hash_algo *algo)
{
	uint32_t value;

	strbuf_reset(out);
	if (!proof->token || !proof->token_len ||
	    proof->token_len > FSMONITOR_CLEAN_PROOF_TOKEN_MAX ||
	    proof->token_len > UINT32_MAX ||
	    memchr(proof->token, '\0', proof->token_len) ||
	    proof->flags & ~FSMONITOR_CLEAN_PROOF_ALL ||
	    !proof->config_hash || !proof->semantic_hash || !proof->attr_hash ||
	    !proof->attr_manifest || proof->attr_manifest_len > UINT32_MAX ||
	    !attr_manifest_valid(proof->attr_manifest,
				 proof->attr_manifest_len, algo))
		return -1;

	put_be32(&value, proof->tracked_policy_hash ?
		FSMONITOR_CLEAN_PROOF_VERSION :
		FSMONITOR_CLEAN_PROOF_VERSION_LEGACY);
	strbuf_add(out, &value, sizeof(value));
	put_be32(&value, FSMONITOR_CLEAN_PROOF_MAGIC);
	strbuf_add(out, &value, sizeof(value));
	put_be32(&value, proof->flags);
	strbuf_add(out, &value, sizeof(value));
	put_be32(&value, proof->token_len);
	strbuf_add(out, &value, sizeof(value));
	put_be32(&value, proof->attr_manifest_len);
	strbuf_add(out, &value, sizeof(value));
	strbuf_add(out, proof->token, proof->token_len);
	strbuf_add(out, proof->config_hash, algo->rawsz);
	strbuf_add(out, proof->semantic_hash, algo->rawsz);
	strbuf_add(out, proof->attr_hash, algo->rawsz);
	if (proof->tracked_policy_hash)
		strbuf_add(out, proof->tracked_policy_hash, algo->rawsz);
	strbuf_add(out, proof->attr_manifest, proof->attr_manifest_len);
	hash_append_checksum(out, algo);
	return 0;
}

int fsmonitor_clean_proof_copy_without_bindings(
	struct strbuf *out, const void *data, size_t len,
	const struct git_hash_algo *algo)
{
	struct fsmonitor_clean_proof proof;

	strbuf_reset(out);
	if (fsmonitor_clean_proof_parse(&proof, data, len, algo))
		return -1;
	proof.flags &= ~(FSMONITOR_CLEAN_PROOF_TOKEN_BOUND |
			 FSMONITOR_CLEAN_PROOF_STAT_BOUND);
	return fsmonitor_clean_proof_write(out, &proof, algo);
}
