#!/bin/sh

test_description='authenticated fsmonitor history across scoped stash writers'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-semantic-verify.sh

test_lazy_prereq UNTRACKED_CACHE '
	{ git update-index --test-untracked-cache; ret=$?; } &&
	test $ret -ne 1
'

scoped_stash_full_proof () {
	perl - "$1" <<-\EOF
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
	die "mismatched provider tokens\n" unless
		$tokens{"FSMN"} eq $tokens{"FSUC"} &&
		$tokens{"FSMN"} eq $tokens{"FSCF"};
	EOF
}

scoped_stash_prime () {
	worktree=$1 &&
	gitdir=$(git -C "$worktree" rev-parse --absolute-git-dir) &&
	test-tool chmtime -120 "$worktree/tracked" "$worktree/sibling" &&
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		git -C "$worktree" update-index --refresh &&
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
		git -C "$worktree" update-index --fsmonitor &&
	GIT_INDEX_FILE="$gitdir/index" \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
		git -C "$worktree" status --porcelain=v2 \
			>"$gitdir/prime" &&
	scoped_stash_full_proof "$gitdir/index"
}

scoped_stash_setup () {
	test_create_repo "$1" &&
	(
		cd "$1" &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit sibling sibling &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		scoped_stash_prime "$PWD"
	)
}

scoped_stash_control_git () {
	git -C "$scoped_control" \
		-c core.fsmonitor=false \
		-c core.untrackedCache=false \
		-c core.trustctime=true \
		-c core.checkStat=default "$@"
}

