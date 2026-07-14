#define DISABLE_SIGN_COMPARE_WARNINGS

#include "git-compat-util.h"
#include "environment.h"
#include "gettext.h"
#include "hex.h"
#include "odb.h"
#include "commit.h"
#include "diff.h"
#include "revision.h"
#include "progress.h"
#include "pack.h"
#include "pack-bitmap.h"
#include "hash-lookup.h"
#include "pack-objects.h"
#include "path.h"
#include "commit-reach.h"
#include "prio-queue.h"
#include "trace2.h"
#include "tree.h"
#include "tree-walk.h"
#include "pseudo-merge.h"
#include "oid-array.h"
#include "config.h"
#include "alloc.h"
#include "refs.h"
#include "strmap.h"
#include "midx.h"
#include "pack-revindex.h"

struct bitmapped_commit {
	struct commit *commit;
	struct ewah_bitmap *bitmap;
	struct ewah_bitmap *write_as;
	struct ewah_bitmap *pseudo_merge_parents;
	int flags;
	int xor_offset;
	uint32_t commit_pos;
	unsigned pseudo_merge : 1;
};

static inline int bitmap_writer_nr_selected_commits(struct bitmap_writer *writer)
{
	return writer->selected_nr - writer->pseudo_merges_nr;
}

void bitmap_writer_init(struct bitmap_writer *writer, struct repository *r,
			struct packing_data *pdata,
			struct multi_pack_index *midx)
{
	memset(writer, 0, sizeof(struct bitmap_writer));
	if (writer->bitmaps)
		BUG("bitmap writer already initialized");
	writer->repo = r;
	writer->bitmaps = kh_init_oid_map();
	writer->pseudo_merge_commits = kh_init_oid_map();
	writer->to_pack = pdata;
	writer->midx = midx;

	string_list_init_dup(&writer->pseudo_merge_groups);

	load_pseudo_merges_from_config(r, &writer->pseudo_merge_groups);
}

static void free_pseudo_merge_commit_idx(struct pseudo_merge_commit_idx *idx)
{
	if (!idx)
		return;
	free(idx->pseudo_merge);
	free(idx);
}

static void pseudo_merge_group_release_cb(void *payload, const char *name UNUSED)
{
	pseudo_merge_group_release(payload);
	free(payload);
}

void bitmap_writer_free(struct bitmap_writer *writer)
{
	uint32_t i;
	struct pseudo_merge_commit_idx *idx;

	if (!writer)
		return;

	ewah_free(writer->commits);
	ewah_free(writer->trees);
	ewah_free(writer->blobs);
	ewah_free(writer->tags);

	kh_destroy_oid_map(writer->bitmaps);
	free(writer->pos_cache);

	kh_foreach_value(writer->pseudo_merge_commits, idx,
			 free_pseudo_merge_commit_idx(idx));
	kh_destroy_oid_map(writer->pseudo_merge_commits);
	string_list_clear_func(&writer->pseudo_merge_groups,
			       pseudo_merge_group_release_cb);

	for (i = 0; i < writer->selected_nr; i++) {
		struct bitmapped_commit *bc = &writer->selected[i];
		if (bc->write_as != bc->bitmap)
			ewah_free(bc->write_as);
		ewah_free(bc->bitmap);
		ewah_free(bc->pseudo_merge_parents);
	}
	free(writer->selected);
}

void bitmap_writer_show_progress(struct bitmap_writer *writer, int show)
{
	writer->show_progress = show;
}

/**
 * Build the initial type index for the packfile or multi-pack-index
 */
void bitmap_writer_build_type_index(struct bitmap_writer *writer,
				    struct pack_idx_entry **index)
{
	uint32_t i;
	uint32_t base_objects = 0;

	if (writer->midx)
		base_objects = writer->midx->num_objects +
			writer->midx->num_objects_in_base;

	writer->commits = ewah_new();
	writer->trees = ewah_new();
	writer->blobs = ewah_new();
	writer->tags = ewah_new();
	ALLOC_ARRAY(writer->to_pack->in_pack_pos, writer->to_pack->nr_objects);

	for (i = 0; i < writer->to_pack->nr_objects; ++i) {
		struct object_entry *entry = (struct object_entry *)index[i];
		enum object_type real_type;

		oe_set_in_pack_pos(writer->to_pack, entry, i);

		switch (oe_type(entry)) {
		case OBJ_COMMIT:
		case OBJ_TREE:
		case OBJ_BLOB:
		case OBJ_TAG:
			real_type = oe_type(entry);
			break;

		default:
			real_type = odb_read_object_info(writer->to_pack->repo->objects,
							 &entry->idx.oid, NULL);
			break;
		}

		switch (real_type) {
		case OBJ_COMMIT:
			ewah_set(writer->commits, i + base_objects);
			break;

		case OBJ_TREE:
			ewah_set(writer->trees, i + base_objects);
			break;

		case OBJ_BLOB:
			ewah_set(writer->blobs, i + base_objects);
			break;

		case OBJ_TAG:
			ewah_set(writer->tags, i + base_objects);
			break;

		default:
			die("Missing type information for %s (%d/%d)",
			    oid_to_hex(&entry->idx.oid), real_type,
			    oe_type(entry));
		}
	}
}

int bitmap_writer_has_bitmapped_object_id(struct bitmap_writer *writer,
					  const struct object_id *oid)
{
	return kh_get_oid_map(writer->bitmaps, *oid) != kh_end(writer->bitmaps);
}

/**
 * Compute the actual bitmaps
 */

void bitmap_writer_push_commit(struct bitmap_writer *writer,
			       struct commit *commit, unsigned pseudo_merge)
{
	if (writer->selected_nr >= writer->selected_alloc) {
		writer->selected_alloc = (writer->selected_alloc + 32) * 2;
		REALLOC_ARRAY(writer->selected, writer->selected_alloc);
	}

	if (!pseudo_merge) {
		int hash_ret;
		khiter_t hash_pos = kh_put_oid_map(writer->bitmaps,
						   commit->object.oid,
						   &hash_ret);

		if (!hash_ret)
			die(_("duplicate entry when writing bitmap index: %s"),
			    oid_to_hex(&commit->object.oid));
		kh_value(writer->bitmaps, hash_pos) = NULL;
	}

	writer->selected[writer->selected_nr].commit = commit;
	writer->selected[writer->selected_nr].bitmap = NULL;
	writer->selected[writer->selected_nr].write_as = NULL;
	writer->selected[writer->selected_nr].flags = 0;
	writer->selected[writer->selected_nr].pseudo_merge = pseudo_merge;
	writer->selected[writer->selected_nr].pseudo_merge_parents = NULL;

	writer->selected_nr++;
}

struct bitmap_pos_cache_entry {
	struct object_id oid;
	uint32_t pos;
};

#define BITMAP_POS_MIN_CACHE_SIZE (1U << 10)
#define BITMAP_POS_MAX_CACHE_SIZE (1U << 21)
#define BITMAP_POS_CACHE_VALID    (1U << 31)

static void bitmap_writer_init_pos_cache(struct bitmap_writer *writer)
{
	if (writer->pos_cache)
		return;

	writer->pos_cache_nr = BITMAP_POS_MIN_CACHE_SIZE;

	while (writer->pos_cache_nr < writer->to_pack->nr_objects &&
	       writer->pos_cache_nr < BITMAP_POS_MAX_CACHE_SIZE)
		writer->pos_cache_nr <<= 1;

	CALLOC_ARRAY(writer->pos_cache, writer->pos_cache_nr);
}

static size_t bitmap_writer_pos_cache_slot(struct bitmap_writer *writer,
					   const struct object_id *oid)
{
	return oidhash(oid) & (writer->pos_cache_nr - 1);
}

static bool bitmap_writer_pos_cache_valid(struct bitmap_writer *writer,
					  size_t slot)
{
	return !!(writer->pos_cache[slot].pos & BITMAP_POS_CACHE_VALID);
}

