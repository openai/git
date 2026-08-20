#include "git-compat-util.h"
#include "clean-status.h"
#include "clean-status-index.h"
#include "clean-status-internal.h"
#include "clean-status-sidecar.h"
#include "hash-framing.h"
#include "object.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "trace2.h"
#include "wrapper.h"

#define LOGICAL_INDEX_PERSISTENT_FLAGS \
	(CE_STAGEMASK | CE_EXTENDED | CE_VALID | CE_EXTENDED_FLAGS)
#define LOGICAL_INDEX_BENIGN_FLAGS \
	(CE_UPTODATE | CE_HASHED | CE_FSMONITOR_VALID)

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

int clean_status_index_snapshot_open_allow_null_checksum(
	struct clean_status_index_snapshot *snapshot, const char *path,
	const struct git_hash_algo *algo)
{
	return snapshot_open(snapshot, path, algo, 1);
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

static int source_index_matches_snapshot(
	const struct clean_status_index_snapshot *snapshot,
	const struct clean_status_state *state,
	const struct git_hash_algo *algo)
{
	struct clean_status_identity identity;
	struct stat st;

	return state && state->source_index_fd >= 0 &&
		state->source_index_identity_valid &&
		!fstat(state->source_index_fd, &st) &&
		!clean_status_identity_from_stat(&identity, &st) &&
		clean_status_identity_equal(
			&identity, &state->source_index_identity) &&
		clean_status_identity_equal(
			&snapshot->identity, &state->source_index_identity) &&
		snapshot_matches(state->source_index_fd, &st,
				 snapshot->version, snapshot->cache_nr,
				 &snapshot->checksum, algo);
}

static int snapshot_matches_index_state(
	const struct clean_status_index_snapshot *snapshot,
	const struct index_state *istate, int allow_process_local_source)
{
	const struct clean_status_state *state = istate->clean_status;

	if (istate->version != snapshot->version ||
	    istate->cache_nr != snapshot->cache_nr ||
	    !oideq(&istate->oid, &snapshot->checksum))
		return 0;
	if (!is_null_oid(&snapshot->checksum))
		return 1;
	if (clean_status_identity_is_durable() && state &&
	    state->source_identity_valid &&
	    clean_status_identity_equal(&snapshot->identity,
					&state->source_identity))
		return 1;
	return allow_process_local_source &&
		source_index_matches_snapshot(
			snapshot, state, istate->repo->hash_algo);
}

static int snapshot_pin(
	struct clean_status_index_snapshot *snapshot,
	struct index_state *istate, int allow_process_local_source)
{
	if (snapshot_open(snapshot, istate->repo->index_file,
			  istate->repo->hash_algo, 1))
		return -1;
	if (snapshot_matches_index_state(
		    snapshot, istate, allow_process_local_source))
		return 0;
	clean_status_index_snapshot_release(snapshot);
	return -1;
}

int clean_status_index_snapshot_pin(
	struct clean_status_index_snapshot *snapshot,
	struct index_state *istate)
{
	return snapshot_pin(snapshot, istate, 0);
}

int clean_status_index_snapshot_pin_proof_epoch(
	struct clean_status_index_snapshot *snapshot,
	struct index_state *istate)
{
	/*
	 * A proof epoch is process-local and dies with its index state.  It may
	 * therefore use the descriptor for the file which populated that state.
	 * Persisted history and sidecars continue to use the generic pin above.
	 */
	return snapshot_pin(snapshot, istate, 1);
}

static int snapshot_still_matches(
	const struct clean_status_index_snapshot *snapshot,
	const struct index_state *istate, int allow_process_local_source)
{
	return snapshot_matches_index_state(
			snapshot, istate, allow_process_local_source) &&
		clean_status_index_snapshot_still_matches_path(
			snapshot, istate->repo->index_file,
			istate->repo->hash_algo);
}

int clean_status_index_snapshot_still_matches(
	const struct clean_status_index_snapshot *snapshot,
	const struct index_state *istate)
{
	return snapshot_still_matches(snapshot, istate, 0);
}

int clean_status_index_snapshot_still_matches_proof_epoch(
	const struct clean_status_index_snapshot *snapshot,
	const struct index_state *istate)
{
	return snapshot_still_matches(snapshot, istate, 1);
}

void clean_status_index_snapshot_release(
	struct clean_status_index_snapshot *snapshot)
{
	if (snapshot->fd >= 0)
		close(snapshot->fd);
	snapshot->fd = -1;
}

int clean_status_index_entries_are_certifiable(
	const struct index_state *istate)
{
	for (size_t i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];

		if (S_ISGITLINK(ce->ce_mode) || ce_stage(ce) ||
		    ce_intent_to_add(ce) || ce_skip_worktree(ce) ||
		    (ce->ce_flags & CE_VALID) ||
		    !(ce->ce_flags & CE_FSMONITOR_VALID) ||
		    (ce->ce_flags & ~(CE_UPTODATE | CE_HASHED |
				     CE_FSMONITOR_VALID |
				     CE_UPDATE_IN_BASE)))
			return 0;
	}
	return 1;
}

