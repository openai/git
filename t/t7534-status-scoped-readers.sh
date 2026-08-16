#!/bin/sh

test_description='bounded readers do not certify partial fsmonitor history'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-semantic-verify.sh

test_lazy_prereq UNTRACKED_CACHE '
	{ git update-index --test-untracked-cache; ret=$?; } &&
	test $ret -ne 1
'

test_scoped_partial_proof () {
	perl - "$1" <<-\EOF
	open my $input, "<", $ARGV[0] or die "cannot read index: $!\n";
	binmode $input;
	local $/;
	my $index = <$input>;
	my $offset = index($index, "FSCF");
	die "missing FSCF extension\n" if $offset < 0;
	my $flags = unpack("N", substr($index, $offset + 16, 4));
	die "unexpected FSCF flags $flags\n" if $flags != 9;
	EOF
}

test_scoped_remove_fscf () {
	perl - "$1" "$2" <<-\EOF
	use Digest::SHA qw(sha1 sha256);
	open my $input, "<", $ARGV[0] or die "cannot read index: $!\n";
	binmode $input;
	binmode STDOUT;
	local $/;
	my $index = <$input>;
	my $rawsz = $ARGV[1] eq "sha256" ? 32 : 20;
	my $offset = index($index, "FSCF");
	die "missing FSCF extension\n" if $offset < 0;
	my $size = unpack("N", substr($index, $offset + 4, 4));
	substr($index, $offset, 8 + $size, "");
	my $payload = substr($index, 0, -$rawsz);
	print $payload, $rawsz == 32 ? sha256($payload) : sha1($payload);
	EOF
}

assert_scoped_reader () {
	scoped_label=$1 &&
	scoped_locks=$2 &&
	shift 2 &&
	cp "$gitdir/index" "$gitdir/$scoped_label.index" &&
	if test "$scoped_label" = same-stat
	then
		scoped_oracle_index="$gitdir/$scoped_label.oracle.index" &&
		cp "$gitdir/index" "$scoped_oracle_index" &&
		GIT_INDEX_FILE="$scoped_oracle_index" \
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				-C "$worktree" ls-files --stage -- tracked \
				>"$gitdir/$scoped_label.stage" &&
		test_line_count = 1 "$gitdir/$scoped_label.stage" &&
		read scoped_mode scoped_oid scoped_stage scoped_path \
			<"$gitdir/$scoped_label.stage" &&
		test "$scoped_stage" = 0 &&
		test "$scoped_path" = tracked &&
		GIT_INDEX_FILE="$scoped_oracle_index" \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				-C "$worktree" update-index \
				--cacheinfo "$scoped_mode,$scoped_oid,$scoped_path" &&
		GIT_INDEX_FILE="$scoped_oracle_index" \
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				-c core.trustctime=true \
				-c core.checkStat=default \
				-C "$worktree" "$@" \
				>"$gitdir/$scoped_label.expect"
	else
		GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false \
				-c core.untrackedCache=false \
				-c core.trustctime=true \
				-c core.checkStat=default \
				-C "$worktree" "$@" \
				>"$gitdir/$scoped_label.expect"
	fi &&
	GIT_OPTIONAL_LOCKS=$scoped_locks \
	GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
	GIT_TRACE2_EVENT="$gitdir/$scoped_label.trace" \
		git -C "$worktree" "$@" \
			>"$gitdir/$scoped_label.actual" &&
	test_cmp "$gitdir/$scoped_label.expect" \
		"$gitdir/$scoped_label.actual" &&
	test_trace2_data fsmonitor \
		semantic/scoped-reader-stat-fallback 1 \
		<"$gitdir/$scoped_label.trace" &&
	test_grep ! "\"label\":\"history_logical_digest\"" \
		"$gitdir/$scoped_label.trace" &&
	! test_trace2_data fsmonitor history/external-restored 1 \
		<"$gitdir/$scoped_label.trace" &&
	! test_trace2_data fsmonitor semantic/manifest-scan-count 1 \
		<"$gitdir/$scoped_label.trace" &&
	test_region ! index do_write_index \
		"$gitdir/$scoped_label.trace" &&
	test_cmp_bin "$gitdir/$scoped_label.index" "$gitdir/index" &&
	test_cmp_bin "$gitdir/checkpoint.pristine" "$scoped_checkpoint"
}

