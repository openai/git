#include "git-compat-util.h"

#ifdef __APPLE__
#include <sys/mount.h>
#endif

#include "clean-status-index.h"
#include "clean-status-sidecar.h"
#include "fsmonitor-clean-proof.h"
#include "hash-framing.h"
#include "lockfile.h"
#include "strbuf.h"
#include "wrapper.h"

#define CLEAN_STATUS_SIDECAR_MAGIC "CSTS"
#define CLEAN_STATUS_FILESYSTEM_ID_SIZE 16

struct clean_status_filesystem_id {
	unsigned char value[CLEAN_STATUS_FILESYSTEM_ID_SIZE];
};

static int checksum_valid(const void *data, size_t len,
			  const struct git_hash_algo *algo)
{
	const unsigned char *bytes = data;
	unsigned char actual[GIT_MAX_RAWSZ];

	if (len < algo->rawsz)
		return 0;
	hash_buffer_digest(algo, data, len - algo->rawsz, actual);
	return !memcmp(actual, bytes + len - algo->rawsz, algo->rawsz);
}

static int token_valid(const unsigned char *token, size_t token_len)
{
	static const char prefix[] = "builtin:";

	return token && token_len &&
		token_len <= FSMONITOR_CLEAN_PROOF_TOKEN_MAX &&
		!memchr(token, '\0', token_len) &&
		token_len >= sizeof(prefix) - 1 &&
		!memcmp(token, prefix, sizeof(prefix) - 1);
}

static int proof_valid(const struct clean_status_proof *proof,
		       const struct git_hash_algo *algo)
{
	return proof->index_version >= 2 && proof->index_version <= 4 &&
		!is_null_oid(&proof->index_checksum) &&
		!is_null_oid(&proof->head_tree) &&
		!is_null_oid(&proof->exclude_source_digest) &&
		proof->index_checksum.algo == hash_algo_by_ptr(algo) &&
		proof->head_tree.algo == hash_algo_by_ptr(algo) &&
		proof->exclude_source_digest.algo == hash_algo_by_ptr(algo);
}

int clean_status_sidecar_parse(struct clean_status_sidecar *sidecar,
			       const void *data, size_t len,
			       const struct git_hash_algo *algo)
{
	const unsigned char *p = data;
	const unsigned char *end;
	size_t minimum = 4 + 2 * sizeof(uint32_t) +
		CLEAN_STATUS_IDENTITY_SIZE + 3 * sizeof(uint32_t) +
		6 * algo->rawsz + 1;
	uint32_t flags, token_len;

	memset(sidecar, 0, sizeof(*sidecar));
	if (len < minimum || memcmp(p, CLEAN_STATUS_SIDECAR_MAGIC, 4) ||
	    !checksum_valid(data, len, algo))
		return -1;
	end = p + len - algo->rawsz;
	p += 4;
	if (get_be32(p) != CLEAN_STATUS_SIDECAR_VERSION)
		return -1;
	p += sizeof(uint32_t);
	flags = get_be32(p);
	p += sizeof(uint32_t);
	if (flags)
		return -1;
	if (clean_status_identity_read(&p, end, &sidecar->identity))
		return -1;
	sidecar->proof.index_version = get_be32(p);
	p += sizeof(uint32_t);
	sidecar->proof.cache_nr = get_be32(p);
	p += sizeof(uint32_t);
	oidread(&sidecar->proof.index_checksum, p, algo);
	p += algo->rawsz;
	oidread(&sidecar->proof.head_tree, p, algo);
	p += algo->rawsz;
	memcpy(sidecar->proof.config_hash, p, algo->rawsz);
	p += algo->rawsz;
	memcpy(sidecar->proof.repo_hash, p, algo->rawsz);
	p += algo->rawsz;
	oidread(&sidecar->proof.exclude_source_digest, p, algo);
	p += algo->rawsz;
	token_len = get_be32(p);
	p += sizeof(uint32_t);
	if (!proof_valid(&sidecar->proof, algo) ||
	    (size_t)(end - p) != token_len ||
	    !token_valid(p, token_len))
		return -1;
	sidecar->token = p;
	sidecar->token_len = token_len;
	return 0;
}

