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

void test_clean_status_config__command_transport_config_does_not_change_proof(void)
{
	static const char *const ignored_keys[] = {
		"credential.helper",
		"credential.https://Example/Team.helper",
		"url.https://Proxy.Example/Team/.insteadof",
		"url.https://Proxy.Example/Team/.pushinsteadof",
	};
	static const enum config_scope persistent_scopes[] = {
		CONFIG_SCOPE_GLOBAL,
		CONFIG_SCOPE_LOCAL,
		CONFIG_SCOPE_WORKTREE,
		CONFIG_SCOPE_UNKNOWN,
	};
	struct key_value_info kvi = KVI_INIT;
	struct config_context ctx = { .kvi = &kvi };
	struct clean_status_config_digest baseline, digest;

	clean_status_config_init(&baseline, &hash_algos[GIT_HASH_SHA1]);
	clean_status_config_final(&baseline);
	kvi.scope = CONFIG_SCOPE_COMMAND;
	kvi.origin_type = CONFIG_ORIGIN_CMDLINE;

	for (size_t i = 0; i < ARRAY_SIZE(ignored_keys); i++) {
		digest_one(&digest, ignored_keys[i], "transport", &ctx);
		cl_assert(hashes_equal(digest.hash, baseline.hash));
		cl_assert(hashes_equal(digest.semantic_hash,
				       baseline.semantic_hash));
		cl_assert(!digest.filter_configured);
		cl_assert(!digest.semantic_config_explicit);

		for (size_t j = 0; j < ARRAY_SIZE(persistent_scopes); j++) {
			kvi.scope = persistent_scopes[j];
			digest_one(&digest, ignored_keys[i], "transport", &ctx);
			cl_assert(!hashes_equal(digest.hash, baseline.hash));
		}
		kvi.scope = CONFIG_SCOPE_COMMAND;
		digest_one(&digest, ignored_keys[i], "transport", NULL);
		cl_assert(!hashes_equal(digest.hash, baseline.hash));
	}
}

void test_clean_status_config__command_preload_config_does_not_change_proof(void)
{
	static const char *const ignored_keys[] = {
		"core.preloadindex",
		"core.preloadindexbulk",
	};
	static const enum config_scope persistent_scopes[] = {
		CONFIG_SCOPE_SYSTEM,
		CONFIG_SCOPE_GLOBAL,
		CONFIG_SCOPE_LOCAL,
		CONFIG_SCOPE_WORKTREE,
		CONFIG_SCOPE_UNKNOWN,
	};
	static const int algorithms[] = {
		GIT_HASH_SHA1,
		GIT_HASH_SHA256,
	};
	struct key_value_info kvi = KVI_INIT;
	struct config_context ctx = { .kvi = &kvi };

	kvi.origin_type = CONFIG_ORIGIN_CMDLINE;
	for (size_t i = 0; i < ARRAY_SIZE(algorithms); i++) {
		const struct git_hash_algo *algo = &hash_algos[algorithms[i]];
		struct clean_status_config_digest baseline, digest;

		clean_status_config_init(&baseline, algo);
		clean_status_config_final(&baseline);
		for (size_t j = 0; j < ARRAY_SIZE(ignored_keys); j++) {
			kvi.scope = CONFIG_SCOPE_COMMAND;
			clean_status_config_init(&digest, algo);
			clean_status_config_add(&digest, ignored_keys[j],
						"true", &ctx);
			clean_status_config_final(&digest);
			cl_assert(hasheq(digest.hash, baseline.hash, algo));
			cl_assert(hasheq(digest.semantic_hash,
					 baseline.semantic_hash, algo));
			cl_assert(hasheq(digest.tracked_policy_hash,
					 baseline.tracked_policy_hash, algo));

			for (size_t scope = 0;
			     scope < ARRAY_SIZE(persistent_scopes); scope++) {
				kvi.scope = persistent_scopes[scope];
				clean_status_config_init(&digest, algo);
				clean_status_config_add(&digest, ignored_keys[j],
							"true", &ctx);
				clean_status_config_final(&digest);
				cl_assert(!hasheq(digest.hash,
						  baseline.hash, algo));
				cl_assert(hasheq(digest.semantic_hash,
						 baseline.semantic_hash, algo));
				cl_assert(hasheq(digest.tracked_policy_hash,
						 baseline.tracked_policy_hash, algo));
			}

			clean_status_config_init(&digest, algo);
			clean_status_config_add(&digest, ignored_keys[j],
						"true", NULL);
			clean_status_config_final(&digest);
			cl_assert(!hasheq(digest.hash, baseline.hash, algo));
		}

		kvi.scope = CONFIG_SCOPE_COMMAND;
		clean_status_config_init(&digest, algo);
		clean_status_config_add(&digest, "core.filemode", "true", &ctx);
		clean_status_config_final(&digest);
		cl_assert(!hasheq(digest.hash, baseline.hash, algo));
		cl_assert(!hasheq(digest.tracked_policy_hash,
				  baseline.tracked_policy_hash, algo));

		clean_status_config_init(&digest, algo);
		clean_status_config_add(&digest, "core.autocrlf", "true", &ctx);
		clean_status_config_final(&digest);
		cl_assert(!hasheq(digest.hash, baseline.hash, algo));
		cl_assert(!hasheq(digest.semantic_hash,
				  baseline.semantic_hash, algo));
	}
}

