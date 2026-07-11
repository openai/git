#include "git-compat-util.h"
#include "clean-status.h"
#include "clean-status-internal.h"
#include "read-cache-ll.h"

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
