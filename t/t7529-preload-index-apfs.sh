#!/bin/sh

test_description='APFS bulk index preload'

. ./test-lib.sh

test_lazy_prereq APFS_BULK_PRELOAD '
	test_have_prereq MACOS &&
	darwin_major=$(uname -r) &&
	darwin_major=${darwin_major%%.*} &&
	test "$darwin_major" -ge 20 &&
	/bin/df -t apfs "$TRASH_DIRECTORY" >/dev/null
'

if ! test_have_prereq APFS_BULK_PRELOAD
then
	skip_all='bulk index preload requires macOS on APFS'
	test_done
fi

setup_repo () {
	repo=$1 &&
	git init "$repo" &&
	mkdir -p "$repo/nested/deep" "$repo/other" &&
	test_write_lines root >"$repo/root" &&
	test_write_lines root-peer >"$repo/root-peer" &&
	test_write_lines nested >"$repo/nested/tracked" &&
	test_write_lines nested-peer >"$repo/nested/peer" &&
	test_write_lines deep >"$repo/nested/deep/tracked" &&
	test_write_lines deep-peer >"$repo/nested/deep/peer" &&
	test_write_lines other >"$repo/other/tracked" &&
	test_write_lines other-peer >"$repo/other/peer" &&
	git -C "$repo" add . &&
	git -C "$repo" commit -m base &&
	git -C "$repo" config core.fsmonitor false &&
	test-tool chmtime -120 \
		"$repo/root" "$repo/root-peer" \
		"$repo/nested/tracked" "$repo/nested/peer" \
		"$repo/nested/deep/tracked" "$repo/nested/deep/peer" \
		"$repo/other/tracked" "$repo/other/peer" &&
	git -C "$repo" update-index --refresh
}

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

configured_bulk_status () {
	repo=$1 &&
	output=$2 &&
	bulk_trace=$TRASH_DIRECTORY/$3 &&
	bulk=${4-true} &&
	preload=${5-true} &&
	rm -f "$bulk_trace" &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TEST_PRELOAD_INDEX=1 \
	GIT_TRACE2_EVENT="$bulk_trace" \
		git -C "$repo" \
		-c core.preloadIndex="$preload" \
		-c core.preloadIndexBulk="$bulk" \
		status --porcelain=v2 >"$output"
}

test_expect_success 'bulk preload follows its configuration' '
	setup_repo opt-in &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TEST_PRELOAD_INDEX=1 \
	GIT_TRACE2_EVENT="$TRASH_DIRECTORY/default.trace" \
		git -C opt-in status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_grep ! "\"key\":\"preload/bulk_result\"" default.trace &&
	configured_bulk_status opt-in actual enabled.trace &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"preload/bulk_result\"" enabled.trace &&
	configured_bulk_status opt-in actual preload-disabled.trace true false &&
	test_must_be_empty actual &&
	test_grep ! "\"key\":\"preload/bulk_result\"" preload-disabled.trace
'

test_expect_success 'test variable overrides bulk preload configuration' '
	test_env GIT_TEST_PRELOAD_INDEX_BULK=0 \
		configured_bulk_status opt-in actual disabled.trace &&
	test_must_be_empty actual &&
	test_grep ! "\"key\":\"preload/bulk_result\"" disabled.trace &&
	test_env GIT_TEST_PRELOAD_INDEX_BULK=1 \
		configured_bulk_status opt-in actual forced.trace false &&
	test_must_be_empty actual &&
	check_data forced.trace preload/bulk_applied 8
'

test_expect_success 'bulk preload waits for fsmonitor provider closure' '
	write_script opt-in/.git/hooks/fsmonitor-test <<-\EOF &&
	printf "token\\0"
	EOF
	git -C opt-in config core.fsmonitor .git/hooks/fsmonitor-test &&
	configured_bulk_status opt-in actual fsmonitor.trace &&
	test_must_be_empty actual &&
	test_grep ! "\"key\":\"preload/bulk_result\"" fsmonitor.trace
'

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
	check_data clean.trace preload/bulk_applied 8 &&
	check_lstat_data clean.trace 0
'

test_expect_success 'definitive size changes are not restated' '
	setup_repo dirty &&
	test_write_lines changed-content >dirty/root &&
	compare_status dirty dirty.trace &&
	test_file_not_empty actual &&
	check_data dirty.trace preload/bulk_applied 7 &&
	check_data dirty.trace preload/bulk_definitive_modified 1 &&
	test_trace2_data status preload/direct_modified 1 \
		<"$TRASH_DIRECTORY/dirty.trace" &&
	check_lstat_data dirty.trace 0 &&
	check_data dirty.trace refresh/sum_lstat 0
