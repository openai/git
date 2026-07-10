#include "git-compat-util.h"
#include "attr-manifest.h"
#include "clean-status-manifest.h"
#include "fsmonitor-clean-proof.h"
#include "hash-framing.h"

void clean_status_manifest_init(struct clean_status_manifest_state *state)
{
	memset(state, 0, sizeof(*state));
	strbuf_init(&state->disk, 0);
	strbuf_init(&state->current, 0);
}

void clean_status_manifest_release(struct clean_status_manifest_state *state)
{
	strbuf_release(&state->disk);
	strbuf_release(&state->current);
}

int clean_status_manifest_load(struct clean_status_manifest_state *state,
			       const void *data, size_t len, uint32_t flags,
			       const struct git_hash_algo *algo)
{
	state->disk_valid = 0;
	state->disk_flags = 0;
	strbuf_reset(&state->disk);
	if (flags & ~FSMONITOR_CLEAN_PROOF_ALL ||
	    !attr_manifest_valid(data, len, algo))
		return -1;
	strbuf_add(&state->disk, data, len);
	hash_buffer_digest(algo, data, len, state->disk_hash);
	state->disk_flags = flags;
	state->disk_valid = 1;
	return 0;
}

void clean_status_manifest_adopt_disk(
	struct clean_status_manifest_state *state)
{
	if (!state->disk_valid)
		BUG("cannot adopt an invalid clean-status manifest");
	strbuf_reset(&state->current);
	strbuf_addbuf(&state->current, &state->disk);
	memcpy(state->current_hash, state->disk_hash,
	       sizeof(state->current_hash));
	state->current_flags = state->disk_flags;
	state->current_valid = 1;
	state->checked = 1;
}

void clean_status_manifest_invalidate(
	struct clean_status_manifest_state *state)
{
	state->current_valid = 0;
	state->current_flags = 0;
}
