#!/bin/sh

test_description='exact clean status sidecars'

. ./test-lib.sh

test_lazy_prereq LOCAL_APFS '
	test_have_prereq MACOS &&
	/bin/df -t apfs "$TRASH_DIRECTORY" >/dev/null
'

if ! test_have_prereq FSMONITOR_DAEMON,LOCAL_APFS,MACOS
then
	skip_all='clean status sidecars require local APFS and the macOS fsmonitor daemon'
	test_done
fi

test_lazy_prereq DURABLE_FSMONITOR '
	test_create_repo durable-fsmonitor-probe || return 1
	(
		cd durable-fsmonitor-probe &&
		test_commit base tracked &&
		git config core.fsmonitor true &&
		git fsmonitor--daemon start --start-timeout=10 &&
		git status --porcelain=v2 >/dev/null &&
		test-tool dump-fsmonitor >token &&
		grep "^fsmonitor last update builtin:" token
		result=$?
		git fsmonitor--daemon stop >/dev/null 2>&1 || :
		exit $result
	)
'

stop_daemon () {
	git -C "$1" fsmonitor--daemon stop 2>/dev/null || :
}

setup_repo () {
	repo=$1 &&
	test_create_repo "$repo" &&
	test_commit -C "$repo" base tracked &&
	test-tool chmtime -120 "$repo/tracked" &&
	git -C "$repo" update-index --refresh &&
	git -C "$repo" config core.fsmonitor true &&
	git -C "$repo" fsmonitor--daemon start --start-timeout=10
}

bulk_status () {
	GIT_TEST_PRELOAD_INDEX=1 \
	GIT_TEST_PRELOAD_INDEX_BULK=1 \
		git "$@"
}

prime_semantic_history () {
	repo=$1 &&
	bulk_status -C "$repo" status --porcelain=2 >actual.1 &&
	test_must_be_empty actual.1 &&
	bulk_status -C "$repo" status --porcelain=2 >actual.2 &&
	test_must_be_empty actual.2 &&
	test_grep FSCF "$repo/.git/index" &&
	rm -f "$repo"/.git/index.csh1.*
}

issue_sidecar () {
	repo=$1 &&
	git -C "$repo" config core.autocrlf false &&
	prime_semantic_history "$repo" &&
	bulk_status -C "$repo" status --porcelain=v2 >actual.issue &&
	test_must_be_empty actual.issue &&
	test_path_is_file "$repo/.git/index.csts"
}

assert_fallback_matches_oracle () {
	repo=$1 &&
	sidecar_trace=$2 &&
	GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
		-c core.untrackedCache=false -C "$repo" \
		status --porcelain=v2 >expect &&
	GIT_OPTIONAL_LOCKS=0 GIT_TRACE2_EVENT="$PWD/$sidecar_trace" \
		git -C "$repo" status --porcelain=v2 >actual &&
	test_cmp expect actual &&
	test_grep ! "\"key\":\"clean-proof/hit\"" "$sidecar_trace"
}

assert_custom_replace_fallback_matches_oracle () {
	repo=$1 &&
	sidecar_trace=$2 &&
	GIT_REPLACE_REF_BASE=refs/status-replace/ \
	GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
		-c core.untrackedCache=false -C "$repo" \
		status --porcelain=v2 >expect &&
	GIT_REPLACE_REF_BASE=refs/status-replace/ \
	GIT_OPTIONAL_LOCKS=0 GIT_TRACE2_EVENT="$PWD/$sidecar_trace" \
		git -C "$repo" status --porcelain=v2 >actual &&
	test_cmp expect actual &&
	test_grep ! "\"key\":\"clean-proof/hit\"" "$sidecar_trace"
}

replacement_tree () {
	repo=$1 &&
	blob=$(printf "replacement\n" |
		git -C "$repo" hash-object -w --stdin) &&
	printf "100644 blob %s\ttracked\n" "$blob" |
		git -C "$repo" mktree
}

cleanup_fast_race () {
	if test -n "$status_pid"
	then
		kill "$status_pid" 2>/dev/null || :
		wait "$status_pid" 2>/dev/null || :
	fi &&
	status_pid= &&
	exec 9>&- &&
	rm -f "$ready" "$resume"
}

wait_for_fast_ready () {
	for i in $(test_seq 1 1000)
	do
		test "$(cat "$ready" 2>/dev/null)" = ready && return 0
		kill -0 "$status_pid" 2>/dev/null || return 1
		sleep 0.01
	done
	return 1
}

start_fast_raced_status () {
	repo=$1 &&
	ready=$TRASH_DIRECTORY/$repo.fast-ready &&
	resume=$TRASH_DIRECTORY/$repo.fast-resume &&
	race_trace=$TRASH_DIRECTORY/$repo.fast-trace &&
	status_pid= &&
	rm -f "$ready" "$resume" "$race_trace" &&
	: >"$ready" &&
	mkfifo "$resume" &&
	exec 9<>"$resume" &&
	{
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_STATUS_CLEAN_SIDECAR_BARRIER_READY="$ready" \
		GIT_TEST_STATUS_CLEAN_SIDECAR_BARRIER_RESUME="$resume" \
		GIT_TRACE2_EVENT="$race_trace" \
			git -C "$repo" status --porcelain=v2 \
			>raced.actual 9>&- &
		status_pid=$!
	} &&
	wait_for_fast_ready
}

