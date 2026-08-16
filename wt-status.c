#define USE_THE_REPOSITORY_VARIABLE
#define DISABLE_SIGN_COMPARE_WARNINGS

#include "git-compat-util.h"
#include "abspath.h"
#include "advice.h"
#include "attr.h"
#include "attr-fingerprint.h"
#include "wt-status.h"
#include "cache-tree.h"
#include "object.h"
#include "dir.h"
#include "commit.h"
#include "clean-status.h"
#include "clean-status-index.h"
#include "clean-status-manifest.h"
#include "diff.h"
#include "environment.h"
#include "exclude-source-proof.h"
#include "gettext.h"
#include "hash.h"
#include "hex.h"
#include "object-name.h"
#include "path.h"
#include "preload-index.h"
#include "replace-object.h"
#include "revision.h"
#include "diffcore.h"
#include "quote.h"
#include "repository.h"
#include "run-command.h"
#include "strvec.h"
#include "remote.h"
#include "refs.h"
#include "submodule.h"
#include "column.h"
#include "read-cache.h"
#include "setup.h"
#include "semantic-verify.h"
#include "strbuf.h"
#include "trace.h"
#include "trace2.h"
#include "tree.h"
#include "utf8.h"
#include "worktree.h"
#include "lockfile.h"
#include "sequencer.h"
#include "fsmonitor.h"
#include "fsmonitor-settings.h"
#include "wrapper.h"

#define AB_DELAY_WARNING_IN_MS (2 * 1000)
#define UF_DELAY_WARNING_IN_MS (2 * 1000)

static const char cut_line[] =
"------------------------ >8 ------------------------\n";

static char default_wt_status_colors[][COLOR_MAXLEN] = {
	GIT_COLOR_NORMAL, /* WT_STATUS_HEADER */
	GIT_COLOR_GREEN,  /* WT_STATUS_UPDATED */
	GIT_COLOR_RED,    /* WT_STATUS_CHANGED */
	GIT_COLOR_RED,    /* WT_STATUS_UNTRACKED */
	GIT_COLOR_RED,    /* WT_STATUS_NOBRANCH */
	GIT_COLOR_RED,    /* WT_STATUS_UNMERGED */
	GIT_COLOR_GREEN,  /* WT_STATUS_LOCAL_BRANCH */
	GIT_COLOR_RED,    /* WT_STATUS_REMOTE_BRANCH */
	GIT_COLOR_NIL,    /* WT_STATUS_ONBRANCH */
};

static const char *color(int slot, struct wt_status *s)
{
	const char *c = "";
	if (want_color(s->use_color))
		c = s->color_palette[slot];
	if (slot == WT_STATUS_ONBRANCH && color_is_nil(c))
		c = s->color_palette[WT_STATUS_HEADER];
	return c;
}

static void status_vprintf(struct wt_status *s, int at_bol, const char *color,
		const char *fmt, va_list ap, const char *trail)
{
	struct strbuf sb = STRBUF_INIT;
	struct strbuf linebuf = STRBUF_INIT;
	const char *line, *eol;

	strbuf_vaddf(&sb, fmt, ap);
	if (!sb.len) {
		if (s->display_comment_prefix) {
			strbuf_addstr(&sb, comment_line_str);
			if (!trail)
				strbuf_addch(&sb, ' ');
		}
		color_print_strbuf(s->fp, color, &sb);
		if (trail)
			fprintf(s->fp, "%s", trail);
		strbuf_release(&sb);
		return;
	}
	for (line = sb.buf; *line; line = eol + 1) {
		eol = strchr(line, '\n');

		strbuf_reset(&linebuf);
		if (at_bol && s->display_comment_prefix) {
			strbuf_addstr(&linebuf, comment_line_str);
			if (*line != '\n' && *line != '\t')
				strbuf_addch(&linebuf, ' ');
		}
		if (eol)
			strbuf_add(&linebuf, line, eol - line);
		else
			strbuf_addstr(&linebuf, line);
		color_print_strbuf(s->fp, color, &linebuf);
		if (eol)
			fprintf(s->fp, "\n");
		else
			break;
		at_bol = 1;
	}
	if (trail)
		fprintf(s->fp, "%s", trail);
	strbuf_release(&linebuf);
	strbuf_release(&sb);
}

void status_printf_ln(struct wt_status *s, const char *color,
			const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	status_vprintf(s, 1, color, fmt, ap, "\n");
	va_end(ap);
}

void status_printf(struct wt_status *s, const char *color,
			const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	status_vprintf(s, 1, color, fmt, ap, NULL);
	va_end(ap);
}

__attribute__((format (printf, 3, 4)))
static void status_printf_more(struct wt_status *s, const char *color,
			       const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	status_vprintf(s, 0, color, fmt, ap, NULL);
	va_end(ap);
}

void wt_status_prepare(struct repository *r, struct wt_status *s)
{
	memset(s, 0, sizeof(*s));
	s->repo = r;
	memcpy(s->color_palette, default_wt_status_colors,
	       sizeof(default_wt_status_colors));
	s->show_untracked_files = SHOW_NORMAL_UNTRACKED_FILES;
	s->use_color = GIT_COLOR_UNKNOWN;
	s->relative_paths = 1;
	s->branch = refs_resolve_refdup(get_main_ref_store(r),
					"HEAD", 0, NULL, NULL);
	s->reference = "HEAD";
	s->fp = stdout;
	s->index_file = repo_get_index_file(r);
	s->change.strdup_strings = 1;
	s->untracked.strdup_strings = 1;
	s->ignored.strdup_strings = 1;
	s->show_branch = -1;  /* unspecified */
	s->show_stash = 0;
	s->ahead_behind_flags = AHEAD_BEHIND_UNSPECIFIED;
	s->display_comment_prefix = 0;
	s->detect_rename = -1;
	s->rename_score = -1;
	s->rename_limit = -1;
}

static void wt_longstatus_print_unmerged_header(struct wt_status *s)
{
	int i;
	int del_mod_conflict = 0;
	int both_deleted = 0;
	int not_deleted = 0;
	const char *c = color(WT_STATUS_HEADER, s);

	status_printf_ln(s, c, _("Unmerged paths:"));

	for (i = 0; i < s->change.nr; i++) {
		struct string_list_item *it = &(s->change.items[i]);
		struct wt_status_change_data *d = it->util;

		switch (d->stagemask) {
		case 0:
			break;
		case 1:
			both_deleted = 1;
			break;
		case 3:
		case 5:
			del_mod_conflict = 1;
			break;
		default:
			not_deleted = 1;
			break;
		}
	}

	if (!s->hints)
		return;
	if (s->whence != FROM_COMMIT)
		;
	else if (!s->is_initial) {
		if (!strcmp(s->reference, "HEAD"))
			status_printf_ln(s, c,
					 _("  (use \"git restore --staged <file>...\" to unstage)"));
		else
			status_printf_ln(s, c,
					 _("  (use \"git restore --source=%s --staged <file>...\" to unstage)"),
					 s->reference);
	} else
		status_printf_ln(s, c, _("  (use \"git rm --cached <file>...\" to unstage)"));

	if (!both_deleted) {
		if (!del_mod_conflict)
			status_printf_ln(s, c, _("  (use \"git add <file>...\" to mark resolution)"));
		else
			status_printf_ln(s, c, _("  (use \"git add/rm <file>...\" as appropriate to mark resolution)"));
	} else if (!del_mod_conflict && !not_deleted) {
		status_printf_ln(s, c, _("  (use \"git rm <file>...\" to mark resolution)"));
	} else {
		status_printf_ln(s, c, _("  (use \"git add/rm <file>...\" as appropriate to mark resolution)"));
	}
}

static void wt_longstatus_print_cached_header(struct wt_status *s)
{
	const char *c = color(WT_STATUS_HEADER, s);

	status_printf_ln(s, c, _("Changes to be committed:"));
	if (!s->hints)
		return;
	if (s->whence != FROM_COMMIT)
		; /* NEEDSWORK: use "git reset --unresolve"??? */
	else if (!s->is_initial) {
		if (!strcmp(s->reference, "HEAD"))
			status_printf_ln(s, c
					 , _("  (use \"git restore --staged <file>...\" to unstage)"));
		else
			status_printf_ln(s, c,
					 _("  (use \"git restore --source=%s --staged <file>...\" to unstage)"),
					 s->reference);
	} else
		status_printf_ln(s, c, _("  (use \"git rm --cached <file>...\" to unstage)"));
}

static void wt_longstatus_print_dirty_header(struct wt_status *s,
					     int has_deleted,
					     int has_dirty_submodules)
{
	const char *c = color(WT_STATUS_HEADER, s);

	status_printf_ln(s, c, _("Changes not staged for commit:"));
	if (!s->hints)
		return;
	if (!has_deleted)
		status_printf_ln(s, c, _("  (use \"git add <file>...\" to update what will be committed)"));
	else
		status_printf_ln(s, c, _("  (use \"git add/rm <file>...\" to update what will be committed)"));
	status_printf_ln(s, c, _("  (use \"git restore <file>...\" to discard changes in working directory)"));
	if (has_dirty_submodules)
		status_printf_ln(s, c, _("  (commit or discard the untracked or modified content in submodules)"));
}

static void wt_longstatus_print_other_header(struct wt_status *s,
					     const char *what,
					     const char *how)
{
	const char *c = color(WT_STATUS_HEADER, s);
	status_printf_ln(s, c, "%s:", what);
	if (!s->hints)
		return;
	status_printf_ln(s, c, _("  (use \"git %s <file>...\" to include in what will be committed)"), how);
}

static void wt_longstatus_print_trailer(struct wt_status *s)
{
	status_printf_ln(s, color(WT_STATUS_HEADER, s), "%s", "");
}

static const char *wt_status_unmerged_status_string(int stagemask)
{
	switch (stagemask) {
	case 1:
		return _("both deleted:");
	case 2:
		return _("added by us:");
	case 3:
		return _("deleted by them:");
	case 4:
		return _("added by them:");
	case 5:
		return _("deleted by us:");
	case 6:
		return _("both added:");
	case 7:
		return _("both modified:");
	default:
		BUG("unhandled unmerged status %x", stagemask);
	}
}

static const char *wt_status_diff_status_string(int status)
{
	switch (status) {
	case DIFF_STATUS_ADDED:
		return _("new file:");
	case DIFF_STATUS_COPIED:
		return _("copied:");
	case DIFF_STATUS_DELETED:
		return _("deleted:");
	case DIFF_STATUS_MODIFIED:
		return _("modified:");
	case DIFF_STATUS_RENAMED:
		return _("renamed:");
	case DIFF_STATUS_TYPE_CHANGED:
		return _("typechange:");
	case DIFF_STATUS_UNKNOWN:
		return _("unknown:");
	case DIFF_STATUS_UNMERGED:
		return _("unmerged:");
	default:
		return NULL;
	}
}

static int maxwidth(const char *(*label)(int), int minval, int maxval)
{
	int result = 0, i;

	for (i = minval; i <= maxval; i++) {
		const char *s = label(i);
		int len = s ? utf8_strwidth(s) : 0;
		if (len > result)
			result = len;
	}
	return result;
}

static void wt_longstatus_print_unmerged_data(struct wt_status *s,
					      struct string_list_item *it)
{
	const char *c = color(WT_STATUS_UNMERGED, s);
	struct wt_status_change_data *d = it->util;
	struct strbuf onebuf = STRBUF_INIT;
	static char *padding;
	static int label_width;
	const char *one, *how;
	int len;

	if (!padding) {
		label_width = maxwidth(wt_status_unmerged_status_string, 1, 7);
		label_width += strlen(" ");
		padding = xmallocz(label_width);
		memset(padding, ' ', label_width);
	}

	one = quote_path(it->string, s->prefix, &onebuf, 0);
	status_printf(s, color(WT_STATUS_HEADER, s), "\t");

	how = wt_status_unmerged_status_string(d->stagemask);
	len = label_width - utf8_strwidth(how);
	status_printf_more(s, c, "%s%.*s%s\n", how, len, padding, one);
	strbuf_release(&onebuf);
}

static void wt_longstatus_print_change_data(struct wt_status *s,
					    int change_type,
					    struct string_list_item *it)
{
	struct wt_status_change_data *d = it->util;
	const char *c = color(change_type, s);
	int status;
	char *one_name;
	char *two_name;
	const char *one, *two;
	struct strbuf onebuf = STRBUF_INIT, twobuf = STRBUF_INIT;
	struct strbuf extra = STRBUF_INIT;
	static char *padding;
	static int label_width;
	const char *what;
	int len;

	if (!padding) {
		/* If DIFF_STATUS_* uses outside the range [A..Z], we're in trouble */
		label_width = maxwidth(wt_status_diff_status_string, 'A', 'Z');
		label_width += strlen(" ");
		padding = xmallocz(label_width);
		memset(padding, ' ', label_width);
	}

	one_name = two_name = it->string;
	switch (change_type) {
	case WT_STATUS_UPDATED:
		status = d->index_status;
		break;
	case WT_STATUS_CHANGED:
		if (d->new_submodule_commits || d->dirty_submodule) {
			strbuf_addstr(&extra, " (");
			if (d->new_submodule_commits)
				strbuf_addstr(&extra, _("new commits, "));
			if (d->dirty_submodule & DIRTY_SUBMODULE_MODIFIED)
				strbuf_addstr(&extra, _("modified content, "));
			if (d->dirty_submodule & DIRTY_SUBMODULE_UNTRACKED)
				strbuf_addstr(&extra, _("untracked content, "));
			strbuf_setlen(&extra, extra.len - 2);
			strbuf_addch(&extra, ')');
		}
		status = d->worktree_status;
		break;
	default:
		BUG("unhandled change_type %d in wt_longstatus_print_change_data",
		    change_type);
	}

	/*
	 * Only pick up the rename it's relevant. If the rename is for
	 * the changed section and we're printing the updated section,
	 * ignore it.
	 */
	if (d->rename_status == status)
		one_name = d->rename_source;

	one = quote_path(one_name, s->prefix, &onebuf, 0);
	two = quote_path(two_name, s->prefix, &twobuf, 0);

	status_printf(s, color(WT_STATUS_HEADER, s), "\t");
	what = wt_status_diff_status_string(status);
	if (!what)
		BUG("unhandled diff status %c", status);
	len = label_width - utf8_strwidth(what);
	assert(len >= 0);
	if (one_name != two_name)
		status_printf_more(s, c, "%s%.*s%s -> %s",
				   what, len, padding, one, two);
	else
		status_printf_more(s, c, "%s%.*s%s",
				   what, len, padding, one);
	if (extra.len) {
		status_printf_more(s, color(WT_STATUS_HEADER, s), "%s", extra.buf);
		strbuf_release(&extra);
	}
	status_printf_more(s, GIT_COLOR_NORMAL, "\n");
	strbuf_release(&onebuf);
	strbuf_release(&twobuf);
}

static char short_submodule_status(struct wt_status_change_data *d)
{
	if (d->new_submodule_commits)
		return 'M';
	if (d->dirty_submodule & DIRTY_SUBMODULE_MODIFIED)
		return 'm';
	if (d->dirty_submodule & DIRTY_SUBMODULE_UNTRACKED)
		return '?';
	return d->worktree_status;
}

static struct wt_status_change_data *wt_status_get_change(
	struct wt_status *s, const char *path)
{
	struct string_list_item *it = string_list_insert(&s->change, path);
	struct wt_status_change_data *d = it->util;

	if (!d) {
		CALLOC_ARRAY(d, 1);
		it->util = d;
	}
	return d;
}

static void wt_status_collect_changed_cb(struct diff_queue_struct *q,
					 struct diff_options *options UNUSED,
					 void *data)
{
	struct wt_status *s = data;
	int i;

	if (!q->nr)
		return;
	s->workdir_dirty = 1;
	for (i = 0; i < q->nr; i++) {
		struct diff_filepair *p;
		struct wt_status_change_data *d;

		p = q->queue[i];
		d = wt_status_get_change(s, p->two->path);
		if (!d->worktree_status)
			d->worktree_status = p->status;
		if (S_ISGITLINK(p->two->mode)) {
			d->dirty_submodule = p->two->dirty_submodule;
			d->new_submodule_commits = !oideq(&p->one->oid,
							  &p->two->oid);
			if (s->status_format == STATUS_FORMAT_SHORT)
				d->worktree_status = short_submodule_status(d);
		}

		switch (p->status) {
		case DIFF_STATUS_ADDED:
			d->mode_worktree = p->two->mode;
			break;

		case DIFF_STATUS_DELETED:
			d->mode_index = p->one->mode;
			oidcpy(&d->oid_index, &p->one->oid);
			/* mode_worktree is zero for a delete. */
			break;

		case DIFF_STATUS_COPIED:
		case DIFF_STATUS_RENAMED:
			if (d->rename_status)
				BUG("multiple renames on the same target? how?");
			d->rename_source = xstrdup(p->one->path);
			d->rename_score = p->score * 100 / MAX_SCORE;
			d->rename_status = p->status;
			/* fallthru */
		case DIFF_STATUS_MODIFIED:
		case DIFF_STATUS_TYPE_CHANGED:
		case DIFF_STATUS_UNMERGED:
			d->mode_index = p->one->mode;
			d->mode_worktree = p->two->mode;
			oidcpy(&d->oid_index, &p->one->oid);
			break;

		default:
			BUG("unhandled diff-files status '%c'", p->status);
			break;
		}

	}
}

static struct cache_entry **wt_status_collect_preload_changes(
	struct wt_status *s, size_t *direct_nr)
{
	struct index_state *istate = s->repo->index;
	struct cache_entry **direct = NULL;
	size_t direct_alloc = 0;
	uint64_t modified = 0, deleted = 0;

	*direct_nr = 0;
	if (istate->preload_bulk_tracked_nr != istate->cache_nr)
		goto clear;
	for (size_t i = 0; i < istate->cache_nr; i++) {
		struct cache_entry *ce = istate->cache[i];
		struct wt_status_change_data *d;
		unsigned char state =
			istate->preload_bulk_tracked_state[i];
		unsigned int worktree_mode = 0;
		int status;

		if (state == PRELOAD_BULK_TRACKED_DEFINITIVE_MODIFIED) {
			struct stat st;

			if (lstat(ce->name, &st))
				continue;
			worktree_mode = ce_mode_from_stat(
				s->repo, ce, st.st_mode);
			status = DIFF_STATUS_MODIFIED;
			modified++;
		} else if (state == PRELOAD_BULK_TRACKED_DEFINITIVE_DELETED) {
			status = DIFF_STATUS_DELETED;
			deleted++;
		} else {
			continue;
		}

		d = wt_status_get_change(s, ce->name);
		if (!d->worktree_status)
			d->worktree_status = status;
		d->mode_index = ce->ce_mode;
		d->mode_worktree = worktree_mode;
		oidcpy(&d->oid_index, &ce->oid);
		ce_mark_uptodate(ce);
		ALLOC_GROW(direct, *direct_nr + 1, direct_alloc);
		direct[(*direct_nr)++] = ce;
		s->workdir_dirty = 1;
	}
	trace2_data_intmax("status", s->repo, "preload/direct_modified",
			   modified);
	trace2_data_intmax("status", s->repo, "preload/direct_deleted",
			   deleted);

clear:
	/*
	 * The tracked result is single-use. Keep a closed excludes digest
	 * available until the index writer has consumed it.
	 */
	preload_index_bulk_result_consume(istate);
	return direct;
}

