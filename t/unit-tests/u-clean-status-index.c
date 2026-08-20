#include "unit-test.h"
#include "clean-status.h"
#include "clean-status-index.h"
#include "clean-status-internal.h"
#include "dir.h"
#include "object.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "strbuf.h"
#include "wrapper.h"

struct index_fixture {
	char *path;
	int fd;
	struct stat st;
	struct object_id checksum;
};

static void fixture_init(struct index_fixture *fixture,
			 const struct git_hash_algo *algo)
{
	const char *tmp = getenv("TMPDIR");
	unsigned char header[12] = "DIRC";
	unsigned char hash[GIT_MAX_RAWSZ];
	static const char payload[] = "payload";

	memset(fixture, 0, sizeof(*fixture));
	fixture->path = xstrfmt("%s/index-snapshot.XXXXXX",
				 tmp ? tmp : "/tmp");
	fixture->fd = mkstemp(fixture->path);
	cl_assert(fixture->fd >= 0);
	put_be32(header + 4, 4);
	put_be32(header + 8, 7);
	memset(hash, 1, algo->rawsz);
	oidread(&fixture->checksum, hash, algo);
	cl_assert_equal_i(write_in_full(fixture->fd, header, sizeof(header)),
			  sizeof(header));
	cl_assert_equal_i(write_in_full(fixture->fd, payload, sizeof(payload)),
			  sizeof(payload));
	cl_assert_equal_i(write_in_full(fixture->fd, hash, algo->rawsz),
			  algo->rawsz);
	cl_assert_equal_i(fstat(fixture->fd, &fixture->st), 0);
}

static void fixture_release(struct index_fixture *fixture)
{
	cl_assert_equal_i(close(fixture->fd), 0);
	cl_assert_equal_i(unlink(fixture->path), 0);
	free(fixture->path);
}

static void write_at(int fd, const void *data, size_t len, off_t offset)
{
	cl_assert_equal_i(lseek(fd, offset, SEEK_SET), offset);
	cl_assert_equal_i(write_in_full(fd, data, len), len);
}

static void fixture_clear_checksum(struct index_fixture *fixture,
				   const struct git_hash_algo *algo)
{
	unsigned char null_hash[GIT_MAX_RAWSZ] = { 0 };

	write_at(fixture->fd, null_hash, algo->rawsz,
		 fixture->st.st_size - algo->rawsz);
	oidclr(&fixture->checksum, algo);
	cl_assert_equal_i(fstat(fixture->fd, &fixture->st), 0);
}

static void assert_reads_snapshot(const struct git_hash_algo *algo)
{
	struct index_fixture fixture;
	struct clean_status_index_snapshot snapshot;
	struct repository repo = { 0 };
	struct index_state istate = INDEX_STATE_INIT(&repo);

	fixture_init(&fixture, algo);
	repo.hash_algo = algo;
	repo.index_file = fixture.path;
	istate.version = 4;
	istate.cache_nr = 7;
	oidcpy(&istate.oid, &fixture.checksum);
	cl_assert_equal_i(clean_status_index_snapshot_pin(
		&snapshot, &istate), 0);
	cl_assert_equal_i(snapshot.version, 4);
	cl_assert_equal_i(snapshot.cache_nr, 7);
	cl_assert(oideq(&snapshot.checksum, &fixture.checksum));
	cl_assert(clean_status_index_snapshot_still_matches(
		&snapshot, &istate));
	clean_status_index_snapshot_release(&snapshot);
	fixture_release(&fixture);
}

void test_clean_status_index__reads_both_object_formats(void)
{
	assert_reads_snapshot(&hash_algos[GIT_HASH_SHA1]);
	assert_reads_snapshot(&hash_algos[GIT_HASH_SHA256]);
}

