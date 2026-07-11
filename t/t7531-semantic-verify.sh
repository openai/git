#!/bin/sh

test_description='descriptor-anchored semantic verification'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-semantic-verify.sh

verify_repo () {
	repo=$1 &&
	shift &&
	(
		cd "$repo" &&
		test-tool semantic-verify "$@"
	)
}

test_expect_success !SEMANTIC_VERIFY_ANCHORED_OPEN \
	'unsupported platforms decline semantic verification' '
	test_create_repo anchored-open-unsupported &&
	test_commit -C anchored-open-unsupported base tracked &&
	(
		cd anchored-open-unsupported &&
		test_must_fail test-tool semantic-verify --show-results
	) >actual &&
	test_grep "^tracked error persist=0 error=[1-9][0-9]*$" actual &&
	test_grep "^entries=1 clean=0 modified=0 sensitive=0 structural=0 " \
		actual &&
	test_grep " unstable=0 errors=1 hardlinks=0 bytes=0 " actual &&
	test_grep " stat_updates=0 root_stable=0 namespace_stable=1" \
		actual
'

test_lazy_prereq HARDLINKS '
	rm -f hardlink-source hardlink-alias &&
	: >hardlink-source &&
	ln hardlink-source hardlink-alias
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'classifies raw, converted, nested, and modified files' '
	test_create_repo classify &&
	mkdir -p classify/a/b &&
	test_write_lines "converted text" >classify/.gitattributes &&
	for path in raw converted modified deleted a/b/nested
	do
		test_write_lines original >"classify/$path" || return 1
	done &&
	test-tool chmtime -120 classify/raw classify/converted \
		classify/modified classify/deleted classify/a/b/nested &&
	git -C classify add . &&
	git -C classify commit -m base &&
	cp -p classify/modified classify/mtime-reference &&
	test_write_lines replaced >classify/modified &&
	touch -r classify/mtime-reference classify/modified &&
	rm classify/deleted classify/mtime-reference &&

	verify_repo classify --show-results --apply >actual &&
	test_grep "^.gitattributes raw-clean persist=1" actual &&
	test_grep "^raw raw-clean persist=1" actual &&
	test_grep "^a/b/nested raw-clean persist=1" actual &&
	test_grep "^converted sensitive" actual &&
	test_grep "^modified raw-modified" actual &&
	test_grep "^deleted raw-modified" actual &&
	test_grep "entries=6 clean=3 modified=2 sensitive=1" actual &&
	test_grep "applied=3 .* after_uptodate=3" actual
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN,HARDLINKS \
	'clean hardlinks require the ordinary tail' '
	test_create_repo hardlink &&
	test_write_lines content >hardlink/tracked &&
	git -C hardlink add tracked &&
	git -C hardlink commit -m base &&
	ln hardlink/tracked hardlink/alias &&

	verify_repo hardlink --show-results --apply >actual &&
	test_grep "^tracked raw-clean persist=0" actual &&
	test_grep "hardlinks=1" actual &&
	test_grep "applied=1 .* after_uptodate=0 after_valid=0" actual
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'structural index state rejects the whole proof' '
	test_create_repo structural &&
	test_write_lines tracked >structural/a-tracked &&
	git -C structural add a-tracked &&
	git -C structural commit -m base &&
	test_write_lines intent >structural/z-intent &&
	git -C structural add -N z-intent &&

	verify_repo structural --show-results --apply >actual &&
	test_grep "^a-tracked raw-clean persist=1" actual &&
	test_grep "^z-intent structural" actual &&
	test_grep "applied=-1 .* after_uptodate=0" actual
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'replaced index entries reject the whole proof' '
	test_create_repo replaced-entry &&
	test_write_lines tracked >replaced-entry/a-tracked &&
	test_write_lines replaced >replaced-entry/z-replaced &&
	git -C replaced-entry add . &&
	git -C replaced-entry commit -m base &&

	verify_repo replaced-entry --show-results --apply \
		--replace-after-prepare=z-replaced >actual &&
	test_grep "^a-tracked raw-clean persist=1" actual &&
	test_grep "^z-replaced raw-clean persist=1" actual &&
	test_grep "applied=-1 before_uptodate=0 before_valid=0 " actual &&
	test_grep "after_uptodate=0 after_valid=0" actual
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN,PTHREADS \
	'parallel verification preserves index-order results' '
	test_create_repo parallel &&
	i=0 &&
	while test $i -lt 16
	do
		mkdir "parallel/d$i" &&
		printf "*.txt -text attr_%s=value\n" "$i" \
			>"parallel/d$i/.gitattributes" &&
		printf "content %s\n" "$i" >"parallel/d$i/file.txt" &&
		i=$((i + 1)) || return 1
	done &&
	git -C parallel add . &&
	git -C parallel commit -m base &&

	verify_repo parallel --threads=1 --show-results >expect &&
	verify_repo parallel --threads=4 --show-results >actual &&
	test_cmp expect actual
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'raw hashing uses the repository object format' '
	git init --object-format=sha256 sha256 &&
	test_write_lines sha256 >sha256/tracked &&
	git -C sha256 add tracked &&
	git -C sha256 commit -m base &&
	verify_repo sha256 --show-results >actual &&
	test_grep "^tracked raw-clean persist=1" actual
'

test_done
