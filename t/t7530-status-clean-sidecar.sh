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

assert_clean_sidecar_result () {
	sidecar_result=$1 &&
	sidecar_repo=$2 &&
	sidecar_cwd=$3 &&
	sidecar_label=$4 &&
	shift 4 &&
	cp "$sidecar_repo/.git/index" "$sidecar_label.index" &&
	GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
		-c core.untrackedCache=false -C "$sidecar_cwd" \
		status "$@" >"$sidecar_label.expect" &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/$sidecar_label.trace" \
		git -C "$sidecar_cwd" status "$@" \
		>"$sidecar_label.actual" &&
	test_cmp_bin "$sidecar_label.expect" "$sidecar_label.actual" &&
	test_cmp_bin "$sidecar_label.index" "$sidecar_repo/.git/index" ||
		return 1

	if test "$sidecar_result" = hit
	then
		test_trace2_data status clean-proof/hit 1 \
			<"$sidecar_label.trace" &&
		test_grep ! "\"label\":\"do_read_index\"" \
			"$sidecar_label.trace" &&
		test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
			"$sidecar_label.trace" &&
		test_grep ! "\"category\":\"index\",\"label\":\"preload" \
			"$sidecar_label.trace" &&
		test_grep ! "\"label\":\"read_directory\"" \
			"$sidecar_label.trace"
	else
		test_grep ! "\"key\":\"clean-proof/hit\"" \
			"$sidecar_label.trace"
	fi
}

assert_clean_sidecar_hit () {
	assert_clean_sidecar_result hit "$@"
}

assert_clean_sidecar_fallback () {
	assert_clean_sidecar_result fallback "$@"
}