int clean_status_index_is_certifiable(const struct index_state *istate)
{
	const struct clean_status_state *state = istate->clean_status;
	int checksum_is_bound =
		!is_null_oid(&istate->oid) ||
		(clean_status_identity_is_durable() && state &&
		 state->source_identity_valid);

	return checksum_is_bound &&
		clean_status_index_entries_are_certifiable(istate);
}

int clean_status_index_is_certifiable_with_hardlinks(
	const struct index_state *istate, uint32_t *hardlink_nr)
{
	const struct clean_status_state *state = istate->clean_status;
	uint32_t nr = 0;
	int checksum_is_bound =
		!is_null_oid(&istate->oid) ||
		(clean_status_identity_is_durable() && state &&
		 state->source_identity_valid);

	if (!hardlink_nr || !checksum_is_bound)
		return 0;
	*hardlink_nr = 0;
	for (size_t i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];

		if (S_ISGITLINK(ce->ce_mode) || ce_stage(ce) ||
		    ce_intent_to_add(ce) || ce_skip_worktree(ce) ||
		    (ce->ce_flags & CE_VALID) ||
		    (ce->ce_flags & ~(CE_UPTODATE | CE_HASHED |
				      CE_FSMONITOR_VALID |
				      CE_UPDATE_IN_BASE)))
			return 0;
		if (ce->ce_flags & CE_FSMONITOR_VALID)
			continue;
		if (!S_ISREG(ce->ce_mode) ||
		    !(ce->ce_flags & CE_UPTODATE) ||
		    nr == CLEAN_STATUS_HARDLINK_WITNESS_MAX)
			return 0;
		nr++;
	}
	if (nr && (!istate->repo->config_values_private_.trust_ctime ||
		   !istate->repo->config_values_private_.check_stat))
		return 0;
	*hardlink_nr = nr;
	return 1;
}

static int index_entry_logical_state_is_supported(
	const struct cache_entry *ce, unsigned int extra_benign_flags)
{
	return !(ce->ce_flags & ~(LOGICAL_INDEX_PERSISTENT_FLAGS |
				 LOGICAL_INDEX_BENIGN_FLAGS |
				 extra_benign_flags));
}

static int index_logical_state_is_supported(
	const struct index_state *istate, unsigned int extra_benign_flags)
{
	if (!istate->repo || !istate->repo->hash_algo || istate->split_index ||
	    istate->sparse_index != INDEX_EXPANDED ||
	    istate->cache_nr > UINT32_MAX)
		return 0;
	for (size_t i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];

		if (!index_entry_logical_state_is_supported(
			    ce, extra_benign_flags))
			return 0;
	}
	return 1;
}

int clean_status_index_can_reuse_source_logical_hash(
	const struct index_state *istate)
{
	const unsigned int acceleration_changes =
		FSMONITOR_CHANGED | UNTRACKED_CHANGED;

	/*
	 * Reading or refreshing acceleration extensions may mark only FSMN/UNTR
	 * state dirty.  Reject any cache-entry change, while the flag walk
	 * preserves every reject condition which the logical digest enforced
	 * before a physical alias could skip it.  Sparse-checkout post-processing
	 * may clear CE_SKIP_WORKTREE without setting cache_changed, so leave that
	 * mode on the digest path.
	 */
	return istate->repo && istate->repo->initialized &&
		!repo_config_values(istate->repo)->apply_sparse_checkout &&
		!(istate->cache_changed & ~acceleration_changes) &&
		index_logical_state_is_supported(istate, 0);
}

