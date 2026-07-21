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

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'filter scope includes early semantic exits' '
	test_create_repo filter-scope &&
	printf "unmatched filter=demo\n" >filter-scope/.gitattributes &&
	test_write_lines content >filter-scope/ordinary &&
	test_write_lines content >filter-scope/assumed &&
	git -C filter-scope add . &&
	git -C filter-scope commit -m base &&
	git -C filter-scope config filter.demo.clean cat &&
	git -C filter-scope update-index --assume-unchanged assumed &&
	verify_repo filter-scope --threads=4 --validate-filter-scope \
		--apply >actual.unused &&
	test_grep "applied=2 .*active_filters=0 " actual.unused &&
	test_grep "filter_scope_checked=1" actual.unused &&

	test_write_lines "ordinary filter=demo" "assumed filter=demo" \
		>filter-scope/.gitattributes &&
	git -C filter-scope add .gitattributes &&
	git -C filter-scope commit -m attributes &&

	verify_repo filter-scope --threads=4 --validate-filter-scope \
		--show-results --apply >actual &&
	test_grep "^assumed skipped" actual &&
	test_grep "applied=-1 .*active_filters=2 " actual &&
	test_grep "filter_scope_checked=1" actual
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'immutable attribute sources preserve file parsing' '
	attrs="$TRASH_DIRECTORY/attribute-parser-file" &&
	printf "\357\273\277*.dat text\nignored\0junk\n*.txt text\r\n*.bin text\r" \
		>"$attrs" &&
	test_create_repo attribute-parser &&
	git -C attribute-parser config core.attributesFile "$attrs" &&
	git -C attribute-parser config core.fsmonitor false &&
	git -C attribute-parser config core.untrackedCache false &&
	for extension in dat txt bin
	do
		printf "alpha\r\n" \
			>"attribute-parser/tracked.$extension" || return 1
	done &&
	git -C attribute-parser add . &&
	git -C attribute-parser commit -m base &&

	GIT_OPTIONAL_LOCKS=0 GIT_TEST_COLD_BULK_STATUS=0 \
		git -C attribute-parser status --porcelain=v2 >actual &&
	test_must_be_empty actual
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'missing attribute history invalidates cached stats' '
	attrs="$TRASH_DIRECTORY/external-attributes-file" &&
	printf "*.txt text eol=crlf\n" >"$attrs" &&
	test_create_repo external-attributes &&
	git -C external-attributes config core.attributesFile "$attrs" &&
	git -C external-attributes config core.fsmonitor false &&
	git -C external-attributes config core.untrackedCache false &&
	printf "alpha\r\n" >external-attributes/tracked.txt &&
	git -C external-attributes add tracked.txt &&
	git -C external-attributes commit -m base &&

	printf "*.txt -text\n" >"$attrs" &&
	GIT_OPTIONAL_LOCKS=0 GIT_TEST_COLD_BULK_STATUS=0 \
		git -C external-attributes status --porcelain=v2 >actual &&
	test_grep "^1 \.M .* tracked.txt$" actual
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'hook cannot hide an observed external attribute change' '
	attrs="$TRASH_DIRECTORY/hook-attribute-change.rules" &&
	marker="$TRASH_DIRECTORY/hook-attribute-change.marker" &&
	printf "*.txt text eol=crlf\n" >"$attrs" &&
	test_create_repo hook-attribute-change &&
	(
		cd hook-attribute-change &&
		git config core.attributesFile "$attrs" &&
		git config core.untrackedCache false &&
		printf "alpha\r\n" >tracked.txt &&
		git add tracked.txt &&
		git commit -m base &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			if test -n "$GIT_TEST_ATTR_FILE"
			then
				printf "*.txt -text\n" >"$GIT_TEST_ATTR_FILE"
				: >"$GIT_TEST_ATTR_MARKER"
			fi
			printf "token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		git status --porcelain=v2 >/dev/null &&
		git status --porcelain=v2 >/dev/null &&

		GIT_TEST_ATTR_FILE="$attrs" \
		GIT_TEST_ATTR_MARKER="$marker" \
			git status --porcelain=v2 >actual &&
		test_path_is_file "$marker" &&
		test_grep "^1 \.M .* tracked.txt$" actual
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'hook missing-history exception preserves reported paths' '
	attrs="$TRASH_DIRECTORY/hook-missing-history.rules" &&
	printf "*.txt -text\n" >"$attrs" &&
	test_create_repo hook-missing-history &&
	(
		cd hook-missing-history &&
		git config core.attributesFile "$attrs" &&
		git config core.untrackedCache false &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		printf "aaaa\n" >tracked.txt &&
		git add tracked.txt &&
		git commit -m base &&
		test-tool chmtime =-60 tracked.txt &&
		git update-index --refresh &&
		mtime=$(test-tool chmtime --get tracked.txt) &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		git status --porcelain=v2 >/dev/null &&
		git status --porcelain=v2 >/dev/null &&
		test_grep ! FSCF .git/index &&

		printf "bbbb\n" >tracked.txt &&
		test-tool chmtime =$mtime tracked.txt &&
		GIT_OPTIONAL_LOCKS=0 \
			git status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual
	)
'

test_done
