#include "git-compat-util.h"
#include "abspath.h"
#include "clean-status-config.h"
#include "clean-status-index.h"
#include "config.h"
#include "environment.h"
#include "hash-framing.h"
#include "path-namespace.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "strbuf.h"
#include "wrapper.h"

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
	git_hash_init(&digest->tracked_policy_ctx, algo);
	hash_optional_cstring(&digest->tracked_policy_ctx,
			      "clean-status-tracked-policy-v1");
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

static int config_is_command_transport(const char *key,
				       const struct config_context *ctx)
{
	const char *subsection, *subkey;
	size_t subsection_len;

	if (!ctx || !ctx->kvi || ctx->kvi->scope != CONFIG_SCOPE_COMMAND)
		return 0;
	if (starts_with(key, "credential."))
		return 1;
	if (parse_config_key(key, "url", &subsection, &subsection_len,
			     &subkey) || !subsection || !subsection_len)
		return 0;
	return !strcmp(subkey, "insteadof") ||
		!strcmp(subkey, "pushinsteadof");
}

static int config_is_command_acceleration(const char *key,
					  const struct config_context *ctx)
{
	return ctx && ctx->kvi && ctx->kvi->scope == CONFIG_SCOPE_COMMAND &&
		(!strcmp(key, "core.preloadindex") ||
		 !strcmp(key, "core.preloadindexbulk"));
}

static int config_is_tracked_policy(const char *key)
{
	return !strcmp(key, "core.filemode") ||
		!strcmp(key, "core.trustctime") ||
		!strcmp(key, "core.checkstat") ||
		!strcmp(key, "core.symlinks") ||
		!strcmp(key, "core.ignorecase") ||
		!strcmp(key, "core.ignorestat") ||
		!strcmp(key, "core.sparsecheckout") ||
		!strcmp(key, "core.sparsecheckoutcone") ||
		!strcmp(key, "core.precomposeunicode") ||
		!strcmp(key, "core.protecthfs") ||
		!strcmp(key, "core.protectntfs") ||
		!strcmp(key, "core.excludesfile") ||
		!strcmp(key, "core.attributesfile");
}

void clean_status_config_add(struct clean_status_config_digest *digest,
			     const char *key, const char *value,
			     const struct config_context *ctx)
{
	const char *suffix;
	int semantic;

	if (!digest->initialized || digest->finalized)
		BUG("invalid clean-status config digest state");
	/* Process-local transport and traversal settings cannot change a proof. */
	if (config_is_command_transport(key, ctx) ||
	    config_is_command_acceleration(key, ctx))
		return;
	hash_config_entry(&digest->ctx, key, value, ctx);
	if (config_is_tracked_policy(key))
		hash_effective_config_entry(&digest->tracked_policy_ctx,
					    key, value);
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
	git_hash_final(digest->tracked_policy_hash,
		       &digest->tracked_policy_ctx);
	digest->finalized = 1;
}

static int config_digest_callback(const char *key, const char *value,
				  const struct config_context *ctx,
				  void *data)
{
	clean_status_config_add(data, key, value, ctx);
	return 0;
}

int clean_status_config_read_repository(
	struct repository *repo,
	struct clean_status_config_digest *digest)
{
	struct config_options opts = { 0 };

	clean_status_config_init(digest, repo->hash_algo);
	opts.respect_includes = 1;
	opts.commondir = repo->commondir;
	opts.git_dir = repo->gitdir;
	if (config_with_options(config_digest_callback, digest, NULL,
				repo, &opts) < 0)
		return -1;
	clean_status_config_final(digest);
	return 0;
}

#ifdef __APPLE__
struct config_epoch_source {
	char *path;
	struct path_namespace_snapshot *namespace;
	struct stat stat;
	int fd;
};

struct config_epoch_proof {
	struct config_epoch_source *sources;
	char *system_path;
	size_t nr;
	size_t alloc;
	struct stat index;
	int failed;
	int system_seen;
};

static int config_epoch_command_is_safe(
	const char *key, const struct config_context *ctx)
{
	return starts_with(key, "advice.") ||
		!strcmp(key, "user.name") || !strcmp(key, "user.email") ||
		!strcmp(key, "core.preloadindexbulk") ||
		config_is_command_transport(key, ctx);
}

static int config_epoch_source_precedes_index(
	const struct stat *source, const struct stat *index)
{
	return source->st_ctimespec.tv_sec < index->st_birthtimespec.tv_sec ||
		(source->st_ctimespec.tv_sec ==
		 index->st_birthtimespec.tv_sec &&
		 source->st_ctimespec.tv_nsec <
		 index->st_birthtimespec.tv_nsec);
}

