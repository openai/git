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
		if assert_backoff_full_proof .git/index \
			>.git/mandatory-proof.out 2>.git/mandatory-proof.err
		then
			return 1
		else
			:
		fi &&
		git -c core.fsmonitor=false diff --cached --name-only \
			>.git/staged &&
		test_grep "^tracked$" .git/staged &&
		git -c core.fsmonitor=false --no-optional-locks show :tracked \
			>.git/staged-content &&
		test_cmp tracked .git/staged-content
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

setup_backoff_bound_proof () {
	test_create_repo "$1" &&
	(
		cd "$1" &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit sibling sibling &&
		if test "${2-clean}" = staged
		then
			test_write_lines staged-before >sibling &&
			git -c core.fsmonitor=false add sibling
		elif test "${2-clean}" = nested
		then
			mkdir nested &&
			test_write_lines nested-base >nested/tracked &&
			git add nested/tracked &&
			git commit -qm nested
		else
			:
		fi &&
		git config core.autocrlf false &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		if test "${2-clean}" = nested
		then
			test-tool chmtime -120 tracked sibling nested/tracked
		else
			test-tool chmtime -120 tracked sibling
		fi &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git update-index --refresh &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			git update-index --fsmonitor &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status --porcelain=v2 >.git/prime &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			--no-optional-locks status --porcelain=v2 \
				>.git/prime.expect &&
		test_cmp .git/prime.expect .git/prime &&
		assert_backoff_full_proof .git/index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/checkpoint.trace" \
			git status --short >.git/checkpoint.status &&
		test_trace2_data fsmonitor history/external-stored 1 \
			<.git/checkpoint.trace &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git status >.git/sidecar.status &&
		find .git -maxdepth 1 -type f -name "index.csh1.*" \
			>.git/checkpoints &&
		test_line_count = 1 .git/checkpoints &&
		checkpoint=$(cat .git/checkpoints) &&
		assert_backoff_full_proof .git/index &&
		cp .git/index .git/index.before-backoff &&
		cp "$checkpoint" .git/checkpoint.before-backoff &&
		if test -f .git/index.csts
		then
			cp .git/index.csts .git/sidecar.before-backoff
		else
			:
		fi
	)
}

record_authenticated_backoff_marker () {
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		test-tool fsmonitor-client record-watch-limit &&
	test_path_is_file .git/fsmonitor--daemon.inotify-limit &&
	test_line_count = 3 .git/fsmonitor--daemon.inotify-limit
}

snapshot_backoff_index_identity () {
	perl - "$1" <<-\EOF
	use strict;
	use warnings;
	my @identity = lstat($ARGV[0]) or die "cannot stat index: $!\n";
	die "index is not a regular file\n" unless -f _ && !-l _;
	print join(" ", @identity[0, 1, 2, 3, 4, 5, 7, 9, 10]), "\n";
	EOF
}

assert_backoff_main_index_write () {
	perl - "$1" "$2" "$3" <<-\EOF
	use strict;
	use warnings;
	my ($trace, $index, $expected) = @ARGV;
	my $lock = "$index.lock";
	my $writes = 0;
	open my $input, "<", $trace or die "cannot read trace: $!\n";
	while (my $line = <$input>) {
		next unless $line =~ /"event":"region_enter"/;
		next unless $line =~ /"category":"index"/;
		next unless $line =~ /"label":"do_write_index"/;
		$writes++ if $line =~ /"msg":"\Q$lock\E"/;
	}
	die "expected a main-index write\n" if $expected eq "yes" && !$writes;
	die "unexpected $writes main-index writes\n"
		if $expected eq "no" && $writes;
	die "unknown main-index write expectation\n"
		unless $expected eq "yes" || $expected eq "no";
	EOF
}