static void wt_status_release_preload_changes(
	struct cache_entry **direct, size_t direct_nr)
{
	for (size_t i = 0; i < direct_nr; i++)
		direct[i]->ce_flags &= ~CE_UPTODATE;
	free(direct);
}

static int unmerged_mask(struct index_state *istate, const char *path)
{
	int pos, mask;
	const struct cache_entry *ce;

	pos = index_name_pos(istate, path, strlen(path));
	if (0 <= pos)
		return 0;

	mask = 0;
	pos = -pos-1;
	while (pos < istate->cache_nr) {
		ce = istate->cache[pos++];
		if (strcmp(ce->name, path) || !ce_stage(ce))
			break;
		mask |= (1 << (ce_stage(ce) - 1));
	}
	return mask;
}

static void wt_status_collect_updated_cb(struct diff_queue_struct *q,
					 struct diff_options *options UNUSED,
					 void *data)
{
	struct wt_status *s = data;
	int i;

	for (i = 0; i < q->nr; i++) {
		struct diff_filepair *p;
		struct wt_status_change_data *d;

		p = q->queue[i];
		d = wt_status_get_change(s, p->two->path);
		if (!d->index_status)
			d->index_status = p->status;
		switch (p->status) {
		case DIFF_STATUS_ADDED:
			/* Leave {mode,oid}_head zero for an add. */
			d->mode_index = p->two->mode;
			oidcpy(&d->oid_index, &p->two->oid);
			s->committable = 1;
			break;
		case DIFF_STATUS_DELETED:
			d->mode_head = p->one->mode;
			oidcpy(&d->oid_head, &p->one->oid);
			s->committable = 1;
			/* Leave {mode,oid}_index zero for a delete. */
			break;

		case DIFF_STATUS_COPIED:
		case DIFF_STATUS_RENAMED:
			if (d->rename_status)
				BUG("multiple renames on the same target? how?");
			d->rename_source = xstrdup(p->one->path);
			d->rename_score = p->score * 100 / MAX_SCORE;
			d->rename_status = p->status;
			/* fallthru */
		case DIFF_STATUS_MODIFIED:
		case DIFF_STATUS_TYPE_CHANGED:
			d->mode_head = p->one->mode;
			d->mode_index = p->two->mode;
			oidcpy(&d->oid_head, &p->one->oid);
			oidcpy(&d->oid_index, &p->two->oid);
			s->committable = 1;
			break;
		case DIFF_STATUS_UNMERGED:
			d->stagemask = unmerged_mask(s->repo->index,
						     p->two->path);
			/*
			 * Don't bother setting {mode,oid}_{head,index} since the print
			 * code will output the stage values directly and not use the
			 * values in these fields.
			 */
			break;

		default:
			BUG("unhandled diff-index status '%c'", p->status);
			break;
		}
	}
}

void wt_status_collect_changes_trees(struct wt_status *s,
				     const struct object_id *old_treeish,
				     const struct object_id *new_treeish)
{
	struct diff_options opts = { 0 };

	repo_diff_setup(s->repo, &opts);
	opts.output_format = DIFF_FORMAT_CALLBACK;
	opts.format_callback = wt_status_collect_updated_cb;
	opts.format_callback_data = s;
	opts.detect_rename = s->detect_rename >= 0 ? s->detect_rename : opts.detect_rename;
	opts.rename_limit = s->rename_limit >= 0 ? s->rename_limit : opts.rename_limit;
	opts.rename_score = s->rename_score >= 0 ? s->rename_score : opts.rename_score;
	opts.flags.recursive = 1;
	diff_setup_done(&opts);

	diff_tree_oid(old_treeish, new_treeish, "", &opts);
	diffcore_std(&opts);
	diff_flush(&opts);
	wt_status_get_state(s->repo, &s->state, 0);

	diff_free(&opts);
}

static void wt_status_collect_changes_worktree(struct wt_status *s)
{
	struct cache_entry **direct;
	size_t direct_nr;
	struct rev_info rev;

	if (s->tracked_from_fsmonitor) {
		preload_index_bulk_result_consume(s->repo->index);
		return;
	}

	direct = wt_status_collect_preload_changes(s, &direct_nr);
	repo_init_revisions(s->repo, &rev, NULL);
	setup_revisions(0, NULL, &rev, NULL);
	rev.diffopt.output_format |= DIFF_FORMAT_CALLBACK;
	rev.diffopt.flags.dirty_submodules = 1;
	rev.diffopt.ita_invisible_in_index = 1;
	if (!s->show_untracked_files)
		rev.diffopt.flags.ignore_untracked_in_submodules = 1;
	if (s->ignore_submodule_arg) {
		rev.diffopt.flags.override_submodule_config = 1;
		handle_ignore_submodules_arg(&rev.diffopt, s->ignore_submodule_arg);
	} else if (!rev.diffopt.flags.ignore_submodule_set &&
			s->show_untracked_files != SHOW_NO_UNTRACKED_FILES)
		handle_ignore_submodules_arg(&rev.diffopt, "none");
	rev.diffopt.format_callback = wt_status_collect_changed_cb;
	rev.diffopt.format_callback_data = s;
	rev.diffopt.detect_rename = s->detect_rename >= 0 ? s->detect_rename : rev.diffopt.detect_rename;
	rev.diffopt.rename_limit = s->rename_limit >= 0 ? s->rename_limit : rev.diffopt.rename_limit;
	rev.diffopt.rename_score = s->rename_score >= 0 ? s->rename_score : rev.diffopt.rename_score;
	copy_pathspec(&rev.prune_data, &s->pathspec);
	run_diff_files(&rev, s->bulk_update_index_stat ?
		       DIFF_UPDATE_INDEX_STAT : 0);
	wt_status_release_preload_changes(direct, direct_nr);
	release_revisions(&rev);
}

static int wt_status_cache_tree_matches_reference(struct wt_status *s)
{
	struct index_state *istate = s->repo->index;
	struct object_id reference_tree;
	struct strbuf reference = STRBUF_INIT;
	int matches = 0;

	if (!s->allow_clean_status_shortcuts || s->is_initial ||
	    getenv(INDEX_ENVIRONMENT) || istate->split_index ||
	    istate->sparse_index != INDEX_EXPANDED ||
	    !istate->cache_tree ||
	    istate->cache_tree->entry_count < 0 ||
	    (unsigned int)istate->cache_tree->entry_count !=
		    istate->cache_nr)
		return 0;

	/*
	 * A replacement below the root can change the effective tree without
	 * changing the root object name stored in the commit.
	 */
	if (replace_refs_enabled(s->repo)) {
		prepare_replace_object(s->repo);
		if (oidmap_get_size(&s->repo->objects->replace_map))
			return 0;
	}

	strbuf_addf(&reference, "%s^{tree}", s->reference);
	if (!repo_get_oid_tree(s->repo, reference.buf, &reference_tree) &&
	    oideq(&istate->cache_tree->oid, &reference_tree))
		matches = 1;
	strbuf_release(&reference);
	return matches;
}

static void wt_status_collect_changes_index(struct wt_status *s)
{
	struct rev_info rev;
	struct setup_revision_opt opt;

	if (wt_status_cache_tree_matches_reference(s)) {
		trace2_data_intmax("status", s->repo,
				   "index/cache-tree-match", 1);
		return;
	}

	repo_init_revisions(s->repo, &rev, NULL);
	memset(&opt, 0, sizeof(opt));
	opt.def = s->is_initial ? empty_tree_oid_hex(s->repo->hash_algo) : s->reference;
	setup_revisions(0, NULL, &rev, &opt);

	rev.diffopt.flags.override_submodule_config = 1;
	rev.diffopt.ita_invisible_in_index = 1;
	if (s->ignore_submodule_arg) {
		handle_ignore_submodules_arg(&rev.diffopt, s->ignore_submodule_arg);
	} else {
		/*
		 * Unless the user did explicitly request a submodule ignore
		 * mode by passing a command line option we do not ignore any
		 * changed submodule SHA-1s when comparing index and HEAD, no
		 * matter what is configured. Otherwise the user won't be
		 * shown any submodules manually added (and which are
		 * staged to be committed), which would be really confusing.
		 */
		handle_ignore_submodules_arg(&rev.diffopt, "dirty");
	}

	rev.diffopt.output_format |= DIFF_FORMAT_CALLBACK;
	rev.diffopt.format_callback = wt_status_collect_updated_cb;
	rev.diffopt.format_callback_data = s;
	rev.diffopt.detect_rename = s->detect_rename >= 0 ? s->detect_rename : rev.diffopt.detect_rename;
	rev.diffopt.rename_limit = s->rename_limit >= 0 ? s->rename_limit : rev.diffopt.rename_limit;
	rev.diffopt.rename_score = s->rename_score >= 0 ? s->rename_score : rev.diffopt.rename_score;

	/*
	 * The `recursive` option must be enabled to allow the diff to recurse
	 * into subdirectories of sparse directory index entries. If it is not
	 * enabled, a subdirectory containing file(s) with changes is reported
	 * as "modified", rather than the modified files themselves.
	 */
	rev.diffopt.flags.recursive = 1;

	copy_pathspec(&rev.prune_data, &s->pathspec);
	run_diff_index(&rev, DIFF_INDEX_CACHED);
	if (!s->pathspec.nr && !s->is_initial &&
	    !s->ignore_submodule_arg && !s->repo->index->split_index &&
	    s->repo->index->sparse_index == INDEX_EXPANDED && !s->change.nr) {
		s->index_tree_verified = 1;
		trace2_data_intmax("status", s->repo,
				   "index/full-tree-match", 1);
	}
	release_revisions(&rev);
}

static int add_file_to_list(const struct object_id *oid,
			    struct strbuf *base, const char *path,
			    unsigned int mode, void *context)
{
	struct string_list_item *it;
	struct wt_status_change_data *d;
	struct wt_status *s = context;
	struct strbuf full_name = STRBUF_INIT;

	if (S_ISDIR(mode))
		return READ_TREE_RECURSIVE;

	strbuf_add(&full_name, base->buf, base->len);
	strbuf_addstr(&full_name, path);
	it = string_list_insert(&s->change, full_name.buf);
	d = it->util;
	if (!d) {
		CALLOC_ARRAY(d, 1);
		it->util = d;
	}

	d->index_status = DIFF_STATUS_ADDED;
	/* Leave {mode,oid}_head zero for adds. */
	d->mode_index = mode;
	oidcpy(&d->oid_index, oid);
	s->committable = 1;
	strbuf_release(&full_name);
	return 0;
}

static void wt_status_collect_changes_initial(struct wt_status *s)
{
	struct index_state *istate = s->repo->index;
	struct strbuf base = STRBUF_INIT;
	int i;

	for (i = 0; i < istate->cache_nr; i++) {
		struct string_list_item *it;
		struct wt_status_change_data *d;
		const struct cache_entry *ce = istate->cache[i];

		if (!ce_path_match(istate, ce, &s->pathspec, NULL))
			continue;
		if (ce_intent_to_add(ce))
			continue;
		if (S_ISSPARSEDIR(ce->ce_mode)) {
			/*
			 * This is a sparse directory entry, so we want to collect all
			 * of the added files within the tree. This requires recursively
			 * expanding the trees to find the elements that are new in this
			 * tree and marking them with DIFF_STATUS_ADDED.
			 */
			struct pathspec ps = { 0 };
			struct tree *tree = lookup_tree(istate->repo, &ce->oid);

			ps.recursive = 1;
			ps.has_wildcard = 1;
			ps.max_depth = -1;

			strbuf_reset(&base);
			strbuf_add(&base, ce->name, ce->ce_namelen);
			read_tree_at(istate->repo, tree, &base, 0, &ps,
				     add_file_to_list, s);

			continue;
		}

		it = string_list_insert(&s->change, ce->name);
		d = it->util;
		if (!d) {
			CALLOC_ARRAY(d, 1);
			it->util = d;
		}
		if (ce_stage(ce)) {
			d->index_status = DIFF_STATUS_UNMERGED;
			d->stagemask |= (1 << (ce_stage(ce) - 1));
			/*
			 * Don't bother setting {mode,oid}_{head,index} since the print
			 * code will output the stage values directly and not use the
			 * values in these fields.
			 */
			s->committable = 1;
		} else {
			d->index_status = DIFF_STATUS_ADDED;
			/* Leave {mode,oid}_head zero for adds. */
			d->mode_index = ce->ce_mode;
			oidcpy(&d->oid_index, &ce->oid);
			s->committable = 1;
		}
	}

	strbuf_release(&base);
}

static unsigned int wt_status_untracked_dir_flags(const struct wt_status *s)
{
	if (s->show_untracked_files == SHOW_ALL_UNTRACKED_FILES)
		return 0;
	return DIR_SHOW_OTHER_DIRECTORIES | DIR_HIDE_EMPTY_DIRECTORIES;
}

static unsigned int wt_status_exclude_preload_flags(const struct wt_status *s)
{
	const struct untracked_cache *untracked = s->repo->index->untracked;

	if (untracked)
		return untracked->dir_flags;
	return wt_status_untracked_dir_flags(s);
}

struct wt_status_exclude_context {
	int root_fd;
};

static void wt_status_release_exclude_proof(struct wt_status *s)
{
	exclude_source_proof_release(s->certify_exclude_proof);
	s->certify_exclude_proof = NULL;
	if (s->certify_exclude_context) {
		if (s->certify_exclude_context->root_fd >= 0)
			close(s->certify_exclude_context->root_fd);
		FREE_AND_NULL(s->certify_exclude_context);
	}
	oidclr(&s->certify_exclude_digest, s->repo->hash_algo);
	s->certify_exclude_digest_valid = 0;
	s->certify_untracked_scan_failed = 0;
}

#if EXCLUDE_SOURCE_PROOF_HAS_ANCHORED_OPEN

static int wt_status_open_exclude_parent(void *data, const char *path)
{
	struct wt_status_exclude_context *context = data;
	int flags = O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_CLOEXEC |
		O_NOFOLLOW;

	if (is_absolute_path(path))
		return open(path, flags);
	return openat(context->root_fd, path, flags);
}

static void wt_status_prepare_exclude_proof(
	struct wt_status *s, struct dir_struct *dir)
{
	struct wt_status_exclude_context *context;
	const char *worktree;

	if (!s->certify_clean_status)
		return;
	if (!s->certify_exclude_proof) {
		worktree = repo_get_work_tree(s->repo);
		if (!worktree)
			return;
		CALLOC_ARRAY(context, 1);
		context->root_fd = open_nofollow(
			worktree,
			O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_CLOEXEC);
		if (context->root_fd < 0) {
			free(context);
			return;
		}
		s->certify_exclude_context = context;
		s->certify_exclude_proof = exclude_source_proof_create(
			s->repo->index, context,
			wt_status_open_exclude_parent,
			EXCLUDE_SOURCE_PROOF_NONBLOCKING);
	}
	dir->internal.exclude_source_proof =
		s->certify_exclude_proof;
}

static void wt_status_record_exclude_digest(struct wt_status *s)
{
	if (s->certify_exclude_digest_valid ||
	    !s->certify_exclude_proof)
		return;
	s->certify_exclude_digest_valid =
		!exclude_source_proof_digest(
			s->certify_exclude_proof,
			s->repo->hash_algo,
			&s->certify_exclude_digest);
}

#else

static void wt_status_prepare_exclude_proof(
	struct wt_status *s UNUSED, struct dir_struct *dir UNUSED)
{
}

static void wt_status_record_exclude_digest(struct wt_status *s UNUSED)
{
}

#endif

int wt_status_certified_excludes_digest(
	struct wt_status *s, struct object_id *digest,
	struct stat *scanned_worktree)
{
	if (s->certify_untracked_scan_failed ||
	    !s->certify_exclude_digest_valid ||
	    !s->certify_exclude_proof ||
	    !s->certify_exclude_context ||
	    s->certify_exclude_context->root_fd < 0 ||
	    !exclude_source_proof_validate(
		    s->certify_exclude_proof) ||
	    fstat(s->certify_exclude_context->root_fd,
		  scanned_worktree))
		return -1;
	oidcpy(digest, &s->certify_exclude_digest);
	return 0;
}

static int wt_status_begin_attr_snapshot(struct wt_status *s)
{
	int ret;
	int hook_provider =
		fsm_settings__get_mode(s->repo) == FSMONITOR_MODE_HOOK;

	if (s->attr_snapshot_failed)
		return -1;
	if (s->attr_source_snapshot)
		return 0;
	ret = clean_status_capture_attr_snapshot(
		s->repo->index, &s->attr_source_snapshot);
	if (ret < 0) {
		s->attr_snapshot_failed = 1;
		untracked_cache_invalidate_all(s->repo->index);
		fsmonitor_invalidate_semantics(s->repo->index);
		return -1;
	}
	if (s->attr_source_snapshot)
		git_attr_source_snapshot_begin(s->attr_source_snapshot);
	if (!s->repo->index->fsmonitor_legacy_untracked_fallback &&
	    ((ret > 0 &&
	      (!hook_provider ||
	       (ret & CLEAN_STATUS_ATTR_CONTENT_CHANGED))) ||
	     (clean_status_fsmonitor_strong_mismatch(s->repo->index) &&
	      !hook_provider))) {
		/*
		 * Hook providers have no closing query with which to adopt
		 * missing semantic history, so absence alone must preserve
		 * their established path-reporting contract. Namespace-only
		 * churn can arise from an index rewrite and is likewise not
		 * evidence that the hook missed a semantic change. Changed
		 * attribute contents are current evidence and invalidate
		 * cached semantics regardless of provider.
		 */
		untracked_cache_invalidate_all(s->repo->index);
		fsmonitor_invalidate_semantics(s->repo->index);
	}
	return ret;
}

