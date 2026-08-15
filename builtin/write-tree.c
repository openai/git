/*
 * GIT - The information manager from hell
 *
 * Copyright (C) Linus Torvalds, 2005
 */
#define USE_THE_REPOSITORY_VARIABLE
#include "builtin.h"
#include "abspath.h"
#include "clean-status.h"
#include "clean-status-config.h"
#include "config.h"
#include "environment.h"
#include "gettext.h"
#include "hex.h"
#include "strbuf.h"
#include "tree.h"
#include "cache-tree.h"
#include "parse-options.h"

static const char * const write_tree_usage[] = {
	N_("git write-tree [--missing-ok] [--prefix=<prefix>/]"),
	NULL
};

static int write_tree_config(const char *key, const char *value,
			     const struct config_context *ctx, void *data)
{
	clean_status_config_add(data, key, value, ctx);
	return git_default_config(key, value, ctx, NULL);
}

static int write_tree_uses_worktree_index(void)
{
	const char *index_file = getenv(INDEX_ENVIRONMENT);
	struct strbuf worktree_index = STRBUF_INIT;
	struct stat st;
	char *expected = NULL, *actual = NULL;
	int matches = 0;

	if (!index_file)
		return 1;
	if (lstat(index_file, &st) || S_ISLNK(st.st_mode))
		return 0;

	strbuf_addf(&worktree_index, "%s/index",
		    repo_get_git_dir(the_repository));
	expected = real_pathdup(worktree_index.buf, 0);
	actual = real_pathdup(index_file, 0);
	if (expected && actual && !strcmp(expected, actual))
		matches = 1;

	free(expected);
	free(actual);
	strbuf_release(&worktree_index);
	return matches;
}

int cmd_write_tree(int argc,
		   const char **argv,
		   const char *cmd_prefix,
		   struct repository *repo UNUSED)
{
	struct clean_status_config_digest clean_digest;
	int flags = 0, ret;
	const char *tree_prefix = NULL;
	struct object_id oid;
	const char *me = "git-write-tree";
	struct option write_tree_options[] = {
		OPT_BIT(0, "missing-ok", &flags, N_("allow missing objects"),
			WRITE_TREE_MISSING_OK),
		OPT_STRING(0, "prefix", &tree_prefix, N_("<prefix>/"),
			   N_("write tree object for a subdirectory <prefix>")),
		{
			.type = OPTION_BIT,
			.long_name = "ignore-cache-tree",
			.value = &flags,
			.precision = sizeof(flags),
			.help = N_("only useful for debugging"),
			.flags = PARSE_OPT_HIDDEN | PARSE_OPT_NOARG,
			.defval = WRITE_TREE_IGNORE_CACHE_TREE,
		},
		OPT_END()
	};

	show_usage_with_options_if_asked(argc, argv,
					 write_tree_usage, write_tree_options);

	if (write_tree_uses_worktree_index()) {
		clean_status_config_init(&clean_digest,
					 the_repository->hash_algo);
		repo_config(the_repository, write_tree_config, &clean_digest);
		clean_status_config_final(&clean_digest);
		clean_status_set_config_digest(the_repository, &clean_digest);
		clean_status_enable_external_history(the_repository);
	} else {
		repo_config(the_repository, git_default_config, NULL);
	}
	argc = parse_options(argc, argv, cmd_prefix, write_tree_options,
			     write_tree_usage, 0);

	prepare_repo_settings(the_repository);
	the_repository->settings.command_requires_full_index = 0;

	ret = write_index_as_tree(&oid, the_repository->index,
				  repo_get_index_file(the_repository),
				  flags, tree_prefix);
	switch (ret) {
	case 0:
		printf("%s\n", oid_to_hex(&oid));
		break;
	case WRITE_TREE_UNREADABLE_INDEX:
		die("%s: error reading the index", me);
		break;
	case WRITE_TREE_UNMERGED_INDEX:
		die("%s: error building trees", me);
		break;
	case WRITE_TREE_PREFIX_ERROR:
		die("%s: prefix %s not found", me, tree_prefix);
		break;
	}
	return ret;
}
