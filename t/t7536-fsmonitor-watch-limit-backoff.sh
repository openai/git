#!/bin/sh

test_description='fsmonitor watch-limit backoff authenticates optional markers'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-semantic-verify.sh

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

test_lazy_prereq UNTRACKED_CACHE '
	{ git update-index --test-untracked-cache; ret=$?; } &&
	test $ret -ne 1
'

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
		test_env GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
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

assert_backoff_full_proof () {
	perl - "$1" <<-\EOF
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
	die "missing builtin provider token\n" unless
		$tokens{"FSMN"} =~ /\Abuiltin:/;
	die "mismatched tracked provider token\n" unless
		$tokens{"FSMN"} eq $tokens{"FSCF"};
	die "mismatched untracked provider token\n" unless
		$tokens{"FSMN"} eq $tokens{"FSUC"};
	EOF
}

assert_backoff_history_unchanged () {
	test_cmp_bin "$1/index.before-backoff" "$1/index" &&
	test_cmp_bin "$1/checkpoint.before-backoff" "$2" &&
	if test -f "$1/sidecar.before-backoff"
	then
		test_cmp_bin "$1/sidecar.before-backoff" "$1/index.csts"
	else
		test_path_is_missing "$1/index.csts"
	fi &&
	test_path_is_missing "$1/index.lock"
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

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'temporary backoff preserves main and linked index and history proofs' '
	test_create_repo watch-backoff-main &&
	test_when_finished "git -C watch-backoff-main -c core.fsmonitor=false \
		worktree remove --force ../watch-backoff-linked \
		>/dev/null 2>&1 || :" &&
	(
		cd watch-backoff-main &&
		test_commit base tracked &&
		git worktree add --detach ../watch-backoff-linked HEAD &&
		git config core.autocrlf false &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		for worktree in "$PWD" "$PWD/../watch-backoff-linked"
		do
			gitdir=$(git -C "$worktree" rev-parse --absolute-git-dir) &&
			test-tool chmtime -120 "$worktree/tracked" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" update-index --refresh &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			assert_backoff_full_proof "$gitdir/index" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/checkpoint.trace" \
				git -C "$worktree" status --short \
					>"$gitdir/checkpoint.status" &&
			test_must_be_empty "$gitdir/checkpoint.status" &&
			test_trace2_data fsmonitor history/external-stored 1 \
				<"$gitdir/checkpoint.trace" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status \
					>"$gitdir/sidecar.status" &&
			find "$gitdir" -maxdepth 1 -type f \
				-name "index.csh1.*" >"$gitdir/checkpoints" &&
			test_line_count = 1 "$gitdir/checkpoints" &&
			checkpoint=$(cat "$gitdir/checkpoints") &&
			assert_backoff_full_proof "$gitdir/index" &&
			cp "$gitdir/index" "$gitdir/index.before-backoff" &&
			cp "$checkpoint" "$gitdir/checkpoint.before-backoff" &&
			if test -f "$gitdir/index.csts"
			then
				cp "$gitdir/index.csts" \
					"$gitdir/sidecar.before-backoff"
			fi &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
				test-tool -C "$worktree" fsmonitor-client \
					record-watch-limit &&
			marker="$gitdir/fsmonitor--daemon.inotify-limit" &&
			test_path_is_file "$marker" &&
			test_line_count = 3 "$marker" &&
			test_grep "^inotify-limit-v1$" "$marker" &&
			test_write_lines changed >"$worktree/tracked" &&
			test_write_lines visible >"$worktree/visible" &&
			git -C "$worktree" -c core.fsmonitor=false \
				-c core.untrackedCache=false --no-optional-locks \
				status --porcelain=v2 >"$gitdir/expected" &&
			test_grep "^1 \\.M .* tracked$" "$gitdir/expected" &&
			test_grep "^? visible$" "$gitdir/expected" &&
			assert_backoff_history_unchanged "$gitdir" "$checkpoint" &&
			for attempt in first second
			do
				GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCCCCC \
				GIT_TEST_FSMONITOR_QUERY_PATH=// \
				GIT_TRACE2_EVENT="$gitdir/$attempt.trace" \
					git -C "$worktree" status --porcelain=v2 \
						>"$gitdir/$attempt.actual" &&
				test_cmp "$gitdir/expected" \
					"$gitdir/$attempt.actual" &&
				test_trace2_data fsm_client \
					settings/inotify-watch-limit-backoff 1 \
					<"$gitdir/$attempt.trace" &&
				! test_trace2_data fsmonitor history/external-stored 1 \
					<"$gitdir/$attempt.trace" &&
				test_region ! fsmonitor history_logical_digest \
					"$gitdir/$attempt.trace" &&
				test_region ! index do_write_index \
					"$gitdir/$attempt.trace" &&
				test_grep ! \
					"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
					"$gitdir/$attempt.trace" &&
				test_path_is_file "$marker" &&
				assert_backoff_history_unchanged \
					"$gitdir" "$checkpoint" || return 1
			done &&
			rm "$marker" &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DDCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=// \
			GIT_TRACE2_EVENT="$gitdir/recovery.trace" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/recovery.actual" &&
			test_cmp "$gitdir/expected" "$gitdir/recovery.actual" &&
			! test_trace2_data fsm_client \
				settings/inotify-watch-limit-backoff 1 \
				<"$gitdir/recovery.trace" &&
			test_path_is_missing "$marker" &&
			assert_backoff_full_proof "$gitdir/index" || return 1
		done
	)
'

test_expect_success PERL_TEST_HELPERS \
	'mandatory writers still update the index during temporary backoff' '
	setup_backoff_marker_fixture watch-backoff-mandatory &&
	(
		cd watch-backoff-mandatory &&
		cp .git/index .git/index.before &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			test-tool fsmonitor-client record-watch-limit &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/mandatory.trace" \
			git add tracked &&
		test_trace2_data fsm_client \
			settings/inotify-watch-limit-backoff 1 \
			<.git/mandatory.trace &&
		test_region index do_write_index .git/mandatory.trace &&
		! cmp .git/index.before .git/index &&
		test_grep ! FSMN .git/index &&
		test_grep ! FSUC .git/index &&
		git -c core.fsmonitor=false diff --cached --name-only \
			>.git/staged &&
		test_grep "^tracked$" .git/staged
	)
'

test_expect_success PERL_TEST_HELPERS \
	'an explicitly disabled fsmonitor still permits optional index writes' '
	setup_backoff_marker_fixture watch-backoff-explicit-disable &&
	(
		cd watch-backoff-explicit-disable &&
		cp .git/index .git/index.before &&
		GIT_TRACE2_EVENT="$PWD/.git/disabled.trace" \
			git -c core.fsmonitor=false status --porcelain=v2 \
				>.git/disabled.actual &&
		test_cmp .git/expect .git/disabled.actual &&
		test_region index do_write_index .git/disabled.trace &&
		! cmp .git/index.before .git/index &&
		test_grep ! FSMN .git/index &&
		! test_trace2_data fsm_client \
			settings/inotify-watch-limit-backoff 1 \
			<.git/disabled.trace
	)
'

test_done