void test_clean_status_index__rejects_invalid_headers(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct index_fixture fixture;
	struct clean_status_index_snapshot snapshot;
	struct repository repo = { 0 };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	uint32_t value;

	fixture_init(&fixture, algo);
	repo.hash_algo = algo;
	repo.index_file = fixture.path;
	istate.version = 4;
	istate.cache_nr = 7;
	oidcpy(&istate.oid, &fixture.checksum);
	write_at(fixture.fd, "NOPE", 4, 0);
	cl_assert_equal_i(clean_status_index_snapshot_pin(
		&snapshot, &istate), -1);
	write_at(fixture.fd, "DIRC", 4, 0);
	put_be32(&value, 1);
	write_at(fixture.fd, &value, sizeof(value), 4);
	cl_assert_equal_i(clean_status_index_snapshot_pin(
		&snapshot, &istate), -1);
	fixture_release(&fixture);
}

static void assert_rejects_null_checksum(const struct git_hash_algo *algo)
{
	struct clean_status_index_snapshot snapshot;
	struct index_fixture fixture;
	struct repository repo = { 0 };
	struct index_state istate = INDEX_STATE_INIT(&repo);

	fixture_init(&fixture, algo);
	repo.hash_algo = algo;
	repo.index_file = fixture.path;
	istate.version = 4;
	istate.cache_nr = 7;
	fixture_clear_checksum(&fixture, algo);
	oidcpy(&istate.oid, &fixture.checksum);
	cl_assert_equal_i(clean_status_index_snapshot_open(
		&snapshot, fixture.path, algo), -1);
	cl_assert_equal_i(clean_status_index_snapshot_pin(
		&snapshot, &istate), -1);
	fixture_release(&fixture);
}

void test_clean_status_index__rejects_null_checksums(void)
{
	assert_rejects_null_checksum(&hash_algos[GIT_HASH_SHA1]);
	assert_rejects_null_checksum(&hash_algos[GIT_HASH_SHA256]);
}

static void assert_opens_null_checksum_for_durable_callers(
	const struct git_hash_algo *algo)
{
	struct clean_status_index_snapshot snapshot;
	struct index_fixture fixture;

	fixture_init(&fixture, algo);
	fixture_clear_checksum(&fixture, algo);
	cl_assert_equal_i(
		clean_status_index_snapshot_open_allow_null_checksum(
			&snapshot, fixture.path, algo), 0);
	cl_assert(is_null_oid(&snapshot.checksum));
	clean_status_index_snapshot_release(&snapshot);
	fixture_release(&fixture);
}

void test_clean_status_index__opens_null_checksum_for_durable_callers(void)
{
	assert_opens_null_checksum_for_durable_callers(
		&hash_algos[GIT_HASH_SHA1]);
	assert_opens_null_checksum_for_durable_callers(
		&hash_algos[GIT_HASH_SHA256]);
}

