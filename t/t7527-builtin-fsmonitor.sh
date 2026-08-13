#!/bin/sh

test_description='built-in file system watcher'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-semantic-verify.sh

if ! test_have_prereq FSMONITOR_DAEMON
then
	skip_all="fsmonitor--daemon is not supported on this platform"
	test_done
fi

# Verify that the filesystem delivers events to the daemon.
# On some configurations (e.g., overlayfs with older kernels),
# inotify watches succeed but events are never delivered.  The
# cookie wait will time out and the daemon logs a trace message.
#
# Use "timeout" (if available) to guard each step against hangs.
maybe_timeout () {
	if type timeout >/dev/null 2>&1
	then
		timeout "$@"
	else
		shift
		"$@"
	fi
}

test_lazy_prereq FSMONITOR_WORKS '
	git init test_fsmonitor_smoke || return 1

	GIT_TRACE_FSMONITOR="$PWD/smoke.trace" &&
	export GIT_TRACE_FSMONITOR &&
	maybe_timeout 30 \
		git -C test_fsmonitor_smoke fsmonitor--daemon start \
			--start-timeout=10
	ret=$?
	unset GIT_TRACE_FSMONITOR
	if test $ret -ne 0
	then
		rm -rf test_fsmonitor_smoke smoke.trace
		return 1
	fi

	maybe_timeout 10 \
		test-tool -C test_fsmonitor_smoke fsmonitor-client query \
			--token 0 >/dev/null 2>&1
	maybe_timeout 5 \
		git -C test_fsmonitor_smoke fsmonitor--daemon stop 2>/dev/null
	! grep -q "cookie_wait timed out" "$PWD/smoke.trace" 2>/dev/null
	ret=$?
	rm -rf test_fsmonitor_smoke smoke.trace
	return $ret
'

test_lazy_prereq HARDLINKS '
	: >hardlink-a &&
	ln hardlink-a hardlink-b
'

test_lazy_prereq FOREIGN_FSMONITOR_GIT '
	test -x /opt/homebrew/bin/git &&
	/opt/homebrew/bin/git version
'

test_lazy_prereq LEGACY_PREVIEW_FSMONITOR_GIT '
	test -x /opt/homebrew/Cellar/og-preview/2026-08-11T2321Z/libexec/openai-git/bin/git
'

if ! test_have_prereq FSMONITOR_WORKS
then
	skip_all="filesystem does not deliver fsmonitor events (container/overlayfs?)"
	test_done
fi

stop_daemon_delete_repo () {
	r=$1 &&
	{ maybe_timeout 30 git -C $r fsmonitor--daemon stop 2>/dev/null || :; } &&
	rm -rf $1
}

start_daemon () {
	r= tf= t2= tk= &&

	while test "$#" -ne 0
	do
		case "$1" in
		-C)
			r="-C ${2?}"
			shift
			;;
		--tf)
			tf="${2?}"
			shift
			;;
		--t2)
			t2="${2?}"
			shift
			;;
		--tk)
			tk="${2?}"
			shift
			;;
		-*)
			BUG "error: unknown option: '$1'"
			;;
		*)
			BUG "error: unbound argument: '$1'"
			;;
		esac
		shift
	done &&

	(
		if test -n "$tf"
		then
			GIT_TRACE_FSMONITOR="$tf"
			export GIT_TRACE_FSMONITOR
		fi &&

		if test -n "$t2"
		then
			GIT_TRACE2_PERF="$t2"
			export GIT_TRACE2_PERF
		fi &&

		if test -n "$tk"
		then
			GIT_TEST_FSMONITOR_TOKEN="$tk"
			export GIT_TEST_FSMONITOR_TOKEN
		fi &&

		git $r fsmonitor--daemon start --start-timeout=10 &&
		git $r fsmonitor--daemon status
	)
}

# Is a Trace2 data event present with the given catetory and key?
# We do not care what the value is.
#
have_t2_data_event () {
	c=$1 &&
	k=$2 &&

	grep -e '"event":"data".*"category":"'"$c"'".*"key":"'"$k"'"'
}

test_expect_success 'explicit daemon start and stop' '
	test_when_finished "stop_daemon_delete_repo test_explicit" &&

	git init test_explicit &&
	start_daemon -C test_explicit &&

	git -C test_explicit fsmonitor--daemon stop &&
	test_must_fail git -C test_explicit fsmonitor--daemon status
'

test_expect_success 'implicit daemon start' '
	test_when_finished "stop_daemon_delete_repo test_implicit" &&

	git init test_implicit &&
	test_must_fail git -C test_implicit fsmonitor--daemon status &&

	# query will implicitly start the daemon.
	#
	# for test-script simplicity, we send a V1 timestamp rather than
	# a V2 token.  either way, the daemon response to any query contains
	# a new V2 token.  (the daemon may complain that we sent a V1 request,
	# but this test case is only concerned with whether the daemon was
	# implicitly started.)

	GIT_TRACE2_EVENT="$PWD/.git/trace" \
		test-tool -C test_implicit fsmonitor-client query --token 0 >actual &&
	nul_to_q <actual >actual.filtered &&
	test_grep "builtin:" actual.filtered &&

	# confirm that a daemon was started in the background.
	#
	# since the mechanism for starting the background daemon is platform
	# dependent, just confirm that the foreground command received a
	# response from the daemon.

	have_t2_data_event fsm_client query/response-length <.git/trace &&

	git -C test_implicit fsmonitor--daemon status &&
	git -C test_implicit fsmonitor--daemon stop &&
	test_must_fail git -C test_implicit fsmonitor--daemon status
'

# Verify that the daemon has shutdown.  Spin a few seconds to
# make the test a little more robust during CI testing.
#
# We're looking for an implicit shutdown, such as when we delete or
# rename the ".git" directory.  Our delete/rename will cause a file
# system event that the daemon will see and the daemon will
# auto-shutdown as soon as it sees it.  But this is racy with our `git
# fsmonitor--daemon status` commands (and we cannot use a cookie file
# here to help us).  So spin a little and give the daemon a chance to
# see the event.  (This is primarily for underpowered CI build/test
# machines (where it might take a moment to wake and reschedule the
# daemon process) to avoid false alarms during test runs.)
#
IMPLICIT_TIMEOUT=5

verify_implicit_shutdown () {
	r=$1 &&

	k=0 &&
	while test "$k" -lt $IMPLICIT_TIMEOUT
	do
		git -C $r fsmonitor--daemon status || return 0

		sleep 1
		k=$(( $k + 1 ))
	done &&

	return 1
}

test_expect_success 'implicit daemon stop (delete .git)' '
	test_when_finished "stop_daemon_delete_repo test_implicit_1" &&

	git init test_implicit_1 &&

	start_daemon -C test_implicit_1 &&

	# deleting the .git directory will implicitly stop the daemon.
	rm -rf test_implicit_1/.git &&

	# [1] Create an empty .git directory so that the following Git
	#     command will stay relative to the `-C` directory.
	#
	#     Without this, the Git command will override the requested
	#     -C argument and crawl out to the containing Git source tree.
	#     This would make the test result dependent upon whether we
	#     were using fsmonitor on our development worktree.
	#
	mkdir test_implicit_1/.git &&

	verify_implicit_shutdown test_implicit_1
'

test_expect_success 'implicit daemon stop (rename .git)' '
	test_when_finished "stop_daemon_delete_repo test_implicit_2" &&

	git init test_implicit_2 &&

	start_daemon -C test_implicit_2 &&

	# renaming the .git directory will implicitly stop the daemon.
	mv test_implicit_2/.git test_implicit_2/.xxx &&

	# See [1] above.
	#
	mkdir test_implicit_2/.git &&

	verify_implicit_shutdown test_implicit_2
'

# File systems on Windows may or may not have shortnames.
# This is a volume-specific setting on modern systems.
# "C:/" drives are required to have them enabled.  Other
# hard drives default to disabled.
#
# This is a crude test to see if shortnames are enabled
# on the volume containing the test directory.  It is
# crude, but it does not require elevation like `fsutil`.
#
test_lazy_prereq SHORTNAMES '
	mkdir .foo &&
	test -d "FOO~1"
'

# Here we assume that the shortname of ".git" is "GIT~1".
test_expect_success MINGW,SHORTNAMES 'implicit daemon stop (rename GIT~1)' '
	test_when_finished "stop_daemon_delete_repo test_implicit_1s" &&

	git init test_implicit_1s &&

	start_daemon -C test_implicit_1s &&

	# renaming the .git directory will implicitly stop the daemon.
	# this moves {.git, GIT~1} to {.gitxyz, GITXYZ~1}.
	# the rename-from FS Event will contain the shortname.
	#
	mv test_implicit_1s/GIT~1 test_implicit_1s/.gitxyz &&

	# See [1] above.
	# this moves {.gitxyz, GITXYZ~1} to {.git, GIT~1}.
	mv test_implicit_1s/.gitxyz test_implicit_1s/.git &&

	verify_implicit_shutdown test_implicit_1s
'

# Here we first create a file with LONGNAME of "GIT~1" before
# we create the repo.  This will cause the shortname of ".git"
# to be "GIT~2".
test_expect_success MINGW,SHORTNAMES 'implicit daemon stop (rename GIT~2)' '
	test_when_finished "stop_daemon_delete_repo test_implicit_1s2" &&

	mkdir test_implicit_1s2 &&
	echo HELLO >test_implicit_1s2/GIT~1 &&
	git init test_implicit_1s2 &&

	test_path_is_file test_implicit_1s2/GIT~1 &&
	test_path_is_dir  test_implicit_1s2/GIT~2 &&

	start_daemon -C test_implicit_1s2 &&

	# renaming the .git directory will implicitly stop the daemon.
	# the rename-from FS Event will contain the shortname.
	#
	mv test_implicit_1s2/GIT~2 test_implicit_1s2/.gitxyz &&

	# See [1] above.
	mv test_implicit_1s2/.gitxyz test_implicit_1s2/.git &&

	verify_implicit_shutdown test_implicit_1s2
'

test_expect_success 'cannot start multiple daemons' '
	test_when_finished "stop_daemon_delete_repo test_multiple" &&

	git init test_multiple &&

	start_daemon -C test_multiple &&

	test_must_fail git -C test_multiple fsmonitor--daemon start 2>actual &&
	test_grep "fsmonitor--daemon is already running" actual &&

	git -C test_multiple fsmonitor--daemon stop &&
	test_must_fail git -C test_multiple fsmonitor--daemon status
'

# These tests use the main repo in the trash directory

test_expect_success 'setup' '
	>tracked &&
	>modified &&
	>delete &&
	>rename &&
	mkdir dir1 &&
	>dir1/tracked &&
	>dir1/modified &&
	>dir1/delete &&
	>dir1/rename &&
	mkdir dir2 &&
	>dir2/tracked &&
	>dir2/modified &&
	>dir2/delete &&
	>dir2/rename &&
	mkdir dirtorename &&
	>dirtorename/a &&
	>dirtorename/b &&

	cat >.gitignore <<-\EOF &&
	.gitignore
	expect*
	actual*
	flush*
	trace*
	EOF

	mkdir -p T1/T2/T3/T4 &&
	echo 1 >T1/F1 &&
	echo 1 >T1/T2/F1 &&
	echo 1 >T1/T2/T3/F1 &&
	echo 1 >T1/T2/T3/T4/F1 &&
	echo 2 >T1/F2 &&
	echo 2 >T1/T2/F2 &&
	echo 2 >T1/T2/T3/F2 &&
	echo 2 >T1/T2/T3/T4/F2 &&

	git -c core.fsmonitor=false add . &&
	test_tick &&
	git -c core.fsmonitor=false commit -m initial &&

	git config core.fsmonitor true
'

# The test already explicitly stopped (or tried to stop) the daemon.
# This is here in case something else fails first.
#
redundant_stop_daemon () {
	test_might_fail git fsmonitor--daemon stop
}

test_expect_success 'update-index implicitly starts daemon' '
	test_when_finished redundant_stop_daemon &&

	test_must_fail git fsmonitor--daemon status &&

	GIT_TRACE2_EVENT="$PWD/.git/trace_implicit_1" \
		git update-index --fsmonitor &&

	git fsmonitor--daemon status &&
	test_might_fail git fsmonitor--daemon stop &&

	# Confirm that the trace2 log contains a record of the
	# daemon starting.
	test_grep "\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
		.git/trace_implicit_1
'

test_expect_success 'status implicitly starts daemon' '
	test_when_finished redundant_stop_daemon &&

	test_must_fail git fsmonitor--daemon status &&

	GIT_TRACE2_EVENT="$PWD/.git/trace_implicit_2" \
		git status >actual &&

	git fsmonitor--daemon status &&
	test_might_fail git fsmonitor--daemon stop &&

	# Confirm that the trace2 log contains a record of the
	# daemon starting.
	test_grep "\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
		.git/trace_implicit_2
'

edit_files () {
	echo 1 >modified &&
	echo 2 >dir1/modified &&
	echo 3 >dir2/modified &&
	>dir1/untracked
}

delete_files () {
	rm -f delete &&
	rm -f dir1/delete &&
	rm -f dir2/delete
}

create_files () {
	echo 1 >new &&
	echo 2 >dir1/new &&
	echo 3 >dir2/new
}

rename_files () {
	mv rename renamed &&
	mv dir1/rename dir1/renamed &&
	mv dir2/rename dir2/renamed
}

file_to_directory () {
	rm -f delete &&
	mkdir delete &&
	echo 1 >delete/new
}

directory_to_file () {
	rm -rf dir1 &&
	echo 1 >dir1
}

move_directory_contents_deeper() {
	mkdir T1/_new_ &&
	mv T1/[A-Z]* T1/_new_
}

move_directory_up() {
	mv T1/T2/T3 T1
}

move_directory() {
	mv T1/T2/T3 T1/T2/NewT3
}

# The next few test cases confirm that our fsmonitor daemon sees each type
# of OS filesystem notification that we care about.  At this layer we just
# ensure we are getting the OS notifications and do not try to confirm what
# is reported by `git status`.
#
# We use retry_grep to handle races between the daemon writing events
# to the trace file and our check.
#
# We `reset` and `clean` at the bottom of each test (and before stopping the
# daemon) because these commands might implicitly restart the daemon.

clean_up_repo_and_stop_daemon () {
	git reset --hard HEAD &&
	git clean -fd &&
	test_might_fail git fsmonitor--daemon stop &&
	rm -f .git/trace
}

# Retry a grep up to RETRY_TIMEOUT times until it succeeds.
#
RETRY_TIMEOUT=5

retry_grep () {
	nr_tries_left=$RETRY_TIMEOUT
	until grep "$1" "$2" 2>/dev/null
	do
		if test $nr_tries_left -eq 0
		then
			grep "$1" "$2"
			return
		fi
		nr_tries_left=$(($nr_tries_left - 1))
		sleep 1
	done
}

test_expect_success 'edit some files' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	edit_files &&

	retry_grep "^event: dir1/modified$" .git/trace &&
	retry_grep "^event: dir2/modified$"  .git/trace &&
	retry_grep "^event: modified$"       .git/trace &&
	retry_grep "^event: dir1/untracked$" .git/trace
'

test_expect_success 'create some files' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	create_files &&

	retry_grep "^event: dir1/new$" .git/trace &&
	retry_grep "^event: dir2/new$" .git/trace &&
	retry_grep "^event: new$"      .git/trace
'

test_expect_success 'delete some files' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	delete_files &&

	retry_grep "^event: dir1/delete$" .git/trace &&
	retry_grep "^event: dir2/delete$" .git/trace &&
	retry_grep "^event: delete$"      .git/trace
'

test_expect_success 'rename some files' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	rename_files &&

	retry_grep "^event: dir1/rename$" .git/trace &&
	retry_grep "^event: dir2/rename$"  .git/trace &&
	retry_grep "^event: rename$"       .git/trace &&
	retry_grep "^event: dir1/renamed$" .git/trace &&
	retry_grep "^event: dir2/renamed$" .git/trace &&
	retry_grep "^event: renamed$"      .git/trace
'

test_expect_success 'rename directory' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	mv dirtorename dirrenamed &&

	retry_grep "^event: dirtorename/*$" .git/trace &&
	retry_grep "^event: dirrenamed/*$"  .git/trace
'

test_expect_success 'file changes to directory' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	file_to_directory &&

	retry_grep "^event: delete$" .git/trace &&
	retry_grep "^event: delete/new$" .git/trace
'

test_expect_success 'directory changes to a file' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	directory_to_file &&

	retry_grep "^event: dir1$" .git/trace
'

test_expect_success 'rapid nested directory creation' '
	test_when_finished "git fsmonitor--daemon stop; rm -rf rapid" &&

	start_daemon --tf "$PWD/.git/trace" &&

	# Rapidly create nested directories to exercise race conditions
	# where directory watches may be added concurrently during
	# event processing and recursive scanning.
	for i in $(test_seq 1 20)
	do
		mkdir -p "rapid/nested/dir$i/subdir/deep" || return 1
	done &&

	# Give the daemon time to process all events
	sleep 1 &&

	test-tool fsmonitor-client query --token 0 &&

	# Verify daemon is still running (did not crash)
	git fsmonitor--daemon status
'

# The next few test cases exercise the token-resync code.  When filesystem
# drops events (because of filesystem velocity or because the daemon isn't
# polling fast enough), we need to discard the cached data (relative to the
# current token) and start collecting events under a new token.
#
# the 'test-tool fsmonitor-client flush' command can be used to send a
# "flush" message to a running daemon and ask it to do a flush/resync.

test_expect_success 'flush cached data' '
	test_when_finished "stop_daemon_delete_repo test_flush" &&

	git init test_flush &&

	start_daemon -C test_flush --tf "$PWD/.git/trace_daemon" --tk true &&

	# The daemon should have an initial token with no events in _0 and
	# then a few (probably platform-specific number of) events in _1.
	# These should both have the same <token_id>.

	test-tool -C test_flush fsmonitor-client query --token "builtin:test_00000001:0" >actual_0 &&
	nul_to_q <actual_0 >actual_q0 &&

	>test_flush/file_1 &&
	>test_flush/file_2 &&

	test-tool -C test_flush fsmonitor-client query --token "builtin:test_00000001:0" >actual_1 &&
	nul_to_q <actual_1 >actual_q1 &&

	test_grep "file_1" actual_q1 &&

	# Force a flush.  This will change the <token_id>, reset the <seq_nr>, and
	# flush the file data.  Then create some events and ensure that the file
	# again appears in the cache.  It should have the new <token_id>.

	test-tool -C test_flush fsmonitor-client flush >flush_0 &&
	nul_to_q <flush_0 >flush_q0 &&
	test_grep "^builtin:test_00000002:0Q/Q$" flush_q0 &&

	test-tool -C test_flush fsmonitor-client query --token "builtin:test_00000002:0" >actual_2 &&
	nul_to_q <actual_2 >actual_q2 &&

	test_grep "^builtin:test_00000002:0Q$" actual_q2 &&

	>test_flush/file_3 &&

	test-tool -C test_flush fsmonitor-client query --token "builtin:test_00000002:0" >actual_3 &&
	nul_to_q <actual_3 >actual_q3 &&

	test_grep "file_3" actual_q3
'

# The next few test cases create repos where the .git directory is NOT
# inside the one of the working directory.  That is, where .git is a file
# that points to a directory elsewhere.  This happens for submodules and
# non-primary worktrees.

test_expect_success 'setup worktree base' '
	git init wt-base &&
	echo 1 >wt-base/file1 &&
	git -C wt-base add file1 &&
	git -C wt-base commit -m "c1"
'

test_expect_success 'worktree with .git file' '
	git -C wt-base worktree add ../wt-secondary &&

	start_daemon -C wt-secondary \
		--tf "$PWD/trace_wt_secondary" \
		--t2 "$PWD/trace2_wt_secondary" &&

	git -C wt-secondary fsmonitor--daemon stop &&
	test_must_fail git -C wt-secondary fsmonitor--daemon status
'

# NEEDSWORK: Repeat one of the "edit" tests on wt-secondary and
# confirm that we get the same events and behavior -- that is, that
# fsmonitor--daemon correctly watches BOTH the working directory and
# the external GITDIR directory and behaves the same as when ".git"
# is a directory inside the working directory.

test_expect_success 'cleanup worktrees' '
	stop_daemon_delete_repo wt-secondary &&
	stop_daemon_delete_repo wt-base
'

# The next few tests perform arbitrary/contrived file operations and
# confirm that status is correct.  That is, that the data (or lack of
# data) from fsmonitor doesn't cause incorrect results.  And doesn't
# cause incorrect results when the untracked-cache is enabled.

test_lazy_prereq UNTRACKED_CACHE '
	git update-index --test-untracked-cache
'

test_expect_success 'Matrix: setup for untracked-cache,fsmonitor matrix' '
	test_unconfig core.fsmonitor &&
	git update-index --no-fsmonitor &&
	test_might_fail git fsmonitor--daemon stop
'

matrix_clean_up_repo () {
	git reset --hard HEAD &&
	git clean -fd
}

matrix_try () {
	uc=$1 &&
	fsm=$2 &&
	fn=$3 &&

	if test $uc = true && test $fsm = false
	then
		# The untracked-cache is buggy when FSMonitor is
		# DISABLED, so skip the tests for this matrix
		# combination.
		#
		# We've observed random, occasional test failures on
		# Windows and MacOS when the UC is turned on and FSM
		# is turned off.  These are rare, but they do happen
		# indicating that it is probably a race condition within
		# the untracked cache itself.
		#
		# It usually happens when a test does F/D trickery and
		# then the NEXT test fails because of extra status
		# output from stale UC data from the previous test.
		#
		# Since FSMonitor is not involved in the error, skip
		# the tests for this matrix combination.
		#
		return 0
	fi &&

	test_expect_success "Matrix[uc:$uc][fsm:$fsm] $fn" '
		matrix_clean_up_repo &&
		$fn &&
		if test $uc = false && test $fsm = false
		then
			git status --porcelain=v1 >.git/expect.$fn
		else
			git status --porcelain=v1 >.git/actual.$fn &&
			test_cmp .git/expect.$fn .git/actual.$fn
		fi
	'
}

uc_values="false"
test_have_prereq UNTRACKED_CACHE && uc_values="false true"
for uc_val in $uc_values
do
	if test $uc_val = false
	then
		test_expect_success "Matrix[uc:$uc_val] disable untracked cache" '
			git config core.untrackedcache false &&
			git update-index --no-untracked-cache
		'
	else
		test_expect_success "Matrix[uc:$uc_val] enable untracked cache" '
			git config core.untrackedcache true &&
			git update-index --untracked-cache
		'
	fi

	fsm_values="false true"
	for fsm_val in $fsm_values
	do
		if test $fsm_val = false
		then
			test_expect_success "Matrix[uc:$uc_val][fsm:$fsm_val] disable fsmonitor" '
				test_unconfig core.fsmonitor &&
				git update-index --no-fsmonitor &&
				test_might_fail git fsmonitor--daemon stop
			'
		else
			test_expect_success "Matrix[uc:$uc_val][fsm:$fsm_val] enable fsmonitor" '
				git config core.fsmonitor true &&
				git fsmonitor--daemon start &&
				git update-index --fsmonitor
			'
		fi

		matrix_try $uc_val $fsm_val edit_files
		matrix_try $uc_val $fsm_val delete_files
		matrix_try $uc_val $fsm_val create_files
		matrix_try $uc_val $fsm_val rename_files
		matrix_try $uc_val $fsm_val file_to_directory
		matrix_try $uc_val $fsm_val directory_to_file

		matrix_try $uc_val $fsm_val move_directory_contents_deeper
		matrix_try $uc_val $fsm_val move_directory_up
		matrix_try $uc_val $fsm_val move_directory

		if test $fsm_val = true
		then
			test_expect_success "Matrix[uc:$uc_val][fsm:$fsm_val] disable fsmonitor at end" '
				test_unconfig core.fsmonitor &&
				git update-index --no-fsmonitor &&
				test_might_fail git fsmonitor--daemon stop
			'
		fi
	done
done

# Test Unicode UTF-8 characters in the pathname of the working
# directory root.  Use of "*A()" routines rather than "*W()" routines
# on Windows can sometimes lead to odd failures.
#
u1=$(printf "u_c3_a6__\xC3\xA6")
u2=$(printf "u_e2_99_ab__\xE2\x99\xAB")
u_values="$u1 $u2"
for u in $u_values
do
	test_expect_success "unicode in repo root path: $u" '
		test_when_finished "stop_daemon_delete_repo $u" &&

		git init "$u" &&
		echo 1 >"$u"/file1 &&
		git -C "$u" add file1 &&
		git -C "$u" config core.fsmonitor true &&

		start_daemon -C "$u" &&
		git -C "$u" status >actual &&
		test_grep "new file:   file1" actual
	'
done

# Test fsmonitor interaction with submodules.
#
# If we start the daemon in the super, it will see FS events for
# everything in the working directory cone and this includes any
# files/directories contained *within* the submodules.
#
# A `git status` at top level will get events for items within the
# submodule and ignore them, since they aren't named in the index
# of the super repo.  This makes the fsmonitor response a little
# noisy, but it doesn't alter the correctness of the state of the
# super-proper.
#
# When we have submodules, `git status` normally does a recursive
# status on each of the submodules and adds a summary row for any
# dirty submodules.  (See the "S..." bits in porcelain V2 output.)
#
# It is therefore important that the top level status not be tricked
# by the FSMonitor response to skip those recursive calls.  That is,
# even if FSMonitor says that the mtime of the submodule directory
# hasn't changed and it could be implicitly marked valid, we must
# not take that shortcut.  We need to force the recursion into the
# submodule so that we get a summary of the status *within* the
# submodule.

create_super () {
	super="$1" &&

	git init "$super" &&
	echo x >"$super/file_1" &&
	echo y >"$super/file_2" &&
	echo z >"$super/file_3" &&
	mkdir "$super/dir_1" &&
	echo a >"$super/dir_1/file_11" &&
	echo b >"$super/dir_1/file_12" &&
	mkdir "$super/dir_1/dir_2" &&
	echo a >"$super/dir_1/dir_2/file_21" &&
	echo b >"$super/dir_1/dir_2/file_22" &&
	git -C "$super" add . &&
	git -C "$super" commit -m "initial $super commit"
}

create_sub () {
	sub="$1" &&

	git init "$sub" &&
	echo x >"$sub/file_x" &&
	echo y >"$sub/file_y" &&
	echo z >"$sub/file_z" &&
	mkdir "$sub/dir_x" &&
	echo a >"$sub/dir_x/file_a" &&
	echo b >"$sub/dir_x/file_b" &&
	mkdir "$sub/dir_x/dir_y" &&
	echo a >"$sub/dir_x/dir_y/file_a" &&
	echo b >"$sub/dir_x/dir_y/file_b" &&
	git -C "$sub" add . &&
	git -C "$sub" commit -m "initial $sub commit"
}

my_match_and_clean () {
	git -C super --no-optional-locks status --porcelain=v2 >actual.with &&
	git -C super --no-optional-locks -c core.fsmonitor=false \
		status --porcelain=v2 >actual.without &&
	test_cmp actual.with actual.without &&

	git -C super --no-optional-locks diff-index --name-status HEAD >actual.with &&
	git -C super --no-optional-locks -c core.fsmonitor=false \
		diff-index --name-status HEAD >actual.without &&
	test_cmp actual.with actual.without &&

	git -C super/dir_1/dir_2/sub reset --hard &&
	git -C super/dir_1/dir_2/sub clean -d -f
}