start_issue_raced_status () {
	repo=$1 &&
	ready=$TRASH_DIRECTORY/$repo.issue-ready &&
	resume=$TRASH_DIRECTORY/$repo.issue-resume &&
	race_trace=$TRASH_DIRECTORY/$repo.issue-trace &&
	status_pid= &&
	rm -f "$ready" "$resume" "$race_trace" &&
	: >"$ready" &&
	mkfifo "$resume" &&
	exec 9<>"$resume" &&
	{
		test_env \
		GIT_TEST_STATUS_CLEAN_SIDECAR_ISSUE_BARRIER_READY="$ready" \
		GIT_TEST_STATUS_CLEAN_SIDECAR_ISSUE_BARRIER_RESUME="$resume" \
		GIT_TRACE2_EVENT="$race_trace" \
			bulk_status -C "$repo" status --porcelain=v2 \
			>raced.actual 9>&- &
		status_pid=$!
	} &&
	wait_for_fast_ready
}

stop_after_fast_fallback () {
	for i in $(test_seq 1 1000)
	do
		if grep -q "\"value\":\"fast-excludes-raced\"" \
			"$race_trace"
		then
			kill "$status_pid" 2>/dev/null || return 1
			wait "$status_pid" 2>/dev/null || :
			status_pid=
			return 0
		fi
		kill -0 "$status_pid" 2>/dev/null || return 1
		sleep 0.01
	done
	return 1
}

finish_fast_raced_status () {
	printf "resume\n" >&9 &&
	exec 9>&- &&
	wait "$status_pid" &&
	status_pid=
}

test_expect_success DURABLE_FSMONITOR \
	'exact clean status installs a sidecar without rewriting the index' '
	test_when_finished "stop_daemon sidecar-issue" &&
	setup_repo sidecar-issue &&
	test_env GIT_TRACE2_EVENT="$PWD/first-scan.trace" \
		bulk_status -C sidecar-issue status --porcelain=v2 \
		>actual.first &&
	test_must_be_empty actual.first &&
	test_path_is_missing sidecar-issue/.git/index.csts &&

	git -C sidecar-issue config core.autocrlf false &&
	prime_semantic_history sidecar-issue &&
	cp sidecar-issue/.git/index index.before &&

	test_env GIT_TRACE2_EVENT="$PWD/issue.trace" \
		bulk_status -C sidecar-issue status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_cmp index.before sidecar-issue/.git/index &&
	test_path_is_file sidecar-issue/.git/index.csts &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<issue.trace &&
	test_grep \
		"\"key\":\"preload/bulk_untracked_complete\",\"value\":\"1\"" \
		issue.trace &&
	test_grep "\"key\":\"preload/bulk_provider_applied\"" issue.trace &&
	test_grep "\"key\":\"clean-proof/sidecar\"" issue.trace &&
	test_grep ! "\"label\":\"do_write_index\"" issue.trace &&

	GIT_TRACE2_EVENT="$PWD/hit.trace" \
		git -C sidecar-issue status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"clean-proof/hit\"" hit.trace &&
	test_grep ! "\"label\":\"do_read_index\"" hit.trace
'

test_expect_success DURABLE_FSMONITOR \
	'dirty exact status checkpoints history without certifying cleanliness' '
	test_when_finished "stop_daemon external-dirty-exact" &&
	setup_repo external-dirty-exact &&
	git -C external-dirty-exact config core.untrackedCache true &&
	prime_semantic_history external-dirty-exact &&
	test_write_lines changed >external-dirty-exact/tracked &&
	test-tool chmtime -60 external-dirty-exact/tracked &&
	bulk_status -C external-dirty-exact status --porcelain=2 \
		>external-dirty-exact.primed &&
	test_env GIT_TRACE2_EVENT="$PWD/external-dirty-exact.trace" \
		bulk_status -C external-dirty-exact status --porcelain=v2 \
		>actual &&
	test_grep "^1 \.M .* tracked$" actual &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<external-dirty-exact.trace &&
	test_path_is_missing external-dirty-exact/.git/index.csts &&
	find external-dirty-exact/.git -maxdepth 1 -type f \
		-name "index.csh1.*" >external-dirty-exact.checkpoints &&
	test_line_count = 1 external-dirty-exact.checkpoints
'

test_expect_success DURABLE_FSMONITOR \
	'daemon-shaped dirty status checkpoints resumable history' '
	test_when_finished "stop_daemon external-daemon-shape" &&
	setup_repo external-daemon-shape &&
	git -C external-daemon-shape config core.untrackedCache true &&
	prime_semantic_history external-daemon-shape &&
	test_write_lines changed >external-daemon-shape/tracked &&
	test-tool chmtime -60 external-daemon-shape/tracked &&
	bulk_status -C external-daemon-shape status --porcelain=2 \
		>external-daemon-shape.primed &&
	test_env GIT_TRACE2_EVENT="$PWD/external-daemon-shape.trace" \
		bulk_status -C external-daemon-shape \
			status --porcelain=v2 -z --branch --show-stash \
			--no-ahead-behind --untracked-files=normal \
			--ignore-submodules=all >actual &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<external-daemon-shape.trace &&
	test_path_is_missing external-daemon-shape/.git/index.csts &&
	find external-daemon-shape/.git -maxdepth 1 -type f \
		-name "index.csh1.*" >external-daemon-shape.checkpoints &&
	test_line_count = 1 external-daemon-shape.checkpoints
'