static int find_cached_object_pos(struct bitmap_writer *writer,
				  const struct object_id *oid, uint32_t *pos)
{
	size_t slot = bitmap_writer_pos_cache_slot(writer, oid);

	if (bitmap_writer_pos_cache_valid(writer, slot) &&
	    oideq(&writer->pos_cache[slot].oid, oid)) {
		writer->pos_cache_hits++;
		*pos = writer->pos_cache[slot].pos & ~BITMAP_POS_CACHE_VALID;
		return 1;
	}

	writer->pos_cache_misses++;
	return 0;
}

static uint32_t store_cached_object_pos(struct bitmap_writer *writer,
					const struct object_id *oid,
					uint32_t pos)
{
	size_t slot;

	if (pos & BITMAP_POS_CACHE_VALID)
		return pos; /* too large to cache */

	slot = bitmap_writer_pos_cache_slot(writer, oid);

	oidcpy(&writer->pos_cache[slot].oid, oid);
	writer->pos_cache[slot].pos = pos | BITMAP_POS_CACHE_VALID;

	return pos;
}

static uint32_t find_object_pos(struct bitmap_writer *writer,
				const struct object_id *oid, int *found)
{
	struct object_entry *entry;
	uint32_t pos;

	bitmap_writer_init_pos_cache(writer);

	if (find_cached_object_pos(writer, oid, &pos)) {
		if (found)
			*found = 1;
		return pos;
	}

	entry = packlist_find(writer->to_pack, oid);
	if (entry) {
		uint32_t base_objects = 0;

		if (writer->midx)
			base_objects = writer->midx->num_objects +
				writer->midx->num_objects_in_base;
		pos = oe_in_pack_pos(writer->to_pack, entry) + base_objects;
	} else if (writer->midx) {
		uint32_t at;

		if (!bsearch_midx(oid, writer->midx, &at))
			goto missing;
		if (midx_to_pack_pos(writer->midx, at, &pos) < 0)
			goto missing;
	} else {
		goto missing;
	}

	if (found)
		*found = 1;
	return store_cached_object_pos(writer, oid, pos);

missing:
	if (found)
		*found = 0;
	warning("Failed to write bitmap index. Packfile doesn't have full closure "
		"(object %s is missing)", oid_to_hex(oid));
	return 0;
}

static int bitmapped_commit_date_cmp(const void *_a, const void *_b)
{
	const struct bitmapped_commit *a = _a;
	const struct bitmapped_commit *b = _b;

	if (a->commit->date < b->commit->date)
		return -1;
	if (a->commit->date > b->commit->date)
		return 1;
	return 0;
}

static void compute_xor_offsets(struct bitmap_writer *writer)
{
	static const int MAX_XOR_OFFSET_SEARCH = 10;

	int i, next = 0;
	int nr = bitmap_writer_nr_selected_commits(writer);

	if (nr > 1) {
		QSORT(writer->selected, nr, bitmapped_commit_date_cmp);

		for (i = 0; i < nr; i++) {
			struct bitmapped_commit *stored = &writer->selected[i];
			khiter_t hash_pos = kh_get_oid_map(writer->bitmaps,
							   stored->commit->object.oid);

			if (hash_pos == kh_end(writer->bitmaps))
				BUG("selected commit missing from bitmap map: %s",
				    oid_to_hex(&stored->commit->object.oid));

			kh_value(writer->bitmaps, hash_pos) = stored;
		}
	}

	while (next < writer->selected_nr) {
		struct bitmapped_commit *stored = &writer->selected[next];
		int best_offset = 0;
		struct ewah_bitmap *best_bitmap = stored->bitmap;
		struct ewah_bitmap *test_xor;

		if (stored->pseudo_merge)
			goto next;

		for (i = 1; i <= MAX_XOR_OFFSET_SEARCH; ++i) {
			int curr = next - i;

			if (curr < 0)
				break;
			if (writer->selected[curr].pseudo_merge)
				continue;

			test_xor = ewah_pool_new();
			ewah_xor(writer->selected[curr].bitmap, stored->bitmap, test_xor);

			if (test_xor->buffer_size < best_bitmap->buffer_size) {
				if (best_bitmap != stored->bitmap)
					ewah_pool_free(best_bitmap);

				best_bitmap = test_xor;
				best_offset = i;
			} else {
				ewah_pool_free(test_xor);
			}
		}

next:
		stored->xor_offset = best_offset;
		stored->write_as = best_bitmap;

		next++;
	}
}

struct bb_commit {
	struct commit_list *reverse_edges;
	struct bitmap *commit_mask;
	struct bitmap *bitmap;
	unsigned selected:1,
		 maximal:1,
		 pseudo_merge:1;
	unsigned idx; /* within selected array */
};

static void clear_bb_commit(struct bb_commit *commit)
{
	commit_list_free(commit->reverse_edges);
	bitmap_free(commit->commit_mask);
	bitmap_free(commit->bitmap);
}

define_commit_slab(bb_data, struct bb_commit);

struct bitmap_builder {
	struct bb_data data;
	struct commit_stack commits;
};

static void bitmap_builder_init(struct bitmap_builder *bb,
				struct bitmap_writer *writer,
				struct bitmap_index *old_bitmap)
{
	struct rev_info revs;
	struct commit *commit;
	struct commit_list *reusable = NULL;
	struct commit_list *r;
	unsigned int i, num_maximal = 0;

	init_bb_data(&bb->data);
	commit_stack_init(&bb->commits);

	reset_revision_walk();
	repo_init_revisions(writer->to_pack->repo, &revs, NULL);
	revs.topo_order = 1;
	revs.first_parent_only = 1;

	for (i = 0; i < bitmap_writer_nr_selected_commits(writer); i++) {
		struct bitmapped_commit *bc = &writer->selected[i];
		struct bb_commit *ent = bb_data_at(&bb->data, bc->commit);

		if (bc->pseudo_merge)
			BUG("unexpected pseudo-merge at %"PRIuMAX,
			    (uintmax_t)i);

		ent->selected = 1;
		ent->maximal = 1;
		ent->pseudo_merge = 0;
		ent->idx = i;

		ent->commit_mask = bitmap_new();
		bitmap_set(ent->commit_mask, i);

		add_pending_object(&revs, &bc->commit->object, "");
	}

	if (prepare_revision_walk(&revs))
		die("revision walk setup failed");

	while ((commit = get_revision(&revs))) {
		struct commit_list *p = commit->parents;
		struct bb_commit *c_ent;

		parse_commit_or_die(commit);

		c_ent = bb_data_at(&bb->data, commit);

		/*
		 * If there is no commit_mask, there is no reason to iterate
		 * over this commit; it is not selected (if it were, it would
		 * not have a blank commit mask) and all its children have
		 * existing bitmaps (see the comment starting with "This commit
		 * has an existing bitmap" below), so it does not contribute
		 * anything to the final bitmap file or its descendants.
		 */
		if (!c_ent->commit_mask)
			continue;

		if (old_bitmap && bitmap_for_commit(old_bitmap, commit)) {
			/*
			 * This commit has an existing bitmap, so we can
			 * get its bits immediately without an object
			 * walk. That is, it is reusable as-is and there is no
			 * need to continue walking beyond it.
			 *
			 * Mark it as such and add it to bb->commits separately
			 * to avoid allocating a position in the commit mask.
			 */
			commit_list_insert(commit, &reusable);
			goto next;
		}

		if (c_ent->maximal) {
			num_maximal++;
			commit_stack_push(&bb->commits, commit);
		}

		if (p) {
			struct bb_commit *p_ent = bb_data_at(&bb->data, p->item);
			int c_not_p, p_not_c;

			if (!p_ent->commit_mask) {
				p_ent->commit_mask = bitmap_new();
				c_not_p = 1;
				p_not_c = 0;
			} else {
				c_not_p = bitmap_is_subset(c_ent->commit_mask, p_ent->commit_mask);
				p_not_c = bitmap_is_subset(p_ent->commit_mask, c_ent->commit_mask);
			}

			if (!c_not_p)
				continue;

			bitmap_or(p_ent->commit_mask, c_ent->commit_mask);

			if (p_not_c)
				p_ent->maximal = 1;
			else {
				p_ent->maximal = 0;
				commit_list_free(p_ent->reverse_edges);
				p_ent->reverse_edges = NULL;
			}

			if (c_ent->maximal) {
				commit_list_insert(commit, &p_ent->reverse_edges);
			} else {
				struct commit_list *cc = c_ent->reverse_edges;

				for (; cc; cc = cc->next) {
					if (!commit_list_contains(cc->item, p_ent->reverse_edges))
						commit_list_insert(cc->item, &p_ent->reverse_edges);
				}
			}
		}

next:
		bitmap_free(c_ent->commit_mask);
		c_ent->commit_mask = NULL;
	}