test_expect_success 'submodule setup' '
	git config --global protocol.file.allow always
'

test_expect_success 'submodule always visited' '
	test_when_finished "git -C super fsmonitor--daemon stop; \
			    rm -rf super; \
			    rm -rf sub" &&

	create_super super &&
	create_sub sub &&

	git -C super submodule add ../sub ./dir_1/dir_2/sub &&
	git -C super commit -m "add sub" &&

	start_daemon -C super &&
	git -C super config core.fsmonitor true &&
	git -C super update-index --fsmonitor &&
	git -C super status &&

	# Now run pairs of commands w/ and w/o FSMonitor while we make
	# some dirt in the submodule and confirm matching output.

	# Completely clean status.
	my_match_and_clean &&

	# .M S..U
	echo z >super/dir_1/dir_2/sub/dir_x/dir_y/foobar_u &&
	my_match_and_clean &&

	# .M S.M.
	echo z >super/dir_1/dir_2/sub/dir_x/dir_y/foobar_m &&
	git -C super/dir_1/dir_2/sub add . &&
	my_match_and_clean &&

	# .M S.M.
	echo z >>super/dir_1/dir_2/sub/dir_x/dir_y/file_a &&
	git -C super/dir_1/dir_2/sub add . &&
	my_match_and_clean &&

	# .M SC..
	echo z >>super/dir_1/dir_2/sub/dir_x/dir_y/file_a &&
	git -C super/dir_1/dir_2/sub add . &&
	git -C super/dir_1/dir_2/sub commit -m "SC.." &&
	my_match_and_clean
'

# If a submodule has a `sub/.git/` directory (rather than a file
# pointing to the super's `.git/modules/sub`) and `core.fsmonitor`
# turned on in the submodule and the daemon is not yet started in
# the submodule, and someone does a `git submodule absorbgitdirs`
# in the super, Git will recursively invoke `git submodule--helper`
# to do the work and this may try to read the index.  This will
# try to start the daemon in the submodule.

test_expect_success "submodule absorbgitdirs implicitly starts daemon" '
	test_when_finished "rm -rf super; \
			    rm -rf sub;   \
			    rm super-sub.trace" &&

	create_super super &&
	create_sub sub &&

	# Copy rather than submodule add so that we get a .git dir.
	cp -R ./sub ./super/dir_1/dir_2/sub &&

	git -C super/dir_1/dir_2/sub config core.fsmonitor true &&

	git -C super submodule add ../sub ./dir_1/dir_2/sub &&
	git -C super commit -m "add sub" &&

	test_path_is_dir super/dir_1/dir_2/sub/.git &&

	cwd="$(cd super && pwd)" &&
	cat >expect <<-EOF &&
	Migrating git directory of '\''dir_1/dir_2/sub'\'' from
	'\''$cwd/dir_1/dir_2/sub/.git'\'' to
	'\''$cwd/.git/modules/dir_1/dir_2/sub'\''
	EOF
	GIT_TRACE2_EVENT="$PWD/super-sub.trace" \
		git -C super submodule absorbgitdirs >out 2>actual &&
	test_cmp expect actual &&
	test_must_be_empty out &&

	# Confirm that the trace2 log contains a record of the
	# daemon starting.
	test_grep "\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
		super-sub.trace
'

start_git_in_background () {
	git "$@" &
	git_pid=$!
	git_pgid=$(ps -o pgid= -p $git_pid 2>/dev/null ||
		awk '{print $5}' /proc/$git_pid/stat 2>/dev/null) &&
	git_pgid="${git_pgid## }" &&
	git_pgid="${git_pgid%% }"
	nr_tries_left=10
	while true
	do
		if test $nr_tries_left -eq 0
		then
			kill -- -$git_pgid
			exit 1
		fi
		sleep 1
		nr_tries_left=$(($nr_tries_left - 1))
	done >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- &
	watchdog_pid=$!
	wait $git_pid
}

stop_git () {
	test -n "$git_pgid" || return 0
	while kill -0 -- -$git_pgid 2>/dev/null
	do
		kill -- -$git_pgid 2>/dev/null
		sleep 1
	done
}

stop_watchdog () {
	while test -n "$watchdog_pid" &&
		kill -0 "$watchdog_pid" 2>/dev/null
	do
		kill "$watchdog_pid" 2>/dev/null
		sleep 1
	done
	watchdog_pid=
}

test_expect_success !MINGW "submodule implicitly starts daemon by pull" '
	test_atexit "stop_watchdog" &&
	test_when_finished "stop_watchdog; set +m; stop_git; rm -rf cloned super sub" &&

	create_super super &&
	create_sub sub &&

	git -C super submodule add ../sub ./dir_1/dir_2/sub &&
	git -C super commit -m "add sub" &&
	git clone --recurse-submodules super cloned &&

	git -C cloned/dir_1/dir_2/sub config core.fsmonitor true &&
	set -m &&
	start_git_in_background -C cloned pull --recurse-submodules
'

# On a case-insensitive file system, confirm that the daemon
# notices when the .git directory is moved/renamed/deleted
# regardless of how it is spelled in the FS event.
# That is, does the FS event receive the spelling of the
# operation or does it receive the spelling preserved with
# the file/directory.
#
test_expect_success CASE_INSENSITIVE_FS 'case insensitive+preserving' '
	test_when_finished "stop_daemon_delete_repo test_insensitive" &&

	git init test_insensitive &&

	start_daemon -C test_insensitive --tf "$PWD/insensitive.trace" &&

	mkdir -p test_insensitive/abc/def &&
	echo xyz >test_insensitive/ABC/DEF/xyz &&

	test_path_is_dir test_insensitive/.git &&
	test_path_is_dir test_insensitive/.GIT &&

	# Rename .git using an alternate spelling to verify that
	# the daemon detects it and automatically shuts down.
	mv test_insensitive/.GIT test_insensitive/.FOO &&

	# See [1] above.
	mv test_insensitive/.FOO test_insensitive/.git &&

	verify_implicit_shutdown test_insensitive &&

	# Verify that events were reported using on-disk spellings of the
	# directories and files that we touched.  We may or may not get a
	# trailing slash on modified directories.
	#
	test_grep -E "^event: abc/?$"       ./insensitive.trace &&
	test_grep -E "^event: abc/def/?$"   ./insensitive.trace &&
	test_grep -E "^event: abc/def/xyz$" ./insensitive.trace
'

# The variable "unicode_debug" is defined in the following library
# script to dump information about how the (OS, FS) handles Unicode
# composition.  Uncomment the following line if you want to enable it.
#
# unicode_debug=true

. "$TEST_DIRECTORY/lib-unicode-nfc-nfd.sh"

# See if the OS or filesystem does NFC/NFD aliasing/munging.
#
# The daemon should err on the side of caution and send BOTH the
# NFC and NFD forms.  It does not know the original spelling of
# the pathname (how the user thinks it should be spelled), so
# emit both and let the client decide (when necessary).  This is
# similar to "core.precomposeUnicode".
#
test_expect_success !UNICODE_COMPOSITION_SENSITIVE 'Unicode nfc/nfd' '
	test_when_finished "stop_daemon_delete_repo test_unicode" &&

	git init test_unicode &&

	start_daemon -C test_unicode --tf "$PWD/unicode.trace" &&

	# Create a directory using an NFC spelling.
	#
	mkdir test_unicode/nfc &&
	mkdir test_unicode/nfc/c_${utf8_nfc} &&

	# Create a directory using an NFD spelling.
	#
	mkdir test_unicode/nfd &&
	mkdir test_unicode/nfd/d_${utf8_nfd} &&

	test-tool -C test_unicode fsmonitor-client query --token 0 &&

	if test_have_prereq UNICODE_NFC_PRESERVED
	then
		# We should have seen NFC event from OS.
		# We should not have synthesized an NFD event.
		test_grep -E    "^event: nfc/c_${utf8_nfc}/?$" ./unicode.trace &&
		test_grep -E -v "^event: nfc/c_${utf8_nfd}/?$" ./unicode.trace
	else
		# We should have seen NFD event from OS.
		# We should have synthesized an NFC event.
		test_grep -E "^event: nfc/c_${utf8_nfd}/?$" ./unicode.trace &&
		test_grep -E "^event: nfc/c_${utf8_nfc}/?$" ./unicode.trace
	fi &&

	# We assume UNICODE_NFD_PRESERVED.
	# We should have seen explicit NFD from OS.
	# We should have synthesized an NFC event.
	test_grep -E "^event: nfd/d_${utf8_nfd}/?$" ./unicode.trace &&
	test_grep -E "^event: nfd/d_${utf8_nfc}/?$" ./unicode.trace
'

test_expect_success 'split-index and FSMonitor work well together' '
	git init split-index &&
	test_when_finished "git -C \"$PWD/split-index\" \
		fsmonitor--daemon stop" &&
	(
		cd split-index &&
		git config core.splitIndex true &&
		# force split-index in most cases
		git config splitIndex.maxPercentChange 99 &&
		git config core.fsmonitor true &&

		# Create the following commit topology:
		#
		# *   merge three
		# |\
		# | * three
		# * | merge two
		# |\|
		# | * two
		# * | one
		# |/
		# * 5a5efd7 initial

		test_commit initial &&
		test_commit two &&
		test_commit three &&
		git reset --hard initial &&
		test_commit one &&
		test_tick &&
		git merge two &&
		test_tick &&
		git merge three &&

		git rebase --force-rebase -r one
	)
'

# The FSMonitor daemon reports the OBSERVED pathname of modified files
# and thus contains the OBSERVED spelling on case-insensitive file
# systems.  The daemon does not (and should not) load the .git/index
# file and therefore does not know the expected case-spelling.  Since
# it is possible for the user to create files/subdirectories with the
# incorrect case, a modified file event for a tracked will not have
# the EXPECTED case. This can cause `index_name_pos()` to incorrectly
# report that the file is untracked. This causes the client to fail to
# mark the file as possibly dirty (keeping the CE_FSMONITOR_VALID bit
# set) so that `git status` will avoid inspecting it and thus not
# present in the status output.
#
# The setup is a little contrived.
#
test_expect_success CASE_INSENSITIVE_FS 'fsmonitor subdir case wrong on disk' '
	test_when_finished "stop_daemon_delete_repo subdir_case_wrong" &&

	git init subdir_case_wrong &&
	(
		cd subdir_case_wrong &&
		echo x >AAA &&
		echo x >BBB &&

		mkdir dir1 &&
		echo x >dir1/file1 &&
		mkdir dir1/dir2 &&
		echo x >dir1/dir2/file2 &&
		mkdir dir1/dir2/dir3 &&
		echo x >dir1/dir2/dir3/file3 &&

		echo x >yyy &&
		echo x >zzz &&
		git add . &&
		git commit -m "data" &&

		# This will cause "dir1/" and everything under it
		# to be deleted.
		git sparse-checkout set --cone --sparse-index &&

		# Create dir2 with the wrong case and then let Git
		# repopulate dir3 -- it will not correct the spelling
		# of dir2.
		mkdir dir1 &&
		mkdir dir1/DIR2 &&
		git sparse-checkout add dir1/dir2/dir3
	) &&

	start_daemon -C subdir_case_wrong --tf "$PWD/subdir_case_wrong.trace" &&

	# Enable FSMonitor in the client. Run enough commands for
	# the .git/index to sync up with the daemon with everything
	# marked clean.
	git -C subdir_case_wrong config core.fsmonitor true &&
	git -C subdir_case_wrong update-index --fsmonitor &&
	git -C subdir_case_wrong status &&

	# Make some files dirty so that FSMonitor gets FSEvents for
	# each of them.
	echo xx >>subdir_case_wrong/AAA &&
	echo xx >>subdir_case_wrong/dir1/DIR2/dir3/file3 &&
	echo xx >>subdir_case_wrong/zzz &&

	GIT_TRACE_FSMONITOR="$PWD/subdir_case_wrong.log" \
		git -C subdir_case_wrong --no-optional-locks status --short \
			>"$PWD/subdir_case_wrong.out" &&

	# "git status" should have gotten file events for each of
	# the 3 files.
	#
	# "dir2" should be in the observed case on disk.
	grep "fsmonitor_refresh_callback" \
		<"$PWD/subdir_case_wrong.log" \
		>"$PWD/subdir_case_wrong.log1" &&

	test_grep -q "AAA.*pos 0" "$PWD/subdir_case_wrong.log1" &&
	test_grep -q "zzz.*pos 6" "$PWD/subdir_case_wrong.log1" &&

	test_grep -q "dir1/DIR2/dir3/file3.*pos -3" "$PWD/subdir_case_wrong.log1" &&

	# Verify that we get a mapping event to correct the case.
	test_grep -q "MAP:.*dir1/DIR2/dir3/file3.*dir1/dir2/dir3/file3" \
		"$PWD/subdir_case_wrong.log1" &&

	# The refresh-callbacks should have caused "git status" to clear
	# the CE_FSMONITOR_VALID bit on each of those files and caused
	# the worktree scan to visit them and mark them as modified.
	test_grep -q " M AAA" "$PWD/subdir_case_wrong.out" &&
	test_grep -q " M zzz" "$PWD/subdir_case_wrong.out" &&
	test_grep -q " M dir1/dir2/dir3/file3" "$PWD/subdir_case_wrong.out"
'

test_expect_success CASE_INSENSITIVE_FS 'fsmonitor file case wrong on disk' '
	test_when_finished "stop_daemon_delete_repo file_case_wrong" &&

	git init file_case_wrong &&
	(
		cd file_case_wrong &&
		echo x >AAA &&
		echo x >BBB &&

		mkdir dir1 &&
		mkdir dir1/dir2 &&
		mkdir dir1/dir2/dir3 &&
		echo x >dir1/dir2/dir3/FILE-3-B &&
		echo x >dir1/dir2/dir3/XXXX-3-X &&
		echo x >dir1/dir2/dir3/file-3-a &&
		echo x >dir1/dir2/dir3/yyyy-3-y &&
		mkdir dir1/dir2/dir4 &&
		echo x >dir1/dir2/dir4/FILE-4-A &&
		echo x >dir1/dir2/dir4/XXXX-4-X &&
		echo x >dir1/dir2/dir4/file-4-b &&
		echo x >dir1/dir2/dir4/yyyy-4-y &&

		echo x >yyy &&
		echo x >zzz &&
		git add . &&
		git commit -m "data"
	) &&

	start_daemon -C file_case_wrong --tf "$PWD/file_case_wrong.trace" &&

	# Enable FSMonitor in the client. Run enough commands for
	# the .git/index to sync up with the daemon with everything
	# marked clean.
	git -C file_case_wrong config core.fsmonitor true &&
	git -C file_case_wrong update-index --fsmonitor &&
	GIT_INDEX_FILE="$PWD/file_case_wrong/.git/index" \
	git -C file_case_wrong status &&

	# Make some files dirty so that FSMonitor gets FSEvents for
	# each of them.
	echo xx >>file_case_wrong/AAA &&
	echo xx >>file_case_wrong/zzz &&

	# Rename some files so that FSMonitor sees a create and delete
	# FSEvent for each.  (A simple "mv foo FOO" is not portable
	# between macOS and Windows. It works on both platforms, but makes
	# the test messy, since (1) one platform updates "ctime" on the
	# moved file and one does not and (2) it causes a directory event
	# on one platform and not on the other which causes additional
	# scanning during "git status" which causes a "H" vs "h" discrepancy
	# in "git ls-files -f".)  So old-school it and move it out of the
	# way and copy it to the case-incorrect name so that we get fresh
	# "ctime" and "mtime" values.

	mv file_case_wrong/dir1/dir2/dir3/file-3-a file_case_wrong/dir1/dir2/dir3/ORIG &&
	cp file_case_wrong/dir1/dir2/dir3/ORIG     file_case_wrong/dir1/dir2/dir3/FILE-3-A &&
	rm file_case_wrong/dir1/dir2/dir3/ORIG &&
	mv file_case_wrong/dir1/dir2/dir4/FILE-4-A file_case_wrong/dir1/dir2/dir4/ORIG &&
	cp file_case_wrong/dir1/dir2/dir4/ORIG     file_case_wrong/dir1/dir2/dir4/file-4-a &&
	rm file_case_wrong/dir1/dir2/dir4/ORIG &&

	# Run status enough times to fully sync.
	#
	# The first instance should get the create and delete FSEvents
	# for each pair.  Status should update the index with a new FSM
	# token (so the next invocation will not see data for these
	# events).

	GIT_INDEX_FILE="$PWD/file_case_wrong/.git/index" \
	GIT_TRACE_FSMONITOR="$PWD/file_case_wrong-try1.log" \
		git -C file_case_wrong status --short \
			>"$PWD/file_case_wrong-try1.out" &&
	test_grep -q "fsmonitor_refresh_callback.*FILE-3-A.*pos -3" "$PWD/file_case_wrong-try1.log" &&
	test_grep -q "fsmonitor_refresh_callback.*file-3-a.*pos 4"  "$PWD/file_case_wrong-try1.log" &&
	test_grep -q "fsmonitor_refresh_callback.*FILE-4-A.*pos 6"  "$PWD/file_case_wrong-try1.log" &&
	test_grep -q "fsmonitor_refresh_callback.*file-4-a.*pos -9" "$PWD/file_case_wrong-try1.log" &&

	# FSM refresh will have invalidated the FSM bit and cause a regular
	# (real) scan of these tracked files, so they should have "H" status.
	# (We will not see a "h" status until the next refresh (on the next
	# command).)

	git -C file_case_wrong ls-files -f >"$PWD/file_case_wrong-lsf1.out" &&
	test_grep -q "H dir1/dir2/dir3/file-3-a" "$PWD/file_case_wrong-lsf1.out" &&
	test_grep -q "H dir1/dir2/dir4/FILE-4-A" "$PWD/file_case_wrong-lsf1.out" &&


	# Try the status again. We assume that the above status command
	# advanced the token so that the next one will not see those events.

	GIT_TRACE_FSMONITOR="$PWD/file_case_wrong-try2.log" \
		git -C file_case_wrong status --short \
			>"$PWD/file_case_wrong-try2.out" &&
	test_grep ! -q "fsmonitor_refresh_callback.*FILE-3-A.*pos" "$PWD/file_case_wrong-try2.log" &&
	test_grep ! -q "fsmonitor_refresh_callback.*file-3-a.*pos" "$PWD/file_case_wrong-try2.log" &&
	test_grep ! -q "fsmonitor_refresh_callback.*FILE-4-A.*pos" "$PWD/file_case_wrong-try2.log" &&
	test_grep ! -q "fsmonitor_refresh_callback.*file-4-a.*pos" "$PWD/file_case_wrong-try2.log" &&

	# A late directory event can invalidate the whole cone. External
	# history can also retain refreshed fsmonitor bits without writing
	# them back into the index, so either marker is valid here.

	git -C file_case_wrong ls-files -f >"$PWD/file_case_wrong-lsf2.out" &&
	test_grep -E -q "^[Hh] dir1/dir2/dir3/file-3-a$" \
		"$PWD/file_case_wrong-lsf2.out" &&
	test_grep -E -q "^[Hh] dir1/dir2/dir4/FILE-4-A$" \
		"$PWD/file_case_wrong-lsf2.out" &&


	# We now have files with clean content, but with case-incorrect
	# file names.  Modify them to see if status properly reports
	# them.

	echo xx >>file_case_wrong/dir1/dir2/dir3/FILE-3-A &&
	echo xx >>file_case_wrong/dir1/dir2/dir4/file-4-a &&

	GIT_TRACE_FSMONITOR="$PWD/file_case_wrong-try3.log" \
		git -C file_case_wrong --no-optional-locks status --short \
			>"$PWD/file_case_wrong-try3.out" &&

	# Verify that we get a mapping event to correct the case.
	test_grep -q "fsmonitor_refresh_callback MAP:.*dir1/dir2/dir3/FILE-3-A.*dir1/dir2/dir3/file-3-a" \
		"$PWD/file_case_wrong-try3.log" &&
	test_grep -q "fsmonitor_refresh_callback MAP:.*dir1/dir2/dir4/file-4-a.*dir1/dir2/dir4/FILE-4-A" \
		"$PWD/file_case_wrong-try3.log" &&

	# FSEvents are in observed case.
	test_grep -q "fsmonitor_refresh_callback.*FILE-3-A.*pos -3" "$PWD/file_case_wrong-try3.log" &&
	test_grep -q "fsmonitor_refresh_callback.*file-4-a.*pos -9" "$PWD/file_case_wrong-try3.log" &&

	# The refresh-callbacks should have caused "git status" to clear
	# the CE_FSMONITOR_VALID bit on each of those files and caused
	# the worktree scan to visit them and mark them as modified.
	test_grep -q " M dir1/dir2/dir3/file-3-a" "$PWD/file_case_wrong-try3.out" &&
	test_grep -q " M dir1/dir2/dir4/FILE-4-A" "$PWD/file_case_wrong-try3.out"
'

test_expect_success MACOS,HARDLINKS 'hardlink events invalidate all tracked paths' '
	test_when_finished "git -C hardlink-event fsmonitor--daemon stop 2>/dev/null || :" &&
	test_create_repo hardlink-event &&
	(
		cd hardlink-event &&
		printf "AAAA\\n" >tracked &&
		git add tracked &&
		git commit -m base &&
		git config core.fsmonitor true &&
		git config core.untrackedCache true &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		cp -p tracked .git/mtime-reference &&
		start_daemon --tf "$PWD/../hardlink-event.trace" &&
		git update-index --fsmonitor &&
		git status --porcelain=v2 >/dev/null &&
		git status --porcelain=v2 >/dev/null &&
		printf "ignore\n" >.git/hardlink-source &&
		ln .git/hardlink-source .git/hardlink-alias &&
		printf "still-ignore\n" >.git/hardlink-alias &&
		test-tool fsmonitor-client query >.git/gitdir-query &&
		test_grep ! "^event: //$" ../hardlink-event.trace &&
		ln tracked alias &&
		printf "BBBB\\n" >alias &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/expect &&
		touch -r .git/mtime-reference alias &&
		GIT_OPTIONAL_LOCKS=0 git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_grep "^event: //$" ../hardlink-event.trace &&
		git fsmonitor--daemon stop
	)
'

test_expect_success MACOS,UNTRACKED_CACHE \
	'directory timestamp events preserve clean fsmonitor proofs' '
	test_when_finished \
		"git -C directory-metadata fsmonitor--daemon stop 2>/dev/null || :" &&
	test_create_repo directory-metadata &&
	(
		cd directory-metadata &&
		mkdir -p api/nested other &&
		test_write_lines api >api/nested/tracked &&
		test_write_lines other >other/tracked &&
		git add api/nested/tracked other/tracked &&
		git commit -m base &&
		git config core.fsmonitor true &&
		git config core.untrackedCache true &&
		start_daemon --tf "$PWD/.git/daemon.trace" &&
		git status --porcelain=2 >.git/warm-one &&
		git status --porcelain=2 >.git/warm-two &&
		git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&

		for mode in root nested xattr
		do
			case "$mode" in
			root) directory=api ;;
			nested) directory=api/nested ;;
			xattr)
				directory=api &&
				xattr -w com.git.fsmonitor.test ignored "$directory"
				;;
			esac &&
			if test -f .git/index.csts
			then
				expect_sidecar_hit=t
			else
				expect_sidecar_hit=
			fi &&
			touch "$directory" &&
			GIT_TRACE2_EVENT="$PWD/.git/touch.trace" \
				git status --porcelain=v2 -- "$directory" \
				>.git/touch &&
			test_must_be_empty .git/touch &&
			if test -n "$expect_sidecar_hit"
			then
				test_trace2_data status clean-proof/hit 1 \
					<.git/touch.trace &&
				test_grep ! "\"label\":\"do_read_index\"" \
					.git/touch.trace
			fi &&
			test_grep ! "\"key\":\"semantic/attributes-cone\"" \
				.git/touch.trace &&
			test_grep ! "\"key\":\"semantic/manifest-scan-count\"" \
				.git/touch.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
				.git/touch.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"preload\"" \
				.git/touch.trace &&
			test_grep ! "\"key\":\"preload/bulk_" \
				.git/touch.trace &&
			rm .git/touch.trace || return 1
		done &&
		test_grep "ignore-dir-metadata:.*api" .git/daemon.trace &&

		mkdir api/created &&
		test_write_lines child >api/created/child &&
		git status --porcelain=v2 -- api >.git/created &&
		test_grep "^? api/created/$" .git/created &&
		rm api/created/child &&
		rmdir api/created &&
		git status --porcelain=v2 -- api >.git/removed &&
		test_must_be_empty .git/removed &&

		test_write_lines "* text" >api/.gitattributes &&
		git status --porcelain=v2 -- api >.git/attributes &&
		test_grep "^? api/.gitattributes$" .git/attributes &&
		rm api/.gitattributes &&
		git status --porcelain=v2 -- api >.git/attributes-removed &&
		test_must_be_empty .git/attributes-removed &&

		chmod 750 api &&
		git status --porcelain=v2 -- api >.git/chmod &&
		test_grep "fsevent:.*api.*ItemChangeOwner" \
			.git/daemon.trace &&
		chmod 755 api &&
		mv api/nested api/renamed &&
		git status --porcelain=v2 -- api >.git/renamed &&
		test_grep "^1 \\.D .*api/nested/tracked$" .git/renamed &&
		test_grep "^? api/renamed/$" .git/renamed
	)
'

test_expect_success MACOS 'implicit daemon reuses the invoking Git executable' '
	test_create_repo same-executable-spawn &&
	mkdir fake-exec-path &&
	write_script fake-exec-path/git <<-EOF &&
	echo invoked >"$TRASH_DIRECTORY/fake-git-used"
	exit 1
	EOF
	(
		cd same-executable-spawn &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_EXEC_PATH="$TRASH_DIRECTORY/fake-exec-path" \
		GIT_TRACE2_EVENT="$PWD/.git/spawn.trace" \
			"$GIT_BUILD_DIR/git" status --porcelain=v2 \
			>.git/actual &&
		test_must_be_empty .git/actual &&
		test_path_is_missing "$TRASH_DIRECTORY/fake-git-used" &&
		test_grep -F "\"argv\":[\"$GIT_BUILD_DIR/git\",\"fsmonitor--daemon\",\"run\",\"--detach\"]" \
			.git/spawn.trace &&
		git fsmonitor--daemon stop
	)
'

test_expect_success MACOS 'implicit daemon rediscovers a linked worktree' '
	test_when_finished "
		git -C reexec-linked-wt fsmonitor--daemon stop 2>/dev/null || :
		git -C reexec-linked-main worktree remove --force \
			../reexec-linked-wt 2>/dev/null || :
	" &&
	test_create_repo reexec-linked-main &&
	(
		cd reexec-linked-main &&
		test_commit base tracked &&
		git worktree add ../reexec-linked-wt &&
		git -C ../reexec-linked-wt config core.untrackedCache true &&
		git -C ../reexec-linked-wt config core.fsmonitor true &&
		linked_worktree=$(test-tool path-utils real_path \
			../reexec-linked-wt) &&
		GIT_TRACE2_EVENT="$PWD/../reexec-linked.trace" \
			git -C ../reexec-linked-wt status --porcelain=v2 \
			>../reexec-linked.actual &&
		test_must_be_empty ../reexec-linked.actual &&
		test_grep "\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
			../reexec-linked.trace &&
		test_grep \
			"\"child_class\":\"fsmonitor\",\"cd\":\"$linked_worktree\"" \
			../reexec-linked.trace &&
		git -C ../reexec-linked-wt fsmonitor--daemon stop &&
		git worktree remove ../reexec-linked-wt
	)