void wt_status_start_untracked_cache_preload(struct wt_status *s)
{
	struct index_state *istate = s->repo->index;
	unsigned int dir_flags;
	int has_fsmonitor =
		fsm_settings__get_mode(s->repo) > FSMONITOR_MODE_DISABLED;
	int reopened_valid_token = 0;

	if (s->untracked_cache_preload)
		BUG("untracked-cache preload already started");
	if (!use_optional_locks())
		s->certify_clean_status = 0;
	wt_status_begin_attr_snapshot(s);
	/* Record the provider token before either filesystem traversal. */
	refresh_fsmonitor(istate);
	if (s->certify_clean_status &&
	    !fsmonitor_has_pending_token(istate))
		reopened_valid_token =
			fsmonitor_reopen_token(istate) &&
			istate->fsmonitor_untracked_valid &&
			istate->untracked && istate->untracked->root &&
			istate->untracked->use_fsmonitor &&
			!clean_status_fsmonitor_semantic_adoption_needed(istate);
	if (has_fsmonitor &&
	    (!fsmonitor_has_pending_token(istate) ||
	     reopened_valid_token ||
	     !fstat_is_reliable())) {
		s->untracked_cache_preload =
			untracked_cache_preload_start_fsmonitor_excludes(
				istate, wt_status_exclude_preload_flags(s),
				s->pathspec.nr ? &s->pathspec : NULL);
		return;
	}
	if ((s->pathspec.nr &&
	     (!istate->untracked ||
	      !istate->untracked->fsmonitor_revalidation ||
	      !fsmonitor_pending_token_from_provider(istate))) ||
	    s->show_untracked_files == SHOW_NO_UNTRACKED_FILES ||
	    s->show_ignored_mode)
		return;

	dir_flags = wt_status_untracked_dir_flags(s);

	if (s->show_untracked_files == SHOW_NORMAL_UNTRACKED_FILES &&
	    !istate->untracked &&
	    istate->sparse_index == INDEX_EXPANDED)
		istate->preload_untracked = &s->untracked;
	/* Restore verified stats before cached excludes inspect them. */
	if (fstat_is_reliable() && !istate->split_index &&
	    fsm_settings__get_mode(s->repo) == FSMONITOR_MODE_IPC &&
	    fsmonitor_pending_token_from_provider(istate) &&
	    clean_status_fsmonitor_semantic_adoption_needed(istate) &&
	    istate->untracked && istate->untracked->root) {
		trace2_data_intmax("status", s->repo,
				   "fsmonitor_token/untracked-deferred", 1);
		return;
	}
	if (has_fsmonitor &&
	    (!istate->untracked ||
	     !istate->untracked->fsmonitor_revalidation ||
	     istate->untracked->use_fsmonitor ||
	     !fsmonitor_pending_token_from_provider(istate)))
		return;

	s->untracked_cache_preload =
		untracked_cache_preload_start_ordinary(istate, dir_flags);
	if (s->untracked_cache_preload &&
	    istate->untracked->fsmonitor_revalidation) {
		trace2_data_intmax("status", s->repo,
				   "untracked/provider-reset-preload", 1);
		if (s->pathspec.nr)
			trace2_data_intmax("status", s->repo,
					   "untracked/provider-reset-scoped-preload", 1);
	}
}

static void wt_status_finish_untracked_cache_preload(struct wt_status *s)
{
	struct index_state *istate = s->repo->index;
	size_t index_invalidated = 0;

	if (!s->untracked_cache_preload)
		return;
	s->untracked_cache_preloaded = untracked_cache_preload_finish(
		s->untracked_cache_preload, istate,
		wt_status_exclude_preload_flags(s), &index_invalidated);
	s->untracked_cache_preload = NULL;
	if (!index_invalidated)
		return;

	s->tracked_from_fsmonitor = 0;
	preload_index_bulk_result_clear(istate);
	trace2_data_intmax("status", s->repo,
			   "fsmonitor/exclude-index-invalidated",
			   index_invalidated);
}

static struct untracked_cache_dir *wt_status_find_cached_directory(
	struct untracked_cache_dir *root,
	const char *path,
	size_t len)
{
	struct untracked_cache_dir *dir = root;
	const char *end = path + len;

	while (path < end) {
		const char *slash = memchr(path, '/', end - path);
		size_t component_len = slash ? slash - path : end - path;
		struct untracked_cache_dir *child = NULL;
		size_t first = 0, last = dir->dirs_nr;

		if (!component_len) {
			path++;
			continue;
		}
		while (last > first) {
			size_t next = first + ((last - first) >> 1);
			struct untracked_cache_dir *candidate = dir->dirs[next];
			int compare = strncmp(path, candidate->name,
					      component_len);

			if (!compare && candidate->name[component_len])
				compare = -1;
			if (!compare) {
				child = candidate;
				break;
			}
			if (compare < 0)
				last = next;
			else
				first = next + 1;
		}
		if (!child || !child->recurse || child->check_only)
			return NULL;
		dir = child;
		path += component_len;
		if (path < end)
			path++;
	}
	return dir;
}

static void wt_status_collect_cached_directory(
	const struct untracked_cache_dir *dir,
	struct strbuf *path,
	struct index_state *istate,
	const struct pathspec *pathspec,
	struct string_list *untracked)
{
	size_t base_len = path->len;

	if (!dir->has_untracked)
		return;
	for (size_t i = 0; i < dir->untracked_nr; i++) {
		const char *name = dir->untracked[i];

		strbuf_setlen(path, base_len);
		strbuf_addstr(path, name);
		if (index_name_is_other(istate, path->buf, path->len) &&
		    match_pathspec(istate, pathspec,
				   path->buf, path->len, 0, NULL,
				   path->len && path->buf[path->len - 1] == '/'))
			string_list_append(untracked, path->buf);
	}
	for (size_t i = 0; i < dir->dirs_nr; i++) {
		const struct untracked_cache_dir *child = dir->dirs[i];

		if (!child->recurse || child->check_only ||
		    !child->has_untracked)
			continue;
		strbuf_setlen(path, base_len);
		strbuf_addstr(path, child->name);
		strbuf_addch(path, '/');
		wt_status_collect_cached_directory(
			child, path, istate, pathspec, untracked);
	}
	strbuf_setlen(path, base_len);
}

static int wt_status_index_directory_pos(
	struct index_state *istate, const char *path, size_t len, int first)
{
	int last = istate->cache_nr;

	if (first < last &&
	    ce_namelen(istate->cache[first]) == len &&
	    !memcmp(istate->cache[first]->name, path, len))
		return -1;

	while (last > first) {
		int next = first + ((last - first) >> 1);
		const struct cache_entry *ce = istate->cache[next];
		int compare = strncmp(ce->name, path, len);

		if (!compare)
			compare = (unsigned char)ce->name[len] - '/';
		if (compare < 0)
			first = next + 1;
		else
			last = next;
	}
	return first;
}

static int wt_status_pathspec_matches_clean_tracked_entries(
	struct wt_status *s, int validate_entries)
{
	struct index_state *istate = s->repo->index;
	int i, positive = 0;

	if ((!validate_entries && !s->tracked_from_fsmonitor) ||
	    !s->pathspec.nr ||
	    istate->sparse_index != INDEX_EXPANDED ||
	    fsmonitor_has_pending_token(istate) ||
	    fsm_settings__get_mode(s->repo) != FSMONITOR_MODE_IPC)
		return 0;

	for (i = 0; i < s->pathspec.nr; i++) {
		const struct pathspec_item *item = &s->pathspec.items[i];
		const struct cache_entry *ce;
		size_t len = item->len;
		int pos, subtree = 0, selected = 0, trailing = 0, wildcard = 0;

		if (item->magic & PATHSPEC_EXCLUDE)
			continue;
		positive = 1;
		if ((item->magic & ~(PATHSPEC_FROMTOP | PATHSPEC_LITERAL |
				     PATHSPEC_GLOB)) || !len)
			return 0;
		if (item->nowildcard_len != item->len) {
			if (!validate_entries ||
			    (s->pathspec.magic & PATHSPEC_ATTR))
				return 0;
			len = item->nowildcard_len;
			if (!len)
				return 0;
			wildcard = 1;
		}
		if (!wildcard && item->match[len - 1] == '/') {
			trailing = 1;
			while (len && item->match[len - 1] == '/')
				len--;
			if (!len)
				return 0;
		}
		pos = index_name_pos(istate, item->match, len);
		if (pos >= 0 && trailing && memchr(item->match, '/', len) &&
		    !validate_entries)
			return 0;
		if (pos < 0) {
			if (!validate_entries)
				return 0;
			pos = -pos - 1;
			if (!wildcard) {
				pos = wt_status_index_directory_pos(
					istate, item->match, len, pos);
				if (pos < 0)
					return 0;
			}
			subtree = 1;
		}
		if (wildcard)
			subtree = 1;
		for (; pos < istate->cache_nr; pos++) {
			ce = istate->cache[pos];
			if (subtree &&
			    (ce_namelen(ce) < len ||
			     strncmp(ce->name, item->match, len) ||
			     (!wildcard && (ce_namelen(ce) == len ||
					    ce->name[len] != '/'))))
				break;
			if (((subtree &&
			      (wildcard || (s->pathspec.magic & PATHSPEC_EXCLUDE))) ||
			     (validate_entries && trailing)) &&
			    !(s->pathspec.magic & PATHSPEC_ATTR) &&
			    !ce_path_match(istate, ce, &s->pathspec, NULL)) {
				selected = 1;
				if (!subtree)
					break;
				continue;
			}
			if (S_ISGITLINK(ce->ce_mode) &&
			    s->ignore_submodule_arg &&
			    !strcmp(s->ignore_submodule_arg, "all")) {
				if (validate_entries &&
				    (ce->ce_flags & ~(CE_UPTODATE | CE_HASHED |
						      CE_FSMONITOR_VALID |
						      CE_UPDATE_IN_BASE)))
					return 0;
				selected = 1;
				if (!subtree)
					break;
				continue;
			}
			if ((!S_ISREG(ce->ce_mode) && !S_ISLNK(ce->ce_mode)) ||
			    (validate_entries &&
			     (!(ce->ce_flags & CE_FSMONITOR_VALID) ||
			      (ce->ce_flags & ~(CE_UPTODATE | CE_HASHED |
					CE_FSMONITOR_VALID |
					CE_UPDATE_IN_BASE)))))
				return 0;
			selected = 1;
			if (!subtree)
				break;
		}
		if (!selected && !validate_entries)
			return 0;
	}
	return positive;
}

static int wt_status_ignored_submodules_are_clean(struct wt_status *s)
{
	const struct index_state *istate = s->repo->index;
	const unsigned int supported_flags =
		CE_UPTODATE | CE_HASHED | CE_FSMONITOR_VALID |
		CE_UPDATE_IN_BASE;

	if (s->pathspec.nr || !s->ignore_submodule_arg ||
	    strcmp(s->ignore_submodule_arg, "all"))
		return 0;

	for (size_t i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];

		if ((ce->ce_flags & ~supported_flags) ||
		    (!S_ISGITLINK(ce->ce_mode) &&
		     (!(ce->ce_flags & CE_FSMONITOR_VALID) ||
		      (!S_ISREG(ce->ce_mode) && !S_ISLNK(ce->ce_mode)))))
			return 0;
	}
	return 1;
}

static int wt_status_collect_cached_pathspec(
	struct wt_status *s,
	struct dir_struct *dir,
	struct string_list *untracked)
{
	struct index_state *istate = s->repo->index;
	struct untracked_cache *uc = istate->untracked;
	const struct pathspec_item *item;
	const struct cache_entry *ce;
	struct untracked_cache_dir *selected;
	struct strbuf path = STRBUF_INIT;
	size_t len;
	int pos;

	if (!s->pathspec.nr || s->pathspec.has_wildcard ||
	    (s->pathspec.magic & ~(PATHSPEC_FROMTOP | PATHSPEC_LITERAL)) ||
	    s->show_ignored_mode ||
	    s->show_untracked_files != SHOW_NORMAL_UNTRACKED_FILES ||
	    istate->sparse_index != INDEX_EXPANDED ||
	    !istate->fsmonitor_untracked_valid ||
	    fsmonitor_has_pending_token(istate) ||
	    fsm_settings__get_mode(s->repo) != FSMONITOR_MODE_IPC ||
	    !uc || !uc->root || !uc->use_fsmonitor ||
	    dir->untracked != uc || dir->flags != uc->dir_flags ||
	    dir->internal.unmanaged_exclude_files ||
	    dir->internal.exclude_list_group[EXC_CMDL].nr ||
	    !oideq(&dir->internal.ss_info_exclude.oid,
		   &uc->ss_info_exclude.oid) ||
	    !oideq(&dir->internal.ss_excludes_file.oid,
		   &uc->ss_excludes_file.oid))
		return 0;

	if (wt_status_pathspec_matches_clean_tracked_entries(s, 0)) {
		trace2_data_intmax("status", s->repo,
				   "untracked/pathspec-cache", 1);
		return 1;
	}
	if (s->pathspec.nr != 1)
		return 0;

	item = &s->pathspec.items[0];
	if (item->nowildcard_len != item->len)
		return 0;
	len = item->len;
	if (len && item->match[len - 1] == '/')
		len--;
	if (!len)
		return 0;

	pos = index_name_pos(istate, item->match, len);
	if (pos >= 0)
		return 0;
	pos = wt_status_index_directory_pos(
		istate, item->match, len, -pos - 1);
	if (pos < 0)
		return 0;
	if (pos >= istate->cache_nr)
		return 0;
	ce = istate->cache[pos];
	if (ce_namelen(ce) <= len || ce->name[len] != '/' ||
	    strncmp(ce->name, item->match, len))
		return 0;

	selected = wt_status_find_cached_directory(
		uc->root, item->match, len);
	if (!selected)
		return 0;

	strbuf_add(&path, item->match, len);
	strbuf_addch(&path, '/');
	if (!uc->root->valid || !selected->valid ||
	    !selected->valid_recursive) {
		if (read_directory_cached_subtree(
			    dir, istate, selected, path.buf, path.len,
			    &s->pathspec) < 0) {
			strbuf_release(&path);
			return 0;
		}
		trace2_data_intmax("status", s->repo,
				   "untracked/pathspec-refreshed", 1);
	}
	wt_status_collect_cached_directory(
		selected, &path, istate, &s->pathspec, untracked);
	strbuf_release(&path);
	trace2_data_intmax("status", s->repo,
			   "untracked/pathspec-cache", 1);
	return 1;
}

static void wt_status_materialize_deferred_untracked(
	struct index_state *istate)
{
	const char *path, *end;

	if (!istate->untracked ||
	    !istate->untracked->fsmonitor_dirty_paths.len)
		return;
	path = istate->untracked->fsmonitor_dirty_paths.buf;
	end = path + istate->untracked->fsmonitor_dirty_paths.len;

	/* Deferred provider paths are not saved with the cache. */
	while (path < end) {
		size_t len = strlen(path) + 1;

		untracked_cache_invalidate_path(istate, path, 1);
		path += len;
	}
	istate->cache_changed |= UNTRACKED_CHANGED;
	istate->fsmonitor_untracked_must_persist = 1;
}

static int wt_status_collect_untracked_1(
	struct wt_status *s,
	struct string_list *untracked,
	struct string_list *ignored)
{
	int i;
	int used_untracked_cache;
	struct dir_struct dir = DIR_INIT;
	uint64_t t_begin = getnanotime();
	struct index_state *istate = s->repo->index;

	if (!s->show_untracked_files) {
		wt_status_materialize_deferred_untracked(istate);
		return 0;
	}

	if (s->show_untracked_files != SHOW_ALL_UNTRACKED_FILES)
		dir.flags |= wt_status_untracked_dir_flags(s);
	if (s->show_ignored_mode) {
		dir.flags |= DIR_SHOW_IGNORED_TOO;

		if (s->show_ignored_mode == SHOW_MATCHING_IGNORED)
			dir.flags |= DIR_SHOW_IGNORED_TOO_MODE_MATCHING;
	} else {
		dir.untracked = istate->untracked;
	}

	wt_status_prepare_exclude_proof(s, &dir);
	setup_standard_excludes(&dir);
	wt_status_record_exclude_digest(s);
	wt_status_finish_untracked_cache_preload(s);
	dir.internal.untracked_cache_preloaded =
		s->untracked_cache_preloaded;

	if (wt_status_collect_cached_pathspec(s, &dir, untracked)) {
		used_untracked_cache = 1;
	} else if (wt_status_pathspec_matches_clean_tracked_entries(s, 0)) {
		trace2_data_intmax("status", s->repo,
				   "untracked/pathspec-cache", 1);
		used_untracked_cache = 0;
	} else {
		fill_directory(&dir, istate, &s->pathspec);
		if (s->certify_clean_status && dir.internal.traversal_failed)
			s->certify_untracked_scan_failed = 1;
		used_untracked_cache = dir.untracked &&
			dir.untracked == istate->untracked;

		for (i = 0; i < dir.nr; i++) {
			struct dir_entry *ent = dir.entries[i];
			if (index_name_is_other(istate, ent->name, ent->len))
				string_list_append(untracked, ent->name);
		}
	}
	string_list_sort_u(untracked, 0);
	if (!s->pathspec.nr && used_untracked_cache && dir.nr &&
	    dir.untracked->dir_opened && !dir.internal.traversal_failed &&
	    !clean_status_external_history_was_restored(istate) &&
	    (istate->cache_changed & UNTRACKED_CHANGED))
		istate->fsmonitor_untracked_must_persist = 1;

	for (i = 0; i < dir.ignored_nr; i++) {
		struct dir_entry *ent = dir.ignored[i];
		if (index_name_is_other(istate, ent->name, ent->len))
			string_list_append(ignored, ent->name);
	}
	string_list_sort_u(ignored, 0);

	dir_clear(&dir);
	if (!used_untracked_cache)
		wt_status_materialize_deferred_untracked(istate);

	if (advice_enabled(ADVICE_STATUS_U_OPTION))
		s->untracked_in_ms = (getnanotime() - t_begin) / 1000000;
	if (used_untracked_cache)
		fsmonitor_mark_untracked_cache_valid(istate);
	return used_untracked_cache;
}

static int wt_status_can_use_bulk_provider(
	struct wt_status *s, unsigned int refresh_flags)
{
	return !s->show_ignored_mode && !s->pathspec.nr &&
		!s->repo->index->fsmonitor_legacy_untracked_fallback &&
		!clean_status_filter_scope_needs_validation(s->repo->index) &&
		(refresh_flags & REFRESH_DEFER_BULK_DIRTY) &&
		preload_index_bulk_can_close_provider(s->repo->index);
}

static struct semantic_verify_proof *wt_status_prepare_semantic_verify(
	struct wt_status *s, unsigned int refresh_flags)
{
	struct index_state *istate = s->repo->index;
	struct semantic_verify_options options = SEMANTIC_VERIFY_OPTIONS_INIT;
	struct semantic_verify_proof *proof = NULL;
	int ret;

	if (!fstat_is_reliable() || istate->split_index ||
	    istate->fsmonitor_legacy_untracked_fallback ||
	    s->show_ignored_mode ||
	    fsm_settings__get_mode(s->repo) != FSMONITOR_MODE_IPC ||
	    istate->sparse_index != INDEX_EXPANDED ||
	    !fsmonitor_has_pending_token(istate) ||
	    !fsmonitor_pending_token_from_provider(istate) ||
	    !clean_status_fsmonitor_semantic_adoption_needed(istate))
		return NULL;
	if (wt_status_can_use_bulk_provider(s, refresh_flags)) {
		trace2_data_intmax("status", s->repo,
				   "semantic_verify/bulk_scan", 1);
		return NULL;
	}

	options.require_proof_epoch = 1;
	options.validate_filter_scope =
		clean_status_filter_scope_needs_validation(istate);
	options.attr_snapshot = s->attr_source_snapshot;
	trace2_region_enter("status", "semantic_verify", s->repo);
	ret = semantic_verify_prepare(istate, &options, &proof);
	trace2_data_intmax("status", s->repo,
			   "semantic_verify/prepared", !ret);
	trace2_region_leave("status", "semantic_verify", s->repo);
	if (ret) {
		semantic_verify_proof_clear(proof);
		return NULL;
	}
	return proof;
}