assert_tracked_clean_fallback () {
	tracked_trace=$3.trace &&
	assert_clean_sidecar_fallback "$@" &&
	test_trace2_data status fsmonitor/tracked-clean 1 \
		<"$tracked_trace" &&
	test_trace2_data status index/cache-tree-match 1 \
		<"$tracked_trace" &&
	test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
		"$tracked_trace" &&
	test_grep ! "\"category\":\"index\",\"label\":\"preload" \
		"$tracked_trace"
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
			if kill "$status_pid" 2>/dev/null
			then
				wait "$status_pid" 2>/dev/null || :
			else
				wait "$status_pid" 2>/dev/null || return 1
			fi
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
	'a clean sidecar serves every index-independent status shape' '
	shapes=sidecar-query-shapes &&
	test_when_finished "stop_daemon $shapes" &&
	setup_repo "$shapes" &&
	mkdir "$shapes/scoped" &&
	test_commit -C "$shapes" scoped scoped/tracked &&
	test_write_lines "*.ignored" >"$shapes/.gitignore" &&
	git -C "$shapes" add .gitignore &&
	git -C "$shapes" commit -qm ignores &&
	git -C "$shapes" branch sidecar-upstream &&
	git -C "$shapes" branch --set-upstream-to=sidecar-upstream &&
	git -C "$shapes" commit --allow-empty -qm ahead &&
	test_write_lines stashed >"$shapes/tracked" &&
	git -C "$shapes" stash push -qm sidecar-stash &&
	test-tool -C "$shapes" chmtime -120 \
		tracked scoped/tracked .gitignore &&
	git -C "$shapes" update-index --refresh &&
	test_write_lines ignored >"$shapes/root.ignored" &&
	test_write_lines ignored >"$shapes/scoped/nested.ignored" &&
	git -C "$shapes" config core.untrackedCache true &&
	issue_sidecar "$shapes" &&

	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-default &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-long --long &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-verbose --verbose &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-verbose-twice -vv &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-verbose-long --verbose --long &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-verbose-short --verbose --short &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-verbose-v2 --verbose --porcelain=v2 &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-verbose-null --verbose -z &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-verbose-branch --verbose --branch &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-verbose-stash --verbose --show-stash &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-verbose-scoped --verbose -- scoped &&
	assert_clean_sidecar_hit "$shapes" "$shapes/scoped" \
		sidecar-verbose-nested --verbose &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-short --short &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-porcelain --porcelain &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-porcelain-v1 --porcelain=v1 &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-porcelain-v2 --porcelain=v2 &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-null -z &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-short-branch --short --branch &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-v1-branch-null \
		--porcelain=v1 --branch -z &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-v2-branch \
		--porcelain=v2 --branch &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-stash --show-stash &&
	test_grep "Your stash currently has 1 entry" sidecar-stash.actual &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-v2-stash \
		--porcelain=v2 --show-stash &&
	test_grep "^# stash 1$" sidecar-v2-stash.actual &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-daemon \
		--porcelain=v2 -z --branch --show-stash \
		--no-ahead-behind --untracked-files=normal \
		--ignore-submodules=all &&
	for ignore_mode in all dirty untracked none
	do
		assert_clean_sidecar_hit "$shapes" "$shapes" \
			"sidecar-ignore-$ignore_mode" \
			"--ignore-submodules=$ignore_mode" || return 1
	done &&
	test_must_fail git -C "$shapes" status \
		--ignore-submodules=bogus >sidecar-invalid-ignore.out \
		2>sidecar-invalid-ignore.err &&
	test_must_be_empty sidecar-invalid-ignore.out &&
	test_grep "bad --ignore-submodules argument: bogus" \
		sidecar-invalid-ignore.err &&
	test_must_fail git -C "$shapes" status \
		--ignore-submodules=bogus -- ":(bogus)tracked" \
		>sidecar-invalid-order.out 2>sidecar-invalid-order.err &&
	test_must_be_empty sidecar-invalid-order.out &&
	test_grep "Invalid pathspec magic.*bogus" \
		sidecar-invalid-order.err &&
	test_grep ! "bad --ignore-submodules argument" \
		sidecar-invalid-order.err &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-untracked-no -uno &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-untracked-all -uall &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-no-renames --no-renames &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-find-renames --find-renames=50% &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-scoped -- scoped &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-scoped-slash -- scoped/ &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-scoped-file -- scoped/tracked &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-multiple -- tracked scoped &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-scoped-v2 \
		--porcelain=v2 -- scoped &&
	assert_clean_sidecar_hit "$shapes" "$shapes/scoped" sidecar-nested &&
	assert_clean_sidecar_hit "$shapes" "$shapes/scoped" sidecar-nested-v2 \
		--porcelain=v2 -- tracked &&
	assert_clean_sidecar_hit "$shapes" "$shapes/scoped" sidecar-nested-root \
		--porcelain=v1 -- ":(top)tracked" &&

	stash_oid=$(git -C "$shapes" rev-parse refs/stash) &&
	git -C "$shapes" stash drop -q &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-stash-dropped --show-stash &&
	test_grep ! "Your stash currently has" \
		sidecar-stash-dropped.actual &&
	git -C "$shapes" stash store -m restored "$stash_oid" &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-stash-restored \
		--porcelain=v2 --show-stash &&
	test_grep "^# stash 1$" sidecar-stash-restored.actual &&

	current_ref=$(git -C "$shapes" symbolic-ref HEAD) &&
	git -C "$shapes" branch sidecar-live HEAD &&
	git -C "$shapes" symbolic-ref HEAD refs/heads/sidecar-live &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-branch-moved \
		--porcelain=v2 --branch &&
	test_grep "^# branch.head sidecar-live$" \
		sidecar-branch-moved.actual &&
	git -C "$shapes" symbolic-ref HEAD "$current_ref" &&

	git -C "$shapes" rev-parse HEAD >"$shapes/.git/MERGE_HEAD" &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-merge --long &&
	test_grep "All conflicts fixed but you are still merging" \
		sidecar-merge.actual &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-merge-verbose --verbose &&
	assert_clean_sidecar_fallback "$shapes" "$shapes" \
		sidecar-merge-verbose-twice -vv &&
	test_grep "Changes to be committed:" \
		sidecar-merge-verbose-twice.actual &&
	rm "$shapes/.git/MERGE_HEAD" &&
	mkdir "$shapes/.git/rebase-merge" &&
	git -C "$shapes" symbolic-ref HEAD \
		>"$shapes/.git/rebase-merge/head-name" &&
	git -C "$shapes" rev-parse HEAD \
		>"$shapes/.git/rebase-merge/onto" &&
	assert_clean_sidecar_hit "$shapes" "$shapes" sidecar-rebase --long &&
	test_grep "You are currently rebasing" sidecar-rebase.actual &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-rebase-verbose --verbose &&
	assert_clean_sidecar_hit "$shapes" "$shapes" \
		sidecar-rebase-verbose-twice -vv &&
	rm -rf "$shapes/.git/rebase-merge"
'

test_expect_success DURABLE_FSMONITOR \
	'a clean sidecar respects configured short and branch output' '
	test_when_finished "stop_daemon sidecar-configured-shapes" &&
	setup_repo sidecar-configured-shapes &&
	git -C sidecar-configured-shapes config status.short true &&
	git -C sidecar-configured-shapes config status.branch true &&
	issue_sidecar sidecar-configured-shapes &&
	assert_clean_sidecar_hit sidecar-configured-shapes \
		sidecar-configured-shapes sidecar-configured-short &&
	test_grep "^## " sidecar-configured-short.actual &&
	assert_clean_sidecar_hit sidecar-configured-shapes \
		sidecar-configured-shapes sidecar-configured-long \
		--no-short --no-branch &&
	assert_clean_sidecar_hit sidecar-configured-shapes \
		sidecar-configured-shapes sidecar-configured-v2 \
		--porcelain=v2 --branch
'

test_expect_success DURABLE_FSMONITOR \
	'configured stash output does not prevent clean sidecar issuance' '
	stash_repo=sidecar-configured-stash &&
	test_when_finished "stop_daemon $stash_repo" &&
	setup_repo "$stash_repo" &&
	git -C "$stash_repo" config core.autocrlf false &&
	git -C "$stash_repo" config core.untrackedCache true &&
	test_write_lines stashed >"$stash_repo/tracked" &&
	git -C "$stash_repo" stash push -qm configured-stash &&
	test-tool chmtime -120 "$stash_repo/tracked" &&
	git -C "$stash_repo" update-index --refresh &&
	prime_semantic_history "$stash_repo" &&
	git -C "$stash_repo" config status.showStash true &&
	test_path_is_missing "$stash_repo/.git/index.csts" &&

	test_env GIT_TRACE2_EVENT="$PWD/configured-stash.exact.trace" \
		bulk_status -C "$stash_repo" status --porcelain=v2 \
		>configured-stash.exact &&
	test_grep "^# stash 1$" configured-stash.exact &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<configured-stash.exact.trace &&
	test_path_is_missing "$stash_repo/.git/index.csts" &&

	test_env GIT_TRACE2_EVENT="$PWD/configured-stash.issue.trace" \
		bulk_status -C "$stash_repo" status >configured-stash.issue &&
	test_grep "nothing to commit, working tree clean" \
		configured-stash.issue &&
	test_grep "Your stash currently has 1 entry" configured-stash.issue &&
	test_trace2_data fsmonitor history/external-restored 1 \
		<configured-stash.issue.trace &&
	test_trace2_data status clean-proof/sidecar 1 \
		<configured-stash.issue.trace &&
	test_path_is_file "$stash_repo/.git/index.csts" &&

	assert_clean_sidecar_hit "$stash_repo" "$stash_repo" \
		configured-stash-hit &&
	test_grep "Your stash currently has 1 entry" \
		configured-stash-hit.actual &&
	assert_clean_sidecar_hit "$stash_repo" "$stash_repo" \
		configured-stash-v2-hit --porcelain=v2 &&
	test_grep "^# stash 1$" configured-stash-v2-hit.actual
'

test_expect_success DURABLE_FSMONITOR \
	'a clean sidecar never answers unsupported or dirty status shapes' '
	test_when_finished "stop_daemon sidecar-unsafe-shapes" &&
	setup_repo sidecar-unsafe-shapes &&
	mkdir sidecar-unsafe-shapes/scoped &&
	test_commit -C sidecar-unsafe-shapes scoped scoped/tracked &&
	test_write_lines "*.ignored" >sidecar-unsafe-shapes/.gitignore &&
	git -C sidecar-unsafe-shapes add .gitignore &&
	git -C sidecar-unsafe-shapes commit -qm ignores &&
	test-tool -C sidecar-unsafe-shapes chmtime -120 \
		tracked scoped/tracked .gitignore &&
	git -C sidecar-unsafe-shapes update-index --refresh &&
	test_write_lines ignored >sidecar-unsafe-shapes/root.ignored &&
	test_write_lines ignored \
		>sidecar-unsafe-shapes/scoped/nested.ignored &&
	git -C sidecar-unsafe-shapes config core.untrackedCache true &&
	issue_sidecar sidecar-unsafe-shapes &&

	assert_tracked_clean_fallback sidecar-unsafe-shapes \
		sidecar-unsafe-shapes sidecar-ignored --ignored &&
	test_grep "root.ignored" sidecar-ignored.actual &&
	test_grep "\"label\":\"read_directory\"" sidecar-ignored.trace &&
	assert_tracked_clean_fallback sidecar-unsafe-shapes \
		sidecar-unsafe-shapes sidecar-ignored-matching \
		--ignored=matching &&
	assert_tracked_clean_fallback sidecar-unsafe-shapes \
		sidecar-unsafe-shapes sidecar-ignored-scoped \
		--ignored -- scoped &&
	test_grep "scoped/nested.ignored" sidecar-ignored-scoped.actual &&
	assert_clean_sidecar_hit sidecar-unsafe-shapes \
		sidecar-unsafe-shapes sidecar-verbose-clean --verbose &&

	git -C sidecar-unsafe-shapes config core.sparseCheckout true &&
	assert_clean_sidecar_fallback sidecar-unsafe-shapes \
		sidecar-unsafe-shapes sidecar-sparse --long &&
	git -C sidecar-unsafe-shapes config --unset core.sparseCheckout &&
	current_ref=$(git -C sidecar-unsafe-shapes symbolic-ref HEAD) &&
	git -C sidecar-unsafe-shapes symbolic-ref \
		HEAD refs/heads/sidecar-unborn &&
	assert_clean_sidecar_fallback sidecar-unsafe-shapes \
		sidecar-unsafe-shapes sidecar-unborn \
		--porcelain=v2 --branch &&
	test_grep "^# branch.oid (initial)$" sidecar-unborn.actual &&
	git -C sidecar-unsafe-shapes symbolic-ref HEAD "$current_ref" &&

	test_write_lines changed >sidecar-unsafe-shapes/tracked &&
	assert_clean_sidecar_fallback sidecar-unsafe-shapes \
		sidecar-unsafe-shapes sidecar-dirty-verbose --verbose &&
	test_grep "tracked" sidecar-dirty-verbose.actual &&
	test_grep "\"category\":\"diff\"" \
		sidecar-dirty-verbose.trace &&
	assert_clean_sidecar_fallback sidecar-unsafe-shapes \
		sidecar-unsafe-shapes sidecar-dirty --porcelain=v2 &&
	test_grep "^1 \.M .* tracked$" sidecar-dirty.actual &&
	assert_clean_sidecar_fallback sidecar-unsafe-shapes \
		sidecar-unsafe-shapes sidecar-dirty-outside \
		--porcelain=v2 -- scoped &&
	test_must_be_empty sidecar-dirty-outside.actual
'

test_expect_success DURABLE_FSMONITOR \
	'submodule summaries reject an otherwise valid clean sidecar' '
	test_when_finished "stop_daemon sidecar-submodule-summary" &&
	setup_repo sidecar-submodule-summary &&
	git -C sidecar-submodule-summary \
		config status.submoduleSummary true &&
	issue_sidecar sidecar-submodule-summary &&
	assert_clean_sidecar_fallback sidecar-submodule-summary \
		sidecar-submodule-summary sidecar-summary --long
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
	'pathspec status preserves history without certifying outside paths' '
	test_when_finished "stop_daemon external-pathspec-status" &&
	setup_repo external-pathspec-status &&
	mkdir external-pathspec-status/scoped &&
	test_commit -C external-pathspec-status scoped scoped/tracked &&
	test-tool -C external-pathspec-status chmtime -120 \
		tracked scoped/tracked &&
	git -C external-pathspec-status update-index --refresh &&
	git -C external-pathspec-status config core.untrackedCache true &&
	prime_semantic_history external-pathspec-status &&
	git -C external-pathspec-status config core.autocrlf false &&
	test_write_lines changed >external-pathspec-status/tracked &&
	test_write_lines selected >external-pathspec-status/scoped/new &&
	test_write_lines outside >external-pathspec-status/outside-new &&
	bulk_status -C external-pathspec-status \
		status --porcelain=v2 -- scoped >external-pathspec-status.first &&
	test_grep "^? scoped/new$" external-pathspec-status.first &&
	test_grep ! "tracked\|outside-new" external-pathspec-status.first &&
	test_path_is_missing external-pathspec-status/.git/index.csts &&
	cp external-pathspec-status/.git/index \
		external-pathspec-status.before &&
	test_env GIT_TRACE2_EVENT="$PWD/external-pathspec-status.trace" \
		bulk_status -C external-pathspec-status \
			status --porcelain=v2 -- scoped \
			>external-pathspec-status.second &&
	test_cmp external-pathspec-status.first \
		external-pathspec-status.second &&
	test_cmp external-pathspec-status.before \
		external-pathspec-status/.git/index &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<external-pathspec-status.trace &&
	! test_trace2_data fsmonitor semantic/manifest-scan-count \
		<external-pathspec-status.trace &&
	test_path_is_missing external-pathspec-status/.git/index.csts &&
	bulk_status -C external-pathspec-status status --porcelain=v2 \
		>external-pathspec-status.root &&
	test_grep "^1 \.M .* tracked$" external-pathspec-status.root
'

test_expect_success DURABLE_FSMONITOR \
	'no-op checkout, restore, and mixed reset preserve a clean sidecar' '
	checkout_repo=sidecar-noop-checkout &&
	test_when_finished "stop_daemon $checkout_repo" &&
	setup_repo "$checkout_repo" &&
	git -C "$checkout_repo" config core.untrackedCache true &&
	issue_sidecar "$checkout_repo" &&

	for checkout_case in checkout-index checkout-head \
		restore-worktree restore-staged reset-path reset-head \
		reset-mixed-head reset-mixed-no-refresh
	do
		case "$checkout_case" in
		checkout-index) set -- checkout -- tracked ;;
		checkout-head) set -- checkout HEAD -- tracked ;;
		restore-worktree) set -- restore --worktree tracked ;;
		restore-staged) set -- restore --staged tracked ;;
		reset-path) set -- reset -- tracked ;;
		reset-head) set -- reset HEAD -- tracked ;;
		reset-mixed-head) set -- reset --mixed HEAD ;;
		reset-mixed-no-refresh)
			set -- reset --mixed --no-refresh HEAD ;;
		esac &&
		cp "$checkout_repo/.git/index" "$checkout_case.before" &&
		cp "$checkout_repo/.git/index.csts" \
			"$checkout_case.sidecar" &&
		GIT_TRACE2_EVENT="$PWD/$checkout_case.command.trace" \
			git -C "$checkout_repo" "$@" &&
		test_cmp_bin "$checkout_case.before" \
			"$checkout_repo/.git/index" &&
		test_cmp_bin "$checkout_case.sidecar" \
			"$checkout_repo/.git/index.csts" &&
		test_grep ! "\"label\":\"do_write_index\"" \
			"$checkout_case.command.trace" &&
		assert_clean_sidecar_hit "$checkout_repo" "$checkout_repo" \
			"$checkout_case.hit" || return 1
	done
