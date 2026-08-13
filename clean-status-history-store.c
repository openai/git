#include "git-compat-util.h"

#ifdef __APPLE__
#include <sys/clonefile.h>
#include <sys/mount.h>
#endif

#include "clean-status-history-store.h"
#include "clean-status-identity.h"
#include "clean-status-index.h"
#include "hash-framing.h"
#include "hex.h"
#include "lockfile.h"
#include "path.h"
#include "strbuf.h"
#include "wrapper.h"

#define CLEAN_STATUS_HISTORY_CHECKPOINT_MAGIC "CSHS"
#define CLEAN_STATUS_HISTORY_CHECKPOINT_VERSION 2
#define CLEAN_STATUS_HISTORY_CHECKPOINT_LEGACY_VERSION 1
#define CLEAN_STATUS_HISTORY_CHECKPOINT_MAX_SIZE (16 * 1024 * 1024)
#define CLEAN_STATUS_HISTORY_STORE_MAX_FILES 8
#define CLEAN_STATUS_HISTORY_HAS_FSMN (1U << 0)
#define CLEAN_STATUS_HISTORY_HAS_UNTR (1U << 1)
#define CLEAN_STATUS_HISTORY_HAS_FSCF (1U << 2)
#define CLEAN_STATUS_HISTORY_HAS_FSUC (1U << 3)
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

static void proof_namespace_hash(const char *proof_namespace,
				 const struct git_hash_algo *algo,
				 unsigned char *out)
{
	static const char domain[] = "git-clean-status-history-namespace-v1";
	struct git_hash_ctx ctx;

	git_hash_init(&ctx, algo);
	hash_length_delimited(&ctx, domain, sizeof(domain) - 1);
	hash_length_delimited(&ctx, proof_namespace, strlen(proof_namespace));
	git_hash_final(out, &ctx);
}

static char *history_store_path(const char *index_path,
				const char *proof_namespace,
				const struct git_hash_algo *algo)
{
	unsigned char hash[GIT_MAX_RAWSZ];
	char hex[GIT_MAX_HEXSZ + 1];

	proof_namespace_hash(proof_namespace, algo, hash);
	hash_to_hex_algop_r(hex, hash, algo);
	return xstrfmt("%s.csh1.%s", index_path, hex);
}

char *clean_status_history_store_witness_path(
	const char *index_path, const char *proof_namespace,
	const struct git_hash_algo *algo)
{
	unsigned char hash[GIT_MAX_RAWSZ];
	char hex[GIT_MAX_HEXSZ + 1];

	proof_namespace_hash(proof_namespace, algo, hash);
	hash_to_hex_algop_r(hex, hash, algo);
	return xstrfmt("%s.cswi.%s", index_path, hex);
}

struct history_store_file {
	char *path;
	timestamp_t mtime;
	unsigned int mtime_nsec;
	unsigned retained : 1;
};

static int history_store_file_cmp(const void *va, const void *vb)
{
	const struct history_store_file *a = va;
	const struct history_store_file *b = vb;

	if (a->mtime != b->mtime)
		return a->mtime < b->mtime ? -1 : 1;
	if (a->mtime_nsec != b->mtime_nsec)
		return a->mtime_nsec < b->mtime_nsec ? -1 : 1;
	return strcmp(a->path, b->path);
}

/*
 * The status caller holds index.lock while publishing a checkpoint.  That
 * serializes this directory-level retention step with every supported
 * publisher, while per-slot lockfiles still make each replacement atomic.
 */
