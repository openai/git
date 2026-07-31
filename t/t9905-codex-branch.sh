#!/bin/sh

test_description='rebasing Codex topics and assembling the generated branch'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=master
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

codex_branch=${CODEX_BRANCH:-$TEST_DIRECTORY/../.github/workflows/codex-branch.sh}

write () {
	printf '%s\n' "$1" >"$2"
}

install_rerere_train () {
	mkdir -p contrib &&
	cp "$TEST_DIRECTORY/../contrib/rerere-train.sh" \
		contrib/rerere-train.sh &&
	git add contrib/rerere-train.sh
}

fetch_all () {
	git fetch --force --prune origin \
		'+refs/heads/*:refs/remotes/origin/*'
}

snapshot_refs () {
	git --git-dir="$1" for-each-ref \
		--format='%(refname)%09%(objectname)' |
		LC_ALL=C sort
}

find_subject () {
	git rev-list --grep="^$1$" "$2" | sed -n '1p'
}

manifest_has () {
	awk -v name="$1" -v old="$2" -v new="$3" '
		index($0, name) && index($0, old) && index($0, new) {
			found = 1
		}
		END { exit !found }
	' "$4"
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

test_expect_success 'topics cannot change the reusable controller workflow' '
	git init --bare control-path.git &&
	test_create_repo control-path-source &&
	(
		cd control-path-source &&
		git remote add origin ../control-path.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/control-path &&
		mkdir -p .github/workflows &&
		write untrusted .github/workflows/codex-topic.yml &&
		git add .github/workflows/codex-topic.yml &&
		git commit -m "change controller workflow" &&

		git switch master &&
		write master master-file &&
		git add master-file &&
		git commit -m "new control-path master" &&
		git branch meta master &&
		git push origin master meta codex aa/codex/control-path
	) &&

	git clone control-path.git control-path-runner &&
	(
		cd control-path-runner &&
		fetch_all &&
		snapshot_refs ../control-path.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure \
			2>rewrite.err &&
		test_grep "meta-only controller files" rewrite.err &&
		snapshot_refs ../control-path.git >after &&
		test_cmp before after
	)
'

test_expect_success 'rewrite rebases one root topic onto current master' '
	git init --bare root.git &&
	test_create_repo root-source &&
	(
		cd root-source &&
		git remote add origin ../root.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/root &&
		write root root-file &&
		git add root-file &&
		git commit -m "root topic" &&

		git switch master &&
		write master master-file &&
		git add master-file &&
		git commit -m "new master" &&
		git branch meta master &&
		git push origin master meta codex aa/codex/root
	) &&

	git clone root.git root-runner &&
	(
		cd root-runner &&
		fetch_all &&
		old_topic=$(git rev-parse origin/aa/codex/root) &&
		master=$(git rev-parse origin/master) &&
		snapshot_refs ../root.git >before &&
		sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure &&
		candidate=$(cat result) &&
		new_topic=$(find_subject "root topic" "$candidate") &&
		test -n "$new_topic" &&
		test "$old_topic" != "$new_topic" &&
		test "$master" = "$(git rev-parse "$new_topic^")" &&
		git merge-base --is-ancestor "$master" "$new_topic" &&
		git merge-base --is-ancestor "$new_topic" "$candidate" &&
		manifest_has aa/codex/root "$old_topic" "$new_topic" updates &&
		test root = "$(git show "$candidate:root-file")" &&
		test master = "$(git show "$candidate:master-file")" &&
		snapshot_refs ../root.git >after &&
		test_cmp before after
	)
'

test_expect_success 'rewrite preserves dependencies and merges maximal tips in name order' '
	git init --bare graph.git &&
	test_create_repo graph-source &&
	(
		cd graph-source &&
		git remote add origin ../graph.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/a &&
		write A a &&
		git add a &&
		git commit -m "topic A" &&

		git switch -c bb/codex/b &&
		write B b &&
		git add b &&
		git commit -m "topic B" &&

		git switch -c cc/codex/c master &&
		write C c &&
		git add c &&
		git commit -m "topic C" &&

		git switch master &&
		write master master-file &&
		git add master-file &&
		git commit -m "new graph master" &&
		git branch meta master &&
		git push origin master meta codex \
			aa/codex/a bb/codex/b cc/codex/c
	) &&

	git clone graph.git graph-runner &&
	(
		cd graph-runner &&
		fetch_all &&
		old_a=$(git rev-parse origin/aa/codex/a) &&
		old_b=$(git rev-parse origin/bb/codex/b) &&
		old_c=$(git rev-parse origin/cc/codex/c) &&
		master=$(git rev-parse origin/master) &&
		test "$old_a" = "$(git rev-parse "$old_b^")" &&

		GIT_COMMITTER_DATE="2002-02-02T00:00:00 +0000" \
		sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure &&
		candidate=$(cat result) &&
		new_a=$(find_subject "topic A" "$candidate") &&
		new_b=$(find_subject "topic B" "$candidate") &&
		new_c=$(find_subject "topic C" "$candidate") &&
		test -n "$new_a" && test -n "$new_b" && test -n "$new_c" &&
		test "$master" = "$(git rev-parse "$new_a^")" &&
		test "$new_a" = "$(git rev-parse "$new_b^")" &&
		test "$master" = "$(git rev-parse "$new_c^")" &&
		git merge-base --is-ancestor "$master" "$new_a" &&
		git merge-base --is-ancestor "$master" "$new_b" &&
		git merge-base --is-ancestor "$master" "$new_c" &&

		manifest_has aa/codex/a "$old_a" "$new_a" updates &&
		manifest_has bb/codex/b "$old_b" "$new_b" updates &&
		manifest_has cc/codex/c "$old_c" "$new_c" updates &&
		sh "$codex_branch" verify-topic --topic aa/codex/a \
			--inputs inputs --updates updates --result result &&
		sh "$codex_branch" verify-topic --topic bb/codex/b \
			--inputs inputs --updates updates --result result &&
		sh "$codex_branch" verify-topic --topic cc/codex/c \
			--inputs inputs --updates updates --result result &&
		sed "s/$new_b\$/$master/" updates >updates-bad &&
		sh "$codex_branch" verify-topic --topic aa/codex/a \
			--inputs inputs --updates updates-bad --result result &&
		sh "$codex_branch" verify-topic --topic cc/codex/c \
			--inputs inputs --updates updates-bad --result result &&
		test_expect_code 1 sh "$codex_branch" verify-topic \
			--topic bb/codex/b --inputs inputs \
			--updates updates-bad --result result \
			2>verify-topic.err &&
		test_grep "lost prerequisite.*aa/codex/a.*bb/codex/b" \
			verify-topic.err &&

		last_merge=$(git rev-parse "$candidate") &&
		first_merge=$(git rev-parse "$last_merge^") &&
		test "$new_c" = "$(git rev-parse "$last_merge^2")" &&
		test "$new_b" = "$(git rev-parse "$first_merge^2")" &&
		test "$master" = "$(git rev-parse "$first_merge^")" &&
		test 2 = "$(git rev-list --count --merges "$master..$candidate")" &&

		sh "$codex_branch" verify-inputs \
			--remote origin --base master --codex codex inputs &&
		git push --atomic --force origin \
			"${new_a}:refs/heads/aa/codex/a" \
			"${new_b}:refs/heads/bb/codex/b" \
			"${new_c}:refs/heads/cc/codex/c" \
			"${candidate}:refs/heads/codex"
	) &&

	git clone graph.git graph-noop &&
	(
		cd graph-noop &&
		fetch_all &&
		old_result=$(git rev-parse origin/codex) &&
		snapshot_refs ../graph.git >before &&
		sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure &&
		test "$old_result" = "$(cat result)" &&
		snapshot_refs ../graph.git >after &&
		test_cmp before after &&
		sh "$codex_branch" verify-inputs \
			--remote origin --base master --codex codex inputs &&

		old_a=$(git rev-parse origin/aa/codex/a) &&
		old_b=$(git rev-parse origin/bb/codex/b) &&
		git --git-dir=../graph.git update-ref \
			refs/heads/aa/codex/a "$old_b" "$old_a" &&
		test_expect_code 1 sh "$codex_branch" verify-inputs \
			--remote origin --base master --codex codex inputs
	)
'

test_expect_success 'shared private history needs a prerequisite topic' '
	git init --bare shared-private.git &&
	test_create_repo shared-private-source &&
	(
		cd shared-private-source &&
		git remote add origin ../shared-private.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c shared-prefix &&
		write prefix prefix-file &&
		git add prefix-file &&
		git commit -m "unrepresented shared prefix" &&

		git switch -c aa/codex/a &&
		write A a &&
		git add a &&
		git commit -m "shared child A" &&

		git switch -c bb/codex/b shared-prefix &&
		write B b &&
		git add b &&
		git commit -m "shared child B" &&

		git switch master &&
		write master master-file &&
		git add master-file &&
		git commit -m "new shared-prefix master" &&
		git branch meta master &&
		git push origin master meta codex aa/codex/a bb/codex/b
	) &&

	git clone shared-private.git shared-private-runner &&
	(
		cd shared-private-runner &&
		fetch_all &&
		snapshot_refs ../shared-private.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates --inputs inputs \
			--failure failure >out 2>err &&
		test_grep "share private commits" err &&
		test_grep "prerequisite topic" err &&
		test_grep "restack" err &&
		snapshot_refs ../shared-private.git >after &&
		test_cmp before after
	)
'

test_expect_success 'represented prerequisite siblings rebase in parallel' '
	git init --bare parallel.git &&
	test_create_repo parallel-source &&
	(
		cd parallel-source &&
		git remote add origin ../parallel.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/release &&
		write first release-first &&
		git add release-first &&
		git commit -m "release first" &&
		write second release-second &&
		git add release-second &&
		git commit -m "release second" &&

		git switch -c bb/codex/one &&
		write one child-one &&
		git add child-one &&
		git commit -m "release child one" &&

		git switch -c cc/codex/two aa/codex/release &&
		write two child-two &&
		git add child-two &&
		git commit -m "release child two" &&

		git switch master &&
		write master master-file &&
		git add master-file &&
		git commit -m "new parallel master" &&
		git branch meta master &&
		git push origin master meta codex \
			aa/codex/release bb/codex/one cc/codex/two
	) &&

	git clone parallel.git parallel-runner &&
	(
		cd parallel-runner &&
		fetch_all &&
		real_git=$(command -v git) &&
		barrier=$PWD/parallel-barrier &&
		mkdir "$barrier" parallel-bin &&
		write "#!/bin/sh
case \" \$* \" in
*\"/parallel/worker-\"*\"rebase --merge\"*)
	marker=\"$barrier/\$\$\"
	: >\"\$marker\"
	attempts=0
	while test \"\$(find \"$barrier\" -type f | wc -l | tr -d \" \")\" -lt 2
	do
		attempts=\$((attempts + 1))
		test \"\$attempts\" -lt 6 || exit 97
		sleep 1
	done
	;;
esac
exec \"$real_git\" \"\$@\"" parallel-bin/git &&
		chmod +x parallel-bin/git &&

		env PATH="$PWD/parallel-bin:$PATH" sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates --inputs inputs \
			--failure failure >out 2>err &&
		test_grep "Rebasing 2 ready topics in parallel" out &&
		test_grep ! "recreating the wave" err &&
		test 2 -le "$(find "$barrier" -type f | wc -l | tr -d " ")" &&

		master=$(git rev-parse origin/master) &&
		old_release=$(git rev-parse origin/aa/codex/release) &&
		old_one=$(git rev-parse origin/bb/codex/one) &&
		old_two=$(git rev-parse origin/cc/codex/two) &&
		new_release=$(awk -F "$(printf '\''\t'\'')" \
			'\''$1 == "refs/heads/aa/codex/release" { print $3 }'\'' \
			updates) &&
		new_one=$(awk -F "$(printf '\''\t'\'')" \
			'\''$1 == "refs/heads/bb/codex/one" { print $3 }'\'' \
			updates) &&
		new_two=$(awk -F "$(printf '\''\t'\'')" \
			'\''$1 == "refs/heads/cc/codex/two" { print $3 }'\'' \
			updates) &&
		manifest_has aa/codex/release "$old_release" "$new_release" updates &&
		manifest_has bb/codex/one "$old_one" "$new_one" updates &&
		manifest_has cc/codex/two "$old_two" "$new_two" updates &&
		first=$(find_subject "release first" "$new_release") &&
		test "$master" = "$(git rev-parse "$first^")" &&
		test "$first" = "$(git rev-parse "$new_release^")" &&
		test "$new_release" = "$(git rev-parse "$new_one^")" &&
		test "$new_release" = "$(git rev-parse "$new_two^")" &&
		git merge-base --is-ancestor "$new_release" "$new_one" &&
		git merge-base --is-ancestor "$new_release" "$new_two"
	)
'

test_expect_success 'rewrite bundle transfers the exact output over pinned inputs' '
	git init --bare bundle.git &&
	test_create_repo bundle-source &&
	(
		cd bundle-source &&
		git remote add origin ../bundle.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/bundle &&
		write topic topic-file &&
		git add topic-file &&
		git commit -m "bundle topic" &&

		git switch master &&
		write master master-file &&
		git add master-file &&
		git commit -m "bundle master" &&
		git branch meta master &&
		git push origin master meta codex aa/codex/bundle
	) &&

	git clone bundle.git bundle-builder &&
	(
		cd bundle-builder &&
		fetch_all &&
		sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --bundle candidate.bundle \
			--failure failure &&
		git bundle verify candidate.bundle &&
		candidate=$(cat result) &&
		test "$candidate" = "$(git bundle list-heads candidate.bundle |
			awk '\''$2 == "refs/codex-output/candidate" { print $1 }'\'')" &&
		test_must_fail git show-ref --verify \
			refs/codex-output/candidate
	) &&

	git clone bundle.git bundle-verifier &&
	(
		cd bundle-verifier &&
		fetch_all &&
		git fetch ../bundle-builder/candidate.bundle \
			refs/codex-output/candidate:refs/codex-output/candidate &&
		test "$(cat ../bundle-builder/result)" = \
			"$(git rev-parse refs/codex-output/candidate)" &&
		sh "$codex_branch" verify-output \
			--inputs ../bundle-builder/inputs \
			--updates ../bundle-builder/updates \
			--result ../bundle-builder/result
	)
