#define USE_THE_REPOSITORY_VARIABLE
#define DISABLE_SIGN_COMPARE_WARNINGS

#include "git-compat-util.h"
#include "abspath.h"
#include "attr.h"
#include "clean-status.h"
#include "clean-status-manifest.h"
#include "config.h"
#include "dir.h"
#include "environment.h"
#include "ewah/ewok.h"
#include "ewah/ewok_rlw.h"
#include "fsmonitor.h"
#include "fsmonitor-ipc.h"
#include "hashmap.h"
#include "hex-ll.h"
#include "name-hash.h"
#include "repository.h"
#include "run-command.h"
#include "strbuf.h"
#include "trace2.h"
#include "wrapper.h"

#define INDEX_EXTENSION_VERSION1	(1)
#define INDEX_EXTENSION_VERSION2	(2)
#define FSMONITOR_TOKEN_MAX		(4096)
#define HOOK_INTERFACE_VERSION1		(1)
#define HOOK_INTERFACE_VERSION2		(2)

struct trace_key trace_fsmonitor = TRACE_KEY_INIT(FSMONITOR);

static void assert_index_minimum(struct index_state *istate, size_t pos)
{
	if (pos > istate->cache_nr)
		BUG("fsmonitor_dirty has more entries than the index (%"PRIuMAX" > %u)",
		    (uintmax_t)pos, istate->cache_nr);
}

static void fsmonitor_ewah_callback(size_t pos, void *is)
{
	struct index_state *istate = (struct index_state *)is;
	struct cache_entry *ce;

	assert_index_minimum(istate, pos + 1);

	ce = istate->cache[pos];
	ce->ce_flags &= ~CE_FSMONITOR_VALID;
}

static int fsmonitor_ewah_is_valid(struct ewah_bitmap *bitmap)
{
	size_t pointer = 0, expanded_words = 0;
	size_t logical_words = bitmap->bit_size / BITS_IN_EWORD +
		!!(bitmap->bit_size % BITS_IN_EWORD);
	size_t padding = bitmap->bit_size % BITS_IN_EWORD;
	eword_t *last_rlw = NULL;

	while (pointer < bitmap->buffer_size) {
		eword_t *rlw = &bitmap->buffer[pointer];
		size_t running_words = rlw_get_running_len(rlw);
		size_t literal_words = rlw_get_literal_words(rlw);
		size_t i;

		last_rlw = rlw;
		if (literal_words > bitmap->buffer_size - pointer - 1)
			return 0;
		if (running_words > logical_words - expanded_words)
			return 0;
		expanded_words += running_words;
		if (rlw_get_run_bit(rlw) && running_words && padding &&
		    expanded_words == logical_words)
			return 0;
		if (literal_words > logical_words - expanded_words)
			return 0;
		for (i = 0; i < literal_words; i++) {
			eword_t literal = bitmap->buffer[pointer + 1 + i];

			if (padding &&
			    expanded_words + i + 1 == logical_words &&
			    literal >> padding)
				return 0;
		}
		expanded_words += literal_words;
		pointer += 1 + literal_words;
	}

	return expanded_words == logical_words && bitmap->rlw == last_rlw;
}

static int fsmonitor_hook_version(void)
{
	int hook_version;

	if (repo_config_get_int(the_repository, "core.fsmonitorhookversion", &hook_version))
		return -1;

	if (hook_version == HOOK_INTERFACE_VERSION1 ||
	    hook_version == HOOK_INTERFACE_VERSION2)
		return hook_version;

	warning("Invalid hook version '%i' in core.fsmonitorhookversion. "
		"Must be 1 or 2.", hook_version);
	return -1;
}

int read_fsmonitor_extension(struct index_state *istate, const void *data,
	unsigned long sz)
{
	const char *index = data;
	const char *end = index + sz;
	const char *nul;
	uint32_t hdr_version;
	uint32_t ewah_size;
	uint32_t ewah_words;
	uint32_t ewah_rlw;
	struct ewah_bitmap *fsmonitor_dirty;
	int ret;
	uint64_t timestamp;
	struct strbuf last_update = STRBUF_INIT;

	if (istate->fsmonitor_extension_seen)
		goto invalid;
	istate->fsmonitor_extension_seen = 1;
	if (end - index < sizeof(uint32_t))
		goto invalid;

	hdr_version = get_be32(index);
	index += sizeof(uint32_t);
	if (hdr_version == INDEX_EXTENSION_VERSION1) {
		if (end - index < sizeof(uint64_t))
			goto invalid;
		timestamp = get_be64(index);
		strbuf_addf(&last_update, "%"PRIu64"", timestamp);
		index += sizeof(uint64_t);
	} else if (hdr_version == INDEX_EXTENSION_VERSION2) {
		nul = memchr(index, '\0', end - index);
		if (!nul || nul == index || nul - index > FSMONITOR_TOKEN_MAX)
			goto invalid;
		strbuf_add(&last_update, index, nul - index);
		index = nul + 1;
	} else {
		goto invalid;
	}

	if (end - index < sizeof(uint32_t))
		goto invalid;
	ewah_size = get_be32(index);
	index += sizeof(uint32_t);
	if (ewah_size != end - index || ewah_size < 3 * sizeof(uint32_t))
		goto invalid;

	/* Reject impossible EWAH lengths before its parser allocates memory. */
	ewah_words = get_be32(index + sizeof(uint32_t));
	if (ewah_words > (ewah_size - 3 * sizeof(uint32_t)) /
			 sizeof(eword_t) ||
	    3 * sizeof(uint32_t) + (size_t)ewah_words * sizeof(eword_t) !=
		    ewah_size)
		goto invalid;
	ewah_rlw = get_be32(index + ewah_size - sizeof(uint32_t));
	if (ewah_rlw >= ewah_words)
		goto invalid;

	fsmonitor_dirty = ewah_new();
	ret = ewah_read_mmap(fsmonitor_dirty, index, ewah_size);
	if (ret != ewah_size) {
		ewah_free(fsmonitor_dirty);
		goto invalid;
	}
	if (!fsmonitor_ewah_is_valid(fsmonitor_dirty)) {
		ewah_free(fsmonitor_dirty);
		goto invalid;
	}
	if (!istate->split_index &&
	    fsmonitor_dirty->bit_size > istate->cache_nr) {
		ewah_free(fsmonitor_dirty);
		goto invalid;
	}

	/* Publish only after the complete optional extension is validated. */
	FREE_AND_NULL(istate->fsmonitor_last_update);
	if (istate->fsmonitor_dirty)
		ewah_free(istate->fsmonitor_dirty);
	istate->fsmonitor_last_update = strbuf_detach(&last_update, NULL);
	istate->fsmonitor_dirty = fsmonitor_dirty;
	istate->fsmonitor_token_valid = 1;

	trace2_data_string("index", NULL, "extension/fsmn/read/token",
			   istate->fsmonitor_last_update);
	trace_printf_key(&trace_fsmonitor,
			 "read fsmonitor extension successful '%s'",
			 istate->fsmonitor_last_update);
	return 0;

invalid:
	istate->fsmonitor_extension_seen = 1;
	istate->fsmonitor_token_valid = 0;
	istate->fsmonitor_untracked_valid = 0;
	FREE_AND_NULL(istate->fsmonitor_last_update);
	if (istate->fsmonitor_dirty) {
		ewah_free(istate->fsmonitor_dirty);
		istate->fsmonitor_dirty = NULL;
	}
	strbuf_release(&last_update);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "extension/invalid", 1);
	return 0;
}

#define FSMONITOR_UNTRACKED_EXTENSION_VERSION 1

int read_fsmonitor_untracked_extension(struct index_state *istate,
				       const void *data, unsigned long sz)
{
	const char *p = data;
	const char *nul;
	uint32_t version;

	if (istate->fsmonitor_untracked_extension_seen)
		goto invalid;
	istate->fsmonitor_untracked_extension_seen = 1;
	if (sz < sizeof(version) + 2)
		goto invalid;
	version = get_be32(p);
	p += sizeof(version);
	sz -= sizeof(version);
	if (version != FSMONITOR_UNTRACKED_EXTENSION_VERSION)
		goto invalid;
	nul = memchr(p, '\0', sz);
	if (!nul || nul == p || (size_t)(nul - p + 1) != sz ||
	    nul - p > FSMONITOR_TOKEN_MAX)
		goto invalid;

	FREE_AND_NULL(istate->fsmonitor_untracked_token);
	istate->fsmonitor_untracked_token = xstrdup(p);
	return 0;

invalid:
	istate->fsmonitor_untracked_extension_seen = 1;
	istate->fsmonitor_untracked_extension_invalid = 1;
	istate->fsmonitor_untracked_valid = 0;
	FREE_AND_NULL(istate->fsmonitor_untracked_token);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "untracked/invalid-extension", 1);
	return 0;
}

void write_fsmonitor_untracked_extension(struct strbuf *sb,
					 struct index_state *istate)
{
	const char *suffix;
	uint32_t version;

