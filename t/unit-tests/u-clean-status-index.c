#include "unit-test.h"
#include "clean-status.h"
#include "clean-status-index.h"
#include "clean-status-internal.h"
#include "dir.h"
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
	cl_assert_equal_i(clean_status_index_snapshot_pin(
		&snapshot, &istate), -1);
	fixture_release(&fixture);
}

void test_clean_status_index__rejects_null_checksums(void)
{
	assert_rejects_null_checksum(&hash_algos[GIT_HASH_SHA1]);
	assert_rejects_null_checksum(&hash_algos[GIT_HASH_SHA256]);
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

void test_clean_status_index__pins_named_index_identity(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct clean_status_index_snapshot snapshot;
	struct index_fixture fixture;
	struct repository repo = { 0 };
	struct index_state istate = INDEX_STATE_INIT(&repo);
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