static int config_epoch_capture_source(
	const char *key, const char *value UNUSED,
	const struct config_context *ctx, void *data)
{
	struct config_epoch_proof *proof = data;
	struct config_epoch_source *source;
	struct path_namespace_snapshot *after = NULL;
	struct strbuf normalized = STRBUF_INIT;
	struct stat named;
	char *absolute = NULL;
	int fd = -1;
	int allocated = 0;

	if (proof->failed)
		return 0;
	if (!ctx || !ctx->kvi)
		goto fail;
	if (ctx->kvi->scope == CONFIG_SCOPE_COMMAND) {
		if (!config_epoch_command_is_safe(key, ctx))
			goto fail;
		return 0;
	}
	if (starts_with(key, "includeif."))
		goto fail;
	if (ctx->kvi->origin_type != CONFIG_ORIGIN_FILE ||
	    !ctx->kvi->filename || !*ctx->kvi->filename)
		goto fail;
	for (size_t i = 0; i < proof->nr; i++)
		if (!strcmp(proof->sources[i].path, ctx->kvi->filename))
			return 0;
	absolute = absolute_pathdup(ctx->kvi->filename);
	strbuf_addstr(&normalized, absolute);
	if (strbuf_normalize_path(&normalized))
		goto fail;
	if (ctx->kvi->scope == CONFIG_SCOPE_SYSTEM &&
	    proof->system_path && strcmp(normalized.buf, proof->system_path))
		goto fail;
	fd = open_nofollow(normalized.buf, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		goto fail;
	ALLOC_GROW(proof->sources, proof->nr + 1, proof->alloc);
	source = &proof->sources[proof->nr];
	memset(source, 0, sizeof(*source));
	source->fd = -1;
	allocated = 1;
	if (fstat(fd, &source->stat) ||
	    !S_ISREG(source->stat.st_mode) ||
	    source->stat.st_nlink != 1 ||
	    (!is_path_owned_by_current_user(normalized.buf, NULL) &&
	     !(source->stat.st_uid == 0 &&
	       ctx->kvi->scope == CONFIG_SCOPE_SYSTEM)) ||
	    !config_epoch_source_precedes_index(&source->stat, &proof->index) ||
	    lstat(normalized.buf, &named) ||
	    !path_namespace_stat_equal(&source->stat, &named) ||
	    path_namespace_capture(normalized.buf, &source->namespace) ||
	    !path_namespace_target_present(source->namespace) ||
	    path_namespace_capture(normalized.buf, &after) ||
	    !path_namespace_equal(source->namespace, after))
		goto fail;
	source->path = xstrdup(ctx->kvi->filename);
	source->fd = fd;
	proof->nr++;
	if (ctx->kvi->scope == CONFIG_SCOPE_SYSTEM && proof->system_path)
		proof->system_seen = 1;
	fd = -1;
	path_namespace_clear(after);
	strbuf_release(&normalized);
	free(absolute);
	return 0;

fail:
	if (fd >= 0)
		close(fd);
	if (allocated)
		path_namespace_clear(proof->sources[proof->nr].namespace);
	path_namespace_clear(after);
	strbuf_release(&normalized);
	free(absolute);
	proof->failed = 1;
	return 0;
}

static int config_epoch_sources_still_match(
	const struct config_epoch_proof *proof)
{
	for (size_t i = 0; i < proof->nr; i++) {
		const struct config_epoch_source *source = &proof->sources[i];
		struct path_namespace_snapshot *namespace = NULL;
		struct strbuf normalized = STRBUF_INIT;
		struct stat held, named;
		char *absolute = absolute_pathdup(source->path);
		int valid;

		strbuf_addstr(&normalized, absolute);
		valid = !strbuf_normalize_path(&normalized) &&
			!fstat(source->fd, &held) &&
			!lstat(normalized.buf, &named) &&
			path_namespace_stat_equal(&source->stat, &held) &&
			path_namespace_stat_equal(&held, &named) &&
			config_epoch_source_precedes_index(&held, &proof->index) &&
			!path_namespace_capture(normalized.buf, &namespace) &&
			path_namespace_equal(source->namespace, namespace);
		path_namespace_clear(namespace);
		strbuf_release(&normalized);
		free(absolute);
		if (!valid)
			return 0;
	}
	return 1;
}
#endif

int clean_status_config_tracked_sources_predate_index(
	struct index_state *istate)
{
#ifdef __APPLE__
	struct clean_status_index_snapshot snapshot = { .fd = -1 };
	struct config_epoch_proof proof = { 0 };
	struct config_options opts = { 0 };
	const char *system_path = getenv("GIT_CONFIG_SYSTEM");
	int valid = 0;

	/*
	 * Version-one proofs did not record their tracked-stat policy. The
	 * shipped writer is trusted not to have used transient tracked-policy
	 * overrides; stable configuration sources older than its index then
	 * authenticate the one-time migration. Version-two proofs carry their
	 * complete policy instead and never use this compatibility exception.
	 */
	if (!istate || getenv("GIT_CONFIG_GLOBAL") ||
	    getenv(GIT_WORK_TREE_ENVIRONMENT) ||
	    getenv(GIT_COMMON_DIR_ENVIRONMENT) ||
	    getenv(INDEX_ENVIRONMENT) ||
	    getenv(ALTERNATE_DB_ENVIRONMENT) ||
	    clean_status_index_snapshot_pin(&snapshot, istate) ||
	    fstat(snapshot.fd, &proof.index) ||
	    proof.index.st_birthtimespec.tv_sec <= 0)
		goto done;
	if (system_path) {
		struct strbuf normalized = STRBUF_INIT;

		if (!is_absolute_path(system_path))
			goto done;
		strbuf_addstr(&normalized, system_path);
		if (strbuf_normalize_path(&normalized)) {
			strbuf_release(&normalized);
			goto done;
		}
		proof.system_path = strbuf_detach(&normalized, NULL);
	}
	opts.respect_includes = 1;
	opts.commondir = istate->repo->commondir;
	opts.git_dir = istate->repo->gitdir;
	if (config_with_options(config_epoch_capture_source, &proof, NULL,
				istate->repo, &opts) < 0 ||
	    proof.failed || !proof.nr ||
	    (proof.system_path && !proof.system_seen) ||
	    !config_epoch_sources_still_match(&proof) ||
	    !clean_status_index_snapshot_still_matches_proof_epoch(
		&snapshot, istate))
		goto done;
	valid = 1;

done:
	free(proof.system_path);
	for (size_t i = 0; i < proof.nr; i++) {
		close(proof.sources[i].fd);
		path_namespace_clear(proof.sources[i].namespace);
		free(proof.sources[i].path);
	}
	free(proof.sources);
	clean_status_index_snapshot_release(&snapshot);
	return valid;
#else
	(void)istate;
	return 0;
#endif
}
