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
		test-tool chmtime =-120 tracked &&
		git -c core.fsmonitor=false update-index --refresh &&
		git config core.fsmonitor true &&
		GIT_TRACE_FSMONITOR="$PWD/.git/daemon.trace" \
			git fsmonitor--daemon start --start-timeout=10 &&
		git status --porcelain=v2 >/dev/null &&
		test-tool fsmonitor-client query --token 0 >token &&
		nul_to_q <token >token.filtered &&
		grep "^builtin:" token.filtered &&
		grep "cookie-seen:" .git/daemon.trace &&
		! grep "cookie_wait timed out" .git/daemon.trace
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
	test_env GIT_INDEX_FILE="$PWD/$repo/.git/index" \
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
	'inactive configured filters can issue authenticated clean sidecars' '
	test_when_finished "stop_daemon sidecar-inactive-filter" &&
	setup_repo sidecar-inactive-filter &&
	git -C sidecar-inactive-filter config core.autocrlf false &&
	git -C sidecar-inactive-filter config core.untrackedCache true &&
	git -C sidecar-inactive-filter config filter.sidecar.clean cat &&
	git -C sidecar-inactive-filter config filter.sidecar.smudge cat &&
	git -C sidecar-inactive-filter config filter.sidecar.process \
		"missing-inactive-filter-process" &&
	git -C sidecar-inactive-filter config filter.sidecar.required true &&
	prime_semantic_history sidecar-inactive-filter &&
	cp sidecar-inactive-filter/.git/index inactive-filter.index &&

	test_env GIT_TRACE2_EVENT="$PWD/inactive-filter.issue.trace" \
		bulk_status -C sidecar-inactive-filter \
			status --porcelain=v2 >inactive-filter.issue &&
	test_must_be_empty inactive-filter.issue &&
	test_cmp_bin inactive-filter.index \
		sidecar-inactive-filter/.git/index &&
	test_trace2_data status clean-proof/sidecar 1 \
		<inactive-filter.issue.trace &&
	test_path_is_file sidecar-inactive-filter/.git/index.csts &&
	assert_clean_sidecar_hit sidecar-inactive-filter \
		sidecar-inactive-filter inactive-filter.hit &&
	assert_clean_sidecar_hit sidecar-inactive-filter \
		sidecar-inactive-filter inactive-filter.hit-again &&

	for label in bulk preload both bulk-false preload-false
	do
		case "$label" in
		bulk) set -- -c core.preloadIndexBulk ;;
		preload) set -- -c core.preloadIndex ;;
		both) set -- -c core.preloadIndexBulk -c core.preloadIndex ;;
		bulk-false) set -- -c core.preloadIndexBulk=false ;;
		preload-false) set -- -c core.preloadIndex=false ;;
		esac &&
		cp sidecar-inactive-filter/.git/index \
			"inactive-filter-$label.index" &&
		cp sidecar-inactive-filter/.git/index.csts \
			"inactive-filter-$label.sidecar" &&
		GIT_OPTIONAL_LOCKS=0 \
			git "$@" -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				-C sidecar-inactive-filter status --porcelain=v2 \
				>"inactive-filter-$label.expect" &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TRACE2_EVENT="$PWD/inactive-filter-$label.trace" \
			git "$@" -C sidecar-inactive-filter \
				status --porcelain=v2 \
				>"inactive-filter-$label.actual" &&
		test_cmp "inactive-filter-$label.expect" \
			"inactive-filter-$label.actual" &&
		test_cmp_bin "inactive-filter-$label.index" \
			sidecar-inactive-filter/.git/index &&
		test_cmp_bin "inactive-filter-$label.sidecar" \
			sidecar-inactive-filter/.git/index.csts &&
		test_trace2_data status clean-proof/hit 1 \
			<"inactive-filter-$label.trace" &&
		test_grep ! "\"label\":\"do_read_index\"" \
			"inactive-filter-$label.trace" &&
		test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
			"inactive-filter-$label.trace" &&
		test_grep ! "\"category\":\"index\",\"label\":\"preload" \
			"inactive-filter-$label.trace" &&
		test_grep ! "\"label\":\"read_directory\"" \
			"inactive-filter-$label.trace" &&
		test_grep ! "\"key\":\"semantic/manifest-scan-count\"" \
			"inactive-filter-$label.trace" &&
		test_grep ! "\"label\":\"do_write_index\"" \
			"inactive-filter-$label.trace" || return 1
	done &&

	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/inactive-filter.config.trace" \
		git -c filter.sidecar.required=false \
			-C sidecar-inactive-filter status --porcelain=v2 \
			>inactive-filter.config &&
	test_must_be_empty inactive-filter.config &&
	test_trace2_data status clean-proof/miss fast-config-changed \
		<inactive-filter.config.trace &&

	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/inactive-filter.disabled-read.trace" \
		git -c filter.sidecar.clean= \
			-c filter.sidecar.smudge= \
			-c filter.sidecar.process= \
			-c filter.sidecar.required=false \
			-C sidecar-inactive-filter status --porcelain=v2 \
			>inactive-filter.disabled-read &&
	test_must_be_empty inactive-filter.disabled-read &&
	test_trace2_data status clean-proof/miss fast-repository-shape \
		<inactive-filter.disabled-read.trace &&
	test_grep ! "\"key\":\"clean-proof/hit\"" \
		inactive-filter.disabled-read.trace &&

	rm sidecar-inactive-filter/.git/index.csts &&
	test_env GIT_TRACE2_EVENT="$PWD/inactive-filter.disabled-issue.trace" \
		bulk_status -c filter.sidecar.clean= \
			-c filter.sidecar.smudge= \
			-c filter.sidecar.process= \
			-c filter.sidecar.required=false \
			-C sidecar-inactive-filter status --porcelain=v2 \
			>inactive-filter.disabled-issue &&
	test_must_be_empty inactive-filter.disabled-issue &&
	test_path_is_missing sidecar-inactive-filter/.git/index.csts &&
	test_grep ! "\"key\":\"clean-proof/sidecar\"" \
		inactive-filter.disabled-issue.trace &&

	bulk_status -C sidecar-inactive-filter \
		status --porcelain=v2 >inactive-filter.reissue &&
	test_must_be_empty inactive-filter.reissue &&
	test_path_is_file sidecar-inactive-filter/.git/index.csts &&
	test_write_lines "tracked -text" \
		>sidecar-inactive-filter/.git/info/attributes &&
	assert_fallback_matches_oracle sidecar-inactive-filter \
		inactive-filter.external-attrs.trace &&
	test_trace2_data status clean-proof/miss \
		fast-repository-unavailable \
		<inactive-filter.external-attrs.trace
'

test_expect_success DURABLE_FSMONITOR \
	'active and command-disabled filters cannot reuse clean sidecars' '
	test_when_finished "stop_daemon sidecar-active-filter" &&
	setup_repo sidecar-active-filter &&
	git -C sidecar-active-filter config core.autocrlf false &&
	git -C sidecar-active-filter config core.untrackedCache true &&
	git -C sidecar-active-filter config filter.sidecar.clean \
		"sed s/base/converted/" &&
	git -C sidecar-active-filter config filter.sidecar.required true &&
	prime_semantic_history sidecar-active-filter &&
	bulk_status -C sidecar-active-filter \
		status --porcelain=v2 >active-filter.issue &&
	test_must_be_empty active-filter.issue &&
	test_path_is_file sidecar-active-filter/.git/index.csts &&

	test_write_lines "tracked filter=sidecar" \
		>sidecar-active-filter/.gitattributes &&
	assert_fallback_matches_oracle sidecar-active-filter \
		active-filter.activation.trace &&
	test_grep "^1 \\.M .* tracked$" actual &&
	test_grep "^? \\.gitattributes$" actual &&

	git -c filter.sidecar.clean= \
		-c filter.sidecar.smudge= \
		-c filter.sidecar.process= \
		-c filter.sidecar.required=false \
		-C sidecar-active-filter add .gitattributes &&
	git -c filter.sidecar.clean= \
		-c filter.sidecar.smudge= \
		-c filter.sidecar.process= \
		-c filter.sidecar.required=false \
		-C sidecar-active-filter commit -qm "activate disabled filter" &&
	rm -f sidecar-active-filter/.git/index.csts &&
	test_env GIT_TRACE2_EVENT="$PWD/active-filter.disabled.trace" \
		bulk_status -c filter.sidecar.clean= \
			-c filter.sidecar.smudge= \
			-c filter.sidecar.process= \
			-c filter.sidecar.required=false \
			-C sidecar-active-filter status --porcelain=v2 \
			>active-filter.disabled &&
	test_must_be_empty active-filter.disabled &&
	test_path_is_missing sidecar-active-filter/.git/index.csts &&
	test_grep ! "\"key\":\"clean-proof/sidecar\"" \
		active-filter.disabled.trace &&
	assert_fallback_matches_oracle sidecar-active-filter \
		active-filter.restored.trace &&
	test_grep "^1 \\.M .* tracked$" actual
'

test_expect_success DURABLE_FSMONITOR \
	'ordinary clean status installs its first missing sidecar' '
	test_when_finished "stop_daemon sidecar-plain-first" &&
	setup_repo sidecar-plain-first &&
	git -C sidecar-plain-first config core.autocrlf false &&
	git -C sidecar-plain-first config core.untrackedCache true &&
	prime_semantic_history sidecar-plain-first &&
	test_path_is_missing sidecar-plain-first/.git/index.csts &&
	cp sidecar-plain-first/.git/index plain-first.index &&
	GIT_OPTIONAL_LOCKS=0 \
		git -c core.fsmonitor=false -c core.untrackedCache=false \
		-C sidecar-plain-first status >plain-first.expect &&
	test_env GIT_TRACE2_EVENT="$PWD/plain-first.trace" \
		git -C sidecar-plain-first status >plain-first.actual &&
	test_cmp plain-first.expect plain-first.actual &&
	test_cmp plain-first.index sidecar-plain-first/.git/index &&
	test_path_is_file sidecar-plain-first/.git/index.csts &&
	test_trace2_data fsmonitor config/coherent 1 \
		<plain-first.trace &&
	! test_trace2_data fsmonitor history/external-restored 1 \
		<plain-first.trace &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<plain-first.trace &&
	test_trace2_data status clean-proof/sidecar 1 \
		<plain-first.trace &&
	test_grep ! "\"key\":\"semantic/manifest-scan-count\"" \
		plain-first.trace &&
	test_grep ! "\"label\":\"do_write_index\"" plain-first.trace &&
	assert_clean_sidecar_hit sidecar-plain-first sidecar-plain-first \
		plain-first-hit
'