test_expect_success UNTRACKED_CACHE,SEMANTIC_VERIFY_ANCHORED_OPEN,PERL_TEST_HELPERS \
	'bounded physical-index readers reject incomplete history without a manifest' '
	test_when_finished "rm -rf scoped-readers scoped-readers-linked" &&
	test_create_repo scoped-readers &&
	(
		cd scoped-readers &&
		sane_unset GIT_TEST_SPLIT_INDEX &&
		test_write_lines "tracked text" >.gitattributes &&
		test_write_lines aaaa >tracked &&
		test_write_lines side >sibling &&
		git add .gitattributes tracked sibling &&
		git commit -m base &&
		git worktree add --detach ../scoped-readers-linked HEAD &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		for worktree in "$PWD" "$PWD/../scoped-readers-linked"
		do
			gitdir=$(git -C "$worktree" \
				rev-parse --absolute-git-dir) &&
			test-tool chmtime -120 "$worktree/.gitattributes" \
				"$worktree/tracked" "$worktree/sibling" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" update-index --refresh &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=C \
				git -C "$worktree" update-index --fsmonitor &&
			GIT_INDEX_FILE="$gitdir/index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" status --porcelain=v2 \
					>"$gitdir/prime" &&
			test_must_be_empty "$gitdir/prime" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/checkpoint.trace" \
				git -C "$worktree" status --short \
					>"$gitdir/checkpoint.status" &&
			test_must_be_empty "$gitdir/checkpoint.status" &&
			test_trace2_data fsmonitor history/external-stored 1 \
				<"$gitdir/checkpoint.trace" &&
			find "$gitdir" -maxdepth 1 -type f \
				-name "index.csh1.*" >"$gitdir/checkpoints" &&
			test_line_count = 1 "$gitdir/checkpoints" &&
			scoped_checkpoint=$(cat "$gitdir/checkpoints") &&
			cp "$scoped_checkpoint" "$gitdir/checkpoint.pristine" &&
			cp "$gitdir/index" "$gitdir/private.index" &&
			test_write_lines staged >"$worktree/staged" &&
			GIT_INDEX_FILE="$gitdir/private.index" \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" add --sparse -- staged &&
			test_scoped_partial_proof "$gitdir/private.index" &&
			cp "$gitdir/private.index" "$gitdir/index" &&
			assert_scoped_reader cached-readonly 0 \
				diff --no-ext-diff --no-textconv \
					--cached HEAD --name-only -z &&
			assert_scoped_reader cached-default 1 \
				diff --no-ext-diff --no-textconv \
					--cached HEAD --name-only -z &&
			assert_scoped_reader worktree-readonly 0 \
				diff --no-ext-diff --no-textconv -- tracked &&
			assert_scoped_reader worktree-default 1 \
				diff --no-ext-diff --no-textconv -- tracked &&
			test_must_be_empty "$gitdir/worktree-default.actual" &&
			if test "$worktree" != "$PWD"
			then
				cp "$gitdir/index" "$gitdir/partial.saved" &&
				test_scoped_remove_fscf "$gitdir/index" \
					"$(test_oid algo)" >"$gitdir/stale.index" &&
				mv "$gitdir/stale.index" "$gitdir/index" &&
				test_grep ! FSCF "$gitdir/index" &&
				assert_scoped_reader stale-linked-checkpoint 0 \
					diff --no-ext-diff --no-textconv -- tracked &&
				cp "$gitdir/partial.saved" "$gitdir/index" ||
					return 1
			fi &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/root-path.trace" \
				git -C "$worktree" diff \
					--no-ext-diff --no-textconv -- . \
					>"$gitdir/root-path.actual" &&
			! test_trace2_data fsmonitor \
				semantic/scoped-reader-stat-fallback 1 \
				<"$gitdir/root-path.trace" &&
			test_cmp_bin "$gitdir/private.index" "$gitdir/index" &&
			assert_scoped_reader attributes 0 \
				check-attr -a -- tracked sibling &&
			assert_scoped_reader cached-attributes 0 \
				check-attr --cached -a -- tracked &&
			assert_scoped_reader index-stage-readonly 0 \
				ls-files --stage -- tracked staged &&
			assert_scoped_reader index-stage-default 1 \
				ls-files --stage -- tracked staged &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/fsmonitor-mode.trace" \
				git -C "$worktree" ls-files -f -- tracked \
					>"$gitdir/fsmonitor-mode" &&
			! test_trace2_data fsmonitor \
				semantic/scoped-reader-stat-fallback 1 \
				<"$gitdir/fsmonitor-mode.trace" &&
			test_cmp_bin "$gitdir/private.index" "$gitdir/index" &&
			git -C "$worktree" config core.trustctime false &&
			git -C "$worktree" config core.checkStat minimal &&
			mtime=$(test-tool chmtime --get "$worktree/tracked") &&
			test_write_lines bbbb >"$worktree/tracked" &&
			test-tool chmtime =$mtime "$worktree/tracked" &&
			assert_scoped_reader same-stat 0 \
				diff --no-ext-diff --no-textconv -- tracked &&
			test_grep "^diff --git a/tracked b/tracked$" \
				"$gitdir/same-stat.actual" &&
			test_write_lines "tracked custom=changed" \
				>"$worktree/.gitattributes" &&
			assert_scoped_reader changed-attributes 0 \
				check-attr -a -- tracked &&
			test_grep "tracked: custom: changed" \
				"$gitdir/changed-attributes.actual" &&
			test_write_lines "tracked filter=required" \
				>"$worktree/.gitattributes" &&
			git -C "$worktree" config filter.required.clean false &&
			git -C "$worktree" config filter.required.required true &&
			cp "$gitdir/index" "$gitdir/filter.before" &&
			test_must_fail env GIT_OPTIONAL_LOCKS=0 \
				GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
				GIT_TRACE2_EVENT="$gitdir/required-filter.trace" \
				git -C "$worktree" diff \
					--no-ext-diff --no-textconv -- tracked \
					>"$gitdir/required-filter.actual" \
					2>"$gitdir/required-filter.error" &&
			test_must_fail env \
				GIT_INDEX_FILE="$gitdir/same-stat.oracle.index" \
				GIT_OPTIONAL_LOCKS=0 \
				git -c core.fsmonitor=false \
					-c core.untrackedCache=false \
					-c core.trustctime=true \
					-c core.checkStat=default \
					-C "$worktree" diff \
						--no-ext-diff --no-textconv -- tracked \
						>"$gitdir/required-filter.expect" \
						2>"$gitdir/required-filter.oracle-error" &&
			test_grep "clean filter .required. failed" \
				"$gitdir/required-filter.error" &&
			test_grep "clean filter .required. failed" \
				"$gitdir/required-filter.oracle-error" &&
			test_trace2_data fsmonitor \
				semantic/scoped-reader-stat-fallback 1 \
				<"$gitdir/required-filter.trace" &&
			! test_trace2_data fsmonitor \
				semantic/manifest-scan-count 1 \
				<"$gitdir/required-filter.trace" &&
			test_cmp_bin "$gitdir/filter.before" "$gitdir/index" &&
			git -C "$worktree" config --unset filter.required.clean &&
			git -C "$worktree" config --unset filter.required.required &&
			git -C "$worktree" config --unset core.trustctime &&
			git -C "$worktree" config --unset core.checkStat &&
			cp "$gitdir/index" "$gitdir/unsplit.before" &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" update-index --split-index &&
			test_must_fail git -C "$worktree" \
				config --get core.splitIndex &&
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=CCCCCCCC \
				git -C "$worktree" rev-parse --shared-index-path \
					>"$gitdir/split.shared" &&
			test_file_not_empty "$gitdir/split.shared" &&
			cp "$gitdir/index" "$gitdir/split.before" &&
			GIT_OPTIONAL_LOCKS=0 \
				git -c core.fsmonitor=false \
					-c core.untrackedCache=false \
					-c core.trustctime=true \
					-c core.checkStat=default \
					-C "$worktree" diff \
						--no-ext-diff --no-textconv -- tracked \
						>"$gitdir/split.expect" &&
			GIT_OPTIONAL_LOCKS=0 \
			GIT_TEST_FSMONITOR_QUERY_SEQUENCE=TCCCCCCCC \
			GIT_TRACE2_EVENT="$gitdir/split.trace" \
				git -C "$worktree" diff \
					--no-ext-diff --no-textconv -- tracked \
					>"$gitdir/split.actual" &&
			test_cmp "$gitdir/split.expect" "$gitdir/split.actual" &&
			! test_trace2_data fsmonitor \
				semantic/scoped-reader-stat-fallback 1 \
				<"$gitdir/split.trace" &&
			test_cmp_bin "$gitdir/split.before" "$gitdir/index" &&
			cp "$gitdir/unsplit.before" "$gitdir/index" ||
				return 1
		done
	)
'

test_done