'

test_expect_success DURABLE_FSMONITOR \
	'clean pathspec status reuses an existing root-wide clean proof' '
	test_when_finished "stop_daemon clean-pathspec-status" &&
	setup_repo clean-pathspec-status &&
	mkdir clean-pathspec-status/scoped &&
	test_commit -C clean-pathspec-status scoped scoped/tracked &&
	test-tool -C clean-pathspec-status chmtime -120 \
		tracked scoped/tracked &&
	git -C clean-pathspec-status update-index --refresh &&
	git -C clean-pathspec-status config core.untrackedCache true &&
	issue_sidecar clean-pathspec-status &&
	cp clean-pathspec-status/.git/index clean-pathspec-status.before &&
	git -C clean-pathspec-status status >clean-pathspec-status.expect &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/clean-pathspec-status.trace" \
		git -C clean-pathspec-status status -- scoped \
			>clean-pathspec-status.actual &&
	test_cmp clean-pathspec-status.expect clean-pathspec-status.actual &&
	test_cmp clean-pathspec-status.before clean-pathspec-status/.git/index &&
	test_trace2_data status clean-proof/hit 1 \
		<clean-pathspec-status.trace &&
	test_grep ! "\"label\":\"do_read_index\"" \
		clean-pathspec-status.trace &&
	test_grep ! "\"label\":\"read_directory\"" \
		clean-pathspec-status.trace &&

	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/clean-pathspec-nested.trace" \
		git -C clean-pathspec-status/scoped status -- tracked \
			>clean-pathspec-nested.actual &&
	test_cmp clean-pathspec-status.expect clean-pathspec-nested.actual &&
	test_trace2_data status clean-proof/hit 1 \
		<clean-pathspec-nested.trace &&
	test_grep ! "\"label\":\"do_read_index\"" \
		clean-pathspec-nested.trace &&

	test_write_lines changed >clean-pathspec-status/tracked &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/clean-pathspec-outside.trace" \
		git -C clean-pathspec-status status -- scoped \
			>clean-pathspec-outside.actual &&
	test_grep "nothing to commit, working tree clean" \
		clean-pathspec-outside.actual &&
	test_grep ! "\"key\":\"clean-proof/hit\"" \
		clean-pathspec-outside.trace &&
	git -C clean-pathspec-status status --porcelain=v2 \
		>clean-pathspec-outside.root &&
	test_grep "^1 \.M .* tracked$" clean-pathspec-outside.root &&

	test_write_lines selected >clean-pathspec-status/scoped/new &&
	mkdir clean-pathspec-status/scoped/newdir &&
	test_write_lines nested >clean-pathspec-status/scoped/newdir/file &&
	test_write_lines outside >clean-pathspec-status/outside-new &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/clean-pathspec-selected.trace" \
		git -C clean-pathspec-status status -- scoped \
			>clean-pathspec-selected.actual &&
	test_grep "scoped/new" clean-pathspec-selected.actual &&
	test_grep "scoped/newdir/" clean-pathspec-selected.actual &&
	test_grep ! "outside-new" clean-pathspec-selected.actual &&
	test_grep ! "\"key\":\"clean-proof/hit\"" \
		clean-pathspec-selected.trace