test_expect_success DURABLE_FSMONITOR \
	'nested status uses root-wide resumable history' '
	test_when_finished "stop_daemon external-nested-status" &&
	setup_repo external-nested-status &&
	git -C external-nested-status config core.untrackedCache true &&
	prime_semantic_history external-nested-status &&
	mkdir -p external-nested-status/deep/inside &&
	test_write_lines changed >external-nested-status/tracked &&
	test-tool chmtime -60 external-nested-status/tracked &&
	bulk_status -C external-nested-status status --porcelain=2 \
		>external-nested-status.primed &&
	test_env GIT_TRACE2_EVENT="$PWD/external-nested-status.trace" \
		bulk_status -C external-nested-status/deep/inside \
			status --porcelain=v2 >actual &&
	test_grep "^1 \.M .* \.\./\.\./tracked$" actual &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<external-nested-status.trace &&
	find external-nested-status/.git -maxdepth 1 -type f \
		-name "index.csh1.*" >external-nested-status.checkpoints &&
	test_line_count = 1 external-nested-status.checkpoints
'

test_expect_success DURABLE_FSMONITOR \
	'normal status persists bootstrap stat repairs' '
	test_when_finished "stop_daemon external-stat-bootstrap" &&
	setup_repo external-stat-bootstrap &&
	git -C external-stat-bootstrap update-index --fsmonitor &&
	test_env GIT_TRACE2_EVENT="$PWD/external-stat-bootstrap.trace" \
		git -C external-stat-bootstrap status >actual &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<external-stat-bootstrap.trace &&
	test_grep "\"label\":\"do_write_index\"" \
		external-stat-bootstrap.trace &&
	git -C external-stat-bootstrap -c core.fsmonitor=false \
		diff-index --quiet HEAD
'

test_expect_success DURABLE_FSMONITOR \
	'exact status persists stat repairs before a sidecar' '
	test_when_finished "stop_daemon external-stat-exact" &&
	setup_repo external-stat-exact &&
	git -C external-stat-exact config core.autocrlf false &&
	prime_semantic_history external-stat-exact &&
	test-tool chmtime -60 external-stat-exact/tracked &&
	test-tool -C external-stat-exact fsmonitor-client flush >flush.out &&
	test_env GIT_TRACE2_EVENT="$PWD/external-stat-exact.trace" \
		bulk_status -C external-stat-exact status --porcelain=v2 \
		>actual &&
	test_must_be_empty actual &&
	! test_trace2_data fsmonitor history/external-stored 1 \
		<external-stat-exact.trace &&
	test_path_is_missing external-stat-exact/.git/index.csts &&
	test_grep "\"label\":\"do_write_index\"" \
		external-stat-exact.trace &&
	git -C external-stat-exact -c core.fsmonitor=false \
		diff-index --quiet HEAD &&

	test_env GIT_TRACE2_EVENT="$PWD/external-stat-exact-issue.trace" \
		bulk_status -C external-stat-exact status --porcelain=v2 \
		>actual &&
	test_must_be_empty actual &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<external-stat-exact-issue.trace &&
	test_path_is_file external-stat-exact/.git/index.csts &&
	test_grep ! "\"label\":\"do_write_index\"" \
		external-stat-exact-issue.trace
'

test_expect_success DURABLE_FSMONITOR \
	'exact clean status certifies an existing untracked cache' '
	test_when_finished "stop_daemon sidecar-untracked-cache" &&
	setup_repo sidecar-untracked-cache &&
	git -C sidecar-untracked-cache config core.untrackedCache true &&
	git -C sidecar-untracked-cache config core.autocrlf false &&
	bulk_status -C sidecar-untracked-cache status --porcelain=2 \
		>actual.1 &&
	test_must_be_empty actual.1 &&
	bulk_status -C sidecar-untracked-cache status --porcelain=2 \
		>actual.2 &&
	test_must_be_empty actual.2 &&
	test_grep UNTR sidecar-untracked-cache/.git/index &&

	test_env GIT_TRACE2_EVENT="$PWD/untracked-cache-issue.trace" \
		bulk_status -C sidecar-untracked-cache \
			status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_path_is_file sidecar-untracked-cache/.git/index.csts &&
	test_grep ! \
		"\"key\":\"preload/bulk_useful\"" \
		untracked-cache-issue.trace &&
	test_grep \
		"\"event\":\"region_enter\".*\"category\":\"dir\",\"label\":\"read_directory\"" \
		untracked-cache-issue.trace >untracked-cache-read-directory &&
	test_line_count = 1 untracked-cache-read-directory &&
	test_grep "\"key\":\"proof_valid\",\"value\":\"1\"" \
		untracked-cache-issue.trace &&
	test_grep FSUC sidecar-untracked-cache/.git/index &&

	GIT_TRACE2_EVENT="$PWD/untracked-cache-hit.trace" \
		git -C sidecar-untracked-cache status --porcelain=v2 \
			>actual &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"clean-proof/hit\"" \
		untracked-cache-hit.trace &&
	test_grep ! "\"label\":\"do_read_index\"" \
		untracked-cache-hit.trace
'

