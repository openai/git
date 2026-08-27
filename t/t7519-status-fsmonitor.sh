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

test_lazy_prereq STATUS_BULK_PRELOAD '
	test_create_repo status-bulk-preload-prereq &&
	(
		cd status-bulk-preload-prereq &&
		test_write_lines tracked >tracked &&
		test_write_lines sibling >sibling &&
		git add tracked sibling &&
		git commit -qm base &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TRACE2_EVENT="$PWD/.git/bulk.trace" \
			git -c core.fsmonitor=false \
				-c core.preloadIndexBulk=true \
				status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		test_trace2_data index preload/bulk_result complete \
			<.git/bulk.trace
	)
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
		GIT_INDEX_FILE="$PWD/.git/index" \
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
		GIT_INDEX_FILE="$PWD/.git/index" \
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
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain >.git/prime-fsmonitor &&
		test_must_be_empty .git/prime-fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status >.git/settle &&
		test_grep "nothing to commit, working tree clean" \
			.git/settle &&

		GIT_OPTIONAL_LOCKS=0 \
		GIT_INDEX_FILE="$PWD/.git/index" \
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

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'historical normalized excludes reuse authenticated index stats' '
	test_when_finished "rm -rf normalized-excludes-lf normalized-excludes-no-lf" &&
	for ending in lf no-lf
	do
		test_create_repo "normalized-excludes-$ending" &&
		(
			cd "normalized-excludes-$ending" &&
			sane_unset GIT_TEST_SPLIT_INDEX &&
			mkdir one two &&
			if test "$ending" = lf
			then
				printf "ignored\n" >one/.gitignore
			else
				printf ignored >one/.gitignore
			fi &&
			cp one/.gitignore two/.gitignore &&
			test_write_lines hidden >one/ignored &&
			test_write_lines hidden >two/ignored &&
			git add one/.gitignore two/.gitignore &&
			git commit -qm base &&
			test-tool chmtime -120 one/.gitignore two/.gitignore &&
			git update-index --refresh &&
			git config core.untrackedCache true &&
			raw=$(git rev-parse :one/.gitignore) &&
			normalized=$(
				{ cat one/.gitignore && printf "\n"; } |
				git hash-object --stdin
			) &&
			test "$raw" != "$normalized" &&

			# Exercise the genuine historical add_patterns() encoding.
			git update-index --assume-unchanged \
				one/.gitignore two/.gitignore &&
			git -c core.fsmonitor=false status --porcelain=v2 \
				>.git/historical &&
			test_must_be_empty .git/historical &&
			test-tool dump-untracked-cache >.git/historical.dump &&
			test_grep "^/one/ $normalized .*valid" \
				.git/historical.dump &&
			test_grep "^/two/ $normalized .*valid" \
				.git/historical.dump &&
			git update-index --no-assume-unchanged \
				one/.gitignore two/.gitignore &&
			git config core.fsmonitor true &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git update-index --fsmonitor &&
			GIT_INDEX_FILE="$PWD/.git/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git status --porcelain=v2 >.git/prime &&
			test_must_be_empty .git/prime &&
			test_grep FSMN .git/index &&
			test_grep FSUC .git/index &&
			test_grep FSCF .git/index &&
			cat >.git/restore-historical-excludes.pl <<-\EOF &&
			use Digest::SHA qw(sha1 sha256);
			binmode STDIN;
			binmode STDOUT;
			local $/;
			my $index = <STDIN>;
			my ($algorithm, $raw_hex, $normalized_hex) = @ARGV;
			my $size = $algorithm eq "sha256" ? 32 : 20;
			my $body = substr($index, 0, -$size);
			my $offset = index($body, "UNTR");
			die "missing UNTR extension\n" if $offset < 0;
			my $length = unpack("N", substr($body, $offset + 4, 4));
			die "invalid UNTR size\n"
				if $offset + 8 + $length > length($body);
			my $payload = substr($body, $offset + 8, $length);
			my $raw = pack("H*", $raw_hex);
			my $normalized = pack("H*", $normalized_hex);
			my $cursor = 0;
			my $replaced = 0;
			while (($cursor = index($payload, $raw, $cursor)) >= 0) {
				substr($payload, $cursor, $size, $normalized);
				$cursor += $size;
				$replaced++;
			}
			die "expected exactly two historical excludes\n"
				unless $replaced == 2;
			substr($body, $offset + 8, $length, $payload);
			print $body,
				$size == 32 ? sha256($body) : sha1($body);
			EOF
			perl .git/restore-historical-excludes.pl \
				"$(test_oid algo)" "$raw" "$normalized" \
				<.git/index >.git/index.historical &&
			mv .git/index.historical .git/index &&
			test-tool dump-untracked-cache >.git/restored.dump &&
			test_grep "^/one/ $normalized " .git/restored.dump &&
			test_grep "^/two/ $normalized " .git/restored.dump &&
			GIT_OPTIONAL_LOCKS=0 \
				git -c core.fsmonitor=false \
					-c core.untrackedCache=false \
					status --porcelain=v2 >.git/expect &&
			cp .git/index .git/readonly.index &&
			for run in first second
			do
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TEST_UNTRACKED_CACHE_THREADS=1 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$PWD/.git/$run.trace" \
					git status --porcelain=v2 \
						>".git/$run.actual" &&
				test_cmp .git/expect ".git/$run.actual" &&
				test_cmp_bin .git/readonly.index .git/index &&
				test_trace2_data fsmonitor config/coherent 1 \
					<".git/$run.trace" &&
				test_trace2_data dir \
					preload_untracked_cache/index-excludes 1 \
					<".git/$run.trace" &&
				test_trace2_data dir \
					preload_untracked_cache/index-normalized-excludes 1 \
					<".git/$run.trace" &&
				test_trace2_data dir \
					preload_untracked_cache/index-normalized-objects 1 \
					<".git/$run.trace" &&
				test_trace2_data dir \
					preload_untracked_cache/index-uptodate 2 \
					<".git/$run.trace" &&
				test_trace2_data dir \
					preload_untracked_cache/index-invalidated 0 \
					<".git/$run.trace" &&
				test_trace2_data dir \
					preload_untracked_cache/normalized-excludes 2 \
					<".git/$run.trace" &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<".git/$run.trace" &&
				! test_trace2_data index refresh/sum_lstat \
					"[1-9][0-9]*" <".git/$run.trace" &&
				! test_region index do_write_index \
					".git/$run.trace" || return 1
			done
		) || return 1
	done
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

test_fsmonitor_full_proof () {
	perl - "$@" <<-\EOF
	binmode STDIN;
	open my $input, "<", $ARGV[0] or die "cannot read index: $!\n";
	binmode $input;
	local $/;
	my $index = <$input>;
	my %tokens;
	for my $name ("FSMN", "FSUC", "FSCF") {
		my $offset = index($index, $name);
		die "missing $name extension\n" if $offset < 0;
		my $size = unpack("N", substr($index, $offset + 4, 4));
		my $payload = substr($index, $offset + 8, $size);
		if ($name eq "FSCF") {
			my $flags = unpack("N", substr($payload, 8, 4));
			die "unbound FSCF flags $flags\n" if $flags != 15;
			my $length = unpack("N", substr($payload, 12, 4));
			$tokens{$name} = substr($payload, 20, $length);
		} else {
			my $end = index($payload, "\0", 4);
			die "invalid $name token\n" if $end < 0;
			$tokens{$name} = substr($payload, 4, $end - 4);
		}
	}
	die "mismatched tracked provider token\n" unless
		$tokens{"FSMN"} eq $tokens{"FSCF"};
	my ($suffix) = $tokens{"FSMN"} =~ /\Abuiltin:(.+)\z/;
	die "missing provider token\n" unless defined $suffix;
	my $untracked = $ARGV[1] eq "pending" ?
		"pending:$suffix" : $tokens{"FSMN"};
	die "mismatched untracked token\n" unless
		$tokens{"FSUC"} eq $untracked;
	die "unexpected provider token\n" if defined($ARGV[2]) &&
		$tokens{"FSMN"} ne $ARGV[2];
	EOF
}

wait_for_fsmonitor_query_barrier () {
	for attempt in $(test_seq 1 500)
	do
		if test "$(cat "$1" 2>/dev/null)" = ready
		then
			return 0
		fi
		kill -0 "$2" 2>/dev/null || return 1
		sleep 0.01
	done
	return 1
}

cleanup_fsmonitor_query_barrier () {
	if test -n "${fsmonitor_query_pid-}"
	then
		kill "$fsmonitor_query_pid" 2>/dev/null || :
		wait "$fsmonitor_query_pid" 2>/dev/null || :
		fsmonitor_query_pid=
	fi
}

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'bare status reuses a current tracked fsmonitor proof' '
	test_when_finished "rm -rf builtin-tracked-clean" &&
	prepare_builtin_closure_repo builtin-tracked-clean &&
	(
		cd builtin-tracked-clean &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain >.git/prime &&
		test_must_be_empty .git/prime &&

		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
		GIT_TRACE2_EVENT="$PWD/.git/clean.trace" \
			git status >.git/clean &&
		test_grep "nothing to commit, working tree clean" \
			.git/clean &&
		test_trace2_data status fsmonitor/tracked-clean 1 \
			<.git/clean.trace &&
		test_trace2_data status index/cache-tree-match 1 \
			<.git/clean.trace &&

		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/exact.trace" \
			git status --porcelain=v2 >.git/exact &&
		test_must_be_empty .git/exact &&
		test_trace2_data status fsmonitor/tracked-clean 1 \
			<.git/exact.trace &&
		test_grep ! \
			"\"category\":\"index\",\"label\":\"refresh\"" \
			.git/exact.trace &&

		test_write_lines changed >tracked &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$PWD/.git/dirty.trace" \
			git status >.git/dirty &&
		test_grep "modified:.*tracked" .git/dirty &&
		! test_trace2_data status fsmonitor/tracked-clean 1 \
			<.git/dirty.trace &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git checkout -- tracked &&
		test_write_lines staged >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git add tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git write-tree >.git/staged-tree &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor-valid tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain >.git/staged-prime &&
		test_grep "^M  tracked$" .git/staged-prime &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
		GIT_TRACE2_EVENT="$PWD/.git/staged.trace" \
			git status >.git/staged &&
		test_grep "Changes to be committed:" .git/staged &&
		test_grep "modified:.*tracked" .git/staged &&
		test_trace2_data status fsmonitor/tracked-clean 1 \
			<.git/staged.trace &&
		! test_trace2_data status index/cache-tree-match 1 \
			<.git/staged.trace
	)