'

test_expect_success 'a topic already in master still produces a valid bundle' '
	git init --bare bundled-noop.git &&
	test_create_repo bundled-noop-source &&
	(
		cd bundled-noop-source &&
		git remote add origin ../bundled-noop.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch meta &&
		git branch aa/codex/done &&
		git push origin master meta codex aa/codex/done
	) &&

	git clone bundled-noop.git bundled-noop-runner &&
	(
		cd bundled-noop-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs \
			--bundle candidate.bundle --failure failure &&
		test "$(git rev-parse origin/master)" = "$(cat result)" &&
		git bundle verify candidate.bundle &&
		test "$(cat result) refs/codex-output/candidate" = \
			"$(git bundle list-heads candidate.bundle)"
	)
'

test_expect_success 'a topic already in master is not a private prerequisite' '
	git init --bare old-prerequisite.git &&
	test_create_repo old-prerequisite-source &&
	(
		cd old-prerequisite-source &&
		git remote add origin ../old-prerequisite.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/done &&
		write done done-file &&
		git add done-file &&
		git commit -m "topic now in master" &&

		git switch master &&
		git merge --ff-only aa/codex/done &&
		write upstream upstream-file &&
		git add upstream-file &&
		git commit -m "upstream after old topic" &&

		git switch -c bb/codex/dependent &&
		write dependent dependent-file &&
		git add dependent-file &&
		git commit -m "dependent after upstream" &&

		git switch master &&
		write newest newest-file &&
		git add newest-file &&
		git commit -m "newest master" &&
		git branch meta master &&
		git push origin master meta codex \
			aa/codex/done bb/codex/dependent
	) &&

	git clone old-prerequisite.git old-prerequisite-runner &&
	(
		cd old-prerequisite-runner &&
		fetch_all &&
		master=$(git rev-parse origin/master) &&
		old_done=$(git rev-parse origin/aa/codex/done) &&
		old_dependent=$(git rev-parse origin/bb/codex/dependent) &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		new_done=$(awk -F "$(printf '\''\t'\'')" \
			'\''$1 == "refs/heads/aa/codex/done" { print $3 }'\'' \
			updates) &&
		new_dependent=$(awk -F "$(printf '\''\t'\'')" \
			'\''$1 == "refs/heads/bb/codex/dependent" { print $3 }'\'' \
			updates) &&
		test "$master" = "$new_done" &&
		test "$master" = "$(git rev-parse "$new_dependent^")" &&
		test 1 = "$(git rev-list --count "$master..$new_dependent")" &&
		manifest_has aa/codex/done "$old_done" "$new_done" updates &&
		manifest_has bb/codex/dependent \
			"$old_dependent" "$new_dependent" updates
	)
