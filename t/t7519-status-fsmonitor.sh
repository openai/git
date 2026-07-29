#!/bin/sh

test_description='git status with file system watcher'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-semantic-verify.sh

# Note, after "git reset --hard HEAD" no extensions exist other than 'TREE'
# "git update-index --fsmonitor" can be used to get the extension written
# before testing the results.

clean_repo () {
	git reset --hard HEAD &&
	git clean -fd
}

dirty_repo () {
	: >untracked &&
	: >dir1/untracked &&
	: >dir2/untracked &&
	echo 1 >modified &&
	echo 2 >dir1/modified &&
	echo 3 >dir2/modified &&
	echo 4 >new &&
	echo 5 >dir1/new &&
	echo 6 >dir2/new
}

write_integration_script () {
	test_hook --setup --clobber fsmonitor-test<<-\EOF
	if test "$#" -ne 2
	then
		echo "$0: exactly 2 arguments expected"
		exit 2
	fi
	if test "$1" != 2
	then
		echo "Unsupported core.fsmonitor hook version." >&2
		exit 1
	fi
	printf "last_update_token\0"
	printf "untracked\0"
	printf "dir1/untracked\0"
	printf "dir2/untracked\0"
	printf "modified\0"
	printf "dir1/modified\0"
	printf "dir2/modified\0"
	printf "new\0"
	printf "dir1/new\0"
	printf "dir2/new\0"
	EOF
}

test_lazy_prereq UNTRACKED_CACHE '
	{ git update-index --test-untracked-cache; ret=$?; } &&
	test $ret -ne 1
'

test_lazy_prereq HARDLINKS '
	: >hardlink-a &&
	ln hardlink-a hardlink-b
'

test_expect_success 'FSMN parser fails closed' '
	test-tool read-cache --test-fsmn-parser
'

test_expect_success 'FSUC parser fails closed' '
	test-tool read-cache --test-fsuc-parser
'

