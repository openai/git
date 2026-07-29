#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "attr.h"
#include "config.h"
#include "dir.h"
#include "environment.h"
#include "ewah/ewok.h"
#include "ewah/ewok_rlw.h"
#include "fsmonitor.h"
#include "fsmonitor-ll.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "setup.h"
#include "strbuf.h"

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

static int fsuc_failed_closed(const struct index_state *istate)
{
	return istate->fsmonitor_untracked_extension_seen &&
		istate->fsmonitor_untracked_extension_invalid &&
		!istate->fsmonitor_untracked_token;
}

static int test_fsuc_parser(void)
{
	struct index_state duplicate = INDEX_STATE_INIT(the_repository);
	struct index_state truncated = INDEX_STATE_INIT(the_repository);
	struct untracked_cache untracked = { 0 };
	struct untracked_cache_dir root = { 0 };
	struct strbuf encoded = STRBUF_INIT;
	struct strbuf written = STRBUF_INIT;
	uint32_t version;

	put_be32(&version, 1);
	strbuf_add(&encoded, &version, sizeof(version));
	strbuf_addstr(&encoded, "token");
	strbuf_addch(&encoded, '\0');
	read_fsmonitor_untracked_extension(
		&duplicate, encoded.buf, encoded.len);
	if (duplicate.fsmonitor_untracked_extension_invalid ||
	    !duplicate.fsmonitor_untracked_token ||
	    strcmp(duplicate.fsmonitor_untracked_token, "token"))
		return error("valid FSUC was not published");

	duplicate.fsmonitor_last_update = xstrdup("token");
	write_fsmonitor_untracked_extension(&written, &duplicate);
	if (written.len != encoded.len ||
	    memcmp(written.buf, encoded.buf, encoded.len))
		return error("FSUC did not round-trip");
	duplicate.fsmonitor_token_valid = 1;
	duplicate.untracked = &untracked;
	untracked.root = &root;
	prepare_fsmonitor_untracked(&duplicate);
	if (!duplicate.fsmonitor_untracked_valid)
		return error("matching FSMN and FSUC tokens were not paired");
	free(duplicate.fsmonitor_last_update);
	duplicate.fsmonitor_last_update = xstrdup("other");
	prepare_fsmonitor_untracked(&duplicate);
	if (duplicate.fsmonitor_untracked_valid)
		return error("mismatched FSMN and FSUC tokens were paired");
	read_fsmonitor_untracked_extension(
		&duplicate, encoded.buf, encoded.len);
	if (!fsuc_failed_closed(&duplicate))
		return error("duplicate FSUC did not fail closed");

	truncated.fsmonitor_untracked_token = xstrdup("old");
	read_fsmonitor_untracked_extension(
		&truncated, encoded.buf, sizeof(version));
	if (!fsuc_failed_closed(&truncated))
		return error("truncated FSUC was partially published");

	free(duplicate.fsmonitor_last_update);
	strbuf_release(&written);
	strbuf_release(&encoded);
	return 0;
}

static void wrap_fsmn_ewah(struct strbuf *out, const struct strbuf *ewah)
{
	uint32_t value;

	put_be32(&value, 2);
	strbuf_add(out, &value, sizeof(value));
	strbuf_addstr(out, "token");
	strbuf_addch(out, '\0');
	put_be32(&value, ewah->len);
	strbuf_add(out, &value, sizeof(value));
	strbuf_addbuf(out, ewah);
}

static void make_valid_fsmn(struct strbuf *out)
{
	struct ewah_bitmap *dirty = ewah_new();
	struct strbuf ewah = STRBUF_INIT;

	ewah_set(dirty, 0);
	ewah_serialize_strbuf(dirty, &ewah);
	wrap_fsmn_ewah(out, &ewah);
	ewah_free(dirty);
	strbuf_release(&ewah);
}

