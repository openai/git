#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "attr.h"
#include "attr-fingerprint.h"
#include "attr-manifest.h"
#include "clean-status.h"
#include "clean-status-index.h"
#include "clean-status-internal.h"
#include "config.h"
#include "dir.h"
#include "environment.h"
#include "ewah/ewok.h"
#include "ewah/ewok_rlw.h"
#include "fsmonitor.h"
#include "fsmonitor-clean-proof.h"
#include "fsmonitor-ll.h"
#include "lockfile.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "setup.h"
#include "strbuf.h"

static int witness_has_only_entries(const struct index_state *istate)
{
	const unsigned int disk_flags =
		CE_STAGEMASK | CE_EXTENDED | CE_VALID | CE_EXTENDED_FLAGS;

	if (!istate->initialized || istate->cache_changed ||
	    istate->name_hash_initialized || istate->cache_tree ||
	    istate->resolve_undo || istate->split_index ||
	    istate->sparse_index != INDEX_EXPANDED || istate->untracked ||
	    istate->clean_status || istate->fsmonitor_dirty ||
	    istate->fsmonitor_last_update ||
	    istate->fsmonitor_last_update_pending ||
	    istate->fsmonitor_untracked_token ||
	    istate->fsmonitor_token_valid || istate->fsmonitor_extension_seen ||
	    istate->fsmonitor_untracked_extension_seen ||
	    istate->fsmonitor_untracked_valid)
		return 0;
	for (size_t i = 0; i < istate->cache_nr; i++)
		if (istate->cache[i]->ce_flags & ~disk_flags)
			return 0;
	return 1;
}

static int compare_witness_entries(const struct index_state *witness,
				   const struct index_state *full)
{
	const unsigned int disk_flags =
		CE_STAGEMASK | CE_EXTENDED | CE_VALID | CE_EXTENDED_FLAGS;

	if (witness->version != full->version ||
	    witness->cache_nr != full->cache_nr ||
	    !oideq(&witness->oid, &full->oid) ||
	    witness->timestamp.sec != full->timestamp.sec ||
	    witness->timestamp.nsec != full->timestamp.nsec)
		return error("witness index header differs from the full reader");
	for (size_t i = 0; i < witness->cache_nr; i++) {
		const struct cache_entry *a = witness->cache[i];
		const struct cache_entry *b = full->cache[i];

		if (memcmp(&a->ce_stat_data, &b->ce_stat_data,
			   sizeof(a->ce_stat_data)) ||
		    a->ce_mode != b->ce_mode ||
		    ((a->ce_flags ^ b->ce_flags) & disk_flags) ||
		    !oideq(&a->oid, &b->oid) ||
		    ce_namelen(a) != ce_namelen(b) ||
		    memcmp(a->name, b->name, ce_namelen(a) + 1))
			return error("witness entry %"PRIuMAX" differs from the full reader",
				     (uintmax_t)i);
	}
	return 0;
}

static int test_read_index_witness(const char *path, int compare,
				   int unlink_after_open, int expect_miss)
{
	struct index_state witness = INDEX_STATE_INIT(the_repository);
	struct index_state full = INDEX_STATE_INIT(the_repository);
	struct clean_status_index_snapshot snapshot = { .fd = -1 };
	struct stat st;
	int flags = O_RDONLY | O_CLOEXEC;
	int fd = -1, ret = 1, read_result;

	setup_git_directory(the_repository);
	repo_config(the_repository, git_default_config, NULL);
#ifdef O_NONBLOCK
	flags |= O_NONBLOCK;
#else
	/* The parser is still useful for regular-file fixtures on this platform. */
	if (lstat(path, &st) || !S_ISREG(st.st_mode)) {
		ret = !expect_miss;
		goto done;
	}
#endif
	fd = open_nofollow(path, flags);
	if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode)) {
		ret = !expect_miss;
		goto done;
	}
	if (lseek(fd, 1, SEEK_SET) != 1)
		goto done;
	if (unlink_after_open &&
	    (clean_status_index_snapshot_open_allow_null_checksum(
		     &snapshot, path, the_repository->hash_algo) ||
	     unlink(path)))
		goto done;
	read_result = read_index_entries_from_fd(&witness, fd);
	if (fstat(fd, &st) || lseek(fd, 0, SEEK_CUR) != 1) {
		error("witness reader consumed its borrowed descriptor");
		goto done;
	}
	if (read_result) {
		if (witness.initialized || witness.cache || witness.cache_nr ||
		    witness.ce_mem_pool) {
			error("failed witness read published partial state");
			goto done;
		}
		ret = !expect_miss;
		goto done;
	}
	if (expect_miss) {
		error("invalid witness was accepted");
		goto done;
	}
	if (!witness_has_only_entries(&witness)) {
		error("witness reader installed non-entry state");
		goto done;
	}
	if (unlink_after_open &&
	    clean_status_index_snapshot_still_matches_path(
		    &snapshot, path, the_repository->hash_algo)) {
		error("unlinked witness retained its named snapshot");
		goto done;
	}
	if (compare) {
		do_read_index(&full, path, 1);
		if (compare_witness_entries(&witness, &full))
			goto done;
	}
	ret = 0;

