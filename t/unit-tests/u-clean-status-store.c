#include "unit-test.h"

#ifdef __APPLE__
#include <sys/mount.h>
#endif

#include "clean-status-index.h"
#include "clean-status-sidecar.h"
#include "dir.h"
#include "strbuf.h"

struct store_fixture {
	char *directory;
	struct strbuf index_path;
	struct clean_status_sidecar sidecar;
};

static void fill_oid(struct object_id *oid, unsigned char value,
		     const struct git_hash_algo *algo)
{
	unsigned char hash[GIT_MAX_RAWSZ];

	memset(hash, value, algo->rawsz);
	oidread(oid, hash, algo);
}

static void fixture_init(struct store_fixture *fixture,
			 const struct git_hash_algo *algo)
{
	static const unsigned char token[] = "builtin:1:2";
	struct strbuf index = STRBUF_INIT;
	struct clean_status_proof *proof;
	struct stat st;
	const char *tmp = getenv("TMPDIR");
	uint32_t value;

	memset(fixture, 0, sizeof(*fixture));
	fixture->index_path = (struct strbuf)STRBUF_INIT;
	fixture->directory = xstrfmt("%s/status-store.XXXXXX",
				    tmp ? tmp : "/tmp");
	cl_assert(mkdtemp(fixture->directory) != NULL);
	strbuf_addf(&fixture->index_path, "%s/index", fixture->directory);
	strbuf_addstr(&index, "DIRC");
	put_be32(&value, 4);
	strbuf_add(&index, &value, sizeof(value));
	put_be32(&value, 5);
	strbuf_add(&index, &value, sizeof(value));
	strbuf_addchars(&index, 2, algo->rawsz);
	write_file_buf(fixture->index_path.buf, index.buf, index.len);
	cl_assert_equal_i(stat(fixture->index_path.buf, &st), 0);
	cl_assert_equal_i(clean_status_identity_from_stat(
		&fixture->sidecar.identity, &st), 0);
	proof = &fixture->sidecar.proof;
	proof->index_version = 4;
	proof->cache_nr = 5;
	fill_oid(&proof->index_checksum, 2, algo);
	fill_oid(&proof->head_tree, 3, algo);
	memset(proof->config_hash, 4, algo->rawsz);
	memset(proof->repo_hash, 5, algo->rawsz);
	fill_oid(&proof->exclude_source_digest, 6, algo);
	fixture->sidecar.token = token;
	fixture->sidecar.token_len = sizeof(token) - 1;
	strbuf_release(&index);
}

static void fixture_release(struct store_fixture *fixture)
{
	struct strbuf cleanup = STRBUF_INIT;

	strbuf_addstr(&cleanup, fixture->directory);
	cl_assert_equal_i(remove_dir_recursively(&cleanup, 0), 0);
	strbuf_release(&cleanup);
	strbuf_release(&fixture->index_path);
	free(fixture->directory);
}

static struct strbuf sidecar_path(struct store_fixture *fixture)
{
	struct strbuf path = STRBUF_INIT;

	strbuf_addf(&path, "%s.csts", fixture->index_path.buf);
	return path;
}

static void require_local_apfs(const char *path MAYBE_UNUSED)
{
#ifdef __APPLE__
	struct statfs fs;
	int fd = git_open_cloexec(path, O_RDONLY);

	if (fd < 0 || fstatfs(fd, &fs) || !(fs.f_flags & MNT_LOCAL) ||
	    strcmp(fs.f_fstypename, "apfs")) {
		if (fd >= 0)
			close(fd);
		cl_skip();
	}
	close(fd);
#else
	cl_skip();
#endif
}

static void assert_installs_against_source(const struct git_hash_algo *algo)
{
	struct clean_status_sidecar parsed;
	struct clean_status_index_snapshot snapshot;
	struct store_fixture fixture;
	struct strbuf encoded = STRBUF_INIT;
	struct strbuf path;

	fixture_init(&fixture, algo);
	path = sidecar_path(&fixture);
	cl_assert_equal_i(clean_status_sidecar_pin_source(
		fixture.index_path.buf, &fixture.sidecar, algo, &snapshot), 0);
	cl_assert_equal_i(clean_status_sidecar_install(
		fixture.index_path.buf, &fixture.sidecar, &snapshot, algo), 0);
	cl_assert(strbuf_read_file(&encoded, path.buf, 0) > 0);
	cl_assert_equal_i(clean_status_sidecar_parse(
		&parsed, encoded.buf, encoded.len, algo), 0);
	cl_assert(clean_status_identity_equal(
		&parsed.identity, &fixture.sidecar.identity));

	clean_status_index_snapshot_release(&snapshot);
	strbuf_release(&path);
	strbuf_release(&encoded);
	fixture_release(&fixture);
}

void test_clean_status_store__installs_both_object_formats(void)
{
	require_local_apfs(getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
	assert_installs_against_source(&hash_algos[GIT_HASH_SHA1]);
	assert_installs_against_source(&hash_algos[GIT_HASH_SHA256]);
}

static void assert_rejects_replaced_source(const struct git_hash_algo *algo)
{
	struct clean_status_index_snapshot snapshot;
	struct store_fixture fixture;
	struct strbuf replacement = STRBUF_INIT;

	fixture_init(&fixture, algo);
	cl_assert_equal_i(clean_status_sidecar_pin_source(
		fixture.index_path.buf, &fixture.sidecar, algo, &snapshot), 0);
	strbuf_addf(&replacement, "%s/replacement", fixture.directory);
	write_file(replacement.buf, "replacement");
	cl_assert_equal_i(rename(replacement.buf, fixture.index_path.buf), 0);
	cl_assert_equal_i(clean_status_sidecar_install(
		fixture.index_path.buf, &fixture.sidecar, &snapshot, algo), -1);

	clean_status_index_snapshot_release(&snapshot);
	strbuf_release(&replacement);
	fixture_release(&fixture);
}

void test_clean_status_store__rejects_a_replaced_source_index(void)
{
	require_local_apfs(getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
	assert_rejects_replaced_source(&hash_algos[GIT_HASH_SHA1]);
	assert_rejects_replaced_source(&hash_algos[GIT_HASH_SHA256]);
}
