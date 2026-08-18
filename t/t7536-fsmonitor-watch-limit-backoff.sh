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

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'unused global LFS preserves two mandatory backoff writes and recovery' '
	test_config_global filter.lfs.clean "git-lfs clean -- %f" &&
	test_config_global filter.lfs.smudge "git-lfs smudge -- %f" &&
	test_config_global filter.lfs.process "git-lfs filter-process" &&
	test_config_global filter.lfs.required true &&
	setup_backoff_bound_proof watch-backoff-unused-lfs &&
	(
		cd watch-backoff-unused-lfs &&
		checkpoint=$(cat .git/checkpoints) &&
		record_authenticated_backoff_marker &&
		test_write_lines staged-first >tracked &&
		test_write_lines staged-second >sibling &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/first-add.trace" \
			git add tracked &&
		test_trace2_data fsmonitor history/watch-limit-suspended 1 \
			<.git/first-add.trace &&
		assert_backoff_main_index_write \
			.git/first-add.trace "$PWD/.git/index" yes &&
		assert_backoff_pending_proof .git/index.before-backoff .git/index &&
		test_cmp_bin .git/checkpoint.before-backoff "$checkpoint" &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/second-add.trace" \
			git add sibling &&
		test_trace2_data fsmonitor history/watch-limit-suspended 1 \
			<.git/second-add.trace &&
		assert_backoff_main_index_write \
			.git/second-add.trace "$PWD/.git/index" yes &&
		assert_backoff_pending_proof .git/index.before-backoff .git/index &&
		test_cmp_bin .git/checkpoint.before-backoff "$checkpoint" &&
		git -c core.fsmonitor=false --no-optional-locks \
			show :tracked >.git/staged-tracked &&
		git -c core.fsmonitor=false --no-optional-locks \
			show :sibling >.git/staged-sibling &&
		test_cmp tracked .git/staged-tracked &&
		test_cmp sibling .git/staged-sibling &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			--no-optional-locks status --porcelain=v2 >.git/expected &&
		test_grep "^1 M\\. .* tracked$" .git/expected &&
		test_grep "^1 M\\. .* sibling$" .git/expected &&
		rm .git/fsmonitor--daemon.inotify-limit &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=// \
		GIT_TRACE2_EVENT="$PWD/.git/recovery.trace" \
			git status --porcelain=v2 >.git/recovery.actual &&
		test_cmp .git/expected .git/recovery.actual &&
		test_trace2_data fsmonitor token_closure/accepted 1 \
			<.git/recovery.trace &&
		assert_backoff_full_proof .git/index &&
		cp .git/index .git/recovered.before-warm &&
		# Scripted provider tokens restart in each Git invocation.
		# Check read-only reuse, not optional publication of a new token.
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/warm.trace" \
			git --no-optional-locks status --porcelain=v2 \
				>.git/warm.actual &&
		test_cmp .git/expected .git/warm.actual &&
		test_trace2_data fsmonitor config/coherent 1 <.git/warm.trace &&
		! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
			<.git/warm.trace &&
		assert_backoff_main_index_write \
			.git/warm.trace "$PWD/.git/index" no &&
		test_cmp_bin .git/recovered.before-warm .git/index &&
		test_grep ! \
			"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
			.git/first-add.trace .git/second-add.trace .git/recovery.trace \
			.git/warm.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'an activated clean filter converts content instead of retaining backoff proof' '
	test_config_global filter.lfs.clean "sed s/raw/converted/" &&
	test_config_global filter.lfs.smudge cat &&
	test_unconfig --global filter.lfs.process &&
	test_config_global filter.lfs.required true &&
	setup_backoff_bound_proof watch-backoff-active-filter &&
	(
		cd watch-backoff-active-filter &&
		record_authenticated_backoff_marker &&
		test_write_lines "tracked filter=lfs" >.gitattributes &&
		test_write_lines raw >tracked &&
		test_write_lines converted >.git/converted.expected &&
		cp .git/index .git/filtered.before &&
		cp .git/index .git/filtered.oracle.index &&
		GIT_INDEX_FILE="$PWD/.git/filtered.oracle.index" \
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				add tracked &&
		GIT_INDEX_FILE="$PWD/.git/filtered.oracle.index" \
			git -c core.fsmonitor=false write-tree >.git/expected-tree &&
		GIT_INDEX_FILE="$PWD/.git/filtered.oracle.index" \
			git -c core.fsmonitor=false show :tracked >.git/oracle-content &&
		test_cmp .git/converted.expected .git/oracle-content &&
		test_cmp_bin .git/filtered.before .git/index &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/filtered-add.trace" \
			git add tracked &&
		assert_backoff_main_index_write \
			.git/filtered-add.trace "$PWD/.git/index" yes &&
		git -c core.fsmonitor=false --no-optional-locks \
			show :tracked >.git/filtered-content &&
		test_cmp .git/converted.expected .git/filtered-content &&
		cp .git/index .git/filtered.actual.index &&
		GIT_INDEX_FILE="$PWD/.git/filtered.actual.index" \
			git -c core.fsmonitor=false write-tree >.git/actual-tree &&
		test_cmp .git/expected-tree .git/actual-tree &&
		test_grep ! "pending:" .git/index &&
		if assert_backoff_full_proof .git/index \
			>.git/filtered-proof.out 2>.git/filtered-proof.err
		then
			return 1
		else
			:
		fi &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			--no-optional-locks status --porcelain=v2 >.git/filtered.expected &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TRACE2_EVENT="$PWD/.git/filtered-status.trace" \
			git status --porcelain=v2 >.git/filtered.actual &&
		test_cmp .git/filtered.expected .git/filtered.actual &&
		test_grep "^1 M\\. .* tracked$" .git/filtered.actual &&
		test_grep "^? .gitattributes$" .git/filtered.actual &&
		test_grep ! \
			"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
			.git/filtered-add.trace .git/filtered-status.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'an activated required filter fails closed during backoff' '
	test_config_global filter.lfs.clean false &&
	test_config_global filter.lfs.smudge cat &&
	test_unconfig --global filter.lfs.process &&
	test_config_global filter.lfs.required true &&
	setup_backoff_bound_proof watch-backoff-required-filter &&
	(
		cd watch-backoff-required-filter &&
		record_authenticated_backoff_marker &&
		cp .git/index .git/required.before &&
		test_write_lines "tracked filter=lfs" >.git/info/attributes &&
		test-tool chmtime +120 tracked &&
		test_must_fail git -c core.fsmonitor=false \
			-c core.untrackedCache=false --no-optional-locks \
			diff -- tracked >.git/required.oracle.out \
				2>.git/required.oracle.err &&
		test_grep "clean filter .lfs. failed" .git/required.oracle.err &&
		test_cmp_bin .git/required.before .git/index &&
		test_must_fail env GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TRACE2_EVENT="$PWD/.git/required-status.trace" \
			git status --porcelain=v2 >.git/required-status.out \
				2>.git/required-status.err &&
		test_grep "clean filter .lfs. failed" .git/required-status.err &&
		test_cmp_bin .git/required.before .git/index &&
		test_must_fail env GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TRACE2_EVENT="$PWD/.git/required-add.trace" \
			git add tracked >.git/required-add.out \
				2>.git/required-add.err &&
		test_grep "clean filter .lfs. failed" .git/required-add.err &&
		test_cmp_bin .git/required.before .git/index &&
		assert_backoff_main_index_write \
			.git/required-add.trace "$PWD/.git/index" no &&
		test_grep ! \
			"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
			.git/required-status.trace .git/required-add.trace
	)
'

test_lazy_prereq STATUS_BULK_PRELOAD '
	test_create_repo backoff-bulk-preload-prereq &&
	(
		cd backoff-bulk-preload-prereq &&
		sane_unset GIT_TEST_PRELOAD_INDEX_BULK &&
		test_write_lines tracked >tracked &&
		test_write_lines sibling >sibling &&
		git -c core.fsmonitor=false add tracked sibling &&
		git -c core.fsmonitor=false commit -qm base &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_PRELOAD_INDEX=1 \
		GIT_TRACE2_EVENT="$PWD/.git/bulk.trace" \
			git -c core.fsmonitor=false \
				-c core.preloadIndex=true \
				-c core.preloadIndexBulk=true \
				status --porcelain=v2 >.git/actual &&
		test_must_be_empty .git/actual &&
		test_trace2_data index preload/bulk_result complete \
			<.git/bulk.trace
	)
'

configure_backoff_unused_lfs () {
	test_config_global filter.lfs.clean "git-lfs clean -- %f" &&
	test_config_global filter.lfs.smudge "git-lfs smudge -- %f" &&
	test_config_global filter.lfs.process "git-lfs filter-process" &&
	test_config_global filter.lfs.required true
}

extract_backoff_root_trace () {
	perl - "$1" <<-\EOF
	use strict;
	use warnings;
	open my $input, "<", $ARGV[0] or die "cannot read trace: $!\n";
	my @lines = <$input>;
	my ($root) = map { /"sid":"([^"]+)"/ ? $1 : () }
		grep { /"event":"start"/ } @lines;
	die "missing root Trace2 start\n" unless defined $root;
	print grep { /"sid":"\Q$root\E"/ } @lines;
	EOF
}

assert_backoff_no_bulk_scan () {
	! test_trace2_data index preload/bulk_useful "[0-9][0-9]*" <"$1" &&
	! test_trace2_data index preload/bulk_dirs "[0-9][0-9]*" <"$1" &&
	! test_trace2_data index preload/bulk_entries "[0-9][0-9]*" <"$1"
}

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'unused global LFS preserves clean add refresh with preload controls' '
	configure_backoff_unused_lfs &&
	setup_backoff_bound_proof watch-backoff-unused-lfs-refresh &&
	(
		cd watch-backoff-unused-lfs-refresh &&
		sane_unset GIT_TEST_PRELOAD_INDEX_BULK &&
		checkpoint=$(cat .git/checkpoints) &&
		record_authenticated_backoff_marker &&
		for preload in false true
		do
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TEST_PRELOAD_INDEX=1 \
			GIT_TRACE2_EVENT="$PWD/.git/refresh-$preload.trace" \
				git -c core.preloadIndex=$preload \
					-c core.preloadIndexBulk=$preload \
					add --refresh -- tracked \
						>".git/refresh-$preload.actual" &&
			test_must_be_empty ".git/refresh-$preload.actual" &&
			test_trace2_data fsmonitor history/watch-limit-suspended 1 \
				<".git/refresh-$preload.trace" &&
			assert_backoff_main_index_write \
				".git/refresh-$preload.trace" "$PWD/.git/index" no &&
			extract_backoff_root_trace ".git/refresh-$preload.trace" \
				>".git/refresh-$preload.root.trace" &&
			assert_backoff_no_bulk_scan \
				".git/refresh-$preload.root.trace" &&
			test_grep ! \
				"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
				".git/refresh-$preload.trace" &&
			assert_backoff_full_proof .git/index &&
			assert_backoff_history_unchanged .git "$checkpoint" || return 1
		done &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			--no-optional-locks status --porcelain=v2 \
				>.git/refresh.oracle &&
		test_must_be_empty .git/refresh.oracle
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'unused global LFS preserves dirty stash trees and reports bulk work' '
	if test_have_prereq STATUS_BULK_PRELOAD
	then
		bulk_available=yes
	else
		bulk_available=no
	fi &&
	configure_backoff_unused_lfs &&
	setup_backoff_bound_proof watch-backoff-unused-lfs-stash staged &&
	(
		cd watch-backoff-unused-lfs-stash &&
		sane_unset GIT_TEST_PRELOAD_INDEX_BULK &&
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
		for preload in false true
		do
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TEST_PRELOAD_INDEX=1 \
			GIT_TRACE2_EVENT="$PWD/.git/stash-$preload.trace" \
				git -c core.preloadIndex=$preload \
					-c core.preloadIndexBulk=$preload \
					stash create >".git/stash-$preload.oid" &&
			test_file_not_empty ".git/stash-$preload.oid" &&
			stash=$(cat ".git/stash-$preload.oid") &&
			git -c core.fsmonitor=false --no-optional-locks \
				rev-parse "$stash^2^{tree}" \
					>".git/stash-$preload.index-tree" &&
			test_cmp .git/expected-stash-tree \
				".git/stash-$preload.index-tree" &&
			git -c core.fsmonitor=false --no-optional-locks \
				rev-parse "$stash^{tree}" \
					>".git/stash-$preload.worktree-tree" &&
			git -c core.fsmonitor=false --no-optional-locks \
				show "$stash:tracked" >".git/stash-$preload.worktree" &&
			test_cmp tracked ".git/stash-$preload.worktree" &&
			git -c core.fsmonitor=false --no-optional-locks \
				show "$stash^2:sibling" >".git/stash-$preload.index" &&
			test_cmp sibling ".git/stash-$preload.index" &&
			test_must_fail git -c core.fsmonitor=false \
				--no-optional-locks rev-parse --verify refs/stash \
					>".git/stash-$preload.ref" \
					2>".git/stash-$preload.ref.err" &&
			test_trace2_data fsmonitor history/watch-limit-suspended 1 \
				<".git/stash-$preload.trace" &&
			snapshot_backoff_index_identity .git/index \
				>".git/stash-$preload.index.identity.after" &&
			test_cmp .git/stash.index.identity.before \
				".git/stash-$preload.index.identity.after" &&
			extract_backoff_root_trace ".git/stash-$preload.trace" \
				>".git/stash-$preload.root.trace" &&
			if test "$preload" = true && test "$bulk_available" = yes
			then
				test_trace2_data index preload/bulk_cache_nr 2 \
					<".git/stash-$preload.root.trace" &&
				test_trace2_data index preload/bulk_useful 2 \
					<".git/stash-$preload.root.trace" &&
				test_trace2_data index preload/bulk_result complete \
					<".git/stash-$preload.root.trace" &&
				test_trace2_data index preload/bulk_dirs "[1-9][0-9]*" \
					<".git/stash-$preload.root.trace" &&
				test_trace2_data index preload/bulk_entries "[1-9][0-9]*" \
					<".git/stash-$preload.root.trace"
			elif test "$preload" = false
			then
				assert_backoff_no_bulk_scan \
					".git/stash-$preload.root.trace"
			else
				:
			fi &&
			test_grep ! \
				"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
				".git/stash-$preload.trace" &&
			assert_backoff_full_proof .git/index &&
			assert_backoff_history_unchanged .git "$checkpoint" &&
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				--no-optional-locks status --porcelain=v2 \
					>".git/stash-$preload.after" &&
			test_cmp .git/stash.oracle ".git/stash-$preload.after" || return 1
		done &&
		test_cmp .git/stash-false.worktree-tree \
			.git/stash-true.worktree-tree
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'backoff membership changes invalidate proof and recover correct trees' '
	for operation in add-new remove rename
	do
		setup_backoff_bound_proof "watch-backoff-structural-$operation" &&
		(
			cd "watch-backoff-structural-$operation" &&
			record_authenticated_backoff_marker &&
			cp .git/index .git/structural.oracle.index &&
			case "$operation" in
			add-new)
				test_write_lines added-content >created &&
				GIT_INDEX_FILE="$PWD/.git/structural.oracle.index" \
					git -c core.fsmonitor=false \
						-c core.untrackedCache=false add created &&
				printf "A\\tcreated\\n" >.git/expected-names &&
				set -- git add created
				;;
			remove)
				GIT_INDEX_FILE="$PWD/.git/structural.oracle.index" \
					git -c core.fsmonitor=false \
						-c core.untrackedCache=false rm --cached tracked \
							>.git/oracle-remove.out &&
				printf "D\\ttracked\\n" >.git/expected-names &&
				set -- git rm tracked
				;;
			rename)
				tracked_oid=$(git -c core.fsmonitor=false \
					--no-optional-locks rev-parse :tracked) &&
				GIT_INDEX_FILE="$PWD/.git/structural.oracle.index" \
					git -c core.fsmonitor=false \
						update-index --force-remove tracked &&
				GIT_INDEX_FILE="$PWD/.git/structural.oracle.index" \
					git -c core.fsmonitor=false update-index --add \
						--cacheinfo "100644,$tracked_oid,renamed" &&
				printf "A\\trenamed\\nD\\ttracked\\n" >.git/expected-names &&
				set -- git mv tracked renamed
				;;
			esac &&
			GIT_INDEX_FILE="$PWD/.git/structural.oracle.index" \
				git -c core.fsmonitor=false write-tree \
					>.git/expected-tree &&
			test_cmp_bin .git/index.before-backoff .git/index &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TRACE2_EVENT="$PWD/.git/structural.trace" \
				"$@" >.git/structural.out &&
			assert_backoff_main_index_write \
				.git/structural.trace "$PWD/.git/index" yes &&
			git -c core.fsmonitor=false --no-optional-locks \
				diff --cached --name-status --no-renames \
					>.git/actual-names &&
			test_cmp .git/expected-names .git/actual-names &&
			cp .git/index .git/structural.actual.index &&
			GIT_INDEX_FILE="$PWD/.git/structural.actual.index" \
				git -c core.fsmonitor=false write-tree \
					>.git/actual-tree &&
			test_cmp .git/expected-tree .git/actual-tree &&
			test_grep ! "pending:" .git/index &&
			if assert_backoff_full_proof .git/index \
				>.git/structural-proof.out 2>.git/structural-proof.err
			then
				return 1
			else
				:
			fi &&
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				--no-optional-locks status --porcelain=v2 \
					>.git/expected &&
			test_file_not_empty .git/expected &&
			cp .git/index .git/structural.before-status &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TRACE2_EVENT="$PWD/.git/backoff-status.trace" \
				git status --porcelain=v2 >.git/backoff.actual &&
			test_cmp .git/expected .git/backoff.actual &&
			assert_backoff_main_index_write \
				.git/backoff-status.trace "$PWD/.git/index" no &&
			test_cmp_bin .git/structural.before-status .git/index &&
			rm .git/fsmonitor--daemon.inotify-limit &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=// \
			GIT_TRACE2_EVENT="$PWD/.git/recovery.trace" \
				git status --porcelain=v2 >.git/recovery.actual &&
			test_cmp .git/expected .git/recovery.actual &&
			test_trace2_data fsm_client query/trivial-response 1 \
				<.git/recovery.trace &&
			test_trace2_data fsmonitor token_closure/accepted 1 \
				<.git/recovery.trace &&
			assert_backoff_main_index_write \
				.git/recovery.trace "$PWD/.git/index" yes &&
			assert_backoff_full_proof .git/index &&
			cp .git/index .git/recovered.before-warm &&
			cp .git/index .git/recovered.oracle.index &&
			GIT_INDEX_FILE="$PWD/.git/recovered.oracle.index" \
				git -c core.fsmonitor=false write-tree \
					>.git/recovered-tree &&
			test_cmp .git/expected-tree .git/recovered-tree &&
			# Scripted tokens restart; qualify read-only warm reuse.
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/warm.trace" \
				git --no-optional-locks status --porcelain=v2 \
					>.git/warm.actual &&
			test_cmp .git/expected .git/warm.actual &&
			test_trace2_data fsmonitor config/coherent 1 <.git/warm.trace &&
			! test_trace2_data fsmonitor semantic/manifest-scan-count \
				"[1-9][0-9]*" <.git/warm.trace &&
			assert_backoff_main_index_write \
				.git/warm.trace "$PWD/.git/index" no &&
			test_cmp_bin .git/recovered.before-warm .git/index &&
			test_grep ! \
				"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
				.git/structural.trace .git/backoff-status.trace \
				.git/recovery.trace .git/warm.trace
		) || return 1
	done