int clean_status_sidecar_write(struct strbuf *out,
			       const struct clean_status_sidecar *sidecar,
			       const struct git_hash_algo *algo)
{
	uint32_t value;

	strbuf_reset(out);
	if (!proof_valid(&sidecar->proof, algo) ||
	    sidecar->token_len > UINT32_MAX ||
	    !token_valid(sidecar->token, sidecar->token_len))
		return -1;

	strbuf_add(out, CLEAN_STATUS_SIDECAR_MAGIC, 4);
	put_be32(&value, CLEAN_STATUS_SIDECAR_VERSION);
	strbuf_add(out, &value, sizeof(value));
	put_be32(&value, 0);
	strbuf_add(out, &value, sizeof(value));
	clean_status_identity_write(out, &sidecar->identity);
	put_be32(&value, sidecar->proof.index_version);
	strbuf_add(out, &value, sizeof(value));
	put_be32(&value, sidecar->proof.cache_nr);
	strbuf_add(out, &value, sizeof(value));
	strbuf_add(out, sidecar->proof.index_checksum.hash, algo->rawsz);
	strbuf_add(out, sidecar->proof.head_tree.hash, algo->rawsz);
	strbuf_add(out, sidecar->proof.config_hash, algo->rawsz);
	strbuf_add(out, sidecar->proof.repo_hash, algo->rawsz);
	strbuf_add(out, sidecar->proof.exclude_source_digest.hash,
		   algo->rawsz);
	put_be32(&value, sidecar->token_len);
	strbuf_add(out, &value, sizeof(value));
	strbuf_add(out, sidecar->token, sidecar->token_len);
	hash_append_checksum(out, algo);
	return 0;
}

static char *sidecar_path(const char *index_path)
{
	return xstrfmt("%s.csts", index_path);
}

static int local_apfs_id(int fd MAYBE_UNUSED,
			 struct clean_status_filesystem_id *id)
{
#ifdef __APPLE__
	struct statfs fs;
#endif

	memset(id, 0, sizeof(*id));
#ifdef __APPLE__
	if (fstatfs(fd, &fs) || !(fs.f_flags & MNT_LOCAL) ||
	    strcmp(fs.f_fstypename, "apfs") ||
	    sizeof(fs.f_fsid) > sizeof(id->value))
		return -1;
	memcpy(id->value, &fs.f_fsid, sizeof(fs.f_fsid));
	return 0;
#else
	return -1;
#endif
}

static int sidecar_matches_snapshot(
	const char *index_path, const struct clean_status_sidecar *sidecar,
	const struct clean_status_index_snapshot *snapshot,
	const struct git_hash_algo *algo)
{
	struct clean_status_filesystem_id fsid;

	return clean_status_identity_is_durable() &&
		snapshot && snapshot->fd >= 0 &&
		!local_apfs_id(snapshot->fd, &fsid) &&
		clean_status_identity_equal(&snapshot->identity,
					    &sidecar->identity) &&
		snapshot->version == sidecar->proof.index_version &&
		snapshot->cache_nr == sidecar->proof.cache_nr &&
		oideq(&snapshot->checksum,
		      &sidecar->proof.index_checksum) &&
		clean_status_index_snapshot_still_matches_path(
			snapshot, index_path, algo);
}

int clean_status_sidecar_pin_source(
	const char *index_path, const struct clean_status_sidecar *sidecar,
	const struct git_hash_algo *algo,
	struct clean_status_index_snapshot *snapshot)
{
	if (clean_status_index_snapshot_open(snapshot, index_path, algo))
		return -1;
	if (sidecar_matches_snapshot(
		    index_path, sidecar, snapshot, algo))
		return 0;
	clean_status_index_snapshot_release(snapshot);
	return -1;
}

int clean_status_sidecar_install(
	const char *index_path, const struct clean_status_sidecar *sidecar,
	const struct clean_status_index_snapshot *snapshot,
	const struct git_hash_algo *algo)
{
	struct strbuf encoded = STRBUF_INIT;
	struct lock_file lock = LOCK_INIT;
	char *path = sidecar_path(index_path);
	int sidecar_fd = -1, ret = -1;

	if (!sidecar_matches_snapshot(
		    index_path, sidecar, snapshot, algo) ||
	    clean_status_sidecar_write(&encoded, sidecar, algo))
		goto done;
	sidecar_fd = hold_lock_file_for_update(&lock, path, 0);
	if (sidecar_fd < 0 ||
	    (size_t)write_in_full(sidecar_fd, encoded.buf, encoded.len) !=
		    encoded.len ||
	    !sidecar_matches_snapshot(
		    index_path, sidecar, snapshot, algo) ||
	    commit_lock_file(&lock))
		goto done;
	ret = 0;

done:
	if (ret)
		rollback_lock_file(&lock);
	free(path);
	strbuf_release(&encoded);
	return ret;
}
