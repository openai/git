#!/bin/sh

test_description='Linux bulk index preload'

. ./test-lib.sh

if test "$(uname -s)" != Linux
then
	skip_all='Linux getdents64/statx backend required'
	test_done
fi

case "$(stat -f -c %t "$TRASH_DIRECTORY")" in
ef53)
	filesystem=ext-family
	;;
58465342)
	filesystem=xfs
	;;
*)
	skip_all='tests require an ext-family filesystem or XFS'
	test_done
	;;
esac

setup_repo () {
	repo=$1 &&
	git init "$repo" &&
	mkdir -p "$repo/nested/deep" &&
	test_write_lines root >"$repo/root" &&
	test_write_lines peer >"$repo/peer" &&
	test_write_lines nested >"$repo/nested/tracked" &&
	test_write_lines deep >"$repo/nested/deep/tracked" &&
	git -C "$repo" add . &&
	git -C "$repo" commit -m base &&
	git -C "$repo" config core.fsmonitor false &&
	test-tool chmtime -120 "$repo/root" "$repo/peer" \
		"$repo/nested/tracked" "$repo/nested/deep/tracked" &&
	git -C "$repo" update-index --refresh
}

setup_provider_proof_repo () {
	setup_repo "$1" &&
	(
		cd "$1" &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		size=$(test_file_size root) &&
		mtime=$(test-tool chmtime --get root) &&
		printf "dirt\n" >root &&
		test "$(test_file_size root)" = "$size" &&
		test-tool chmtime =$mtime root &&
		test "$(test-tool chmtime --get root)" = "$mtime" &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor-valid root &&
		test_grep ! FSCF .git/index
	)
}

test_lazy_prereq LINUX_BULK_PRELOAD '
	setup_repo linux-bulk-prereq &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TEST_PRELOAD_INDEX=1 \
	GIT_TRACE2_EVENT="$TRASH_DIRECTORY/linux-bulk-prereq.trace" \
		git -C linux-bulk-prereq \
		-c core.preloadIndexBulk=true \
		status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_trace2_data index preload/bulk_result complete \
		<"$TRASH_DIRECTORY/linux-bulk-prereq.trace"
'

if ! test_have_prereq LINUX_BULK_PRELOAD
then
	skip_all="Linux bulk preload backend unavailable at runtime"
	test_done
fi

ordinary_status () {
	GIT_OPTIONAL_LOCKS=0 \
		git -C "$1" -c core.preloadIndex=false \
		status --porcelain=v2 >"$2"
}

bulk_status () {
	repo=$1 &&
	output=$2 &&
	bulk_trace=$TRASH_DIRECTORY/$3 &&
	rm -f "$bulk_trace" &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TEST_PRELOAD_INDEX=1 \
	GIT_TEST_PRELOAD_INDEX_BULK=1 \
	GIT_TRACE2_EVENT="$bulk_trace" \
		git -C "$repo" status --porcelain=v2 >"$output"
}

check_data () {
	test_trace2_data index "$2" "$3" <"$TRASH_DIRECTORY/$1"
}

check_lstat_data () {
	test_have_prereq !PTHREADS ||
	check_data "$1" preload/sum_lstat "$2"
}

compare_status () {
	ordinary_status "$1" expect &&
	bulk_status "$1" actual "$2" &&
	test_cmp expect actual
}

cleanup_race () {
	exec 9>&-
	if test -n "$status_pid"
	then
		kill "$status_pid" 2>/dev/null || :
		wait "$status_pid" 2>/dev/null || :
	fi
	status_pid= &&
	rm -f "$ready" "$resume"
}

wait_for_ready () {
	for i in $(test_seq 1 1000)
	do
		test "$(cat "$ready" 2>/dev/null)" = ready && return 0
		kill -0 "$status_pid" 2>/dev/null || return 1
		sleep 0.01
	done
	return 1
}