static int prune_history_store(const char *index_path,
			       const char *retained_path,
			       const struct git_hash_algo *algo,
			       size_t limit)
{
	struct history_store_file *files = NULL;
	struct strbuf directory = STRBUF_INIT;
	struct strbuf prefix = STRBUF_INIT;
	struct strbuf candidate = STRBUF_INIT;
	const char *slash = find_last_dir_sep(index_path);
	const char *base = slash ? slash + 1 : index_path;
	const char *retained_slash = find_last_dir_sep(retained_path);
	const char *retained_base = retained_slash ?
		retained_slash + 1 : retained_path;
	DIR *dir = NULL;
	struct dirent *de;
	size_t nr = 0, alloc = 0, remove_nr;
	int ret = -1;

	if (slash) {
		if (slash == index_path)
			strbuf_addch(&directory, '/');
		else
			strbuf_add(&directory, index_path, slash - index_path);
	} else {
		strbuf_addch(&directory, '.');
	}
	strbuf_addf(&prefix, "%s.csh1.", base);
	dir = opendir(directory.buf);
	if (!dir)
		goto done;
	while ((de = readdir(dir))) {
		const char *suffix;
		struct stat st;

		if (!starts_with(de->d_name, prefix.buf))
			continue;
		suffix = de->d_name + prefix.len;
		if (strlen(suffix) != algo->hexsz ||
		    strspn(suffix, "0123456789abcdef") != algo->hexsz)
			continue;
		strbuf_reset(&candidate);
		strbuf_addf(&candidate, "%s/%s", directory.buf, de->d_name);
		if (lstat(candidate.buf, &st) || !S_ISREG(st.st_mode))
			continue;
		ALLOC_GROW(files, nr + 1, alloc);
		files[nr].path = xstrdup(candidate.buf);
		files[nr].mtime = st.st_mtime;
		files[nr].mtime_nsec = ST_MTIME_NSEC(st);
		files[nr].retained = !strcmp(de->d_name, retained_base);
		nr++;
	}
	if (limit >= nr) {
		ret = 0;
		goto done;
	}
	QSORT(files, nr, history_store_file_cmp);
	remove_nr = nr - limit;
	for (size_t i = 0; i < nr && remove_nr; i++) {
		struct stat st;

		if (files[i].retained)
			continue;
		/* Recheck without following links immediately before removal. */
		if (lstat(files[i].path, &st) || !S_ISREG(st.st_mode) ||
		    unlink(files[i].path))
			goto done;
		{
			char *witness = xstrdup(files[i].path);
			size_t pathlen = strlen(witness);
			char *marker = pathlen >= algo->hexsz + 6 ?
				witness + pathlen - algo->hexsz - 6 : NULL;

			if (marker && !memcmp(marker, ".csh1.", 6))
				memcpy(marker, ".cswi.", 6);
			else
				marker = NULL;
			if (marker && !lstat(witness, &st) &&
			    S_ISREG(st.st_mode))
				unlink(witness);
			free(witness);
		}
		remove_nr--;
	}
	ret = remove_nr ? -1 : 0;

done:
	if (dir)
		closedir(dir);
	for (size_t i = 0; i < nr; i++)
		free(files[i].path);
	free(files);
	strbuf_release(&candidate);
	strbuf_release(&prefix);
	strbuf_release(&directory);
	return ret;
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

int clean_status_history_checkpoint_parse(
	struct clean_status_history_checkpoint *checkpoint,
	const char *proof_namespace, const void *data, size_t len,
	const struct git_hash_algo *algo)
{
	const unsigned char *p = data;
	const unsigned char *end;
	const unsigned char *payload;
	unsigned char expected_namespace[GIT_MAX_RAWSZ];
	size_t minimum = 4 + 2 * sizeof(uint32_t) + 2 * algo->rawsz +
		4 * sizeof(uint32_t) + algo->rawsz;
	uint32_t version, flags, lengths[4];

	memset(checkpoint, 0, sizeof(*checkpoint));
	if (!proof_namespace || !*proof_namespace || len < minimum ||
	    len > CLEAN_STATUS_HISTORY_CHECKPOINT_MAX_SIZE ||
	    memcmp(p, CLEAN_STATUS_HISTORY_CHECKPOINT_MAGIC, 4) ||
	    !checksum_valid(data, len, algo))
		return -1;
	end = p + len - algo->rawsz;
	p += 4;
	version = get_be32(p);
	if (version != CLEAN_STATUS_HISTORY_CHECKPOINT_VERSION &&
	    version != CLEAN_STATUS_HISTORY_CHECKPOINT_LEGACY_VERSION)
		return -1;
	p += sizeof(uint32_t);
	if (version == CLEAN_STATUS_HISTORY_CHECKPOINT_VERSION) {
		minimum += CLEAN_STATUS_IDENTITY_SIZE +
			2 * sizeof(uint32_t) + algo->rawsz;
		if (len < minimum)
			return -1;
	}
	flags = get_be32(p);
	p += sizeof(uint32_t);
	if ((flags & (CLEAN_STATUS_HISTORY_HAS_FSMN |
		      CLEAN_STATUS_HISTORY_HAS_FSCF)) !=
		    (CLEAN_STATUS_HISTORY_HAS_FSMN |
		     CLEAN_STATUS_HISTORY_HAS_FSCF) ||
	    !!(flags & CLEAN_STATUS_HISTORY_HAS_UNTR) !=
		    !!(flags & CLEAN_STATUS_HISTORY_HAS_FSUC) ||
	    flags & ~(CLEAN_STATUS_HISTORY_HAS_FSMN |
			       CLEAN_STATUS_HISTORY_HAS_UNTR |
			       CLEAN_STATUS_HISTORY_HAS_FSCF |
			       CLEAN_STATUS_HISTORY_HAS_FSUC))
		return -1;
	proof_namespace_hash(proof_namespace, algo, expected_namespace);
	if (memcmp(p, expected_namespace, algo->rawsz))
		return -1;
	p += algo->rawsz;
	memcpy(checkpoint->index_hash, p, algo->rawsz);
	p += algo->rawsz;
	if (version == CLEAN_STATUS_HISTORY_CHECKPOINT_VERSION) {
		if (clean_status_identity_read(
			    &p, end, &checkpoint->source_identity))
			return -1;
		checkpoint->source_version = get_be32(p);
		p += sizeof(uint32_t);
		checkpoint->source_cache_nr = get_be32(p);
		p += sizeof(uint32_t);
		oidread(&checkpoint->source_checksum, p, algo);
		p += algo->rawsz;
		if (checkpoint->source_version < 2 ||
		    checkpoint->source_version > 4)
			return -1;
		checkpoint->source_alias_valid = 1;
	}
	for (size_t i = 0; i < ARRAY_SIZE(lengths); i++) {
		lengths[i] = get_be32(p);
		p += sizeof(uint32_t);
	}
	payload = p;
	if (!!lengths[0] != !!(flags & CLEAN_STATUS_HISTORY_HAS_FSMN) ||
	    !!lengths[1] != !!(flags & CLEAN_STATUS_HISTORY_HAS_UNTR) ||
	    !!lengths[2] != !!(flags & CLEAN_STATUS_HISTORY_HAS_FSCF) ||
	    !!lengths[3] != !!(flags & CLEAN_STATUS_HISTORY_HAS_FSUC))
		return -1;
	for (size_t i = 0; i < ARRAY_SIZE(lengths); i++) {
		if ((size_t)(end - p) < lengths[i])
			return -1;
		p += lengths[i];
	}
	if (p != end)
		return -1;
	p = payload;
	if (lengths[0]) {
		checkpoint->fsmonitor = p;
		checkpoint->fsmonitor_len = lengths[0];
		p += lengths[0];
	}
	if (lengths[1]) {
		checkpoint->untracked_cache = p;
		checkpoint->untracked_cache_len = lengths[1];
		p += lengths[1];
	}
	if (lengths[2]) {
		checkpoint->fsmonitor_config = p;
		checkpoint->fsmonitor_config_len = lengths[2];
		p += lengths[2];
	}
	if (lengths[3]) {
		checkpoint->fsmonitor_untracked = p;
		checkpoint->fsmonitor_untracked_len = lengths[3];
	}
	return 0;
}

int clean_status_history_checkpoint_write(
	struct strbuf *out, const char *proof_namespace,
	const struct clean_status_history_checkpoint *checkpoint,
	const struct git_hash_algo *algo)
{
	unsigned char namespace_hash[GIT_MAX_RAWSZ];
	uint32_t value, flags = 0;
	uint32_t version = checkpoint->source_alias_valid ?
		CLEAN_STATUS_HISTORY_CHECKPOINT_VERSION :
		CLEAN_STATUS_HISTORY_CHECKPOINT_LEGACY_VERSION;

	strbuf_reset(out);
	if (!proof_namespace || !*proof_namespace ||
	    checkpoint->fsmonitor_len > UINT32_MAX ||
	    checkpoint->untracked_cache_len > UINT32_MAX ||
	    checkpoint->fsmonitor_config_len > UINT32_MAX ||
	    checkpoint->fsmonitor_untracked_len > UINT32_MAX ||
	    (!!checkpoint->fsmonitor != !!checkpoint->fsmonitor_len) ||
	    (!!checkpoint->untracked_cache !=
	     !!checkpoint->untracked_cache_len) ||
	    (!!checkpoint->fsmonitor_config !=
	     !!checkpoint->fsmonitor_config_len) ||
	    (!!checkpoint->fsmonitor_untracked !=
	     !!checkpoint->fsmonitor_untracked_len) ||
	    (checkpoint->source_alias_valid &&
	     (checkpoint->source_version < 2 ||
	      checkpoint->source_version > 4 ||
	      checkpoint->source_checksum.algo != hash_algo_by_ptr(algo))) ||
	    !checkpoint->fsmonitor_len || !checkpoint->fsmonitor_config_len ||
	    (!!checkpoint->untracked_cache_len !=
	     !!checkpoint->fsmonitor_untracked_len))
		return -1;
	flags |= CLEAN_STATUS_HISTORY_HAS_FSMN;
	if (checkpoint->untracked_cache_len)
		flags |= CLEAN_STATUS_HISTORY_HAS_UNTR;
	if (checkpoint->fsmonitor_config_len)
		flags |= CLEAN_STATUS_HISTORY_HAS_FSCF;
	if (checkpoint->fsmonitor_untracked_len)
		flags |= CLEAN_STATUS_HISTORY_HAS_FSUC;
	proof_namespace_hash(proof_namespace, algo, namespace_hash);
	strbuf_add(out, CLEAN_STATUS_HISTORY_CHECKPOINT_MAGIC, 4);
	put_be32(&value, version);
	strbuf_add(out, &value, sizeof(value));
	put_be32(&value, flags);
	strbuf_add(out, &value, sizeof(value));
	strbuf_add(out, namespace_hash, algo->rawsz);
	strbuf_add(out, checkpoint->index_hash, algo->rawsz);
	if (checkpoint->source_alias_valid) {
		clean_status_identity_write(out, &checkpoint->source_identity);
		put_be32(&value, checkpoint->source_version);
		strbuf_add(out, &value, sizeof(value));
		put_be32(&value, checkpoint->source_cache_nr);
		strbuf_add(out, &value, sizeof(value));
		strbuf_add(out, checkpoint->source_checksum.hash,
			   algo->rawsz);
	}
	put_be32(&value, checkpoint->fsmonitor_len);
	strbuf_add(out, &value, sizeof(value));
	put_be32(&value, checkpoint->untracked_cache_len);
	strbuf_add(out, &value, sizeof(value));
	put_be32(&value, checkpoint->fsmonitor_config_len);
	strbuf_add(out, &value, sizeof(value));
	put_be32(&value, checkpoint->fsmonitor_untracked_len);
	strbuf_add(out, &value, sizeof(value));
	strbuf_add(out, checkpoint->fsmonitor, checkpoint->fsmonitor_len);
	if (checkpoint->untracked_cache_len)
		strbuf_add(out, checkpoint->untracked_cache,
			   checkpoint->untracked_cache_len);
	strbuf_add(out, checkpoint->fsmonitor_config,
		   checkpoint->fsmonitor_config_len);
	if (checkpoint->fsmonitor_untracked_len)
		strbuf_add(out, checkpoint->fsmonitor_untracked,
			   checkpoint->fsmonitor_untracked_len);
	hash_append_checksum(out, algo);
	if (out->len > CLEAN_STATUS_HISTORY_CHECKPOINT_MAX_SIZE) {
		strbuf_reset(out);
		return -1;
	}
	return 0;
}

int clean_status_history_store_load(
	const char *index_path, const char *proof_namespace,
	const struct git_hash_algo *algo,
	struct clean_status_history_store_record *record)
{
	struct stat st;
	char extra;
	char *path = history_store_path(index_path, proof_namespace, algo);
	int fd = -1, ret = -1;
	size_t size;

	memset(&record->checkpoint, 0, sizeof(record->checkpoint));
	strbuf_reset(&record->storage);
	fd = open_nofollow_nonblocking(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) ||
	    st.st_size < 0 ||
	    st.st_size > CLEAN_STATUS_HISTORY_CHECKPOINT_MAX_SIZE)
		goto done;
	size = xsize_t(st.st_size);
	strbuf_grow(&record->storage, size);
	strbuf_setlen(&record->storage, size);
	if ((size_t)read_in_full(fd, record->storage.buf, size) != size ||
	    read(fd, &extra, 1) != 0 ||
	    clean_status_history_checkpoint_parse(
		    &record->checkpoint, proof_namespace, record->storage.buf,
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

void clean_status_history_store_record_release(
	struct clean_status_history_store_record *record)
{
	strbuf_release(&record->storage);
	memset(&record->checkpoint, 0, sizeof(record->checkpoint));
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

static void install_history_witness(
	const char *index_path, const char *proof_namespace,
	const struct clean_status_index_snapshot *snapshot,
	const struct git_hash_algo *algo, int encoded_matches)
{
#ifdef __APPLE__
	struct clean_status_filesystem_id fsid;
	struct clean_status_index_snapshot existing = { .fd = -1 };
	char *witness = NULL, *temporary = NULL;

	if (!snapshot || snapshot->fd < 0 ||
	    local_apfs_id(snapshot->fd, &fsid))
		return;
	witness = clean_status_history_store_witness_path(
		index_path, proof_namespace, algo);
	if (encoded_matches &&
	    !clean_status_index_snapshot_open(&existing, witness, algo) &&
	    existing.version == snapshot->version &&
	    existing.cache_nr == snapshot->cache_nr &&
	    oideq(&existing.checksum, &snapshot->checksum)) {
		clean_status_index_snapshot_release(&existing);
		free(witness);
		return;
	}
	clean_status_index_snapshot_release(&existing);
	temporary = xstrfmt("%s.tmp.%"PRIuMAX, witness,
			   (uintmax_t)getpid());
	if (!fclonefileat(snapshot->fd, AT_FDCWD, temporary, 0) &&
	    clean_status_index_snapshot_still_matches_path(
		    snapshot, index_path, algo))
		rename(temporary, witness);
	unlink(temporary);
	free(temporary);
	free(witness);
#else
	(void)index_path;
	(void)proof_namespace;
	(void)snapshot;
	(void)algo;
	(void)encoded_matches;
#endif
}

int clean_status_history_checkpoint_source_matches(
	const char *index_path,
	const struct clean_status_history_checkpoint *checkpoint,
	const struct clean_status_index_snapshot *snapshot,
	const struct git_hash_algo *algo)
{
	struct clean_status_filesystem_id fsid;

	return checkpoint && checkpoint->source_alias_valid &&
		clean_status_identity_is_durable() &&
		snapshot && snapshot->fd >= 0 &&
		!local_apfs_id(snapshot->fd, &fsid) &&
		clean_status_identity_equal(
			&checkpoint->source_identity, &snapshot->identity) &&
		checkpoint->source_version == snapshot->version &&
		checkpoint->source_cache_nr == snapshot->cache_nr &&
		oideq(&checkpoint->source_checksum, &snapshot->checksum) &&
		clean_status_index_snapshot_still_matches_path(
			snapshot, index_path, algo);
}

int clean_status_history_store_install(
	const char *index_path, const char *proof_namespace,
	const struct clean_status_history_checkpoint *checkpoint,
	const struct clean_status_index_snapshot *snapshot,
	const struct git_hash_algo *algo)
{
	struct clean_status_filesystem_id fsid;
	struct clean_status_history_checkpoint aliased;
	struct clean_status_history_store_record current =
		CLEAN_STATUS_HISTORY_STORE_RECORD_INIT;
	struct strbuf encoded = STRBUF_INIT;
	struct lock_file lock = LOCK_INIT;
	char *path = history_store_path(index_path, proof_namespace, algo);
	struct stat st;
	int current_is_regular, encoded_matches = 0;
	int checkpoint_fd = -1, ret = -1;

#ifdef GIT_WINDOWS_NATIVE
	/* Preserve the unsupported Windows path's original fail-closed behavior. */
	goto done;
#endif
	if (!snapshot || snapshot->fd < 0 ||
	    !clean_status_index_snapshot_still_matches_path(
		    snapshot, index_path, algo))
		goto done;
	aliased = *checkpoint;
	aliased.source_alias_valid =
		clean_status_identity_is_durable() &&
		!local_apfs_id(snapshot->fd, &fsid);
	if (aliased.source_alias_valid) {
		aliased.source_identity = snapshot->identity;
		aliased.source_version = snapshot->version;
		aliased.source_cache_nr = snapshot->cache_nr;
		oidcpy(&aliased.source_checksum, &snapshot->checksum);
	}
	if (clean_status_history_checkpoint_write(
		    &encoded, proof_namespace, &aliased, algo))
		goto done;
	current_is_regular = !lstat(path, &st) && S_ISREG(st.st_mode);
	if (!clean_status_history_store_load(
		    index_path, proof_namespace, algo, &current))
		encoded_matches = current.storage.len == encoded.len &&
			!memcmp(current.storage.buf, encoded.buf, encoded.len);
	clean_status_history_store_record_release(&current);

	/*
	 * If this namespace is new, make room before the atomic install so a
	 * successful publication never takes the bounded store above eight
	 * regular checkpoint slots.  No other checkpoint schema is considered.
	 */
	if (prune_history_store(
		    index_path, path, algo,
		    current_is_regular ? CLEAN_STATUS_HISTORY_STORE_MAX_FILES :
				 CLEAN_STATUS_HISTORY_STORE_MAX_FILES - 1) ||
	    !clean_status_index_snapshot_still_matches_path(
		    snapshot, index_path, algo))
		goto done;
	if (aliased.source_alias_valid)
		install_history_witness(index_path, proof_namespace,
					snapshot, algo, encoded_matches);
	if (encoded_matches) {
		ret = 0;
		goto done;
	}
	checkpoint_fd = hold_lock_file_for_update(&lock, path, 0);
	if (checkpoint_fd < 0 ||
	    (size_t)write_in_full(checkpoint_fd, encoded.buf, encoded.len) !=
		    encoded.len ||
	    !clean_status_index_snapshot_still_matches_path(
		    snapshot, index_path, algo) ||
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