	for (r = reusable; r; r = r->next) {
		commit_stack_push(&bb->commits, r->item);
	}

	trace2_data_intmax("pack-bitmap-write", writer->repo,
			   "num_selected_commits", writer->selected_nr);
	trace2_data_intmax("pack-bitmap-write", writer->repo,
			   "num_maximal_commits", num_maximal);

	release_revisions(&revs);
	commit_list_free(reusable);
}

static void bitmap_builder_clear(struct bitmap_builder *bb)
{
	deep_clear_bb_data(&bb->data, clear_bb_commit);
	commit_stack_clear(&bb->commits);
}

static int fill_bitmap_tree(struct bitmap_writer *writer,
			    struct bitmap *bitmap,
			    struct tree *tree,
			    uint32_t pos)
{
	int found;
	struct tree_desc desc;
	struct name_entry entry;

	bitmap_set(bitmap, pos);

	if (repo_parse_tree(writer->repo, tree) < 0)
		die("unable to load tree object %s",
		    oid_to_hex(&tree->object.oid));
	init_tree_desc(&desc, &tree->object.oid, tree->buffer, tree->size);

	while (tree_entry(&desc, &entry)) {
		switch (object_type(entry.mode)) {
		case OBJ_TREE:
			pos = find_object_pos(writer, &entry.oid, &found);
			if (!found)
				return -1;
			if (bitmap_get(bitmap, pos)) {
				/*
				 * If our bit is already set, then there
				 * is nothing to do. Both this tree and
				 * all of its children will be set.
				 */
				break;
			}

			if (fill_bitmap_tree(writer, bitmap,
					     lookup_tree(writer->repo,
							 &entry.oid), pos) < 0)
				return -1;
			break;
		case OBJ_BLOB:
			pos = find_object_pos(writer, &entry.oid, &found);
			if (!found)
				return -1;
			bitmap_set(bitmap, pos);
			break;
		default:
			/* Gitlink, etc; not reachable */
			break;
		}
	}

	free_tree_buffer(tree);
	return 0;
}

static int reused_bitmaps_nr;
static int reused_pseudo_merge_bitmaps_nr;
static int pseudo_merge_bitmap_nr;
static int pseudo_merge_bitmap_parents;

static int fill_bitmap_commit_calls_nr;
static int fill_bitmap_commit_found_ancestor_nr;

static int fill_bitmap_commit(struct bitmap_writer *writer,
			      struct bb_commit *ent,
			      struct commit *commit,
			      struct prio_queue *queue,
			      struct prio_queue *tree_queue,
			      struct bitmap_index *old_bitmap,
			      const uint32_t *mapping)
{
	struct commit *c;
	struct tree *t;
	int found;
	int from_pseudo_merge = commit->object.flags & BITMAP_PSEUDO_MERGE;
	uint32_t pos;

	if (ent->pseudo_merge)
		BUG("unexpected pseudo-merge commit in fill_bitmap_commit()");

	fill_bitmap_commit_calls_nr++;

	if (!ent->bitmap)
		ent->bitmap = bitmap_new();

	prio_queue_put(queue, commit);

	while ((c = prio_queue_get(queue))) {
		struct commit_list *p;

		if (old_bitmap && mapping) {
			struct ewah_bitmap *old;
			struct bitmap *remapped = bitmap_new();

			old = bitmap_for_commit(old_bitmap, c);
			/*
			 * If this commit has an old bitmap, then translate that
			 * bitmap and add its bits to this one. No need to walk
			 * parents or the tree for this commit.
			 */
			if (old && !rebuild_bitmap(mapping, old, remapped)) {
				bitmap_or(ent->bitmap, remapped);
				bitmap_free(remapped);
				reused_bitmaps_nr++;
				continue;
			}
			bitmap_free(remapped);
		}

		/*
		 * If we encounter an ancestor for which we have already
		 * computed a bitmap during this build (i.e. a regular
		 * selected commit processed earlier in topo order), we can
		 * short-circuit the walk: its stored bitmap already covers
		 * the commit itself, its tree, and all of its ancestors.
		 */
		if (c != commit) {
			khiter_t hash_pos = kh_get_oid_map(writer->bitmaps,
							   c->object.oid);
			if (hash_pos != kh_end(writer->bitmaps)) {
				struct bitmapped_commit *stored =
					kh_value(writer->bitmaps, hash_pos);
				if (stored && stored->bitmap) {
					fill_bitmap_commit_found_ancestor_nr++;
					bitmap_or_ewah(ent->bitmap,
						       stored->bitmap);
					continue;
				}
			}
		}

		/*
		 * Mark ourselves and queue our tree. The commit
		 * walk ensures we cover all parents.
		 */
		if (!(c->object.flags & BITMAP_PSEUDO_MERGE)) {
			struct tree *tree;

			if (from_pseudo_merge && !c->object.parsed) {
				/*
				 * Commits reachable from selected
				 * non-pseudo-merges are already parsed
				 * by the regular bitmap build.
				 *
				 * However, pseudo-merge fills can also
				 * reach commits that were not covered
				 * there, so parse any such leftovers
				 * before reading their tree or parents.
				 */
				if (repo_parse_commit(writer->repo, c))
					return -1;
			}

			pos = find_object_pos(writer, &c->object.oid, &found);
			if (!found)
				return -1;
			bitmap_set(ent->bitmap, pos);

			tree = repo_get_commit_tree(writer->repo, c);
			if (!tree)
				return -1;
			prio_queue_put(tree_queue, tree);
		}

		for (p = c->parents; p; p = p->next) {
			pos = find_object_pos(writer, &p->item->object.oid,
					      &found);
			if (!found)
				return -1;
			if (!bitmap_get(ent->bitmap, pos)) {
				bitmap_set(ent->bitmap, pos);
				prio_queue_put(queue, p->item);
			}
		}
	}

	while ((t = prio_queue_get(tree_queue))) {
		int found;

		pos = find_object_pos(writer, &t->object.oid, &found);
		if (!found)
			return -1;
		if (bitmap_get(ent->bitmap, pos)) {
			/*
			 * If our bit is already set, then there is
			 * nothing to do. Both this tree and all of its
			 * children will be set.
			 */
			continue;
		}

		if (fill_bitmap_tree(writer, ent->bitmap, t, pos) < 0)
			return -1;
	}
	return 0;
}

static int reuse_pseudo_merge_bitmap(struct bitmap_index *old_bitmap,
				     const uint32_t *mapping,
				     struct commit *merge,
				     struct ewah_bitmap **out)
{
	struct ewah_bitmap *old;
	struct bitmap *remapped;

	if (!old_bitmap || !mapping)
		return 0;

	old = pseudo_merge_bitmap_for_commit(old_bitmap, merge);
	if (!old)
		return 0;

	remapped = bitmap_new();
	if (rebuild_bitmap(mapping, old, remapped) < 0) {
		bitmap_free(remapped);
		return 0;
	}

	*out = bitmap_to_ewah(remapped);
	bitmap_free(remapped);
	reused_pseudo_merge_bitmaps_nr++;
	return 1;
}