test_expect_success DURABLE_FSMONITOR \
	'ordinary status never certifies dirty tracked or untracked files' '
	test_when_finished "stop_daemon sidecar-plain-dirty" &&
	setup_repo sidecar-plain-dirty &&
	git -C sidecar-plain-dirty config core.autocrlf false &&
	git -C sidecar-plain-dirty config core.untrackedCache true &&
	prime_semantic_history sidecar-plain-dirty &&
	test_path_is_missing sidecar-plain-dirty/.git/index.csts &&
	cp sidecar-plain-dirty/tracked plain-dirty.tracked &&
	test_write_lines changed >sidecar-plain-dirty/tracked &&
	GIT_OPTIONAL_LOCKS=0 \
		git -c core.fsmonitor=false -c core.untrackedCache=false \
		-C sidecar-plain-dirty status >plain-dirty-tracked.expect &&
	test_env GIT_TRACE2_EVENT="$PWD/plain-dirty-tracked.trace" \
		git -C sidecar-plain-dirty status \
			>plain-dirty-tracked.actual &&
	test_cmp plain-dirty-tracked.expect plain-dirty-tracked.actual &&
	test_trace2_data status count/changed 1 \
		<plain-dirty-tracked.trace &&
	test_grep ! "\"key\":\"clean-proof/sidecar\"" \
		plain-dirty-tracked.trace &&
	test_path_is_missing sidecar-plain-dirty/.git/index.csts &&

	cp plain-dirty.tracked sidecar-plain-dirty/tracked &&
	test-tool chmtime -120 sidecar-plain-dirty/tracked &&
	git -C sidecar-plain-dirty update-index --refresh &&
	prime_semantic_history sidecar-plain-dirty &&
	test_write_lines untracked >sidecar-plain-dirty/untracked &&
	GIT_OPTIONAL_LOCKS=0 \
		git -c core.fsmonitor=false -c core.untrackedCache=false \
		-C sidecar-plain-dirty status >plain-dirty-untracked.expect &&
	test_env GIT_TRACE2_EVENT="$PWD/plain-dirty-untracked.trace" \
		git -C sidecar-plain-dirty status \
			>plain-dirty-untracked.actual &&
	test_cmp plain-dirty-untracked.expect \
		plain-dirty-untracked.actual &&
	test_trace2_data status count/untracked 1 \
		<plain-dirty-untracked.trace &&
	test_grep ! "\"key\":\"clean-proof/sidecar\"" \
		plain-dirty-untracked.trace &&
	test_path_is_missing sidecar-plain-dirty/.git/index.csts &&

	rm sidecar-plain-dirty/untracked &&
	test_env GIT_TRACE2_EVENT="$PWD/plain-dirty-recovered.trace" \
		git -C sidecar-plain-dirty status >plain-dirty-recovered.actual &&
	test_grep "nothing to commit, working tree clean" \
		plain-dirty-recovered.actual &&
	test_trace2_data status clean-proof/sidecar 1 \
		<plain-dirty-recovered.trace &&
	assert_clean_sidecar_hit sidecar-plain-dirty sidecar-plain-dirty \
		plain-dirty-recovered-hit
'

test_expect_success DURABLE_FSMONITOR \
	'clean sidecars revalidate tracked hardlinks and ignored aliases' '
	test_when_finished "stop_daemon sidecar-hardlink" &&
	setup_repo sidecar-hardlink &&
	test_write_lines "/ignored/" >sidecar-hardlink/.gitignore &&
	git -C sidecar-hardlink add .gitignore &&
	git -C sidecar-hardlink commit -qm ignores &&
	mkdir sidecar-hardlink/ignored &&
	ln sidecar-hardlink/tracked sidecar-hardlink/ignored/alias &&
	test-tool -C sidecar-hardlink chmtime -120 tracked .gitignore &&
	git -C sidecar-hardlink update-index --refresh &&
	git -C sidecar-hardlink config core.autocrlf false &&
	git -C sidecar-hardlink config core.untrackedCache true &&
	git -C sidecar-hardlink config core.trustctime true &&
	git -C sidecar-hardlink config core.checkStat default &&
	prime_semantic_history sidecar-hardlink &&
	test_path_is_missing sidecar-hardlink/.git/index.csts &&
	test_env GIT_TRACE2_EVENT="$PWD/hardlink-issue.trace" \
		git -C sidecar-hardlink status >hardlink-issue.actual &&
	test_grep "nothing to commit, working tree clean" \
		hardlink-issue.actual &&
	test_trace2_data status clean-proof/sidecar 1 \
		<hardlink-issue.trace &&
	test_trace2_data status clean-proof/hardlink-witnesses 1 \
		<hardlink-issue.trace &&
	test_path_is_file sidecar-hardlink/.git/index.csts &&
	assert_clean_sidecar_hit sidecar-hardlink sidecar-hardlink \
		hardlink-clean-hit &&
	test_trace2_data status clean-proof/hardlink-validated 1 \
		<hardlink-clean-hit.trace &&

	mtime=$(test-tool chmtime --get sidecar-hardlink/tracked) &&
	printf "xxxx\\n" >sidecar-hardlink/ignored/alias &&
	test-tool chmtime =$mtime sidecar-hardlink/ignored/alias &&
	test "$(git -C sidecar-hardlink hash-object tracked)" != \
		"$(git -C sidecar-hardlink rev-parse HEAD:tracked)" &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/hardlink-dirty.trace" \
		git -C sidecar-hardlink status --porcelain=v2 \
			>hardlink-dirty.actual &&
	test_grep "^1 \\.M .* tracked$" hardlink-dirty.actual &&
	test_grep ! "\"key\":\"clean-proof/hit\"" hardlink-dirty.trace &&
	test_grep "fast-hardlink-changed" hardlink-dirty.trace
'

test_expect_success DURABLE_FSMONITOR \
	'explicitly invalid tracked hardlinks keep authenticated clean proofs' '
	test_when_finished "stop_daemon sidecar-hardlinks-invalid" &&
	setup_repo sidecar-hardlinks-invalid &&
	test_write_lines "/ignored/" \
		>sidecar-hardlinks-invalid/.gitignore &&
	printf "bbbb\\n" >sidecar-hardlinks-invalid/other &&
	git -C sidecar-hardlinks-invalid add .gitignore other &&
	git -C sidecar-hardlinks-invalid commit -qm hardlinks &&
	mkdir sidecar-hardlinks-invalid/ignored &&
	ln sidecar-hardlinks-invalid/tracked \
		sidecar-hardlinks-invalid/ignored/tracked &&
	ln sidecar-hardlinks-invalid/other \
		sidecar-hardlinks-invalid/ignored/other &&
	test-tool -C sidecar-hardlinks-invalid \
		chmtime -120 tracked other .gitignore &&
	git -C sidecar-hardlinks-invalid update-index --refresh &&
	git -C sidecar-hardlinks-invalid config core.autocrlf false &&
	git -C sidecar-hardlinks-invalid config core.untrackedCache true &&
	git -C sidecar-hardlinks-invalid config core.trustctime true &&
	git -C sidecar-hardlinks-invalid config core.checkStat default &&
	prime_semantic_history sidecar-hardlinks-invalid &&
	test_grep FSCF sidecar-hardlinks-invalid/.git/index &&
	test_grep FSUC sidecar-hardlinks-invalid/.git/index &&
	test_env GIT_TRACE2_EVENT="$PWD/hardlinks-invalid-checkpoint.trace" \
		git -C sidecar-hardlinks-invalid status \
			>hardlinks-invalid-checkpoint.actual &&
	test_grep "nothing to commit, working tree clean" \
		hardlinks-invalid-checkpoint.actual &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<hardlinks-invalid-checkpoint.trace &&
	find sidecar-hardlinks-invalid/.git -maxdepth 1 -type f \
		-name "index.csh1.*" >hardlinks-invalid.checkpoints &&
	test_line_count = 1 hardlinks-invalid.checkpoints &&
	rm -f sidecar-hardlinks-invalid/.git/index.csts &&
	rm sidecar-hardlinks-invalid/.git/index &&
	git -c core.fsmonitor=false -c core.untrackedCache=false \
		-C sidecar-hardlinks-invalid read-tree HEAD &&
	test_grep ! FSCF sidecar-hardlinks-invalid/.git/index &&
	test_grep ! FSMN sidecar-hardlinks-invalid/.git/index &&
	GIT_TRACE2_EVENT="$PWD/hardlinks-invalid-refresh.trace" \
		git -C sidecar-hardlinks-invalid update-index \
			--refresh -- tracked &&
	test_trace2_data fsmonitor history/external-restored 1 \
		<hardlinks-invalid-refresh.trace &&
	test_grep FSCF sidecar-hardlinks-invalid/.git/index &&
	test_grep FSUC sidecar-hardlinks-invalid/.git/index &&
	test-tool -C sidecar-hardlinks-invalid dump-cache-tree \
		>hardlinks-invalid.tree-before &&
	test_grep ! "^invalid " hardlinks-invalid.tree-before &&
	GIT_TRACE2_EVENT="$PWD/hardlinks-invalid-update.trace" \
		git -C sidecar-hardlinks-invalid update-index \
			--no-fsmonitor-valid tracked other &&
	test_grep FSCF sidecar-hardlinks-invalid/.git/index &&
	test_grep FSUC sidecar-hardlinks-invalid/.git/index &&
	test-tool -C sidecar-hardlinks-invalid dump-cache-tree \
		>hardlinks-invalid.tree-after &&
	test_grep ! "^invalid " hardlinks-invalid.tree-after &&
	test_cmp hardlinks-invalid.tree-before hardlinks-invalid.tree-after &&
	GIT_TRACE2_EVENT="$PWD/hardlinks-invalid-separated.trace" \
		git -C sidecar-hardlinks-invalid update-index \
			--no-fsmonitor-valid -- tracked other &&
	test_grep FSCF sidecar-hardlinks-invalid/.git/index &&
	test_grep FSUC sidecar-hardlinks-invalid/.git/index &&
	test-tool -C sidecar-hardlinks-invalid dump-cache-tree \
		>hardlinks-invalid.tree-separated &&
	test_cmp hardlinks-invalid.tree-before \
		hardlinks-invalid.tree-separated &&
	test_env GIT_TRACE2_EVENT="$PWD/hardlinks-invalid-issue.trace" \
		git -C sidecar-hardlinks-invalid status \
			>hardlinks-invalid-issue.actual &&
	test_grep "nothing to commit, working tree clean" \
		hardlinks-invalid-issue.actual &&
	test_trace2_data status clean-proof/sidecar 1 \
		<hardlinks-invalid-issue.trace &&
	test_trace2_data status clean-proof/hardlink-witnesses 2 \
		<hardlinks-invalid-issue.trace &&
	! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
		<hardlinks-invalid-issue.trace &&
	assert_clean_sidecar_hit sidecar-hardlinks-invalid \
		sidecar-hardlinks-invalid hardlinks-invalid-clean-hit &&
	test_trace2_data status clean-proof/hardlink-validated 2 \
		<hardlinks-invalid-clean-hit.trace &&
	mtime=$(test-tool chmtime --get \
		sidecar-hardlinks-invalid/tracked) &&
	printf "xxxx\\n" \
		>sidecar-hardlinks-invalid/ignored/tracked &&
	test-tool chmtime =$mtime \
		sidecar-hardlinks-invalid/ignored/tracked &&
	test "$(git -C sidecar-hardlinks-invalid hash-object tracked)" \
		!= "$(git -C sidecar-hardlinks-invalid \
			rev-parse HEAD:tracked)" &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/hardlinks-invalid-dirty.trace" \
		git -C sidecar-hardlinks-invalid status --porcelain=v2 \
			>hardlinks-invalid-dirty.actual &&
	test_grep "^1 \\.M .* tracked$" hardlinks-invalid-dirty.actual &&
	test_grep "fast-hardlink-changed" hardlinks-invalid-dirty.trace
'

