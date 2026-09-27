#!/bin/sh

test_description='exact push discovery preserves native destination selection'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

exact_candidates () {
	sed -n 's/^option push-exact-ref //p' "$EXACT_REFS_LOG" >actual
}

reset_helper () {
	>"$EXACT_REFS_LOG" &&
	>"$EXACT_REFS_ADVERTISEMENT"
}

test_expect_success 'setup recording remote helper' '
	EXACT_REFS_LOG="$TRASH_DIRECTORY/helper.log" &&
	EXACT_REFS_ADVERTISEMENT="$TRASH_DIRECTORY/advertisement" &&
	export EXACT_REFS_LOG EXACT_REFS_ADVERTISEMENT &&
	write_script git-remote-exact-test <<-\EOF_HELPER &&
	complete=false
	while IFS= read -r line
	do
		printf "%s\n" "$line" >>"$EXACT_REFS_LOG"
		case "$line" in
		capabilities)
			printf "push\noption\nobject-format\n"
			if test -z "$EXACT_REFS_LEGACY"
			then
				printf "push-exact-refs\n"
			fi
			printf "\n"
			;;
		"option push-exact-refs "*)
			complete=${line#option push-exact-refs }
			printf "ok\n"
			;;
		option\ *)
			printf "ok\n"
			;;
		"list for-push")
			printf ":object-format %s\n" "$(git rev-parse --show-object-format)"
			if test -n "$EXACT_REFS_SWITCH_HEAD"
			then
				git symbolic-ref HEAD "$EXACT_REFS_SWITCH_HEAD" || exit 1
			fi
			cat "$EXACT_REFS_ADVERTISEMENT"
			if test "$complete" = true &&
			   test -z "$EXACT_REFS_FALLBACK"
			then
				printf ":push-exact-refs\n"
			fi
			printf "\n"
			;;
		push\ *)
			while test -n "$line"
			do
				printf "ok %s\n" "${line##*:}"
				IFS= read -r line || exit 1
				printf "%s\n" "$line" >>"$EXACT_REFS_LOG"
			done
			printf "\n"
			;;
		"") exit 0 ;;
		*) exit 1 ;;
		esac
	done
	EOF_HELPER
	PATH="$TRASH_DIRECTORY:$PATH" &&
	export PATH &&
	test_commit initial &&
	git remote add target exact-test::unused &&
	git config push.default current &&
	cat >expect-main <<-\EOF_EXPECT &&
	refs/heads/main
	refs/heads/refs/heads/main
	refs/refs/heads/main
	refs/remotes/refs/heads/main
	refs/remotes/refs/heads/main/HEAD
	refs/tags/refs/heads/main
	EOF_EXPECT
	cat >expect-topic <<-\EOF_EXPECT
	refs/heads/topic
	refs/remotes/topic
	refs/remotes/topic/HEAD
	refs/tags/topic
	refs/topic
	EOF_EXPECT
'

test_expect_success 'colonless HEAD queries its resolved branch' '
	reset_helper &&
	git push target HEAD &&
	exact_candidates &&
	test_cmp expect-main actual &&
	test_grep "^push HEAD:refs/heads/main$" "$EXACT_REFS_LOG"
'

test_expect_success 'changing HEAD during discovery rejects an unqueried destination' '
	git branch other &&
	test_when_finished "git symbolic-ref HEAD refs/heads/main" &&
	reset_helper &&
	test_must_fail env EXACT_REFS_SWITCH_HEAD=refs/heads/other \
		git push target HEAD 2>err &&
	exact_candidates &&
	test_cmp expect-main actual &&
	test_grep "push destination for .* changed during discovery" err &&
	test_grep ! "^push " "$EXACT_REFS_LOG"
'

test_expect_success 'source normalization does not introduce local ambiguity' '
	git branch refs/heads/main &&
	test_when_finished "git branch -D refs/heads/main" &&
	reset_helper &&
	git push target main &&
	exact_candidates &&
	test_cmp expect-main actual &&
	reset_helper &&
	git push target HEAD &&
	exact_candidates &&
	test_cmp expect-main actual
'

