#include "git-compat-util.h"
#include "clean-status-config.h"
#include "config.h"
#include "hash-framing.h"
#include "strbuf.h"

#define CLEAN_STATUS_FILTER_PROOF_DOMAIN \
	"clean-status-configured-filter-scope-v1"

void clean_status_config_init(struct clean_status_config_digest *digest,
			      const struct git_hash_algo *algo)
{
	if (!algo)
		BUG("clean-status config digest requires a hash algorithm");
	memset(digest, 0, sizeof(*digest));
	git_hash_init(&digest->ctx, algo);
	git_hash_init(&digest->semantic_ctx, algo);
	/* Invalidate proofs written before multiply-linked files stayed dirty. */
	hash_optional_cstring(&digest->ctx,
			      "clean-status-config-hardlink-v1");
	digest->initialized = 1;
}

static void hash_config_entry(struct git_hash_ctx *ctx,
			      const char *key, const char *value,
			      const struct config_context *config_ctx)
{
	uint32_t metadata[2] = { 0 };

	hash_optional_cstring(ctx, key);
	hash_optional_cstring(ctx, value);
	if (config_ctx && config_ctx->kvi) {
		put_be32(&metadata[0], config_ctx->kvi->scope);
		put_be32(&metadata[1], config_ctx->kvi->origin_type);
		hash_length_delimited(ctx, metadata, sizeof(metadata));
		hash_optional_cstring(ctx, config_ctx->kvi->filename);
	} else {
		hash_length_delimited(ctx, metadata, sizeof(metadata));
		hash_optional_cstring(ctx, NULL);
	}
}

static void hash_effective_config_entry(struct git_hash_ctx *ctx,
					const char *key,
					const char *value)
{
	hash_optional_cstring(ctx, key);
	hash_optional_cstring(ctx, value);
}

void clean_status_config_add(struct clean_status_config_digest *digest,
			     const char *key, const char *value,
			     const struct config_context *ctx)
{
	const char *suffix;
	int semantic;

	if (!digest->initialized || digest->finalized)
		BUG("invalid clean-status config digest state");
	hash_config_entry(&digest->ctx, key, value, ctx);
	semantic = !strcmp(key, "core.autocrlf") ||
		!strcmp(key, "core.eol") ||
		!strcmp(key, "core.checkroundtripencoding");
	if (skip_prefix(key, "filter.", &suffix) &&
	    (ends_with(suffix, ".clean") || ends_with(suffix, ".process") ||
	     ends_with(suffix, ".required"))) {
		digest->filter_configured = 1;
		semantic = 1;
	}
	if (semantic) {
		hash_effective_config_entry(&digest->semantic_ctx, key, value);
		digest->semantic_config_explicit = 1;
	}
}

void clean_status_config_final(struct clean_status_config_digest *digest)
{
	if (!digest->initialized || digest->finalized)
		BUG("invalid clean-status config digest state");
	if (digest->filter_configured) {
		/*
		 * Leave repositories without configured clean filters in their
		 * existing proof domain. Configured filters require a proof which
		 * has classified every tracked path before it may be reused.
		 */
		hash_optional_cstring(&digest->ctx,
				      CLEAN_STATUS_FILTER_PROOF_DOMAIN);
		hash_optional_cstring(&digest->semantic_ctx,
				      CLEAN_STATUS_FILTER_PROOF_DOMAIN);
	}
	git_hash_final(digest->hash, &digest->ctx);
	git_hash_final(digest->semantic_hash, &digest->semantic_ctx);
	digest->finalized = 1;
}