void test_clean_status_config__only_complete_disabled_filters_are_normalized(void)
{
	static const char *const keys[] = {
		"filter.demo.clean", "filter.demo.smudge",
		"filter.demo.process", "filter.demo.required",
	};
	static const char *const values[] = { "", "", "", "false" };
	static const int algorithms[] = { GIT_HASH_SHA1, GIT_HASH_SHA256 };
	struct key_value_info kvi = KVI_INIT;
	struct config_context ctx = { .kvi = &kvi };

	kvi.origin_type = CONFIG_ORIGIN_CMDLINE;
	for (size_t a = 0; a < ARRAY_SIZE(algorithms); a++) {
		const struct git_hash_algo *algo = &hash_algos[algorithms[a]];
		struct clean_status_config_digest baseline, digest;

		kvi.scope = CONFIG_SCOPE_LOCAL;
		clean_status_config_init(&baseline, algo);
		clean_status_config_add(&baseline, keys[0], "configured", &ctx);
		clean_status_config_final(&baseline);
		cl_assert(!baseline.normalized_filter_disable);

		for (unsigned mask = 0; mask < (1U << ARRAY_SIZE(keys)); mask++) {
			clean_status_config_init(&digest, algo);
			kvi.scope = CONFIG_SCOPE_LOCAL;
			clean_status_config_add(&digest, keys[0], "configured", &ctx);
			kvi.scope = CONFIG_SCOPE_COMMAND;
			for (size_t part = 0; part < ARRAY_SIZE(keys); part++) {
				if (mask & (1U << part))
					clean_status_config_add(&digest, keys[part],
								values[part], &ctx);
			}
			clean_status_config_final(&digest);
			cl_assert_equal_i(hasheq(digest.hash, baseline.hash, algo),
					  !mask || mask == 15);
			cl_assert_equal_i(digest.normalized_filter_disable,
					  mask == 15);
			if (mask == 15) {
				cl_assert(hasheq(digest.semantic_hash,
						 baseline.semantic_hash, algo));
				cl_assert(hasheq(digest.tracked_policy_hash,
						 baseline.tracked_policy_hash, algo));
			}
		}

		for (unsigned hostile = 0; hostile < 5; hostile++) {
			clean_status_config_init(&digest, algo);
			kvi.scope = CONFIG_SCOPE_LOCAL;
			clean_status_config_add(&digest, keys[0], "configured", &ctx);
			kvi.scope = CONFIG_SCOPE_COMMAND;
			for (size_t part = 0; part < ARRAY_SIZE(keys); part++) {
				const char *key = keys[part];
				const char *value = values[part];

				if (hostile == 0 && part == 1)
					clean_status_config_add(&digest, keys[0], "", &ctx);
				if (hostile == 1 && part == 1)
					clean_status_config_add(&digest, "core.hookspath",
								"/dev/null", &ctx);
				if (hostile == 2 && part == 2)
					key = "filter.other.process";
				if (hostile == 3 && part == 0)
					value = "unsafe-helper";
				if (hostile == 4 && part == 3)
					value = "true";
				clean_status_config_add(&digest, key, value, &ctx);
			}
			clean_status_config_final(&digest);
			cl_assert(!hasheq(digest.hash, baseline.hash, algo));
		}
	}
}

