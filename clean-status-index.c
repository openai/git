#include "git-compat-util.h"
#include "clean-status.h"
#include "clean-status-index.h"
#include "clean-status-internal.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "wrapper.h"

static int snapshot_read(
	int fd, const struct stat *st, const struct git_hash_algo *algo,
	uint32_t *version, uint32_t *cache_nr, struct object_id *checksum)
{
	unsigned char header[12];
	unsigned char trailer[GIT_MAX_RAWSZ];

	if (st->st_size < 0 ||
	    (uintmax_t)st->st_size < sizeof(header) + algo->rawsz ||
	    (size_t)pread_in_full(fd, header, sizeof(header), 0) !=
		sizeof(header) ||
	    memcmp(header, "DIRC", 4) ||
	    (size_t)pread_in_full(fd, trailer, algo->rawsz,
				  st->st_size - (off_t)algo->rawsz) !=
		algo->rawsz)
		return -1;
	*version = get_be32(header + 4);
	*cache_nr = get_be32(header + 8);
	if (*version < 2 || *version > 4)
		return -1;
	oidread(checksum, trailer, algo);
	return 0;
}

static int snapshot_matches(
	int fd, const struct stat *st, uint32_t expected_version,
	uint32_t expected_cache_nr, const struct object_id *expected_checksum,
	const struct git_hash_algo *algo)
{
	struct object_id checksum;
	uint32_t version, cache_nr;

	return !snapshot_read(fd, st, algo, &version, &cache_nr, &checksum) &&
		version == expected_version && cache_nr == expected_cache_nr &&
		oideq(&checksum, expected_checksum);
}

static int snapshot_open(
	struct clean_status_index_snapshot *snapshot, const char *path,
	const struct git_hash_algo *algo, int allow_null_checksum)
{
	struct clean_status_identity named;
	struct stat fd_st, named_st;
	int fd;

	memset(snapshot, 0, sizeof(*snapshot));
	snapshot->fd = -1;
	fd = open_nofollow(path, O_RDONLY);
	if (fd < 0 ||
	    fstat(fd, &fd_st) ||
	    lstat(path, &named_st) ||
	    clean_status_identity_from_stat(&snapshot->identity, &fd_st) ||
	    clean_status_identity_from_stat(&named, &named_st) ||
	    !clean_status_identity_equal(&snapshot->identity, &named) ||
	    snapshot_read(fd, &fd_st, algo, &snapshot->version,
			  &snapshot->cache_nr, &snapshot->checksum) ||
	    (!allow_null_checksum && is_null_oid(&snapshot->checksum)))
		goto fail;
	snapshot->fd = fd;
	return 0;

fail:
	if (fd >= 0)
		close(fd);
	return -1;
}

int clean_status_index_snapshot_open(
	struct clean_status_index_snapshot *snapshot, const char *path,
	const struct git_hash_algo *algo)
{
	return snapshot_open(snapshot, path, algo, 0);
}

int clean_status_index_snapshot_still_matches_path(
	const struct clean_status_index_snapshot *snapshot, const char *path,
	const struct git_hash_algo *algo)
{
	struct clean_status_identity fd_identity, named_identity;
	struct stat fd_st, named_st;

	return snapshot->fd >= 0 &&
		!fstat(snapshot->fd, &fd_st) &&
		!lstat(path, &named_st) &&
		!clean_status_identity_from_stat(&fd_identity, &fd_st) &&
		!clean_status_identity_from_stat(&named_identity, &named_st) &&
		clean_status_identity_equal(&fd_identity, &snapshot->identity) &&
		clean_status_identity_equal(&named_identity,
					    &snapshot->identity) &&
		snapshot_matches(snapshot->fd, &fd_st, snapshot->version,
				 snapshot->cache_nr, &snapshot->checksum, algo);
}

static int snapshot_matches_index_state(
	const struct clean_status_index_snapshot *snapshot,
	const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;

	return istate->version == snapshot->version &&
		istate->cache_nr == snapshot->cache_nr &&
		oideq(&istate->oid, &snapshot->checksum) &&
		(!is_null_oid(&snapshot->checksum) ||
		 (clean_status_identity_is_durable() && state &&
		  state->source_identity_valid &&
		  clean_status_identity_equal(&snapshot->identity,
					      &state->source_identity)));
}

int clean_status_index_snapshot_pin(
	struct clean_status_index_snapshot *snapshot,
	struct index_state *istate)
{
	if (snapshot_open(snapshot, istate->repo->index_file,
			  istate->repo->hash_algo, 1))
		return -1;
	if (snapshot_matches_index_state(snapshot, istate))
		return 0;
	clean_status_index_snapshot_release(snapshot);
	return -1;
}

int clean_status_index_snapshot_still_matches(
	const struct clean_status_index_snapshot *snapshot,
	const struct index_state *istate)
{
	return snapshot_matches_index_state(snapshot, istate) &&
		clean_status_index_snapshot_still_matches_path(
			snapshot, istate->repo->index_file,
			istate->repo->hash_algo);
}

void clean_status_index_snapshot_release(
	struct clean_status_index_snapshot *snapshot)
{
	if (snapshot->fd >= 0)
		close(snapshot->fd);
	snapshot->fd = -1;
}

void clean_status_record_source_identity(struct index_state *istate,
					 const struct stat *st)
{
	struct clean_status_state *state = istate->clean_status;

	if (!state || state->source_identity_valid ||
	    !clean_status_identity_is_durable())
		return;
	if (!clean_status_identity_from_stat(&state->source_identity, st))
		state->source_identity_valid = 1;
}

int clean_status_verify_null_index(const struct index_state *istate,
				   const struct stat *st)
{
	const struct clean_status_state *state = istate->clean_status;
	struct clean_status_identity identity;

	if (!state || !clean_status_identity_is_durable())
		return 1;
	return state->source_identity_valid &&
		!clean_status_identity_from_stat(&identity, st) &&
		clean_status_identity_equal(&identity, &state->source_identity);
}