static int wt_status_collect_untracked(struct wt_status *s)
{
	if (s->untracked_from_token_closure && !s->show_ignored_mode)
		return 1;
	if (s->untracked_from_preload && !s->show_ignored_mode)
		return 0;
	return wt_status_collect_untracked_1(
		s, &s->untracked, &s->ignored);
}

#define FSMONITOR_TOKEN_MAX_QUERIES 3

struct wt_status_token_closure {
	struct wt_status *status;
	unsigned int refresh_flags;
	int require_untracked;
	int can_prime;
	int use_bulk_provider;
	int untracked_ready;
	int untracked_proof_complete;
	struct string_list staged_untracked;
	struct string_list staged_ignored;
	int staged_untracked_ready;
	int staged_output_matches_status;
	int refresh_result;
	int queries;
};

static void wt_status_discard_staged_untracked(
	struct wt_status_token_closure *closure)
{
	string_list_clear(&closure->staged_untracked, 0);
	string_list_clear(&closure->staged_ignored, 0);
	closure->staged_untracked_ready = 0;
}

static int wt_status_stage_untracked(
	struct wt_status_token_closure *closure)
{
	struct wt_status *s = closure->status;
	struct index_state *istate = s->repo->index;
	struct pathspec pathspec = s->pathspec;
	enum untracked_status_type requested_untracked =
		s->show_untracked_files;
	int prime_configured_cache =
		requested_untracked == SHOW_ALL_UNTRACKED_FILES &&
		istate->untracked && !s->untracked_cache_preload &&
		istate->untracked->dir_flags ==
			(DIR_SHOW_OTHER_DIRECTORIES | DIR_HIDE_EMPTY_DIRECTORIES);

	wt_status_discard_staged_untracked(closure);
	closure->staged_output_matches_status = !prime_configured_cache;
	/* A provider token can certify only a complete untracked traversal. */
	if (pathspec.nr)
		memset(&s->pathspec, 0, sizeof(s->pathspec));
	if (prime_configured_cache)
		s->show_untracked_files = SHOW_NORMAL_UNTRACKED_FILES;
	closure->staged_untracked_ready =
		wt_status_collect_untracked_1(
			s,
			&closure->staged_untracked,
			&closure->staged_ignored) ||
		(!istate->untracked &&
		 !s->certify_untracked_scan_failed);
	s->show_untracked_files = requested_untracked;
	if (prime_configured_cache) {
		string_list_clear(&closure->staged_untracked, 0);
		string_list_clear(&closure->staged_ignored, 0);
	}
	if (closure->staged_untracked_ready &&
	    istate->preload_untracked == &s->untracked) {
		if (closure->staged_untracked.nr ||
		    !closure->use_bulk_provider)
			istate->preload_untracked = NULL;
		else
			wt_status_discard_staged_untracked(closure);
	}
	if (pathspec.nr) {
		s->pathspec = pathspec;
		/* The ordinary scoped traversal supplies the displayed results. */
		string_list_clear(&closure->staged_untracked, 0);
		string_list_clear(&closure->staged_ignored, 0);
	}
	if (!closure->staged_untracked_ready)
		wt_status_discard_staged_untracked(closure);
	return closure->staged_untracked_ready;
}

static void wt_status_publish_staged_untracked(
	struct wt_status_token_closure *closure)
{
	struct wt_status *s = closure->status;

	if (!closure->staged_untracked_ready ||
	    !closure->staged_output_matches_status || s->pathspec.nr)
		return;
	if (s->untracked.nr || s->ignored.nr)
		BUG("publishing untracked results over collected status");
	SWAP(s->untracked, closure->staged_untracked);
	SWAP(s->ignored, closure->staged_ignored);
	s->untracked_from_token_closure = 1;
	closure->staged_untracked_ready = 0;
}

static int wt_status_untracked_cache_valid(
	const struct wt_status_token_closure *closure)
{
	const struct index_state *istate = closure->status->repo->index;

	return closure->untracked_ready &&
		istate->untracked && istate->untracked->root;
}

static void wt_status_record_bulk_untracked(
	struct wt_status_token_closure *closure)
{
	if (closure->status->repo->index->preload_untracked_complete)
		closure->untracked_proof_complete = 1;
}

static int fsmonitor_token_requires_rescan(enum fsmonitor_token_result result)
{
	return result == FSMONITOR_TOKEN_CHANGED ||
		result == FSMONITOR_TOKEN_TRIVIAL;
}

static void wt_status_release_attr_snapshot(struct wt_status *s);

static int wt_status_attr_snapshot_matches(struct wt_status *s)
{
	if (s->attr_snapshot_failed)
		return 0;
	return !s->attr_source_snapshot ||
		attr_source_snapshot_matches_repository(
			s->repo, s->attr_source_snapshot);
}

static int wt_status_refresh_invalidated_manifest(struct wt_status *s)
{
	if (!clean_status_worktree_manifest_needs_refresh(s->repo->index))
		return 0;
	return clean_status_refresh_worktree_manifest(s->repo->index) < 0 ?
		-1 : 0;
}

static void wt_status_reset_attr_snapshot_if_changed(struct wt_status *s)
{
	if (wt_status_attr_snapshot_matches(s))
		return;
	wt_status_release_attr_snapshot(s);
	wt_status_begin_attr_snapshot(s);
	trace2_data_intmax("status", s->repo,
			   "semantic/attribute-epoch-rejected", 1);
}

static void wt_status_discard_semantic_verify(
	struct wt_status *s, struct semantic_verify_proof **proof,
	const char *reason)
{
	if (!*proof)
		return;
	trace2_data_string("status", s->repo, "semantic_verify/discard",
			   reason);
	semantic_verify_proof_clear(*proof);
	*proof = NULL;
	git_attr_invalidate_all();
}

static void wt_status_refresh_for_token(
	struct wt_status *s, unsigned int refresh_flags,
	struct clean_status_proof_epoch **epoch, int use_bulk_provider,
	int *refresh_result)
{
	struct index_state *istate = s->repo->index;

	if (!*epoch)
		*epoch = clean_status_capture_proof_epoch(
			istate, s->attr_source_snapshot, 0);
	if (*epoch && use_bulk_provider)
		istate->preload_bulk_proof_epoch = *epoch;
	if (*epoch) {
		*refresh_result |= refresh_index(
			istate, refresh_flags | REFRESH_IN_PROOF_EPOCH,
			&s->pathspec, NULL, NULL);
	}
	istate->preload_bulk_proof_epoch = NULL;
}

static int wt_status_close_ordinary_fsmonitor_token(
	struct wt_status_token_closure *closure,
	int refreshed_before_closure)
{
	struct wt_status *s = closure->status;
	struct index_state *istate = s->repo->index;
	struct clean_status_proof_epoch *scan_epoch = NULL;
	int reliable_stat = fstat_is_reliable();
	int validate_epoch = reliable_stat &&
		!istate->fsmonitor_legacy_untracked_fallback;

	/*
	 * A pending token must close a refresh begun after its epoch was
	 * captured. A refresh performed before entering token closure cannot
	 * be validated by capturing its inputs afterward.
	 */
	if (validate_epoch) {
		if (s->allow_clean_status_shortcuts &&
		    s->certify_clean_status &&
		    closure->can_prime &&
		    !s->untracked_cache_preload &&
		    !getenv(INDEX_ENVIRONMENT) &&
		    !istate->split_index &&
		    istate->sparse_index == INDEX_EXPANDED &&
		    istate->fsmonitor_token_valid &&
		    clean_status_revalidated_token_matches(istate) &&
		    !clean_status_manifest_global_fallback(istate) &&
		    !clean_status_worktree_manifest_needs_refresh(istate) &&
		    clean_status_index_entries_are_certifiable(istate) &&
		    (scan_epoch = clean_status_capture_proof_epoch(
			istate, s->attr_source_snapshot, 0)) &&
		    wt_status_stage_untracked(closure) &&
		    closure->staged_untracked.nr &&
		    !clean_status_worktree_manifest_needs_refresh(istate)) {
			s->tracked_from_fsmonitor = 1;
			closure->untracked_ready = 1;
			closure->untracked_proof_complete = 1;
		} else {
			if (closure->staged_untracked_ready) {
				closure->untracked_ready = 1;
				closure->untracked_proof_complete = 1;
			}
			wt_status_refresh_for_token(
				s, closure->refresh_flags, &scan_epoch,
				closure->use_bulk_provider,
				&closure->refresh_result);
		}
		if (!scan_epoch)
			return 0;
	} else if (!refreshed_before_closure ||
		   istate->fsmonitor_legacy_untracked_fallback) {
		closure->refresh_result |= refresh_index(
			istate, closure->refresh_flags, &s->pathspec,
			NULL, NULL);
	}
	wt_status_record_bulk_untracked(closure);
	if (!closure->untracked_proof_complete && closure->can_prime) {
		closure->untracked_ready =
			wt_status_stage_untracked(closure);
		closure->untracked_proof_complete =
			closure->untracked_ready;
		if (closure->queries)
			trace2_data_intmax(
				"status", s->repo,
				"fsmonitor_token/untracked-after-retry",
				closure->untracked_ready);
	}

	while (closure->queries < FSMONITOR_TOKEN_MAX_QUERIES) {
		enum fsmonitor_token_result result;

		if (validate_epoch &&
		    !clean_status_proof_epoch_start_token_matches(
			    istate, scan_epoch))
			break;
		closure->queries++;
		result = fsmonitor_query_pending_token(
			istate,
			wt_status_untracked_cache_valid(closure));
		if (result == FSMONITOR_TOKEN_CLEAN) {
			if (validate_epoch &&
			    !clean_status_proof_epoch_matches(
				    istate, scan_epoch)) {
				wt_status_reset_attr_snapshot_if_changed(s);
				break;
			}
			if (closure->untracked_proof_complete ||
			    !closure->require_untracked) {
				if (preload_index_bulk_result_accept(istate) < 0)
					break;
				if (validate_epoch)
					clean_status_mark_fsmonitor_config_valid(
						istate,
						istate->fsmonitor_last_update_pending);
				clean_status_release_proof_epoch(scan_epoch);
				fsmonitor_accept_pending_token(
					istate,
					closure->untracked_proof_complete,
					wt_status_untracked_cache_valid(
						closure));
				if (s->tracked_from_fsmonitor) {
					s->certify_clean_status = 0;
					trace2_data_intmax("status", s->repo,
							   "fsmonitor/tracked-clean", 1);
				}
				return 1;
			}
			break;
		}
		s->tracked_from_fsmonitor = 0;
		wt_status_discard_staged_untracked(closure);
		closure->untracked_proof_complete =
			!closure->require_untracked ||
			(!istate->untracked && !closure->can_prime);
		clean_status_release_proof_epoch(scan_epoch);
		scan_epoch = NULL;
		if (!fsmonitor_token_requires_rescan(result))
			break;

		/* Rescan invalidations returned by the closure query. */
		wt_status_reset_attr_snapshot_if_changed(s);
		if (wt_status_refresh_invalidated_manifest(s))
			break;
		if (validate_epoch) {
			wt_status_refresh_for_token(
				s, closure->refresh_flags, &scan_epoch,
				closure->use_bulk_provider,
				&closure->refresh_result);
			if (!scan_epoch)
				break;
		} else {
			closure->refresh_result |= refresh_index(
				istate, closure->refresh_flags,
				&s->pathspec, NULL, NULL);
		}
		wt_status_record_bulk_untracked(closure);
		if (!closure->untracked_proof_complete &&
		    closure->can_prime) {
			closure->untracked_ready =
				wt_status_stage_untracked(closure);
			closure->untracked_proof_complete =
				closure->untracked_ready;
		}
	}
	clean_status_release_proof_epoch(scan_epoch);
	return 0;
}

enum wt_status_token_closure_result {
	WT_STATUS_TOKEN_CLOSURE_FALLBACK = -1,
	WT_STATUS_TOKEN_CLOSURE_RETRY,
	WT_STATUS_TOKEN_CLOSURE_ACCEPTED,
};

static enum wt_status_token_closure_result
wt_status_close_semantic_fsmonitor_token(
	struct wt_status_token_closure *closure,
	struct semantic_verify_proof **proof)
{
	struct wt_status *s = closure->status;
	struct index_state *istate = s->repo->index;
	enum fsmonitor_token_result result;
	int defer_untracked =
		closure->can_prime &&
		!closure->untracked_proof_complete;
	int applied;

	if (!semantic_verify_start_token_is_current(istate, *proof)) {
		wt_status_discard_semantic_verify(
			s, proof, "start-token-drift");
		return WT_STATUS_TOKEN_CLOSURE_FALLBACK;
	}

	/* The first query closes the tracked scan and its semantic proof. */
	closure->queries++;
	result = fsmonitor_query_pending_token(
		istate, defer_untracked ? 0 :
		wt_status_untracked_cache_valid(closure));
	if (result != FSMONITOR_TOKEN_CLEAN) {
		wt_status_discard_semantic_verify(
			s, proof, "token-reset");
		if (fsmonitor_token_requires_rescan(result))
			return WT_STATUS_TOKEN_CLOSURE_RETRY;
		return WT_STATUS_TOKEN_CLOSURE_FALLBACK;
	}

	applied = semantic_verify_apply_after_closure(istate, *proof);
	if (applied < 0) {
		wt_status_reset_attr_snapshot_if_changed(s);
		wt_status_discard_semantic_verify(
			s, proof, "closure-drift");
		return WT_STATUS_TOKEN_CLOSURE_FALLBACK;
	}
	closure->refresh_result |= refresh_index(
		istate, closure->refresh_flags, &s->pathspec, NULL, NULL);
	trace2_data_intmax("status", s->repo,
			   "fsmonitor_token/semantic-closed", 1);
	if (!semantic_verify_proof_is_current(istate, *proof)) {
		wt_status_reset_attr_snapshot_if_changed(s);
		wt_status_discard_semantic_verify(
			s, proof, "closure-drift");
		return WT_STATUS_TOKEN_CLOSURE_FALLBACK;
	}

	if (defer_untracked) {
		int directory_delta_reused;

		closure->untracked_ready =
			wt_status_stage_untracked(closure);
		closure->untracked_proof_complete =
			closure->untracked_ready;
		trace2_data_intmax(
			"status", s->repo,
			"fsmonitor_token/untracked-after-semantic",
			closure->untracked_ready);
		if (!closure->untracked_ready ||
		    closure->queries >= FSMONITOR_TOKEN_MAX_QUERIES)
			return WT_STATUS_TOKEN_CLOSURE_FALLBACK;

		/* A second query closes the subsequent untracked scan. */
		closure->queries++;
		clean_status_manifest_begin_directory_delta(istate, *proof);
		result = fsmonitor_query_pending_token(
			istate,
			wt_status_untracked_cache_valid(closure));
		directory_delta_reused =
			clean_status_manifest_end_directory_delta(istate);
		if (result != FSMONITOR_TOKEN_CLEAN) {
			/* Only directory reuse adds an unobserved exclude risk. */
			int reuse_semantic_subtrees =
				result == FSMONITOR_TOKEN_CHANGED &&
				!clean_status_filter_scope_needs_validation(istate) &&
				!clean_status_worktree_manifest_needs_refresh(istate) &&
				semantic_verify_proof_is_current(istate, *proof) &&
				(!directory_delta_reused ||
				 (s->certify_exclude_proof &&
				  exclude_source_proof_validate(
					  s->certify_exclude_proof)));

			wt_status_discard_staged_untracked(closure);
			if (reuse_semantic_subtrees) {
				/* Recompute scanned subtrees after the localized delta. */
				untracked_cache_recompute_fsmonitor_valid_recursive(
					istate->untracked);
				trace2_data_intmax(
					"status", s->repo,
					"fsmonitor_token/reused-semantic-subtrees", 1);
			} else {
				untracked_cache_invalidate_all(istate);
				fsmonitor_invalidate_semantics(istate);
			}
			closure->untracked_ready = 0;
			closure->untracked_proof_complete = 0;
			wt_status_discard_semantic_verify(
				s, proof, "token-reset");
			if (fsmonitor_token_requires_rescan(result))
				return WT_STATUS_TOKEN_CLOSURE_RETRY;
			return WT_STATUS_TOKEN_CLOSURE_FALLBACK;
		}
		if (!semantic_verify_proof_is_current(istate, *proof)) {
			wt_status_reset_attr_snapshot_if_changed(s);
			wt_status_discard_semantic_verify(
				s, proof, "closure-drift");
			return WT_STATUS_TOKEN_CLOSURE_FALLBACK;
		}
	}
	if (semantic_verify_accept_filter_scope(istate, *proof) < 0) {
		wt_status_discard_semantic_verify(
			s, proof, "filter-scope-drift");
		return WT_STATUS_TOKEN_CLOSURE_FALLBACK;
	}

	clean_status_mark_fsmonitor_config_valid(
		istate, istate->fsmonitor_last_update_pending);
	semantic_verify_proof_clear(*proof);
	*proof = NULL;
	fsmonitor_accept_pending_token(
		istate, closure->untracked_proof_complete,
		wt_status_untracked_cache_valid(closure));
	return WT_STATUS_TOKEN_CLOSURE_ACCEPTED;
}

static int wt_status_tracked_fsmonitor_state_is_current(
	struct wt_status *s)
{
	struct index_state *istate = s->repo->index;

	return s->allow_clean_status_shortcuts &&
		!s->certify_clean_status &&
		!getenv(INDEX_ENVIRONMENT) && !istate->split_index &&
		istate->sparse_index == INDEX_EXPANDED &&
		fsm_settings__get_mode(s->repo) == FSMONITOR_MODE_IPC &&
		is_fsmonitor_refreshed(istate) &&
		!fsmonitor_has_pending_token(istate) &&
		istate->fsmonitor_token_valid &&
		istate->fsmonitor_last_update &&
		*istate->fsmonitor_last_update &&
		clean_status_revalidated_token_matches(istate) &&
		!clean_status_manifest_global_fallback(istate) &&
		!clean_status_worktree_manifest_needs_refresh(istate);
}