	put_be32(&version, FSMONITOR_UNTRACKED_EXTENSION_VERSION);
	strbuf_add(sb, &version, sizeof(version));
	if (!istate->fsmonitor_untracked_valid && istate->untracked &&
	    istate->untracked->fsmonitor_revalidation) {
		if (!skip_prefix(istate->fsmonitor_last_update,
				 "builtin:", &suffix) ||
		    !*suffix || !strcmp(suffix, "fake"))
			BUG("cannot serialize unauthenticated fsmonitor cache");
		strbuf_addstr(sb, "pending:");
		strbuf_addstr(sb, suffix);
		trace2_data_intmax("fsmonitor", istate->repo,
				   "untracked/provider-reset-pending", 1);
	} else {
		strbuf_addstr(sb, istate->fsmonitor_last_update);
	}
	strbuf_addch(sb, '\0');
}

void prepare_fsmonitor_untracked(struct index_state *istate)
{
	istate->fsmonitor_untracked_valid =
		!istate->fsmonitor_untracked_extension_invalid &&
		(!istate->untracked || !istate->untracked->root ||
		 (istate->fsmonitor_token_valid &&
		  istate->fsmonitor_last_update &&
		  istate->fsmonitor_untracked_token &&
		  !strcmp(istate->fsmonitor_last_update,
			  istate->fsmonitor_untracked_token)));
	if (istate->fsmonitor_untracked_valid)
		untracked_cache_recompute_fsmonitor_valid_recursive(
			istate->untracked);
	else if (istate->fsmonitor_untracked_token &&
		 starts_with(istate->fsmonitor_untracked_token, "pending:"))
		untracked_cache_preserve_for_revalidation(istate);
}

static struct ewah_bitmap *fsmonitor_bitmap_from_index(
	struct index_state *istate)
{
	struct ewah_bitmap *bitmap = ewah_new();
	unsigned int i, skipped = 0;

	for (i = 0; i < istate->cache_nr; i++) {
		if (istate->cache[i]->ce_flags & CE_REMOVE)
			skipped++;
		else if (!(istate->cache[i]->ce_flags & CE_FSMONITOR_VALID))
			ewah_set(bitmap, i - skipped);
	}
	return bitmap;
}

void fill_fsmonitor_bitmap(struct index_state *istate)
{
	istate->fsmonitor_dirty = fsmonitor_bitmap_from_index(istate);
}

static void serialize_fsmonitor_extension(struct strbuf *sb,
					  struct index_state *istate,
					  struct ewah_bitmap *bitmap)
{
	uint32_t hdr_version;
	uint32_t ewah_start;
	uint32_t ewah_size = 0;
	int fixup = 0;

	if (!istate->split_index)
		assert_index_minimum(istate, bitmap->bit_size);

	put_be32(&hdr_version, INDEX_EXTENSION_VERSION2);
	strbuf_add(sb, &hdr_version, sizeof(uint32_t));

	strbuf_addstr(sb, istate->fsmonitor_last_update);
	strbuf_addch(sb, 0); /* Want to keep a NUL */

	fixup = sb->len;
	strbuf_add(sb, &ewah_size, sizeof(uint32_t)); /* we'll fix this up later */

	ewah_start = sb->len;
	ewah_serialize_strbuf(bitmap, sb);

	/* fix up size field */
	put_be32(&ewah_size, sb->len - ewah_start);
	memcpy(sb->buf + fixup, &ewah_size, sizeof(uint32_t));
}

void snapshot_fsmonitor_extension(struct strbuf *sb,
				  struct index_state *istate)
{
	struct ewah_bitmap *bitmap = fsmonitor_bitmap_from_index(istate);

	serialize_fsmonitor_extension(sb, istate, bitmap);
	ewah_free(bitmap);
}

void write_fsmonitor_extension(struct strbuf *sb, struct index_state *istate)
{
	serialize_fsmonitor_extension(sb, istate, istate->fsmonitor_dirty);
	ewah_free(istate->fsmonitor_dirty);
	istate->fsmonitor_dirty = NULL;

	trace2_data_string("index", NULL, "extension/fsmn/write/token",
			   istate->fsmonitor_last_update);
	trace_printf_key(&trace_fsmonitor,
			 "write fsmonitor extension successful '%s'",
			 istate->fsmonitor_last_update);
}

/*
 * Call the query-fsmonitor hook passing the last update token of the saved results.
 */
static int query_fsmonitor_hook(struct repository *r,
				int version,
				const char *last_update,
				struct strbuf *query_result)
{
	struct child_process cp = CHILD_PROCESS_INIT;
	int result;

	if (fsm_settings__get_mode(r) != FSMONITOR_MODE_HOOK)
		return -1;

	strvec_push(&cp.args, fsm_settings__get_hook_path(r));
	strvec_pushf(&cp.args, "%d", version);
	strvec_pushf(&cp.args, "%s", last_update);
	cp.use_shell = 1;
	cp.dir = repo_get_work_tree(the_repository);

	trace2_region_enter("fsm_hook", "query", NULL);

	result = capture_command(&cp, query_result, 1024);

	if (result)
		trace2_data_intmax("fsm_hook", NULL, "query/failed", result);
	else
		trace2_data_intmax("fsm_hook", NULL, "query/response-length",
				   query_result->len);

	trace2_region_leave("fsm_hook", "query", NULL);

	return result;
}

/*
 * Strongly invalidate one cache entry without touching attributes or the
 * untracked cache. Callers choose those wider invalidation scopes explicitly.
 */
void fsmonitor_invalidate_cache_entry(struct cache_entry *ce)
{
	ce->ce_flags &= ~CE_UPTODATE;
	memset(&ce->ce_stat_data, 0, sizeof(ce->ce_stat_data));
	ce->ce_flags |= CE_CONTENT_CHECK_REQUIRED;
	if (ce->ce_flags & CE_FSMONITOR_VALID) {
		trace_printf_key(&trace_fsmonitor,
				 "fsmonitor_refresh_callback INV: '%s'",
				 ce->name);
		ce->ce_flags &= ~CE_FSMONITOR_VALID;
	}
}

static size_t handle_path_with_trailing_slash(
	struct index_state *istate, const char *name, int pos,
	int directory_is_semantically_safe);

int fsmonitor_invalidate_attributes_path(struct index_state *istate,
					 const char *name)
{
	size_t len = strlen(name), base, attr_len = strlen(GITATTRIBUTES_FILE);
	size_t invalidated = 0;
	unsigned int i;

	while (len && is_dir_sep(name[len - 1]))
		len--;
	base = len;
	while (base && !is_dir_sep(name[base - 1]))
		base--;
	if (len - base != attr_len ||
	    fspathncmp(name + base, GITATTRIBUTES_FILE, attr_len))
		return 0;

	git_attr_invalidate_all();
	for (i = 0; i < istate->cache_nr; i++) {
		struct cache_entry *ce = istate->cache[i];

		if (base && (ce->ce_namelen < base ||
			     fspathncmp(ce->name, name, base)))
			continue;
		fsmonitor_invalidate_cache_entry(ce);
		invalidated++;
	}
	if (invalidated)
		istate->cache_changed |= FSMONITOR_CHANGED;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/attributes-scope", base);
	return invalidated > 0;
}

/*
 * Use the name-hash to do a case-insensitive cache-entry lookup with
 * the pathname and invalidate the cache-entry.
 *
 * Returns the number of cache-entries that we invalidated.
 */
static size_t handle_using_name_hash_icase(
	struct index_state *istate, const char *name)
{
	struct cache_entry *ce = NULL;

	ce = index_file_exists(istate, name, strlen(name), 1);
	if (!ce)
		return 0;

	/*
	 * A case-insensitive search in the name-hash using the
	 * observed pathname found a cache-entry, so the observed path
	 * is case-incorrect.  Invalidate the cache-entry and use the
	 * correct spelling from the cache-entry to invalidate the
	 * untracked-cache.  Since we now have sparse-directories in
	 * the index, the observed pathname may represent a regular
	 * file or a sparse-index directory.
	 *
	 * Note that we should not have seen FSEvents for a
	 * sparse-index directory, but we handle it just in case.
	 *
	 * Either way, we know that there are not any cache-entries for
	 * children inside the cone of the directory, so we don't need to
	 * do the usual scan.
	 */
	trace_printf_key(&trace_fsmonitor,
			 "fsmonitor_refresh_callback MAP: '%s' '%s'",
			 name, ce->name);

	/*
	 * NEEDSWORK: We used the name-hash to find the correct
	 * case-spelling of the pathname in the cache-entry[], so
	 * technically this is a tracked file or a sparse-directory.
	 * It should not have any entries in the untracked-cache, so
	 * we should not need to use the case-corrected spelling to
	 * invalidate the untracked-cache.  So we may not need to
	 * do this.  For now, I'm going to be conservative and always
	 * do it; we can revisit this later.
	 */
	untracked_cache_invalidate_trimmed_path(istate, ce->name, 0);

	fsmonitor_invalidate_cache_entry(ce);
	return 1;
}