test_expect_success POSIXPERM,DURABLE_FSMONITOR \
	'an incomplete untracked traversal cannot issue a sidecar' '
	test_when_finished "stop_daemon sidecar-unreadable" &&
	setup_repo sidecar-unreadable &&
	git -C sidecar-unreadable config core.untrackedCache true &&
	git -C sidecar-unreadable config core.autocrlf false &&
	prime_semantic_history sidecar-unreadable &&
	mkdir sidecar-unreadable/hidden &&
	test_when_finished "chmod u+rwx sidecar-unreadable/hidden" &&
	test_write_lines untracked >sidecar-unreadable/hidden/untracked &&
	chmod a-r sidecar-unreadable/hidden &&

	test_env GIT_TRACE2_EVENT="$PWD/unreadable.trace" \
		bulk_status -C sidecar-unreadable \
			status --porcelain=v2 >actual 2>err &&
	test_must_be_empty actual &&
	test_grep "could not open directory .hidden/." err &&
	test_path_is_missing sidecar-unreadable/.git/index.csts &&
	test_grep "\"value\":\"issue-scan-or-index-shape\"" \
		unreadable.trace &&

	chmod u+rwx sidecar-unreadable/hidden &&
	git -C sidecar-unreadable status --porcelain=v2 >actual &&
	test_grep "^? hidden/" actual
'

test_expect_success DURABLE_FSMONITOR \
	'a replaced worktree root cannot inherit a sidecar' '
	test_when_finished "stop_daemon sidecar-root-race" &&
	test_when_finished "stop_daemon sidecar-root-race.scanned" &&
	test_when_finished "cleanup_fast_race" &&
	setup_repo sidecar-root-race &&
	git -C sidecar-root-race config core.untrackedCache true &&
	git -C sidecar-root-race config core.autocrlf false &&
	prime_semantic_history sidecar-root-race &&
	cp -R sidecar-root-race sidecar-root-race.replacement &&
	test_write_lines replacement-only \
		>sidecar-root-race.replacement/replacement-only &&
	rm -f sidecar-root-race.replacement/.git/index.csts &&

	start_issue_raced_status sidecar-root-race &&
	mv sidecar-root-race sidecar-root-race.scanned &&
	mv sidecar-root-race.replacement sidecar-root-race &&
	finish_fast_raced_status &&

	test_must_be_empty raced.actual &&
	test_path_is_missing sidecar-root-race/.git/index.csts &&
	test_grep \
		"\"category\":\"dir\",\"label\":\"read_directory\"" \
		"$race_trace" &&
	test_grep ! \
		"\"key\":\"preload/bulk_untracked_complete\",\"value\":\"1\"" \
		"$race_trace" &&
	test_grep "\"key\":\"proof_valid\",\"value\":\"1\"" "$race_trace" &&
	test_grep "\"value\":\"issue-pinned-inputs\"" "$race_trace"
'

test_expect_success PIPE,DURABLE_FSMONITOR \
	'an existing per-directory exclude FIFO cannot block sidecar issuance' '
	test_when_finished "stop_daemon sidecar-issue-fifo" &&
	setup_repo sidecar-issue-fifo &&
	test_when_finished "rm -f sidecar-issue-fifo/.gitignore" &&
	git -C sidecar-issue-fifo config core.untrackedCache true &&
	git -C sidecar-issue-fifo config core.autocrlf false &&
	prime_semantic_history sidecar-issue-fifo &&
	mkfifo sidecar-issue-fifo/.gitignore &&

	test_env GIT_TRACE2_EVENT="$PWD/issue-fifo.trace" \
		bulk_status -C sidecar-issue-fifo \
			status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_path_is_file sidecar-issue-fifo/.git/index.csts &&
	test_grep "\"key\":\"clean-proof/sidecar\"" issue-fifo.trace
'

test_expect_success DURABLE_FSMONITOR \
	'a clean exact status replaces a stale sidecar' '
	test_when_finished "stop_daemon sidecar-reissue" &&
	setup_repo sidecar-reissue &&
	git -C sidecar-reissue config core.untrackedCache true &&
	issue_sidecar sidecar-reissue &&
	test_write_lines untracked >sidecar-reissue/untracked &&
	git -C sidecar-reissue status --porcelain=2 >dirty &&
	test_grep "^? untracked$" dirty &&
	rm sidecar-reissue/untracked &&

	test_env GIT_TRACE2_EVENT="$PWD/reissue.trace" \
		bulk_status -C sidecar-reissue status --porcelain=v2 \
			>actual &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"clean-proof/sidecar\"" reissue.trace &&
	test_grep ! \
		"\"key\":\"preload/bulk_useful\"" \
		reissue.trace &&
	test_grep \
		"\"event\":\"region_enter\".*\"category\":\"dir\",\"label\":\"read_directory\"" \
		reissue.trace >reissue-read-directory &&
	test_line_count = 1 reissue-read-directory &&
	test_grep ! "\"label\":\"do_write_index\"" reissue.trace &&

	GIT_TRACE2_EVENT="$PWD/reissued-hit.trace" \
		git -C sidecar-reissue status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"clean-proof/hit\"" reissued-hit.trace &&
	test_grep ! "\"label\":\"do_read_index\"" reissued-hit.trace
'

test_expect_success DURABLE_FSMONITOR \
	'only an exact empty output installs a sidecar' '
	test_when_finished "stop_daemon sidecar-shape" &&
	setup_repo sidecar-shape &&
	prime_semantic_history sidecar-shape &&

	bulk_status -C sidecar-shape status --porcelain=2 >actual &&
	test_must_be_empty actual &&
	test_path_is_missing sidecar-shape/.git/index.csts &&

	bulk_status -C sidecar-shape status --porcelain=v2 --branch >actual &&
	test_grep "^# branch.oid " actual &&
	test_path_is_missing sidecar-shape/.git/index.csts &&

	echo changed >sidecar-shape/tracked &&
	bulk_status -C sidecar-shape status --porcelain=v2 >actual &&
	test_grep "^1 .M " actual &&
	test_path_is_missing sidecar-shape/.git/index.csts
'