'

setup_backoff_hook_pair () {
	test_create_repo "$1-main" &&
	test_when_finished "git -C \"$1-main\" -c core.fsmonitor=false \
		worktree remove --force \"../$1-linked\" >/dev/null 2>&1 || :" &&
	(
		cd "$1-main" &&
		test_commit base tracked &&
		test_commit sibling sibling &&
		git -c core.fsmonitor=false worktree add --detach "../$1-linked" HEAD &&
		git config core.autocrlf false &&
		git config core.preloadIndex false &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		for worktree in "$PWD" "$PWD/../$1-linked"
		do
			gitdir=$(git -C "$worktree" -c core.fsmonitor=false \
				--no-optional-locks rev-parse --absolute-git-dir) &&
			test_write_lines staged-before >"$worktree/sibling" &&
			git -C "$worktree" -c core.fsmonitor=false add sibling &&
			git -C "$worktree" -c core.fsmonitor=false write-tree \
				>"$gitdir/hook.expected-index-tree" &&
			test-tool chmtime -120 "$worktree/tracked" "$worktree/sibling" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" update-index --refresh &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 >"$gitdir/prime" &&
			git -C "$worktree" -c core.fsmonitor=false \
				-c core.untrackedCache=false --no-optional-locks \
				status --porcelain=v2 >"$gitdir/prime.expect" &&
			test_cmp "$gitdir/prime.expect" "$gitdir/prime" &&
			test_grep "^1 M\\. .* sibling$" "$gitdir/prime" &&
			assert_backoff_full_proof "$gitdir/index" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/checkpoint.trace" \
				git -C "$worktree" status --short >"$gitdir/checkpoint.status" &&
			test_trace2_data fsmonitor history/external-stored 1 \
				<"$gitdir/checkpoint.trace" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status >"$gitdir/sidecar.status" &&
			find "$gitdir" -maxdepth 1 -type f -name "index.csh1.*" \
				>"$gitdir/checkpoints" &&
			test_line_count = 1 "$gitdir/checkpoints" &&
			checkpoint=$(cat "$gitdir/checkpoints") &&
			assert_backoff_full_proof "$gitdir/index" &&
			cp "$gitdir/index" "$gitdir/index.before-backoff" &&
			cp "$checkpoint" "$gitdir/checkpoint.before-backoff" &&
			if test -f "$gitdir/index.csts"
			then
				cp "$gitdir/index.csts" "$gitdir/sidecar.before-backoff"
			else
				:
			fi || return 1
		done
	)
}

assert_backoff_checkpoint_unchanged () {
	test_cmp_bin "$1/checkpoint.before-backoff" "$2" &&
	if test -f "$1/sidecar.before-backoff"
	then
		test_cmp_bin "$1/sidecar.before-backoff" "$1/index.csts"
	else
		test_path_is_missing "$1/index.csts"
	fi
}

write_backoff_hook_identity_helper () {
	cat >"$1" <<-\EOF
	use strict;
	use warnings;
	use Cwd qw(abs_path getcwd);
	use File::Spec;
	use Fcntl qw(:mode);
	my ($mode, $path, $main) = @ARGV;
	my @selected = lstat($path) or die "cannot stat selected index: $!\n";
	die "selected index is not a singly linked regular file\n"
		unless S_ISREG($selected[2]) && $selected[3] == 1;
	if ($mode eq "identity") {
		print join(" ", @selected[0, 1, 2, 3, 4, 5, 7, 9, 10]), "\n";
	} elsif ($mode eq "relative") {
		print File::Spec->abs2rel(abs_path($path), getcwd()), "\n";
	} elsif ($mode eq "canonical") {
		my @authority = lstat($main) or die "cannot stat physical index: $!\n";
		my $selected_path = abs_path($path);
		my $physical_path = abs_path($main);
		die "hook did not receive the physical canonical index\n" unless
			defined($selected_path) && defined($physical_path) &&
			$selected_path eq $physical_path &&
			S_ISREG($authority[2]) && $authority[3] == 1 &&
			$selected[0] == $authority[0] && $selected[1] == $authority[1];
		print "$selected_path\n";
	} else {
		die "unknown hook index operation\n";
	}
	EOF
}

retain_backoff_linked_hook_evidence () {
	archive="$1/retained-linked-hook-$5" &&
	test_path_is_missing "$archive" &&
	mkdir "$archive" &&
	cp -R "$3" "$archive/hook" &&
	cp "$2/hook.expected-index-tree" "$archive/expected-index-tree" &&
	cp "$2/prime.expect" "$archive/expected-status" &&
	test_cmp "$2/hook.expected-index-tree" "$archive/expected-index-tree" &&
	test_cmp "$2/prime.expect" "$archive/expected-status" &&
	test_write_lines "$2" "$3" "$4" >"$archive/source-paths" &&
	cp "$2/index.before-backoff" "$archive/index.before" &&
	cp "$2/index" "$archive/index.after" &&
	snapshot_backoff_index_identity "$2/index" >"$archive/index.after.identity" &&
	cp "$2/checkpoint.before-backoff" "$archive/checkpoint.before" &&
	cp "$4" "$archive/checkpoint.after" &&
	snapshot_backoff_index_identity "$4" >"$archive/checkpoint.after.identity" &&
	if test -f "$2/sidecar.before-backoff"
	then
		cp "$2/sidecar.before-backoff" "$archive/sidecar.before" &&
		test_cmp_bin "$2/sidecar.before-backoff" "$archive/sidecar.before"
	else
		test_write_lines absent >"$archive/sidecar.before.absent"
	fi &&
	if test -f "$2/index.csts"
	then
		cp "$2/index.csts" "$archive/sidecar.after" &&
		test_cmp_bin "$2/index.csts" "$archive/sidecar.after"
	else
		test_write_lines absent >"$archive/sidecar.after.absent"
	fi &&
	test_cmp_bin "$2/index.before-backoff" "$archive/index.before" &&
	test_cmp_bin "$2/index" "$archive/index.after" &&
	test_cmp_bin "$2/checkpoint.before-backoff" "$archive/checkpoint.before" &&
	test_cmp_bin "$4" "$archive/checkpoint.after"
}
install_backoff_canonical_hook () {
	test_hook -C "$1" pre-commit <<-\EOF
	set -eu
	test -n "$GIT_INDEX_FILE"
	evidence=$BACKOFF_HOOK_EVIDENCE
	main=$BACKOFF_HOOK_MAIN_INDEX
	helper=$BACKOFF_HOOK_IDENTITY_HELPER
	printf "%s\n" "$GIT_INDEX_FILE" >"$evidence/index.env"
	perl "$helper" canonical "$GIT_INDEX_FILE" "$main" \
		>"$evidence/selected.path"
	perl "$helper" identity "$main" >"$evidence/main.identity.before"
	cp "$main" "$evidence/main.before"
	cp "$GIT_INDEX_FILE" "$evidence/selected.before"
	case "$BACKOFF_HOOK_ACTION" in
	refresh)
		GIT_TRACE2_EVENT="$evidence/refresh-emitted.trace" \
			git add --refresh -- tracked
		cp "$main" "$evidence/after-emitted"
		perl "$helper" identity "$main" >"$evidence/identity-emitted"
		absolute=$(dirname "$main")/./index
		relative=./$(perl "$helper" relative "$main")
		printf "%s\n" "$absolute" "$relative" >"$evidence/normalized.paths"
		GIT_INDEX_FILE="$absolute" \
		GIT_TRACE2_EVENT="$evidence/refresh-absolute.trace" \
			git add --refresh -- tracked
		cp "$main" "$evidence/after-absolute"
		perl "$helper" identity "$main" >"$evidence/identity-absolute"
		GIT_INDEX_FILE="$relative" \
		GIT_TRACE2_EVENT="$evidence/refresh-relative.trace" \
			git add --refresh -- tracked
		cp "$main" "$evidence/after-relative"
		perl "$helper" identity "$main" >"$evidence/identity-relative"
		;;
	stage)
		printf "%s\n" hook-first >tracked
		GIT_TRACE2_EVENT="$evidence/first-add.trace" git add tracked
		cp "$main" "$evidence/after-first"
		perl "$helper" identity "$main" >"$evidence/identity-first"
		printf "%s\n" hook-second >sibling
		GIT_TRACE2_EVENT="$evidence/second-add.trace" git add sibling
		cp "$main" "$evidence/after-second"
		perl "$helper" identity "$main" >"$evidence/identity-second"
		test-tool dump-cache-tree >"$evidence/cache-tree.before-write-tree"
		GIT_TRACE2_EVENT="$evidence/write-tree.trace" \
			git write-tree >"$evidence/write-tree"
		cp "$main" "$evidence/after-write-tree"
		perl "$helper" identity "$main" >"$evidence/identity-write-tree"
		;;
	*)
		exit 2
		;;
	esac
	cp "$main" "$evidence/main.after"
	perl "$helper" identity "$main" >"$evidence/main.identity.after"
	printf "%s\n" complete >"$evidence/completed"
	exit 1
	EOF
}

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'canonical pre-commit refresh preserves primary and linked backoff proofs' '
	sane_unset GIT_INDEX_FILE &&
	setup_backoff_hook_pair watch-backoff-hook-refresh &&
	common=$(git -C watch-backoff-hook-refresh-main -c core.fsmonitor=false \
		--no-optional-locks rev-parse --absolute-git-dir) &&
	write_backoff_hook_identity_helper "$common/hook-index.pl" &&
	install_backoff_canonical_hook watch-backoff-hook-refresh-main &&
	for kind in main linked
	do
		(
			cd "watch-backoff-hook-refresh-$kind" &&
			gitdir=$(git -c core.fsmonitor=false --no-optional-locks \
				rev-parse --absolute-git-dir) &&
			checkpoint=$(cat "$gitdir/checkpoints") &&
			evidence="$gitdir/hook-refresh-evidence" &&
			mkdir "$evidence" &&
			main_index=$(perl "$common/hook-index.pl" canonical \
				"$gitdir/index" "$gitdir/index") &&
			printf "%s\n" "$main_index" >"$evidence/expected.path" &&
			git -c core.fsmonitor=false --no-optional-locks \
				rev-parse HEAD >"$evidence/head.before" &&
			git -c core.fsmonitor=false --no-optional-locks \
				for-each-ref --format="%(refname) %(objectname)" \
					>"$evidence/refs.before" &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
				test-tool fsmonitor-client record-watch-limit &&
			test_must_fail env GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
				GIT_TRACE2_EVENT="$evidence/commit.trace" \
				BACKOFF_HOOK_ACTION=refresh BACKOFF_HOOK_EVIDENCE="$evidence" \
				BACKOFF_HOOK_MAIN_INDEX="$main_index" \
				BACKOFF_HOOK_IDENTITY_HELPER="$common/hook-index.pl" \
				git commit -qm "canonical refresh hook" &&
			test_grep "^complete$" "$evidence/completed" &&
			test_file_not_empty "$evidence/index.env" &&
			test_cmp "$evidence/expected.path" "$evidence/selected.path" &&
			assert_backoff_full_proof "$evidence/selected.before" &&
			for spelling in emitted absolute relative
			do
				test_cmp_bin "$evidence/selected.before" \
					"$evidence/after-$spelling" &&
				test_cmp "$evidence/main.identity.before" \
					"$evidence/identity-$spelling" &&
				assert_backoff_full_proof "$evidence/after-$spelling" &&
				test_trace2_data fsmonitor history/watch-limit-suspended 1 \
					<"$evidence/refresh-$spelling.trace" &&
				assert_backoff_main_index_write \
					"$evidence/refresh-$spelling.trace" "$main_index" no ||
					return 1
			done &&
			test_cmp "$evidence/main.identity.before" \
				"$evidence/main.identity.after" &&
			assert_backoff_history_unchanged "$gitdir" "$checkpoint" &&
			git -c core.fsmonitor=false --no-optional-locks \
				rev-parse HEAD >"$evidence/head.after" &&
			git -c core.fsmonitor=false --no-optional-locks \
				for-each-ref --format="%(refname) %(objectname)" \
					>"$evidence/refs.after" &&
			test_cmp "$evidence/head.before" "$evidence/head.after" &&
			test_cmp "$evidence/refs.before" "$evidence/refs.after" &&
			cp "$gitdir/index" "$evidence/tree.index" &&
			GIT_INDEX_FILE="$evidence/tree.index" \
				git -c core.fsmonitor=false write-tree >"$evidence/actual-tree" &&
			test_cmp "$gitdir/hook.expected-index-tree" "$evidence/actual-tree" &&
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				--no-optional-locks status --porcelain=v2 >"$evidence/status.after" &&
			test_cmp "$gitdir/prime.expect" "$evidence/status.after" &&
			test_grep ! \
				"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
				"$evidence/commit.trace" "$evidence"/refresh-*.trace &&
			if test "$kind" = linked
			then
				retain_backoff_linked_hook_evidence \
					"$common" "$gitdir" "$evidence" "$checkpoint" refresh
			else
				:
			fi
		) || return 1
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'canonical pre-commit staging retains pending history across repeated writes' '
	sane_unset GIT_INDEX_FILE &&
	setup_backoff_hook_pair watch-backoff-hook-stage &&
	common=$(git -C watch-backoff-hook-stage-main -c core.fsmonitor=false \
		--no-optional-locks rev-parse --absolute-git-dir) &&
	write_backoff_hook_identity_helper "$common/hook-index.pl" &&
	install_backoff_canonical_hook watch-backoff-hook-stage-main &&
	for kind in main linked
	do
		(
			cd "watch-backoff-hook-stage-$kind" &&
			gitdir=$(git -c core.fsmonitor=false --no-optional-locks \
				rev-parse --absolute-git-dir) &&
			checkpoint=$(cat "$gitdir/checkpoints") &&
			evidence="$gitdir/hook-stage-evidence" &&
			mkdir "$evidence" &&
			main_index=$(perl "$common/hook-index.pl" canonical \
				"$gitdir/index" "$gitdir/index") &&
			printf "%s\n" "$main_index" >"$evidence/expected.path" &&
			git -c core.fsmonitor=false --no-optional-locks \
				rev-parse HEAD >"$evidence/head.before" &&
			git -c core.fsmonitor=false --no-optional-locks \
				for-each-ref --format="%(refname) %(objectname)" \
					>"$evidence/refs.before" &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
				test-tool fsmonitor-client record-watch-limit &&
			test_must_fail env GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
				GIT_TRACE2_EVENT="$evidence/commit.trace" \
				BACKOFF_HOOK_ACTION=stage BACKOFF_HOOK_EVIDENCE="$evidence" \
				BACKOFF_HOOK_MAIN_INDEX="$main_index" \
				BACKOFF_HOOK_IDENTITY_HELPER="$common/hook-index.pl" \
				git commit -qm "canonical staging hook" &&
			test_grep "^complete$" "$evidence/completed" &&
			test_cmp "$evidence/expected.path" "$evidence/selected.path" &&
			assert_backoff_full_proof "$evidence/selected.before" &&
			for stage in first second
			do
				test_trace2_data fsmonitor history/watch-limit-suspended 1 \
					<"$evidence/$stage-add.trace" &&
				assert_backoff_main_index_write \
					"$evidence/$stage-add.trace" "$main_index" yes &&
				assert_backoff_pending_proof "$evidence/selected.before" \
					"$evidence/after-$stage" || return 1
			done &&
			test_grep "^invalid " "$evidence/cache-tree.before-write-tree" &&
			! test_cmp_bin "$evidence/selected.before" "$evidence/after-first" &&
			! test_cmp_bin "$evidence/after-first" "$evidence/after-second" &&
			test_cmp_bin "$evidence/after-second" "$evidence/after-write-tree" &&
			test_cmp "$evidence/identity-second" "$evidence/identity-write-tree" &&
			test_cmp_bin "$evidence/after-write-tree" "$gitdir/index" &&
			assert_backoff_pending_proof "$evidence/selected.before" "$gitdir/index" &&
			assert_backoff_checkpoint_unchanged "$gitdir" "$checkpoint" &&
			test_path_is_missing "$gitdir/index.lock" &&
			cp "$evidence/selected.before" "$evidence/oracle.index" &&
			GIT_INDEX_FILE="$evidence/oracle.index" \
				git -c core.fsmonitor=false -c core.untrackedCache=false \
					add tracked sibling &&
			GIT_INDEX_FILE="$evidence/oracle.index" \
				git -c core.fsmonitor=false write-tree >"$evidence/expected-tree" &&
			test_cmp "$evidence/expected-tree" "$evidence/write-tree" &&
			cp "$gitdir/index" "$evidence/actual.index" &&
			GIT_INDEX_FILE="$evidence/actual.index" \
				git -c core.fsmonitor=false write-tree >"$evidence/actual-tree" &&
			test_cmp "$evidence/expected-tree" "$evidence/actual-tree" &&
			git -c core.fsmonitor=false --no-optional-locks \
				show :tracked >"$evidence/staged-tracked" &&
			git -c core.fsmonitor=false --no-optional-locks \
				show :sibling >"$evidence/staged-sibling" &&
			test_cmp tracked "$evidence/staged-tracked" &&
			test_cmp sibling "$evidence/staged-sibling" &&
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				--no-optional-locks status --porcelain=v2 >"$evidence/status.expected" &&
			test_grep "^1 M\\. .* tracked$" "$evidence/status.expected" &&
			test_grep "^1 M\\. .* sibling$" "$evidence/status.expected" &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TRACE2_EVENT="$evidence/status.trace" \
				git status --porcelain=v2 >"$evidence/status.actual" &&
			test_cmp "$evidence/status.expected" "$evidence/status.actual" &&
			test_cmp_bin "$evidence/after-second" "$gitdir/index" &&
			assert_backoff_checkpoint_unchanged "$gitdir" "$checkpoint" &&
			git -c core.fsmonitor=false --no-optional-locks \
				rev-parse HEAD >"$evidence/head.after" &&
			git -c core.fsmonitor=false --no-optional-locks \
				for-each-ref --format="%(refname) %(objectname)" \
					>"$evidence/refs.after" &&
			test_cmp "$evidence/head.before" "$evidence/head.after" &&
			test_cmp "$evidence/refs.before" "$evidence/refs.after" &&
			test_grep ! \
				"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
				"$evidence/commit.trace" "$evidence/first-add.trace" \
				"$evidence/second-add.trace" "$evidence/write-tree.trace" \
				"$evidence/status.trace" &&
			if test "$kind" = linked
			then
				retain_backoff_linked_hook_evidence \
					"$common" "$gitdir" "$evidence" "$checkpoint" stage
			else
				:
			fi
		) || return 1
	done