'

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

		GIT_INDEX_FILE="$PWD/.git/index" \
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

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'provider reset revalidates authenticated untracked directories' '
	test_when_finished "rm -rf builtin-reset-untracked" &&
	test_create_repo builtin-reset-untracked &&
	(
		cd builtin-reset-untracked &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir -p cached/deep sibling/empty &&
		test_write_lines "*.root-ignored" >.gitignore &&
		test_write_lines "*.nested-ignored" >cached/.gitignore &&
		test_write_lines tracked >cached/deep/tracked &&
		test_write_lines sibling >sibling/empty/tracked &&
		test_write_lines hidden >cached/deep/hidden.nested-ignored &&
		test_write_lines hidden >sibling/hidden.root-ignored &&
		test_write_lines visible >cached/deep/retained &&
		git add .gitignore cached/.gitignore cached/deep/tracked \
			sibling/empty/tracked &&
		git commit -m base &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		test-tool chmtime =-60 cached/deep cached \
			sibling/empty sibling . &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		for prime in first second third
		do
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
				git status --porcelain=v2 >.git/prime || return 1
		done &&
		test_grep "^? cached/deep/retained$" .git/prime &&
		test_grep FSUC .git/index &&
		test_grep FSCF .git/index &&
		rm -f .git/index.csts &&
		cp .git/index .git/reset.index &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
		GIT_TEST_UNTRACKED_CACHE_AUTO_PRELOAD=1 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=4 \
		GIT_TRACE2_EVENT="$PWD/.git/reset.trace" \
			git status --porcelain=v2 >.git/reset.actual &&
		test_cmp .git/prime .git/reset.actual &&
		test_trace2_data fsmonitor \
			untracked/provider-reset-preserved 1 <.git/reset.trace &&
		test_trace2_data status \
			untracked/provider-reset-preload 1 <.git/reset.trace &&
		test_trace2_data dir preload_untracked_cache/valid 1 \
			<.git/reset.trace &&
		test_trace2_data read_directory opendir 0 <.git/reset.trace &&
		test_trace2_data fsmonitor \
			untracked/provider-reset-revalidated 1 <.git/reset.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/reset.trace &&
		test_cmp .git/reset.index .git/index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
		GIT_TEST_UNTRACKED_CACHE_AUTO_PRELOAD=1 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=4 \
		GIT_TRACE2_EVENT="$PWD/.git/reset-write.trace" \
			git status --porcelain=v2 >.git/reset-write.actual &&
		test_cmp .git/prime .git/reset-write.actual &&
		test_trace2_data fsmonitor \
			untracked/provider-reset-revalidated 1 \
			<.git/reset-write.trace &&
		test_region index do_write_index .git/reset-write.trace &&
		test_grep FSMN .git/index &&
		test_grep FSUC .git/index &&
		test_write_lines changed >cached/deep/tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/reset-add.trace" \
			git add cached/deep/tracked &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/reset-add.trace &&
		test_grep FSMN .git/index &&
		test_grep FSUC .git/index
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'discarded legacy caches select one bulk recovery pass' '
	test_when_finished "rm -rf legacy-discard-bulk" &&
	if test_have_prereq STATUS_BULK_PRELOAD
	then
		bulk_available=yes
	else
		bulk_available=no
	fi &&
	test_create_repo legacy-discard-bulk &&
	(
		cd legacy-discard-bulk &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir -p cached/deep sibling/empty &&
		test_write_lines "*.ignored" >.gitignore &&
		test_write_lines tracked >cached/deep/tracked &&
		test_write_lines sibling >sibling/empty/tracked &&
		test_write_lines hidden >cached/deep/hidden.ignored &&
		test_write_lines visible >cached/deep/visible &&
		git add .gitignore cached/deep/tracked sibling/empty/tracked &&
		git commit -qm base &&
		test-tool chmtime -120 .gitignore cached/deep/tracked \
			sibling/empty/tracked &&
		git update-index --refresh &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/paired &&
		test_grep "^? cached/deep/visible$" .git/paired &&
		test_grep ! hidden.ignored .git/paired &&
		test_fsmonitor_full_proof .git/index paired &&
		test_path_is_missing .git/index.csts &&
		find .git -maxdepth 1 -type f \
			\( -name "index.csh1.*" -o -name "index.cswi.*" \) \
			>.git/checkpoints &&
		test_must_be_empty .git/checkpoints &&
		cp .git/index .git/paired.index &&

		cat >.git/restore-legacy-untracked.pl <<-\EOF &&
		use Digest::SHA qw(sha1 sha256);
		binmode STDIN;
		binmode STDOUT;
		local $/;
		my $index = <STDIN>;
		my $algorithm = $ARGV[0];
		my $empty = $ARGV[1] && $ARGV[1] =~ /^(current-)?empty$/;
		my $current = $ARGV[1] && $ARGV[1] eq "current-empty";
		my $rawsz = $algorithm eq "sha256" ? 32 : 20;
		my $body = substr($index, 0, -$rawsz);
		my $offset = index($body, "UNTR");
		die "missing UNTR extension\n" if $offset < 0;
		my $size = unpack("N", substr($body, $offset + 4, 4));
		die "invalid UNTR extension size\n"
			if $offset + 8 + $size > length($body);
		my $payload = substr($body, $offset + 8, $size);
		die "missing populated UNTR directory root\n"
			unless index($payload, "cached\0") >= 0 &&
				index($payload, "visible\0") >= 0;
		my $cursor = 0;
		my $byte = ord(substr($payload, $cursor++, 1));
		my $ident_length = $byte & 127;
		while ($byte & 128) {
			die "truncated UNTR identity length\n"
				if $cursor >= length($payload);
			$ident_length++;
			$byte = ord(substr($payload, $cursor++, 1));
			$ident_length = ($ident_length << 7) + ($byte & 127);
		}
		die "truncated UNTR identity\n"
			if $cursor + $ident_length > length($payload);
		my $ident = substr($payload, $cursor, $ident_length);
		my $suffix = ", cache version 2\0";
		die "unexpected current UNTR identity\n"
			unless substr($ident, -length($suffix)) eq $suffix;
		substr($ident, -length($suffix), length($suffix), "\0")
			unless $current;
		my $length = length($ident);
		my @bytes = ($length & 127);
		while ($length >>= 7) {
			unshift @bytes, 128 | ((--$length) & 127);
		}
		my $tail = substr($payload, $cursor + $ident_length);
		if ($empty) {
			my $exclude = index($tail, "\0", 76 + 2 * $rawsz);
			die "missing UNTR per-directory exclude name\n"
				if $exclude < 0;
			$tail = substr($tail, 0, $exclude + 1) . "\0";
		}
		my $replacement = pack("C*", @bytes) . $ident . $tail;
		substr($body, $offset, 8 + $size,
			"UNTR" . pack("N", length($replacement)) . $replacement);
		my $fsuc = index($body, "FSUC");
		die "missing paired FSUC extension\n" if $fsuc < 0;
		my $fsuc_size = unpack("N", substr($body, $fsuc + 4, 4));
		die "invalid FSUC extension size\n"
			if $fsuc + 8 + $fsuc_size > length($body);
		substr($body, $fsuc, 8 + $fsuc_size, "");
		if ($empty) {
			my $fscf = index($body, "FSCF");
			die "missing FSCF extension\n" if $fscf < 0;
			my $fscf_size = unpack("N", substr($body, $fscf + 4, 4));
			die "invalid FSCF extension size\n"
				if $fscf + 8 + $fscf_size > length($body);
			substr($body, $fscf, 8 + $fscf_size, "");
		}
		print $body,
			$algorithm eq "sha256" ? sha256($body) : sha1($body);
		EOF
		perl .git/restore-legacy-untracked.pl "$(test_oid algo)" \
			<.git/paired.index >.git/legacy.index &&
		cp .git/legacy.index .git/index &&
		test_grep FSMN .git/index &&
		test_grep UNTR .git/index &&
		test_grep FSCF .git/index &&
		test_grep ! FSUC .git/index &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				status --porcelain=v2 >.git/expect &&
		test_cmp .git/paired .git/expect &&
		test_cmp_bin .git/legacy.index .git/index &&

		for disabled in bulk environment preload
		do
			case "$disabled" in
			bulk)
				set -- git -c core.preloadIndexBulk=false
				;;
			environment)
				set -- env GIT_TEST_PRELOAD_INDEX_BULK=0 \
					git -c core.preloadIndexBulk=true
				;;
			preload)
				set -- git -c core.preloadIndex=false \
					-c core.preloadIndexBulk=true
				;;
			esac &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_PRELOAD_INDEX=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$disabled.trace" \
				"$@" status --porcelain=v2 \
				>".git/$disabled.actual" &&
			test_cmp .git/expect ".git/$disabled.actual" &&
			test_cmp_bin .git/legacy.index .git/index &&
			test_trace2_data fsm_client query/trivial-response 1 \
				<".git/$disabled.trace" &&
			test_trace2_data fsmonitor untracked/legacy-preserved 1 \
				<".git/$disabled.trace" &&
			test_trace2_data fsmonitor untracked/legacy-discarded 1 \
				<".git/$disabled.trace" &&
			! test_trace2_data status untracked/bulk-recovery 1 \
				<".git/$disabled.trace" &&
			! test_trace2_data index preload/bulk_untracked_complete 1 \
				<".git/$disabled.trace" &&
			test_region dir read_directory ".git/$disabled.trace" &&
			! test_region index do_write_index \
				".git/$disabled.trace" || return 1
		done &&

		cp .git/paired.index .git/index &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/paired.trace" \
			git -c core.preloadIndexBulk=true \
				status --porcelain=v2 >.git/paired.actual &&
		test_cmp .git/expect .git/paired.actual &&
		test_cmp_bin .git/paired.index .git/index &&
		test_fsmonitor_full_proof .git/index paired &&
		! test_trace2_data fsmonitor untracked/legacy-discarded 1 \
			<.git/paired.trace &&
		! test_trace2_data status untracked/bulk-recovery 1 \
			<.git/paired.trace &&

		cp .git/legacy.index .git/index &&
		for run in first second auto
		do
			if test "$run" = auto
			then
				set -- git
			else
				set -- git -c core.preloadIndexBulk=true
			fi &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_PRELOAD_INDEX=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$run.trace" \
				"$@" status --porcelain=v2 \
					>".git/$run.actual" &&
			test_cmp .git/expect ".git/$run.actual" &&
			test_cmp_bin .git/legacy.index .git/index &&
			test_path_is_missing .git/index.csts &&
			find .git -maxdepth 1 -type f \
				\( -name "index.csh1.*" \
					-o -name "index.cswi.*" \) \
				>".git/$run.checkpoints" &&
			test_must_be_empty ".git/$run.checkpoints" &&
			test_trace2_data fsm_client query/trivial-response 1 \
				<".git/$run.trace" &&
			test_trace2_data fsmonitor untracked/legacy-discarded 1 \
				<".git/$run.trace" &&
			! test_region index do_write_index ".git/$run.trace" &&
			if test "$bulk_available" = yes
			then
				test_trace2_data status untracked/bulk-recovery 1 \
					<".git/$run.trace" &&
				test_trace2_data index \
					preload/bulk_untracked_complete 1 \
					<".git/$run.trace" &&
				test_trace2_data index \
					preload/bulk_provider_applied \
					"[1-9][0-9]*" <".git/$run.trace" &&
				! test_region dir read_directory \
					".git/$run.trace"
			else
				! test_trace2_data index \
					preload/bulk_untracked_complete 1 \
					<".git/$run.trace" &&
				test_region dir read_directory \
					".git/$run.trace"
			fi || return 1
		done &&

		perl .git/restore-legacy-untracked.pl "$(test_oid algo)" \
			current-empty <.git/paired.index >.git/current.index &&
		cp .git/current.index .git/index &&
		test_grep FSMN .git/index &&
		test_grep UNTR .git/index &&
		test_grep ! FSCF .git/index &&
		test_grep ! FSUC .git/index &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/current.trace" \
			git status --porcelain=v2 >.git/current.actual &&
		test_cmp .git/expect .git/current.actual &&
		test_cmp_bin .git/current.index .git/index &&
		test_path_is_missing .git/index.csts &&
		find .git -maxdepth 1 -type f \
			\( -name "index.csh1.*" -o -name "index.cswi.*" \) \
			>.git/current.checkpoints &&
		test_must_be_empty .git/current.checkpoints &&
		! test_trace2_data fsmonitor untracked/legacy-discarded 1 \
			<.git/current.trace &&
		! test_trace2_data status untracked/bulk-recovery 1 \
			<.git/current.trace &&
		! test_region index do_write_index .git/current.trace &&
		test_region dir read_directory .git/current.trace &&

		perl .git/restore-legacy-untracked.pl "$(test_oid algo)" \
			empty <.git/paired.index >.git/empty.index &&
		cp .git/empty.index .git/index &&
		test_grep FSMN .git/index &&
		test_grep UNTR .git/index &&
		test_grep ! FSCF .git/index &&
		test_grep ! FSUC .git/index &&
		for run in empty-explicit empty-auto
		do
			if test "$run" = empty-auto
			then
				set -- git
			else
				set -- git -c core.preloadIndexBulk=true
			fi &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_PRELOAD_INDEX=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$run.trace" \
				"$@" status --porcelain=v2 \
					>".git/$run.actual" &&
			test_cmp .git/expect ".git/$run.actual" &&
			test_cmp_bin .git/empty.index .git/index &&
			test_path_is_missing .git/index.csts &&
			find .git -maxdepth 1 -type f \
				\( -name "index.csh1.*" \
					-o -name "index.cswi.*" \) \
				>".git/$run.checkpoints" &&
			test_must_be_empty ".git/$run.checkpoints" &&
			test_trace2_data fsmonitor untracked/legacy-preserved 1 \
				<".git/$run.trace" &&
			test_trace2_data fsmonitor untracked/legacy-discarded 1 \
				<".git/$run.trace" &&
			! test_trace2_data fsm_client query/trivial-response 1 \
				<".git/$run.trace" &&
			! test_region index do_write_index ".git/$run.trace" &&
			if test "$bulk_available" = yes
			then
				test_trace2_data status untracked/bulk-recovery 1 \
					<".git/$run.trace" &&
				test_trace2_data index \
					preload/bulk_untracked_complete 1 \
					<".git/$run.trace" &&
				! test_region dir read_directory \
					".git/$run.trace"
			else
				! test_trace2_data index \
					preload/bulk_untracked_complete 1 \
					<".git/$run.trace" &&
				test_region dir read_directory \
					".git/$run.trace"
			fi || return 1
		done &&
		cp .git/legacy.index .git/index &&

		GIT_OPTIONAL_LOCKS=1 \
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/writable.trace" \
			git -c core.preloadIndexBulk=true \
				status --porcelain=v2 >.git/writable &&
		test_cmp .git/expect .git/writable &&
		test_trace2_data fsmonitor untracked/legacy-discarded 1 \
			<.git/writable.trace &&
		! test_trace2_data status untracked/bulk-recovery 1 \
			<.git/writable.trace &&
		test_region index do_write_index .git/writable.trace &&
		test_fsmonitor_full_proof .git/index paired &&
		cp .git/index .git/writable.index &&
		find .git -maxdepth 1 -type f \
			\( -name "index.csts" -o -name "index.csh1.*" \
				-o -name "index.cswi.*" \) |
			sort >.git/sidecars.before &&
		git hash-object --no-filters --stdin-paths \
			<.git/sidecars.before >.git/sidecar-hashes.before &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/follower.trace" \
			git status --porcelain=v2 >.git/follower &&
		test_cmp .git/expect .git/follower &&
		test_cmp_bin .git/writable.index .git/index &&
		test_fsmonitor_full_proof .git/index paired &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/follower.trace &&
		! test_trace2_data fsmonitor untracked/legacy-discarded 1 \
			<.git/follower.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count \
			"[1-9][0-9]*" <.git/follower.trace &&
		! test_trace2_data read_directory opendir \
			"[1-9][0-9]*" <.git/follower.trace &&
		! test_trace2_data index preload/bulk_dirs \
			"[1-9][0-9]*" <.git/follower.trace &&
		! test_trace2_data index preload/sum_lstat \
			"[1-9][0-9]*" <.git/follower.trace &&
		! test_region index do_write_index .git/follower.trace &&
		find .git -maxdepth 1 -type f \
			\( -name "index.csts" -o -name "index.csh1.*" \
				-o -name "index.cswi.*" \) |
			sort >.git/sidecars.after &&
		test_cmp .git/sidecars.before .git/sidecars.after &&
		git hash-object --no-filters --stdin-paths \
			<.git/sidecars.after >.git/sidecar-hashes.after &&
		test_cmp .git/sidecar-hashes.before .git/sidecar-hashes.after
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'index writers preserve authenticated untracked proofs' '
	test_when_finished "rm -rf missing-untracked-proof" &&
	test_create_repo missing-untracked-proof &&
	(
		cd missing-untracked-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSMN .git/index &&
		test_grep FSUC .git/index &&

		test_write_lines changed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/healthy.trace" \
			git add tracked &&
		test_grep FSUC .git/index &&
		! test_trace2_data fsmonitor untracked/proof-missing 1 \
			<.git/healthy.trace &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/reset.trace" \
			git reset --hard HEAD >.git/reset.out &&
		test_region index do_write_index .git/reset.trace &&
		! test_trace2_data fsmonitor untracked/proof-missing 1 \
			<.git/reset.trace &&
		test_grep FSMN .git/index &&
		test_grep UNTR .git/index &&
		test_grep FSUC .git/index &&
		test_fsmonitor_full_proof .git/index paired &&

		cp .git/index .git/reset.index &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/reset-status.trace" \
			git status --porcelain=v2 >.git/reset-status &&
		test_must_be_empty .git/reset-status &&
		test_cmp_bin .git/reset.index .git/index &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/reset-status.trace &&
		! test_region index do_write_index .git/reset-status.trace &&

		cp .git/index .git/alternate.index &&
		GIT_INDEX_FILE="$PWD/.git/alternate.index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/alternate.trace" \
			git reset --hard HEAD >.git/alternate.out &&
		! test_trace2_data fsmonitor untracked/proof-missing 1 \
			<.git/alternate.trace &&
		test_grep FSUC .git/index &&

		test_write_lines stashed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=T \
			git add tracked &&
		test_grep "pending:" .git/index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
			git status --porcelain=v2 >.git/staged &&
		test_grep "^1 M\\. .* tracked$" .git/staged &&
		test_grep FSUC .git/index &&
		test_grep ! "pending:" .git/index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/stash.trace" \
			git stash push -m proof-missing >.git/stash.out &&
		test_region index do_write_index .git/stash.trace &&
		! test_trace2_data fsmonitor untracked/proof-missing 1 \
			<.git/stash.trace &&
		test_grep FSMN .git/index &&
		test_grep UNTR .git/index &&
		test_grep FSUC .git/index &&
		test_fsmonitor_full_proof .git/index paired
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'repeated stash creation preserves bound worktree proofs' '
	test_when_finished "rm -rf stash-unbound-proof stash-unbound-linked" &&
	test_create_repo stash-unbound-proof &&
	(
		cd stash-unbound-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit sibling sibling &&
		git worktree add --detach ../stash-unbound-linked HEAD &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		cat >.git/check-stash-proof.pl <<-\EOF &&
		binmode STDIN;
		local $/;
		my $index = <STDIN>;
		my %tokens;
		for my $name ("FSMN", "FSUC", "FSCF") {
			my $offset = index($index, $name);
			die "missing $name extension\n" if $offset < 0;
			my $size = unpack("N", substr($index, $offset + 4, 4));
			my $payload = substr($index, $offset + 8, $size);
			if ($name eq "FSCF") {
				my $flags = unpack("N", substr($payload, 8, 4));
				die "unbound FSCF flags $flags\n" if $flags != 15;
				my $length = unpack("N", substr($payload, 12, 4));
				$tokens{$name} = substr($payload, 20, $length);
			} else {
				my $end = index($payload, "\0", 4);
				die "invalid $name token\n" if $end < 0;
				$tokens{$name} = substr($payload, 4, $end - 4);
			}
		}
		die "mismatched provider tokens\n" unless
			$tokens{"FSMN"} eq $tokens{"FSUC"} &&
			$tokens{"FSMN"} eq $tokens{"FSCF"};
		EOF
		for worktree in "$PWD" "$PWD/../stash-unbound-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			test_write_lines staged >"$worktree/staged" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" add staged &&
			test_write_lines modified >"$worktree/tracked" &&
			for run in first second
			do
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
				GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
				GIT_TRACE2_EVENT="$gitdir/stash-$run.trace" \
					git -C "$worktree" stash create \
						"cmux last turn baseline" \
						>"$gitdir/stash-$run" &&
				test_file_not_empty "$gitdir/stash-$run" &&
				! test_trace2_data fsmonitor \
					untracked/proof-missing 1 \
					<"$gitdir/stash-$run.trace" &&
				! test_trace2_data fsmonitor config/coherent 0 \
					<"$gitdir/stash-$run.trace" &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<"$gitdir/stash-$run.trace" &&
				perl "$PWD/.git/check-stash-proof.pl" \
					<"$gitdir/index" &&
				cp "$gitdir/index" "$gitdir/readonly.index" &&
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TEST_PRELOAD_INDEX=1 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/status-$run.trace" \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/status-$run" &&
				test_cmp_bin "$gitdir/readonly.index" "$gitdir/index" &&
				test_grep "^1 A\\. .* staged$" \
					"$gitdir/status-$run" &&
				test_grep "^1 \\.M .* tracked$" \
					"$gitdir/status-$run" &&
				test_trace2_data fsmonitor config/coherent 1 \
					<"$gitdir/status-$run.trace" &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<"$gitdir/status-$run.trace" &&
				if test_have_prereq PTHREADS
				then
					test_trace2_data index preload/sum_lstat 1 \
						<"$gitdir/status-$run.trace"
				else
					test_region ! index preload \
						"$gitdir/status-$run.trace"
				fi &&
				test_trace2_data index refresh/sum_lstat 1 \
					<"$gitdir/status-$run.trace" || return 1
			done &&
			test_write_lines "*.asset text" \
				>"$worktree/.gitattributes" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" add .gitattributes &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/attributes.trace" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/attributes" &&
			test_trace2_data fsmonitor config/coherent 0 \
				<"$gitdir/attributes.trace" &&
			test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/attributes.trace" &&
			test_grep "^1 A\\. .* \\.gitattributes$" \
				"$gitdir/attributes" || return 1
		done
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'commit modes restore external-only worktree proofs' '
	test_when_finished "rm -rf commit-external-only commit-external-linked" &&
	test_create_repo commit-external-only &&
	(
		cd commit-external-only &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_write_lines "tracked -text" >.gitattributes &&
		git add .gitattributes &&
		git commit -qm attributes &&
		git worktree add --detach ../commit-external-linked HEAD &&
		test-tool chmtime -120 tracked .gitattributes \
			../commit-external-linked/tracked \
			../commit-external-linked/.gitattributes &&
		git update-index --refresh &&
		git -C ../commit-external-linked update-index --refresh &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		cat >.git/remove-paired-proofs.pl <<-\EOF &&
		use Digest::SHA qw(sha1 sha256);
		binmode STDIN;
		binmode STDOUT;
		local $/;
		my $index = <STDIN>;
		my $rawsz = $ARGV[0] eq "sha256" ? 32 : 20;
		for my $name ("FSUC", "FSCF") {
			my $offset = index($index, $name);
			die "missing $name extension\n" if $offset < 0;
			my $size = unpack("N", substr($index, $offset + 4, 4));
			substr($index, $offset, 8 + $size, "");
		}
		my $payload = substr($index, 0, -$rawsz);
		print $payload, $rawsz == 32 ? sha256($payload) : sha1($payload);
		EOF
		for worktree in "$PWD" "$PWD/../commit-external-linked"
		do
			gitdir=$(git -C "$worktree" rev-parse --absolute-git-dir) &&
			for mode in all include amend only attributes
			do
				test-tool chmtime -120 "$worktree/tracked" &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
				GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
					git -C "$worktree" update-index --refresh &&
				rm -f "$gitdir"/index.csh1.* "$gitdir"/index.cswi.* &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
					git -C "$worktree" update-index --fsmonitor &&
				GIT_INDEX_FILE="$gitdir/index" \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/$mode.prime" &&
				test_must_be_empty "$gitdir/$mode.prime" &&
				test_fsmonitor_full_proof "$gitdir/index" paired &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/$mode.checkpoint.trace" \
					git -C "$worktree" status --short \
						>"$gitdir/$mode.checkpoint" &&
				test_must_be_empty "$gitdir/$mode.checkpoint" &&
				test_trace2_data fsmonitor history/external-stored 1 \
					<"$gitdir/$mode.checkpoint.trace" &&
				find "$gitdir" -maxdepth 1 -type f \
					-name "index.csh1.*" >"$gitdir/$mode.csh" &&
				test_line_count = 1 "$gitdir/$mode.csh" &&
				perl "$PWD/.git/remove-paired-proofs.pl" \
					"$(test_oid algo)" <"$gitdir/index" \
					>"$gitdir/index.foreign" &&
				mv "$gitdir/index.foreign" "$gitdir/index" &&
				test_grep FSMN "$gitdir/index" &&
				test_grep ! FSUC "$gitdir/index" &&
				test_grep ! FSCF "$gitdir/index" &&
				query=DDDDCCCCCCCCCCCC &&
				case "$mode" in
				all)
					test_write_lines all >"$worktree/tracked" &&
					path=tracked &&
					set -- -a -qm commit-all
					;;
				include)
					test_write_lines include >"$worktree/tracked" &&
					path=tracked &&
					set -- --include tracked -qm commit-include
					;;
				amend)
					test_write_lines amend >"$worktree/tracked" &&
					path=tracked &&
					set -- -a --amend --no-edit -q
					;;
				only)
					test_write_lines only >"$worktree/tracked" &&
					path=tracked &&
					query=DDDDDDCCCCCCCCCCCC &&
					set -- --only tracked -qm commit-only
					;;
				attributes)
					test_write_lines "tracked text" \
						>"$worktree/.gitattributes" &&
					path=.gitattributes &&
					set -- -a -qm changed-attributes
					;;
				esac &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE="$query" \
				GIT_TEST_FSMONITOR_QUERY_PATH="$path" \
				GIT_TRACE2_EVENT="$gitdir/$mode.commit.trace" \
					git -C "$worktree" commit "$@" &&
				test_trace2_data fsmonitor history/external-restored 1 \
					<"$gitdir/$mode.commit.trace" &&
				if test "$mode" = attributes
				then
					test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
						<"$gitdir/$mode.commit.trace" &&
					test_trace2_data fsmonitor semantic/manifest-invalidated 1 \
						<"$gitdir/$mode.commit.trace" &&
					test_trace2_data fsmonitor untracked/proof-missing 1 \
						<"$gitdir/$mode.commit.trace"
				else
					! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
						<"$gitdir/$mode.commit.trace" &&
					! test_trace2_data fsmonitor untracked/proof-missing 1 \
						<"$gitdir/$mode.commit.trace" &&
					if test "$mode" = only
					then
						test_trace2_data fsmonitor history/untracked-paired-transfer 1 \
							<"$gitdir/$mode.commit.trace" || return 1
					fi &&
					test_fsmonitor_full_proof "$gitdir/index" paired
				fi &&
				cp "$gitdir/index" "$gitdir/$mode.before-status" &&
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/$mode.status.trace" \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/$mode.status" &&
				test_must_be_empty "$gitdir/$mode.status" &&
				test_cmp_bin "$gitdir/$mode.before-status" "$gitdir/index" &&
				if test "$mode" != attributes
				then
					test_trace2_data fsmonitor config/coherent 1 \
						<"$gitdir/$mode.status.trace" &&
					! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
						<"$gitdir/$mode.status.trace" || return 1
				fi || return 1
			done || return 1
		done
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'checkout-index updates restore external-only worktree proofs' '
	test_when_finished "rm -rf checkout-external-only checkout-external-linked" &&
	test_create_repo checkout-external-only &&
	(
		cd checkout-external-only &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit sibling sibling &&
		git worktree add --detach ../checkout-external-linked HEAD &&
		test-tool chmtime -120 tracked sibling \
			../checkout-external-linked/tracked \
			../checkout-external-linked/sibling &&
		git update-index --refresh &&
		git -C ../checkout-external-linked update-index --refresh &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		cat >.git/remove-checkout-proofs.pl <<-\EOF &&
		use Digest::SHA qw(sha1 sha256);
		binmode STDIN;
		binmode STDOUT;
		local $/;
		my $index = <STDIN>;
		my $rawsz = $ARGV[0] eq "sha256" ? 32 : 20;
		for my $name ("FSUC", "FSCF") {
			my $offset = index($index, $name);
			die "missing $name extension\n" if $offset < 0;
			my $size = unpack("N", substr($index, $offset + 4, 4));
			substr($index, $offset, 8 + $size, "");
		}
		my $payload = substr($index, 0, -$rawsz);
		print $payload, $rawsz == 32 ? sha256($payload) : sha1($payload);
		EOF
		strip_checkout_proofs="$PWD/.git/remove-checkout-proofs.pl" &&
		for worktree in "$PWD" "$PWD/../checkout-external-linked"
		do
			gitdir=$(git -C "$worktree" rev-parse --absolute-git-dir) &&
			for mode in noop ordinary temp prefix alternate attributes
			do
				test-tool chmtime -120 "$worktree/tracked" &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
				GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
					git -C "$worktree" update-index --refresh &&
				rm -f "$worktree/.gitattributes" \
					"$gitdir"/index.csh1.* \
					"$gitdir"/index.cswi.* \
					"$gitdir/index.csts" &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
					git -C "$worktree" update-index --fsmonitor &&
				GIT_INDEX_FILE="$gitdir/index" \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/$mode.prime" &&
				test_must_be_empty "$gitdir/$mode.prime" &&
				test_fsmonitor_full_proof "$gitdir/index" paired &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/$mode.checkpoint.trace" \
					git -C "$worktree" status --short \
						>"$gitdir/$mode.checkpoint" &&
				test_must_be_empty "$gitdir/$mode.checkpoint" &&
				test_trace2_data fsmonitor history/external-stored 1 \
					<"$gitdir/$mode.checkpoint.trace" &&
				find "$gitdir" -maxdepth 1 -type f \
					-name "index.csh1.*" >"$gitdir/$mode.csh" &&
				test_line_count = 1 "$gitdir/$mode.csh" &&
				checkpoint=$(cat "$gitdir/$mode.csh") &&
				cp "$checkpoint" "$gitdir/$mode.checkpoint.before" &&
				perl "$strip_checkout_proofs" "$(test_oid algo)" \
					<"$gitdir/index" >"$gitdir/index.foreign" &&
				mv "$gitdir/index.foreign" "$gitdir/index" &&
				test_grep FSMN "$gitdir/index" &&
				test_grep UNTR "$gitdir/index" &&
				test_grep ! FSUC "$gitdir/index" &&
				test_grep ! FSCF "$gitdir/index" &&
				cp "$gitdir/index" "$gitdir/$mode.stripped.index" &&

				case "$mode" in
				noop)
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					GIT_TRACE2_EVENT="$gitdir/$mode.checkout.trace" \
						git -C "$worktree" checkout-index \
							-f -u tracked &&
					test_trace2_data fsmonitor \
						history/external-restored 1 \
						<"$gitdir/$mode.checkout.trace" &&
					test_trace2_data index \
						extension/fsmn/read/token builtin:test:3 \
						<"$gitdir/$mode.checkout.trace" &&
					test_trace2_data index \
						extension/fsmn/read/token builtin:test:1 \
						<"$gitdir/$mode.checkout.trace" &&
					test_region ! index do_write_index \
						"$gitdir/$mode.checkout.trace" &&
					test_cmp_bin "$gitdir/$mode.stripped.index" \
						"$gitdir/index"
					;;
				ordinary)
					test_write_lines modified >"$worktree/tracked" &&
					GIT_OPTIONAL_LOCKS=0 \
						git -C "$worktree" \
							-c core.fsmonitor=false \
							-c core.untrackedCache=false \
							-c core.trustctime=true \
							-c core.checkStat=default \
							status --porcelain=v2 \
							>"$gitdir/$mode.expected" &&
					test_line_count = 1 "$gitdir/$mode.expected" &&
					test_grep "^1 \\.M .* tracked$" \
						"$gitdir/$mode.expected" &&
					test_cmp_bin "$gitdir/$mode.stripped.index" \
						"$gitdir/index" &&
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCCCCCCC \
					GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
					GIT_TRACE2_EVENT="$gitdir/$mode.checkout.trace" \
						git -C "$worktree" checkout-index \
							-f -u tracked &&
					test_trace2_data fsmonitor \
						history/external-restored 1 \
						<"$gitdir/$mode.checkout.trace" &&
					test_trace2_data fsmonitor apply_count 1 \
						<"$gitdir/$mode.checkout.trace" &&
					test_region index do_write_index \
						"$gitdir/$mode.checkout.trace" &&
					test_fsmonitor_full_proof "$gitdir/index" \
						paired &&
					! test_trace2_data fsmonitor \
						semantic/manifest-scan-count 1 \
						<"$gitdir/$mode.checkout.trace" &&
					cp "$gitdir/index" \
						"$gitdir/$mode.before-status" &&
					GIT_OPTIONAL_LOCKS=0 \
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					GIT_TRACE2_EVENT="$gitdir/$mode.status.trace" \
						git -C "$worktree" status --porcelain=v2 \
							>"$gitdir/$mode.status" &&
					test_must_be_empty "$gitdir/$mode.status" &&
					test_cmp_bin "$gitdir/$mode.before-status" \
						"$gitdir/index" &&
					test_trace2_data fsmonitor config/coherent 1 \
						<"$gitdir/$mode.status.trace" &&
					! test_trace2_data fsmonitor \
						semantic/manifest-scan-count 1 \
						<"$gitdir/$mode.status.trace"
					;;
				temp)
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					GIT_TRACE2_EVENT="$gitdir/$mode.checkout.trace" \
						git -C "$worktree" checkout-index \
							-u --temp tracked \
							>"$gitdir/$mode.output" &&
					temp_path=$(cut -f1 "$gitdir/$mode.output") &&
					test_path_is_file "$worktree/$temp_path" &&
					rm "$worktree/$temp_path" &&
					! test_trace2_data fsmonitor \
						history/external-restored 1 \
						<"$gitdir/$mode.checkout.trace" &&
					test_cmp_bin "$gitdir/$mode.stripped.index" \
						"$gitdir/index"
					;;
				prefix)
					mkdir "$gitdir/checkout-prefix" &&
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					GIT_TRACE2_EVENT="$gitdir/$mode.checkout.trace" \
						git -C "$worktree" checkout-index \
							-f -u \
							--prefix="$gitdir/checkout-prefix/" \
							tracked &&
					test_path_is_file \
						"$gitdir/checkout-prefix/tracked" &&
					! test_trace2_data fsmonitor \
						history/external-restored 1 \
						<"$gitdir/$mode.checkout.trace" &&
					test_cmp_bin "$gitdir/$mode.stripped.index" \
						"$gitdir/index"
					;;
				alternate)
					cp "$gitdir/index" "$gitdir/alternate.index" &&
					GIT_INDEX_FILE="$gitdir/alternate.index" \
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					GIT_TRACE2_EVENT="$gitdir/$mode.checkout.trace" \
						git -C "$worktree" checkout-index \
							-f -u tracked &&
					! test_trace2_data fsmonitor \
						history/external-restored 1 \
						<"$gitdir/$mode.checkout.trace" &&
					test_cmp_bin "$gitdir/$mode.stripped.index" \
						"$gitdir/index"
					;;
				attributes)
					test_write_lines "tracked text eol=crlf" \
						>"$worktree/.gitattributes" &&
					test_write_lines modified >"$worktree/tracked" &&
					GIT_OPTIONAL_LOCKS=0 \
						git -C "$worktree" \
							-c core.fsmonitor=false \
							-c core.untrackedCache=false \
							-c core.trustctime=true \
							-c core.checkStat=default \
							status --porcelain=v2 \
							>"$gitdir/$mode.dirty" &&
					test_line_count = 2 "$gitdir/$mode.dirty" &&
					test_grep "^1 \\.M .* tracked$" \
						"$gitdir/$mode.dirty" &&
					test_grep "^? \\.gitattributes$" \
						"$gitdir/$mode.dirty" &&
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCCCCCCC \
					GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
					GIT_TRACE2_EVENT="$gitdir/$mode.checkout.trace" \
						git -C "$worktree" checkout-index \
							-f -u tracked &&
					test_trace2_data fsmonitor \
						history/external-restored 1 \
						<"$gitdir/$mode.checkout.trace" &&
					test_trace2_data fsmonitor apply_count 1 \
						<"$gitdir/$mode.checkout.trace" &&
					test_trace2_data fsmonitor \
						semantic/attributes-scope 0 \
						<"$gitdir/$mode.checkout.trace" &&
					test_trace2_data fsmonitor \
						semantic/manifest-scan-count 1 \
						<"$gitdir/$mode.checkout.trace" &&
					test_trace2_data fsmonitor \
						semantic/manifest-invalidated 1 \
						<"$gitdir/$mode.checkout.trace" &&
					test_trace2_data fsmonitor \
						untracked/proof-missing 1 \
						<"$gitdir/$mode.checkout.trace" &&
					test_region index do_write_index \
						"$gitdir/$mode.checkout.trace" &&
					test_grep ! FSUC "$gitdir/index" &&
					perl - "$gitdir/index" <<-\EOF &&
					binmode STDIN;
					open my $input, "<", $ARGV[0] or
						die "cannot read index: $!\n";
					binmode $input;
					local $/;
					my $index = <$input>;
					my $offset = index($index, "FSCF");
					die "missing FSCF extension\n" if $offset < 0;
					my $flags = unpack("N", substr($index, $offset + 16, 4));
					die "unexpected FSCF flags $flags\n" if $flags != 9;
					EOF
					printf "base\r\n" >"$gitdir/$mode.converted" &&
					test_cmp_bin "$gitdir/$mode.converted" \
						"$worktree/tracked" &&
					cp "$gitdir/index" "$gitdir/$mode.before-status" &&
					GIT_OPTIONAL_LOCKS=0 \
						git -C "$worktree" \
							-c core.fsmonitor=false \
							-c core.untrackedCache=false \
							-c core.trustctime=true \
							-c core.checkStat=default \
							status --porcelain=v2 \
							>"$gitdir/$mode.expected" &&
					test_line_count = 1 "$gitdir/$mode.expected" &&
					test_grep "^? \\.gitattributes$" \
						"$gitdir/$mode.expected" &&
					test_cmp_bin "$gitdir/$mode.before-status" \
						"$gitdir/index" &&
					GIT_OPTIONAL_LOCKS=0 \
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					GIT_TRACE2_EVENT="$gitdir/$mode.status.trace" \
						git -C "$worktree" status --porcelain=v2 \
							>"$gitdir/$mode.status" &&
					test_cmp "$gitdir/$mode.expected" \
						"$gitdir/$mode.status" &&
					test_cmp_bin "$gitdir/$mode.before-status" \
						"$gitdir/index"
					;;
				esac &&
				test_cmp_bin "$gitdir/$mode.checkpoint.before" \
					"$checkpoint" || return 1
			done || return 1
		done
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'write-tree preserves authenticated primary and linked index proofs' '
	test_when_finished "rm -rf write-tree-bound-proof write-tree-linked" &&
	test_create_repo write-tree-bound-proof &&
	(
		cd write-tree-bound-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit sibling sibling &&
		git worktree add --detach ../write-tree-linked HEAD &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		cat >.git/check-write-tree-proof.pl <<-\EOF &&
		binmode STDIN;
		local $/;
		my $index = <STDIN>;
		my %tokens;
		for my $name ("FSMN", "FSUC", "FSCF") {
			my $offset = index($index, $name);
			die "missing $name extension\n" if $offset < 0;
			my $size = unpack("N", substr($index, $offset + 4, 4));
			my $payload = substr($index, $offset + 8, $size);
			if ($name eq "FSCF") {
				my $flags = unpack("N", substr($payload, 8, 4));
				die "unbound FSCF flags $flags\n" if $flags != 15;
				my $length = unpack("N", substr($payload, 12, 4));
				$tokens{$name} = substr($payload, 20, $length);
			} else {
				my $end = index($payload, "\0", 4);
				die "invalid $name token\n" if $end < 0;
				$tokens{$name} = substr($payload, 4, $end - 4);
			}
		}
		die "mismatched provider tokens\n" unless
			$tokens{"FSMN"} eq $tokens{"FSUC"} &&
			$tokens{"FSMN"} eq $tokens{"FSCF"};
		EOF
		cat >.git/check-write-tree-unbound.pl <<-\EOF &&
		binmode STDIN;
		local $/;
		my $index = <STDIN>;
		my $offset = index($index, "FSCF");
		die "missing FSCF extension\n" if $offset < 0;
		my $flags = unpack("N", substr($index, $offset + 16, 4));
		die "unexpected FSCF flags $flags\n" if $flags != 9;
		EOF
		write_script .git/hooks/pre-commit <<-\EOF &&
		test -n "$GIT_INDEX_FILE" || exit 1
		if test -n "${HOOK_GENERATE-}"
		then
			test "$GIT_INDEX_FILE" = "$HOOK_EXPECT_INDEX" || exit 1
			printf "%s\n" generated >"$HOOK_GENERATE" || exit 1
			git add -- "$HOOK_GENERATE" || exit 1
		fi
		git write-tree >"$HOOK_PROOF_OUTPUT" || exit 1
		perl "$HOOK_PROOF_HELPER" <"$GIT_INDEX_FILE"
		EOF
		for worktree in "$PWD" "$PWD/../write-tree-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			test_write_lines changed >"$worktree/tracked" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
				git -C "$worktree" add tracked &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_grep "^1 M\\. .* tracked$" "$gitdir/prime" &&
			perl "$PWD/.git/check-write-tree-proof.pl" \
				<"$gitdir/index" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/write-tree.trace" \
				git -C "$worktree" write-tree \
					>"$gitdir/tree" &&
			test_file_not_empty "$gitdir/tree" &&
			test_region index do_write_index \
				"$gitdir/write-tree.trace" &&
			! test_trace2_data fsmonitor untracked/proof-missing 1 \
				<"$gitdir/write-tree.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/write-tree.trace" &&
			perl "$PWD/.git/check-write-tree-proof.pl" \
				<"$gitdir/index" &&
			cp "$gitdir/index" "$gitdir/readonly.index" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_PRELOAD_INDEX=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/status.trace" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/status" &&
			test_cmp_bin "$gitdir/readonly.index" "$gitdir/index" &&
			test_grep "^1 M\\. .* tracked$" "$gitdir/status" &&
			test_trace2_data fsmonitor config/coherent 1 \
				<"$gitdir/status.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/status.trace" &&
			test_write_lines canonical >"$worktree/sibling" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=sibling \
				git -C "$worktree" add sibling &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/canonical-prime" &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/canonical-tree.trace" \
				git -C "$worktree" write-tree \
					>"$gitdir/canonical-tree" &&
			test_region index do_write_index \
				"$gitdir/canonical-tree.trace" &&
			! test_trace2_data fsmonitor \
				semantic/temporary-index-stat-fallback 1 \
				<"$gitdir/canonical-tree.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/canonical-tree.trace" &&
			perl "$PWD/.git/check-write-tree-proof.pl" \
				<"$gitdir/index" &&
			test_write_lines hooked >"$worktree/sibling" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=sibling \
				git -C "$worktree" add sibling &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/hook-prime" &&
			HOOK_PROOF_HELPER="$PWD/.git/check-write-tree-proof.pl" \
			HOOK_PROOF_OUTPUT="$gitdir/hook-tree" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/hook.trace" \
				git -C "$worktree" commit -qm hooked &&
			test_file_not_empty "$gitdir/hook-tree" &&
			test_grep "\"name\":\"write-tree\"" \
				"$gitdir/hook.trace" &&
			perl "$PWD/.git/check-write-tree-proof.pl" \
				<"$gitdir/index" &&
			test_write_lines commit-all >"$worktree/sibling" &&
			HOOK_GENERATE=hook-generated \
			HOOK_EXPECT_INDEX="$gitdir/index.lock" \
			HOOK_PROOF_HELPER="$PWD/.git/check-write-tree-proof.pl" \
			HOOK_PROOF_OUTPUT="$gitdir/hook-all-tree" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=sibling \
			GIT_TRACE2_EVENT="$gitdir/hook-all.trace" \
				git -C "$worktree" commit -aqm commit-all &&
			test_file_not_empty "$gitdir/hook-all-tree" &&
			git -C "$worktree" ls-tree HEAD hook-generated \
				>"$gitdir/hook-all-entry" &&
			test_grep "hook-generated$" "$gitdir/hook-all-entry" &&
			! test_trace2_data fsmonitor \
				semantic/temporary-index-stat-fallback 1 \
				<"$gitdir/hook-all.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/hook-all.trace" &&
			perl "$PWD/.git/check-write-tree-proof.pl" \
				<"$gitdir/index" &&
			cp "$gitdir/index" "$gitdir/hook-all-before-status" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/hook-all-status.trace" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/hook-all-status" &&
			test_must_be_empty "$gitdir/hook-all-status" &&
			test_cmp_bin "$gitdir/hook-all-before-status" \
				"$gitdir/index" &&
			test_trace2_data fsmonitor config/coherent 1 \
				<"$gitdir/hook-all-status.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/hook-all-status.trace" &&
			cp "$gitdir/index" "$gitdir/readonly.index" &&
			cp "$gitdir/index" "$gitdir/snapshot.index" &&
			test_write_lines snapshot >"$worktree/snapshot-new" &&
			printf "%s\0" snapshot-new |
			GIT_OPTIONAL_LOCKS=0 \
			GIT_INDEX_FILE="$gitdir/snapshot.index" \
			GIT_LITERAL_PATHSPECS=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/snapshot-prime.trace" \
				git -C "$worktree" add --sparse \
					--pathspec-from-file=- \
					--pathspec-file-nul &&
			perl "$PWD/.git/check-write-tree-unbound.pl" \
				<"$gitdir/snapshot.index" &&
			test_cmp_bin "$gitdir/readonly.index" "$gitdir/index" &&
			if test_have_prereq HARDLINKS &&
			   test_have_prereq SYMLINKS
			then
				cp "$gitdir/snapshot.index" "$gitdir/index" &&
				ln "$gitdir/index" "$gitdir/physical-hardlink" &&
				ln -s "$gitdir/index" "$gitdir/physical-symlink" &&
				cp "$gitdir/index" "$gitdir/index.lock" &&
				for alias in index physical-hardlink \
					physical-symlink index.lock
				do
					GIT_OPTIONAL_LOCKS=0 \
					GIT_INDEX_FILE="$gitdir/$alias" \
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
					GIT_TRACE2_EVENT="$gitdir/alias-$alias.trace" \
						git -C "$worktree" status \
							--porcelain=v2 \
							>"$gitdir/alias-$alias" &&
					! test_trace2_data fsmonitor \
						semantic/temporary-index-stat-fallback 1 \
						<"$gitdir/alias-$alias.trace" &&
					test_cmp_bin "$gitdir/snapshot.index" \
						"$gitdir/index" || return 1
				done &&
				rm -f "$gitdir/physical-hardlink" \
					"$gitdir/physical-symlink" \
					"$gitdir/index.lock" &&
				cp "$gitdir/readonly.index" "$gitdir/index"
			fi &&
			test_write_lines next >"$worktree/snapshot-next" &&
			printf "%s\0" snapshot-next |
			GIT_OPTIONAL_LOCKS=0 \
			GIT_INDEX_FILE="$gitdir/snapshot.index" \
			GIT_LITERAL_PATHSPECS=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/snapshot-add.trace" \
				git -C "$worktree" add --sparse \
					--pathspec-from-file=- \
					--pathspec-file-nul &&
			test_trace2_data fsmonitor \
				semantic/temporary-index-stat-fallback 1 \
				<"$gitdir/snapshot-add.trace" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/snapshot-add.trace" &&
			test_cmp_bin "$gitdir/readonly.index" "$gitdir/index" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_INDEX_FILE="$gitdir/snapshot.index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/snapshot-tree.trace" \
				git -C "$worktree" write-tree \
					>"$gitdir/snapshot-tree" &&
			test_file_not_empty "$gitdir/snapshot-tree" &&
			test_trace2_data fsmonitor \
				semantic/temporary-index-stat-fallback 1 \
				<"$gitdir/snapshot-tree.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/snapshot-tree.trace" &&
			git -C "$worktree" ls-tree \
				"$(cat "$gitdir/snapshot-tree")" \
					snapshot-new snapshot-next \
				>"$gitdir/snapshot-entry" &&
			test_grep "snapshot-new$" "$gitdir/snapshot-entry" &&
			test_grep "snapshot-next$" "$gitdir/snapshot-entry" &&
			cp "$gitdir/readonly.index" "$gitdir/control.index" &&
			printf "%s\0" snapshot-new snapshot-next |
			GIT_OPTIONAL_LOCKS=0 \
			GIT_INDEX_FILE="$gitdir/control.index" \
			GIT_LITERAL_PATHSPECS=1 \
				git -c core.fsmonitor=false \
					-c core.untrackedCache=false \
					-C "$worktree" add --sparse \
						--pathspec-from-file=- \
						--pathspec-file-nul &&
			GIT_INDEX_FILE="$gitdir/control.index" \
				git -c core.fsmonitor=false \
					-c core.untrackedCache=false \
					-C "$worktree" write-tree \
					>"$gitdir/snapshot-expect" &&
			test_cmp "$gitdir/snapshot-expect" "$gitdir/snapshot-tree" &&
			test_cmp_bin "$gitdir/readonly.index" "$gitdir/index" &&
			test_write_lines "*.filtered filter=snapshot" \
				>"$worktree/.gitattributes" &&
			test_write_lines raw >"$worktree/snapshot.filtered" &&
			printf "%s\0" .gitattributes snapshot.filtered |
			GIT_OPTIONAL_LOCKS=0 \
			GIT_INDEX_FILE="$gitdir/snapshot.index" \
			GIT_LITERAL_PATHSPECS=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/filter-add.trace" \
				git -c filter.snapshot.clean="sed s/raw/converted/" \
					-c filter.snapshot.required=true \
					-C "$worktree" add --sparse \
						--pathspec-from-file=- \
						--pathspec-file-nul &&
			test_trace2_data fsmonitor \
				semantic/temporary-index-stat-fallback 1 \
				<"$gitdir/filter-add.trace" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/filter-add.trace" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_INDEX_FILE="$gitdir/snapshot.index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/filter-tree.trace" \
				git -c filter.snapshot.clean="sed s/raw/converted/" \
					-c filter.snapshot.required=true \
					-C "$worktree" write-tree \
						>"$gitdir/filter-tree" &&
			test_trace2_data fsmonitor \
				semantic/temporary-index-stat-fallback 1 \
				<"$gitdir/filter-tree.trace" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/filter-tree.trace" &&
			cp "$gitdir/readonly.index" "$gitdir/filter-control.index" &&
			printf "%s\0" snapshot-new snapshot-next \
				.gitattributes snapshot.filtered |
			GIT_OPTIONAL_LOCKS=0 \
			GIT_INDEX_FILE="$gitdir/filter-control.index" \
			GIT_LITERAL_PATHSPECS=1 \
				git -c core.fsmonitor=false \
					-c core.untrackedCache=false \
					-c filter.snapshot.clean="sed s/raw/converted/" \
					-c filter.snapshot.required=true \
					-C "$worktree" add --sparse \
						--pathspec-from-file=- \
						--pathspec-file-nul &&
			GIT_INDEX_FILE="$gitdir/filter-control.index" \
				git -c core.fsmonitor=false \
					-c core.untrackedCache=false \
					-c filter.snapshot.clean="sed s/raw/converted/" \
					-c filter.snapshot.required=true \
					-C "$worktree" write-tree \
						>"$gitdir/filter-expect" &&
			test_cmp "$gitdir/filter-expect" "$gitdir/filter-tree" &&
			git -C "$worktree" cat-file blob \
				"$(cat "$gitdir/filter-tree"):snapshot.filtered" \
					>"$gitdir/filter-actual-blob" &&
			test_write_lines converted >"$gitdir/filter-expect-blob" &&
			test_cmp "$gitdir/filter-expect-blob" \
				"$gitdir/filter-actual-blob" &&
			test_cmp_bin "$gitdir/readonly.index" "$gitdir/index" &&
			test_write_lines raw >"$worktree/required-failure.filtered" &&
			printf "%s\0" required-failure.filtered \
				>"$gitdir/required-failure.paths" &&
			cp "$gitdir/snapshot.index" "$gitdir/filter-failure.index" &&
			cp "$gitdir/filter-failure.index" \
				"$gitdir/filter-failure.before" &&
			test_must_fail env \
				GIT_OPTIONAL_LOCKS=0 \
				GIT_INDEX_FILE="$gitdir/filter-failure.index" \
				GIT_LITERAL_PATHSPECS=1 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/filter-failure.trace" \
				git -c filter.snapshot.clean=false \
					-c filter.snapshot.required=true \
					-C "$worktree" add --sparse \
						--pathspec-from-file="$gitdir/required-failure.paths" \
						--pathspec-file-nul \
						2>"$gitdir/filter-failure.error" &&
			test_grep "clean filter .snapshot. failed" \
				"$gitdir/filter-failure.error" &&
			test_trace2_data fsmonitor \
				semantic/temporary-index-stat-fallback 1 \
				<"$gitdir/filter-failure.trace" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/filter-failure.trace" &&
			test_cmp_bin "$gitdir/filter-failure.before" \
				"$gitdir/filter-failure.index" &&
			cp "$gitdir/readonly.index" \
				"$gitdir/filter-control-failure.index" &&
			test_must_fail env \
				GIT_OPTIONAL_LOCKS=0 \
				GIT_INDEX_FILE="$gitdir/filter-control-failure.index" \
				GIT_LITERAL_PATHSPECS=1 \
				git -c core.fsmonitor=false \
					-c core.untrackedCache=false \
					-c filter.snapshot.clean=false \
					-c filter.snapshot.required=true \
					-C "$worktree" add --sparse \
						--pathspec-from-file="$gitdir/required-failure.paths" \
						--pathspec-file-nul \
						2>"$gitdir/filter-control-failure.error" &&
			test_grep "clean filter .snapshot. failed" \
				"$gitdir/filter-control-failure.error" &&
			test_cmp_bin "$gitdir/readonly.index" \
				"$gitdir/filter-control-failure.index" &&
			test_cmp_bin "$gitdir/readonly.index" "$gitdir/index" &&
			rm -f "$worktree/.gitattributes" \
				"$worktree/snapshot.filtered" \
				"$worktree/required-failure.filtered" &&
			GIT_INDEX_FILE="$gitdir/manifestless.index" \
				git -C "$worktree" read-tree HEAD &&
			test_grep ! FSCF "$gitdir/manifestless.index" &&
			test_write_lines manifestless \
				>"$worktree/manifestless-new" &&
			printf "%s\n" manifestless-new |
			GIT_INDEX_FILE="$gitdir/manifestless.index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/manifestless-add.trace" \
				git -C "$worktree" add --sparse \
					--pathspec-from-file=- &&
			test_trace2_data fsmonitor \
				semantic/temporary-index-stat-fallback 1 \
				<"$gitdir/manifestless-add.trace" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/manifestless-add.trace" &&
			GIT_INDEX_FILE="$gitdir/manifestless.index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/manifestless-tree.trace" \
				git -C "$worktree" write-tree \
					>"$gitdir/manifestless-tree" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/manifestless-tree.trace" &&
			git -C "$worktree" ls-tree \
				"$(cat "$gitdir/manifestless-tree")" \
				manifestless-new >"$gitdir/manifestless-entry" &&
			test_grep "manifestless-new$" \
				"$gitdir/manifestless-entry" &&
			test_cmp_bin "$gitdir/readonly.index" "$gitdir/index" &&
			test_write_lines "*.asset text" \
				>"$worktree/.gitattributes" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" add .gitattributes &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/attributes.trace" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/attributes" &&
			test_trace2_data fsmonitor config/coherent 0 \
				<"$gitdir/attributes.trace" &&
			test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/attributes.trace" &&
			test_grep "^1 A\\. .* \\.gitattributes$" \
				"$gitdir/attributes" || return 1
		done
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'fast-forward merges preserve authenticated worktree proofs' '
	test_when_finished "rm -rf fast-forward-bound-proof fast-forward-linked fast-forward-target" &&
	test_create_repo fast-forward-bound-proof &&
	(
		cd fast-forward-bound-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git worktree add --detach ../fast-forward-target HEAD &&
		test_write_lines incoming >../fast-forward-target/tracked &&
		git -C ../fast-forward-target add tracked &&
		git -C ../fast-forward-target commit -qm incoming &&
		target=$(git -C ../fast-forward-target rev-parse HEAD) &&
		git worktree add --detach ../fast-forward-linked HEAD &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		cat >.git/check-merge-proof.pl <<-\EOF &&
		binmode STDIN;
		local $/;
		my $index = <STDIN>;
		my %tokens;
		for my $name ("FSMN", "FSUC", "FSCF") {
			my $offset = index($index, $name);
			die "missing $name extension\n" if $offset < 0;
			my $size = unpack("N", substr($index, $offset + 4, 4));
			my $payload = substr($index, $offset + 8, $size);
			if ($name eq "FSCF") {
				my $flags = unpack("N", substr($payload, 8, 4));
				die "unbound FSCF flags $flags\n" if $flags != 15;
				my $length = unpack("N", substr($payload, 12, 4));
				$tokens{$name} = substr($payload, 20, $length);
			} else {
				my $end = index($payload, "\0", 4);
				die "invalid $name token\n" if $end < 0;
				$tokens{$name} = substr($payload, 4, $end - 4);
			}
		}
		die "mismatched provider tokens\n" unless
			$tokens{"FSMN"} eq $tokens{"FSUC"} &&
			$tokens{"FSMN"} eq $tokens{"FSCF"};
		EOF
		for worktree in "$PWD" "$PWD/../fast-forward-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			perl "$PWD/.git/check-merge-proof.pl" \
				<"$gitdir/index" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/merge.trace" \
				git -C "$worktree" merge --ff-only "$target" \
					>"$gitdir/merge" &&
			test_region index do_write_index "$gitdir/merge.trace" &&
			! test_trace2_data fsmonitor untracked/proof-missing 1 \
				<"$gitdir/merge.trace" &&
			perl "$PWD/.git/check-merge-proof.pl" \
				<"$gitdir/index" &&
			cp "$gitdir/index" "$gitdir/readonly.index" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/status.trace" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/status" &&
			test_must_be_empty "$gitdir/status" &&
			test_cmp_bin "$gitdir/readonly.index" "$gitdir/index" &&
			test_trace2_data fsmonitor config/coherent 1 \
				<"$gitdir/status.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/status.trace" &&
			test_write_lines "*.asset text" \
				>"$worktree/.gitattributes" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" add .gitattributes &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/attributes.trace" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/attributes" &&
			test_trace2_data fsmonitor config/coherent 0 \
				<"$gitdir/attributes.trace" &&
			test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/attributes.trace" &&
			test_grep "^1 A\\. .* \\.gitattributes$" \
				"$gitdir/attributes" || return 1
		done
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'clean non-fast-forward merges preserve authenticated worktree proofs' '
	test_when_finished "rm -rf clean-no-ff-proof-*" &&
	for mode in cli no-commit config
	do
		repo=clean-no-ff-proof-$mode &&
		test_create_repo "$repo" &&
		(
			cd "$repo" &&
			sane_unset GIT_TEST_SPLIT_INDEX &&
			test_commit base base &&
			primary=$(git symbolic-ref --short HEAD) &&
			git switch -c side &&
			test_commit topic topic &&
			git switch "$primary" &&
			test_commit primary primary &&
			git config core.untrackedCache true &&
			git config core.fsmonitor true &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git update-index --fsmonitor &&
			GIT_INDEX_FILE="$PWD/.git/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git status --porcelain=v2 >.git/prime &&
			test_must_be_empty .git/prime &&
			test_fsmonitor_full_proof .git/index paired &&
			case "$mode" in
			cli)
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
					git merge --no-ff --no-edit side
				;;
			no-commit)
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
					git merge --no-ff --no-commit side
				;;
			config)
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
					git -c merge.ff=false merge --no-edit side
				;;
			esac &&
			test_fsmonitor_full_proof .git/index paired &&
			cp .git/index .git/readonly.index &&
			for run in 1 2 3
			do
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$PWD/.git/status-$run.trace" \
					git status --porcelain=v2 \
						>.git/status-$run &&
				test_cmp_bin .git/readonly.index .git/index &&
				! test_trace2_data fsmonitor \
					history/external-proof-invalidated 1 \
					<.git/status-$run.trace &&
				! have_t2_data_event fsmonitor \
					semantic/manifest-scan-count \
					<.git/status-$run.trace &&
				if test "$mode" = no-commit
				then
					test_grep "^1 A\\. .* topic$" \
						.git/status-$run
				else
					test_must_be_empty .git/status-$run
				fi || return 1
			done
		) || return 1
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'non-fast-forward conflicts and alternate indexes fail closed' '
	test_when_finished "rm -rf no-ff-alt-proof no-ff-conflict-proof" &&
	test_create_repo no-ff-alt-proof &&
	(
		cd no-ff-alt-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base base &&
		primary=$(git symbolic-ref --short HEAD) &&
		git switch -c side &&
		test_commit topic topic &&
		git switch "$primary" &&
		test_commit primary primary &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_fsmonitor_full_proof .git/index paired &&
		cp .git/index .git/alternate.index &&
		GIT_INDEX_FILE="$PWD/.git/alternate.index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			git merge --no-ff --no-commit side &&
		! test_fsmonitor_full_proof .git/alternate.index paired \
			2>.git/alternate.proof &&
		test_grep ! FSUC .git/alternate.index
	) &&
	test_create_repo no-ff-conflict-proof &&
	(
		cd no-ff-conflict-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines base >tracked &&
		git add tracked &&
		git commit -m base &&
		primary=$(git symbolic-ref --short HEAD) &&
		git switch -c side &&
		test_write_lines side >tracked &&
		git commit -am side &&
		git switch "$primary" &&
		test_write_lines primary >tracked &&
		git commit -am primary &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_fsmonitor_full_proof .git/index paired &&
		test_must_fail env \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			git merge --no-ff side &&
		! test_fsmonitor_full_proof .git/index paired \
			2>.git/conflict.proof &&
		test_grep ! FSUC .git/index &&
		git ls-files -u >.git/unmerged &&
		test_file_not_empty .git/unmerged
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'full status durably repairs missing mixed-writer index proofs' '
	test_when_finished "rm -rf mixed-writer-missing-proofs" &&
	test_create_repo mixed-writer-missing-proofs &&
	(
		cd mixed-writer-missing-proofs &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSMN .git/index &&
		test_grep FSUC .git/index &&
		test_grep FSCF .git/index &&
		cat >.git/remove-mixed-writer-proofs.pl <<-\EOF &&
		use Digest::SHA qw(sha1 sha256);
		binmode STDIN;
		binmode STDOUT;
		local $/;
		my $index = <STDIN>;
		my $algorithm = $ARGV[0];
		my $rawsz = $algorithm eq "sha256" ? 32 : 20;
		for my $name ("FSUC", "FSCF") {
			my $offset = index($index, $name);
			die "missing $name extension\n" if $offset < 0;
			my $size = unpack("N", substr($index, $offset + 4, 4));
			substr($index, $offset, 8 + $size, "");
		}
		my $payload = substr($index, 0, -$rawsz);
		print $payload,
			$algorithm eq "sha256" ? sha256($payload) : sha1($payload);
		EOF
		perl .git/remove-mixed-writer-proofs.pl "$(test_oid algo)" \
			<.git/index >.git/index.mixed &&
		mv .git/index.mixed .git/index &&
		test_grep FSMN .git/index &&
		test_grep UNTR .git/index &&
		test_grep ! FSUC .git/index &&
		test_grep ! FSCF .git/index &&
		cp .git/index .git/cold.before &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/cold.trace" \
			git status --porcelain=v2 >.git/cold &&
		test_must_be_empty .git/cold &&
		test_cmp_bin .git/cold.before .git/index &&
		! test_region index do_write_index .git/cold.trace &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/repair.trace" \
			git status >.git/repair &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/repair.trace &&
		test_region index do_write_index .git/repair.trace &&
		test_grep FSMN .git/index &&
		test_grep FSUC .git/index &&
		test_grep FSCF .git/index &&
		cat >.git/check-mixed-writer-proof.pl <<-\EOF &&
		binmode STDIN;
		local $/;
		my $index = <STDIN>;
		my %tokens;
		for my $name ("FSMN", "FSUC", "FSCF") {
			my $offset = index($index, $name);
			my $size = unpack("N", substr($index, $offset + 4, 4));
			my $payload = substr($index, $offset + 8, $size);
			if ($name eq "FSCF") {
				my $flags = unpack("N", substr($payload, 8, 4));
				die "unbound FSCF flags $flags\n" if $flags != 15;
				my $length = unpack("N", substr($payload, 12, 4));
				$tokens{$name} = substr($payload, 20, $length);
			} else {
				my $end = index($payload, "\0", 4);
				$tokens{$name} = substr($payload, 4, $end - 4);
			}
		}
		die "mismatched provider tokens\n" unless
			$tokens{"FSMN"} eq $tokens{"FSUC"} &&
			$tokens{"FSMN"} eq $tokens{"FSCF"};
		EOF
		perl .git/check-mixed-writer-proof.pl <.git/index &&
		for run in first second
		do
			cp .git/index ".git/readonly-$run.index" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/readonly-$run.trace" \
				git status --porcelain=v2 >".git/readonly-$run" &&
			test_must_be_empty ".git/readonly-$run" &&
			test_cmp_bin ".git/readonly-$run.index" .git/index &&
			test_trace2_data fsmonitor config/coherent 1 \
				<".git/readonly-$run.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<".git/readonly-$run.trace" &&
			! test_region index do_write_index \
				".git/readonly-$run.trace" || return 1
		done
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'ordinary removals and renames preserve safe worktree proofs' '
	test_when_finished "rm -rf rm-mv-bound-proof rm-mv-linked" &&
	test_create_repo rm-mv-bound-proof &&
	(
		cd rm-mv-bound-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines remove >remove-me &&
		test_write_lines move >move-me &&
		test_write_lines sibling >sibling &&
		test_write_lines "*.asset text" >.gitattributes &&
		test_write_lines "*.ignored" >.gitignore &&
		git add remove-me move-me sibling .gitattributes .gitignore &&
		git commit -qm base &&
		test_write_lines successor >sibling &&
		git add sibling &&
		git commit -qm successor &&
		git worktree add --detach ../rm-mv-linked HEAD &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		cat >.git/check-rm-mv-proof.pl <<-\EOF &&
		binmode STDIN;
		local $/;
		my $index = <STDIN>;
		my %tokens;
		for my $name ("FSMN", "FSUC", "FSCF") {
			my $offset = index($index, $name);
			die "missing $name extension\n" if $offset < 0;
			my $size = unpack("N", substr($index, $offset + 4, 4));
			my $payload = substr($index, $offset + 8, $size);
			if ($name eq "FSCF") {
				my $flags = unpack("N", substr($payload, 8, 4));
				die "unbound FSCF flags $flags\n" if $flags != 15;
				my $length = unpack("N", substr($payload, 12, 4));
				$tokens{$name} = substr($payload, 20, $length);
			} else {
				my $end = index($payload, "\0", 4);
				$tokens{$name} = substr($payload, 4, $end - 4);
			}
		}
		die "mismatched provider tokens\n" unless
			$tokens{"FSMN"} eq $tokens{"FSUC"} &&
			$tokens{"FSMN"} eq $tokens{"FSCF"};
		EOF
		for worktree in "$PWD" "$PWD/../rm-mv-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			for operation in remove rename mixed-reset
			do
				case "$operation" in
				remove) set -- rm --quiet remove-me ;;
				rename) set -- mv move-me renamed ;;
				mixed-reset) set -- reset --mixed HEAD~1 ;;
				esac &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/$operation.trace" \
					git -C "$worktree" "$@" &&
				perl "$PWD/.git/check-rm-mv-proof.pl" \
					<"$gitdir/index" &&
				! test_trace2_data fsmonitor untracked/proof-missing 1 \
					<"$gitdir/$operation.trace" &&
				cp "$gitdir/index" "$gitdir/$operation.index" &&
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/$operation-status.trace" \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/$operation-status" &&
				test_cmp_bin "$gitdir/$operation.index" \
					"$gitdir/index" &&
				test_trace2_data fsmonitor config/coherent 1 \
					<"$gitdir/$operation-status.trace" &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<"$gitdir/$operation-status.trace" || return 1
			done &&
			test_write_lines exposed >"$worktree/hidden.ignored" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" rm --quiet .gitignore &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/ignore-removed" &&
			test_grep "^? hidden\\.ignored$" \
				"$gitdir/ignore-removed" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" mv .gitattributes \
					moved.attributes &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/attributes.trace" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/attributes" &&
			test_trace2_data fsmonitor config/coherent 0 \
				<"$gitdir/attributes.trace" &&
			test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/attributes.trace" || return 1
		done &&
		test_write_lines "*.filtered filter=demo" >.gitattributes &&
		git config filter.demo.clean cat &&
		git config filter.demo.required true &&
		test_write_lines raw >active.filtered &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git add .gitattributes active.filtered &&
		git config filter.demo.clean false &&
		test_must_fail env GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 --untracked-files=no \
				>.git/filtered 2>.git/filter-error &&
		test_grep "clean filter .demo. failed" .git/filter-error
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'configured pulls preserve authenticated worktree proofs' '
	test_when_finished "rm -rf pull-proof-origin.git pull-proof-seed pull-proof-ff pull-proof-ff-linked pull-proof-rebase pull-proof-rebase-linked pull-proof-autostash pull-proof-autostash-linked pull-proof-delete pull-proof-delete-linked pull-proof-filter" &&
	git init --bare pull-proof-origin.git &&
	test_create_repo pull-proof-seed &&
	(
		cd pull-proof-seed &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git branch -M main &&
		git remote add origin "$PWD/../pull-proof-origin.git" &&
		git push --quiet -u origin main &&
		git --git-dir="$PWD/../pull-proof-origin.git" \
			symbolic-ref HEAD refs/heads/main &&
		cat >.git/check-pull-proof.pl <<-\EOF &&
		binmode STDIN;
		local $/;
		my $index = <STDIN>;
		my %tokens;
		for my $name ("FSMN", "FSUC", "FSCF") {
			my $offset = index($index, $name);
			die "missing $name extension\n" if $offset < 0;
			my $size = unpack("N", substr($index, $offset + 4, 4));
			my $payload = substr($index, $offset + 8, $size);
			if ($name eq "FSCF") {
				my $flags = unpack("N", substr($payload, 8, 4));
				die "unbound FSCF flags $flags\n" if $flags != 15;
				my $length = unpack("N", substr($payload, 12, 4));
				$tokens{$name} = substr($payload, 20, $length);
			} else {
				my $end = index($payload, "\0", 4);
				$tokens{$name} = substr($payload, 4, $end - 4);
			}
		}
		die "mismatched provider tokens\n" unless
			$tokens{"FSMN"} eq $tokens{"FSUC"} &&
			$tokens{"FSMN"} eq $tokens{"FSCF"};
		EOF
		for mode in ff rebase autostash
		do
			git clone --quiet "$PWD/../pull-proof-origin.git" \
				"$PWD/../pull-proof-$mode" &&
			repo="$PWD/../pull-proof-$mode" &&
			linked="$PWD/../pull-proof-$mode-linked" &&
			git -C "$repo" worktree add --quiet \
				-b "linked-$mode" "$linked" origin/main &&
			git -C "$linked" branch --quiet \
				--set-upstream-to=origin/main &&
			if test "$mode" = ff
			then
				git -C "$repo" config pull.ff only
			else
				git -C "$repo" config pull.rebase true
			fi &&
			git -C "$repo" config core.untrackedCache true &&
			git -C "$repo" config core.fsmonitor true &&
			for role in main linked
			do
				case "$role" in
				main)
					worktree="$repo" &&
					invalidated=98
					;;
				linked)
					worktree="$linked" &&
					invalidated=196
					;;
				esac &&
				if test "$mode" != ff
				then
					test_write_lines "$mode-$role" \
						>"$worktree/local-$role" &&
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
						git -C "$worktree" add "local-$role" &&
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
						git -C "$worktree" commit \
							-qm "local-$mode-$role" || return 1
				fi &&
				gitdir=$(git -C "$worktree" \
					rev-parse --absolute-git-dir) &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
					git -C "$worktree" update-index --fsmonitor &&
				GIT_INDEX_FILE="$gitdir/index" \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/prime" &&
				test_must_be_empty "$gitdir/prime" &&
				perl "$PWD/.git/check-pull-proof.pl" \
					<"$gitdir/index" &&
				if test "$mode" = ff
				then
					mkdir -p "upstream-$mode-$role/nested" &&
					for file in $(test_seq 1 96)
					do
						test_write_lines "$mode-$role-$file" \
							>"upstream-$mode-$role/nested/$file" ||
								return 1
					done &&
					test_write_lines "# $mode-$role" \
						>"upstream-$mode-$role/nested/.gitattributes" &&
					test_write_lines "*.ignored" "# $mode-$role" \
						>"upstream-$mode-$role/nested/.gitignore" &&
					git add "upstream-$mode-$role"
				else
					test_write_lines "$mode-$role" \
						>"upstream-$mode-$role" &&
					git add "upstream-$mode-$role"
				fi &&
				git commit -qm "upstream-$mode-$role" &&
				git push --quiet origin main &&
				if test "$mode" = autostash
				then
					test_write_lines dirty >"$worktree/tracked" &&
					set -- pull --quiet --rebase --autostash
				else
					set -- pull --quiet
				fi &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
				GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
				GIT_TRACE2_EVENT="$gitdir/pull.trace" \
					git -C "$worktree" \
						-c protocol.version=2 \
						-c fetch.uriprotocols=https \
						-c http.https://example.invalid.extraHeader=header \
						-c http.https://example.invalid.proactiveAuth=basic \
						-c http.https://example.invalid.sslVerify=true \
						"$@" \
						>"$gitdir/pull" &&
				if test "$mode" != ff
				then
					test_grep "\"name\":\"rebase\"" \
						"$gitdir/pull.trace" &&
					test_path_is_file "$worktree/local-$role" ||
						return 1
				fi &&
				! test_trace2_data fsmonitor config/coherent 0 \
					<"$gitdir/pull.trace" &&
				! test_trace2_data fsmonitor untracked/proof-missing 1 \
					<"$gitdir/pull.trace" &&
				if test "$mode" = ff
				then
					test_trace2_data fsmonitor \
						semantic/manifest-scan-count 1 \
						<"$gitdir/pull.trace" &&
					test_trace2_data fsmonitor \
						history/checkout-manifest-refreshed 1 \
						<"$gitdir/pull.trace" &&
					test_trace2_data fsmonitor \
						history/untracked-paired-new-directory-invalidated \
						"$invalidated" <"$gitdir/pull.trace"
				else
					! test_trace2_data fsmonitor \
						semantic/manifest-scan-count 1 \
						<"$gitdir/pull.trace"
				fi &&
				perl "$PWD/.git/check-pull-proof.pl" \
					<"$gitdir/index" &&
				for pass in first second
				do
					cp "$gitdir/index" \
						"$gitdir/readonly-$pass.index" &&
					GIT_OPTIONAL_LOCKS=0 \
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
					GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
					GIT_TRACE2_EVENT="$gitdir/status-$pass.trace" \
						git -C "$worktree" status --porcelain=v2 \
							>"$gitdir/status-$pass" &&
					if test "$mode" = autostash
					then
						test_grep "^1 \\.M .* tracked$" \
							"$gitdir/status-$pass" || return 1
					else
						test_must_be_empty \
							"$gitdir/status-$pass" || return 1
					fi &&
					test_cmp_bin "$gitdir/readonly-$pass.index" \
						"$gitdir/index" &&
					test_trace2_data fsmonitor config/coherent 1 \
						<"$gitdir/status-$pass.trace" &&
					! test_trace2_data fsmonitor \
						semantic/manifest-scan-count 1 \
						<"$gitdir/status-$pass.trace" &&
					! test_region index do_write_index \
						"$gitdir/status-$pass.trace" || return 1
				done || return 1
			done || return 1
		done &&
		git clone --quiet "$PWD/../pull-proof-origin.git" \
			"$PWD/../pull-proof-delete" &&
		delete_repo="$PWD/../pull-proof-delete" &&
		delete_linked="$PWD/../pull-proof-delete-linked" &&
		git -C "$delete_repo" worktree add --quiet -b linked-delete \
			"$delete_linked" origin/main &&
		git -C "$delete_linked" branch --quiet \
			--set-upstream-to=origin/main &&
		git -C "$delete_repo" config pull.ff only &&
		git -C "$delete_repo" config core.untrackedCache true &&
		git -C "$delete_repo" config core.fsmonitor true &&
		for worktree in "$delete_repo" "$delete_linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			perl "$PWD/.git/check-pull-proof.pl" \
				<"$gitdir/index" || return 1
		done &&
		test_write_lines "# root attributes" >.gitattributes &&
		test_write_lines "# root ignore" >.gitignore &&
		git rm --quiet \
			upstream-ff-main/nested/.gitattributes \
			upstream-ff-main/nested/.gitignore &&
		git add .gitattributes .gitignore &&
		git commit -qm "change policy sources" &&
		git push --quiet origin main &&
		for worktree in "$delete_repo" "$delete_linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			GIT_TRACE2_EVENT="$gitdir/pull.trace" \
				git -C "$worktree" pull --quiet &&
			! test_trace2_data fsmonitor untracked/proof-missing 1 \
				<"$gitdir/pull.trace" &&
			perl "$PWD/.git/check-pull-proof.pl" \
				<"$gitdir/index" &&
			for pass in first second
			do
				cp "$gitdir/index" \
					"$gitdir/delete-$pass.index" &&
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/delete-$pass.trace" \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/delete-$pass" &&
				test_must_be_empty "$gitdir/delete-$pass" &&
				test_cmp_bin "$gitdir/delete-$pass.index" \
					"$gitdir/index" &&
				test_trace2_data fsmonitor config/coherent 1 \
					<"$gitdir/delete-$pass.trace" &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<"$gitdir/delete-$pass.trace" &&
				! test_region index do_write_index \
					"$gitdir/delete-$pass.trace" || return 1
			done || return 1
		done &&
		git clone --quiet "$PWD/../pull-proof-origin.git" \
			"$PWD/../pull-proof-filter" &&
		filter="$PWD/../pull-proof-filter" &&
		git -C "$filter" config pull.ff only &&
		git -C "$filter" config core.untrackedCache true &&
		git -C "$filter" config core.fsmonitor true &&
		git -C "$filter" config filter.pullproof.clean false &&
		git -C "$filter" config filter.pullproof.required true &&
		filter_gitdir=$(git -C "$filter" rev-parse --absolute-git-dir) &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git -C "$filter" update-index --fsmonitor &&
		GIT_INDEX_FILE="$filter_gitdir/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git -C "$filter" status --porcelain=v2 \
				>"$filter_gitdir/prime" &&
		test_must_be_empty "$filter_gitdir/prime" &&
		test_write_lines "tracked filter=pullproof" >.gitattributes &&
		git add .gitattributes &&
		git commit -qm "upstream-filter" &&
		git push --quiet origin main &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$filter_gitdir/pull.trace" \
			git -C "$filter" pull --quiet &&
		test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<"$filter_gitdir/pull.trace" &&
		test_trace2_data fsmonitor history/checkout-manifest-refreshed 1 \
			<"$filter_gitdir/pull.trace" &&
		test_trace2_data fsmonitor semantic/manifest-invalidated 1 \
			<"$filter_gitdir/pull.trace" &&
		test_trace2_data fsmonitor history/untracked-paired-transfer 1 \
			<"$filter_gitdir/pull.trace" &&
		cp "$filter_gitdir/index" "$filter_gitdir/status.before" &&
		test_must_fail env GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$filter_gitdir/status.trace" \
			git -C "$filter" status --porcelain=v2 \
				--untracked-files=no -- tracked \
				>"$filter_gitdir/status" \
				2>"$filter_gitdir/status.err" &&
		test_grep "clean filter .pullproof. failed" \
			"$filter_gitdir/status.err" &&
		test_cmp_bin "$filter_gitdir/status.before" \
			"$filter_gitdir/index"
	)
