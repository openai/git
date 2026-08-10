#include "unit-test.h"

#ifdef __APPLE__
#include <sys/mount.h>
#endif

#include "clean-status-history-store.h"
#include "clean-status-index.h"
#include "dir.h"
#include "hash-framing.h"
#include "hex.h"
#include "strbuf.h"

struct history_store_fixture {
	char *directory;
	struct strbuf index_path;
};

static void fixture_init(struct history_store_fixture *fixture,
			 const struct git_hash_algo *algo)
{
	struct strbuf index = STRBUF_INIT;
	const char *tmp = getenv("TMPDIR");
	uint32_t value;

	memset(fixture, 0, sizeof(*fixture));
	fixture->index_path = (struct strbuf)STRBUF_INIT;
	fixture->directory = xstrfmt("%s/status-history-store.XXXXXX",
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
	strbuf_release(&index);
}

static void fixture_release(struct history_store_fixture *fixture)
{
	struct strbuf cleanup = STRBUF_INIT;

	strbuf_addstr(&cleanup, fixture->directory);
	cl_assert_equal_i(remove_dir_recursively(&cleanup, 0), 0);
	strbuf_release(&cleanup);
	strbuf_release(&fixture->index_path);
	free(fixture->directory);
}

static void replace_checksum(struct strbuf *encoded,
			     const struct git_hash_algo *algo)
{
	strbuf_setlen(encoded, encoded->len - algo->rawsz);
	hash_append_checksum(encoded, algo);
}

static struct strbuf history_store_path_for_index(
	const char *index_path, const char *proof_namespace,
	const struct git_hash_algo *algo)
{
	static const char domain[] = "git-clean-status-history-namespace-v1";
	struct git_hash_ctx ctx;
	unsigned char hash[GIT_MAX_RAWSZ];
	char hex[GIT_MAX_HEXSZ + 1];
	struct strbuf path = STRBUF_INIT;

	git_hash_init(&ctx, algo);
	hash_length_delimited(&ctx, domain, sizeof(domain) - 1);
	hash_length_delimited(&ctx, proof_namespace, strlen(proof_namespace));
	git_hash_final(hash, &ctx);
	hash_to_hex_algop_r(hex, hash, algo);
	strbuf_addf(&path, "%s.csh1.%s", index_path, hex);
	return path;
}

static struct strbuf history_store_path(
	struct history_store_fixture *fixture, const char *proof_namespace,
	const struct git_hash_algo *algo)
{
	return history_store_path_for_index(
		fixture->index_path.buf, proof_namespace, algo);
}

static size_t count_history_store_files(const char *directory,
					const char *index_basename,
					const struct git_hash_algo *algo)
{
	struct strbuf prefix = STRBUF_INIT;
	struct dirent *de;
	DIR *dir = opendir(directory);
	size_t nr = 0;

	cl_assert(dir != NULL);
	strbuf_addf(&prefix, "%s.csh1.", index_basename);
	while ((de = readdir(dir))) {
		const char *suffix;

		if (!starts_with(de->d_name, prefix.buf))
			continue;
		suffix = de->d_name + prefix.len;
		if (strlen(suffix) == algo->hexsz &&
		    strspn(suffix, "0123456789abcdef") == algo->hexsz)
			nr++;
	}
	closedir(dir);
	strbuf_release(&prefix);
	return nr;
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

void test_clean_status_history_store__rejects_incomplete_checkpoints(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	static const unsigned char fsmn[] = "fsmn";
	static const unsigned char fscf[] = "fscf";
	struct clean_status_history_checkpoint checkpoint = { 0 }, parsed;
	struct strbuf encoded = STRBUF_INIT;
	const size_t flags_offset = 4 + sizeof(uint32_t);

	memset(checkpoint.index_hash, 1, algo->rawsz);
	checkpoint.fsmonitor = fsmn;
	checkpoint.fsmonitor_len = sizeof(fsmn) - 1;
	checkpoint.fsmonitor_config = fscf;
	checkpoint.fsmonitor_config_len = sizeof(fscf) - 1;
	cl_assert_equal_i(clean_status_history_checkpoint_write(
		&encoded, "proof-schema", &checkpoint, algo), 0);

	/* The optional UNTR and FSUC pair may both be absent. */
	cl_assert_equal_i(clean_status_history_checkpoint_parse(
		&parsed, "proof-schema", encoded.buf, encoded.len, algo), 0);
	cl_assert_equal_i(parsed.fsmonitor_len, sizeof(fsmn) - 1);
	cl_assert(!memcmp(parsed.fsmonitor, fsmn, sizeof(fsmn) - 1));
	cl_assert_equal_i(parsed.untracked_cache_len, 0);
	cl_assert(parsed.untracked_cache == NULL);
	cl_assert_equal_i(parsed.fsmonitor_config_len, sizeof(fscf) - 1);
	cl_assert(!memcmp(parsed.fsmonitor_config, fscf, sizeof(fscf) - 1));
	cl_assert_equal_i(parsed.fsmonitor_untracked_len, 0);
	cl_assert(parsed.fsmonitor_untracked == NULL);
	cl_assert(!parsed.source_alias_valid);

	/* A checkpoint must contain both FSMN and FSCF. */
	put_be32(encoded.buf + flags_offset, 1U << 1);
	replace_checksum(&encoded, algo);
	cl_assert_equal_i(clean_status_history_checkpoint_parse(
		&parsed, "proof-schema", encoded.buf, encoded.len, algo), -1);

	/* UNTR is useful only together with its FSUC binding. */
	put_be32(encoded.buf + flags_offset,
		 (1U << 0) | (1U << 1) | (1U << 2));
	replace_checksum(&encoded, algo);
	cl_assert_equal_i(clean_status_history_checkpoint_parse(
		&parsed, "proof-schema", encoded.buf, encoded.len, algo), -1);

	strbuf_release(&encoded);
}

void test_clean_status_history_store__keeps_namespaces_independent(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	struct clean_status_history_store_record first_record =
		CLEAN_STATUS_HISTORY_STORE_RECORD_INIT;
	struct clean_status_history_store_record second_record =
		CLEAN_STATUS_HISTORY_STORE_RECORD_INIT;
	struct clean_status_history_checkpoint first = { 0 }, second = { 0 };
	struct clean_status_index_snapshot snapshot;
	struct history_store_fixture fixture;
	static const unsigned char first_fsmn[] = "first-fsmn";
	static const unsigned char first_fscf[] = "first-fscf";
	static const unsigned char second_fsmn[] = "second-fsmn";
	static const unsigned char second_fscf[] = "second-fscf";

	require_local_apfs(getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
	fixture_init(&fixture, algo);
	memset(first.index_hash, 1, algo->rawsz);
	first.fsmonitor = first_fsmn;
	first.fsmonitor_len = sizeof(first_fsmn) - 1;
	first.fsmonitor_config = first_fscf;
	first.fsmonitor_config_len = sizeof(first_fscf) - 1;
	memset(second.index_hash, 2, algo->rawsz);
	second.fsmonitor = second_fsmn;
	second.fsmonitor_len = sizeof(second_fsmn) - 1;
	second.fsmonitor_config = second_fscf;
	second.fsmonitor_config_len = sizeof(second_fscf) - 1;

	cl_assert_equal_i(clean_status_index_snapshot_open(
		&snapshot, fixture.index_path.buf, algo), 0);
	cl_assert_equal_i(clean_status_history_store_install(
		fixture.index_path.buf, "proof-schema-one", &first,
		&snapshot, algo), 0);
	cl_assert_equal_i(clean_status_history_store_install(
		fixture.index_path.buf, "proof-schema-two", &second,
		&snapshot, algo), 0);
	cl_assert_equal_i(clean_status_history_store_load(
		fixture.index_path.buf, "proof-schema-one", algo,
		&first_record), 0);
	cl_assert_equal_i(clean_status_history_store_load(
		fixture.index_path.buf, "proof-schema-two", algo,
		&second_record), 0);
	cl_assert_equal_i(first_record.checkpoint.fsmonitor_config_len,
			  sizeof(first_fscf) - 1);
	cl_assert(!memcmp(first_record.checkpoint.fsmonitor_config,
			  first_fscf, sizeof(first_fscf) - 1));
	cl_assert_equal_i(second_record.checkpoint.fsmonitor_config_len,
			  sizeof(second_fscf) - 1);
	cl_assert(!memcmp(second_record.checkpoint.fsmonitor_config,
			  second_fscf, sizeof(second_fscf) - 1));

	clean_status_history_store_record_release(&second_record);
	clean_status_history_store_record_release(&first_record);
	clean_status_index_snapshot_release(&snapshot);
	fixture_release(&fixture);
}

void test_clean_status_history_store__does_not_rewrite_unchanged_checkpoint(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	static const unsigned char fsmn[] = "fsmn";
	static const unsigned char fscf[] = "fscf";
	struct clean_status_history_checkpoint checkpoint = { 0 };
	struct clean_status_history_store_record record =
		CLEAN_STATUS_HISTORY_STORE_RECORD_INIT;
	struct clean_status_index_snapshot snapshot;
	struct history_store_fixture fixture;
	struct strbuf path;
	struct stat before, after;

	require_local_apfs(getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
	fixture_init(&fixture, algo);
	memset(checkpoint.index_hash, 1, algo->rawsz);
	checkpoint.fsmonitor = fsmn;
	checkpoint.fsmonitor_len = sizeof(fsmn) - 1;
	checkpoint.fsmonitor_config = fscf;
	checkpoint.fsmonitor_config_len = sizeof(fscf) - 1;
	path = history_store_path(&fixture, "proof-schema", algo);

	cl_assert_equal_i(clean_status_index_snapshot_open(
		&snapshot, fixture.index_path.buf, algo), 0);
	cl_assert_equal_i(clean_status_history_store_install(
		fixture.index_path.buf, "proof-schema", &checkpoint,
		&snapshot, algo), 0);
	cl_assert_equal_i(clean_status_history_store_load(
		fixture.index_path.buf, "proof-schema", algo, &record), 0);
	cl_assert(record.checkpoint.source_alias_valid);
	cl_assert(clean_status_history_checkpoint_source_matches(
		fixture.index_path.buf, &record.checkpoint, &snapshot, algo));
	cl_assert_equal_i(lstat(path.buf, &before), 0);
	cl_assert_equal_i(clean_status_history_store_install(
		fixture.index_path.buf, "proof-schema", &checkpoint,
		&snapshot, algo), 0);
	cl_assert_equal_i(lstat(path.buf, &after), 0);
	cl_assert_equal_i(before.st_ino, after.st_ino);

	clean_status_history_store_record_release(&record);
	clean_status_index_snapshot_release(&snapshot);
	strbuf_release(&path);
	fixture_release(&fixture);
}

void test_clean_status_history_store__bounds_namespaces(void)
{
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA1];
	static const unsigned char fsmn[] = "fsmn";
	static const unsigned char fscf[] = "fscf";
	struct clean_status_history_checkpoint checkpoint = { 0 };
	struct clean_status_index_snapshot snapshot;
	struct clean_status_history_store_record record =
		CLEAN_STATUS_HISTORY_STORE_RECORD_INIT;
	struct history_store_fixture fixture;
	struct strbuf cwd = STRBUF_INIT;
	struct strbuf encoded = STRBUF_INIT;
	struct strbuf extra = STRBUF_INIT;
	struct utimbuf times;
	char namespace[32];

	require_local_apfs(getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
	fixture_init(&fixture, algo);
	checkpoint.fsmonitor = fsmn;
	checkpoint.fsmonitor_len = sizeof(fsmn) - 1;
	checkpoint.fsmonitor_config = fscf;
	checkpoint.fsmonitor_config_len = sizeof(fscf) - 1;
	cl_assert_equal_i(clean_status_index_snapshot_open(
		&snapshot, fixture.index_path.buf, algo), 0);
	cl_assert_equal_i(strbuf_getcwd(&cwd), 0);
	cl_assert_equal_i(chdir(fixture.directory), 0);
	for (size_t i = 0; i < 10; i++) {
		struct strbuf path;

		xsnprintf(namespace, sizeof(namespace), "proof-schema-%"PRIuMAX,
			  (uintmax_t)i);
		memset(checkpoint.index_hash, i + 1, algo->rawsz);
		cl_assert_equal_i(clean_status_history_store_install(
			"index", namespace, &checkpoint, &snapshot, algo), 0);
		path = history_store_path_for_index("index", namespace, algo);
		times.actime = times.modtime = 100 + i;
		cl_assert_equal_i(utime(path.buf, &times), 0);
		strbuf_release(&path);
	}
	for (size_t i = 0; i < 10; i++) {
		xsnprintf(namespace, sizeof(namespace), "proof-schema-%"PRIuMAX,
			  (uintmax_t)i);
		if (i < 2) {
			cl_assert_equal_i(clean_status_history_store_load(
				"index", namespace, algo, &record), -1);
		} else {
			cl_assert_equal_i(clean_status_history_store_load(
				"index", namespace, algo, &record), 0);
			clean_status_history_store_record_release(&record);
		}
	}
	cl_assert_equal_i(count_history_store_files(".", "index", algo), 8);

	/*
	 * An identical reinstall must retain its target even when a relative
	 * index path makes the scanned candidate spell that path as "./...".
	 */
	xsnprintf(namespace, sizeof(namespace), "proof-schema-2");
	{
		struct strbuf retained = history_store_path_for_index(
			"index", namespace, algo);

		times.actime = times.modtime = 1;
		cl_assert_equal_i(utime(retained.buf, &times), 0);
		strbuf_addf(&extra, "index.csh1.%0*d", (int)algo->hexsz, 0);
		cl_assert(strbuf_read_file(&encoded, retained.buf, 0) > 0);
		write_file_buf(extra.buf, encoded.buf, encoded.len);
		times.actime = times.modtime = 1000;
		cl_assert_equal_i(utime(extra.buf, &times), 0);
		cl_assert_equal_i(
			count_history_store_files(".", "index", algo), 9);

		memset(checkpoint.index_hash, 3, algo->rawsz);
		cl_assert_equal_i(clean_status_history_store_install(
			"index", namespace, &checkpoint, &snapshot, algo), 0);
		cl_assert_equal_i(clean_status_history_store_load(
			"index", namespace, algo, &record), 0);
		clean_status_history_store_record_release(&record);
		cl_assert_equal_i(
			count_history_store_files(".", "index", algo), 8);
		strbuf_release(&retained);
	}
	xsnprintf(namespace, sizeof(namespace), "proof-schema-3");
	cl_assert_equal_i(clean_status_history_store_load(
		"index", namespace, algo, &record), -1);
	cl_assert_equal_i(chdir(cwd.buf), 0);

	clean_status_history_store_record_release(&record);
	clean_status_index_snapshot_release(&snapshot);
	strbuf_release(&extra);
	strbuf_release(&encoded);
	strbuf_release(&cwd);
	fixture_release(&fixture);
}
