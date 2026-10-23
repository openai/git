#!/bin/sh

test_description='opt-in sparse connectivity checks'

. ./test-lib.sh

# These tests remove objects after creating commits. Check that a commit still
# exists before reading it from a commit-graph, as in t6022-rev-list-missing.sh.
GIT_COMMIT_GRAPH_PARANOIA=true
export GIT_COMMIT_GRAPH_PARANOIA

# Keep the graph small, with an unchanged outer tree hiding a copied subtree.
test_expect_success 'setup connected history and a copied subtree' '
	mkdir -p source/deep &&
	echo old >source/deep/file &&
	echo unchanged >unchanged &&
	git add . &&
	git commit -m old &&
	git tag old &&
	mkdir copy &&
	cp source/deep/file copy/file &&
	git add copy &&
	git commit -m copy &&
	git tag copied &&
	old_blob=$(git rev-parse old:source/deep/file) &&
	old_blob_path=.git/objects/$(test_oid_to_path "$old_blob")
'

test_expect_success 'explicit sparse connectivity accepts intact copied history' '
	git rev-list --objects --quiet --sparse-connectivity \
		--missing=error copied ^old >out &&
	test_must_be_empty out
'

test_expect_success 'eager remains the default; sparse checks the nested copy' '
	test_when_finished "mv saved-blob $old_blob_path" &&
	mv "$old_blob_path" saved-blob &&
	git rev-list --objects --quiet copied ^old &&
	test_must_fail git rev-list --objects --quiet --sparse-connectivity \
		copied ^old 2>err &&
	test_grep "missing blob object.*$old_blob" err
'

test_expect_success 'extra sparse traversal respects the depth limit' '
	git -c core.maxTreeDepth=0 rev-list --objects --quiet copied ^old &&
	test_must_fail git -c core.maxTreeDepth=0 rev-list \
		--objects --quiet --sparse-connectivity copied ^old 2>err &&
	test_grep "exceeded maximum allowed tree depth" err
'

test_expect_success 'setup intermediate and merge-side history absent from the tip tree' '
	echo transient >transient &&
	git add transient &&
	git commit -m intermediate &&
	git tag intermediate &&
	git rm transient &&
	git commit -m remove &&
	git tag tip &&
	merge=$(echo merge | git commit-tree old^{tree} -p old -p tip) &&
	git tag merge "$merge"
'

for object in intermediate intermediate^{tree} intermediate:transient
do
	test_expect_success "sparse checks $object in intermediate and merge history" '
		oid=$(git rev-parse "$object") &&
		path=.git/objects/$(test_oid_to_path "$oid") &&
		test_when_finished "mv saved-object $path" &&
		mv "$path" saved-object &&
		for revision in tip merge
		do
			test_must_fail git rev-list --objects --quiet \
				--sparse-connectivity "$revision" ^old 2>err &&
			test_grep "$oid" err || return 1
		done
	'
done

test_expect_success 'reject missing-object modes before sparse can see a missing commit' '
	oid=$(git rev-parse intermediate) &&
	path=.git/objects/$(test_oid_to_path "$oid") &&
	test_when_finished "mv saved-commit $path" &&
	mv "$path" saved-commit &&
	for action in allow-any allow-promisor print print-info
	do
		test_must_fail git rev-list --objects --quiet --sparse-connectivity \
			--missing=$action tip ^old 2>err &&
		test_grep "requires missing objects to be errors" err || return 1
	done &&
	git rev-list --objects --quiet --missing=allow-any tip ^old
'

test_expect_success 'sparse connectivity requires both objects and quiet' '
	for option in --objects --quiet
	do
		test_must_fail git rev-list "$option" --sparse-connectivity \
			copied ^old 2>err &&
		test_grep "requires --objects and --quiet" err || return 1
	done
'

for option in --ignore-missing --exclude-promisor-objects \
	--filter=blob:none --filter-print-omitted --filter-provided-objects \
	--max-count=1 --skip=1 --since=2000-01-01 --before=2000-01-01 \
	--min-parents=1 --no-merges --first-parent --exclude-first-parent-only \
	--ancestry-path --simplify-merges --simplify-by-decoration \
	--remove-empty --maximal-only --grep=old --author=nobody \
	--unpacked --no-kept-objects --cherry-pick --left-only \
	--count --disk-usage --use-bitmap-index --test-bitmap --bisect \
	--objects-edge --boundary --verify-objects --left-right --cherry-mark \
	--graph -z --header --timestamp --pretty=oneline
do
	test_expect_success "sparse connectivity rejects $option" '
		test_must_fail git rev-list --objects --quiet --sparse-connectivity \
			"$option" tip ^old 2>err &&
		test_grep "sparse-connectivity" err
	'
done

test_expect_success 'sparse connectivity rejects no-walk without excluded revisions' '
	test_must_fail git rev-list --objects --quiet --sparse-connectivity \
		--no-walk tip 2>err &&
	test_grep "cannot be combined with traversal filters" err
'

test_expect_success 'sparse connectivity rejects pathspecs including stdin paths' '
	test_must_fail git rev-list --objects --quiet --sparse-connectivity \
		tip ^old -- source 2>err &&
	test_grep "cannot be combined with traversal filters" err &&
	printf "%s\n" tip ^old -- source >input &&
	test_must_fail git rev-list --objects --quiet --sparse-connectivity \
		--stdin <input 2>err &&
	test_grep "cannot be combined with traversal filters" err
'

test_expect_success 'sparse connectivity rejects shallow and partial repositories' '
	git rev-parse old >.git/shallow &&
	test_when_finished "rm -f .git/shallow" &&
	test_must_fail git rev-list --objects --quiet --sparse-connectivity \
		tip ^old 2>err &&
	test_grep "requires a full clone" err &&
	rm .git/shallow &&
	test_must_fail git -c remote.origin.promisor=true rev-list \
		--objects --quiet --sparse-connectivity tip ^old 2>err &&
	test_grep "requires a full clone" err
'

test_done