'

test_expect_success FSMONITOR_DAEMON,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'provider restarts preserve authenticated pull proofs' '
	test_when_finished "rm -rf daemon-pull-origin.git daemon-pull-seed daemon-pull-fast daemon-pull daemon-pull-linked daemon-pull-root daemon-pull-root-linked daemon-pull-filter" &&
	test_when_finished \
		"git -C daemon-pull-fast fsmonitor--daemon stop 2>/dev/null || :" &&
	test_when_finished \
		"git -C daemon-pull fsmonitor--daemon stop 2>/dev/null || :" &&
	test_when_finished \
		"git -C daemon-pull-linked fsmonitor--daemon stop 2>/dev/null || :" &&
	test_when_finished \
		"git -C daemon-pull-root fsmonitor--daemon stop 2>/dev/null || :" &&
	test_when_finished \
		"git -C daemon-pull-root-linked fsmonitor--daemon stop 2>/dev/null || :" &&
	test_when_finished \
		"git -C daemon-pull-filter fsmonitor--daemon stop 2>/dev/null || :" &&
	git init --bare daemon-pull-origin.git &&
	test_create_repo daemon-pull-seed &&
	(
		cd daemon-pull-seed &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir stable &&
		mkdir -p policy-main/nested policy-linked/nested &&
		for file in $(test_seq 1 128)
		do
			test_write_lines "stable-$file" >"stable/$file" ||
				return 1
		done &&
		test_write_lines "# base main" \
			>policy-main/nested/.gitattributes &&
		test_write_lines "# base main" \
			>policy-main/nested/.gitignore &&
		test_write_lines "# base linked" \
			>policy-linked/nested/.gitattributes &&
		test_write_lines "# base linked" \
			>policy-linked/nested/.gitignore &&
		git add stable policy-main policy-linked &&
		test_commit base tracked &&
		git branch -M main &&
		git remote add origin "$PWD/../daemon-pull-origin.git" &&
		git push --quiet -u origin main &&
		git --git-dir="$PWD/../daemon-pull-origin.git" \
			symbolic-ref HEAD refs/heads/main &&
		git clone --quiet "$PWD/../daemon-pull-origin.git" \
			"$PWD/../daemon-pull-fast" &&
		fast="$PWD/../daemon-pull-fast" &&
		fast_gitdir=$(git -C "$fast" rev-parse --absolute-git-dir) &&
		git -C "$fast" config pull.ff only &&
		git -C "$fast" config core.untrackedCache true &&
		git -C "$fast" config core.fsmonitor true &&
		git -C "$fast" config core.preloadIndexBulk true &&
		git -C "$fast" fsmonitor--daemon start --start-timeout=10 &&
		git -C "$fast" update-index --fsmonitor &&
		GIT_INDEX_FILE="$fast_gitdir/index" \
			git -C "$fast" status --porcelain=v2 \
				>"$fast_gitdir/prime" &&
		test_must_be_empty "$fast_gitdir/prime" &&
		test_write_lines normal >normal-fast-path &&
		git add normal-fast-path &&
		git commit -qm "normal fast path" &&
		git push --quiet origin main &&
		GIT_TRACE2_EVENT="$fast_gitdir/pull.trace" \
			git -C "$fast" pull --quiet &&
		test_trace2_data fsmonitor history/post-worktree-refresh 1 \
			<"$fast_gitdir/pull.trace" &&
		test_trace2_data fsmonitor history/writer-proof-repaired 1 \
			<"$fast_gitdir/pull.trace" &&
		test_trace2_data index refresh/sum_lstat 1 \
			<"$fast_gitdir/pull.trace" &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<"$fast_gitdir/pull.trace" &&
		test_fsmonitor_full_proof "$fast_gitdir/index" paired &&
		git -C "$fast" fsmonitor--daemon stop &&
		git clone --quiet "$PWD/../daemon-pull-origin.git" \
			"$PWD/../daemon-pull" &&
		repo="$PWD/../daemon-pull" &&
		linked="$PWD/../daemon-pull-linked" &&
		git -C "$repo" worktree add --quiet -b daemon-linked \
			"$linked" origin/main &&
		git -C "$linked" branch --quiet \
			--set-upstream-to=origin/main &&
		git -C "$repo" config pull.ff only &&
		git -C "$repo" config core.untrackedCache true &&
		git -C "$repo" config core.fsmonitor true &&
		git -C "$repo" config core.preloadIndexBulk true &&
		write_script "$repo/.git/hooks/post-index-change" <<-\EOF &&
			gitdir=$(git rev-parse --absolute-git-dir) || exit 1
			test ! -f "$gitdir/index.lock" || exit 1
			test -f "$gitdir/index" || exit 1
			printf "%s %s\n" "$1" "$2" >>"$gitdir/post-index-change.log"
		EOF
		for role in main linked
		do
			if test "$role" = main
			then
				worktree="$repo" &&
				affected=98 &&
				total=230
			else
				worktree="$linked" &&
				affected=196 &&
				total=326
			fi &&
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			git -C "$worktree" fsmonitor--daemon start \
				--start-timeout=10 &&
			git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			test_fsmonitor_full_proof "$gitdir/index" paired &&
			git -C "$worktree" fsmonitor--daemon stop &&
			git -C "$worktree" fsmonitor--daemon start \
				--start-timeout=10 &&
			rm -f "$gitdir/post-index-change.log" &&
			mkdir -p "policy-$role/nested/new" &&
			for file in $(test_seq 1 96)
			do
				test_write_lines "$role-$file" \
					>"policy-$role/nested/new/$file" || return 1
			done &&
			if test "$role" = main
			then
				test_write_lines "# changed main" \
					>policy-main/nested/.gitattributes &&
				test_write_lines "*.ignored" "# changed main" \
					>policy-main/nested/.gitignore
			else
				test_write_lines "* text" \
					>policy-linked/nested/.gitattributes &&
				test_write_lines "*.ignored" "!keep.ignored" \
					>policy-linked/nested/.gitignore
			fi &&
			git add "policy-$role" &&
			git commit -qm "upstream-$role" &&
			git push --quiet origin main &&
			GIT_TRACE2_EVENT="$gitdir/pull.trace" \
				git -C "$worktree" \
					-c protocol.version=2 \
					-c fetch.uriprotocols=https \
					-c http.https://example.invalid.extraHeader=header \
					-c http.https://example.invalid.proactiveAuth=basic \
					-c http.https://example.invalid.sslVerify=true \
					pull --quiet >"$gitdir/pull" &&
			! test_trace2_data fsmonitor untracked/proof-missing 1 \
				<"$gitdir/pull.trace" &&
			test_trace2_data index refresh/sum_lstat "$affected" \
				<"$gitdir/pull.trace" &&
			! test_trace2_data index refresh/sum_lstat "$total" \
				<"$gitdir/pull.trace" &&
			test_write_lines "1 0" \
				>"$gitdir/post-index-change.expect" &&
			test_cmp "$gitdir/post-index-change.expect" \
				"$gitdir/post-index-change.log" &&
			test_trace2_data fsmonitor history/writer-proof-repaired 1 \
				<"$gitdir/pull.trace" &&
			! test_trace2_data fsmonitor history/writer-proof-repaired 0 \
				<"$gitdir/pull.trace" &&
			test_fsmonitor_full_proof "$gitdir/index" paired &&
			for pass in first second
			do
				cp "$gitdir/index" "$gitdir/readonly-$pass.index" &&
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TRACE2_EVENT="$gitdir/readonly-$pass.trace" \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/readonly-$pass" &&
				test_must_be_empty "$gitdir/readonly-$pass" &&
				test_cmp_bin "$gitdir/readonly-$pass.index" \
					"$gitdir/index" &&
				test_trace2_data fsmonitor config/coherent 1 \
					<"$gitdir/readonly-$pass.trace" &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<"$gitdir/readonly-$pass.trace" &&
				! test_trace2_data fsmonitor untracked/proof-missing 1 \
					<"$gitdir/readonly-$pass.trace" &&
				! test_trace2_data read_directory \
					directories-visited "[1-9][0-9]*" \
					<"$gitdir/readonly-$pass.trace" &&
				! test_trace2_data read_directory paths-visited \
					"[1-9][0-9]*" \
					<"$gitdir/readonly-$pass.trace" &&
				! test_trace2_data read_directory opendir \
					"[1-9][0-9]*" \
					<"$gitdir/readonly-$pass.trace" &&
				! test_trace2_data index preload/sum_lstat \
					"[1-9][0-9]*" \
					<"$gitdir/readonly-$pass.trace" &&
				! test_region index do_write_index \
					"$gitdir/readonly-$pass.trace" || return 1
			done &&
			git -C "$worktree" fsmonitor--daemon stop || return 1
		done &&
		mkdir -p root-tree &&
		for file in $(test_seq 1 96)
		do
			mkdir -p "root-tree/$file/nested" &&
			test_write_lines "root-$file" \
				>"root-tree/$file/nested/tracked.txt" || return 1
		done &&
		test_write_lines "*.ignored" "# root ignore base" \
			>.gitignore &&
		test_write_lines "*.txt text" "# root attributes base" \
			>.gitattributes &&
		git add root-tree .gitignore .gitattributes &&
		git commit -qm "root policy base" &&
		git push --quiet origin main &&
		git clone --quiet "$PWD/../daemon-pull-origin.git" \
			"$PWD/../daemon-pull-root" &&
		root_repo="$PWD/../daemon-pull-root" &&
		root_linked="$PWD/../daemon-pull-root-linked" &&
		git -C "$root_repo" worktree add --quiet -b daemon-root-linked \
			"$root_linked" origin/main &&
		git -C "$root_linked" branch --quiet \
			--set-upstream-to=origin/main &&
		git -C "$root_repo" config pull.ff only &&
		git -C "$root_repo" config core.untrackedCache true &&
		git -C "$root_repo" config core.fsmonitor true &&
		git -C "$root_repo" config core.preloadIndexBulk true &&
		for worktree in "$root_repo" "$root_linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			git -C "$worktree" fsmonitor--daemon start \
				--start-timeout=10 &&
			git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/root-prime" &&
			test_must_be_empty "$gitdir/root-prime" &&
			test_fsmonitor_full_proof "$gitdir/index" paired || return 1
		done &&
		for role in main linked
		do
			if test "$role" = main
			then
				worktree="$root_repo" &&
				policy_dir=1
			else
				worktree="$root_linked" &&
				policy_dir=2
			fi &&
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			test_write_lines "*.ignored" \
				"# root ignore $role" >.gitignore &&
			test_write_lines "*.txt text" \
				"# root attributes $role" >.gitattributes &&
			test_write_lines "*.ignored" \
				"# nested ignore $role" \
				>"root-tree/$policy_dir/nested/.gitignore" &&
			test_write_lines "*.txt text" \
				"# nested attributes $role" \
				>"root-tree/$policy_dir/nested/.gitattributes" &&
			git add .gitignore .gitattributes \
				"root-tree/$policy_dir/nested/.gitignore" \
				"root-tree/$policy_dir/nested/.gitattributes" &&
			git commit -qm "root policy $role" &&
			git push --quiet origin main &&
			GIT_TRACE2_EVENT="$gitdir/root-pull.trace" \
				git -C "$worktree" pull --quiet &&
			test_trace2_data fsmonitor \
				checkout/untracked-policy-targeted 1 \
				<"$gitdir/root-pull.trace" &&
			test_trace2_data fsmonitor history/writer-proof-repaired 1 \
				<"$gitdir/root-pull.trace" &&
			test_fsmonitor_full_proof "$gitdir/index" paired &&
			git --no-optional-locks -C "$worktree" \
				-c core.fsmonitor=false ls-files --debug -- \
				.gitattributes .gitignore \
				"root-tree/$policy_dir/nested/.gitattributes" \
				"root-tree/$policy_dir/nested/.gitignore" \
					>"$gitdir/root-policy-stat" &&
			test_grep ! "ctime: 0:0" "$gitdir/root-policy-stat" &&
			test_grep ! "mtime: 0:0" "$gitdir/root-policy-stat" &&
			test_grep ! "size: 0" "$gitdir/root-policy-stat" &&
			for pass in first second
			do
				cp "$gitdir/index" "$gitdir/root-$pass.index" &&
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TRACE2_EVENT="$gitdir/root-$pass.trace" \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/root-$pass" &&
				test_must_be_empty "$gitdir/root-$pass" &&
				test_cmp_bin "$gitdir/root-$pass.index" \
					"$gitdir/index" &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<"$gitdir/root-$pass.trace" &&
				! test_trace2_data read_directory directories-visited \
					"[1-9][0-9]*" <"$gitdir/root-$pass.trace" &&
				! test_trace2_data read_directory opendir \
					"[1-9][0-9]*" <"$gitdir/root-$pass.trace" &&
				! test_trace2_data index preload/sum_lstat \
					"[1-9][0-9]*" <"$gitdir/root-$pass.trace" &&
				! test_trace2_data index refresh/sum_lstat \
					"[1-9][0-9]*" <"$gitdir/root-$pass.trace" &&
				! test_region index do_write_index \
					"$gitdir/root-$pass.trace" || return 1
			done &&
			git -C "$worktree" fsmonitor--daemon stop || return 1
		done &&
		git clone --quiet "$PWD/../daemon-pull-origin.git" \
			"$PWD/../daemon-pull-filter" &&
		filter="$PWD/../daemon-pull-filter" &&
		filter_gitdir=$(git -C "$filter" rev-parse --absolute-git-dir) &&
		git -C "$filter" config pull.ff only &&
		git -C "$filter" config core.untrackedCache true &&
		git -C "$filter" config core.fsmonitor true &&
		git -C "$filter" config core.preloadIndexBulk true &&
		git -C "$filter" config filter.daemonpull.clean false &&
		git -C "$filter" config filter.daemonpull.required true &&
		git -C "$filter" fsmonitor--daemon start --start-timeout=10 &&
		git -C "$filter" update-index --fsmonitor &&
		GIT_INDEX_FILE="$filter_gitdir/index" \
			git -C "$filter" status --porcelain=v2 \
				>"$filter_gitdir/prime" &&
		test_must_be_empty "$filter_gitdir/prime" &&
		git -C "$filter" fsmonitor--daemon stop &&
		git -C "$filter" fsmonitor--daemon start --start-timeout=10 &&
		test_write_lines "tracked filter=daemonpull" >.gitattributes &&
		git add .gitattributes &&
		git commit -qm "require unavailable filter" &&
		git push --quiet origin main &&
		GIT_TRACE2_EVENT="$filter_gitdir/pull.trace" \
			git -C "$filter" pull --quiet &&
		test_trace2_data fsmonitor semantic/manifest-invalidated 1 \
			<"$filter_gitdir/pull.trace" &&
		! test_trace2_data fsmonitor history/post-worktree-refresh 1 \
			<"$filter_gitdir/pull.trace" &&
		cp "$filter_gitdir/index" "$filter_gitdir/status.before" &&
		test_must_fail env GIT_OPTIONAL_LOCKS=0 \
			GIT_TRACE2_EVENT="$filter_gitdir/status.trace" \
			git -C "$filter" status --porcelain=v2 \
				--untracked-files=no -- tracked \
				>"$filter_gitdir/status" \
				2>"$filter_gitdir/status.err" &&
		test_grep "clean filter .daemonpull. failed" \
			"$filter_gitdir/status.err" &&
		test_cmp_bin "$filter_gitdir/status.before" \
			"$filter_gitdir/index" &&
		git -C "$filter" fsmonitor--daemon stop
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'clean sequencer operations preserve authenticated worktree proofs' '
	test_when_finished "rm -rf sequencer-proof sequencer-linked" &&
	test_create_repo sequencer-proof &&
	(
		cd sequencer-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_write_lines picked >tracked &&
		git add tracked &&
		git commit -qm picked &&
		picked=$(git rev-parse HEAD) &&
		git reset --hard HEAD^ &&
		git worktree add --detach ../sequencer-linked HEAD &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		git config core.preloadIndexBulk true &&
		for worktree in "$PWD" "$PWD/../sequencer-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			for operation in pick revert
			do
				case "$operation" in
				pick) set -- cherry-pick --no-edit "$picked" ;;
				revert) set -- revert --no-edit HEAD ;;
				esac &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
				GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
				GIT_TRACE2_EVENT="$gitdir/$operation.trace" \
					git -C "$worktree" "$@" \
						>"$gitdir/$operation" &&
				test_fsmonitor_full_proof \
					"$gitdir/index" paired &&
				cp "$gitdir/index" \
					"$gitdir/$operation.index" &&
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/$operation-status.trace" \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/$operation-status" &&
				test_must_be_empty "$gitdir/$operation-status" &&
				test_cmp_bin "$gitdir/$operation.index" \
					"$gitdir/index" &&
				test_trace2_data fsmonitor config/coherent 1 \
					<"$gitdir/$operation-status.trace" &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<"$gitdir/$operation-status.trace" || return 1
			done || return 1
		done &&
		test_write_lines conflicting >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git add tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git commit -qm local-conflict &&
		test_must_fail env \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git cherry-pick --no-edit "$picked" \
				>.git/conflict.out 2>.git/conflict.err &&
		if test_fsmonitor_full_proof .git/index paired \
			>/dev/null 2>&1
		then
			return 1
		fi &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/conflict &&
		test_grep "^u UU .* tracked$" .git/conflict
	)