test_expect_success DURABLE_FSMONITOR \
	'external attributes and alternate indexes are rejected' '
	test_when_finished "stop_daemon sidecar-inputs" &&
	setup_repo sidecar-inputs &&
	prime_semantic_history sidecar-inputs &&

	test_write_lines "tracked -text" \
		>sidecar-inputs/.git/info/attributes &&
	bulk_status -C sidecar-inputs status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_path_is_missing sidecar-inputs/.git/index.csts &&

	rm sidecar-inputs/.git/info/attributes &&
	cp sidecar-inputs/.git/index sidecar-inputs/.git/alternate-index &&
	test_env GIT_INDEX_FILE="$PWD/sidecar-inputs/.git/alternate-index" \
		bulk_status -C sidecar-inputs status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_path_is_missing sidecar-inputs/.git/alternate-index.csts
'

test_expect_success DURABLE_FSMONITOR \
	'a fast hit remains read-only without optional locks' '
	test_when_finished "stop_daemon sidecar-read-only" &&
	setup_repo sidecar-read-only &&
	issue_sidecar sidecar-read-only &&
	cp sidecar-read-only/.git/index.csts sidecar.before &&

	GIT_OPTIONAL_LOCKS=0 GIT_TRACE2_EVENT="$PWD/read-only.trace" \
		git -C sidecar-read-only status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"clean-proof/hit\"" read-only.trace &&
	test_grep ! "\"label\":\"do_read_index\"" read-only.trace &&
	test_cmp sidecar.before sidecar-read-only/.git/index.csts
'

test_expect_success DURABLE_FSMONITOR \
	'provider changes fall back for each dirty worktree shape' '
	test_when_finished "stop_daemon sidecar-modified" &&
	test_when_finished "stop_daemon sidecar-deleted" &&
	test_when_finished "stop_daemon sidecar-renamed" &&
	test_when_finished "stop_daemon sidecar-untracked" &&

	setup_repo sidecar-modified &&
	issue_sidecar sidecar-modified &&
	echo changed >sidecar-modified/tracked &&
	assert_fallback_matches_oracle sidecar-modified modified.trace &&
	test_grep "^1 .M " actual &&

	setup_repo sidecar-deleted &&
	issue_sidecar sidecar-deleted &&
	rm sidecar-deleted/tracked &&
	assert_fallback_matches_oracle sidecar-deleted deleted.trace &&
	test_grep "^1 .D " actual &&

	setup_repo sidecar-renamed &&
	issue_sidecar sidecar-renamed &&
	mv sidecar-renamed/tracked sidecar-renamed/renamed &&
	assert_fallback_matches_oracle sidecar-renamed renamed.trace &&
	test_grep "^1 .D " actual &&
	test_grep "^? renamed" actual &&

	setup_repo sidecar-untracked &&
	issue_sidecar sidecar-untracked &&
	echo untracked >sidecar-untracked/new-file &&
	assert_fallback_matches_oracle sidecar-untracked untracked.trace &&
	test_grep "^? new-file" actual
'

test_expect_success DURABLE_FSMONITOR \
	'loose and packed replace refs invalidate a sidecar' '
	test_when_finished "stop_daemon sidecar-replace" &&
	setup_repo sidecar-replace &&
	issue_sidecar sidecar-replace &&
	old_tree=$(git -C sidecar-replace rev-parse "HEAD^{tree}") &&
	new_tree=$(replacement_tree sidecar-replace) &&
	git -C sidecar-replace replace "$old_tree" "$new_tree" &&

	assert_fallback_matches_oracle sidecar-replace replace-loose.trace &&
	test_grep "^1 M. " actual &&
	git -C sidecar-replace pack-refs --all &&
	test_path_is_missing \
		"sidecar-replace/.git/refs/replace/$old_tree" &&
	assert_fallback_matches_oracle sidecar-replace replace-packed.trace &&
	test_grep "^1 M. " actual
'

test_expect_success DURABLE_FSMONITOR \
	'a custom replace namespace invalidates a sidecar' '
	test_when_finished "stop_daemon sidecar-custom-replace" &&
	setup_repo sidecar-custom-replace &&
	issue_sidecar sidecar-custom-replace &&
	old_tree=$(git -C sidecar-custom-replace rev-parse "HEAD^{tree}") &&
	new_tree=$(replacement_tree sidecar-custom-replace) &&
	GIT_REPLACE_REF_BASE=refs/status-replace/ \
		git -C sidecar-custom-replace update-ref \
		"refs/status-replace/$old_tree" "$new_tree" &&

	assert_custom_replace_fallback_matches_oracle \
		sidecar-custom-replace replace-custom.trace &&
	test_grep "^1 M. " actual
'

test_expect_success PIPE,DURABLE_FSMONITOR \
	'a sidecar FIFO cannot block or supply a hit' '
	test_when_finished "stop_daemon sidecar-fifo" &&
	test_when_finished "rm -f sidecar-fifo/.git/index.csts" &&
	setup_repo sidecar-fifo &&
	issue_sidecar sidecar-fifo &&
	rm sidecar-fifo/.git/index.csts &&
	mkfifo sidecar-fifo/.git/index.csts &&

	GIT_OPTIONAL_LOCKS=0 GIT_TRACE2_EVENT="$PWD/fifo.trace" \
		git -C sidecar-fifo status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_grep ! "\"key\":\"clean-proof/hit\"" fifo.trace &&
	test_grep "\"value\":\"fast-sidecar-missing-or-corrupt\"" fifo.trace