'

test_expect_success 'missing entries bypass speculative lstat' '
	setup_repo missing &&
	rm missing/root &&
	rm -rf missing/nested &&
	compare_status missing missing.trace &&
	test_line_count = 5 actual &&
	check_data missing.trace preload/bulk_applied 3 &&
	check_data missing.trace preload/bulk_definitive_deleted 5 &&
	test_trace2_data status preload/direct_deleted 5 \
		<"$TRASH_DIRECTORY/missing.trace" &&
	check_lstat_data missing.trace 0 &&
	check_data missing.trace refresh/sum_lstat 0
'

test_expect_success 'metadata-only mismatches are checked by diff' '
	setup_repo metadata &&
	test-tool chmtime +60 metadata/root &&
	compare_status metadata metadata.trace &&
	test_must_be_empty actual &&
	check_data metadata.trace preload/bulk_content_check 1 &&
	check_lstat_data metadata.trace 0 &&
	check_data metadata.trace refresh/sum_lstat 0
'

test_expect_success PIPE \
	'tracked directories and unsupported vnodes fall back' '
	setup_repo tracked-types &&
	rm tracked-types/root tracked-types/root-peer &&
	mkdir tracked-types/root &&
	mkfifo tracked-types/root-peer &&
	compare_status tracked-types tracked-types.trace &&
	test_line_count = 2 actual &&
	check_data tracked-types.trace preload/bulk_applied 6 &&
	check_data tracked-types.trace preload/bulk_fallback 2 &&
	check_lstat_data tracked-types.trace 2 &&
	check_data tracked-types.trace refresh/sum_lstat 2
'

test_expect_success CASE_INSENSITIVE_FS \
	'case aliases retain parallel preload' '
	setup_repo case-alias &&
	mv case-alias/root case-alias/ROOT &&
	mv case-alias/nested case-alias/NESTED &&
	git -C case-alias update-index --refresh &&
	compare_status case-alias case-alias.trace &&
	test_must_be_empty actual &&
	check_data case-alias.trace preload/bulk_applied 3 &&
	check_lstat_data case-alias.trace 5 &&
	{
		test_have_prereq !PTHREADS ||
		check_data case-alias.trace refresh/sum_lstat 0
	}
'