static int wt_status_close_fsmonitor_token(
	struct wt_status *s, struct semantic_verify_proof *proof,
	unsigned int refresh_flags, int require_untracked,
	int refreshed_before_closure)
{
	struct index_state *istate = s->repo->index;
	struct wt_status_token_closure closure = {
		.status = s,
		.refresh_flags = refresh_flags,
		.require_untracked = require_untracked,
		.staged_untracked = STRING_LIST_INIT_DUP,
		.staged_ignored = STRING_LIST_INIT_DUP,
	};
	enum wt_status_token_closure_result result;
	int preserve_untracked, token_accepted = 0;

	refresh_fsmonitor(istate);
	preserve_untracked = !require_untracked &&
		s->show_untracked_files == SHOW_NO_UNTRACKED_FILES &&
		!s->show_ignored_mode && !s->pathspec.nr &&
		fstat_is_reliable() && !getenv(INDEX_ENVIRONMENT) &&
		istate == istate->repo->index && !istate->split_index &&
		istate->sparse_index == INDEX_EXPANDED &&
		fsm_settings__get_mode(s->repo) == FSMONITOR_MODE_IPC &&
		istate->fsmonitor_untracked_extension_seen &&
		!istate->fsmonitor_untracked_extension_invalid &&
		istate->untracked && istate->untracked->root &&
		istate->untracked->root->valid &&
		istate->untracked->fsmonitor_revalidation;
	if (!fsmonitor_has_pending_token(istate) ||
	    fsm_settings__get_mode(s->repo) != FSMONITOR_MODE_IPC) {
		int attr_inputs_match =
			wt_status_attr_snapshot_matches(s) &&
			!clean_status_worktree_manifest_needs_refresh(istate);

		wt_status_discard_semantic_verify(
			s, &proof, "provider-unavailable");
		if (!refreshed_before_closure && attr_inputs_match &&
		    wt_status_tracked_fsmonitor_state_is_current(s) &&
		    (wt_status_pathspec_matches_clean_tracked_entries(s, 1) ||
		     clean_status_index_entries_are_certifiable(istate) ||
		     wt_status_ignored_submodules_are_clean(s))) {
			s->tracked_from_fsmonitor = 1;
			trace2_data_intmax(
				"status", s->repo,
				"fsmonitor/tracked-clean", 1);
			return 0;
		}
		if (refreshed_before_closure && attr_inputs_match &&
		    s->tracked_from_fsmonitor &&
		    wt_status_tracked_fsmonitor_state_is_current(s))
			return closure.refresh_result;
		s->tracked_from_fsmonitor = 0;
		if (!refreshed_before_closure && attr_inputs_match)
			return refresh_index(
				istate, refresh_flags, &s->pathspec,
				NULL, NULL);
		if (refreshed_before_closure && attr_inputs_match)
			return closure.refresh_result;

		wt_status_reset_attr_snapshot_if_changed(s);
		if (fsmonitor_has_pending_token(istate))
			fsmonitor_reject_pending_token(istate);
		untracked_cache_invalidate_all(istate);
		fsmonitor_invalidate_semantics(istate);
		closure.refresh_result |= refresh_index(
			istate, refresh_flags, &s->pathspec, NULL, NULL);
		return closure.refresh_result;
	}

	s->tracked_from_fsmonitor = 0;
	closure.can_prime = require_untracked &&
		(istate->untracked || s->certify_clean_status) &&
		s->show_untracked_files != SHOW_NO_UNTRACKED_FILES &&
		!s->show_ignored_mode;
	closure.use_bulk_provider =
		wt_status_can_use_bulk_provider(s, refresh_flags);
	closure.untracked_ready = !istate->untracked ||
		!istate->untracked->root ||
		(istate->fsmonitor_legacy_untracked_adopted &&
		 istate->fsmonitor_untracked_valid &&
		 istate->untracked->root->valid_recursive) ||
		(!require_untracked &&
		 (s->show_untracked_files == SHOW_NO_UNTRACKED_FILES ||
		  s->show_ignored_mode) &&
		 istate->fsmonitor_untracked_valid &&
		 istate->fsmonitor_untracked_token &&
		 istate->fsmonitor_last_update &&
		 !strcmp(istate->fsmonitor_untracked_token,
			 istate->fsmonitor_last_update));
	closure.untracked_proof_complete =
		!require_untracked || !istate->untracked ||
		(istate->fsmonitor_legacy_untracked_adopted &&
		 closure.untracked_ready);
	if (require_untracked && !closure.can_prime &&
	    !closure.untracked_ready)
		BUG("cannot close required untracked scan");
	trace2_region_enter("status", "fsmonitor_token_closure", s->repo);
	wt_status_reset_attr_snapshot_if_changed(s);
	if (wt_status_refresh_invalidated_manifest(s))
		goto fallback;

	if (proof) {
		result = wt_status_close_semantic_fsmonitor_token(
			&closure, &proof);
		if (result == WT_STATUS_TOKEN_CLOSURE_ACCEPTED) {
			token_accepted = 1;
			goto accepted;
		}
		if (result == WT_STATUS_TOKEN_CLOSURE_FALLBACK)
			goto fallback;
		wt_status_reset_attr_snapshot_if_changed(s);
		if (wt_status_refresh_invalidated_manifest(s))
			goto fallback;
	}

	if (wt_status_close_ordinary_fsmonitor_token(
		    &closure, refreshed_before_closure)) {
		token_accepted = 1;
		goto accepted;
	}

	/* Keep the last valid token and fall back to complete scans. */
fallback:
	s->tracked_from_fsmonitor = 0;
	wt_status_discard_semantic_verify(s, &proof, "fallback");
	wt_status_discard_staged_untracked(&closure);
	preload_index_bulk_result_clear(istate);
	fsmonitor_reject_pending_token(istate);
	if (fstat_is_reliable()) {
		if (closure.can_prime)
			untracked_cache_invalidate_all(istate);
		fsmonitor_invalidate_semantics(istate);
	}
	closure.refresh_result |= refresh_index(
		istate, refresh_flags, &s->pathspec, NULL, NULL);
accepted:
	if (token_accepted && preserve_untracked &&
	    !istate->fsmonitor_untracked_valid &&
	    istate->untracked->root && istate->untracked->root->valid &&
	    clean_status_revalidated_token_matches(istate) &&
	    !clean_status_filter_scope_needs_validation(istate)) {
		/* Tracked closure leaves directory snapshots unverified. */
		istate->untracked->fsmonitor_revalidation = 1;
		istate->fsmonitor_untracked_token =
			xstrdup(istate->fsmonitor_last_update);
		clean_status_begin_fsmonitor_semantic_baseline(istate);
	}
	wt_status_publish_staged_untracked(&closure);
	wt_status_discard_staged_untracked(&closure);
	trace2_region_leave("status", "fsmonitor_token_closure", s->repo);
	return closure.refresh_result;
}

int wt_status_refresh_index(struct wt_status *s,
			    unsigned int refresh_flags,
			    int require_untracked)
{
	struct index_state *istate = s->repo->index;
	struct semantic_verify_proof *proof;
	int ret;

	wt_status_begin_attr_snapshot(s);
	refresh_fsmonitor(istate);
	proof = wt_status_prepare_semantic_verify(s, refresh_flags);
	ret = wt_status_close_fsmonitor_token(
		s, proof, refresh_flags, require_untracked, 0);
	if (istate->preload_untracked == &s->untracked) {
		s->untracked_from_preload =
			istate->preload_untracked_complete;
		istate->preload_untracked = NULL;
		istate->preload_untracked_complete = 0;
	}
	return ret;
}

static void wt_status_release_attr_snapshot(struct wt_status *s)
{
	if (s->attr_source_snapshot)
		git_attr_source_snapshot_end(s->attr_source_snapshot);
	attr_source_snapshot_free(s->attr_source_snapshot);
	s->attr_source_snapshot = NULL;
	s->attr_snapshot_failed = 0;
}

void wt_status_invalidate_refresh(struct wt_status *s)
{
	struct index_state *istate = s->repo->index;

	s->tracked_from_fsmonitor = 0;
	if (s->untracked_from_token_closure) {
		string_list_clear(&s->untracked, 0);
		string_list_clear(&s->ignored, 0);
		s->untracked_from_token_closure = 0;
	}
	wt_status_release_exclude_proof(s);
	wt_status_release_attr_snapshot(s);
	if (!s->pathspec.nr && !istate->split_index &&
	    fsmonitor_reopen_token(istate))
		return;
	if (fsmonitor_has_pending_token(istate))
		fsmonitor_reject_pending_token(istate);
	clean_status_invalidate_current_manifest(istate);
	untracked_cache_invalidate_all(istate);
	fsmonitor_invalidate_semantics(istate);
}

static int has_unmerged(struct wt_status *s)
{
	int i;

	for (i = 0; i < s->change.nr; i++) {
		struct wt_status_change_data *d;
		d = s->change.items[i].util;
		if (d->stagemask)
			return 1;
	}
	return 0;
}

void wt_status_collect(struct wt_status *s)
{
	int used_untracked_cache;

	if (fsm_settings__get_mode(s->repo) > FSMONITOR_MODE_DISABLED)
		wt_status_finish_untracked_cache_preload(s);
	wt_status_begin_attr_snapshot(s);
	wt_status_close_fsmonitor_token(
		s, NULL, REFRESH_QUIET | REFRESH_UNMERGED,
		s->show_untracked_files != SHOW_NO_UNTRACKED_FILES &&
		!s->show_ignored_mode, 1);

	trace2_region_enter("status", "worktrees", s->repo);
	wt_status_collect_changes_worktree(s);
	trace2_region_leave("status", "worktrees", s->repo);

	if (s->is_initial) {
		trace2_region_enter("status", "initial", s->repo);
		wt_status_collect_changes_initial(s);
		trace2_region_leave("status", "initial", s->repo);
	} else {
		trace2_region_enter("status", "index", s->repo);
		wt_status_collect_changes_index(s);
		trace2_region_leave("status", "index", s->repo);
	}

	trace2_region_enter("status", "untracked", s->repo);
	used_untracked_cache = wt_status_collect_untracked(s);
	trace2_region_leave("status", "untracked", s->repo);

	/* Hook providers have no second query with which to close the scan. */
	if (fsmonitor_has_pending_token(s->repo->index) && !s->pathspec.nr &&
	    fsm_settings__get_mode(s->repo) == FSMONITOR_MODE_HOOK &&
	    (used_untracked_cache || !s->repo->index->untracked ||
	     !s->repo->index->untracked->root)) {
		if (fsmonitor_pending_token_from_provider(s->repo->index))
			fsmonitor_accept_pending_token(
				s->repo->index, 1, used_untracked_cache);
		else
			fsmonitor_reject_pending_token(s->repo->index);
	}

	wt_status_get_state(s->repo, &s->state, s->branch && !strcmp(s->branch, "HEAD"));
	if (s->state.merge_in_progress && !has_unmerged(s))
		s->committable = 1;
}

void wt_status_collect_free_buffers(struct wt_status *s)
{
	untracked_cache_preload_release(s->untracked_cache_preload);
	s->untracked_cache_preload = NULL;
	wt_status_release_exclude_proof(s);
	wt_status_release_attr_snapshot(s);
	wt_status_state_free_buffers(&s->state);
}

void wt_status_state_free_buffers(struct wt_status_state *state)
{
	FREE_AND_NULL(state->branch);
	FREE_AND_NULL(state->onto);
	FREE_AND_NULL(state->detached_from);
	FREE_AND_NULL(state->bisecting_from);
}

static void wt_longstatus_print_unmerged(struct wt_status *s)
{
	int shown_header = 0;
	int i;

	for (i = 0; i < s->change.nr; i++) {
		struct wt_status_change_data *d;
		struct string_list_item *it;
		it = &(s->change.items[i]);
		d = it->util;
		if (!d->stagemask)
			continue;
		if (!shown_header) {
			wt_longstatus_print_unmerged_header(s);
			shown_header = 1;
		}
		wt_longstatus_print_unmerged_data(s, it);
	}
	if (shown_header)
		wt_longstatus_print_trailer(s);

}

static void wt_longstatus_print_updated(struct wt_status *s)
{
	int shown_header = 0;
	int i;

	for (i = 0; i < s->change.nr; i++) {
		struct wt_status_change_data *d;
		struct string_list_item *it;
		it = &(s->change.items[i]);
		d = it->util;
		if (!d->index_status ||
		    d->index_status == DIFF_STATUS_UNMERGED)
			continue;
		if (!shown_header) {
			wt_longstatus_print_cached_header(s);
			shown_header = 1;
		}
		wt_longstatus_print_change_data(s, WT_STATUS_UPDATED, it);
	}
	if (shown_header)
		wt_longstatus_print_trailer(s);
}

/*
 * -1 : has delete
 *  0 : no change
 *  1 : some change but no delete
 */
static int wt_status_check_worktree_changes(struct wt_status *s,
					     int *dirty_submodules)
{
	int i;
	int changes = 0;

	*dirty_submodules = 0;

	for (i = 0; i < s->change.nr; i++) {
		struct wt_status_change_data *d;
		d = s->change.items[i].util;
		if (!d->worktree_status ||
		    d->worktree_status == DIFF_STATUS_UNMERGED)
			continue;
		if (!changes)
			changes = 1;
		if (d->dirty_submodule)
			*dirty_submodules = 1;
		if (d->worktree_status == DIFF_STATUS_DELETED)
			changes = -1;
	}
	return changes;
}

static void wt_longstatus_print_changed(struct wt_status *s)
{
	int i, dirty_submodules;
	int worktree_changes = wt_status_check_worktree_changes(s, &dirty_submodules);

	if (!worktree_changes)
		return;

	wt_longstatus_print_dirty_header(s, worktree_changes < 0, dirty_submodules);

	for (i = 0; i < s->change.nr; i++) {
		struct wt_status_change_data *d;
		struct string_list_item *it;
		it = &(s->change.items[i]);
		d = it->util;
		if (!d->worktree_status ||
		    d->worktree_status == DIFF_STATUS_UNMERGED)
			continue;
		wt_longstatus_print_change_data(s, WT_STATUS_CHANGED, it);
	}
	wt_longstatus_print_trailer(s);
}

static int stash_count_refs(const char *refname UNUSED,
			    struct object_id *ooid UNUSED,
			    struct object_id *noid UNUSED,
			    const char *email UNUSED,
			    timestamp_t timestamp UNUSED, int tz UNUSED,
			    const char *message UNUSED, void *cb_data)
{
	int *c = cb_data;
	(*c)++;
	return 0;
}

static int count_stash_entries(struct repository *r)
{
	int n = 0;
	refs_for_each_reflog_ent(get_main_ref_store(r),
				 "refs/stash", stash_count_refs, &n);
	return n;
}

static void wt_longstatus_print_stash_summary(struct wt_status *s)
{
	int stash_count = count_stash_entries(s->repo);

	if (stash_count > 0)
		status_printf_ln(s, GIT_COLOR_NORMAL,
				 Q_("Your stash currently has %d entry",
				    "Your stash currently has %d entries", stash_count),
				 stash_count);
}

static void wt_longstatus_print_submodule_summary(struct wt_status *s, int uncommitted)
{
	struct child_process sm_summary = CHILD_PROCESS_INIT;
	struct strbuf cmd_stdout = STRBUF_INIT;
	struct strbuf summary = STRBUF_INIT;
	char *summary_content;

	strvec_pushf(&sm_summary.env, "GIT_INDEX_FILE=%s", s->index_file);

	strvec_push(&sm_summary.args, "submodule");
	strvec_push(&sm_summary.args, "summary");
	strvec_push(&sm_summary.args, uncommitted ? "--files" : "--cached");
	strvec_push(&sm_summary.args, "--for-status");
	strvec_push(&sm_summary.args, "--summary-limit");
	strvec_pushf(&sm_summary.args, "%d", s->submodule_summary);
	if (!uncommitted)
		strvec_push(&sm_summary.args, s->amend ? "HEAD^" : "HEAD");

	sm_summary.git_cmd = 1;
	sm_summary.no_stdin = 1;

	capture_command(&sm_summary, &cmd_stdout, 1024);

	/* prepend header, only if there's an actual output */
	if (cmd_stdout.len) {
		if (uncommitted)
			strbuf_addstr(&summary, _("Submodules changed but not updated:"));
		else
			strbuf_addstr(&summary, _("Submodule changes to be committed:"));
		strbuf_addstr(&summary, "\n\n");
	}
	strbuf_addbuf(&summary, &cmd_stdout);
	strbuf_release(&cmd_stdout);

	if (s->display_comment_prefix) {
		size_t len;
		summary_content = strbuf_detach(&summary, &len);
		strbuf_add_commented_lines(&summary, summary_content, len, comment_line_str);
		free(summary_content);
	}

	fputs(summary.buf, s->fp);
	strbuf_release(&summary);
}

static void wt_longstatus_print_other(struct wt_status *s,
				      struct string_list *l,
				      const char *what,
				      const char *how)
{
	int i;
	struct strbuf buf = STRBUF_INIT;
	static struct string_list output = STRING_LIST_INIT_DUP;
	struct column_options copts;

	if (!l->nr)
		return;

	wt_longstatus_print_other_header(s, what, how);

	for (i = 0; i < l->nr; i++) {
		struct string_list_item *it;
		const char *path;
		it = &(l->items[i]);
		path = quote_path(it->string, s->prefix, &buf, 0);
		if (column_active(s->colopts)) {
			string_list_append(&output, path);
			continue;
		}
		status_printf(s, color(WT_STATUS_HEADER, s), "\t");
		status_printf_more(s, color(WT_STATUS_UNTRACKED, s),
				   "%s\n", path);
	}

	strbuf_release(&buf);
	if (!column_active(s->colopts))
		goto conclude;

	strbuf_addf(&buf, "%s%s\t%s",
		    color(WT_STATUS_HEADER, s),
		    s->display_comment_prefix ? "#" : "",
		    color(WT_STATUS_UNTRACKED, s));
	memset(&copts, 0, sizeof(copts));
	copts.padding = 1;
	copts.indent = buf.buf;
	if (want_color(s->use_color))
		copts.nl = GIT_COLOR_RESET "\n";
	print_columns(&output, s->colopts, &copts);
	string_list_clear(&output, 0);
	strbuf_release(&buf);
conclude:
	status_printf_ln(s, GIT_COLOR_NORMAL, "%s", "");
}

size_t wt_status_locate_end(const char *s, size_t len)
{
	const char *p;
	struct strbuf pattern = STRBUF_INIT;

	strbuf_addf(&pattern, "\n%s %s", comment_line_str, cut_line);
	if (starts_with(s, pattern.buf + 1))
		len = 0;
	else if ((p = strstr(s, pattern.buf))) {
		size_t newlen = p - s + 1;
		if (newlen < len)
			len = newlen;
	}
	strbuf_release(&pattern);
	return len;
}

void wt_status_append_cut_line(struct strbuf *buf)
{
	const char *explanation = _("Do not modify or remove the line above.\nEverything below it will be ignored.");

	strbuf_commented_addf(buf, comment_line_str, "%s", cut_line);
	strbuf_add_commented_lines(buf, explanation, strlen(explanation), comment_line_str);
}

void wt_status_add_cut_line(struct wt_status *s)
{
	struct strbuf buf = STRBUF_INIT;

	if (s->added_cut_line)
		return;
	s->added_cut_line = 1;
	wt_status_append_cut_line(&buf);
	fputs(buf.buf, s->fp);
	strbuf_release(&buf);
}