'

test_lazy_prereq HARDLINKS '
	: >hardlink-a &&
	ln hardlink-a hardlink-b
'

write_backoff_rejected_index_helper () {
	cat >"$1" <<-\EOF
	use strict;
	use warnings;
	use Cwd qw(abs_path);
	use File::Basename qw(basename dirname);
	use Fcntl qw(:mode);
	my ($operation, $kind, $path, $main) = @ARGV;
	my $dir = abs_path(dirname($main)) or die "cannot resolve gitdir\n";
	my $physical = "$dir/index";
	my @authority = lstat($main) or die "cannot stat physical index: $!\n";
	my @selected = lstat($path) or die "cannot stat selected index: $!\n";
	my $parent = abs_path(dirname($path)) or die "cannot resolve selected parent\n";
	my $named = "$parent/" . basename($path);
	die "invalid physical index authority\n" unless
		S_ISREG($authority[2]) && $authority[4] == $> &&
		abs_path($main) eq $physical;
	die "selected path is not fixture-owned\n" unless
		$selected[4] == $> && $parent eq $dir && $named ne $physical;
	my $same = $selected[0] == $authority[0] &&
		$selected[1] == $authority[1];
	if ($operation eq "temporary") {
		die "selected index is not an independent regular lockfile\n" unless
			S_ISREG($selected[2]) && $selected[3] == 1 &&
			$authority[3] == 1 && !$same &&
			abs_path($path) eq $named;
		die "unexpected commit -a index\n" if
			$kind eq "all" && $named ne "$physical.lock";
		die "unexpected partial-commit index\n" if
			$kind eq "partial" &&
			$named !~ /\A\Q$dir\E\/next-index-[0-9]+\.lock\z/;
		die "unknown commit style\n" unless $kind eq "all" || $kind eq "partial";
		print "$named\n";
	} elsif ($operation eq "alias") {
		die "unexpected owned alias name\n" unless
			$named eq "$dir/index.alias-$kind";
		if ($kind eq "copy") {
			die "invalid copied-index control\n" unless
				S_ISREG($selected[2]) && $selected[3] == 1 &&
				$authority[3] == 1 && !$same;
		} elsif ($kind eq "symlink") {
			my @target = stat($path) or die "cannot stat alias target: $!\n";
			die "invalid leaf-symlink control\n" unless
				S_ISLNK($selected[2]) && $selected[3] == 1 &&
				$authority[3] == 1 && readlink($path) eq "index" &&
				$target[0] == $authority[0] && $target[1] == $authority[1];
		} elsif ($kind eq "hardlink") {
			die "invalid hardlink control\n" unless
				S_ISREG($selected[2]) && $selected[3] == 2 &&
				$authority[3] == 2 && $same;
		} else {
			die "unknown alias kind\n";
		}
		print join(" ", @selected[0, 1, 2, 3, 4, 5, 7, 9, 10]), "\n";
	} else {
		die "unknown rejected-index operation\n";
	}
	EOF
}

assert_backoff_rejected_index_trace () {
	test_trace2_data fsm_client settings/inotify-watch-limit-backoff 1 <"$1" &&
	! test_trace2_data fsmonitor history/watch-limit-suspended 1 <"$1" &&
	! test_trace2_data fsmonitor token_closure/accepted 1 <"$1" &&
	! test_trace2_data fsmonitor config/revalidated 1 <"$1" &&
	! test_trace2_data fsmonitor config/tracked-epoch-valid 1 <"$1" &&
	! test_trace2_data status clean-proof/hit 1 <"$1" &&
	! test_trace2_data status clean-proof/sidecar 1 <"$1" &&
	test_grep ! "\"event\":\"child_start\".*\"fsmonitor--daemon\"" "$1"
}

install_backoff_temporary_hook () {
	test_hook -C "$1" pre-commit <<-\EOF
	set -eu
	test -n "$GIT_INDEX_FILE"
	evidence=$BACKOFF_HOOK_EVIDENCE
	main=$BACKOFF_HOOK_MAIN_INDEX
	helper=$BACKOFF_HOOK_IDENTITY_HELPER
	reject=$BACKOFF_HOOK_REJECT_HELPER
	printf "%s\n" "$GIT_INDEX_FILE" >"$evidence/index.env"
	selected=$(perl "$reject" temporary "$BACKOFF_HOOK_STYLE" \
		"$GIT_INDEX_FILE" "$main")
	printf "%s\n" "$selected" >"$evidence/selected.path"
	perl "$helper" identity "$main" >"$evidence/main.identity.hook-before"
	perl "$helper" identity "$selected" >"$evidence/selected.identity.original"
	cp "$selected" "$evidence/selected.original"
	cp "$selected" "$evidence/original-tree.index"
	GIT_INDEX_FILE="$evidence/original-tree.index" \
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			write-tree >"$evidence/original-tree"
	cmp "$evidence/main.seed" "$main"
	perl "$reject" temporary "$BACKOFF_HOOK_STYLE" \
		"$GIT_INDEX_FILE" "$main" >"$evidence/selected.path.rechecked"
	cmp "$evidence/selected.path" "$evidence/selected.path.rechecked"
	# Deliberately inject the canonical proof into the genuine private index.
	# Its naturally produced contents are retained separately above.
	cp "$main" "$selected"
	cp "$selected" "$evidence/selected.seeded"
	GIT_TRACE2_EVENT="$evidence/refresh.trace" \
		git add --refresh -- sibling
	perl "$reject" temporary "$BACKOFF_HOOK_STYLE" \
		"$GIT_INDEX_FILE" "$main" >"$evidence/selected.path.after"
	cp "$selected" "$evidence/selected.after"
	cp "$selected" "$evidence/after-tree.index"
	GIT_INDEX_FILE="$evidence/after-tree.index" \
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			write-tree >"$evidence/after-tree"
	cp "$main" "$evidence/main.after-hook"
	perl "$helper" identity "$main" >"$evidence/main.identity.hook-after"
	printf "%s\n" complete >"$evidence/completed"
	exit 1
	EOF
}

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'commit temporary indexes and noncanonical aliases reject backoff authority' '
	sane_unset GIT_INDEX_FILE &&
	for style in all partial
	do
		setup_backoff_bound_proof "watch-backoff-hook-reject-$style" staged &&
		write_backoff_hook_identity_helper \
			"watch-backoff-hook-reject-$style/.git/hook-index.pl" &&
		write_backoff_rejected_index_helper \
			"watch-backoff-hook-reject-$style/.git/rejected-index.pl" &&
		install_backoff_temporary_hook "watch-backoff-hook-reject-$style" &&
		(
			cd "watch-backoff-hook-reject-$style" &&
			gitdir=$(git -c core.fsmonitor=false --no-optional-locks \
				rev-parse --absolute-git-dir) &&
			main_index="$gitdir/index" &&
			checkpoint=$(cat .git/checkpoints) &&
			evidence="$gitdir/hook-reject-evidence" &&
			mkdir "$evidence" &&
			test_write_lines worktree-change >tracked &&
			cp "$main_index" "$evidence/main.seed" &&
			assert_backoff_full_proof "$evidence/main.seed" &&
			cp "$main_index" "$evidence/oracle-main.index" &&
			GIT_INDEX_FILE="$evidence/oracle-main.index" \
				git -c core.fsmonitor=false -c core.untrackedCache=false \
					write-tree >"$evidence/expected-main-tree" &&
			case "$style" in
			all)
				cp "$main_index" "$evidence/oracle-selected.index" &&
				GIT_INDEX_FILE="$evidence/oracle-selected.index" \
					git -c core.fsmonitor=false -c core.untrackedCache=false add -u &&
				set -- -a
				;;
			partial)
				GIT_INDEX_FILE="$evidence/oracle-selected.index" \
					git -c core.fsmonitor=false -c core.untrackedCache=false read-tree HEAD &&
				GIT_INDEX_FILE="$evidence/oracle-selected.index" \
					git -c core.fsmonitor=false -c core.untrackedCache=false add -- tracked &&
				set -- -- tracked
				;;
			esac &&
			GIT_INDEX_FILE="$evidence/oracle-selected.index" \
				git -c core.fsmonitor=false -c core.untrackedCache=false \
					write-tree >"$evidence/expected-selected-tree" &&
			! test_cmp "$evidence/expected-main-tree" "$evidence/expected-selected-tree" &&
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				--no-optional-locks status --porcelain=v2 >"$evidence/status.before" &&
			test_grep "^1 \\.M .* tracked$" "$evidence/status.before" &&
			test_grep "^1 M\\. .* sibling$" "$evidence/status.before" &&
			git -c core.fsmonitor=false --no-optional-locks \
				rev-parse HEAD >"$evidence/head.before" &&
			git -c core.fsmonitor=false --no-optional-locks \
				for-each-ref --format="%(refname) %(objectname)" >"$evidence/refs.before" &&
			snapshot_backoff_index_identity "$main_index" >"$evidence/main.identity.before" &&
			record_authenticated_backoff_marker &&
			test_must_fail env GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
				GIT_TRACE2_EVENT="$evidence/commit.trace" \
				BACKOFF_HOOK_STYLE="$style" BACKOFF_HOOK_EVIDENCE="$evidence" \
				BACKOFF_HOOK_MAIN_INDEX="$main_index" \
				BACKOFF_HOOK_IDENTITY_HELPER="$gitdir/hook-index.pl" \
				BACKOFF_HOOK_REJECT_HELPER="$gitdir/rejected-index.pl" \
				git commit -qm "temporary index hook" "$@" &&
			test_grep "^complete$" "$evidence/completed" &&
			test_cmp "$evidence/expected-selected-tree" "$evidence/original-tree" &&
			test_cmp "$evidence/expected-main-tree" "$evidence/after-tree" &&
			test_cmp_bin "$evidence/main.seed" "$evidence/selected.seeded" &&
			assert_backoff_full_proof "$evidence/selected.seeded" &&
			assert_backoff_rejected_index_trace "$evidence/refresh.trace" &&
			test_region index do_write_index "$evidence/refresh.trace" &&
			test_grep ! "pending:" "$evidence/selected.after" &&
			if assert_backoff_full_proof "$evidence/selected.after" \
				>"$evidence/rejected-proof.out" 2>"$evidence/rejected-proof.err"
			then
				return 1
			else
				:
			fi &&
			test_cmp "$evidence/selected.path" "$evidence/selected.path.after" &&
			test_cmp_bin "$evidence/main.seed" "$evidence/main.after-hook" &&
			test_cmp "$evidence/main.identity.before" "$evidence/main.identity.hook-before" &&
			test_cmp "$evidence/main.identity.before" "$evidence/main.identity.hook-after" &&
			snapshot_backoff_index_identity "$main_index" >"$evidence/main.identity.after" &&
			test_cmp "$evidence/main.identity.before" "$evidence/main.identity.after" &&
			assert_backoff_full_proof "$main_index" &&
			assert_backoff_history_unchanged .git "$checkpoint" &&
			selected=$(cat "$evidence/selected.path") &&
			test_path_is_missing "$selected" &&
			test_path_is_missing "$selected.lock" &&
			find "$gitdir" -maxdepth 1 -name "next-index-*.lock" \
				>"$evidence/remaining-temporary-indexes" &&
			test_must_be_empty "$evidence/remaining-temporary-indexes" &&
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				--no-optional-locks status --porcelain=v2 >"$evidence/status.after" &&
			test_cmp "$evidence/status.before" "$evidence/status.after" &&
			git -c core.fsmonitor=false --no-optional-locks \
				rev-parse HEAD >"$evidence/head.after" &&
			git -c core.fsmonitor=false --no-optional-locks \
				for-each-ref --format="%(refname) %(objectname)" >"$evidence/refs.after" &&
			test_cmp "$evidence/head.before" "$evidence/head.after" &&
			test_cmp "$evidence/refs.before" "$evidence/refs.after" &&
			test_grep ! "\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
				"$evidence/commit.trace"
		) || return 1
	done &&
	setup_backoff_bound_proof watch-backoff-index-aliases &&
	test_when_finished "rm -f \
		\"$PWD/watch-backoff-index-aliases/.git/index.alias-copy\" \
		\"$PWD/watch-backoff-index-aliases/.git/index.alias-symlink\" \
		\"$PWD/watch-backoff-index-aliases/.git/index.alias-hardlink\"" &&
	(
		cd watch-backoff-index-aliases &&
		gitdir=$(git -c core.fsmonitor=false --no-optional-locks \
			rev-parse --absolute-git-dir) &&
		main_index="$gitdir/index" &&
		checkpoint=$(cat .git/checkpoints) &&
		evidence="$gitdir/alias-evidence" &&
		mkdir "$evidence" &&
		write_backoff_rejected_index_helper "$gitdir/rejected-index.pl" &&
		test_write_lines changed >tracked &&
		test_write_lines visible >visible &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			--no-optional-locks status --porcelain=v2 >"$evidence/status.expected" &&
		test_grep "^1 \\.M .* tracked$" "$evidence/status.expected" &&
		test_grep "^? visible$" "$evidence/status.expected" &&
		record_authenticated_backoff_marker &&
		for kind in copy symlink hardlink
		do
			case "$kind" in
			copy) alias_prereq= ;;
			symlink) alias_prereq=SYMLINKS ;;
			hardlink) alias_prereq=HARDLINKS ;;
			esac &&
			if test -n "$alias_prereq" && ! test_have_prereq "$alias_prereq"
			then
				test_write_lines "$alias_prereq prerequisite unavailable" \
					>"$evidence/$kind.skipped" &&
				continue
			fi &&
			alias="$gitdir/index.alias-$kind" &&
			test_path_is_missing "$alias" &&
			snapshot_backoff_index_identity "$main_index" \
				>"$evidence/$kind.main.before-setup" &&
			case "$kind" in
			copy) cp "$main_index" "$alias" ;;
			symlink) ln -s index "$alias" ;;
			hardlink) ln "$main_index" "$alias" ;;
			esac &&
			perl "$gitdir/rejected-index.pl" alias "$kind" "$alias" "$main_index" \
				>"$evidence/$kind.selected.before" &&
			snapshot_backoff_index_identity "$main_index" \
				>"$evidence/$kind.main.after-setup" &&
			cp "$alias" "$evidence/$kind.seeded" &&
			test_cmp_bin .git/index.before-backoff "$evidence/$kind.seeded" &&
			assert_backoff_full_proof "$evidence/$kind.seeded" &&
			GIT_INDEX_FILE="$alias" GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TRACE2_EVENT="$evidence/$kind.trace" \
				git --no-optional-locks status --porcelain=v2 \
					>"$evidence/$kind.status" &&
			test_cmp "$evidence/status.expected" "$evidence/$kind.status" &&
			assert_backoff_rejected_index_trace "$evidence/$kind.trace" &&
			test_region ! index do_write_index "$evidence/$kind.trace" &&
			test_cmp_bin "$evidence/$kind.seeded" "$alias" &&
			perl "$gitdir/rejected-index.pl" alias "$kind" "$alias" "$main_index" \
				>"$evidence/$kind.selected.after" &&
			test_cmp "$evidence/$kind.selected.before" "$evidence/$kind.selected.after" &&
			snapshot_backoff_index_identity "$main_index" \
				>"$evidence/$kind.main.after-probe" &&
			test_cmp "$evidence/$kind.main.after-setup" "$evidence/$kind.main.after-probe" &&
			assert_backoff_history_unchanged .git "$checkpoint" &&
			rm "$alias" &&
			test_path_is_missing "$alias" &&
			snapshot_backoff_index_identity "$main_index" \
				>"$evidence/$kind.main.after-cleanup" &&
			assert_backoff_history_unchanged .git "$checkpoint" || return 1
		done
	)
