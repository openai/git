#include "git-compat-util.h"

#ifdef __APPLE__
#include <sys/mount.h>
#endif

#include "abspath.h"
#include "attr-fingerprint.h"
#include "clean-status-index.h"
#include "clean-status-sidecar.h"
#include "dir.h"
#include "fsmonitor-clean-proof.h"
#include "hash-framing.h"
#include "lockfile.h"
#include "path.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "replace-object.h"
#include "strbuf.h"
#include "worktree.h"
#include "wrapper.h"

#define CLEAN_STATUS_SIDECAR_MAGIC "CSTS"
#define CLEAN_STATUS_HARDLINK_PATH_MAX 4096
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
		(!is_null_oid(&proof->index_checksum) ||
		 clean_status_identity_is_durable()) &&
		!is_null_oid(&proof->head_tree) &&
		!is_null_oid(&proof->exclude_source_digest) &&
		proof->index_checksum.algo == hash_algo_by_ptr(algo) &&
		proof->head_tree.algo == hash_algo_by_ptr(algo) &&
		proof->exclude_source_digest.algo == hash_algo_by_ptr(algo);
}

static int hardlink_path_valid(const unsigned char *path, size_t len,
			       const struct path_stat_identity *identity)
{
	char *name;
	int valid;

	if (!path || !len || len > CLEAN_STATUS_HARDLINK_PATH_MAX ||
	    memchr(path, '\0', len) ||
	    identity->fields[2] > UINT32_MAX ||
	    !S_ISREG((mode_t)identity->fields[2]) ||
	    identity->fields[3] <= 1)
		return 0;
	name = xmemdupz(path, len);
	valid = verify_path(name, (unsigned)identity->fields[2]);
	free(name);
	return valid;
}

int clean_status_sidecar_append_hardlink(
	struct strbuf *out, const char *path,
	const struct path_stat_identity *identity)
{
	uint32_t path_len;
	uint64_t field;
	size_t len;

	if (!out || !path || !identity)
		return -1;
	len = strlen(path);
	if (!hardlink_path_valid((const unsigned char *)path, len, identity) ||
	    out->len > CLEAN_STATUS_SIDECAR_MAX_SIZE -
		(sizeof(path_len) + len + CLEAN_STATUS_IDENTITY_SIZE))
		return -1;
	put_be32(&path_len, (uint32_t)len);
	strbuf_add(out, &path_len, sizeof(path_len));
	strbuf_add(out, path, len);
	for (size_t i = 0; i < PATH_STAT_IDENTITY_FIELDS; i++) {
		put_be64(&field, identity->fields[i]);
		strbuf_add(out, &field, sizeof(field));
	}
	return 0;
}

int clean_status_sidecar_next_hardlink(
	const unsigned char **cursor, const unsigned char *end,
	const unsigned char **path, size_t *path_len,
	struct path_stat_identity *identity)
{
	const unsigned char *p;
	size_t len;

	if (!cursor || !*cursor || !end || !path || !path_len || !identity ||
	    *cursor > end || (size_t)(end - *cursor) < sizeof(uint32_t))
		return -1;
	p = *cursor;
	len = get_be32(p);
	p += sizeof(uint32_t);
	if (len > (size_t)(end - p) ||
	    (size_t)(end - p) - len < CLEAN_STATUS_IDENTITY_SIZE)
		return -1;
	*path = p;
	*path_len = len;
	p += len;
	for (size_t i = 0; i < PATH_STAT_IDENTITY_FIELDS; i++) {
		identity->fields[i] = get_be64(p);
		p += sizeof(uint64_t);
	}
	if (!hardlink_path_valid(*path, *path_len, identity))
		return -1;
	*cursor = p;
	return 0;
}