'

test_expect_success FSMONITOR_DAEMON,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'routed push and owned writers preserve authenticated clean proofs' '
	test_when_finished "rm -rf daemon-writers daemon-writers-linked" &&
	test_when_finished \
		"git -C daemon-writers fsmonitor--daemon stop 2>/dev/null || :" &&
	test_when_finished \
		"git -C daemon-writers-linked fsmonitor--daemon stop 2>/dev/null || :" &&
	test_create_repo daemon-writers &&
	(
		cd daemon-writers &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir stable &&
		for file in $(test_seq 1 16)
		do
			test_write_lines "stable-$file" >"stable/$file" ||
				return 1
		done &&
		test_write_lines base >stable/anchor &&
		git add stable &&
		git commit -qm base &&
		base=$(git rev-parse HEAD) &&
		git checkout -q -b upstream &&
		for file in $(test_seq 1 16)
		do
			mkdir -p "incoming/package-$file/nested" &&
			test_write_lines "incoming-$file" \
				>"incoming/package-$file/nested/tracked" ||
				return 1
		done &&
		git add incoming &&
		git commit -qm upstream &&
		git checkout -q -b owned-main "$base" &&
		test_write_lines base topic >stable/anchor &&
		git add stable/anchor &&
		git commit -qm topic &&
		git branch owned-linked &&
		git worktree add -q ../daemon-writers-linked owned-linked &&
		repo=$PWD &&
		linked=$PWD/../daemon-writers-linked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		git config filter.lfs.clean "git-lfs clean -- %f" &&
		git config filter.lfs.smudge "git-lfs smudge -- %f" &&
		git config filter.lfs.process "git-lfs filter-process" &&
		git config filter.lfs.required true &&

		assert_no_full_worktree_scan () {
			trace=$1 &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 <"$trace" &&
			! test_trace2_data read_directory directories-visited \
				"[1-9][0-9]*" <"$trace" &&
			! test_trace2_data read_directory opendir \
				"[1-9][0-9]*" <"$trace" &&
			! test_trace2_data index preload/bulk_dirs \
				"[1-9][0-9]*" <"$trace" &&
			! test_trace2_data index preload/bulk_entries \
				"[1-9][0-9]*" <"$trace" &&
			! test_trace2_data index preload/sum_lstat \
				"[1-9][0-9]*" <"$trace" &&
			! test_trace2_data index refresh/sum_lstat \
				"[1-9][0-9]*" <"$trace" &&
			! test_region index do_write_index "$trace"
		} &&

		assert_clean_status_fast () {
			trace=$1 &&
			{
				test_trace2_data status clean-proof/hit 1 \
					<"$trace" ||
				test_trace2_data fsmonitor config/coherent 1 \
					<"$trace"
			}
		} &&

		assert_owned_writer_clean () {
			worktree=$1 &&
			label=$2 &&
			shift 2 &&
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			test_fsmonitor_full_proof "$gitdir/index" paired &&
			git --no-optional-locks -C "$worktree" \
				-c core.fsmonitor=false ls-files --debug -- "$@" \
					>"$gitdir/$label-stat" &&
			test_grep ! "ctime: 0:0" "$gitdir/$label-stat" &&
			test_grep ! "mtime: 0:0" "$gitdir/$label-stat" &&
			test_grep ! "size: 0" "$gitdir/$label-stat" &&
			for bulk in false true
			do
				pass=bulk-$bulk &&
				cp "$gitdir/index" \
					"$gitdir/$label-$pass.index" &&
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TRACE2_EVENT="$gitdir/$label-$pass.trace" \
					git -C "$worktree" \
						-c core.preloadIndexBulk=$bulk \
						status --porcelain=v2 \
						>"$gitdir/$label-$pass" &&
				test_must_be_empty "$gitdir/$label-$pass" &&
				test_cmp_bin "$gitdir/$label-$pass.index" \
					"$gitdir/index" &&
				test_trace2_data fsmonitor config/coherent 1 \
					<"$gitdir/$label-$pass.trace" &&
				! test_trace2_data fsmonitor untracked/proof-missing 1 \
					<"$gitdir/$label-$pass.trace" &&
				assert_no_full_worktree_scan \
					"$gitdir/$label-$pass.trace" || return 1
			done
		} &&

		assert_routed_push_fast () {
			worktree=$1 &&
			label=$2 &&
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			for route in https ssh
			do
				case "$route" in
				https)
					pushurl_key=remote.https.pushurl &&
					pushurl=https://example.invalid/repository.git
					;;
				ssh)
					pushurl_key=remote.origin.pushurl &&
					pushurl=ssh://git@example.invalid/repository.git
					;;
				esac &&
				for pass in first second
				do
					prefix="$gitdir/$label-$route-$pass" &&
					cp "$gitdir/index" "$prefix.index" &&
					GIT_OPTIONAL_LOCKS=0 \
					GIT_TRACE2_EVENT="$prefix.diff.trace" \
						git -C "$worktree" \
							-c push.negotiate=true \
							-c "$pushurl_key=$pushurl" \
							diff --quiet --no-ext-diff \
								--no-textconv --ignore-submodules &&
					test_cmp_bin "$prefix.index" "$gitdir/index" &&
					test_trace2_data fsmonitor config/coherent 1 \
						<"$prefix.diff.trace" &&
					assert_no_full_worktree_scan \
						"$prefix.diff.trace" &&
					GIT_TRACE2_EVENT="$prefix.write-tree.trace" \
						git -C "$worktree" \
							-c push.negotiate=true \
							-c "$pushurl_key=$pushurl" \
							write-tree >"$prefix.tree" &&
					test_file_not_empty "$prefix.tree" &&
					test_cmp_bin "$prefix.index" "$gitdir/index" &&
					assert_no_full_worktree_scan \
						"$prefix.write-tree.trace" &&
					GIT_OPTIONAL_LOCKS=0 \
					GIT_TRACE2_EVENT="$prefix.status.trace" \
						git -C "$worktree" \
							-c push.negotiate=true \
							-c "$pushurl_key=$pushurl" \
							status --porcelain=v2 \
								>"$prefix.status" &&
					test_must_be_empty "$prefix.status" &&
					test_cmp_bin "$prefix.index" "$gitdir/index" &&
					assert_clean_status_fast \
						"$prefix.status.trace" &&
					assert_no_full_worktree_scan \
						"$prefix.status.trace" || return 1
				done &&
				prefix="$gitdir/$label-$route-writable" &&
				cp "$gitdir/index" "$prefix.index" &&
				GIT_TRACE2_EVENT="$prefix.status.trace" \
					git -C "$worktree" \
						-c push.negotiate=true \
						-c "$pushurl_key=$pushurl" \
						status --porcelain=v2 >"$prefix.status" &&
				test_must_be_empty "$prefix.status" &&
				assert_clean_status_fast \
					"$prefix.status.trace" &&
				assert_no_full_worktree_scan \
					"$prefix.status.trace" &&
				GIT_TRACE2_EVENT="$prefix.tracked.trace" \
					git -C "$worktree" status --porcelain=v2 \
						--untracked-files=no >"$prefix.tracked" &&
				test_must_be_empty "$prefix.tracked" &&
				test_cmp_bin "$prefix.index" "$gitdir/index" &&
				assert_clean_status_fast \
					"$prefix.tracked.trace" &&
				assert_no_full_worktree_scan \
					"$prefix.tracked.trace" &&
				test_fsmonitor_full_proof "$gitdir/index" paired ||
					return 1
			done
		} &&

		for worktree in "$repo" "$linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			test-tool chmtime =-60 "$worktree"/stable/* &&
			git -C "$worktree" -c core.fsmonitor=false \
				update-index --refresh &&
			git -C "$worktree" fsmonitor--daemon start \
				--start-timeout=10 &&
			git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			test_fsmonitor_full_proof "$gitdir/index" paired ||
				return 1
		done &&
		assert_routed_push_fast "$repo" main &&
		assert_routed_push_fast "$linked" linked &&

		for worktree in "$repo" "$linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			GIT_TRACE2_EVENT="$gitdir/rebase.trace" \
				git -C "$worktree" rebase upstream &&
			test_trace2_data fsmonitor \
				history/writer-proof-repaired 1 \
				<"$gitdir/rebase.trace" &&
			! test_trace2_data fsmonitor \
				history/writer-proof-repaired 0 \
				<"$gitdir/rebase.trace" &&
			assert_owned_writer_clean "$worktree" rebase incoming ||
				return 1
		done &&

		rebased=$(git rev-parse HEAD) &&
		gitdir=$(git rev-parse --absolute-git-dir) &&
		GIT_TRACE2_EVENT="$gitdir/reset.trace" \
			git reset --hard -q upstream &&
		test_trace2_data fsmonitor history/writer-proof-repaired 1 \
			<"$gitdir/reset.trace" &&
		assert_owned_writer_clean "$repo" reset incoming &&
		GIT_TRACE2_EVENT="$gitdir/reset-back.trace" \
			git reset --hard -q "$rebased" &&
		test_trace2_data fsmonitor history/writer-proof-repaired 1 \
			<"$gitdir/reset-back.trace" &&
		assert_owned_writer_clean "$repo" reset-back incoming &&

		test_write_lines base topic stashed >stable/anchor &&
		GIT_TRACE2_EVENT="$gitdir/stash.trace" \
			git stash push -qm writer-proof &&
		test_trace2_data fsmonitor history/writer-proof-repaired 1 \
			<"$gitdir/stash.trace" &&
		assert_owned_writer_clean "$repo" stash incoming &&

		GIT_TRACE2_EVENT="$gitdir/checkout-upstream.trace" \
			git checkout -q upstream &&
		assert_owned_writer_clean "$repo" checkout-upstream incoming &&
		GIT_TRACE2_EVENT="$gitdir/checkout-topic.trace" \
			git checkout -q owned-main &&
		test_trace2_data fsmonitor history/writer-proof-repaired 1 \
			<"$gitdir/checkout-topic.trace" &&
		assert_owned_writer_clean "$repo" checkout-topic incoming &&

		git -C "$repo" fsmonitor--daemon stop &&
		git -C "$linked" fsmonitor--daemon stop
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'expired add preserves untracked candidates until revalidation' '
	test_when_finished "rm -rf pending-untracked-revalidation pending-untracked-hostile" &&
	test_create_repo pending-untracked-revalidation &&
	(
		cd pending-untracked-revalidation &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir -p cached/deep sibling &&
		test_write_lines base >cached/deep/tracked &&
		test_write_lines sibling >sibling/tracked &&
		git add cached/deep/tracked sibling/tracked &&
		git commit -m base &&
		test_write_lines visible >root-visible-unique &&
		test_write_lines nested >cached/deep/nested-visible-unique &&
		test_write_lines sibling >sibling/sibling-visible-unique &&
		git config filter.inactive.clean cat &&
		git config filter.inactive.process cat &&
		git config filter.hostile.clean "tr a-z A-Z" &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		test-tool chmtime =-60 cached/deep cached sibling . &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/prime.trace" \
			git status --porcelain=v2 >.git/prime &&
		test_trace2_data fsmonitor filter-scope/valid 1 \
			<.git/prime.trace &&
		test_grep FSUC .git/index &&
		test_grep root-visible-unique .git/index &&
		test_grep nested-visible-unique .git/index &&
		test_grep sibling-visible-unique .git/index &&

		test_write_lines changed >cached/deep/tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=T \
		GIT_TRACE2_EVENT="$PWD/.git/add.trace" \
			git add cached/deep/tracked &&
		test_trace2_data fsmonitor \
			untracked/provider-reset-preserved 1 <.git/add.trace &&
		test_trace2_data fsmonitor \
			untracked/provider-reset-pending 1 <.git/add.trace &&
		test_grep FSMN .git/index &&
		test_grep FSUC .git/index &&
		test_grep "pending:" .git/index &&
		test_grep root-visible-unique .git/index &&
		test_grep nested-visible-unique .git/index &&
		test_grep sibling-visible-unique .git/index &&

		GIT_OPTIONAL_LOCKS=0 git \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/expect &&
		test_grep "^1 M\\. .* cached/deep/tracked$" .git/expect &&
		test_grep "^? root-visible-unique$" .git/expect &&
		test_grep "^? cached/deep/nested-visible-unique$" .git/expect &&
		if test -n "${GIT_TEST_FSMONITOR_LEGACY-}" &&
			test -x "$GIT_TEST_FSMONITOR_LEGACY"
		then
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
				"$GIT_TEST_FSMONITOR_LEGACY" \
				status --porcelain=v2 >.git/legacy &&
			test_cmp .git/expect .git/legacy
		else
			:
		fi &&

		cp .git/index .git/worktree-pending.index &&
		GIT_WORK_TREE="$PWD" \
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
		GIT_TEST_UNTRACKED_CACHE_AUTO_PRELOAD=1 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=4 \
		GIT_TRACE2_EVENT="$PWD/.git/worktree.trace" \
			git status --porcelain=v2 >.git/worktree.actual &&
		test_cmp .git/expect .git/worktree.actual &&
		test_trace2_data fsmonitor \
			untracked/provider-reset-resumed 1 <.git/worktree.trace &&
		test_trace2_data read_directory opendir 0 <.git/worktree.trace &&
		test_cmp .git/worktree-pending.index .git/index &&
		test_grep "pending:" .git/index &&

		mkdir ../pending-untracked-hostile &&
		GIT_WORK_TREE="$PWD/../pending-untracked-hostile" \
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/worktree-hostile.expect &&
		GIT_WORK_TREE="$PWD/../pending-untracked-hostile" \
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/worktree-hostile.trace" \
			git status --porcelain=v2 >.git/worktree-hostile.actual &&
		test_cmp .git/worktree-hostile.expect \
			.git/worktree-hostile.actual &&
		! test_trace2_data fsmonitor \
			untracked/provider-reset-resumed 1 \
			<.git/worktree-hostile.trace &&
		test_cmp .git/worktree-pending.index .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
		GIT_TEST_UNTRACKED_CACHE_AUTO_PRELOAD=1 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=4 \
		GIT_TRACE2_EVENT="$PWD/.git/revalidated.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_trace2_data status \
			untracked/provider-reset-preload 1 \
			<.git/revalidated.trace &&
		test_trace2_data dir preload_untracked_cache/valid 1 \
			<.git/revalidated.trace &&
		test_trace2_data read_directory opendir 0 \
			<.git/revalidated.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/revalidated.trace &&
		test_trace2_data fsmonitor \
			untracked/provider-reset-resumed 1 \
			<.git/revalidated.trace &&
		test_grep FSUC .git/index &&
		test_grep ! "pending:" .git/index &&

		cp .git/index .git/pending-alternate.index &&
		test_write_lines alternate >cached/deep/tracked &&
		GIT_INDEX_FILE="$PWD/.git/pending-alternate.index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=T \
		GIT_TRACE2_EVENT="$PWD/.git/alternate.trace" \
			git add cached/deep/tracked &&
		test_grep ! "pending:" .git/pending-alternate.index &&
		test_grep FSUC .git/index &&
		test_grep ! "pending:" .git/index &&
		! test_trace2_data fsmonitor untracked/provider-reset-pending 1 \
			<.git/alternate.trace &&

		test_write_lines changed-again >cached/deep/tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=T \
			git add cached/deep/tracked &&
		test_grep "pending:" .git/index &&
		test_write_lines "tracked filter=hostile" \
			>cached/deep/.gitattributes &&
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/hostile.expect &&
		test_grep "^1 MM .* cached/deep/tracked$" .git/hostile.expect &&
		test_grep "^? cached/deep/.gitattributes$" .git/hostile.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
		GIT_TEST_UNTRACKED_CACHE_AUTO_PRELOAD=1 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=4 \
		GIT_TRACE2_EVENT="$PWD/.git/hostile.trace" \
			git status --porcelain=v2 >.git/hostile.actual &&
		test_cmp .git/hostile.expect .git/hostile.actual &&
		! test_trace2_data status untracked/provider-reset-preload 1 \
			<.git/hostile.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'scoped provider resets validate the complete cache in parallel' '
	test_when_finished "rm -rf builtin-reset-scoped" &&
	test_create_repo builtin-reset-scoped &&
	(
		cd builtin-reset-scoped &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir -p cached/deep &&
		test_write_lines "*.root-ignored" >.gitignore &&
		test_write_lines "*.nested-ignored" >cached/.gitignore &&
		test_write_lines tracked >cached/deep/tracked &&
		test_write_lines visible >cached/deep/retained &&
		test_write_lines hidden >cached/deep/hidden.nested-ignored &&
		for nr in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16
		do
			mkdir "outside-$nr" &&
			test_write_lines "$nr" >"outside-$nr/tracked" || return 1
		done &&
		test_write_lines outside >outside-01/retained &&
		test_write_lines hidden >outside-01/hidden.root-ignored &&
		git add .gitignore cached/.gitignore cached/deep/tracked \
			outside-*/tracked &&
		git commit -m base &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		test-tool chmtime =-60 cached/deep cached outside-* . &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		for prime in first second third
		do
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
				git status --porcelain=v2 >.git/prime || return 1
		done &&
		test_grep "^? cached/deep/retained$" .git/prime &&
		test_grep "^? outside-01/retained$" .git/prime &&
		test_grep FSUC .git/index &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				status --porcelain=v2 -- cached/deep >.git/scoped.expect &&
		if test_have_prereq PTHREADS
		then
			worker_counts="6 8 12 16"
		else
			worker_counts=1
		fi &&
		for workers in $worker_counts
		do
			rm -f .git/index.csts &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
			GIT_TEST_UNTRACKED_CACHE_AUTO_PRELOAD=1 \
			GIT_TEST_UNTRACKED_CACHE_THREADS="$workers" \
			GIT_TRACE2_EVENT="$PWD/.git/scoped-$workers.trace" \
				git status --porcelain=v2 -- cached/deep \
				>.git/scoped.actual &&
			test_cmp .git/scoped.expect .git/scoped.actual &&
			test_trace2_data dir preload_untracked_cache/threads \
				"$workers" <".git/scoped-$workers.trace" &&
			test_trace2_data status \
				untracked/provider-reset-scoped-preload 1 \
				<".git/scoped-$workers.trace" &&
			test_trace2_data fsmonitor token_closure/accepted 1 \
				<".git/scoped-$workers.trace" || return 1
		done &&

		test_write_lines outside-new >outside-01/new &&
		rm -f .git/index.csts &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
		GIT_TEST_UNTRACKED_CACHE_AUTO_PRELOAD=1 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=8 \
		GIT_TRACE2_EVENT="$PWD/.git/outside.trace" \
			git status --porcelain=v2 -- cached/deep \
			>.git/outside.actual &&
		test_cmp .git/scoped.expect .git/outside.actual &&
		test_trace2_data dir preload_untracked_cache/valid 0 \
			<.git/outside.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/outside.trace &&

		test_write_lines retained >cached/.gitignore &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				status --porcelain=v2 -- cached/deep \
				>.git/ignore.expect &&
		rm -f .git/index.csts &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
		GIT_TEST_UNTRACKED_CACHE_AUTO_PRELOAD=1 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=8 \
		GIT_TRACE2_EVENT="$PWD/.git/ignore.trace" \
			git status --porcelain=v2 -- cached/deep \
			>.git/ignore.actual &&
		test_cmp .git/ignore.expect .git/ignore.actual &&
		test_grep "^? cached/deep/hidden.nested-ignored$" \
			.git/ignore.actual &&
		test_grep ! "^? cached/deep/retained$" .git/ignore.actual &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/ignore.trace &&

		rm -f .git/index.csts &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=// \
		GIT_TRACE2_EVENT="$PWD/.git/global.trace" \
			git status --porcelain=v2 -- cached/deep \
			>.git/global.actual &&
		test_cmp .git/ignore.expect .git/global.actual &&
		test_trace2_data fsmonitor apply/global-invalidation 1 \
			<.git/global.trace &&
		! test_trace2_data status \
			untracked/provider-reset-scoped-preload 1 \
			<.git/global.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'provider reset detects new nested untracked and ignore changes' '
	test_when_finished "rm -rf builtin-reset-changed" &&
	test_create_repo builtin-reset-changed &&
	(
		cd builtin-reset-changed &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir -p cached/deep sibling/empty &&
		test_write_lines hidden >cached/.gitignore &&
		test_write_lines tracked >cached/deep/tracked &&
		test_write_lines sibling >sibling/empty/tracked &&
		test_write_lines hidden >cached/deep/hidden &&
		git add cached/.gitignore cached/deep/tracked \
			sibling/empty/tracked &&
		git commit -m base &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		test-tool chmtime =-60 cached/deep cached \
			sibling/empty sibling . &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		for prime in first second third
		do
			GIT_INDEX_FILE="$PWD/.git/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
				git status --porcelain=v2 >.git/prime || return 1
		done &&
		test_must_be_empty .git/prime &&
		test_grep FSUC .git/index &&
		test_write_lines visible >cached/deep/new &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				status --porcelain=v2 >.git/new.expect &&
		rm -f .git/index.csts &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
		GIT_TEST_UNTRACKED_CACHE_AUTO_PRELOAD=1 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=4 \
		GIT_TRACE2_EVENT="$PWD/.git/new.trace" \
			git status --porcelain=v2 >.git/new.actual &&
		test_cmp .git/new.expect .git/new.actual &&
		test_grep "^? cached/deep/new$" .git/new.actual &&
		test_trace2_data fsmonitor \
			untracked/provider-reset-preserved 1 <.git/new.trace &&
		test_trace2_data dir preload_untracked_cache/valid 0 \
			<.git/new.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/new.trace &&

		test_write_lines other >cached/.gitignore &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				status --porcelain=v2 >.git/ignore.expect &&
		rm -f .git/index.csts &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCC \
		GIT_TEST_UNTRACKED_CACHE_AUTO_PRELOAD=1 \
		GIT_TEST_UNTRACKED_CACHE_THREADS=4 \
		GIT_TRACE2_EVENT="$PWD/.git/ignore.trace" \
			git status --porcelain=v2 >.git/ignore.actual &&
		test_cmp .git/ignore.expect .git/ignore.actual &&
		test_grep "^1 \\.M .* cached/.gitignore$" .git/ignore.actual &&
		test_grep "^? cached/deep/hidden$" .git/ignore.actual &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/ignore.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'global provider invalidation never preserves untracked snapshots' '
	test_when_finished "rm -rf builtin-reset-global" &&
	test_create_repo builtin-reset-global &&
	(
		cd builtin-reset-global &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir cached &&
		test_write_lines tracked >cached/tracked &&
		git add cached/tracked &&
		git commit -m base &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSUC .git/index &&
		test_write_lines visible >cached/new &&
		rm -f .git/index.csts &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=// \
		GIT_TRACE2_EVENT="$PWD/.git/global.trace" \
			git status --porcelain=v2 >.git/global.actual &&
		test_grep "^? cached/new$" .git/global.actual &&
		test_trace2_data fsmonitor apply/global-invalidation 1 \
			<.git/global.trace &&
		! test_trace2_data fsmonitor \
			untracked/provider-reset-preserved 1 <.git/global.trace
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
		GIT_INDEX_FILE="$PWD/.git/index" \
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

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'diff fully revalidates reset proofs in main and linked worktrees' '
	test_when_finished "rm -rf builtin-diff-reset builtin-diff-reset-linked" &&
	test_create_repo builtin-diff-reset &&
	(
		cd builtin-diff-reset &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit sibling sibling &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		git -c core.fsmonitor=false worktree add --detach \
			../builtin-diff-reset-linked HEAD &&
		git config filter.lfs.clean "git-lfs clean -- %f" &&
		git config filter.lfs.smudge "git-lfs smudge -- %f" &&
		git config filter.lfs.process "git-lfs filter-process" &&
		git config filter.lfs.required true &&
		for worktree in "$PWD" "$PWD/../builtin-diff-reset-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			test_grep FSMN "$gitdir/index" &&
			test_grep FSUC "$gitdir/index" &&
			test-tool chmtime =-60 "$worktree/tracked" &&
			cp "$gitdir/index" "$gitdir/readonly.index" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_PRELOAD_INDEX=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/readonly.trace" \
				git -C "$worktree" diff \
					>"$gitdir/readonly.actual" &&
			test_must_be_empty "$gitdir/readonly.actual" &&
			test_cmp_bin "$gitdir/readonly.index" "$gitdir/index" &&
			test_trace2_data fsm_client query/trivial-response 1 \
				<"$gitdir/readonly.trace" &&
			GIT_TEST_PRELOAD_INDEX=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/reset.trace" \
				git -C "$worktree" diff \
					>"$gitdir/reset.actual" &&
			test_must_be_empty "$gitdir/reset.actual" &&
			test_trace2_data fsm_client query/trivial-response 1 \
				<"$gitdir/reset.trace" &&
			test_trace2_data diff recovery/reused-provider-observations 1 \
				<"$gitdir/reset.trace" &&
			test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/reset.trace" >"$gitdir/reset.manifests" &&
			test_line_count = 1 "$gitdir/reset.manifests" &&
			test_grep \
				"\"event\":\"region_enter\".*\"category\":\"index\",\"label\":\"do_read_index\"" \
				"$gitdir/reset.trace" >"$gitdir/reset.reads" &&
			test_line_count = 1 "$gitdir/reset.reads" &&
			test_region index do_write_index "$gitdir/reset.trace" &&
			test_fsmonitor_full_proof "$gitdir/index" paired &&
			cp "$gitdir/index" "$gitdir/pending.index" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/pending-status.trace" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/pending-status" &&
			test_must_be_empty "$gitdir/pending-status" &&
			test_cmp_bin "$gitdir/pending.index" "$gitdir/index" &&
			test_trace2_data fsmonitor config/coherent 1 \
				<"$gitdir/pending-status.trace" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/pending-status.trace" &&
			! test_trace2_data dir preload_untracked_cache/dirs \
				"[2-9][0-9]*" \
				<"$gitdir/pending-status.trace" &&
			! test_trace2_data dir preload_untracked_cache/dirs \
				"1[0-9][0-9]*" \
				<"$gitdir/pending-status.trace" &&
			! test_region index do_write_index \
				"$gitdir/pending-status.trace" &&
			GIT_TEST_PRELOAD_INDEX=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/next.trace" \
				git -C "$worktree" diff \
					>"$gitdir/next.actual" &&
			test_must_be_empty "$gitdir/next.actual" &&
			if test_have_prereq PTHREADS
			then
				test_trace2_data index preload/sum_lstat 0 \
					<"$gitdir/next.trace"
			else
				test_region ! index preload "$gitdir/next.trace"
			fi || return 1
		done &&
		git config filter.lfs.process "" &&
		git config filter.lfs.clean false &&
		test_write_lines "tracked filter=lfs" >.gitattributes &&
		cp .git/index .git/filtered.index &&
		test_must_fail env GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
			git diff >.git/filtered.out 2>.git/filtered.err &&
		test_grep "clean filter .lfs. failed" .git/filtered.err &&
		test_cmp_bin .git/filtered.index .git/index
	)
'

test_expect_success PIPE,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'provider-reset diff never overwrites a competing skipHash writer' '
	test_when_finished "rm -rf diff-recovery-competing-writer" &&
	test_create_repo diff-recovery-competing-writer &&
	(
		cd diff-recovery-competing-writer &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		fsmonitor_query_pid= &&
		trap cleanup_fsmonitor_query_barrier 0 &&
		test_commit base tracked &&
		test_commit sibling sibling &&
		git config index.skipHash true &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_trailing_hash .git/index >.git/index.hash &&
		test_oid zero >.git/zero &&
		test_cmp .git/zero .git/index.hash &&
		test-tool chmtime =-60 tracked &&
		ready="$PWD/.git/provider.ready" &&
		resume="$PWD/.git/provider.resume" &&
		mkfifo "$resume" &&
		{
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_BARRIER_AT=2 \
			GIT_TEST_FSMONITOR_QUERY_BARRIER_READY="$ready" \
			GIT_TEST_FSMONITOR_QUERY_BARRIER_RESUME="$resume" \
			GIT_TRACE2_EVENT="$PWD/.git/diff.trace" \
				git diff >.git/actual 2>.git/error &
			fsmonitor_query_pid=$!
		} &&
		wait_for_fsmonitor_query_barrier \
			"$ready" "$fsmonitor_query_pid" &&
		test_trace2_data diff recovery/reused-provider-observations 1 \
			<.git/diff.trace &&
		test_path_is_missing .git/index.lock &&
		test_write_lines competing >sibling &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			add sibling &&
		cp .git/index .git/competing.index &&
		printf x >"$resume" &&
		wait "$fsmonitor_query_pid" &&
		fsmonitor_query_pid= &&
		trap - 0 &&
		test_must_be_empty .git/actual &&
		test_cmp_bin .git/competing.index .git/index &&
		! test_region index do_write_index .git/diff.trace &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			diff --cached --name-only >.git/staged &&
		test_grep "^sibling$" .git/staged
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
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CE \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_grep "^? visible$" .git/actual &&
		test_grep \
			"\"event\":\"region_enter\".*\"category\":\"dir\",\"label\":\"read_directory\"" \
			.git/status.trace >.git/read-directory &&
		test_line_count -ge 1 .git/read-directory &&
		test_trace2_data fsmonitor token_closure/rejected 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep ! FSUC .git/index
	)
'

test_expect_success PERL_TEST_HELPERS \
	'index reader rejects an out-of-bounds extension size' '
	test_when_finished "rm -rf oversized-index-extension" &&
	test_create_repo oversized-index-extension &&
	(
		cd oversized-index-extension &&
		test_commit base tracked &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		test_grep FSMN .git/index >/dev/null &&
		perl -0777 -pe "
			\$pos = index(\$_, q(FSMN));
			die q(FSMN-not-found) if \$pos < 0;
			substr(\$_, \$pos + 4, 4) = pack(q(N), 0xffffffff);
		" .git/index >.git/index.bad &&
		mv .git/index.bad .git/index &&
		test_must_fail git status --porcelain=v2 2>err &&
		test_grep "index file corrupt" err
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
	'second closing-query change preserves verified sibling subtrees' '
	test_when_finished \
		"rm -rf second-query-changed-file second-query-changed-directory second-query-changed-large-directory" &&
	for event in file directory large-directory
	do
		test_create_repo "second-query-changed-$event" &&
		(
		cd "second-query-changed-$event" &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir cached &&
		test_write_lines "*.ignored" >.gitignore &&
		test_write_lines "*.ignored" >cached/.gitignore &&
		printf "aaaa\n" >cached/tracked &&
		test_write_lines ignored >cached/junk.ignored &&
		if test "$event" = large-directory
		then
			for descendant in $(test_seq 1 128)
			do
				test_write_lines "$descendant" \
					>"cached/retained-$descendant" || return 1
			done
		fi &&
		for sibling in $(test_seq 1 12)
		do
			mkdir "sibling-$sibling" &&
			test-tool genrandom "sibling-$sibling" 4096 \
				>"sibling-$sibling/tracked" &&
			test_write_lines ignored \
				>"sibling-$sibling/retained.ignored" || return 1
		done &&
		git add .gitignore cached/.gitignore cached/tracked sibling-* &&
		if test "$event" = large-directory
		then
			git add cached/retained-*
		fi &&
		git commit -m base &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		git config core.untrackedCache true &&
		test_write_lines visible >sibling-1/visible &&
		git -c core.fsmonitor=false status --porcelain=v2 \
			>.git/prime &&
		test_line_count = 1 .git/prime &&
		test_grep "^? sibling-1/visible$" .git/prime &&
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
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			-c core.trustctime=true -c core.checkStat=default \
			status --porcelain=v2 >.git/expect &&

		if test "$event" != file
		then
			changed_path=cached/
		else
			changed_path=cached/tracked
		fi &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCDC \
		GIT_TEST_FSMONITOR_QUERY_PATH="$changed_path" \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
		GIT_TRACE2_PERF="$PWD/.git/status.perf" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_line_count = 2 .git/actual &&
		test_grep "^1 \.M .* cached/tracked$" .git/actual &&
		test_grep "^? sibling-1/visible$" .git/actual &&
		test_trace2_data status fsmonitor_token/semantic-closed 1 \
			<.git/status.trace &&
		test_trace2_data status \
			fsmonitor_token/untracked-after-semantic 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/apply_count 1 \
			<.git/status.trace &&
		if test "$event" != file
		then
			test_trace2_data fsmonitor \
				semantic/manifest-directory-reused 1 \
				<.git/status.trace
		else
			! test_trace2_data fsmonitor \
				semantic/manifest-directory-reused 1 \
				<.git/status.trace
		fi &&
		test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/status.trace >.git/manifest-scans &&
		test_line_count = 1 .git/manifest-scans &&
		test_trace2_data status \
			fsmonitor_token/reused-semantic-subtrees 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/status.trace >.git/strong-invalidations &&
		test_line_count = 1 .git/strong-invalidations &&
		sed -n \
			"s/.*directories-visited:\\([0-9][0-9]*\\).*/\\1/p" \
			.git/status.perf >.git/visited &&
		test_line_count = 2 .git/visited &&
		initial_visited=$(sed -n 1p .git/visited) &&
		retry_visited=$(sed -n 2p .git/visited) &&
		test "$initial_visited" -gt 8 &&
		test "$retry_visited" -lt 4 &&
		sed -n \
			"s/.*paths-visited:\\([0-9][0-9]*\\).*/\\1/p" \
			.git/status.perf >.git/visited-paths &&
		test_line_count = 2 .git/visited-paths &&
		initial_paths=$(sed -n 1p .git/visited-paths) &&
		retry_paths=$(sed -n 2p .git/visited-paths) &&
		test "$retry_paths" -lt "$initial_paths" &&
		sed -n "s/.*opendir:\\([0-9][0-9]*\\).*/\\1/p" \
			.git/status.perf >.git/opened &&
		test_line_count = 2 .git/opened &&
		initial_opened=$(sed -n 1p .git/opened) &&
		retry_opened=$(sed -n 2p .git/opened) &&
		test "$initial_opened" -gt 8 &&
		test $((retry_opened - initial_opened)) -gt 0 &&
		test $((retry_opened - initial_opened)) -le 2 &&
		if test "$event" = large-directory
		then
			test_trace2_data index refresh/sum_lstat 130 \
				<.git/status.trace
		else
			test_trace2_data index refresh/sum_lstat "[0-2]" \
				<.git/status.trace
		fi &&
		test_trace2_data status \
			fsmonitor_token/untracked-after-retry 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_fsmonitor_full_proof .git/index paired
		) || return 1
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'directory closure reuses more than 64 authenticated attribute sources' '
	test_when_finished "rm -rf directory-many-attribute-candidates" &&
	test_create_repo directory-many-attribute-candidates &&
	(
		cd directory-many-attribute-candidates &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir before cached sibling &&
		for descendant in $(test_seq 1 64)
		do
			mkdir "cached/child-$descendant" &&
			printf "aaaa\n" \
				>"cached/child-$descendant/tracked" || return 1
		done &&
		test_write_lines "# unchanged before" \
			>before/.gitattributes &&
		test_write_lines "# unchanged inside" \
			>cached/child-32/.gitattributes &&
		test_write_lines "# unchanged after" \
			>sibling/.gitattributes &&
		test_write_lines retained >before/tracked &&
		test_write_lines retained >sibling/tracked &&
		git add before cached sibling &&
		git commit -qm base &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		git config core.untrackedCache true &&
		test_write_lines visible >sibling/visible &&
		git -c core.fsmonitor=false status --porcelain=v2 >.git/prime &&
		test_grep "^? sibling/visible$" .git/prime &&
		test-tool chmtime =-60 cached/child-1/tracked &&
		git update-index --refresh &&
		mtime=$(test-tool chmtime --get cached/child-1/tracked) &&
		printf "bbbb\n" >cached/child-1/tracked &&
		test-tool chmtime =$mtime cached/child-1/tracked &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor-valid cached/child-1/tracked &&
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			-c core.trustctime=true -c core.checkStat=default \
			status --porcelain=v2 >.git/expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCDC \
		GIT_TEST_FSMONITOR_QUERY_PATH=cached/ \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_grep "^1 \\.M .* cached/child-1/tracked$" .git/actual &&
		test_grep "^? sibling/visible$" .git/actual &&
		test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor semantic/manifest-directory-reused 1 \
			<.git/status.trace &&
		test_trace2_data status \
			fsmonitor_token/reused-semantic-subtrees 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_fsmonitor_full_proof .git/index paired
	)
'

test_expect_success PIPE,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'directory closure rejects raced attributes and rechecks raced excludes' '
	test_when_finished "rm -rf directory-race-attributes \
		directory-race-nested-attributes directory-race-ignore" &&
	for mutation in attributes nested-attributes ignore
	do
		test_create_repo "directory-race-$mutation" &&
		(
			cd "directory-race-$mutation" &&
			sane_unset GIT_TEST_SPLIT_INDEX &&
			fsmonitor_query_pid= &&
			trap cleanup_fsmonitor_query_barrier 0 &&
			mkdir cached &&
			test_write_lines "*.ignored" >.gitignore &&
			test_write_lines "*.ignored" >cached/.gitignore &&
			printf "aaaa\n" >cached/tracked &&
			test_write_lines ignored >cached/junk.ignored &&
			for descendant in $(test_seq 1 128)
			do
				test_write_lines "$descendant" \
					>"cached/retained-$descendant" || return 1
			done &&
			if test "$mutation" = nested-attributes
			then
				for descendant in $(test_seq 1 64)
				do
					mkdir "cached/child-$descendant" &&
					test_write_lines "$descendant" \
						>"cached/child-$descendant/tracked" ||
						return 1
				done
			fi &&
			for sibling in $(test_seq 1 8)
			do
				mkdir "sibling-$sibling" &&
				test_write_lines "$sibling" \
					>"sibling-$sibling/tracked" || return 1
			done &&
			git add .gitignore cached/.gitignore cached/tracked \
				cached/retained-* sibling-* &&
			if test "$mutation" = nested-attributes
			then
				git add cached/child-*
			fi &&
			git commit -qm base &&
			git config core.trustctime false &&
			git config core.checkStat minimal &&
			git config core.untrackedCache true &&
			test_write_lines visible >sibling-1/visible &&
			git -c core.fsmonitor=false status --porcelain=v2 \
				>.git/prime &&
			test_grep "^? sibling-1/visible$" .git/prime &&
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
			ready="$PWD/.git/provider.ready" &&
			resume="$PWD/.git/provider.resume" &&
			mkfifo "$resume" &&
			{
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCDC \
				GIT_TEST_FSMONITOR_QUERY_PATH=cached/ \
				GIT_TEST_FSMONITOR_QUERY_BARRIER_AT=3 \
				GIT_TEST_FSMONITOR_QUERY_BARRIER_READY="$ready" \
				GIT_TEST_FSMONITOR_QUERY_BARRIER_RESUME="$resume" \
				GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
					git status --porcelain=v2 \
						>.git/actual 2>.git/error &
				fsmonitor_query_pid=$!
			} &&
			wait_for_fsmonitor_query_barrier \
				"$ready" "$fsmonitor_query_pid" &&
			if test "$mutation" = attributes
			then
				test_write_lines "tracked text eol=crlf" \
					>cached/.gitattributes
			elif test "$mutation" = nested-attributes
			then
				test_write_lines "tracked text eol=crlf" \
					>cached/child-64/.gitattributes
			else
				test_write_lines "!junk.ignored" >cached/.gitignore
			fi &&
			GIT_OPTIONAL_LOCKS=0 \
				git -c core.fsmonitor=false \
					-c core.untrackedCache=false \
					-c core.trustctime=true \
					-c core.checkStat=default \
					status --porcelain=v2 >.git/expect &&
			printf x >"$resume" &&
			wait "$fsmonitor_query_pid" &&
			fsmonitor_query_pid= &&
			trap - 0 &&
			test_cmp .git/expect .git/actual &&
			test_grep "^1 \\.M .* cached/tracked$" .git/actual &&
			test_grep "^? sibling-1/visible$" .git/actual &&
			if test "$mutation" = attributes ||
				test "$mutation" = nested-attributes
			then
				if test "$mutation" = attributes
				then
					test_grep "^? cached/\\.gitattributes$" \
						.git/actual
				else
					test_grep \
						"^? cached/child-64/\\.gitattributes$" \
						.git/actual
				fi &&
				test_trace2_data fsmonitor \
					semantic/manifest-scan-count 2 \
					<.git/status.trace &&
				! test_trace2_data fsmonitor \
					semantic/manifest-directory-reused 1 \
					<.git/status.trace
			else
				test_grep "^1 \\.M .* cached/\\.gitignore$" \
					.git/actual &&
				test_grep "^? cached/junk\\.ignored$" .git/actual
			fi &&
			test_trace2_data fsmonitor token_closure/accepted 1 \
				<.git/status.trace
		) || return 1
	done
'

test_expect_success MACOS,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'plumbing diffs restore clean history lost by a foreign index writer' '
	test_when_finished "rm -rf plumbing-diff-history" &&
	test_create_repo plumbing-diff-history &&
	(
		cd plumbing-diff-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test-tool chmtime -120 tracked &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		for prime in first second third
		do
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
				git status --porcelain=v2 >.git/prime || return 1
		done &&
		test_must_be_empty .git/prime &&
		test_path_is_file .git/index.csts &&
		find .git -maxdepth 1 -type f -name "index.csh1.*" \
			>.git/checkpoints &&
		test_line_count = 1 .git/checkpoints &&

		rm .git/index &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			read-tree HEAD &&
		test_grep ! FSMN .git/index &&
		cp .git/index .git/index.before &&

		for diff_case in files index cached describe
		do
			case "$diff_case" in
			files) set -- diff-files ;;
			index) set -- diff-index HEAD -- ;;
			cached) set -- diff-index --cached HEAD -- ;;
			describe) set -- describe --dirty --tags ;;
			esac &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$diff_case.trace" \
				git "$@" >".git/$diff_case.actual" &&
			if test "$diff_case" = describe
			then
				test_grep "^base$" ".git/$diff_case.actual" &&
				test_trace2_data index refresh/sum_lstat 0 \
					<".git/$diff_case.trace"
			else
				test_must_be_empty ".git/$diff_case.actual"
			fi &&
			test_cmp_bin .git/index.before .git/index &&
			if test "$diff_case" = cached
			then
				test_trace2_data fsmonitor \
					semantic/scoped-reader-stat-fallback 1 \
					<".git/$diff_case.trace" &&
				! test_trace2_data fsmonitor \
					history/external-restored 1 \
					<".git/$diff_case.trace" &&
				test_region ! fsmonitor history_logical_digest \
					".git/$diff_case.trace"
			else
				test_trace2_data fsmonitor history/external-restored 1 \
					<".git/$diff_case.trace"
			fi &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count \
				<".git/$diff_case.trace" &&
			test_grep ! "\"label\":\"do_write_index\"" \
				".git/$diff_case.trace" || return 1
		done &&

		test_write_lines changed >tracked &&
		for diff_case in files index describe
		do
			case "$diff_case" in
			files) set -- diff-files -p ;;
			index) set -- diff-index -p HEAD -- ;;
			describe) set -- describe --dirty --tags ;;
			esac &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			GIT_TRACE2_EVENT="$PWD/.git/$diff_case-dirty.trace" \
				git "$@" >".git/$diff_case-dirty.actual" &&
			if test "$diff_case" = describe
			then
				test_grep "^base-dirty$" \
					".git/$diff_case-dirty.actual"
			else
				test_grep "^+changed$" \
					".git/$diff_case-dirty.actual"
			fi &&
			test_trace2_data fsmonitor history/external-restored 1 \
				<".git/$diff_case-dirty.trace" &&
			test_cmp_bin .git/index.before .git/index || return 1
		done
	)
