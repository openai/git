#!/bin/sh

test_description='fsmonitor cookie-retirement daemon compatibility'

. ./test-lib.sh

if ! test_have_prereq FSMONITOR_DAEMON
then
	skip_all='fsmonitor--daemon is not supported on this platform'
	test_done
fi

if test_have_prereq MACOS
then
	fsmonitor_pre_cookie_token_prefix=dirmeta-v1.inode-v1.
	fsmonitor_cookie_token_prefix=${fsmonitor_pre_cookie_token_prefix}cookie-v1.fence-v1.
elif test "$uname_s" = Linux
then
	fsmonitor_pre_cookie_token_prefix=dirmeta-v1.
	fsmonitor_cookie_token_prefix=cookie-v1.dirmeta-v1.
else
	fsmonitor_pre_cookie_token_prefix=
	fsmonitor_cookie_token_prefix=cookie-v1.
fi

stop_cookie_compat_daemon () {
	cookie_compat_repo=$1 &&
	test -d "$cookie_compat_repo/.git" || return 0
	cookie_compat_ipc=$(
		git -C "$cookie_compat_repo" \
			rev-parse --path-format=absolute \
			--git-path fsmonitor--daemon.ipc 2>/dev/null
	) || return 0
	test-tool simple-ipc stop-daemon \
		--name="$cookie_compat_ipc" --max-wait=5 \
		>/dev/null 2>&1 || :
}

have_t2_data_event () {
	grep -e '"event":"data".*"category":"'"$1"'".*"key":"'"$2"'"'
}

# Unlike test_when_finished, these still stop our private daemons under -i.
test_atexit 'stop_cookie_compat_daemon cookie-retirement-upgrade'
test_atexit 'stop_cookie_compat_daemon cookie-retirement-unmarked'