start_raced_status () {
	repo=$1 &&
	barrier=$2 &&
	ready=$TRASH_DIRECTORY/$repo.ready &&
	resume=$TRASH_DIRECTORY/$repo.resume &&
	race_trace=$TRASH_DIRECTORY/$repo.trace &&
	status_pid= &&
	rm -f "$ready" "$resume" "$race_trace" &&
	mkfifo "$resume" &&
	exec 9<>"$resume" &&
	{
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_PRELOAD_INDEX_BULK=1 \
		GIT_TEST_PRELOAD_INDEX_BULK_BARRIER_PATH="$barrier" \
		GIT_TEST_PRELOAD_INDEX_BULK_BARRIER_READY="$ready" \
		GIT_TEST_PRELOAD_INDEX_BULK_BARRIER_RESUME="$resume" \
		GIT_TRACE2_EVENT="$race_trace" \
			git -C "$repo" status --porcelain=v2 >actual 9>&- &
		status_pid=$!
	} &&
	wait_for_ready
}

finish_raced_status () {
	printf "resume\n" >&9 &&
	exec 9>&- &&
	wait "$status_pid" &&
	status_pid= &&
	ordinary_status "$1" expect &&
	test_cmp expect actual &&
	test_trace2_data index preload/bulk_applied 0 <"$race_trace"
}

test_expect_success 'clean entries are published without lstat' '
	setup_repo clean &&
	bulk_status clean actual clean.trace &&
	test_must_be_empty actual &&
	check_data clean.trace preload/bulk_filesystem "$filesystem" &&
	check_data clean.trace preload/bulk_applied 4 &&
	check_data clean.trace preload/bulk_untracked_complete 1 &&
	check_lstat_data clean.trace 0
'

test_expect_success 'provider closure accepts bulk content proofs' '
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		setup_provider_proof_repo provider-proof &&
		cd provider-proof &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_PRELOAD_INDEX_BULK=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_grep "^1 \.M .* root$" .git/actual &&
		test_trace2_data status semantic_verify/bulk_scan 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace &&
		test_trace2_data index preload/bulk_content_verify 1 \
			<.git/status.trace &&
		test_trace2_data index preload/bulk_bytes_hashed \
			"[1-9][0-9]*" <.git/status.trace &&
		test_trace2_data index preload/bulk_provider_applied 3 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep FSCF .git/index
	)
'

test_expect_success 'provider failure discards bulk content proofs' '
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		setup_provider_proof_repo provider-failure &&
		cd provider-failure &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_PRELOAD_INDEX_BULK=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CE \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_grep "^1 \.M .* root$" .git/actual &&
		test_trace2_data status semantic_verify/bulk_scan 1 \
			<.git/status.trace &&
		test_trace2_data index preload/bulk_content_verify 1 \
			<.git/status.trace &&
		test_trace2_data index preload/bulk_bytes_hashed \
			"[1-9][0-9]*" <.git/status.trace &&
		! test_trace2_data index preload/bulk_provider_applied \
			"[0-9][0-9]*" <.git/status.trace &&
		test_trace2_data fsmonitor token_closure/rejected 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep ! FSCF .git/index
	)
'

test_expect_success 'tracked files ignore a directory type hint' '
	setup_repo dirent-file &&
	ordinary_status dirent-file expect &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TEST_PRELOAD_INDEX=1 \
	GIT_TEST_PRELOAD_INDEX_BULK=1 \
	GIT_TEST_PRELOAD_INDEX_BULK_DIRENT_TYPE=dir:root \
	GIT_TRACE2_EVENT="$TRASH_DIRECTORY/dirent-file.trace" \
		git -C dirent-file status --porcelain=v2 >actual &&
	test_cmp expect actual &&
	check_data dirent-file.trace preload/bulk_result complete &&
	check_data dirent-file.trace preload/bulk_applied 4 &&
	check_data dirent-file.trace preload/bulk_fallback 0
'