void test_clean_status_config__only_safe_command_guards_are_normalized(void)
{
	static const char *const keys[] = {
		"core.hookspath", "safe.barerepository",
		"hook.post-index-change.enabled",
	};
	static const char *const safe[] = { "/dev/null", "explicit", "false" };
	static const char *const unsafe[] = { "/tmp/unsafe-hook", "all", "true" };
	static const char *const previous[] = {
		"true", "false", "true", "/tmp/hook", "true", NULL,
	};
	static const char *const next[] = {
		"true", "false", "false", "true", "/tmp/hook", "true",
	};
	static const int algorithms[] = { GIT_HASH_SHA1, GIT_HASH_SHA256 };
	struct key_value_info kvi = KVI_INIT;
	struct config_context ctx = { .kvi = &kvi };

	kvi.origin_type = CONFIG_ORIGIN_CMDLINE;
	for (size_t a = 0; a < ARRAY_SIZE(algorithms); a++) {
		const struct git_hash_algo *algo = &hash_algos[algorithms[a]];
		struct clean_status_config_digest baseline, digest;

		clean_status_config_init(&baseline, algo);
		clean_status_config_final(&baseline);
		for (size_t guard = 0; guard < ARRAY_SIZE(keys); guard++) {
			kvi.scope = CONFIG_SCOPE_COMMAND;
			clean_status_config_init(&digest, algo);
			clean_status_config_add(&digest, keys[guard], safe[guard], &ctx);
			clean_status_config_final(&digest);
			cl_assert(hasheq(digest.hash, baseline.hash, algo));
			cl_assert(hasheq(digest.semantic_hash,
					 baseline.semantic_hash, algo));
			cl_assert(hasheq(digest.tracked_policy_hash,
					 baseline.tracked_policy_hash, algo));

			kvi.scope = CONFIG_SCOPE_LOCAL;
			clean_status_config_init(&digest, algo);
			clean_status_config_add(&digest, keys[guard], safe[guard], &ctx);
			clean_status_config_final(&digest);
			cl_assert(!hasheq(digest.hash, baseline.hash, algo));

			kvi.scope = CONFIG_SCOPE_COMMAND;
			clean_status_config_init(&digest, algo);
			clean_status_config_add(&digest, keys[guard], unsafe[guard], &ctx);
			clean_status_config_final(&digest);
			cl_assert(!hasheq(digest.hash, baseline.hash, algo));

			clean_status_config_init(&digest, algo);
			clean_status_config_add(&digest, keys[guard], safe[guard], NULL);
			clean_status_config_final(&digest);
			cl_assert(!hasheq(digest.hash, baseline.hash, algo));
		}

		for (size_t state = 0; state < ARRAY_SIZE(previous); state++) {
			kvi.scope = CONFIG_SCOPE_LOCAL;
			clean_status_config_init(&baseline, algo);
			if (previous[state])
				clean_status_config_add(&baseline, "core.fsmonitor",
							previous[state], &ctx);
			clean_status_config_final(&baseline);

			clean_status_config_init(&digest, algo);
			if (previous[state])
				clean_status_config_add(&digest, "core.fsmonitor",
							previous[state], &ctx);
			kvi.scope = CONFIG_SCOPE_COMMAND;
			clean_status_config_add(&digest, "core.fsmonitor", next[state], &ctx);
			clean_status_config_final(&digest);
			cl_assert_equal_i(hasheq(digest.hash, baseline.hash, algo),
					  state < 2);
		}
	}
}