'

make_backoff_patch_series () (
	shape=$1 &&
	git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD \
		>.git/patch-base.commit &&
	parent=$(cat .git/patch-base.commit) &&
	cp .git/index .git/patch-maker.index &&
	for step in first second
	do
		case "$step" in
		first) patch_target=tracked ;;
		second) patch_target=sibling ;;
		esac &&
		test_write_lines "patched-$step" >".git/patch-$step.contents" &&
		oid=$(git -c core.fsmonitor=false hash-object -w --stdin \
			<".git/patch-$step.contents") &&
		GIT_INDEX_FILE="$PWD/.git/patch-maker.index" \
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				update-index --cacheinfo "100644,$oid,$patch_target" &&
		if test "$shape" = mixed
		then
			test_write_lines created >.git/patch-created.contents &&
			oid=$(git -c core.fsmonitor=false hash-object -w --stdin \
				<.git/patch-created.contents) &&
			GIT_INDEX_FILE="$PWD/.git/patch-maker.index" \
				git -c core.fsmonitor=false -c core.untrackedCache=false \
					update-index --add \
					--cacheinfo "100644,$oid,zz-created"
		else
			:
		fi &&
		GIT_INDEX_FILE="$PWD/.git/patch-maker.index" \
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				write-tree >".git/patch-$step.tree" &&
		tree=$(cat ".git/patch-$step.tree") &&
		commit=$(git -c core.fsmonitor=false -c commit.gpgSign=false \
			commit-tree "$tree" -p "$parent" -m "backoff $step") &&
		test_write_lines "$commit" >".git/patch-$step.commit" &&
		git -c core.fsmonitor=false --no-optional-locks \
			diff-tree --binary --full-index --no-renames --no-commit-id -p \
				"$parent" "$commit" -- >".git/patch-$step.diff" &&
		git -c core.fsmonitor=false --no-optional-locks \
			format-patch -1 --stdout --no-signature --no-renames "$commit" \
				>".git/patch-$step.mbox" &&
		parent=$commit || return 1
		test "$shape" != mixed || break
	done &&
	test_cmp_bin .git/index.before-backoff .git/index
)

assert_backoff_patch_tree () {
	cp "$1" "$2.actual.index" &&
	GIT_INDEX_FILE="$PWD/$2.actual.index" \
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			write-tree >"$2.actual.tree" &&
	test_cmp "$2.tree" "$2.actual.tree"
}

recover_backoff_patch_history () {
	expected_status=$1 &&
	expected_tree=$2 &&
	rm .git/fsmonitor--daemon.inotify-limit &&
	GIT_INDEX_FILE="$PWD/.git/index" \
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCCCCCC \
	GIT_TEST_FSMONITOR_QUERY_PATH=// \
	GIT_TRACE2_EVENT="$PWD/.git/patch-recovery.trace" \
		git status --porcelain=v2 >.git/patch-recovery.actual &&
	test_cmp "$expected_status" .git/patch-recovery.actual &&
	test_trace2_data fsm_client query/trivial-response 1 \
		<.git/patch-recovery.trace &&
	test_trace2_data fsmonitor token_closure/accepted 1 \
		<.git/patch-recovery.trace &&
	assert_backoff_full_proof .git/index &&
	cp .git/index .git/patch-recovered.index &&
	cp .git/index .git/patch-recovered.oracle.index &&
	GIT_INDEX_FILE="$PWD/.git/patch-recovered.oracle.index" \
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			write-tree >.git/patch-recovered.tree &&
	test_cmp "$expected_tree" .git/patch-recovered.tree &&
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
	GIT_TRACE2_EVENT="$PWD/.git/patch-warm.trace" \
		git --no-optional-locks status --porcelain=v2 \
			>.git/patch-warm.actual &&
	test_cmp "$expected_status" .git/patch-warm.actual &&
	test_trace2_data fsmonitor config/coherent 1 <.git/patch-warm.trace &&
	! test_trace2_data fsmonitor semantic/manifest-scan-count \
		"[1-9][0-9]*" <.git/patch-warm.trace &&
	assert_backoff_main_index_write .git/patch-warm.trace \
		"$PWD/.git/index" no &&
	test_cmp_bin .git/patch-recovered.index .git/index &&
	test_grep ! \
		"\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
		.git/patch-*.trace
}

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'apply and am retain pending backoff history across same-path patches' '
	for operation in apply am
	do
		setup_backoff_bound_proof "watch-backoff-patch-$operation" &&
		(
			cd "watch-backoff-patch-$operation" &&
			checkpoint=$(cat .git/checkpoints) &&
			make_backoff_patch_series same-path &&
			cp .git/patch-base.commit .git/patch-previous.commit &&
			record_authenticated_backoff_marker &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/patch-noop.trace" \
				git --no-optional-locks status --porcelain=v2 \
					>.git/patch-noop.actual &&
			test_cmp .git/prime.expect .git/patch-noop.actual &&
			test_trace2_data fsmonitor history/watch-limit-suspended 1 \
				<.git/patch-noop.trace &&
			assert_backoff_history_unchanged .git "$checkpoint" &&
			test_write_lines visible >visible &&
			for step in first second
			do
				case "$operation" in
				apply) set -- git apply --index ".git/patch-$step.diff" ;;
				am) set -- git am ".git/patch-$step.mbox" ;;
				esac &&
				GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
				GIT_TRACE2_EVENT="$PWD/.git/patch-$step.trace" \
					"$@" >".git/patch-$step.out" &&
				cp .git/index ".git/patch-after-$step.index" &&
				snapshot_backoff_index_identity .git/index \
					>".git/patch-after-$step.identity" &&
				assert_backoff_pending_proof .git/index.before-backoff \
					".git/patch-after-$step.index" &&
				test_trace2_data fsmonitor history/watch-limit-suspended 1 \
					<".git/patch-$step.trace" &&
				assert_backoff_main_index_write ".git/patch-$step.trace" \
					"$PWD/.git/index" yes &&
				assert_backoff_checkpoint_unchanged .git "$checkpoint" &&
				assert_backoff_patch_tree ".git/patch-after-$step.index" \
					".git/patch-$step" &&
				git -c core.fsmonitor=false --no-optional-locks \
					rev-parse HEAD >".git/patch-$step.head" &&
				if test "$operation" = am
				then
					git -c core.fsmonitor=false --no-optional-locks \
						rev-parse HEAD^ >".git/patch-$step.parent" &&
					test_cmp .git/patch-previous.commit \
						".git/patch-$step.parent" &&
					git -c core.fsmonitor=false --no-optional-locks \
						rev-parse HEAD^{tree} >".git/patch-$step.head-tree" &&
					test_cmp ".git/patch-$step.tree" \
						".git/patch-$step.head-tree" &&
					cp ".git/patch-$step.head" .git/patch-previous.commit &&
					test_path_is_missing .git/rebase-apply
				else
					test_cmp .git/patch-base.commit ".git/patch-$step.head"
				fi || return 1
			done &&
			test_cmp .git/patch-first.contents tracked &&
			test_cmp .git/patch-second.contents sibling &&
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				--no-optional-locks status --porcelain=v2 \
					>.git/patch-status.expected &&
			test_grep "^? visible$" .git/patch-status.expected &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/patch-status.trace" \
				git --no-optional-locks status --porcelain=v2 \
					>.git/patch-status.actual &&
			test_cmp .git/patch-status.expected .git/patch-status.actual &&
			test_cmp_bin .git/patch-after-second.index .git/index &&
			assert_backoff_pending_proof .git/index.before-backoff .git/index &&
			! test_trace2_data fsmonitor token_closure/accepted 1 \
				<.git/patch-status.trace &&
			recover_backoff_patch_history .git/patch-status.expected \
				.git/patch-second.tree
		) || return 1
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'a structural patch revokes backoff history for the complete apply or am batch' '
	for operation in apply am
	do
		setup_backoff_bound_proof "watch-backoff-mixed-patch-$operation" &&
		(
			cd "watch-backoff-mixed-patch-$operation" &&
			make_backoff_patch_series mixed &&
			git -c core.fsmonitor=false --no-optional-locks \
				diff-tree --no-commit-id --name-status --no-renames \
					"$(cat .git/patch-base.commit)" \
					"$(cat .git/patch-first.commit)" \
						>.git/patch-first.names &&
			printf "M\ttracked\nA\tzz-created\n" >.git/patch-expected.names &&
			test_cmp .git/patch-expected.names .git/patch-first.names &&
			record_authenticated_backoff_marker &&
			test_write_lines visible >visible &&
			case "$operation" in
			apply) set -- git apply --index .git/patch-first.diff ;;
			am) set -- git am .git/patch-first.mbox ;;
			esac &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/patch-first.trace" \
				"$@" >.git/patch-first.out &&
			cp .git/index .git/patch-after-first.index &&
			snapshot_backoff_index_identity .git/index \
				>.git/patch-after-first.identity &&
			test_trace2_data fsmonitor history/watch-limit-suspended 1 \
				<.git/patch-first.trace &&
			assert_backoff_main_index_write .git/patch-first.trace \
				"$PWD/.git/index" yes &&
			test_grep ! FSUC .git/patch-after-first.index &&
			test_grep ! "pending:" .git/patch-after-first.index &&
			if assert_backoff_full_proof .git/patch-after-first.index \
				>.git/patch-proof.out 2>.git/patch-proof.err
			then
				return 1
			else
				:
			fi &&
			assert_backoff_patch_tree .git/patch-after-first.index \
				.git/patch-first &&
			test_cmp .git/patch-first.contents tracked &&
			test_cmp .git/patch-created.contents zz-created &&
			git -c core.fsmonitor=false --no-optional-locks \
				rev-parse HEAD >.git/patch-first.head &&
			if test "$operation" = am
			then
				git -c core.fsmonitor=false --no-optional-locks \
					rev-parse HEAD^ >.git/patch-first.parent &&
				test_cmp .git/patch-base.commit .git/patch-first.parent &&
				git -c core.fsmonitor=false --no-optional-locks \
					rev-parse HEAD^{tree} >.git/patch-first.head-tree &&
				test_cmp .git/patch-first.tree .git/patch-first.head-tree &&
				test_path_is_missing .git/rebase-apply
			else
				test_cmp .git/patch-base.commit .git/patch-first.head
			fi &&
			git -c core.fsmonitor=false -c core.untrackedCache=false \
				--no-optional-locks status --porcelain=v2 \
					>.git/patch-status.expected &&
			test_grep "^? visible$" .git/patch-status.expected &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$PWD/.git/patch-status.trace" \
				git --no-optional-locks status --porcelain=v2 \
					>.git/patch-status.actual &&
			test_cmp .git/patch-status.expected .git/patch-status.actual &&
			test_cmp_bin .git/patch-after-first.index .git/index &&
			! test_trace2_data fsmonitor token_closure/accepted 1 \
				<.git/patch-status.trace &&
			recover_backoff_patch_history .git/patch-status.expected \
				.git/patch-first.tree
		) || return 1
	done
'

# A successful COMMIT_NORMAL publishes the lockfile handed to pre-commit.
# The older hook tests abort before that publication.  Keep the immediate
# on-disk result separate from any later status which could repair it.
backoff_commit_index () (
	selected_index=$1 &&
	shift &&
	sane_unset GIT_TEST_PRELOAD_INDEX_BULK \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE GIT_TEST_FSMONITOR_QUERY_PATH &&
	GIT_INDEX_FILE="$selected_index" \
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			-c core.preloadIndex=false -c core.preloadIndexBulk=false \
			--no-optional-locks "$@"
)

backoff_commit_entries () {
	# Include the stage, mode, object ID, name, and assume/skip-worktree flags.
	backoff_commit_index "$1" ls-files --stage -v -z
}

assert_backoff_commit_unbound () {
	test_grep ! "pending:" "$1" &&
	if assert_backoff_full_proof "$1" >"$2.out" 2>"$2.err"
	then
		echo "unexpected complete proof in $1" >&2 &&
		return 1
	else
		:
	fi
}