'

test_expect_success DURABLE_FSMONITOR \
	'non-provider proof inputs invalidate a sidecar' '
	test_when_finished "stop_daemon sidecar-metadata" &&
	setup_repo sidecar-metadata &&
	issue_sidecar sidecar-metadata &&

	git -C sidecar-metadata config status.relativePaths false &&
	assert_fallback_matches_oracle sidecar-metadata config.trace &&
	test_grep "\"value\":\"fast-config-changed\"" config.trace &&
	git -C sidecar-metadata config --unset status.relativePaths &&

	cp sidecar-metadata/.git/info/exclude info-exclude &&
	test_write_lines ignored >sidecar-metadata/.git/info/exclude &&
	assert_fallback_matches_oracle sidecar-metadata exclude.trace &&
	test_grep "\"value\":\"fast-excludes\"" exclude.trace &&
	mv info-exclude sidecar-metadata/.git/info/exclude &&

	test_write_lines "tracked ident" \
		>sidecar-metadata/.git/info/attributes &&
	assert_fallback_matches_oracle sidecar-metadata attributes.trace &&
	test_grep "\"value\":\"fast-repository-unavailable\"" attributes.trace &&
	rm sidecar-metadata/.git/info/attributes &&

	blob=$(printf "different\n" |
		git -C sidecar-metadata hash-object -w --stdin) &&
	tree=$(printf "100644 blob %s\ttracked\n" "$blob" |
		git -C sidecar-metadata mktree) &&
	commit=$(printf "different tree\n" |
		git -C sidecar-metadata commit-tree "$tree" -p HEAD) &&
	git -C sidecar-metadata update-ref HEAD "$commit" &&
	assert_fallback_matches_oracle sidecar-metadata head.trace &&
	test_grep "\"value\":\"fast-head-changed\"" head.trace &&
	test_grep "^1 M. " actual
'

test_expect_success DURABLE_FSMONITOR \
	'a v4 skipHash index uses durable identity for a clean proof' '
	test_when_finished "stop_daemon sidecar-v4" &&
	setup_repo sidecar-v4 &&
	prime_semantic_history sidecar-v4 &&
	git -C sidecar-v4 config index.version 4 &&
	git -C sidecar-v4 config index.skipHash true &&
	git -C sidecar-v4 update-index --force-write-index &&
	git -C sidecar-v4 config core.autocrlf false &&
	prime_semantic_history sidecar-v4 &&

	dd if=/dev/zero of=zeros bs=20 count=1 2>/dev/null &&
	tail -c 20 sidecar-v4/.git/index >trailer &&
	test_cmp_bin zeros trailer &&
	test_env GIT_TRACE2_EVENT="$PWD/v4.trace" \
		bulk_status -C sidecar-v4 status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_path_is_file sidecar-v4/.git/index.csts &&
	test_grep "\"key\":\"clean-proof/sidecar\"" v4.trace &&

	GIT_OPTIONAL_LOCKS=0 GIT_TRACE2_EVENT="$PWD/v4-hit.trace" \
		git -C sidecar-v4 status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"clean-proof/hit\"" v4-hit.trace &&
	test_grep ! "\"label\":\"do_read_index\"" v4-hit.trace &&

	# Rewriting the same zero-checksum entries changes the durable identity.
	git -C sidecar-v4 update-index --force-write-index &&
	GIT_OPTIONAL_LOCKS=0 GIT_TRACE2_EVENT="$PWD/v4-rewrite.trace" \
		git -C sidecar-v4 status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_grep ! "\"key\":\"clean-proof/hit\"" v4-rewrite.trace &&
	test_grep "\"value\":\"fast-index-mismatch\"" v4-rewrite.trace
'

test_expect_success PIPE,DURABLE_FSMONITOR \
	'an existing exclude FIFO cannot block fast-path capture' '
	test_when_finished "stop_daemon sidecar-exclude-fifo" &&
	setup_repo sidecar-exclude-fifo &&
	exclude_file=$(mktemp \
		"${TMPDIR:-/tmp}/git-status-exclude-fifo.XXXXXX") &&
	test_when_finished "rm -f \"$exclude_file\"" &&
	git -C sidecar-exclude-fifo config core.excludesFile \
		"$exclude_file" &&
	issue_sidecar sidecar-exclude-fifo &&
	rm "$exclude_file" &&
	mkfifo "$exclude_file" &&

	GIT_OPTIONAL_LOCKS=0 GIT_TRACE2_EVENT="$PWD/exclude-fifo.trace" \
		git -C sidecar-exclude-fifo status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"clean-proof/hit\"" exclude-fifo.trace
'

test_expect_success PIPE,DURABLE_FSMONITOR \
	'a raced exclude FIFO cannot block sidecar validation' '
	test_when_finished "stop_daemon sidecar-exclude-race" &&
	test_when_finished "cleanup_fast_race" &&
	setup_repo sidecar-exclude-race &&
	exclude_file=$(mktemp \
		"${TMPDIR:-/tmp}/git-status-exclude-race.XXXXXX") &&
	test_when_finished "rm -f \"$exclude_file\"" &&
	test_write_lines ignored >"$exclude_file" &&
	git -C sidecar-exclude-race config core.excludesFile \
		"$exclude_file" &&
	issue_sidecar sidecar-exclude-race &&

	start_fast_raced_status sidecar-exclude-race &&
	rm "$exclude_file" &&
	mkfifo "$exclude_file" &&
	printf "resume\n" >&9 &&
	exec 9>&- &&
	stop_after_fast_fallback &&
	test_must_be_empty raced.actual &&
	test_grep ! "\"key\":\"clean-proof/hit\"" "$race_trace" &&
	test_grep "\"value\":\"fast-excludes-raced\"" "$race_trace"