static void wt_longstatus_print_verbose(struct wt_status *s)
{
	struct rev_info rev;
	struct setup_revision_opt opt;
	int dirty_submodules;
	const char *c = color(WT_STATUS_HEADER, s);

	repo_init_revisions(s->repo, &rev, NULL);
	rev.diffopt.flags.allow_textconv = 1;
	rev.diffopt.ita_invisible_in_index = 1;

	memset(&opt, 0, sizeof(opt));
	opt.def = s->is_initial ? empty_tree_oid_hex(s->repo->hash_algo) : s->reference;
	setup_revisions(0, NULL, &rev, &opt);

	rev.diffopt.output_format |= DIFF_FORMAT_PATCH;
	rev.diffopt.detect_rename = s->detect_rename >= 0 ? s->detect_rename : rev.diffopt.detect_rename;
	rev.diffopt.rename_limit = s->rename_limit >= 0 ? s->rename_limit : rev.diffopt.rename_limit;
	rev.diffopt.rename_score = s->rename_score >= 0 ? s->rename_score : rev.diffopt.rename_score;
	rev.diffopt.file = s->fp;
	rev.diffopt.close_file = 0;
	/*
	 * If we're not going to stdout, then we definitely don't
	 * want color, since we are going to the commit message
	 * file (and even the "auto" setting won't work, since it
	 * will have checked isatty on stdout). But we then do want
	 * to insert the scissor line here to reliably remove the
	 * diff before committing, if we didn't already include one
	 * before.
	 */
	if (s->fp != stdout) {
		rev.diffopt.use_color = GIT_COLOR_NEVER;
		wt_status_add_cut_line(s);
	}
	if (s->verbose > 1 && s->committable) {
		/* print_updated() printed a header, so do we */
		if (s->fp != stdout)
			wt_longstatus_print_trailer(s);
		status_printf_ln(s, c, _("Changes to be committed:"));
		rev.diffopt.a_prefix = "c/";
		rev.diffopt.b_prefix = "i/";
	} /* else use prefix as per user config */
	run_diff_index(&rev, DIFF_INDEX_CACHED);
	if (s->verbose > 1 &&
	    wt_status_check_worktree_changes(s, &dirty_submodules)) {
		status_printf_ln(s, c,
			"--------------------------------------------------");
		status_printf_ln(s, c, _("Changes not staged for commit:"));
		setup_work_tree(the_repository);
		rev.diffopt.a_prefix = "i/";
		rev.diffopt.b_prefix = "w/";
		run_diff_files(&rev, 0);
	}
	release_revisions(&rev);
}

static void wt_longstatus_print_tracking(struct wt_status *s)
{
	struct strbuf sb = STRBUF_INIT;
	const char *cp, *ep, *branch_name;
	struct branch *branch;
	uint64_t t_begin = 0;

	assert(s->branch && !s->is_initial);
	if (!skip_prefix(s->branch, "refs/heads/", &branch_name))
		return;
	branch = branch_get(branch_name);

	t_begin = getnanotime();

	if (!format_tracking_info(branch, &sb, s->ahead_behind_flags,
				  !s->commit_template))
		return;

	if (advice_enabled(ADVICE_STATUS_AHEAD_BEHIND_WARNING) &&
	    s->ahead_behind_flags == AHEAD_BEHIND_FULL) {
		uint64_t t_delta_in_ms = (getnanotime() - t_begin) / 1000000;
		if (t_delta_in_ms > AB_DELAY_WARNING_IN_MS) {
			strbuf_addf(&sb, _("\n"
					   "It took %.2f seconds to compute the branch ahead/behind values.\n"
					   "You can use '--no-ahead-behind' to avoid this.\n"),
				    t_delta_in_ms / 1000.0);
		}
	}

	for (cp = sb.buf; (ep = strchr(cp, '\n')) != NULL; cp = ep + 1)
		color_fprintf_ln(s->fp, color(WT_STATUS_HEADER, s),
				 "%s%s%.*s",
				 s->display_comment_prefix ? comment_line_str : "",
				 s->display_comment_prefix ? " " : "",
				 (int)(ep - cp), cp);
	if (s->display_comment_prefix)
		color_fprintf_ln(s->fp, color(WT_STATUS_HEADER, s), "%s",
				 comment_line_str);
	else
		fputs("\n", s->fp);
	strbuf_release(&sb);
}

static int uf_was_slow(struct wt_status *s)
{
	if (getenv("GIT_TEST_UF_DELAY_WARNING"))
		s->untracked_in_ms = 3250;
	return UF_DELAY_WARNING_IN_MS < s->untracked_in_ms;
}

static void show_merge_in_progress(struct wt_status *s,
				   const char *color)
{
	if (has_unmerged(s)) {
		status_printf_ln(s, color, _("You have unmerged paths."));
		if (s->hints) {
			status_printf_ln(s, color,
					 _("  (fix conflicts and run \"git commit\")"));
			status_printf_ln(s, color,
					 _("  (use \"git merge --abort\" to abort the merge)"));
		}
	} else {
		status_printf_ln(s, color,
			_("All conflicts fixed but you are still merging."));
		if (s->hints)
			status_printf_ln(s, color,
				_("  (use \"git commit\" to conclude merge)"));
	}
	wt_longstatus_print_trailer(s);
}

static void show_am_in_progress(struct wt_status *s,
				const char *color)
{
	int am_empty_patch;

	status_printf_ln(s, color,
		_("You are in the middle of an am session."));
	if (s->state.am_empty_patch)
		status_printf_ln(s, color,
			_("The current patch is empty."));
	if (s->hints) {
		am_empty_patch = s->state.am_empty_patch;
		if (!am_empty_patch)
			status_printf_ln(s, color,
				_("  (fix conflicts and then run \"git am --continue\")"));
		status_printf_ln(s, color,
			_("  (use \"git am --skip\" to skip this patch)"));
		if (am_empty_patch)
			status_printf_ln(s, color,
				_("  (use \"git am --allow-empty\" to record this patch as an empty commit)"));
		status_printf_ln(s, color,
			_("  (use \"git am --abort\" to restore the original branch)"));
	}
	wt_longstatus_print_trailer(s);
}

static char *read_line_from_git_path(struct repository *r, const char *filename)
{
	struct strbuf buf = STRBUF_INIT;
	FILE *fp = fopen_or_warn(repo_git_path_append(r, &buf,
						      "%s", filename), "r");

	if (!fp) {
		strbuf_release(&buf);
		return NULL;
	}
	strbuf_getline_lf(&buf, fp);
	if (!fclose(fp)) {
		return strbuf_detach(&buf, NULL);
	} else {
		strbuf_release(&buf);
		return NULL;
	}
}

static int split_commit_in_progress(struct wt_status *s)
{
	int split_in_progress = 0;
	struct object_id head_oid, orig_head_oid;
	char *rebase_amend, *rebase_orig_head;
	int head_flags, orig_head_flags;

	if ((!s->amend && !s->nowarn && !s->workdir_dirty) ||
	    !s->branch || strcmp(s->branch, "HEAD"))
		return 0;

	if (refs_read_ref_full(get_main_ref_store(s->repo), "HEAD", RESOLVE_REF_READING | RESOLVE_REF_NO_RECURSE,
			       &head_oid, &head_flags) ||
	    refs_read_ref_full(get_main_ref_store(s->repo), "ORIG_HEAD", RESOLVE_REF_READING | RESOLVE_REF_NO_RECURSE,
			       &orig_head_oid, &orig_head_flags))
		return 0;
	if (head_flags & REF_ISSYMREF || orig_head_flags & REF_ISSYMREF)
		return 0;

	rebase_amend = read_line_from_git_path(s->repo, "rebase-merge/amend");
	rebase_orig_head = read_line_from_git_path(s->repo, "rebase-merge/orig-head");

	if (!rebase_amend || !rebase_orig_head)
		; /* fall through, no split in progress */
	else if (!strcmp(rebase_amend, rebase_orig_head))
		split_in_progress = !!strcmp(oid_to_hex(&head_oid), rebase_amend);
	else if (strcmp(oid_to_hex(&orig_head_oid), rebase_orig_head))
		split_in_progress = 1;

	free(rebase_amend);
	free(rebase_orig_head);

	return split_in_progress;
}

/*
 * If the whitespace-delimited token starting at or just after *pp
 * is a hex object id that is longer than its default abbreviation,
 * abbreviate it in-place, shrinking `line` accordingly. On return
 * *pp points one past the (possibly abbreviated) token. Leaves both
 * `line` and *pp-advanced-past-the-token unchanged in all other cases
 * (non-hex token, label name, unresolvable, or a refname that happens
 * to consist only of hex digits).
 */
static void abbrev_oid_in_line(struct repository *r, struct strbuf *scratch,
			       struct strbuf *line, bool maybe_label, char **pp)
{
	char *p = *pp;
	char *end_of_object_name, saved;
	const char *abbrev;
	struct object_id oid;
	bool have_oid;

	p += strspn(p, " \t");
	end_of_object_name = p + strcspn(p, " \t");
	/*
	 * For "merge" and "reset" the object name may be a label or
	 * ref rather than a hex object id. Only abbreviate the object
	 * name if it is a hex object id.
	 */
	for (const char *q = p; q < end_of_object_name; q++) {
		if (!isxdigit(*q))
			goto out;
	}
	if (maybe_label) {
		strbuf_reset(scratch);
		strbuf_addf(scratch, "refs/rewritten/%.*s",
			    (int)(end_of_object_name - p), p);
		if (refs_ref_exists(get_main_ref_store(r), scratch->buf))
			goto out; /* object name was a label */
	}
	saved = *end_of_object_name;
	*end_of_object_name = '\0';
	have_oid = !repo_get_oid(r, p, &oid);
	*end_of_object_name = saved;
	if (!have_oid)
		goto out; /* invalid object name */
	abbrev = repo_find_unique_abbrev(r, &oid, DEFAULT_ABBREV);
	if (!starts_with(p, abbrev))
		goto out; /* object name was a refname containing only xdigits */
	p += strlen(abbrev);
	strbuf_remove(line, p - line->buf, end_of_object_name - p);
	end_of_object_name = p;
out:
	*pp = end_of_object_name;
}

/* Skip "[ \t]*(-[cC])?", returns true if "-c/-C" was skipped. */
static bool skip_dash_c(char **pp)
{
	bool ret;
	char *p = *pp;

	p += strspn(p, " \t");
	ret = skip_prefix(p, "-C", &p) || skip_prefix(p, "-c", &p);
	*pp = p;

	return ret;
}

/*
 * Turn
 * "pick d6a2f0303e897ec257dd0e0a39a5ccb709bc2047 some message"
 * into
 * "pick d6a2f03 some message"
 *
 * Returns false on comment lines, true otherwise
 */
static bool format_todo_line(struct repository *r, struct strbuf *line)
{
	enum todo_command cmd;
	struct strbuf scratch = STRBUF_INIT;
	char *p = line->buf;

	if (!sequencer_parse_todo_command((const char **)&p, &cmd))
		return true; /* keep invalid lines */

	switch (cmd) {
	case TODO_COMMENT:
		return false;

	case TODO_MERGE: {
		/*
		 * The argument to -C cannot be a label, but the parents
		 * can be labels.
		 */
		bool maybe_label = !skip_dash_c(&p);

		while (true) {
			p += strspn(p, " \t");
			if (!p[0] || (p[0] == '#' && (!p[1] || isspace(p[1]))))
				break;
			abbrev_oid_in_line(r, &scratch, line, maybe_label, &p);
			maybe_label = true;
		}
		break;
	}

	case TODO_FIXUP:
		skip_dash_c(&p);
		/* fallthrough */
	case TODO_DROP:
	case TODO_EDIT:
	case TODO_PICK:
	case TODO_REVERT:
	case TODO_REWORD:
	case TODO_SQUASH:
		abbrev_oid_in_line(r, &scratch, line, false, &p);
		break;

	case TODO_RESET:
		abbrev_oid_in_line(r, &scratch, line, true, &p);
		break;
	/*
	 * Avoid "default" and instead list all the other commands so
	 * that -Wswitch (which is included in -Wall) warns if a new
	 * command is added without handling it in this function.
	 */
	case TODO_BREAK:
	case TODO_EXEC:
	case TODO_LABEL:
	case TODO_NOOP:
	case TODO_UPDATE_REF:
		break;
	}

	strbuf_release(&scratch);
	return true;
}

static int read_rebase_todolist(struct repository *r, const char *fname, struct string_list *lines)
{
	struct strbuf buf = STRBUF_INIT;
	FILE *f = fopen(repo_git_path_append(r, &buf, "%s", fname), "r");
	int ret;

	if (!f) {
		if (errno == ENOENT) {
			ret = -1;
			goto out;
		}
		die_errno("Could not open file %s for reading",
			  repo_git_path_replace(r, &buf, "%s", fname));
	}
	while (!strbuf_getline_lf(&buf, f)) {
		strbuf_trim(&buf);
		if (format_todo_line(r, &buf))
			string_list_append(lines, buf.buf);
	}
	fclose(f);

	ret = 0;
out:
	strbuf_release(&buf);
	return ret;
}

static void show_rebase_information(struct wt_status *s,
				    const char *color)
{
	if (s->state.rebase_interactive_in_progress) {
		int i;
		int nr_lines_to_show = 2;

		struct string_list have_done = STRING_LIST_INIT_DUP;
		struct string_list yet_to_do = STRING_LIST_INIT_DUP;

		read_rebase_todolist(s->repo, "rebase-merge/done", &have_done);
		if (read_rebase_todolist(s->repo, "rebase-merge/git-rebase-todo",
					 &yet_to_do))
			status_printf_ln(s, color,
				_("git-rebase-todo is missing."));
		if (have_done.nr == 0)
			status_printf_ln(s, color, _("No commands done."));
		else {
			status_printf_ln(s, color,
				Q_("Last command done (%"PRIuMAX" command done):",
					"Last commands done (%"PRIuMAX" commands done):",
					have_done.nr),
				(uintmax_t)have_done.nr);
			for (i = (have_done.nr > nr_lines_to_show)
				? have_done.nr - nr_lines_to_show : 0;
				i < have_done.nr;
				i++)
				status_printf_ln(s, color, "   %s", have_done.items[i].string);
			if (have_done.nr > nr_lines_to_show && s->hints) {
				char *path = repo_git_path(s->repo, "rebase-merge/done");
				status_printf_ln(s, color,
					_("  (see more in file %s)"), path);
				free(path);
			}
		}

		if (yet_to_do.nr == 0)
			status_printf_ln(s, color,
					 _("No commands remaining."));
		else {
			status_printf_ln(s, color,
				Q_("Next command to do (%"PRIuMAX" remaining command):",
					"Next commands to do (%"PRIuMAX" remaining commands):",
					yet_to_do.nr),
				(uintmax_t)yet_to_do.nr);
			for (i = 0; i < nr_lines_to_show && i < yet_to_do.nr; i++)
				status_printf_ln(s, color, "   %s", yet_to_do.items[i].string);
			if (s->hints)
				status_printf_ln(s, color,
					_("  (use \"git rebase --edit-todo\" to view and edit)"));
		}
		string_list_clear(&yet_to_do, 0);
		string_list_clear(&have_done, 0);
	}
}

static void print_rebase_state(struct wt_status *s,
			       const char *color)
{
	if (s->state.branch)
		status_printf_ln(s, color,
				 _("You are currently rebasing branch '%s' on '%s'."),
				 s->state.branch,
				 s->state.onto);
	else
		status_printf_ln(s, color,
				 _("You are currently rebasing."));
}

static void show_rebase_in_progress(struct wt_status *s,
				    const char *color)
{
	struct stat st;

	show_rebase_information(s, color);
	if (has_unmerged(s)) {
		print_rebase_state(s, color);
		if (s->hints) {
			status_printf_ln(s, color,
				_("  (fix conflicts and then run \"git rebase --continue\")"));
			status_printf_ln(s, color,
				_("  (use \"git rebase --skip\" to skip this patch)"));
			status_printf_ln(s, color,
				_("  (use \"git rebase --abort\" to check out the original branch)"));
		}
	} else if (s->state.rebase_in_progress ||
		   !stat(git_path_merge_msg(s->repo), &st)) {
		print_rebase_state(s, color);
		if (s->hints)
			status_printf_ln(s, color,
				_("  (all conflicts fixed: run \"git rebase --continue\")"));
	} else if (split_commit_in_progress(s)) {
		if (s->state.branch)
			status_printf_ln(s, color,
					 _("You are currently splitting a commit while rebasing branch '%s' on '%s'."),
					 s->state.branch,
					 s->state.onto);
		else
			status_printf_ln(s, color,
					 _("You are currently splitting a commit during a rebase."));
		if (s->hints)
			status_printf_ln(s, color,
				_("  (Once your working directory is clean, run \"git rebase --continue\")"));
	} else {
		if (s->state.branch)
			status_printf_ln(s, color,
					 _("You are currently editing a commit while rebasing branch '%s' on '%s'."),
					 s->state.branch,
					 s->state.onto);
		else
			status_printf_ln(s, color,
					 _("You are currently editing a commit during a rebase."));
		if (s->hints && !s->amend) {
			status_printf_ln(s, color,
				_("  (use \"git commit --amend\" to amend the current commit)"));
			status_printf_ln(s, color,
				_("  (use \"git rebase --continue\" once you are satisfied with your changes)"));
		}
	}
	wt_longstatus_print_trailer(s);
}

static void show_cherry_pick_in_progress(struct wt_status *s,
					 const char *color)
{
	if (is_null_oid(&s->state.cherry_pick_head_oid))
		status_printf_ln(s, color,
			_("Cherry-pick currently in progress."));
	else
		status_printf_ln(s, color,
			_("You are currently cherry-picking commit %s."),
			repo_find_unique_abbrev(s->repo, &s->state.cherry_pick_head_oid,
						DEFAULT_ABBREV));

	if (s->hints) {
		if (has_unmerged(s))
			status_printf_ln(s, color,
				_("  (fix conflicts and run \"git cherry-pick --continue\")"));
		else if (is_null_oid(&s->state.cherry_pick_head_oid))
			status_printf_ln(s, color,
				_("  (run \"git cherry-pick --continue\" to continue)"));
		else
			status_printf_ln(s, color,
				_("  (all conflicts fixed: run \"git cherry-pick --continue\")"));
		status_printf_ln(s, color,
			_("  (use \"git cherry-pick --skip\" to skip this patch)"));
		status_printf_ln(s, color,
			_("  (use \"git cherry-pick --abort\" to cancel the cherry-pick operation)"));
	}
	wt_longstatus_print_trailer(s);
}

static void show_revert_in_progress(struct wt_status *s,
				    const char *color)
{
	if (is_null_oid(&s->state.revert_head_oid))
		status_printf_ln(s, color,
			_("Revert currently in progress."));
	else
		status_printf_ln(s, color,
			_("You are currently reverting commit %s."),
			repo_find_unique_abbrev(s->repo, &s->state.revert_head_oid,
						DEFAULT_ABBREV));
	if (s->hints) {
		if (has_unmerged(s))
			status_printf_ln(s, color,
				_("  (fix conflicts and run \"git revert --continue\")"));
		else if (is_null_oid(&s->state.revert_head_oid))
			status_printf_ln(s, color,
				_("  (run \"git revert --continue\" to continue)"));
		else
			status_printf_ln(s, color,
				_("  (all conflicts fixed: run \"git revert --continue\")"));
		status_printf_ln(s, color,
			_("  (use \"git revert --skip\" to skip this patch)"));
		status_printf_ln(s, color,
			_("  (use \"git revert --abort\" to cancel the revert operation)"));
	}
	wt_longstatus_print_trailer(s);
}

static void show_bisect_in_progress(struct wt_status *s,
				    const char *color)
{
	if (s->state.bisecting_from)
		status_printf_ln(s, color,
				 _("You are currently bisecting, started from branch '%s'."),
				 s->state.bisecting_from);
	else
		status_printf_ln(s, color,
				 _("You are currently bisecting."));
	if (s->hints)
		status_printf_ln(s, color,
			_("  (use \"git bisect reset\" to get back to the original branch)"));
	wt_longstatus_print_trailer(s);
}