assert_backoff_pending_proof () {
	perl - "$1" "$2" <<-\EOF
	use strict;
	use warnings;
	my %tokens;
	my %flags;
	my %payloads;
	my %entries;
	for my $which (0, 1) {
		open my $input, "<", $ARGV[$which]
			or die "cannot read index: $!\n";
		binmode $input;
		local $/;
		my $index = <$input>;
		die "invalid index signature\n"
			unless substr($index, 0, 4) eq "DIRC";
		$entries{$which} = unpack("N", substr($index, 8, 4));
		for my $name ("FSMN", "FSUC", "FSCF") {
			my $offset = index($index, $name);
			die "missing $name extension\n" if $offset < 0;
			my $size = unpack("N", substr($index, $offset + 4, 4));
			my $payload = substr($index, $offset + 8, $size);
			die "truncated $name extension\n"
				unless length($payload) == $size;
			$payloads{"$which:$name"} = $payload;
			if ($name eq "FSCF") {
				$flags{$which} = unpack("N", substr($payload, 8, 4));
				my $length = unpack("N", substr($payload, 12, 4));
				$tokens{"$which:$name"} =
					substr($payload, 20, $length);
			} else {
				my $end = index($payload, "\0", 4);
				die "invalid $name token\n" if $end < 0;
				$tokens{"$which:$name"} =
					substr($payload, 4, $end - 4);
			}
		}
	}
	die "original proof is not fully bound\n" if $flags{0} != 15;
	die "original provider tokens are not paired\n"
		unless $tokens{"0:FSMN"} eq $tokens{"0:FSUC"} &&
		       $tokens{"0:FSMN"} eq $tokens{"0:FSCF"};
	my ($suffix) = $tokens{"0:FSMN"} =~ /\Abuiltin:(.+)\z/;
	die "missing authenticated provider suffix\n" unless defined $suffix;
	die "staging advanced the historical provider token\n"
		unless $tokens{"1:FSMN"} eq $tokens{"0:FSMN"};
	die "staging retained a fully valid provider proof\n"
		unless $flags{1} == 9;
	die "downgraded configuration names another provider token\n"
		unless $tokens{"1:FSCF"} eq $tokens{"0:FSMN"};
	die "untracked history is not authenticated pending state\n"
		unless $tokens{"1:FSUC"} eq "pending:$suffix";
	die "fixture does not have exactly two tracked entries\n"
		unless $entries{0} == 2 && $entries{1} == 2;
	my $payload = $payloads{"1:FSMN"};
	my $end = index($payload, "\0", 4);
	my $size = unpack("N", substr($payload, $end + 1, 4));
	my $bitmap = substr($payload, $end + 5, $size);
	die "truncated tracked dirty bitmap\n" unless length($bitmap) == $size;
	my ($bits, $words) = unpack("NN", substr($bitmap, 0, 8));
	die "tracked dirty bitmap does not span every entry\n"
		unless $bits == $entries{1} && $words == 2 && $size == 28;
	my ($rlw_high, $rlw_low, $literal_high, $literal_low) =
		unpack("NNNN", substr($bitmap, 8, 16));
	die "unexpected tracked dirty bitmap encoding\n"
		unless $rlw_high == 2 && $rlw_low == 0 &&
		       $literal_high == 0;
	die "historical token falsely marks a tracked entry valid\n"
		unless $literal_low == (1 << $entries{1}) - 1;
	die "invalid tracked bitmap running-word position\n"
		unless unpack("N", substr($bitmap, 24, 4)) == 0;
	EOF
}

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'clean add refresh preserves authenticated proofs during backoff' '
	setup_backoff_bound_proof watch-backoff-refresh &&
	(
		cd watch-backoff-refresh &&
		checkpoint=$(cat .git/checkpoints) &&
		record_authenticated_backoff_marker &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/refresh.trace" \
			git add --refresh tracked sibling >.git/refresh.actual &&
		test_must_be_empty .git/refresh.actual &&
		test_trace2_data fsm_client \
			settings/inotify-watch-limit-backoff 1 \
			<.git/refresh.trace &&
		assert_backoff_main_index_write \
			.git/refresh.trace "$PWD/.git/index" no &&
		test_grep ! \
			"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
			.git/refresh.trace &&
		assert_backoff_full_proof .git/index &&
		assert_backoff_history_unchanged .git "$checkpoint" &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			--no-optional-locks status --porcelain=v2 \
				>.git/refresh.oracle &&
		test_must_be_empty .git/refresh.oracle
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'dirty stash creation preserves the main index during backoff' '
	setup_backoff_bound_proof watch-backoff-stash staged &&
	(
		cd watch-backoff-stash &&
		checkpoint=$(cat .git/checkpoints) &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
			test-tool dump-cache-tree >.git/cache-tree.before &&
		test_grep "^invalid " .git/cache-tree.before &&
		cp .git/index .git/expected-stash.index &&
		GIT_INDEX_FILE="$PWD/.git/expected-stash.index" \
			git -c core.fsmonitor=false write-tree \
				>.git/expected-stash-tree &&
		record_authenticated_backoff_marker &&
		test_write_lines unstaged-worktree >tracked &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			--no-optional-locks status --porcelain=v2 \
				>.git/stash.oracle &&
		test_grep "^1 M\\. .* sibling$" .git/stash.oracle &&
		test_grep "^1 \\.M .* tracked$" .git/stash.oracle &&
		snapshot_backoff_index_identity .git/index \
			>.git/stash.index.identity.before &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/stash.trace" \
			git stash create >.git/stash.oid &&
		test_file_not_empty .git/stash.oid &&
		stash=$(cat .git/stash.oid) &&
		git -c core.fsmonitor=false rev-parse "$stash^2^{tree}" \
			>.git/actual-stash-tree &&
		test_cmp .git/expected-stash-tree .git/actual-stash-tree &&
		git -c core.fsmonitor=false show "$stash:tracked" \
			>.git/stash-worktree &&
		test_cmp tracked .git/stash-worktree &&
		git -c core.fsmonitor=false show "$stash^2:sibling" \
			>.git/stash-index &&
		test_cmp sibling .git/stash-index &&
		test_must_fail git rev-parse --verify refs/stash \
			>.git/stash-ref 2>.git/stash-ref.err &&
		test_trace2_data fsm_client \
			settings/inotify-watch-limit-backoff 1 \
			<.git/stash.trace &&
		snapshot_backoff_index_identity .git/index \
			>.git/stash.index.identity.after &&
		test_cmp .git/stash.index.identity.before \
			.git/stash.index.identity.after &&
		test_grep ! \
			"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
			.git/stash.trace &&
		assert_backoff_full_proof .git/index &&
		assert_backoff_history_unchanged .git "$checkpoint" &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			--no-optional-locks status --porcelain=v2 \
				>.git/stash.after &&
		test_cmp .git/stash.oracle .git/stash.after
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'mandatory staging downgrades proofs until authenticated recovery' '
	for outcome in delta trivial
	do
		setup_backoff_bound_proof "watch-backoff-staging-$outcome" &&
		(
			cd "watch-backoff-staging-$outcome" &&
			checkpoint=$(cat .git/checkpoints) &&
			record_authenticated_backoff_marker &&
			test_write_lines staged-first >tracked &&
			test_write_lines staged-second >sibling &&
			test_write_lines visible >visible &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TRACE2_EVENT="$PWD/.git/first-add.trace" \
				git add tracked &&
			assert_backoff_main_index_write \
				.git/first-add.trace "$PWD/.git/index" yes &&
			assert_backoff_pending_proof \
				.git/index.before-backoff .git/index &&
			test_cmp_bin .git/checkpoint.before-backoff \
				"$checkpoint" &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TRACE2_EVENT="$PWD/.git/second-add.trace" \
				git add sibling &&
			assert_backoff_main_index_write \
				.git/second-add.trace "$PWD/.git/index" yes &&
			assert_backoff_pending_proof \
				.git/index.before-backoff .git/index &&
			test_cmp_bin .git/checkpoint.before-backoff \
				"$checkpoint" &&
			test_write_lines unstaged-after >sibling &&
			git -c core.fsmonitor=false --no-optional-locks \
				show :tracked >.git/staged-tracked &&
			test_cmp tracked .git/staged-tracked &&
			git -c core.fsmonitor=false --no-optional-locks \
				show :sibling >.git/staged-sibling &&
			test_write_lines staged-second >.git/expected-sibling &&
			test_cmp .git/expected-sibling .git/staged-sibling &&
			cp .git/index .git/expected-staging.index &&
			GIT_INDEX_FILE="$PWD/.git/expected-staging.index" \
				git -c core.fsmonitor=false write-tree \
					>.git/expected-stage-tree &&
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				--no-optional-locks status --porcelain=v2 \
					>.git/staging.expect &&
			test_grep "^1 M\\. .* tracked$" .git/staging.expect &&
			test_grep "^1 MM .* sibling$" .git/staging.expect &&
			test_grep "^? visible$" .git/staging.expect &&
			cp .git/index .git/pending.before-status &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TRACE2_EVENT="$PWD/.git/backoff-status.trace" \
				git status --porcelain=v2 \
					>.git/backoff-status.actual &&
			test_cmp .git/staging.expect \
				.git/backoff-status.actual &&
			test_cmp_bin .git/pending.before-status .git/index &&
			assert_backoff_pending_proof \
				.git/index.before-backoff .git/index &&
			test_grep ! \
				"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
				.git/first-add.trace .git/second-add.trace \
				.git/backoff-status.trace &&
			rm .git/fsmonitor--daemon.inotify-limit &&
			case "$outcome" in
			delta) sequence=DDCCCCCCCCCCCC ;;
			trivial) sequence=TCCCCCCCCCCCC ;;
			esac &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE="$sequence" \
			GIT_TEST_FSMONITOR_QUERY_PATH=// \
			GIT_TRACE2_EVENT="$PWD/.git/recovery.trace" \
				git status --porcelain=v2 \
					>.git/recovery.actual &&
			test_cmp .git/staging.expect .git/recovery.actual &&
			test_trace2_data fsmonitor token_closure/accepted 1 \
				<.git/recovery.trace &&
			if test "$outcome" = trivial
			then
				test_trace2_data fsm_client query/trivial-response 1 \
					<.git/recovery.trace
			else
				:
			fi &&
			assert_backoff_full_proof .git/index &&
			cp .git/index .git/recovered-staging.index &&
			GIT_INDEX_FILE="$PWD/.git/recovered-staging.index" \
				git -c core.fsmonitor=false write-tree \
					>.git/recovered-stage-tree &&
			test_cmp .git/expected-stage-tree \
				.git/recovered-stage-tree
		) || return 1
	done &&
	setup_backoff_bound_proof watch-backoff-hostile &&
	(
		cd watch-backoff-hostile &&
		record_authenticated_backoff_marker &&
		test_write_lines "tracked text" >.gitattributes &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/hostile.trace" \
			git add .gitattributes &&
		assert_backoff_main_index_write \
			.git/hostile.trace "$PWD/.git/index" yes &&
		test_grep ! "pending:" .git/index &&
		if assert_backoff_full_proof .git/index \
			>.git/hostile-proof.out 2>.git/hostile-proof.err
		then
			return 1
		else
			:
		fi &&
		git -c core.fsmonitor=false --no-optional-locks \
			show :.gitattributes >.git/hostile-staged &&
		test_cmp .gitattributes .git/hostile-staged
	) &&
	for location in root nested
	do
		case "$location" in
		root)
			mode=clean &&
			attribute=.gitattributes &&
			tracked=tracked
			;;
		nested)
			mode=nested &&
			attribute=nested/.gitattributes &&
			tracked=nested/tracked
			;;
		esac &&
		setup_backoff_bound_proof \
			"watch-backoff-hostile-$location" "$mode" &&
		(
			cd "watch-backoff-hostile-$location" &&
			record_authenticated_backoff_marker &&
			test_write_lines "tracked text" >"$attribute" &&
			printf "changed\\r\\n" >"$tracked" &&
			test_write_lines changed >.git/hostile.expected &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TRACE2_EVENT="$PWD/.git/hostile-ordinary.trace" \
				git add "$tracked" &&
			assert_backoff_main_index_write \
				.git/hostile-ordinary.trace "$PWD/.git/index" yes &&
			git -c core.fsmonitor=false --no-optional-locks \
				show ":$tracked" >.git/hostile.actual &&
			test_cmp .git/hostile.expected .git/hostile.actual &&
			test_grep ! "pending:" .git/index &&
			if assert_backoff_full_proof .git/index \
				>.git/hostile-proof.out 2>.git/hostile-proof.err
			then
				return 1
			else
				:
			fi &&
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				--no-optional-locks status --porcelain=v2 \
					>.git/hostile.oracle &&
			test_grep "^1 M\\. .* $tracked$" \
				.git/hostile.oracle &&
			test_grep "^? $attribute$" .git/hostile.oracle
		) || return 1
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'conditional diff refresh preserves authenticated backoff proofs' '
	setup_backoff_bound_proof watch-backoff-diff-control &&
	(
		cd watch-backoff-diff-control &&
		test-tool chmtime +120 tracked &&
		GIT_TRACE2_EVENT="$PWD/.git/control.trace" \
			git -c core.fsmonitor=false \
				-c diff.autoRefreshIndex=true diff -- tracked \
					>.git/control.actual &&
		test_must_be_empty .git/control.actual &&
		assert_backoff_main_index_write \
			.git/control.trace "$PWD/.git/index" yes
	) &&
	setup_backoff_bound_proof watch-backoff-diff &&
	(
		cd watch-backoff-diff &&
		checkpoint=$(cat .git/checkpoints) &&
		record_authenticated_backoff_marker &&
		test-tool chmtime +120 tracked &&
		git -c core.fsmonitor=false -c diff.autoRefreshIndex=true \
			--no-optional-locks diff -- tracked >.git/diff.expect &&
		test_must_be_empty .git/diff.expect &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/diff.trace" \
			git -c diff.autoRefreshIndex=true diff -- tracked \
				>.git/diff.actual &&
		test_cmp .git/diff.expect .git/diff.actual &&
		test_trace2_data fsm_client \
			settings/inotify-watch-limit-backoff 1 \
			<.git/diff.trace &&
		assert_backoff_main_index_write \
			.git/diff.trace "$PWD/.git/index" no &&
		test_grep ! \
			"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
			.git/diff.trace &&
		assert_backoff_full_proof .git/index &&
		assert_backoff_history_unchanged .git "$checkpoint"
	)
'

test_done