test_expect_success 'tracked subtrees ignore a regular-file type hint' '
	setup_repo dirent-prefix &&
	test_write_lines visible >dirent-prefix/nested/untracked &&
	ordinary_status dirent-prefix expect &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TEST_PRELOAD_INDEX=1 \
	GIT_TEST_PRELOAD_INDEX_BULK=1 \
	GIT_TEST_PRELOAD_INDEX_BULK_DIRENT_TYPE=reg:nested \
	GIT_TRACE2_EVENT="$TRASH_DIRECTORY/dirent-prefix.trace" \
		git -C dirent-prefix status --porcelain=v2 >actual &&
	test_cmp expect actual &&
	check_data dirent-prefix.trace preload/bulk_result complete &&
	check_data dirent-prefix.trace preload/bulk_applied 4 &&
	check_data dirent-prefix.trace preload/bulk_definitive_deleted 0 &&
	check_data dirent-prefix.trace preload/bulk_fallback 0 &&
	check_data dirent-prefix.trace preload/bulk_untracked_complete 1
'

test_expect_success 'untracked directories ignore a regular-file type hint' '
	setup_repo dirent-untracked-directory &&
	mkdir -p dirent-untracked-directory/collapsed/deep &&
	test_write_lines visible \
		>dirent-untracked-directory/collapsed/deep/file &&
	ordinary_status dirent-untracked-directory expect &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TEST_PRELOAD_INDEX=1 \
	GIT_TEST_PRELOAD_INDEX_BULK=1 \
	GIT_TEST_PRELOAD_INDEX_BULK_DIRENT_TYPE=reg:collapsed \
	GIT_TRACE2_EVENT="$TRASH_DIRECTORY/dirent-untracked-directory.trace" \
		git -C dirent-untracked-directory \
		status --porcelain=v2 >actual &&
	test_cmp expect actual &&
	test_grep "^? collapsed/$" actual &&
	check_data dirent-untracked-directory.trace \
		preload/bulk_result complete &&
	check_data dirent-untracked-directory.trace \
		preload/bulk_untracked_complete 1 &&
	check_data dirent-untracked-directory.trace \
		preload/bulk_untracked_count 1
'

test_expect_success 'ignored directories ignore a regular-file type hint' '
	setup_repo dirent-ignored-directory &&
	test_write_lines "*.ignored" >dirent-ignored-directory/.gitignore &&
	git -C dirent-ignored-directory add .gitignore &&
	git -C dirent-ignored-directory commit -m ignore &&
	mkdir dirent-ignored-directory/ignored-only &&
	test_write_lines ignored \
		>dirent-ignored-directory/ignored-only/file.ignored &&
	ordinary_status dirent-ignored-directory expect &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TEST_PRELOAD_INDEX=1 \
	GIT_TEST_PRELOAD_INDEX_BULK=1 \
	GIT_TEST_PRELOAD_INDEX_BULK_DIRENT_TYPE=reg:ignored-only \
	GIT_TRACE2_EVENT="$TRASH_DIRECTORY/dirent-ignored-directory.trace" \
		git -C dirent-ignored-directory \
		status --porcelain=v2 >actual &&
	test_cmp expect actual &&
	test_must_be_empty actual &&
	check_data dirent-ignored-directory.trace \
		preload/bulk_result complete &&
	check_data dirent-ignored-directory.trace \
		preload/bulk_untracked_complete 1 &&
	check_data dirent-ignored-directory.trace \
		preload/bulk_untracked_count 0
'

test_expect_success 'untracked files ignore a directory type hint' '
	setup_repo dirent-untracked-file &&
	test_write_lines "visible/" >dirent-untracked-file/.gitignore &&
	git -C dirent-untracked-file add .gitignore &&
	git -C dirent-untracked-file commit -m ignore &&
	test_write_lines visible >dirent-untracked-file/visible &&
	ordinary_status dirent-untracked-file expect &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TEST_PRELOAD_INDEX=1 \
	GIT_TEST_PRELOAD_INDEX_BULK=1 \
	GIT_TEST_PRELOAD_INDEX_BULK_DIRENT_TYPE=dir:visible \
	GIT_TRACE2_EVENT="$TRASH_DIRECTORY/dirent-untracked-file.trace" \
		git -C dirent-untracked-file status --porcelain=v2 >actual &&
	test_cmp expect actual &&
	test_grep "^? visible$" actual &&
	check_data dirent-untracked-file.trace \
		preload/bulk_result complete &&
	check_data dirent-untracked-file.trace \
		preload/bulk_untracked_complete 1 &&
	check_data dirent-untracked-file.trace \
		preload/bulk_untracked_count 1
