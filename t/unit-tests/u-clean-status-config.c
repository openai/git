#include "unit-test.h"
#include "clean-status-config.h"
#include "config.h"

static void digest_one(struct clean_status_config_digest *digest,
		       const char *key, const char *value,
		       const struct config_context *ctx)
{
	clean_status_config_init(digest, &hash_algos[GIT_HASH_SHA1]);
	clean_status_config_add(digest, key, value, ctx);
	clean_status_config_final(digest);
}

static int hashes_equal(const unsigned char *a, const unsigned char *b)
{
	return hasheq(a, b, &hash_algos[GIT_HASH_SHA1]);
}

void test_clean_status_config__non_semantic_values_only_change_full_hash(void)
{
	struct clean_status_config_digest a, b;

	digest_one(&a, "status.showuntrackedfiles", "normal", NULL);
	digest_one(&b, "status.showuntrackedfiles", "all", NULL);
	cl_assert(!hashes_equal(a.hash, b.hash));
	cl_assert(hashes_equal(a.semantic_hash, b.semantic_hash));
	cl_assert(!a.semantic_config_explicit);
	cl_assert(!b.semantic_config_explicit);
}

void test_clean_status_config__semantic_values_change_semantic_hash(void)
{
	struct clean_status_config_digest a, b;

	digest_one(&a, "core.autocrlf", "true", NULL);
	digest_one(&b, "core.autocrlf", "false", NULL);
	cl_assert(!hashes_equal(a.semantic_hash, b.semantic_hash));
	cl_assert(a.semantic_config_explicit);
	cl_assert(b.semantic_config_explicit);
}

void test_clean_status_config__origin_only_affects_full_hash(void)
{
	struct key_value_info global_kvi = KVI_INIT;
	struct key_value_info local_kvi = KVI_INIT;
	struct config_context global_ctx = { .kvi = &global_kvi };
	struct config_context local_ctx = { .kvi = &local_kvi };
	struct clean_status_config_digest global, local;

	global_kvi.scope = CONFIG_SCOPE_GLOBAL;
	global_kvi.origin_type = CONFIG_ORIGIN_FILE;
	global_kvi.filename = "/global";
	local_kvi.scope = CONFIG_SCOPE_LOCAL;
	local_kvi.origin_type = CONFIG_ORIGIN_FILE;
	local_kvi.filename = "/local";
	digest_one(&global, "core.eol", "lf", &global_ctx);
	digest_one(&local, "core.eol", "lf", &local_ctx);
	cl_assert(!hashes_equal(global.hash, local.hash));
	cl_assert(hashes_equal(global.semantic_hash, local.semantic_hash));
}

static void digest_without_final_domain(
	const struct clean_status_config_digest *digest,
	unsigned char *full_hash, unsigned char *semantic_hash)
{
	struct git_hash_ctx full, semantic;

	git_hash_init(&full, &hash_algos[GIT_HASH_SHA1]);
	git_hash_init(&semantic, &hash_algos[GIT_HASH_SHA1]);
	git_hash_clone(&full, &digest->ctx);
	git_hash_clone(&semantic, &digest->semantic_ctx);
	git_hash_final(full_hash, &full);
	git_hash_final(semantic_hash, &semantic);
}

void test_clean_status_config__configured_filters_bump_proof_domains(void)
{
	static const char *const configured_suffixes[] = {
		"clean", "process", "required",
	};
	struct clean_status_config_digest smudge;
	unsigned char smudge_full[GIT_MAX_RAWSZ];
	unsigned char smudge_semantic[GIT_MAX_RAWSZ];

	for (size_t i = 0; i < ARRAY_SIZE(configured_suffixes); i++) {
		struct clean_status_config_digest configured;
		unsigned char full[GIT_MAX_RAWSZ];
		unsigned char semantic[GIT_MAX_RAWSZ];
		char *key = xstrfmt("filter.demo.%s", configured_suffixes[i]);

		clean_status_config_init(&configured, &hash_algos[GIT_HASH_SHA1]);
		clean_status_config_add(&configured, key, "command", NULL);
		digest_without_final_domain(&configured, full, semantic);
		clean_status_config_final(&configured);
		cl_assert(configured.filter_configured);
		cl_assert(configured.semantic_config_explicit);
		cl_assert(!hashes_equal(configured.hash, full));
		cl_assert(!hashes_equal(configured.semantic_hash, semantic));
		free(key);
	}

	clean_status_config_init(&smudge, &hash_algos[GIT_HASH_SHA1]);
	clean_status_config_add(
		&smudge, "filter.demo.smudge", "command", NULL);
	digest_without_final_domain(
		&smudge, smudge_full, smudge_semantic);
	clean_status_config_final(&smudge);

	cl_assert(!smudge.filter_configured);
	cl_assert(!smudge.semantic_config_explicit);
	cl_assert(hashes_equal(smudge.hash, smudge_full));
	cl_assert(hashes_equal(smudge.semantic_hash, smudge_semantic));
}
