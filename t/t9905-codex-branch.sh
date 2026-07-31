#!/bin/sh

test_description='building the generated Codex branch from topic refs'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=master
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

codex_branch="$TEST_DIRECTORY/../.github/workflows/codex-branch.sh"

write () {
	printf '%s\n' "$1" >"$2"
}

fetch_all () {
	git fetch --force --prune origin \
		'+refs/heads/*:refs/remotes/origin/*'
}

test_expect_success 'topic names use the two-character namespace' '
	sh "$codex_branch" check-topic tb/codex/release &&
	test_expect_code 1 sh "$codex_branch" check-topic t/codex/release &&
	test_expect_code 1 sh "$codex_branch" check-topic team/codex/release &&
	test_expect_code 1 sh "$codex_branch" check-topic tb/codex/group/release &&
	test_expect_code 1 sh "$codex_branch" check-topic tb/codex/release-wip &&
	test_expect_code 1 sh "$codex_branch" check-topic tb/codex/release-stale &&
	test_expect_code 1 sh "$codex_branch" check-topic tb/codex/.bad &&
	test_expect_code 1 sh "$codex_branch" check-topic tb/codex/x.lock &&
	test_expect_code 1 sh "$codex_branch" check-topic tb/codex/x..y
'

test_expect_success 'assemble discovers topics and uses ancestry as dependency' '
	git init --bare topics.git &&
	test_create_repo topics-source &&
	(
		cd topics-source &&
		git remote add origin ../topics.git &&
		write base shared &&
		git add shared &&
		git commit -m base &&
		git push origin HEAD:master HEAD:codex &&

		git switch -c aa/codex/base master &&
		write base-topic base-topic &&
		git add base-topic &&
		git commit -m base-topic &&
		git push origin HEAD &&

		git switch -c aa/codex/stacked &&
		write stacked stacked &&
		git add stacked &&
		git commit -m stacked &&
		git push origin HEAD &&

		git switch -c bb/codex/independent master &&
		write independent independent &&
		git add independent &&
		git commit -m independent &&
		git push origin HEAD &&

		git switch -c cc/codex/ignored-wip master &&
		write ignored ignored &&
		git add ignored &&
		git commit -m ignored &&
		git push origin HEAD &&

		git branch dd/codex/alias aa/codex/stacked &&
		git push origin dd/codex/alias
	) &&

	git clone topics.git topics-runner &&
	(
		cd topics-runner &&
		fetch_all &&
		git config user.name Codex &&
		git config user.email codex@example.com &&
		sh "$codex_branch" assemble \
			--result candidate --inputs inputs &&
		candidate=$(cat candidate) &&
		git merge-base --is-ancestor origin/aa/codex/base "$candidate" &&
		git merge-base --is-ancestor origin/aa/codex/stacked "$candidate" &&
		git merge-base --is-ancestor origin/bb/codex/independent "$candidate" &&
		test_must_fail git merge-base --is-ancestor \
			origin/cc/codex/ignored-wip "$candidate" &&
		sh "$codex_branch" check-pr aa/codex/base \
			origin/aa/codex/base origin/codex origin/master &&
		test_expect_code 1 sh "$codex_branch" check-pr aa/codex/base \
			"$candidate" origin/codex origin/master &&
		test_path_is_file base-topic &&
		test_path_is_file stacked &&
		test_path_is_file independent &&
		test_path_is_missing ignored &&
		test "$(git rev-list --count --merges origin/master.."$candidate")" = 2
	)
'

test_expect_success 'assemble rejects a topic containing generated codex' '
	candidate=$(git -C topics-runner rev-parse HEAD) &&
	git -C topics-runner update-ref \
		refs/remotes/origin/zz/codex/polluted "$candidate" &&
	git -C topics-runner worktree add --detach \
		"$TRASH_DIRECTORY/contamination" origin/master &&
	(
		cd contamination &&
		test_expect_code 1 sh "$codex_branch" assemble \
			>"$TRASH_DIRECTORY/contamination.err" 2>&1 &&
		test_grep "contains a generated codex integration commit" \
			"$TRASH_DIRECTORY/contamination.err"
	) &&
	git -C topics-runner worktree remove --force \
		"$TRASH_DIRECTORY/contamination" &&
	git -C topics-runner update-ref -d \
		refs/remotes/origin/zz/codex/polluted
'

test_expect_success 'publishing rejects a topic that moved during testing' '
	(
		cd topics-runner &&
		sh "$codex_branch" verify-inputs inputs
	) &&
	(
		cd topics-source &&
		git switch bb/codex/independent &&
		write moved moved &&
		git add moved &&
		git commit -m moved &&
		git push origin HEAD
	) &&
	(
		cd topics-runner &&
		test_expect_code 1 sh "$codex_branch" verify-inputs inputs
	)
'

