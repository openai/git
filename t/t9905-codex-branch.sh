#!/bin/sh

test_description='rebasing Codex topics and assembling the generated branch'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=master
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

codex_branch=${CODEX_BRANCH:-$TEST_DIRECTORY/../.github/workflows/codex-branch.sh}
codex_workflow=${CODEX_WORKFLOW:-$(dirname "$codex_branch")/codex.yml}
codex_root=$(CDPATH= cd "$(dirname "$codex_branch")/../.." && pwd)
codex_entrypoint=${CODEX_ENTRYPOINT:-$codex_root/codex}

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

snapshot_without_staging () {
	snapshot_refs "$1" |
	sed '/^refs\/heads\/codex-staging[[:space:]]/d'
}

write_automation_workflow () {
	cat >"$1" <<-\EOF
	name: Refresh codex

	on: workflow_dispatch

	permissions:
	  actions: read
	  contents: read

	jobs:
	  refresh:
	    uses: openai/git/.github/workflows/codex.yml@meta
	EOF
}

write_release_workflow () {
	cat >"$2" <<-EOF
	name: Codex Git release

	on:
	  push:
	    branches:
	      - $1

	permissions:
	  contents: read
	EOF
}

install_meta_state () {
	meta_branch=$1
	base_branch=$2
	output_branch=$3
	meta_parent=$(git rev-parse "$meta_branch") &&
	output_tip=$(git rev-parse "$output_branch") &&
	state_topics=.codex-state-topics &&
	state_rows=.codex-state-rows &&
	state_bases=.codex-state-bases &&
	state_config=.codex-state-config &&
	state_index=.codex-state-index &&
	: >"$state_topics" &&
	git for-each-ref --format="%(refname:short)%09%(objectname)" refs/heads |
	while IFS="$(printf '\t')" read -r name oid
	do
		case "$name" in
		??/codex/?*) ;;
		*) continue ;;
		esac
		case "$name" in
		*-wip|*-stale|??/codex/*/*) continue ;;
		esac
		if git merge-base --is-ancestor "$oid" "$output_tip"
		then
			printf "%s\t%s\n" "$name" "$oid"
		fi
	done | LC_ALL=C sort >"$state_topics" &&
	set -- git merge-base --all --octopus "$base_branch" "$output_tip" &&
	while IFS="$(printf '\t')" read -r name oid
	do
		set -- "$@" "$oid"
	done <"$state_topics" &&
	"$@" >"$state_bases" &&
	test "$(wc -l <"$state_bases" | tr -d " ")" = 1 &&
	base_tip=$(sed -n 1p "$state_bases") &&
	: >"$state_rows" &&
	while IFS="$(printf '\t')" read -r name oid
	do
		prerequisite=$base_branch &&
		prerequisite_tip=$base_tip &&
		while IFS="$(printf '\t')" read -r other_name other_oid
		do
			test "$name" = "$other_name" && continue
			if git merge-base --is-ancestor "$other_oid" "$oid" &&
				git merge-base --is-ancestor "$prerequisite_tip" "$other_oid"
			then
				prerequisite=$other_name &&
				prerequisite_tip=$other_oid
			fi
		done <"$state_topics" &&
		printf "%s\t%s\t%s\n" "$name" "$oid" "$prerequisite" \
			>>"$state_rows"
	done <"$state_topics" &&
	{
		printf "[codex]\n" &&
		printf "\tversion = 1\n" &&
		printf "\tbase-ref = refs/heads/%s\n" "$base_branch" &&
		printf "\tbase-tip = %s\n" "$base_tip" &&
		printf "\toutput-ref = refs/heads/%s\n" "$output_branch" &&
		printf "\toutput-tip = %s\n" "$output_tip" &&
		while IFS="$(printf '\t')" read -r name oid prerequisite
		do
			printf "\n[branch \"%s\"]\n" "$name" &&
			printf "\tremote = .\n" &&
			printf "\tmerge = refs/heads/%s\n" "$prerequisite" &&
			printf "\tcodex-tip = %s\n" "$oid"
		done <"$state_rows"
	} >"$state_config" &&
	blob=$(git hash-object -w "$state_config") &&
	helper_blob=$(git hash-object -w "$codex_branch") &&
	rm -f "$state_index" &&
	GIT_INDEX_FILE=$state_index git read-tree "$meta_parent^{tree}" &&
	GIT_INDEX_FILE=$state_index git update-index --add --cacheinfo \
		100644,"$blob",codex.config &&
	GIT_INDEX_FILE=$state_index git update-index --add --cacheinfo \
		100755,"$helper_blob",.github/workflows/codex-branch.sh &&
	tree=$(GIT_INDEX_FILE=$state_index git write-tree) &&
	meta_tip=$(printf "%s\n" "meta: initialize Codex topic state" |
		git commit-tree "$tree" -p "$meta_parent") &&
	git update-ref "refs/heads/$meta_branch" "$meta_tip" "$meta_parent" &&
	rm -f "$state_topics" "$state_rows" "$state_bases" \
		"$state_config" "$state_index"
}

install_explicit_meta_state () (
	meta_branch=$1
	base_branch=$2
	output_branch=$3
	rows=$4
	meta_parent=$(git rev-parse "$meta_branch") &&
	output_tip=$(git rev-parse "$output_branch") &&
	state_bases=.codex-explicit-state-bases &&
	state_config=.codex-explicit-state-config &&
	state_index=.codex-explicit-state-index &&
	set -- git merge-base --all --octopus "$base_branch" "$output_tip" &&
	while IFS="$(printf '\t')" read -r name oid prerequisite
	do
		set -- "$@" "$oid"
	done <"$rows" &&
	"$@" >"$state_bases" &&
	test "$(wc -l <"$state_bases" | tr -d " ")" = 1 &&
	base_tip=$(sed -n 1p "$state_bases") &&
	{
		printf "[codex]\n" &&
		printf "\tversion = 1\n" &&
		printf "\tbase-ref = refs/heads/%s\n" "$base_branch" &&
		printf "\tbase-tip = %s\n" "$base_tip" &&
		printf "\toutput-ref = refs/heads/%s\n" "$output_branch" &&
		printf "\toutput-tip = %s\n" "$output_tip" &&
		while IFS="$(printf '\t')" read -r name oid prerequisite
		do
			printf "\n[branch \"%s\"]\n" "$name" &&
			printf "\tremote = .\n" &&
			printf "\tmerge = refs/heads/%s\n" "$prerequisite" &&
			printf "\tcodex-tip = %s\n" "$oid"
		done <"$rows"
	} >"$state_config" &&
	blob=$(git hash-object -w "$state_config") &&
	helper_blob=$(git hash-object -w "$codex_branch") &&
	rm -f "$state_index" &&
	GIT_INDEX_FILE=$state_index git read-tree "$meta_parent^{tree}" &&
	GIT_INDEX_FILE=$state_index git update-index --add --cacheinfo \
		100644,"$blob",codex.config &&
	GIT_INDEX_FILE=$state_index git update-index --add --cacheinfo \
		100755,"$helper_blob",.github/workflows/codex-branch.sh &&
	tree=$(GIT_INDEX_FILE=$state_index git write-tree) &&
	meta_tip=$(printf "%s\n" "meta: initialize explicit Codex topic state" |
		git commit-tree "$tree" -p "$meta_parent") &&
	git update-ref "refs/heads/$meta_branch" "$meta_tip" "$meta_parent" &&
	rm -f "$state_bases" "$state_config" "$state_index"
)

updated_tip () {
	awk -F "$(printf '\t')" -v ref="refs/heads/$1" \
		'$1 == ref { print $3 }' "$2"
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

test_expect_success 'generated commits do not hard-code the Actions bot' '
	! grep -F "github-actions[bot]" "$codex_branch"
'

test_expect_success 'refresh has no topic fanout and delegates testing to staging CI' '
	! grep -F "codex-topic.yml" "$codex_workflow" &&
	! grep -E "make -C|t9905-codex-branch.sh" "$codex_workflow" &&
	! grep -E "clone --shared|parallel worker" "$codex_branch" &&
	! grep -E "CODEX_BRANCH_TOKEN|CODEX_BRANCH_MANAGER_TOKEN|secret-broker|id-token" \
		"$codex_workflow" &&
	test_grep "CODEX_DEPLOY_KEY" "$codex_workflow" &&
	test_grep "environment: codex-publish" "$codex_workflow" &&
	test_grep "Wait for CI on the exact staging SHA" "$codex_workflow"
'

test_expect_success 'topics cannot change the meta branch ruleset' '
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
		mkdir -p .github/rulesets &&
		write untrusted .github/rulesets/codex-meta.json &&
		git add .github/rulesets/codex-meta.json &&
		git commit -m "change meta branch ruleset" &&

		git switch master &&
		write master master-file &&
		git add master-file &&
		git commit -m "new control-path master" &&
		git branch meta master &&
		install_meta_state meta master codex &&
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

test_expect_success 'required automation is the exact isolated trampoline' '
	git init --bare automation.git &&
	test_create_repo automation-source &&
	(
		cd automation-source &&
		git remote add origin ../automation.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/automation &&
		mkdir -p .github/workflows &&
		write_automation_workflow .github/workflows/codex.yml &&
		git add .github/workflows/codex.yml &&
		git commit -m "add automation trampoline" &&

		git switch -c automation-bad master &&
		mkdir -p .github/workflows &&
		write wrong .github/workflows/codex.yml &&
		git add .github/workflows/codex.yml &&
		git commit -m "add wrong automation" &&

		git switch -c automation-extra master &&
		mkdir -p .github/workflows &&
		write_automation_workflow .github/workflows/codex.yml &&
		write extra automation-extra &&
		git add .github/workflows/codex.yml automation-extra &&
		git commit -m "add non-isolated automation" &&

		git switch -c bb/codex/control master &&
		mkdir -p .github/workflows &&
		write changed .github/workflows/main.yml &&
		git add .github/workflows/main.yml &&
		git commit -m "change protected CI" &&

		git switch -c release-staging master &&
		mkdir -p .github/workflows &&
		write_release_workflow codex-staging \
			.github/workflows/codex-release.yml &&
		git add .github/workflows/codex-release.yml &&
		git commit -m "publish releases from staging" &&

		git switch -c release-credentials master &&
		mkdir -p .github/workflows &&
		write_release_workflow codex \
			.github/workflows/codex-release.yml &&
		echo "    'environment': production" \
			>>.github/workflows/codex-release.yml &&
		echo "    token: \${{ secrets.NOT_THE_PUBLISHER }}" \
			>>.github/workflows/codex-release.yml &&
		git add .github/workflows/codex-release.yml &&
		git commit -m "obtain promotion credentials in release" &&

		git switch -c workflow-extra master &&
		mkdir -p .github/workflows &&
		write untrusted .github/workflows/extra.yml &&
		git add .github/workflows/extra.yml &&
		git commit -m "add another workflow" &&

		git switch -c cc/codex/feature master &&
		write feature feature-file &&
		git add feature-file &&
		git commit -m "ordinary feature" &&

		git switch master &&
		write master master-file &&
		git add master-file &&
		git commit -m "automation master" &&
		git branch meta master &&
		install_meta_state meta master codex &&
		git push origin master meta codex aa/codex/automation \
			cc/codex/feature automation-bad automation-extra \
			bb/codex/control:refs/heads/control-invalid \
			release-staging:refs/heads/release-invalid \
			release-credentials:refs/heads/release-credentials-invalid \
			workflow-extra:refs/heads/workflow-invalid
	) &&

	git clone automation.git automation-runner &&
	(
		cd automation-runner &&
		fetch_all &&
		snapshot_refs ../automation.git >before &&
		good=$(git rev-parse origin/aa/codex/automation) &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			--require-automation &&
		candidate=$(cat result) &&
		write_automation_workflow expected-automation.yml &&
		git show "$candidate:.github/workflows/codex.yml" \
			>actual-automation.yml &&
		test_cmp expected-automation.yml actual-automation.yml &&

		git --git-dir=../automation.git update-ref -d \
			refs/heads/aa/codex/automation &&
		fetch_all &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result missing-result --updates missing-updates \
			--inputs missing-inputs --failure missing-failure \
			--require-automation 2>missing.err &&
		test_grep "canonical Refresh codex workflow" missing.err &&

		git --git-dir=../automation.git update-ref \
			refs/heads/aa/codex/automation "$good" &&
		git --git-dir=../automation.git update-ref \
			refs/heads/dd/codex/automation "$good" &&
		fetch_all &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result duplicate-result --updates duplicate-updates \
			--inputs duplicate-inputs --failure duplicate-failure \
			--require-automation 2>duplicate.err &&
		test_grep "exactly one active.*automation topic" duplicate.err &&
		git --git-dir=../automation.git update-ref -d \
			refs/heads/dd/codex/automation "$good" &&

		bad=$(git --git-dir=../automation.git \
			rev-parse refs/heads/automation-bad) &&
		git --git-dir=../automation.git update-ref \
			refs/heads/aa/codex/automation "$bad" "$good" &&
		fetch_all &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result bad-result --updates bad-updates \
			--inputs bad-inputs --failure bad-failure \
			--require-automation 2>bad.err &&
		test_grep "canonical Refresh codex workflow" bad.err &&

		extra=$(git --git-dir=../automation.git \
			rev-parse refs/heads/automation-extra) &&
		git --git-dir=../automation.git update-ref \
			refs/heads/aa/codex/automation "$extra" "$bad" &&
		fetch_all &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result extra-result --updates extra-updates \
			--inputs extra-inputs --failure extra-failure \
			--require-automation 2>extra.err &&
		test_grep "must change only .github/workflows/codex.yml" \
			extra.err &&

		control=$(git --git-dir=../automation.git \
			rev-parse refs/heads/control-invalid) &&
		git --git-dir=../automation.git update-ref \
			refs/heads/aa/codex/automation "$good" "$extra" &&
		git --git-dir=../automation.git update-ref \
			refs/heads/bb/codex/control "$control" &&
		fetch_all &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result control-result --updates control-updates \
			--inputs control-inputs --failure control-failure \
			--require-automation 2>control.err &&
		test_grep "protected controller or CI file" control.err &&
		git --git-dir=../automation.git update-ref -d \
			refs/heads/bb/codex/control "$control" &&

		release=$(git --git-dir=../automation.git \
			rev-parse refs/heads/release-invalid) &&
		git --git-dir=../automation.git update-ref \
			refs/heads/bb/codex/control "$release" &&
		fetch_all &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result release-result --updates release-updates \
			--inputs release-inputs --failure release-failure \
			--require-automation 2>release.err &&
		test_grep "release workflow must run only for pushes to codex" \
			release.err &&
		git --git-dir=../automation.git update-ref -d \
			refs/heads/bb/codex/control "$release" &&

		release_credentials=$(git --git-dir=../automation.git \
			rev-parse refs/heads/release-credentials-invalid) &&
		git --git-dir=../automation.git update-ref \
			refs/heads/bb/codex/control "$release_credentials" &&
		fetch_all &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result release-credentials-result \
			--updates release-credentials-updates \
			--inputs release-credentials-inputs \
			--failure release-credentials-failure \
			--require-automation 2>release-credentials.err &&
		test_grep "must not obtain promotion credentials" \
			release-credentials.err &&
		git --git-dir=../automation.git update-ref -d \
			refs/heads/bb/codex/control "$release_credentials" &&

		extra_workflow=$(git --git-dir=../automation.git \
			rev-parse refs/heads/workflow-invalid) &&
		git --git-dir=../automation.git update-ref \
			refs/heads/bb/codex/control "$extra_workflow" &&
		fetch_all &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result workflow-result --updates workflow-updates \
			--inputs workflow-inputs --failure workflow-failure \
			--require-automation 2>workflow.err &&
		test_grep "protected controller or CI file" workflow.err &&
		git --git-dir=../automation.git update-ref -d \
			refs/heads/bb/codex/control "$extra_workflow" &&
		snapshot_refs ../automation.git >after &&
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
		install_meta_state meta master codex &&
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
		install_meta_state meta master codex &&
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
		git config user.name "github-actions[bot]" &&
		git config user.email \
			"41898282+github-actions[bot]@users.noreply.github.com" &&

		(
			unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL &&
			GIT_COMMITTER_DATE="2002-02-02T00:00:00 +0000" \
			sh "$codex_branch" rewrite \
				--remote origin --base master --codex codex \
				--result result --updates updates \
				--inputs inputs \
				--failure failure
		) >rewrite.out 2>rewrite.err &&
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

		last_merge=$(git rev-parse "$candidate") &&
		first_merge=$(git rev-parse "$last_merge^") &&
		test "$(git show -s --format=%cn "$new_a")" = \
			"github-actions[bot]" &&
		test "$(git show -s --format=%cn "$new_b")" = \
			"github-actions[bot]" &&
		test "$(git show -s --format=%cn "$new_c")" = \
			"github-actions[bot]" &&
		test "$(git show -s --format=%cn "$first_merge")" = \
			"github-actions[bot]" &&
		test "$(git show -s --format=%cn "$last_merge")" = \
			"github-actions[bot]" &&
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
		install_meta_state meta master codex &&
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

test_expect_success 'represented prerequisite siblings rebase sequentially' '
	git init --bare sequential.git &&
	test_create_repo sequential-source &&
	(
		cd sequential-source &&
		git remote add origin ../sequential.git &&
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
		git commit -m "new sequential master" &&
		git branch meta master &&
		install_meta_state meta master codex &&
		git push origin master meta codex \
			aa/codex/release bb/codex/one cc/codex/two
	) &&

	git clone sequential.git sequential-runner &&
	(
		cd sequential-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates --inputs inputs \
			--failure failure >out 2>err &&

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
		install_meta_state meta master codex &&
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
		meta=$(updated_tip meta updates) &&
		test 2 = "$(git bundle list-heads candidate.bundle | wc -l |
			tr -d " ")" &&
		test "$candidate" = "$(git bundle list-heads candidate.bundle |
			awk '\''$2 == "refs/codex-output/candidate" { print $1 }'\'')" &&
		test "$meta" = "$(git bundle list-heads candidate.bundle |
			awk '\''$2 == "refs/codex-output/meta" { print $1 }'\'')" &&
		test_must_fail git show-ref --verify \
			refs/codex-output/candidate &&
		test_must_fail git show-ref --verify refs/codex-output/meta
	) &&

	git clone bundle.git bundle-verifier &&
	(
		cd bundle-verifier &&
		fetch_all &&
		git fetch ../bundle-builder/candidate.bundle \
			"+refs/codex-output/*:refs/codex-output/*" &&
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
		install_meta_state meta master codex &&
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
		candidate=$(cat result) &&
		meta=$(updated_tip meta updates) &&
		test "$candidate" = "$(git bundle list-heads candidate.bundle |
			awk '\''$2 == "refs/codex-output/candidate" { print $1 }'\'')" &&
		test "$meta" = "$(git bundle list-heads candidate.bundle |
			awk '\''$2 == "refs/codex-output/meta" { print $1 }'\'')"
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
		install_meta_state meta master codex &&
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

test_expect_success 'stage leaves primary refs untouched and promote is atomic' '
	git init --bare promotion.git &&
	test_create_repo promotion-source &&
	(
		cd promotion-source &&
		git remote add origin ../promotion.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/a &&
		write A a &&
		git add a &&
		git commit -m "promotion topic A" &&

		git switch -c bb/codex/b master &&
		write B b &&
		git add b &&
		git commit -m "promotion topic B" &&

		git switch master &&
		write master master-file &&
		git add master-file &&
		git commit -m "promotion master" &&
		git branch meta master &&
		install_meta_state meta master codex &&
		git push origin master meta codex aa/codex/a bb/codex/b
	) &&

	git clone promotion.git promotion-runner &&
	(
		cd promotion-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure &&
		sh "$codex_branch" verify-output \
			--inputs inputs --updates updates --result result &&
		candidate=$(cat result) &&
		snapshot_without_staging ../promotion.git >before-stage &&
		GIT_TRACE=1 sh "$codex_branch" stage \
			--remote origin --inputs inputs --updates updates \
			>stage.out 2>stage.trace &&
		test_grep "push --atomic --porcelain" stage.trace &&
		test_grep \
			"force-with-lease=refs/heads/codex-staging:" \
			stage.trace &&
		test "$candidate" = "$(git --git-dir=../promotion.git \
			rev-parse refs/heads/codex-staging)" &&
		snapshot_without_staging ../promotion.git >after-stage &&
		test_cmp before-stage after-stage &&

		GIT_TRACE=1 sh "$codex_branch" stage \
			--remote origin --inputs inputs --updates updates \
			>restage.out 2>restage.trace &&
		test 2 = "$(grep -c "push --atomic --porcelain" \
			restage.trace)" &&
		grep -F \
			"force-with-lease=refs/heads/codex-staging:$candidate" \
			restage.trace &&
		grep -F ":refs/heads/codex-staging" restage.trace &&
		grep -F \
			"force-with-lease=refs/heads/codex-staging:" \
			restage.trace &&
		grep -F "$candidate:refs/heads/codex-staging" \
			restage.trace &&
		test "$candidate" = "$(git --git-dir=../promotion.git \
			rev-parse refs/heads/codex-staging)" &&
		snapshot_without_staging ../promotion.git >after-restage &&
		test_cmp before-stage after-restage &&
		while IFS="$(printf '\''\t'\'')" read -r ref old new
		do
			test "$old" = "$(git --git-dir=../promotion.git \
				rev-parse "$ref")" || return 1
		done <updates &&

		GIT_TRACE=1 sh "$codex_branch" promote \
			--remote origin --inputs inputs --updates updates \
			>promote.out 2>promote.trace &&
		test_grep "push --atomic --porcelain" promote.trace &&
		grep -F \
			"force-with-lease=refs/heads/codex-staging:$candidate" \
			promote.trace &&
		grep -F ":refs/heads/codex-staging" promote.trace &&
		while IFS="$(printf '\''\t'\'')" read -r ref old new
		do
			grep -F "force-with-lease=$ref:$old" promote.trace &&
			test "$new" = "$(git --git-dir=../promotion.git \
				rev-parse "$ref")" || return 1
		done <updates &&
		test_must_fail git --git-dir=../promotion.git rev-parse --verify \
			refs/heads/codex-staging
	)
'

test_expect_success 'stale staging and output leases fail without partial promotion' '
	git init --bare promotion-race.git &&
	test_create_repo promotion-race-source &&
	(
		cd promotion-race-source &&
		git remote add origin ../promotion-race.git &&
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
		install_meta_state meta master codex &&
		git push origin master meta codex aa/codex/a bb/codex/b
	) &&

	git clone promotion-race.git promotion-race-runner &&
	(
		cd promotion-race-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure &&
		sh "$codex_branch" verify-output \
			--inputs inputs --updates updates --result result &&
		candidate=$(cat result) &&
		master=$(git rev-parse origin/master) &&
		sh "$codex_branch" stage --remote origin \
			--inputs inputs --updates updates &&
		snapshot_without_staging ../promotion-race.git >primary-before &&

		git --git-dir=../promotion-race.git update-ref \
			refs/heads/codex-staging "$master" "$candidate" &&
		test_expect_code 1 sh "$codex_branch" promote \
			--remote origin --inputs inputs --updates updates \
			>staging.out 2>staging.err &&
		test_grep "staging ref.*moved or disappeared" staging.err &&
		snapshot_without_staging ../promotion-race.git \
			>primary-after-staging-race &&
		test_cmp primary-before primary-after-staging-race &&
		git --git-dir=../promotion-race.git update-ref \
			refs/heads/codex-staging "$candidate" "$master" &&

		race_ref=refs/heads/aa/codex/a &&
		race_old=$(awk -F "$(printf '\''\t'\'')" -v ref="$race_ref" \
			'\''$1 == ref { print $2 }'\'' updates) &&
		race_new=$master &&
		test "$race_old" != "$race_new" &&
		real_git=$(command -v git) &&
		remote_git=$(pwd)/../promotion-race.git &&
		mkdir topic-race-bin &&
		write "#!/bin/sh
case \" \$* \" in
*\" push \"*)
	\"$real_git\" --git-dir=\"$remote_git\" update-ref \\
		\"$race_ref\" \"$race_new\" \"$race_old\" || exit
	;;
esac
exec \"$real_git\" \"\$@\"" topic-race-bin/git &&
		chmod +x topic-race-bin/git &&

		test_expect_code 1 env PATH="$PWD/topic-race-bin:$PATH" \
			sh "$codex_branch" promote \
			--remote origin --inputs inputs --updates updates \
			>topic-race.out 2>topic-race.err &&
		test "$race_new" = "$(git --git-dir=../promotion-race.git \
			rev-parse "$race_ref")" &&
		while IFS="$(printf '\''\t'\'')" read -r ref old new
		do
			test "$ref" = "$race_ref" && continue
			test "$old" = "$(git --git-dir=../promotion-race.git \
				rev-parse "$ref")" || return 1
		done <updates &&
		test "$candidate" = "$(git --git-dir=../promotion-race.git \
			rev-parse refs/heads/codex-staging)" &&
		test_grep -i "atomic\|stale\|failed to update ref" topic-race.err &&
		git --git-dir=../promotion-race.git update-ref \
			"$race_ref" "$race_old" "$race_new" &&
		snapshot_without_staging ../promotion-race.git \
			>primary-after-topic-race &&
		test_cmp primary-before primary-after-topic-race &&

		race_ref=refs/heads/codex &&
		race_old=$(awk -F "$(printf '\''\t'\'')" -v ref="$race_ref" \
			'\''$1 == ref { print $2 }'\'' updates) &&
		race_new=$master &&
		test "$race_old" != "$race_new" &&
		mkdir codex-race-bin &&
		write "#!/bin/sh
case \" \$* \" in
*\" push \"*)
	\"$real_git\" --git-dir=\"$remote_git\" update-ref \\
		\"$race_ref\" \"$race_new\" \"$race_old\" || exit
	;;
esac
exec \"$real_git\" \"\$@\"" codex-race-bin/git &&
		chmod +x codex-race-bin/git &&

		test_expect_code 1 env PATH="$PWD/codex-race-bin:$PATH" \
			sh "$codex_branch" promote \
			--remote origin --inputs inputs --updates updates \
			>codex-race.out 2>codex-race.err &&
		test "$race_new" = "$(git --git-dir=../promotion-race.git \
			rev-parse "$race_ref")" &&
		while IFS="$(printf '\''\t'\'')" read -r ref old new
		do
			test "$ref" = "$race_ref" && continue
			test "$old" = "$(git --git-dir=../promotion-race.git \
				rev-parse "$ref")" || return 1
		done <updates &&
		test "$candidate" = "$(git --git-dir=../promotion-race.git \
			rev-parse refs/heads/codex-staging)" &&
		test_grep -i "atomic\|stale\|failed to update ref" codex-race.err &&
		git --git-dir=../promotion-race.git update-ref \
			"$race_ref" "$race_old" "$race_new" &&
		snapshot_without_staging ../promotion-race.git \
			>primary-after-codex-race &&
		test_cmp primary-before primary-after-codex-race &&

		race_ref=refs/heads/meta &&
		race_old=$(awk -F "$(printf '\''\t'\'')" -v ref="$race_ref" \
			'\''$1 == ref { print $2 }'\'' updates) &&
		race_new=$master &&
		test "$race_old" != "$race_new" &&
		mkdir meta-race-bin &&
		write "#!/bin/sh
case \" \$* \" in
*\" push \"*)
	\"$real_git\" --git-dir=\"$remote_git\" update-ref \\
		\"$race_ref\" \"$race_new\" \"$race_old\" || exit
	;;
esac
exec \"$real_git\" \"\$@\"" meta-race-bin/git &&
		chmod +x meta-race-bin/git &&

		test_expect_code 1 env PATH="$PWD/meta-race-bin:$PATH" \
			sh "$codex_branch" promote \
			--remote origin --inputs inputs --updates updates \
			>meta-race.out 2>meta-race.err &&
		test "$race_new" = "$(git --git-dir=../promotion-race.git \
			rev-parse "$race_ref")" &&
		while IFS="$(printf '\''\t'\'')" read -r ref old new
		do
			test "$ref" = "$race_ref" && continue
			test "$old" = "$(git --git-dir=../promotion-race.git \
				rev-parse "$ref")" || return 1
		done <updates &&
		test "$candidate" = "$(git --git-dir=../promotion-race.git \
			rev-parse refs/heads/codex-staging)" &&
		test_grep -i "atomic\|stale\|failed to update ref" meta-race.err &&
		git --git-dir=../promotion-race.git update-ref \
			"$race_ref" "$race_old" "$race_new" &&
		snapshot_without_staging ../promotion-race.git \
			>primary-after-meta-race &&
		test_cmp primary-before primary-after-meta-race
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
		install_meta_state meta master codex &&
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
		install_meta_state meta master codex &&
		git push origin master meta codex \
			aa/codex/dependent yy/codex/clean zz/codex/root
	) &&

	git clone conflict.git conflict-runner &&
	(
		cd conflict-runner &&
		fetch_all &&
		controller=$(git rev-parse origin/meta) &&
		base=$(git rev-parse origin/master) &&
		codex=$(git rev-parse origin/codex) &&
		dependent=$(git rev-parse origin/aa/codex/dependent) &&
		clean=$(git rev-parse origin/yy/codex/clean) &&
		root=$(git rev-parse origin/zz/codex/root) &&
		snapshot_refs ../conflict.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure \
			>rewrite.out 2>rewrite.err &&
		digest=$(git hash-object inputs) &&
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
		test_grep "Meta/codex continue" failure &&
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
		install_meta_state meta master codex &&

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
		install_meta_state meta master codex &&
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
		install_meta_state meta master codex &&
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

test_expect_success 'a rewritten parent replaces rather than duplicates its old history' '
	git init --bare parent-rewrite.git &&
	test_create_repo parent-rewrite-source &&
	(
		cd parent-rewrite-source &&
		git remote add origin ../parent-rewrite.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&

		git switch -c aa/codex/parent &&
		write old parent-file &&
		git add parent-file &&
		git commit -m "old parent" &&

		git switch -c bb/codex/child &&
		write child child-file &&
		git add child-file &&
		git commit -m "unchanged child" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&

		git switch --detach master &&
		write replacement parent-file &&
		git add parent-file &&
		git commit -m "replacement parent" &&
		git branch -f aa/codex/parent HEAD &&
		git push origin master meta codex \
			aa/codex/parent bb/codex/child
	) &&

	git clone parent-rewrite.git parent-rewrite-runner &&
	(
		cd parent-rewrite-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		new_parent=$(updated_tip aa/codex/parent updates) &&
		new_child=$(updated_tip bb/codex/child updates) &&
		test -n "$new_parent" &&
		test "$new_parent" = "$(git rev-parse "$new_child^")" &&
		test 2 = "$(git rev-list --count origin/master..$new_child)" &&
		test 1 = "$(git log --format=%s origin/master..$new_child |
			grep -c "^replacement parent$")" &&
		git log --format=%s origin/master..$new_child >subjects &&
		! grep -q "^old parent$" subjects
	)
'

test_expect_success 'a disjoint parent rewrite drops stale parent content from its child' '
	git init --bare disjoint-parent.git &&
	test_create_repo disjoint-parent-source &&
	(
		cd disjoint-parent-source &&
		git remote add origin ../disjoint-parent.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&

		git switch -c aa/codex/parent &&
		write old old-parent-file &&
		git add old-parent-file &&
		git commit -m "old disjoint parent" &&
		git switch -c bb/codex/child &&
		write child child-file &&
		git add child-file &&
		git commit -m "disjoint child" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&

		git switch --detach master &&
		write new new-parent-file &&
		git add new-parent-file &&
		git commit -m "new disjoint parent" &&
		git branch -f aa/codex/parent HEAD &&
		git push origin master meta codex \
			aa/codex/parent bb/codex/child
	) &&

	git clone disjoint-parent.git disjoint-parent-runner &&
	(
		cd disjoint-parent-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		candidate=$(cat result) &&
		test new = "$(git show "$candidate:new-parent-file")" &&
		test child = "$(git show "$candidate:child-file")" &&
		test_must_fail git cat-file -e "$candidate:old-parent-file"
	)
'

test_expect_success 'rewinding a parent does not migrate its removed commit into the child' '
	git init --bare parent-rewind.git &&
	test_create_repo parent-rewind-source &&
	(
		cd parent-rewind-source &&
		git remote add origin ../parent-rewind.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&

		git switch -c aa/codex/parent &&
		write kept kept-parent-file &&
		git add kept-parent-file &&
		git commit -m "kept parent commit" &&
		kept=$(git rev-parse HEAD) &&
		write removed removed-parent-file &&
		git add removed-parent-file &&
		git commit -m "removed parent commit" &&
		git switch -c bb/codex/child &&
		write child child-file &&
		git add child-file &&
		git commit -m "child after rewind" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&

		git branch -f aa/codex/parent "$kept" &&
		git push origin master meta codex \
			aa/codex/parent bb/codex/child
	) &&

	git clone parent-rewind.git parent-rewind-runner &&
	(
		cd parent-rewind-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		new_parent=$(updated_tip aa/codex/parent updates) &&
		new_child=$(updated_tip bb/codex/child updates) &&
		test "$new_parent" = "$(git rev-parse "$new_child^")" &&
		test kept = "$(git show "$new_child:kept-parent-file")" &&
		test child = "$(git show "$new_child:child-file")" &&
		test_must_fail git cat-file -e "$new_child:removed-parent-file" &&
		git log --format=%s origin/master..$new_child >subjects &&
		! grep -q "^removed parent commit$" subjects
	)
'

test_expect_success 'a child restacked onto current master is explicitly reparented' '
	git init --bare reparent-master.git &&
	test_create_repo reparent-master-source &&
	(
		cd reparent-master-source &&
		git remote add origin ../reparent-master.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&

		git switch -c aa/codex/parent &&
		write parent parent-file &&
		git add parent-file &&
		git commit -m "reparent parent" &&
		old_parent=$(git rev-parse HEAD) &&
		git switch -c bb/codex/child &&
		write child child-file &&
		git add child-file &&
		git commit -m "reparent child" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&

		git switch master &&
		write current master-file &&
		git add master-file &&
		git commit -m "current master for reparent" &&
		git switch bb/codex/child &&
		git rebase --onto master "$old_parent" &&
		git push origin master meta codex \
			aa/codex/parent bb/codex/child
	) &&

	git clone reparent-master.git reparent-master-runner &&
	(
		cd reparent-master-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		new_parent=$(updated_tip aa/codex/parent updates) &&
		new_child=$(updated_tip bb/codex/child updates) &&
		new_meta=$(updated_tip meta updates) &&
		test "$(git rev-parse origin/master)" = \
			"$(git rev-parse "$new_child^")" &&
		test_must_fail git merge-base --is-ancestor \
			"$new_parent" "$new_child" &&
		git show "$new_meta:codex.config" >next.config &&
		test refs/heads/master = "$(git config -f next.config \
			--get branch.bb/codex/child.merge)"
	)
'

test_expect_success 'removing a parent while its stale child survives is rejected' '
	git init --bare removed-parent.git &&
	test_create_repo removed-parent-source &&
	(
		cd removed-parent-source &&
		git remote add origin ../removed-parent.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git switch -c aa/codex/parent &&
		write parent parent-file &&
		git add parent-file &&
		git commit -m "removed prerequisite" &&
		git switch -c bb/codex/child &&
		write child child-file &&
		git add child-file &&
		git commit -m "stale surviving child" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&
		git push origin master meta codex bb/codex/child
	) &&

	git clone removed-parent.git removed-parent-runner &&
	(
		cd removed-parent-runner &&
		fetch_all &&
		snapshot_refs ../removed-parent.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			>out 2>err &&
		test_grep "published prerequisite.*was retired" err &&
		snapshot_refs ../removed-parent.git >after &&
		test_cmp before after
	)
'

test_expect_success 'an empty dependent follows its rewritten equal-tip parent' '
	git init --bare empty-dependent.git &&
	test_create_repo empty-dependent-source &&
	(
		cd empty-dependent-source &&
		git remote add origin ../empty-dependent.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git switch -c aa/codex/parent &&
		write old parent-file &&
		git add parent-file &&
		git commit -m "equal-tip old parent" &&
		old_parent=$(git rev-parse HEAD) &&
		git branch bb/codex/empty &&
		git branch codex &&
		git branch meta master &&
		printf "aa/codex/parent\t%s\tmaster\n" "$old_parent" \
			>explicit.rows &&
		printf "bb/codex/empty\t%s\taa/codex/parent\n" "$old_parent" \
			>>explicit.rows &&
		install_explicit_meta_state meta master codex explicit.rows &&

		git switch --detach master &&
		write replacement parent-file &&
		git add parent-file &&
		git commit -m "equal-tip replacement parent" &&
		git branch -f aa/codex/parent HEAD &&
		git push origin master meta codex \
			aa/codex/parent bb/codex/empty
	) &&

	git clone empty-dependent.git empty-dependent-runner &&
	(
		cd empty-dependent-runner &&
		fetch_all &&
		old_empty=$(git rev-parse origin/bb/codex/empty) &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		new_parent=$(updated_tip aa/codex/parent updates) &&
		new_empty=$(updated_tip bb/codex/empty updates) &&
		test "$old_empty" != "$new_empty" &&
		test "$new_parent" = "$new_empty" &&
		test replacement = "$(git show "$new_empty:parent-file")"
	)
'

test_expect_success 'an unexplained commit added directly to codex is rejected' '
	git init --bare direct-codex.git &&
	test_create_repo direct-codex-source &&
	(
		cd direct-codex-source &&
		git remote add origin ../direct-codex.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git switch -c aa/codex/topic &&
		write topic topic-file &&
		git add topic-file &&
		git commit -m "represented topic" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&

		git switch codex &&
		write unexplained unexplained-file &&
		git add unexplained-file &&
		git commit -m "unexplained direct codex commit" &&
		git push origin master meta codex aa/codex/topic
	) &&

	git clone direct-codex.git direct-codex-runner &&
	(
		cd direct-codex-runner &&
		fetch_all &&
		snapshot_refs ../direct-codex.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			>out 2>err &&
		test_grep "not represented by an active" err &&
		snapshot_refs ../direct-codex.git >after &&
		test_cmp before after
	)
'

test_expect_success 'a clean topic merge above recorded codex is accepted' '
	git init --bare merged-codex.git &&
	test_create_repo merged-codex-source &&
	(
		cd merged-codex-source &&
		git remote add origin ../merged-codex.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git switch -c aa/codex/topic &&
		write first topic-first &&
		git add topic-first &&
		git commit -m "first represented topic commit" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&

		write second topic-second &&
		git add topic-second &&
		git commit -m "second represented topic commit" &&
		git switch codex &&
		git merge --no-ff aa/codex/topic -m "merge updated topic into codex" &&
		git push origin master meta codex aa/codex/topic
	) &&

	git clone merged-codex.git merged-codex-runner &&
	(
		cd merged-codex-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		candidate=$(cat result) &&
		test "$(git rev-parse "$candidate^{tree}")" = \
			"$(git rev-parse origin/codex^{tree})" &&
		test second = "$(git show "$candidate:topic-second")"
	)
'

test_expect_success 'initialize emits canonical tree-same state and rejects a mismatch' '
	git init --bare initialize.git &&
	test_create_repo initialize-source &&
	(
		cd initialize-source &&
		git remote add origin ../initialize.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		base=$(git rev-parse HEAD) &&
		git switch -c aa/codex/parent &&
		write parent parent-file &&
		git add parent-file &&
		git commit -m "initialize parent" &&
		parent=$(git rev-parse HEAD) &&
		git switch -c bb/codex/child &&
		write child child-file &&
		git add child-file &&
		git commit -m "initialize child" &&
		git branch codex &&
		codex=$(git rev-parse codex) &&
		git branch meta master &&
		git push origin master meta codex \
			aa/codex/parent bb/codex/child &&
		printf "%s\n%s\n%s\n" "$base" "$parent" "$codex" \
			>../initialize-oids &&

		git switch codex &&
		write mismatch unmatched-file &&
		git add unmatched-file &&
		git commit -m "unmatched codex-only content" &&
		git branch mismatch-codex &&
		git push origin mismatch-codex
	) &&

	git clone initialize.git initialize-runner &&
	(
		cd initialize-runner &&
		fetch_all &&
		base=$(sed -n 1p ../initialize-oids) &&
		parent=$(sed -n 2p ../initialize-oids) &&
		codex=$(sed -n 3p ../initialize-oids) &&
		sh "$codex_branch" initialize --remote origin \
			--base master --codex codex --output initialized.config \
			>initialize.out &&
		{
			printf "[codex]\n" &&
			printf "\tversion = 1\n" &&
			printf "\tbase-ref = refs/heads/master\n" &&
			printf "\tbase-tip = %s\n" "$base" &&
			printf "\toutput-ref = refs/heads/codex\n" &&
			printf "\toutput-tip = %s\n" "$codex" &&
			printf "\n[branch \"aa/codex/parent\"]\n" &&
			printf "\tremote = .\n" &&
			printf "\tmerge = refs/heads/master\n" &&
			printf "\tcodex-tip = %s\n" "$parent" &&
			printf "\n[branch \"bb/codex/child\"]\n" &&
			printf "\tremote = .\n" &&
			printf "\tmerge = refs/heads/aa/codex/parent\n" &&
			printf "\tcodex-tip = %s\n" "$codex"
		} >expected.config &&
		test_cmp expected.config initialized.config &&
		test_grep "known-good codex tree" initialize.out &&

		mismatch=$(git -C ../initialize-source rev-parse mismatch-codex) &&
		git --git-dir=../initialize.git update-ref refs/heads/codex \
			"$mismatch" "$codex" &&
		test_expect_code 1 sh "$codex_branch" initialize --remote origin \
			--base master --codex codex --output mismatch.config \
			>mismatch.out 2>mismatch.err &&
		test_grep "do not reconstruct the known-good codex tree" mismatch.err &&
		test_path_is_missing mismatch.config
	)
'

test_expect_success 'a partially advanced root uses its intermediate master boundary' '
	git init --bare partial-master.git &&
	test_create_repo partial-master-source &&
	(
		cd partial-master-source &&
		git remote add origin ../partial-master.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		write published published-base-file &&
		git add published-base-file &&
		git commit -m "published master boundary" &&
		published_base=$(git rev-parse HEAD) &&

		git switch -c aa/codex/root &&
		write topic topic-file &&
		git add topic-file &&
		git commit -m "partially advanced root topic" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&

		git switch master &&
		write intermediate intermediate-master-file &&
		git add intermediate-master-file &&
		git commit -m "intermediate master" &&
		intermediate=$(git rev-parse HEAD) &&
		write current current-master-file &&
		git add current-master-file &&
		git commit -m "current master" &&
		git switch aa/codex/root &&
		git rebase --onto "$intermediate" "$published_base" &&
		test "$intermediate" = "$(git rev-parse HEAD^)" &&
		git push origin master meta codex aa/codex/root
	) &&

	git clone partial-master.git partial-master-runner &&
	(
		cd partial-master-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		new_root=$(updated_tip aa/codex/root updates) &&
		test "$(git rev-parse origin/master)" = \
			"$(git rev-parse "$new_root^")" &&
		test 1 = "$(git rev-list --count origin/master..$new_root)" &&
		test topic = "$(git show "$new_root:topic-file")" &&
		test intermediate = \
			"$(git show "$new_root:intermediate-master-file")" &&
		test current = "$(git show "$new_root:current-master-file")"
	)
'

test_expect_success 'rewriting master does not transfer removed base commits into a root topic' '
	git init --bare rewritten-master.git &&
	test_create_repo rewritten-master-source &&
	(
		cd rewritten-master-source &&
		git remote add origin ../rewritten-master.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		root_base=$(git rev-parse HEAD) &&
		write removed removed-base-file &&
		git add removed-base-file &&
		git commit -m "removed published master commit" &&

		git switch -c aa/codex/root &&
		write topic topic-file &&
		git add topic-file &&
		git commit -m "root after rewritten master" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&

		git switch --detach "$root_base" &&
		write replacement replacement-base-file &&
		git add replacement-base-file &&
		git commit -m "replacement master commit" &&
		git branch -f master HEAD &&
		git push origin master meta codex aa/codex/root
	) &&

	git clone rewritten-master.git rewritten-master-runner &&
	(
		cd rewritten-master-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		new_root=$(updated_tip aa/codex/root updates) &&
		test "$(git rev-parse origin/master)" = \
			"$(git rev-parse "$new_root^")" &&
		test 1 = "$(git rev-list --count origin/master..$new_root)" &&
		test replacement = \
			"$(git show "$new_root:replacement-base-file")" &&
		test topic = "$(git show "$new_root:topic-file")" &&
		test_must_fail git cat-file -e "$new_root:removed-base-file"
	)
'

test_expect_success 'an absorbed parent can retire after its child is restacked on master' '
	git init --bare absorbed-parent.git &&
	test_create_repo absorbed-parent-source &&
	(
		cd absorbed-parent-source &&
		git remote add origin ../absorbed-parent.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&

		git switch -c aa/codex/parent &&
		write parent parent-file &&
		git add parent-file &&
		git commit -m "parent later absorbed by master" &&
		old_parent=$(git rev-parse HEAD) &&
		git switch -c bb/codex/child &&
		write child child-file &&
		git add child-file &&
		git commit -m "child of absorbed parent" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&

		git switch master &&
		git cherry-pick --no-commit "$old_parent" &&
		git commit -m "absorb parent patch into master" &&
		git switch bb/codex/child &&
		git rebase --onto master "$old_parent" &&
		git branch -D aa/codex/parent &&
		git push origin master meta codex bb/codex/child
	) &&

	git clone absorbed-parent.git absorbed-parent-runner &&
	(
		cd absorbed-parent-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		new_child=$(updated_tip bb/codex/child updates) &&
		new_meta=$(updated_tip meta updates) &&
		test "$(git rev-parse origin/master)" = \
			"$(git rev-parse "$new_child^")" &&
		test parent = "$(git show "$new_child:parent-file")" &&
		test child = "$(git show "$new_child:child-file")" &&
		git show "$new_meta:codex.config" >next.config &&
		test refs/heads/master = "$(git config -f next.config \
			--get branch.bb/codex/child.merge)" &&
		test_must_fail git config -f next.config \
			--get branch.aa/codex/parent.codex-tip
	)
'

test_expect_success 'a coherent restack can swap a published dependency' '
	git init --bare dependency-swap.git &&
	test_create_repo dependency-swap-source &&
	(
		cd dependency-swap-source &&
		git remote add origin ../dependency-swap.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&

		git switch -c aa/codex/a &&
		write A a-file &&
		git add a-file &&
		git commit -m "dependency A" &&
		old_a=$(git rev-parse HEAD) &&
		git switch -c bb/codex/b &&
		write B b-file &&
		git add b-file &&
		git commit -m "dependency B" &&
		old_b=$(git rev-parse HEAD) &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&

		git switch --detach master &&
		git cherry-pick "$old_b" &&
		new_b=$(git rev-parse HEAD) &&
		git branch -f bb/codex/b "$new_b" &&
		git cherry-pick "$old_a" &&
		git branch -f aa/codex/a HEAD &&
		git push origin master meta codex aa/codex/a bb/codex/b
	) &&

	git clone dependency-swap.git dependency-swap-runner &&
	(
		cd dependency-swap-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		new_a=$(updated_tip aa/codex/a updates) &&
		new_b=$(updated_tip bb/codex/b updates) &&
		new_meta=$(updated_tip meta updates) &&
		test "$(git rev-parse origin/master)" = \
			"$(git rev-parse "$new_b^")" &&
		test "$new_b" = "$(git rev-parse "$new_a^")" &&
		git show "$new_meta:codex.config" >next.config &&
		test refs/heads/master = "$(git config -f next.config \
			--get branch.bb/codex/b.merge)" &&
		test refs/heads/bb/codex/b = "$(git config -f next.config \
			--get branch.aa/codex/a.merge)"
	)
'

test_expect_success 'Meta/codex pins both controller files to Meta HEAD' '
	test_create_repo wrapper-pin &&
	(
		cd wrapper-pin &&
		write base tracked &&
		git add tracked &&
		git commit -m base &&
		git branch meta
	) &&
	git -C wrapper-pin worktree add ../wrapper-pin-Meta meta &&
	mkdir -p wrapper-pin-Meta/.github/workflows &&
	cp "$codex_entrypoint" wrapper-pin-Meta/codex &&
	cp "$codex_branch" \
		wrapper-pin-Meta/.github/workflows/codex-branch.sh &&
	chmod +x wrapper-pin-Meta/codex \
		wrapper-pin-Meta/.github/workflows/codex-branch.sh &&
	git -C wrapper-pin-Meta add codex .github/workflows/codex-branch.sh &&
	git -C wrapper-pin-Meta commit -m "install pinned controller" &&
	(
		cd wrapper-pin &&
		../wrapper-pin-Meta/codex check-topic aa/codex/topic
	) &&
	write dirty wrapper-pin-Meta/.github/workflows/codex-branch.sh &&
	(
		cd wrapper-pin &&
		test_expect_code 1 ../wrapper-pin-Meta/codex \
			check-topic aa/codex/topic 2>../dirty-helper.err
	) &&
	test_grep ".github/workflows/codex-branch.sh must match Meta/HEAD" \
		dirty-helper.err &&
	git -C wrapper-pin-Meta restore .github/workflows/codex-branch.sh &&
	printf "\n# dirty\n" >>wrapper-pin-Meta/codex &&
	(
		cd wrapper-pin &&
		test_expect_code 1 ../wrapper-pin-Meta/codex \
			check-topic aa/codex/topic 2>../dirty-wrapper.err
	) &&
	test_grep "codex must match Meta/HEAD" dirty-wrapper.err
'

test_expect_success 'rewrite requires codex.config on meta' '
	git init --bare missing-state.git &&
	test_create_repo missing-state-source &&
	(
		cd missing-state-source &&
		git remote add origin ../missing-state.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch meta &&
		git switch -c aa/codex/topic &&
		write topic topic-file &&
		git add topic-file &&
		git commit -m "missing-state topic" &&
		git branch codex &&
		git push origin master meta codex aa/codex/topic
	) &&

	git clone missing-state.git missing-state-runner &&
	(
		cd missing-state-runner &&
		fetch_all &&
		snapshot_refs ../missing-state.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			>out 2>err &&
		test_grep "meta has no codex.config" err &&
		test_path_is_missing result &&
		snapshot_refs ../missing-state.git >after &&
		test_cmp before after
	)
'

test_expect_success 'rewrite rejects malformed and noncanonical codex.config' '
	git init --bare invalid-state.git &&
	test_create_repo invalid-state-source &&
	(
		cd invalid-state-source &&
		git remote add origin ../invalid-state.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git switch -c aa/codex/topic &&
		write topic topic-file &&
		git add topic-file &&
		git commit -m "invalid-state topic" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&
		valid_meta=$(git rev-parse meta) &&

		git switch --detach "$valid_meta" &&
		printf "[codex]\n\tversion = 1\n" >codex.config &&
		git add codex.config &&
		git commit -m "malformed codex state" &&
		malformed=$(git rev-parse HEAD) &&
		git branch malformed-state "$malformed" &&

		git switch --detach "$valid_meta" &&
		git show "$valid_meta:codex.config" >codex.config &&
		printf "\n" >>codex.config &&
		git add codex.config &&
		git commit -m "noncanonical codex state" &&
		git branch noncanonical-state &&
		git branch -f meta "$malformed" &&
		git push origin master meta codex aa/codex/topic \
			malformed-state noncanonical-state
	) &&

	git clone invalid-state.git invalid-state-runner &&
	(
		cd invalid-state-runner &&
		fetch_all &&
		snapshot_refs ../invalid-state.git >before-malformed &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result malformed-result \
			--updates malformed-updates --inputs malformed-inputs \
			--failure malformed-failure >malformed.out 2>malformed.err &&
		test_grep "codex.config is missing.*base-ref" malformed.err &&
		snapshot_refs ../invalid-state.git >after-malformed &&
		test_cmp before-malformed after-malformed &&

		malformed=$(git rev-parse origin/meta) &&
		noncanonical=$(git rev-parse origin/noncanonical-state) &&
		git --git-dir=../invalid-state.git update-ref refs/heads/meta \
			"$noncanonical" "$malformed" &&
		fetch_all &&
		snapshot_refs ../invalid-state.git >before-noncanonical &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result noncanonical-result \
			--updates noncanonical-updates --inputs noncanonical-inputs \
			--failure noncanonical-failure \
			>noncanonical.out 2>noncanonical.err &&
		test_grep "codex.config is not in canonical form" noncanonical.err &&
		snapshot_refs ../invalid-state.git >after-noncanonical &&
		test_cmp before-noncanonical after-noncanonical
	)
'

test_expect_success 'verify-output rejects malformed generated meta commits' '
	git init --bare malformed-meta-output.git &&
	test_create_repo malformed-meta-output-source &&
	(
		cd malformed-meta-output-source &&
		git remote add origin ../malformed-meta-output.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git switch -c aa/codex/topic &&
		write topic topic-file &&
		git add topic-file &&
		git commit -m "meta-output topic" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&
		git switch master &&
		write current master-file &&
		git add master-file &&
		git commit -m "meta-output master" &&
		git push origin master meta codex aa/codex/topic
	) &&

	git clone malformed-meta-output.git malformed-meta-output-runner &&
	(
		cd malformed-meta-output-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		sh "$codex_branch" verify-output \
			--inputs inputs --updates updates --result result &&

		old_meta=$(awk -F "$(printf '\''\t'\'')" \
			'\''$1 == "controller" { print $3 }'\'' inputs) &&
		valid_meta=$(updated_tip meta updates) &&
		config_blob=$(git rev-parse "$valid_meta:codex.config") &&
		GIT_INDEX_FILE=$PWD/bad-mode-index \
			git read-tree "$old_meta^{tree}" &&
		GIT_INDEX_FILE=$PWD/bad-mode-index git update-index \
			--add --cacheinfo 100755,"$config_blob",codex.config &&
		bad_mode_tree=$(GIT_INDEX_FILE=$PWD/bad-mode-index \
			git write-tree) &&
		bad_mode_meta=$(printf "%s\n" "meta: invalid config mode" |
			git commit-tree "$bad_mode_tree" -p "$old_meta") &&
		awk -F "$(printf '\''\t'\'')" -v OFS="$(printf '\''\t'\'')" \
			-v meta="$bad_mode_meta" \
			'\''$1 == "refs/heads/meta" { $3=meta } { print }'\'' \
			updates >bad-mode-updates &&
		test_expect_code 1 sh "$codex_branch" verify-output \
			--inputs inputs --updates bad-mode-updates --result result \
			>bad-mode.out 2>bad-mode.err &&
		test_grep "codex.config as one regular blob" bad-mode.err &&

		extra_blob=$(printf "%s\n" extra | git hash-object -w --stdin) &&
		GIT_INDEX_FILE=$PWD/extra-path-index \
			git read-tree "$valid_meta^{tree}" &&
		GIT_INDEX_FILE=$PWD/extra-path-index git update-index \
			--add --cacheinfo 100644,"$extra_blob",unexpected-meta-path &&
		extra_tree=$(GIT_INDEX_FILE=$PWD/extra-path-index git write-tree) &&
		extra_meta=$(printf "%s\n" "meta: invalid extra path" |
			git commit-tree "$extra_tree" -p "$old_meta") &&
		awk -F "$(printf '\''\t'\'')" -v OFS="$(printf '\''\t'\'')" \
			-v meta="$extra_meta" \
			'\''$1 == "refs/heads/meta" { $3=meta } { print }'\'' \
			updates >extra-path-updates &&
		test_expect_code 1 sh "$codex_branch" verify-output \
			--inputs inputs --updates extra-path-updates --result result \
			>extra-path.out 2>extra-path.err &&
		test_grep "changes more than codex.config" extra-path.err
	)
'

test_done