static void assert_pins_null_checksum_source(
	const struct git_hash_algo *algo)
{
	struct clean_status_index_snapshot snapshot;
	struct index_fixture fixture, replacement;
	struct repository repo = { 0 };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct index_state parsed = INDEX_STATE_INIT(&repo);
	char *moved;

	fixture_init(&fixture, algo);
	fixture_init(&replacement, algo);
	fixture_clear_checksum(&fixture, algo);
	fixture_clear_checksum(&replacement, algo);
	repo.hash_algo = algo;
	repo.index_file = fixture.path;
	istate.version = 4;
	istate.cache_nr = 7;
	oidcpy(&istate.oid, &fixture.checksum);
	parsed.version = 4;
	parsed.cache_nr = 7;
	oidcpy(&parsed.oid, &replacement.checksum);
	clean_status_get_state(&istate);
	clean_status_record_source_identity(&istate, &fixture.st);
	clean_status_get_state(&parsed);
	clean_status_record_source_identity(&parsed, &replacement.st);

	if (clean_status_identity_is_durable()) {
		cl_assert_equal_i(clean_status_index_snapshot_pin(
			&snapshot, &istate), 0);
		cl_assert(clean_status_index_snapshot_still_matches(
			&snapshot, &istate));

		/*
		 * Model an A-to-B-to-A replacement while a second index state
		 * parses B.  The named path and held descriptor are back on A,
		 * while the parsed state's source identity still binds it to B.
		 */
		cl_assert(!clean_status_index_snapshot_still_matches(
			&snapshot, &parsed));
		clean_status_index_snapshot_release(&snapshot);
	} else {
		cl_assert_equal_i(clean_status_index_snapshot_pin(
			&snapshot, &istate), -1);
		clean_status_release(&istate);
		clean_status_release(&parsed);
		fixture_release(&fixture);
		fixture_release(&replacement);
		return;
	}

	moved = xstrfmt("%s.old", fixture.path);
	cl_assert_equal_i(rename(fixture.path, moved), 0);
	cl_assert_equal_i(rename(replacement.path, fixture.path), 0);
	cl_assert_equal_i(clean_status_index_snapshot_pin(
		&snapshot, &istate), -1);

	clean_status_release(&istate);
	clean_status_release(&parsed);
	cl_assert_equal_i(close(fixture.fd), 0);
	cl_assert_equal_i(close(replacement.fd), 0);
	cl_assert_equal_i(unlink(fixture.path), 0);
	cl_assert_equal_i(unlink(moved), 0);
	free(moved);
	free(fixture.path);
	free(replacement.path);
}

void test_clean_status_index__pins_null_checksum_source_identity(void)
{
	assert_pins_null_checksum_source(&hash_algos[GIT_HASH_SHA1]);
	assert_pins_null_checksum_source(&hash_algos[GIT_HASH_SHA256]);
}

static int retain_null_checksum_source(
	struct index_fixture *fixture, struct repository *repo,
	struct index_state *istate)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct clean_status_state *state;
	struct stat source_st;
	int source_fd;

	repo->hash_algo = algo;
	repo->index_file = fixture->path;
	istate->version = 4;
	istate->cache_nr = 7;
	oidcpy(&istate->oid, &fixture->checksum);
	state = clean_status_get_state(istate);
	source_fd = git_open_cloexec(fixture->path, O_RDONLY);
	cl_assert(source_fd >= 0);
#if defined(F_GETFD) && defined(FD_CLOEXEC)
	cl_assert(fcntl(source_fd, F_GETFD) & FD_CLOEXEC);
#endif
	cl_assert_equal_i(fstat(source_fd, &source_st), 0);
	cl_assert(!clean_status_retain_source_index_fd(
		istate, source_fd, &source_st));
	cl_assert_equal_i(fstat(source_fd, &source_st), 0);
	state->config_enforced = 1;
	cl_assert(clean_status_retain_source_index_fd(
		istate, source_fd, &source_st));
	return source_fd;
}

void test_clean_status_index__pins_null_checksum_epoch_to_source_fd(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct clean_status_index_snapshot snapshot;
	struct index_fixture fixture;
	struct repository repo = { 0 };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct stat source_st;
	int source_fd;

	if (!fstat_is_reliable())
		return;
	fixture_init(&fixture, algo);
	fixture_clear_checksum(&fixture, algo);
	source_fd = retain_null_checksum_source(&fixture, &repo, &istate);

	/* The held source is an exception only for proof epochs. */
	cl_assert_equal_i(clean_status_index_snapshot_pin(
		&snapshot, &istate), -1);
	cl_assert_equal_i(clean_status_index_snapshot_pin_proof_epoch(
		&snapshot, &istate), 0);
	cl_assert(clean_status_index_snapshot_still_matches_proof_epoch(
		&snapshot, &istate));
	cl_assert(!clean_status_index_snapshot_still_matches(
		&snapshot, &istate));
	clean_status_index_snapshot_release(&snapshot);

	release_index(&istate);
	errno = 0;
	cl_assert_equal_i(fstat(source_fd, &source_st), -1);
	cl_assert_equal_i(errno, EBADF);
	fixture_release(&fixture);
}

