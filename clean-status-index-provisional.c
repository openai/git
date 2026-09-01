#include "git-compat-util.h"
#include "clean-status-index.h"
#include "lockfile.h"
#include "read-cache-ll.h"
#include "repository.h"

int clean_status_write_index_after_provisional(
	struct index_state *istate, struct lock_file *lock, unsigned flags,
	struct clean_status_index_write_receipt *receipt)
{
	/* Let receipt preparation authenticate the final null trailer. */
	if (istate->repo->settings.index_skip_hash)
		oidcpy(&istate->oid, istate->repo->hash_algo->null_oid);
	return write_locked_index_with_receipt(
		istate, lock, flags, receipt);
}