'

test_expect_success DURABLE_FSMONITOR \
	'tracked-directory pathspec reuses a valid untracked-cache subtree' '
	test_when_finished "stop_daemon cached-pathspec-status" &&
	setup_repo cached-pathspec-status &&
	mkdir cached-pathspec-status/scoped &&
	test_commit -C cached-pathspec-status scoped scoped/tracked &&
	test-tool -C cached-pathspec-status chmtime -120 \
		tracked scoped/tracked &&
	git -C cached-pathspec-status update-index --refresh &&
	git -C cached-pathspec-status config core.untrackedCache true &&
	test_write_lines selected >cached-pathspec-status/scoped/new &&
	test_write_lines outside >cached-pathspec-status/outside-new &&
	git -C cached-pathspec-status status >cached-pathspec-status.root &&
	git -C cached-pathspec-status status >/dev/null &&
	cp cached-pathspec-status/.git/index cached-pathspec-status.before &&
	GIT_TRACE2_EVENT="$PWD/cached-pathspec-status.trace" \
		git -C cached-pathspec-status status -- scoped \
			>cached-pathspec-status.actual &&
	test_grep "scoped/new" cached-pathspec-status.actual &&
	test_grep ! "outside-new" cached-pathspec-status.actual &&
	test_cmp cached-pathspec-status.before \
		cached-pathspec-status/.git/index &&
	test_trace2_data status untracked/pathspec-cache 1 \
		<cached-pathspec-status.trace &&
	test_grep ! "\"label\":\"read_directory\"" \
		cached-pathspec-status.trace &&
	GIT_TRACE2_EVENT="$PWD/cached-pathspec-nested.trace" \
		git -C cached-pathspec-status/scoped status -- . \
			>cached-pathspec-nested.actual &&
	test_grep "new" cached-pathspec-nested.actual &&
	test_grep ! "outside-new" cached-pathspec-nested.actual &&
	test_trace2_data status untracked/pathspec-cache 1 \
		<cached-pathspec-nested.trace