test_expect_success DURABLE_FSMONITOR \
	'a racy scoped hardlink refresh still installs a clean sidecar' '
	test_when_finished "stop_daemon sidecar-hardlink-racy" &&
	setup_repo sidecar-hardlink-racy &&
	test_write_lines "/ignored/" >sidecar-hardlink-racy/.gitignore &&
	git -C sidecar-hardlink-racy add .gitignore &&
	git -C sidecar-hardlink-racy commit -qm ignores &&
	git -C sidecar-hardlink-racy config core.autocrlf false &&
	git -C sidecar-hardlink-racy config core.untrackedCache true &&
	git -C sidecar-hardlink-racy config core.trustctime true &&
	git -C sidecar-hardlink-racy config core.checkStat default &&
	prime_semantic_history sidecar-hardlink-racy &&
	test_grep FSCF sidecar-hardlink-racy/.git/index &&
	test_grep FSUC sidecar-hardlink-racy/.git/index &&
	git -C sidecar-hardlink-racy update-index --refresh -- tracked &&
	test_grep FSCF sidecar-hardlink-racy/.git/index &&
	test_grep FSUC sidecar-hardlink-racy/.git/index &&
	test-tool -C sidecar-hardlink-racy dump-fsmonitor \
		>hardlink-racy.token &&
	hardlink_token=$(sed -n "s/^fsmonitor last update //p" \
		hardlink-racy.token) &&
	test -n "$hardlink_token" &&
	mkdir sidecar-hardlink-racy/ignored &&
	ln sidecar-hardlink-racy/tracked \
		sidecar-hardlink-racy/ignored/tracked &&
	test-tool -C sidecar-hardlink-racy fsmonitor-client query \
		--token "$hardlink_token" >hardlink-racy-event.out &&
	test_env GIT_INDEX_FILE="$PWD/sidecar-hardlink-racy/.git/index" \
		GIT_TRACE2_EVENT="$PWD/hardlink-racy-rebaseline.trace" \
		git -C sidecar-hardlink-racy status --porcelain=v2 \
			>hardlink-racy-rebaseline.actual &&
	test_must_be_empty hardlink-racy-rebaseline.actual &&
	test_trace2_data fsmonitor apply/hardlink-matches 1 \
		<hardlink-racy-rebaseline.trace &&
	! test_trace2_data fsmonitor apply/global-invalidation 1 \
		<hardlink-racy-rebaseline.trace &&
	test_grep FSCF sidecar-hardlink-racy/.git/index &&
	test_grep FSUC sidecar-hardlink-racy/.git/index &&
	test_env GIT_TRACE2_EVENT="$PWD/hardlink-racy-update.trace" \
		git -C sidecar-hardlink-racy update-index \
			--no-fsmonitor-valid -- tracked &&
	test_grep FSCF sidecar-hardlink-racy/.git/index &&
	test_grep FSUC sidecar-hardlink-racy/.git/index &&
	test-tool -C sidecar-hardlink-racy dump-cache-tree \
		>hardlink-racy.tree &&
	test_grep ! "^invalid " hardlink-racy.tree &&
	test-tool -C sidecar-hardlink-racy chmtime -180 .git/index &&
	rm -f sidecar-hardlink-racy/.git/index.csts &&
	test_env GIT_TRACE2_EVENT="$PWD/hardlink-racy-issue.trace" \
		git -C sidecar-hardlink-racy status >hardlink-racy-issue.actual &&
	test_grep "nothing to commit, working tree clean" \
		hardlink-racy-issue.actual &&
	test_trace2_data fsmonitor history/external-save-reject racy-index \
		<hardlink-racy-issue.trace &&
	test_trace2_data status clean-proof/hardlink-witnesses 1 \
		<hardlink-racy-issue.trace &&
	test_trace2_data status clean-proof/sidecar 1 \
		<hardlink-racy-issue.trace &&
	test_path_is_file sidecar-hardlink-racy/.git/index.csts &&
	assert_clean_sidecar_hit sidecar-hardlink-racy \
		sidecar-hardlink-racy hardlink-racy-hit &&
	test_trace2_data status clean-proof/hardlink-validated 1 \
		<hardlink-racy-hit.trace
'

test_expect_success DURABLE_FSMONITOR,PERL_TEST_HELPERS \
	'hardlink witnesses verify stale subsecond index stat data' '
	test_when_finished "stop_daemon sidecar-hardlink-stale-stat" &&
	setup_repo sidecar-hardlink-stale-stat &&
	test_write_lines "/ignored/" \
		>sidecar-hardlink-stale-stat/.gitignore &&
	printf "aaaa\\n" >sidecar-hardlink-stale-stat/.npmrc &&
	mkdir -p sidecar-hardlink-stale-stat/nested &&
	printf "bbbb\\n" \
		>sidecar-hardlink-stale-stat/nested/.node-version &&
	git -C sidecar-hardlink-stale-stat add \
		.gitignore .npmrc nested/.node-version &&
	git -C sidecar-hardlink-stale-stat commit -qm hardlinks &&
	git -C sidecar-hardlink-stale-stat config core.autocrlf false &&
	git -C sidecar-hardlink-stale-stat config core.untrackedCache true &&
	git -C sidecar-hardlink-stale-stat config core.trustctime true &&
	git -C sidecar-hardlink-stale-stat config core.checkStat default &&
	git -C sidecar-hardlink-stale-stat update-index \
		--index-version 2 &&
	prime_semantic_history sidecar-hardlink-stale-stat &&
	test_grep FSCF sidecar-hardlink-stale-stat/.git/index &&
	test_grep FSUC sidecar-hardlink-stale-stat/.git/index &&
	test-tool -C sidecar-hardlink-stale-stat dump-fsmonitor \
		>hardlink-stale-stat.token &&
	stale_token=$(sed -n "s/^fsmonitor last update //p" \
		hardlink-stale-stat.token) &&
	test -n "$stale_token" &&
	mkdir sidecar-hardlink-stale-stat/ignored &&
	stale_same_second= &&
	for stale_attempt in 1 2 3 4 5
	do
		rm -f sidecar-hardlink-stale-stat/ignored/npmrc \
			sidecar-hardlink-stale-stat/ignored/node-version &&
		test-tool -C sidecar-hardlink-stale-stat \
			chmtime -1 .npmrc nested/.node-version &&
		git -C sidecar-hardlink-stale-stat update-index \
			--refresh -- .npmrc &&
		npmrc_second=$(/usr/bin/stat -f %c \
			sidecar-hardlink-stale-stat/.npmrc) &&
		node_second=$(/usr/bin/stat -f %c \
			sidecar-hardlink-stale-stat/nested/.node-version) &&
		ln sidecar-hardlink-stale-stat/.npmrc \
			sidecar-hardlink-stale-stat/ignored/npmrc &&
		ln sidecar-hardlink-stale-stat/nested/.node-version \
			sidecar-hardlink-stale-stat/ignored/node-version ||
			return 1
		if test "$npmrc_second" = "$(/usr/bin/stat -f %c \
			sidecar-hardlink-stale-stat/.npmrc)" &&
		   test "$node_second" = "$(/usr/bin/stat -f %c \
			sidecar-hardlink-stale-stat/nested/.node-version)"
		then
			stale_same_second=1 &&
			break
		fi
	done &&
	test "$stale_same_second" = 1 &&
	test-tool -C sidecar-hardlink-stale-stat fsmonitor-client query \
		--token "$stale_token" >hardlink-stale-stat-event.out &&
	test_env GIT_INDEX_FILE="$PWD/sidecar-hardlink-stale-stat/.git/index" \
		GIT_TRACE2_EVENT="$PWD/hardlink-stale-stat-rebaseline.trace" \
		git -C sidecar-hardlink-stale-stat status --porcelain=v2 \
			>hardlink-stale-stat-rebaseline.actual &&
	test_must_be_empty hardlink-stale-stat-rebaseline.actual &&
	test_trace2_data fsmonitor apply/hardlink-matches 2 \
		<hardlink-stale-stat-rebaseline.trace &&
	! test_trace2_data fsmonitor apply/global-invalidation 1 \
		<hardlink-stale-stat-rebaseline.trace &&
	test_grep FSCF sidecar-hardlink-stale-stat/.git/index &&
	test_grep FSUC sidecar-hardlink-stale-stat/.git/index &&
	git -C sidecar-hardlink-stale-stat update-index \
		--no-fsmonitor-valid -- .npmrc nested/.node-version &&
	test_grep FSCF sidecar-hardlink-stale-stat/.git/index &&
	test_grep FSUC sidecar-hardlink-stale-stat/.git/index &&
	cat >sidecar-hardlink-stale-stat/.git/stale-index-stat.pl <<-\EOF &&
	use Digest::SHA qw(sha1 sha256);
	binmode STDIN;
	binmode STDOUT;
	local $/;
	my $index = <STDIN>;
	my $algorithm = $ARGV[0];
	my $rawsz = $algorithm eq "sha256" ? 32 : 20;
	my $payload = substr($index, 0, -$rawsz);
	die "not a version 2 index\n"
		unless substr($payload, 0, 4) eq "DIRC" &&
		unpack("N", substr($payload, 4, 4)) == 2;
	my $entries = unpack("N", substr($payload, 8, 4));
	my $offset = 12;
	my $changed = 0;
	for (1 .. $entries) {
		my $name_offset = $offset + 40 + $rawsz + 2;
		my $end = index($payload, "\0", $name_offset);
		die "unterminated index entry\n" if $end < 0;
		my $name = substr($payload, $name_offset, $end - $name_offset);
		if ($name eq ".npmrc" || $name eq "nested/.node-version") {
			my $nsec = unpack("N", substr($payload, $offset + 4, 4));
			$nsec = ($nsec + 1) % 1000000000;
			substr($payload, $offset + 4, 4, pack("N", $nsec));
			$changed++;
		}
		$offset += (($end + 1 - $offset + 7) & ~7);
	}
	die "did not rewrite both indexed hardlinks\n" unless $changed == 2;
	print $payload,
		$algorithm eq "sha256" ? sha256($payload) : sha1($payload);
	EOF
	perl sidecar-hardlink-stale-stat/.git/stale-index-stat.pl \
		"$(test_oid algo)" \
		<sidecar-hardlink-stale-stat/.git/index \
		>sidecar-hardlink-stale-stat/.git/index.stale &&
	mv sidecar-hardlink-stale-stat/.git/index.stale \
		sidecar-hardlink-stale-stat/.git/index &&
	test_grep FSCF sidecar-hardlink-stale-stat/.git/index &&
	test_grep FSUC sidecar-hardlink-stale-stat/.git/index &&
	rm -f sidecar-hardlink-stale-stat/.git/index.csts &&
	test_env GIT_TRACE2_EVENT="$PWD/hardlink-stale-stat-issue.trace" \
		git -C sidecar-hardlink-stale-stat status \
			>hardlink-stale-stat-issue.actual &&
	test_grep "nothing to commit, working tree clean" \
		hardlink-stale-stat-issue.actual &&
	test_trace2_data status clean-proof/hardlink-content-verified 2 \
		<hardlink-stale-stat-issue.trace &&
	test_trace2_data status clean-proof/hardlink-witnesses 2 \
		<hardlink-stale-stat-issue.trace &&
	test_trace2_data status clean-proof/sidecar 1 \
		<hardlink-stale-stat-issue.trace &&
	assert_clean_sidecar_hit sidecar-hardlink-stale-stat \
		sidecar-hardlink-stale-stat hardlink-stale-stat-hit &&
	test_trace2_data status clean-proof/hardlink-validated 2 \
		<hardlink-stale-stat-hit.trace &&
	cp sidecar-hardlink-stale-stat/.git/index.csts \
		sidecar-hardlink-stale-stat/.git/index.csts.valid &&
	for malformed in bad-checksum truncated oversized
	do
		cp sidecar-hardlink-stale-stat/.git/index.csts.valid \
			sidecar-hardlink-stale-stat/.git/index.csts &&
		case "$malformed" in
		bad-checksum)
			printf "invalid-checksum" \
				>>sidecar-hardlink-stale-stat/.git/index.csts
			;;
		truncated)
			printf "CSTS" \
				>sidecar-hardlink-stale-stat/.git/index.csts
			;;
		oversized)
			dd if=/dev/zero \
				of=sidecar-hardlink-stale-stat/.git/index.csts \
				bs=1048577 count=1 2>/dev/null
			;;
		esac &&
		test_env \
			GIT_TRACE2_EVENT="$PWD/hardlink-sidecar-$malformed.trace" \
			git -C sidecar-hardlink-stale-stat status \
				>"hardlink-sidecar-$malformed.actual" &&
		test_grep "nothing to commit, working tree clean" \
			"hardlink-sidecar-$malformed.actual" &&
		test_grep "fast-sidecar-missing-or-corrupt" \
			"hardlink-sidecar-$malformed.trace" &&
		test_trace2_data status clean-proof/hardlink-content-verified 2 \
			<"hardlink-sidecar-$malformed.trace" &&
		test_trace2_data status clean-proof/hardlink-witnesses 2 \
			<"hardlink-sidecar-$malformed.trace" &&
		test_trace2_data status clean-proof/sidecar 1 \
			<"hardlink-sidecar-$malformed.trace" &&
		assert_clean_sidecar_hit sidecar-hardlink-stale-stat \
			sidecar-hardlink-stale-stat \
			"hardlink-sidecar-$malformed-hit" &&
		test_trace2_data status clean-proof/hardlink-validated 2 \
			<"hardlink-sidecar-$malformed-hit.trace" || return 1
	done &&
	cp sidecar-hardlink-stale-stat/.git/index.csts.valid \
		sidecar-hardlink-stale-stat/.git/index.csts.pristine &&
	for unsafe in fifo symlink directory multilink
	do
		rm -rf sidecar-hardlink-stale-stat/.git/index.csts &&
		case "$unsafe" in
		fifo)
			mkfifo sidecar-hardlink-stale-stat/.git/index.csts
			;;
		symlink)
			ln -s index.csts.valid \
				sidecar-hardlink-stale-stat/.git/index.csts
			;;
		directory)
			mkdir sidecar-hardlink-stale-stat/.git/index.csts
			;;
		multilink)
			ln sidecar-hardlink-stale-stat/.git/index.csts.valid \
				sidecar-hardlink-stale-stat/.git/index.csts
			;;
		esac &&
		test_env \
			GIT_TRACE2_EVENT="$PWD/hardlink-sidecar-$unsafe.trace" \
			git -C sidecar-hardlink-stale-stat status \
				>"hardlink-sidecar-$unsafe.actual" &&
		test_grep "nothing to commit, working tree clean" \
			"hardlink-sidecar-$unsafe.actual" &&
		! test_trace2_data status clean-proof/sidecar 1 \
			<"hardlink-sidecar-$unsafe.trace" &&
		test_cmp sidecar-hardlink-stale-stat/.git/index.csts.pristine \
			sidecar-hardlink-stale-stat/.git/index.csts.valid &&
		case "$unsafe" in
		fifo)
			test -p sidecar-hardlink-stale-stat/.git/index.csts
			;;
		symlink)
			test -h sidecar-hardlink-stale-stat/.git/index.csts
			;;
		directory)
			test -d sidecar-hardlink-stale-stat/.git/index.csts
			;;
		multilink)
			test "$(/usr/bin/stat -f %i \
				sidecar-hardlink-stale-stat/.git/index.csts)" = \
			     "$(/usr/bin/stat -f %i \
				sidecar-hardlink-stale-stat/.git/index.csts.valid)"
			;;
		esac || return 1
	done &&
	rm -f sidecar-hardlink-stale-stat/.git/index.csts &&
	cp sidecar-hardlink-stale-stat/.git/index.csts.valid \
		sidecar-hardlink-stale-stat/.git/index.csts &&
	git -C sidecar-hardlink-stale-stat status \
		>hardlink-sidecar-repair-prime.actual &&
	test_grep "nothing to commit, working tree clean" \
		hardlink-sidecar-repair-prime.actual &&
	assert_clean_sidecar_hit sidecar-hardlink-stale-stat \
		sidecar-hardlink-stale-stat hardlink-sidecar-repair-prime-hit &&
	cp sidecar-hardlink-stale-stat/.git/index \
		sidecar-hardlink-stale-stat/.git/index.before-repair &&
	test-tool -C sidecar-hardlink-stale-stat chmtime -60 tracked &&
	chmod 0600 sidecar-hardlink-stale-stat/ignored/npmrc \
		sidecar-hardlink-stale-stat/ignored/node-version &&
	chmod 0644 sidecar-hardlink-stale-stat/ignored/npmrc \
		sidecar-hardlink-stale-stat/ignored/node-version &&
	test_env \
		GIT_TRACE2_EVENT="$PWD/hardlink-sidecar-repair-reissue.trace" \
		git -C sidecar-hardlink-stale-stat status \
			>hardlink-sidecar-repair-reissue.actual &&
	test_grep "nothing to commit, working tree clean" \
		hardlink-sidecar-repair-reissue.actual &&
	test_grep "fast-hardlink-changed" \
		hardlink-sidecar-repair-reissue.trace &&
	test_grep "\"label\":\"do_write_index\"" \
		hardlink-sidecar-repair-reissue.trace &&
	test_trace2_data status clean-proof/sidecar 1 \
		<hardlink-sidecar-repair-reissue.trace &&
	test_trace2_data status clean-proof/postwrite-reissued 1 \
		<hardlink-sidecar-repair-reissue.trace &&
	! test_cmp sidecar-hardlink-stale-stat/.git/index.before-repair \
		sidecar-hardlink-stale-stat/.git/index &&
	assert_clean_sidecar_hit sidecar-hardlink-stale-stat \
		sidecar-hardlink-stale-stat hardlink-sidecar-repair-hit &&
	write_script \
		sidecar-hardlink-stale-stat/.git/hooks/post-index-change \
		<<-\EOF &&
	printf "hook-created\n" >hook-created
	printf "ran\n" >.git/post-index-change-ran
	EOF
	test-tool -C sidecar-hardlink-stale-stat chmtime -120 tracked &&
	chmod 0600 sidecar-hardlink-stale-stat/ignored/npmrc \
		sidecar-hardlink-stale-stat/ignored/node-version &&
	chmod 0644 sidecar-hardlink-stale-stat/ignored/npmrc \
		sidecar-hardlink-stale-stat/ignored/node-version &&
	test_env \
		GIT_TRACE2_EVENT="$PWD/hardlink-sidecar-post-hook.trace" \
		git -C sidecar-hardlink-stale-stat status \
			>hardlink-sidecar-post-hook.actual &&
	test_path_is_file \
		sidecar-hardlink-stale-stat/.git/post-index-change-ran &&
	test_path_is_file sidecar-hardlink-stale-stat/hook-created &&
	test_grep "fast-hardlink-changed" \
		hardlink-sidecar-post-hook.trace &&
	test_grep "\"label\":\"do_write_index\"" \
		hardlink-sidecar-post-hook.trace &&
	! test_trace2_data status clean-proof/postwrite-reissued 1 \
		<hardlink-sidecar-post-hook.trace &&
	! test_trace2_data status clean-proof/sidecar 1 \
		<hardlink-sidecar-post-hook.trace &&
	GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
		-c core.untrackedCache=false \
		-C sidecar-hardlink-stale-stat status --porcelain=v2 \
			>hardlink-sidecar-post-hook.expect &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/hardlink-sidecar-post-hook-repeat.trace" \
		git -C sidecar-hardlink-stale-stat status --porcelain=v2 \
			>hardlink-sidecar-post-hook-repeat.actual &&
	test_cmp hardlink-sidecar-post-hook.expect \
		hardlink-sidecar-post-hook-repeat.actual &&
	test_grep "^? hook-created$" \
		hardlink-sidecar-post-hook-repeat.actual &&
	! test_trace2_data status clean-proof/hit 1 \
		<hardlink-sidecar-post-hook-repeat.trace &&
	rm sidecar-hardlink-stale-stat/.git/hooks/post-index-change \
		sidecar-hardlink-stale-stat/hook-created &&
	rm -f sidecar-hardlink-stale-stat/.git/index.csts &&
	mtime=$(test-tool chmtime --get \
		sidecar-hardlink-stale-stat/.npmrc) &&
	printf "xxxx\\n" \
		>sidecar-hardlink-stale-stat/ignored/npmrc &&
	test-tool chmtime =$mtime \
		sidecar-hardlink-stale-stat/ignored/npmrc &&
	test "$(git -C sidecar-hardlink-stale-stat hash-object .npmrc)" \
		!= "$(git -C sidecar-hardlink-stale-stat \
			rev-parse HEAD:.npmrc)" &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/hardlink-stale-stat-dirty.trace" \
		git -C sidecar-hardlink-stale-stat status --porcelain=v2 \
			>hardlink-stale-stat-dirty.actual &&
	test_grep "^1 \\.M .* \\.npmrc$" \
		hardlink-stale-stat-dirty.actual &&
	test_path_is_missing sidecar-hardlink-stale-stat/.git/index.csts &&
	! test_trace2_data status clean-proof/sidecar 1 \
		<hardlink-stale-stat-dirty.trace