test_expect_success !SEMANTIC_VERIFY_ANCHORED_OPEN \
	'unsupported identity preserves an ordinary provider token' '
	test_when_finished "rm -rf unsupported-provider-token" &&
	test_create_repo unsupported-provider-token &&
	(
		cd unsupported-provider-token &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		test-tool dump-fsmonitor >.git/fsmonitor &&
		test_grep "^fsmonitor last update builtin:test:" \
			.git/fsmonitor &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/status.trace
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'FSCF survives index I/O and generic rewrites' '
	test_when_finished "rm -rf fscf-round-trip" &&
	test_create_repo fscf-round-trip &&
	(
		cd fscf-round-trip &&
		test_commit base tracked &&
		test-tool read-cache --test-fscf-round-trip &&
		test_grep FSCF .git/index
	)
'

test_expect_success 'hook parser ignores empty path records' '
	test_when_finished "rm -rf empty-hook-record" &&
	test_create_repo empty-hook-record &&
	(
		cd empty-hook-record &&
		test_commit base tracked &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "token\0"
			printf "\0"
			printf "tracked\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		echo changed >tracked &&
		git status --porcelain --untracked-files=no >actual &&
		echo " M tracked" >expect &&
		test_cmp expect actual
	)
'

test_expect_success UNTRACKED_CACHE 'trivial hook clears a paired UNTR token' '
	test_when_finished "rm -rf hook-token-pair" &&
	test_create_repo hook-token-pair &&
	(
		cd hook-token-pair &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git -c core.fsmonitor=false status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "token1\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		test_grep ! FSUC .git/index &&
		git status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		test_grep FSUC .git/index &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "token2\0/\0"
		EOF
		git status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		test_grep ! FSUC .git/index
	)
'

test_expect_success UNTRACKED_CACHE 'failed hook clears a paired UNTR token' '
	test_when_finished "rm -rf hook-token-error" &&
	test_create_repo hook-token-error &&
	(
		cd hook-token-error &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git -c core.fsmonitor=false status --porcelain=v2 >/dev/null &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "token1\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		git status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		test_grep FSUC .git/index &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			exit 1
		EOF
		git status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		test_grep ! FSUC .git/index
	)
'

test_expect_success UNTRACKED_CACHE \
	'paired fsmonitor cache prunes recursively valid empty subtrees' '
	test_when_finished "rm -rf fsmonitor-untracked-prune" &&
	test_create_repo fsmonitor-untracked-prune &&
	(
		cd fsmonitor-untracked-prune &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir -p cached/empty/deep &&
		test_write_lines tracked >cached/empty/deep/tracked &&
		git add cached/empty/deep/tracked &&
		git commit -m base &&
		git config core.untrackedCache true &&
		git -c core.fsmonitor=false status --porcelain=v2 \
			>.git/prime &&
		test_must_be_empty .git/prime &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime-fsmonitor &&
		test_must_be_empty .git/prime-fsmonitor &&
		test_grep FSUC .git/index &&

		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/clean.trace" \
			git status --porcelain=v2 >.git/clean &&
		test_must_be_empty .git/clean &&
		test_trace2_data read_directory directories-visited 0 \
			<.git/clean.trace &&

		test_write_lines untracked >cached/empty/deep/new &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=cached/empty/deep/new \
			git status --porcelain=v2 >.git/changed &&
		test_grep "^? cached/empty/deep/new$" .git/changed
	)
'

test_expect_success UNTRACKED_CACHE,HARDLINKS \
	'fsmonitor pruning rechecks cached per-directory excludes' '
	test_when_finished "rm -rf fsmonitor-untracked-exclude" &&
	test_when_finished "rm -f fsmonitor-untracked-exclude-alias" &&
	test_create_repo fsmonitor-untracked-exclude &&
	(
		cd fsmonitor-untracked-exclude &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir cached cached2 cached3 &&
		test_write_lines ignored >cached/.gitignore &&
		test_write_lines hidden >cached/ignored &&
		test_write_lines ignored >cached2/.gitignore &&
		test_write_lines hidden >cached2/ignored &&
		test_write_lines ignored >cached3/.gitignore &&
		test_write_lines hidden >cached3/ignored &&
		git add cached/.gitignore cached2/.gitignore \
			cached3/.gitignore &&
		git commit -m base &&
		test-tool chmtime +60 cached2/.gitignore &&
		test-tool chmtime =-60 cached3/.gitignore &&
		git update-index --refresh &&
		git config core.untrackedCache true &&
		git -c core.fsmonitor=false status --porcelain=v2 \
			>.git/prime &&
		test_must_be_empty .git/prime &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime-fsmonitor &&
		test_must_be_empty .git/prime-fsmonitor &&
		test_grep FSUC .git/index &&
		ln cached/.gitignore ../fsmonitor-untracked-exclude-alias &&

		if test_have_prereq PTHREADS
		then
			threads=2
		else
			threads=1
		fi &&
		if test_have_prereq MINGW || test_have_prereq CYGWIN
		then
			index_excludes=0
		else
			index_excludes=1
		fi &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=2 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT_NESTING=10 \
		GIT_TRACE2_EVENT="$PWD/.git/clean.trace" \
			git status --porcelain >.git/clean &&
		test_must_be_empty .git/clean &&
		test_trace2_data dir \
			preload_untracked_cache/fsmonitor-excludes-only 1 \
			<.git/clean.trace &&
		test_trace2_data dir preload_untracked_cache/threads \
			$threads \
			<.git/clean.trace &&
		test_trace2_data dir preload_untracked_cache/dirs 3 \
			<.git/clean.trace &&
		test_trace2_data dir \
			preload_untracked_cache/index-excludes "$index_excludes" \
			<.git/clean.trace &&
		test_trace2_data read_directory directories-visited 0 \
			<.git/clean.trace &&

		if test_have_prereq FILEMODE
		then
			chmod +x ../fsmonitor-untracked-exclude-alias &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_UNTRACKED_CACHE_THREADS=2 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/mode.trace" \
				git status --porcelain >.git/mode &&
			test_trace2_data dir \
				preload_untracked_cache/index-uptodate 2 \
				<.git/mode.trace &&
			chmod -x ../fsmonitor-untracked-exclude-alias
		else
			:
		fi &&

		mtime=$(test-tool chmtime --get cached/.gitignore) &&
		test_write_lines visible \
			>../fsmonitor-untracked-exclude-alias &&
		test-tool chmtime =$mtime cached/.gitignore &&
		GIT_TEST_UNTRACKED_CACHE_THREADS=2 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/changed.trace" \
			git status >.git/changed &&
		test_grep "modified:.*cached/.gitignore" .git/changed &&
		test_grep "cached/ignored" .git/changed &&
		test_trace2_data status \
			fsmonitor/exclude-index-invalidated 1 \
			<.git/changed.trace &&

		test_write_lines ignored \
			>../fsmonitor-untracked-exclude-alias &&
		test-tool chmtime =$mtime cached/.gitignore &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=2 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/restored.trace" \
			git status >.git/restored &&
		test_grep "nothing to commit, working tree clean" \
			.git/restored &&

		test_write_lines "?? cached/ignored" >.git/flagged.expect &&

		git update-index --assume-unchanged cached/.gitignore &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain >.git/assume-prime &&
		test_must_be_empty .git/assume-prime &&
		mtime=$(test-tool chmtime --get cached/.gitignore) &&
		test_write_lines visible \
			>../fsmonitor-untracked-exclude-alias &&
		test-tool chmtime =$mtime cached/.gitignore &&
		GIT_TEST_UNTRACKED_CACHE_THREADS=2 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/assume-changed.trace" \
			git status --porcelain >.git/assume-changed &&
		test_cmp .git/flagged.expect .git/assume-changed &&
		test_write_lines ignored \
			>../fsmonitor-untracked-exclude-alias &&
		test-tool chmtime =$mtime cached/.gitignore &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=2 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/assume-restored.trace" \
			git status --porcelain >.git/assume-restored &&
		test_must_be_empty .git/assume-restored &&
		git update-index --no-assume-unchanged cached/.gitignore &&

		git update-index --skip-worktree cached/.gitignore &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain >.git/skip-prime &&
		test_must_be_empty .git/skip-prime &&
		mtime=$(test-tool chmtime --get cached/.gitignore) &&
		test_write_lines visible \
			>../fsmonitor-untracked-exclude-alias &&
		test-tool chmtime =$mtime cached/.gitignore &&
		GIT_TEST_UNTRACKED_CACHE_THREADS=2 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/skip-changed.trace" \
			git status --porcelain >.git/skip-changed &&
		test_cmp .git/flagged.expect .git/skip-changed &&
		test_write_lines ignored \
			>../fsmonitor-untracked-exclude-alias &&
		test-tool chmtime =$mtime cached/.gitignore &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=2 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/skip-restored.trace" \
			git status --porcelain >.git/skip-restored &&
		test_must_be_empty .git/skip-restored &&
		git update-index --no-skip-worktree cached/.gitignore
	)
'

test_expect_success UNTRACKED_CACHE \
	'converted cached excludes retain a stable index proof' '
	test_when_finished "rm -rf fsmonitor-converted-exclude" &&
	test_create_repo fsmonitor-converted-exclude &&
	(
		cd fsmonitor-converted-exclude &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir cached &&
		printf "ignored\r\n" >cached/.gitignore &&
		test_write_lines hidden >cached/ignored &&
		test_write_lines "cached/.gitignore text eol=lf" \
			>.gitattributes &&
		git add .gitattributes cached/.gitignore &&
		git commit -m base &&
		git config core.untrackedCache true &&
		git -c core.fsmonitor=false status --porcelain >.git/prime &&
		test_must_be_empty .git/prime &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain >.git/prime-fsmonitor &&
		test_must_be_empty .git/prime-fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status >.git/settle &&
		test_grep "nothing to commit, working tree clean" \
			.git/settle &&

		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/clean.trace" \
			git status >.git/clean &&
		test_grep "nothing to commit, working tree clean" \
			.git/clean &&
		test_trace2_data dir \
			preload_untracked_cache/index-uptodate 1 \
			<.git/clean.trace &&
		test_trace2_data dir \
			preload_untracked_cache/index-invalidated 0 \
			<.git/clean.trace &&
		test_trace2_data dir \
			preload_untracked_cache/normalized-excludes 0 \
			<.git/clean.trace &&
		test_trace2_data read_directory directories-visited 0 \
			<.git/clean.trace
	)
'

test_expect_success UNTRACKED_CACHE,HARDLINKS,POSIXPERM,SANITY \
	'fsmonitor rechecks cached unreadable per-directory excludes' '
	test_when_finished "rm -rf fsmonitor-unreadable-exclude" &&
	test_when_finished "rm -f fsmonitor-unreadable-exclude-alias" &&
	test_create_repo fsmonitor-unreadable-exclude &&
	(
		cd fsmonitor-unreadable-exclude &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir cached &&
		test_write_lines hidden >cached/.gitignore &&
		test_write_lines untracked >cached/hidden &&
		test_write_lines tracked >cached/tracked &&
		git add cached/tracked &&
		git commit -m base &&
		chmod 000 cached/.gitignore &&
		git config core.untrackedCache true &&
		git -c core.fsmonitor=false status --porcelain \
			>.git/prime 2>.git/prime.err &&
		test_grep "^?? cached/hidden$" .git/prime &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain >.git/prime-fsmonitor \
				2>.git/prime-fsmonitor.err &&
		test_grep "^?? cached/hidden$" .git/prime-fsmonitor &&
		empty_tree=$(git mktree </dev/null) &&
		test-tool dump-untracked-cache >.git/untracked-cache &&
		test_grep "cached/ $empty_tree" .git/untracked-cache &&
		ln cached/.gitignore \
			../fsmonitor-unreadable-exclude-alias &&

		chmod 644 ../fsmonitor-unreadable-exclude-alias &&
		test_write_lines "?? cached/.gitignore" \
			>.git/readable.expect &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/readable.trace" \
			git status --porcelain >.git/readable &&
		test_cmp .git/readable.expect .git/readable &&
		test_trace2_data dir \
			preload_untracked_cache/dirs "[1-9]" \
			<.git/readable.trace
	)
'

check_weak_exclude_stat () {
	repo=$1 &&
	key=$2 &&
	value=$3 &&
	test_create_repo "$repo" &&
	(
		cd "$repo" &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir cached &&
		test_write_lines ignored >cached/.gitignore &&
		test_write_lines hidden >cached/ignored &&
		git add cached/.gitignore &&
		git commit -m base &&
		git config "$key" "$value" &&
		git config core.untrackedCache true &&
		git -c core.fsmonitor=false status --porcelain=v2 \
			>.git/prime &&
		test_must_be_empty .git/prime &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime-fsmonitor &&
		test_must_be_empty .git/prime-fsmonitor &&

		mtime=$(test-tool chmtime --get cached/.gitignore) &&
		test_write_lines visible >cached/.gitignore &&
		test-tool chmtime =$mtime cached/.gitignore &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
		GIT_TRACE2_EVENT="$PWD/.git/changed.trace" \
			git status --porcelain >.git/changed &&
		test_grep "^?? cached/ignored$" .git/changed &&
		test_trace2_data dir \
			preload_untracked_cache/index-excludes 0 \
			<.git/changed.trace
	)
}

test_expect_success UNTRACKED_CACHE \
	'weak stat settings retain exclude content checks' '
	test_when_finished "rm -rf weak-exclude-ctime weak-exclude-stat" &&
	check_weak_exclude_stat weak-exclude-ctime \
		core.trustctime false &&
	check_weak_exclude_stat weak-exclude-stat \
		core.checkStat minimal
'

test_expect_success UNTRACKED_CACHE \
	'root untracked events preserve cached descendant excludes' '
	test_when_finished "rm -rf root-untracked-event" &&
	test_create_repo root-untracked-event &&
	(
		cd root-untracked-event &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir -p cached/deep &&
		test_write_lines "*.ignored" >.gitignore &&
		test_write_lines "*.ignored" >cached/.gitignore &&
		test_write_lines tracked >cached/deep/tracked &&
		test_write_lines ignored >cached/deep/junk.ignored &&
		git add .gitignore cached/.gitignore cached/deep/tracked &&
		git commit -m base &&
		git config core.untrackedCache true &&
		git -c core.fsmonitor=false status --porcelain=v2 \
			>.git/prime &&
		test_must_be_empty .git/prime &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime-fsmonitor &&
		test_must_be_empty .git/prime-fsmonitor &&

		test_write_lines visible >root-probe &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=root-probe \
		GIT_TRACE2_EVENT="$PWD/.git/created.trace" \
			git status >.git/created &&
		test_grep "root-probe" .git/created &&
		test_trace2_data read_directory directories-visited 1 \
			<.git/created.trace &&
		test_trace2_data read_directory gitignore-invalidation 0 \
			<.git/created.trace &&

		rm root-probe &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=root-probe \
		GIT_TRACE2_EVENT="$PWD/.git/removed.trace" \
			git status >.git/removed &&
		test_grep "nothing to commit, working tree clean" \
			.git/removed &&
		test_trace2_data read_directory directories-visited 1 \
			<.git/removed.trace &&
		test_trace2_data read_directory gitignore-invalidation 0 \
			<.git/removed.trace
	)
'

prepare_builtin_closure_repo () {
	test_create_repo "$1" &&
	(
		cd "$1" &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		if test "${2-}" = untracked
		then
			git config core.untrackedCache true &&
			git -c core.fsmonitor=false status --porcelain=v2 \
				>.git/actual &&
			test_must_be_empty .git/actual &&
			test_grep UNTR .git/index &&
			test_grep ! FSUC .git/index
		else
			:
		fi &&
		git config core.fsmonitor true &&
		test_grep ! FSMN .git/index
	)
}

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'builtin closure initializes a new untracked cache' '
	test_when_finished "rm -rf builtin-closure-new-uc" &&
	test_create_repo builtin-closure-new-uc &&
	(
		cd builtin-closure-new-uc &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		test_grep UNTR .git/index &&
		test_grep ! FSUC .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		test_grep \
			"\"event\":\"region_enter\".*\"category\":\"dir\",\"label\":\"read_directory\"" \
			.git/status.trace >.git/read-directory &&
		test_line_count = 1 .git/read-directory &&
		test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep FSUC .git/index
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'builtin clean closure publishes its proof' '
	test_when_finished "rm -rf builtin-closure-clean" &&
	prepare_builtin_closure_repo builtin-closure-clean untracked &&
	(
		cd builtin-closure-clean &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines visible >visible &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_grep "^? visible$" .git/actual &&
		test_grep \
			"\"event\":\"region_enter\".*\"category\":\"dir\",\"label\":\"read_directory\"" \
			.git/status.trace >.git/read-directory &&
		test_line_count = 1 .git/read-directory &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep FSMN .git/index &&
		test_grep FSUC .git/index
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'builtin changed closure rescans before acceptance' '
	test_when_finished "rm -rf builtin-closure-changed" &&
	prepare_builtin_closure_repo builtin-closure-changed &&
	(
		cd builtin-closure-changed &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CDC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
		GIT_TRACE_FSMONITOR="$PWD/.git/fsmonitor.trace" \
			git status --porcelain=v2 \
				--untracked-files=no >.git/actual &&
		test_must_be_empty .git/actual &&
		test_grep "fsmonitor_refresh_callback.*tracked" \
			.git/fsmonitor.trace &&
		test_trace2_data fsmonitor token_closure/apply_count 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'builtin initial trivial response anchors a closure' '
	test_when_finished "rm -rf builtin-initial-trivial" &&
	prepare_builtin_closure_repo builtin-initial-trivial &&
	(
		cd builtin-initial-trivial &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 \
				--untracked-files=no >.git/actual &&
		test_must_be_empty .git/actual &&
		test_trace2_data fsm_client query/trivial-response 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor token_closure/rejected 1 \
			<.git/status.trace &&
		test-tool dump-fsmonitor >.git/fsmonitor &&
		test_grep "^fsmonitor last update builtin:test:2" \
			.git/fsmonitor
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'builtin trivial closure can rescan and accept' '
	test_when_finished "rm -rf builtin-closure-trivial" &&
	prepare_builtin_closure_repo builtin-closure-trivial &&
	(
		cd builtin-closure-trivial &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CTC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 \
				--untracked-files=no >.git/actual &&
		test_must_be_empty .git/actual &&
		test_trace2_data fsmonitor token_closure/trivial 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor token_closure/rejected 1 \
			<.git/status.trace
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'builtin closure rejects three intervening changes' '
	test_when_finished "rm -rf builtin-closure-exhausted" &&
	prepare_builtin_closure_repo builtin-closure-exhausted &&
	(
		cd builtin-closure-exhausted &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CDDD \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 \
				--untracked-files=no >.git/actual &&
		test_must_be_empty .git/actual &&
		test_trace2_data fsmonitor token_closure/apply_count 1 \
			<.git/status.trace >.git/applied &&
		test_line_count = 3 .git/applied &&
		test_trace2_data fsmonitor token_closure/rejected 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep ! FSUC .git/index
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'builtin closure query errors fall back completely' '
	test_when_finished "rm -rf builtin-closure-error" &&
	prepare_builtin_closure_repo builtin-closure-error untracked &&
	(
		cd builtin-closure-error &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines visible >visible &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCE \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_grep "^? visible$" .git/actual &&
		test_grep \
			"\"event\":\"region_enter\".*\"category\":\"dir\",\"label\":\"read_directory\"" \
			.git/status.trace >.git/read-directory &&
		test_line_count = 2 .git/read-directory &&
		test_trace2_data fsmonitor token_closure/rejected 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep ! FSUC .git/index
	)
'

# Test that we detect and disallow repos that are incompatible with FSMonitor.
test_expect_success 'incompatible bare repo' '
	test_when_finished "rm -rf ./bare-clone actual expect" &&
	git init --bare bare-clone &&

	test_must_fail \
		git -C ./bare-clone -c core.fsmonitor=foo \
			update-index --fsmonitor 2>actual &&
	test_grep "bare repository .* is incompatible with fsmonitor" actual &&

	test_must_fail \
		git -C ./bare-clone -c core.fsmonitor=true \
			update-index --fsmonitor 2>actual &&
	test_grep "bare repository .* is incompatible with fsmonitor" actual
'

test_expect_success FSMONITOR_DAEMON 'run fsmonitor-daemon in bare repo' '
	test_when_finished "rm -rf ./bare-clone actual" &&
	git init --bare bare-clone &&
	test_must_fail git -C ./bare-clone fsmonitor--daemon run 2>actual &&
	test_grep "bare repository .* is incompatible with fsmonitor" actual
'

test_expect_success MINGW,FSMONITOR_DAEMON 'run fsmonitor-daemon in virtual repo' '
	test_when_finished "rm -rf ./fake-virtual-clone actual" &&
	git init fake-virtual-clone &&
	test_must_fail git -C ./fake-virtual-clone \
			   -c core.virtualfilesystem=true \
			   fsmonitor--daemon run 2>actual &&
	test_grep "virtual repository .* is incompatible with fsmonitor" actual
'

test_expect_success 'setup' '
	: >tracked &&
	: >modified &&
	mkdir dir1 &&
	: >dir1/tracked &&
	: >dir1/modified &&
	mkdir dir2 &&
	: >dir2/tracked &&
	: >dir2/modified &&
	git -c core.fsmonitor= add . &&
	git -c core.fsmonitor= commit -m initial &&
	git config core.fsmonitor .git/hooks/fsmonitor-test &&
	cat >.gitignore <<-\EOF
	.gitignore
	expect*
	actual*
	marker*
	trace2*
	EOF
'

# test that the fsmonitor extension is off by default
test_expect_success 'fsmonitor extension is off by default' '
	test-tool dump-fsmonitor >actual &&
	test_grep "^no fsmonitor" actual
'

# test that "update-index --fsmonitor" adds the fsmonitor extension
test_expect_success 'update-index --fsmonitor" adds the fsmonitor extension' '
	git update-index --fsmonitor &&
	test-tool dump-fsmonitor >actual &&
	test_grep "^fsmonitor last update" actual
'

# test that "update-index --no-fsmonitor" removes the fsmonitor extension
test_expect_success 'update-index --no-fsmonitor" removes the fsmonitor extension' '
	git update-index --no-fsmonitor &&
	test-tool dump-fsmonitor >actual &&
	test_grep "^no fsmonitor" actual
'

cat >expect <<EOF &&
h dir1/modified
H dir1/tracked
h dir2/modified
H dir2/tracked
h modified
H tracked
EOF

# test that "update-index --fsmonitor-valid" sets the fsmonitor valid bit
test_expect_success 'update-index --fsmonitor-valid" sets the fsmonitor valid bit' '
	test_hook fsmonitor-test<<-\EOF &&
		printf "last_update_token\0"
	EOF
	git update-index --fsmonitor &&
	git update-index --fsmonitor-valid dir1/modified &&
	git update-index --fsmonitor-valid dir2/modified &&
	git update-index --fsmonitor-valid modified &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
H dir1/tracked
H dir2/modified
H dir2/tracked
H modified
H tracked
EOF

# test that "update-index --no-fsmonitor-valid" clears the fsmonitor valid bit
test_expect_success 'update-index --no-fsmonitor-valid" clears the fsmonitor valid bit' '
	git update-index --no-fsmonitor-valid dir1/modified &&
	git update-index --no-fsmonitor-valid dir2/modified &&
	git update-index --no-fsmonitor-valid modified &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
H dir1/tracked
H dir2/modified
H dir2/tracked
H modified
H tracked
EOF

# test that all files returned by the script get flagged as invalid
test_expect_success 'all files returned by integration script get flagged as invalid' '
	write_integration_script &&
	dirty_repo &&
	git update-index --fsmonitor &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
h dir1/new
H dir1/tracked
H dir2/modified
h dir2/new
H dir2/tracked
H modified
h new
H tracked
EOF

# test that newly added files are marked valid
test_expect_success 'newly added files are marked valid' '
	test_hook --setup --clobber fsmonitor-test<<-\EOF &&
		printf "last_update_token\0"
	EOF
	git add new &&
	git add dir1/new &&
	git add dir2/new &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
h dir1/new
h dir1/tracked
H dir2/modified
h dir2/new
h dir2/tracked
H modified
h new
h tracked
EOF

# test that all unmodified files get marked valid
test_expect_success 'all unmodified files get marked valid' '
	# modified files result in update-index returning 1
	test_must_fail git update-index --refresh --force-write-index &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
h dir1/tracked
h dir2/modified
h dir2/tracked
h modified
h tracked
EOF

# test that *only* files returned by the integration script get flagged as invalid
test_expect_success '*only* files returned by the integration script get flagged as invalid' '
	test_hook --clobber fsmonitor-test<<-\EOF &&
	printf "last_update_token\0"
	printf "dir1/modified\0"
	EOF
	clean_repo &&
	git update-index --refresh --force-write-index &&
	echo 1 >modified &&
	echo 2 >dir1/modified &&
	echo 3 >dir2/modified &&
	test_must_fail git update-index --refresh --force-write-index &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

# Ensure commands that call refresh_index() to move the index back in time
# properly invalidate the fsmonitor cache
test_expect_success 'refresh_index() invalidates fsmonitor cache' '
	clean_repo &&
	dirty_repo &&
	write_integration_script &&
	git add . &&
	test_hook --clobber fsmonitor-test<<-\EOF &&
	EOF
	git commit -m "to reset" &&
	git reset HEAD~1 &&
	git status >actual &&
	git -c core.fsmonitor= status >expect &&
	test_cmp expect actual
'

# test fsmonitor with and without preloadIndex
preload_values="false true"
for preload_val in $preload_values
do
	test_expect_success "setup preloadIndex to $preload_val" '
		git config core.preloadIndex $preload_val &&
		if test $preload_val = true
		then
			GIT_TEST_PRELOAD_INDEX=$preload_val && export GIT_TEST_PRELOAD_INDEX
		else
			sane_unset GIT_TEST_PRELOAD_INDEX
		fi
	'

	# test fsmonitor with and without the untracked cache (if available)
	uc_values="false"
	test_have_prereq UNTRACKED_CACHE && uc_values="false true"
	for uc_val in $uc_values
	do
		test_expect_success "setup untracked cache to $uc_val" '
			git config core.untrackedcache $uc_val
		'

		# Status is well tested elsewhere so we'll just ensure that the results are
		# the same when using core.fsmonitor.
		test_expect_success 'compare status with and without fsmonitor' '
			write_integration_script &&
			clean_repo &&
			dirty_repo &&
			git add new &&
			git add dir1/new &&
			git add dir2/new &&
			git status >actual &&
			git -c core.fsmonitor= status >expect &&
			test_cmp expect actual
		'

		# Make sure it's actually skipping the check for modified and untracked
		# (if enabled) files unless it is told about them.
		test_expect_success "status doesn't detect unreported modifications" '
			test_hook --clobber fsmonitor-test<<-\EOF &&
			printf "last_update_token\0"
			:>marker
			EOF
			clean_repo &&
			git status &&
			test_path_is_file marker &&
			dirty_repo &&
			rm -f marker &&
			git status >actual &&
			test_path_is_file marker &&
			test_grep ! "Changes not staged for commit:" actual &&
			if test $uc_val = true
			then
				test_grep ! "Untracked files:" actual
			fi &&
			if test $uc_val = false
			then
				test_grep "Untracked files:" actual
			fi &&
			rm -f marker
		'
	done
done

# test that splitting the index doesn't interfere
test_expect_success 'splitting the index results in the same state' '
	write_integration_script &&
	dirty_repo &&
	git update-index --fsmonitor  &&
	git ls-files -f >expect &&
	test-tool dump-fsmonitor >&2 && echo &&
	git update-index --fsmonitor --split-index &&
	test-tool dump-fsmonitor >&2 && echo &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

test_expect_success UNTRACKED_CACHE 'ignore .git changes when invalidating UNTR' '
	test_create_repo dot-git &&
	(
		cd dot-git &&
		: >tracked &&
		test-tool chmtime =-60 tracked &&
		: >modified &&
		test-tool chmtime =-60 modified &&
		mkdir dir1 &&
		: >dir1/tracked &&
		test-tool chmtime =-60 dir1/tracked &&
		: >dir1/modified &&
		test-tool chmtime =-60 dir1/modified &&
		mkdir dir2 &&
		: >dir2/tracked &&
		test-tool chmtime =-60 dir2/tracked &&
		: >dir2/modified &&
		test-tool chmtime =-60 dir2/modified &&
		write_integration_script &&
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git update-index --untracked-cache &&
		git update-index --fsmonitor &&
		git status &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-before" \
		git status &&
		test-tool dump-untracked-cache >../before
	) &&
	cat >>dot-git/.git/hooks/fsmonitor-test <<-\EOF &&
	printf ".git\0"
	printf ".git/index\0"
	printf "dir1/.git\0"
	printf "dir1/.git/index\0"
	EOF
	(
		cd dot-git &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-after" \
		git status &&
		test-tool dump-untracked-cache >../after
	) &&
	grep "directory-invalidation" trace-before | cut -d"|" -f 9 >>before &&
	grep "directory-invalidation" trace-after  | cut -d"|" -f 9 >>after &&
	# UNTR extension unchanged, dir invalidation count unchanged
	test_cmp before after
'

test_expect_success 'discard_index() also discards fsmonitor info' '
	test_config core.fsmonitor "$TEST_DIRECTORY/t7519/fsmonitor-all" &&
	test_might_fail git update-index --refresh &&
	test-tool read-cache --print-and-refresh=tracked 2 >actual &&
	printf "tracked is%s up to date\n" "" " not" >expect &&
	test_cmp expect actual
'

# Test unstaging entries that:
#  - Are not flagged with CE_FSMONITOR_VALID
#  - Have a position in the index >= the number of entries present in the index
#    after unstaging.
test_expect_success 'status succeeds after staging/unstaging' '
	test_create_repo fsmonitor-stage-unstage &&
	(
		cd fsmonitor-stage-unstage &&
		test_commit initial &&
		git update-index --fsmonitor &&
		removed=$(test_seq 1 100 | sed "s/^/z/") &&
		touch $removed &&
		git add $removed &&
		git config core.fsmonitor "$TEST_DIRECTORY/t7519/fsmonitor-env" &&
		FSMONITOR_LIST="$removed" git restore -S $removed &&
		FSMONITOR_LIST="$removed" git status
	)
'

# Usage:
# check_sparse_index_behavior [!]
# If "!" is supplied, then we verify that we do not call ensure_full_index
# during a call to 'git status'. Otherwise, we verify that we _do_ call it.
check_sparse_index_behavior () {
	git -C full status --porcelain=v2 >expect &&
	GIT_TRACE2_EVENT="$(pwd)/trace2.txt" \
		git -C sparse status --porcelain=v2 >actual &&
	test_region $1 index ensure_full_index trace2.txt &&
	test_region fsm_hook query trace2.txt &&
	test_cmp expect actual &&
	rm trace2.txt
}

test_expect_success 'status succeeds with sparse index' '
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&

		git clone . full &&
		git clone --sparse . sparse &&
		git -C sparse sparse-checkout init --cone --sparse-index &&
		git -C sparse sparse-checkout set dir1 dir2 &&

		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git -C full config core.fsmonitor ../.git/hooks/fsmonitor-test &&
		git -C sparse config core.fsmonitor ../.git/hooks/fsmonitor-test &&
		check_sparse_index_behavior ! &&

		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "dir1/modified\0"
		EOF
		check_sparse_index_behavior ! &&

		git -C sparse sparse-checkout add dir1a &&

		for repo in full sparse
		do
			cp -r $repo/dir1 $repo/dir1a &&
			git -C $repo add dir1a &&
			git -C $repo commit -m "add dir1a" || return 1
		done &&
		git -C sparse sparse-checkout set dir1 dir2 &&

		# This one modifies outside the sparse-checkout definition
		# and hence we expect to expand the sparse-index.
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "dir1a/modified\0"
		EOF
		check_sparse_index_behavior
	)
'

test_expect_success 'reported events poison weak stat-cache matches' '
	test_create_repo reported-event &&
	(
		cd reported-event &&
		printf "aaaa\n" >tracked &&
		printf "clean\n" >clean &&
		git add tracked clean &&
		git commit -m base &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		test-tool chmtime =-60 tracked clean &&
		git update-index --refresh &&
		mtime=$(test-tool chmtime --get tracked) &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "token\0tracked\0clean\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		git status --porcelain=v2 >/dev/null &&
		git status --porcelain=v2 >/dev/null &&
		printf "bbbb\n" >tracked &&
		test-tool chmtime =$mtime tracked &&

		GIT_OPTIONAL_LOCKS=0 git diff-index --name-status HEAD \
			>.git/diff-index &&
		test_grep "^M.*tracked$" .git/diff-index &&
		test_grep ! "clean$" .git/diff-index &&
		git status --porcelain=v2 >.git/status &&
		test_grep "^1 \.M .* tracked$" .git/status &&
		test_grep ! " clean$" .git/status
	)
'

test_expect_success 'reported path permits apply --index content match' '
	test_create_repo apply-marker &&
	(
		cd apply-marker &&
		test_commit base tracked &&
		test_write_lines next >tracked &&
		git diff >../apply-marker.patch &&
		git checkout -- tracked &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "token\0tracked\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		git apply --index ../apply-marker.patch
	)
'

test_expect_success 'reported path permits checkout-index content match' '
	test_create_repo checkout-marker &&
	(
		cd checkout-marker &&
		test_commit base tracked &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "token\0tracked\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		git checkout-index tracked
	)
'

test_expect_success CASE_INSENSITIVE_FS \
	'reported path permits case-folded unpack match' '
	test_create_repo icase-marker &&
	(
		cd icase-marker &&
		test_write_lines same >foo &&
		git add foo &&
		git commit -m base &&
		base=$(git rev-parse HEAD) &&
		git mv foo intermediate &&
		git mv intermediate FOO &&
		git commit -m target &&
		target=$(git rev-parse HEAD) &&
		git checkout "$base" &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "token\0foo\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		git read-tree -m -u "$target" &&
		echo FOO >expect &&
		git ls-files >actual &&
		test_cmp expect actual
	)
'

test_expect_success 'reported unchanged path avoids reset checkout' '
	test_create_repo reset-marker &&
	(
		cd reset-marker &&
		test_commit base tracked &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		test-tool chmtime =-60 tracked &&
		git update-index --refresh &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "token\0tracked\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		before=$(test-tool chmtime --get tracked) &&
		git reset --hard HEAD &&
		after=$(test-tool chmtime --get tracked) &&
		test "$before" = "$after"
	)
'

test_expect_success 'ordinary zero-stat entries retain diff-index behavior' '
	test_create_repo ordinary-zero-stat &&
	(
		cd ordinary-zero-stat &&
		echo content >tracked &&
		git add tracked &&
		git commit -m base &&
		oid=$(git rev-parse :tracked) &&
		git update-index --cacheinfo 100644,$oid,tracked &&
		git -c core.fsmonitor=false diff-index --name-status HEAD >actual &&
		test_grep "^M.*tracked$" actual
	)
'

test_expect_success 'verified reported paths restore poisoned stat data' '
	test_create_repo fsmonitor-stat-recovery &&
	(
		cd fsmonitor-stat-recovery &&
		echo content >tracked &&
		git add tracked &&
		git commit -m base &&
		test-tool read-cache \
			--test-fsmonitor-content-recovery tracked
	)
'

test_expect_success 'provider global marker invalidates every tracked entry' '
	test_create_repo global-invalidate &&
	(
		cd global-invalidate &&
		printf "aaaa\n" >tracked &&
		git add tracked &&
		git commit -m base &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		test-tool chmtime =-60 tracked &&
		git update-index --refresh &&
		mtime=$(test-tool chmtime --get tracked) &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			if test -f .git/global
			then
				printf "token1\0//\0"
			else
				printf "token0\0"
			fi
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		git status --porcelain=v2 >/dev/null &&
		git status --porcelain=v2 >/dev/null &&
		printf "bbbb\n" >tracked &&
		test-tool chmtime =$mtime tracked &&
		> .git/global &&
		git status --porcelain=v2 >.git/actual &&
		test_grep "^1 \.M .* tracked$" .git/actual
	)
'

test_expect_success \
	'directory attribute invalidation requires an indexed cone' '
	test_create_repo directory-attributes &&
	(
		cd directory-attributes &&
		mkdir tracked-dir &&
		test_commit base tracked-dir/tracked &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			if test -f .git/report-cone
			then
				printf "cone-token\0tracked-dir/\0"
			elif test -f .git/report-unmatched
			then
				printf "unmatched-token\0untracked/\0"
			else
				printf "base-token\0"
			fi
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		git status --porcelain=v2 >/dev/null &&
		git status --porcelain=v2 >/dev/null &&

		> .git/report-cone &&
		GIT_TRACE2_EVENT="$PWD/.git/cone.trace" \
		GIT_TRACE_FSMONITOR="$PWD/.git/cone.fsm" \
			git status --porcelain=v2 >.git/cone.actual &&
		test_must_be_empty .git/cone.actual &&
		test_grep "fsmonitor_refresh_callback.*tracked-dir/" \
			.git/cone.fsm &&
		test_trace2_data fsmonitor semantic/attributes-cone 1 \
			<.git/cone.trace &&

		rm .git/report-cone &&
		> .git/report-unmatched &&
		GIT_TRACE2_EVENT="$PWD/.git/unmatched.trace" \
		GIT_TRACE_FSMONITOR="$PWD/.git/unmatched.fsm" \
			git status --porcelain=v2 >.git/unmatched.actual &&
		test_must_be_empty .git/unmatched.actual &&
		test_grep "fsmonitor_refresh_callback.*untracked/" \
			.git/unmatched.fsm &&
		test_grep ! \
			"\"category\":\"fsmonitor\",\"key\":\"semantic/attributes-cone\"" \
			.git/unmatched.trace
	)
'

test_expect_success 'directory events invalidate cached attributes' '
	test_create_repo directory-attribute-cache &&
	(
		cd directory-attribute-cache &&
		mkdir tracked-dir &&
		test_write_lines "tracked marker=old" \
			>tracked-dir/.gitattributes &&
		test_write_lines tracked >tracked-dir/tracked &&
		git add tracked-dir &&
		git commit -m base &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "new-token\0tracked-dir/\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		test-tool read-cache \
			--test-fsmonitor-directory-attributes
	)
'

test_expect_success HARDLINKS,!MINGW,!CYGWIN \
	'multiply-linked files stay fsmonitor-invalid' '
	test_when_finished "rm -f hardlink-alias" &&
	test_create_repo hardlink-validity &&
	(
		cd hardlink-validity &&
		echo content >tracked &&
		git add tracked &&
		git commit -m base &&
		ln tracked ../hardlink-alias &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		git status --porcelain=v2 >/dev/null &&
		git status --porcelain=v2 >/dev/null &&
		git ls-files -f >.git/flags &&
		test_grep "^H tracked$" .git/flags &&
		echo changed >>../hardlink-alias &&
		git status --porcelain=v2 >.git/actual &&
		test_grep "^1 \.M .* tracked$" .git/actual
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'second closing-query change reprimes untracked cache' '
	test_when_finished "rm -rf second-query-changed" &&
	test_create_repo second-query-changed &&
	(
		cd second-query-changed &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir cached &&
		test_write_lines "*.ignored" >.gitignore &&
		test_write_lines "*.ignored" >cached/.gitignore &&
		printf "aaaa\n" >cached/tracked &&
		test_write_lines ignored >cached/junk.ignored &&
		git add .gitignore cached/.gitignore cached/tracked &&
		git commit -m base &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		git config core.untrackedCache true &&
		git -c core.fsmonitor=false status --porcelain=v2 \
			>.git/prime &&
		test_must_be_empty .git/prime &&
		test-tool chmtime =-60 cached/tracked &&
		git update-index --refresh &&
		mtime=$(test-tool chmtime --get cached/tracked) &&
		printf "bbbb\n" >cached/tracked &&
		test-tool chmtime =$mtime cached/tracked &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor-valid cached/tracked &&
		test_grep ! FSCF .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCDC \
		GIT_TEST_FSMONITOR_QUERY_PATH=cached/tracked \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_line_count = 1 .git/actual &&
		test_grep "^1 \.M .* cached/tracked$" .git/actual &&
		test_trace2_data status fsmonitor_token/semantic-closed 1 \
			<.git/status.trace &&
		test_trace2_data status \
			fsmonitor_token/untracked-after-semantic 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/apply_count 1 \
			<.git/status.trace &&
		test_trace2_data status \
			fsmonitor_token/untracked-after-retry 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index
	)
'

test_done