test_expect_success 'default current and configured mapping use resolved destinations' '
	reset_helper &&
	git push target &&
	exact_candidates &&
	test_cmp expect-main actual &&
	test_config remote.target.push refs/heads/main:refs/heads/mapped &&
	reset_helper &&
	git push target main &&
	exact_candidates &&
	sed s/main/mapped/g expect-main >expect &&
	test_cmp expect actual
'

test_expect_success 'unqualified destination retains all normal-ref candidates' '
	reset_helper &&
	git push target HEAD:topic &&
	exact_candidates &&
	test_cmp expect-topic actual &&
	test_grep "^push HEAD:refs/heads/topic$" "$EXACT_REFS_LOG"
'

test_expect_success 'default upstream uses its configured destination' '
	reset_helper &&
	git -c push.default=upstream -c branch.main.remote=target \
		-c branch.main.merge=refs/heads/upstream push target &&
	exact_candidates &&
	sed s/main/upstream/g expect-main | sort >expect &&
	test_cmp expect actual
'

test_expect_success 'existing unqualified tag wins over branch inference' '
	reset_helper &&
	printf "%s refs/tags/topic\n" "$(git rev-parse HEAD)" >"$EXACT_REFS_ADVERTISEMENT" &&
	git push target HEAD:topic &&
	exact_candidates &&
	test_cmp expect-topic actual &&
	test_grep ! "^push .*:refs/heads/topic$" "$EXACT_REFS_LOG"
'

test_expect_success 'branch and tag ambiguity still rejects the push' '
	reset_helper &&
	printf "%s refs/tags/topic\n%s refs/heads/topic\n" \
		"$(git rev-parse HEAD)" "$(git rev-parse HEAD)" >"$EXACT_REFS_ADVERTISEMENT" &&
	test_must_fail git push target HEAD:topic 2>err &&
	test_grep "dst refspec topic matches more than one" err &&
	test_grep ! "^push " "$EXACT_REFS_LOG"
'

test_expect_success 'weak matches retain native ambiguity and strong-match preference' '
	reset_helper &&
	printf "%s refs/remotes/topic\n%s refs/remotes/topic/HEAD\n" \
		"$(git rev-parse HEAD)" "$(git rev-parse HEAD)" >"$EXACT_REFS_ADVERTISEMENT" &&
	test_must_fail git push target HEAD:topic 2>err &&
	test_grep "dst refspec topic matches more than one" err &&
	printf "%s refs/heads/topic\n" "$(git rev-parse HEAD)" >>"$EXACT_REFS_ADVERTISEMENT" &&
	git push target HEAD:topic
'

for delete in -d --delete
 do
	test_expect_success "$delete uses native unqualified deletion matching" '
		reset_helper &&
		printf "%s refs/tags/topic\n" "$(git rev-parse HEAD)" >"$EXACT_REFS_ADVERTISEMENT" &&
		git push "$delete" target topic &&
		exact_candidates &&
		test_cmp expect-topic actual &&
		test_grep "^push :refs/tags/topic$" "$EXACT_REFS_LOG"
	'
done

test_expect_success 'multiple destinations are queried and pushed together' '
	reset_helper &&
	git push target HEAD:refs/heads/main HEAD:topic &&
	exact_candidates &&
	cat expect-main expect-topic | sort -u >expect &&
	test_cmp expect actual &&
	test_grep "^push HEAD:refs/heads/main$" "$EXACT_REFS_LOG" &&
	test_grep "^push HEAD:refs/heads/topic$" "$EXACT_REFS_LOG"
'

test_expect_success 'lease checks compare the discovered destination OID' '
	test_commit second &&
	reset_helper &&
	printf "%s refs/heads/topic\n" "$(git rev-parse initial)" >"$EXACT_REFS_ADVERTISEMENT" &&
	test_must_fail git push --force-with-lease=refs/heads/topic:$ZERO_OID \
		target HEAD:refs/heads/topic 2>err &&
	test_grep "stale info" err &&
	test_grep ! "^push " "$EXACT_REFS_LOG" &&
	git push --force-with-lease=refs/heads/topic:$(git rev-parse initial) \
		target HEAD:refs/heads/topic &&
	test_grep "^push HEAD:refs/heads/topic$" "$EXACT_REFS_LOG"
'

test_expect_success 'helpers without exact discovery retain original refspecs' '
	reset_helper &&
	EXACT_REFS_LEGACY=1 git push target HEAD &&
	exact_candidates &&
	test_must_be_empty actual &&
	test_grep "^push HEAD:refs/heads/main$" "$EXACT_REFS_LOG"