'

test_expect_success MACOS,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'redundant disabled recursion preserves linked pre-commit diff proofs' '
	test_when_finished "rm -rf precommit-linked-proof precommit-linked-worktree" &&
	test_create_repo precommit-linked-proof &&
	(
		cd precommit-linked-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit sibling sibling &&
		git worktree add --detach ../precommit-linked-worktree HEAD &&
		git config index.skipHash true &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		worktree="$PWD/../precommit-linked-worktree" &&
		gitdir=$(git -C "$worktree" rev-parse --absolute-git-dir) &&
		test-tool chmtime -120 "$worktree/tracked" "$worktree/sibling" &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git -C "$worktree" update-index --refresh &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git -C "$worktree" update-index --fsmonitor &&
		GIT_INDEX_FILE="$gitdir/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git -C "$worktree" status --porcelain=v2 \
				>"$gitdir/prime" &&
		test_must_be_empty "$gitdir/prime" &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$gitdir/checkpoint.trace" \
			git -C "$worktree" status >"$gitdir/checkpoint.out" &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<"$gitdir/checkpoint.trace" &&
		test_fsmonitor_full_proof "$gitdir/index" paired &&
		test_trailing_hash "$gitdir/index" >"$gitdir/index.hash" &&
		test_oid zero >"$gitdir/zero" &&
		test_cmp "$gitdir/zero" "$gitdir/index.hash" &&
		find "$gitdir" -maxdepth 1 -type f -name "index.csh1.*" \
			>"$gitdir/checkpoints" &&
		find "$gitdir" -maxdepth 1 -type f -name "index.cswi.*" \
			>"$gitdir/witnesses" &&
		test_line_count = 1 "$gitdir/checkpoints" &&
		test_line_count = 1 "$gitdir/witnesses" &&
		checkpoint=$(cat "$gitdir/checkpoints") &&
		witness=$(cat "$gitdir/witnesses") &&
		cp "$checkpoint" "$gitdir/checkpoint.before" &&
		cp "$witness" "$gitdir/witness.before" &&

		test_write_lines dirty >"$worktree/tracked" &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$gitdir/checkout.trace" \
			git -C "$worktree" -c submodule.recurse=0 \
				checkout -- . &&
		test_region index do_write_index "$gitdir/checkout.trace" &&
		test_fsmonitor_full_proof "$gitdir/index" paired &&
		test_trailing_hash "$gitdir/index" >"$gitdir/index.hash" &&
		test_cmp "$gitdir/zero" "$gitdir/index.hash" &&
		test_cmp_bin "$gitdir/checkpoint.before" "$checkpoint" &&
		test_cmp_bin "$gitdir/witness.before" "$witness" &&
		cp "$gitdir/index" "$gitdir/index.before-diff" &&
		git -C "$worktree" --no-optional-locks \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			-c core.trustctime=true -c core.checkStat=default \
			diff --no-ext-diff --no-textconv --ignore-submodules \
				>"$gitdir/expect" &&
		test_cmp_bin "$gitdir/index.before-diff" "$gitdir/index" &&
		for attempt in first second
		do
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/diff-$attempt.trace" \
				git -C "$worktree" diff \
					--no-ext-diff --no-textconv --ignore-submodules \
						>"$gitdir/diff-$attempt.actual" &&
			test_cmp "$gitdir/expect" "$gitdir/diff-$attempt.actual" &&
			test_cmp_bin "$gitdir/index.before-diff" "$gitdir/index" &&
			test_cmp_bin "$gitdir/checkpoint.before" "$checkpoint" &&
			test_cmp_bin "$gitdir/witness.before" "$witness" &&
			test_grep ! "\"label\":\"history_logical_digest\"" \
				"$gitdir/diff-$attempt.trace" &&
			test_trace2_data fsmonitor config/coherent 1 \
				<"$gitdir/diff-$attempt.trace" &&
			! test_trace2_data fsmonitor history/external-restored 1 \
				<"$gitdir/diff-$attempt.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/diff-$attempt.trace" &&
			! test_region index do_write_index \
				"$gitdir/diff-$attempt.trace" || return 1
		done &&
		test_trace2_data fsmonitor config/coherent 1 \
			<"$gitdir/checkout.trace" &&

		git -C "$worktree" config submodule.recurse true &&
		GIT_INDEX_FILE="$gitdir/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git -C "$worktree" status --porcelain=v2 \
				>"$gitdir/enabled.prime" &&
		test_must_be_empty "$gitdir/enabled.prime" &&
		test_fsmonitor_full_proof "$gitdir/index" paired &&
		test_write_lines dirty >"$worktree/tracked" &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$gitdir/enabled.checkout.trace" \
			git -C "$worktree" -c submodule.recurse=false \
				checkout -- . &&
		test_trace2_data fsmonitor config/coherent 0 \
			<"$gitdir/enabled.checkout.trace" &&
		cp "$gitdir/index" "$gitdir/enabled.index" &&
		git -C "$worktree" --no-optional-locks \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			-c core.trustctime=true -c core.checkStat=default \
			diff --no-ext-diff --no-textconv --ignore-submodules \
				>"$gitdir/enabled.expect" &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git -C "$worktree" diff \
				--no-ext-diff --no-textconv --ignore-submodules \
					>"$gitdir/enabled.actual" &&
		test_cmp "$gitdir/enabled.expect" "$gitdir/enabled.actual" &&
		test_cmp_bin "$gitdir/enabled.index" "$gitdir/index"
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'global second closing-query change rejects verified subtree reuse' '
	test_when_finished "rm -rf second-query-global" &&
	test_create_repo second-query-global &&
	(
		cd second-query-global &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir cached untouched &&
		test_write_lines "*.ignored" >.gitignore &&
		test_write_lines "*.ignored" >cached/.gitignore &&
		printf "aaaa\n" >cached/tracked &&
		printf "untouched\n" >untouched/tracked &&
		test_write_lines ignored >cached/junk.ignored &&
		git add .gitignore cached/.gitignore cached/tracked \
			untouched/tracked &&
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
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			-c core.trustctime=true -c core.checkStat=default \
			status --porcelain=v2 >.git/expect &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCDC \
		GIT_TEST_FSMONITOR_QUERY_PATH=// \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_line_count = 1 .git/actual &&
		test_grep "^1 \.M .* cached/tracked$" .git/actual &&
		test_trace2_data fsmonitor apply/global-invalidation 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor semantic/manifest-scan-count 2 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor semantic/manifest-directory-reused 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/status.trace >.git/strong-invalidations &&
		test_line_count = 2 .git/strong-invalidations &&
		! test_trace2_data status \
			fsmonitor_token/reused-semantic-subtrees 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index
	)
'

test_expect_success MACOS,FSMONITOR_DAEMON,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'foreign index writers preserve unchanged worktree semantics' '
	test_when_finished "rm -rf foreign-semantic-history" &&
	test_when_finished \
		"git -C foreign-semantic-history fsmonitor--daemon stop 2>/dev/null || :" &&
	test_create_repo foreign-semantic-history &&
	(
		cd foreign-semantic-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir existing &&
		test_commit base existing/tracked &&
		test_commit retained existing/retained &&
		test-tool chmtime -120 existing/tracked existing/retained &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		git fsmonitor--daemon start --start-timeout=10 &&
		git update-index --fsmonitor &&
		for prime in first second third
		do
			git status --porcelain=v2 >.git/prime || return 1
		done &&
		find .git -maxdepth 1 -type f -name "index.cswi.*" \
			>.git/witnesses &&
		test_line_count = 1 .git/witnesses &&
		cat >.git/foreign-writer.pl <<-\EOF &&
		use Digest::SHA qw(sha1 sha256);
		binmode STDIN;
		binmode STDOUT;
		local $/;
		my $index = <STDIN>;
		my $name = $ARGV[0];
		my $rawsz = $name eq "sha256" ? 32 : 20;
		for my $extension ("FSUC", "FSCF") {
			my $offset = index($index, $extension);
			next if $offset < 0;
			my $size = unpack("N", substr($index, $offset + 4, 4));
			substr($index, $offset, 8 + $size, "");
		}
		my $payload = substr($index, 0, -$rawsz);
		print $payload,
			$name eq "sha256" ? sha256($payload) : sha1($payload);
		EOF

		test_write_lines changed >existing/tracked &&
		git update-index --no-fsmonitor-valid existing/retained &&
		git update-index --add existing/tracked &&
		perl .git/foreign-writer.pl "$(test_oid algo)" \
			<.git/index >.git/index.foreign &&
		mv .git/index.foreign .git/index &&
		test_grep ! FSCF .git/index &&
		git -c core.fsmonitor=false --no-optional-locks \
			status --porcelain=v2 >.git/existing.expect &&
		test_grep "^1 M\. .* existing/tracked$" .git/existing.expect &&
		GIT_TRACE2_EVENT="$PWD/.git/existing.trace" \
			git status --porcelain=v2 >.git/existing &&
		test_grep "^1 M\. .* existing/tracked$" .git/existing &&
		test_trace2_data fsmonitor \
			history/external-semantic-restored 1 <.git/existing.trace &&
		test_trace2_data fsmonitor \
			history/external-untracked-restored 1 <.git/existing.trace &&
		test_trace2_data fsmonitor \
			history/external-tracked-restored 1 <.git/existing.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count \
			<.git/existing.trace &&
		! test_trace2_data index preload/bulk_useful \
			<.git/existing.trace &&

		mkdir newdir &&
		test_write_lines new >newdir/tracked &&
		git update-index --add newdir/tracked &&
		perl .git/foreign-writer.pl "$(test_oid algo)" \
			<.git/index >.git/index.foreign &&
		mv .git/index.foreign .git/index &&
		test_grep ! FSCF .git/index &&
		GIT_TRACE2_EVENT="$PWD/.git/newdir.trace" \
			git status --porcelain=v2 >.git/newdir &&
		test_grep "^1 A\. .* newdir/tracked$" .git/newdir &&
		test_trace2_data fsmonitor \
			history/external-semantic-restored 1 <.git/newdir.trace &&
		test_trace2_data fsmonitor \
			history/external-untracked-restored 1 <.git/newdir.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count \
			<.git/newdir.trace &&
		! test_trace2_data index preload/bulk_useful \
			<.git/newdir.trace &&

		mkdir existing/retired-directory &&
		test_write_lines transient >existing/retired-directory/file &&
		rm existing/retired-directory/file &&
		rmdir existing/retired-directory &&
		test_write_lines changed-again >existing/tracked &&
		git update-index --add existing/tracked &&
		perl .git/foreign-writer.pl "$(test_oid algo)" \
			<.git/index >.git/index.foreign &&
		mv .git/index.foreign .git/index &&
		GIT_TRACE2_EVENT="$PWD/.git/retired.trace" \
			git status --porcelain=v2 >.git/retired &&
		test_grep "^1 M\. .* existing/tracked$" .git/retired &&
		test_trace2_data fsmonitor \
			history/external-semantic-restored 1 <.git/retired.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count \
			<.git/retired.trace &&
		! test_trace2_data index preload/bulk_useful \
			<.git/retired.trace &&

		test_write_lines "* text" >existing/.gitattributes &&
		git update-index --add existing/.gitattributes &&
		perl .git/foreign-writer.pl "$(test_oid algo)" \
			<.git/index >.git/index.foreign &&
		mv .git/index.foreign .git/index &&
		GIT_TRACE2_EVENT="$PWD/.git/attributes.trace" \
			git status --porcelain=v2 >.git/attributes &&
		test_grep "^1 A\. .* existing/.gitattributes$" \
			.git/attributes &&
		! test_trace2_data fsmonitor \
			history/external-semantic-restored <.git/attributes.trace &&
		test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/attributes.trace &&

		mkdir guarded &&
		test_write_lines "* text" >guarded/.gitattributes &&
		test_write_lines guarded >guarded/tracked &&
		git update-index --add guarded/tracked &&
		perl .git/foreign-writer.pl "$(test_oid algo)" \
			<.git/index >.git/index.foreign &&
		mv .git/index.foreign .git/index &&
		GIT_TRACE2_EVENT="$PWD/.git/guarded.trace" \
			git status --porcelain=v2 >.git/guarded &&
		test_grep "^1 A\. .* guarded/tracked$" .git/guarded &&
		! test_trace2_data fsmonitor \
			history/external-semantic-restored <.git/guarded.trace &&
		test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/guarded.trace
	)
'

test_expect_success MACOS,FSMONITOR_DAEMON,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'branch switches preserve existing authenticated index proofs' '
	test_when_finished "rm -rf switch-authenticated-history" &&
	test_when_finished \
		"git -C switch-authenticated-history fsmonitor--daemon stop 2>/dev/null || :" &&
	test_create_repo switch-authenticated-history &&
	(
		cd switch-authenticated-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir -p api/existing &&
		test_write_lines "*.txt text" >api/.gitattributes &&
		test_write_lines base >api/existing/tracked &&
		for sibling in $(test_seq 1 24)
		do
			mkdir "api/sibling-$sibling" &&
			test_write_lines retained \
				>"api/sibling-$sibling/tracked" || return 1
		done &&
		git add api &&
		git commit -m base &&
		initial_branch=$(git symbolic-ref --short HEAD) &&
		git switch -c replace-only &&
		test_write_lines replacement >api/existing/tracked &&
		git add api/existing/tracked &&
		git commit -m replacement &&
		git switch "$initial_branch" &&
		git switch -c alternate &&
		mkdir api/new-directory &&
		mkdir api/new-directory/__pycache__ &&
		test_write_lines existing >api/existing/added.txt &&
		test_write_lines new >api/new-directory/added.txt &&
		test_write_lines ignored \
			>api/new-directory/__pycache__/hidden.pyc &&
		git config core.excludesFile "$PWD/.git/test-excludes" &&
		test_write_lines "__pycache__/" >.git/test-excludes &&
		git add api/existing/added.txt api/new-directory/added.txt &&
		git commit -m alternate &&
		git switch "$initial_branch" &&
		test-tool chmtime -120 api/.gitattributes api/existing/tracked \
			api/sibling-*/tracked &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config index.recordEndOfIndexEntries false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		git fsmonitor--daemon start --start-timeout=10 &&
		git update-index --fsmonitor &&
		for prime in first second third
		do
			git status --porcelain=v2 >.git/prime || return 1
		done &&
		test_must_be_empty .git/prime &&
		find .git -maxdepth 1 -type f -name "index.cswi.*" \
			>.git/witnesses &&
		test_line_count = 1 .git/witnesses &&
		for branch in replace-only "$initial_branch" \
			alternate "$initial_branch"
		do
			GIT_TRACE2_EVENT="$PWD/.git/switch-$branch.trace" \
			GIT_TRACE2_EVENT_NESTING=10 \
				git switch "$branch" &&
			test_trace2_data fsmonitor history/semantic-transferred 1 \
				<".git/switch-$branch.trace" &&
			if test "$branch" = alternate
			then
				test_trace2_data fsmonitor \
					history/untracked-paired-new-directory-invalidated 2 \
					<".git/switch-$branch.trace" &&
				test_trace2_data fsmonitor \
					history/untracked-paired-transfer 1 \
					<".git/switch-$branch.trace" &&
				test_grep FSUC .git/index &&
				test_grep FSCF .git/index
			else
				test_trace2_data fsmonitor \
					history/untracked-paired-transfer 1 \
					<".git/switch-$branch.trace" &&
				test_grep FSUC .git/index
			fi &&
			git -c core.fsmonitor=false --no-optional-locks \
				status --porcelain=v2 >.git/expect &&
			GIT_TRACE2_EVENT="$PWD/.git/status-$branch.trace" \
			GIT_TRACE2_EVENT_NESTING=10 \
			GIT_TRACE2_PERF="$PWD/.git/status-$branch.perf" \
				git status --porcelain=v2 >.git/actual &&
			test_cmp .git/expect .git/actual &&
			test_trace2_data fsmonitor config/coherent 1 \
				<".git/status-$branch.trace" &&
			! test_trace2_data fsmonitor config/invalid-extension 1 \
				<".git/status-$branch.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count \
				<".git/status-$branch.trace" &&
			! test_trace2_data index preload/bulk_useful \
				<".git/status-$branch.trace" &&
			if test "$branch" = replace-only
			then
				test_trace2_data fsmonitor \
					checkout/untracked-replacement-targeted 1 \
					<".git/switch-$branch.trace" &&
				visited_dirs=$(sed -n \
					"s/.*directories-visited:\\([0-9][0-9]*\\).*/\\1/p" \
					".git/status-$branch.perf") &&
				test "$visited_dirs" -lt 12
			elif test "$branch" = alternate
			then
				! test_trace2_data fsmonitor \
					history/external-untracked-restored 1 \
					<".git/status-$branch.trace" &&
				test_grep FSUC .git/index &&
				visited_dirs=$(sed -n \
					"s/.*directories-visited:\\([0-9][0-9]*\\).*/\\1/p" \
					".git/status-$branch.perf") &&
				test "$visited_dirs" -lt 12
			fi || return 1
		done &&

		cat >.git/duplicate-fscf.pl <<-\EOF &&
		use Digest::SHA qw(sha1 sha256);
		binmode STDIN;
		binmode STDOUT;
		local $/;
		my $index = <STDIN>;
		my $name = $ARGV[0];
		my $rawsz = $name eq "sha256" ? 32 : 20;
		my $payload = substr($index, 0, -$rawsz);
		my $offset = index($payload, "FSCF");
		die "index has no FSCF extension\n" if $offset < 0;
		my $size = unpack("N", substr($payload, $offset + 4, 4));
		$payload .= substr($payload, $offset, 8 + $size);
		print $payload,
			$name eq "sha256" ? sha256($payload) : sha1($payload);
		EOF
		perl .git/duplicate-fscf.pl "$(test_oid algo)" \
			<.git/index >.git/index.duplicate &&
		mv .git/index.duplicate .git/index &&
		GIT_TRACE2_EVENT="$PWD/.git/duplicate.trace" \
			git status --porcelain=v2 >.git/duplicate &&
		test_cmp .git/expect .git/duplicate &&
		test_trace2_data fsmonitor config/invalid-extension 1 \
			<.git/duplicate.trace &&
		! test_trace2_data fsmonitor history/external-restored 1 \
			<.git/duplicate.trace &&
		! test_trace2_data fsmonitor history/external-semantic-restored 1 \
			<.git/duplicate.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'branch switches preserve unchanged worktree semantics' '
	test_when_finished "rm -rf switch-semantic-history" &&
	test_create_repo switch-semantic-history &&
	(
		cd switch-semantic-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_write_lines changed >tracked &&
		git add tracked &&
		git commit -m changed &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/switch.trace" \
			git switch --detach HEAD^ &&
		test_trace2_data fsmonitor history/semantic-transferred 1 \
			<.git/switch.trace &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/status.trace
	)
'

test_expect_success MACOS,FSMONITOR_DAEMON,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'stash creation restores linked external clean history' '
	test_when_finished "rm -rf stash-linked-history stash-linked-worktree" &&
	test_when_finished \
		"git -C stash-linked-worktree fsmonitor--daemon stop 2>/dev/null || :" &&
	test_create_repo stash-linked-history &&
	(
		cd stash-linked-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir existing &&
		test_commit base existing/tracked &&
		test_commit sibling existing/sibling &&
		git worktree add --detach ../stash-linked-worktree HEAD &&
		worktree="$PWD/../stash-linked-worktree" &&
		gitdir=$(git -C "$worktree" rev-parse --absolute-git-dir) &&
		git -C "$worktree" config core.autocrlf false &&
		git -C "$worktree" config core.untrackedCache true &&
		git -C "$worktree" config core.fsmonitor true &&
		git -C "$worktree" config filter.lfs.clean \
			"git-lfs clean -- %f" &&
		git -C "$worktree" config filter.lfs.smudge \
			"git-lfs smudge -- %f" &&
		git -C "$worktree" config filter.lfs.process \
			"git-lfs filter-process" &&
		git -C "$worktree" config filter.lfs.required true &&
		git -C "$worktree" config index.recordEndOfIndexEntries false &&
		test-tool chmtime -120 \
			"$worktree/existing/tracked" "$worktree/existing/sibling" &&
		git -C "$worktree" fsmonitor--daemon start --start-timeout=10 &&
		git -C "$worktree" update-index --refresh &&
		git -C "$worktree" update-index --fsmonitor &&
		git -C "$worktree" status --porcelain=v2 >"$gitdir/prime" &&
		test_must_be_empty "$gitdir/prime" &&
		find "$gitdir" -maxdepth 1 -type f -name "index.csh1.*" \
			>"$gitdir/checkpoints" &&
		test_line_count = 1 "$gitdir/checkpoints" &&
		find "$gitdir" -maxdepth 1 -type f -name "index.cswi.*" \
			>"$gitdir/witnesses" &&
		test_line_count = 1 "$gitdir/witnesses" &&
		test_write_lines staged >"$worktree/existing/staged" &&
		test-tool chmtime =-120 "$worktree/existing/staged" &&
		git -C "$worktree" add existing/staged &&
		GIT_INDEX_FILE="$gitdir/index" \
			git -C "$worktree" status --porcelain=v2 \
				>"$gitdir/physical-prime" &&
		test_grep FSMN "$gitdir/index" &&
		test_grep UNTR "$gitdir/index" &&
		test_grep FSUC "$gitdir/index" &&
		test_grep FSCF "$gitdir/index" &&
		cat >"$gitdir/remove-proofs.pl" <<-\EOF &&
		use Digest::SHA qw(sha1 sha256);
		binmode STDIN;
		binmode STDOUT;
		local $/;
		my $index = <STDIN>;
		my $rawsz = $ARGV[0] eq "sha256" ? 32 : 20;
		for my $extension ("FSUC", "FSCF") {
			my $offset = index($index, $extension);
			next if $offset < 0;
			my $size = unpack("N", substr($index, $offset + 4, 4));
			substr($index, $offset, 8 + $size, "");
		}
		my $payload = substr($index, 0, -$rawsz);
		print $payload, $rawsz == 32 ? sha256($payload) : sha1($payload);
		EOF
		perl "$gitdir/remove-proofs.pl" "$(test_oid algo)" \
			<"$gitdir/index" >"$gitdir/index.foreign" &&
		mv "$gitdir/index.foreign" "$gitdir/index" &&
		test_grep FSMN "$gitdir/index" &&
		test_grep UNTR "$gitdir/index" &&
		test_grep ! FSUC "$gitdir/index" &&
		test_grep ! FSCF "$gitdir/index" &&
		checkpoint=$(cat "$gitdir/checkpoints") &&
		cp "$checkpoint" "$gitdir/checkpoint.valid" &&
		for corruption in missing malformed wrong-namespace
		do
			rm -f "$checkpoint" "$checkpoint.wrong" &&
			case "$corruption" in
			missing) : ;;
			malformed) printf "%s\n" corrupt >"$checkpoint" ;;
			wrong-namespace)
				cp "$gitdir/checkpoint.valid" "$checkpoint.wrong" ;;
			esac &&
			GIT_OPTIONAL_LOCKS=0 \
				git -C "$worktree" -c core.fsmonitor=false \
					-c core.untrackedCache=false diff \
					>"$gitdir/$corruption.expect" &&
			for locking in readonly default
			do
				trace="$gitdir/$corruption-$locking.trace" &&
				cp "$gitdir/index" \
					"$gitdir/$corruption-$locking.before" &&
				if test "$locking" = readonly
				then
					GIT_OPTIONAL_LOCKS=0 \
					GIT_TRACE2_EVENT="$trace" \
						git -C "$worktree" diff \
							>"$gitdir/$corruption.actual"
				else
					sane_unset GIT_OPTIONAL_LOCKS &&
					GIT_TRACE2_EVENT="$trace" \
						git -C "$worktree" diff \
							>"$gitdir/$corruption.actual"
				fi &&
				test_cmp "$gitdir/$corruption.expect" \
					"$gitdir/$corruption.actual" &&
				test_cmp_bin \
					"$gitdir/$corruption-$locking.before" \
					"$gitdir/index" &&
				test_trace2_data fsmonitor config/coherent 0 \
					<"$trace" &&
				test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 <"$trace" &&
				test_grep ! "\"label\":\"history_logical_digest\"" \
					"$trace" &&
				! test_region index do_write_index "$trace" ||
					return 1
			done || return 1
		done &&
		rm -f "$checkpoint.wrong" &&
		cp "$gitdir/checkpoint.valid" "$checkpoint" &&
		for command in diff diff-files diff-index
		do
			case "$command" in
			diff-index) set -- "$command" HEAD ;;
			*) set -- "$command" ;;
			esac &&
			GIT_OPTIONAL_LOCKS=0 \
				git -C "$worktree" -c core.fsmonitor=false \
					-c core.untrackedCache=false "$@" \
					>"$gitdir/$command.expect" &&
			cp "$gitdir/index" "$gitdir/$command.before" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_PRELOAD_INDEX=1 \
			GIT_TRACE2_EVENT="$gitdir/$command.trace" \
				git -C "$worktree" "$@" \
					>"$gitdir/$command.actual" &&
			test_cmp "$gitdir/$command.expect" \
				"$gitdir/$command.actual" &&
			test_cmp_bin "$gitdir/$command.before" "$gitdir/index" &&
			{
				test_trace2_data fsmonitor history/external-restored 1 \
					<"$gitdir/$command.trace" ||
				test_trace2_data fsmonitor \
					history/external-semantic-restored 1 \
					<"$gitdir/$command.trace"
			} &&
			test_trace2_data fsmonitor config/coherent 1 \
				<"$gitdir/$command.trace" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/$command.trace" &&
			! test_trace2_data index preload/sum_lstat \
				"[2-9][0-9]*" <"$gitdir/$command.trace" &&
			! test_trace2_data index preload/sum_lstat \
				"1[0-9][0-9]*" <"$gitdir/$command.trace" ||
				return 1
		done &&
		test_write_lines dirty >"$worktree/existing/tracked" &&
		for run in first second
		do
			GIT_TRACE2_EVENT="$gitdir/stash-$run.trace" \
				git -C "$worktree" stash create \
					"cmux last turn baseline" \
					>"$gitdir/stash-$run" &&
			test_file_not_empty "$gitdir/stash-$run" &&
			! test_trace2_data fsmonitor config/coherent 0 \
				<"$gitdir/stash-$run.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/stash-$run.trace" &&
			! test_trace2_data fsmonitor untracked/proof-missing 1 \
				<"$gitdir/stash-$run.trace" &&
			if test "$run" = first
			then
				{
					test_trace2_data fsmonitor history/external-restored 1 \
						<"$gitdir/stash-$run.trace" ||
					test_trace2_data fsmonitor \
						history/external-semantic-restored 1 \
						<"$gitdir/stash-$run.trace"
				} &&
				test_region index do_write_index \
					"$gitdir/stash-$run.trace"
			fi &&
			test_grep FSUC "$gitdir/index" &&
			test_grep FSCF "$gitdir/index" &&
			cp "$gitdir/index" "$gitdir/index.before-status" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TRACE2_EVENT="$gitdir/status-$run.trace" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/status-$run" &&
			test_cmp_bin "$gitdir/index.before-status" "$gitdir/index" &&
			test_grep "^1 A\\. .* existing/staged$" \
				"$gitdir/status-$run" &&
			test_grep "^1 \\.M .* existing/tracked$" \
				"$gitdir/status-$run" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<"$gitdir/status-$run.trace" || return 1
		done &&
		rm -f "$checkpoint" &&
		GIT_TRACE2_EVENT="$gitdir/reissue-checkpoint.trace" \
			git -C "$worktree" status --porcelain=v2 \
				>"$gitdir/reissue-checkpoint" &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<"$gitdir/reissue-checkpoint.trace" &&
		test_path_is_file "$checkpoint" &&
		test_fsmonitor_full_proof "$gitdir/index" paired &&
		git -C "$worktree" config filter.lfs.process "" &&
		git -C "$worktree" config filter.lfs.clean false &&
		test_write_lines "existing/tracked filter=lfs" \
			>"$worktree/.gitattributes" &&
		cp "$gitdir/index" "$gitdir/active-filter.before" &&
		test_must_fail env GIT_OPTIONAL_LOCKS=0 \
			GIT_TRACE2_EVENT="$gitdir/active-filter.trace" \
			git -C "$worktree" diff \
				>"$gitdir/active-filter.out" \
				2>"$gitdir/active-filter.err" &&
		test_grep "clean filter .lfs. failed" \
			"$gitdir/active-filter.err" &&
		test_cmp_bin "$gitdir/active-filter.before" "$gitdir/index" &&
		! test_trace2_data fsmonitor history/external-restored 1 \
			<"$gitdir/active-filter.trace" &&
		! test_trace2_data fsmonitor history/external-semantic-restored 1 \
			<"$gitdir/active-filter.trace"
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'update-index doctor permutations retain authenticated proofs' '
	test_when_finished "rm -rf doctor-update-proof doctor-update-linked" &&
	test_create_repo doctor-update-proof &&
	(
		cd doctor-update-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git worktree add --detach ../doctor-update-linked HEAD &&
		test-tool chmtime -120 tracked \
			../doctor-update-linked/tracked &&
		git update-index --refresh &&
		git -C ../doctor-update-linked update-index --refresh &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		cat >.git/remove-doctor-proofs.pl <<-\EOF &&
		use Digest::SHA qw(sha1 sha256);
		binmode STDIN;
		binmode STDOUT;
		local $/;
		my $index = <STDIN>;
		my $rawsz = $ARGV[0] eq "sha256" ? 32 : 20;
		for my $name ("FSUC", "FSCF") {
			my $offset = index($index, $name);
			die "missing $name extension\n" if $offset < 0;
			my $size = unpack("N", substr($index, $offset + 4, 4));
			substr($index, $offset, 8 + $size, "");
		}
		my $payload = substr($index, 0, -$rawsz);
		print $payload, $rawsz == 32 ? sha256($payload) : sha1($payload);
		EOF
		for worktree in "$PWD" "$PWD/../doctor-update-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/checkpoint.trace" \
				git -C "$worktree" status --short \
					>"$gitdir/checkpoint" &&
			test_must_be_empty "$gitdir/checkpoint" &&
			test_trace2_data fsmonitor history/external-stored 1 \
				<"$gitdir/checkpoint.trace" &&
			find "$gitdir" -maxdepth 1 -type f \
				-name "index.csh1.*" >"$gitdir/checkpoints" &&
			test_line_count = 1 "$gitdir/checkpoints" &&
			if test_have_prereq MACOS
			then
				find "$gitdir" -maxdepth 1 -type f \
					-name "index.cswi.*" >"$gitdir/witnesses" &&
				test_line_count = 1 "$gitdir/witnesses" || return 1
			fi &&
			for mode in healthy history
			do
				for order in normal reverse
				do
					if test "$mode" = history
					then
						perl "$PWD/.git/remove-doctor-proofs.pl" \
							"$(test_oid algo)" <"$gitdir/index" \
							>"$gitdir/index.foreign" &&
						mv "$gitdir/index.foreign" \
							"$gitdir/index" &&
						test_grep ! FSUC "$gitdir/index" &&
						test_grep ! FSCF "$gitdir/index" || return 1
					fi &&
					if test "$order" = normal
					then
						set -- --untracked-cache --force-write-index
					else
						set -- --force-write-index --untracked-cache
					fi &&
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					GIT_TRACE2_EVENT="$gitdir/$mode-$order.trace" \
						git -C "$worktree" update-index "$@" &&
					test_grep FSUC "$gitdir/index" &&
					test_grep FSCF "$gitdir/index" &&
					! test_trace2_data fsmonitor config/coherent 0 \
						<"$gitdir/$mode-$order.trace" &&
					! test_trace2_data fsmonitor \
						semantic/manifest-scan-count 1 \
						<"$gitdir/$mode-$order.trace" || return 1
				done || return 1
			done || return 1
		done
	)
