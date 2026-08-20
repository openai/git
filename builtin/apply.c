#define USE_THE_REPOSITORY_VARIABLE
#include "builtin.h"
#include "clean-status.h"
#include "gettext.h"
#include "hash.h"
#include "apply.h"

static const char * const apply_usage[] = {
	N_("git apply [<options>] [<patch>...]"),
	NULL
};

int cmd_apply(int argc,
	      const char **argv,
	      const char *prefix,
	      struct repository *repo)
{
	int force_apply = 0;
	int options = 0;
	int ret;
	struct apply_state state;

	if (init_apply_state(&state, the_repository, prefix))
		exit(128);

	/*
	 * We could to redo the "apply.c" machinery to make this
	 * arbitrary fallback unnecessary, but it is dubious that it
	 * is worth the effort.
	 * cf. https://lore.kernel.org/git/xmqqcypfcmn4.fsf@gitster.g/
	 */
	if (!the_hash_algo)
		repo_set_hash_algo(the_repository, GIT_HASH_DEFAULT);

	argc = apply_parse_options(argc, argv,
				   &state, &force_apply, &options,
				   apply_usage);

	if (repo) {
		prepare_repo_settings(repo);
		repo->settings.command_requires_full_index = 0;
	}

	if (check_apply_state(&state, force_apply))
		exit(128);

	if (state.apply && state.check_index && !state.threeway &&
	    !state.apply_with_reject && !state.ita_only &&
	    !state.fake_ancestor && !state.index_file)
		clean_status_prepare_main_index_history(the_repository);

	ret = apply_all_patches(&state, argc, argv, options);

	clear_apply_state(&state);

	return ret;
}
