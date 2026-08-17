#!/bin/sh

test_description='failed fsmonitor cookies retire the provider boundary'

. ./test-lib.sh

if ! test_have_prereq FSMONITOR_DAEMON
then
	skip_all='fsmonitor--daemon is not supported on this platform'
	test_done
fi

test_expect_success 'a failed cookie permanently invalidates the old token' '
	test_when_finished "git -C cookie-reset fsmonitor--daemon stop 2>/dev/null || :" &&
	test_create_repo cookie-reset &&
	GIT_TRACE2_EVENT="$PWD/cookie-daemon.trace" \
		git -C cookie-reset fsmonitor--daemon start --start-timeout=10 &&
	test-tool -C cookie-reset fsmonitor-client flush >before &&
	nul_to_q <before >before.q &&
	test_grep "^builtin:.*:0Q/Q$" before.q &&
	old_token=$(sed "s/Q.*//" before.q) &&
	mv cookie-reset/.git/fsmonitor--daemon/cookies \
		cookie-reset/.git/fsmonitor--daemon/cookies.saved &&
	test_when_finished "test ! -d cookie-reset/.git/fsmonitor--daemon/cookies.saved ||
		mv cookie-reset/.git/fsmonitor--daemon/cookies.saved \
		cookie-reset/.git/fsmonitor--daemon/cookies" &&
	test-tool -C cookie-reset fsmonitor-client query \
		--token "$old_token" >failed &&
	nul_to_q <failed >failed.q &&
	test_grep "^builtin:.*:0Q/Q$" failed.q &&
	new_token=$(sed "s/Q.*//" failed.q) &&
	test "$old_token" != "$new_token" &&
	mv cookie-reset/.git/fsmonitor--daemon/cookies.saved \
		cookie-reset/.git/fsmonitor--daemon/cookies &&
	test-tool -C cookie-reset fsmonitor-client query \
		--token "$old_token" >recovered &&
	nul_to_q <recovered >recovered.q &&
	test_grep "^builtin:.*Q/Q$" recovered.q &&
	recovered_token=$(sed "s/Q.*//" recovered.q) &&
	test "$recovered_token" != "$old_token" &&
	if test "$recovered_token" = "$new_token" &&
		test_trace2_data fsmonitor response/token different \
			<cookie-daemon.trace
	then
		test_set_prereq COOKIE_REPLAY_COMPLETE
	fi
'

test_expect_success COOKIE_REPLAY_COMPLETE \
	'a successful later cookie still rejects the retired token' '
	test "$recovered_token" = "$new_token" &&
	test_trace2_data fsmonitor response/token different \
		<cookie-daemon.trace
'

test_done