'

test_expect_success 'publish uses exact leases and updates all refs atomically' '
	git init --bare publish.git &&
	test_create_repo publish-source &&
	(
		cd publish-source &&
		git remote add origin ../publish.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/a &&
		write A a &&
		git add a &&
		git commit -m "publish topic A" &&

		git switch -c bb/codex/b master &&
		write B b &&
		git add b &&
		git commit -m "publish topic B" &&

		git switch master &&
		write master master-file &&
		git add master-file &&
		git commit -m "publish master" &&
		git branch meta master &&
		git push origin master meta codex aa/codex/a bb/codex/b
	) &&

	git clone publish.git publish-runner &&
	(
		cd publish-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure &&
		sh "$codex_branch" verify-output \
			--inputs inputs --updates updates --result result &&
		GIT_TRACE=1 sh "$codex_branch" publish \
			--remote origin --inputs inputs --updates updates \
			>publish.out 2>publish.trace &&
		test_grep "push --atomic --porcelain" publish.trace &&
		while IFS="$(printf '\''\t'\'')" read -r ref old new
		do
			grep -F "force-with-lease=$ref:$old" publish.trace &&
			test "$new" = "$(git --git-dir=../publish.git \
				rev-parse "$ref")" || return 1
		done <updates
	)
'

test_expect_success 'one ref racing after verification rejects the whole publish' '
	git init --bare publish-race.git &&
	test_create_repo publish-race-source &&
	(
		cd publish-race-source &&
		git remote add origin ../publish-race.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/a &&
		write A a &&
		git add a &&
		git commit -m "racing topic A" &&

		git switch -c bb/codex/b master &&
		write B b &&
		git add b &&
		git commit -m "racing topic B" &&

		git switch master &&
		write master master-file &&
		git add master-file &&
		git commit -m "racing master" &&
		git branch meta master &&
		git push origin master meta codex aa/codex/a bb/codex/b
	) &&

	git clone publish-race.git publish-race-runner &&
	(
		cd publish-race-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure &&
		sh "$codex_branch" verify-output \
			--inputs inputs --updates updates --result result &&

		race_ref=refs/heads/aa/codex/a &&
		race_old=$(awk -F "$(printf '\''\t'\'')" -v ref="$race_ref" \
			'\''$1 == ref { print $2 }'\'' updates) &&
		race_new=$(git rev-parse origin/master) &&
		test "$race_old" != "$race_new" &&
		real_git=$(command -v git) &&
		remote_git=$(pwd)/../publish-race.git &&
		mkdir race-bin &&
		write "#!/bin/sh
case \" \$* \" in
*\" push \"*)
	\"$real_git\" --git-dir=\"$remote_git\" update-ref \\
		\"$race_ref\" \"$race_new\" \"$race_old\" || exit
	;;
esac
exec \"$real_git\" \"\$@\"" race-bin/git &&
		chmod +x race-bin/git &&

		test_expect_code 1 env PATH="$PWD/race-bin:$PATH" \
			sh "$codex_branch" publish \
			--remote origin --inputs inputs --updates updates \
			>publish.out 2>publish.err &&
		test "$race_new" = "$(git --git-dir=../publish-race.git \
			rev-parse "$race_ref")" &&
		while IFS="$(printf '\''\t'\'')" read -r ref old new
		do
			test "$ref" = "$race_ref" && continue
			test "$old" = "$(git --git-dir=../publish-race.git \
				rev-parse "$ref")" || return 1
		done <updates &&
		test_grep -i "atomic\|stale\|failed to update ref" publish.err
	)