scoped_stash_control () {
	scoped_source=$1 &&
	scoped_control=$2 &&
	scoped_output=$3 &&
	git -c core.fsmonitor=false \
		-c core.untrackedCache=false \
		clone -q --no-hardlinks "$scoped_source" \
			"$scoped_control" &&
	test_write_lines scoped >"$scoped_control/tracked" &&
	scoped_stash_control_git add -- tracked &&
	scoped_stash_control_git stash push -q \
		-m independent-control -- tracked &&
	scoped_stash_control_git rev-parse \
		"stash@{0}^{tree}" "stash@{0}^2^{tree}" \
			>"$scoped_output/control.trees" &&
	scoped_stash_control_git --no-optional-locks \
		status --porcelain=v2 \
			>"$scoped_output/control.pushed" &&
	scoped_stash_control_git stash apply --index -q "stash@{0}" &&
	scoped_stash_control_git --no-optional-locks \
		status --porcelain=v2 \
			>"$scoped_output/control.applied" &&
	scoped_stash_control_git --no-optional-locks \
		ls-files --stage \
			>"$scoped_output/control.staged"
}

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'scoped stash push and indexed apply preserve paired worktree proofs' '
	test_when_finished "rm -rf scoped-stash scoped-stash-linked \
				scoped-stash-control-1 scoped-stash-control-2" &&
	test_create_repo scoped-stash &&
	(
		cd scoped-stash &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit sibling sibling &&
		git worktree add --detach ../scoped-stash-linked HEAD &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		control_nr=0 &&
		for worktree in "$PWD" "$PWD/../scoped-stash-linked"
		do
			control_nr=$((control_nr + 1)) &&
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			scoped_stash_prime "$worktree" &&
			scoped_stash_control "$worktree" \
				"$PWD/../scoped-stash-control-$control_nr" \
				"$gitdir" &&
			test_write_lines scoped >"$worktree/tracked" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
				git -C "$worktree" add -- tracked &&
			scoped_stash_full_proof "$gitdir/index" &&

			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			GIT_TRACE2_EVENT="$gitdir/push.trace" \
				git -C "$worktree" stash push -q \
					-m scoped-proof -- tracked &&
			scoped_stash_full_proof "$gitdir/index" &&
			test_trace2_data fsmonitor \
				apply/untracked-replacement-preserved 1 \
				<"$gitdir/push.trace" &&
			! test_trace2_data fsmonitor untracked/proof-missing 1 \
				<"$gitdir/push.trace" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/push.trace" &&

			stash=$(git -C "$worktree" rev-parse stash@{0}) &&
			git -C "$worktree" rev-parse \
				"$stash^{tree}" "$stash^2^{tree}" \
					>"$gitdir/push.trees" &&
			test_cmp "$gitdir/control.trees" \
				"$gitdir/push.trees" &&
			GIT_OPTIONAL_LOCKS=0 \
				git -C "$worktree" \
					-c core.fsmonitor=false \
					-c core.untrackedCache=false \
					status --porcelain=v2 \
						>"$gitdir/push.actual" &&
			test_cmp "$gitdir/control.pushed" \
				"$gitdir/push.actual" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			GIT_TRACE2_EVENT="$gitdir/apply.trace" \
				git -C "$worktree" stash apply --index -q \
					"$stash" &&
			scoped_stash_full_proof "$gitdir/index" &&
			! test_trace2_data fsmonitor untracked/proof-missing 1 \
				<"$gitdir/apply.trace" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/apply.trace" &&

			cp "$gitdir/index" "$gitdir/index.before" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/status.trace" \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/actual" &&
			GIT_OPTIONAL_LOCKS=0 \
				git -C "$worktree" \
					-c core.fsmonitor=false \
					-c core.untrackedCache=false \
					status --porcelain=v2 >"$gitdir/expect" &&
			test_cmp "$gitdir/expect" "$gitdir/actual" &&
			test_cmp "$gitdir/control.applied" \
				"$gitdir/actual" &&
			GIT_OPTIONAL_LOCKS=0 \
				git -C "$worktree" \
					-c core.fsmonitor=false \
					-c core.untrackedCache=false \
					ls-files --stage \
						>"$gitdir/staged.actual" &&
			test_cmp "$gitdir/control.staged" \
				"$gitdir/staged.actual" &&
			test_cmp "$scoped_control/tracked" \
				"$worktree/tracked" &&
			test_cmp "$scoped_control/sibling" \
				"$worktree/sibling" &&
			test_grep "^1 M\\. .* tracked$" "$gitdir/actual" &&
			test_cmp_bin "$gitdir/index.before" "$gitdir/index" &&
			test_trace2_data fsmonitor config/coherent 1 \
				<"$gitdir/status.trace" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/status.trace" || return 1
		done
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'scoped stash push preserves an unrelated staged sibling' '
	test_when_finished "rm -rf scoped-stash-staged \
				scoped-stash-staged-control" &&
	scoped_stash_setup scoped-stash-staged &&
	(
		cd scoped-stash-staged &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		gitdir="$PWD/.git" &&
		scoped_control="$PWD/../scoped-stash-staged-control" &&
		git -c core.fsmonitor=false \
			-c core.untrackedCache=false \
			clone -q --no-hardlinks "$PWD" \
				"$scoped_control" &&
		test_write_lines scoped >"$scoped_control/tracked" &&
		test_write_lines independently-staged \
			>"$scoped_control/sibling" &&
		scoped_stash_control_git add -- tracked sibling &&
		scoped_stash_control_git stash push -q \
			-m independent-staged-control -- tracked &&
		scoped_stash_control_git rev-parse \
			"stash@{0}^{tree}" "stash@{0}^2^{tree}" \
				>.git/control.trees &&
		scoped_stash_control_git --no-optional-locks \
			status --porcelain=v2 >.git/control.status &&
		scoped_stash_control_git --no-optional-locks \
			ls-files --stage >.git/control.staged &&
		test_grep "^1 M\\. .* sibling$" .git/control.status &&

		test_write_lines scoped >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git add -- tracked &&
		test_write_lines independently-staged >sibling &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=sibling \
			git add -- sibling &&
		scoped_stash_full_proof .git/index &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$PWD/.git/staged-push.trace" \
			git stash push -q -m staged-proof -- tracked &&
		scoped_stash_full_proof .git/index &&
		test_trace2_data fsmonitor \
			apply/untracked-replacement-preserved 1 \
			<.git/staged-push.trace &&
		! test_trace2_data fsmonitor \
			untracked/proof-missing 1 <.git/staged-push.trace &&
		! test_trace2_data fsmonitor \
			semantic/manifest-scan-count 1 \
			<.git/staged-push.trace &&
		git rev-parse "stash@{0}^{tree}" \
			"stash@{0}^2^{tree}" >.git/staged.trees &&
		test_cmp .git/control.trees .git/staged.trees &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				status --porcelain=v2 >.git/staged.status &&
		test_cmp .git/control.status .git/staged.status &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				ls-files --stage >.git/staged.entries &&
		test_cmp .git/control.staged .git/staged.entries &&
		test_cmp "$scoped_control/tracked" tracked &&
		test_cmp "$scoped_control/sibling" sibling
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'scoped stash invalidates a changed attribute-source proof' '
	test_when_finished "rm -rf scoped-stash-attributes" &&
	test_create_repo scoped-stash-attributes &&
	(
		cd scoped-stash-attributes &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines base >tracked &&
		test_write_lines sibling >sibling &&
		test_write_lines "*.asset text" >.gitattributes &&
		git add tracked sibling .gitattributes &&
		git commit -qm base &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		scoped_stash_prime "$PWD" &&
		test_write_lines "*.asset -text" >.gitattributes &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
			git add .gitattributes &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			git status --porcelain=v2 >.git/staged &&
		scoped_stash_full_proof .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
		GIT_TRACE2_EVENT="$PWD/.git/attributes.trace" \
			git stash push -q -m attributes -- .gitattributes &&
		! test_trace2_data fsmonitor \
			apply/untracked-replacement-preserved 1 \
			<.git/attributes.trace &&
		! scoped_stash_full_proof .git/index &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			git status --porcelain=v2 >.git/actual &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				status --porcelain=v2 >.git/expect &&
		test_cmp .git/expect .git/actual
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'mixed apply batches reject attribute and ignore proofs in either order' '
	test_when_finished "rm -rf scoped-stash-mixed-*" &&
	for source in .gitattributes .gitignore
	do
		for order in regular-first source-first
		do
			repo="scoped-stash-mixed-${source#.}-$order" &&
			test_create_repo "$repo" &&
			(
				cd "$repo" &&
				sane_unset GIT_TEST_SPLIT_INDEX &&
				test_write_lines base >tracked &&
				test_write_lines sibling >sibling &&
				test_write_lines "*.asset text" \
					>.gitattributes &&
				test_write_lines ignored-before >.gitignore &&
				git add tracked sibling .gitattributes \
					.gitignore &&
				git commit -qm base &&
				git config core.untrackedCache true &&
				git config core.fsmonitor true &&
				test_write_lines mixed >tracked &&
				case "$source" in
				.gitattributes)
					test_write_lines "*.asset -text" \
						>"$source"
					;;
				.gitignore)
					test_write_lines ignored-after \
						>"$source"
					;;
				esac &&
				GIT_OPTIONAL_LOCKS=0 \
					git -c core.fsmonitor=false \
						-c core.untrackedCache=false \
						diff -- tracked \
							>.git/regular.patch &&
				GIT_OPTIONAL_LOCKS=0 \
					git -c core.fsmonitor=false \
						-c core.untrackedCache=false \
						diff -- "$source" \
							>.git/source.patch &&
				if test "$order" = regular-first
				then
					cat .git/regular.patch \
						.git/source.patch \
						>.git/mixed.patch
				else
					cat .git/source.patch \
						.git/regular.patch \
						>.git/mixed.patch
				fi &&
				git -c core.fsmonitor=false \
					-c core.untrackedCache=false \
					checkout -- tracked "$source" &&
				scoped_stash_prime "$PWD" &&
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				GIT_TRACE2_EVENT="$PWD/.git/mixed.trace" \
					git apply --index .git/mixed.patch &&
				! test_trace2_data fsmonitor \
					apply/untracked-replacement-preserved 1 \
					<.git/mixed.trace &&
				! scoped_stash_full_proof .git/index &&
				GIT_OPTIONAL_LOCKS=0 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
					git status --porcelain=v2 \
						>.git/actual &&
				GIT_OPTIONAL_LOCKS=0 \
					git -c core.fsmonitor=false \
						-c core.untrackedCache=false \
						status --porcelain=v2 \
							>.git/expect &&
				test_cmp .git/expect .git/actual &&
				test_grep " tracked$" .git/actual &&
				test_grep " $source$" .git/actual
			) || return 1
		done
	done
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'scoped stash never preserves an active required clean filter' '
	test_when_finished "rm -rf scoped-stash-filter" &&
	test_create_repo scoped-stash-filter &&
	(
		cd scoped-stash-filter &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines base >tracked &&
		test_write_lines sibling >sibling &&
		test_write_lines "tracked text" >.gitattributes &&
		git add tracked sibling .gitattributes &&
		git commit -qm base &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		scoped_stash_prime "$PWD" &&
		git config filter.scoped.clean cat &&
		git config filter.scoped.smudge cat &&
		git config filter.scoped.required true &&
		test_write_lines "tracked filter=scoped" >.gitattributes &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=.gitattributes \
			git add -- .gitattributes &&
		test_write_lines filtered >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git add tracked &&
		GIT_INDEX_FILE="$PWD/.git/index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			git status --porcelain=v2 >.git/staged &&
		! scoped_stash_full_proof .git/index &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$PWD/.git/filter.trace" \
			git stash push -q -m filtered -- tracked &&
		! test_trace2_data fsmonitor \
			apply/untracked-replacement-preserved 1 \
			<.git/filter.trace &&
		! scoped_stash_full_proof .git/index &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			git status --porcelain=v2 >.git/actual &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				status --porcelain=v2 >.git/expect &&
		test_cmp .git/expect .git/actual &&

		git config filter.scoped.clean false &&
		test_write_lines rejected >tracked &&
		cp .git/index .git/required.before &&
		git rev-parse refs/stash >.git/stash.before &&
		test_must_fail env \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
			GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			GIT_TRACE2_EVENT="$PWD/.git/required.trace" \
			git stash push -q -m rejected -- tracked \
				>.git/required.out 2>.git/required.err &&
		test_grep "clean filter .scoped. failed" \
			.git/required.err &&
		test_cmp_bin .git/required.before .git/index &&
		git rev-parse refs/stash >.git/stash.after &&
		test_cmp .git/stash.before .git/stash.after &&
		! test_trace2_data fsmonitor \
			apply/untracked-replacement-preserved 1 \
			<.git/required.trace
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'whole-worktree stash preserves its authenticated proof' '
	test_when_finished "rm -rf scoped-stash-whole" &&
	scoped_stash_setup scoped-stash-whole &&
	(
		cd scoped-stash-whole &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines dirty >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
		GIT_TRACE2_EVENT="$PWD/.git/whole.trace" \
			git stash push -q -m whole &&
		! test_trace2_data fsmonitor \
			apply/untracked-replacement-preserved 1 \
			<.git/whole.trace &&
		scoped_stash_full_proof .git/index &&
		GIT_OPTIONAL_LOCKS=0 \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			git status --porcelain=v2 >.git/actual &&
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				status --porcelain=v2 >.git/expect &&
		test_cmp .git/expect .git/actual
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'alternate indexed apply cannot transfer a primary worktree proof' '
	test_when_finished "rm -rf scoped-stash-alternate" &&
	scoped_stash_setup scoped-stash-alternate &&
	(
		cd scoped-stash-alternate &&
		test_write_lines alternate >tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git diff >.git/alternate.patch &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=tracked \
			git checkout -- tracked &&
		scoped_stash_full_proof .git/index &&
		cp .git/index .git/index.before &&
		cp .git/index .git/alternate.index &&
		GIT_INDEX_FILE="$PWD/.git/alternate.index" \
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/alternate.trace" \
			git apply --cached .git/alternate.patch &&
		! test_trace2_data fsmonitor \
			apply/untracked-replacement-preserved 1 \
			<.git/alternate.trace &&
		test_cmp_bin .git/index.before .git/index &&
		scoped_stash_full_proof .git/index
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'nested scoped stash never resurrects dirty untracked siblings' '
	test_when_finished "rm -rf scoped-stash-nested \
				scoped-stash-nested-control" &&
	test_create_repo scoped-stash-nested &&
	(
		cd scoped-stash-nested &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit sibling sibling &&
		mkdir nested &&
		test_write_lines base >nested/tracked &&
		git add -- nested/tracked &&
		git commit -qm nested-base &&
		scoped_control="$PWD/../scoped-stash-nested-control" &&
		git -c core.fsmonitor=false \
			-c core.untrackedCache=false \
			clone -q --no-hardlinks "$PWD" "$scoped_control" &&
		test_write_lines existing >nested/existing-untracked &&
		test_write_lines existing \
			>"$scoped_control/nested/existing-untracked" &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		test-tool chmtime -120 nested/tracked &&
		scoped_stash_prime "$PWD" &&
		test_grep "^? nested/existing-untracked$" .git/prime &&
		GIT_CONFIG_PARAMETERS="${SQ}core.fsmonitor=false${SQ}" \
			test-tool dump-untracked-cache >.git/initial-cache &&
		test_grep "^/nested/ .* valid" .git/initial-cache &&
		test_grep "^existing-untracked$" .git/initial-cache &&

		test_write_lines staged >nested/tracked &&
		test_write_lines staged >"$scoped_control/nested/tracked" &&
		scoped_stash_control_git add -- nested/tracked &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=nested/tracked \
			git add -- nested/tracked &&
		scoped_stash_full_proof .git/index &&

		test_write_lines new >nested/new-untracked &&
		test_write_lines new \
			>"$scoped_control/nested/new-untracked" &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=nested/new-untracked \
		GIT_TRACE2_EVENT="$PWD/.git/nested-writer.trace" \
			git update-index --force-write-index &&
		test_trace2_data fsmonitor apply_count 1 \
			<.git/nested-writer.trace &&
		test_region index do_write_index .git/nested-writer.trace &&
		scoped_stash_full_proof .git/index &&
		GIT_CONFIG_PARAMETERS="${SQ}core.fsmonitor=false${SQ}" \
			test-tool dump-untracked-cache >.git/dirty-cache &&
		test_grep "^/nested/ .* recurse$" .git/dirty-cache &&
		test_grep ! "^/nested/ .* valid" .git/dirty-cache &&
		test_grep ! "^existing-untracked$" .git/dirty-cache &&
		cp .git/index .git/before-reader &&
		scoped_stash_control_git --no-optional-locks \
			status --porcelain=v2 >.git/control-before &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/nested-reader.trace" \
			git --no-optional-locks status --porcelain=v2 \
				>.git/candidate-before &&
		test_cmp .git/control-before .git/candidate-before &&
		test_grep "^? nested/existing-untracked$" \
			.git/candidate-before &&
		test_grep "^? nested/new-untracked$" \
			.git/candidate-before &&
		test_cmp_bin .git/before-reader .git/index &&
		! test_region index do_write_index .git/nested-reader.trace &&

		test_write_lines unstaged >nested/tracked &&
		test_write_lines unstaged \
			>"$scoped_control/nested/tracked" &&
		scoped_stash_control_git stash push -q \
			-m nested-control -- nested/tracked &&
		scoped_stash_control_git rev-parse \
			"stash@{0}^{tree}" "stash@{0}^2^{tree}" \
				>.git/control-trees &&
		scoped_stash_control_git --no-optional-locks \
			status --porcelain=v2 >.git/control-pushed &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=nested/tracked \
		GIT_TRACE2_EVENT="$PWD/.git/nested-push.trace" \
			git stash push -q -m nested-proof -- nested/tracked &&
		scoped_stash_full_proof .git/index &&
		test_trace2_data fsmonitor \
			apply/untracked-replacement-preserved 1 \
			<.git/nested-push.trace &&
		! test_trace2_data fsmonitor \
			untracked/proof-missing 1 <.git/nested-push.trace &&
		git rev-parse "stash@{0}^{tree}" "stash@{0}^2^{tree}" \
			>.git/candidate-trees &&
		test_cmp .git/control-trees .git/candidate-trees &&
		cp .git/index .git/after-push &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			git --no-optional-locks status --porcelain=v2 \
				>.git/candidate-pushed &&
		test_cmp .git/control-pushed .git/candidate-pushed &&
		test_grep "^? nested/existing-untracked$" \
			.git/candidate-pushed &&
		test_grep "^? nested/new-untracked$" \
			.git/candidate-pushed &&
		test_cmp_bin .git/after-push .git/index &&

		scoped_stash_control_git stash apply --index -q "stash@{0}" &&
		scoped_stash_control_git --no-optional-locks \
			status --porcelain=v2 >.git/control-applied &&
		scoped_stash_control_git --no-optional-locks \
			ls-files --stage >.git/control-staged &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=nested/tracked \
		GIT_TRACE2_EVENT="$PWD/.git/nested-apply.trace" \
			git stash apply --index -q "stash@{0}" &&
		scoped_stash_full_proof .git/index &&
		! test_trace2_data fsmonitor \
			untracked/proof-missing 1 <.git/nested-apply.trace &&
		cp .git/index .git/after-apply &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			git --no-optional-locks status --porcelain=v2 \
				>.git/candidate-applied &&
		test_cmp .git/control-applied .git/candidate-applied &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			git --no-optional-locks ls-files --stage \
				>.git/candidate-staged &&
		test_cmp .git/control-staged .git/candidate-staged &&
		test_grep "^? nested/existing-untracked$" \
			.git/candidate-applied &&
		test_grep "^? nested/new-untracked$" \
			.git/candidate-applied &&
		test_cmp "$scoped_control/nested/tracked" nested/tracked &&
		test_cmp_bin .git/after-apply .git/index
	)
'

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'cached apply safely expires a pending nested provider event' '
	test_when_finished "rm -rf scoped-stash-soft-dirty \
				scoped-stash-soft-dirty-control" &&
	test_create_repo scoped-stash-soft-dirty &&
	(
		cd scoped-stash-soft-dirty &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_commit base tracked &&
		test_commit sibling sibling &&
		mkdir nested &&
		test_write_lines base >nested/tracked &&
		git add -- nested/tracked &&
		git commit -qm nested-base &&
		scoped_control="$PWD/../scoped-stash-soft-dirty-control" &&
		git -c core.fsmonitor=false \
			-c core.untrackedCache=false \
			clone -q --no-hardlinks "$PWD" "$scoped_control" &&
		test_write_lines existing >nested/existing-untracked &&
		test_write_lines existing \
			>"$scoped_control/nested/existing-untracked" &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		test-tool chmtime -120 nested/tracked &&
		scoped_stash_prime "$PWD" &&
		test_grep "^? nested/existing-untracked$" .git/prime &&
		GIT_CONFIG_PARAMETERS="${SQ}core.fsmonitor=false${SQ}" \
			test-tool dump-untracked-cache >.git/initial-cache &&
		test_grep "^/nested/ .* valid" .git/initial-cache &&
		test_grep "^existing-untracked$" .git/initial-cache &&

		test_write_lines indexed >"$scoped_control/nested/tracked" &&
		scoped_stash_control_git diff -- nested/tracked \
			>.git/nested.patch &&
		scoped_stash_control_git checkout -- nested/tracked &&
		test_cmp "$scoped_control/nested/tracked" nested/tracked &&
		test_write_lines visible >nested/new-visible &&
		test_write_lines visible \
			>"$scoped_control/nested/new-visible" &&
		scoped_stash_control_git apply --cached \
			"$PWD/.git/nested.patch" &&
		scoped_stash_control_git --no-optional-locks \
			status --porcelain=v2 >.git/control.status &&
		scoped_stash_control_git --no-optional-locks \
			ls-files --stage >.git/control.staged &&
		test_grep "^1 MM .* nested/tracked$" .git/control.status &&
		test_grep "^? nested/existing-untracked$" \
			.git/control.status &&
		test_grep "^? nested/new-visible$" .git/control.status &&

		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=DCCCCCCCCCCCC \
		GIT_TEST_FSMONITOR_QUERY_PATH=nested/new-visible \
		GIT_TRACE2_EVENT="$PWD/.git/apply.trace" \
			git apply --cached .git/nested.patch &&
		test_trace2_data fsmonitor apply_count 1 <.git/apply.trace &&
		test_trace2_data fsmonitor \
			apply/untracked-replacement-preserved 1 \
			<.git/apply.trace &&
		! test_trace2_data fsmonitor \
			untracked/proof-missing 1 <.git/apply.trace &&
		test_region index do_write_index .git/apply.trace &&
		scoped_stash_full_proof .git/index &&
		GIT_CONFIG_PARAMETERS="${SQ}core.fsmonitor=false${SQ}" \
			test-tool dump-untracked-cache >.git/serialized-cache &&
		test_grep "^/nested/ .* recurse$" .git/serialized-cache &&
		test_grep ! "^/nested/ .* valid" .git/serialized-cache &&
		test_grep ! "^existing-untracked$" \
			.git/serialized-cache &&
		cp .git/index .git/after-apply &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
		GIT_TRACE2_EVENT="$PWD/.git/reader.trace" \
			git --no-optional-locks status --porcelain=v2 \
				>.git/candidate.status &&
		test_cmp .git/control.status .git/candidate.status &&
		test_grep "^? nested/existing-untracked$" \
			.git/candidate.status &&
		test_grep "^? nested/new-visible$" .git/candidate.status &&
		test_cmp_bin .git/after-apply .git/index &&
		! test_region index do_write_index .git/reader.trace &&
		GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCCCCCC \
			git --no-optional-locks ls-files --stage \
				>.git/candidate.staged &&
		test_cmp .git/control.staged .git/candidate.staged &&
		test_cmp "$scoped_control/nested/tracked" nested/tracked &&
		test_cmp_bin .git/after-apply .git/index
	)
'

test_done