done:
	if (fd >= 0)
		close(fd);
	clean_status_index_snapshot_release(&snapshot);
	release_index(&full);
	release_index(&witness);
	return ret;
}

static int test_index_witness_snapshot(const char *path)
{
	struct clean_status_index_snapshot snapshot = { .fd = -1 };
	int ret;

	setup_git_directory(the_repository);
	ret = clean_status_index_snapshot_open_allow_null_checksum(
		&snapshot, path, the_repository->hash_algo);
	clean_status_index_snapshot_release(&snapshot);
	return !!ret;
}

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
	struct untracked_cache_dir child = { 0 };
	struct untracked_cache_dir *dirs[] = { &child };
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
	root.valid = child.valid = 1;
	root.dirs = dirs;
	root.dirs_nr = ARRAY_SIZE(dirs);
	prepare_fsmonitor_untracked(&duplicate);
	if (!duplicate.fsmonitor_untracked_valid)
		return error("matching FSMN and FSUC tokens were not paired");
	if (!root.valid_recursive || !child.valid_recursive)
		return error("matching FSUC did not restore recursive validity");
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

static int test_fsmn_bitmap_ownership(const struct strbuf *encoded)
{
	struct index_state parsed = INDEX_STATE_INIT(the_repository);
	struct index_state regenerated = INDEX_STATE_INIT(the_repository);

	parsed.cache_nr = 1;
	read_fsmonitor_extension(&parsed, encoded->buf, encoded->len);
	if (!parsed.fsmonitor_token_valid || !parsed.fsmonitor_dirty)
		return error("raw FSMN bitmap was not published");
	parsed.cache_nr = 0;
	release_index(&parsed);

	fill_fsmonitor_bitmap(&regenerated);
	if (!regenerated.fsmonitor_dirty)
		return error("initial FSMN bitmap was not published");
	fill_fsmonitor_bitmap(&regenerated);
	if (!regenerated.fsmonitor_dirty)
		return error("regenerated FSMN bitmap did not replace its owner");
	release_index(&regenerated);

	if (parsed.fsmonitor_dirty || regenerated.fsmonitor_dirty)
		return error("released index retained its FSMN bitmap");
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
	if (test_fsmn_bitmap_ownership(&encoded))
		return 1;

	strbuf_release(&malformed);
	strbuf_release(&encoded);
	return 0;
}

static int write_test_index(void)
{
	struct lock_file index_lock = LOCK_INIT;

	repo_hold_locked_index(the_repository, &index_lock, LOCK_DIE_ON_ERROR);
	if (write_locked_index(the_repository->index, &index_lock, COMMIT_LOCK))
		return error("unable to write test index");
	return 0;
}

static int test_fscf_history_is_coherent(const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return state && state->disk_config_valid &&
		!state->disk_config_invalid && state->disk_semantic_valid &&
		state->disk_attr_valid && state->manifest.disk_valid &&
		(state->manifest.disk_flags & FSMONITOR_CLEAN_PROOF_ALL) ==
			FSMONITOR_CLEAN_PROOF_ALL &&
		state->disk_config_raw.len && state->initial_coherent;
}

static int test_fscf_config(const char *key, const char *value,
			    const struct config_context *ctx, void *cb)
{
	struct clean_status_config_digest *config = cb;

	clean_status_config_add(config, key, value, ctx);
	return git_default_config(key, value, ctx, NULL);
}