'

test_expect_success FSMONITOR_DAEMON,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'provider restarts keep diff and untracked status correct' '
	test_when_finished "rm -rf daemon-diff-reset daemon-diff-linked" &&
	test_when_finished \
		"git -C daemon-diff-reset fsmonitor--daemon stop 2>/dev/null || :" &&
	test_when_finished \
		"git -C daemon-diff-linked fsmonitor--daemon stop 2>/dev/null || :" &&
	test_create_repo daemon-diff-reset &&
	(
		cd daemon-diff-reset &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir -p cached/deep &&
		test_commit base cached/deep/tracked &&
		git worktree add --detach ../daemon-diff-linked HEAD &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		git config filter.lfs.clean "git-lfs clean -- %f" &&
		git config filter.lfs.smudge "git-lfs smudge -- %f" &&
		git config filter.lfs.process "git-lfs filter-process" &&
		git config filter.lfs.required true &&
		for worktree in "$PWD" "$PWD/../daemon-diff-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			git -C "$worktree" fsmonitor--daemon start \
				--start-timeout=10 &&
			git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			test_grep FSMN "$gitdir/index" &&
			test_grep FSUC "$gitdir/index" &&
			test_grep FSCF "$gitdir/index" &&
			git -C "$worktree" fsmonitor--daemon stop &&
			test-tool chmtime =-60 \
				"$worktree/cached/deep/tracked" &&
			git -C "$worktree" fsmonitor--daemon start \
				--start-timeout=10 &&
			cp "$gitdir/index" "$gitdir/locked.index" &&
			: >"$gitdir/index.lock" &&
			GIT_TRACE2_EVENT="$gitdir/locked.trace" \
				git -C "$worktree" diff >"$gitdir/locked" &&
			rm -f "$gitdir/index.lock" &&
			test_must_be_empty "$gitdir/locked" &&
			test_cmp_bin "$gitdir/locked.index" "$gitdir/index" &&
			! test_region index do_write_index \
				"$gitdir/locked.trace" &&
			GIT_TRACE2_EVENT="$gitdir/diff.trace" \
				git -C "$worktree" diff >"$gitdir/diff" &&
			test_must_be_empty "$gitdir/diff" &&
			test_trace2_data fsm_client query/trivial-response 1 \
				<"$gitdir/diff.trace" &&
			test_fsmonitor_full_proof "$gitdir/index" paired &&
			cp "$gitdir/index" "$gitdir/readonly.index" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TRACE2_EVENT="$gitdir/readonly.trace" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/readonly" &&
			test_must_be_empty "$gitdir/readonly" &&
			test_cmp_bin "$gitdir/readonly.index" "$gitdir/index" &&
			test_trace2_data fsmonitor config/coherent 1 \
				<"$gitdir/readonly.trace" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/readonly.trace" &&
			! test_trace2_data dir preload_untracked_cache/dirs \
				"[2-9][0-9]*" \
				<"$gitdir/readonly.trace" &&
			! test_trace2_data dir preload_untracked_cache/dirs \
				"1[0-9][0-9]*" \
				<"$gitdir/readonly.trace" &&
			! test_region index do_write_index \
				"$gitdir/readonly.trace" &&
			git -C "$worktree" fsmonitor--daemon stop &&
			test_write_lines hidden \
				>"$worktree/cached/deep/hidden-during-restart" &&
			test_write_lines "tracked -text" \
				>"$worktree/cached/deep/.gitattributes" &&
			test-tool chmtime =-30 \
				"$worktree/cached/deep/tracked" &&
			git -C "$worktree" fsmonitor--daemon start \
				--start-timeout=10 &&
			git -C "$worktree" diff >"$gitdir/hidden-diff" &&
			test_must_be_empty "$gitdir/hidden-diff" &&
			GIT_OPTIONAL_LOCKS=0 \
				git -C "$worktree" -c core.untrackedCache=false \
					status --porcelain=v2 >"$gitdir/hidden.expect" &&
			GIT_OPTIONAL_LOCKS=0 \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/hidden.actual" &&
			test_cmp "$gitdir/hidden.expect" \
				"$gitdir/hidden.actual" &&
			test_grep "^? cached/deep/hidden-during-restart$" \
				"$gitdir/hidden.actual" &&
			test_grep "^? cached/deep/\\.gitattributes$" \
				"$gitdir/hidden.actual" &&
			git -C "$worktree" fsmonitor--daemon stop || return 1
		done
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'tracked-only status never authenticates stale untracked history' '
	test_when_finished "rm -rf tracked-only-reset tracked-only-linked" &&
	test_create_repo tracked-only-reset &&
	(
		cd tracked-only-reset &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir -p cached/deep &&
		test_commit base cached/deep/tracked &&
		git worktree add --detach ../tracked-only-linked HEAD &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		for worktree in "$PWD" "$PWD/../tracked-only-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			test_grep FSUC "$gitdir/index" &&
			test_write_lines unexpected \
				>"$worktree/cached/deep/new-untracked" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/tracked-only.trace" \
				git -C "$worktree" status --porcelain=v2 \
					--untracked-files=no >"$gitdir/tracked-only" &&
			test_must_be_empty "$gitdir/tracked-only" &&
			test_trace2_data fsm_client query/trivial-response 1 \
				<"$gitdir/tracked-only.trace" &&
			test_trace2_data fsmonitor \
				untracked/provider-reset-pending 1 \
				<"$gitdir/tracked-only.trace" &&
			test_fsmonitor_full_proof "$gitdir/index" pending &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" -c core.untrackedCache=false \
					status --porcelain=v2 >"$gitdir/expect" &&
			test_grep "^? cached/deep/new-untracked$" \
				"$gitdir/expect" &&
			for pass in first second
			do
				cp "$gitdir/index" "$gitdir/readonly-$pass.index" &&
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/readonly-$pass.trace" \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/readonly-$pass" &&
				test_cmp "$gitdir/expect" \
					"$gitdir/readonly-$pass" &&
				test_cmp_bin "$gitdir/readonly-$pass.index" \
					"$gitdir/index" &&
				test_trace2_data fsmonitor config/coherent 1 \
					<"$gitdir/readonly-$pass.trace" &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<"$gitdir/readonly-$pass.trace" &&
				! test_region index do_write_index \
					"$gitdir/readonly-$pass.trace" || return 1
			done &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/writable" &&
			test_cmp "$gitdir/expect" "$gitdir/writable" || return 1
		done
	)
'

test_expect_success FSMONITOR_DAEMON,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'tracked-only status preserves new files after daemon restart' '
	test_when_finished "rm -rf daemon-tracked-only daemon-tracked-only-linked" &&
	test_when_finished \
		"git -C daemon-tracked-only fsmonitor--daemon stop 2>/dev/null || :" &&
	test_when_finished \
		"git -C daemon-tracked-only-linked fsmonitor--daemon stop 2>/dev/null || :" &&
	test_create_repo daemon-tracked-only &&
	(
		cd daemon-tracked-only &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir -p cached/deep &&
		test_commit base cached/deep/tracked &&
		git worktree add --detach ../daemon-tracked-only-linked HEAD &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		for worktree in "$PWD" "$PWD/../daemon-tracked-only-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			git -C "$worktree" fsmonitor--daemon start \
				--start-timeout=10 &&
			git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			test_grep FSUC "$gitdir/index" &&
			git -C "$worktree" fsmonitor--daemon stop &&
			test_write_lines unexpected \
				>"$worktree/cached/deep/new-untracked" &&
			git -C "$worktree" fsmonitor--daemon start \
				--start-timeout=10 &&
			GIT_TRACE2_EVENT="$gitdir/tracked-only.trace" \
				git -C "$worktree" status --porcelain=v2 \
					--untracked-files=no >"$gitdir/tracked-only" &&
			test_must_be_empty "$gitdir/tracked-only" &&
			test_trace2_data fsm_client query/trivial-response 1 \
				<"$gitdir/tracked-only.trace" &&
			test_trace2_data fsmonitor \
				untracked/provider-reset-pending 1 \
				<"$gitdir/tracked-only.trace" &&
			test_fsmonitor_full_proof "$gitdir/index" pending &&
			GIT_OPTIONAL_LOCKS=0 \
				git -C "$worktree" -c core.untrackedCache=false \
					status --porcelain=v2 >"$gitdir/expect" &&
			test_grep "^? cached/deep/new-untracked$" \
				"$gitdir/expect" &&
			for pass in first second
			do
				cp "$gitdir/index" "$gitdir/readonly-$pass.index" &&
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TRACE2_EVENT="$gitdir/readonly-$pass.trace" \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/readonly-$pass" &&
				test_cmp "$gitdir/expect" \
					"$gitdir/readonly-$pass" &&
				test_cmp_bin "$gitdir/readonly-$pass.index" \
					"$gitdir/index" &&
				test_trace2_data fsmonitor config/coherent 1 \
					<"$gitdir/readonly-$pass.trace" &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<"$gitdir/readonly-$pass.trace" &&
				! test_region index do_write_index \
					"$gitdir/readonly-$pass.trace" || return 1
			done &&
			git -C "$worktree" status --porcelain=v2 \
				>"$gitdir/writable" &&
			test_cmp "$gitdir/expect" "$gitdir/writable" &&
			git -C "$worktree" fsmonitor--daemon stop || return 1
		done
	)
'

test_expect_success PTHREADS,UNTRACKED_CACHE,SHA1 'load cache-tree and untracked-cache extensions in parallel' '
	test_create_repo parallel-extensions &&
	(
		cd parallel-extensions &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir dir &&
		echo tracked >dir/tracked &&
		git config index.threads 4 &&
		git add dir/tracked &&
		git commit -m initial &&
		git config core.untrackedCache true &&
		git status --porcelain >/dev/null &&
		echo modified >>dir/tracked &&
		echo untracked >dir/untracked &&
		GIT_TEST_INDEX_THREADS=1 \
		git --no-optional-locks status --porcelain >"$TRASH_DIRECTORY/parallel-serial.status" &&
		GIT_TEST_INDEX_THREADS=1 \
		test-tool dump-cache-tree >"$TRASH_DIRECTORY/parallel-serial.tree" &&
		GIT_TEST_INDEX_THREADS=1 \
		test-tool dump-untracked-cache >"$TRASH_DIRECTORY/parallel-serial.untracked" &&
		GIT_TEST_INDEX_THREADS=4 \
		GIT_TEST_PARALLEL_INDEX_EXTENSIONS=1 \
		GIT_TRACE2_EVENT="$TRASH_DIRECTORY/parallel-extensions.trace" \
		git --no-optional-locks status --porcelain >"$TRASH_DIRECTORY/parallel-parallel.status" &&
		GIT_TEST_INDEX_THREADS=4 GIT_TEST_PARALLEL_INDEX_EXTENSIONS=1 \
		test-tool dump-cache-tree >"$TRASH_DIRECTORY/parallel-parallel.tree" &&
		GIT_TEST_INDEX_THREADS=4 GIT_TEST_PARALLEL_INDEX_EXTENSIONS=1 \
		test-tool dump-untracked-cache >"$TRASH_DIRECTORY/parallel-parallel.untracked" &&
		test_grep "extension/parallel/tree-untracked" \
			"$TRASH_DIRECTORY/parallel-extensions.trace" &&
		test_cmp "$TRASH_DIRECTORY/parallel-serial.status" \
			 "$TRASH_DIRECTORY/parallel-parallel.status" &&
		test_cmp "$TRASH_DIRECTORY/parallel-serial.tree" \
			 "$TRASH_DIRECTORY/parallel-parallel.tree" &&
		test_cmp "$TRASH_DIRECTORY/parallel-serial.untracked" \
			 "$TRASH_DIRECTORY/parallel-parallel.untracked"
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'untracked provider events do not disappear across an index rewrite' '
	test_when_finished "rm -rf untracked-provider-index-rewrite" &&
	test_create_repo untracked-provider-index-rewrite &&
	(
		cd untracked-provider-index-rewrite &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir cached &&
		test_write_lines tracked >cached/tracked &&
		test_write_lines outside >outside &&
		git add cached/tracked outside &&
		git commit -qm base &&
		test-tool chmtime -120 cached/tracked outside &&
		git update-index --refresh &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_fsmonitor_full_proof .git/index paired &&

		test_write_lines visible >cached/new-visible &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=cached/new-visible \
		GIT_TRACE2_EVENT="$PWD/.git/writer.trace" \
			git update-index --force-write-index &&
		test_trace2_data fsmonitor apply_count 1 <.git/writer.trace &&
		test_region index do_write_index .git/writer.trace &&
		test_fsmonitor_full_proof .git/index paired &&
		cp .git/index .git/index.snapshot &&

		git --no-optional-locks \
			-c core.fsmonitor=false \
			-c core.untrackedCache=false \
			-c core.trustctime=true \
			-c core.checkStat=default \
			status --porcelain=v2 >.git/expect &&
		test_grep "^? cached/new-visible$" .git/expect &&
		test_cmp_bin .git/index.snapshot .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/reader.trace" \
			git --no-optional-locks status --porcelain=v2 \
				>.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_cmp_bin .git/index.snapshot .git/index &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/reader.trace &&
		test_trace2_data fsmonitor apply_count 0 \
			<.git/reader.trace &&
		! test_trace2_data read_directory opendir 0 \
			<.git/reader.trace &&
		! test_region index do_write_index .git/reader.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'am preserves complete worktree proofs at an unchanged provider token' '
	test_when_finished "rm -rf am-provider-proof am-provider-proof-linked \
				am-provider-proof.patch \
				am-provider-proof.expected-tree" &&
	test_create_repo am-provider-proof &&
	(
		cd am-provider-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines base >tracked &&
		test_write_lines sibling >sibling &&
		git add tracked sibling &&
		git commit -qm base &&
		test_write_lines patched >tracked &&
		git add tracked &&
		git commit -qm patched &&
		git rev-parse HEAD^{tree} >../am-provider-proof.expected-tree &&
		git format-patch -1 --stdout >../am-provider-proof.patch &&
		git reset --hard -q HEAD^ &&
		git worktree add --detach -q \
			../am-provider-proof-linked HEAD &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		for worktree in "$PWD" "$PWD/../am-provider-proof-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			test-tool chmtime -120 \
				"$worktree/tracked" "$worktree/sibling" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" update-index --refresh &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			test_fsmonitor_full_proof "$gitdir/index" paired &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index \
					--force-write-index &&
			test_fsmonitor_full_proof "$gitdir/index" paired \
				"builtin:test:1" &&

			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/am.trace" \
				git -C "$worktree" am --quiet \
					"$PWD/../am-provider-proof.patch" &&
			test_fsmonitor_full_proof "$gitdir/index" paired \
				"builtin:test:1" &&
			test_trace2_data fsmonitor config/coherent 1 \
				<"$gitdir/am.trace" &&
			git -C "$worktree" rev-parse HEAD^{tree} \
				>"$gitdir/actual-tree" &&
			test_cmp "$PWD/../am-provider-proof.expected-tree" \
				"$gitdir/actual-tree" &&
			test_write_lines patched >"$gitdir/expected-tracked" &&
			test_cmp "$gitdir/expected-tracked" \
				"$worktree/tracked" &&
			cp "$gitdir/index" "$gitdir/index.snapshot" &&
			git --no-optional-locks -C "$worktree" \
				-c core.fsmonitor=false \
				-c core.untrackedCache=false \
				-c core.trustctime=true \
				-c core.checkStat=default \
				status --porcelain=v2 >"$gitdir/expected" &&
			test_must_be_empty "$gitdir/expected" &&
			test_cmp_bin "$gitdir/index.snapshot" "$gitdir/index" &&
			for reader in first second
			do
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/$reader.trace" \
					git --no-optional-locks -C "$worktree" \
						status --porcelain=v2 \
						>"$gitdir/$reader.actual" &&
				test_cmp "$gitdir/expected" \
					"$gitdir/$reader.actual" &&
				test_cmp_bin "$gitdir/index.snapshot" \
					"$gitdir/index" &&
				test_trace2_data fsmonitor config/coherent 1 \
					<"$gitdir/$reader.trace" &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<"$gitdir/$reader.trace" &&
				test_region ! index do_write_index \
					"$gitdir/$reader.trace" || return 1
			done || return 1
		done
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'am invalidates proofs when a patch changes attribute semantics' '
	test_when_finished "rm -rf am-provider-attributes \
				am-provider-attributes.patch" &&
	test_create_repo am-provider-attributes &&
	(
		cd am-provider-attributes &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines base >tracked &&
		test_write_lines sibling >sibling &&
		test_write_lines "tracked text" >.gitattributes &&
		git add tracked sibling .gitattributes &&
		git commit -qm base &&
		test_write_lines patched >tracked &&
		test_write_lines "tracked -text" >.gitattributes &&
		git add tracked .gitattributes &&
		git commit -qm "change attribute semantics" &&
		git rev-parse HEAD^{tree} >.git/expected-tree &&
		git format-patch -1 --stdout >../am-provider-attributes.patch &&
		git reset --hard -q HEAD^ &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		test-tool chmtime -120 tracked sibling .gitattributes &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git update-index --refresh &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_fsmonitor_full_proof .git/index paired &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --force-write-index &&
		test_fsmonitor_full_proof .git/index paired \
			"builtin:test:1" &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/am.trace" \
			git am --quiet ../am-provider-attributes.patch &&
		! test_fsmonitor_full_proof .git/index paired &&
		! test_trace2_data fsmonitor \
			apply/untracked-replacement-preserved 1 \
			<.git/am.trace &&
		git rev-parse HEAD^{tree} >.git/actual-tree &&
		test_cmp .git/expected-tree .git/actual-tree &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git --no-optional-locks status --porcelain=v2 \
				>.git/actual &&
		git --no-optional-locks \
			-c core.fsmonitor=false \
			-c core.untrackedCache=false \
			-c core.trustctime=true \
			-c core.checkStat=default \
			status --porcelain=v2 >.git/expected &&
		test_cmp .git/expected .git/actual
	)
'

test_lazy_prereq LINUX_SCOPED_HISTORY '
	test "$uname_s" = Linux
'

test_expect_success LINUX_SCOPED_HISTORY,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'bounded tracked-only status verifies zero-stat entries before omitting history' '
	test_when_finished "rm -rf nondurable-scoped-repair \
				nondurable-scoped-repair-linked" &&
	test_create_repo nondurable-scoped-repair &&
	(
		cd nondurable-scoped-repair &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir cached &&
		test_write_lines indexed >cached/tracked &&
		test_write_lines sibling >cached/sibling &&
		test_write_lines "* -filter" "*.asset text" >.gitattributes &&
		test_write_lines ignored >.gitignore &&
		git add cached/tracked cached/sibling \
			.gitattributes .gitignore &&
		git commit -qm base &&
		git worktree add --detach -q \
			../nondurable-scoped-repair-linked HEAD &&
		git config index.skipHash true &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		git config filter.scoped.clean cat &&
		git config filter.scoped.smudge cat &&
		git config filter.scoped.required true &&
		git config status.showUntrackedFiles no &&
		for worktree in "$PWD" "$PWD/../nondurable-scoped-repair-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			test_write_lines temporary \
				>"$worktree/cached/tracked" &&
			git --no-optional-locks -C "$worktree" \
				-c core.fsmonitor=false \
				-c core.untrackedCache=false \
				diff -- cached/tracked >"$gitdir/scoped.patch" &&
			test_write_lines indexed \
				>"$worktree/cached/tracked" &&
			test-tool chmtime -120 \
				"$worktree/cached/tracked" &&
			test-tool chmtime -240 \
				"$worktree/cached/sibling" \
				"$worktree/.gitattributes" \
				"$worktree/.gitignore" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" update-index --refresh &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					--untracked-files=normal \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			test_fsmonitor_full_proof "$gitdir/index" paired &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/forward.trace" \
				git -C "$worktree" apply --cached \
					"$gitdir/scoped.patch" &&
			test_trace2_data fsmonitor \
				apply/untracked-replacement-preserved 1 \
				<"$gitdir/forward.trace" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/reverse.trace" \
				git -C "$worktree" apply --cached --reverse \
					"$gitdir/scoped.patch" &&
			test_trace2_data fsmonitor \
				apply/untracked-replacement-preserved 1 \
				<"$gitdir/reverse.trace" &&
			test_fsmonitor_full_proof "$gitdir/index" paired &&
			git --no-optional-locks -C "$worktree" \
				-c core.fsmonitor=false \
				ls-files --debug -- cached/tracked \
					>"$gitdir/zero-stat" &&
			test_grep "ctime: 0:0" "$gitdir/zero-stat" &&
			test_grep "mtime: 0:0" "$gitdir/zero-stat" &&
			test_grep "size: 0" "$gitdir/zero-stat" &&
			(
				cd "$worktree" &&
				test-tool dump-fsmonitor
			) >"$gitdir/fsmonitor" &&
			test_grep "[-]$" "$gitdir/fsmonitor" &&
			(
				cd "$worktree" &&
				GIT_CONFIG_PARAMETERS="${SQ}core.fsmonitor=false${SQ}" \
					test-tool dump-untracked-cache
			) >"$gitdir/untracked" &&
			test_grep "^/ .* valid$" "$gitdir/untracked" &&
			test_grep "^/cached/ .* valid$" \
				"$gitdir/untracked" &&
			test_write_lines definitely-dirty \
				>"$worktree/cached/tracked" &&
			git --no-optional-locks -C "$worktree" \
				-c core.fsmonitor=false \
				-c core.untrackedCache=false \
				-c core.trustctime=true \
				-c core.checkStat=default \
				status --porcelain=v2 --untracked-files=no \
					-- cached/tracked >"$gitdir/dirty.expected" &&
			test_grep "^1 \\.M .* cached/tracked$" \
				"$gitdir/dirty.expected" &&

			# Normal-untracked pathspecs must still publish global history.
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/publish.trace" \
				git -C "$worktree" status --porcelain=v2 \
					--untracked-files=normal -- cached/tracked \
						>"$gitdir/publish.actual" &&
			test_cmp "$gitdir/dirty.expected" \
				"$gitdir/publish.actual" &&
			test_trace2_data fsmonitor history/external-stored 1 \
				<"$gitdir/publish.trace" &&
			test_region fsmonitor history_logical_digest \
				"$gitdir/publish.trace" &&
			find "$gitdir" -maxdepth 1 -type f \
				-name "index.csh1.*" >"$gitdir/checkpoints" &&
			test_line_count = 1 "$gitdir/checkpoints" &&
			checkpoint=$(cat "$gitdir/checkpoints") &&
			cat >"$gitdir/retoken.pl" <<-\EOF &&
			use Digest::SHA qw(sha1 sha256);
			binmode STDIN;
			binmode STDOUT;
			local $/;
			my $index = <STDIN>;
			my $rawsz = $ARGV[0] eq "sha256" ? 32 : 20;
			for my $name ("FSMN", "FSUC", "FSCF") {
				my $at = index($index, $name);
				die "missing $name" if $at < 0;
				my $size = unpack("N", substr($index, $at + 4, 4));
				my $payload = substr($index, $at + 8, $size);
				my $count = ($payload =~
					s/builtin:test:[0-9]/builtin:test:3/g);
				die "unexpected $name token" unless $count == 1;
				if ($name eq "FSCF") {
					my $proof = substr($payload, 0, -$rawsz);
					my $checksum = $rawsz == 32 ?
						sha256($proof) : sha1($proof);
					substr($payload, -$rawsz, $rawsz,
						$checksum);
				}
				substr($index, $at + 8, $size, $payload);
			}
			my $payload = substr($index, 0, -$rawsz);
			print $payload, "\0" x $rawsz;
			EOF
			perl "$gitdir/retoken.pl" "$(test_oid algo)" \
				<"$gitdir/index" >"$gitdir/index.retoken" &&
			mv "$gitdir/index.retoken" "$gitdir/index" &&
			test_fsmonitor_full_proof "$gitdir/index" paired \
				"builtin:test:3" &&
			test_trailing_hash "$gitdir/index" \
				>"$gitdir/initial-zero.hash" &&
			test_oid zero >"$gitdir/zero.expected" &&
			test_cmp "$gitdir/zero.expected" \
				"$gitdir/initial-zero.hash" &&
			cp "$gitdir/index" "$gitdir/zero.index" &&
			cp "$checkpoint" "$gitdir/checkpoint.snapshot" &&

			for attempt in first second
			do
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/$attempt.trace" \
					git -C "$worktree" status --porcelain=v2 \
						--untracked-files=no \
						-- cached/tracked \
							>"$gitdir/$attempt.actual" &&
				test_trace2_data fsmonitor config/coherent 1 \
					<"$gitdir/$attempt.trace" &&
				! test_trace2_data fsmonitor config/invalid-extension 1 \
					<"$gitdir/$attempt.trace" &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<"$gitdir/$attempt.trace" &&
				test_cmp "$gitdir/dirty.expected" \
					"$gitdir/$attempt.actual" &&
				test_cmp_bin "$gitdir/zero.index" \
					"$gitdir/index" &&
				test_cmp_bin "$gitdir/checkpoint.snapshot" \
					"$checkpoint" &&
				test_trace2_data fsmonitor \
					history/scoped-source-capture-deferred 1 \
					<"$gitdir/$attempt.trace" &&
				test_trace2_data fsmonitor \
					history/scoped-source-capture-skipped 1 \
					<"$gitdir/$attempt.trace" &&
				test_trace2_data fsmonitor config/token-advanced 1 \
					<"$gitdir/$attempt.trace" &&
				test_region ! fsmonitor history_logical_digest \
					"$gitdir/$attempt.trace" &&
				test_region ! index do_write_index \
					"$gitdir/$attempt.trace" || return 1
			done &&

			# A zero-stat clean entry must still be physically repaired.
			test_write_lines indexed \
				>"$worktree/cached/tracked" &&
			test-tool chmtime =-60 \
				"$worktree/cached/tracked" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/repair.trace" \
				git -C "$worktree" status --porcelain=v2 \
					--untracked-files=no -- cached/tracked \
						>"$gitdir/repair.actual" &&
			test_must_be_empty "$gitdir/repair.actual" &&
			test_trace2_data fsmonitor \
				history/scoped-source-capture-deferred 1 \
				<"$gitdir/repair.trace" &&
			test_trace2_data fsmonitor \
				history/scoped-source-repair-required 1 \
				<"$gitdir/repair.trace" &&
			test_trace2_data fsmonitor \
				history/scoped-original-source-restored 1 \
				<"$gitdir/repair.trace" &&
			test_trace2_data fsmonitor history/external-stored 1 \
				<"$gitdir/repair.trace" &&
			test_region fsmonitor history_logical_digest \
				"$gitdir/repair.trace" &&
			test_region index do_write_index \
				"$gitdir/repair.trace" &&
			! test_cmp_bin "$gitdir/zero.index" \
				"$gitdir/index" &&
			git --no-optional-locks -C "$worktree" \
				-c core.fsmonitor=false \
				ls-files --debug -- cached/tracked \
					>"$gitdir/repaired-stat" &&
			test_grep ! "size: 0" "$gitdir/repaired-stat" &&
			test_fsmonitor_full_proof "$gitdir/index" paired &&

			# That repaired source still survives a subsequent foreign writer.
			cp "$gitdir/index" "$gitdir/repaired.index" &&
			cp "$checkpoint" "$gitdir/repaired.checkpoint" &&
			git -C "$worktree" \
				-c core.fsmonitor=false \
				-c core.untrackedCache=false \
				update-index --force-write-index &&
			test_grep ! FSUC "$gitdir/index" &&
			cp "$gitdir/index" "$gitdir/foreign-stripped.index" &&
			git --no-optional-locks -C "$worktree" \
				-c core.fsmonitor=false \
				-c core.untrackedCache=false \
				status --porcelain=v2 --untracked-files=no \
					-- cached/tracked \
						>"$gitdir/follower.expected" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/follower.trace" \
				git --no-optional-locks -C "$worktree" \
					status --porcelain=v2 --untracked-files=no \
						-- cached/tracked \
							>"$gitdir/follower.actual" &&
			test_cmp "$gitdir/follower.expected" \
				"$gitdir/follower.actual" &&
			test_cmp_bin "$gitdir/foreign-stripped.index" \
				"$gitdir/index" &&
			test_cmp_bin "$gitdir/repaired.checkpoint" \
				"$checkpoint" &&
			test_trace2_data fsmonitor history/external-restored 1 \
				<"$gitdir/follower.trace" &&
			test_region ! index do_write_index \
				"$gitdir/follower.trace" &&
			cp "$gitdir/repaired.index" "$gitdir/index" &&

			# Neither a selected nor an unrelated racy CE may lose its write.
			selected_mtime=$(test-tool chmtime --get \
				"$worktree/cached/tracked") &&
			test-tool chmtime =$selected_mtime "$gitdir/index" &&
			cp "$gitdir/index" "$gitdir/selected-racy.before" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/selected-racy.trace" \
				git -C "$worktree" status --porcelain=v2 \
					--untracked-files=no -- cached/tracked \
						>"$gitdir/selected-racy.actual" &&
			test_must_be_empty "$gitdir/selected-racy.actual" &&
			! test_trace2_data fsmonitor \
				history/scoped-source-capture-skipped 1 \
				<"$gitdir/selected-racy.trace" &&
			test_trace2_data fsmonitor history/external-save-reject \
				racy-index \
				<"$gitdir/selected-racy.trace" &&
			test_region index do_write_index \
				"$gitdir/selected-racy.trace" &&
			test-tool chmtime =-30 \
				"$worktree/cached/sibling" &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=cached/sibling \
				git -C "$worktree" status --porcelain=v2 \
					--untracked-files=normal \
						>"$gitdir/sibling-refresh.actual" &&
			test_must_be_empty "$gitdir/sibling-refresh.actual" &&
			test_fsmonitor_full_proof "$gitdir/index" paired &&
			sibling_mtime=$(test-tool chmtime --get \
				"$worktree/cached/sibling") &&
			test-tool chmtime =$sibling_mtime "$gitdir/index" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/unselected-racy.trace" \
				git -C "$worktree" status --porcelain=v2 \
					--untracked-files=no -- cached/tracked \
						>"$gitdir/unselected-racy.actual" &&
			test_must_be_empty "$gitdir/unselected-racy.actual" &&
			! test_trace2_data fsmonitor \
				history/scoped-source-capture-skipped 1 \
				<"$gitdir/unselected-racy.trace" &&
			test_trace2_data fsmonitor history/external-save-reject \
				racy-index \
				<"$gitdir/unselected-racy.trace" &&
			test_region index do_write_index \
				"$gitdir/unselected-racy.trace" &&

			# Dirt that disappears during refresh must take the repair path.
			if test_have_prereq PIPE
			then
				cp "$gitdir/zero.index" "$gitdir/index" &&
				test_write_lines race-dirty \
					>"$worktree/cached/tracked" &&
				ready="$gitdir/dirty-clean.ready" &&
				resume="$gitdir/dirty-clean.resume" &&
				fsmonitor_query_pid= &&
				trap cleanup_fsmonitor_query_barrier 0 &&
				mkfifo "$resume" &&
				{
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					GIT_TEST_CLEAN_STATUS_SCOPED_HISTORY_BARRIER_READY="$ready" \
					GIT_TEST_CLEAN_STATUS_SCOPED_HISTORY_BARRIER_RESUME="$resume" \
					GIT_TRACE2_EVENT="$gitdir/dirty-clean.trace" \
						git -C "$worktree" status --porcelain=v2 \
							--untracked-files=no \
							-- cached/tracked \
								>"$gitdir/dirty-clean.actual" \
								2>"$gitdir/dirty-clean.err" &
					fsmonitor_query_pid=$!
				} &&
				wait_for_fsmonitor_query_barrier \
					"$ready" "$fsmonitor_query_pid" &&
				test_trace2_data fsmonitor \
					history/scoped-source-capture-deferred 1 \
					<"$gitdir/dirty-clean.trace" &&
				test_write_lines indexed \
					>"$worktree/cached/tracked" &&
				test-tool chmtime =-60 \
					"$worktree/cached/tracked" &&
				git --no-optional-locks -C "$worktree" \
					-c core.fsmonitor=false \
					-c core.untrackedCache=false \
					status --porcelain=v2 --untracked-files=no \
						-- cached/tracked \
							>"$gitdir/dirty-clean.expected" &&
				printf x >"$resume" &&
				wait "$fsmonitor_query_pid" &&
				fsmonitor_query_pid= &&
				trap - 0 &&
				test_cmp "$gitdir/dirty-clean.expected" \
					"$gitdir/dirty-clean.actual" &&
				test_trace2_data fsmonitor \
					history/scoped-source-repair-required 1 \
					<"$gitdir/dirty-clean.trace" &&
				test_trace2_data fsmonitor \
					history/scoped-original-source-restored 1 \
					<"$gitdir/dirty-clean.trace" &&
				test_trace2_data fsmonitor history/external-stored 1 \
					<"$gitdir/dirty-clean.trace" &&
				test_region index do_write_index \
					"$gitdir/dirty-clean.trace" &&
				test_fsmonitor_full_proof "$gitdir/index" paired
			else
				:
			fi &&

			# Root equivalents and implicit -uno retain the original writer.
			for scope in root root-dot root-magic wildcard implicit
			do
				case "$scope" in
				root)
					set -- --untracked-files=no
					;;
				root-dot)
					set -- --untracked-files=no -- .
					;;
				root-magic)
					set -- --untracked-files=no -- :/
					;;
				wildcard)
					set -- --untracked-files=no -- "cached/*"
					;;
				implicit)
					set -- -- cached/tracked
					;;
				esac &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/$scope.trace" \
					git -C "$worktree" status --porcelain=v2 \
						"$@" >"$gitdir/$scope.actual" &&
				test_must_be_empty "$gitdir/$scope.actual" &&
				! test_trace2_data fsmonitor \
					history/scoped-source-capture-deferred 1 \
					<"$gitdir/$scope.trace" &&
				test_region fsmonitor history_logical_digest \
					"$gitdir/$scope.trace" || return 1
			done &&

			# A bounded literal must not select an attribute or exclude source.
			for source in .gitattributes .gitignore
			do
				case "$source" in
				.gitattributes)
					label=attributes
					;;
				.gitignore)
					label=ignore
					;;
				esac &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/$label.trace" \
					git -C "$worktree" status --porcelain=v2 \
						--untracked-files=no -- "$source" \
							>"$gitdir/$label.actual" &&
				test_must_be_empty "$gitdir/$label.actual" &&
				! test_trace2_data fsmonitor \
					history/scoped-source-capture-deferred 1 \
					<"$gitdir/$label.trace" || return 1
			done &&

			# A mismatched config and an actual provider delta fail closed.
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/config.trace" \
				git -C "$worktree" -c core.autocrlf=true \
					status --porcelain=v2 \
						--untracked-files=no -- cached/tracked \
							>"$gitdir/config.actual" &&
			! test_trace2_data fsmonitor \
				history/scoped-source-capture-deferred 1 \
				<"$gitdir/config.trace" &&
			cp "$gitdir/zero.index" "$gitdir/index" &&
			test_write_lines provider-dirty \
				>"$worktree/cached/tracked" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=cached/tracked \
			GIT_TRACE2_EVENT="$gitdir/provider.trace" \
				git -C "$worktree" status --porcelain=v2 \
					--untracked-files=no -- cached/tracked \
						>"$gitdir/provider.actual" &&
			test_grep "^1 \\.M .* cached/tracked$" \
				"$gitdir/provider.actual" &&
			! test_trace2_data fsmonitor \
				history/scoped-source-capture-skipped 1 \
				<"$gitdir/provider.trace" &&

			# An active clean filter cannot enter this lane.
			test_write_lines "cached/tracked filter=scoped" \
				>"$worktree/.gitattributes" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
				git -C "$worktree" add -- .gitattributes &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					--untracked-files=normal \
						>"$gitdir/active-prime.actual" &&
			git --no-optional-locks -C "$worktree" \
				-c core.fsmonitor=false \
				-c core.untrackedCache=false \
				status --porcelain=v2 --untracked-files=no \
					-- cached/tracked \
						>"$gitdir/active.expected" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/active.trace" \
				git -C "$worktree" status --porcelain=v2 \
					--untracked-files=no -- cached/tracked \
						>"$gitdir/active.actual" &&
			test_cmp "$gitdir/active.expected" \
				"$gitdir/active.actual" &&
			! test_trace2_data fsmonitor \
				history/scoped-source-capture-deferred 1 \
				<"$gitdir/active.trace" &&

			# A subsequently failing required filter cannot be bypassed.
			cp "$gitdir/index" "$gitdir/filter.before" &&
			test_must_fail env \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
				GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
				GIT_TRACE2_EVENT="$gitdir/filter.trace" \
				git -C "$worktree" \
					-c filter.scoped.clean=false \
					-c filter.scoped.smudge=cat \
					-c filter.scoped.required=true \
					status --porcelain=v2 --untracked-files=no \
						-- cached/tracked \
						>"$gitdir/filter.actual" \
						2>"$gitdir/filter.err" &&
			test_grep "clean filter .scoped. failed" \
				"$gitdir/filter.err" &&
			test_cmp_bin "$gitdir/filter.before" "$gitdir/index" &&
			! test_trace2_data fsmonitor \
				history/scoped-source-capture-skipped 1 \
				<"$gitdir/filter.trace" &&

			# A competing physical writer must never be overwritten.
			if test_have_prereq PIPE
			then
				test_write_lines "* -filter" "*.asset text" \
					>"$worktree/.gitattributes" &&
				cp "$gitdir/zero.index" "$gitdir/index" &&
				test_write_lines race-dirty \
					>"$worktree/cached/tracked" &&
				ready="$gitdir/foreign.ready" &&
				resume="$gitdir/foreign.resume" &&
				fsmonitor_query_pid= &&
				trap cleanup_fsmonitor_query_barrier 0 &&
				mkfifo "$resume" &&
				{
					GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					GIT_TEST_CLEAN_STATUS_SCOPED_HISTORY_BARRIER_READY="$ready" \
					GIT_TEST_CLEAN_STATUS_SCOPED_HISTORY_BARRIER_RESUME="$resume" \
					GIT_TRACE2_EVENT="$gitdir/foreign.trace" \
						git -C "$worktree" status --porcelain=v2 \
							--untracked-files=no \
							-- cached/tracked \
								>"$gitdir/foreign.actual" \
								2>"$gitdir/foreign.err" &
					fsmonitor_query_pid=$!
				} &&
				wait_for_fsmonitor_query_barrier \
					"$ready" "$fsmonitor_query_pid" &&
				test_trace2_data fsmonitor \
					history/scoped-source-capture-deferred 1 \
					<"$gitdir/foreign.trace" &&
				test_path_is_missing "$gitdir/index.lock" &&
				test_write_lines competing \
					>"$worktree/cached/sibling" &&
				git -C "$worktree" \
					-c core.fsmonitor=false \
					-c core.untrackedCache=false \
					add cached/sibling &&
				cp "$gitdir/index" "$gitdir/foreign.index" &&
				test_trailing_hash "$gitdir/foreign.index" \
					>"$gitdir/foreign.zero" &&
				test_cmp "$gitdir/zero.expected" \
					"$gitdir/foreign.zero" &&
				printf x >"$resume" &&
				wait "$fsmonitor_query_pid" &&
				fsmonitor_query_pid= &&
				trap - 0 &&
				test_cmp_bin "$gitdir/foreign.index" \
					"$gitdir/index" &&
				! test_trace2_data fsmonitor \
					history/scoped-source-capture-skipped 1 \
					<"$gitdir/foreign.trace" &&
				test_trace2_data fsmonitor \
					history/scoped-source-epoch-mismatch 1 \
					<"$gitdir/foreign.trace" &&
				! test_trace2_data fsmonitor history/external-stored 1 \
					<"$gitdir/foreign.trace" &&
				test_region ! index do_write_index \
					"$gitdir/foreign.trace"
			else
				:
			fi || return 1
		done
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'repeated provider resets fall back before an unclosable rescan' '
	test_when_finished "rm -rf builtin-closure-terminal-reset" &&
	prepare_builtin_closure_repo builtin-closure-terminal-reset untracked &&
	(
		cd builtin-closure-terminal-reset &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_fsmonitor_full_proof .git/index paired &&
		test_write_lines modified >tracked &&
		test_write_lines "tracked -text" >.gitattributes &&
		test_write_lines visible >visible &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				status --porcelain=v2 >.git/expected &&
		test_grep "^1 \\.M .* tracked$" .git/expected &&
		test_grep "^? \\.gitattributes$" .git/expected &&
		test_grep "^? visible$" .git/expected &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TTTT \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expected .git/actual &&
		test_trace2_data fsmonitor token_closure/trivial 1 \
			<.git/status.trace >.git/trivial &&
		test_line_count = 2 .git/trivial &&
		test_trace2_data fsmonitor semantic/proof-epoch-captured 1 \
			<.git/status.trace >.git/epochs &&
		test_line_count = 2 .git/epochs &&
		test_trace2_data status \
			fsmonitor_token/repeated-trivial-fallback 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/rejected 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test-tool dump-fsmonitor >.git/fsmonitor &&
		test_grep "^fsmonitor last update builtin:test:2$" \
			.git/fsmonitor &&
		! test_fsmonitor_full_proof .git/index paired \
			2>.git/unbound-proof &&
		test_grep "^unbound FSCF flags 9$" .git/unbound-proof
	)
'

test_done