test_expect_success 'a conflict produces a pinned resolution recipe' '
	git init --bare conflict.git &&
	test_create_repo conflict-source &&
	(
		cd conflict-source &&
		git remote add origin ../conflict.git &&
		write base shared &&
		git add shared &&
		git commit -m base &&
		git push origin HEAD:master HEAD:codex &&

		git switch -c aa/codex/first master &&
		write first shared &&
		git add shared &&
		git commit -m first &&
		git push origin HEAD &&

		git switch -c bb/codex/second master &&
		write second shared &&
		git add shared &&
		git commit -m second &&
		git push origin HEAD
	) &&

	git clone conflict.git conflict-runner &&
	(
		cd conflict-runner &&
		fetch_all &&
		git config user.name Codex &&
		git config user.email codex@example.com &&
		old_codex=$(git rev-parse origin/codex) &&
		test_expect_code 1 sh "$codex_branch" assemble \
			--result candidate --failure conflict.md &&
		test_grep "codex was not changed" conflict.md &&
		test_grep -- "--failed .*bb/codex/second" conflict.md &&
		sed -n "/^\`\`\`sh$/,/^\`\`\`$/p" conflict.md |
			sed "1d;\$d" >recipe.sh &&
		sh -n recipe.sh &&
		test "$old_codex" = "$(git ls-remote origin refs/heads/codex | cut -f1)" &&

		base=$(git rev-parse origin/master) &&
		first=$(git rev-parse origin/aa/codex/first) &&
		second=$(git rev-parse origin/bb/codex/second) &&
		prefix_tree=$(git rev-parse HEAD^{tree}) &&
		git merge --abort &&
		sh "$codex_branch" resolve \
			--base master "$base" \
			--merged aa/codex/first "$first" \
			--failed bb/codex/second "$second" \
			--prefix-tree "$prefix_tree" \
			--worktree "$TRASH_DIRECTORY/resolution" >resolve.out &&
		test_grep "Do not push this resolution to codex" resolve.out &&
		test_grep -- "--force-with-lease=.*bb/codex/second:$second" resolve.out
	) &&

	write resolved resolution/shared &&
	git -C resolution add shared &&
	git -C resolution commit -m resolve &&
	resolved=$(git -C resolution rev-parse HEAD) &&
	git -C resolution merge-base --is-ancestor \
		refs/remotes/origin/aa/codex/first "$resolved" &&
	git -C resolution merge-base --is-ancestor \
		refs/remotes/origin/bb/codex/second "$resolved" &&
	second=$(git --git-dir=conflict.git rev-parse \
		refs/heads/bb/codex/second) &&
	git -C resolution push \
		--force-with-lease="refs/heads/bb/codex/second:$second" \
		origin HEAD:refs/heads/bb/codex/second &&
	test "$(git --git-dir=conflict.git rev-parse codex)" = \
		"$(git --git-dir=conflict.git rev-parse master)" &&
	git -C conflict-runner worktree remove --force "$TRASH_DIRECTORY/resolution"
'

test_expect_success 'the pushed resolution makes the next assembly clean' '
	git clone conflict.git resolved-runner &&
	(
		cd resolved-runner &&
		fetch_all &&
		git config user.name Codex &&
		git config user.email codex@example.com &&
		sh "$codex_branch" assemble --result candidate &&
		candidate=$(cat candidate) &&
		sh "$codex_branch" check-pr bb/codex/second \
			origin/bb/codex/second origin/codex origin/master &&
		git merge-base --is-ancestor origin/aa/codex/first "$candidate" &&
		git merge-base --is-ancestor origin/bb/codex/second "$candidate" &&
		test resolved = "$(cat shared)"
	)
'

test_expect_success 'resolution replays a rerere-resolved prefix' '
	git init --bare rerere.git &&
	test_create_repo rerere-source &&
	(
		cd rerere-source &&
		git remote add origin ../rerere.git &&
		write base shared &&
		git add shared &&
		git commit -m base &&

		git switch -c aa/codex/first &&
		write first shared &&
		git add shared &&
		git commit -m first &&
		git push origin HEAD &&

		git switch master &&
		write master shared &&
		git add shared &&
		git commit -m master &&
		git push origin HEAD &&

		git switch -c bb/codex/second &&
		write second shared &&
		git add shared &&
		git commit -m second &&
		git push origin HEAD &&

		git switch --detach master &&
		test_must_fail git merge --no-ff aa/codex/first &&
		write first-resolved shared &&
		git add shared &&
		git commit -m first-resolution &&
		git push origin HEAD:refs/heads/codex
	) &&

	git clone rerere.git rerere-runner &&
	(
		cd rerere-runner &&
		fetch_all &&
		base=$(git rev-parse origin/master) &&
		old_codex=$(git rev-parse origin/codex) &&
		first=$(git rev-parse origin/aa/codex/first) &&
		second=$(git rev-parse origin/bb/codex/second) &&
		test_expect_code 1 sh "$codex_branch" assemble \
			--rerere-from codex --failure rerere-conflict.md &&
		test_grep -- "--rerere-from .*codex.*$old_codex" \
			rerere-conflict.md &&
		test_grep -- "--merged .*aa/codex/first.*$first" \
			rerere-conflict.md &&
		prefix_tree=$(git rev-parse HEAD^{tree}) &&
		git merge --abort &&
		sh "$codex_branch" resolve \
			--base master "$base" \
			--rerere-from codex "$old_codex" \
			--merged aa/codex/first "$first" \
			--failed bb/codex/second "$second" \
			--prefix-tree "$prefix_tree" \
			--worktree "$TRASH_DIRECTORY/rerere-resolution" \
			>rerere-resolve.out 2>&1 &&
		test_grep "Resolution worktree" rerere-resolve.out &&
		git worktree remove --force "$TRASH_DIRECTORY/rerere-resolution"
	)
'

test_done