/*
 * Use the dir-name-hash to find the correct-case spelling of the
 * directory.  Use the canonical spelling to invalidate all of the
 * cache-entries within the matching cone.
 *
 * Returns the number of cache-entries that we invalidated.
 */
static size_t handle_using_dir_name_hash_icase(
	struct index_state *istate, const char *name)
{
	struct strbuf canonical_path = STRBUF_INIT;
	int pos;
	size_t len = strlen(name);
	size_t nr_in_cone;

	if (name[len - 1] == '/')
		len--;

	if (!index_dir_find(istate, name, len, &canonical_path))
		return 0; /* name is untracked */

	if (!memcmp(name, canonical_path.buf, canonical_path.len)) {
		strbuf_release(&canonical_path);
		/*
		 * NEEDSWORK: Our caller already tried an exact match
		 * and failed to find one.  They called us to do an
		 * ICASE match, so we should never get an exact match,
		 * so we could promote this to a BUG() here if we
		 * wanted to.  It doesn't hurt anything to just return
		 * 0 and go on because we should never get here.  Or we
		 * could just get rid of the memcmp() and this "if"
		 * clause completely.
		 */
		BUG("handle_using_dir_name_hash_icase(%s) did not exact match",
		    name);
	}

	trace_printf_key(&trace_fsmonitor,
			 "fsmonitor_refresh_callback MAP: '%s' '%s'",
			 name, canonical_path.buf);

	/*
	 * The dir-name-hash only tells us the corrected spelling of
	 * the prefix.  We have to use this canonical path to do a
	 * lookup in the cache-entry array so that we repeat the
	 * original search using the case-corrected spelling.
	 */
	strbuf_addch(&canonical_path, '/');
	pos = index_name_pos(istate, canonical_path.buf,
			     canonical_path.len);
	nr_in_cone = handle_path_with_trailing_slash(
		istate, canonical_path.buf, pos,
		clean_status_directory_event_is_semantically_safe(
			istate, canonical_path.buf));
	strbuf_release(&canonical_path);
	return nr_in_cone;
}

/*
 * The daemon sent an observed pathname without a trailing slash.
 * (This is the normal case.)  We do not know if it is a tracked or
 * untracked file, a sparse-directory, or a populated directory (on a
 * platform such as Windows where FSEvents are not qualified).
 *
 * The pathname contains the observed case reported by the FS. We
 * do not know it is case-correct or -incorrect.
 *
 * Assume it is case-correct and try an exact match.
 *
 * Return the number of cache-entries that we invalidated.
 */
static size_t handle_path_without_trailing_slash(
	struct index_state *istate, const char *name, int pos)
{
	/*
	 * Mark the untracked cache dirty for this path (regardless of
	 * whether or not we find an exact match for it in the index).
	 * Since the path is unqualified (no trailing slash hint in the
	 * FSEvent), it may refer to a file or directory. So we should
	 * not assume one or the other and should always let the untracked
	 * cache decide what needs to invalidated.
	 */
	untracked_cache_invalidate_trimmed_path(istate, name, 0);

	if (pos >= 0) {
		/*
		 * An exact match on a tracked file. We assume that we
		 * do not need to scan forward for a sparse-directory
		 * cache-entry with the same pathname, nor for a cone
		 * at that directory. (That is, assume no D/F conflicts.)
		 */
		fsmonitor_invalidate_cache_entry(istate->cache[pos]);
		return 1;
	} else {
		size_t nr_in_cone;
		struct strbuf work_path = STRBUF_INIT;

		/*
		 * The negative "pos" gives us the suggested insertion
		 * point for the pathname (without the trailing slash).
		 * We need to see if there is a directory with that
		 * prefix, but there can be lots of pathnames between
		 * "foo" and "foo/" like "foo-" or "foo-bar", so we
		 * don't want to do our own scan.
		 */
		strbuf_add(&work_path, name, strlen(name));
		strbuf_addch(&work_path, '/');
		pos = index_name_pos(istate, work_path.buf, work_path.len);
		nr_in_cone = handle_path_with_trailing_slash(
			istate, work_path.buf, pos,
			clean_status_directory_event_is_semantically_safe(
				istate, work_path.buf));
		strbuf_release(&work_path);
		return nr_in_cone;
	}
}

/*
 * The daemon can decorate directory events, such as a move or rename,
 * by adding a trailing slash to the observed name.  Use this to
 * explicitly invalidate the entire cone under that directory.
 *
 * The daemon can only reliably do that if the OS FSEvent contains
 * sufficient information in the event.
 *
 * macOS FSEvents have enough information.
 *
 * Other platforms may or may not be able to do it (and it might
 * depend on the type of event (for example, a daemon could lstat() an
 * observed pathname after a rename, but not after a delete)).
 *
 * If we find an exact match in the index for a path with a trailing
 * slash, it means that we matched a sparse-index directory in a
 * cone-mode sparse-checkout (since that's the only time we have
 * directories in the index).  We should never see this in practice
 * (because sparse directories should not be present and therefore
 * not generating FS events).  Either way, we can treat them in the
 * same way and just invalidate the cache-entry and the untracked
 * cache (and in this case, the forward cache-entry scan won't find
 * anything and it doesn't hurt to let it run).
 *
 * Return the number of cache-entries that we invalidated.  We will
 * use this later to determine if we need to attempt a second
 * case-insensitive search on case-insensitive file systems.  That is,
 * if the search using the observed-case in the FSEvent yields any
 * results, we assume the prefix is case-correct.  If there are no
 * matches, we still don't know if the observed path is simply
 * untracked or case-incorrect.
 */
static size_t handle_path_with_trailing_slash(
	struct index_state *istate, const char *name, int pos,
	int directory_is_semantically_safe)
{
	int i;
	size_t nr_in_cone = 0;

	/*
	 * Mark the untracked cache dirty for this directory path
	 * (regardless of whether or not we find an exact match for it
	 * in the index or find it to be proper prefix of one or more
	 * files in the index), since the FSEvent is hinting that
	 * there may be changes on or within the directory.
	 */
	untracked_cache_invalidate_trimmed_path(istate, name, 0);

	if (pos < 0)
		pos = -pos - 1;

	/* Mark all entries for the folder invalid */
	for (i = pos; i < istate->cache_nr; i++) {
		if (!starts_with(istate->cache[i]->name, name))
			break;
		fsmonitor_invalidate_cache_entry(istate->cache[i]);
		nr_in_cone++;
	}

	if (nr_in_cone && !directory_is_semantically_safe) {
		/*
		 * A matched directory event may stand in for a nested
		 * attribute-file change.
		 */
		git_attr_invalidate_all();
		trace2_data_intmax("fsmonitor", istate->repo,
				   "semantic/attributes-cone", nr_in_cone);
	}

	return nr_in_cone;
}

static void fsmonitor_refresh_callback(struct index_state *istate, char *name,
				       int closing_delta)
{
	int len = strlen(name);
	int pos;
	int attributes_may_have_changed;
	int directory_is_semantically_safe;
	size_t nr_in_cone;

	trace_printf_key(&trace_fsmonitor,
			 "fsmonitor_refresh_callback '%s' (pos %d)",
			 name, !strcmp(name, FSMONITOR_PATH_GLOBAL_INVALIDATE) ?
			 -1 : index_name_pos(istate, name, len));
	if (!strcmp(name, FSMONITOR_PATH_GLOBAL_INVALIDATE)) {
		unsigned int i;

		clean_status_invalidate_current_manifest(istate);
		git_attr_invalidate_all();
		untracked_cache_invalidate_all(istate);
		for (i = 0; i < istate->cache_nr; i++)
			fsmonitor_invalidate_cache_entry(istate->cache[i]);
		istate->cache_changed |= FSMONITOR_CHANGED;
		trace2_data_intmax("fsmonitor", istate->repo,
				   "apply/global-invalidation", 1);
		return;
	}
	pos = index_name_pos(istate, name, len);
	if (pos >= 0 &&
	    clean_status_manifest_reconcile_deleted_attribute(istate, name)) {
		attributes_may_have_changed = 0;
		trace2_data_intmax("fsmonitor", istate->repo,
				   "semantic/attribute-source-reused", 1);
	} else if (pos >= 0 &&
		   clean_status_manifest_accept_current_display_only_attribute(
			   istate, name)) {
		git_attr_invalidate_all();
		attributes_may_have_changed = 0;
		trace2_data_intmax("fsmonitor", istate->repo,
				   "semantic/nonconversion-attribute-replayed", 1);
	} else {
		attributes_may_have_changed =
			fsmonitor_invalidate_attributes_path(istate, name);
	}
	directory_is_semantically_safe = name[len - 1] == '/' &&
		(clean_status_directory_event_is_semantically_safe(istate, name) ||
		 (closing_delta &&
		  clean_status_manifest_directory_unchanged(istate, name)));

	if (name[len - 1] == '/')
		nr_in_cone = handle_path_with_trailing_slash(
			istate, name, pos, directory_is_semantically_safe);
	else
		nr_in_cone = handle_path_without_trailing_slash(istate, name, pos);
	if (pos < 0 && nr_in_cone && !directory_is_semantically_safe)
		attributes_may_have_changed = 1;

	/*
	 * If we did not find an exact match for this pathname or any
	 * cache-entries with this directory prefix and we're on a
	 * case-insensitive file system, try again using the name-hash
	 * and dir-name-hash.
	 */
	if (!nr_in_cone && repo_ignore_case(the_repository)) {
		nr_in_cone = handle_using_name_hash_icase(istate, name);
		if (!nr_in_cone) {
			nr_in_cone = handle_using_dir_name_hash_icase(
				istate, name);
			if (nr_in_cone)
				attributes_may_have_changed = 1;
		}
	}
	if (attributes_may_have_changed)
		clean_status_invalidate_current_manifest(istate);

	if (nr_in_cone)
		trace_printf_key(&trace_fsmonitor,
				 "fsmonitor_refresh_callback CNT: %d",
				 (int)nr_in_cone);
}