static void assert_changed_null_checksum_source_is_rejected(int replace)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct clean_status_index_snapshot snapshot;
	struct index_fixture fixture, replacement;
	struct repository repo = { 0 };
	struct index_state istate = INDEX_STATE_INIT(&repo);
#ifndef GIT_WINDOWS_NATIVE
	char *moved = NULL;
#endif

	fixture_init(&fixture, algo);
	fixture_clear_checksum(&fixture, algo);
	if (replace) {
		fixture_init(&replacement, algo);
		fixture_clear_checksum(&replacement, algo);
	}
	retain_null_checksum_source(&fixture, &repo, &istate);
	cl_assert_equal_i(clean_status_index_snapshot_pin_proof_epoch(
		&snapshot, &istate), 0);

	if (replace) {
#ifndef GIT_WINDOWS_NATIVE
		moved = xstrfmt("%s.old", fixture.path);
		cl_assert_equal_i(rename(fixture.path, moved), 0);
		cl_assert_equal_i(rename(replacement.path, fixture.path), 0);
#endif
	} else {
		write_at(fixture.fd, "\0", 1, fixture.st.st_size);
	}
	cl_assert(!clean_status_index_snapshot_still_matches_proof_epoch(
		&snapshot, &istate));
	clean_status_index_snapshot_release(&snapshot);
	cl_assert_equal_i(clean_status_index_snapshot_pin_proof_epoch(
		&snapshot, &istate), -1);
	if (replace) {
#ifndef GIT_WINDOWS_NATIVE
		cl_assert_equal_i(rename(fixture.path, replacement.path), 0);
		cl_assert_equal_i(rename(moved, fixture.path), 0);
		free(moved);
#endif
	}

	release_index(&istate);
	fixture_release(&fixture);
	if (replace)
		fixture_release(&replacement);
}

void test_clean_status_index__rejects_changed_null_checksum_epoch_source(void)
{
	if (!fstat_is_reliable())
		return;
	assert_changed_null_checksum_source_is_rejected(0);
#ifndef GIT_WINDOWS_NATIVE
	assert_changed_null_checksum_source_is_rejected(1);
#endif
}

void test_clean_status_index__pins_named_index_identity(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct clean_status_index_snapshot snapshot;
	struct index_fixture fixture;
	struct repository repo = { 0 };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct index_state parsed = INDEX_STATE_INIT(&repo);
	unsigned char replacement_hash[GIT_MAX_RAWSZ];
#ifndef GIT_WINDOWS_NATIVE
	char *moved;
	int replacement;
#endif

	fixture_init(&fixture, algo);
	repo.hash_algo = algo;
	repo.index_file = fixture.path;
	istate.version = 4;
	istate.cache_nr = 7;
	oidcpy(&istate.oid, &fixture.checksum);

	cl_assert_equal_i(clean_status_index_snapshot_pin(
		&snapshot, &istate), 0);
	cl_assert(clean_status_index_snapshot_still_matches(
		&snapshot, &istate));

	/*
	 * Model an A-to-B-to-A replacement while a consumer parses B.
	 * Matching the restored named path is insufficient unless the parsed
	 * state is also bound to the pinned A contents.
	 */
	memset(replacement_hash, 2, algo->rawsz);
	parsed.version = 4;
	parsed.cache_nr = 7;
	oidread(&parsed.oid, replacement_hash, algo);
	cl_assert(!clean_status_index_snapshot_still_matches(
		&snapshot, &parsed));

	istate.cache_nr++;
	cl_assert(!clean_status_index_snapshot_still_matches(
		&snapshot, &istate));
	istate.cache_nr--;

#ifndef GIT_WINDOWS_NATIVE
	moved = xstrfmt("%s.old", fixture.path);
	cl_assert_equal_i(rename(fixture.path, moved), 0);
	replacement = open(fixture.path, O_WRONLY | O_CREAT | O_EXCL, 0600);
	cl_assert(replacement >= 0);
	cl_assert_equal_i(close(replacement), 0);
	cl_assert(!clean_status_index_snapshot_still_matches(
		&snapshot, &istate));
	cl_assert_equal_i(unlink(fixture.path), 0);
	cl_assert_equal_i(rename(moved, fixture.path), 0);
	free(moved);
#endif
	clean_status_index_snapshot_release(&snapshot);

#ifndef GIT_WINDOWS_NATIVE
	{
		char *symlink_path = xstrfmt("%s.link", fixture.path);

		cl_assert_equal_i(symlink(fixture.path, symlink_path), 0);
		repo.index_file = symlink_path;
		cl_assert_equal_i(clean_status_index_snapshot_pin(
			&snapshot, &istate), -1);
		repo.index_file = fixture.path;
		cl_assert_equal_i(unlink(symlink_path), 0);
		free(symlink_path);
	}
#endif

	fixture_release(&fixture);
}