'

test_expect_success 'a non-conflict rebase error fails closed' '
	git init --bare rebase-error.git &&
	test_create_repo rebase-error-source &&
	(
		cd rebase-error-source &&
		git remote add origin ../rebase-error.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/error &&
		write topic topic-file &&
		git add topic-file &&
		git commit -m "rebase error topic" &&

		git switch master &&
		write master master-file &&
		git add master-file &&
		git commit -m "rebase error master" &&
		git branch meta master &&
		git push origin master meta codex aa/codex/error
	) &&

	git clone rebase-error.git rebase-error-runner &&
	(
		cd rebase-error-runner &&
		fetch_all &&
		real_git=$(command -v git) &&
		mkdir fail-bin &&
		write "#!/bin/sh
case \" \$* \" in
*\" rebase --merge \"*) exit 88 ;;
esac
exec \"$real_git\" \"\$@\"" fail-bin/git &&
		chmod +x fail-bin/git &&
		snapshot_refs ../rebase-error.git >before &&
		test_expect_code 1 env PATH="$PWD/fail-bin:$PATH" \
			sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			>out 2>err &&
		test_grep "failed without leaving recoverable state" err &&
		test_path_is_missing result &&
		test_path_is_missing failure &&
		snapshot_refs ../rebase-error.git >after &&
		test_cmp before after
	)