static int hardlink_block_valid(const unsigned char *block, size_t len,
				uint32_t nr)
{
	struct path_stat_identity identity;
	const unsigned char *cursor = block, *previous = NULL;
	const unsigned char *path;
	size_t path_len, previous_len = 0;

	if (!nr || nr > CLEAN_STATUS_HARDLINK_WITNESS_MAX || !block ||
	    len > CLEAN_STATUS_SIDECAR_MAX_SIZE)
		return 0;
	for (uint32_t i = 0; i < nr; i++) {
		if (clean_status_sidecar_next_hardlink(
			    &cursor, block + len, &path, &path_len, &identity))
			return 0;
		if (previous) {
			size_t common = previous_len < path_len ?
				previous_len : path_len;
			int order = memcmp(previous, path, common);

			if (order > 0 || (!order && previous_len >= path_len))
				return 0;
		}
		previous = path;
		previous_len = path_len;
	}
	return cursor == block + len;
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
	uint32_t flags, token_len, version;

	memset(sidecar, 0, sizeof(*sidecar));
	if (len < minimum || len > CLEAN_STATUS_SIDECAR_MAX_SIZE ||
	    memcmp(p, CLEAN_STATUS_SIDECAR_MAGIC, 4) ||
	    !checksum_valid(data, len, algo))
		return -1;
	end = p + len - algo->rawsz;
	p += 4;
	version = get_be32(p);
	if (version != CLEAN_STATUS_SIDECAR_VERSION &&
	    version != CLEAN_STATUS_SIDECAR_HARDLINK_VERSION)
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
	    (size_t)(end - p) < token_len ||
	    !token_valid(p, token_len))
		return -1;
	sidecar->token = p;
	sidecar->token_len = token_len;
	p += token_len;
	if (version == CLEAN_STATUS_SIDECAR_VERSION)
		return p == end ? 0 : -1;
	if ((size_t)(end - p) < sizeof(uint32_t))
		return -1;
	sidecar->hardlink_nr = get_be32(p);
	p += sizeof(uint32_t);
	sidecar->hardlinks = p;
	sidecar->hardlinks_len = end - p;
	if (!hardlink_block_valid(sidecar->hardlinks,
				  sidecar->hardlinks_len,
				  sidecar->hardlink_nr))
		return -1;
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
	    !token_valid(sidecar->token, sidecar->token_len) ||
	    (sidecar->hardlink_nr ?
		!hardlink_block_valid(sidecar->hardlinks,
				      sidecar->hardlinks_len,
				      sidecar->hardlink_nr) :
		(sidecar->hardlinks || sidecar->hardlinks_len)))
		return -1;

	strbuf_add(out, CLEAN_STATUS_SIDECAR_MAGIC, 4);
	put_be32(&value, sidecar->hardlink_nr ?
		 CLEAN_STATUS_SIDECAR_HARDLINK_VERSION :
		 CLEAN_STATUS_SIDECAR_VERSION);
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
	if (sidecar->hardlink_nr) {
		put_be32(&value, sidecar->hardlink_nr);
		strbuf_add(out, &value, sizeof(value));
		strbuf_add(out, sidecar->hardlinks, sidecar->hardlinks_len);
	}
	if (out->len > CLEAN_STATUS_SIDECAR_MAX_SIZE - algo->rawsz) {
		strbuf_reset(out);
		return -1;
	}
	hash_append_checksum(out, algo);
	return 0;
}

static char *sidecar_path(const char *index_path)
{
	return xstrfmt("%s.csts", index_path);
}

static int open_nofollow_nonblocking(const char *path, int flags)
{
#ifdef O_NONBLOCK
	return open_nofollow(path, flags | O_NONBLOCK);
#else
	(void)path;
	(void)flags;
	errno = ENOSYS;
	return -1;
#endif
}

int clean_status_sidecar_load(
	const char *index_path, const struct git_hash_algo *algo,
	struct clean_status_sidecar_record *record)
{
	struct stat st;
	char extra;
	char *path = sidecar_path(index_path);
	int fd = -1, ret = -1;
	size_t size;

	memset(&record->sidecar, 0, sizeof(record->sidecar));
	strbuf_reset(&record->storage);
	fd = open_nofollow_nonblocking(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) ||
	    st.st_size < 0 || st.st_size > CLEAN_STATUS_SIDECAR_MAX_SIZE)
		goto done;
	size = xsize_t(st.st_size);
	strbuf_grow(&record->storage, size);
	strbuf_setlen(&record->storage, size);
	if ((size_t)read_in_full(fd, record->storage.buf, size) != size ||
	    read(fd, &extra, 1) != 0 ||
	    clean_status_sidecar_parse(&record->sidecar,
				       record->storage.buf,
				       record->storage.len, algo))
		goto done;
	ret = 0;

done:
	if (ret)
		strbuf_reset(&record->storage);
	if (fd >= 0)
		close(fd);
	free(path);
	return ret;
}