void test_clean_status_index__binds_the_parsed_source(void)
{
	const char *tmp = getenv("TMPDIR");
	char *worktree = xstrfmt("%s/status-source.XXXXXX",
				 tmp ? tmp : "/tmp");
	struct index_state istate = { 0 };
	struct strbuf path = STRBUF_INIT, replacement = STRBUF_INIT;
	struct strbuf cleanup = STRBUF_INIT;
	struct stat original, current;

	cl_assert(mkdtemp(worktree) != NULL);
	strbuf_addf(&path, "%s/index", worktree);
	strbuf_addf(&replacement, "%s/replacement", worktree);
	write_file(path.buf, "original");
	write_file(replacement.buf, "replacement");
	cl_assert_equal_i(stat(path.buf, &original), 0);
	clean_status_get_state(&istate);
	clean_status_record_source_identity(&istate, &original);
	cl_assert(clean_status_verify_null_index(&istate, &original));

	cl_assert_equal_i(rename(replacement.buf, path.buf), 0);
	cl_assert_equal_i(stat(path.buf, &current), 0);
	if (clean_status_identity_is_durable())
		cl_assert(!clean_status_verify_null_index(&istate, &current));
	else
		cl_assert(clean_status_verify_null_index(&istate, &current));

	clean_status_release(&istate);
	strbuf_addstr(&cleanup, worktree);
	cl_assert_equal_i(remove_dir_recursively(&cleanup, 0), 0);
	strbuf_release(&cleanup);
	strbuf_release(&replacement);
	strbuf_release(&path);
	free(worktree);
}