static void show_sparse_checkout_in_use(struct wt_status *s,
					const char *color)
{
	if (s->state.sparse_checkout_percentage == SPARSE_CHECKOUT_DISABLED)
		return;

	if (s->state.sparse_checkout_percentage == SPARSE_CHECKOUT_SPARSE_INDEX)
		status_printf_ln(s, color, _("You are in a sparse checkout."));
	else
		status_printf_ln(s, color,
				_("You are in a sparse checkout with %d%% of tracked files present."),
				s->state.sparse_checkout_percentage);
	wt_longstatus_print_trailer(s);
}

/*
 * Extract branch information from rebase/bisect
 */
static char *get_branch(const struct worktree *wt, const char *path)
{
	struct strbuf sb = STRBUF_INIT;
	struct object_id oid;
	const char *branch_name;

	if (strbuf_read_file(&sb, worktree_git_path(wt, "%s", path), 0) <= 0)
		goto got_nothing;

	while (sb.len && sb.buf[sb.len - 1] == '\n')
		strbuf_setlen(&sb, sb.len - 1);
	if (!sb.len)
		goto got_nothing;
	if (skip_prefix(sb.buf, "refs/heads/", &branch_name))
		strbuf_remove(&sb, 0, branch_name - sb.buf);
	else if (starts_with(sb.buf, "refs/"))
		;
	else if (!get_oid_hex(sb.buf, &oid)) {
		strbuf_reset(&sb);
		strbuf_add_unique_abbrev(&sb, &oid, DEFAULT_ABBREV);
	} else if (!strcmp(sb.buf, "detached HEAD")) /* rebase */
		goto got_nothing;
	else			/* bisect */
		;
	return strbuf_detach(&sb, NULL);

got_nothing:
	strbuf_release(&sb);
	return NULL;
}

struct grab_1st_switch_cbdata {
	struct strbuf buf;
	struct object_id noid;
};

static int grab_1st_switch(const char *refname UNUSED,
			   struct object_id *ooid UNUSED,
			   struct object_id *noid,
			   const char *email UNUSED,
			   timestamp_t timestamp UNUSED, int tz UNUSED,
			   const char *message, void *cb_data)
{
	struct grab_1st_switch_cbdata *cb = cb_data;
	const char *target = NULL, *end;

	if (!skip_prefix(message, "checkout: moving from ", &message))
		return 0;
	target = strstr(message, " to ");
	if (!target)
		return 0;
	target += strlen(" to ");
	strbuf_reset(&cb->buf);
	oidcpy(&cb->noid, noid);
	end = strchrnul(target, '\n');
	strbuf_add(&cb->buf, target, end - target);
	if (!strcmp(cb->buf.buf, "HEAD")) {
		/* HEAD is relative. Resolve it to the right reflog entry. */
		strbuf_reset(&cb->buf);
		strbuf_add_unique_abbrev(&cb->buf, noid, DEFAULT_ABBREV);
	}
	return 1;
}

static void wt_status_get_detached_from(struct repository *r,
					struct wt_status_state *state)
{
	struct grab_1st_switch_cbdata cb;
	struct commit *commit;
	struct object_id oid;
	char *ref = NULL;

	strbuf_init(&cb.buf, 0);
	if (refs_for_each_reflog_ent_reverse(get_main_ref_store(r), "HEAD", grab_1st_switch, &cb) <= 0) {
		strbuf_release(&cb.buf);
		return;
	}

	if (repo_dwim_ref(r, cb.buf.buf, cb.buf.len, &oid, &ref,
			  1) == 1 &&
	    /* oid is a commit? match without further lookup */
	    (oideq(&cb.noid, &oid) ||
	     /* perhaps oid is a tag, try to dereference to a commit */
	     ((commit = lookup_commit_reference_gently(r, &oid, 1)) != NULL &&
	      oideq(&cb.noid, &commit->object.oid)))) {
		const char *from = ref;
		if (!skip_prefix(from, "refs/tags/", &from))
			skip_prefix(from, "refs/remotes/", &from);
		state->detached_from = xstrdup(from);
	} else
		state->detached_from =
			xstrdup(repo_find_unique_abbrev(r, &cb.noid, DEFAULT_ABBREV));
	oidcpy(&state->detached_oid, &cb.noid);
	state->detached_at = !repo_get_oid(r, "HEAD", &oid) &&
			     oideq(&oid, &state->detached_oid);

	free(ref);
	strbuf_release(&cb.buf);
}

int wt_status_check_rebase(const struct worktree *wt,
			   struct wt_status_state *state)
{
	struct stat st;

	if (!wt)
		BUG("wt_status_check_rebase() called with NULL worktree");

	if (!stat(worktree_git_path(wt, "rebase-apply"), &st)) {
		if (!stat(worktree_git_path(wt, "rebase-apply/applying"), &st)) {
			state->am_in_progress = 1;
			if (!stat(worktree_git_path(wt, "rebase-apply/patch"), &st) && !st.st_size)
				state->am_empty_patch = 1;
		} else {
			state->rebase_in_progress = 1;
			state->branch = get_branch(wt, "rebase-apply/head-name");
			state->onto = get_branch(wt, "rebase-apply/onto");
		}
	} else if (!stat(worktree_git_path(wt, "rebase-merge"), &st)) {
		if (!stat(worktree_git_path(wt, "rebase-merge/interactive"), &st))
			state->rebase_interactive_in_progress = 1;
		else
			state->rebase_in_progress = 1;
		state->branch = get_branch(wt, "rebase-merge/head-name");
		state->onto = get_branch(wt, "rebase-merge/onto");
	} else
		return 0;
	return 1;
}

int wt_status_check_bisect(const struct worktree *wt,
			   struct wt_status_state *state)
{
	struct stat st;

	if (!wt)
		BUG("wt_status_check_bisect() called with NULL worktree");

	if (!stat(worktree_git_path(wt, "BISECT_LOG"), &st)) {
		state->bisect_in_progress = 1;
		state->bisecting_from = get_branch(wt, "BISECT_START");
		return 1;
	}
	return 0;
}

static void wt_status_check_sparse_checkout(struct repository *r,
					    struct wt_status_state *state)
{
	int skip_worktree = 0;
	int i;
	struct repo_config_values *cfg = repo_config_values(the_repository);

	if (!cfg->apply_sparse_checkout ||
	    r->index->cache_nr == 0) {
		/*
		 * Don't compute percentage of checked out files if we
		 * aren't in a sparse checkout or would get division by 0.
		 */
		state->sparse_checkout_percentage = SPARSE_CHECKOUT_DISABLED;
		return;
	}

	if (r->index->sparse_index) {
		state->sparse_checkout_percentage = SPARSE_CHECKOUT_SPARSE_INDEX;
		return;
	}

	for (i = 0; i < r->index->cache_nr; i++) {
		struct cache_entry *ce = r->index->cache[i];
		if (ce_skip_worktree(ce))
			skip_worktree++;
	}

	state->sparse_checkout_percentage =
		100 - (100 * skip_worktree)/r->index->cache_nr;
}

void wt_status_get_state(struct repository *r,
			 struct wt_status_state *state,
			 int get_detached_from)
{
	struct stat st;
	struct object_id oid;
	enum replay_action action;
	struct worktree *wt = get_current_worktree(r);

	if (!stat(git_path_merge_head(r), &st)) {
		wt_status_check_rebase(wt, state);
		state->merge_in_progress = 1;
	} else if (wt_status_check_rebase(wt, state)) {
		;		/* all set */
	} else if (refs_ref_exists(get_main_ref_store(r), "CHERRY_PICK_HEAD") &&
		   !repo_get_oid(r, "CHERRY_PICK_HEAD", &oid)) {
		state->cherry_pick_in_progress = 1;
		oidcpy(&state->cherry_pick_head_oid, &oid);
	}
	wt_status_check_bisect(wt, state);
	if (refs_ref_exists(get_main_ref_store(r), "REVERT_HEAD") &&
	    !repo_get_oid(r, "REVERT_HEAD", &oid)) {
		state->revert_in_progress = 1;
		oidcpy(&state->revert_head_oid, &oid);
	}
	if (!sequencer_get_last_command(r, &action)) {
		if (action == REPLAY_PICK && !state->cherry_pick_in_progress) {
			state->cherry_pick_in_progress = 1;
			oidcpy(&state->cherry_pick_head_oid, null_oid(r->hash_algo));
		} else if (action == REPLAY_REVERT && !state->revert_in_progress) {
			state->revert_in_progress = 1;
			oidcpy(&state->revert_head_oid, null_oid(r->hash_algo));
		}
	}
	if (get_detached_from)
		wt_status_get_detached_from(r, state);
	wt_status_check_sparse_checkout(r, state);

	free_worktree(wt);
}

static void wt_longstatus_print_state(struct wt_status *s)
{
	const char *state_color = color(WT_STATUS_HEADER, s);
	struct wt_status_state *state = &s->state;

	if (state->merge_in_progress) {
		if (state->rebase_interactive_in_progress) {
			show_rebase_information(s, state_color);
			fputs("\n", s->fp);
		}
		show_merge_in_progress(s, state_color);
	} else if (state->am_in_progress)
		show_am_in_progress(s, state_color);
	else if (state->rebase_in_progress || state->rebase_interactive_in_progress)
		show_rebase_in_progress(s, state_color);
	else if (state->cherry_pick_in_progress)
		show_cherry_pick_in_progress(s, state_color);
	else if (state->revert_in_progress)
		show_revert_in_progress(s, state_color);
	if (state->bisect_in_progress)
		show_bisect_in_progress(s, state_color);

	if (state->sparse_checkout_percentage != SPARSE_CHECKOUT_DISABLED)
		show_sparse_checkout_in_use(s, state_color);
}

static void wt_longstatus_print(struct wt_status *s)
{
	const char *branch_color = color(WT_STATUS_ONBRANCH, s);
	const char *branch_status_color = color(WT_STATUS_HEADER, s);
	enum fsmonitor_mode fsm_mode = fsm_settings__get_mode(s->repo);

	if (s->branch) {
		const char *on_what = _("On branch ");
		const char *branch_name = s->branch;
		if (!strcmp(branch_name, "HEAD")) {
			branch_status_color = color(WT_STATUS_NOBRANCH, s);
			if (s->state.rebase_in_progress ||
			    s->state.rebase_interactive_in_progress) {
				if (s->state.rebase_interactive_in_progress)
					on_what = _("interactive rebase in progress; onto ");
				else
					on_what = _("rebase in progress; onto ");
				branch_name = s->state.onto;
			} else if (s->state.detached_from) {
				branch_name = s->state.detached_from;
				if (s->state.detached_at)
					on_what = _("HEAD detached at ");
				else
					on_what = _("HEAD detached from ");
			} else {
				branch_name = "";
				on_what = _("Not currently on any branch.");
			}
		} else
			skip_prefix(branch_name, "refs/heads/", &branch_name);
		status_printf(s, color(WT_STATUS_HEADER, s), "%s", "");
		status_printf_more(s, branch_status_color, "%s", on_what);
		status_printf_more(s, branch_color, "%s\n", branch_name);
		if (!s->is_initial)
			wt_longstatus_print_tracking(s);
	}

	wt_longstatus_print_state(s);

	if (s->is_initial) {
		status_printf_ln(s, color(WT_STATUS_HEADER, s), "%s", "");
		status_printf_ln(s, color(WT_STATUS_HEADER, s),
				 s->commit_template
				 ? _("Initial commit")
				 : _("No commits yet"));
		status_printf_ln(s, color(WT_STATUS_HEADER, s), "%s", "");
	}

	wt_longstatus_print_updated(s);
	wt_longstatus_print_unmerged(s);
	wt_longstatus_print_changed(s);
	if (s->submodule_summary &&
	    (!s->ignore_submodule_arg ||
	     strcmp(s->ignore_submodule_arg, "all"))) {
		wt_longstatus_print_submodule_summary(s, 0);  /* staged */
		wt_longstatus_print_submodule_summary(s, 1);  /* unstaged */
	}
	if (s->show_untracked_files) {
		wt_longstatus_print_other(s, &s->untracked, _("Untracked files"), "add");
		if (s->show_ignored_mode)
			wt_longstatus_print_other(s, &s->ignored, _("Ignored files"), "add -f");
		if (advice_enabled(ADVICE_STATUS_U_OPTION) && uf_was_slow(s)) {
			status_printf_ln(s, GIT_COLOR_NORMAL, "%s", "");
			if (fsm_mode > FSMONITOR_MODE_DISABLED) {
				status_printf_ln(s, GIT_COLOR_NORMAL,
						_("It took %.2f seconds to enumerate untracked files,\n"
						"but the results were cached, and subsequent runs may be faster."),
						s->untracked_in_ms / 1000.0);
			} else {
				status_printf_ln(s, GIT_COLOR_NORMAL,
						_("It took %.2f seconds to enumerate untracked files."),
						s->untracked_in_ms / 1000.0);
			}
			status_printf_ln(s, GIT_COLOR_NORMAL,
					_("See 'git help status' for information on how to improve this."));
			status_printf_ln(s, GIT_COLOR_NORMAL, "%s", "");
		}
	} else if (s->committable)
		status_printf_ln(s, GIT_COLOR_NORMAL, _("Untracked files not listed%s"),
			s->hints
			? _(" (use -u option to show untracked files)") : "");

	if (s->verbose)
		wt_longstatus_print_verbose(s);
	if (!s->committable) {
		if (s->amend)
			status_printf_ln(s, GIT_COLOR_NORMAL, _("No changes"));
		else if (s->nowarn)
			; /* nothing */
		else if (s->workdir_dirty) {
			if (s->hints)
				fprintf(s->fp, _("no changes added to commit "
						 "(use \"git add\" and/or "
						 "\"git commit -a\")\n"));
			else
				fprintf(s->fp, _("no changes added to "
						 "commit\n"));
		} else if (s->untracked.nr) {
			if (s->hints)
				fprintf(s->fp, _("nothing added to commit but "
						 "untracked files present (use "
						 "\"git add\" to track)\n"));
			else
				fprintf(s->fp, _("nothing added to commit but "
						 "untracked files present\n"));
		} else if (s->is_initial) {
			if (s->hints)
				fprintf(s->fp, _("nothing to commit (create/"
						 "copy files and use \"git "
						 "add\" to track)\n"));
			else
				fprintf(s->fp, _("nothing to commit\n"));
		} else if (!s->show_untracked_files) {
			if (s->hints)
				fprintf(s->fp, _("nothing to commit (use -u to "
						 "show untracked files)\n"));
			else
				fprintf(s->fp, _("nothing to commit\n"));
		} else
			fprintf(s->fp, _("nothing to commit, working tree "
					 "clean\n"));
	}
	if(s->show_stash)
		wt_longstatus_print_stash_summary(s);
}

static void wt_shortstatus_unmerged(struct string_list_item *it,
			   struct wt_status *s)
{
	struct wt_status_change_data *d = it->util;
	const char *how = "??";

	switch (d->stagemask) {
	case 1: how = "DD"; break; /* both deleted */
	case 2: how = "AU"; break; /* added by us */
	case 3: how = "UD"; break; /* deleted by them */
	case 4: how = "UA"; break; /* added by them */
	case 5: how = "DU"; break; /* deleted by us */
	case 6: how = "AA"; break; /* both added */
	case 7: how = "UU"; break; /* both modified */
	}
	color_fprintf(s->fp, color(WT_STATUS_UNMERGED, s), "%s", how);
	if (s->null_termination) {
		fprintf(s->fp, " %s%c", it->string, 0);
	} else {
		struct strbuf onebuf = STRBUF_INIT;
		const char *one;
		one = quote_path(it->string, s->prefix, &onebuf, QUOTE_PATH_QUOTE_SP);
		fprintf(s->fp, " %s\n", one);
		strbuf_release(&onebuf);
	}
}

static void wt_shortstatus_status(struct string_list_item *it,
			 struct wt_status *s)
{
	struct wt_status_change_data *d = it->util;

	if (d->index_status)
		color_fprintf(s->fp, color(WT_STATUS_UPDATED, s), "%c", d->index_status);
	else
		fputc(' ', s->fp);
	if (d->worktree_status)
		color_fprintf(s->fp, color(WT_STATUS_CHANGED, s), "%c", d->worktree_status);
	else
		fputc(' ', s->fp);
	fputc(' ', s->fp);
	if (s->null_termination) {
		fprintf(s->fp, "%s%c", it->string, 0);
		if (d->rename_source)
			fprintf(s->fp, "%s%c", d->rename_source, 0);
	} else {
		struct strbuf onebuf = STRBUF_INIT;
		const char *one;

		if (d->rename_source) {
			one = quote_path(d->rename_source, s->prefix, &onebuf,
					 QUOTE_PATH_QUOTE_SP);
			fprintf(s->fp, "%s -> ", one);
			strbuf_release(&onebuf);
		}
		one = quote_path(it->string, s->prefix, &onebuf, QUOTE_PATH_QUOTE_SP);
		fprintf(s->fp, "%s\n", one);
		strbuf_release(&onebuf);
	}
}

static void wt_shortstatus_other(struct string_list_item *it,
				 struct wt_status *s, const char *sign)
{
	color_fprintf(s->fp, color(WT_STATUS_UNTRACKED, s), "%s", sign);
	if (s->null_termination) {
		fprintf(s->fp, " %s%c", it->string, 0);
	} else {
		struct strbuf onebuf = STRBUF_INIT;
		const char *one;
		one = quote_path(it->string, s->prefix, &onebuf, QUOTE_PATH_QUOTE_SP);
		fprintf(s->fp, " %s\n", one);
		strbuf_release(&onebuf);
	}
}