'

test_expect_success DURABLE_FSMONITOR \
	'a changed hardlink never receives its first clean sidecar' '
	test_when_finished "stop_daemon sidecar-hardlink-first-dirty" &&
	setup_repo sidecar-hardlink-first-dirty &&
	test_write_lines "/ignored/" \
		>sidecar-hardlink-first-dirty/.gitignore &&
	git -C sidecar-hardlink-first-dirty add .gitignore &&
	git -C sidecar-hardlink-first-dirty commit -qm ignores &&
	mkdir sidecar-hardlink-first-dirty/ignored &&
	ln sidecar-hardlink-first-dirty/tracked \
		sidecar-hardlink-first-dirty/ignored/alias &&
	test-tool -C sidecar-hardlink-first-dirty \
		chmtime -120 tracked .gitignore &&
	git -C sidecar-hardlink-first-dirty update-index --refresh &&
	git -C sidecar-hardlink-first-dirty config core.autocrlf false &&
	git -C sidecar-hardlink-first-dirty config core.untrackedCache true &&
	git -C sidecar-hardlink-first-dirty config core.trustctime true &&
	git -C sidecar-hardlink-first-dirty config core.checkStat default &&
	prime_semantic_history sidecar-hardlink-first-dirty &&
	test_path_is_missing sidecar-hardlink-first-dirty/.git/index.csts &&
	mtime=$(test-tool chmtime --get \
		sidecar-hardlink-first-dirty/tracked) &&
	printf "xxxx\\n" \
		>sidecar-hardlink-first-dirty/ignored/alias &&
	test-tool chmtime =$mtime \
		sidecar-hardlink-first-dirty/ignored/alias &&
	test "$(git -C sidecar-hardlink-first-dirty hash-object tracked)" \
		!= "$(git -C sidecar-hardlink-first-dirty \
			rev-parse HEAD:tracked)" &&
	test_env GIT_TRACE2_EVENT="$PWD/hardlink-first-dirty.trace" \
		git -C sidecar-hardlink-first-dirty status \
			>hardlink-first-dirty.actual &&
	test_path_is_missing sidecar-hardlink-first-dirty/.git/index.csts &&
	test_grep ! "\"key\":\"clean-proof/sidecar\"" \
		hardlink-first-dirty.trace
'