/*
 * The number of pathnames that we need to receive from FSMonitor
 * before we force the index to be updated.
 *
 * Note that any pathname within the set of received paths MAY cause
 * cache-entry or istate flag bits to be updated and thus cause the
 * index to be updated on disk.
 *
 * However, the response may contain many paths (such as ignored
 * paths) that will not update any flag bits.  And thus not force the
 * index to be updated.  (This is fine and normal.)  It also means
 * that the token will not be updated in the FSMonitor index
 * extension.  So the next Git command will find the same token in the
 * index, make the same token-relative request, and receive the same
 * response (plus any newly changed paths).  If this response is large
 * (and continues to grow), performance could be impacted.
 *
 * For example, if the user runs a build and it writes 100K object
 * files but doesn't modify any source files, the index would not need
 * to be updated.  The FSMonitor response (after the build and
 * relative to a pre-build token) might be 5MB.  Each subsequent Git
 * command will receive that same 100K/5MB response until something
 * causes the index to be updated.  And `refresh_fsmonitor()` will
 * have to iterate over those 100K paths each time.
 *
 * Performance could be improved if we optionally force update the
 * index after a very large response and get an updated token into
 * the FSMonitor index extension.  This should allow subsequent
 * commands to get smaller and more current responses.
 *
 * The value chosen here does not need to be precise.  The index
 * will be updated automatically the first time the user touches
 * a tracked file and causes a command like `git status` to
 * update an mtime to be updated and/or set a flag bit.
 */
static int fsmonitor_force_update_threshold = 100;

static int is_trivial_response_at(const struct strbuf *result, size_t offset)
{
	size_t i;

	if (offset >= result->len || result->buf[offset] != '/')
		return 0;
	for (i = offset + 1; i < result->len; i++)
		if (result->buf[i] != '\0' && result->buf[i] != '\n' &&
		    result->buf[i] != '\r')
			return 0;
	return 1;
}

void fsmonitor_query_result_release(struct fsmonitor_query_result *result)
{
	strbuf_release(&result->token);
	strbuf_release(&result->paths);
}

static int fsmonitor_valid_worktree_path(const char *path, size_t len)
{
	struct strbuf copy = STRBUF_INIT;
	int valid = 0;

	if (!len || is_dir_sep(path[0]) || has_dos_drive_prefix(path))
		return 0;
	strbuf_add(&copy, path, len);
	if (is_dir_sep(copy.buf[copy.len - 1]))
		strbuf_setlen(&copy, copy.len - 1);
	if (!copy.len || is_dir_sep(copy.buf[copy.len - 1]))
		goto done;
	valid = verify_path(copy.buf, 0);

done:
	strbuf_release(&copy);
	return valid;
}

static int fsmonitor_parse_hardlink_inode(const char *path, size_t len,
					  uint32_t *inode)
{
	const char *hex;
	uint64_t value = 0;
	size_t i;

	if (!skip_prefix(path, FSMONITOR_PATH_HARDLINK_INODE_PREFIX, &hex))
		return 0;
	if (len != strlen(FSMONITOR_PATH_HARDLINK_INODE_PREFIX) +
		    FSMONITOR_PATH_HARDLINK_INODE_HEX)
		return -1;
	for (i = 0; i < FSMONITOR_PATH_HARDLINK_INODE_HEX; i++) {
		unsigned int digit = hexval(hex[i]);

		if (digit > 0xf)
			return -1;
		value = (value << 4) | digit;
	}
	if (!value)
		return -1;
	if (inode)
		*inode = (uint32_t)value;
	return 1;
}

enum fsmonitor_query_outcome fsmonitor_parse_builtin_response(
	const struct strbuf *raw, struct fsmonitor_query_result *result)
{
	const char *nul, *p, *end;

	if (!raw->len)
		goto malformed;
	nul = memchr(raw->buf, '\0', raw->len);
	if (!nul || nul == raw->buf || nul - raw->buf > FSMONITOR_TOKEN_MAX)
		goto malformed;
	strbuf_add(&result->token, raw->buf, nul - raw->buf);
	if (!starts_with(result->token.buf, "builtin:"))
		goto malformed;

	p = nul + 1;
	end = raw->buf + raw->len;
	if (p == end) {
		result->outcome = FSMONITOR_QUERY_DELTA;
		return result->outcome;
	}
	if (end[-1] != '\0')
		goto malformed;
	if (end - p == 2 && p[0] == '/' && p[1] == '\0') {
		result->outcome = FSMONITOR_QUERY_TRIVIAL;
		return result->outcome;
	}

	while (p < end) {
		nul = memchr(p, '\0', end - p);
		if (!nul || nul == p)
			goto malformed;
		if (strcmp(p, FSMONITOR_PATH_GLOBAL_INVALIDATE) &&
		    fsmonitor_parse_hardlink_inode(p, nul - p, NULL) <= 0 &&
		    !fsmonitor_valid_worktree_path(p, nul - p))
			goto malformed;
		p = nul + 1;
	}
	strbuf_add(&result->paths, raw->buf + result->token.len + 1,
		   end - (raw->buf + result->token.len + 1));
	result->outcome = FSMONITOR_QUERY_DELTA;
	return result->outcome;

malformed:
	strbuf_reset(&result->token);
	strbuf_reset(&result->paths);
	trace2_data_intmax("fsm_client", NULL, "query/invalid-response", 1);
	return FSMONITOR_QUERY_ERROR;
}