'

test_expect_success 'rewrite conflicts do not write the remote and give a pinned recipe' '
	git init --bare conflict.git &&
	test_create_repo conflict-source &&
	(
		cd conflict-source &&
		git remote add origin ../conflict.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c zz/codex/root &&
		write before root-before &&
		git add root-before &&
		git commit -m "root before conflict" &&
		write topic shared &&
		git add shared &&
		git commit -m "conflicting root" &&
		write after root-after &&
		git add root-after &&
		git commit -m "root after conflict" &&

		git switch -c aa/codex/dependent &&
		write dependent dependent-file &&
		git add dependent-file &&
		git commit -m "dependent topic" &&

		git switch -c yy/codex/clean master &&
		write clean clean-file &&
		git add clean-file &&
		git commit -m "independent clean topic" &&

		git switch master &&
		write master shared &&
		git add shared &&
		git commit -m "conflicting master" &&
		git branch meta master &&
		git push origin master meta codex \
			aa/codex/dependent yy/codex/clean zz/codex/root
	) &&

	git clone conflict.git conflict-runner &&
	(
		cd conflict-runner &&
		fetch_all &&
		controller=$(git rev-parse HEAD) &&
		base=$(git rev-parse origin/master) &&
		codex=$(git rev-parse origin/codex) &&
		dependent=$(git rev-parse origin/aa/codex/dependent) &&
		clean=$(git rev-parse origin/yy/codex/clean) &&
		root=$(git rev-parse origin/zz/codex/root) &&
		printf "controller\tmeta\t%s\nbase\trefs/heads/master\t%s\ncodex\trefs/heads/codex\t%s\ntopic\trefs/heads/aa/codex/dependent\t%s\ntopic\trefs/heads/yy/codex/clean\t%s\ntopic\trefs/heads/zz/codex/root\t%s\n" \
			"$controller" "$base" "$codex" "$dependent" "$clean" "$root" \
			>expected-inputs &&
		digest=$(git hash-object expected-inputs) &&
		snapshot_refs ../conflict.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure \
			>rewrite.out 2>rewrite.err &&
		test_grep "Rebasing 2 ready topics in parallel" rewrite.out &&
		test_grep "recreating the wave" rewrite.err &&
		snapshot_refs ../conflict.git >after &&
		test_cmp before after &&
		test_path_is_file failure &&
		test_grep "zz/codex/root" failure &&
		test_grep "$controller" failure &&
		test_grep "$digest" failure &&
		test_grep "git status" failure &&
		test_grep "git rebase --show-current-patch" failure &&
		test_grep "git add" failure &&
		test_grep "git rebase --continue" failure &&
		test_grep "codex-branch continue" failure &&
		test_grep "git push --force-with-lease" failure &&
		test_grep "Do not force-push only" failure &&

		sh "$codex_branch" resolve --remote origin \
			--base master --codex codex --inputs-oid "$digest" \
			--worktree quit-resolution >quit-resolve.out &&
		git -C quit-resolution rebase --quit &&
		git -C quit-resolution restore --staged --worktree . &&
		test_expect_code 1 sh "$codex_branch" continue \
			--worktree quit-resolution >quit-continue.out 2>quit-continue.err &&
		test_grep "completion sentinel" quit-continue.err &&
		git worktree remove --force quit-resolution &&

		sh "$codex_branch" resolve --remote origin \
			--base master --codex codex --inputs-oid "$digest" \
			--worktree abort-resolution >abort-resolve.out &&
		git -C abort-resolution rebase --abort &&
		test_expect_code 1 sh "$codex_branch" continue \
			--worktree abort-resolution >abort-continue.out \
			2>abort-continue.err &&
		test_grep "was aborted" abort-continue.err &&
		git worktree remove --force abort-resolution &&

		sh "$codex_branch" resolve --remote origin \
			--base master --codex codex --inputs-oid "$digest" \
			--worktree resolution >resolve.out &&
		test_grep "Resolution worktree" resolve.out &&
		write resolved resolution/shared &&
		git -C resolution add shared &&
		GIT_EDITOR=true git -C resolution rebase --continue &&
		sh "$codex_branch" continue --worktree resolution \
			>continue.out &&
		test_grep "publish-topics" continue.out &&
		sh "$codex_branch" publish-topics --worktree resolution &&
		new_root=$(git --git-dir=../conflict.git \
			rev-parse refs/heads/zz/codex/root) &&
		new_dependent=$(git --git-dir=../conflict.git \
			rev-parse refs/heads/aa/codex/dependent) &&
		new_clean=$(git --git-dir=../conflict.git \
			rev-parse refs/heads/yy/codex/clean) &&
		test "$root" != "$new_root" &&
		test "$dependent" != "$new_dependent" &&
		test "$clean" != "$new_clean" &&
		test "$new_root" = "$(git rev-parse "$new_dependent^")" &&
		test "$base" = "$(git rev-parse "$new_clean^")" &&
		test before = "$(git show "$new_root:root-before")" &&
		test after = "$(git show "$new_root:root-after")" &&
		test resolved = "$(git show "$new_root:shared")" &&
		test "$codex" = "$(git --git-dir=../conflict.git \
			rev-parse refs/heads/codex)" &&
		git worktree remove --force resolution
	)