test_expect_success DURABLE_FSMONITOR \
	'weak stat identity never certifies multiply linked tracked files' '
	test_when_finished "stop_daemon sidecar-hardlink-weak" &&
	setup_repo sidecar-hardlink-weak &&
	test_write_lines "/ignored/" >sidecar-hardlink-weak/.gitignore &&
	git -C sidecar-hardlink-weak add .gitignore &&
	git -C sidecar-hardlink-weak commit -qm ignores &&
	mkdir sidecar-hardlink-weak/ignored &&
	ln sidecar-hardlink-weak/tracked \
		sidecar-hardlink-weak/ignored/alias &&
	test-tool chmtime -120 sidecar-hardlink-weak/tracked &&
	git -C sidecar-hardlink-weak update-index --refresh &&
	git -C sidecar-hardlink-weak config core.autocrlf false &&
	git -C sidecar-hardlink-weak config core.untrackedCache true &&
	git -C sidecar-hardlink-weak config core.trustctime false &&
	git -C sidecar-hardlink-weak config core.checkStat minimal &&
	prime_semantic_history sidecar-hardlink-weak &&
	test_env GIT_TRACE2_EVENT="$PWD/hardlink-weak.trace" \
		git -C sidecar-hardlink-weak status >hardlink-weak.actual &&
	test_grep "nothing to commit, working tree clean" \
		hardlink-weak.actual &&
	test_path_is_missing sidecar-hardlink-weak/.git/index.csts &&
	test_grep ! "\"key\":\"clean-proof/sidecar\"" hardlink-weak.trace
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
	test-tool chmtime -60 external-stat-bootstrap/tracked &&
	test-tool -C external-stat-bootstrap \
		fsmonitor-client flush >bootstrap.flush &&
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
	test_trace2_data fsmonitor history/external-stored 1 \
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
	'a plain clean status reissues a proof after locale changes' '
	test_when_finished "stop_daemon sidecar-locale-reissue" &&
	setup_repo sidecar-locale-reissue &&
	git -C sidecar-locale-reissue config core.untrackedCache true &&
	issue_sidecar sidecar-locale-reissue &&
	cp sidecar-locale-reissue/.git/index locale-reissue.index &&

	test_env LANG=sidecar-locale-reissue \
		GIT_TRACE2_EVENT="$PWD/locale-reissue.trace" \
		git -C sidecar-locale-reissue status >locale-reissue.actual &&
	test_grep "working tree clean" locale-reissue.actual &&
	test_cmp_bin locale-reissue.index \
		sidecar-locale-reissue/.git/index &&
	test_trace2_data status clean-proof/miss fast-repository-input \
		<locale-reissue.trace &&
	test_trace2_data status clean-proof/sidecar 1 \
		<locale-reissue.trace &&
	test_grep ! "\"label\":\"do_write_index\"" locale-reissue.trace &&

	test_env LANG=sidecar-locale-reissue \
		GIT_TRACE2_EVENT="$PWD/locale-reissue-hit.trace" \
		git -C sidecar-locale-reissue status >locale-reissue-hit.actual &&
	test_cmp locale-reissue.actual locale-reissue-hit.actual &&
	test_trace2_data status clean-proof/hit 1 \
		<locale-reissue-hit.trace &&
	test_grep ! "\"label\":\"do_read_index\"" locale-reissue-hit.trace
'

test_expect_success DURABLE_FSMONITOR \
	'a locale mismatch does not rewrite proof without optional locks' '
	test_when_finished "stop_daemon sidecar-locale-readonly" &&
	setup_repo sidecar-locale-readonly &&
	git -C sidecar-locale-readonly config core.untrackedCache true &&
	issue_sidecar sidecar-locale-readonly &&
	cp sidecar-locale-readonly/.git/index.csts locale-readonly.sidecar &&

	test_env LANG=sidecar-locale-readonly GIT_OPTIONAL_LOCKS=0 \
		GIT_TRACE2_EVENT="$PWD/locale-readonly.trace" \
		git -C sidecar-locale-readonly status >locale-readonly.actual &&
	test_grep "working tree clean" locale-readonly.actual &&
	test_cmp_bin locale-readonly.sidecar \
		sidecar-locale-readonly/.git/index.csts &&
	test_trace2_data status clean-proof/miss fast-repository-input \
		<locale-readonly.trace &&
	! test_trace2_data status clean-proof/sidecar 1 \
		<locale-readonly.trace
'

test_expect_success DURABLE_FSMONITOR \
	'a plain clean status repairs a stale proof with an invalid cache tree' '
	test_when_finished "stop_daemon sidecar-invalid-tree" &&
	setup_repo sidecar-invalid-tree &&
	git -C sidecar-invalid-tree config core.untrackedCache true &&
	issue_sidecar sidecar-invalid-tree &&
	cp sidecar-invalid-tree/.git/index.csts stale-proof &&
	cp sidecar-invalid-tree/tracked tracked.original &&
	test_write_lines changed >sidecar-invalid-tree/tracked &&
	git -C sidecar-invalid-tree add tracked &&
	cp tracked.original sidecar-invalid-tree/tracked &&
	test-tool chmtime -120 sidecar-invalid-tree/tracked &&
	git -C sidecar-invalid-tree add tracked &&
	test-tool -C sidecar-invalid-tree dump-cache-tree >tree.dump &&
	test_grep "^invalid " tree.dump &&
	GIT_OPTIONAL_LOCKS=0 \
		git -C sidecar-invalid-tree status --porcelain=v2 >before &&
	test_must_be_empty before &&
	cp stale-proof sidecar-invalid-tree/.git/index.csts &&
	rm -f sidecar-invalid-tree/.git/index.csh1.* &&
	cp sidecar-invalid-tree/.git/index invalid-tree.index &&
	test_env GIT_TRACE2_EVENT="$PWD/invalid-tree-reissue.trace" \
		git -C sidecar-invalid-tree status >actual &&
	test_grep "working tree clean" actual &&
	test_cmp invalid-tree.index sidecar-invalid-tree/.git/index &&
	test_trace2_data status index/full-tree-match 1 \
		<invalid-tree-reissue.trace &&
	test_trace2_data fsmonitor history/external-stored 1 \
		<invalid-tree-reissue.trace &&
	! test_trace2_data fsmonitor history/external-restored 1 \
		<invalid-tree-reissue.trace &&
	test_trace2_data status clean-proof/sidecar 1 \
		<invalid-tree-reissue.trace &&
	test_grep ! "\"label\":\"do_write_index\"" \
		invalid-tree-reissue.trace &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/invalid-tree-hit.trace" \
		git -C sidecar-invalid-tree status >actual.hit &&
	test_cmp actual actual.hit &&
	test_trace2_data status clean-proof/hit 1 \
		<invalid-tree-hit.trace &&
	test_grep ! "\"label\":\"do_read_index\"" \
		invalid-tree-hit.trace
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
	exclude_dir=$(mktemp -d \
		"${TMPDIR:-/tmp}/git-status-exclude-fifo.XXXXXX") &&
	test_when_finished "rm -rf \"$exclude_dir\"" &&
	exclude_file=$exclude_dir/global &&
	: >"$exclude_file" &&
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
	exclude_dir=$(mktemp -d \
		"${TMPDIR:-/tmp}/git-status-exclude-race.XXXXXX") &&
	test_when_finished "rm -rf \"$exclude_dir\"" &&
	exclude_file=$exclude_dir/global &&
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
	test_trace2_data status clean-proof/sidecar 1 \
		<external-seed.trace &&
	test_path_is_file external-history/.git/index.csts &&
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
	'expired index and checkpoint tokens preserve paired untracked history' '
	repo=sidecar-provider-reset &&
	test_when_finished "stop_daemon $repo" &&
	setup_repo "$repo" &&
	mkdir -p "$repo/cached/deep" &&
	test_write_lines tracked >"$repo/cached/deep/tracked" &&
	test_write_lines hidden >"$repo/cached/deep/visible.ignored" &&
	test_write_lines "*.ignored" >"$repo/.gitignore" &&
	test-tool chmtime -120 "$repo/cached/deep/tracked" \
		"$repo/.gitignore" &&
	git -C "$repo" add .gitignore cached/deep/tracked &&
	git -C "$repo" commit -qm nested &&
	git -C "$repo" config core.untrackedCache true &&
	git -C "$repo" config status.renameLimit 100 &&
	git -C "$repo" status --porcelain=v2 >reset.prime &&
	test_env GIT_INDEX_FILE="$PWD/$repo/.git/index" \
		git -C "$repo" status --porcelain=v2 >reset.prime &&
	test_must_be_empty reset.prime &&
	test_grep FSMN "$repo/.git/index" &&
	test_grep FSUC "$repo/.git/index" &&
	cp "$repo/.git/index" reset.namespace-a.index &&
	test-tool -C "$repo" fsmonitor-client flush >reset.flush &&
	git -C "$repo" config status.renameLimit 200 &&
	git -C "$repo" status --porcelain=v2 >reset.namespace-b &&
	test_must_be_empty reset.namespace-b &&
	cp reset.namespace-a.index "$repo/.git/index" &&
	rm -f "$repo/.git/index.csts" &&
	stop_daemon "$repo" &&
	test_write_lines "*.other" >"$repo/.gitignore" &&
	test_write_lines new >"$repo/cached/deep/new" &&
	git -C "$repo" fsmonitor--daemon start --start-timeout=10 &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TEST_UNTRACKED_CACHE_AUTO_PRELOAD=1 \
	GIT_TEST_UNTRACKED_CACHE_THREADS=4 \
	GIT_TRACE2_EVENT="$PWD/external-provider-reset.trace" \
		git -C "$repo" status --porcelain=v2 >reset.actual &&
	test_grep "^1 \\.M .* \\.gitignore$" reset.actual &&
	test_grep "^? cached/deep/new$" reset.actual &&
	test_grep "^? cached/deep/visible\\.ignored$" reset.actual &&
	test_trace2_data fsmonitor history/external-reset-restored 1 \
		<external-provider-reset.trace &&
	test_trace2_data fsmonitor history/external-restored 1 \
		<external-provider-reset.trace &&
	test_trace2_data fsmonitor untracked/provider-reset-preserved 1 \
		<external-provider-reset.trace &&
	test_trace2_data status untracked/provider-reset-preload 1 \
		<external-provider-reset.trace &&
	test_trace2_data fsmonitor untracked/provider-reset-revalidated 1 \
		<external-provider-reset.trace
'

test_expect_success DURABLE_FSMONITOR \
	'diff restores clean history lost by a foreign index writer' '
	diff_repo=sidecar-foreign-diff &&
	test_when_finished "stop_daemon $diff_repo" &&
	setup_repo "$diff_repo" &&
	git -C "$diff_repo" config core.untrackedCache true &&
	issue_sidecar "$diff_repo" &&
	test_grep FSMN "$diff_repo/.git/index" &&
	test_grep FSCF "$diff_repo/.git/index" &&
	find "$diff_repo/.git" -maxdepth 1 -type f \
		-name "index.csh1.*" >diff-history.checkpoints &&
	test_line_count = 1 diff-history.checkpoints &&
	git -C "$diff_repo" ls-files --stage >diff-history.stage &&

	rm "$diff_repo/.git/index" &&
	git -c core.fsmonitor=false -c core.untrackedCache=false \
		-C "$diff_repo" read-tree HEAD &&
	test_grep ! FSMN "$diff_repo/.git/index" &&
	test_grep ! FSCF "$diff_repo/.git/index" &&
	git -c core.fsmonitor=false -C "$diff_repo" \
		ls-files --stage >diff-history.rewritten.stage &&
	test_cmp diff-history.stage diff-history.rewritten.stage &&
	cp "$diff_repo/.git/index" diff-history.index &&
	cp "$diff_repo/.git/index.csts" diff-history.sidecar &&

	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/diff-history.clean.trace" \
		git -C "$diff_repo" diff --no-ext-diff \
		>diff-history.clean &&
	test_must_be_empty diff-history.clean &&
	test_cmp_bin diff-history.index "$diff_repo/.git/index" &&
	test_cmp_bin diff-history.sidecar "$diff_repo/.git/index.csts" &&
	test_trace2_data fsmonitor history/external-restored 1 \
		<diff-history.clean.trace &&
	! test_trace2_data fsmonitor semantic/manifest-scan-count \
		<diff-history.clean.trace &&
	test_grep ! \
		"\"key\":\"preload/sum_lstat\",\"value\":\"[1-9]" \
		diff-history.clean.trace &&
	test_grep ! "\"label\":\"do_write_index\"" \
		diff-history.clean.trace &&

	test_write_lines changed >"$diff_repo/tracked" &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT="$PWD/diff-history.dirty.trace" \
		git -C "$diff_repo" diff --no-ext-diff \
		>diff-history.dirty &&
	test_grep "^+changed$" diff-history.dirty &&
	test_trace2_data fsmonitor history/external-restored 1 \
		<diff-history.dirty.trace &&
	test_cmp_bin diff-history.index "$diff_repo/.git/index"
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