'

test_expect_success DURABLE_FSMONITOR \
	'exact dirty status avoids a sparse full-worktree bulk scan' '
	test_when_finished "stop_daemon external-sparse-exact" &&
	setup_repo external-sparse-exact &&
	for i in $(test_seq 1 31)
	do
		test_write_lines "$i" >external-sparse-exact/clean-$i ||
			return 1
	done &&
	git -C external-sparse-exact add . &&
	git -C external-sparse-exact commit -m clean-files &&
	test-tool chmtime -120 external-sparse-exact/tracked \
		external-sparse-exact/clean-* &&
	git -C external-sparse-exact update-index --refresh &&
	git -C external-sparse-exact config core.untrackedCache true &&
	prime_semantic_history external-sparse-exact &&
	test_write_lines changed >external-sparse-exact/tracked &&
	test-tool chmtime -60 external-sparse-exact/tracked &&
	bulk_status -C external-sparse-exact status --porcelain=2 \
		>external-sparse-exact.primed &&
	bulk_status -C external-sparse-exact status --porcelain=v2 \
		-z --branch --show-stash --no-ahead-behind \
		--untracked-files=normal --ignore-submodules=all \
		>external-sparse-exact.daemon &&
	test_env GIT_TRACE2_EVENT="$PWD/external-sparse-exact.trace" \
		bulk_status -C external-sparse-exact status --porcelain=v2 \
		>actual &&
	test_grep "^1 \.M .* tracked$" actual &&
	test_trace2_data index preload/bulk_sparse_skip 1 \
		<external-sparse-exact.trace &&
	test_grep ! "\"category\":\"index\",\"label\":\"preload/bulk\"" \
		external-sparse-exact.trace
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

	test_env GIT_TRACE2_EVENT="$PWD/shape-branch.trace" \
		bulk_status -C sidecar-shape \
			status --porcelain=v2 --branch >actual &&
	test_grep "^# branch.oid " actual &&
	test_grep ! "\"key\":\"clean-proof/sidecar\"" \
		shape-branch.trace &&
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