static int index_logical_digest(const struct index_state *istate,
				unsigned int extra_benign_flags,
				unsigned char *out)
{
	static const char domain[] = "git-clean-status-logical-index-v1";
	struct git_hash_ctx ctx;
	uint32_t value;
	int initialized = 0, ret = -1;

	if (!istate->repo || !istate->repo->hash_algo || istate->split_index ||
	    istate->sparse_index != INDEX_EXPANDED ||
	    istate->cache_nr > UINT32_MAX)
		return -1;
	trace2_region_enter("fsmonitor", "history_logical_digest",
			    istate->repo);
	git_hash_init(&ctx, istate->repo->hash_algo);
	initialized = 1;
	hash_length_delimited(&ctx, domain, sizeof(domain) - 1);
	put_be32(&value, istate->cache_nr);
	hash_length_delimited(&ctx, &value, sizeof(value));
	for (size_t i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];

		/*
		 * Every in-memory flag not explicitly known to be an
		 * acceleration hint may describe work which must be completed
		 * before the entry is safe to externalize.  In particular,
		 * CE_CONTENT_CHECK_REQUIRED must not disappear with the process
		 * which raised it.
		 */
		if (!index_entry_logical_state_is_supported(
			    ce, extra_benign_flags))
			goto done;
		put_be32(&value, ce->ce_mode);
		hash_length_delimited(&ctx, &value, sizeof(value));
		put_be32(&value,
			 ce->ce_flags & LOGICAL_INDEX_PERSISTENT_FLAGS);
		hash_length_delimited(&ctx, &value, sizeof(value));
		hash_length_delimited(&ctx, ce->oid.hash,
				      istate->repo->hash_algo->rawsz);
		hash_length_delimited(&ctx, ce->name, ce_namelen(ce));
	}
	git_hash_final(out, &ctx);
	initialized = 0;
	ret = 0;

done:
	if (initialized)
		git_hash_discard(&ctx);
	trace2_region_leave("fsmonitor", "history_logical_digest",
			    istate->repo);
	return ret;
}

int clean_status_index_logical_digest(const struct index_state *istate,
				      unsigned char *out)
{
	return index_logical_digest(istate, 0, out);
}

int clean_status_index_logical_digest_after_status(
	const struct index_state *istate, unsigned char *out)
{
	const unsigned int acceleration_changes =
		CE_ENTRY_CHANGED | FSMONITOR_CHANGED | UNTRACKED_CHANGED;

	/*
	 * CE_UPDATE_IN_BASE has no independent meaning for a full index; status
	 * uses it as stat-refresh bookkeeping.  Keep that exception confined
	 * to the main, expanded, acceleration-only status result.  The common
	 * digest still rejects split/sparse indexes and every other transient
	 * flag, and hashes every persistent logical field.
	 */
	if (!istate->repo ||
	    !clean_status_external_history_enabled(istate) ||
	    istate != istate->repo->index ||
	    (istate->cache_changed & ~acceleration_changes))
		return -1;
	return index_logical_digest(istate, CE_UPDATE_IN_BASE, out);
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

int clean_status_retain_source_index_fd(struct index_state *istate, int fd,
					const struct stat *st)
{
	struct clean_status_state *state = istate->clean_status;
	struct clean_status_identity identity, current_identity;
	struct stat current;

	if (!fstat_is_reliable() || fd < 0 || !state ||
	    !state->config_enforced || istate->split_index ||
	    !is_null_oid(&istate->oid) ||
	    state->source_index_fd >= 0 ||
	    clean_status_identity_from_stat(&identity, st) ||
	    fstat(fd, &current) ||
	    clean_status_identity_from_stat(&current_identity, &current) ||
	    !clean_status_identity_equal(&identity, &current_identity))
		return 0;
	state->source_index_fd = fd;
	state->source_index_identity = identity;
	state->source_index_identity_valid = 1;
	/* Ownership transfers only after every fail-closed check succeeds. */
	return 1;
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