static int fsmonitor_test_query_barrier(size_t query_nr)
{
	const char *at = getenv("GIT_TEST_FSMONITOR_QUERY_BARRIER_AT");
	const char *ready = getenv("GIT_TEST_FSMONITOR_QUERY_BARRIER_READY");
	const char *resume = getenv("GIT_TEST_FSMONITOR_QUERY_BARRIER_RESUME");
	struct stat st;
	uintmax_t selected;
	char *end;
	char resumed;
	int fd, ret;

	if (!at && !ready && !resume)
		return 0;
	if (!at || !ready || !resume || !*at || !*ready || !*resume ||
	    !isdigit((unsigned char)*at))
		return -1;
	errno = 0;
	selected = strtoumax(at, &end, 10);
	if (errno || *end || !selected)
		return -1;
	if (selected != (uintmax_t)query_nr)
		return 0;
	if (lstat(resume, &st) || !S_ISFIFO(st.st_mode))
		return -1;
	fd = open(ready, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	if (fd < 0)
		return -1;
	ret = write_in_full(fd, "ready\n", 6) == 6 ? 0 : -1;
	if (close(fd) || ret)
		return -1;
	fd = open(resume, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	ret = read_in_full(fd, &resumed, 1) == 1 ? 0 : -1;
	if (close(fd))
		ret = -1;
	return ret;
}

enum fsmonitor_query_outcome query_builtin_fsmonitor(
	const char *since_token, struct fsmonitor_query_result *result)
{
	const char *test_sequence =
		getenv("GIT_TEST_FSMONITOR_QUERY_SEQUENCE");
	struct strbuf raw = STRBUF_INIT;
	int legacy_authenticated = 0;

	/*
	 * Tests may script clean, delta, trivial, and error responses with
	 * C, D, T, and E. A delta uses GIT_TEST_FSMONITOR_QUERY_PATH.
	 */
	if (test_sequence && *test_sequence) {
		static size_t query_nr;
		const char *path;
		char outcome;

		if (query_nr >= strlen(test_sequence))
			return FSMONITOR_QUERY_ERROR;
		outcome = test_sequence[query_nr++];
		if (fsmonitor_test_query_barrier(query_nr))
			return FSMONITOR_QUERY_ERROR;
		if (outcome == 'E')
			return FSMONITOR_QUERY_ERROR;

		strbuf_addf(&result->token, "builtin:test:%"PRIuMAX,
			    (uintmax_t)query_nr);
		if (outcome == 'T') {
			result->outcome = FSMONITOR_QUERY_TRIVIAL;
			return result->outcome;
		}
		if (outcome == 'D') {
			path = getenv("GIT_TEST_FSMONITOR_QUERY_PATH");
			if (!path || !*path)
				return FSMONITOR_QUERY_ERROR;
			strbuf_addstr(&result->paths, path);
			strbuf_addch(&result->paths, '\0');
		} else if (outcome != 'C') {
			return FSMONITOR_QUERY_ERROR;
		}
		result->outcome = FSMONITOR_QUERY_DELTA;
		return result->outcome;
	}

	if (!fsmonitor_ipc__send_query(
		    since_token, &raw, &legacy_authenticated)) {
		fsmonitor_parse_builtin_response(&raw, result);
		result->legacy_worktree_authenticated =
			legacy_authenticated;
	}
	strbuf_release(&raw);
	return result->outcome;
}

struct fsmonitor_hardlink_inode {
	struct hashmap_entry ent;
	uint32_t inode;
};

static int fsmonitor_hardlink_inode_cmp(const void *unused UNUSED,
					 const struct hashmap_entry *eptr,
					 const struct hashmap_entry *entry_or_key,
					 const void *keydata)
{
	const struct fsmonitor_hardlink_inode *entry =
		container_of(eptr, const struct fsmonitor_hardlink_inode, ent);
	const uint32_t *inode = keydata;

	if (inode)
		return entry->inode != *inode;
	return entry->inode !=
		container_of(entry_or_key,
			     const struct fsmonitor_hardlink_inode, ent)->inode;
}

static int apply_fsmonitor_paths(struct index_state *istate,
				 const struct strbuf *paths, int closing_delta)
{
	const char *p = paths->buf;
	const char *end = paths->buf + paths->len;
	struct hashmap inodes = HASHMAP_INIT(fsmonitor_hardlink_inode_cmp, NULL);
	struct fsmonitor_hardlink_inode *entry;
	unsigned int matches = 0;
	int count = 0;

	if (closing_delta) {
		for (const char *changed = p; changed < end;
		     changed += strlen(changed) + 1) {
			size_t changed_len = strlen(changed);

			if (!strcmp(changed, FSMONITOR_PATH_GLOBAL_INVALIDATE) ||
			    fsmonitor_parse_hardlink_inode(
				    changed, changed_len, NULL)) {
				closing_delta = 0;
				break;
			}
		}
	}

	while (p < end) {
		size_t len = strlen(p);
		uint32_t inode;
		int parsed = fsmonitor_parse_hardlink_inode(p, len, &inode);

		if (parsed < 0) {
			fsmonitor_refresh_callback(
				istate, (char *)FSMONITOR_PATH_GLOBAL_INVALIDATE, 0);
			count++;
			goto done;
		}
		if (!parsed) {
			fsmonitor_refresh_callback(
				istate, (char *)p, closing_delta);
			count++;
		} else if (!hashmap_get_entry_from_hash(
				   &inodes, memhash(&inode, sizeof(inode)), &inode,
				   struct fsmonitor_hardlink_inode, ent)) {
			CALLOC_ARRAY(entry, 1);
			entry->inode = inode;
			hashmap_entry_init(&entry->ent,
					   memhash(&inode, sizeof(inode)));
			hashmap_add(&inodes, &entry->ent);
		}
		p += len + 1;
	}

	if (hashmap_get_size(&inodes)) {
		unsigned int i;

		trace2_data_intmax("fsmonitor", istate->repo,
				   "apply/hardlink-inode-events",
				   hashmap_get_size(&inodes));
		for (i = 0; i < istate->cache_nr; i++) {
			struct cache_entry *ce = istate->cache[i];
			uint32_t inode = ce->ce_stat_data.sd_ino;

			if (inode &&
			    !hashmap_get_entry_from_hash(
				    &inodes, memhash(&inode, sizeof(inode)), &inode,
				    struct fsmonitor_hardlink_inode, ent))
				continue;
			fsmonitor_refresh_callback(istate, ce->name, 0);
			matches++;
			count++;
		}
		trace2_data_intmax("fsmonitor", istate->repo,
				   "apply/hardlink-index-scan", 1);
		trace2_data_intmax("fsmonitor", istate->repo,
				   "apply/hardlink-matches", matches);
	}

done:
	hashmap_clear_and_free(&inodes, struct fsmonitor_hardlink_inode, ent);
	return count;
}

static void adopt_legacy_untracked_cache(
	struct index_state *istate,
	const struct fsmonitor_query_result *result,
	int semantic_baseline_needed)
{
	if (fstat_is_reliable() && !istate->split_index &&
	    istate->repo->config_values_private_.trust_ctime &&
	    istate->repo->config_values_private_.check_stat &&
	    result->outcome == FSMONITOR_QUERY_TRIVIAL &&
	    istate->fsmonitor_token_valid &&
	    istate->fsmonitor_last_update &&
	    !strcmp(istate->fsmonitor_last_update, "builtin:fake") &&
	    !istate->fsmonitor_untracked_extension_seen &&
	    !istate->fsmonitor_untracked_extension_invalid &&
	    istate->untracked && istate->untracked->root) {
		/*
		 * A client without daemon support records builtin:fake. Its
		 * UNTR tree is still useful with ordinary directory timestamp
		 * validation, but it cannot certify fsmonitor acceleration.
		 */
		istate->fsmonitor_legacy_untracked_fallback = 1;
		istate->untracked->use_fsmonitor = 0;
		trace2_data_intmax("fsmonitor", istate->repo,
				   "untracked/legacy-stat-fallback", 1);
		return;
	}
	if (!semantic_baseline_needed ||
	    !result->legacy_worktree_authenticated ||
	    result->outcome != FSMONITOR_QUERY_DELTA ||
	    !istate->fsmonitor_token_valid ||
	    !istate->fsmonitor_last_update ||
	    istate->fsmonitor_untracked_extension_seen ||
	    istate->fsmonitor_untracked_extension_invalid ||
	    !istate->untracked || !istate->untracked->root) {
		untracked_cache_discard_legacy(istate);
		return;
	}
	if (!untracked_cache_adopt_legacy(istate))
		return;
	FREE_AND_NULL(istate->fsmonitor_untracked_token);
	istate->fsmonitor_untracked_token =
		xstrdup(istate->fsmonitor_last_update);
	istate->fsmonitor_untracked_valid = 1;
	istate->fsmonitor_legacy_untracked_adopted = 1;
	istate->untracked->use_fsmonitor = 1;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "untracked/legacy-adopted", 1);
}

static void invalidate_all_fsmonitor(struct index_state *istate)
{
	unsigned int i;
	int changed = 0;

	istate->fsmonitor_untracked_revalidation_authenticated = 0;
	for (i = 0; i < istate->cache_nr; i++) {
		if (istate->cache[i]->ce_flags & CE_FSMONITOR_VALID)
			changed = 1;
		istate->cache[i]->ce_flags &= ~CE_FSMONITOR_VALID;
	}
	istate->fsmonitor_untracked_valid = 0;
	if (istate->untracked)
		istate->untracked->use_fsmonitor = 0;
	if (changed)
		istate->cache_changed |= FSMONITOR_CHANGED;
}

/*
 * A forward baseline still needs one ordinary stat refresh before its
 * provider token can certify the index. Clear only process-local
 * uptodate state so that refresh_index() performs those stats without
 * escalating to content checks.
 */
static void invalidate_all_fsmonitor_for_baseline(
	struct index_state *istate)
{
	unsigned int i;
	int preserve_untracked = istate->fsmonitor_legacy_untracked_adopted &&
		istate->fsmonitor_untracked_valid;

	invalidate_all_fsmonitor(istate);
	if (preserve_untracked) {
		istate->fsmonitor_untracked_valid = 1;
		istate->untracked->use_fsmonitor = 1;
	}
	for (i = 0; i < istate->cache_nr; i++)
		istate->cache[i]->ce_flags &= ~CE_UPTODATE;
}

static void invalidate_all_fsmonitor_strong(struct index_state *istate)
{
	unsigned int i;
	int provider_disabled =
		fsm_settings__get_mode(istate->repo) == FSMONITOR_MODE_DISABLED;

	invalidate_all_fsmonitor(istate);
	for (i = 0; i < istate->cache_nr; i++) {
		struct cache_entry *ce = istate->cache[i];

		if (provider_disabled && ce_skip_worktree(ce))
			continue;
		fsmonitor_invalidate_cache_entry(ce);
	}
}

void fsmonitor_invalidate_semantics(struct index_state *istate)
{
	istate->fsmonitor_legacy_untracked_adopted = 0;
	clean_status_invalidate_current_proof(istate);
	git_attr_invalidate_all();
	invalidate_all_fsmonitor_strong(istate);
	istate->cache_changed |= FSMONITOR_CHANGED;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "semantic/strong-invalidation", 1);
}