static int build_pseudo_merge_bitmap(struct bitmap_writer *writer,
				     struct bitmap_index *old_bitmap,
				     const uint32_t *mapping,
				     struct commit *merge,
				     struct ewah_bitmap **out)
{
	struct bb_commit ent = { 0 };
	struct prio_queue queue = { NULL };
	struct prio_queue tree_queue = { NULL };
	unsigned parents = commit_list_count(merge->parents);
	int ret;

	ent.bitmap = bitmap_new();

	pseudo_merge_bitmap_nr++;
	pseudo_merge_bitmap_parents += parents;

	if (reuse_pseudo_merge_bitmap(old_bitmap, mapping, merge, out)) {
		ret = 0;
		goto done;
	}

	ret = fill_bitmap_commit(writer, &ent, merge, &queue, &tree_queue,
				 old_bitmap, mapping);

	if (!ret)
		*out = bitmap_to_ewah(ent.bitmap);

done:
	bitmap_free(ent.bitmap);
	clear_prio_queue(&queue);
	clear_prio_queue(&tree_queue);

	return ret;
}

static int build_pseudo_merge_bitmaps(struct bitmap_writer *writer,
				      struct bitmap_index *old_bitmap,
				      const uint32_t *mapping,
				      int *nr_stored)
{
	size_t i = bitmap_writer_nr_selected_commits(writer);
	int ret = 0;

	if (!writer->pseudo_merges_nr)
		return 0;

	trace2_region_enter("pack-bitmap-write", "building_pseudo_merge_bitmaps",
			    writer->repo);

	for (; i < writer->selected_nr; i++) {
		struct bitmapped_commit *merge = &writer->selected[i];
		struct commit_list *p;
		struct bitmap *parents = bitmap_new();
		struct ewah_bitmap *objects = NULL;

		if (!merge->pseudo_merge)
			BUG("found non-pseudo merge commit at %"PRIuMAX,
			    (uintmax_t)i);

		for (p = merge->commit->parents; p; p = p->next) {
			int found;
			uint32_t pos = find_object_pos(writer,
						       &p->item->object.oid,
						       &found);
			if (!found) {
				bitmap_free(parents);
				ret = -1;
				goto done;
			}
			bitmap_set(parents, pos);
		}

		merge->pseudo_merge_parents = bitmap_to_ewah(parents);
		bitmap_free(parents);

		if (build_pseudo_merge_bitmap(writer, old_bitmap, mapping,
					      merge->commit, &objects) < 0) {
			ret = -1;
			goto done;
		}
		merge->bitmap = objects;

		(*nr_stored)++;
		display_progress(writer->progress, *nr_stored);
	}

done:
	trace2_region_leave("pack-bitmap-write", "building_pseudo_merge_bitmaps",
			    writer->repo);

	trace2_data_intmax("pack-bitmap-write", writer->repo,
			   "pseudo_merge_bitmap_nr",
			   pseudo_merge_bitmap_nr);
	trace2_data_intmax("pack-bitmap-write", writer->repo,
			   "building_bitmaps_pseudo_merge_reused",
			   reused_pseudo_merge_bitmaps_nr);
	trace2_data_intmax("pack-bitmap-write", writer->repo,
			   "pseudo_merge_bitmap_parents",
			   pseudo_merge_bitmap_parents);

	return ret;
}

static void store_selected(struct bitmap_writer *writer,
			   struct bb_commit *ent, struct commit *commit)
{
	struct bitmapped_commit *stored = &writer->selected[ent->idx];
	khiter_t hash_pos;

	stored->bitmap = bitmap_to_ewah(ent->bitmap);

	if (ent->pseudo_merge)
		return;

	hash_pos = kh_get_oid_map(writer->bitmaps, commit->object.oid);
	if (hash_pos == kh_end(writer->bitmaps))
		die(_("attempted to store non-selected commit: '%s'"),
		    oid_to_hex(&commit->object.oid));

	kh_value(writer->bitmaps, hash_pos) = stored;
}

int bitmap_writer_build(struct bitmap_writer *writer)
{
	struct bitmap_builder bb;
	size_t i;
	int nr_stored = 0; /* for progress */
	struct prio_queue queue = { compare_commits_by_gen_then_commit_date };
	struct prio_queue tree_queue = { NULL };
	struct bitmap_index *old_bitmap;
	uint32_t *mapping = NULL;
	int closed = 1; /* until proven otherwise */

	if (writer->show_progress)
		writer->progress = start_progress(writer->repo,
						  "Building bitmaps",
						  writer->selected_nr);

	writer->pos_cache_hits = 0;
	writer->pos_cache_misses = 0;

	trace2_region_enter("pack-bitmap-write", "building_bitmaps_total",
			    writer->repo);

	old_bitmap = prepare_bitmap_git(writer->to_pack->repo);
	if (old_bitmap)
		mapping = create_bitmap_mapping(old_bitmap, writer->to_pack);
	else
		mapping = NULL;

	bitmap_builder_init(&bb, writer, old_bitmap);
	for (i = bb.commits.nr; i > 0; i--) {
		struct commit *commit = bb.commits.items[i-1];
		struct bb_commit *ent = bb_data_at(&bb.data, commit);
		struct commit *child;
		int reused = 0;

		if (fill_bitmap_commit(writer, ent, commit, &queue, &tree_queue,
				       old_bitmap, mapping) < 0) {
			closed = 0;
			break;
		}

		if (ent->selected) {
			store_selected(writer, ent, commit);
			nr_stored++;
			display_progress(writer->progress, nr_stored);
		}

		while ((child = pop_commit(&ent->reverse_edges))) {
			struct bb_commit *child_ent =
				bb_data_at(&bb.data, child);

			if (child_ent->bitmap)
				bitmap_or(child_ent->bitmap, ent->bitmap);
			else if (reused)
				child_ent->bitmap = bitmap_dup(ent->bitmap);
			else {
				child_ent->bitmap = ent->bitmap;
				reused = 1;
			}
		}
		if (!reused)
			bitmap_free(ent->bitmap);
		ent->bitmap = NULL;
	}
	if (closed &&
	    build_pseudo_merge_bitmaps(writer, old_bitmap, mapping,
				       &nr_stored) < 0)
		closed = 0;
	clear_prio_queue(&queue);
	clear_prio_queue(&tree_queue);
	bitmap_builder_clear(&bb);
	free_bitmap_index(old_bitmap);
	free(mapping);

	trace2_region_leave("pack-bitmap-write", "building_bitmaps_total",
			    writer->repo);
	trace2_data_intmax("pack-bitmap-write", writer->repo,
			   "building_bitmaps_reused", reused_bitmaps_nr);
	trace2_data_intmax("pack-bitmap-write", writer->repo,
			   "fill_bitmap_commit_calls_nr",
			   fill_bitmap_commit_calls_nr);
	trace2_data_intmax("pack-bitmap-write", writer->repo,
			   "fill_bitmap_commit_found_ancestor_nr",
			   fill_bitmap_commit_found_ancestor_nr);
	trace2_data_intmax("pack-bitmap-write", writer->repo,
			   "bitmap_pos_cache_hits", writer->pos_cache_hits);
	trace2_data_intmax("pack-bitmap-write", writer->repo,
			   "bitmap_pos_cache_misses", writer->pos_cache_misses);

	stop_progress(&writer->progress);

	if (closed)
		compute_xor_offsets(writer);
	return closed ? 0 : -1;
}

/**
 * Select the commits that will be bitmapped
 */
static inline unsigned int next_commit_index(unsigned int idx)
{
	static const unsigned int MIN_COMMITS = 100;
	static const unsigned int MAX_COMMITS = 5000;

	static const unsigned int MUST_REGION = 100;
	static const unsigned int MIN_REGION = 20000;

	unsigned int offset, next;

	if (idx <= MUST_REGION)
		return 0;

	if (idx <= MIN_REGION) {
		offset = idx - MUST_REGION;
		return (offset < MIN_COMMITS) ? offset : MIN_COMMITS;
	}

	offset = idx - MIN_REGION;
	next = (offset < MAX_COMMITS) ? offset : MAX_COMMITS;

	return (next > MIN_COMMITS) ? next : MIN_COMMITS;
}

