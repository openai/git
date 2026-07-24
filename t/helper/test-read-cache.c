#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "attr.h"
#include "config.h"
#include "environment.h"
#include "fsmonitor.h"
#include "fsmonitor-ll.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "setup.h"

static int test_fsmonitor_content_recovery(const char *path)
{
	struct index_state *istate;
	struct cache_entry *ce;
	struct stat_data empty = { 0 };
	struct stat st;
	int pos;

	setup_git_directory(the_repository);
	repo_config(the_repository, git_default_config, NULL);
	if (repo_read_index(the_repository) < 0)
		return error("unable to read test index");
	istate = the_repository->index;
	pos = index_name_pos(istate, path, strlen(path));
	if (pos < 0)
		return error("path is not indexed: %s", path);
	ce = istate->cache[pos];
	if (lstat(path, &st))
		return error_errno("unable to stat indexed path");

	fsmonitor_invalidate_cache_entry(ce);
	if (memcmp(&ce->ce_stat_data, &empty, sizeof(empty)))
		return error("invalidation did not poison cached stat data");
	if (ie_match_stat_with_content_check(istate, ce, &st, 0))
		return error("clean content did not match");
	if (!memcmp(&ce->ce_stat_data, &empty, sizeof(empty)))
		return error("verified clean entry retained poisoned stat data");
	if (!(ce->ce_flags & CE_UPDATE_IN_BASE) ||
	    !(istate->cache_changed & CE_ENTRY_CHANGED))
		return error("verified stat refresh was not marked for persistence");
	return 0;
}

static int test_fsmonitor_directory_attributes(void)
{
	struct attr_check *check;
	int ret = 1;

	setup_git_directory(the_repository);
	repo_config(the_repository, git_default_config, NULL);
	if (repo_read_index(the_repository) < 0)
		return error("unable to read test index");

	check = attr_check_initl("marker", NULL);
	git_check_attr(the_repository->index, "tracked-dir/tracked", check);
	if (!check->items[0].value ||
	    strcmp(check->items[0].value, "old")) {
		error("initial attribute value was not cached");
		goto done;
	}

	write_file("tracked-dir/.gitattributes", "tracked marker=new\n");
	/*
	 * repo_read_index() consumed the normal refresh. Re-arm it after
	 * caching the pre-event attribute value.
	 */
	the_repository->index->fsmonitor_has_run_once = 0;
	refresh_fsmonitor(the_repository->index);
	git_check_attr(the_repository->index, "tracked-dir/tracked", check);
	if (!check->items[0].value ||
	    strcmp(check->items[0].value, "new")) {
		error("directory event did not invalidate cached attributes");
		goto done;
	}
	ret = 0;

done:
	attr_check_free(check);
	discard_index(the_repository->index);
	return ret;
}

int cmd__read_cache(int argc, const char **argv)
{
	int i, cnt = 1;
	const char *name = NULL;

	if (argc == 3 &&
	    !strcmp(argv[1], "--test-fsmonitor-content-recovery"))
		return test_fsmonitor_content_recovery(argv[2]);
	if (argc == 2 &&
	    !strcmp(argv[1], "--test-fsmonitor-directory-attributes"))
		return test_fsmonitor_directory_attributes();

	if (argc > 1 && skip_prefix(argv[1], "--print-and-refresh=", &name)) {
		argc--;
		argv++;
	}

	if (argc == 2)
		cnt = strtol(argv[1], NULL, 0);
	setup_git_directory(the_repository);
	repo_config(the_repository, git_default_config, NULL);

	for (i = 0; i < cnt; i++) {
		repo_read_index(the_repository);
		if (name) {
			int pos;

			refresh_index(the_repository->index, REFRESH_QUIET,
				      NULL, NULL, NULL);
			pos = index_name_pos(the_repository->index, name, strlen(name));
			if (pos < 0)
				die("%s not in index", name);
			printf("%s is%s up to date\n", name,
			       ce_uptodate(the_repository->index->cache[pos]) ? "" : " not");
			write_file(name, "%d\n", i);
		}
		discard_index(the_repository->index);
	}
	return 0;
}