'

test_expect_success MACOS 'implicit startup treats a bad timeout as best effort' '
	test_create_repo reexec-timeout &&
	(
		cd reexec-timeout &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		git config fsmonitor.starttimeout nonsense &&
		git status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		git config --unset fsmonitor.starttimeout &&
		git fsmonitor--daemon stop &&
		git config fsmonitor.starttimeout nonsense &&
		test_must_fail git fsmonitor--daemon start 2>.git/err &&
		test_grep "bad numeric config value" .git/err
	)
'

test_expect_success 'bound query replaces a legacy daemon' '
	test_when_finished \
		"stop_daemon_delete_repo legacy-daemon-upgrade" &&
	test_create_repo legacy-daemon-upgrade &&
	(
		cd legacy-daemon-upgrade &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git status --porcelain=v2 >/dev/null &&
		git config core.fsmonitor true &&
		ipc_path=$(git rev-parse --path-format=absolute \
			--git-path fsmonitor--daemon.ipc) &&
		test-tool simple-ipc start-daemon \
			--name="$ipc_path" --threads=1 --fsmonitor-legacy &&

		GIT_TRACE2_EVENT="$PWD/.git/upgrade.trace" \
			git status >.git/upgrade.out &&
		test_trace2_data fsm_client query/incompatible-daemon 1 \
			<.git/upgrade.trace &&
		test-tool dump-fsmonitor >.git/fsmonitor &&
		test_grep ! "builtin:test-legacy:0" .git/fsmonitor &&
		test_grep \
			"\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
			.git/upgrade.trace &&

		GIT_TRACE2_EVENT="$PWD/.git/warm.trace" \
			git status >.git/warm.out &&
		! test_trace2_data index refresh/sum_lstat \
			"[1-9][0-9]*" <.git/warm.trace &&
		! test_trace2_data fsm_client query/trivial-response 1 \
			<.git/warm.trace &&
		test_grep ! \
			"\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
			.git/warm.trace
	)
'

test_expect_success MACOS 'bound query upgrades stale directory event daemon' '
	test_when_finished \
		"stop_daemon_delete_repo directory-daemon-upgrade" &&
	test_create_repo directory-daemon-upgrade &&
	(
		cd directory-daemon-upgrade &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git status --porcelain=v2 >.git/before &&
		test_must_be_empty .git/before &&
		git config core.fsmonitor true &&
		ipc_path=$(git rev-parse --path-format=absolute \
			--git-path fsmonitor--daemon.ipc) &&
		test-tool simple-ipc start-daemon \
			--name="$ipc_path" --threads=1 \
			--fsmonitor-pre-dir-metadata &&

		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TRACE2_EVENT="$PWD/.git/upgrade.trace" \
			git status --porcelain=v2 >.git/upgrade &&
		test_must_be_empty .git/upgrade &&
		test_trace2_data fsm_client query/incompatible-daemon 1 \
			<.git/upgrade.trace &&
		test_grep \
			"\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
			.git/upgrade.trace &&
		test-tool dump-fsmonitor >.git/fsmonitor &&
		test_grep "fsmonitor last update builtin:dirmeta-v1\\." \
			.git/fsmonitor &&

		GIT_TRACE2_EVENT="$PWD/.git/repeat.trace" \
			git status --porcelain=v2 >.git/repeat &&
		test_cmp .git/upgrade .git/repeat &&
		! test_trace2_data fsm_client query/incompatible-daemon 1 \
			<.git/repeat.trace &&
		test_grep ! \
			"\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
			.git/repeat.trace
	)
'

test_expect_success MACOS,UNTRACKED_CACHE \
	'inotify watch-limit backoff preserves ordinary status without retries' '
	test_when_finished "stop_daemon_delete_repo inotify-watch-backoff" &&
	test_create_repo inotify-watch-backoff &&
	(
		cd inotify-watch-backoff &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		printf "inotify-limit-v1\\ntest-worktree\\n0\\n" \
			>.git/fsmonitor--daemon.inotify-limit &&
		chmod 600 .git/fsmonitor--daemon.inotify-limit &&
		test_write_lines changed >tracked &&
		test_write_lines visible >blep &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/expect &&

		for attempt in first second
		do
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TRACE2_EVENT="$PWD/.git/$attempt.trace" \
				git status --porcelain=v2 >.git/$attempt.actual &&
			test_cmp .git/expect .git/$attempt.actual &&
			test_trace2_data fsm_client \
				settings/inotify-watch-limit-backoff 1 \
				<.git/$attempt.trace &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<.git/$attempt.trace &&
			test_grep ! \
				"\\\"event\\\":\\\"child_start\\\".*\\\"fsmonitor--daemon\\\"" \
				.git/$attempt.trace || return 1
		done &&
		test_grep "^1 \\.M .* tracked$" .git/first.actual &&
		test_grep "^? blep$" .git/first.actual
	)
'

test_expect_success MACOS,UNTRACKED_CACHE \
	'expired watch-limit backoff allows an authenticated daemon to recover' '
	test_when_finished "stop_daemon_delete_repo inotify-watch-expired" &&
	test_create_repo inotify-watch-expired &&
	(
		cd inotify-watch-expired &&
		test_commit base tracked &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		printf "inotify-limit-v1\\ntest-worktree\\n0\\n" \
			>.git/fsmonitor--daemon.inotify-limit &&
		chmod 600 .git/fsmonitor--daemon.inotify-limit &&
		test-tool chmtime -120 .git/fsmonitor--daemon.inotify-limit &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/expired.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		! test_trace2_data fsm_client \
			settings/inotify-watch-limit-backoff 1 \
			<.git/expired.trace &&
		test_grep \
			"\\\"event\\\":\\\"child_start\\\".*\\\"fsmonitor--daemon\\\"" \
			.git/expired.trace &&
		test_path_is_missing .git/fsmonitor--daemon.inotify-limit &&
		git fsmonitor--daemon status
	)
'

test_expect_success MACOS,UNTRACKED_CACHE \
	'a running or explicitly started daemon overrides watch-limit backoff' '
	test_when_finished "stop_daemon_delete_repo inotify-watch-live" &&
	test_create_repo inotify-watch-live &&
	(
		cd inotify-watch-live &&
		test_commit base tracked &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		git fsmonitor--daemon start &&
		printf "inotify-limit-v1\\ntest-worktree\\n0\\n" \
			>.git/fsmonitor--daemon.inotify-limit &&
		chmod 600 .git/fsmonitor--daemon.inotify-limit &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/live.trace" \
			git status --porcelain=v2 >.git/live &&
		test_must_be_empty .git/live &&
		! test_trace2_data fsm_client \
			settings/inotify-watch-limit-backoff 1 <.git/live.trace &&
		git fsmonitor--daemon stop &&
		printf "inotify-limit-v1\\ntest-worktree\\n0\\n" \
			>.git/fsmonitor--daemon.inotify-limit &&
		chmod 600 .git/fsmonitor--daemon.inotify-limit &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			git fsmonitor--daemon start &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			git status --porcelain=v2 >.git/recovered &&
		test_must_be_empty .git/recovered &&
		test_path_is_missing .git/fsmonitor--daemon.inotify-limit
	)
'

test_expect_success MACOS,SYMLINKS,UNTRACKED_CACHE \
	'foreign and symlinked watch-limit markers never disable a worktree' '
	test_when_finished "stop_daemon_delete_repo inotify-watch-foreign" &&
	test_create_repo inotify-watch-foreign &&
	(
		cd inotify-watch-foreign &&
		test_commit base tracked &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		printf "inotify-limit-v1\\nforeign-worktree\\n0\\n" \
			>.git/fsmonitor--daemon.inotify-limit &&
		chmod 600 .git/fsmonitor--daemon.inotify-limit &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/foreign.trace" \
			git status --porcelain=v2 >.git/foreign &&
		test_must_be_empty .git/foreign &&
		! test_trace2_data fsm_client \
			settings/inotify-watch-limit-backoff 1 \
			<.git/foreign.trace &&
		git fsmonitor--daemon stop &&
		rm -f .git/fsmonitor--daemon.inotify-limit &&
		printf "inotify-limit-v1\\ntest-worktree\\n0\\n" \
			>.git/inotify-marker-target &&
		chmod 600 .git/inotify-marker-target &&
		ln -s inotify-marker-target .git/fsmonitor--daemon.inotify-limit &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/symlink.trace" \
			git status --porcelain=v2 >.git/symlink &&
		test_must_be_empty .git/symlink &&
		! test_trace2_data fsm_client \
			settings/inotify-watch-limit-backoff 1 \
			<.git/symlink.trace &&
		test_path_is_file .git/inotify-marker-target &&
		test_grep test-worktree .git/inotify-marker-target
	)
'

test_expect_success MACOS,UNTRACKED_CACHE \
	'watch-limit backoff does not leak into a linked worktree' '
	test_when_finished "
		git -C inotify-watch-linked fsmonitor--daemon stop \
			2>/dev/null || :
		git -C inotify-watch-main fsmonitor--daemon stop \
			2>/dev/null || :
		git -C inotify-watch-main -c core.fsmonitor=false \
			worktree remove --force ../inotify-watch-linked \
			2>/dev/null || :
	" &&
	test_create_repo inotify-watch-main &&
	(
		cd inotify-watch-main &&
		test_commit base tracked &&
		git worktree add ../inotify-watch-linked &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		printf "inotify-limit-v1\\ntest-worktree\\n0\\n" \
			>.git/fsmonitor--daemon.inotify-limit &&
		chmod 600 .git/fsmonitor--daemon.inotify-limit &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/main.trace" \
			git status --porcelain=v2 >.git/main &&
		test_must_be_empty .git/main &&
		test_trace2_data fsm_client \
			settings/inotify-watch-limit-backoff 1 <.git/main.trace &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/linked.trace" \
			git -C ../inotify-watch-linked status --porcelain=v2 \
			>.git/linked &&
		test_must_be_empty .git/linked &&
		! test_trace2_data fsm_client \
			settings/inotify-watch-limit-backoff 1 \
			<.git/linked.trace &&
		test_grep \
			"\\\"event\\\":\\\"child_start\\\".*\\\"fsmonitor--daemon\\\"" \
			.git/linked.trace
	)
'

test_expect_success MACOS,UNTRACKED_CACHE \
	'failed bound query reconnects to an authenticated replacement daemon' '
	test_when_finished \
		"stop_daemon_delete_repo disconnected-directory-daemon" &&
	test_create_repo disconnected-directory-daemon &&
	(
		cd disconnected-directory-daemon &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_write_lines visible >blep &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git status --porcelain=v2 >.git/expect &&
		test_grep "^? blep$" .git/expect &&
		git config core.fsmonitor true &&
		ipc_path=$(git rev-parse --path-format=absolute \
			--git-path fsmonitor--daemon.ipc) &&
		test-tool simple-ipc start-daemon \
			--name="$ipc_path" --threads=1 \
			--fsmonitor-disconnect-first &&

		GIT_TRACE2_EVENT="$PWD/.git/reconnect.trace" \
			git status --porcelain=v2 \
				>.git/actual 2>.git/reconnect.error &&
		test_cmp .git/expect .git/actual &&
		test_must_be_empty .git/reconnect.error &&
		test_trace2_data fsm_client query/reconnect-after-failed-send 1 \
			<.git/reconnect.trace &&
		test_grep \
			"\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
			.git/reconnect.trace &&
		! test_trace2_data fsm_client query/worktree-mismatch 1 \
			<.git/reconnect.trace &&
		test-tool dump-fsmonitor >.git/fsmonitor &&
		test_grep "fsmonitor last update builtin:dirmeta-v1\\." \
			.git/fsmonitor &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&

		GIT_TRACE2_EVENT="$PWD/.git/repeat.trace" \
			git status --porcelain=v2 >.git/repeat &&
		test_cmp .git/expect .git/repeat &&
		! test_trace2_data fsm_client query/reconnect-after-failed-send 1 \
			<.git/repeat.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/repeat.trace &&
		test_grep ! \
			"\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
			.git/repeat.trace
	)
'

test_expect_success MACOS,UNTRACKED_CACHE \
	'concurrent clients share one stale directory daemon upgrade' '
	test_when_finished \
		"stop_daemon_delete_repo concurrent-directory-daemon-upgrade" &&
	test_create_repo concurrent-directory-daemon-upgrade &&
	(
		cd concurrent-directory-daemon-upgrade &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		for sibling in $(test_seq 1 16)
		do
			mkdir "sibling-$sibling" &&
			test_write_lines "base-$sibling" \
				>"sibling-$sibling/tracked" || return 1
		done &&
		git add sibling-* &&
		git commit -m base &&
		test_write_lines visible >blep &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git status --porcelain=v2 >.git/expect &&
		test_grep "^? blep$" .git/expect &&
		git config core.fsmonitor true &&
		ipc_path=$(git rev-parse --path-format=absolute \
			--git-path fsmonitor--daemon.ipc) &&
		test-tool simple-ipc start-daemon \
			--name="$ipc_path" --threads=8 \
			--fsmonitor-pre-dir-metadata &&

		pids= &&
		for client in $(test_seq 1 8)
		do
			GIT_TRACE2_EVENT="$PWD/.git/client-$client.trace" \
				git status --porcelain=v2 \
				>.git/client-$client.actual \
				2>.git/client-$client.error &
			pids="$pids $!" || return 1
		done &&
		failed= &&
		for pid in $pids
		do
			wait "$pid" || failed=1 || return 1
		done &&
		test -z "$failed" &&

		for client in $(test_seq 1 8)
		do
			test_cmp .git/expect .git/client-$client.actual &&
			test_must_be_empty .git/client-$client.error &&
			! test_trace2_data fsm_client query/worktree-mismatch 1 \
				<.git/client-$client.trace || return 1
		done &&
		grep -h \
			"\"event\":\"child_start\".*\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
			.git/client-*.trace >.git/daemon-spawns &&
		test_line_count = 1 .git/daemon-spawns &&
		test-tool dump-fsmonitor >.git/fsmonitor &&
		test_grep "fsmonitor last update builtin:dirmeta-v1\\." \
			.git/fsmonitor &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&

		GIT_TRACE2_EVENT="$PWD/.git/repeat.trace" \
			git status --porcelain=v2 >.git/repeat &&
		test_cmp .git/expect .git/repeat &&
		! test_trace2_data fsm_client query/incompatible-daemon 1 \
			<.git/repeat.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/repeat.trace &&
		test_grep ! \
			"\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
			.git/repeat.trace
	)
'

test_expect_success 'bound daemon also serves legacy token queries' '
	test_when_finished "stop_daemon_delete_repo legacy-client-query" &&
	test_create_repo legacy-client-query &&
	(
		cd legacy-client-query &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TRACE2_EVENT="$PWD/.git/daemon.trace" \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test-tool dump-fsmonitor >.git/fsmonitor &&
		token=$(sed -n "s/^fsmonitor last update //p" \
			.git/fsmonitor) &&
		test -n "$token" &&
		ipc_path=$(git rev-parse --path-format=absolute \
			--git-path fsmonitor--daemon.ipc) &&
		test-tool simple-ipc send --name="$ipc_path" \
			--token="$token" >.git/legacy-response &&
		test_grep "^builtin:" .git/legacy-response &&
		! test_trace2_data fsmonitor query/worktree-mismatch 1 \
			<.git/daemon.trace &&
		GIT_TRACE2_EVENT="$PWD/.git/legacy-client.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		! test_trace2_data fsm_client query/trivial-response 1 \
			<.git/legacy-client.trace
	)
'

test_expect_success MACOS 'daemon token reset closes a skipHash index' '
	test_when_finished \
		"stop_daemon_delete_repo daemon-token-reset" &&
	test_create_repo daemon-token-reset &&
	(
		cd daemon-token-reset &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit remove removed &&
		test_commit keep clean &&
		git config core.preloadIndexBulk true &&
		git config core.untrackedCache true &&
		git config index.skipHash true &&
		test-tool chmtime =-60 tracked removed clean &&
		git update-index --refresh &&
		git config core.fsmonitor true &&
		start_daemon &&

		git update-index --force-write-index &&
		GIT_INDEX_FILE="$PWD/.git/index" \
			git status --porcelain=v2 >.git/prime.out &&
		test_must_be_empty .git/prime.out &&
		test_grep FSMN .git/index &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		test_trailing_hash .git/index >.git/index.hash &&
		test_oid zero >.git/zero &&
		test_cmp .git/zero .git/index.hash &&
		test-tool dump-fsmonitor >.git/token.before &&
		token_before=$(sed -n \
			"s/^fsmonitor last update //p" .git/token.before) &&

		git fsmonitor--daemon stop &&
		start_daemon &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TRACE2_EVENT="$PWD/.git/reset.trace" \
			git status --porcelain=v2 --untracked-files=normal >.git/reset.out &&
		test_must_be_empty .git/reset.out &&
		test_trace2_data fsm_client query/trivial-response 1 \
			<.git/reset.trace &&
		test_trace2_data index preload/bulk_provider_applied \
			"[1-9][0-9]*" \
			<.git/reset.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/reset.trace &&
		test-tool dump-fsmonitor >.git/token.after &&
		token_after=$(sed -n \
			"s/^fsmonitor last update //p" .git/token.after) &&
		test -n "$token_before" &&
		test -n "$token_after" &&
		test "$token_before" != "$token_after" &&

		GIT_TRACE2_EVENT="$PWD/.git/warm.trace" \
			git status --porcelain=v2 >.git/warm.out &&
		test_must_be_empty .git/warm.out &&
		! test_trace2_data index refresh/sum_lstat \
			"[1-9][0-9]*" <.git/warm.trace &&
		! test_trace2_data fsm_client query/trivial-response 1 \
			<.git/warm.trace &&

		git fsmonitor--daemon stop &&
		echo changed >>tracked &&
		rm removed &&
		start_daemon &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TRACE2_EVENT="$PWD/.git/dirty-reset.trace" \
			git status --porcelain=v2 >.git/dirty-reset.out &&
		test_line_count = 2 .git/dirty-reset.out &&
		test_grep "^1 \.M .* tracked$" .git/dirty-reset.out &&
		test_grep "^1 \.D .* removed$" .git/dirty-reset.out &&
		test_trace2_data fsm_client query/trivial-response 1 \
			<.git/dirty-reset.trace &&
		test_trace2_data index preload/bulk_provider_applied 1 \
			<.git/dirty-reset.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/dirty-reset.trace &&

		GIT_TRACE2_EVENT="$PWD/.git/dirty-warm.trace" \
			git status --porcelain=v2 >.git/dirty-warm.out &&
		test_cmp .git/dirty-reset.out .git/dirty-warm.out &&
		test_trace2_data index preload/bulk_provider_applied 1 \
			<.git/dirty-warm.trace &&
		test_trace2_data index refresh/sum_lstat 0 \
			<.git/dirty-warm.trace &&
		! test_trace2_data fsm_client query/trivial-response 1 \
			<.git/dirty-warm.trace
	)
'

test_expect_success 'bound query accepts a capability superset' '
	test_when_finished \
		"stop_daemon_delete_repo capability-superset" &&
	test_create_repo capability-superset &&
	(
		cd capability-superset &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git status --porcelain=v2 >/dev/null &&
		git config core.fsmonitor true &&
		ipc_path=$(git rev-parse --path-format=absolute \
			--git-path fsmonitor--daemon.ipc) &&
		test-tool simple-ipc start-daemon \
			--name="$ipc_path" --threads=1 \
			--fsmonitor-capability-superset &&

		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/status.out &&
		test_trace2_data fsm_client query/command \
			"builtin:test-capable:0" <.git/status.trace &&
		test_grep ! \
			"\"key\":\"query/incompatible-daemon\"" \
			.git/status.trace &&
		test_grep ! \
			"\"argv\":.*\"fsmonitor--daemon\",\"run\",\"--detach\"" \
			.git/status.trace
	)
'