install_backoff_successful_commit_hook () {
	test_hook -C "$1" pre-commit <<-\EOF
	set -eu
	test -n "$GIT_INDEX_FILE"
	evidence=$BACKOFF_HOOK_EVIDENCE
	main=$BACKOFF_HOOK_MAIN_INDEX
	helper=$BACKOFF_HOOK_IDENTITY_HELPER
	reject=$BACKOFF_HOOK_REJECT_HELPER
	printf "%s\n" "$GIT_INDEX_FILE" >"$evidence/index.env"
	selected=$(perl "$reject" temporary "$BACKOFF_HOOK_STYLE" \
		"$GIT_INDEX_FILE" "$main")
	printf "%s\n" "$selected" >"$evidence/selected.path"
	perl "$helper" identity "$main" >"$evidence/main.identity.hook-before"
	cp "$main" "$evidence/main.in-hook.before"
	cp "$selected" "$evidence/selected.before"
	if test "$BACKOFF_HOOK_STYLE" = partial
	then
		perl "$reject" temporary all "$main.lock" "$main" \
			>"$evidence/real-lock.path"
		cp "$main.lock" "$evidence/real-lock.before"
	fi
	: >"$evidence/pre-mutation-refresh.trace"
	case "$BACKOFF_HOOK_ACTION" in
	noop | refresh)
		:
		;;
	*)
		GIT_TRACE2_EVENT="$evidence/pre-mutation-refresh.trace" \
			git add --refresh -- sibling
		cp "$selected" "$evidence/selected.after-refresh"
		;;
	esac
	: >"$evidence/hook.trace"
	GIT_TRACE2_EVENT="$evidence/hook.trace"
	export GIT_TRACE2_EVENT
	case "$BACKOFF_HOOK_ACTION" in
	noop)
		:
		;;
	refresh)
		git add --refresh -- "$BACKOFF_HOOK_REFRESH_PATH"
		;;
	content)
		printf "%s\n" hook-content >sibling
		git add sibling
		;;
	add-new)
		printf "%s\n" hook-added >created
		git add created
		;;
	remove)
		git rm -f sibling
		;;
	rename)
		git mv sibling renamed
		;;
	mode)
		git update-index --chmod=+x sibling
		;;
	assume-unchanged)
		git update-index --assume-unchanged sibling
		;;
	info-attributes)
		printf "%s\n" "sibling -text" >"$BACKOFF_HOOK_ATTRIBUTES"
		git add --refresh -- sibling
		;;
	*)
		exit 2
		;;
	esac
	perl "$reject" temporary "$BACKOFF_HOOK_STYLE" \
		"$GIT_INDEX_FILE" "$main" >"$evidence/selected.path.after"
	cp "$selected" "$evidence/selected.after"
	cp "$main" "$evidence/main.in-hook.after"
	perl "$helper" identity "$main" >"$evidence/main.identity.hook-after"
	if test "$BACKOFF_HOOK_STYLE" = partial
	then
		cp "$main.lock" "$evidence/real-lock.after"
	fi
	printf "%s\n" success >"$evidence/completed"
	exit 0
	EOF
}

setup_backoff_successful_commit_pair () {
	setup_backoff_hook_pair "$1" &&
	common=$(git -C "$1-main" -c core.fsmonitor=false \
		--no-optional-locks rev-parse --absolute-git-dir) &&
	write_backoff_hook_identity_helper "$common/hook-index.pl" &&
	write_backoff_rejected_index_helper "$common/rejected-index.pl" &&
	install_backoff_successful_commit_hook "$1-main"
}

make_backoff_successful_commit_oracles () (
	style=$1 &&
	action=$2 &&
	evidence=$3 &&
	cp "$evidence/main.seed" "$evidence/oracle-main.index" &&
	backoff_commit_index "$evidence/oracle-main.index" add -u &&
	case "$style" in
	all)
		cp "$evidence/oracle-main.index" "$evidence/oracle-commit.index"
		;;
	partial)
		backoff_commit_index "$evidence/oracle-commit.index" read-tree HEAD &&
		backoff_commit_index "$evidence/oracle-commit.index" add -- tracked
		;;
	esac &&
	backoff_commit_entries "$evidence/oracle-commit.index" \
		>"$evidence/expected-pre-hook.entries" &&
	case "$action" in
	noop | refresh | info-attributes)
		:
		;;
	content | add-new)
		case "$action" in
		content) contents=hook-content target=sibling ;;
		add-new) contents=hook-added target=created ;;
		esac &&
		test_write_lines "$contents" >"$evidence/expected-content" &&
		oid=$(git -c core.fsmonitor=false hash-object -w --stdin \
			<"$evidence/expected-content") &&
		backoff_commit_index "$evidence/oracle-commit.index" \
			update-index --add --cacheinfo "100644,$oid,$target"
		;;
	remove)
		backoff_commit_index "$evidence/oracle-commit.index" \
			update-index --force-remove sibling
		;;
	rename)
		oid=$(backoff_commit_index "$evidence/oracle-commit.index" \
			rev-parse :sibling) &&
		backoff_commit_index "$evidence/oracle-commit.index" \
			update-index --force-remove sibling &&
		backoff_commit_index "$evidence/oracle-commit.index" \
			update-index --add --cacheinfo "100644,$oid,renamed"
		;;
	mode)
		backoff_commit_index "$evidence/oracle-commit.index" \
			update-index --chmod=+x sibling
		;;
	assume-unchanged)
		backoff_commit_index "$evidence/oracle-commit.index" \
			update-index --assume-unchanged sibling
		;;
	*)
		return 1
		;;
	esac &&
	backoff_commit_index "$evidence/oracle-commit.index" write-tree \
		>"$evidence/expected-commit.tree" &&
	backoff_commit_entries "$evidence/oracle-commit.index" \
		>"$evidence/expected-commit.entries" &&
	case "$action" in
	noop | refresh | info-attributes)
		test_cmp_bin "$evidence/expected-pre-hook.entries" \
			"$evidence/expected-commit.entries"
		;;
	*)
		! test_cmp_bin "$evidence/expected-pre-hook.entries" \
			"$evidence/expected-commit.entries"
		;;
	esac &&
	if test "$style" = all
	then
		cp "$evidence/oracle-commit.index" "$evidence/oracle-main.index"
	else
		:
	fi &&
	backoff_commit_index "$evidence/oracle-main.index" write-tree \
		>"$evidence/expected-main.tree" &&
	backoff_commit_entries "$evidence/oracle-main.index" \
		>"$evidence/expected-main.entries" &&
	if test "$style" = partial
	then
		! test_cmp "$evidence/expected-commit.tree" "$evidence/expected-main.tree"
	else
		test_cmp "$evidence/expected-commit.tree" "$evidence/expected-main.tree"
	fi
)

check_backoff_successful_commit () (
	prefix=$1 &&
	style=$2 &&
	action=$3 &&
	kind=$4 &&
	common=$5 &&
	case "$kind" in
	main)
		other_gitdir=$(git -C "$prefix-linked" -c core.fsmonitor=false \
			--no-optional-locks rev-parse --absolute-git-dir)
		;;
	linked)
		other_gitdir=$common
		;;
	esac &&
	cd "$prefix-$kind" &&
	sane_unset GIT_INDEX_FILE GIT_TEST_PRELOAD_INDEX_BULK \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE GIT_TEST_FSMONITOR_QUERY_PATH &&
	gitdir=$(git -c core.fsmonitor=false --no-optional-locks \
		rev-parse --absolute-git-dir) &&
	main_index="$gitdir/index" &&
	checkpoint=$(cat "$gitdir/checkpoints") &&
	# Keep linked-worktree evidence in the common gitdir after its cleanup.
	evidence="$common/successful-$style-$action-$kind" &&
	mkdir "$evidence" &&
	cp "$main_index" "$evidence/main.seed" &&
	cp "$checkpoint" "$evidence/checkpoint.before" &&
	cp "$other_gitdir/index" "$evidence/other-index.before" &&
	snapshot_backoff_index_identity "$main_index" >"$evidence/main.identity.before" &&
	snapshot_backoff_index_identity "$other_gitdir/index" \
		>"$evidence/other-index.identity.before" &&
	assert_backoff_full_proof "$evidence/main.seed" &&
	test_path_is_missing "$common/info/attributes" &&
	test_write_lines worktree-change >tracked &&
	make_backoff_successful_commit_oracles "$style" "$action" "$evidence" &&
	git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD \
		>"$evidence/head.before" &&
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		test-tool fsmonitor-client record-watch-limit &&
	test_path_is_file "$gitdir/fsmonitor--daemon.inotify-limit" &&
	case "$style" in
	all) refresh_path=sibling && set -- -a ;;
	partial) refresh_path=tracked && set -- -- tracked ;;
	esac &&
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TRACE2_EVENT="$evidence/commit.trace" \
	BACKOFF_HOOK_STYLE="$style" BACKOFF_HOOK_ACTION="$action" \
	BACKOFF_HOOK_EVIDENCE="$evidence" BACKOFF_HOOK_MAIN_INDEX="$main_index" \
	BACKOFF_HOOK_IDENTITY_HELPER="$common/hook-index.pl" \
	BACKOFF_HOOK_REJECT_HELPER="$common/rejected-index.pl" \
	BACKOFF_HOOK_REFRESH_PATH="$refresh_path" \
	BACKOFF_HOOK_ATTRIBUTES="$common/info/attributes" \
		git commit -qm "successful $style $action hook" "$@" \
			>"$evidence/commit.out" &&
	# This must be the first observation after the successful commit.
	cp "$main_index" "$evidence/index.published" &&
	snapshot_backoff_index_identity "$main_index" \
		>"$evidence/index.published.identity" &&
	test_grep "^success$" "$evidence/completed" &&
	test_cmp "$evidence/selected.path" "$evidence/selected.path.after" &&
	test_cmp_bin "$evidence/main.seed" "$evidence/main.in-hook.before" &&
	test_cmp_bin "$evidence/main.seed" "$evidence/main.in-hook.after" &&
	test_cmp "$evidence/main.identity.before" "$evidence/main.identity.hook-before" &&
	test_cmp "$evidence/main.identity.before" "$evidence/main.identity.hook-after" &&
	! test_cmp "$evidence/main.identity.before" "$evidence/index.published.identity" &&
	test_cmp_bin "$evidence/checkpoint.before" "$checkpoint" &&
	test_path_is_missing "$main_index.lock" &&
	selected=$(cat "$evidence/selected.path") &&
	test_path_is_missing "$selected" &&
	test_path_is_missing "$selected.lock" &&
	find "$gitdir" -maxdepth 1 -name "next-index-*.lock" \
		>"$evidence/remaining-temporary-indexes" &&
	test_must_be_empty "$evidence/remaining-temporary-indexes" &&
	backoff_commit_entries "$evidence/selected.before" \
		>"$evidence/selected-before.entries" &&
	backoff_commit_entries "$evidence/selected.after" \
		>"$evidence/selected-after.entries" &&
	backoff_commit_entries "$evidence/index.published" \
		>"$evidence/published.entries" &&
	test_cmp_bin "$evidence/expected-pre-hook.entries" \
		"$evidence/selected-before.entries" &&
	test_cmp_bin "$evidence/expected-commit.entries" \
		"$evidence/selected-after.entries" &&
	test_cmp_bin "$evidence/expected-main.entries" "$evidence/published.entries" &&
	cp "$evidence/index.published" "$evidence/published-oracle.index" &&
	backoff_commit_index "$evidence/published-oracle.index" write-tree \
		>"$evidence/published.tree" &&
	test_cmp "$evidence/expected-main.tree" "$evidence/published.tree" &&
	git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD^{tree} \
		>"$evidence/committed.tree" &&
	git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD^ \
		>"$evidence/committed.parent" &&
	test_cmp "$evidence/expected-commit.tree" "$evidence/committed.tree" &&
	test_cmp "$evidence/head.before" "$evidence/committed.parent" &&
	extract_backoff_root_trace "$evidence/commit.trace" >"$evidence/commit.root.trace" &&
	test_trace2_data fsm_client settings/inotify-watch-limit-backoff 1 \
		<"$evidence/commit.root.trace" &&
	! test_trace2_data fsmonitor token_closure/accepted 1 \
		<"$evidence/commit.root.trace" &&
	! test_trace2_data fsmonitor history/commit-backoff-restored 1 \
		<"$evidence/hook.trace" &&
	case "$style:$action" in
	all:noop | all:refresh)
		assert_backoff_pending_proof "$evidence/main.seed" "$evidence/selected.before" &&
		assert_backoff_pending_proof "$evidence/main.seed" "$evidence/index.published" &&
		if test "$action" = refresh
		then
			assert_backoff_rejected_index_trace "$evidence/hook.trace" &&
			assert_backoff_commit_unbound "$evidence/selected.after" \
				"$evidence/selected-unbound" &&
			test_trace2_data fsmonitor history/commit-backoff-restored 1 \
				<"$evidence/commit.root.trace"
		else
			test_cmp_bin "$evidence/selected.before" "$evidence/selected.after"
		fi
		;;
	partial:*)
		# The false commit index and real lockfile have different trees.
		# Only the latter is published; no normal-commit repair may run.
		test_cmp_bin "$evidence/real-lock.before" "$evidence/real-lock.after" &&
		test_cmp_bin "$evidence/real-lock.after" "$evidence/index.published" &&
		assert_backoff_commit_unbound "$evidence/selected.after" \
			"$evidence/selected-unbound" &&
		! test_trace2_data fsmonitor history/commit-backoff-restored 1 \
			<"$evidence/commit.root.trace" &&
		if test "$action" = refresh
		then
			assert_backoff_rejected_index_trace "$evidence/hook.trace"
		else
			:
		fi
		;;
	all:*)
		assert_backoff_pending_proof "$evidence/main.seed" "$evidence/selected.before" &&
		assert_backoff_rejected_index_trace "$evidence/pre-mutation-refresh.trace" &&
		assert_backoff_commit_unbound "$evidence/selected.after-refresh" \
			"$evidence/after-refresh-unbound" &&
		# A real hook may serialize its own optional metadata.  The
		# parent must publish those exact bytes, not strengthen them.
		test_cmp_bin "$evidence/selected.after" "$evidence/index.published" &&
		! test_trace2_data fsmonitor history/commit-backoff-restored 1 \
			<"$evidence/commit.root.trace"
		;;
	esac &&
	git -c core.fsmonitor=false -c core.untrackedCache=false \
		-c core.preloadIndex=false -c core.preloadIndexBulk=false \
		--no-optional-locks status --porcelain=v2 >"$evidence/status.expected" &&
	if test "$style" = partial
	then
		test_grep "^1 M\\. .* sibling$" "$evidence/status.expected"
	else
		:
	fi &&
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TRACE2_EVENT="$evidence/status.trace" \
		git status --porcelain=v2 >"$evidence/status.actual" &&
	test_cmp "$evidence/status.expected" "$evidence/status.actual" &&
	test_cmp_bin "$evidence/index.published" "$main_index" &&
	snapshot_backoff_index_identity "$main_index" >"$evidence/index.after-status.identity" &&
	test_cmp "$evidence/index.published.identity" "$evidence/index.after-status.identity" &&
	assert_backoff_main_index_write "$evidence/status.trace" "$main_index" no &&
	test_cmp_bin "$evidence/checkpoint.before" "$checkpoint" &&
	# CE_VALID is itself a negative admission case.  Check its publication
	# first, then return the fixture to an eligible shape for real recovery.
	if test "$action" = assume-unchanged
	then
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			update-index --no-assume-unchanged sibling &&
		backoff_commit_index "$evidence/oracle-main.index" \
			update-index --no-assume-unchanged sibling
	else
		:
	fi &&
	backoff_commit_entries "$evidence/oracle-main.index" \
		>"$evidence/expected-recovery.entries" &&
	git -c core.fsmonitor=false -c core.untrackedCache=false \
		-c core.preloadIndex=false -c core.preloadIndexBulk=false \
		--no-optional-locks status --porcelain=v2 >"$evidence/recovery.expected" &&
	rm "$gitdir/fsmonitor--daemon.inotify-limit" &&
	GIT_INDEX_FILE="$main_index" GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCCCCCC \
	GIT_TEST_FSMONITOR_QUERY_PATH=// \
	GIT_TRACE2_EVENT="$evidence/recovery.trace" \
		git status --porcelain=v2 >"$evidence/recovery.actual" &&
	test_cmp "$evidence/recovery.expected" "$evidence/recovery.actual" &&
	test_trace2_data fsm_client query/trivial-response 1 <"$evidence/recovery.trace" &&
	test_trace2_data fsmonitor token_closure/accepted 1 <"$evidence/recovery.trace" &&
	assert_backoff_full_proof "$main_index" &&
	cp "$main_index" "$evidence/index.recovered" &&
	cp "$main_index" "$evidence/recovered-oracle.index" &&
	backoff_commit_index "$evidence/recovered-oracle.index" write-tree \
		>"$evidence/recovered.tree" &&
	backoff_commit_entries "$evidence/index.recovered" \
		>"$evidence/recovered.entries" &&
	test_cmp "$evidence/expected-main.tree" "$evidence/recovered.tree" &&
	test_cmp_bin "$evidence/expected-recovery.entries" "$evidence/recovered.entries" &&
	test_cmp_bin "$evidence/other-index.before" "$other_gitdir/index" &&
	snapshot_backoff_index_identity "$other_gitdir/index" \
		>"$evidence/other-index.identity.after" &&
	test_cmp "$evidence/other-index.identity.before" "$evidence/other-index.identity.after" &&
	test_path_is_missing "$main_index.lock" &&
	test_grep ! "\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
		"$evidence/commit.trace" "$evidence/hook.trace" \
		"$evidence/pre-mutation-refresh.trace" \
		"$evidence/status.trace" "$evidence/recovery.trace"
)

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'successful normal commit hooks publish authenticated pending history' '
	sane_unset GIT_INDEX_FILE &&
	for action in noop refresh
	do
		prefix="watch-backoff-successful-all-$action" &&
		setup_backoff_successful_commit_pair "$prefix" &&
		for kind in main linked
		do
			check_backoff_successful_commit "$prefix" all "$action" "$kind" "$common" ||
				return 1
		done || return 1
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'successful partial commit hooks do not transplant the false index' '
	sane_unset GIT_INDEX_FILE &&
	for action in noop refresh
	do
		prefix="watch-backoff-successful-partial-$action" &&
		setup_backoff_successful_commit_pair "$prefix" &&
		for kind in main linked
		do
			check_backoff_successful_commit "$prefix" partial "$action" "$kind" "$common" ||
				return 1
		done || return 1
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'successful normal hooks cannot reuse history across changed entries or attributes' '
	sane_unset GIT_INDEX_FILE &&
	for action in content add-new remove rename mode assume-unchanged info-attributes
	do
		for kind in main linked
		do
			# The semantic-input control changes common info/attributes;
			# every arm starts from its own genuinely primed pair.
			prefix="watch-backoff-successful-$action-$kind" &&
			setup_backoff_successful_commit_pair "$prefix" &&
			check_backoff_successful_commit "$prefix" all "$action" "$kind" "$common" ||
				return 1
		done || return 1
	done
