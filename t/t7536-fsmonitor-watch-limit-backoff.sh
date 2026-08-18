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

test_done
