#!/bin/sh

test_description='local replay of reviewed source boundaries'
. ./test-lib.sh
codex_branch=${CODEX_BRANCH:-$TEST_DIRECTORY/../.github/workflows/codex-branch.sh}

assemble () {
	sh "$codex_branch" assemble-plan --base "$1" --name example \
		--plan plan --session "$TRASH_DIRECTORY/$2" --result "$TRASH_DIRECTORY/$2.sha"
}

test_expect_success 'set up a pinned topic and a newer public base' '
	test_commit base file base && base=$(git rev-parse HEAD) &&
	git checkout -b feature && test_commit feature feature feature && tip=$(git rev-parse HEAD) &&
	git checkout -b newer "$base" && test_commit upstream upstream upstream && newer=$(git rev-parse HEAD)
'

test_expect_success 'empty plan returns the exact base without moving refs' '
	: >plan && git for-each-ref >before && assemble "$base" empty &&
	test "$(cat empty.sha)" = "$base" && git for-each-ref >after && test_cmp before after
'

test_expect_success 'replay is deterministic and preserves the newer base' '
	printf "feature\t%s\t%s\trelease-base\n" "$tip" "$base" >plan &&
	git for-each-ref >before && assemble "$newer" one && assemble "$newer" two &&
	test_cmp one.sha two.sha && test "$(git show "$(cat one.sha):upstream")" = upstream &&
	test "$(git show "$(cat one.sha):feature")" = feature &&
	git for-each-ref >after && test_cmp before after
'

test_expect_success 'source hooks are disabled' '
	write_script .git/hooks/post-checkout <<-EOF &&
	touch "$TRASH_DIRECTORY/hook-ran"
	EOF
	assemble "$newer" no-hooks && test_path_is_missing hook-ran && rm .git/hooks/post-checkout
'

test_expect_success 'merge topology survives replay' '
	git checkout -b right "$base" && test_commit right right right &&
	git merge --no-ff -m join feature && graph=$(git rev-parse HEAD) &&
	printf "graph\t%s\t%s\trelease-base\n" "$graph" "$base" >plan &&
	assemble "$newer" graph && replayed=$(git rev-parse "$(cat graph.sha)^2") &&
	test "$(git show -s --format=%P "$replayed" | wc -w | tr -d " ")" = 2 &&
	test "$(git show "$replayed:feature")" = feature && test "$(git show "$replayed:right")" = right
'

test_expect_success 'invalid dependency order fails before replay' '
	printf "child\t%s\t%s\tmissing\n" "$tip" "$base" >plan &&
	if assemble "$base" bad-order; then return 1; fi &&
	test_path_is_missing bad-order.sha
'

test_expect_success 'conflicts preserve the session and ignore local rerere resolutions' '
	git checkout -b conflict "$base" && test_commit topic-change file topic && conflict=$(git rev-parse HEAD) &&
	git checkout -b conflicting-base "$base" && test_commit upstream-change file upstream && conflict_base=$(git rev-parse HEAD) &&
	test_must_fail git -c rerere.enabled=true merge conflict &&
	echo cached >file && git -c rerere.enabled=true rerere && git merge --abort &&
	printf "conflict\t%s\t%s\trelease-base\n" "$conflict" "$base" >plan &&
	git for-each-ref >before &&
	if assemble "$conflict_base" conflict-session; then return 1; fi &&
	test_path_is_dir conflict-session/worktree &&
	test_path_is_file conflict-session/state/failed-owner &&
	test_path_is_missing conflict-session.sha && git for-each-ref >after && test_cmp before after
'

test_done