'

# Keep the selected writer's result separate from any later status refresh.
backoff_scoped_index_tree () {
	cp "$1" "$2.index" &&
	backoff_commit_index "$2.index" write-tree >"$2.tree"
}

backoff_scoped_recover () (
	gitdir=$1 && evidence=$2 && expected_tree=$3 &&
	backoff_commit_index "$gitdir/index" status --porcelain=v2 \
		>"$evidence/status.expected" &&
	cp "$gitdir/index" "$evidence/index.before-recovery" &&
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
	GIT_TRACE2_EVENT="$evidence/backoff-status.trace" \
		git --no-optional-locks status --porcelain=v2 \
			>"$evidence/status.actual" &&
	test_cmp "$evidence/status.expected" "$evidence/status.actual" &&
	test_cmp_bin "$evidence/index.before-recovery" "$gitdir/index" &&
	! test_trace2_data fsmonitor token_closure/accepted 1 \
		<"$evidence/backoff-status.trace" &&
	rm "$gitdir/fsmonitor--daemon.inotify-limit" &&
	GIT_INDEX_FILE="$gitdir/index" \
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCCCCCC \
	GIT_TEST_FSMONITOR_QUERY_PATH=// \
	GIT_TRACE2_EVENT="$evidence/recovery.trace" \
		git status --porcelain=v2 >"$evidence/recovery.actual" &&
	test_cmp "$evidence/status.expected" "$evidence/recovery.actual" &&
	test_trace2_data fsm_client query/trivial-response 1 <"$evidence/recovery.trace" &&
	test_trace2_data fsmonitor token_closure/accepted 1 <"$evidence/recovery.trace" &&
	assert_backoff_full_proof "$gitdir/index" &&
	cp "$gitdir/index" "$evidence/index.recovered" &&
	backoff_scoped_index_tree "$gitdir/index" "$evidence/recovered" &&
	test_cmp "$expected_tree" "$evidence/recovered.tree" &&
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
	GIT_TRACE2_EVENT="$evidence/warm.trace" \
		git --no-optional-locks status --porcelain=v2 >"$evidence/warm.actual" &&
	test_cmp "$evidence/status.expected" "$evidence/warm.actual" &&
	test_trace2_data fsmonitor config/coherent 1 <"$evidence/warm.trace" &&
	! test_trace2_data fsmonitor semantic/manifest-scan-count \
		"[1-9][0-9]*" <"$evidence/warm.trace" &&
	test_region ! index do_write_index "$evidence/warm.trace" &&
	test_cmp_bin "$evidence/index.recovered" "$gitdir/index" &&
	test_path_is_missing "$gitdir/index.lock" &&
	test_path_is_missing "$gitdir/rebase-apply" &&
	test_grep ! "\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
		"$evidence/backoff-status.trace" "$evidence/recovery.trace" "$evidence/warm.trace"
)

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'scoped stash push retains pending backoff history and selected trees' '
	sane_unset GIT_INDEX_FILE &&
	setup_backoff_hook_pair watch-backoff-scoped-stash &&
	common=$(git -C watch-backoff-scoped-stash-main -c core.fsmonitor=false \
		--no-optional-locks rev-parse --absolute-git-dir) &&
	for kind in main linked
	do
		(
			cd "watch-backoff-scoped-stash-$kind" &&
			gitdir=$(git -c core.fsmonitor=false --no-optional-locks \
				rev-parse --absolute-git-dir) &&
			evidence="$common/scoped-stash-$kind" &&
			mkdir "$evidence" &&
			checkpoint=$(cat "$gitdir/checkpoints") &&
			cp "$gitdir/index" "$evidence/index.seed" &&
			backoff_scoped_index_tree "$evidence/index.seed" "$evidence/expected-main" &&
			git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD \
				>"$evidence/head.before" &&
			git -c core.fsmonitor=false show HEAD:tracked >"$evidence/expected-tracked" &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
				test-tool fsmonitor-client record-watch-limit &&
			test_write_lines scoped-staged >tracked &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$evidence/stage.trace" git add tracked &&
			cp "$gitdir/index" "$evidence/index.staged" &&
			assert_backoff_pending_proof "$evidence/index.seed" "$evidence/index.staged" &&
			backoff_scoped_index_tree "$evidence/index.staged" "$evidence/expected-stash-index" &&
			cp "$evidence/index.staged" "$evidence/worktree-oracle.index" &&
			test_write_lines scoped-worktree >"$evidence/selected.contents" &&
			oid=$(git -c core.fsmonitor=false hash-object -w --stdin \
				<"$evidence/selected.contents") &&
			backoff_commit_index "$evidence/worktree-oracle.index" \
				update-index --cacheinfo "100644,$oid,tracked" &&
			backoff_commit_index "$evidence/worktree-oracle.index" write-tree \
				>"$evidence/expected-stash-worktree.tree" &&
			cp "$evidence/selected.contents" tracked &&
			test_write_lines outside-path >sibling &&
			cp sibling "$evidence/expected-sibling" &&
			test_write_lines visible >visible &&
			GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			GIT_TRACE2_EVENT="$evidence/stash.trace" \
				git stash push -- tracked >"$evidence/stash.out" &&
			cp "$gitdir/index" "$evidence/index.published" &&
			snapshot_backoff_index_identity "$gitdir/index" \
				>"$evidence/index.published.identity" &&
			assert_backoff_pending_proof "$evidence/index.seed" "$evidence/index.published" &&
			test_trace2_data fsmonitor history/watch-limit-suspended 1 <"$evidence/stash.trace" &&
			assert_backoff_checkpoint_unchanged "$gitdir" "$checkpoint" &&
			backoff_scoped_index_tree "$evidence/index.published" "$evidence/published" &&
			test_cmp "$evidence/expected-main.tree" "$evidence/published.tree" &&
			git -c core.fsmonitor=false --no-optional-locks rev-parse stash^{tree} \
				>"$evidence/stash-worktree.tree" &&
			git -c core.fsmonitor=false --no-optional-locks rev-parse stash^2^{tree} \
				>"$evidence/stash-index.tree" &&
			git -c core.fsmonitor=false --no-optional-locks rev-parse stash^1 \
				>"$evidence/stash-parent" &&
			git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD \
				>"$evidence/head.after" &&
			test_cmp "$evidence/expected-stash-worktree.tree" "$evidence/stash-worktree.tree" &&
			test_cmp "$evidence/expected-stash-index.tree" "$evidence/stash-index.tree" &&
			test_cmp "$evidence/head.before" "$evidence/stash-parent" &&
			test_cmp "$evidence/head.before" "$evidence/head.after" &&
			test_cmp "$evidence/expected-tracked" tracked &&
			test_cmp "$evidence/expected-sibling" sibling &&
			test_grep "^visible$" visible &&
			test_grep ! "\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
				"$evidence/stage.trace" "$evidence/stash.trace" &&
			backoff_scoped_recover "$gitdir" "$evidence" "$evidence/expected-main.tree"
		) || return 1
	done
'

make_backoff_hook_patch_series () (
	gitdir=$1 && evidence=$2 &&
	cp "$gitdir/index.before-backoff" "$evidence/maker.index" &&
	backoff_commit_index "$evidence/maker.index" write-tree >"$evidence/base.tree" &&
	parent=$(cat "$evidence/base.tree") &&
	for step in first second
	do
		case "$step" in first) target=tracked ;; second) target=sibling ;; esac &&
		test_write_lines "hook-patch-$step" >"$evidence/$step.contents" &&
		oid=$(git -c core.fsmonitor=false hash-object -w --stdin <"$evidence/$step.contents") &&
		backoff_commit_index "$evidence/maker.index" \
			update-index --cacheinfo "100644,$oid,$target" &&
		backoff_commit_index "$evidence/maker.index" write-tree >"$evidence/$step.tree" &&
		tree=$(cat "$evidence/$step.tree") &&
		git -c core.fsmonitor=false --no-optional-locks \
			diff-tree --binary --full-index --no-renames --no-commit-id -p \
				"$parent" "$tree" -- >"$evidence/$step.diff" &&
		parent=$tree || return 1
	done &&
	test_cmp_bin "$gitdir/index.before-backoff" "$gitdir/index"
)

install_backoff_hook_patch () {
	test_hook -C "$1" pre-commit <<-\EOF
	set -eu
	evidence=$BACKOFF_HOOK_EVIDENCE
	main=$BACKOFF_HOOK_MAIN_INDEX
	printf "%s\n" "$GIT_INDEX_FILE" >"$evidence/index.env"
	if test "$BACKOFF_HOOK_PATCH_STYLE" = canonical
	then
		perl "$BACKOFF_HOOK_IDENTITY_HELPER" canonical "$GIT_INDEX_FILE" "$main" \
			>"$evidence/selected.path"
	else
		perl "$BACKOFF_HOOK_REJECT_HELPER" temporary all "$GIT_INDEX_FILE" "$main" \
			>"$evidence/selected.path"
	fi
	cp "$GIT_INDEX_FILE" "$evidence/selected.before"
	cp "$main" "$evidence/main.in-hook.before"
	GIT_TRACE2_EVENT="$evidence/child.trace" \
		git apply --index "$evidence/second.diff"
	cp "$GIT_INDEX_FILE" "$evidence/selected.after"
	cp "$main" "$evidence/main.in-hook.after"
	printf "%s\n" success >"$evidence/completed"
	EOF
}

check_backoff_hook_patch () (
	prefix=$1 && kind=$2 && style=$3 && common=$4 &&
	cd "$prefix-$kind" &&
	gitdir=$(git -c core.fsmonitor=false --no-optional-locks rev-parse --absolute-git-dir) &&
	evidence="$common/hook-patch-$style-$kind" &&
	mkdir "$evidence" &&
	cp "$gitdir/index" "$evidence/index.seed" &&
	make_backoff_hook_patch_series "$gitdir" "$evidence" &&
	git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD >"$evidence/head.before" &&
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 test-tool fsmonitor-client record-watch-limit &&
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
	GIT_TRACE2_EVENT="$evidence/direct.trace" \
		git apply --index "$evidence/first.diff" &&
	cp "$gitdir/index" "$evidence/index.first" &&
	assert_backoff_pending_proof "$evidence/index.seed" "$evidence/index.first" &&
	case "$style" in canonical) set -- ;; temporary) set -- -a ;; *) return 1 ;; esac &&
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
	GIT_TRACE2_EVENT="$evidence/commit.trace" \
	BACKOFF_HOOK_PATCH_STYLE="$style" BACKOFF_HOOK_EVIDENCE="$evidence" \
	BACKOFF_HOOK_MAIN_INDEX="$gitdir/index" \
	BACKOFF_HOOK_IDENTITY_HELPER="$common/hook-index.pl" \
	BACKOFF_HOOK_REJECT_HELPER="$common/rejected-index.pl" \
		git commit -qm "successful $style patch hook" "$@" >"$evidence/commit.out" &&
	cp "$gitdir/index" "$evidence/index.published" &&
	snapshot_backoff_index_identity "$gitdir/index" >"$evidence/index.published.identity" &&
	test_grep "^success$" "$evidence/completed" &&
	assert_backoff_pending_proof "$evidence/index.seed" "$evidence/selected.before" &&
	case "$style" in
	canonical)
		assert_backoff_pending_proof "$evidence/index.seed" "$evidence/selected.after" &&
		test_trace2_data fsmonitor history/watch-limit-suspended 1 <"$evidence/child.trace"
		;;
	temporary)
		assert_backoff_rejected_index_trace "$evidence/child.trace" &&
		test_grep ! FSUC "$evidence/selected.after" &&
		assert_backoff_commit_unbound "$evidence/selected.after" "$evidence/selected-unbound" &&
		assert_backoff_commit_unbound "$evidence/index.published" "$evidence/published-unbound" &&
		test_cmp_bin "$evidence/main.in-hook.before" "$evidence/main.in-hook.after"
		;;
	esac &&
	# AS_IS status refresh after a successful hook may deliberately revoke UC
	# history. The child transition above, not that later write, is this gate.
	backoff_scoped_index_tree "$evidence/selected.after" "$evidence/selected" &&
	backoff_scoped_index_tree "$evidence/index.published" "$evidence/published" &&
	git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD^{tree} \
		>"$evidence/committed.tree" &&
	git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD^ \
		>"$evidence/committed.parent" &&
	test_cmp "$evidence/second.tree" "$evidence/selected.tree" &&
	test_cmp "$evidence/second.tree" "$evidence/published.tree" &&
	test_cmp "$evidence/second.tree" "$evidence/committed.tree" &&
	test_cmp "$evidence/head.before" "$evidence/committed.parent" &&
	test_cmp "$evidence/first.contents" tracked &&
	test_cmp "$evidence/second.contents" sibling &&
	test_grep ! "\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
		"$evidence/direct.trace" "$evidence/commit.trace" "$evidence/child.trace" &&
	backoff_scoped_recover "$gitdir" "$evidence" "$evidence/second.tree"
)

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'canonical-index hooks and am retain same-path backoff history' '
	sane_unset GIT_INDEX_FILE &&
	prefix=watch-backoff-canonical-patch &&
	setup_backoff_hook_pair "$prefix" &&
	common=$(git -C "$prefix-main" -c core.fsmonitor=false \
		--no-optional-locks rev-parse --absolute-git-dir) &&
	write_backoff_hook_identity_helper "$common/hook-index.pl" &&
	write_backoff_rejected_index_helper "$common/rejected-index.pl" &&
	install_backoff_hook_patch "$prefix-main" &&
	for kind in main linked
	do
		check_backoff_hook_patch "$prefix" "$kind" canonical "$common" || return 1
	done &&
	setup_backoff_bound_proof watch-backoff-canonical-am &&
	(
		cd watch-backoff-canonical-am &&
		make_backoff_patch_series same-path &&
		record_authenticated_backoff_marker &&
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			git am .git/patch-first.mbox &&
		cp .git/index .git/canonical-am.first &&
		assert_backoff_pending_proof .git/index.before-backoff .git/canonical-am.first &&
		git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD \
			>.git/canonical-am.parent.expected &&
		GIT_INDEX_FILE="$PWD/.git/index" GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/canonical-am.trace" \
			git am .git/patch-second.mbox &&
		cp .git/index .git/canonical-am.published &&
		assert_backoff_pending_proof .git/index.before-backoff .git/canonical-am.published &&
		test_trace2_data fsmonitor history/watch-limit-suspended 1 <.git/canonical-am.trace &&
		assert_backoff_patch_tree .git/canonical-am.published .git/patch-second &&
		git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD^{tree} \
			>.git/canonical-am.committed.tree &&
		git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD^ \
			>.git/canonical-am.parent &&
		test_cmp .git/patch-second.tree .git/canonical-am.committed.tree &&
		test_cmp .git/canonical-am.parent.expected .git/canonical-am.parent &&
		mkdir .git/canonical-am-recovery &&
		backoff_scoped_recover "$PWD/.git" "$PWD/.git/canonical-am-recovery" \
			"$PWD/.git/patch-second.tree"
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'temporary and alternate patch indexes cannot import backoff history' '
	sane_unset GIT_INDEX_FILE &&
	prefix=watch-backoff-temporary-patch &&
	setup_backoff_hook_pair "$prefix" &&
	common=$(git -C "$prefix-main" -c core.fsmonitor=false \
		--no-optional-locks rev-parse --absolute-git-dir) &&
	write_backoff_hook_identity_helper "$common/hook-index.pl" &&
	write_backoff_rejected_index_helper "$common/rejected-index.pl" &&
	install_backoff_hook_patch "$prefix-main" &&
	check_backoff_hook_patch "$prefix" main temporary "$common" &&
	for operation in apply am
	do
		setup_backoff_bound_proof "watch-backoff-alternate-patch-$operation" &&
		(
			cd "watch-backoff-alternate-patch-$operation" &&
			make_backoff_patch_series same-path &&
			record_authenticated_backoff_marker &&
			evidence="$PWD/.git/alternate-patch" && mkdir "$evidence" &&
			cp .git/index "$evidence/main.before" &&
			cp .git/index "$evidence/alternate.index" &&
			snapshot_backoff_index_identity .git/index >"$evidence/main.identity.before" &&
			backoff_scoped_index_tree "$evidence/main.before" "$evidence/expected-main" &&
			case "$operation" in
			apply) set -- git apply --index .git/patch-first.diff ;;
			am) set -- git am .git/patch-first.mbox ;;
			esac &&
			GIT_INDEX_FILE="$evidence/alternate.index" GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			GIT_TRACE2_EVENT="$evidence/command.trace" "$@" >"$evidence/command.out" &&
			cp "$evidence/alternate.index" "$evidence/selected.after" &&
			cp .git/index "$evidence/main.after" &&
			snapshot_backoff_index_identity .git/index >"$evidence/main.identity.after" &&
			test_cmp_bin "$evidence/main.before" "$evidence/main.after" &&
			test_cmp "$evidence/main.identity.before" "$evidence/main.identity.after" &&
			assert_backoff_rejected_index_trace "$evidence/command.trace" &&
			test_grep ! FSUC "$evidence/selected.after" &&
			assert_backoff_commit_unbound "$evidence/selected.after" "$evidence/selected-unbound" &&
			assert_backoff_patch_tree "$evidence/selected.after" .git/patch-first &&
			if test "$operation" = am
			then
				git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD^{tree} \
					>"$evidence/committed.tree" &&
				test_cmp .git/patch-first.tree "$evidence/committed.tree"
			else
				git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD \
					>"$evidence/head.after" &&
				test_cmp .git/patch-base.commit "$evidence/head.after"
			fi &&
			backoff_scoped_recover "$PWD/.git" "$evidence" "$evidence/expected-main.tree"
		) || return 1
	done