static void make_raw_fsmn(struct strbuf *out, uint32_t bit_size,
			  const eword_t *words, uint32_t word_count,
			  uint32_t rlw)
{
	struct strbuf ewah = STRBUF_INIT;
	uint32_t value;
	uint32_t i;

	put_be32(&value, bit_size);
	strbuf_add(&ewah, &value, sizeof(value));
	put_be32(&value, word_count);
	strbuf_add(&ewah, &value, sizeof(value));
	for (i = 0; i < word_count; i++) {
		eword_t word = htonll(words[i]);

		strbuf_add(&ewah, &word, sizeof(word));
	}
	put_be32(&value, rlw);
	strbuf_add(&ewah, &value, sizeof(value));
	wrap_fsmn_ewah(out, &ewah);
	strbuf_release(&ewah);
}

static int fsmn_failed_closed(const struct index_state *istate)
{
	return istate->fsmonitor_extension_seen &&
		!istate->fsmonitor_last_update && !istate->fsmonitor_dirty &&
		!istate->fsmonitor_token_valid;
}

static int check_invalid_fsmn(const struct strbuf *encoded,
			      const char *description)
{
	struct index_state invalid = INDEX_STATE_INIT(the_repository);

	invalid.cache_nr = 1;
	invalid.fsmonitor_last_update = xstrdup("old");
	invalid.fsmonitor_dirty = ewah_new();
	invalid.fsmonitor_token_valid = 1;
	read_fsmonitor_extension(&invalid, encoded->buf, encoded->len);
	if (!fsmn_failed_closed(&invalid))
		return error("%s FSMN was published", description);
	return 0;
}

static int test_fsmn_parser(void)
{
	struct index_state duplicate = INDEX_STATE_INIT(the_repository);
	struct index_state truncated = INDEX_STATE_INIT(the_repository);
	struct strbuf encoded = STRBUF_INIT;
	struct strbuf malformed = STRBUF_INIT;
	eword_t words[2] = { 0 };

	duplicate.cache_nr = truncated.cache_nr = 1;
	make_valid_fsmn(&encoded);
	read_fsmonitor_extension(&duplicate, encoded.buf, encoded.len);
	if (!duplicate.fsmonitor_token_valid ||
	    !duplicate.fsmonitor_last_update ||
	    strcmp(duplicate.fsmonitor_last_update, "token") ||
	    !duplicate.fsmonitor_dirty)
		return error("valid FSMN was not published");
	read_fsmonitor_extension(&duplicate, encoded.buf, encoded.len);
	if (!fsmn_failed_closed(&duplicate))
		return error("duplicate FSMN did not fail closed");

	truncated.fsmonitor_last_update = xstrdup("old");
	truncated.fsmonitor_dirty = ewah_new();
	truncated.fsmonitor_token_valid = 1;
	read_fsmonitor_extension(&truncated, encoded.buf, encoded.len - 1);
	if (!fsmn_failed_closed(&truncated))
		return error("truncated FSMN was partially published");

	rlw_set_literal_words(&words[0], 1);
	make_raw_fsmn(&malformed, 1, words, 1, 0);
	if (check_invalid_fsmn(&malformed, "out-of-bounds literal"))
		return 1;
	strbuf_reset(&malformed);

	words[0] = 0;
	rlw_set_run_bit(&words[0], 1);
	rlw_set_running_len(&words[0], 1);
	make_raw_fsmn(&malformed, 1, words, 1, 0);
	if (check_invalid_fsmn(&malformed, "oversized set-bit run"))
		return 1;
	strbuf_reset(&malformed);

	words[0] = words[1] = 0;
	rlw_set_literal_words(&words[0], 1);
	words[1] = 2;
	make_raw_fsmn(&malformed, 1, words, 2, 0);
	if (check_invalid_fsmn(&malformed, "set padding bit"))
		return 1;
	strbuf_reset(&malformed);

	words[1] = 1;
	make_raw_fsmn(&malformed, 1, words, 2, 1);
	if (check_invalid_fsmn(&malformed, "non-final RLW"))
		return 1;

	strbuf_release(&malformed);
	strbuf_release(&encoded);
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
	if (argc == 2 && !strcmp(argv[1], "--test-fsuc-parser"))
		return test_fsuc_parser();
	if (argc == 2 && !strcmp(argv[1], "--test-fsmn-parser"))
		return test_fsmn_parser();
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