test_expect_success MACOS 'worktree binding rejects same-gitdir aliases' '
	test_when_finished "git -C binding-a fsmonitor--daemon stop 2>/dev/null || :" &&
	git init --separate-git-dir="$PWD/binding-gitdir" binding-a &&
	mkdir binding-b &&
	cp binding-a/.git binding-b/.git &&
	(
		cd binding-a &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TRACE2_EVENT="$PWD/../binding-daemon.trace" \
			git status --porcelain=v2 >/dev/null &&
		git status --porcelain=v2 >/dev/null
	) &&
	cp binding-a/tracked binding-b/tracked &&
	echo changed >>binding-b/tracked &&
	GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
		-c core.untrackedCache=false -C binding-b \
		status --porcelain=v2 >binding.expect &&
	GIT_OPTIONAL_LOCKS=0 git -C binding-b \
		status --porcelain=v2 >binding.actual &&
	test_cmp binding.expect binding.actual &&
	test_grep "^1 \.M .* tracked$" binding.actual &&
	test_grep "\"key\":\"query/worktree-mismatch\",\"value\":\"1\"" \
		binding-daemon.trace &&
	git -C binding-a fsmonitor--daemon stop
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'ordinary deltas advance only attribute-stable proofs' '
	test_when_finished "rm -rf token-carry" &&
	test_create_repo token-carry &&
	(
		cd token-carry &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_write_lines "*.txt text" >.gitattributes &&
		git add .gitattributes &&
		git commit -m attributes &&
		git config core.untrackedCache true &&
		git -c core.fsmonitor=false status --porcelain=v2 \
			>.git/initial &&
		test_must_be_empty .git/initial &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSUC .git/index &&
		test_grep FSCF .git/index &&

		touch x &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=x \
		GIT_TRACE2_EVENT="$PWD/.git/created.trace" \
			git status --porcelain=v2 >.git/created &&
		test_grep "^? x$" .git/created &&
		test_trace2_data fsmonitor config/token-advanced 1 \
			<.git/created.trace &&

		rm x &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=x \
		GIT_TRACE2_EVENT="$PWD/.git/deleted.trace" \
			git status --porcelain=v2 >.git/deleted &&
		test_must_be_empty .git/deleted &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/deleted.trace &&
		test_trace2_data fsmonitor config/token-advanced 1 \
			<.git/deleted.trace &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
		GIT_TRACE2_EVENT="$PWD/.git/attributes.trace" \
			git status --porcelain=v2 >.git/attributes &&
		test_must_be_empty .git/attributes &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/attributes.trace &&
		test_trace2_data fsmonitor apply_count 1 \
			<.git/attributes.trace &&
		test_trace2_data fsmonitor semantic/manifest-reconciled 1 \
			<.git/attributes.trace &&
		test_trace2_data fsmonitor config/token-advanced 1 \
			<.git/attributes.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'worktree-only checkout preserves closed semantic history' '
	test_when_finished "rm -rf checkout-history" &&
	test_create_repo checkout-history &&
	(
		cd checkout-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit other other &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test_write_lines changed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git status >.git/dirty &&
		test_grep "modified:.*tracked" .git/dirty &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git checkout -- tracked &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'source-tree checkout preserves closed semantic history' '
	test_when_finished "rm -rf checkout-source-history" &&
	test_create_repo checkout-source-history &&
	(
		cd checkout-source-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test_write_lines changed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git status >.git/dirty &&
		test_grep "modified:.*tracked" .git/dirty &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git checkout HEAD -- tracked &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'source-tree checkout preserves history after a nonsemantic index change' '
	test_when_finished "rm -rf checkout-source-changed" &&
	test_create_repo checkout-source-changed &&
	(
		cd checkout-source-changed &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_write_lines next >tracked &&
		git add tracked &&
		git commit -m next &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git checkout HEAD^ -- tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_grep "^1 M\." .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'checkout-index -u preserves closed semantic history' '
	test_when_finished "rm -rf checkout-index-history" &&
	test_create_repo checkout-index-history &&
	(
		cd checkout-index-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test_write_lines changed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git checkout-index -f -u tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'stat-only update-index preserves closed semantic history' '
	test_when_finished "rm -rf update-index-history" &&
	test_create_repo update-index-history &&
	(
		cd update-index-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test-tool chmtime +1 tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git update-index --refresh --force-write-index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'add --refresh preserves closed semantic history' '
	test_when_finished "rm -rf add-refresh-history" &&
	test_create_repo add-refresh-history &&
	(
		cd add-refresh-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test-tool chmtime +1 tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git add --refresh tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'mtime-only ordinary add preserves closed semantic history' '
	test_when_finished "rm -rf add-ordinary-history" &&
	test_create_repo add-ordinary-history &&
	(
		cd add-ordinary-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test-tool chmtime +1 tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git add tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/path.trace" \
			git status >.git/path &&
		test_grep "nothing to commit, working tree clean" .git/path &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/path.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/path.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'ordinary add preserves history after a nonsemantic index change' '
	test_when_finished "rm -rf add-ordinary-changed" &&
	test_create_repo add-ordinary-changed &&
	(
		cd add-ordinary-changed &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test_write_lines changed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git add tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_grep "^1 M\." .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'ordinary staged paths preserve closed semantic history' '
	test_when_finished "rm -rf staged-semantic-history" &&
	test_create_repo staged-semantic-history &&
	(
		cd staged-semantic-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&

		test_write_lines changed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git add tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/staged.trace" \
			git status --porcelain=v2 >.git/staged &&
		test_grep "^1 M\\..* tracked$" .git/staged &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/staged.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/staged.trace &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git restore --staged tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/unstaged.trace" \
			git status --porcelain=v2 >.git/unstaged &&
		test_grep "^1 \\.M.* tracked$" .git/unstaged &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/unstaged.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/unstaged.trace &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git add tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git reset HEAD -- tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/reset.trace" \
			git status --porcelain=v2 >.git/reset &&
		test_grep "^1 \\.M.* tracked$" .git/reset &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/reset.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/reset.trace &&

		test_write_lines new >new-root-file &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=new-root-file \
			git add new-root-file &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/new-staged.trace" \
			git status --porcelain=v2 >.git/new-staged &&
		test_grep "^1 A\\..* new-root-file$" .git/new-staged &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/new-staged.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/new-staged.trace &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git restore --staged new-root-file &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/new-unstaged.trace" \
			git status --porcelain=v2 >.git/new-unstaged &&
		test_grep "^? new-root-file$" .git/new-unstaged &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/new-unstaged.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/new-unstaged.trace &&

		mkdir -p brand-new/deeper &&
		test_write_lines nested >brand-new/deeper/staged &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=brand-new/deeper/staged \
			git add brand-new/deeper/staged &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/nested-staged.trace" \
			git status --porcelain=v2 >.git/nested-staged &&
		test_grep "^1 A\\..* brand-new/deeper/staged$" \
			.git/nested-staged &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/nested-staged.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/nested-staged.trace &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git restore --staged brand-new/deeper/staged &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/nested-unstaged.trace" \
			git status --porcelain=v2 >.git/nested-unstaged &&
		test_grep "^? brand-new/$" .git/nested-unstaged &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/nested-unstaged.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/nested-unstaged.trace &&

		test_write_lines "* text" >brand-new/.gitattributes &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=brand-new/deeper/staged \
			git add brand-new/deeper/staged &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/attributes-fallback.trace" \
			git status --porcelain=v2 \
			>.git/attributes-fallback &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/attributes-fallback.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'command-scoped transport config preserves staged worktree proofs' '
	test_when_finished "rm -rf command-transport-history" &&
	test_create_repo command-transport-history &&
	(
		cd command-transport-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		for sibling in $(test_seq 1 32)
		do
			mkdir "sibling-$sibling" &&
			test_write_lines "base-$sibling" \
				>"sibling-$sibling/tracked" || return 1
		done &&
		git add sibling-* &&
		git commit -m base &&
		git branch transport-alternate &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&

		for cycle in first second
		do
			test_write_lines "changed-$cycle" >sibling-1/tracked &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
			GIT_TEST_FSMONITOR_QUERY_PATH=sibling-1/tracked \
				git add sibling-1/tracked &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
				git status --porcelain=v2 >.git/staged &&
			test_grep "^1 M\\..* sibling-1/tracked$" .git/staged &&
			test_grep FSUC .git/index &&

			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$cycle.restore.trace" \
				git \
				-c "url.https://proxy.example/github/.insteadOf=https://github.com/" \
				-c "url.https://proxy.example/github/.insteadOf=https://proxy.example/github/" \
				-c "url.https://proxy.example/github/.insteadOf=https://proxy.example/" \
				-c "credential.https://github.com.helper=" \
				-c "credential.https://proxy.example.helper=" \
				-c "credential.https://proxy.example.helper=!og github-proxy credential-helper" \
				restore --staged sibling-1/tracked &&
			test_trace2_data fsmonitor config/coherent 1 \
				<".git/$cycle.restore.trace" &&
			test_trace2_data fsmonitor apply_count 0 \
				<".git/$cycle.restore.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<".git/$cycle.restore.trace" &&
			test_grep FSCF .git/index &&
			test_grep FSUC .git/index &&

			GIT_OPTIONAL_LOCKS=0 git \
				-c core.fsmonitor=false -c core.untrackedCache=false \
				status --porcelain=v2 >.git/expect &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$cycle.status.trace" \
				git status --porcelain=v2 >.git/actual &&
			test_cmp .git/expect .git/actual &&
			test_grep "^1 \\.M.* sibling-1/tracked$" .git/actual &&
			test_trace2_data fsmonitor config/coherent 1 \
				<".git/$cycle.status.trace" &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<".git/$cycle.status.trace" &&
			test_trace2_data index refresh/sum_lstat 1 \
				<".git/$cycle.status.trace" &&
			test_trace2_data read_directory directories-visited 2 \
				<".git/$cycle.status.trace" &&
			test_grep FSCF .git/index &&
			test_grep FSUC .git/index || return 1
		done &&

		test_write_lines "new root file" >blep &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=blep \
			git add blep &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			git status --porcelain=v2 >.git/root-staged &&
		test_grep "^1 A\\..* blep$" .git/root-staged &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/root.restore.trace" \
			git \
			-c "url.https://proxy.example/github/.insteadOf=https://github.com/" \
			-c "url.https://proxy.example/github/.insteadOf=https://proxy.example/github/" \
			-c "url.https://proxy.example/github/.insteadOf=https://proxy.example/" \
			-c "credential.https://github.com.helper=" \
			-c "credential.https://proxy.example.helper=" \
			-c "credential.https://proxy.example.helper=!og github-proxy credential-helper" \
			restore --staged blep &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/root.restore.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/root.restore.trace &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/root.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/root.status.trace" \
			git status --porcelain=v2 >.git/root.actual &&
		test_cmp .git/root.expect .git/root.actual &&
		test_grep "^? blep$" .git/root.actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/root.status.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/root.status.trace &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/switch.trace" \
			git \
			-c "url.https://proxy.example/github/.insteadOf=https://github.com/" \
			-c "url.https://proxy.example/github/.insteadOf=https://proxy.example/github/" \
			-c "url.https://proxy.example/github/.insteadOf=https://proxy.example/" \
			-c "credential.https://github.com.helper=" \
			-c "credential.https://proxy.example.helper=" \
			-c "credential.https://proxy.example.helper=!og github-proxy credential-helper" \
			switch transport-alternate &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/switch.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/switch.trace &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/switch.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/switch-status.trace" \
			git status --porcelain=v2 >.git/switch.actual &&
		test_cmp .git/switch.expect .git/switch.actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/switch-status.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/switch-status.trace &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index
	)
'

	test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'nonsemantic configuration changes reuse the authenticated manifest' '
	test_when_finished "rm -rf command-nonsemantic-history" &&
	test_create_repo command-nonsemantic-history &&
	(
		cd command-nonsemantic-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir sibling &&
		test_commit base sibling/tracked &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSMN .git/index &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		GIT_OPTIONAL_LOCKS=0 git -c user.name=Alternate \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git -c user.name=Alternate status --porcelain=v2 \
				>.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/status.trace &&
		test_trace2_data fsmonitor semantic/initial-mismatch 0 \
			<.git/status.trace &&
		test_trace2_data fsmonitor semantic/manifest-reused 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor config/revalidated 1 \
			<.git/status.trace &&

		test_write_lines hidden >sibling/hidden &&
		test_write_lines sibling/hidden >.git/excludes &&
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.excludesFile="$PWD/.git/excludes" \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/excludes.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=sibling/hidden \
		GIT_TRACE2_EVENT="$PWD/.git/excludes.trace" \
			git -c core.excludesFile="$PWD/.git/excludes" \
				status --porcelain=v2 >.git/excludes.actual &&
		test_cmp .git/excludes.expect .git/excludes.actual &&
		test_must_be_empty .git/excludes.actual &&
		test_trace2_data fsmonitor semantic/manifest-reused 1 \
			<.git/excludes.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/excludes.trace &&
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.excludesFile=/dev/null \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/visible.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/visible.trace" \
			git -c core.excludesFile=/dev/null \
				status --porcelain=v2 >.git/visible.actual &&
		test_cmp .git/visible.expect .git/visible.actual &&
		test_grep "^? sibling/hidden$" .git/visible.actual &&
		test_trace2_data fsmonitor semantic/manifest-reused 1 \
			<.git/visible.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/visible.trace
	)
'

test_expect_success MACOS,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'harmless configuration drift preserves authenticated tracked state' '
	test_when_finished "rm -rf command-tracked-config-history" &&
	test_create_repo command-tracked-config-history &&
	(
		cd command-tracked-config-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir entries &&
		for tracked_entry in $(test_seq 1 257)
		do
			test_write_lines "$tracked_entry" \
				>"entries/tracked-$tracked_entry" || return 1
		done &&
		git add entries &&
		git commit -qm base &&
		test-tool chmtime -120 entries/tracked-* &&
		git -c core.fsmonitor=false update-index --refresh &&
		git config core.autocrlf false &&
		git config core.trustctime true &&
		git config core.checkStat default &&
		git config core.untrackedCache true &&
		git config core.preloadIndexBulk true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSMN .git/index &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c advice.statusHints=false \
				-c core.fsmonitor=false \
				-c core.untrackedCache=false \
				status --porcelain=v2 >.git/expect &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=entries/tracked-1 \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git -c advice.statusHints=false \
				status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_must_be_empty .git/actual &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/status.trace &&
		test_trace2_data fsmonitor config/tracked-epoch-preserved 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor apply_count 1 \
			<.git/status.trace &&
		! test_trace2_data index preload/bulk_useful \
			"[2-9][0-9]*" <.git/status.trace &&
		! test_trace2_data index preload/sum_lstat \
			"[2-9][0-9]*" <.git/status.trace &&
		! test_trace2_data index refresh/sum_lstat \
			"[2-9][0-9]*" <.git/status.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/status.trace &&
		test_region index do_write_index .git/status.trace &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/issue.trace" \
			git -c advice.statusHints=false \
				status --porcelain=v2 >.git/issue &&
		test_cmp .git/expect .git/issue &&
		test_path_is_file .git/index.csts &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/repeat.trace" \
			git -c advice.statusHints=false \
				status --porcelain=v2 >.git/repeat &&
		test_cmp .git/expect .git/repeat &&
		test_trace2_data status clean-proof/hit 1 \
			<.git/repeat.trace
	)
'

test_expect_success MACOS,UNTRACKED_CACHE,PERL_TEST_HELPERS,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'executable policy changes invalidate prior tracked cleanliness' '
	test_when_finished "rm -rf command-tracked-filemode-history" &&
	test_create_repo command-tracked-filemode-history &&
	(
		cd command-tracked-filemode-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines tracked >tracked &&
		git add tracked &&
		git commit -qm base &&
		git config core.filemode false &&
		git config core.autocrlf false &&
		git config core.trustctime true &&
		git config core.checkStat default &&
		git config core.untrackedCache true &&
		git config core.preloadIndexBulk true &&
		git config core.fsmonitor true &&
		chmod +x tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSMN .git/index &&
		test_grep FSCF .git/index &&
		cp .git/index .git/false.before &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.filemode=true \
				-c core.fsmonitor=false \
				-c core.untrackedCache=false \
				status --porcelain=v2 >.git/expect &&
		test_grep "^1 .M .* tracked$" .git/expect &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/command.trace" \
			git -c core.filemode=true \
				status --porcelain=v2 >.git/command &&
		test_cmp .git/expect .git/command &&
		! test_trace2_data fsmonitor config/tracked-epoch-preserved 1 \
			<.git/command.trace &&
		cp .git/false.before .git/index &&
		rm -f .git/index.csts .git/index.csh1.* .git/index.cswi.* &&
		git config core.filemode true &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				status --porcelain=v2 >.git/persistent.expect &&
		test_grep "^1 .M .* tracked$" .git/persistent.expect &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/persistent.trace" \
			git status --porcelain=v2 >.git/persistent &&
		test_cmp .git/persistent.expect .git/persistent &&
		! test_trace2_data fsmonitor config/tracked-epoch-preserved 1 \
			<.git/persistent.trace &&
		cp .git/false.before .git/index &&
		rm -f .git/index.csts .git/index.csh1.* .git/index.cswi.* &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git -c core.filemode=false \
				status --porcelain=v2 >.git/old-command.prime &&
		test_must_be_empty .git/old-command.prime &&
		test_grep FSMN .git/index &&
		test_grep FSCF .git/index &&
		rm -f .git/index.csts .git/index.csh1.* .git/index.cswi.* &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/old-command.trace" \
			git status --porcelain=v2 >.git/old-command &&
		test_cmp .git/persistent.expect .git/old-command &&
		! test_trace2_data fsmonitor config/tracked-epoch-preserved 1 \
			<.git/old-command.trace &&

		cp .git/false.before .git/index &&
		rm -f .git/index.csts .git/index.csh1.* .git/index.cswi.* &&
		git config core.filemode false &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git update-index --index-version 2 &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/tampered.prime &&
		test_must_be_empty .git/tampered.prime &&
		cat >.git/tamper-tracked-policy.pl <<-\EOF &&
		use Digest::SHA qw(sha1 sha256);
		binmode STDIN;
		binmode STDOUT;
		local $/;
		my $index = <STDIN>;
		my $algorithm = shift;
		my $rawsz = $algorithm eq "sha256" ? 32 : 20;
		my $digest = sub {
			return $algorithm eq "sha256" ?
				sha256($_[0]) : sha1($_[0]);
		};
		my $payload = substr($index, 0, -$rawsz);
		die "invalid index checksum\n"
			unless substr($index, -$rawsz) eq $digest->($payload);
		die "not a version 2 index\n"
			unless substr($payload, 0, 4) eq "DIRC" &&
			unpack("N", substr($payload, 4, 4)) == 2;
		my $entries = unpack("N", substr($payload, 8, 4));
		my $offset = 12;
		for (1 .. $entries) {
			my $name_offset = $offset + 40 + $rawsz + 2;
			my $end = index($payload, "\0", $name_offset);
			die "unterminated index entry\n" if $end < 0;
			$offset += (($end + 1 - $offset + 7) & ~7);
		}
		my $found = 0;
		while ($offset < length($payload)) {
			die "truncated index extension\n"
				if length($payload) - $offset < 8;
			my $name = substr($payload, $offset, 4);
			my $size = unpack("N", substr($payload, $offset + 4, 4));
			$offset += 8;
			die "index extension exceeds payload\n"
				if $size > length($payload) - $offset;
			if ($name eq "FSCF") {
				die "duplicate or truncated semantic proof\n"
					if $found++ || $size < 20 + 5 * $rawsz;
				my $extension = substr($payload, $offset, $size);
				my ($version, $magic, $flags, $token, $manifest) =
					unpack("NNNNN", substr($extension, 0, 20));
				die "incomplete version 2 semantic proof\n"
					unless $version == 2 &&
					$magic == 0x46534331 &&
					$flags == 15 && $token &&
					$size == 20 + $token +
						5 * $rawsz + $manifest;
				die "invalid semantic proof checksum\n"
					unless substr($extension, -$rawsz) eq
					$digest->(substr($extension, 0, -$rawsz));
				my $policy_offset = 20 + $token + 3 * $rawsz;
				substr($extension, $policy_offset, 1,
					chr(ord(substr($extension,
						$policy_offset, 1)) ^ 1));
				substr($extension, -$rawsz, $rawsz,
					$digest->(substr($extension, 0, -$rawsz)));
				substr($payload, $offset, $size, $extension);
			}
			$offset += $size;
		}
		die "missing version 2 semantic proof\n" unless $found == 1;
		print $payload, $digest->($payload);
		EOF
		perl .git/tamper-tracked-policy.pl "$(test_oid algo)" \
			<.git/index >.git/index.policy-tampered &&
		cp .git/index.policy-tampered .git/index &&
		rm -f .git/index.csts .git/index.csh1.* .git/index.cswi.* &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/policy-tampered.trace" \
			git status --porcelain=v2 >.git/policy-tampered &&
		test_must_be_empty .git/policy-tampered &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/policy-tampered.trace &&
		! test_trace2_data fsmonitor config/tracked-epoch-preserved 1 \
			<.git/policy-tampered.trace &&

		cp .git/index.policy-tampered .git/index &&
		rm -f .git/index.csts .git/index.csh1.* .git/index.cswi.* &&
		git config core.filemode true &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/policy-tampered-dirty.trace" \
			git status --porcelain=v2 >.git/policy-tampered-dirty &&
		test_cmp .git/persistent.expect .git/policy-tampered-dirty &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/policy-tampered-dirty.trace &&
		! test_trace2_data fsmonitor config/tracked-epoch-preserved 1 \
			<.git/policy-tampered-dirty.trace
	)
'

test_expect_success MACOS,UNTRACKED_CACHE,PERL_TEST_HELPERS,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'legacy empty attribute fingerprints retain authenticated manifests' '
	test_when_finished "rm -rf legacy-empty-attribute-history" &&
	test_create_repo legacy-empty-attribute-history &&
	(
		cd legacy-empty-attribute-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		sane_unset GIT_ATTR_NOSYSTEM &&
		sane_unset GIT_CONFIG_NOSYSTEM &&
		GIT_CONFIG_SYSTEM="$PWD/.git/published-system.gitconfig" &&
		export GIT_CONFIG_SYSTEM &&
		test_write_lines "[advice]" "	statusHints = false" \
			>"$GIT_CONFIG_SYSTEM" &&
		git config --show-scope --get advice.statusHints \
			>.git/system-scope &&
		test_grep "^system[[:space:]]" .git/system-scope &&
		legacy_global=$(git var GIT_ATTR_GLOBAL) &&
		legacy_info=$(git rev-parse --git-path info/attributes) &&
		test_path_is_missing "$(git var GIT_ATTR_SYSTEM)" &&
		test_path_is_missing //etc/gitattributes &&
		test_path_is_missing "$legacy_global" &&
		test_path_is_missing "$legacy_info" &&
		test_write_lines "*.txt -text" >.gitattributes &&
		test_write_lines stable >tracked.txt &&
		for legacy_dir in $(test_seq 1 128)
		do
			mkdir "nested-$legacy_dir" &&
			test_write_lines "*.txt -text" \
				>"nested-$legacy_dir/.gitattributes" &&
			test_write_lines "$legacy_dir" \
				>"nested-$legacy_dir/tracked.txt" || return 1
		done &&
		git add .gitattributes tracked.txt nested-* &&
		git commit -qm base &&
		test-tool chmtime -120 .gitattributes tracked.txt \
			nested-*/*.txt nested-*/.gitattributes &&
		git -c core.fsmonitor=false update-index --refresh &&
		git config core.autocrlf false &&
		git config core.trustctime true &&
		git config core.checkStat default &&
		git config core.untrackedCache true &&
		git config core.preloadIndexBulk true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git update-index --index-version 2 &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSMN .git/index &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		test-tool dump-fsmonitor >.git/current-token &&
		cat >.git/legacy-empty-attributes.pl <<-\EOF &&
		use Digest::SHA qw(sha1 sha256);
		binmode STDIN;
		binmode STDOUT;
		local $/;
		my $index = <STDIN>;
		my ($algorithm, $system, $global, $info, $invalid) = @ARGV;
		my $rawsz = $algorithm eq "sha256" ? 32 : 20;
		my $digest = sub {
			return $algorithm eq "sha256" ?
				sha256($_[0]) : sha1($_[0]);
		};
		my $frame = sub {
			return pack("N", length($_[0])) . $_[0];
		};
		my $legacy = $frame->("attribute-source-content-v1") .
			$frame->(pack("N", 3));
		for my $path ($system, $global, $info) {
			$legacy .= $frame->($path) .
				$frame->(pack("N", 1)) .
				$frame->(pack("N", 0));
		}
		my $legacy_hash = $digest->($legacy);
		if ($invalid) {
			substr($legacy_hash, 0, 1,
				chr(ord(substr($legacy_hash, 0, 1)) ^ 1));
		}
		my $payload = substr($index, 0, -$rawsz);
		die "invalid index checksum\n"
			unless substr($index, -$rawsz) eq $digest->($payload);
		die "not a version 2 index\n"
			unless substr($payload, 0, 4) eq "DIRC" &&
			unpack("N", substr($payload, 4, 4)) == 2;
		my $entries = unpack("N", substr($payload, 8, 4));
		my $offset = 12;
		for (1 .. $entries) {
			my $name_offset = $offset + 40 + $rawsz + 2;
			my $end = index($payload, "\0", $name_offset);
			die "unterminated index entry\n" if $end < 0;
			$offset += (($end + 1 - $offset + 7) & ~7);
		}
		my $rewritten = substr($payload, 0, $offset);
		my $found_proof = 0;
		my $found_token = 0;
		my $removed_untracked = 0;
		while ($offset < length($payload)) {
			die "truncated index extension\n"
				if length($payload) - $offset < 8;
			my $name = substr($payload, $offset, 4);
			my $size = unpack("N", substr($payload, $offset + 4, 4));
			$offset += 8;
			die "index extension exceeds payload\n"
				if $size > length($payload) - $offset;
			my $extension = substr($payload, $offset, $size);
			$offset += $size;
			if ($name eq "FSUC") {
				$removed_untracked++;
				next;
			}
			$found_token++ if $name eq "FSMN";
			if ($name eq "FSCF") {
				die "duplicate or truncated semantic proof\n"
					if $found_proof++ || $size < 20 + 4 * $rawsz;
				my ($version, $magic, $flags, $token, $manifest) =
					unpack("NNNNN", substr($extension, 0, 20));
				my $hashes = $version == 2 ? 5 : 4;
				die "incomplete semantic proof\n"
					unless ($version == 1 || $version == 2) &&
					$magic == 0x46534331 &&
					$flags == 15 && $token &&
					$size == 20 + $token +
						$hashes * $rawsz + $manifest;
				die "invalid semantic proof checksum\n"
					unless substr($extension, -$rawsz) eq
					$digest->(substr($extension, 0, -$rawsz));
				my $attribute_offset = 20 + $token + 2 * $rawsz;
				if ($version == 2) {
					substr($extension,
						$attribute_offset + $rawsz, $rawsz, "");
					substr($extension, 0, 4, pack("N", 1));
				}
				substr($extension, $attribute_offset, $rawsz,
					$legacy_hash);
				substr($extension, -$rawsz, $rawsz,
					$digest->(substr($extension, 0, -$rawsz)));
			}
			$rewritten .= $name . pack("N", length($extension)) .
				$extension;
		}
		die "missing complete semantic proof, token, or untracked proof\n"
			unless $found_proof == 1 && $found_token == 1 &&
			$removed_untracked == 1;
		print $rewritten, $digest->($rewritten);
		EOF
		perl .git/legacy-empty-attributes.pl "$(test_oid algo)" \
			//etc/gitattributes "$legacy_global" "$legacy_info" 0 \
			<.git/index >.git/index.legacy &&
		perl .git/legacy-empty-attributes.pl "$(test_oid algo)" \
			//etc/gitattributes "$legacy_global" "$legacy_info" 1 \
			<.git/index >.git/index.invalid &&
		cp .git/index.legacy .git/index &&
		test_grep FSMN .git/index &&
		test_grep FSCF .git/index &&
		test_grep ! FSUC .git/index &&
		test-tool dump-fsmonitor >.git/legacy-token &&
		test_cmp .git/current-token .git/legacy-token &&
		GIT_OPTIONAL_LOCKS=0 git -c user.name=Legacy \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 \
			>.git/legacy.expect &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked.txt \
		GIT_TRACE2_EVENT="$PWD/.git/legacy.trace" \
			git -c user.name=Legacy status --porcelain=v2 \
				>.git/legacy.actual &&
		test_cmp .git/legacy.expect .git/legacy.actual &&
		test_must_be_empty .git/legacy.actual &&
		test_trace2_data fsmonitor semantic/legacy-empty-attributes 1 \
			<.git/legacy.trace &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/legacy.trace &&
		test_trace2_data fsmonitor semantic/initial-mismatch 0 \
			<.git/legacy.trace &&
		test_trace2_data fsmonitor semantic/manifest-reused 1 \
			<.git/legacy.trace &&
		test_trace2_data fsmonitor config/tracked-epoch-preserved 1 \
			<.git/legacy.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/legacy.trace &&
		! test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/legacy.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/legacy.trace &&
		! test_trace2_data index preload/bulk_useful \
			"[1-9][0-9]*" <.git/legacy.trace &&
		! test_trace2_data index preload/sum_lstat \
			"[2-9][0-9]*" <.git/legacy.trace &&
		! test_trace2_data index refresh/sum_lstat \
			"[2-9][0-9]*" <.git/legacy.trace &&
		test_region index do_write_index .git/legacy.trace &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/issue.trace" \
			git -c user.name=Legacy status --porcelain=v2 \
				>.git/issue.actual &&
		test_cmp .git/legacy.expect .git/issue.actual &&
		test_path_is_file .git/index.csts &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/repeat.trace" \
			git -c user.name=Legacy status --porcelain=v2 \
				>.git/repeat.actual &&
		test_cmp .git/legacy.expect .git/repeat.actual &&
		test_trace2_data status clean-proof/hit 1 \
			<.git/repeat.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/repeat.trace &&

		cp .git/index.legacy .git/index &&
		rm -f .git/index.csts .git/index.csh1.* .git/index.cswi.* &&
		GIT_OPTIONAL_LOCKS=0 git -c advice.statusHints=true \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/system-advice.expect &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked.txt \
		GIT_TRACE2_EVENT="$PWD/.git/system-advice.trace" \
			git -c advice.statusHints=true status --porcelain=v2 \
				>.git/system-advice.actual &&
		test_cmp .git/system-advice.expect .git/system-advice.actual &&
		test_trace2_data fsmonitor semantic/legacy-empty-attributes 1 \
			<.git/system-advice.trace &&
		test_trace2_data fsmonitor config/tracked-epoch-preserved 1 \
			<.git/system-advice.trace &&
		! test_trace2_data index preload/bulk_useful \
			"[1-9][0-9]*" <.git/system-advice.trace &&
		! test_trace2_data index preload/sum_lstat \
			"[2-9][0-9]*" <.git/system-advice.trace &&

		for boundary in invalid external semantic filter
		do
			rm -f .git/index.csts .git/index.csh1.* \
				.git/index.cswi.* "$legacy_info" &&
			if test "$boundary" = invalid
			then
				cp .git/index.invalid .git/index
			else
				cp .git/index.legacy .git/index
			fi &&
			case "$boundary" in
			external)
				test_write_lines "*.txt text eol=crlf" \
					>"$legacy_info" &&
				legacy_config=
				;;
			semantic)
				legacy_config="-c core.autocrlf=true"
				;;
			filter)
				legacy_config="-c filter.legacy.clean=cat"
				;;
			*)
				legacy_config=
				;;
			esac &&
			GIT_OPTIONAL_LOCKS=0 git $legacy_config \
				-c core.fsmonitor=false \
				-c core.untrackedCache=false status --porcelain=v2 \
				>".git/$boundary.expect" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$boundary.trace" \
				git $legacy_config status --porcelain=v2 \
					>".git/$boundary.actual" &&
			test_cmp ".git/$boundary.expect" \
				".git/$boundary.actual" &&
			! test_trace2_data fsmonitor \
				semantic/legacy-empty-attributes 1 \
				<".git/$boundary.trace" &&
			test_trace2_data fsmonitor semantic/initial-mismatch 1 \
				<".git/$boundary.trace" &&
			test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<".git/$boundary.trace" &&
			test_trace2_data fsmonitor semantic/strong-invalidation 1 \
				<".git/$boundary.trace" || return 1
		done &&

		for system_boundary in newer symlink missing
		do
			rm -f .git/index.csts .git/index.csh1.* \
				.git/index.cswi.* "$legacy_info" &&
			cp .git/index.legacy .git/index &&
			case "$system_boundary" in
			newer)
				test_write_lines "[advice]" \
					" statusHints = true" \
					>"$GIT_CONFIG_SYSTEM"
				;;
			symlink)
				mv "$GIT_CONFIG_SYSTEM" .git/system-config.real &&
				ln -s system-config.real "$GIT_CONFIG_SYSTEM"
				;;
			missing)
				rm -f "$GIT_CONFIG_SYSTEM"
				;;
			esac &&
			GIT_OPTIONAL_LOCKS=0 git \
				-c core.fsmonitor=false \
				-c core.untrackedCache=false status --porcelain=v2 \
				>".git/system-$system_boundary.expect" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/system-$system_boundary.trace" \
				git status --porcelain=v2 \
					>".git/system-$system_boundary.actual" &&
			test_cmp ".git/system-$system_boundary.expect" \
				".git/system-$system_boundary.actual" &&
			! test_trace2_data fsmonitor \
				config/tracked-epoch-preserved 1 \
				<".git/system-$system_boundary.trace" || return 1
		done
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'command-scoped conversion config still invalidates worktree proofs' '
	test_when_finished "rm -rf command-semantic-history" &&
	test_create_repo command-semantic-history &&
	(
		cd command-semantic-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		test_write_lines changed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git add tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			git status --porcelain=v2 >.git/staged &&
		test_grep "^1 M\\..* tracked$" .git/staged &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/restore.trace" \
			git -c core.autocrlf=true restore --staged tracked &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/restore.trace &&
		test_trace2_data fsmonitor semantic/initial-mismatch 1 \
			<.git/restore.trace &&
		test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/restore.trace &&
		test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/restore.trace &&
		test_grep ! FSUC .git/index &&
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_grep "^1 \\.M.* tracked$" .git/actual &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/status.trace &&
		test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/status.trace &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'ordinary staged paths reuse unchanged tracked ancestor attributes' '
	test_when_finished "rm -rf staged-tracked-ancestor-attributes" &&
	test_create_repo staged-tracked-ancestor-attributes &&
	(
		cd staged-tracked-ancestor-attributes &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir -p api/existing api/brand-new/deeper &&
		test_write_lines "*.txt text" >api/.gitattributes &&
		test_write_lines existing >api/existing/tracked &&
		git add api/.gitattributes api/existing/tracked &&
		git commit -m base &&
		initial_branch=$(git symbolic-ref --short HEAD) &&
		git switch -c changed-tree &&
		mkdir -p api/branch-only/deeper &&
		test_write_lines alternate >api/existing/alternate.txt &&
		test_write_lines alternate >api/branch-only/deeper/alternate.txt &&
		git add api/existing/alternate.txt \
			api/branch-only/deeper/alternate.txt &&
		git commit -m alternate &&
		git switch "$initial_branch" &&
		test-tool chmtime -120 api/.gitattributes api/existing/tracked &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&

		for location in api/existing/added.txt api/brand-new/deeper/added.txt
		do
			test_write_lines added >"$location" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
			GIT_TEST_FSMONITOR_QUERY_PATH="$location" \
				git add "$location" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/ancestor-add.trace" \
				git status --porcelain=v2 >.git/ancestor-add &&
			test_grep "^1 A\\..* $location$" .git/ancestor-add &&
			test_trace2_data fsmonitor config/coherent 1 \
				<.git/ancestor-add.trace &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<.git/ancestor-add.trace &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git restore --staged "$location" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/ancestor-remove.trace" \
				git status --porcelain=v2 >.git/ancestor-remove &&
			test_trace2_data fsmonitor config/coherent 1 \
				<.git/ancestor-remove.trace &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<.git/ancestor-remove.trace &&
			rm "$location" .git/ancestor-add.trace \
				.git/ancestor-remove.trace &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH="$location" \
				git status --porcelain=v2 >.git/ancestor-deleted &&
			test_must_be_empty .git/ancestor-deleted || return 1
		done &&

		rmdir api/brand-new/deeper api/brand-new &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=api/brand-new/ \
			git status --porcelain=v2 >.git/before-switch &&
		test_must_be_empty .git/before-switch &&

		for branch in changed-tree "$initial_branch"
		do
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
				git switch "$branch" &&
			if test "$branch" = changed-tree
			then
				test_path_is_file api/branch-only/deeper/alternate.txt
			else
				test_path_is_missing api/branch-only
			fi &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/ancestor-switch.trace" \
				git status --porcelain=v2 >.git/ancestor-switch &&
			GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
				-c core.untrackedCache=false status --porcelain=v2 \
				>.git/ancestor-switch.expect &&
			test_cmp .git/ancestor-switch.expect .git/ancestor-switch &&
			test_trace2_data fsmonitor config/coherent 1 \
				<.git/ancestor-switch.trace &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<.git/ancestor-switch.trace &&
			! test_trace2_data index preload/bulk_useful \
				<.git/ancestor-switch.trace &&
			rm .git/ancestor-switch.trace || return 1
		done &&

		cp api/.gitattributes .git/attributes.saved &&
		rm api/.gitattributes &&
		test_write_lines missing >api/existing/missing.txt &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=api/existing/missing.txt \
			git add api/existing/missing.txt &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/ancestor-missing.trace" \
			git status --porcelain=v2 >.git/ancestor-missing &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/ancestor-missing.trace &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git restore --staged api/existing/missing.txt &&
		rm api/existing/missing.txt &&
		cp .git/attributes.saved api/.gitattributes &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=api/.gitattributes \
			git status --porcelain=v2 >.git/repaired &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/repaired-repeat &&

		test_write_lines "*.txt -text" >api/.gitattributes &&
		test_write_lines changed >api/existing/changed.txt &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=api/existing/changed.txt \
			git add api/existing/changed.txt &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/ancestor-changed.trace" \
			git status --porcelain=v2 >.git/ancestor-changed &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/ancestor-changed.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'ordinary add drops history after ITA resolution' '
	test_when_finished "rm -rf add-ordinary-ita" &&
	test_create_repo add-ordinary-ita &&
	(
		cd add-ordinary-ita &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		touch empty &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=empty \
			git add -N empty &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=empty \
			git status --porcelain=v2 >.git/ita &&
		test_grep FSCF .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git add empty &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_grep "^1 A\\." .git/actual &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'a racy restored checkpoint advances the named provider token' '
	test_when_finished "rm -rf restored-racy-token" &&
	test_create_repo restored-racy-token &&
	(
		cd restored-racy-token &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test-tool chmtime -120 tracked &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.trustctime true &&
		git config core.checkStat default &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&
		test_grep FSMN .git/index &&
		test_grep FSUC .git/index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$TRASH_DIRECTORY/restored-racy-baseline.trace" \
			git status --short >.git/baseline &&
		test_must_be_empty .git/baseline &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<"$TRASH_DIRECTORY/restored-racy-baseline.trace" &&
		cp .git/index .git/owned.before &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$TRASH_DIRECTORY/restored-racy-checkpoint.trace" \
			git status --short >.git/checkpoint &&
		test_must_be_empty .git/checkpoint &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<"$TRASH_DIRECTORY/restored-racy-checkpoint.trace" &&
		cp .git/owned.before .git/index &&
		git -c core.fsmonitor=false update-index \
			--no-fsmonitor --force-write-index &&
		test_grep ! FSMN .git/index &&
		test_grep FSCF .git/index &&
		test-tool chmtime -180 .git/index &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --short \
			>.git/expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$TRASH_DIRECTORY/restored-racy-first.trace" \
			git status --short >.git/first &&
		test_cmp .git/expect .git/first &&
		test_trace2_data fsmonitor history/external-restored 1 \
			<"$TRASH_DIRECTORY/restored-racy-first.trace" &&
		test_trace2_data fsmonitor history/external-fsmn-recovered 1 \
			<"$TRASH_DIRECTORY/restored-racy-first.trace" &&
		test_trace2_data fsmonitor history/external-save-reject \
			racy-index <"$TRASH_DIRECTORY/restored-racy-first.trace" &&
		test_trace2_data fsmonitor \
			history/external-racy-index-persisted 1 \
			<"$TRASH_DIRECTORY/restored-racy-first.trace" &&
		test_grep "\"label\":\"do_write_index\"" \
			"$TRASH_DIRECTORY/restored-racy-first.trace" &&
		test-tool dump-fsmonitor >.git/first-token &&
		first_token=$(sed -n "s/^fsmonitor last update //p" \
			.git/first-token) &&
		test -n "$first_token" &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/repeat.trace" \
			git status --short >.git/repeat &&
		test_cmp .git/expect .git/repeat &&
		test_trace2_data index extension/fsmn/read/token "$first_token" \
			<.git/repeat.trace &&
		! test_trace2_data fsmonitor apply_count 1 \
			<.git/repeat.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/repeat.trace
	)
'

test_expect_success MACOS,LEGACY_PREVIEW_FSMONITOR_GIT,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'a legacy writer preserves clean siblings when staging a new directory' '
	test_when_finished "stop_daemon_delete_repo foreign-staged-directory" &&
	test_create_repo foreign-staged-directory &&
	(
		cd foreign-staged-directory &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		for legacy_entry in $(test_seq 1 129)
		do
			legacy_dir="existing-$((legacy_entry % 24))" &&
			mkdir -p "$legacy_dir" &&
			test_write_lines "$legacy_entry" \
				>"$legacy_dir/tracked-$legacy_entry" || return 1
		done &&
		git add existing-* &&
		git commit -qm base &&
		test-tool chmtime -120 existing-*/* &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.trustctime true &&
		git config core.checkStat default &&
		git config core.untrackedCache true &&
		git config core.preloadIndexBulk true &&
		test_write_lines "*.forced" >.git/info/exclude &&
		git config core.fsmonitor true &&
		git fsmonitor--daemon start --start-timeout=10 &&
		git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSMN .git/index &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		GIT_TRACE2_EVENT="$PWD/.git/checkpoint.trace" \
			git status --porcelain=v2 >.git/checkpoint &&
		test_must_be_empty .git/checkpoint &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<.git/checkpoint.trace &&

		mkdir brand-new &&
		test_write_lines staged >brand-new/first &&
		/opt/homebrew/Cellar/og-preview/2026-08-11T2321Z/libexec/openai-git/bin/git \
			add brand-new/first &&
		cp .git/index .git/foreign-before.index &&
		test_grep FSMN .git/index &&
		test_grep ! FSCF .git/index &&
		test_grep ! FSUC .git/index &&
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/expect &&
		test_grep "^1 A\\..* brand-new/first$" .git/expect &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TRACE2_EVENT="$PWD/.git/foreign-stage.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_trace2_data fsmonitor history/external-semantic-restored 1 \
			<.git/foreign-stage.trace &&
		test_trace2_data fsmonitor history/external-untracked-restored 1 \
			<.git/foreign-stage.trace &&
		test_trace2_data fsmonitor history/external-tracked-restored \
			"[1-9][0-9]*" <.git/foreign-stage.trace &&
		! test_trace2_data index preload/bulk_useful \
			"[1-9][0-9]*" <.git/foreign-stage.trace &&
		! test_trace2_data index preload/bulk_dirs \
			"[1-9][0-9]*" <.git/foreign-stage.trace &&

		/opt/homebrew/Cellar/og-preview/2026-08-11T2321Z/libexec/openai-git/bin/git \
			restore --staged brand-new/first &&
		cp .git/index .git/foreign-unstaged-before.index &&
		test_grep FSMN .git/index &&
		test_grep ! FSCF .git/index &&
		test_grep ! FSUC .git/index &&
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/unstaged.expect &&
		test_grep "^? brand-new/$" .git/unstaged.expect &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TRACE2_EVENT="$PWD/.git/foreign-unstaged.trace" \
			git status --porcelain=v2 >.git/unstaged.actual &&
		test_cmp .git/unstaged.expect .git/unstaged.actual &&
		test_trace2_data fsmonitor history/external-restored 1 \
			<.git/foreign-unstaged.trace &&
		! test_trace2_data index preload/bulk_useful \
			"[1-9][0-9]*" <.git/foreign-unstaged.trace &&
		! test_trace2_data index preload/bulk_dirs \
			"[1-9][0-9]*" <.git/foreign-unstaged.trace &&

		test_write_lines ignored >existing-0/ignored.forced &&
		/opt/homebrew/Cellar/og-preview/2026-08-11T2321Z/libexec/openai-git/bin/git \
			add --force existing-0/ignored.forced &&
		cp .git/index .git/foreign-forced-before.index &&
		test_grep FSMN .git/index &&
		test_grep ! FSCF .git/index &&
		test_grep ! FSUC .git/index &&
		GIT_OPTIONAL_LOCKS=0 git \
			-c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain=v2 >.git/forced.expect &&
		test_grep "^1 A\\..* existing-0/ignored.forced$" \
			.git/forced.expect &&
		test_grep "^? brand-new/$" .git/forced.expect &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TRACE2_EVENT="$PWD/.git/foreign-forced.trace" \
			git status --porcelain=v2 >.git/forced.actual &&
		test_cmp .git/forced.expect .git/forced.actual &&
		test_trace2_data fsmonitor history/external-semantic-restored 1 \
			<.git/foreign-forced.trace &&
		test_trace2_data fsmonitor history/external-untracked-restored 1 \
			<.git/foreign-forced.trace &&
		test_trace2_data fsmonitor history/external-tracked-restored \
			"[1-9][0-9]*" <.git/foreign-forced.trace &&
		! test_trace2_data index preload/bulk_useful \
			"[1-9][0-9]*" <.git/foreign-forced.trace &&
		! test_trace2_data index preload/bulk_dirs \
			"[1-9][0-9]*" <.git/foreign-forced.trace
	)
'

test_expect_success FOREIGN_FSMONITOR_GIT,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'a foreign index writer does not strand a racy provider token' '
	test_when_finished "stop_daemon_delete_repo foreign-racy-token" &&
	test_create_repo foreign-racy-token &&
	(
		cd foreign-racy-token &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit peer racy-peer &&
		test-tool chmtime -120 tracked racy-peer &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.trustctime true &&
		git config core.checkStat default &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		git fsmonitor--daemon start --start-timeout=10 &&
		git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSMN .git/index &&
		test_grep FSCF .git/index &&
		GIT_TRACE2_EVENT="$PWD/.git/checkpoint.trace" \
			git status --short >.git/checkpoint &&
		test_must_be_empty .git/checkpoint &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<.git/checkpoint.trace &&

		/opt/homebrew/bin/git update-index --force-write-index &&
		test_grep FSMN .git/index &&
		test_grep ! FSCF .git/index &&
		test-tool dump-fsmonitor >.git/homebrew-token &&
		homebrew_token=$(sed -n "s/^fsmonitor last update //p" \
			.git/homebrew-token) &&
		test -n "$homebrew_token" &&
		test-tool chmtime -120 tracked &&
		test-tool fsmonitor-client query \
			--token "$homebrew_token" >.git/observed &&
		nul_to_q <.git/observed >.git/observed.paths &&
		test_grep tracked .git/observed.paths &&
		test-tool chmtime -180 .git/index &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --short \
			>.git/expect &&
		GIT_TRACE2_EVENT="$PWD/.git/first.trace" \
			git status --short >.git/first &&
		test_cmp .git/expect .git/first &&
		test_trace2_data fsmonitor history/external-restored 1 \
			<.git/first.trace &&
		test_trace2_data fsmonitor history/external-save-reject \
			racy-index <.git/first.trace &&
		test_trace2_data fsmonitor \
			history/external-racy-index-persisted 1 \
			<.git/first.trace &&
		test_grep "\"label\":\"do_write_index\"" .git/first.trace &&
		test-tool dump-fsmonitor >.git/first-token &&
		first_token=$(sed -n "s/^fsmonitor last update //p" \
			.git/first-token) &&
		test -n "$first_token" &&
		test "$homebrew_token" != "$first_token" &&
		GIT_TRACE2_EVENT="$PWD/.git/repeat.trace" \
			git status --short >.git/repeat &&
		test_cmp .git/expect .git/repeat &&
		test_trace2_data index extension/fsmn/read/token "$first_token" \
			<.git/repeat.trace &&
		! test_trace2_data fsmonitor apply_count 1 \
			<.git/repeat.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/repeat.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'describe --dirty preserves closed semantic history' '
	test_when_finished "rm -rf describe-dirty-history" &&
	test_create_repo describe-dirty-history &&
	(
		cd describe-dirty-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test-tool chmtime +1 tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git describe --always --dirty >.git/describe &&
		test_grep ! dirty .git/describe &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'clean stash push preserves closed semantic history' '
	test_when_finished "rm -rf stash-clean-history" &&
	test_create_repo stash-clean-history &&
	(
		cd stash-clean-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		cp .git/index .git/index.before &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
		GIT_TRACE2_EVENT="$PWD/.git/stash.trace" \
			git stash push >.git/stash &&
		test_grep "No local changes to save" .git/stash &&
		test_cmp .git/index.before .git/index &&
		test_grep ! "\"label\":\"do_write_index\"" .git/stash.trace &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'dirty stash push drops closed semantic history' '
	test_when_finished "rm -rf stash-dirty-history" &&
	test_create_repo stash-dirty-history &&
	(
		cd stash-dirty-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test_write_lines changed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git stash push >.git/stash &&
		test_grep "Saved working directory" .git/stash &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,!MINGW \
	'dirty stash cannot resurrect an invalidated external checkpoint' '
	test_when_finished "rm -rf stash-checkpoint-history" &&
	test_create_repo stash-checkpoint-history &&
	(
		cd stash-checkpoint-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test-tool chmtime -120 tracked &&
		git update-index --refresh &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/checkpoint.trace" \
			git status --porcelain=v2 >.git/checkpoint &&
		test_must_be_empty .git/checkpoint &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<.git/checkpoint.trace &&

		test_write_lines changed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git stash push >.git/stash &&
		test_grep "Saved working directory" .git/stash &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor history/external-proof-invalidated 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor history/external-restored 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,!MINGW \
	'pathspec status preserves global history without hiding outside dirt' '
	test_when_finished "rm -rf pathspec-checkpoint-history" &&
	test_create_repo pathspec-checkpoint-history &&
	(
		cd pathspec-checkpoint-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		mkdir scoped &&
		test_commit selected scoped/tracked &&
		test-tool chmtime -120 tracked scoped/tracked &&
		git update-index --refresh &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		test_write_lines changed >tracked &&
		test_write_lines selected >scoped/new &&
		test_write_lines outside >outside-new &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git status --porcelain=v2 -- scoped >.git/first &&
		test_grep "^? scoped/new$" .git/first &&
		test_grep ! "tracked\|outside-new" .git/first &&
		test_path_is_missing .git/index.csts &&
		cp .git/index .git/before &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 -- scoped >.git/second &&
		test_cmp .git/first .git/second &&
		test_cmp .git/before .git/index &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count \
			<.git/status.trace &&
		test_path_is_missing .git/index.csts &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/root &&
		test_grep "^1 \.M .* tracked$" .git/root
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'read-only exact status skips a proof it cannot publish' '
	test_when_finished "rm -rf read-only-exact-true read-only-exact-false" &&
	for use_untracked_cache in true false
	do
		test_create_repo read-only-exact-$use_untracked_cache &&
		(
			cd read-only-exact-$use_untracked_cache &&
			sane_unset GIT_TEST_SPLIT_INDEX &&
			test_commit base tracked &&
			test-tool chmtime -120 tracked &&
			git update-index --refresh &&
			git config core.autocrlf false &&
			git config core.untrackedCache $use_untracked_cache &&
			git config core.fsmonitor true &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git update-index --fsmonitor &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
				git status --porcelain=2 >.git/prime &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
				git status --porcelain=2 >.git/prime-repeat &&
			test_path_is_missing .git/index.csts &&
			cp .git/index .git/before &&
			for label in first repeat
			do
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
				GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
					git status --porcelain=v2 >.git/$label &&
				test_must_be_empty .git/$label &&
				test_trace2_data status fsmonitor/tracked-clean 1 \
					<.git/$label.trace &&
				test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
					.git/$label.trace &&
				test_grep ! "\"category\":\"index\",\"label\":\"preload\"" \
					.git/$label.trace &&
				test_grep ! "\"label\":\"do_write_index\"" \
					.git/$label.trace || return 1
			done &&
			test_cmp .git/before .git/index &&
			test_path_is_missing .git/index.csts &&
			if test_have_prereq MACOS
			then
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
				GIT_TRACE2_EVENT="$PWD/.git/writable.trace" \
					git status --porcelain=v2 >.git/writable &&
				test_trace2_data status clean-proof/sidecar 1 \
					<.git/writable.trace &&
				test_path_is_file .git/index.csts &&
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
				GIT_TRACE2_EVENT="$PWD/.git/hit.trace" \
					git status --porcelain=v2 >.git/hit &&
				test_trace2_data status clean-proof/hit 1 \
					<.git/hit.trace &&
				test_grep ! "\"label\":\"do_read_index\"" .git/hit.trace
			fi
		) || return 1
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'tracked-only status preserves an existing untracked proof' '
	test_when_finished "rm -rf tracked-only-untracked-proof" &&
	test_create_repo tracked-only-untracked-proof &&
	(
		cd tracked-only-untracked-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		mkdir scoped &&
		test_commit selected scoped/tracked &&
		test-tool chmtime -120 tracked scoped/tracked &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		test_write_lines outside >outside-new &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 --untracked-files=normal \
				>.git/prime &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 --untracked-files=normal \
				>.git/prime-repeat &&
		test_grep "^? outside-new$" .git/prime-repeat &&
		test_grep FSUC .git/index &&
		git config status.showUntrackedFiles no &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/configured-first.trace" \
			git status --porcelain=v2 >.git/configured-first &&
		test_must_be_empty .git/configured-first &&
		test_grep FSUC .git/index &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<.git/configured-first.trace &&
		test_grep ! "\"label\":\"do_write_index\"" \
			.git/configured-first.trace &&
		for label in exact plain short
		do
			case "$label" in
			exact) set -- --porcelain=v2 ;;
			plain) set -- ;;
			short) set -- --short ;;
			esac &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
				git status "$@" >.git/$label &&
			test_grep ! "outside-new" .git/$label &&
			test_trace2_data status fsmonitor/tracked-clean 1 \
				<.git/$label.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
				.git/$label.trace &&
			test_grep ! "\"label\":\"do_write_index\"" \
				.git/$label.trace || return 1
		done &&
		test_write_lines selected >scoped/new &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=scoped/new \
		GIT_TRACE2_EVENT="$PWD/.git/hidden-new.trace" \
			git status --porcelain=v2 >.git/hidden-new &&
		test_trace2_data fsmonitor apply_count 1 \
			<.git/hidden-new.trace &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/hidden-new-repeat.trace" \
			git status --porcelain=v2 >.git/hidden-new-repeat &&
		for label in hidden-new hidden-new-repeat
		do
			test_must_be_empty .git/$label &&
			test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
				.git/$label.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"preload\"" \
				.git/$label.trace &&
			if test "$label" = hidden-new
			then
				test_grep "\"label\":\"do_write_index\"" \
					.git/$label.trace
			else
				test_grep ! "\"label\":\"do_write_index\"" \
					.git/$label.trace
			fi &&
			test_grep ! "\"label\":\"read_directory\"" \
				.git/$label.trace || return 1
		done &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			--untracked-files=normal >.git/visible.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/visible.trace" \
			git status --porcelain=v2 --untracked-files=normal \
			>.git/visible.actual &&
		test_cmp .git/visible.expect .git/visible.actual &&
		test_grep "^? scoped/new$" .git/visible.actual &&
		test_write_lines changed >tracked &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/changed.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$PWD/.git/changed.trace" \
			git status --porcelain=v2 >.git/changed.actual &&
		test_cmp .git/changed.expect .git/changed.actual &&
		test_grep "^1 \\.M .* tracked$" .git/changed.actual &&
		test_grep ! "outside-new" .git/changed.actual &&
		test_grep "\"category\":\"index\",\"label\":\"refresh\"" \
			.git/changed.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'ignored status preserves an existing untracked proof' '
	test_when_finished "rm -rf ignored-untracked-proof" &&
	test_create_repo ignored-untracked-proof &&
	(
		cd ignored-untracked-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		mkdir scoped &&
		test_commit selected scoped/tracked &&
		test_write_lines "*.ignored" >.gitignore &&
		git add .gitignore &&
		git commit -m ignore &&
		test-tool chmtime -120 tracked scoped/tracked .gitignore &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		test_write_lines outside >outside-new &&
		test_write_lines ignored >skip.ignored &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 --untracked-files=normal \
				>.git/prime &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 --untracked-files=normal \
				>.git/prime-repeat &&
		test_grep FSUC .git/index &&
		git config status.showUntrackedFiles normal &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			--ignored >.git/ignored.expect &&
		for label in first repeat
		do
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
				git status --porcelain=v2 --ignored >.git/$label &&
			test_cmp .git/ignored.expect .git/$label &&
			test_grep FSUC .git/index &&
			test_grep ! "\"label\":\"do_write_index\"" \
				.git/$label.trace &&
			if test "$label" = repeat
			then
				test_trace2_data status fsmonitor/tracked-clean 1 \
					<.git/$label.trace &&
				test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
					.git/$label.trace &&
				test_grep ! "\"category\":\"index\",\"label\":\"preload\"" \
					.git/$label.trace
			fi || return 1
		done &&
		test_grep "^? outside-new$" .git/repeat &&
		test_grep "^! skip\\.ignored$" .git/repeat &&
		test_write_lines selected >scoped/new &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=scoped/new \
		GIT_TRACE2_EVENT="$PWD/.git/changed.trace" \
			git status --porcelain=v2 --ignored >.git/changed &&
		test_trace2_data fsmonitor apply_count 1 \
			<.git/changed.trace &&
		test_grep "^? scoped/new$" .git/changed &&
		test_grep "^! skip\\.ignored$" .git/changed &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/visible.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/visible.actual &&
		test_cmp .git/visible.expect .git/visible.actual &&
		test_grep "^? scoped/new$" .git/visible.actual
	)
'

test_expect_success UNTRACKED_CACHE,HARDLINKS,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'status modes revalidate cached exclude contents' '
	test_when_finished "rm -rf all-untracked-excludes" &&
	test_when_finished "rm -f all-untracked-exclude-alias" &&
	test_create_repo all-untracked-excludes &&
	(
		cd all-untracked-excludes &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir cached &&
		test_write_lines ignored >cached/.gitignore &&
		test_write_lines hidden >cached/ignored &&
		git add cached/.gitignore &&
		git commit -m base &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
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
		ln cached/.gitignore ../all-untracked-exclude-alias &&
		mtime=$(test-tool chmtime --get cached/.gitignore) &&
		test_write_lines visible >../all-untracked-exclude-alias &&
		test-tool chmtime =$mtime cached/.gitignore &&
		cp .git/index .git/index.before &&
		for label in all-root all-directory all-exclude \
			normal-directory normal-exclude \
			tracked-root tracked-directory tracked-exclude \
			ignored-root ignored-directory ignored-exclude
		do
			cp .git/index.before .git/index &&
			case "$label" in
			all-root) set -- --untracked-files=all ;;
			all-directory) set -- --untracked-files=all -- cached ;;
			all-exclude) \
				set -- --untracked-files=all -- cached/.gitignore ;;
			normal-directory) set -- -- cached ;;
			normal-exclude) set -- -- cached/.gitignore ;;
			tracked-root) set -- --untracked-files=no ;;
			tracked-directory) set -- --untracked-files=no -- cached ;;
			tracked-exclude) \
				set -- --untracked-files=no -- cached/.gitignore ;;
			ignored-root) set -- --ignored ;;
			ignored-directory) set -- --ignored -- cached ;;
			ignored-exclude) set -- --ignored -- cached/.gitignore ;;
			esac &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
				git status --porcelain=v2 "$@" \
					>.git/$label.actual &&
			test_grep "^1 \\.M .* cached/.gitignore$" \
				.git/$label.actual &&
			test_trace2_data status \
				fsmonitor/exclude-index-invalidated 1 \
				<.git/$label.trace &&
			case "$label" in
			all-root|all-directory|normal-directory|ignored-root|ignored-directory)
				test_grep "^? cached/ignored$" \
					.git/$label.actual ;;
			*) : ;;
			esac || return 1
		done
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'tracked pathspecs reuse scoped fsmonitor proofs' '
	test_when_finished "rm -rf scoped-fsmonitor-proof" &&
	test_create_repo scoped-fsmonitor-proof &&
	(
		cd scoped-fsmonitor-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit root-prefix track &&
		test_commit root-longer tracked-extra &&
		mkdir scoped other &&
		test_commit selected scoped/tracked &&
		mkdir scoped/deep &&
		test_commit excluded scoped/deep/tracked &&
		test_commit unrelated other/tracked &&
		test-tool chmtime -120 track tracked tracked-extra scoped/tracked \
			scoped/deep/tracked other/tracked &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 --untracked-files=normal \
				>.git/prime &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 --untracked-files=normal \
				>.git/prime-repeat &&
		git config status.showUntrackedFiles all &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/all-prime &&
		test_must_be_empty .git/all-prime &&
		test_write_lines nested >scoped/new &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=scoped/new \
		GIT_TRACE2_EVENT="$PWD/.git/first.trace" \
			git status --porcelain=v2 -- tracked >.git/first &&
		test_must_be_empty .git/first &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			-- scoped/tracked/ >.git/trailing-first.expect \
				2>.git/trailing-first.expect.err &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/trailing-first.trace" \
			git status --porcelain=v2 -- scoped/tracked/ \
				>.git/trailing-first.actual \
				2>.git/trailing-first.actual.err &&
		test_cmp .git/trailing-first.expect \
			.git/trailing-first.actual &&
		test_cmp .git/trailing-first.expect.err \
			.git/trailing-first.actual.err &&
		test_grep "could not open directory" \
			.git/trailing-first.actual.err &&
		test_trace2_data status fsmonitor/tracked-clean 1 \
			<.git/trailing-first.trace &&
		test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
			.git/trailing-first.trace &&
		test_grep ! "\"category\":\"index\",\"label\":\"preload\"" \
			.git/trailing-first.trace &&
		for label in repeat repeated
		do
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
				git status --porcelain=v2 -- tracked >.git/$label &&
			test_must_be_empty .git/$label &&
			test_trace2_data status fsmonitor/tracked-clean 1 \
				<.git/$label.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
				.git/$label.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"preload\"" \
				.git/$label.trace &&
			test_grep ! "\"label\":\"read_directory\"" \
				.git/$label.trace || return 1
		done &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 -- scoped \
				":(exclude)scoped/deep" >.git/directory-prime &&
		test_grep "^? scoped/new$" .git/directory-prime &&
		for label in directory directory-repeat mixed \
			excluded-glob excluded-icase
		do
			case "$label" in
			directory|directory-repeat) \
				set -- scoped ":(exclude)scoped/deep" ;;
			mixed) set -- tracked scoped ":(exclude)scoped/deep" ;;
			excluded-glob) \
				set -- scoped ":(exclude,glob)scoped/deep/**" ;;
			excluded-icase) \
				set -- scoped ":(exclude,icase)SCOPED/DEEP" ;;
			esac &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
				git status --porcelain=v2 -- "$@" >.git/$label &&
			test_grep "^? scoped/new$" .git/$label &&
			test_line_count = 1 .git/$label &&
			test_trace2_data status fsmonitor/tracked-clean 1 \
				<.git/$label.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
				.git/$label.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"preload\"" \
				.git/$label.trace &&
			test_grep "\"label\":\"read_directory\"" \
				.git/$label.trace || return 1
		done &&
		test_write_lines deep >scoped/deep/new &&
		for label in excluded-self excluded-all-files
		do
			query_sequence=CCCC &&
			case "$label" in
			excluded-self) query_sequence=DDCCC &&
				set -- scoped ":(exclude)scoped" ;;
			excluded-all-files) \
				set -- scoped/deep ":(exclude)scoped/deep/tracked" ;;
			esac &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=$query_sequence \
			GIT_TEST_FSMONITOR_QUERY_PATH=scoped/deep/new \
			GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
				git status --porcelain=v2 -- "$@" >.git/$label &&
			if test "$label" = excluded-self
			then
				test_must_be_empty .git/$label &&
				test_trace2_data fsmonitor apply_count 1 \
					<.git/$label.trace
			else
				test_grep "^? scoped/deep/new$" .git/$label &&
				test_line_count = 1 .git/$label
			fi &&
			test_trace2_data status fsmonitor/tracked-clean 1 \
				<.git/$label.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
				.git/$label.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"preload\"" \
				.git/$label.trace &&
			test_grep "\"label\":\"read_directory\"" \
				.git/$label.trace || return 1
		done &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 -- scoped/deep \
				>.git/deep-prime &&
		test_grep "^? scoped/deep/new$" .git/deep-prime &&
		for label in nested-directory nested-cwd
		do
			status_dir=. &&
			case "$label" in
			nested-directory) set -- scoped/deep/ ;;
			nested-cwd) status_dir=scoped/deep && set -- . ;;
			esac &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
				git -C "$status_dir" status --porcelain=v2 \
					-- "$@" >.git/$label &&
			if test "$label" = nested-cwd
			then
				test_grep "^? new$" .git/$label
			else
				test_grep "^? scoped/deep/new$" .git/$label
			fi &&
			test_line_count = 1 .git/$label &&
			test_trace2_data status fsmonitor/tracked-clean 1 \
				<.git/$label.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
				.git/$label.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"preload\"" \
				.git/$label.trace || return 1
		done &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 -- "track*" \
				>.git/root-wildcard-prime &&
		for label in wildcard wildcard-glob wildcard-deep \
			wildcard-mixed wildcard-excluded \
			wildcard-root wildcard-root-glob wildcard-root-question \
			wildcard-root-excluded untracked-exact untracked-missing \
			untracked-wildcard untracked-mixed nested-trailing
		do
			case "$label" in
			wildcard) set -- "scoped/*" ;;
			wildcard-glob) set -- ":(glob)scoped/*" ;;
			wildcard-deep) set -- "scoped/deep/trac*" ;;
			wildcard-mixed) set -- tracked "scoped/*" ;;
			wildcard-excluded) \
				set -- "scoped/*" ":(exclude)scoped/deep" ;;
			wildcard-root) set -- "track*" ;;
			wildcard-root-glob) set -- ":(glob)track*" ;;
			wildcard-root-question) set -- "track?*" ;;
			wildcard-root-excluded) \
				set -- "track*" ":(exclude)tracked-extra" ;;
			untracked-exact) set -- scoped/new ;;
			untracked-missing) set -- missing ;;
			untracked-wildcard) set -- "missing-*" ;;
			untracked-mixed) set -- tracked scoped/new ;;
			nested-trailing) set -- scoped/tracked/ ;;
			esac &&
			GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
				-c core.untrackedCache=false status \
				--porcelain=v2 -- "$@" >.git/$label.expect \
					2>.git/$label.expect.err &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
				git status --porcelain=v2 -- "$@" \
					>.git/$label.actual 2>.git/$label.actual.err &&
			test_cmp .git/$label.expect .git/$label.actual &&
			test_cmp .git/$label.expect.err .git/$label.actual.err &&
			test_trace2_data status fsmonitor/tracked-clean 1 \
				<.git/$label.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
				.git/$label.trace &&
			test_grep ! "\"category\":\"index\",\"label\":\"preload\"" \
				.git/$label.trace &&
			test_grep "\"label\":\"read_directory\"" \
				.git/$label.trace || return 1
		done &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/visible.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/visible.actual &&
		test_cmp .git/visible.expect .git/visible.actual &&
		test_grep "^? scoped/new$" .git/visible.actual
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'explicit all-untracked status retains configured normal history' '
	test_when_finished "rm -rf explicit-all-untracked-history" &&
	test_create_repo explicit-all-untracked-history &&
	(
		cd explicit-all-untracked-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		mkdir scoped &&
		test_commit nested scoped/tracked &&
		test-tool chmtime -120 tracked scoped/tracked &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		for label in first second third
		do
			GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
				-c core.untrackedCache=false status \
				--porcelain=v2 --untracked-files=all \
					>.git/$label.expect &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
				git status --porcelain=v2 --untracked-files=all \
					>.git/$label.actual &&
			test_cmp .git/$label.expect .git/$label.actual &&
			if test "$label" != first
			then
				test_trace2_data status fsmonitor/tracked-clean 1 \
					<.git/$label.trace &&
				test_grep ! "\"label\":\"do_write_index\"" \
					.git/$label.trace &&
				test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
					.git/$label.trace
			fi || return 1
		done &&
		test_write_lines outside >outside-new &&
		test_write_lines nested >scoped/new &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status \
			--porcelain=v2 --untracked-files=all \
				>.git/visible.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=scoped/new \
			git status --porcelain=v2 --untracked-files=all \
				>.git/visible.actual &&
		test_cmp .git/visible.expect .git/visible.actual &&
		test_grep "^? outside-new$" .git/visible.actual &&
		test_grep "^? scoped/new$" .git/visible.actual
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'ignored submodule pathspecs avoid needless tracked refresh' '
	test_when_finished "rm -rf ignored-submodule-proof" &&
	test_create_repo ignored-submodule-proof &&
	(
		cd ignored-submodule-proof &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit root tracked &&
		git init -q child &&
		git -C child config user.name "Submodule Fixture" &&
		git -C child config user.email fixture@example.invalid &&
		test_write_lines original >child/tracked &&
		git -C child add tracked &&
		git -C child commit -qm base &&
		git add child &&
		git commit -qm "add child gitlink" &&
		test-tool chmtime -120 tracked &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		for label in prime repeat
		do
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
				git status --porcelain=v2 \
					--ignore-submodules=all -- child \
					>.git/$label || return 1
		done &&
		for label in clean dirty committed staged
		do
			case "$label" in
			dirty) test_write_lines modified >child/tracked ;;
			committed)
				git -C child add tracked &&
				git -C child commit -qm changed ;;
			staged)
				git add child &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
					git status --porcelain=v2 \
						--ignore-submodules=all -- child \
						>.git/staged-prime ;;
			esac &&
			for shape in scoped root
			do
				if test "$shape" = scoped
				then
					set -- -- child
				else
					set --
				fi &&
				GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
					-c core.untrackedCache=false status \
					--porcelain=v2 --ignore-submodules=all "$@" \
						>.git/$label-$shape.expect &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
				GIT_TRACE2_EVENT="$PWD/.git/$label-$shape.trace" \
					git status --porcelain=v2 \
						--ignore-submodules=all "$@" \
						>.git/$label-$shape.actual &&
				test_cmp .git/$label-$shape.expect \
					.git/$label-$shape.actual &&
				if test "$label" != staged || test "$shape" != root
				then
					test_trace2_data status fsmonitor/tracked-clean 1 \
						<.git/$label-$shape.trace &&
					test_grep ! \
						"\"category\":\"index\",\"label\":\"refresh\"" \
						.git/$label-$shape.trace &&
					test_grep ! \
						"\"category\":\"index\",\"label\":\"preload\"" \
						.git/$label-$shape.trace
				fi || return 1
			done || return 1
		done &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status \
			--porcelain=v2 --ignore-submodules=none -- child \
				>.git/visible.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 \
				--ignore-submodules=none -- child \
				>.git/visible.actual &&
		test_cmp .git/visible.expect .git/visible.actual
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'tracked-directory pathspec reads a closed untracked-cache subtree' '
	test_when_finished "rm -rf pathspec-cached-subtree" &&
	test_create_repo pathspec-cached-subtree &&
	(
		cd pathspec-cached-subtree &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		mkdir scoped scope scoped-extra aaa zzz &&
		test_commit selected scoped/tracked &&
		test_commit prefix scope/tracked &&
		test_commit extended scoped-extra/tracked &&
		test_commit before aaa/tracked &&
		test_commit after zzz/tracked &&
		test-tool chmtime -120 tracked scoped/tracked scope/tracked \
			scoped-extra/tracked aaa/tracked zzz/tracked &&
		git update-index --refresh &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		test_write_lines selected >scoped/new &&
		test_write_lines outside >outside-new &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/root &&
		test_grep "^? scoped/new$" .git/root &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/root-repeat &&
		cp .git/index .git/before &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/scoped.trace" \
			git status --porcelain=v2 -- scoped >.git/scoped &&
		test_grep "^? scoped/new$" .git/scoped &&
		test_grep ! "outside-new" .git/scoped &&
		test_cmp .git/before .git/index &&
		test_trace2_data status untracked/pathspec-cache 1 \
			<.git/scoped.trace &&
		test_grep ! "\"label\":\"read_directory\"" \
			.git/scoped.trace &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/nested.trace" \
			git -C scoped status --porcelain=v2 -- . >.git/nested &&
		test_grep "^? new$" .git/nested &&
		test_trace2_data status untracked/pathspec-cache 1 \
			<.git/nested.trace &&
		for label in tracked-file nested-file tracked-files nested-files \
			root-trailing root-trailing-glob root-trailing-nested \
			root-trailing-top root-trailing-top-nested \
			excluded excluded-self excluded-first \
			glob glob-nested glob-excluded \
			excluded-wildcard excluded-icase excluded-attr \
			all ignored ignored-matching
		do
			status_dir=. &&
			case "$label" in
			tracked-file) set -- -- scoped/tracked ;;
			nested-file) status_dir=scoped && set -- -- tracked ;;
			tracked-files) set -- -- tracked scoped/tracked ;;
			nested-files) status_dir=scoped && \
				set -- -- tracked ../tracked ;;
			root-trailing) set -- -- tracked/ ;;
			root-trailing-glob) set -- -- ":(glob)tracked/" ;;
			root-trailing-nested) status_dir=scoped && \
				set -- -- ../tracked/ ;;
			root-trailing-top) set -- -- ":(top,literal)tracked//" ;;
			root-trailing-top-nested) status_dir=scoped && \
				set -- -- ":(top)tracked//" ;;
			excluded) set -- -- tracked ":(exclude)scoped/tracked" ;;
			excluded-self) set -- -- tracked ":(exclude)tracked" ;;
			excluded-first) set -- -- ":(exclude)scoped/tracked" tracked ;;
			glob) set -- -- ":(glob)tracked" ;;
			glob-nested) set -- -- ":(glob)scoped/tracked" ;;
			glob-excluded) set -- -- ":(glob)tracked" \
				":(exclude,glob)scoped/tracked" ;;
			excluded-wildcard) set -- -- tracked \
				":(exclude,glob)scoped/*" ;;
			excluded-icase) set -- -- tracked \
				":(exclude,icase)SCOPED/TRACKED" ;;
			excluded-attr) set -- -- tracked \
				":(exclude,attr:proof)scoped/tracked" ;;
			all) set -- --untracked-files=all -- tracked scoped/tracked ;;
			ignored) set -- --ignored -- tracked scoped/tracked ;;
			ignored-matching) set -- --ignored=matching -- \
				tracked scoped/tracked ;;
			esac &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
				git -C "$status_dir" status --porcelain=v2 \
					"$@" >.git/$label &&
			test_must_be_empty .git/$label &&
			test_trace2_data status untracked/pathspec-cache 1 \
				<.git/$label.trace &&
			test_grep ! "\"label\":\"read_directory\"" \
				.git/$label.trace || return 1
		done &&
		for label in excluded-only glob-wildcard positive-icase \
			mixed-ignored mixed-untracked mixed-directory
		do
			expect_untracked=outside-new &&
			case "$label" in
			excluded-only) set -- -- ":(exclude)scoped/tracked" ;;
			glob-wildcard) set -- -- ":(glob)*" ;;
			positive-icase) set -- -- ":(icase)OUTSIDE-NEW" ;;
			mixed-ignored) expect_untracked=scoped/new && \
				set -- --ignored -- tracked scoped ;;
			mixed-untracked) set -- -- tracked outside-new ;;
			mixed-directory) expect_untracked=scoped/new && \
				set -- -- tracked scoped ;;
			esac &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
				git status --porcelain=v2 "$@" >.git/$label &&
			test_grep "^? $expect_untracked$" .git/$label &&
			test_grep "\"label\":\"read_directory\"" \
				.git/$label.trace || return 1
		done &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/nested-trailing.trace" \
			git status --porcelain=v2 -- scoped/tracked/ \
				>.git/nested-trailing \
				2>.git/nested-trailing.err &&
		test_must_be_empty .git/nested-trailing &&
		test_grep "could not open directory" \
			.git/nested-trailing.err &&
		test_grep "\"label\":\"read_directory\"" \
			.git/nested-trailing.trace &&
		test_env GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/nested-repeated.trace" \
			test_must_fail git status --porcelain=v2 -- \
				":(top)scoped//tracked" \
				>.git/nested-repeated 2>.git/nested-repeated.err &&
		test_grep "fatal: oops in prep_exclude" \
			.git/nested-repeated.err &&
		rm scoped/tracked &&
		mkdir scoped/tracked &&
		test_write_lines child >scoped/tracked/new &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			-- scoped/tracked >.git/tracked-file-dirty.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=scoped/tracked \
		GIT_TRACE2_EVENT="$PWD/.git/tracked-file-dirty.trace" \
			git status --porcelain=v2 -- scoped/tracked \
				>.git/tracked-file-dirty.actual &&
		test_cmp .git/tracked-file-dirty.expect \
			.git/tracked-file-dirty.actual &&
		test_grep "scoped/tracked" .git/tracked-file-dirty.actual &&
		test_grep "\"label\":\"read_directory\"" \
			.git/tracked-file-dirty.trace
	)
'

assert_clean_tracked_status () {
	label=$1 &&
	directory=$2 &&
	shift 2 &&
	GIT_OPTIONAL_LOCKS=0 \
		git -c core.fsmonitor=false \
			-c core.untrackedCache=false \
			-C "$directory" status "$@" >".git/$label.expect" &&
	GIT_OPTIONAL_LOCKS=0 \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
	GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
		git -C "$directory" status "$@" >".git/$label.actual" &&
	test_cmp_bin ".git/$label.expect" ".git/$label.actual" &&
	test_trace2_data status fsmonitor/tracked-clean 1 \
		<".git/$label.trace" &&
	test_trace2_data status index/cache-tree-match 1 \
		<".git/$label.trace" &&
	test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
		".git/$label.trace" &&
	test_grep ! "\"category\":\"index\",\"label\":\"preload\"" \
		".git/$label.trace"
}

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'tracked file pathspecs avoid traversal without an untracked cache' '
	test_when_finished "rm -rf pathspec-no-untracked-cache" &&
	test_create_repo pathspec-no-untracked-cache &&
	(
		cd pathspec-no-untracked-cache &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		mkdir scoped &&
		test_commit selected scoped/tracked &&
		test-tool chmtime -120 tracked scoped/tracked &&
		git update-index --refresh &&
		git config core.untrackedCache false &&
		git config core.fsmonitor true &&
		test_write_lines outside >outside-new &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor --no-untracked-cache &&
		test_grep ! UNTR .git/index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 --untracked-files=normal \
				>.git/prime &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 --untracked-files=normal \
				>.git/prime-repeat &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false status --porcelain=v2 \
					>.git/exact.expect &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/exact.trace" \
			git status --porcelain=v2 >.git/exact.actual &&
		test_cmp .git/exact.expect .git/exact.actual &&
		test_grep "^? outside-new$" .git/exact.actual &&
		test_trace2_data status fsmonitor/tracked-clean 1 \
			<.git/exact.trace &&
		test_grep ! "\"category\":\"index\",\"label\":\"refresh\"" \
			.git/exact.trace &&
		test_grep ! "\"category\":\"index\",\"label\":\"preload\"" \
			.git/exact.trace &&
		for label in one multiple excluded glob glob-excluded \
			excluded-special root-trailing root-trailing-top
		do
			case "$label" in
			one) set -- scoped/tracked ;;
			multiple) set -- tracked scoped/tracked ;;
			excluded) set -- tracked ":(exclude)scoped/tracked" ;;
			glob) set -- ":(glob)scoped/tracked" ;;
			glob-excluded) set -- ":(glob)tracked" \
				":(exclude,glob)scoped/tracked" ;;
			excluded-special) set -- tracked \
				":(exclude,glob)scoped/*" \
				":(exclude,icase)SCOPED/TRACKED" \
				":(exclude,attr:proof)scoped/tracked" ;;
			root-trailing) set -- tracked/ ;;
			root-trailing-top) set -- ":(top,literal)tracked//" ;;
			esac &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/$label.trace" \
				git status --porcelain=v2 -- "$@" >.git/$label &&
			test_must_be_empty .git/$label &&
			test_trace2_data status fsmonitor/tracked-clean 1 \
				<.git/$label.trace &&
			test_trace2_data status untracked/pathspec-cache 1 \
				<.git/$label.trace &&
			test_grep ! "\"label\":\"read_directory\"" \
				.git/$label.trace || return 1
		done &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/mixed.trace" \
			git status --porcelain=v2 -- tracked outside-new \
				>.git/mixed &&
		test_grep "^? outside-new$" .git/mixed &&
		test_grep "\"label\":\"read_directory\"" .git/mixed.trace &&
		test_write_lines changed >scoped/tracked &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/closing-dirty.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CDCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=scoped/tracked \
		GIT_TRACE2_EVENT="$PWD/.git/closing-dirty.trace" \
			git status --porcelain=v2 >.git/closing-dirty.actual &&
		test_cmp .git/closing-dirty.expect .git/closing-dirty.actual &&
		test_grep "^1 \\.M .* scoped/tracked$" \
			.git/closing-dirty.actual &&
		test_grep "^? outside-new$" .git/closing-dirty.actual &&
		test_grep ! "\"key\":\"fsmonitor/tracked-clean\"" \
			.git/closing-dirty.trace &&
		test_grep "\"category\":\"index\",\"label\":\"refresh\"" \
			.git/closing-dirty.trace &&
		test_write_lines selected >scoped/tracked &&
		test-tool chmtime -120 scoped/tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=scoped/tracked \
			git update-index --refresh &&
		rm outside-new &&
		git config core.preloadIndex false &&
		for label in prime prime-repeat
		do
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
				git status --porcelain=v2 \
					--untracked-files=normal >.git/clean-$label &&
			test_must_be_empty .git/clean-$label || return 1
		done &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/clean-issue.trace" \
			git status --porcelain=v2 >.git/clean-issue &&
		test_must_be_empty .git/clean-issue &&
		if test_have_prereq MACOS
		then
			test_trace2_data status clean-proof/sidecar 1 \
				<.git/clean-issue.trace &&
			test_path_is_file .git/index.csts &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/clean-hit.trace" \
				git status --porcelain=v2 >.git/clean-hit &&
			test_must_be_empty .git/clean-hit &&
			test_trace2_data status clean-proof/hit 1 \
				<.git/clean-hit.trace &&
			test_grep ! "\"label\":\"do_read_index\"" \
				.git/clean-hit.trace
		fi
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'clean tracked entries avoid refresh across dirty status shapes' '
	test_when_finished "rm -rf tracked-clean-status-shapes" &&
	test_create_repo tracked-clean-status-shapes &&
	(
		cd tracked-clean-status-shapes &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		mkdir scoped scoped-extra sibling &&
		test_commit selected scoped/tracked &&
		test_commit colliding scoped-extra/tracked &&
		test_commit other sibling/tracked &&
		test-tool chmtime -120 \
			tracked scoped/tracked scoped-extra/tracked sibling/tracked &&
		git update-index --refresh &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		test_write_lines selected >scoped/new &&
		test_write_lines sibling >sibling/new &&
		test_write_lines outside >outside-new &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_grep "^? scoped/new$" .git/prime &&
		test_grep "^? sibling/new$" .git/prime &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime-repeat &&
		test_cmp .git/prime .git/prime-repeat &&
		test_path_is_missing .git/index.csts &&

		assert_clean_tracked_status root-long . &&
		assert_clean_tracked_status root-short . --short &&
		assert_clean_tracked_status root-porcelain . --porcelain &&
		assert_clean_tracked_status root-v2-exact . --porcelain=v2 &&
		assert_clean_tracked_status root-v2 . \
			--porcelain=v2 --untracked-files=normal &&
		assert_clean_tracked_status root-daemon . \
			--porcelain=v2 -z --branch --show-stash \
			--no-ahead-behind --untracked-files=normal \
			--ignore-submodules=all &&
		assert_clean_tracked_status scoped-long . -- scoped &&
		assert_clean_tracked_status scoped-v2 . \
			--porcelain=v2 -- scoped &&
		assert_clean_tracked_status sibling-v2 . \
			--porcelain=v2 -- sibling &&
		assert_clean_tracked_status nested-root scoped \
			--porcelain=v2 --untracked-files=normal &&
		assert_clean_tracked_status nested-scoped scoped \
			--porcelain=v2 -- . &&
		assert_clean_tracked_status multiple-v2 . \
			--porcelain=v2 -- scoped sibling &&
		test_grep "^? scoped/new$" .git/scoped-v2.actual &&
		test_grep ! "sibling/new\|outside-new" \
			.git/scoped-v2.actual &&
		test_grep "^? sibling/new$" .git/sibling-v2.actual &&
		test_grep ! "scoped/new\|outside-new" \
			.git/sibling-v2.actual &&
		test_grep "^? new$" .git/nested-scoped.actual &&
		test_trace2_data status untracked/pathspec-cache 1 \
			<.git/scoped-v2.trace &&
		test_trace2_data status untracked/pathspec-cache 1 \
			<.git/sibling-v2.trace &&
		test_trace2_data status untracked/pathspec-cache 1 \
			<.git/nested-scoped.trace &&

		test_write_lines changed >scoped/tracked &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/closing-dirty.expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CDCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=scoped/tracked \
		GIT_TRACE2_EVENT="$PWD/.git/closing-dirty.trace" \
			git status --porcelain=v2 >.git/closing-dirty.actual &&
		test_cmp .git/closing-dirty.expect .git/closing-dirty.actual &&
		test_grep "^1 \\.M .* scoped/tracked$" .git/closing-dirty.actual &&
		test_grep ! "\"key\":\"fsmonitor/tracked-clean\"" \
			.git/closing-dirty.trace &&

		test_write_lines changed >scoped/tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=scoped/tracked \
		GIT_TRACE2_EVENT="$PWD/.git/dirty-tracked.trace" \
			git status --porcelain=v2 -- scoped \
				>.git/dirty-tracked.actual &&
		test_grep "^1 \\.M .* scoped/tracked$" \
			.git/dirty-tracked.actual &&
		test_grep "^? scoped/new$" .git/dirty-tracked.actual &&
		test_grep ! "sibling/new\|outside-new" \
			.git/dirty-tracked.actual &&
		! test_trace2_data status fsmonitor/tracked-clean 1 \
			<.git/dirty-tracked.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'tracked-directory pathspec repairs changed untracked children' '
	test_when_finished "rm -rf pathspec-repaired-subtree" &&
	test_create_repo pathspec-repaired-subtree &&
	(
		cd pathspec-repaired-subtree &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		mkdir scoped outside &&
		test_commit selected scoped/tracked &&
		test_commit unrelated outside/tracked &&
		test_write_lines "*.ignored" >.gitignore &&
		test_write_lines "ignored-dir/" >scoped/.gitignore &&
		git add .gitignore scoped/.gitignore &&
		git commit -qm "add tracked ignore files" &&
		test-tool chmtime -120 tracked scoped/tracked outside/tracked \
			.gitignore scoped/.gitignore &&
		git update-index --refresh &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&

		test_write_lines created >scoped/new &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=scoped/new \
		GIT_TRACE2_EVENT_NESTING=5 \
		GIT_TRACE2_EVENT="$PWD/.git/created.trace" \
			git status --porcelain=v2 -- scoped >.git/created &&
		test_grep "^? scoped/new$" .git/created &&
		test_trace2_data status untracked/pathspec-refreshed 1 \
			<.git/created.trace &&
		test_trace2_data fsmonitor untracked/targeted-refresh 1 \
			<.git/created.trace &&
		test_trace2_data read_directory paths-visited 1 \
			<.git/created.trace &&
		test_trace2_data read_directory opendir 0 \
			<.git/created.trace &&
		test_grep ! "\"label\":\"read_directory\"" \
			.git/created.trace &&
		test_grep "\"label\":\"do_write_index\"" \
			.git/created.trace &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=scoped/new \
		GIT_TRACE2_EVENT_NESTING=5 \
		GIT_TRACE2_EVENT="$PWD/.git/created-repeat.trace" \
			git status --porcelain=v2 -- scoped >.git/created-repeat &&
		test_cmp .git/created .git/created-repeat &&
		test_grep ! "\"label\":\"do_write_index\"" \
			.git/created-repeat.trace &&

		rm scoped/new &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=scoped/new \
		GIT_TRACE2_EVENT_NESTING=5 \
		GIT_TRACE2_EVENT="$PWD/.git/removed.trace" \
			git status --porcelain=v2 -- scoped >.git/removed &&
		test_must_be_empty .git/removed &&
		test_trace2_data status untracked/pathspec-refreshed 1 \
			<.git/removed.trace &&
		test_trace2_data fsmonitor untracked/targeted-refresh 1 \
			<.git/removed.trace &&
		test_trace2_data read_directory paths-visited 1 \
			<.git/removed.trace &&
		test_trace2_data read_directory opendir 0 \
			<.git/removed.trace &&
		test_grep ! "\"label\":\"read_directory\"" \
			.git/removed.trace &&
		test_grep "\"label\":\"do_write_index\"" \
			.git/removed.trace &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT_NESTING=5 \
		GIT_TRACE2_EVENT="$PWD/.git/root-after-remove.trace" \
			git status --porcelain=v2 >.git/root-after-remove &&
		test_must_be_empty .git/root-after-remove &&
		test_grep ! "\"key\":\"gitignore-invalidation\",\"value\":\"[1-9]" \
			.git/root-after-remove.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'mixed reset to a same-tree commit preserves closed history' '
	test_when_finished "rm -rf reset-mixed-same-tree" &&
	test_create_repo reset-mixed-same-tree &&
	(
		cd reset-mixed-same-tree &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git commit --allow-empty -m same-tree &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test-tool chmtime +1 tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git reset --mixed HEAD^ >.git/reset &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'mixed reset drops history after a logical index change' '
	test_when_finished "rm -rf reset-mixed-changed" &&
	test_create_repo reset-mixed-changed &&
	(
		cd reset-mixed-changed &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test_write_lines staged >tracked &&
		git add tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/staged &&
		test_grep "^1 M\." .git/staged &&
		test_grep FSCF .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git reset --mixed HEAD >.git/reset &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "modified:.*tracked" .git/actual &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'hard reset to a same-tree commit preserves closed history' '
	test_when_finished "rm -rf reset-hard-same-tree" &&
	test_create_repo reset-hard-same-tree &&
	(
		cd reset-hard-same-tree &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git commit --allow-empty -m same-tree &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test_write_lines changed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git status >.git/dirty &&
		test_grep "modified:.*tracked" .git/dirty &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git reset --hard HEAD^ >.git/reset &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'hard reset to a different tree drops closed semantic history' '
	test_when_finished "rm -rf reset-hard-changed" &&
	test_create_repo reset-hard-changed &&
	(
		cd reset-hard-changed &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_write_lines next >tracked &&
		git add tracked &&
		git commit -m next &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git reset --hard HEAD^ >.git/reset &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 0 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'forced same-tree checkout preserves closed semantic history' '
	test_when_finished "rm -rf checkout-same-tree" &&
	test_create_repo checkout-same-tree &&
	(
		cd checkout-same-tree &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git branch same &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test_write_lines changed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git status >.git/dirty &&
		test_grep "modified:.*tracked" .git/dirty &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git checkout -f same >.git/checkout &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'one-tree read-tree reset preserves closed semantic history' '
	test_when_finished "rm -rf read-tree-reset-history" &&
	test_create_repo read-tree-reset-history &&
	(
		cd read-tree-reset-history &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		test_write_lines changed >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git status >.git/dirty &&
		test_grep "modified:.*tracked" .git/dirty &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git read-tree --reset -u HEAD >.git/read-tree &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status >.git/actual &&
		test_grep "nothing to commit, working tree clean" .git/actual &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace
	)
'

test_expect_success UNTRACKED_CACHE,HARDLINKS,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'a lost fsmonitor token reuses an authenticated external checkpoint' '
	test_when_finished "rm -rf missing-fsmonitor-token-checkpoint" &&
	test_create_repo missing-fsmonitor-token-checkpoint &&
	(
		cd missing-fsmonitor-token-checkpoint &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines "/ignored/" >.gitignore &&
		printf "aaaa\\n" >tracked &&
		git add .gitignore tracked &&
		git commit -m base &&
		mkdir ignored &&
		ln tracked ignored/alias &&
		test-tool chmtime -120 tracked .gitignore &&
		git update-index --refresh &&
		git config core.autocrlf false &&
		git config core.trustctime true &&
		git config core.checkStat default &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/materialized &&
		test_must_be_empty .git/materialized &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/checkpoint.trace" \
			git status --porcelain=v2 >.git/checkpoint &&
		test_must_be_empty .git/checkpoint &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<.git/checkpoint.trace &&
		git -c core.fsmonitor=false update-index \
			--no-fsmonitor --force-write-index &&
		test_grep ! FSMN .git/index &&
		test_grep FSCF .git/index &&
		cp .git/index .git/missing.index &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/clean.expect &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/clean.trace" \
			git status --porcelain=v2 >.git/clean.actual &&
		test_cmp .git/clean.expect .git/clean.actual &&
		test_trace2_data fsmonitor history/external-fsmn-recovered 1 \
			<.git/clean.trace &&
		test_trace2_data fsmonitor history/external-restored 1 \
			<.git/clean.trace &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/clean.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/clean.trace &&
		! test_trace2_data fsmonitor semantic/token-reset-stat-baseline 1 \
			<.git/clean.trace &&

		mtime=$(test-tool chmtime --get tracked) &&
		printf "bbbb\\n" >ignored/alias &&
		test-tool chmtime =$mtime ignored/alias &&
		test "$(git hash-object tracked)" != \
			"$(git rev-parse HEAD:tracked)" &&
		cp .git/missing.index .git/index &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=ignored/alias \
		GIT_TRACE2_EVENT="$PWD/.git/dirty.trace" \
			git status --porcelain=v2 >.git/dirty.actual &&
		test_grep "^1 \\.M .* tracked$" .git/dirty.actual
	)
'

test_expect_success UNTRACKED_CACHE,HARDLINKS,PERL,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'a lost token never trusts an unwatched tracked hardlink' '
	test_when_finished \
		"rm -rf missing-fsmonitor-token-hardlink missing-fsmonitor-token.alias" &&
	test_create_repo missing-fsmonitor-token-hardlink &&
	(
		cd missing-fsmonitor-token-hardlink &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		printf "aaaa\\n" >tracked &&
		test_write_lines stable >sibling &&
		git add tracked sibling &&
		git commit -m base &&
		ln tracked ../missing-fsmonitor-token.alias &&
		test-tool chmtime -120 tracked sibling &&
		git update-index --refresh &&
		git config core.trustctime true &&
		git config core.checkStat default &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSMN .git/index &&
		test_grep FSCF .git/index &&
		rm -f .git/index.csh1.* .git/index.cswi.* .git/index.csts &&
		git -c core.fsmonitor=false update-index \
			--no-fsmonitor --force-write-index &&
		test_grep ! FSMN .git/index &&
		test_grep FSCF .git/index &&
		mtime=$(test-tool chmtime --get tracked) &&
		for attempt in 1 2 3 4 5
		do
			printf "aaaa\\n" \
				>../missing-fsmonitor-token.alias &&
			test-tool chmtime =$mtime \
				../missing-fsmonitor-token.alias &&
			git -c core.fsmonitor=false update-index \
				--refresh --force-write-index &&
			test_grep ! FSMN .git/index &&
			test_grep FSCF .git/index &&
			ctime=$(perl -e "print((stat(shift))[10])" tracked) &&
			printf "bbbb\\n" \
				>../missing-fsmonitor-token.alias &&
			test-tool chmtime =$mtime \
				../missing-fsmonitor-token.alias &&
			if test "$(perl -e "print((stat(shift))[10])" tracked)" = \
				"$ctime"
			then
				break
			fi || return 1
		done &&
		test "$(perl -e "print((stat(shift))[10])" tracked)" = \
			"$ctime" &&
		test "$(git hash-object tracked)" != \
			"$(git rev-parse HEAD:tracked)" &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/recovery.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_grep "^1 \\.M .* tracked$" .git/actual &&
		test_line_count = 1 .git/actual &&
		test_trace2_data fsm_client query/trivial-response 1 \
			<.git/recovery.trace &&
		test_trace2_data fsmonitor semantic/token-reset-stat-baseline 1 \
			<.git/recovery.trace &&
		! test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/recovery.trace
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'a missing fsmonitor token reuses strong tracked-file stat identities' '
	test_when_finished "rm -rf missing-fsmonitor-token-strong" &&
	test_create_repo missing-fsmonitor-token-strong &&
	(
		cd missing-fsmonitor-token-strong &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test-tool chmtime -120 tracked &&
		git update-index --refresh &&
		git config core.trustctime true &&
		git config core.checkStat default &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSMN .git/index &&
		test_grep FSCF .git/index &&
		rm -f .git/index.csh1.* .git/index.cswi.* .git/index.csts &&
		git -c core.fsmonitor=false update-index \
			--no-fsmonitor --force-write-index &&
		test_grep ! FSMN .git/index &&
		test_grep FSCF .git/index &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/recovery.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_trace2_data fsmonitor semantic/token-reset-stat-baseline 1 \
			<.git/recovery.trace &&
		test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/recovery.trace &&
		! test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/recovery.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/recovery.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/recovery.trace &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<.git/recovery.trace
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'a missing fsmonitor token cannot trust weak tracked-file identities' '
	test_when_finished "rm -rf missing-fsmonitor-token-weak" &&
	test_create_repo missing-fsmonitor-token-weak &&
	(
		cd missing-fsmonitor-token-weak &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		printf "aaaa\\n" >tracked &&
		git add tracked &&
		git commit -m base &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		test-tool chmtime =-60 tracked &&
		git update-index --refresh &&
		mtime=$(test-tool chmtime --get tracked) &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&
		rm -f .git/index.csh1.* .git/index.cswi.* .git/index.csts &&
		git -c core.fsmonitor=false update-index \
			--no-fsmonitor --force-write-index &&
		test_grep ! FSMN .git/index &&
		test_grep FSCF .git/index &&
		printf "bbbb\\n" >tracked &&
		test-tool chmtime =$mtime tracked &&
		test "$(git hash-object tracked)" != \
			"$(git rev-parse HEAD:tracked)" &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/recovery.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_grep "^1 \\.M .* tracked$" .git/actual &&
		! test_trace2_data fsmonitor semantic/token-reset-stat-baseline 1 \
			<.git/recovery.trace &&
		test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/recovery.trace
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'missing semantic history seeds a forward baseline' '
	test_when_finished \
		"stop_daemon_delete_repo missing-semantic-baseline" &&
	test_create_repo missing-semantic-baseline &&
	(
		cd missing-semantic-baseline &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor-valid tracked &&
		test_grep ! FSCF .git/index &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		test_grep FSCF .git/index &&
		test_trace2_data fsmonitor semantic/adoption-baseline 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/status.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'missing semantic history with weak stat identity forces content verification' '
	test_when_finished \
		"stop_daemon_delete_repo missing-semantic-history" &&
	test_create_repo missing-semantic-history &&
	(
		cd missing-semantic-history &&
		printf "aaaa\n" >tracked &&
		git add tracked &&
		git commit -m base &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		test-tool chmtime =-60 tracked &&
		git update-index --refresh &&
		mtime=$(test-tool chmtime --get tracked) &&
		printf "bbbb\n" >tracked &&
		test-tool chmtime =$mtime tracked &&
		git config core.fsmonitor true &&
		git update-index --fsmonitor &&
		git update-index --fsmonitor-valid tracked &&
		test_grep FSMN .git/index &&
		test_grep ! FSCF .git/index &&
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_line_count = 1 .git/actual &&
		test_grep "^1 \.M .* tracked$" .git/actual &&
		test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/status.trace
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'token closure refresh starts inside its proof epoch' '
	test_when_finished "rm -rf proof-epoch-refresh" &&
	test_create_repo proof-epoch-refresh &&
	(
		cd proof-epoch-refresh &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&

		# Leave the next refresh with untracked history to bootstrap.
		git update-index --no-untracked-cache 2>.git/no-uc.err &&
		test_grep FSCF .git/index &&
		test_grep ! FSUC .git/index &&

		test_env GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			test_must_fail git commit --dry-run --porcelain \
			>.git/actual &&
		test_must_be_empty .git/actual &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		captured=$(test_grep -n \
			"\"key\":\"semantic/proof-epoch-captured\"" \
			.git/status.trace | sed -n "1s/:.*//p") &&
		refreshed=$(test_grep -n \
			"\"category\":\"index\",\"label\":\"refresh\"" \
			.git/status.trace | sed -n "\$s/:.*//p") &&
		test -n "$captured" &&
		test -n "$refreshed" &&
		test "$captured" -lt "$refreshed"
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'trivial query closes zero-trailer unbound history' '
	test_when_finished "rm -rf unbound-trivial" &&
	test_create_repo unbound-trivial &&
	(
		cd unbound-trivial &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config index.version 4 &&
		git config feature.manyFiles true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			test-tool read-cache --test-fscf-round-trip &&
		test_grep FSMN .git/index &&
		test_grep FSCF .git/index &&
		test_trailing_hash .git/index >.git/index.hash &&
		test_oid zero >.git/zero &&
		test_cmp .git/zero .git/index.hash &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TC \
		GIT_TRACE2_EVENT="$PWD/.git/recovery.trace" \
			git status \
			>.git/recovery.out &&
		test_grep "nothing to commit, working tree clean" \
			.git/recovery.out &&
		test_trace2_data fsm_client query/trivial-response 1 \
			<.git/recovery.trace &&
		test_trace2_data fsmonitor semantic/manifest-scan-count \
			"[1-9]" <.git/recovery.trace &&
		test_trace2_data fsmonitor semantic/proof-epoch-captured 1 \
			<.git/recovery.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/recovery.trace &&
		! test_trace2_data fsmonitor token_closure/rejected 1 \
			<.git/recovery.trace &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CC \
		GIT_TRACE2_EVENT="$PWD/.git/warm.trace" \
			git status \
			>.git/warm.out &&
		test_grep "nothing to commit, working tree clean" \
			.git/warm.out &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/warm.trace &&
		! test_trace2_data index refresh/sum_lstat \
			"[1-9][0-9]*" <.git/warm.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count \
			"[1-9]" <.git/warm.trace &&
		! test_trace2_data fsm_client query/trivial-response 1 \
			<.git/warm.trace &&
		! test_trace2_data fsmonitor token_closure/rejected 1 \
			<.git/warm.trace
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'configured unused filters establish scoped history' '
	test_when_finished "rm -rf configured-filter" &&
	test_create_repo configured-filter &&
	(
		cd configured-filter &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		git config filter.demo.clean cat &&
		git config core.preloadIndexBulk true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&

		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/filter-scope.trace" \
			git status --porcelain=v2 --untracked-files=no \
			>.git/filter-scope.out &&
		test_must_be_empty .git/filter-scope.out &&
		test_trace2_data status semantic_verify/prepared 1 \
			<.git/filter-scope.trace &&
		! test_trace2_data status semantic_verify/bulk_scan 1 \
			<.git/filter-scope.trace &&
		test_trace2_data semantic_verify active-filters 0 \
			<.git/filter-scope.trace &&
		test_trace2_data semantic_verify filter-scope-checked 1 \
			<.git/filter-scope.trace &&
		test_trace2_data fsmonitor filter-scope/valid 1 \
			<.git/filter-scope.trace &&
		test_grep FSCF .git/index &&

		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
		GIT_TRACE2_EVENT="$PWD/.git/warm-filter-scope.trace" \
			git status --porcelain=v2 --untracked-files=no \
			>.git/warm-filter-scope.out &&
		test_must_be_empty .git/warm-filter-scope.out &&
		test_trace2_data fsmonitor config/coherent 1 \
			<.git/warm-filter-scope.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/warm-filter-scope.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count \
			"[1-9][0-9]*" <.git/warm-filter-scope.trace &&
		! test_trace2_data index refresh/sum_lstat \
			"[1-9][0-9]*" <.git/warm-filter-scope.trace &&

		test_write_lines "tracked filter=demo" >.git/info/attributes &&
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/active-filter.trace" \
			git status --porcelain=v2 --untracked-files=no \
			>.git/active-filter.out &&
		test_must_be_empty .git/active-filter.out &&
		test_trace2_data status semantic_verify/prepared 1 \
			<.git/active-filter.trace &&
		test_trace2_data semantic_verify active-filters 1 \
			<.git/active-filter.trace &&
		test_trace2_data semantic_verify filter-scope-rejected 1 \
			<.git/active-filter.trace &&
		! test_trace2_data fsmonitor filter-scope/valid 1 \
			<.git/active-filter.trace
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'sparse index rebuilds semantic history without expansion' '
	test_when_finished "rm -rf sparse-semantic" &&
	test_create_repo sparse-semantic &&
	(
		cd sparse-semantic &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir in outside &&
		printf "aaaa\n" >in/tracked &&
		printf "outside\n" >outside/file &&
		git add . &&
		git commit -m base &&
		git sparse-checkout set --cone --sparse-index in &&
		git ls-files --sparse >.git/sparse.before &&
		test_grep "^outside/$" .git/sparse.before &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		git config core.untrackedCache true &&
		test-tool chmtime =-60 in/tracked &&
		git update-index --refresh &&
		mtime=$(test-tool chmtime --get in/tracked) &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCC \
		GIT_TRACE2_EVENT="$PWD/.git/prime.trace" \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_trace2_data fsm_client query/trivial-response 1 \
			<.git/prime.trace &&
		test_trace2_data fsmonitor semantic/manifest-scan-count \
			"[1-9]" <.git/prime.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/prime.trace &&
		test_grep FSMN .git/index &&
		git -c core.fsmonitor=false ls-files --sparse \
			>.git/sparse.after-prime &&
		test_grep "^outside/$" .git/sparse.after-prime &&
		printf "bbbb\n" >in/tracked &&
		test-tool chmtime =$mtime in/tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=D \
		GIT_TEST_FSMONITOR_QUERY_PATH=in/tracked \
		GIT_TRACE2_EVENT="$PWD/.git/change.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_grep "^1 \.M .* in/tracked$" .git/actual &&
		test_trace2_data fsmonitor apply_count 1 \
			<.git/change.trace &&
		test_grep FSMN .git/index &&
		git -c core.fsmonitor=false ls-files --sparse \
			>.git/sparse.after-change &&
		test_grep "^outside/$" .git/sparse.after-change
	)
'

prepare_semantic_untracked_repo () {
	r=$1 &&
	test_create_repo "$r" &&
	(
		cd "$r" &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir cached &&
		test_write_lines "*.ignored" >.gitignore &&
		test_write_lines "*.ignored" >cached/.gitignore &&
		printf "aaaa\n" >cached/tracked &&
		printf "cccc\n" >cached/hook-tracked &&
		git add .gitignore cached/.gitignore cached/hook-tracked \
			cached/tracked &&
		git commit -m base &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		git config core.untrackedCache true &&
		test_write_lines ignored >cached/junk.ignored &&
		git status --porcelain=v2 >.git/prime.actual &&
		test_must_be_empty .git/prime.actual &&
		test_grep UNTR .git/index &&
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
		test_grep FSMN .git/index &&
		test_grep ! FSCF .git/index
	)
}

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'semantic adoption closes the untracked scan' '
	test_when_finished "rm -rf semantic-untracked" &&
	prepare_semantic_untracked_repo semantic-untracked &&
	(
		cd semantic-untracked &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_line_count = 1 .git/actual &&
		test_grep "^1 \.M .* cached/tracked$" .git/actual &&
		test_trace2_data status fsmonitor_token/untracked-deferred 1 \
			<.git/status.trace &&
		test_trace2_data status fsmonitor_token/semantic-closed 1 \
			<.git/status.trace &&
		test_trace2_data status \
			fsmonitor_token/untracked-after-semantic 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/apply_count \
			"[0-9][0-9]*" <.git/status.trace >.git/apply-count &&
		test_line_count = 2 .git/apply-count &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'failed untracked closure discards semantic adoption' '
	test_when_finished "rm -rf failed-semantic-untracked" &&
	prepare_semantic_untracked_repo failed-semantic-untracked &&
	(
		cd failed-semantic-untracked &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		GIT_DISABLE_UNTRACKED_CACHE=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_line_count = 1 .git/actual &&
		test_grep "^1 \.M .* cached/tracked$" .git/actual &&
		test_trace2_data status fsmonitor_token/semantic-closed 1 \
			<.git/status.trace &&
		test_trace2_data status \
			fsmonitor_token/untracked-after-semantic 0 \
			<.git/status.trace &&
		test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/status.trace >.git/strong-invalidations &&
		test_line_count = 2 .git/strong-invalidations &&
		test_trace2_data fsmonitor token_closure/rejected 1 \
			<.git/status.trace &&
		! test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep ! FSCF .git/index
	)
'

test_expect_success UNTRACKED_CACHE,!MINGW,!CYGWIN \
	'commit closes hook changes without an untracked cache' '
	test_when_finished "rm -rf commit-hook-closure" &&
	prepare_semantic_untracked_repo commit-hook-closure &&
	(
		cd commit-hook-closure &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git config core.untrackedCache false &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --no-untracked-cache &&
		test_grep ! UNTR .git/index &&
		write_script .git/hooks/pre-commit <<-\EOF &&
		mtime=$(test-tool chmtime --get cached/hook-tracked) &&
		printf "dddd\n" >cached/hook-tracked &&
		test-tool chmtime =$mtime cached/hook-tracked
		EOF
		GIT_EDITOR=: \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCDC \
		GIT_TEST_FSMONITOR_QUERY_PATH=cached/hook-tracked \
		GIT_TRACE2_EVENT="$PWD/.git/commit.trace" \
			git commit --allow-empty --edit -m adoption &&
		test_trace2_data status fsmonitor_token/semantic-closed 1 \
			<.git/commit.trace &&
		test_trace2_data fsmonitor token_closure/apply_count "[1-9]" \
			<.git/commit.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/commit.trace >.git/accepted &&
		test_line_count = 2 .git/accepted &&
		test_grep FSCF .git/index &&
		test_grep ! FSUC .git/index &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/status.actual &&
		test_grep "^1 \.M .* cached/hook-tracked$" \
			.git/status.actual &&
		test_grep ! UNTR .git/index
	)
'

test_expect_success UNTRACKED_CACHE,!MINGW,!CYGWIN \
	'failed hook closure refreshes the worktree' '
	test_when_finished "rm -rf commit-hook-fallback" &&
	prepare_semantic_untracked_repo commit-hook-fallback &&
	(
		cd commit-hook-fallback &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		write_script .git/hooks/pre-commit <<-\EOF &&
		mtime=$(test-tool chmtime --get cached/hook-tracked) &&
		printf "dddd\n" >cached/hook-tracked &&
		test-tool chmtime =$mtime cached/hook-tracked
		EOF
		GIT_EDITOR=: \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCE \
		GIT_TRACE2_EVENT="$PWD/.git/commit.trace" \
			git commit --allow-empty --edit -m adoption &&
		test_trace2_data fsmonitor token_closure/rejected 1 \
			<.git/commit.trace &&
		test_trace2_data status count/changed 2 <.git/commit.trace &&
		test_grep "cached/hook-tracked$" .git/COMMIT_EDITMSG &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/status.actual &&
		test_grep "cached/hook-tracked$" .git/status.actual
	)
'

test_expect_success UNTRACKED_CACHE,!MINGW,!CYGWIN \
	'post-hook refresh preserves hook index updates' '
	test_when_finished "rm -rf commit-hook-index" &&
	prepare_semantic_untracked_repo commit-hook-index &&
	(
		cd commit-hook-index &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		write_script .git/hooks/pre-commit <<-\EOF &&
		printf "hook update\n" >cached/hook-tracked &&
		oid=$(git hash-object -w cached/hook-tracked) &&
		git update-index --cacheinfo \
			100644,$oid,cached/hook-tracked
		EOF
		GIT_EDITOR=: \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git commit --allow-empty --edit -m adoption &&
		printf "hook update\n" >expect &&
		git show HEAD:cached/hook-tracked >actual &&
		test_cmp expect actual
	)
'

prepare_deleted_attribute_repo () {
	test_create_repo "$1" &&
	(
		cd "$1" &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir scoped sibling &&
		test_write_lines "*.txt -text" >.gitattributes &&
		test_write_lines "*.txt -text" >scoped/.gitattributes &&
		test_write_lines root >tracked.txt &&
		test_write_lines scoped >scoped/tracked.txt &&
		test_write_lines sibling >sibling/tracked.txt &&
		git add .gitattributes scoped sibling tracked.txt &&
		git commit -qm base &&
		git config core.autocrlf false &&
		git config core.trustctime true &&
		git config core.checkStat default &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index
	)
}

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'deleting identical tracked attributes preserves root and nested proofs' '
	test_when_finished "rm -rf deleted-attributes-root deleted-attributes-nested" &&
	for scope in root nested
	do
		repo=deleted-attributes-$scope &&
		prepare_deleted_attribute_repo "$repo" &&
		(
			cd "$repo" &&
			if test "$scope" = root
			then
				path=.gitattributes
			else
				path=scoped/.gitattributes
			fi &&
			rm "$path" &&
			GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
				-c core.untrackedCache=false status --porcelain=v2 \
				>.git/expect &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH="$path" \
			GIT_TRACE2_EVENT="$PWD/.git/deleted.trace" \
				git status --porcelain=v2 >.git/actual &&
			test_cmp .git/expect .git/actual &&
			test_line_count = 1 .git/actual &&
			test_grep "^1 \\.D .* $path$" .git/actual &&
			test_trace2_data fsmonitor \
				semantic/manifest-reconciled 1 <.git/deleted.trace &&
			! have_t2_data_event fsmonitor \
				semantic/manifest-scan-count <.git/deleted.trace &&
			! have_t2_data_event fsmonitor \
				semantic/attributes-scope <.git/deleted.trace &&
			! have_t2_data_event fsmonitor \
				semantic/attributes-cone <.git/deleted.trace &&
			! test_trace2_data fsmonitor \
				semantic/strong-invalidation 1 <.git/deleted.trace &&
			! test_trace2_data index \
				preload/sum_lstat "[2-9][0-9]*" \
				<.git/deleted.trace &&
			! test_trace2_data index \
				preload/sum_lstat "1[0-9][0-9]*" \
				<.git/deleted.trace &&
			! test_trace2_data index \
				refresh/sum_lstat "[2-9][0-9]*" \
				<.git/deleted.trace &&
			! test_trace2_data index \
				refresh/sum_lstat "1[0-9][0-9]*" \
				<.git/deleted.trace &&
			git show "HEAD:$path" >"$path" &&
			GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
				-c core.untrackedCache=false status --porcelain=v2 \
				>.git/restored.expect &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH="$path" \
			GIT_TRACE2_EVENT="$PWD/.git/restored.trace" \
				git status --porcelain=v2 >.git/restored.actual &&
			test_cmp .git/restored.expect .git/restored.actual &&
			test_must_be_empty .git/restored.actual &&
			test_trace2_data fsmonitor \
				semantic/manifest-reconciled 1 \
				<.git/restored.trace &&
			! have_t2_data_event fsmonitor \
				semantic/manifest-scan-count <.git/restored.trace &&
			! have_t2_data_event fsmonitor \
				semantic/attributes-scope <.git/restored.trace &&
			! test_trace2_data index \
				refresh/sum_lstat "[2-9][0-9]*" \
				<.git/restored.trace &&
			! test_trace2_data index \
				refresh/sum_lstat "1[0-9][0-9]*" \
				<.git/restored.trace &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			GIT_TRACE2_EVENT="$PWD/.git/repeated.trace" \
				git status --porcelain=v2 >.git/repeated.actual &&
			test_must_be_empty .git/repeated.actual &&
			! have_t2_data_event fsmonitor \
				semantic/manifest-scan-count <.git/repeated.trace &&
			! have_t2_data_event fsmonitor \
				semantic/attributes-scope <.git/repeated.trace
		) || return 1
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'attribute deletion reuses a checkpoint when the index lost its token' '
	test_when_finished \
		"rm -rf deleted-checkpoint-root deleted-checkpoint-nested" &&
	for scope in root nested
	do
		repo=deleted-checkpoint-$scope &&
		prepare_deleted_attribute_repo "$repo" &&
		(
			cd "$repo" &&
			sane_unset GIT_TEST_SPLIT_INDEX &&
			test-tool chmtime -120 .gitattributes \
				scoped/.gitattributes tracked.txt \
				scoped/tracked.txt sibling/tracked.txt &&
			git -c core.fsmonitor=false update-index --refresh &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git update-index --fsmonitor &&
			GIT_INDEX_FILE="$PWD/.git/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
				git status --porcelain=v2 >.git/materialized &&
			test_must_be_empty .git/materialized &&
			test_grep FSCF .git/index &&
			test_grep FSUC .git/index &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/checkpoint.trace" \
				git status --porcelain=v2 >.git/checkpoint &&
			test_must_be_empty .git/checkpoint &&
			test_trace2_data fsmonitor history/external-stored 1 \
				<.git/checkpoint.trace &&
			git -c core.fsmonitor=false update-index \
				--no-fsmonitor --force-write-index &&
			test_grep ! FSMN .git/index &&
			test_grep FSCF .git/index &&
			if test "$scope" = root
			then
				path=.gitattributes
			else
				path=scoped/.gitattributes
			fi &&
			rm "$path" &&
			GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
				-c core.untrackedCache=false status --porcelain=v2 \
				>.git/expect &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH="$path" \
			GIT_TRACE2_EVENT="$PWD/.git/deleted.trace" \
				git status --porcelain=v2 >.git/actual &&
			test_cmp .git/expect .git/actual &&
			test_line_count = 1 .git/actual &&
			test_grep "^1 \\.D .* $path$" .git/actual &&
			test_trace2_data fsmonitor \
				history/external-fsmn-recovered 1 \
				<.git/deleted.trace &&
			test_trace2_data fsmonitor \
				semantic/manifest-reconciled 1 \
				<.git/deleted.trace &&
			! have_t2_data_event fsmonitor \
				semantic/manifest-scan-count <.git/deleted.trace &&
			! have_t2_data_event fsmonitor \
				semantic/attributes-scope <.git/deleted.trace &&
			! test_trace2_data fsmonitor \
				history/external-proof-invalidated 1 \
				<.git/deleted.trace &&
			git -c core.fsmonitor=false update-index \
				--no-fsmonitor --force-write-index &&
			test_grep ! FSMN .git/index &&
			test_grep FSCF .git/index &&
			git show "HEAD:$path" >"$path" &&
			GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
				-c core.untrackedCache=false status --porcelain=v2 \
				>.git/restored.expect &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH="$path" \
			GIT_TRACE2_EVENT="$PWD/.git/restored.trace" \
				git status --porcelain=v2 >.git/restored.actual &&
			test_cmp .git/restored.expect .git/restored.actual &&
			test_must_be_empty .git/restored.actual &&
			test_trace2_data fsmonitor \
				history/external-fsmn-recovered 1 \
				<.git/restored.trace &&
			test_trace2_data fsmonitor \
				semantic/manifest-reconciled 1 \
				<.git/restored.trace &&
			! have_t2_data_event fsmonitor \
				semantic/manifest-scan-count <.git/restored.trace &&
			! have_t2_data_event fsmonitor \
				semantic/attributes-scope <.git/restored.trace &&
			! test_trace2_data fsmonitor \
				history/external-proof-invalidated 1 \
				<.git/restored.trace
		) || return 1
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'a changed attribute fallback cannot resurrect a lost-token checkpoint' '
	test_when_finished "rm -rf deleted-checkpoint-changed" &&
	prepare_deleted_attribute_repo deleted-checkpoint-changed &&
	(
		cd deleted-checkpoint-changed &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test-tool chmtime -120 .gitattributes \
			scoped/.gitattributes tracked.txt scoped/tracked.txt \
			sibling/tracked.txt &&
		git -c core.fsmonitor=false update-index --refresh &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		test_write_lines "*.txt text eol=crlf" >.gitattributes &&
		test-tool chmtime -120 .gitattributes &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
			git status --porcelain=v2 >.git/materialized &&
		test_grep "^1 \\.M .* .gitattributes$" .git/materialized &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/checkpoint.trace" \
			git status --porcelain=v2 >.git/checkpoint &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<.git/checkpoint.trace &&
		git -c core.fsmonitor=false update-index \
			--no-fsmonitor --force-write-index &&
		test_grep ! FSMN .git/index &&
		test_grep FSCF .git/index &&
		rm .gitattributes &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/expect &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
		GIT_TRACE2_EVENT="$PWD/.git/deleted.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_grep "^1 \\.D .* .gitattributes$" .git/actual &&
		test_trace2_data fsmonitor history/external-proof-invalidated 1 \
			<.git/deleted.trace &&
		test_trace2_data fsmonitor semantic/attributes-scope 0 \
			<.git/deleted.trace &&
		! test_trace2_data fsmonitor \
			history/external-fsmn-recovered 1 <.git/deleted.trace &&
		! test_trace2_data fsmonitor semantic/manifest-reconciled 1 \
			<.git/deleted.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'deleting changed tracked attributes still invalidates their scope' '
	test_when_finished "rm -rf deleted-attributes-changed" &&
	prepare_deleted_attribute_repo deleted-attributes-changed &&
	(
		cd deleted-attributes-changed &&
		test_write_lines "*.txt text eol=crlf" >.gitattributes &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
			git status --porcelain=v2 >.git/changed &&
		test_grep "^1 \\.M .* .gitattributes$" .git/changed &&
		test_grep FSCF .git/index &&
		rm .gitattributes &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/expect &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
		GIT_TRACE2_EVENT="$PWD/.git/deleted.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_grep "^1 \\.D .* .gitattributes$" .git/actual &&
		test_trace2_data fsmonitor semantic/attributes-scope 0 \
			<.git/deleted.trace &&
		! test_trace2_data fsmonitor semantic/manifest-reconciled 1 \
			<.git/deleted.trace
	)
'

test_expect_success SYMLINKS,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN \
	'an attribute symlink cannot impersonate an indexed fallback' '
	test_when_finished "rm -rf deleted-attributes-symlink" &&
	prepare_deleted_attribute_repo deleted-attributes-symlink &&
	(
		cd deleted-attributes-symlink &&
		rm .gitattributes &&
		ln -s tracked.txt .gitattributes &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/expect &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
		GIT_TRACE2_EVENT="$PWD/.git/symlink.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_grep "^1 \\.T .* .gitattributes$" .git/actual &&
		test_trace2_data fsmonitor semantic/attributes-scope 0 \
			<.git/symlink.trace &&
		! test_trace2_data fsmonitor semantic/manifest-reconciled 1 \
			<.git/symlink.trace
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'diff skips content verification for display-only root attributes' '
	test_when_finished "rm -rf display-only-root-attributes" &&
	test_create_repo display-only-root-attributes &&
	(
		cd display-only-root-attributes &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines "*.txt -text" >.gitattributes &&
		test_write_lines alpha >tracked.txt &&
		test_write_lines beta >sibling.txt &&
		for attribute_dir in $(test_seq 1 128)
		do
			mkdir "nested-$attribute_dir" &&
			test_write_lines "*.txt -text" \
				>"nested-$attribute_dir/.gitattributes" &&
			test_write_lines "$attribute_dir" \
				>"nested-$attribute_dir/tracked.txt" || return 1
		done &&
		git add .gitattributes tracked.txt sibling.txt nested-* &&
		git commit -m base &&
		git config core.autocrlf false &&
		git config core.trustctime true &&
		git config core.checkStat default &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime &&
		test_must_be_empty .git/prime &&
		test_grep FSCF .git/index &&
		git -c core.fsmonitor=false update-index \
			--no-fsmonitor --force-write-index &&
		test_grep ! FSMN .git/index &&
		test_grep FSCF .git/index &&
		test_write_lines "*.gen linguist-generated" \
			>>.gitattributes &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false diff \
			>.git/display.expect &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCC \
		GIT_TRACE2_EVENT="$PWD/.git/display.trace" \
			git diff >.git/display.actual &&
		test_cmp .git/display.expect .git/display.actual &&
		test_grep "^+\\*.gen linguist-generated$" \
			.git/display.actual &&
		test_trace2_data fsmonitor semantic/nonconversion-attributes 1 \
			<.git/display.trace &&
		test_trace2_data fsmonitor semantic/manifest-changed 1 \
			<.git/display.trace &&
		! test_trace2_data fsmonitor apply/global-invalidation 1 \
			<.git/display.trace &&
		! test_trace2_data fsmonitor semantic/attributes-scope 0 \
			<.git/display.trace &&
		! test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/display.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/display.trace &&
		! test_trace2_data index preload/bulk_useful \
			"[1-9][0-9]*" <.git/display.trace &&

		# Preserve an authenticated checkpoint from the unchanged old
		# index before an unstaged, presentation-only root change.
		git show HEAD:.gitattributes >.gitattributes &&
		test-tool chmtime -120 .gitattributes tracked.txt sibling.txt \
			nested-*/*.txt nested-*/.gitattributes &&
		git -c core.fsmonitor=false update-index --refresh &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/old-display-materialized &&
		test_must_be_empty .git/old-display-materialized &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/old-display-checkpoint.trace" \
			git status --porcelain=v2 >.git/old-display-checkpoint &&
		test_must_be_empty .git/old-display-checkpoint &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<.git/old-display-checkpoint.trace &&
		old_display_attributes=$(git rev-parse :.gitattributes) &&
		git -c core.fsmonitor=false update-index \
			--no-fsmonitor --force-write-index &&
		test_grep ! FSMN .git/index &&
		test_grep FSCF .git/index &&
		test_write_lines "*.gen linguist-generated" \
			>>.gitattributes &&
		test "$old_display_attributes" = \
			"$(git rev-parse :.gitattributes)" &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false diff \
			>.git/old-display.expect &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDDCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
		GIT_TRACE2_EVENT="$PWD/.git/old-display.trace" \
			git diff >.git/old-display.actual &&
		test_cmp .git/old-display.expect .git/old-display.actual &&
		test_grep "^+\\*.gen linguist-generated$" \
			.git/old-display.actual &&
		test_trace2_data fsmonitor history/external-restored 1 \
			<.git/old-display.trace &&
		test_trace2_data fsmonitor \
			history/external-fsmn-recovered 1 \
			<.git/old-display.trace &&
		test_trace2_data fsmonitor semantic/nonconversion-attributes 1 \
			<.git/old-display.trace &&
		test_trace2_data fsmonitor \
			semantic/nonconversion-attribute-replayed 1 \
			<.git/old-display.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/old-display.trace &&
		! test_trace2_data fsmonitor semantic/manifest-candidates 129 \
			<.git/old-display.trace &&
		! test_trace2_data fsmonitor apply/global-invalidation 1 \
			<.git/old-display.trace &&
		! test_trace2_data fsmonitor semantic/attributes-scope 0 \
			<.git/old-display.trace &&
		! test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/old-display.trace &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/old-display.trace &&

		for boundary in conversion macro
		do
			if test "$boundary" = conversion
			then
				test_write_lines "*.txt text eol=crlf" \
					>.gitattributes
			else
				test_write_lines \
					"[attr]linguist-generated filter=custom" \
					"*.gen linguist-generated" \
					>.gitattributes
			fi &&
			GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
				-c core.untrackedCache=false diff \
				>".git/$boundary.expect" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDDCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
			GIT_TRACE2_EVENT="$PWD/.git/$boundary.trace" \
				git diff >".git/$boundary.actual" &&
			test_cmp ".git/$boundary.expect" \
				".git/$boundary.actual" &&
			test_trace2_data fsmonitor semantic/attributes-scope 0 \
				<".git/$boundary.trace" &&
			test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
				<".git/$boundary.trace" &&
			! test_trace2_data fsmonitor history/external-restored 1 \
				<".git/$boundary.trace" &&
			! test_trace2_data fsmonitor \
				semantic/nonconversion-attribute-replayed 1 \
				<".git/$boundary.trace" &&
			! test_trace2_data fsmonitor \
				semantic/nonconversion-attributes 1 \
				<".git/$boundary.trace" || return 1
			done &&

		test_write_lines "*.txt text eol=crlf" >.gitattributes &&
		test_must_fail env \
			GIT_TRACE2_EVENT="$PWD/.git/scoped-attributes.trace" \
			git update-index --refresh -- .gitattributes &&
		! test_trace2_data fsmonitor history/external-restored 1 \
			<.git/scoped-attributes.trace &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false diff \
			>.git/scoped-attributes.expect &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCC \
		GIT_TRACE2_EVENT="$PWD/.git/scoped-attributes-diff.trace" \
			git diff >.git/scoped-attributes.actual &&
		test_cmp .git/scoped-attributes.expect \
			.git/scoped-attributes.actual &&
		test_trace2_data fsmonitor semantic/attributes-scope 0 \
			<.git/scoped-attributes-diff.trace &&
		! test_trace2_data fsmonitor \
			semantic/nonconversion-attributes 1 \
			<.git/scoped-attributes-diff.trace &&

		git show HEAD:.gitattributes >.gitattributes &&
		cp .git/index .git/old-index &&
		test_write_lines \
			"*.one linguist-generated" \
			"*.two linguist-generated" \
			"*.three linguist-generated" \
			"*.four linguist-generated" \
			>>.gitattributes &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git add .gitattributes &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git commit -qm generated &&
		new_attributes=$(git rev-parse HEAD:.gitattributes) &&
		history_base=$(git rev-parse HEAD) &&
		{
			for unrelated in $(test_seq 1 1038)
			do
				printf "commit refs/heads/linguist-history\\n" &&
				printf "mark :%s\\n" "$unrelated" &&
				printf "committer Test <test@example.com> 1112911993 +0000\\n" &&
				printf "data 9\\nunrelated\\n" &&
				if test "$unrelated" = 1
				then
					printf "from %s\\n\\n" "$history_base"
				else
					previous=$((unrelated - 1)) &&
					printf "from :%s\\n\\n" "$previous"
				fi || return 1
			done
		} >.git/history.stream &&
		git fast-import --quiet <.git/history.stream &&
		git update-ref "$(git symbolic-ref HEAD)" \
			"$(git rev-parse refs/heads/linguist-history)" &&
		git commit-graph write --reachable --changed-paths &&
		test "$(git rev-parse HEAD:.gitattributes)" = \
			"$new_attributes" &&
		test "$(git rev-parse HEAD^:.gitattributes)" = \
			"$new_attributes" &&
		test "$(git rev-parse HEAD~1038:.gitattributes)" = \
			"$new_attributes" &&
		test "$(git rev-parse HEAD~1039:.gitattributes)" != \
			"$new_attributes" &&
		cp .git/old-index .git/index &&
		git -c core.fsmonitor=false update-index \
			--no-fsmonitor \
			--cacheinfo "100644,$new_attributes,.gitattributes" \
			--force-write-index &&
		test_grep ! FSMN .git/index &&
		test_grep FSCF .git/index &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false diff --cached \
			>.git/committed-index &&
		test_must_be_empty .git/committed-index &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false diff \
			>.git/committed.expect &&
		test_must_be_empty .git/committed.expect &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCC \
		GIT_TRACE2_EVENT="$PWD/.git/committed.trace" \
			git diff >.git/committed.actual &&
		test_cmp .git/committed.expect .git/committed.actual &&
		test_trace2_data fsmonitor semantic/nonconversion-attributes 1 \
			<.git/committed.trace &&
		test_trace2_data fsmonitor \
			semantic/attribute-history-commits 1039 \
			<.git/committed.trace &&
		test_trace2_data fsmonitor \
			semantic/attribute-history-bloom-skips 1038 \
			<.git/committed.trace &&
		test_trace2_data fsmonitor semantic/manifest-changed 1 \
			<.git/committed.trace &&
		! test_trace2_data fsmonitor semantic/attributes-scope 0 \
			<.git/committed.trace &&
		! test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/committed.trace &&

		# Keep the same logical index but checkpoint the old worktree
		# attributes, as an earlier dirty command would have done.
		test-tool chmtime -120 .gitattributes tracked.txt sibling.txt \
			nested-*/*.txt nested-*/.gitattributes &&
		git -c core.fsmonitor=false update-index --refresh &&
		git show HEAD~1039:.gitattributes >.gitattributes &&
		test-tool chmtime -120 .gitattributes &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
			git status --porcelain=v2 >.git/old-materialized &&
		test_grep "^1 \\.M .* .gitattributes$" \
			.git/old-materialized &&
		test_grep FSCF .git/index &&
		test_grep FSUC .git/index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/old-checkpoint.trace" \
			git status --porcelain=v2 >.git/old-checkpoint &&
		test_cmp .git/old-materialized .git/old-checkpoint &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<.git/old-checkpoint.trace &&
		find .git -maxdepth 1 -type f -name "index.csh1.*" \
			>.git/old-checkpoints &&
		test_line_count = 1 .git/old-checkpoints &&
		rm -f .git/index.csts &&
		git -c core.fsmonitor=false update-index \
			--no-fsmonitor --force-write-index &&
		test_grep ! FSMN .git/index &&
		test_grep FSCF .git/index &&
		git show HEAD:.gitattributes >.gitattributes &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false diff \
			>.git/checkpoint.expect &&
		test_must_be_empty .git/checkpoint.expect &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDDCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
		GIT_TRACE2_EVENT="$PWD/.git/checkpoint.trace" \
			git diff >.git/checkpoint.actual &&
		test_cmp .git/checkpoint.expect .git/checkpoint.actual &&
		test_trace2_data fsmonitor history/external-restored 1 \
			<.git/checkpoint.trace &&
		test_trace2_data fsmonitor \
			history/external-fsmn-recovered 1 \
			<.git/checkpoint.trace &&
		test_trace2_data fsmonitor semantic/nonconversion-attributes 1 \
			<.git/checkpoint.trace &&
		test_trace2_data fsmonitor \
			semantic/attribute-history-commits 1039 \
			<.git/checkpoint.trace &&
		test_trace2_data fsmonitor \
			semantic/attribute-history-bloom-skips 1038 \
			<.git/checkpoint.trace &&
		! test_trace2_data fsmonitor semantic/attributes-scope 0 \
			<.git/checkpoint.trace &&
		! test_trace2_data fsmonitor semantic/strong-invalidation 1 \
			<.git/checkpoint.trace &&

		# A writer can also advance the staged attribute blob after the
		# checkpoint. Its token and tracked bitmap no longer authenticate
		# the named index, but the old attribute manifest remains useful.
		if test_have_prereq MACOS
		then
			test-tool chmtime -120 \
				.gitattributes tracked.txt sibling.txt \
				nested-*/*.txt nested-*/.gitattributes &&
			git -c core.fsmonitor=false update-index --refresh &&
			git show HEAD~1039:.gitattributes >.gitattributes &&
			old_attributes=$(git rev-parse HEAD~1039:.gitattributes) &&
			test-tool chmtime -120 .gitattributes &&
			git -c core.fsmonitor=false update-index \
				--cacheinfo "100644,$old_attributes,.gitattributes" \
				--force-write-index &&
			test "$(git rev-parse :.gitattributes)" = \
				"$old_attributes" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git update-index --fsmonitor &&
			GIT_INDEX_FILE="$PWD/.git/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
				git status --porcelain=v2 \
				>.git/advanced-materialized &&
			test_grep "^1 M\\. .* .gitattributes$" \
				.git/advanced-materialized &&
			test_grep FSCF .git/index &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/advanced-checkpoint.trace" \
				git status --porcelain=v2 \
				>.git/advanced-checkpoint &&
			test_cmp .git/advanced-materialized \
				.git/advanced-checkpoint &&
			test_trace2_data fsmonitor history/external-stored 1 \
				<.git/advanced-checkpoint.trace &&
			rm -f .git/index.csts &&
			git -c core.fsmonitor=false update-index \
				--no-fsmonitor \
				--cacheinfo \
				"100644,$new_attributes,.gitattributes" \
				--force-write-index &&
			test "$(git rev-parse :.gitattributes)" = \
				"$new_attributes" &&
			test_grep ! FSMN .git/index &&
			test_grep FSCF .git/index &&
			test_grep UNTR .git/index &&
			test_grep ! FSUC .git/index &&
			git show HEAD:.gitattributes >.gitattributes &&
			GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
				-c core.untrackedCache=false diff \
				>.git/advanced.expect &&
			test_must_be_empty .git/advanced.expect &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DTCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
			GIT_TRACE2_EVENT="$PWD/.git/advanced.trace" \
				git diff >.git/advanced.actual &&
			test_cmp .git/advanced.expect .git/advanced.actual &&
			test_trace2_data fsmonitor \
				history/external-bootstrap-manifest 1 \
				<.git/advanced.trace &&
			test_trace2_data fsmonitor \
				semantic/nonconversion-attributes 1 \
				<.git/advanced.trace &&
			test_trace2_data fsmonitor \
				semantic/attribute-history-commits 1039 \
				<.git/advanced.trace &&
			test_trace2_data fsmonitor \
				semantic/attribute-history-bloom-skips 1038 \
				<.git/advanced.trace &&
			test_trace2_data fsmonitor \
				semantic/token-reset-stat-baseline 1 \
				<.git/advanced.trace &&
			! test_trace2_data fsmonitor history/external-restored 1 \
				<.git/advanced.trace &&
			! test_trace2_data fsmonitor \
				history/external-fsmn-recovered 1 \
				<.git/advanced.trace &&
			! have_t2_data_event fsmonitor \
				semantic/manifest-scan-count \
				<.git/advanced.trace &&
			! test_trace2_data fsmonitor \
				semantic/strong-invalidation 1 \
				<.git/advanced.trace &&

			test_write_lines "*.txt text eol=crlf" \
				>.gitattributes &&
			GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
				-c core.untrackedCache=false diff \
				>.git/advanced-conversion.expect &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DTCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
			GIT_TRACE2_EVENT="$PWD/.git/advanced-conversion.trace" \
				git diff >.git/advanced-conversion.actual &&
			test_cmp .git/advanced-conversion.expect \
				.git/advanced-conversion.actual &&
			! test_trace2_data fsmonitor \
				history/external-bootstrap-manifest 1 \
				<.git/advanced-conversion.trace &&
			! test_trace2_data fsmonitor \
				semantic/nonconversion-attributes 1 \
				<.git/advanced-conversion.trace &&
			test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<.git/advanced-conversion.trace
		fi
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'tracked attribute events reopen semantic history' '
	test_when_finished "rm -rf tracked-attr-change" &&
	test_create_repo tracked-attr-change &&
	(
		cd tracked-attr-change &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		printf "*.txt text eol=crlf\n" >.gitattributes &&
		printf "alpha\r\n" >tracked.txt &&
		git add .gitattributes tracked.txt &&
		git commit -m base &&
		git config core.fsmonitor true &&
		git config core.untrackedCache true &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
			git status --porcelain=v2 >.git/prime.actual &&
		test_must_be_empty .git/prime.actual &&
		test_grep FSCF .git/index &&
		test-tool chmtime =-60 tracked.txt &&

		printf "*.txt -text\n" >.gitattributes &&
		test-tool chmtime +1 tracked.txt &&
		GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain=v2 \
			>.git/expect &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_grep "^1 \.M .* tracked.txt$" .git/actual &&
		test_trace2_data fsmonitor semantic/manifest-scan-count \
			"[1-9]" <.git/status.trace
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'tracked-only status adopts missing semantic history' '
	test_when_finished "rm -rf tracked-semantic-adoption" &&
	test_create_repo tracked-semantic-adoption &&
	(
		cd tracked-semantic-adoption &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		printf "aaaa\n" >tracked &&
		git add tracked &&
		git commit -m base &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		git config core.untrackedCache true &&
		test-tool chmtime -60 tracked &&
		git update-index --refresh &&
		mtime=$(test-tool chmtime --get tracked) &&
		printf "bbbb\n" >tracked &&
		test-tool chmtime =$mtime tracked &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor-valid tracked &&
		test_grep ! FSCF .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCC \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 --untracked-files=no \
			>.git/actual &&
		test_grep "^1 \.M .* tracked$" .git/actual &&
		test_trace2_data status fsmonitor_token/semantic-closed 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep FSCF .git/index
	)
'

test_expect_success SEMANTIC_VERIFY_ANCHORED_OPEN \
	'collapsed sparse index uses ordinary token closure' '
	test_when_finished "rm -rf sparse-tracked-only" &&
	test_create_repo sparse-tracked-only &&
	(
		cd sparse-tracked-only &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		mkdir in outside &&
		printf "aaaa\n" >in/tracked &&
		printf "outside\n" >outside/file &&
		git add . &&
		git commit -m base &&
		git sparse-checkout set --cone --sparse-index in &&
		git config core.trustctime false &&
		git config core.checkStat minimal &&
		git config core.untrackedCache true &&
		test-tool chmtime =-60 in/tracked &&
		git update-index --refresh &&
		mtime=$(test-tool chmtime --get in/tracked) &&
		printf "bbbb\n" >in/tracked &&
		test-tool chmtime =$mtime in/tracked &&
		git config core.fsmonitor true &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor-valid in/tracked &&
		test_grep ! FSCF .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDC \
		GIT_TEST_FSMONITOR_QUERY_PATH=in/tracked \
		GIT_TRACE2_EVENT="$PWD/.git/status.trace" \
			git status --porcelain=v2 --untracked-files=no \
			>.git/actual &&
		test_grep "^1 \.M .* in/tracked$" .git/actual &&
		! test_trace2_data status semantic_verify/prepared 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/apply_count 1 \
			<.git/status.trace &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/status.trace &&
		test_grep FSCF .git/index &&
		git -c core.fsmonitor=false ls-files --sparse \
			>.git/sparse.after &&
		test_grep "^outside/$" .git/sparse.after
	)
'

test_done