'

test_expect_success 'visible and ignored paths match ordinary status' '
	setup_repo visible &&
	test_write_lines "*.ignored" >visible/.gitignore &&
	git -C visible add .gitignore &&
	git -C visible commit -m ignore &&
	test_write_lines root >visible/untracked &&
	mkdir -p visible/collapsed/deep visible/ignored-only &&
	test_write_lines nested >visible/collapsed/deep/file &&
	test_write_lines ignored >visible/ignored-only/file.ignored &&
	compare_status visible visible.trace &&
	test_grep "^? untracked$" actual &&
	test_grep "^? collapsed/$" actual &&
	test_grep ! "ignored-only" actual &&
	check_data visible.trace preload/bulk_untracked_complete 1 &&
	check_data visible.trace preload/bulk_untracked_count 2 &&
	test_grep ! "\"category\":\"read_directory\"" visible.trace
'

test_expect_success 'tracked changes match ordinary status' '
	for mode in modified deleted metadata
	do
		setup_repo "$mode" || return 1 &&
		case "$mode" in
		modified) test_write_lines changed-content >"$mode/root" ;;
		deleted) rm "$mode/nested/tracked" ;;
		metadata) test-tool chmtime +60 "$mode/root" ;;
		esac &&
		compare_status "$mode" "$mode.trace" || return 1
	done &&
	check_data modified.trace preload/bulk_definitive_modified 1 &&
	check_data modified.trace refresh/sum_lstat 0 &&
	check_data deleted.trace preload/bulk_definitive_deleted 1 &&
	check_data deleted.trace refresh/sum_lstat 0 &&
	check_data metadata.trace preload/bulk_content_check 1 &&
	check_data metadata.trace refresh/sum_lstat 0
'

test_expect_success 'tracked-file replacement directories are pruned' '
	setup_repo replacement-dir &&
	rm replacement-dir/root &&
	mkdir -p replacement-dir/root/deep/embedded &&
	test_write_lines hidden >replacement-dir/root/deep/untracked &&
	git -C replacement-dir/root/deep/embedded init &&
	compare_status replacement-dir replacement-dir.trace &&
	test_line_count = 1 actual &&
	check_data replacement-dir.trace preload/bulk_fallback 1 &&
	check_data replacement-dir.trace preload/bulk_untracked_complete 1
'

test_expect_success PIPE 'tracked FIFO replacements fall back' '
	setup_repo tracked-fifo &&
	rm tracked-fifo/root &&
	mkfifo tracked-fifo/root &&
	compare_status tracked-fifo tracked-fifo.trace &&
	test_grep "^1 \\.M .* root$" actual &&
	check_data tracked-fifo.trace preload/bulk_result complete &&
	check_data tracked-fifo.trace preload/bulk_applied 3 &&
	check_data tracked-fifo.trace preload/bulk_fallback 1 &&
	check_data tracked-fifo.trace preload/bulk_definitive_deleted 0
'

test_expect_success PIPE 'queued child replacement discards observations' '
	setup_repo child-race &&
	test_when_finished cleanup_race &&
	start_raced_status child-race nested/deep &&
	mv child-race/nested/deep child-race/deep-away &&
	mkdir child-race/nested/deep &&
	test_write_lines dirty >child-race/nested/deep/tracked &&
	finish_raced_status child-race &&
	test_file_not_empty actual
'

test_expect_success PIPE 'fallback shapes retain exact output' '
	setup_repo shapes &&
	ln shapes/root shapes/linked &&
	mkfifo shapes/fifo &&
	git init shapes/embedded &&
	compare_status shapes shapes.trace &&
	check_data shapes.trace preload/bulk_fallback 1 &&
	check_data shapes.trace preload/bulk_untracked_complete 0
'

test_done