test_expect_success \
	'a marked provider boundary replaces pre-retirement daemons once' '
	test_when_finished \
		"stop_cookie_compat_daemon cookie-retirement-upgrade" &&
	test_create_repo cookie-retirement-upgrade &&
	(
		cd cookie-retirement-upgrade &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		test_write_lines modified >tracked &&
		test_write_lines visible >visible &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				status --porcelain=v2 >.git/expected &&
		test_grep "^1 \\.M .* tracked$" .git/expected &&
		test_grep "^? visible$" .git/expected &&
		git config core.fsmonitor true &&
		ipc_path=$(git rev-parse --path-format=absolute \
			--git-path fsmonitor--daemon.ipc) &&
		test-tool simple-ipc start-daemon \
			--name="$ipc_path" --threads=1 --max-wait=10 \
			--fsmonitor-pre-cookie-retirement &&
		test-tool simple-ipc send --name="$ipc_path" \
			--token=get-capabilities >.git/old-capabilities &&
		test_grep "^query-v1$" .git/old-capabilities &&
		test_grep ! "^cookie-token-retirement-v1$" \
			.git/old-capabilities &&
		old_token="builtin:${fsmonitor_pre_cookie_token_prefix}test-pre-cookie:0" &&
		GIT_TRACE2_EVENT="$PWD/.git/upgrade.trace" \
			test-tool fsmonitor-client query \
				--token "$old_token" >.git/upgrade.raw &&
		nul_to_q <.git/upgrade.raw >.git/upgrade.response &&
		test_grep "^builtin:${fsmonitor_cookie_token_prefix}" \
			.git/upgrade.response &&
		test_trace2_data fsm_client query/command \
			"$old_token" <.git/upgrade.trace &&
		test_trace2_data fsm_client query/unmarked-response 1 \
			<.git/upgrade.trace &&
		test_trace2_data fsm_client query/incompatible-daemon 1 \
			<.git/upgrade.trace >.git/restarts &&
		test_line_count = 1 .git/restarts &&
		test_grep \
			"\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
			.git/upgrade.trace &&
		GIT_TRACE2_EVENT="$PWD/.git/prime.trace" \
			git status --porcelain=v2 >.git/prime &&
		test_cmp .git/expected .git/prime &&
		current_token=$(sed -n "1s/Q.*//p" .git/upgrade.response) &&
		worktree_identity=$(
			sed -n \
				"s/.*\"category\":\"fsmonitor\",\"key\":\"request\",\"value\":\"query-v[12] \\([0-9a-f]*\\)\\\\n.*/\\1/p" \
				.git/upgrade.trace |
			sed -n 1p
		) &&
		test ${#worktree_identity} = 64 &&
		for legacy_protocol in raw query-v1 query-v2
		do
			if test "$legacy_protocol" = raw
			then
				legacy_command=$current_token
			else
				legacy_command=$(printf "%s %s\\n%s" \
					"$legacy_protocol" "$worktree_identity" \
					"$current_token")
			fi &&
			test-tool simple-ipc send --name="$ipc_path" \
				--token="$legacy_command" \
				>".git/legacy-$legacy_protocol.response" &&
			test_grep "^builtin:${fsmonitor_cookie_token_prefix}" \
				".git/legacy-$legacy_protocol.response" || return 1
		done &&
		test-tool simple-ipc stop-daemon \
			--name="$ipc_path" --max-wait=5 &&
		GIT_TRACE2_EVENT="$PWD/.git/marked-provider.trace" \
			test-tool simple-ipc start-daemon \
				--name="$ipc_path" --threads=1 --max-wait=10 \
				--fsmonitor-capability-superset &&
		test-tool simple-ipc send --name="$ipc_path" \
			--token=get-capabilities >.git/marked-capabilities &&
		test_grep "^cookie-token-retirement-v1$" \
			.git/marked-capabilities &&
		test_trace2_data fsmonitor request get-capabilities \
			<.git/marked-provider.trace \
			>.git/capabilities.before &&
		test_line_count = 1 .git/capabilities.before &&
		marked_token="builtin:${fsmonitor_cookie_token_prefix}test-capable:0" &&
		printf "%s\\000" "$marked_token" >.git/warm.expected &&
		for warm_query in first repeated
		do
			GIT_TRACE2_EVENT="$PWD/.git/warm-$warm_query.trace" \
				test-tool fsmonitor-client query \
					--token "$marked_token" \
					>".git/warm-$warm_query.actual" &&
			test_cmp_bin .git/warm.expected \
				".git/warm-$warm_query.actual" &&
			have_t2_data_event fsm_client query/response-length \
				<".git/warm-$warm_query.trace" &&
			! test_trace2_data fsm_client query/unmarked-response 1 \
				<".git/warm-$warm_query.trace" &&
			! test_trace2_data fsm_client query/incompatible-daemon 1 \
				<".git/warm-$warm_query.trace" || return 1
		done &&
		test_trace2_data fsmonitor request get-capabilities \
			<.git/marked-provider.trace \
			>.git/capabilities.after &&
		test_cmp .git/capabilities.before .git/capabilities.after
	)
'

test_expect_success \
	'an advertised capability never authenticates an unmarked response' '
	test_when_finished \
		"stop_cookie_compat_daemon cookie-retirement-unmarked" &&
	test_create_repo cookie-retirement-unmarked &&
	(
		cd cookie-retirement-unmarked &&
		test_commit base tracked &&
		git config core.fsmonitor true &&
		ipc_path=$(git rev-parse --path-format=absolute \
			--git-path fsmonitor--daemon.ipc) &&
		test-tool simple-ipc start-daemon \
			--name="$ipc_path" --threads=1 --max-wait=10 \
			--fsmonitor-unmarked-response &&
		test-tool simple-ipc send --name="$ipc_path" \
			--token=get-capabilities >.git/capabilities &&
		test_grep "^cookie-token-retirement-v1$" \
			.git/capabilities &&
		old_token="builtin:${fsmonitor_pre_cookie_token_prefix}test-pre-cookie:0" &&
		test_must_fail env \
			GIT_TRACE2_EVENT="$PWD/.git/unmarked.trace" \
				test-tool fsmonitor-client query \
					--token "$old_token" \
					>.git/unmarked.raw \
					2>.git/unmarked.err &&
		test_must_be_empty .git/unmarked.raw &&
		test_trace2_data fsm_client query/unmarked-response 1 \
			<.git/unmarked.trace >.git/rejected-responses &&
		test_line_count = 4 .git/rejected-responses &&
		! test_trace2_data fsm_client query/incompatible-daemon 1 \
			<.git/unmarked.trace &&
		test-tool simple-ipc is-active --name="$ipc_path"
	)
'

test_done
