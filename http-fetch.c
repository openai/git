#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "config.h"
#include "environment.h"
#include "gettext.h"
#include "hex.h"
#include "http.h"
#include "walker.h"
#include "setup.h"
#include "strvec.h"
#include "url.h"
#include "urlmatch.h"
#include "trace.h"
#include "trace2.h"

static const char http_fetch_usage[] = "git http-fetch "
"[-c] [-t] [-a] [-v] [--recover] [-w ref] [--stdin | --packfile=hash | commit-id] url";

static int fetch_using_walker(const char *raw_url, int get_verbosely,
			      int get_recover, int commits, char **commit_id,
			      const char **write_ref, int commits_on_stdin)
{
	char *url = NULL;
	struct walker *walker;
	int rc;

	str_end_url_with_slash(raw_url, &url);

	http_init(NULL, url, 0);

	walker = get_http_walker(url);
	walker->get_verbosely = get_verbosely;
	walker->get_recover = get_recover;
	walker->get_progress = 0;

	rc = walker_fetch(walker, commits, commit_id, write_ref, url);

	if (commits_on_stdin)
		walker_targets_free(commits, commit_id, write_ref);

	if (walker->corrupt_object_found) {
		fprintf(stderr,
"Some loose object were found to be corrupt, but they might be just\n"
"a false '404 Not Found' error message sent with incorrect HTTP\n"
"status code.  Suggest running 'git fsck'.\n");
	}

	walker_free(walker);
	http_cleanup();
	free(url);

	return rc;
}

struct packfile_progress {
	uint64_t bytes;
	uint64_t last_update;
};

static void report_packfile_progress(struct packfile_progress *progress)
{
	printf("bytes %"PRIu64"\n", progress->bytes);
	if (fflush(stdout))
		die_errno("unable to report packfile download progress");
	progress->last_update = getnanotime();
}

static void update_packfile_progress(void *data, size_t bytes)
{
	struct packfile_progress *progress = data;

	progress->bytes += bytes;
	if (getnanotime() - progress->last_update >= 500000000)
		report_packfile_progress(progress);
}

static void fetch_single_packfile(struct object_id *packfile_hash,
				  const char *url,
				  const char **index_pack_args,
				  int report_progress)
{
	struct http_pack_request *preq;
	struct slot_results results;
	struct packfile_progress progress = { 0 };
	int ret;

	http_init(NULL, url, 0);

	preq = new_direct_http_pack_request(packfile_hash->hash, xstrdup(url));
	if (!preq)
		die("couldn't create http pack request");
	preq->slot->results = &results;
	preq->index_pack_args = index_pack_args;
	preq->preserve_index_pack_stdout = 1;
	if (report_progress) {
		progress.last_update = getnanotime();
		preq->progress = update_packfile_progress;
		preq->progress_data = &progress;
	}

	if (start_active_slot(preq->slot)) {
		run_active_slot(preq->slot);
		if (results.curl_result != CURLE_OK &&
		    results.http_code != 416) {
			struct url_info url;
			char *nurl = url_normalize(preq->url, &url);
			if (!nurl || !git_env_bool("GIT_TRACE_REDACT", 1)) {
				die("unable to get pack file '%s'\n%s", preq->url,
				    curl_errorstr);
			} else {
				die("failed to get '%.*s' url from '%.*s' "
				    "(full URL redacted due to GIT_TRACE_REDACT setting)\n%s",
				    (int)url.scheme_len, url.url,
				    (int)url.host_len, &url.url[url.host_off], curl_errorstr);
			}
		}
	} else {
		die("Unable to start request");
	}

	if (report_progress)
		report_packfile_progress(&progress);

	if ((ret = finish_http_pack_request(preq)))
		die("finish_http_pack_request gave result %d", ret);

	release_http_pack_request(preq);
	http_cleanup();
}

int cmd_main(int argc, const char **argv)
{
	int commits_on_stdin = 0;
	int commits;
	const char **write_ref = NULL;
	char **commit_id;
	int arg = 1;
	int get_verbosely = 0;
	int get_recover = 0;
	int packfile = 0;
	int report_progress = 0;
	int nongit;
	struct object_id packfile_hash;
	struct strvec index_pack_args = STRVEC_INIT;
	int ret;

	setup_git_directory_gently(the_repository, &nongit);

	while (arg < argc && argv[arg][0] == '-') {
		const char *p;

		if (argv[arg][1] == 't') {
		} else if (argv[arg][1] == 'c') {
		} else if (argv[arg][1] == 'a') {
		} else if (argv[arg][1] == 'v') {
			get_verbosely = 1;
		} else if (argv[arg][1] == 'w') {
			write_ref = &argv[arg + 1];
			arg++;
		} else if (argv[arg][1] == 'h') {
			usage(http_fetch_usage);
		} else if (!strcmp(argv[arg], "--recover")) {
			get_recover = 1;
		} else if (!strcmp(argv[arg], "--stdin")) {
			commits_on_stdin = 1;
		} else if (!strcmp(argv[arg], "--report-progress")) {
			report_progress = 1;
		} else if (skip_prefix(argv[arg], "--packfile=", &p)) {
			const char *end;

			if (nongit)
				die(_("not a git repository"));

			packfile = 1;
			if (parse_oid_hex_algop(p, &packfile_hash, &end,
						the_repository->hash_algo) || *end)
				die(_("argument to --packfile must be a valid hash (got '%s')"), p);
		} else if (skip_prefix(argv[arg], "--index-pack-arg=", &p)) {
			strvec_push(&index_pack_args, p);
		}
		arg++;
	}
	if (argc != arg + 2 - (commits_on_stdin || packfile))
		usage(http_fetch_usage);

	if (nongit)
		die(_("not a git repository"));

	trace2_cmd_name("http-fetch");

	repo_config(the_repository, git_default_config, NULL);

	if (packfile) {
		if (!index_pack_args.nr)
			die(_("the option '%s' requires '%s'"), "--packfile", "--index-pack-arg");

		fetch_single_packfile(&packfile_hash, argv[arg],
				      index_pack_args.v, report_progress);
		ret = 0;
		goto out;
	}

	if (report_progress)
		die(_("the option '%s' requires '%s'"), "--report-progress", "--packfile");

	if (index_pack_args.nr)
		die(_("the option '%s' requires '%s'"), "--index-pack-arg", "--packfile");

	if (commits_on_stdin) {
		commits = walker_targets_stdin(&commit_id, &write_ref);
	} else {
		commit_id = (char **) &argv[arg++];
		commits = 1;
	}

	ret = fetch_using_walker(argv[arg], get_verbosely, get_recover,
				 commits, commit_id, write_ref,
				 commits_on_stdin);

out:
	strvec_clear(&index_pack_args);
	return ret;
}
