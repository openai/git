#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "config.h"
#include "parse-options.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "semantic-verify.h"
#include "setup.h"

static const char *kind_name(enum semantic_verify_kind kind)
{
	switch (kind) {
	case SEMANTIC_VERIFY_UNCHECKED:
		return "unchecked";
	case SEMANTIC_VERIFY_SKIPPED:
		return "skipped";
	case SEMANTIC_VERIFY_RAW_CLEAN:
		return "raw-clean";
	case SEMANTIC_VERIFY_RAW_MODIFIED:
		return "raw-modified";
	case SEMANTIC_VERIFY_SENSITIVE:
		return "sensitive";
	case SEMANTIC_VERIFY_STRUCTURAL:
		return "structural";
	case SEMANTIC_VERIFY_UNSTABLE:
		return "unstable";
	case SEMANTIC_VERIFY_ERROR:
		return "error";
	}
	BUG("unknown semantic verification kind");
}

int cmd__semantic_verify(int argc, const char **argv)
{
	struct semantic_verify_proof *proof = NULL;
	struct semantic_verify_stats stats;
	int show_results = 0;
	int ret;
	const char * const usage[] = {
		"test-tool semantic-verify [<options>]",
		NULL
	};
	struct option opts[] = {
		OPT_BOOL(0, "show-results", &show_results,
			 "show one result per cache entry"),
		OPT_END()
	};

	argc = parse_options(argc, argv, NULL, opts, usage, 0);
	if (argc)
		usage_with_options(usage, opts);

	setup_git_directory(the_repository);
	repo_config(the_repository, git_default_config, NULL);
	prepare_repo_settings(the_repository);
	the_repository->settings.command_requires_full_index = 0;
	if (repo_read_index(the_repository) < 0)
		die("unable to read index");
	ret = semantic_verify_prepare(the_repository->index, &proof);
	semantic_verify_get_stats(proof, &stats);
	if (show_results) {
		for (size_t i = 0; i < stats.cache_nr; i++) {
			const struct semantic_verify_result *result =
				semantic_verify_result_at(proof, i);

			printf("%s %s persist=%d error=%u\n",
			       the_repository->index->cache[i]->name,
			       kind_name(result->kind),
			       !!(result->flags & SEMANTIC_VERIFY_PERSISTABLE),
			       result->error);
		}
	}
	printf("entries=%"PRIuMAX" clean=%"PRIuMAX
	       " modified=%"PRIuMAX" sensitive=%"PRIuMAX
	       " structural=%"PRIuMAX" unstable=%"PRIuMAX
	       " errors=%"PRIuMAX" hardlinks=%"PRIuMAX
	       " bytes=%"PRIuMAX" stat_updates=%"PRIuMAX
	       " root_stable=%d namespace_stable=%d\n",
	       (uintmax_t)stats.cache_nr, (uintmax_t)stats.raw_clean,
	       (uintmax_t)stats.raw_modified, (uintmax_t)stats.sensitive,
	       (uintmax_t)stats.structural, (uintmax_t)stats.unstable,
	       (uintmax_t)stats.errors, (uintmax_t)stats.hardlinks,
	       (uintmax_t)stats.bytes_hashed,
	       (uintmax_t)stats.stat_updates_nr,
	       semantic_verify_root_is_stable(proof),
	       !stats.namespace_unstable);
	semantic_verify_proof_clear(proof);
	return !!ret;
}