'

extract_backoff_interactive_apply_trace () {
	perl - "$1" <<-\EOF
	use strict;
	use warnings;
	open my $input, "<", $ARGV[0] or die "cannot read trace: $!\n";
	my @lines = <$input>;
	my @sids = map { /"sid":"([^"]+)"/ ? $1 : () }
		grep { /"event":"cmd_name"/ && /"name":"apply"/ } @lines;
	die "expected exactly one real apply child\n" unless @sids == 1;
	print grep { /"sid":"\Q$sids[0]\E"/ } @lines;
	EOF
}

assert_backoff_interactive_index_env () {
	perl - "$1" "$2" <<-\EOF
	use strict;
	use warnings;
	my ($trace, $expected) = @ARGV;
	open my $input, "<", $trace or die "cannot read trace: $!\n";
	my @matches = grep {
		/"event":"def_param"/ && /"param":"GIT_INDEX_FILE"/ &&
		/"value":"\Q$expected\E"/
	} <$input>;
	die "apply did not receive the expected selected index\n" unless @matches == 1;
	EOF
}

check_backoff_interactive () (
	prefix=$1 &&
	operation=$2 &&
	action=$3 &&
	kind=$4 &&
	common=$5 &&
	case "$kind" in
	main)
		other_gitdir=$(git -C "$prefix-linked" -c core.fsmonitor=false \
			--no-optional-locks rev-parse --absolute-git-dir)
		;;
	linked)
		other_gitdir=$common
		;;
	esac &&
	cd "$prefix-$kind" &&
	sane_unset GIT_INDEX_FILE GIT_TEST_PRELOAD_INDEX_BULK \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE GIT_TEST_FSMONITOR_QUERY_PATH &&
	gitdir=$(git -c core.fsmonitor=false --no-optional-locks \
		rev-parse --absolute-git-dir) &&
	main_index="$gitdir/index" &&
	checkpoint=$(cat "$gitdir/checkpoints") &&
	evidence="$common/interactive-$operation-$action-$kind" &&
	mkdir "$evidence" &&
	cp "$main_index" "$evidence/main.seed" &&
	cp "$checkpoint" "$evidence/checkpoint.before" &&
	cp "$other_gitdir/index" "$evidence/other-index.before" &&
	snapshot_backoff_index_identity "$main_index" >"$evidence/main.identity.before" &&
	snapshot_backoff_index_identity "$other_gitdir/index" \
		>"$evidence/other-index.identity.before" &&
	assert_backoff_full_proof "$evidence/main.seed" &&
	case "$operation" in
	commit-p-mode) chmod +x tracked ;;
	commit-p-delete) rm tracked ;;
	*) test_write_lines worktree-change >tracked ;;
	esac &&
	cp "$evidence/main.seed" "$evidence/oracle-main.index" &&
	cp "$evidence/main.seed" "$evidence/oracle-selected.index" &&
	case "$operation" in
	quit-p | quit-i)
		:
		;;
	add-p | commit-p)
		backoff_commit_index "$evidence/oracle-main.index" add -- tracked &&
		cp "$evidence/oracle-main.index" "$evidence/oracle-selected.index"
		;;
	commit-p-mode | commit-p-delete)
		case "$operation" in
		commit-p-mode)
			backoff_commit_index "$evidence/oracle-main.index" \
				update-index --chmod=+x tracked
			;;
		commit-p-delete)
			backoff_commit_index "$evidence/oracle-main.index" \
				update-index --force-remove tracked
			;;
		esac &&
		cp "$evidence/oracle-main.index" "$evidence/oracle-selected.index"
		;;
	private-p)
		backoff_commit_index "$evidence/oracle-selected.index" add -- tracked
		;;
	*)
		return 1
		;;
	esac &&
	for oracle in main selected
	do
		backoff_commit_index "$evidence/oracle-$oracle.index" write-tree \
			>"$evidence/expected-$oracle.tree" &&
		backoff_commit_entries "$evidence/oracle-$oracle.index" \
			>"$evidence/expected-$oracle.entries" || return 1
	done &&
	git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD \
		>"$evidence/head.before" &&
	selected=$main_index &&
	if test "$operation" = private-p
	then
		selected="$gitdir/index.alias-copy" &&
		cp "$evidence/main.seed" "$selected" &&
		perl "$common/rejected-index.pl" alias copy "$selected" "$main_index" \
			>"$evidence/private.identity.before"
	else
		:
	fi &&
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
		test-tool fsmonitor-client record-watch-limit &&
	test_path_is_file "$gitdir/fsmonitor--daemon.inotify-limit" &&
	case "$operation" in
	quit-p) answer=q && set -- add -p -- tracked ;;
	quit-i) answer=q && set -- add -i -- tracked ;;
	add-p | private-p) answer=y && set -- add -p -- tracked ;;
	commit-p | commit-p-mode | commit-p-delete)
		answer=y && set -- commit -p -qm "accepted tracked change" ;;
	esac &&
	test_write_lines "$answer" >"$evidence/input" &&
	(
		GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=EEEEEEEEEEEEEEEE &&
		GIT_TRACE2_EVENT="$evidence/interactive.trace" &&
		GIT_TRACE2_ENV_VARS=GIT_INDEX_FILE &&
		BACKOFF_HOOK_STYLE=all BACKOFF_HOOK_ACTION=$action &&
		BACKOFF_HOOK_EVIDENCE=$evidence BACKOFF_HOOK_MAIN_INDEX=$main_index &&
		BACKOFF_HOOK_IDENTITY_HELPER="$common/hook-index.pl" &&
		BACKOFF_HOOK_REJECT_HELPER="$common/rejected-index.pl" &&
		BACKOFF_HOOK_REFRESH_PATH=sibling &&
		export GIT_TEST_FSMONITOR_INOTIFY_BACKOFF \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE GIT_TRACE2_EVENT GIT_TRACE2_ENV_VARS \
			BACKOFF_HOOK_STYLE BACKOFF_HOOK_ACTION BACKOFF_HOOK_EVIDENCE \
			BACKOFF_HOOK_MAIN_INDEX BACKOFF_HOOK_IDENTITY_HELPER \
			BACKOFF_HOOK_REJECT_HELPER BACKOFF_HOOK_REFRESH_PATH &&
		if test "$operation" = private-p
		then
			GIT_INDEX_FILE=$selected && export GIT_INDEX_FILE
		else
			sane_unset GIT_INDEX_FILE
		fi &&
		git "$@" <"$evidence/input" >"$evidence/interactive.out" \
			2>"$evidence/interactive.err"
	) &&
	# Snapshot the publication before any status or other Git command.
	cp "$main_index" "$evidence/index.published" &&
	cp "$selected" "$evidence/selected.published" &&
	snapshot_backoff_index_identity "$main_index" \
		>"$evidence/index.published.identity" &&
	test_path_is_missing "$main_index.lock" &&
	test_path_is_missing "$selected.lock" &&
	case "$operation" in
	quit-i) test_grep "What now" "$evidence/interactive.out" ;;
	commit-p-mode) test_grep "Stage mode change" "$evidence/interactive.out" ;;
	commit-p-delete) test_grep "Stage deletion" "$evidence/interactive.out" ;;
	*) test_grep "Stage this hunk" "$evidence/interactive.out" ;;
	esac &&
	for view in main selected
	do
		case "$view" in
		main) published="$evidence/index.published" ;;
		selected) published="$evidence/selected.published" ;;
		esac &&
		cp "$published" "$evidence/actual-$view.index" &&
		backoff_commit_index "$evidence/actual-$view.index" write-tree \
			>"$evidence/actual-$view.tree" &&
		backoff_commit_entries "$published" >"$evidence/actual-$view.entries" &&
		test_cmp "$evidence/expected-$view.tree" "$evidence/actual-$view.tree" &&
		test_cmp_bin "$evidence/expected-$view.entries" \
			"$evidence/actual-$view.entries" || return 1
	done &&
	extract_backoff_root_trace "$evidence/interactive.trace" \
		>"$evidence/interactive.root.trace" &&
	test_trace2_data fsm_client settings/inotify-watch-limit-backoff 1 \
		<"$evidence/interactive.root.trace" &&
	! test_trace2_data fsmonitor token_closure/accepted 1 \
		<"$evidence/interactive.trace" &&
	case "$operation" in
	quit-p | quit-i)
		assert_backoff_full_proof "$evidence/index.published" &&
		test_cmp "$evidence/main.identity.before" "$evidence/index.published.identity" &&
		assert_backoff_history_unchanged "$gitdir" "$checkpoint" &&
		assert_backoff_main_index_write "$evidence/interactive.trace" "$main_index" no &&
		test_grep ! '"event":"child_start".*"apply","--cached"' \
			"$evidence/interactive.trace"
		;;
	add-p | commit-p | commit-p-mode | commit-p-delete | private-p)
		extract_backoff_interactive_apply_trace "$evidence/interactive.trace" \
			>"$evidence/apply.trace" &&
		test_grep '"event":"child_start".*"apply","--cached"' \
			"$evidence/interactive.trace" &&
		! test_trace2_data fsmonitor history/commit-backoff-advanced 1 \
			<"$evidence/apply.trace" &&
		! test_trace2_data fsmonitor history/commit-backoff-restored 1 \
			<"$evidence/apply.trace" &&
		case "$operation" in
		add-p)
			index_env=$(git -c core.fsmonitor=false --no-optional-locks \
				rev-parse --git-path index) &&
			assert_backoff_interactive_index_env "$evidence/apply.trace" "$index_env" &&
			test_trace2_data fsmonitor history/watch-limit-suspended 1 \
				<"$evidence/apply.trace" &&
			assert_backoff_pending_proof "$evidence/main.seed" "$evidence/index.published" &&
			assert_backoff_main_index_write "$evidence/interactive.trace" "$main_index" yes
			;;
		commit-p)
			# The child still uses an untrusted temporary index.  Only its
			# owning commit may validate and advance the same-path epoch.
			assert_backoff_interactive_index_env "$evidence/apply.trace" "$main_index.lock" &&
			assert_backoff_rejected_index_trace "$evidence/apply.trace" &&
			assert_backoff_pending_proof "$evidence/main.seed" "$evidence/index.published" &&
			test_trace2_data fsmonitor history/commit-backoff-advanced 1 \
				<"$evidence/interactive.root.trace" &&
			test_trace2_data fsmonitor history/commit-backoff-restored 1 \
				<"$evidence/interactive.root.trace" &&
			assert_backoff_main_index_write "$evidence/interactive.trace" "$main_index" yes
			;;
		commit-p-mode | commit-p-delete)
			assert_backoff_interactive_index_env "$evidence/apply.trace" "$main_index.lock" &&
			assert_backoff_rejected_index_trace "$evidence/apply.trace" &&
			assert_backoff_commit_unbound "$evidence/index.published" \
				"$evidence/transition-unbound" &&
			! test_trace2_data fsmonitor history/commit-backoff-advanced 1 \
				<"$evidence/interactive.root.trace" &&
			! test_trace2_data fsmonitor history/commit-backoff-restored 1 \
				<"$evidence/interactive.root.trace" &&
			assert_backoff_main_index_write "$evidence/interactive.trace" "$main_index" yes
			;;
		private-p)
			assert_backoff_interactive_index_env "$evidence/apply.trace" "$selected" &&
			assert_backoff_rejected_index_trace "$evidence/interactive.trace" &&
			assert_backoff_commit_unbound "$evidence/selected.published" \
				"$evidence/private-unbound" &&
			test_cmp "$evidence/main.identity.before" "$evidence/index.published.identity" &&
			assert_backoff_history_unchanged "$gitdir" "$checkpoint" &&
			assert_backoff_main_index_write "$evidence/interactive.trace" "$main_index" no
			;;
		esac
		;;
	esac &&
	case "$operation" in
	commit-p | commit-p-mode | commit-p-delete)
		git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD^{tree} \
			>"$evidence/committed.tree" &&
		git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD^ \
			>"$evidence/committed.parent" &&
		test_cmp "$evidence/expected-main.tree" "$evidence/committed.tree" &&
		test_cmp "$evidence/head.before" "$evidence/committed.parent" &&
		if test "$action" != none
		then
			test_grep "^success$" "$evidence/completed" &&
			test_cmp_bin "$evidence/main.seed" "$evidence/main.in-hook.before" &&
			test_cmp_bin "$evidence/main.seed" "$evidence/main.in-hook.after" &&
			test_cmp "$evidence/main.identity.before" "$evidence/main.identity.hook-before" &&
			test_cmp "$evidence/main.identity.before" "$evidence/main.identity.hook-after" &&
			assert_backoff_commit_unbound "$evidence/selected.before" "$evidence/hook-before-unbound" &&
			assert_backoff_commit_unbound "$evidence/selected.after" "$evidence/hook-after-unbound" &&
			backoff_commit_entries "$evidence/selected.before" >"$evidence/hook-before.entries" &&
			backoff_commit_entries "$evidence/selected.after" >"$evidence/hook-after.entries" &&
			test_cmp_bin "$evidence/expected-main.entries" "$evidence/hook-before.entries" &&
			test_cmp_bin "$evidence/expected-main.entries" "$evidence/hook-after.entries" &&
			! test_trace2_data fsmonitor history/commit-backoff-advanced 1 <"$evidence/hook.trace" &&
			! test_trace2_data fsmonitor history/commit-backoff-restored 1 <"$evidence/hook.trace" &&
			if test "$action" = refresh
			then
				assert_backoff_rejected_index_trace "$evidence/hook.trace"
			else
				test_cmp_bin "$evidence/selected.before" "$evidence/selected.after"
			fi
		else
			:
		fi
		;;
	*)
		git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD \
			>"$evidence/head.after" &&
		test_cmp "$evidence/head.before" "$evidence/head.after" &&
		! test_trace2_data fsmonitor history/commit-backoff-advanced 1 \
			<"$evidence/interactive.trace" &&
		! test_trace2_data fsmonitor history/commit-backoff-restored 1 \
			<"$evidence/interactive.trace"
		;;
	esac &&
	test_cmp_bin "$evidence/checkpoint.before" "$checkpoint" &&
	git -c core.fsmonitor=false -c core.untrackedCache=false \
		-c core.preloadIndex=false -c core.preloadIndexBulk=false \
		--no-optional-locks status --porcelain=v2 >"$evidence/status.expected" &&
	case "$operation" in
	commit-p | commit-p-mode | commit-p-delete)
		test_must_be_empty "$evidence/status.expected"
		;;
	*) : ;;
	esac &&
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=EEEEEEEEEEEEEEEE \
	GIT_TRACE2_EVENT="$evidence/status.trace" \
		git status --porcelain=v2 >"$evidence/status.actual" &&
	test_cmp "$evidence/status.expected" "$evidence/status.actual" &&
	test_cmp_bin "$evidence/index.published" "$main_index" &&
	snapshot_backoff_index_identity "$main_index" >"$evidence/index.after-status.identity" &&
	test_cmp "$evidence/index.published.identity" "$evidence/index.after-status.identity" &&
	assert_backoff_main_index_write "$evidence/status.trace" "$main_index" no &&
	rm "$gitdir/fsmonitor--daemon.inotify-limit" &&
	GIT_INDEX_FILE="$main_index" GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCCCCCC \
	GIT_TEST_FSMONITOR_QUERY_PATH=// \
	GIT_TRACE2_EVENT="$evidence/recovery.trace" \
		git status --porcelain=v2 >"$evidence/recovery.actual" &&
	test_cmp "$evidence/status.expected" "$evidence/recovery.actual" &&
	test_trace2_data fsm_client query/trivial-response 1 <"$evidence/recovery.trace" &&
	test_trace2_data fsmonitor token_closure/accepted 1 <"$evidence/recovery.trace" &&
	assert_backoff_full_proof "$main_index" &&
	cp "$main_index" "$evidence/index.recovered" &&
	cp "$main_index" "$evidence/recovery-oracle.index" &&
	backoff_commit_index "$evidence/recovery-oracle.index" write-tree \
		>"$evidence/recovered.tree" &&
	backoff_commit_entries "$evidence/index.recovered" >"$evidence/recovered.entries" &&
	test_cmp "$evidence/expected-main.tree" "$evidence/recovered.tree" &&
	test_cmp_bin "$evidence/expected-main.entries" "$evidence/recovered.entries" &&
	test_cmp_bin "$evidence/other-index.before" "$other_gitdir/index" &&
	snapshot_backoff_index_identity "$other_gitdir/index" \
		>"$evidence/other-index.identity.after" &&
	test_cmp "$evidence/other-index.identity.before" "$evidence/other-index.identity.after" &&
	test_grep ! '"event":"child_start".*"fsmonitor--daemon"' \
		"$evidence/interactive.trace" "$evidence/status.trace" "$evidence/recovery.trace"
)