void test_clean_status_config__command_empty_attributes_do_not_change_proof(void)
{
	static const enum config_scope persistent_scopes[] = {
		CONFIG_SCOPE_SYSTEM,
		CONFIG_SCOPE_GLOBAL,
		CONFIG_SCOPE_LOCAL,
		CONFIG_SCOPE_WORKTREE,
		CONFIG_SCOPE_UNKNOWN,
	};
	static const int algorithms[] = {
		GIT_HASH_SHA1,
		GIT_HASH_SHA256,
	};
	struct key_value_info kvi = KVI_INIT;
	struct config_context ctx = { .kvi = &kvi };

	kvi.origin_type = CONFIG_ORIGIN_CMDLINE;
	for (size_t i = 0; i < ARRAY_SIZE(algorithms); i++) {
		const struct git_hash_algo *algo = &hash_algos[algorithms[i]];
		struct clean_status_config_digest baseline, digest;

		clean_status_config_init(&baseline, algo);
		clean_status_config_final(&baseline);
		kvi.scope = CONFIG_SCOPE_COMMAND;
		clean_status_config_init(&digest, algo);
		clean_status_config_add(&digest, "core.attributesfile", "", &ctx);
		clean_status_config_final(&digest);
		cl_assert(hasheq(digest.hash, baseline.hash, algo));
		cl_assert(hasheq(digest.semantic_hash,
				 baseline.semantic_hash, algo));
		cl_assert(hasheq(digest.tracked_policy_hash,
				 baseline.tracked_policy_hash, algo));

		clean_status_config_init(&digest, algo);
		clean_status_config_add(&digest, "attr.tree", "", &ctx);
		clean_status_config_final(&digest);
		cl_assert(hasheq(digest.hash, baseline.hash, algo));
		cl_assert(hasheq(digest.semantic_hash,
				 baseline.semantic_hash, algo));
		cl_assert(hasheq(digest.tracked_policy_hash,
				 baseline.tracked_policy_hash, algo));
		cl_assert(!digest.attribute_tree_configured);

		for (size_t scope = 0; scope < ARRAY_SIZE(persistent_scopes);
		     scope++) {
			kvi.scope = persistent_scopes[scope];
			clean_status_config_init(&digest, algo);
			clean_status_config_add(&digest, "core.attributesfile",
						"", &ctx);
			clean_status_config_final(&digest);
			cl_assert(!hasheq(digest.hash, baseline.hash, algo));
			cl_assert(!hasheq(digest.tracked_policy_hash,
					  baseline.tracked_policy_hash, algo));

			clean_status_config_init(&digest, algo);
			clean_status_config_add(&digest, "attr.tree", "", &ctx);
			clean_status_config_final(&digest);
			cl_assert(!hasheq(digest.hash, baseline.hash, algo));
		}

		kvi.scope = CONFIG_SCOPE_COMMAND;
		clean_status_config_init(&digest, algo);
		clean_status_config_add(&digest, "core.attributesfile",
					"/tmp/attributes", &ctx);
		clean_status_config_final(&digest);
		cl_assert(!hasheq(digest.hash, baseline.hash, algo));
		cl_assert(!hasheq(digest.tracked_policy_hash,
				  baseline.tracked_policy_hash, algo));

		clean_status_config_init(&digest, algo);
		clean_status_config_add(&digest, "core.attributesfile", "", NULL);
		clean_status_config_final(&digest);
		cl_assert(!hasheq(digest.hash, baseline.hash, algo));

		clean_status_config_init(&digest, algo);
		clean_status_config_add(&digest, "core.attributesfile", NULL, &ctx);
		clean_status_config_final(&digest);
		cl_assert(!hasheq(digest.hash, baseline.hash, algo));

		clean_status_config_init(&baseline, algo);
		kvi.scope = CONFIG_SCOPE_LOCAL;
		clean_status_config_add(&baseline, "attr.tree", "HEAD", &ctx);
		clean_status_config_final(&baseline);
		cl_assert(baseline.attribute_tree_configured);

		clean_status_config_init(&digest, algo);
		clean_status_config_add(&digest, "attr.tree", "HEAD", &ctx);
		kvi.scope = CONFIG_SCOPE_COMMAND;
		clean_status_config_add(&digest, "attr.tree", "", &ctx);
		clean_status_config_final(&digest);
		cl_assert(digest.attribute_tree_configured);
		cl_assert(!hasheq(digest.hash, baseline.hash, algo));
	}
}

void test_clean_status_config__command_worktree_config_still_changes_proof(void)
{
	static const char *const retained_keys[] = {
		"url.insteadof",
		"url.https://Proxy.Example/Team/.other",
		"core.excludesfile",
		"status.showuntrackedfiles",
	};
	struct key_value_info kvi = KVI_INIT;
	struct config_context ctx = { .kvi = &kvi };
	struct clean_status_config_digest baseline, digest;

	clean_status_config_init(&baseline, &hash_algos[GIT_HASH_SHA1]);
	clean_status_config_final(&baseline);
	kvi.scope = CONFIG_SCOPE_COMMAND;
	kvi.origin_type = CONFIG_ORIGIN_CMDLINE;

	for (size_t i = 0; i < ARRAY_SIZE(retained_keys); i++) {
		digest_one(&digest, retained_keys[i], "value", &ctx);
		cl_assert(!hashes_equal(digest.hash, baseline.hash));
		cl_assert(hashes_equal(digest.semantic_hash,
				       baseline.semantic_hash));
	}

	digest_one(&digest, "core.autocrlf", "true", &ctx);
	cl_assert(!hashes_equal(digest.hash, baseline.hash));
	cl_assert(!hashes_equal(digest.semantic_hash, baseline.semantic_hash));
	cl_assert(digest.semantic_config_explicit);
	cl_assert(!digest.filter_configured);

	digest_one(&digest, "filter.demo.clean", "cat", &ctx);
	cl_assert(!hashes_equal(digest.hash, baseline.hash));
	cl_assert(!hashes_equal(digest.semantic_hash, baseline.semantic_hash));
	cl_assert(digest.semantic_config_explicit);
	cl_assert(digest.filter_configured);
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
	cl_assert(state->filter_configured);
	cl_assert(!state->filter_scope_valid);
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
	cl_assert(!memcmp(state->current_attr_portable_namespace_hash,
			  attrs.portable_namespace_hash, algo->rawsz));

	clean_status_set_config_digest(&repo_a, &replacement);
	clean_status_attach_config(&istate_a);
	cl_assert(hashes_equal(state->current_config_hash, digest.hash));
	cl_assert(hashes_equal(state->current_semantic_hash,
			       digest.semantic_hash));
	cl_assert(state->filter_configured);
	cl_assert(!state->filter_scope_valid);

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