test_expect_success PERL_TEST_HELPERS \
	'a trivial fast probe survives a later empty provider delta' '
	test_when_finished "rm -rf sidecar-trivial-probe" &&
	test_create_repo sidecar-trivial-probe &&
	(
		cd sidecar-trivial-probe &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test-tool chmtime -120 tracked &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config filter.sidecar.clean "sed s/base/converted/" &&
		git config filter.sidecar.required true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git update-index --fsmonitor &&
		test_env GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			bulk_status status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_env GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			bulk_status status --porcelain=v2 >.git/issue &&
		test_must_be_empty .git/issue &&
		test_path_is_file .git/index.csts &&
		cp .git/index .git/index.before &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/clean.trace" \
			git status --porcelain=v2 >.git/clean &&
		test_must_be_empty .git/clean &&
		test_trace2_data status clean-proof/hit 1 <.git/clean.trace &&
		test_region ! index do_read_index .git/clean.trace &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TTCCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/clean-reset.trace" \
			git status --porcelain=v2 >.git/clean-reset &&
		test_must_be_empty .git/clean-reset &&
		test_trace2_data status clean-proof/provider-reset-carried 1 \
			<.git/clean-reset.trace &&
		test_trace2_data fsmonitor semantic/token-reset-stat-baseline 1 \
			<.git/clean-reset.trace &&
		test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/clean-reset.trace >.git/clean-reset.scans &&
		test_line_count = 1 .git/clean-reset.scans &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 2 \
			<.git/clean-reset.trace &&
		test_cmp_bin .git/index.before .git/index &&
		test_write_lines "tracked filter=sidecar" >.gitattributes &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				-c core.trustctime=true -c core.checkStat=default \
				status --porcelain=v2 >.git/expect &&
		test_grep "^1 \\.M .* tracked$" .git/expect &&
		test_grep "^? \\.gitattributes$" .git/expect &&
		for outcome in T E TT TE
		do
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE="$outcome"CCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$outcome.trace" \
				git status --porcelain=v2 >.git/actual &&
			test_cmp .git/expect .git/actual &&
			test_trace2_data status clean-proof/miss fast-provider-changed \
				<".git/$outcome.trace" &&
			test_trace2_data status clean-proof/provider-reset-carried 1 \
				<".git/$outcome.trace" &&
			case "$outcome" in
			E)
				! test_trace2_data fsm_client query/trivial-response 1 \
					<".git/$outcome.trace"
				;;
			*)
				test_trace2_data fsm_client query/trivial-response 1 \
					<".git/$outcome.trace" >.git/trivial-responses &&
				if test "$outcome" = TT
				then
					test_line_count = 2 .git/trivial-responses
				else
					test_line_count = 1 .git/trivial-responses
				fi
				;;
			esac &&
			test_grep ! "\"key\":\"clean-proof/hit\"" \
				".git/$outcome.trace" &&
			test_cmp_bin .git/index.before .git/index &&
			case "$outcome" in
			TT)
				test_trace2_data fsmonitor \
					semantic/token-reset-stat-baseline 1 \
					<.git/TT.trace &&
				test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<.git/TT.trace >.git/TT.scans &&
				test_line_count = 1 .git/TT.scans &&
				! test_trace2_data fsmonitor \
					semantic/manifest-scan-count 2 \
					<.git/TT.trace
				;;
			TE)
				! test_trace2_data fsmonitor \
					semantic/token-reset-stat-baseline 1 \
					<.git/TE.trace &&
				test_trace2_data fsmonitor \
					semantic/manifest-scan-count 1 \
					<.git/TE.trace &&
				test_trace2_data fsmonitor \
					semantic/manifest-scan-count 2 \
					<.git/TE.trace
				;;
			esac || return 1
		done &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
		GIT_TRACE2_EVENT="$PWD/.git/delta.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		! test_trace2_data status clean-proof/provider-reset-carried 1 \
			<.git/delta.trace &&
		! test_trace2_data fsm_client query/trivial-response 1 \
			<.git/delta.trace &&
		test_cmp_bin .git/index.before .git/index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/writable.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_trace2_data status clean-proof/provider-reset-carried 1 \
			<.git/writable.trace &&
		! test_trace2_data status clean-proof/sidecar 1 \
			<.git/writable.trace &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/follower &&
		test_cmp .git/expect .git/follower
	)
'

test_expect_success PERL_TEST_HELPERS \
	'a rewritten skipHash index reissues its clean status sidecar' '
	test_when_finished "rm -rf sidecar-skiphash-postwrite" &&
	test_create_repo sidecar-skiphash-postwrite &&
	(
		cd sidecar-skiphash-postwrite &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test-tool chmtime =-180 tracked &&
		git -c core.fsmonitor=false update-index --refresh &&
		git config index.version 4 &&
		git config index.skipHash true &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git update-index --fsmonitor &&
		test_env GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			bulk_status status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		rawsz=$(test_oid rawsz) &&
		dd if=/dev/zero of=.git/zero-trailer \
			bs="$rawsz" count=1 2>/dev/null &&
		tail -c "$rawsz" .git/index >.git/trailer &&
		test_cmp_bin .git/zero-trailer .git/trailer &&
		test_env GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			bulk_status status --porcelain=v2 >.git/issue &&
		test_must_be_empty .git/issue &&
		test_path_is_file .git/index.csts &&

		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				-c core.trustctime=true \
				-c core.checkStat=default \
				status >.git/expected &&
		cp .git/index .git/index.before-noop &&
		cp .git/index.csts .git/index.csts.before-noop &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/noop.trace" \
			git status >.git/noop &&
		test_cmp .git/expected .git/noop &&
		test_trace2_data status clean-proof/hit 1 \
			<.git/noop.trace &&
		test_region ! index do_read_index .git/noop.trace &&
		test_region ! index do_write_index .git/noop.trace &&
		test_cmp_bin .git/index.before-noop .git/index &&
		test_cmp_bin .git/index.csts.before-noop .git/index.csts &&

		before_inode=$(/usr/bin/stat -f %i .git/index) &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git update-index --force-write-index &&
		foreign_inode=$(/usr/bin/stat -f %i .git/index) &&
		test "$before_inode" != "$foreign_inode" &&
		tail -c "$rawsz" .git/index >.git/trailer &&
		test_cmp_bin .git/zero-trailer .git/trailer &&
		test_cmp_bin .git/index.csts.before-noop .git/index.csts &&
		cp .git/index .git/index.foreign &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/foreign.trace" \
			git status >.git/foreign &&
		test_cmp .git/expected .git/foreign &&
		test_trace2_data status clean-proof/miss \
			fast-index-mismatch <.git/foreign.trace &&
		! test_trace2_data status clean-proof/hit 1 \
			<.git/foreign.trace &&
		test_region ! index do_write_index .git/foreign.trace &&
		test_cmp_bin .git/index.foreign .git/index &&
		test_cmp_bin .git/index.csts.before-noop .git/index.csts &&

		test-tool chmtime =-90 tracked &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				-c core.trustctime=true \
				-c core.checkStat=default \
				status >.git/expected &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$PWD/.git/repair.trace" \
			git -c core.preloadIndex=true \
				-c core.preloadIndexBulk=true \
				status >.git/actual &&
		test_cmp .git/expected .git/actual &&
		test_trace2_data status clean-proof/miss \
			fast-index-mismatch <.git/repair.trace &&
		test_trace2_data fsmonitor apply_count 1 \
			<.git/repair.trace &&
		test_region index do_write_index .git/repair.trace &&
		repaired_inode=$(/usr/bin/stat -f %i .git/index) &&
		test "$repaired_inode" != "$foreign_inode" &&
		! test_cmp_bin .git/index.foreign .git/index &&
		tail -c "$rawsz" .git/index >.git/trailer &&
		test_cmp_bin .git/zero-trailer .git/trailer &&
		test_trace2_data status clean-proof/sidecar 1 \
			<.git/repair.trace &&
		test_trace2_data status clean-proof/postwrite-reissued 1 \
			<.git/repair.trace &&
		! test_trace2_data status clean-proof/miss \
			issue-pinned-inputs <.git/repair.trace &&

		cp .git/index .git/index.before-follower &&
		cp .git/index.csts .git/index.csts.before-follower &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/follower.trace" \
			git -c core.preloadIndex=true \
				-c core.preloadIndexBulk=true \
				status >.git/follower &&
		test_cmp .git/expected .git/follower &&
		test_trace2_data status clean-proof/hit 1 \
			<.git/follower.trace &&
		test_region ! index do_read_index .git/follower.trace &&
		test_region ! index do_write_index .git/follower.trace &&
		test_cmp_bin .git/index.before-follower .git/index &&
		test_cmp_bin .git/index.csts.before-follower .git/index.csts
	)
'

test_expect_success PERL_TEST_HELPERS \
	'index write receipts reject in-place and foreign hook mutations' '
	test_when_finished "rm -rf sidecar-receipt-valid sidecar-receipt-same-inode sidecar-receipt-foreign-replace" &&
	for mode in valid same-inode foreign-replace
	do
		repo=sidecar-receipt-$mode &&
		test_create_repo "$repo" &&
		(
			cd "$repo" &&
			sane_unset GIT_TEST_SPLIT_INDEX &&
			test_commit base tracked &&
			test-tool chmtime =-180 tracked &&
			git -c core.fsmonitor=false update-index --refresh &&
			git config index.version 4 &&
			git config index.skipHash true &&
			git config core.autocrlf false &&
			git config core.untrackedCache true &&
			git config core.fsmonitor true &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git update-index --fsmonitor &&
			test_env GIT_INDEX_FILE="$PWD/.git/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				bulk_status status --porcelain=v2 >.git/prime &&
			test_must_be_empty .git/prime &&
			test_grep FSCF .git/index &&
			test_grep FSUC .git/index &&
			test_env GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				bulk_status status --porcelain=v2 >.git/issued &&
			test_must_be_empty .git/issued &&
			test_path_is_file .git/index.csts &&
			cp .git/index.csts .git/sidecar.before &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git update-index --force-write-index &&
			test_cmp_bin .git/sidecar.before .git/index.csts &&
			rawsz=$(test_oid rawsz) &&
			printf "%s\n" "$rawsz" >.git/receipt-rawsz &&
			dd if=/dev/zero of=.git/zero-trailer \
				bs="$rawsz" count=1 2>/dev/null &&
			test-tool chmtime =-90 tracked &&
			GIT_OPTIONAL_LOCKS=0 \
				git -c core.fsmonitor=false \
					-c core.untrackedCache=false \
					-c core.trustctime=true \
					-c core.checkStat=default \
					status >.git/expected &&

			if test "$mode" != valid
			then
				printf "%s\n" "$mode" >.git/receipt-mode &&
				cat >.git/receipt-mutate.pl <<-\EOF &&
				use strict;
				use warnings;
				my $path = shift;
				open(my $index, "+<", $path) or die "open: $!";
				binmode $index;
				read($index, my $header, 12) == 12 or die "header";
				substr($header, 0, 4) eq "DIRC" or die "magic";
				unpack("N", substr($header, 8, 4)) or die "entries";
				seek($index, 16, 0) or die "seek";
				read($index, my $ctime, 4) == 4 or die "ctime";
				seek($index, 16, 0) or die "rewind";
				my $next = (unpack("N", $ctime) + 1) % 1000000000;
				print {$index} pack("N", $next) or die "write";
				close($index) or die "close";
				EOF
				write_script .git/hooks/post-index-change <<-\EOF
				mode=$(cat .git/receipt-mode) &&
				/usr/bin/stat -f %i .git/index >.git/hook-inode-before &&
				cp .git/index .git/hook-index-before &&
				rm -f "$0" &&
				case "$mode" in
				same-inode)
					perl .git/receipt-mutate.pl .git/index
					;;
				foreign-replace)
					cp .git/index .git/hook-replacement &&
					mv .git/hook-replacement .git/index
					;;
				*)
					exit 1
					;;
				esac &&
				/usr/bin/stat -f %i .git/index >.git/hook-inode-after &&
				tail -c "$(cat .git/receipt-rawsz)" .git/index \
					>.git/hook-trailer
				EOF
			else
				:
			fi &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
				git -c core.preloadIndex=true \
					-c core.preloadIndexBulk=true \
					status >.git/actual &&
			test_cmp .git/expected .git/actual &&
			test_region index do_write_index .git/status.trace &&
			test_trace2_data fsmonitor \
				history/own-write-source-recorded 1 \
				<.git/status.trace &&
			tail -c "$rawsz" .git/index >.git/trailer &&
			test_cmp_bin .git/zero-trailer .git/trailer &&

			case "$mode" in
			valid)
				test_trace2_data fsmonitor \
					history/own-write-source-adopted 1 \
					<.git/status.trace &&
				test_trace2_data status \
					clean-proof/postwrite-reissued 1 \
					<.git/status.trace
				;;
			same-inode|foreign-replace)
				test_path_is_missing .git/hooks/post-index-change &&
				test_cmp_bin .git/zero-trailer .git/hook-trailer &&
				! test_trace2_data fsmonitor \
					history/own-write-source-adopted 1 \
					<.git/status.trace &&
				! test_trace2_data status \
					clean-proof/sidecar 1 \
					<.git/status.trace &&
				! test_trace2_data status \
					clean-proof/postwrite-reissued 1 \
					<.git/status.trace &&
				test_cmp_bin .git/sidecar.before .git/index.csts &&
				if test "$mode" = same-inode
				then
					test_cmp .git/hook-inode-before \
						.git/hook-inode-after &&
					! test_cmp_bin .git/hook-index-before .git/index
				else
					! test_cmp .git/hook-inode-before \
						.git/hook-inode-after &&
					test_cmp_bin .git/hook-index-before .git/index
				fi
				;;
			esac &&
			cp .git/index .git/follower-index &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/follower.trace" \
				git -c core.preloadIndex=true \
					-c core.preloadIndexBulk=true \
					status >.git/follower &&
			test_cmp .git/expected .git/follower &&
			test_cmp_bin .git/follower-index .git/index &&
			test_region ! index do_write_index .git/follower.trace &&
			if test "$mode" = valid
			then
				test_trace2_data status clean-proof/hit 1 \
					<.git/follower.trace
			else
				test_trace2_data status clean-proof/miss \
					fast-index-mismatch <.git/follower.trace &&
				! test_trace2_data status clean-proof/hit 1 \
					<.git/follower.trace
			fi
		) || return 1
	done