static void invalidate_fsmonitor_for_bootstrap(
	struct index_state *istate, enum fsmonitor_mode mode,
	int semantic_adoption_needed, int semantic_baseline_needed,
	int physical_history_unavailable, int provider_query_success)
{
	int manifest_refresh_failed;

	if (!fstat_is_reliable() || mode != FSMONITOR_MODE_IPC ||
	    istate->split_index) {
		invalidate_all_fsmonitor(istate);
		return;
	}
	if (getenv(INDEX_ENVIRONMENT) &&
	    !clean_status_has_persistent_fsmonitor_semantic_history(istate)) {
		char *physical = xstrfmt("%s/index", repo_get_git_dir(istate->repo));
		char *selected = real_pathdup(repo_get_index_file(istate->repo), 0);
		char *canonical = real_pathdup(physical, 0);
		char *physical_lock = canonical ? xstrfmt("%s.lock", canonical) : NULL;
		struct stat selected_stat, physical_stat;
		int temporary = selected && canonical &&
			fspathcmp(selected, canonical) &&
			fspathcmp(selected, physical_lock) &&
			!stat(selected, &selected_stat) &&
			!stat(canonical, &physical_stat) &&
			(selected_stat.st_dev != physical_stat.st_dev ||
			 selected_stat.st_ino != physical_stat.st_ino);

		free(physical_lock);
		free(canonical);
		free(selected);
		free(physical);
		if (temporary) {
			fsmonitor_invalidate_semantics(istate);
			untracked_cache_invalidate_all(istate);
			trace2_data_intmax("fsmonitor", istate->repo,
					   "semantic/temporary-index-stat-fallback", 1);
			return;
		}
	}

	if (physical_history_unavailable) {
		int authenticated_manifest =
			clean_status_has_authenticated_worktree_manifest(istate);
		int pending_revalidation =
			istate->fsmonitor_untracked_revalidation_authenticated;
		int preserve_untracked = 0;

		if (istate->fsmonitor_legacy_untracked_fallback) {
			invalidate_all_fsmonitor_for_baseline(istate);
			trace2_data_intmax("fsmonitor", istate->repo,
					   "semantic/legacy-stat-fallback", 1);
			return;
		}
		manifest_refresh_failed =
			(pending_revalidation ||
			 !clean_status_has_authenticated_bootstrap_manifest(istate)) &&
			clean_status_refresh_worktree_manifest(istate) < 0;
		if (provider_query_success && !manifest_refresh_failed &&
		    !clean_status_manifest_global_fallback(istate) &&
		    !clean_status_fsmonitor_strong_mismatch(istate) &&
		    !clean_status_filter_scope_needs_validation(istate) &&
		    (!pending_revalidation ||
		     (istate->fsmonitor_untracked_revalidation_authenticated &&
		      istate->untracked && istate->untracked->root &&
		      istate->untracked->root->valid &&
		      clean_status_pending_revalidation_manifest_unchanged(
			      istate))) &&
		    istate->repo->config_values_private_.trust_ctime &&
		    istate->repo->config_values_private_.check_stat) {
			/* Strong stat identity survives a lost provider boundary. */
			if ((authenticated_manifest &&
			     !clean_status_fsmonitor_config_mismatch(istate)) ||
			    pending_revalidation)
				preserve_untracked =
					untracked_cache_preserve_for_revalidation(istate);
			if (pending_revalidation && preserve_untracked)
				trace2_data_intmax("fsmonitor", istate->repo,
						   "untracked/provider-reset-resumed", 1);
			clean_status_begin_fsmonitor_semantic_baseline(istate);
			invalidate_all_fsmonitor_for_baseline(istate);
			trace2_data_intmax("fsmonitor", istate->repo,
					   "semantic/token-reset-stat-baseline", 1);
		} else {
			fsmonitor_invalidate_semantics(istate);
		}
		if (!preserve_untracked)
			untracked_cache_invalidate_all(istate);
		return;
	}

	manifest_refresh_failed =
		!clean_status_has_authenticated_worktree_manifest(istate) &&
		clean_status_refresh_worktree_manifest(istate) < 0;
	if (manifest_refresh_failed ||
	    clean_status_manifest_global_fallback(istate) ||
	    (semantic_adoption_needed && !semantic_baseline_needed)) {
		fsmonitor_invalidate_semantics(istate);
	} else {
		if (semantic_baseline_needed) {
			clean_status_begin_fsmonitor_semantic_baseline(istate);
			invalidate_all_fsmonitor_for_baseline(istate);
			trace2_data_intmax("fsmonitor", istate->repo,
					   "semantic/adoption-baseline", 1);
		} else {
			invalidate_all_fsmonitor(istate);
		}
	}
}