'

test_expect_success PIPE,DURABLE_FSMONITOR \
	'a replace ref created after the provider query prevents a hit' '
	test_when_finished "stop_daemon sidecar-replace-race" &&
	test_when_finished "cleanup_fast_race" &&
	setup_repo sidecar-replace-race &&
	issue_sidecar sidecar-replace-race &&
	old_tree=$(git -C sidecar-replace-race rev-parse "HEAD^{tree}") &&
	new_tree=$(replacement_tree sidecar-replace-race) &&

	start_fast_raced_status sidecar-replace-race &&
	git -C sidecar-replace-race update-ref \
		"refs/replace/$old_tree" "$new_tree" &&
	finish_fast_raced_status &&
	test_grep ! "\"key\":\"clean-proof/hit\"" "$race_trace" &&
	test_grep "\"value\":\"fast-repository-raced\"" "$race_trace"
'

test_expect_success DURABLE_FSMONITOR \
	'normal status restores namespace-specific history outside the index' '
	test_when_finished "stop_daemon external-history" &&
	setup_repo external-history &&
	mkdir -p external-history/cached/deep &&
	test_commit -C external-history nested cached/deep/tracked &&
	test-tool -C external-history chmtime =-60 cached/deep/tracked &&
	git -C external-history update-index --refresh &&
	git -C external-history config core.untrackedCache true &&
	git -C external-history config index.skipHash true &&
	git -C external-history config status.renameLimit 100 &&
	git -C external-history update-index \
		--index-version=4 --force-write-index &&
	prime_semantic_history external-history &&
	test "$(git -C external-history \
		update-index --show-index-version)" = 4 &&
	test_grep FSMN external-history/.git/index &&
	test_grep UNTR external-history/.git/index &&
	test_grep FSCF external-history/.git/index &&
	test_grep FSUC external-history/.git/index &&
	dd if=/dev/zero of=external-zeros bs=20 count=1 2>/dev/null &&
	tail -c 20 external-history/.git/index >external-trailer &&
	test_cmp_bin external-zeros external-trailer &&
	git -C external-history ls-files --stage >baseline.stage &&
	cp external-history/.git/index namespace-a-v4.index &&

	# Namespace B recovers once, but leaves namespace A in the main index.
	git -C external-history config status.renameLimit 200 &&
	cp external-history/.git/index seed.before &&
	test_env GIT_TRACE2_EVENT="$PWD/external-seed.trace" \
		git -C external-history status >actual.seed &&
	test_grep "nothing to commit, working tree clean" actual.seed &&
	test_cmp seed.before external-history/.git/index &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<external-seed.trace &&
	test_path_is_missing external-history/.git/index.csts &&
	test_grep ! "\"label\":\"do_write_index\"" external-seed.trace &&
	find external-history/.git -maxdepth 1 -type f \
		-name "index.csh1.*" >external-sidecars &&
	test_line_count = 1 external-sidecars &&
	sidecar=$(cat external-sidecars) &&

	# Namespace A rewrites the same entries in a different physical format.
	cp "$sidecar" sidecar.before-rewrite &&
	git -C external-history config status.renameLimit 100 &&
	git -C external-history update-index \
		--index-version=2 --force-write-index &&
	test "$(git -C external-history \
		update-index --show-index-version)" = 2 &&
	! cmp namespace-a-v4.index external-history/.git/index &&
	git -C external-history ls-files --stage >namespace-a-v2.stage &&
	test_cmp baseline.stage namespace-a-v2.stage &&
	test_grep FSMN external-history/.git/index &&
	test_grep UNTR external-history/.git/index &&
	test_grep FSCF external-history/.git/index &&
	test_grep FSUC external-history/.git/index &&
	tail -c 20 external-history/.git/index >external-trailer &&
	test_cmp_bin external-zeros external-trailer &&
	test_cmp sidecar.before-rewrite "$sidecar" &&

	git -C external-history config status.renameLimit 200 &&
	test_cmp sidecar.before-rewrite "$sidecar" &&
	cp external-history/.git/index namespace-a-v2.index &&
	test_env GIT_TRACE2_EVENT="$PWD/external-restore.trace" \
		git -C external-history status >actual.restore &&
	test_grep "nothing to commit, working tree clean" actual.restore &&
	test_cmp namespace-a-v2.index external-history/.git/index &&
	test_trace2_data fsmonitor history/external-restored 1 \
		<external-restore.trace &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<external-restore.trace &&
	test_trace2_data fsmonitor config/coherent 1 \
		<external-restore.trace &&
	test_trace2_data status clean-proof/sidecar 1 \
		<external-restore.trace &&
	test_path_is_file external-history/.git/index.csts &&
	test_grep ! \
		"\"key\":\"refresh/sum_lstat\",\"value\":\"[1-9]" \
		external-restore.trace &&
	! test_trace2_data status semantic_verify/prepared 1 \
		<external-restore.trace &&
	! test_trace2_data fsmonitor semantic/manifest-scan-count \
		<external-restore.trace &&
	test_trace2_data read_directory opendir 0 \
		<external-restore.trace &&
	test_grep ! "\"label\":\"do_write_index\"" external-restore.trace &&

	# The physical proof skips both logical digests on the next plain status,
	# while still using the normal long-status printer.
	GIT_OPTIONAL_LOCKS=0 GIT_TRACE2_EVENT="$PWD/external-fast.trace" \
		git -C external-history status >actual.fast &&
	test_cmp actual.restore actual.fast &&
	test_trace2_data status clean-proof/hit 1 \
		<external-fast.trace &&
	test_grep ! "\"label\":\"do_read_index\"" external-fast.trace &&
	test_grep ! "\"label\":\"history_logical_digest\"" \
		external-fast.trace &&
	test_grep ! "\"key\":\"preload/sum_lstat\"" external-fast.trace &&
	test_grep ! "\"key\":\"refresh/sum_lstat\"" external-fast.trace &&
	test_grep ! \
		"\"event\":\"region_enter\".*\"category\":\"dir\",\"label\":\"read_directory\"" \
		external-fast.trace &&

	# The proof does not cache long output: same-tree branch metadata stays
	# live without reading the index.
	git -C external-history branch sidecar-live &&
	git -C external-history symbolic-ref HEAD refs/heads/sidecar-live &&
	GIT_OPTIONAL_LOCKS=0 GIT_TRACE2_EVENT="$PWD/external-branch.trace" \
		git -C external-history status >actual.branch &&
	test_grep "^On branch sidecar-live$" actual.branch &&
	test_trace2_data status clean-proof/hit 1 \
		<external-branch.trace &&
	test_grep ! "\"label\":\"do_read_index\"" external-branch.trace &&

	# In-progress operation state is also read live on a fast hit.
	git -C external-history rev-parse HEAD \
		>external-history/.git/MERGE_HEAD &&
	GIT_OPTIONAL_LOCKS=0 GIT_TRACE2_EVENT="$PWD/external-merge.trace" \
		git -C external-history status >actual.merge &&
	test_grep "All conflicts fixed but you are still merging" \
		actual.merge &&
	test_trace2_data status clean-proof/hit 1 \
		<external-merge.trace &&
	test_grep ! "\"label\":\"do_read_index\"" external-merge.trace &&
	rm external-history/.git/MERGE_HEAD &&

	# A root-only dirty event stays shallow after external FSUC restore and
	# advances only the external acceleration history.
	rm -f external-history/.git/index.csts &&
	cp "$sidecar" sidecar.before-dirty &&
	: >external-history/root-probe &&
	sleep 1 &&
	test_env GIT_TRACE2_EVENT_NESTING=10 \
		GIT_TRACE2_EVENT="$PWD/external-dirty.trace" \
		git -C external-history status >actual.dirty &&
	test_grep root-probe actual.dirty &&
	test_trace2_data fsmonitor history/external-physical-alias 1 \
		<external-dirty.trace &&
	test_grep ! "\"label\":\"history_logical_digest\"" \
		external-dirty.trace &&
	test_trace2_data read_directory directories-visited 1 \
		<external-dirty.trace &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<external-dirty.trace &&
	test_grep ! "\"label\":\"do_write_index\"" external-dirty.trace &&
	! test_cmp sidecar.before-dirty "$sidecar" &&
	rm external-history/root-probe &&

	# A failed checkpoint refresh must not spill namespace B into main.
	cp namespace-a-v2.index namespace-a-v2.rewrite &&
	mv namespace-a-v2.rewrite external-history/.git/index &&
	: >"$sidecar.lock" &&
	test_when_finished "rm -f \"$sidecar.lock\"" &&
	cp external-history/.git/index locked.before &&
	test_env GIT_TRACE2_EVENT="$PWD/external-locked.trace" \
		git -C external-history status >actual.locked &&
	test_grep "nothing to commit, working tree clean" actual.locked &&
	test_cmp locked.before external-history/.git/index &&
	test_trace2_data fsmonitor history/external-restored 1 \
		<external-locked.trace &&
	! test_trace2_data fsmonitor history/external-stored \
		<external-locked.trace &&
	test_grep ! "\"label\":\"do_write_index\"" external-locked.trace &&

	# A foreign writer can leave a usable FSMN token from a new provider epoch
	# while preserving only an older, unreplayable external checkpoint.
	# Do not replace the named index provider boundary in that case.
	rm -f external-history/.git/index.csts &&
	rm -f "$sidecar.lock" &&
	test-tool -C external-history fsmonitor-client flush >flush.out &&
	git -C external-history config status.renameLimit 100 &&
	test_env GIT_INDEX_FILE="$PWD/external-history/.git/index" \
		GIT_TRACE2_EVENT="$PWD/external-main-token.trace" \
		git -C external-history status --porcelain=v2 \
			--untracked-files=normal >actual.main-token &&
	test_grep "\"label\":\"do_write_index\"" \
		external-main-token.trace &&
	test-tool -C external-history dump-fsmonitor >main-token &&
	main_token=$(sed -n "s/^fsmonitor last update //p" main-token) &&

	git -C external-history config status.renameLimit 200 &&
	test_env GIT_TRACE2_EVENT="$PWD/external-token.trace" \
		git -C external-history status >actual.token &&
	test_grep "nothing to commit, working tree clean" actual.token &&
	test_trace2_data fsmonitor history/external-token-unreplayable 1 \
		<external-token.trace &&
	! test_trace2_data fsmonitor history/external-restored 1 \
		<external-token.trace &&
	! test_trace2_data fsmonitor semantic/strong-invalidation 1 \
		<external-token.trace &&
	test_grep -F \
		"\"key\":\"query/command\",\"value\":\"$main_token\"" \
		external-token.trace
'

test_done