'

test_expect_success PERL_TEST_HELPERS \
	'index write receipts reject unchanged and private indexes' '
	test_when_finished "rm -rf sidecar-receipt-private" &&
	test_create_repo sidecar-receipt-private &&
	(
		cd sidecar-receipt-private &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test-tool chmtime =-180 tracked &&
		git -c core.fsmonitor=false update-index --refresh &&
		git config index.version 4 &&
		git config index.skipHash true &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git update-index --fsmonitor &&
		test_env GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			bulk_status status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_env GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			bulk_status status --porcelain=v2 >.git/issued &&
		test_must_be_empty .git/issued &&
		test_path_is_file .git/index.csts &&
		cp .git/index .git/canonical.before &&
		cp .git/index.csts .git/sidecar.before &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/noop.trace" \
			git status >.git/noop &&
		test_trace2_data status clean-proof/hit 1 \
			<.git/noop.trace &&
		! test_trace2_data fsmonitor \
			history/own-write-source-recorded 1 <.git/noop.trace &&
		! test_trace2_data fsmonitor \
			history/own-write-source-adopted 1 <.git/noop.trace &&
		test_cmp_bin .git/canonical.before .git/index &&
		test_cmp_bin .git/sidecar.before .git/index.csts &&

		cp .git/index .git/private.index &&
		test-tool chmtime =-90 tracked &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				-c core.trustctime=true \
				-c core.checkStat=default \
				status >.git/expected &&
		GIT_INDEX_FILE="$PWD/.git/private.index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$PWD/.git/private.trace" \
			git status >.git/private.actual &&
		test_cmp .git/expected .git/private.actual &&
		test_region index do_write_index .git/private.trace &&
		! test_trace2_data fsmonitor \
			history/own-write-source-recorded 1 <.git/private.trace &&
		! test_trace2_data fsmonitor \
			history/own-write-source-adopted 1 <.git/private.trace &&
		test_cmp_bin .git/canonical.before .git/index &&
		test_cmp_bin .git/sidecar.before .git/index.csts
	)
'

test_expect_success PERL_TEST_HELPERS \
	'a provider reset reissues an otherwise current skipHash sidecar' '
	test_when_finished "rm -rf sidecar-receipt-provider-reset" &&
	test_create_repo sidecar-receipt-provider-reset &&
	(
		cd sidecar-receipt-provider-reset &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test-tool chmtime =-180 tracked &&
		git -c core.fsmonitor=false update-index --refresh &&
		git config index.version 4 &&
		git config index.skipHash true &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git update-index --fsmonitor &&
		test_env GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			bulk_status status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		test_env GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			bulk_status status --porcelain=v2 >.git/issued &&
		test_must_be_empty .git/issued &&
		test_path_is_file .git/index.csts &&
		rawsz=$(test_oid rawsz) &&
		dd if=/dev/zero of=.git/zero-trailer \
			bs="$rawsz" count=1 2>/dev/null &&
		tail -c "$rawsz" .git/index >.git/trailer &&
		test_cmp_bin .git/zero-trailer .git/trailer &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				-c core.trustctime=true \
				-c core.checkStat=default \
				status >.git/expected &&
		cp .git/index .git/index.before &&
		cp .git/index.csts .git/sidecar.before &&
		before_inode=$(/usr/bin/stat -f %i .git/index) &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/hit.trace" \
			git status >.git/hit &&
		test_cmp .git/expected .git/hit &&
		test_trace2_data status clean-proof/hit 1 <.git/hit.trace &&
		test_region ! index do_read_index .git/hit.trace &&
		test_region ! index do_write_index .git/hit.trace &&
		test_cmp_bin .git/index.before .git/index &&
		test_cmp_bin .git/sidecar.before .git/index.csts &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/reset.trace" \
			git -c core.preloadIndex=true \
				-c core.preloadIndexBulk=true \
				status >.git/actual &&
		test_cmp .git/expected .git/actual &&
		test_trace2_data status clean-proof/miss \
			fast-provider-changed <.git/reset.trace &&
		test_trace2_data status clean-proof/provider-reset-carried 1 \
			<.git/reset.trace &&
		test_region index do_write_index .git/reset.trace &&
		after_inode=$(/usr/bin/stat -f %i .git/index) &&
		test "$before_inode" != "$after_inode" &&
		tail -c "$rawsz" .git/index >.git/trailer &&
		test_cmp_bin .git/zero-trailer .git/trailer &&
		test_trace2_data fsmonitor \
			history/own-write-source-recorded 1 <.git/reset.trace &&
		test_trace2_data fsmonitor \
			history/own-write-source-adopted 1 <.git/reset.trace &&
		test_trace2_data status clean-proof/sidecar 1 \
			<.git/reset.trace &&
		test_trace2_data status clean-proof/postwrite-reissued 1 \
			<.git/reset.trace &&
		! test_cmp_bin .git/sidecar.before .git/index.csts &&
		cp .git/index .git/index.after &&
		cp .git/index.csts .git/sidecar.after &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/follower.trace" \
			git -c core.preloadIndex=true \
				-c core.preloadIndexBulk=true \
				status >.git/follower &&
		test_cmp .git/expected .git/follower &&
		test_trace2_data status clean-proof/hit 1 \
			<.git/follower.trace &&
		test_region ! index do_read_index .git/follower.trace &&
		test_region ! index do_write_index .git/follower.trace &&
		test_cmp_bin .git/index.after .git/index &&
		test_cmp_bin .git/sidecar.after .git/index.csts
	)
'

test_expect_success PERL_TEST_HELPERS \
	'a plain clean status reissues a proof after nonsemantic config changes' '
	test_create_repo sidecar-config-reissue &&
	(
		cd sidecar-config-reissue &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test-tool chmtime =-180 tracked &&
		git -c core.fsmonitor=false update-index --refresh &&
		git config index.version 4 &&
		git config index.skipHash true &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git update-index --fsmonitor &&
		test_env GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			bulk_status status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		test_env GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			bulk_status status --porcelain=v2 >.git/issued &&
		test_must_be_empty .git/issued &&
		test_path_is_file .git/index.csts &&
		rawsz=$(test_oid rawsz) &&
		dd if=/dev/zero of=.git/zero-trailer \
			bs="$rawsz" count=1 2>/dev/null &&
		tail -c "$rawsz" .git/index >.git/trailer &&
		test_cmp_bin .git/zero-trailer .git/trailer &&
		cp .git/index .git/index.before &&
		cp .git/index.csts .git/sidecar.before &&
		before_inode=$(/usr/bin/stat -f %i .git/index) &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/baseline.trace" \
			git -c core.preloadIndex=true \
				-c core.preloadIndexBulk=true \
				status >.git/baseline &&
		test_trace2_data status clean-proof/hit 1 \
			<.git/baseline.trace &&
		test_region ! index do_read_index .git/baseline.trace &&
		test_region ! index do_write_index .git/baseline.trace &&
		test_cmp_bin .git/index.before .git/index &&
		test_cmp_bin .git/sidecar.before .git/index.csts &&
		test "$before_inode" = "$(/usr/bin/stat -f %i .git/index)" &&

		git config status.relativePaths false &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				-c core.trustctime=true \
				-c core.checkStat=default \
				status >.git/expected &&
		test_cmp .git/baseline .git/expected &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/readonly.trace" \
			git -c core.preloadIndex=true \
				-c core.preloadIndexBulk=true \
				status >.git/readonly &&
		test_cmp .git/expected .git/readonly &&
		test_trace2_data status clean-proof/miss \
			fast-config-changed <.git/readonly.trace &&
		! test_trace2_data status clean-proof/sidecar 1 \
			<.git/readonly.trace &&
		test_region ! index do_write_index .git/readonly.trace &&
		test_cmp_bin .git/index.before .git/index &&
		test_cmp_bin .git/sidecar.before .git/index.csts &&
		test "$before_inode" = "$(/usr/bin/stat -f %i .git/index)" &&

		GIT_OPTIONAL_LOCKS=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/reissue.trace" \
			git -c core.preloadIndex=true \
				-c core.preloadIndexBulk=true \
				status >.git/actual &&
		cp .git/index .git/index.after &&
		cp .git/index.csts .git/sidecar.after &&
		after_inode=$(/usr/bin/stat -f %i .git/index) &&
		test_cmp .git/expected .git/actual &&
		test_trace2_data status clean-proof/miss \
			fast-config-changed <.git/reissue.trace &&
		test_trace2_data status clean-proof/sidecar 1 \
			<.git/reissue.trace &&
		! test_trace2_data status clean-proof/provider-reset-carried 1 \
			<.git/reissue.trace &&
		test_region ! index do_write_index .git/reissue.trace &&
		test_cmp_bin .git/index.before .git/index.after &&
		test "$before_inode" = "$after_inode" &&
		! test_cmp_bin .git/sidecar.before .git/sidecar.after &&

		GIT_OPTIONAL_LOCKS=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/follower.trace" \
			git -c core.preloadIndex=true \
				-c core.preloadIndexBulk=true \
				status >.git/follower &&
		test_cmp .git/expected .git/follower &&
		test_trace2_data status clean-proof/hit 1 \
			<.git/follower.trace &&
		test_region ! index do_read_index .git/follower.trace &&
		test_region ! index do_write_index .git/follower.trace &&
		test_cmp_bin .git/index.after .git/index &&
		test_cmp_bin .git/sidecar.after .git/index.csts &&
		test "$after_inode" = "$(/usr/bin/stat -f %i .git/index)"
	)