'

test_expect_success 'a helper using full discovery retains original refspecs' '
	reset_helper &&
	EXACT_REFS_FALLBACK=1 git push target HEAD &&
	exact_candidates &&
	test_cmp expect-main actual &&
	test_grep "^push HEAD:refs/heads/main$" "$EXACT_REFS_LOG"
'

test_expect_success 'invalid local source is rejected before helper discovery' '
	reset_helper &&
	test_must_fail git push target nonexistent:topic 2>err &&
	test_grep "src refspec nonexistent does not match any" err &&
	test_grep ! "^list for-push$" "$EXACT_REFS_LOG"
'

for mode in --mirror --prune --follow-tags
 do
	test_expect_success "$mode does not claim complete exact discovery" '
		reset_helper &&
		git push "$mode" target &&
		test_grep "^option push-exact-refs false$" "$EXACT_REFS_LOG" &&
		exact_candidates &&
		test_must_be_empty actual
	'
done

test_expect_success 'all branches query every local branch destination' '
	reset_helper &&
	git push --all target &&
	exact_candidates &&
	git for-each-ref --format="%(refname)" refs/heads >expect &&
	test_cmp expect actual &&
	test_grep "^push refs/heads/main:refs/heads/main$" "$EXACT_REFS_LOG" &&
	test_grep "^push refs/heads/other:refs/heads/other$" "$EXACT_REFS_LOG"
'

test_expect_success 'matching queries local branches but pushes only existing destinations' '
	reset_helper &&
	printf "%s refs/heads/main\n" "$(git rev-parse initial)" >"$EXACT_REFS_ADVERTISEMENT" &&
	git push target : &&
	exact_candidates &&
	git for-each-ref --format="%(refname)" refs/heads >expect &&
	test_cmp expect actual &&
	test_grep "^push refs/heads/main:refs/heads/main$" "$EXACT_REFS_LOG" &&
	test_grep ! "^push .*:refs/heads/other$" "$EXACT_REFS_LOG"
'

test_expect_success 'wildcard mapping queries every mapped local destination' '
	reset_helper &&
	git push target "refs/heads/*:refs/heads/mapped/*" &&
	exact_candidates &&
	git for-each-ref --format="%(refname)" refs/heads |
		sed "s,refs/heads/,refs/heads/mapped/," >expect &&
	test_cmp expect actual &&
	test_grep "^push refs/heads/main:refs/heads/mapped/main$" "$EXACT_REFS_LOG" &&
	test_grep "^push refs/heads/other:refs/heads/mapped/other$" "$EXACT_REFS_LOG"
'

test_expect_success 'negative refspecs retain native exclusions after discovery' '
	reset_helper &&
	git push target "refs/heads/*:refs/heads/*" ^refs/heads/other &&
	exact_candidates &&
	git for-each-ref --format="%(refname)" refs/heads >expect &&
	test_cmp expect actual &&
	test_grep "^push refs/heads/main:refs/heads/main$" "$EXACT_REFS_LOG" &&
	test_grep ! "^push .*:refs/heads/other$" "$EXACT_REFS_LOG"
'

test_expect_success 'a finite empty wildcard selection does not request all refs' '
	reset_helper &&
	git push target "refs/heads/missing/*:refs/heads/missing/*" &&
	exact_candidates &&
	test_must_be_empty actual &&
	test_grep "^option push-exact-refs true$" "$EXACT_REFS_LOG" &&
	test_grep ! "^push " "$EXACT_REFS_LOG"
'

test_expect_success 'large finite selections reach the helper without truncation' '
	test_when_finished "git for-each-ref --format=\"delete %(refname)\" refs/heads/bulk | git update-ref --stdin" &&
	oid=$(git rev-parse HEAD) &&
	test_seq 1 129 >numbers &&
	while read n
	do
		printf "create refs/heads/bulk/%s %s\n" "$n" "$oid" || return 1
	done <numbers >updates &&
	git update-ref --stdin <updates &&
	reset_helper &&
	git push --all target &&
	exact_candidates &&
	git for-each-ref --format="%(refname)" refs/heads >expect &&
	test_cmp expect actual
'

test_done