void test_clean_status_index__recognizes_certifiable_entries(void)
{
	struct repository repo = { .hash_algo = &hash_algos[GIT_HASH_SHA1] };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct cache_entry *ce;
	static const char path[] = "tracked";

	CALLOC_ARRAY(istate.cache, 1);
	istate.cache_alloc = istate.cache_nr = 1;
	memset(istate.oid.hash, 1, repo.hash_algo->rawsz);
	oid_set_algo(&istate.oid, repo.hash_algo);
	ce = make_empty_cache_entry(&istate, sizeof(path) - 1);
	ce->ce_mode = S_IFREG | 0644;
	ce->ce_namelen = sizeof(path) - 1;
	memcpy(ce->name, path, sizeof(path));
	istate.cache[0] = ce;

	ce->ce_flags = CE_FSMONITOR_VALID;
	cl_assert(clean_status_index_is_certifiable(&istate));
	ce->ce_flags |= CE_UPTODATE | CE_HASHED;
	cl_assert(clean_status_index_is_certifiable(&istate));

	oidclr(&istate.oid, repo.hash_algo);
	cl_assert(!clean_status_index_is_certifiable(&istate));
	cl_assert(clean_status_index_entries_are_certifiable(&istate));
	memset(istate.oid.hash, 1, repo.hash_algo->rawsz);

	ce->ce_flags = 0;
	cl_assert(!clean_status_index_is_certifiable(&istate));
	ce->ce_flags = CE_FSMONITOR_VALID | CE_VALID;
	cl_assert(!clean_status_index_is_certifiable(&istate));
	ce->ce_flags = CE_FSMONITOR_VALID | CE_UPDATE_IN_BASE;
	cl_assert(clean_status_index_is_certifiable(&istate));
	ce->ce_flags = CE_FSMONITOR_VALID | create_ce_flags(1);
	cl_assert(!clean_status_index_is_certifiable(&istate));
	ce->ce_flags = CE_FSMONITOR_VALID | CE_INTENT_TO_ADD;
	cl_assert(!clean_status_index_is_certifiable(&istate));
	ce->ce_flags = CE_FSMONITOR_VALID | CE_SKIP_WORKTREE;
	cl_assert(!clean_status_index_is_certifiable(&istate));
	ce->ce_flags = CE_FSMONITOR_VALID | CE_WT_REMOVE;
	cl_assert(!clean_status_index_is_certifiable(&istate));
	ce->ce_flags = CE_FSMONITOR_VALID;
	ce->ce_mode = S_IFGITLINK;
	cl_assert(!clean_status_index_is_certifiable(&istate));

	release_index(&istate);
}

void test_clean_status_index__digests_only_persistent_logical_entries(void)
{
	struct repository repo = { .hash_algo = &hash_algos[GIT_HASH_SHA1] };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct cache_entry *ce;
	unsigned char baseline[GIT_MAX_RAWSZ];
	unsigned char changed[GIT_MAX_RAWSZ];
	static const char path[] = "tracked";

	CALLOC_ARRAY(istate.cache, 1);
	istate.cache_alloc = istate.cache_nr = 1;
	ce = make_empty_cache_entry(&istate, sizeof(path) - 1);
	ce->ce_mode = S_IFREG | 0644;
	ce->ce_namelen = sizeof(path) - 1;
	memcpy(ce->name, path, sizeof(path));
	memset(ce->oid.hash, 1, repo.hash_algo->rawsz);
	oid_set_algo(&ce->oid, repo.hash_algo);
	istate.cache[0] = ce;

	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, baseline), 0);
	ce->ce_flags = CE_FSMONITOR_VALID | CE_UPTODATE | CE_HASHED;
	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, changed), 0);
	cl_assert(!memcmp(baseline, changed, repo.hash_algo->rawsz));

	ce->ce_flags |= CE_VALID;
	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, changed), 0);
	cl_assert(memcmp(baseline, changed, repo.hash_algo->rawsz));
	ce->ce_flags = CE_SKIP_WORKTREE;
	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, changed), 0);
	cl_assert(memcmp(baseline, changed, repo.hash_algo->rawsz));
	ce->ce_flags = CE_INTENT_TO_ADD;
	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, changed), 0);
	cl_assert(memcmp(baseline, changed, repo.hash_algo->rawsz));
	ce->ce_flags = create_ce_flags(1);
	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, changed), 0);
	cl_assert(memcmp(baseline, changed, repo.hash_algo->rawsz));

	ce->ce_flags = 0;
	ce->ce_mode = S_IFREG | 0755;
	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, changed), 0);
	cl_assert(memcmp(baseline, changed, repo.hash_algo->rawsz));
	ce->ce_mode = S_IFREG | 0644;
	ce->oid.hash[0] = 2;
	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, changed), 0);
	cl_assert(memcmp(baseline, changed, repo.hash_algo->rawsz));
	ce->oid.hash[0] = 1;
	ce->name[0] = 'T';
	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, changed), 0);
	cl_assert(memcmp(baseline, changed, repo.hash_algo->rawsz));

	ce->name[0] = 't';
	ce->ce_flags = CE_WT_REMOVE;
	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, changed), -1);
	ce->ce_flags = CE_CONTENT_CHECK_REQUIRED;
	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, changed), -1);
	ce->ce_flags = CE_UPDATE_IN_BASE;
	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, changed), -1);

	release_index(&istate);
}