static int test_fscf_history(void)
{
	struct clean_status_config_digest config;
	struct attr_fingerprint attrs;
	struct attr_manifest_writer writer;
	struct strbuf manifest = STRBUF_INIT;
	struct strbuf encoded = STRBUF_INIT;
	unsigned char index_hash[GIT_MAX_RAWSZ] = { 0 };
	const char *token;
	struct fsmonitor_clean_proof proof = {
		.flags = FSMONITOR_CLEAN_PROOF_ALL,
	};
	const struct git_hash_algo *algo;
	int ret = 1;

	setup_git_directory(the_repository);
	algo = the_repository->hash_algo;
	clean_status_config_init(&config, algo);
	repo_config(the_repository, test_fscf_config, &config);
	clean_status_config_final(&config);
	clean_status_set_config_digest(the_repository, &config);
	if (repo_read_index(the_repository) < 0)
		return error("unable to read test index");
	token = "fscf-test-token";
	if (attr_fingerprint_repository(the_repository, &attrs))
		return error("unable to fingerprint attribute sources");

	attr_manifest_writer_init(&writer, &manifest, algo);
	if (attr_manifest_writer_add(&writer, ".gitattributes",
				     ATTR_MANIFEST_INDEX, index_hash))
		return error("unable to write test attribute manifest");
	proof.config_hash = config.hash;
	proof.semantic_hash = config.semantic_hash;
	proof.attr_hash = attrs.content_hash;
	proof.token = (const unsigned char *)token;
	proof.token_len = strlen(token);
	proof.attr_manifest = (const unsigned char *)manifest.buf;
	proof.attr_manifest_len = manifest.len;
	if (fsmonitor_clean_proof_write(&encoded, &proof, algo))
		return error("unable to write test clean proof");

	FREE_AND_NULL(the_repository->index->fsmonitor_last_update);
	the_repository->index->fsmonitor_last_update = xstrdup(token);
	the_repository->index->fsmonitor_token_valid = 1;
	clean_status_read_fsmonitor_config(the_repository->index,
					   encoded.buf, encoded.len);
	clean_status_prepare_fsmonitor_config(the_repository->index);
	if (!test_fscf_history_is_coherent(the_repository->index))
		return error("test clean proof was not coherent");
	if (write_test_index())
		goto done;

	discard_index(the_repository->index);
	if (repo_read_index(the_repository) < 0)
		return error("unable to reread test index");
	if (!test_fscf_history_is_coherent(the_repository->index))
		return error("FSCF did not survive an index round trip");

	clean_status_invalidate_current_manifest(the_repository->index);
	if (write_test_index())
		goto done;
	discard_index(the_repository->index);
	if (repo_read_index(the_repository) < 0)
		return error("unable to reread preserved test index");
	if (clean_status_has_persistent_fsmonitor_semantic_history(
		    the_repository->index))
		return error("generic rewrite retained FSCF epoch bindings");
	if (!clean_status_has_worktree_manifest_history(the_repository->index))
		return error("generic rewrite discarded FSCF manifest history");
	ret = 0;

done:
	strbuf_release(&encoded);
	strbuf_release(&manifest);
	return ret;
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

	if (argc == 3 && !strcmp(argv[1], "--read-index-witness"))
		return test_read_index_witness(argv[2], 0, 0, 0);
	if (argc == 3 && !strcmp(argv[1], "--expect-index-witness-miss"))
		return test_read_index_witness(argv[2], 0, 0, 1);
	if (argc == 3 && !strcmp(argv[1], "--compare-index-witness"))
		return test_read_index_witness(argv[2], 1, 0, 0);
	if (argc == 3 && !strcmp(argv[1], "--read-index-witness-unlink"))
		return test_read_index_witness(argv[2], 0, 1, 0);
	if (argc == 3 && !strcmp(argv[1], "--index-witness-snapshot"))
		return test_index_witness_snapshot(argv[2]);
	if (argc == 3 &&
	    !strcmp(argv[1], "--test-fsmonitor-content-recovery"))
		return test_fsmonitor_content_recovery(argv[2]);
	if (argc == 2 && !strcmp(argv[1], "--test-fsuc-parser"))
		return test_fsuc_parser();
	if (argc == 2 && !strcmp(argv[1], "--test-fsmn-parser"))
		return test_fsmn_parser();
	if (argc == 2 && !strcmp(argv[1], "--test-fscf-round-trip"))
		return test_fscf_history();
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