static void wt_shortstatus_print_tracking(struct wt_status *s)
{
	struct branch *branch;
	const char *header_color = color(WT_STATUS_HEADER, s);
	const char *branch_color_local = color(WT_STATUS_LOCAL_BRANCH, s);
	const char *branch_color_remote = color(WT_STATUS_REMOTE_BRANCH, s);

	const char *base;
	char *short_base;
	const char *branch_name;
	int num_ours, num_theirs, sti;
	int upstream_is_gone = 0;

	color_fprintf(s->fp, color(WT_STATUS_HEADER, s), "## ");

	if (!s->branch)
		return;
	branch_name = s->branch;

#define LABEL(string) (s->no_gettext ? (string) : _(string))

	if (s->is_initial)
		color_fprintf(s->fp, header_color, LABEL(N_("No commits yet on ")));

	if (!strcmp(s->branch, "HEAD")) {
		color_fprintf(s->fp, color(WT_STATUS_NOBRANCH, s), "%s",
			      LABEL(N_("HEAD (no branch)")));
		goto conclude;
	}

	skip_prefix(branch_name, "refs/heads/", &branch_name);

	branch = branch_get(branch_name);

	color_fprintf(s->fp, branch_color_local, "%s", branch_name);

	sti = stat_tracking_info(branch, &num_ours, &num_theirs, &base,
				 0, s->ahead_behind_flags);
	if (sti < 0) {
		if (!base)
			goto conclude;

		upstream_is_gone = 1;
	}

	short_base = refs_shorten_unambiguous_ref(get_main_ref_store(s->repo),
						  base, 0);
	color_fprintf(s->fp, header_color, "...");
	color_fprintf(s->fp, branch_color_remote, "%s", short_base);
	free(short_base);

	if (!upstream_is_gone && !sti)
		goto conclude;

	color_fprintf(s->fp, header_color, " [");
	if (upstream_is_gone) {
		color_fprintf(s->fp, header_color, LABEL(N_("gone")));
	} else if (s->ahead_behind_flags == AHEAD_BEHIND_QUICK) {
		color_fprintf(s->fp, header_color, LABEL(N_("different")));
	} else if (!num_ours) {
		color_fprintf(s->fp, header_color, LABEL(N_("behind ")));
		color_fprintf(s->fp, branch_color_remote, "%d", num_theirs);
	} else if (!num_theirs) {
		color_fprintf(s->fp, header_color, LABEL(N_("ahead ")));
		color_fprintf(s->fp, branch_color_local, "%d", num_ours);
	} else {
		color_fprintf(s->fp, header_color, LABEL(N_("ahead ")));
		color_fprintf(s->fp, branch_color_local, "%d", num_ours);
		color_fprintf(s->fp, header_color, ", %s", LABEL(N_("behind ")));
		color_fprintf(s->fp, branch_color_remote, "%d", num_theirs);
	}

	color_fprintf(s->fp, header_color, "]");
 conclude:
	fputc(s->null_termination ? '\0' : '\n', s->fp);
}

static void wt_shortstatus_print(struct wt_status *s)
{
	struct string_list_item *it;

	if (s->show_branch)
		wt_shortstatus_print_tracking(s);

	for_each_string_list_item(it, &s->change) {
		struct wt_status_change_data *d = it->util;

		if (d->stagemask)
			wt_shortstatus_unmerged(it, s);
		else
			wt_shortstatus_status(it, s);
	}
	for_each_string_list_item(it, &s->untracked)
		wt_shortstatus_other(it, s, "??");

	for_each_string_list_item(it, &s->ignored)
		wt_shortstatus_other(it, s, "!!");
}

static void wt_porcelain_print(struct wt_status *s)
{
	s->use_color = GIT_COLOR_NEVER;
	s->relative_paths = 0;
	s->prefix = NULL;
	s->no_gettext = 1;
	wt_shortstatus_print(s);
}

/*
 * Print branch information for porcelain v2 output.  These lines
 * are printed when the '--branch' parameter is given.
 *
 *    # branch.oid <commit><eol>
 *    # branch.head <head><eol>
 *   [# branch.upstream <upstream><eol>
 *   [# branch.ab +<ahead> -<behind><eol>]]
 *
 *      <commit> ::= the current commit hash or the literal
 *                   "(initial)" to indicate an initialized repo
 *                   with no commits.
 *
 *        <head> ::= <branch_name> the current branch name or
 *                   "(detached)" literal when detached head or
 *                   "(unknown)" when something is wrong.
 *
 *    <upstream> ::= the upstream branch name, when set.
 *
 *       <ahead> ::= integer ahead value or '?'.
 *
 *      <behind> ::= integer behind value or '?'.
 *
 * The end-of-line is defined by the -z flag.
 *
 *                 <eol> ::= NUL when -z,
 *                           LF when NOT -z.
 *
 * When an upstream is set and present, the 'branch.ab' line will
 * be printed with the ahead/behind counts for the branch and the
 * upstream.  When AHEAD_BEHIND_QUICK is requested and the branches
 * are different, '?' will be substituted for the actual count.
 */
static void wt_porcelain_v2_print_tracking(struct wt_status *s)
{
	struct branch *branch;
	const char *base;
	const char *branch_name;
	int ab_info, nr_ahead, nr_behind;
	char eol = s->null_termination ? '\0' : '\n';

	fprintf(s->fp, "# branch.oid %s%c",
			(s->is_initial ? "(initial)" : oid_to_hex(&s->oid_commit)),
			eol);

	if (!s->branch)
		fprintf(s->fp, "# branch.head %s%c", "(unknown)", eol);
	else {
		if (!strcmp(s->branch, "HEAD")) {
			fprintf(s->fp, "# branch.head %s%c", "(detached)", eol);

			if (s->state.rebase_in_progress ||
			    s->state.rebase_interactive_in_progress)
				branch_name = s->state.onto;
			else if (s->state.detached_from)
				branch_name = s->state.detached_from;
			else
				branch_name = "";
		} else {
			branch_name = NULL;
			skip_prefix(s->branch, "refs/heads/", &branch_name);

			fprintf(s->fp, "# branch.head %s%c", branch_name, eol);
		}

		/* Lookup stats on the upstream tracking branch, if set. */
		branch = branch_get(branch_name);
		base = NULL;
		ab_info = stat_tracking_info(branch, &nr_ahead, &nr_behind,
					     &base, 0, s->ahead_behind_flags);
		if (base) {
			base = refs_shorten_unambiguous_ref(get_main_ref_store(s->repo),
							    base, 0);
			fprintf(s->fp, "# branch.upstream %s%c", base, eol);
			free((char *)base);

			if (ab_info > 0) {
				/* different */
				if (nr_ahead || nr_behind)
					fprintf(s->fp, "# branch.ab +%d -%d%c",
						nr_ahead, nr_behind, eol);
				else
					fprintf(s->fp, "# branch.ab +? -?%c",
						eol);
			} else if (!ab_info) {
				/* same */
				fprintf(s->fp, "# branch.ab +0 -0%c", eol);
			}
		}
	}
}

/*
 * Print the stash count in a porcelain-friendly format
 */
static void wt_porcelain_v2_print_stash(struct wt_status *s)
{
	int stash_count = count_stash_entries(s->repo);
	char eol = s->null_termination ? '\0' : '\n';

	if (stash_count > 0)
		fprintf(s->fp, "# stash %d%c", stash_count, eol);
}

/*
 * Convert various submodule status values into a
 * fixed-length string of characters in the buffer provided.
 */
static void wt_porcelain_v2_submodule_state(
	struct wt_status_change_data *d,
	char sub[5])
{
	if (S_ISGITLINK(d->mode_head) ||
		S_ISGITLINK(d->mode_index) ||
		S_ISGITLINK(d->mode_worktree)) {
		sub[0] = 'S';
		sub[1] = d->new_submodule_commits ? 'C' : '.';
		sub[2] = (d->dirty_submodule & DIRTY_SUBMODULE_MODIFIED) ? 'M' : '.';
		sub[3] = (d->dirty_submodule & DIRTY_SUBMODULE_UNTRACKED) ? 'U' : '.';
	} else {
		sub[0] = 'N';
		sub[1] = '.';
		sub[2] = '.';
		sub[3] = '.';
	}
	sub[4] = 0;
}

/*
 * Fix-up changed entries before we print them.
 */
static void wt_porcelain_v2_fix_up_changed(struct string_list_item *it)
{
	struct wt_status_change_data *d = it->util;

	if (!d->index_status) {
		/*
		 * This entry is unchanged in the index (relative to the head).
		 * Therefore, the collect_updated_cb was never called for this
		 * entry (during the head-vs-index scan) and so the head column
		 * fields were never set.
		 *
		 * We must have data for the index column (from the
		 * index-vs-worktree scan (otherwise, this entry should not be
		 * in the list of changes)).
		 *
		 * Copy index column fields to the head column, so that our
		 * output looks complete.
		 */
		assert(d->mode_head == 0);
		d->mode_head = d->mode_index;
		oidcpy(&d->oid_head, &d->oid_index);
	}

	if (!d->worktree_status) {
		/*
		 * This entry is unchanged in the worktree (relative to the index).
		 * Therefore, the collect_changed_cb was never called for this entry
		 * (during the index-vs-worktree scan) and so the worktree column
		 * fields were never set.
		 *
		 * We must have data for the index column (from the head-vs-index
		 * scan).
		 *
		 * Copy the index column fields to the worktree column so that
		 * our output looks complete.
		 *
		 * Note that we only have a mode field in the worktree column
		 * because the scan code tries really hard to not have to compute it.
		 */
		assert(d->mode_worktree == 0);
		d->mode_worktree = d->mode_index;
	}
}

/*
 * Print porcelain v2 info for tracked entries with changes.
 */
static void wt_porcelain_v2_print_changed_entry(
	struct string_list_item *it,
	struct wt_status *s)
{
	struct wt_status_change_data *d = it->util;
	struct strbuf buf = STRBUF_INIT;
	struct strbuf buf_from = STRBUF_INIT;
	const char *path = NULL;
	const char *path_from = NULL;
	char key[3];
	char submodule_token[5];
	char sep_char, eol_char;

	wt_porcelain_v2_fix_up_changed(it);
	wt_porcelain_v2_submodule_state(d, submodule_token);

	key[0] = d->index_status ? d->index_status : '.';
	key[1] = d->worktree_status ? d->worktree_status : '.';
	key[2] = 0;

	if (s->null_termination) {
		/*
		 * In -z mode, we DO NOT C-quote pathnames.  Current path is ALWAYS first.
		 * A single NUL character separates them.
		 */
		sep_char = '\0';
		eol_char = '\0';
		path = it->string;
		path_from = d->rename_source;
	} else {
		/*
		 * Path(s) are C-quoted if necessary. Current path is ALWAYS first.
		 * The source path is only present when necessary.
		 * A single TAB separates them (because paths can contain spaces
		 * which are not escaped and C-quoting does escape TAB characters).
		 */
		sep_char = '\t';
		eol_char = '\n';
		path = quote_path(it->string, s->prefix, &buf, 0);
		if (d->rename_source)
			path_from = quote_path(d->rename_source, s->prefix, &buf_from, 0);
	}

	if (path_from)
		fprintf(s->fp, "2 %s %s %06o %06o %06o %s %s %c%d %s%c%s%c",
				key, submodule_token,
				d->mode_head, d->mode_index, d->mode_worktree,
				oid_to_hex(&d->oid_head), oid_to_hex(&d->oid_index),
				d->rename_status, d->rename_score,
				path, sep_char, path_from, eol_char);
	else
		fprintf(s->fp, "1 %s %s %06o %06o %06o %s %s %s%c",
				key, submodule_token,
				d->mode_head, d->mode_index, d->mode_worktree,
				oid_to_hex(&d->oid_head), oid_to_hex(&d->oid_index),
				path, eol_char);

	strbuf_release(&buf);
	strbuf_release(&buf_from);
}

/*
 * Print porcelain v2 status info for unmerged entries.
 */
static void wt_porcelain_v2_print_unmerged_entry(
	struct string_list_item *it,
	struct wt_status *s)
{
	struct wt_status_change_data *d = it->util;
	struct index_state *istate = s->repo->index;
	const struct cache_entry *ce;
	struct strbuf buf_index = STRBUF_INIT;
	const char *path_index = NULL;
	int pos, stage, sum;
	struct {
		int mode;
		struct object_id oid;
	} stages[3];
	const char *key;
	char submodule_token[5];
	char unmerged_prefix = 'u';
	char eol_char = s->null_termination ? '\0' : '\n';

	wt_porcelain_v2_submodule_state(d, submodule_token);

	switch (d->stagemask) {
	case 1: key = "DD"; break; /* both deleted */
	case 2: key = "AU"; break; /* added by us */
	case 3: key = "UD"; break; /* deleted by them */
	case 4: key = "UA"; break; /* added by them */
	case 5: key = "DU"; break; /* deleted by us */
	case 6: key = "AA"; break; /* both added */
	case 7: key = "UU"; break; /* both modified */
	default:
		BUG("unhandled unmerged status %x", d->stagemask);
	}

	/*
	 * Disregard d.aux.porcelain_v2 data that we accumulated
	 * for the head and index columns during the scans and
	 * replace with the actual stage data.
	 *
	 * Note that this is a last-one-wins for each the individual
	 * stage [123] columns in the event of multiple cache entries
	 * for same stage.
	 */
	memset(stages, 0, sizeof(stages));
	sum = 0;
	pos = index_name_pos(istate, it->string, strlen(it->string));
	assert(pos < 0);
	pos = -pos-1;
	while (pos < istate->cache_nr) {
		ce = istate->cache[pos++];
		stage = ce_stage(ce);
		if (strcmp(ce->name, it->string) || !stage)
			break;
		stages[stage - 1].mode = ce->ce_mode;
		oidcpy(&stages[stage - 1].oid, &ce->oid);
		sum |= (1 << (stage - 1));
	}
	if (sum != d->stagemask)
		BUG("observed stagemask 0x%x != expected stagemask 0x%x", sum, d->stagemask);

	if (s->null_termination)
		path_index = it->string;
	else
		path_index = quote_path(it->string, s->prefix, &buf_index, 0);

	fprintf(s->fp, "%c %s %s %06o %06o %06o %06o %s %s %s %s%c",
			unmerged_prefix, key, submodule_token,
			stages[0].mode, /* stage 1 */
			stages[1].mode, /* stage 2 */
			stages[2].mode, /* stage 3 */
			d->mode_worktree,
			oid_to_hex(&stages[0].oid), /* stage 1 */
			oid_to_hex(&stages[1].oid), /* stage 2 */
			oid_to_hex(&stages[2].oid), /* stage 3 */
			path_index,
			eol_char);

	strbuf_release(&buf_index);
}

/*
 * Print porcelain V2 status info for untracked and ignored entries.
 */
static void wt_porcelain_v2_print_other(
	struct string_list_item *it,
	struct wt_status *s,
	char prefix)
{
	struct strbuf buf = STRBUF_INIT;
	const char *path;
	char eol_char;

	if (s->null_termination) {
		path = it->string;
		eol_char = '\0';
	} else {
		path = quote_path(it->string, s->prefix, &buf, 0);
		eol_char = '\n';
	}

	fprintf(s->fp, "%c %s%c", prefix, path, eol_char);

	strbuf_release(&buf);
}

/*
 * Print porcelain V2 status.
 *
 * [<v2_branch>]
 * [<v2_changed_items>]*
 * [<v2_unmerged_items>]*
 * [<v2_untracked_items>]*
 * [<v2_ignored_items>]*
 *
 */
static void wt_porcelain_v2_print(struct wt_status *s)
{
	struct wt_status_change_data *d;
	struct string_list_item *it;
	int i;

	if (s->show_branch)
		wt_porcelain_v2_print_tracking(s);

	if (s->show_stash)
		wt_porcelain_v2_print_stash(s);

	for (i = 0; i < s->change.nr; i++) {
		it = &(s->change.items[i]);
		d = it->util;
		if (!d->stagemask)
			wt_porcelain_v2_print_changed_entry(it, s);
	}

	for (i = 0; i < s->change.nr; i++) {
		it = &(s->change.items[i]);
		d = it->util;
		if (d->stagemask)
			wt_porcelain_v2_print_unmerged_entry(it, s);
	}

	for (i = 0; i < s->untracked.nr; i++) {
		it = &(s->untracked.items[i]);
		wt_porcelain_v2_print_other(it, s, '?');
	}

	for (i = 0; i < s->ignored.nr; i++) {
		it = &(s->ignored.items[i]);
		wt_porcelain_v2_print_other(it, s, '!');
	}
}

void wt_status_print(struct wt_status *s)
{
	trace2_data_intmax("status", s->repo, "count/changed", s->change.nr);
	trace2_data_intmax("status", s->repo, "count/untracked",
			   s->untracked.nr);
	trace2_data_intmax("status", s->repo, "count/ignored", s->ignored.nr);

	trace2_region_enter("status", "print", s->repo);

	switch (s->status_format) {
	case STATUS_FORMAT_SHORT:
		wt_shortstatus_print(s);
		break;
	case STATUS_FORMAT_PORCELAIN:
		wt_porcelain_print(s);
		break;
	case STATUS_FORMAT_PORCELAIN_V2:
		wt_porcelain_v2_print(s);
		break;
	case STATUS_FORMAT_UNSPECIFIED:
		BUG("finalize_deferred_config() should have been called");
		break;
	case STATUS_FORMAT_NONE:
	case STATUS_FORMAT_LONG:
		wt_longstatus_print(s);
		break;
	}

	trace2_region_leave("status", "print", s->repo);
}

/**
 * Returns 1 if there are unstaged changes, 0 otherwise.
 */
int has_unstaged_changes(struct repository *r, int ignore_submodules)
{
	struct rev_info rev_info;
	int result;

	repo_init_revisions(r, &rev_info, NULL);
	if (ignore_submodules) {
		rev_info.diffopt.flags.ignore_submodules = 1;
		rev_info.diffopt.flags.override_submodule_config = 1;
	}
	rev_info.diffopt.flags.quick = 1;
	diff_setup_done(&rev_info.diffopt);
	run_diff_files(&rev_info, 0);
	result = diff_result_code(&rev_info);
	release_revisions(&rev_info);
	return result;
}

/**
 * Returns 1 if there are uncommitted changes, 0 otherwise.
 */
int has_uncommitted_changes(struct repository *r,
			    int ignore_submodules)
{
	struct rev_info rev_info;
	int result;

	if (is_index_unborn(r->index))
		return 0;

	repo_init_revisions(r, &rev_info, NULL);
	if (ignore_submodules)
		rev_info.diffopt.flags.ignore_submodules = 1;
	rev_info.diffopt.flags.quick = 1;

	add_head_to_pending(&rev_info);
	if (!rev_info.pending.nr) {
		/*
		 * We have no head (or it's corrupt); use the empty tree,
		 * which will complain if the index is non-empty.
		 */
		struct tree *tree = lookup_tree(r, r->hash_algo->empty_tree);
		add_pending_object(&rev_info, &tree->object, "");
	}

	diff_setup_done(&rev_info.diffopt);
	run_diff_index(&rev_info, DIFF_INDEX_CACHED);
	result = diff_result_code(&rev_info);
	release_revisions(&rev_info);
	return result;
}

/**
 * If the work tree has unstaged or uncommitted changes, dies with the
 * appropriate message.
 */
int require_clean_work_tree(struct repository *r,
			    const char *action,
			    const char *hint,
			    int ignore_submodules,
			    int gently)
{
	struct lock_file lock_file = LOCK_INIT;
	int err = 0, fd;

	fd = repo_hold_locked_index(r, &lock_file, 0);
	refresh_index(r->index, REFRESH_QUIET, NULL, NULL, NULL);
	if (0 <= fd)
		repo_update_index_if_able(r, &lock_file);
	rollback_lock_file(&lock_file);

	if (has_unstaged_changes(r, ignore_submodules)) {
		/* TRANSLATORS: the action is e.g. "pull with rebase" */
		error(_("cannot %s: You have unstaged changes."), _(action));
		err = 1;
	}

	if (has_uncommitted_changes(r, ignore_submodules)) {
		if (err)
			error(_("additionally, your index contains uncommitted changes."));
		else
			error(_("cannot %s: Your index contains uncommitted changes."),
			      _(action));
		err = 1;
	}

	if (err) {
		if (hint) {
			if (!*hint)
				BUG("empty hint passed to require_clean_work_tree();"
				    " use NULL instead");
			error("%s", hint);
		}
		if (!gently)
			exit(128);
	}

	return err;
}