void refresh_fsmonitor(struct index_state *istate)
{
	static int warn_once = 0;
	struct strbuf query_result = STRBUF_INIT;
	int query_success = 0, hook_version = -1;
	size_t bol = 0; /* beginning of line */
	uint64_t last_update;
	struct strbuf last_update_token = STRBUF_INIT;
	char *buf;
	unsigned int i;
	int is_trivial = 0;
	int tracked_requires_bootstrap;
	int untracked_requires_bootstrap;
	int semantic_adoption_needed;
	int semantic_baseline_needed;
	struct repository *r = istate->repo;
	enum fsmonitor_mode fsm_mode = fsm_settings__get_mode(r);
	enum fsmonitor_reason reason = fsm_settings__get_reason(r);

	if (!warn_once && reason > FSMONITOR_REASON_OK) {
		char *msg = fsm_settings__get_incompatible_msg(r, reason);
		warn_once = 1;
		warning("%s", msg);
		free(msg);
	}

	if (fsm_mode <= FSMONITOR_MODE_DISABLED ||
	    istate->fsmonitor_has_run_once)
		return;

	istate->fsmonitor_has_run_once = 1;
	semantic_adoption_needed = fstat_is_reliable() &&
		!istate->split_index &&
		fsm_mode == FSMONITOR_MODE_IPC &&
		clean_status_fsmonitor_semantic_adoption_needed(istate);
	semantic_baseline_needed = fstat_is_reliable() &&
		!istate->split_index &&
		fsm_mode == FSMONITOR_MODE_IPC &&
		clean_status_fsmonitor_semantic_baseline_needed(istate);

	trace_printf_key(&trace_fsmonitor, "refresh fsmonitor");

	if (fsm_mode == FSMONITOR_MODE_IPC) {
		struct fsmonitor_query_result result =
			FSMONITOR_QUERY_RESULT_INIT;

		query_builtin_fsmonitor(
			istate->fsmonitor_last_update ?
			istate->fsmonitor_last_update : "builtin:fake",
			&result);
		adopt_legacy_untracked_cache(
			istate, &result, semantic_baseline_needed);
		if (result.outcome != FSMONITOR_QUERY_ERROR) {
			query_success = 1;
			strbuf_addbuf(&last_update_token, &result.token);
			is_trivial = result.outcome == FSMONITOR_QUERY_TRIVIAL;
			if (!is_trivial)
				strbuf_addbuf(&query_result, &result.paths);
			if (is_trivial)
				trace2_data_intmax("fsm_client", NULL,
						   "query/trivial-response", 1);
		} else {
			/*
			 * The builtin daemon is not available on this
			 * platform -OR- we failed to get a response.
			 *
			 * Generate a fake token (rather than a V1
			 * timestamp) for the index extension.  (If
			 * they switch back to the hook API, we don't
			 * want ambiguous state.)
			 */
			strbuf_addstr(&last_update_token, "builtin:fake");
		}
		fsmonitor_query_result_release(&result);

		goto apply_results;
	}

	assert(fsm_mode == FSMONITOR_MODE_HOOK);

	hook_version = fsmonitor_hook_version();

	/*
	 * This could be racy so save the date/time now and query_fsmonitor_hook
	 * should be inclusive to ensure we don't miss potential changes.
	 */
	last_update = getnanotime();
	if (hook_version == HOOK_INTERFACE_VERSION1)
		strbuf_addf(&last_update_token, "%"PRIu64"", last_update);

	/*
	 * If we have a last update token, call query_fsmonitor_hook for the set of
	 * changes since that token, else assume everything is possibly dirty
	 * and check it all.
	 */
	if (istate->fsmonitor_last_update) {
		if (hook_version == -1 || hook_version == HOOK_INTERFACE_VERSION2) {
			query_success = !query_fsmonitor_hook(
				r, HOOK_INTERFACE_VERSION2,
				istate->fsmonitor_last_update, &query_result);

			if (query_success) {
				if (hook_version < 0)
					hook_version = HOOK_INTERFACE_VERSION2;

				/*
				 * First entry will be the last update token
				 * Need to use a char * variable because static
				 * analysis was suggesting to use strbuf_addbuf
				 * but we don't want to copy the entire strbuf
				 * only the chars up to the first NUL
				 */
				buf = query_result.buf;
				strbuf_addstr(&last_update_token, buf);
				if (!last_update_token.len) {
					warning("Empty last update token.");
					query_success = 0;
				} else {
					bol = last_update_token.len + 1;
					is_trivial = is_trivial_response_at(
						&query_result, bol);
				}
			} else if (hook_version < 0) {
				hook_version = HOOK_INTERFACE_VERSION1;
				if (!last_update_token.len)
					strbuf_addf(&last_update_token, "%"PRIu64"", last_update);
			}
		}

		if (hook_version == HOOK_INTERFACE_VERSION1) {
			query_success = !query_fsmonitor_hook(
				r, HOOK_INTERFACE_VERSION1,
				istate->fsmonitor_last_update, &query_result);
			if (query_success)
				is_trivial = is_trivial_response_at(&query_result, 0);
		}

		if (is_trivial)
			trace2_data_intmax("fsm_hook", NULL,
					   "query/trivial-response", 1);

		trace_performance_since(last_update, "fsmonitor process '%s'",
					fsm_settings__get_hook_path(r));
		trace_printf_key(&trace_fsmonitor,
				 "fsmonitor process '%s' returned %s",
				 fsm_settings__get_hook_path(r),
				 query_success ? "success" : "failure");
	}

apply_results:
	/*
	 * The response from FSMonitor (excluding the header token) is
	 * either:
	 *
	 * [a] a (possibly empty) list of NUL delimited relative
	 *     pathnames of changed paths.  This list can contain
	 *     files and directories.  Directories have a trailing
	 *     slash.
	 *
	 * [b] a single '/' to indicate the provider had no
	 *     information and that we should consider everything
	 *     invalid.  We call this a trivial response.
	 */
	trace2_region_enter("fsmonitor", "apply_results", istate->repo);

	tracked_requires_bootstrap = !query_success || is_trivial ||
		!istate->fsmonitor_token_valid ||
		(fstat_is_reliable() && !istate->split_index &&
		 fsm_mode == FSMONITOR_MODE_IPC &&
		 clean_status_fsmonitor_config_mismatch(istate));
	untracked_requires_bootstrap = !istate->fsmonitor_untracked_valid;

	if (query_success && !is_trivial) {
		/*
		 * Mark all pathnames returned by the monitor as dirty.
		 *
		 * This updates both the cache-entries and the untracked-cache.
		 */
		int count = 0;

		if (fsm_mode == FSMONITOR_MODE_IPC) {
			count = apply_fsmonitor_paths(istate, &query_result, 0);
		} else {
			buf = query_result.buf;
			for (i = bol; i < query_result.len; i++) {
				if (buf[i] != '\0')
					continue;
				if (i > bol) {
					fsmonitor_refresh_callback(
						istate, buf + bol, 0);
					count++;
				}
				bol = i + 1;
			}
			if (bol < query_result.len) {
				fsmonitor_refresh_callback(istate, buf + bol, 0);
				count++;
			}
		}

		/*
		 * Applying a provider event may expire semantic history after
		 * the initial bootstrap decision. Keep the new token pending
		 * until status has rescanned against rebuilt inputs.
		 */
		if (fstat_is_reliable() && !istate->split_index &&
		    fsm_mode == FSMONITOR_MODE_IPC &&
		    clean_status_fsmonitor_config_mismatch(istate)) {
			if (clean_status_try_preserve_tracked_config_epoch(istate)) {
				tracked_requires_bootstrap = 0;
				trace2_data_intmax("fsmonitor", istate->repo,
						   "config/tracked-epoch-preserved", 1);
			} else {
				tracked_requires_bootstrap = 1;
			}
		}

		if (tracked_requires_bootstrap) {
			/*
			 * Provider paths can invalidate the manifest or
			 * semantic inputs after our pre-query snapshot.
			 * Recheck before choosing the narrow baseline lane.
			 */
			semantic_adoption_needed = fstat_is_reliable() &&
				!istate->split_index &&
				fsm_mode == FSMONITOR_MODE_IPC &&
				clean_status_fsmonitor_semantic_adoption_needed(
					istate);
			semantic_baseline_needed = fstat_is_reliable() &&
				!istate->split_index &&
				fsm_mode == FSMONITOR_MODE_IPC &&
				clean_status_fsmonitor_semantic_baseline_needed(
					istate);
			invalidate_fsmonitor_for_bootstrap(
				istate, fsm_mode, semantic_adoption_needed,
				semantic_baseline_needed,
				!istate->fsmonitor_token_valid, query_success);
		}

		/* Now mark the untracked cache for fsmonitor usage */
		if (istate->untracked)
			istate->untracked->use_fsmonitor =
				!tracked_requires_bootstrap &&
				!untracked_requires_bootstrap;

		if (count > fsmonitor_force_update_threshold)
			istate->cache_changed |= FSMONITOR_CHANGED;

		trace2_data_intmax("fsmonitor", istate->repo, "apply_count",
				   count);

	} else {
		/*
		 * We failed to get a response or received a trivial response,
		 * so invalidate everything.
		 *
		 * We only want to run the post index changed hook if
		 * we've actually changed entries, so keep track if we
		 * actually changed entries or not.
		 */
		invalidate_fsmonitor_for_bootstrap(
			istate, fsm_mode, semantic_adoption_needed,
			semantic_baseline_needed, 1, query_success);
	}
	trace2_region_leave("fsmonitor", "apply_results", istate->repo);

	strbuf_release(&query_result);

	/*
	 * A token obtained before a full scan cannot describe changes which
	 * race with that scan. Keep it in memory until the caller closes the
	 * race with a second query. The last valid token remains safe because
	 * a query relative to it will return a superset of changes.
	 */
	if (tracked_requires_bootstrap) {
		if (!last_update_token.len) {
			if (istate->fsmonitor_last_update)
				strbuf_addstr(&last_update_token,
					      istate->fsmonitor_last_update);
			else
				strbuf_addstr(&last_update_token, "builtin:fake");
		}
		FREE_AND_NULL(istate->fsmonitor_last_update_pending);
		istate->fsmonitor_last_update_pending =
			strbuf_detach(&last_update_token, NULL);
		/*
		 * A trivial response cannot validate prior state, but its
		 * returned token is still a provider-owned boundary.  Use it
		 * to anchor the complete scan which the caller will close with
		 * another query.  Hook providers cannot perform that closing
		 * query, so do not publish their trivial-response tokens.
		 */
		istate->fsmonitor_pending_token_from_provider =
			query_success &&
			(fsm_mode == FSMONITOR_MODE_IPC || !is_trivial);
		if (istate->fsmonitor_legacy_untracked_adopted) {
			FREE_AND_NULL(istate->fsmonitor_untracked_token);
			istate->fsmonitor_untracked_token =
				xstrdup(istate->fsmonitor_last_update_pending);
		} else {
			istate->fsmonitor_untracked_valid = 0;
		}
	} else {
		/*
		 * The applied delta carries an existing proof forward:
		 * tracked paths are now invalid in FSMN, while semantic
		 * events have already expired the proof itself.
		 */
		if (fsm_mode == FSMONITOR_MODE_IPC)
			clean_status_advance_fsmonitor_config_token(
				istate, last_update_token.buf);
		FREE_AND_NULL(istate->fsmonitor_last_update);
		istate->fsmonitor_last_update =
			strbuf_detach(&last_update_token, NULL);
		if (untracked_requires_bootstrap) {
			FREE_AND_NULL(istate->fsmonitor_last_update_pending);
			istate->fsmonitor_last_update_pending =
				xstrdup(istate->fsmonitor_last_update);
			istate->fsmonitor_pending_token_from_provider = 1;
		} else {
			FREE_AND_NULL(istate->fsmonitor_last_update_pending);
			istate->fsmonitor_pending_token_from_provider = 0;
		}
		if (istate->fsmonitor_untracked_valid && istate->untracked) {
			FREE_AND_NULL(istate->fsmonitor_untracked_token);
			istate->fsmonitor_untracked_token =
				xstrdup(istate->fsmonitor_last_update);
		}
	}
}

int fsmonitor_has_pending_token(const struct index_state *istate)
{
	return !!istate->fsmonitor_last_update_pending;
}

int fsmonitor_pending_token_from_provider(const struct index_state *istate)
{
	return istate->fsmonitor_last_update_pending &&
		istate->fsmonitor_pending_token_from_provider;
}

int fsmonitor_reopen_token(struct index_state *istate)
{
	if (!fstat_is_reliable() || istate->split_index ||
	    fsm_settings__get_mode(istate->repo) != FSMONITOR_MODE_IPC)
		return 0;
	if (istate->fsmonitor_last_update_pending)
		return istate->fsmonitor_pending_token_from_provider;
	if (!istate->fsmonitor_token_valid || !istate->fsmonitor_last_update)
		return 0;
	istate->fsmonitor_last_update_pending =
		xstrdup(istate->fsmonitor_last_update);
	istate->fsmonitor_pending_token_from_provider = 1;
	return 1;
}

enum fsmonitor_token_result fsmonitor_query_pending_token(
	struct index_state *istate, int untracked_ready)
{
	struct fsmonitor_query_result result = FSMONITOR_QUERY_RESULT_INIT;
	enum fsmonitor_token_result ret;
	int count;