void clean_status_sidecar_record_release(
	struct clean_status_sidecar_record *record)
{
	strbuf_release(&record->storage);
	memset(&record->sidecar, 0, sizeof(record->sidecar));
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
	if (clean_status_index_snapshot_open_allow_null_checksum(
		    snapshot, index_path, algo))
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
	sidecar_fd = hold_lock_file_for_update(&lock, path, LOCK_NO_DEREF);
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

int clean_status_worktree_shape_supported(struct repository *repo)
{
	struct worktree *current = get_current_worktree(repo);
	struct worktree *registered = NULL;
	int ret = 0;

	if (!current)
		goto done;
	if (is_main_worktree(current)) {
		ret = 1;
		goto done;
	}
	if (!current->id)
		goto done;
	/*
	 * A linked worktree has its own index and sidecar. Accept it only when
	 * both repository paths still name the worktree registered in the common
	 * directory; an ad-hoc GIT_DIR/GIT_WORK_TREE pairing must fall back.
	 */
	registered = get_linked_worktree(repo, current->id, 1);
	ret = registered && registered->is_current &&
		!fspathcmp(current->path, registered->path);

done:
	free_worktree(registered);
	free_worktree(current);
	return ret;
}

static int worktree_root_identity(
	const struct stat *st, uint64_t *identity MAYBE_UNUSED)
{
	if (!S_ISDIR(st->st_mode))
		return -1;
#ifdef __APPLE__
	identity[0] = st->st_dev;
	identity[1] = st->st_ino;
	identity[2] = st->st_birthtimespec.tv_sec;
	identity[3] = st->st_birthtimespec.tv_nsec;
	identity[4] = st->st_gen;
	return 0;
#else
	return -1;
#endif
}

int clean_status_repository_fingerprint(
	struct repository *repo,
	const struct attr_source_snapshot *attrs,
	const struct clean_status_index_snapshot *index,
	const struct stat *scanned_worktree,
	unsigned char *out)
{
	static const char domain[] = "git-clean-status-repository-v1";
	const struct attr_fingerprint *attr_fingerprint =
		attr_source_snapshot_fingerprint(attrs);
	struct clean_status_filesystem_id index_fsid, worktree_fsid;
	struct git_hash_ctx ctx;
	struct stat st;
	char *worktree = NULL, *gitdir = NULL, *commondir = NULL;
	uint64_t root_identity[5];
	uint64_t scanned_root_identity[5];
	uint64_t value;
	int worktree_fd = -1, ret = -1;

	if (!attr_fingerprint || attr_fingerprint->sources_present ||
	    !index || index->fd < 0 || !scanned_worktree ||
	    is_bare_repository(repo) ||
	    !repo_get_work_tree(repo) ||
	    !clean_status_worktree_shape_supported(repo) ||
	    repo_has_replace_refs_uncached(repo))
		goto done;

	worktree = real_pathdup(repo_get_work_tree(repo), 0);
	gitdir = real_pathdup(repo_get_git_dir(repo), 0);
	commondir = real_pathdup(repo_get_common_dir(repo), 0);
	if (!worktree || !gitdir || !commondir)
		goto done;
	worktree_fd = open_nofollow_nonblocking(
		worktree, O_RDONLY | O_CLOEXEC);
	if (worktree_fd < 0 ||
	    local_apfs_id(worktree_fd, &worktree_fsid) ||
	    local_apfs_id(index->fd, &index_fsid) ||
	    fstat(worktree_fd, &st) ||
	    worktree_root_identity(&st, root_identity) ||
	    worktree_root_identity(
		    scanned_worktree, scanned_root_identity) ||
	    memcmp(root_identity, scanned_root_identity,
		   sizeof(root_identity)))
		goto done;

	git_hash_init(&ctx, repo->hash_algo);
	hash_length_delimited(&ctx, domain, sizeof(domain) - 1);
	hash_length_delimited(&ctx, worktree, strlen(worktree));
	hash_length_delimited(&ctx, gitdir, strlen(gitdir));
	hash_length_delimited(&ctx, commondir, strlen(commondir));
	for (size_t i = 0; i < ARRAY_SIZE(root_identity); i++) {
		put_be64(&value, root_identity[i]);
		hash_length_delimited(&ctx, &value, sizeof(value));
	}
	hash_length_delimited(&ctx, worktree_fsid.value,
			      sizeof(worktree_fsid.value));
	hash_length_delimited(&ctx, index_fsid.value,
			      sizeof(index_fsid.value));
	hash_length_delimited(&ctx, attr_fingerprint->content_hash,
			      repo->hash_algo->rawsz);
	hash_optional_cstring(&ctx, setlocale(LC_CTYPE, NULL));
	hash_optional_cstring(&ctx, getenv("LC_ALL"));
	hash_optional_cstring(&ctx, getenv("LC_CTYPE"));
	hash_optional_cstring(&ctx, getenv("LANG"));
	git_hash_final(out, &ctx);
	ret = 0;

done:
	if (worktree_fd >= 0)
		close(worktree_fd);
	free(worktree);
	free(gitdir);
	free(commondir);
	return ret;
}