/*
 * Keep the number of ordinary bitmap entries independent of the selection
 * strategy. This is the number produced by the historical date-window
 * schedule encoded by next_commit_index(); pseudo-merge entries are accounted
 * for separately.
 */
static unsigned int bitmap_selection_budget(unsigned int indexed_commits_nr)
{
	unsigned int count = 0;
	unsigned int i = 0;

	while (i < indexed_commits_nr) {
		unsigned int next = next_commit_index(i);

		if (next >= indexed_commits_nr - i)
			break;
		count++;
		i += next + 1;
	}

	return count;
}

static int bitmap_selection_date_cmp(const void *_a, const void *_b)
{
	const struct commit *a = *(struct commit **)_a;
	const struct commit *b = *(struct commit **)_b;

	if (a->date != b->date)
		return a->date > b->date ? -1 : 1;
	return 0;
}

struct bitmap_selection_commit {
	struct commit *path_parent;
	unsigned int child_nr;
	unsigned int parent_nr;
	unsigned int path_length;
	unsigned int height;
	unsigned candidate : 1;
	unsigned assigned : 1;
	unsigned hard_boundary : 1;
};

struct bitmap_selection_gap {
	struct commit **path;
	unsigned int left;
	unsigned int right;
	unsigned int split;
	uint64_t gain;
};

define_commit_slab(bitmap_selection_data, struct bitmap_selection_commit);

static struct bitmap_selection_commit *bitmap_selection_candidate_peek(
	struct bitmap_selection_data *data, const struct commit *commit)
{
	struct bitmap_selection_commit *ent =
		bitmap_selection_data_peek(data, commit);

	return ent && ent->candidate ? ent : NULL;
}

static int bitmap_selection_height_cmp(const void *_a, const void *_b,
				       void *_data)
{
	struct bitmap_selection_data *data = _data;
	const struct commit *a = *(struct commit **)_a;
	const struct commit *b = *(struct commit **)_b;
	const struct bitmap_selection_commit *a_ent =
		bitmap_selection_candidate_peek(data, a);
	const struct bitmap_selection_commit *b_ent =
		bitmap_selection_candidate_peek(data, b);

	if (!a_ent || !b_ent)
		BUG("sorting commit outside bitmap candidate set");
	if (a_ent->height != b_ent->height)
		return a_ent->height > b_ent->height ? -1 : 1;
	if (a_ent->parent_nr != b_ent->parent_nr)
		return a_ent->parent_nr > b_ent->parent_nr ? -1 : 1;
	return oidcmp(&a->object.oid, &b->object.oid);
}

static struct commit *bitmap_selection_gap_commit(
	const struct bitmap_selection_gap *gap)
{
	return gap->path[gap->split - 1];
}

/* Negative means that a is the more valuable gap. */
static int bitmap_selection_gap_cmp(const void *_a, const void *_b, void *_data)
{
	const struct bitmap_selection_gap *a = _a;
	const struct bitmap_selection_gap *b = _b;
	struct bitmap_selection_data *data = _data;
	struct commit *a_commit = bitmap_selection_gap_commit(a);
	struct commit *b_commit = bitmap_selection_gap_commit(b);
	struct bitmap_selection_commit *a_ent =
		bitmap_selection_data_at(data, a_commit);
	struct bitmap_selection_commit *b_ent =
		bitmap_selection_data_at(data, b_commit);
	unsigned int a_distance = a->split - a->left;
	unsigned int b_distance = b->split - b->left;
	int a_preferred = !!(a_commit->object.flags & NEEDS_BITMAP);
	int b_preferred = !!(b_commit->object.flags & NEEDS_BITMAP);

	if (a->gain != b->gain)
		return a->gain > b->gain ? -1 : 1;
	if (a_distance != b_distance)
		return a_distance > b_distance ? -1 : 1;
	if (a_preferred != b_preferred)
		return a_preferred ? -1 : 1;
	if (a_ent->height != b_ent->height)
		return a_ent->height > b_ent->height ? -1 : 1;
	return oidcmp(&a_commit->object.oid, &b_commit->object.oid);
}

/* Negative means that a is the less valuable gap. */
static int bitmap_selection_gap_reverse_cmp(const void *a, const void *b,
					    void *data)
{
	return bitmap_selection_gap_cmp(b, a, data);
}

static uint64_t bitmap_selection_gap_gain(
	const struct bitmap_selection_gap *gap, unsigned int split)
{
	uint64_t coverage = (uint64_t)split - gap->left;
	uint64_t suffix = (uint64_t)gap->right - split + 1;

	if (coverage && suffix > UINT64_MAX / coverage)
		BUG("bitmap selection score overflow");
	return coverage * suffix;
}

static void bitmap_selection_score_gap(struct bitmap_selection_gap *gap)
{
	unsigned int length = gap->right - gap->left;
	unsigned int distance = 1;
	unsigned int last = 0;

	gap->gain = 0;
	gap->split = 0;
	for (;;) {
		unsigned int split = gap->left + distance;
		uint64_t gain = bitmap_selection_gap_gain(gap, split);

		if (gain > gap->gain ||
		    (gain == gap->gain && split > gap->split)) {
			gap->gain = gain;
			gap->split = split;
		}
		last = distance;
		if (distance > length / 2)
			break;
		distance *= 2;
	}

	if (last != length) {
		unsigned int split = gap->right;
		uint64_t gain = bitmap_selection_gap_gain(gap, split);

		if (gain > gap->gain ||
		    (gain == gap->gain && split > gap->split)) {
			gap->gain = gain;
			gap->split = split;
		}
	}
}

static struct bitmap_selection_gap *bitmap_selection_gap_new(
	struct commit **path, unsigned int left, unsigned int right)
{
	struct bitmap_selection_gap *gap;

	if (left >= right)
		return NULL;

	CALLOC_ARRAY(gap, 1);
	gap->path = path;
	gap->left = left;
	gap->right = right;
	bitmap_selection_score_gap(gap);
	return gap;
}

static void bitmap_selection_keep_initial_gap(
	struct prio_queue *queue, const struct bitmap_selection_gap *gap,
	unsigned int budget, struct bitmap_selection_data *data)
{
	struct bitmap_selection_gap *old;
	struct bitmap_selection_gap *copy;

	if (prio_queue_size(queue) < budget) {
		ALLOC_ARRAY(copy, 1);
		*copy = *gap;
		prio_queue_put(queue, copy);
		return;
	}

	old = prio_queue_peek(queue);
	if (bitmap_selection_gap_cmp(gap, old, data) < 0) {
		old = prio_queue_get(queue);
		*old = *gap;
		prio_queue_put(queue, old);
	}
}

static void bitmap_selection_offer_initial_gap(
	struct prio_queue *queue, struct commit **path, unsigned int left,
	unsigned int right, unsigned int budget,
	struct bitmap_selection_data *data)
{
	struct bitmap_selection_gap gap = {
		.path = path,
		.left = left,
		.right = right,
	};

	if (left >= right || !budget)
		return;
	bitmap_selection_score_gap(&gap);
	bitmap_selection_keep_initial_gap(queue, &gap, budget, data);
}

/*
 * Kahn's algorithm builds a children-before-parents order without recursion.
 * Walk that array backwards to compute graph heights, then repeatedly claim
 * the deepest remaining parent path. The resulting paths are vertex-disjoint
 * and deterministic, and give a one-dimensional approximation of graph
 * reachability. Merge edges can cross paths, so this is not a decomposition
 * of the complete bitmap walk.
 *
 * Within a path, selecting s after the preceding bitmap a saves (s-a) steps
 * for every query at or after s. Treat every candidate as one query and
 * repeatedly split the gap with the greatest saved coverage. Testing only
 * power-of-two distances from a gap's left edge bounds each split to O(log N)
 * score evaluations. It also retains at least half of the best path-local
 * gain: rounding a distance down to a power of two halves the distance at
 * worst and can only increase the suffix size.
 */