void test_clean_status_index__limits_full_status_bookkeeping_exception(void)
{
	struct repository repo = { .hash_algo = &hash_algos[GIT_HASH_SHA1] };
	struct index_state istate = INDEX_STATE_INIT(&repo);
	struct cache_entry *ce;
	unsigned char baseline[GIT_MAX_RAWSZ];
	unsigned char changed[GIT_MAX_RAWSZ];
	static const char path[] = "tracked";

	CALLOC_ARRAY(istate.cache, 1);
	istate.cache_alloc = istate.cache_nr = 1;
	ce = make_empty_cache_entry(&istate, sizeof(path) - 1);
	ce->ce_mode = S_IFREG | 0644;
	ce->ce_namelen = sizeof(path) - 1;
	memcpy(ce->name, path, sizeof(path));
	memset(ce->oid.hash, 1, repo.hash_algo->rawsz);
	oid_set_algo(&ce->oid, repo.hash_algo);
	istate.cache[0] = ce;
	repo.index = &istate;
	istate.cache_changed = CE_ENTRY_CHANGED;
	clean_status_enable_external_history(&repo);

	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, baseline), 0);
	ce->ce_flags = CE_UPDATE_IN_BASE;
	cl_assert_equal_i(clean_status_index_logical_digest(
		&istate, changed), -1);
	cl_assert_equal_i(clean_status_index_logical_digest_after_status(
		&istate, changed), 0);
	cl_assert(!memcmp(baseline, changed, repo.hash_algo->rawsz));

	ce->ce_mode = S_IFREG | 0755;
	cl_assert_equal_i(clean_status_index_logical_digest_after_status(
		&istate, changed), 0);
	cl_assert(memcmp(baseline, changed, repo.hash_algo->rawsz));
	ce->ce_mode = S_IFREG | 0644;
	ce->oid.hash[0] = 2;
	cl_assert_equal_i(clean_status_index_logical_digest_after_status(
		&istate, changed), 0);
	cl_assert(memcmp(baseline, changed, repo.hash_algo->rawsz));
	ce->oid.hash[0] = 1;
	ce->name[0] = 'T';
	cl_assert_equal_i(clean_status_index_logical_digest_after_status(
		&istate, changed), 0);
	cl_assert(memcmp(baseline, changed, repo.hash_algo->rawsz));
	ce->name[0] = 't';
	ce->ce_flags = CE_UPDATE_IN_BASE | CE_VALID;
	cl_assert_equal_i(clean_status_index_logical_digest_after_status(
		&istate, changed), 0);
	cl_assert(memcmp(baseline, changed, repo.hash_algo->rawsz));

	ce->ce_flags = CE_UPDATE_IN_BASE | CE_CONTENT_CHECK_REQUIRED;
	cl_assert_equal_i(clean_status_index_logical_digest_after_status(
		&istate, changed), -1);
	ce->ce_flags = CE_UPDATE_IN_BASE | CE_WT_REMOVE;
	cl_assert_equal_i(clean_status_index_logical_digest_after_status(
		&istate, changed), -1);
	ce->ce_flags = CE_UPDATE_IN_BASE;
	istate.cache_changed |= CACHE_TREE_CHANGED;
	cl_assert_equal_i(clean_status_index_logical_digest_after_status(
		&istate, changed), -1);
	istate.cache_changed = CE_ENTRY_CHANGED;
	repo.index = NULL;
	cl_assert_equal_i(clean_status_index_logical_digest_after_status(
		&istate, changed), -1);
	clean_status_enable_external_history(NULL);

	release_index(&istate);
}