'

test_expect_success 'integration conflicts identify the missing dependency' '
	git init --bare integration.git &&
	test_create_repo integration-source &&
	(
		cd integration-source &&
		git remote add origin ../integration.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch meta &&

		git switch -c aa/codex/a &&
		write A shared &&
		git add shared &&
		git commit -m "integration topic A" &&

		git switch -c bb/codex/b master &&
		write B shared &&
		git add shared &&
		git commit -m "integration topic B" &&
		git push origin master meta codex aa/codex/a bb/codex/b
	) &&

	git clone integration.git integration-runner &&
	(
		cd integration-runner &&
		fetch_all &&
		snapshot_refs ../integration.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates --inputs inputs \
			--failure failure >out 2>err &&
		test_path_is_file failure &&
		test_grep "integration conflict" failure &&
		test_grep "aa/codex/a" failure &&
		test_grep "bb/codex/b" failure &&
		test_grep shared failure &&
		test_grep "Make the real dependency explicit" failure &&
		test_grep "no refs were updated" err &&
		snapshot_refs ../integration.git >after &&
		test_cmp before after
	)
'

test_expect_success 'codex rerere history can resolve a topic rebase' '
	git init --bare rerere.git &&
	test_create_repo rerere-source &&
	(
		cd rerere-source &&
		git remote add origin ../rerere.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&

		git switch -c aa/codex/rerere &&
		write topic shared &&
		git add shared &&
		git commit -m "rerere topic" &&

		git switch master &&
		write master shared &&
		git add shared &&
		git commit -m "rerere master" &&
		git switch --detach master &&
		test_must_fail git merge --no-ff aa/codex/rerere &&
		write resolved shared &&
		git add shared &&
		git commit -m "record resolution" &&
		git branch codex &&

		git switch -c bb/codex/other aa/codex/rerere^ &&
		write other other-file &&
		git add other-file &&
		git commit -m "independent rerere sibling" &&

		git switch master &&
		git branch meta master &&
		git push origin master meta codex \
			aa/codex/rerere bb/codex/other
	) &&

	git clone rerere.git rerere-runner &&
	(
		cd rerere-runner &&
		fetch_all &&
		old_topic=$(git rev-parse origin/aa/codex/rerere) &&
		old_other=$(git rev-parse origin/bb/codex/other) &&
		sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure \
			>rewrite.out 2>rewrite.err &&
		test_grep "Rebasing 2 ready topics in parallel" rewrite.out &&
		test_grep ! "recreating the wave" rewrite.err &&
		candidate=$(cat result) &&
		new_topic=$(find_subject "rerere topic" "$candidate") &&
		new_other=$(find_subject "independent rerere sibling" "$candidate") &&
		test -n "$new_topic" &&
		test -n "$new_other" &&
		test resolved = "$(git show "$new_topic:shared")" &&
		manifest_has aa/codex/rerere \
			"$old_topic" "$new_topic" updates &&
		manifest_has bb/codex/other \
			"$old_other" "$new_other" updates
	)
'

test_expect_success 'rewrite rejects a private merge in a topic' '
	git init --bare private.git &&
	test_create_repo private-source &&
	(
		cd private-source &&
		git remote add origin ../private.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c private-side &&
		write private private-file &&
		git add private-file &&
		git commit -m private &&

		git switch -c aa/codex/merged master &&
		write topic topic-file &&
		git add topic-file &&
		git commit -m topic &&
		git merge --no-ff private-side -m "private merge" &&
		git branch meta master &&
		git push origin master meta codex aa/codex/merged
	) &&

	git clone private.git private-runner &&
	(
		cd private-runner &&
		fetch_all &&
		snapshot_refs ../private.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure \
			>out 2>err &&
		test_grep -i merge err &&
		snapshot_refs ../private.git >after &&
		test_cmp before after
	)
'

test_done