static void bitmap_selection_order_by_graph(
	struct commit **indexed_commits, unsigned int indexed_commits_nr,
	unsigned int budget, struct bitmap_selection_data *data)
{
	struct commit **order;
	struct commit **boundaries = NULL;
	struct prio_queue initial = {
		.compare = bitmap_selection_gap_reverse_cmp,
		.cb_data = data,
	};
	struct prio_queue gaps = {
		.compare = bitmap_selection_gap_cmp,
		.cb_data = data,
	};
	unsigned int preferred_nr = 0;
	unsigned int tip_nr = 0;
	unsigned int boundary_nr = 0;
	unsigned int selected_boundary_nr = 0;
	unsigned int gap_budget = budget;
	unsigned int i, nr = 0, next = 0;

	if (indexed_commits_nr == UINT_MAX)
		BUG("too many commits for bitmap selection");

	init_bitmap_selection_data(data);
	ALLOC_ARRAY(order, indexed_commits_nr);

	for (i = 0; i < indexed_commits_nr; i++) {
		struct commit *commit = indexed_commits[i];
		struct bitmap_selection_commit *ent =
			bitmap_selection_data_at(data, commit);

		if (ent->candidate)
			BUG("duplicate bitmap candidate: %s",
			    oid_to_hex(&commit->object.oid));
		ent->candidate = 1;
		if (commit->object.flags & NEEDS_BITMAP)
			preferred_nr++;
	}

	for (i = 0; i < indexed_commits_nr; i++) {
		struct bitmap_selection_commit *ent =
			bitmap_selection_data_at(data, indexed_commits[i]);
		struct commit_list *p;

		for (p = indexed_commits[i]->parents; p; p = p->next) {
			struct bitmap_selection_commit *parent =
				bitmap_selection_candidate_peek(data, p->item);

			if (parent) {
				parent->child_nr++;
				ent->parent_nr++;
			}
		}
	}

	for (i = 0; i < indexed_commits_nr; i++) {
		struct bitmap_selection_commit *ent =
			bitmap_selection_data_at(data, indexed_commits[i]);

		if (!ent->child_nr) {
			order[nr++] = indexed_commits[i];
			if (!(indexed_commits[i]->object.flags & NEEDS_BITMAP))
				tip_nr++;
		}
	}

	/*
	 * Configured preferred tips are hard boundaries when all of them fit.
	 * Candidate-graph tips are useful query starting points, too; include
	 * those as boundaries when they fit in the remaining budget.
	 */
	if (preferred_nr <= budget) {
		for (i = 0; i < indexed_commits_nr; i++) {
			struct bitmap_selection_commit *ent =
				bitmap_selection_data_at(data, indexed_commits[i]);

			if (indexed_commits[i]->object.flags & NEEDS_BITMAP) {
				ent->hard_boundary = 1;
				boundary_nr++;
			}
		}
		if (tip_nr <= budget - boundary_nr) {
			for (i = 0; i < nr; i++) {
				struct bitmap_selection_commit *ent =
					bitmap_selection_data_at(data, order[i]);

				if (!ent->hard_boundary) {
					ent->hard_boundary = 1;
					boundary_nr++;
				}
			}
		}
	}
	if (boundary_nr) {
		ALLOC_ARRAY(boundaries, boundary_nr);
		gap_budget -= boundary_nr;
	}

	while (next < nr) {
		struct commit *commit = order[next++];
		struct commit_list *p;

		for (p = commit->parents; p; p = p->next) {
			struct bitmap_selection_commit *parent =
				bitmap_selection_candidate_peek(data, p->item);

			if (!parent)
				continue;
			if (!parent->child_nr)
				BUG("bitmap candidate child count underflow");
			if (!--parent->child_nr)
				order[nr++] = p->item;
		}
	}

	if (nr != indexed_commits_nr)
		BUG("bitmap candidate graph is not acyclic");

	for (i = nr; i > 0; i--) {
		struct commit *commit = order[i - 1];
		struct bitmap_selection_commit *ent =
			bitmap_selection_data_at(data, commit);
		struct commit_list *p;

		ent->height = 1;
		for (p = commit->parents; p; p = p->next) {
			struct bitmap_selection_commit *parent =
				bitmap_selection_candidate_peek(data, p->item);

			if (!parent)
				continue;
			if (ent->height <= parent->height)
				ent->height = parent->height == UINT_MAX ?
					UINT_MAX : parent->height + 1;
		}
	}

	QSORT_S(indexed_commits, indexed_commits_nr,
		bitmap_selection_height_cmp, data);

	nr = 0;
	for (i = 0; i < indexed_commits_nr; i++) {
		struct commit *start = indexed_commits[i];
		struct bitmap_selection_commit *start_ent =
			bitmap_selection_data_at(data, start);
		struct commit *commit, *previous;
		struct commit **path;
		unsigned int length = 0;

		if (start_ent->assigned)
			continue;

		/* Claim one deepest path, recording it newest-to-oldest. */
		for (commit = start; commit; length++) {
			struct bitmap_selection_commit *ent =
				bitmap_selection_data_at(data, commit);
			struct commit_list *p;
			struct commit *best = NULL;

			if (ent->assigned)
				BUG("bitmap path reached an assigned candidate");
			ent->assigned = 1;
			for (p = commit->parents; p; p = p->next) {
				struct bitmap_selection_commit *parent =
					bitmap_selection_candidate_peek(data,
								p->item);
				struct bitmap_selection_commit *best_ent;

				if (!parent || parent->assigned)
					continue;
				if (!best) {
					best = p->item;
					continue;
				}
				best_ent = bitmap_selection_data_at(data, best);
				if (parent->height > best_ent->height ||
				    (parent->height == best_ent->height &&
				     parent->parent_nr > best_ent->parent_nr) ||
				    (parent->height == best_ent->height &&
				     parent->parent_nr == best_ent->parent_nr &&
				     oidcmp(&p->item->object.oid,
					    &best->object.oid) < 0))
					best = p->item;
			}
			ent->path_parent = best;
			commit = best;
		}

		/* Reverse the path, then materialize it oldest-to-newest. */
		previous = NULL;
		for (commit = start; commit; ) {
			struct bitmap_selection_commit *ent =
				bitmap_selection_data_at(data, commit);
			struct commit *parent = ent->path_parent;

			ent->path_parent = previous;
			previous = commit;
			commit = parent;
		}

		path = order + nr;
		for (commit = previous; commit; ) {
			struct bitmap_selection_commit *ent =
				bitmap_selection_data_at(data, commit);

			order[nr++] = commit;
			commit = ent->path_parent;
		}
		bitmap_selection_data_at(data, path[0])->path_length = length;
	}

	if (nr != indexed_commits_nr)
		BUG("bitmap paths covered %u commits, expected %u", nr,
		    indexed_commits_nr);

	for (i = 0; i < nr; ) {
		struct commit **path = order + i;
		struct bitmap_selection_commit *first =
			bitmap_selection_data_at(data, path[0]);
		unsigned int left = 0;
		unsigned int length = first->path_length;
		unsigned int position;

		if (!length || length > nr - i)
			BUG("invalid bitmap path length %u", length);
		for (position = 0; position < length; position++) {
			struct commit *commit = path[position];
			struct bitmap_selection_commit *ent =
				bitmap_selection_data_at(data, commit);

			if (!ent->hard_boundary)
				continue;
			bitmap_selection_offer_initial_gap(
				&initial, path, left, position, gap_budget, data);
			boundaries[selected_boundary_nr++] = commit;
			left = position + 1;
		}
		bitmap_selection_offer_initial_gap(
			&initial, path, left, length, gap_budget, data);
		i += length;
	}

	/*
	 * A descendant gap cannot be selected before its initial gap. Therefore,
	 * only the best 'gap_budget' initial gaps can contribute to the first
	 * 'gap_budget' selections. Keep this queue bounded for wide graphs.
	 */
	for (;;) {
		struct bitmap_selection_gap *gap = prio_queue_get(&initial);

		if (!gap)
			break;
		prio_queue_put(&gaps, gap);
	}
	clear_prio_queue(&initial);

	if (selected_boundary_nr != boundary_nr)
		BUG("selected %u bitmap boundaries, expected %u",
		    selected_boundary_nr, boundary_nr);
	for (i = 0; i < selected_boundary_nr; i++)
		indexed_commits[i] = boundaries[i];

	for (; i < budget; i++) {
		struct bitmap_selection_gap *gap = prio_queue_get(&gaps);
		struct bitmap_selection_gap *left, *right;

		if (!gap)
			BUG("ran out of bitmap selection gaps after %u commits", i);
		indexed_commits[i] = bitmap_selection_gap_commit(gap);
		left = bitmap_selection_gap_new(gap->path, gap->left,
						gap->split - 1);
		right = bitmap_selection_gap_new(gap->path, gap->split,
						 gap->right);
		free(gap);
		if (left)
			prio_queue_put(&gaps, left);
		if (right)
			prio_queue_put(&gaps, right);
	}

	for (;;) {
		struct bitmap_selection_gap *gap = prio_queue_get(&gaps);

		if (!gap)
			break;
		free(gap);
	}
	clear_prio_queue(&gaps);

	free(boundaries);
	free(order);
}