'

sidecar_aba_setup () {
	sidecar_aba_path=$1 &&
	sane_unset GIT_TEST_SPLIT_INDEX &&
	test_commit base "$sidecar_aba_path" &&
	test-tool chmtime =-180 "$sidecar_aba_path" &&
	git -c core.fsmonitor=false update-index --refresh &&
	git config index.version 4 &&
	git config index.skipHash true &&
	git config core.autocrlf false &&
	git config core.untrackedCache true &&
	git config core.fsmonitor true &&
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		git update-index --fsmonitor &&
	test_env GIT_INDEX_FILE="$PWD/.git/index" \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		bulk_status status --porcelain=v2 >.git/prime &&
	test_must_be_empty .git/prime &&
	test_grep FSCF .git/index &&
	test_grep FSUC .git/index &&
	test_env GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		bulk_status status --porcelain=v2 >.git/issued &&
	test_must_be_empty .git/issued &&
	test_path_is_file .git/index.csts &&
	rawsz=$(test_oid rawsz) &&
	dd if=/dev/zero of=.git/zero-trailer \
		bs="$rawsz" count=1 2>/dev/null &&
	tail -c "$rawsz" .git/index >.git/trailer &&
	test_cmp_bin .git/zero-trailer .git/trailer &&
	cp .git/config .git/config.before &&
	cp .git/index .git/index.before &&
	cp .git/index.csts .git/sidecar.before &&
	/usr/bin/stat -f "%d %i %l %z %p %u %g %m %c %B" \
		.git/index >.git/index.before.stat &&
	/usr/bin/stat -f "%d %i %l %z %p %u %g %m %c %B" \
		.git/index.csts >.git/sidecar.before.stat
}

sidecar_aba_capture () {
	sidecar_aba_label=$1 &&
	sidecar_aba_mode=$2 &&
	shift 2 &&
	case "$sidecar_aba_mode" in
	clean)
		sidecar_aba_locks=1 &&
		sidecar_aba_sequence=CCCCCCCC
		;;
	readonly)
		sidecar_aba_locks=0 &&
		sidecar_aba_sequence=CCCCCCCC
		;;
	dirty)
		sidecar_aba_locks=0 &&
		sidecar_aba_sequence=DDCCCCCCCC
		;;
	*) return 1 ;;
	esac &&
	GIT_OPTIONAL_LOCKS=$sidecar_aba_locks \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=$sidecar_aba_sequence \
	GIT_TEST_FSMONITOR_QUERY_PATH="$sidecar_aba_path" \
	GIT_TRACE2_EVENT_NESTING=100 \
	GIT_TRACE2_EVENT="$PWD/.git/$sidecar_aba_label.trace" \
		git "$@" >".git/$sidecar_aba_label.actual" &&
	cp .git/index ".git/$sidecar_aba_label.index" &&
	cp .git/index.csts ".git/$sidecar_aba_label.csts" &&
	/usr/bin/stat -f "%d %i %l %z %p %u %g %m %c %B" \
		.git/index >".git/$sidecar_aba_label.index.stat" &&
	/usr/bin/stat -f "%d %i %l %z %p %u %g %m %c %B" \
		.git/index.csts >".git/$sidecar_aba_label.csts.stat" &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TRACE2_EVENT_NESTING=100 \
	GIT_TRACE2_EVENT="$PWD/.git/$sidecar_aba_label.oracle.trace" \
		git -c core.fsmonitor=false \
			-c core.untrackedCache=false \
			-c core.trustctime=true \
			-c core.checkStat=default \
			"$@" >".git/$sidecar_aba_label.expect" &&
	cp .git/index ".git/$sidecar_aba_label.oracle.index" &&
	cp .git/index.csts ".git/$sidecar_aba_label.oracle.csts" &&
	/usr/bin/stat -f "%d %i %l %z %p %u %g %m %c %B" \
		.git/index >".git/$sidecar_aba_label.oracle.index.stat" &&
	/usr/bin/stat -f "%d %i %l %z %p %u %g %m %c %B" \
		.git/index.csts >".git/$sidecar_aba_label.oracle.csts.stat"
}

sidecar_aba_assert_unchanged () {
	for sidecar_aba_label in "$@"
	do
		test_cmp ".git/$sidecar_aba_label.expect" \
			".git/$sidecar_aba_label.actual" &&
		test_cmp_bin .git/index.before \
			".git/$sidecar_aba_label.index" &&
		test_cmp .git/index.before.stat \
			".git/$sidecar_aba_label.index.stat" &&
		test_cmp_bin ".git/$sidecar_aba_label.index" \
			".git/$sidecar_aba_label.oracle.index" &&
		test_cmp ".git/$sidecar_aba_label.index.stat" \
			".git/$sidecar_aba_label.oracle.index.stat" &&
		test_cmp_bin .git/sidecar.before \
			".git/$sidecar_aba_label.csts" &&
		test_cmp .git/sidecar.before.stat \
			".git/$sidecar_aba_label.csts.stat" &&
		test_cmp_bin ".git/$sidecar_aba_label.csts" \
			".git/$sidecar_aba_label.oracle.csts" &&
		test_cmp ".git/$sidecar_aba_label.csts.stat" \
			".git/$sidecar_aba_label.oracle.csts.stat" &&
		test_region ! index do_write_index \
			".git/$sidecar_aba_label.trace" &&
		test_region ! index do_write_index \
			".git/$sidecar_aba_label.oracle.trace" ||
			return 1
	done
}

test_expect_success PERL_TEST_HELPERS \
	'temporary status presentation settings preserve the original clean proof' '
	test_create_repo sidecar-command-config-aba &&
	(
		cd sidecar-command-config-aba &&
		mkdir subdir &&
		git config color.status.branch red &&
		sidecar_aba_setup tracked &&
		test_must_fail git config --get status.relativePaths \
			>.git/relativepaths.absent &&
		test_must_fail git config --get color.ui >.git/color.absent &&
		test_must_fail git config --get core.quotePath >.git/quotepath.absent &&

		# Retain every pair before testing the fast-path behavior.
		sidecar_aba_capture a0 clean status &&
		sidecar_aba_capture b clean -c status.relativePaths=false status &&
		sidecar_aba_capture a1 clean status &&
		sidecar_aba_capture color-off clean -c color.ui=false status &&
		sidecar_aba_capture color-a clean status &&
		sidecar_aba_capture quote-off clean -c core.quotePath=false status &&
		sidecar_aba_capture quote-a clean status &&
		sidecar_aba_capture color-on clean -c color.ui=always status &&
		sidecar_aba_capture color-final-a clean status &&
		sidecar_aba_capture subdir clean \
			-C subdir -c status.relativePaths=false status &&
		test_write_lines changed >tracked &&
		sidecar_aba_capture dirty-relative dirty -C subdir status &&
		sidecar_aba_capture dirty-root dirty \
			-C subdir -c status.relativePaths=false status &&

		sidecar_aba_assert_unchanged \
			a0 b a1 color-off color-a quote-off quote-a \
			color-on color-final-a subdir dirty-relative dirty-root &&
		for sidecar_aba_label in a0 b a1 color-off color-a \
			quote-off quote-a color-on color-final-a subdir
		do
			test_trace2_data status clean-proof/hit 1 \
				<".git/$sidecar_aba_label.trace" &&
			test_region ! index do_read_index \
				".git/$sidecar_aba_label.trace" &&
			! test_trace2_data status clean-proof/sidecar 1 \
				<".git/$sidecar_aba_label.trace" ||
				exit 1
		done &&
		test_decode_color <.git/color-on.actual >.git/color-on.decoded &&
		test_grep "^On branch <RED>.*<RESET>$" .git/color-on.decoded &&
		test_decode_color <.git/color-off.actual >.git/color-off.decoded &&
		test_grep ! "<RED>" .git/color-off.decoded &&
		test_cmp .git/a0.actual .git/color-off.actual &&
		! test_cmp_bin .git/color-off.actual .git/color-on.actual &&
		for sidecar_aba_label in dirty-relative dirty-root
		do
			test_trace2_data status clean-proof/miss fast-provider-changed \
				<".git/$sidecar_aba_label.trace" &&
			! test_trace2_data status clean-proof/hit 1 \
				<".git/$sidecar_aba_label.trace" ||
				exit 1
		done &&
		test_grep "modified:   \.\./tracked$" .git/dirty-relative.actual &&
		test_grep "modified:   tracked$" .git/dirty-root.actual &&
		test_grep ! "modified:   \.\./tracked$" .git/dirty-root.actual &&
		test_cmp_bin .git/config.before .git/config &&
		test_cmp_bin .git/index.before .git/index &&
		test_cmp_bin .git/sidecar.before .git/index.csts
	)
'

test_expect_success PERL_TEST_HELPERS \
	'the current quotePath setting still controls dirty status output' '
	test_create_repo sidecar-command-quotepath &&
	(
		cd sidecar-command-quotepath &&
		quoted_path=$(printf "tracked-\303\270") &&
		sidecar_aba_setup "$quoted_path" &&
		test_write_lines changed >"$quoted_path" &&
		sidecar_aba_capture quoted dirty -c core.quotePath=true status &&
		sidecar_aba_capture unquoted dirty -c core.quotePath=false status &&
		sidecar_aba_assert_unchanged quoted unquoted &&
		for sidecar_aba_label in quoted unquoted
		do
			test_trace2_data status clean-proof/miss fast-provider-changed \
				<".git/$sidecar_aba_label.trace" &&
			! test_trace2_data status clean-proof/hit 1 \
				<".git/$sidecar_aba_label.trace" ||
				exit 1
		done &&
		test_grep -F "modified:   \"tracked-\\303\\270\"" .git/quoted.actual &&
		test_grep -F "modified:   $quoted_path" .git/unquoted.actual &&
		! test_cmp_bin .git/quoted.actual .git/unquoted.actual &&
		test_cmp_bin .git/config.before .git/config
	)
'

test_expect_success PERL_TEST_HELPERS \
	'presentation config normalization does not suppress parse errors or persistent changes' '
	test_create_repo sidecar-presentation-config &&
	(
		cd sidecar-presentation-config &&
		sidecar_aba_setup tracked &&
		for key in color.ui core.quotePath
		do
			GIT_OPTIONAL_LOCKS=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$key.invalid.trace" \
				test_must_fail git -c "$key=invalid" status \
				>".git/$key.invalid.out" 2>".git/$key.invalid.err" &&
			test_must_be_empty ".git/$key.invalid.out" &&
			test_grep "bad boolean config value" ".git/$key.invalid.err" &&
			test_region ! index do_read_index ".git/$key.invalid.trace" &&
			test_region ! index do_write_index ".git/$key.invalid.trace" &&
			test_cmp_bin .git/index.before .git/index &&
			test_cmp_bin .git/sidecar.before .git/index.csts ||
				exit 1
		done &&
		for key in color.ui core.quotePath
		do
			git config "$key" false &&
			sidecar_aba_capture "$key" readonly status &&
			sidecar_aba_assert_unchanged "$key" &&
			test_trace2_data status clean-proof/miss fast-config-changed \
				<".git/$key.trace" &&
			! test_trace2_data status clean-proof/sidecar 1 \
				<".git/$key.trace" &&
			cp .git/config.before .git/config ||
				exit 1
		done &&
		test_cmp_bin .git/config.before .git/config
	)
'

test_done