test_expect_success DURABLE_FSMONITOR \
	'no-op checkout-index -u preserves a clean status proof' '
	update_repo=sidecar-noop-checkout-index &&
	test_when_finished "stop_daemon $update_repo" &&
	setup_repo "$update_repo" &&
	git -C "$update_repo" config core.untrackedCache true &&
	issue_sidecar "$update_repo" &&

	for update_case in path force all stdin
	do
		case "$update_case" in
		path) set -- -u tracked ;;
		force) set -- -u -f tracked ;;
		all) set -- -u -a ;;
		stdin) set -- -u --stdin ;;
		esac &&
		if test "$update_case" = stdin
		then
			echo tracked >checkout-update.stdin
		else
			: >checkout-update.stdin
		fi &&
		cp "$update_repo/.git/index" \
			"checkout-update-$update_case.index" &&
		cp "$update_repo/.git/index.csts" \
			"checkout-update-$update_case.sidecar" &&
		GIT_TRACE2_EVENT="$PWD/checkout-update-$update_case.trace" \
			git -C "$update_repo" checkout-index "$@" \
			<checkout-update.stdin &&
		test_cmp_bin "checkout-update-$update_case.index" \
			"$update_repo/.git/index" &&
		test_cmp_bin "checkout-update-$update_case.sidecar" \
			"$update_repo/.git/index.csts" &&
		test_grep ! "\"label\":\"do_write_index\"" \
			"checkout-update-$update_case.trace" &&
		assert_clean_sidecar_hit "$update_repo" "$update_repo" \
			"checkout-update-$update_case.hit" || return 1
	done
'

test_done