void bitmap_writer_select_commits(struct bitmap_writer *writer,
				  struct commit **indexed_commits,
				  unsigned int indexed_commits_nr)
{
	struct bitmap_selection_data data;
	unsigned int i;
	unsigned int budget = bitmap_selection_budget(indexed_commits_nr);

	trace2_region_enter("pack-bitmap-write", "selecting_commits",
			    writer->repo);

	if (budget == indexed_commits_nr) {
		QSORT(indexed_commits, indexed_commits_nr,
		      bitmap_selection_date_cmp);
		for (i = 0; i < indexed_commits_nr; ++i)
			bitmap_writer_push_commit(writer, indexed_commits[i], 0);
		goto done;
	}

	bitmap_selection_order_by_graph(indexed_commits, indexed_commits_nr,
					budget, &data);

	if (writer->show_progress)
		writer->progress = start_progress(writer->repo,
						  "Selecting bitmap commits", 0);

	for (i = 0; i < budget; i++) {
		bitmap_writer_push_commit(writer, indexed_commits[i], 0);
		display_progress(writer->progress, i + 1);
	}

	stop_progress(&writer->progress);
	clear_bitmap_selection_data(&data);

done:
	if (bitmap_writer_nr_selected_commits(writer) != budget)
		BUG("selected %d bitmap commits, expected %u",
		    bitmap_writer_nr_selected_commits(writer), budget);
	trace2_region_leave("pack-bitmap-write", "selecting_commits",
			    writer->repo);

	select_pseudo_merges(writer);
}


static int hashwrite_ewah_helper(void *f, const void *buf, size_t len)
{
	/* hashwrite will die on error */
	hashwrite(f, buf, len);
	return len;
}

/**
 * Write the bitmap index to disk
 */
static inline void dump_bitmap(struct hashfile *f, struct ewah_bitmap *bitmap)
{
	if (ewah_serialize_to(bitmap, hashwrite_ewah_helper, f) < 0)
		die("Failed to write bitmap index");
}

static const struct object_id *oid_access(size_t pos, const void *table)
{
	const struct pack_idx_entry * const *index = table;
	return &index[pos]->oid;
}

static void write_selected_commits_v1(struct bitmap_writer *writer,
				      struct hashfile *f, off_t *offsets)
{
	int i;

	for (i = 0; i < bitmap_writer_nr_selected_commits(writer); ++i) {
		struct bitmapped_commit *stored = &writer->selected[i];
		if (stored->pseudo_merge)
			BUG("unexpected pseudo-merge among selected: %s",
			    oid_to_hex(&stored->commit->object.oid));

		if (offsets)
			offsets[i] = hashfile_total(f);

		hashwrite_be32(f, stored->commit_pos);
		hashwrite_u8(f, stored->xor_offset);
		hashwrite_u8(f, stored->flags);

		dump_bitmap(f, stored->write_as);
	}
}

static int pseudo_merge_commit_pos_cmp(const void *_va, const void *_vb,
				       void *_data)
{
	struct bitmap_writer *writer = _data;
	uint32_t pos_a = find_object_pos(writer, _va, NULL);
	uint32_t pos_b = find_object_pos(writer, _vb, NULL);

	if (pos_a < pos_b)
		return -1;
	if (pos_a > pos_b)
		return 1;
	return 0;
}

static void write_pseudo_merges(struct bitmap_writer *writer,
				struct hashfile *f)
{
	struct oid_array commits = OID_ARRAY_INIT;
	off_t *pseudo_merge_ofs = NULL;
	off_t start, table_start, next_ext;

	uint32_t base = bitmap_writer_nr_selected_commits(writer);
	size_t i, j = 0;

	CALLOC_ARRAY(pseudo_merge_ofs, writer->pseudo_merges_nr);

	start = hashfile_total(f);

	for (i = 0; i < writer->pseudo_merges_nr; i++) {
		struct bitmapped_commit *merge = &writer->selected[base + i];

		if (!merge->pseudo_merge)
			BUG("found non-pseudo merge commit at %"PRIuMAX, (uintmax_t)i);

		if (!merge->pseudo_merge_parents || !merge->bitmap)
			BUG("missing pseudo-merge bitmap for commit %s",
			    oid_to_hex(&merge->commit->object.oid));

		pseudo_merge_ofs[i] = hashfile_total(f);
		dump_bitmap(f, merge->pseudo_merge_parents);
		dump_bitmap(f, merge->bitmap);
	}

	next_ext = st_add(hashfile_total(f),
			  st_mult(kh_size(writer->pseudo_merge_commits),
				  sizeof(uint32_t) + sizeof(uint64_t)));

	table_start = hashfile_total(f);

	commits.alloc = kh_size(writer->pseudo_merge_commits);
	CALLOC_ARRAY(commits.oid, commits.alloc);

	for (i = kh_begin(writer->pseudo_merge_commits); i != kh_end(writer->pseudo_merge_commits); i++) {
		if (!kh_exist(writer->pseudo_merge_commits, i))
			continue;
		oid_array_append(&commits, &kh_key(writer->pseudo_merge_commits, i));
	}

	/*
	 * Sort the commits by their bit position so that the lookup
	 * table can be binary searched by the reader (see
	 * find_pseudo_merge()).
	 */
	QSORT_S(commits.oid, commits.nr, pseudo_merge_commit_pos_cmp, writer);

	/* write lookup table (non-extended) */
	for (i = 0; i < commits.nr; i++) {
		int hash_pos;
		struct pseudo_merge_commit_idx *c;

		hash_pos = kh_get_oid_map(writer->pseudo_merge_commits,
					  commits.oid[i]);
		if (hash_pos == kh_end(writer->pseudo_merge_commits))
			BUG("could not find pseudo-merge commit %s",
			    oid_to_hex(&commits.oid[i]));

		c = kh_value(writer->pseudo_merge_commits, hash_pos);

		hashwrite_be32(f, find_object_pos(writer, &commits.oid[i],
						  NULL));
		if (c->nr == 1)
			hashwrite_be64(f, pseudo_merge_ofs[c->pseudo_merge[0]]);
		else if (c->nr > 1) {
			if (next_ext & ((uint64_t)1<<63))
				die(_("too many pseudo-merges"));
			hashwrite_be64(f, next_ext | ((uint64_t)1<<63));
			next_ext = st_add3(next_ext,
					   sizeof(uint32_t),
					   st_mult(c->nr, sizeof(uint64_t)));
		} else
			BUG("expected commit '%s' to have at least one "
			    "pseudo-merge", oid_to_hex(&commits.oid[i]));
	}

