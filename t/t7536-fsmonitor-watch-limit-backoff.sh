#!/bin/sh

test_description='fsmonitor watch-limit backoff authenticates optional markers'

. ./test-lib.sh

if ! test_have_prereq FSMONITOR_DAEMON
then
	skip_all='fsmonitor--daemon is not supported on this platform'
	test_done
fi

case "$uname_s" in
Linux | Darwin)
	;;
*)
	skip_all='inotify watch-limit markers are not supported on this platform'
	test_done
	;;
esac

sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_FSMONITOR

setup_backoff_marker_fixture () {
	test_create_repo "$1" &&
	(
		cd "$1" &&
		test_commit base tracked &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_write_lines changed >tracked &&
		test_write_lines visible >visible &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			--no-optional-locks status --porcelain=v2 >.git/expect &&
		test_grep "^1 \\.M .* tracked$" .git/expect &&
		test_grep "^? visible$" .git/expect
	)
}

check_rejected_backoff_marker () {
	(
		cd "$1" &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=// \
		GIT_TRACE2_EVENT="$PWD/.git/$2.trace" \
			perl -e "alarm 5; exec @ARGV" \
				git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		! test_trace2_data fsm_client \
			settings/inotify-watch-limit-backoff 1 \
			<".git/$2.trace" &&
		test_grep ! \
			"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
			".git/$2.trace"
	)
}

test_expect_success PIPE,PERL_TEST_HELPERS \
	'a FIFO watch-limit marker never blocks ordinary status' '
	setup_backoff_marker_fixture marker-fifo &&
	marker=marker-fifo/.git/fsmonitor--daemon.inotify-limit &&
	mkfifo "$marker" &&
	test_when_finished "rm -f $marker" &&
	check_rejected_backoff_marker marker-fifo fifo &&
	test -p "$marker"
'

test_expect_success PERL_TEST_HELPERS \
	'an oversized watch-limit marker cannot disable fsmonitor' '
	setup_backoff_marker_fixture marker-oversized &&
	marker=marker-oversized/.git/fsmonitor--daemon.inotify-limit &&
	printf "%0257d\\n" 0 >"$marker" &&
	chmod 600 "$marker" &&
	test "$(wc -c <"$marker")" -gt 256 &&
	check_rejected_backoff_marker marker-oversized oversized &&
	test_path_is_file "$marker"
'

test_expect_success PERL_TEST_HELPERS \
	'a malformed watch-limit marker cannot disable fsmonitor' '
	setup_backoff_marker_fixture marker-malformed &&
	marker=marker-malformed/.git/fsmonitor--daemon.inotify-limit &&
	printf "inotify-limit-v1\\ninvalid-identity\\nnot-a-limit\\n" \
		>"$marker" &&
	chmod 600 "$marker" &&
	check_rejected_backoff_marker marker-malformed malformed &&
	test_path_is_file "$marker"
'

test_done
