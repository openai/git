#include "unit-test.h"
#include "attr-fingerprint.h"
#include "clean-status.h"
#include "clean-status-config.h"
#include "clean-status-internal.h"
#include "config.h"
#include "dir.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "strbuf.h"
#include "wrapper.h"

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

void test_clean_status_config__clean_filters_are_unsafe(void)
{
	struct clean_status_config_digest clean, smudge;

	digest_one(&clean, "filter.demo.clean", "command", NULL);
	digest_one(&smudge, "filter.demo.smudge", "command", NULL);
	cl_assert(clean.unsafe_filter);
	cl_assert(clean.semantic_config_explicit);
	cl_assert(!smudge.unsafe_filter);
	cl_assert(!smudge.semantic_config_explicit);
}

#if defined(O_NONBLOCK) && !defined(GIT_WINDOWS_NATIVE)
static char *create_gitdir(int with_attributes)
{
	const char *tmp = getenv("TMPDIR");
	char *gitdir = xstrfmt("%s/clean-status-config.XXXXXX",
			      tmp ? tmp : "/tmp");
	struct strbuf path = STRBUF_INIT;

	cl_assert(mkdtemp(gitdir) != NULL);
	if (with_attributes) {
		strbuf_addf(&path, "%s/info", gitdir);
		cl_assert_equal_i(mkdir(path.buf, 0777), 0);
		strbuf_addstr(&path, "/attributes");
		write_file(path.buf, "*.txt text\n");
	}
	strbuf_release(&path);
	return gitdir;
}

static void remove_gitdir(char *gitdir)
{
	struct strbuf path = STRBUF_INIT;

	strbuf_addstr(&path, gitdir);
	cl_assert_equal_i(remove_dir_recursively(&path, 0), 0);
	strbuf_release(&path);
	free(gitdir);
}

static void clear_staged_config(void *unused UNUSED)
{
	clean_status_set_config_digest(NULL, NULL);
}
#endif

void test_clean_status_config__attaches_only_to_the_staged_repository(void)
{
#if !defined(O_NONBLOCK) || defined(GIT_WINDOWS_NATIVE)
	cl_skip();
#else
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	char *gitdir_a = create_gitdir(1);
	char *gitdir_b = create_gitdir(0);
	struct repository repo_a = {
		.gitdir = gitdir_a,
		.commondir = gitdir_a,
		.hash_algo = algo,
	};
	struct repository repo_b = {
		.gitdir = gitdir_b,
		.commondir = gitdir_b,
		.hash_algo = algo,
	};
	struct index_state istate_a = INDEX_STATE_INIT(&repo_a);
	struct index_state istate_b = INDEX_STATE_INIT(&repo_b);
	struct clean_status_config_digest digest, replacement;
	struct clean_status_state *state;
	struct attr_fingerprint attrs;

	cl_set_cleanup(clear_staged_config, NULL);
	digest_one(&digest, "filter.demo.clean", "cat", NULL);
	digest_one(&replacement, "core.autocrlf", "false", NULL);
	cl_assert_equal_i(attr_fingerprint_repository(&repo_a, &attrs), 0);
	cl_assert(attrs.sources_present);

	clean_status_set_config_digest(&repo_a, &digest);
	clean_status_attach_config(&istate_b);
	cl_assert_equal_p(istate_b.clean_status, NULL);
	clean_status_attach_config(&istate_a);
	state = istate_a.clean_status;
	cl_assert(state != NULL);
	cl_assert(state->current_config_valid);
	cl_assert(state->current_semantic_valid);
	cl_assert(state->current_attr_valid);
	cl_assert(state->config_enforced);
	cl_assert(state->unsafe_filter);
	cl_assert(state->current_semantic_explicit);
	cl_assert_equal_i(state->current_attr_sources_present,
			  attrs.sources_present);
	cl_assert(hashes_equal(state->current_config_hash, digest.hash));
	cl_assert(hashes_equal(state->current_semantic_hash,
			       digest.semantic_hash));
	cl_assert(!memcmp(state->current_attr_hash, attrs.content_hash,
			  algo->rawsz));
	cl_assert(!memcmp(state->current_attr_namespace_hash,
			  attrs.namespace_hash, algo->rawsz));

	clean_status_set_config_digest(&repo_a, &replacement);
	clean_status_attach_config(&istate_a);
	cl_assert(hashes_equal(state->current_config_hash, digest.hash));
	cl_assert(hashes_equal(state->current_semantic_hash,
			       digest.semantic_hash));
	cl_assert(state->unsafe_filter);

	release_index(&istate_a);
	cl_assert_equal_p(istate_a.clean_status, NULL);
	release_index(&istate_b);
	clear_staged_config(NULL);
	if (repo_a.config) {
		git_configset_clear(repo_a.config);
		FREE_AND_NULL(repo_a.config);
	}
	if (repo_b.config) {
		git_configset_clear(repo_b.config);
		FREE_AND_NULL(repo_b.config);
	}
	repo_settings_clear(&repo_a);
	repo_settings_clear(&repo_b);
	remove_gitdir(gitdir_b);
	remove_gitdir(gitdir_a);
#endif
}