	/* write lookup table (extended) */
	for (i = 0; i < commits.nr; i++) {
		int hash_pos;
		struct pseudo_merge_commit_idx *c;

		hash_pos = kh_get_oid_map(writer->pseudo_merge_commits,
					  commits.oid[i]);
		if (hash_pos == kh_end(writer->pseudo_merge_commits))
			BUG("could not find pseudo-merge commit %s",
			    oid_to_hex(&commits.oid[i]));

		c = kh_value(writer->pseudo_merge_commits, hash_pos);
		if (c->nr == 1)
			continue;

		hashwrite_be32(f, c->nr);
		for (j = 0; j < c->nr; j++)
			hashwrite_be64(f, pseudo_merge_ofs[c->pseudo_merge[j]]);
	}

	/* write positions for all pseudo merges */
	for (i = 0; i < writer->pseudo_merges_nr; i++)
		hashwrite_be64(f, pseudo_merge_ofs[i]);

	hashwrite_be32(f, writer->pseudo_merges_nr);
	hashwrite_be32(f, kh_size(writer->pseudo_merge_commits));
	hashwrite_be64(f, table_start - start);
	hashwrite_be64(f, hashfile_total(f) - start + sizeof(uint64_t));

	oid_array_clear(&commits);
	free(pseudo_merge_ofs);
}

static int table_cmp(const void *_va, const void *_vb, void *_data)
{
	struct bitmap_writer *writer = _data;
	struct bitmapped_commit *a = &writer->selected[*(uint32_t *)_va];
	struct bitmapped_commit *b = &writer->selected[*(uint32_t *)_vb];

	if (a->commit_pos < b->commit_pos)
		return -1;
	else if (a->commit_pos > b->commit_pos)
		return 1;

	return 0;
}

static void write_lookup_table(struct bitmap_writer *writer, struct hashfile *f,
			       off_t *offsets)
{
	uint32_t i;
	uint32_t *table, *table_inv;

	ALLOC_ARRAY(table, bitmap_writer_nr_selected_commits(writer));
	ALLOC_ARRAY(table_inv, bitmap_writer_nr_selected_commits(writer));

	for (i = 0; i < bitmap_writer_nr_selected_commits(writer); i++)
		table[i] = i;

	/*
	 * At the end of this sort table[j] = i means that the i'th
	 * bitmap corresponds to j'th bitmapped commit (among the selected
	 * commits) in lex order of OIDs.
	 */
	QSORT_S(table, bitmap_writer_nr_selected_commits(writer), table_cmp, writer);

	/* table_inv helps us discover that relationship (i'th bitmap
	 * to j'th commit by j = table_inv[i])
	 */
	for (i = 0; i < bitmap_writer_nr_selected_commits(writer); i++)
		table_inv[table[i]] = i;

	trace2_region_enter("pack-bitmap-write", "writing_lookup_table", writer->repo);
	for (i = 0; i < bitmap_writer_nr_selected_commits(writer); i++) {
		struct bitmapped_commit *selected = &writer->selected[table[i]];
		uint32_t xor_offset = selected->xor_offset;
		uint32_t xor_row;

		if (xor_offset) {
			/*
			 * xor_index stores the index (in the bitmap entries)
			 * of the corresponding xor bitmap. But we need to convert
			 * this index into lookup table's index. So, table_inv[xor_index]
			 * gives us the index position w.r.t. the lookup table.
			 *
			 * If "k = table[i] - xor_offset" then the xor base is the k'th
			 * bitmap. `table_inv[k]` gives us the position of that bitmap
			 * in the lookup table.
			 */
			uint32_t xor_index = table[i] - xor_offset;
			xor_row = table_inv[xor_index];
		} else {
			xor_row = 0xffffffff;
		}

		hashwrite_be32(f, writer->selected[table[i]].commit_pos);
		hashwrite_be64(f, (uint64_t)offsets[table[i]]);
		hashwrite_be32(f, xor_row);
	}
	trace2_region_leave("pack-bitmap-write", "writing_lookup_table", writer->repo);

	free(table);
	free(table_inv);
}

static void write_hash_cache(struct hashfile *f,
			     struct pack_idx_entry **index,
			     uint32_t index_nr)
{
	uint32_t i;

	for (i = 0; i < index_nr; ++i) {
		struct object_entry *entry = (struct object_entry *)index[i];
		hashwrite_be32(f, entry->hash);
	}
}

void bitmap_writer_set_checksum(struct bitmap_writer *writer,
				const unsigned char *sha1)
{
	hashcpy(writer->pack_checksum, sha1, writer->repo->hash_algo);
}

void bitmap_writer_finish(struct bitmap_writer *writer,
			  struct pack_idx_entry **index,
			  const char *filename,
			  uint16_t options)
{
	static uint16_t default_version = 1;
	static uint16_t flags = BITMAP_OPT_FULL_DAG;
	struct strbuf tmp_file = STRBUF_INIT;
	struct hashfile *f;
	off_t *offsets = NULL;
	uint32_t i, base_objects;

	struct bitmap_disk_header header;

	int fd = odb_mkstemp(writer->repo->objects, &tmp_file,
			     "pack/tmp_bitmap_XXXXXX");

	if (writer->pseudo_merges_nr)
		options |= BITMAP_OPT_PSEUDO_MERGES;

	f = hashfd(writer->repo->hash_algo, fd, tmp_file.buf);

	memcpy(header.magic, BITMAP_IDX_SIGNATURE, sizeof(BITMAP_IDX_SIGNATURE));
	header.version = htons(default_version);
	header.options = htons(flags | options);
	header.entry_count = htonl(bitmap_writer_nr_selected_commits(writer));
	hashcpy(header.checksum, writer->pack_checksum, writer->repo->hash_algo);

	hashwrite(f, &header, sizeof(header) - GIT_MAX_RAWSZ + writer->repo->hash_algo->rawsz);
	dump_bitmap(f, writer->commits);
	dump_bitmap(f, writer->trees);
	dump_bitmap(f, writer->blobs);
	dump_bitmap(f, writer->tags);

	if (options & BITMAP_OPT_LOOKUP_TABLE)
		CALLOC_ARRAY(offsets, writer->to_pack->nr_objects);

	if (writer->midx)
		base_objects = writer->midx->num_objects +
			writer->midx->num_objects_in_base;
	else
		base_objects = 0;

	for (i = 0; i < bitmap_writer_nr_selected_commits(writer); i++) {
		struct bitmapped_commit *stored = &writer->selected[i];
		int commit_pos = oid_pos(&stored->commit->object.oid, index,
					 writer->to_pack->nr_objects,
					 oid_access);

		if (commit_pos < 0)
			BUG("trying to write commit not in index");
		stored->commit_pos = commit_pos + base_objects;
	}

	write_selected_commits_v1(writer, f, offsets);

	if (options & BITMAP_OPT_PSEUDO_MERGES)
		write_pseudo_merges(writer, f);

	if (options & BITMAP_OPT_LOOKUP_TABLE)
		write_lookup_table(writer, f, offsets);

	if (options & BITMAP_OPT_HASH_CACHE)
		write_hash_cache(f, index, writer->to_pack->nr_objects);

	finalize_hashfile(f, NULL, FSYNC_COMPONENT_PACK_METADATA,
			  CSUM_HASH_IN_STREAM | CSUM_FSYNC | CSUM_CLOSE);

	if (adjust_shared_perm(writer->repo, tmp_file.buf))
		die_errno("unable to make temporary bitmap file readable");

	if (rename(tmp_file.buf, filename))
		die_errno("unable to rename temporary bitmap file to '%s'", filename);

	strbuf_release(&tmp_file);
	free(offsets);
}