	if (!istate->fsmonitor_last_update_pending)
		return FSMONITOR_TOKEN_NOT_PENDING;
	if (fsm_settings__get_mode(istate->repo) != FSMONITOR_MODE_IPC)
		return FSMONITOR_TOKEN_ERROR;

	query_builtin_fsmonitor(istate->fsmonitor_last_update_pending, &result);
	if (result.outcome == FSMONITOR_QUERY_ERROR) {
		istate->fsmonitor_pending_token_from_provider = 0;
		ret = FSMONITOR_TOKEN_ERROR;
		goto done;
	}

	FREE_AND_NULL(istate->fsmonitor_last_update_pending);
	istate->fsmonitor_last_update_pending =
		strbuf_detach(&result.token, NULL);
	istate->fsmonitor_pending_token_from_provider = 1;
	if (result.outcome == FSMONITOR_QUERY_TRIVIAL) {
		invalidate_all_fsmonitor_strong(istate);
		trace2_data_intmax("fsmonitor", istate->repo,
				   "token_closure/trivial", 1);
		ret = FSMONITOR_TOKEN_TRIVIAL;
		goto done;
	}

	count = apply_fsmonitor_paths(istate, &result.paths, 1);
	if (istate->untracked)
		istate->untracked->use_fsmonitor = !!untracked_ready;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "token_closure/apply_count", count);
	ret = count ? FSMONITOR_TOKEN_CHANGED : FSMONITOR_TOKEN_CLEAN;

done:
	fsmonitor_query_result_release(&result);
	return ret;
}

void fsmonitor_accept_pending_token(struct index_state *istate,
				    int untracked_proof_complete,
				    int untracked_cache_valid)
{
	if (untracked_cache_valid && !untracked_proof_complete)
		BUG("valid untracked cache without a complete proof");
	if (!fsmonitor_pending_token_from_provider(istate))
		return;
	istate->fsmonitor_untracked_revalidation_authenticated = 0;
	FREE_AND_NULL(istate->fsmonitor_last_update);
	istate->fsmonitor_last_update = istate->fsmonitor_last_update_pending;
	istate->fsmonitor_last_update_pending = NULL;
	istate->fsmonitor_pending_token_from_provider = 0;
	istate->fsmonitor_token_valid = 1;
	istate->fsmonitor_untracked_valid = !!untracked_cache_valid;
	if (istate->untracked) {
		if (istate->untracked->fsmonitor_revalidation &&
		    untracked_cache_valid) {
			istate->fsmonitor_untracked_must_persist = 1;
			trace2_data_intmax("fsmonitor", istate->repo,
					   "untracked/provider-reset-revalidated", 1);
		}
		if (untracked_cache_valid &&
		    !istate->fsmonitor_untracked_extension_seen &&
		    istate == istate->repo->index &&
		    !getenv(INDEX_ENVIRONMENT) && !istate->split_index &&
		    istate->sparse_index == INDEX_EXPANDED &&
		    fsm_settings__get_mode(istate->repo) == FSMONITOR_MODE_IPC)
			istate->fsmonitor_untracked_must_persist = 1;
		istate->untracked->fsmonitor_revalidation = 0;
		istate->untracked->use_fsmonitor = !!untracked_cache_valid;
	}
	istate->cache_changed |= FSMONITOR_CHANGED;
	FREE_AND_NULL(istate->fsmonitor_untracked_token);
	if (untracked_cache_valid)
		istate->fsmonitor_untracked_token =
			xstrdup(istate->fsmonitor_last_update);
	else if (!untracked_proof_complete) {
		/*
		 * Keep a query anchored at the accepted tracked token. A
		 * later in-process status may need to close work done after
		 * this point before validating its untracked cache.
		 */
		istate->fsmonitor_last_update_pending =
			xstrdup(istate->fsmonitor_last_update);
		istate->fsmonitor_pending_token_from_provider = 1;
	}
	trace2_data_intmax("fsmonitor", istate->repo,
			   "token_closure/accepted", 1);
}

void fsmonitor_reject_pending_token(struct index_state *istate)
{
	FREE_AND_NULL(istate->fsmonitor_last_update_pending);
	istate->fsmonitor_pending_token_from_provider = 0;
	if (istate->untracked)
		istate->untracked->fsmonitor_revalidation = 0;
	if (!istate->fsmonitor_token_valid)
		FREE_AND_NULL(istate->fsmonitor_last_update);
	invalidate_all_fsmonitor_strong(istate);
	trace2_data_intmax("fsmonitor", istate->repo,
			   "token_closure/rejected", 1);
}

void fsmonitor_mark_untracked_cache_valid(struct index_state *istate)
{
	if (istate->fsmonitor_last_update_pending ||
	    !istate->fsmonitor_token_valid ||
	    !istate->fsmonitor_last_update || !istate->untracked ||
	    istate->fsmonitor_untracked_valid)
		return;
	istate->fsmonitor_untracked_valid = 1;
	FREE_AND_NULL(istate->fsmonitor_untracked_token);
	istate->fsmonitor_untracked_token =
		xstrdup(istate->fsmonitor_last_update);
	istate->cache_changed |= FSMONITOR_CHANGED;
}

/*
 * The caller wants to turn on FSMonitor.  And when the caller writes
 * the index to disk, a FSMonitor extension should be included.  This
 * requires that `istate->fsmonitor_last_update` not be NULL.  But we
 * have not actually talked to a FSMonitor process yet, so we don't
 * have an initial value for this field.
 *
 * For a protocol V1 FSMonitor process, this field is a formatted
 * "nanoseconds since epoch" field.  However, for a protocol V2
 * FSMonitor process, this field is an opaque token.
 *
 * Historically, `add_fsmonitor()` has initialized this field to the
 * current time for protocol V1 processes.  There are lots of race
 * conditions here, but that code has shipped...
 *
 * The only true solution is to use a V2 FSMonitor and get a current
 * or default token value (that it understands), but we cannot do that
 * until we have actually talked to an instance of the FSMonitor process
 * (but the protocol requires that we send a token first...).
 *
 * For simplicity, just initialize like we have a V1 process and require
 * that V2 processes adapt.
 */
static void initialize_fsmonitor_last_update(struct index_state *istate)
{
	struct strbuf last_update = STRBUF_INIT;

	strbuf_addf(&last_update, "%"PRIu64"", getnanotime());
	istate->fsmonitor_last_update = strbuf_detach(&last_update, NULL);
	istate->fsmonitor_token_valid = 0;
}

void add_fsmonitor(struct index_state *istate)
{
	unsigned int i;

	if (!istate->fsmonitor_last_update) {
		trace_printf_key(&trace_fsmonitor, "add fsmonitor");
		istate->cache_changed |= FSMONITOR_CHANGED;
		initialize_fsmonitor_last_update(istate);

		/* reset the fsmonitor state */
		for (i = 0; i < istate->cache_nr; i++)
			istate->cache[i]->ce_flags &= ~CE_FSMONITOR_VALID;

		/* reset the untracked cache */
		if (istate->untracked) {
			add_untracked_cache(istate);
			istate->untracked->use_fsmonitor = 0;
		}

		/* Update the fsmonitor state */
		refresh_fsmonitor(istate);
	}
}

void remove_fsmonitor(struct index_state *istate)
{
	istate->fsmonitor_token_valid = 0;
	istate->fsmonitor_untracked_valid = 0;
	istate->fsmonitor_untracked_revalidation_authenticated = 0;
	FREE_AND_NULL(istate->fsmonitor_last_update_pending);
	istate->fsmonitor_pending_token_from_provider = 0;
	FREE_AND_NULL(istate->fsmonitor_untracked_token);
	if (istate->untracked)
		istate->untracked->use_fsmonitor = 0;
	if (istate->fsmonitor_last_update) {
		trace_printf_key(&trace_fsmonitor, "remove fsmonitor");
		istate->cache_changed |= FSMONITOR_CHANGED;
		FREE_AND_NULL(istate->fsmonitor_last_update);
	}
}

void tweak_fsmonitor(struct index_state *istate)
{
	unsigned int i;
	int fsmonitor_enabled = (fsm_settings__get_mode(istate->repo)
				 > FSMONITOR_MODE_DISABLED);

	if (istate->fsmonitor_dirty) {
		if (fsmonitor_enabled) {
			/* Mark all entries valid */
			for (i = 0; i < istate->cache_nr; i++) {
				if (S_ISGITLINK(istate->cache[i]->ce_mode))
					continue;
				istate->cache[i]->ce_flags |= CE_FSMONITOR_VALID;
			}

			/* Mark all previously saved entries as dirty */
			assert_index_minimum(istate, istate->fsmonitor_dirty->bit_size);
			ewah_each_bit(istate->fsmonitor_dirty, fsmonitor_ewah_callback, istate);

			refresh_fsmonitor(istate);
		}

		ewah_free(istate->fsmonitor_dirty);
		istate->fsmonitor_dirty = NULL;
	}

	if (fsmonitor_enabled)
		add_fsmonitor(istate);
	else
		remove_fsmonitor(istate);
}