test_expect_success ULIMIT_FILE_DESCRIPTORS \
	'bulk preload reopens directories under a low descriptor limit' '
	git init low-fd &&
	for i in $(test_seq 1 64)
	do
		mkdir "low-fd/$i" &&
		test_write_lines "$i" >"low-fd/$i/tracked" ||
		return 1
	done &&
	git -C low-fd add . &&
	git -C low-fd commit -m base &&
	test-tool chmtime -120 low-fd/*/tracked &&
	git -C low-fd update-index --refresh &&
	run_with_limited_open_files \
		bulk_status low-fd actual low-fd.trace &&
	test_must_be_empty actual &&
	check_data low-fd.trace preload/bulk_applied 64
'

test_expect_success 'prefix siblings do not hide tracked descendants' '
	git init prefix-order &&
	mkdir prefix-order/feather prefix-order/feather-db &&
	test_write_lines tracked >prefix-order/feather/tracked &&
	test_write_lines sibling >prefix-order/feather-db/tracked &&
	git -C prefix-order add . &&
	git -C prefix-order commit -m base &&
	test-tool chmtime -120 prefix-order/feather/tracked \
		prefix-order/feather-db/tracked &&
	git -C prefix-order update-index --refresh &&
	bulk_status prefix-order actual prefix-order.trace &&
	test_must_be_empty actual &&
	check_data prefix-order.trace preload/bulk_applied 2 &&
	check_lstat_data prefix-order.trace 0
'

test_expect_success SYMLINKS \
	'modified, deleted, typechanged, and symlink entries agree' '
	setup_repo worktree-states &&
	ln -s root worktree-states/link &&
	git -C worktree-states add link &&
	git -C worktree-states commit -m symlink &&
	mtime=$(test-tool chmtime --get worktree-states/root) &&
	sleep 1 &&
	test_write_lines moot >worktree-states/root &&
	test-tool chmtime "=$mtime" worktree-states/root &&
	rm worktree-states/nested/tracked &&
	rm worktree-states/nested/deep/tracked &&
	mkdir worktree-states/nested/deep/tracked &&
	rm worktree-states/other/tracked worktree-states/other/peer &&
	rmdir worktree-states/other &&
	test_write_lines other >worktree-states/other &&
	rm worktree-states/link &&
	ln -s nested/deep/peer worktree-states/link &&
	compare_status worktree-states worktree-states.trace &&
	test_file_not_empty actual
'

test_expect_success 'staged and unmerged entries agree' '
	setup_repo index-states &&
	test_write_lines staged >index-states/root &&
	test_write_lines added >index-states/added &&
	git -C index-states add root added &&
	git -C index-states rm nested/tracked &&
	base=$(git -C index-states rev-parse HEAD:nested/peer) &&
	ours=$(printf "ours\n" |
		git -C index-states hash-object -w --stdin) &&
	theirs=$(printf "theirs\n" |
		git -C index-states hash-object -w --stdin) &&
	{
		printf "0 %s\tnested/peer\n" "$(test_oid zero)" &&
		printf "100644 %s 1\tnested/peer\n" "$base" &&
		printf "100644 %s 2\tnested/peer\n" "$ours" &&
		printf "100644 %s 3\tnested/peer\n" "$theirs"
	} | git -C index-states update-index --index-info &&
	compare_status index-states index-states.trace &&
	test_file_not_empty actual
'

test_expect_success 'sparse-index entries are left unexpanded' '
	setup_repo sparse &&
	git -C sparse sparse-checkout init --cone --sparse-index &&
	git -C sparse sparse-checkout set nested &&
	git -C sparse ls-files --sparse >before &&
	test_grep "^other/$" before &&
	test_write_lines changed >sparse/nested/tracked &&
	compare_status sparse sparse.trace &&
	git -C sparse ls-files --sparse >after &&
	test_cmp before after
'

test_expect_success UTF8_NFD_TO_NFC \
	'decomposed Unicode names agree' '
	setup_repo unicode &&
	nfc=$(printf "\303\244") &&
	nfd=$(printf "\141\314\210") &&
	git -C unicode config core.precomposeunicode true &&
	test_write_lines unicode >"unicode/$nfd" &&
	git -C unicode add "$nfc" &&
	git -C unicode commit -m unicode &&
	test-tool chmtime -120 "unicode/$nfd" &&
	git -C unicode update-index --refresh &&
	compare_status unicode unicode.trace &&
	test_must_be_empty actual &&
	check_data unicode.trace preload/bulk_applied 9 &&
	check_lstat_data unicode.trace 0
'

test_expect_success 'multiply-linked entries are left to lstat' '
	setup_repo hardlink &&
	# Mutate through a name outside the watched worktree, then restore
	# mtime. The bulk scan must leave the multiply-linked entry to lstat.
	ln hardlink/root hardlink-alias &&
	test-tool chmtime -120 hardlink/root &&
	git -C hardlink update-index --refresh &&
	mtime=$(test-tool chmtime --get hardlink/root) &&
	sleep 1 &&
	test_write_lines moot >hardlink-alias &&
	test-tool chmtime "=$mtime" hardlink/root &&
	compare_status hardlink hardlink.trace &&
	test_file_not_empty actual &&
	check_data hardlink.trace preload/bulk_applied 7 &&
	check_data hardlink.trace preload/bulk_fallback 1 &&
	check_lstat_data hardlink.trace 1 &&
	check_data hardlink.trace refresh/sum_lstat 1
'

test_expect_success PIPE 'queued child replacement discards observations' '
	setup_repo child-race &&
	test_when_finished cleanup_race &&
	start_raced_status child-race nested/deep &&
	mv child-race/nested/deep child-race/nested/deep-away &&
	mkdir child-race/nested/deep &&
	test_write_lines dirty >child-race/nested/deep/tracked &&
	test_write_lines deep-peer >child-race/nested/deep/peer &&
	finish_raced_status child-race &&
	test_file_not_empty actual
'

test_expect_success PIPE,SYMLINKS \
	'worktree root replacement discards observations' '
	setup_repo root-race &&
	test_when_finished cleanup_race &&
	start_raced_status root-race "" &&
	mv root-race root-race-away &&
	ln -s root-race-away root-race &&
	test_write_lines dirty >root-race-away/root &&
	finish_raced_status root-race &&
	test_file_not_empty actual
'

test_done