setup_backoff_interactive_pair () {
	setup_backoff_hook_pair "$1" &&
	common=$(git -C "$1-main" -c core.fsmonitor=false \
		--no-optional-locks rev-parse --absolute-git-dir) &&
	write_backoff_hook_identity_helper "$common/hook-index.pl" &&
	write_backoff_rejected_index_helper "$common/rejected-index.pl" &&
	if test "$2" != none
	then
		install_backoff_successful_commit_hook "$1-main"
	else
		:
	fi
}

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'quitting either interactive add entrypoint preserves the main proof' '
	test_config_global interactive.singleKey false &&
	test_config_global color.ui false &&
	for operation in quit-p quit-i
	do
		prefix="watch-backoff-interactive-$operation" &&
		setup_backoff_interactive_pair "$prefix" none &&
		for kind in main linked
		do
			check_backoff_interactive "$prefix" "$operation" none "$kind" "$common" ||
				return 1
		done || return 1
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'accepted interactive hunks retain only authenticated pending history' '
	test_config_global interactive.singleKey false &&
	test_config_global color.ui false &&
	for mode in add-p commit-p-none commit-p-noop commit-p-refresh
	do
		case "$mode" in
		add-p) operation=add-p action=none ;;
		commit-p-*) operation=commit-p action=${mode#commit-p-} ;;
		esac &&
		prefix="watch-backoff-interactive-$mode" &&
		setup_backoff_interactive_pair "$prefix" "$action" &&
		for kind in main linked
		do
			check_backoff_interactive "$prefix" "$operation" "$action" "$kind" "$common" ||
				return 1
		done || return 1
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'interactive patching cannot authenticate a copied private index' '
	test_config_global interactive.singleKey false &&
	test_config_global color.ui false &&
	prefix=watch-backoff-interactive-private &&
	setup_backoff_interactive_pair "$prefix" none &&
	for kind in main linked
	do
		check_backoff_interactive "$prefix" private-p none "$kind" "$common" ||
			return 1
	done
'

test_expect_success FILEMODE,UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'interactive commit cannot advance history across mode or membership changes' '
	test_config_global interactive.singleKey false &&
	test_config_global color.ui false &&
	for operation in commit-p-mode commit-p-delete
	do
		prefix="watch-backoff-interactive-$operation" &&
		setup_backoff_interactive_pair "$prefix" none &&
		for kind in main linked
		do
			check_backoff_interactive "$prefix" "$operation" none "$kind" "$common" ||
				return 1
		done || return 1
	done
'

check_backoff_manifest_attribute () {
	perl - "$1" "$2" "$3" "$4" "$(test_oid rawsz)" <<-\EOF
	use strict;
	use warnings;
	my ($file, $flags, $name, $hash, $rawsz) = @ARGV;
	open my $input, "<", $file or die "cannot read index: $!\n";
	binmode $input;
	local $/;
	my $index = <$input>;
	my $offset = index($index, "FSCF");
	die "missing FSCF extension\n" if $offset < 0;
	my $size = unpack("N", substr($index, $offset + 4, 4));
	my $proof = substr($index, $offset + 8, $size);
	my ($version, $magic, $actual_flags, $token_len, $manifest_len) =
		unpack("NNNNN", substr($proof, 0, 20));
	die "invalid FSCF header\n" unless length($proof) == $size &&
		($version == 1 || $version == 2) && $magic == 0x46534331 &&
		$actual_flags == $flags;
	my $start = 20 + $token_len + (3 + ($version == 2)) * $rawsz;
	die "invalid manifest extent\n"
		unless $start + $manifest_len + $rawsz == length($proof);
	my $manifest = substr($proof, $start, $manifest_len);
	my $count = unpack("N", substr($manifest, 0, 4));
	my ($pos, $found) = (4, 0);
	for (1 .. $count) {
		my $len = unpack("N", substr($manifest, $pos, 4));
		my $source = ord(substr($manifest, $pos + 4, 1));
		my $digest = unpack("H*", substr($manifest, $pos + 8, $rawsz));
		$pos += 8 + $rawsz;
		my $path = substr($manifest, $pos, $len);
		$pos += $len;
		if ($path eq $name) {
			die "wrong attribute source or content\n"
				unless $source == 1 && $digest eq $hash;
			$found++;
		}
	}
	die "invalid or missing attribute manifest entry\n"
		unless $pos == length($manifest) && $found == 1;
	EOF
}

check_backoff_worktree_attributes_after_hook () (
	scope=$1 &&
	test_create_repo "watch-backoff-worktree-attrs-$scope" &&
	cd "watch-backoff-worktree-attrs-$scope" &&
	sane_unset GIT_INDEX_FILE GIT_TEST_PRELOAD_INDEX_BULK \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE GIT_TEST_FSMONITOR_QUERY_PATH &&
	case "$scope" in
	root) attrs=.gitattributes target=target visible=visible-untracked ;;
	nested)
		mkdir nested &&
		attrs=nested/.gitattributes target=nested/target \
			visible=nested/visible-untracked
		;;
	esac &&
	gitdir=$(git -c core.fsmonitor=false --no-optional-locks \
		rev-parse --absolute-git-dir) &&
	main_index="$gitdir/index" &&
	evidence="$gitdir/attribute-evidence" &&
	mkdir "$evidence" &&
	: >"$gitdir/empty-attributes" &&
	: >"$gitdir/empty-excludes" &&
	git config core.attributesFile "$gitdir/empty-attributes" &&
	git config core.excludesFile "$gitdir/empty-excludes" &&
	git config core.autocrlf false &&
	git config core.safecrlf false &&
	git config core.preloadIndex false &&
	git config core.preloadIndexBulk false &&
	git config index.version 2 &&
	git config gc.auto 0 &&
	git config maintenance.auto false &&
	printf "%s\n" "target -text" >"$attrs" &&
	printf "line\r\n" >"$target" &&
	test_write_lines base >trigger &&
	git -c core.fsmonitor=false -c core.untrackedCache=false \
		add -- "$attrs" "$target" trigger &&
	git -c core.fsmonitor=false -c core.untrackedCache=false \
		commit -qm base &&
	git config core.untrackedCache true &&
	git config core.fsmonitor true &&
	test-tool chmtime -120 "$attrs" "$target" trigger &&
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
		git update-index --refresh &&
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C git update-index --fsmonitor &&
	GIT_INDEX_FILE="$main_index" \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
		git status --porcelain=v2 >"$evidence/prime" &&
	test_must_be_empty "$evidence/prime" &&
	cp "$main_index" "$evidence/index.seed" &&
	assert_backoff_full_proof "$evidence/index.seed" &&
	old_hash=$(test-tool "$test_hash_algo" <"$attrs") &&
	check_backoff_manifest_attribute "$evidence/index.seed" 15 "$attrs" "$old_hash" &&
	test_write_lines commit-change >trigger &&
	cp "$main_index" "$evidence/oracle.index" &&
	backoff_commit_index "$evidence/oracle.index" add -u &&
	backoff_commit_index "$evidence/oracle.index" write-tree \
		>"$evidence/expected.tree" &&
	git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD \
		>"$evidence/parent" &&
	write_script "$gitdir/hooks/pre-commit" <<-\EOF &&
	set -eu
	test "$GIT_INDEX_FILE" = "$BACKOFF_ATTR_MAIN.lock"
	cp "$BACKOFF_ATTR_MAIN" "$BACKOFF_ATTR_EVIDENCE/main.before"
	cp "$GIT_INDEX_FILE" "$BACKOFF_ATTR_EVIDENCE/selected.before"
	GIT_TRACE2_EVENT="$BACKOFF_ATTR_EVIDENCE/hook.trace" \
		git add --refresh -- trigger
	cp "$GIT_INDEX_FILE" "$BACKOFF_ATTR_EVIDENCE/selected.after-refresh"
	printf "%s\n" "target text" >"$BACKOFF_ATTR_FILE"
	cp "$GIT_INDEX_FILE" "$BACKOFF_ATTR_EVIDENCE/selected.after"
	cp "$BACKOFF_ATTR_MAIN" "$BACKOFF_ATTR_EVIDENCE/main.after"
	printf "%s\n" success >"$BACKOFF_ATTR_EVIDENCE/completed"
	EOF
	record_authenticated_backoff_marker &&
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=E \
	GIT_TRACE2_EVENT="$evidence/commit.trace" \
	BACKOFF_ATTR_MAIN="$main_index" BACKOFF_ATTR_FILE="$PWD/$attrs" \
	BACKOFF_ATTR_EVIDENCE="$evidence" \
		git commit -aqm "attribute-only successful hook" &&
	# Observe publication before any status can repair its optional metadata.
	cp "$main_index" "$evidence/index.published" &&
	test_grep "^success$" "$evidence/completed" &&
	test_cmp_bin "$evidence/index.seed" "$evidence/main.before" &&
	test_cmp_bin "$evidence/index.seed" "$evidence/main.after" &&
	test_cmp_bin "$evidence/selected.after-refresh" "$evidence/selected.after" &&
	backoff_commit_entries "$evidence/selected.before" >"$evidence/entries.before" &&
	backoff_commit_entries "$evidence/selected.after" >"$evidence/entries.after" &&
	test_cmp_bin "$evidence/entries.before" "$evidence/entries.after" &&
	assert_backoff_commit_unbound "$evidence/selected.after" "$evidence/private" &&
	if assert_backoff_full_proof "$evidence/index.published" \
		>"$evidence/published-full.out" 2>"$evidence/published-full.err"
	then
		echo "backoff publication granted current cleanliness" >&2 &&
		return 1
	fi &&
	if test_trace2_data fsmonitor history/commit-backoff-restored 1 \
		<"$evidence/commit.trace"
	then
		check_backoff_manifest_attribute "$evidence/index.published" 9 \
			"$attrs" "$old_hash"
	else
		:
	fi &&
	git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD^{tree} \
		>"$evidence/committed.tree" &&
	git -c core.fsmonitor=false --no-optional-locks rev-parse HEAD^ \
		>"$evidence/committed.parent" &&
	test_cmp "$evidence/expected.tree" "$evidence/committed.tree" &&
	test_cmp "$evidence/parent" "$evidence/committed.parent" &&
	test_write_lines visible >"$visible" &&
	test-tool chmtime +120 "$target" &&
	backoff_commit_index "$main_index" hash-object --path="$target" --stdin \
		<"$target" >"$evidence/normalized.oid" &&
	printf "line\n" >"$evidence/expected-normalized" &&
	backoff_commit_index "$main_index" hash-object --no-filters --stdin \
		<"$evidence/expected-normalized" >"$evidence/expected-normalized.oid" &&
	test_cmp "$evidence/expected-normalized.oid" "$evidence/normalized.oid" &&
	backoff_commit_index "$main_index" rev-parse ":$target" \
		>"$evidence/indexed.oid" &&
	! test_cmp "$evidence/indexed.oid" "$evidence/normalized.oid" &&
	backoff_commit_index "$main_index" status --porcelain=v2 -z \
		--untracked-files=all >"$evidence/status.expected" &&
	tr "\000" "\n" <"$evidence/status.expected" >"$evidence/status.lines" &&
	test_grep "^1 \\.M .* $attrs$" "$evidence/status.lines" &&
	test_grep "^1 \\.M .* $target$" "$evidence/status.lines" &&
	test_grep "^? $visible$" "$evidence/status.lines" &&
	GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=E \
	GIT_TRACE2_EVENT="$evidence/backoff.trace" \
		git status --porcelain=v2 -z --untracked-files=all \
			>"$evidence/status.actual" &&
	test_cmp_bin "$evidence/status.expected" "$evidence/status.actual" &&
	rm .git/fsmonitor--daemon.inotify-limit &&
	GIT_INDEX_FILE="$main_index" GIT_TEST_FSMONITOR_INOTIFY_BACKOFF=1 \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCCCCCC \
	GIT_TEST_FSMONITOR_QUERY_PATH=// \
	GIT_TRACE2_EVENT="$evidence/recovery.trace" \
		git status --porcelain=v2 -z --untracked-files=all \
			>"$evidence/recovery.actual" &&
	test_cmp_bin "$evidence/status.expected" "$evidence/recovery.actual" &&
	test_trace2_data fsm_client query/trivial-response 1 <"$evidence/recovery.trace" &&
	test_trace2_data fsmonitor token_closure/accepted 1 <"$evidence/recovery.trace" &&
	assert_backoff_full_proof "$main_index" &&
	new_hash=$(test-tool "$test_hash_algo" <"$attrs") &&
	test "$old_hash" != "$new_hash" &&
	check_backoff_manifest_attribute "$main_index" 15 "$attrs" "$new_hash" &&
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
		git --no-optional-locks status --porcelain=v2 -z --untracked-files=all \
			>"$evidence/warm.actual" &&
	test_cmp_bin "$evidence/status.expected" "$evidence/warm.actual" &&
	test_path_is_missing "$main_index.lock" &&
	test_grep ! "\"event\":\"child_start\".*\"fsmonitor--daemon\"" \
		"$evidence/commit.trace" "$evidence/hook.trace" \
		"$evidence/backoff.trace" "$evidence/recovery.trace"
)

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'historical commit recovery revalidates worktree attributes and untracked files' '
	for scope in root nested
	do
		check_backoff_worktree_attributes_after_hook "$scope" || return 1
	done
'

test_done
