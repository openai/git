#!/bin/sh

test_description='rebasing Codex topics and assembling the generated branch'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=master
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

codex_branch=${CODEX_BRANCH:-$TEST_DIRECTORY/../.github/workflows/codex-branch.sh}
codex_workflow=${CODEX_WORKFLOW:-$(dirname "$codex_branch")/codex.yml}
codex_root=$(CDPATH= cd "$(dirname "$codex_branch")/../.." && pwd)
codex_entrypoint=${CODEX_ENTRYPOINT:-$codex_root/codex}
codex_rebuild=${CODEX_REBUILD:-$codex_root/rebuild}
codex_publish=${CODEX_PUBLISH:-$codex_root/publish}
codex_admission_workflow=$codex_root/.github/workflows/codex-admission.yml
codex_bot_name='chatgpt-codex-connector[bot]'
codex_bot_email='199175422+chatgpt-codex-connector[bot]@users.noreply.github.com'

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
	sed '/^refs\/heads\/codex-staging[[:space:]]/d
		/^refs\/heads\/codex-unstable-staging[[:space:]]/d'
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

write_reviewed_automation_workflow () {
	cat >"$1" <<-'EOF'
	name: Refresh codex

	on:
	  workflow_dispatch:
	  pull_request:
	    branches:
	      - codex
	      - codex-unstable
	    types:
	      - opened
	      - reopened
	      - synchronize
	      - ready_for_review
	  merge_group:
	    types:
	      - checks_requested

	permissions:
	  actions: read
	  contents: read
	  pull-requests: read

	jobs:
	  refresh:
	    if: github.event_name == 'workflow_dispatch'
	    uses: openai/git/.github/workflows/codex.yml@meta
	  admission:
	    name: Codex admission
	    if: >-
	      (github.event_name == 'pull_request' &&
	       github.event.pull_request.base.ref == 'codex') ||
	      (github.event_name == 'merge_group' &&
	       github.event.merge_group.base_ref == 'refs/heads/codex')
	    permissions:
	      contents: read
	      pull-requests: read
	    uses: openai/git/.github/workflows/codex-admission.yml@meta
	  unstable_admission:
	    name: Codex unstable admission
	    if: >-
	      (github.event_name == 'pull_request' &&
	       github.event.pull_request.base.ref == 'codex-unstable') ||
	      (github.event_name == 'merge_group' &&
	       github.event.merge_group.base_ref == 'refs/heads/codex-unstable')
	    permissions:
	      contents: read
	      pull-requests: read
	    uses: openai/git/.github/workflows/codex-admission.yml@meta
	EOF
}

write_stable_reviewed_automation_workflow () {
	cat >"$1" <<-'EOF'
	name: Refresh codex

	on:
	  workflow_dispatch:
	  pull_request:
	    branches:
	      - codex
	    types:
	      - opened
	      - reopened
	      - synchronize
	      - ready_for_review
	  merge_group:
	    types:
	      - checks_requested

	permissions:
	  actions: read
	  contents: read
	  pull-requests: read

	jobs:
	  refresh:
	    if: github.event_name == 'workflow_dispatch'
	    uses: openai/git/.github/workflows/codex.yml@meta
	  admission:
	    name: Codex admission
	    if: github.event_name == 'pull_request' || github.event_name == 'merge_group'
	    permissions:
	      contents: read
	      pull-requests: read
	    uses: openai/git/.github/workflows/codex-admission.yml@meta
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

write_guarded_release_workflow () {
	write_release_workflow codex "$1" &&
	cat >>"$1" <<-'EOF'

	jobs:
	  publication:
	    name: Verify controller publication
	    runs-on: ubuntu-24.04
	    outputs:
	      published: ${{ steps.verify.outputs.published }}
	    steps:
	      - id: verify
	        run: echo publication

	  version:
	    needs: publication
	    if: needs.publication.outputs.published == 'true'
	    runs-on: ubuntu-24.04
	    steps:
	      - run: echo version
	EOF
}

install_admission_gh () {
	directory=$1 &&
	mkdir -p "$directory" &&
	cat >"$directory/gh" <<-'EOF' &&
	#!/bin/sh

	set -eu

	test "${1:-}" = api || exit 90
	shift
	endpoint=
	while test $# -gt 0
	do
		case "$1" in
		repos/openai/git/commits/*/pulls*) endpoint=pulls ;;
		repos/openai/git/pulls/*/reviews*) endpoint=reviews ;;
		esac
		shift
	done
	test -n "$endpoint" || exit 91
	test -z "${FAKE_ADMISSION_LOG:-}" ||
		printf '%s\n' "$endpoint" >>"$FAKE_ADMISSION_LOG"
	test "${FAKE_ADMISSION_MODE:-}" != api-failure || exit 92

	if test "$endpoint" = pulls
	then
		test "${FAKE_ADMISSION_MODE:-}" != no-pull-request || exit 0
		number=${FAKE_ADMISSION_NUMBER:-42}
		state=closed
		merged_at=2026-08-04T00:00:00Z
		merge=$FAKE_ADMISSION_MERGE
		base_repository=openai/git
		base=${FAKE_ADMISSION_BASE:-codex}
		head_repository=openai/git
		head_ref=$FAKE_ADMISSION_BRANCH
		head=$FAKE_ADMISSION_HEAD
		draft=false
		author=${FAKE_ADMISSION_AUTHOR:-topic-author}
		case "${FAKE_ADMISSION_MODE:-}" in
		open-pull-request) state=open ;;
		unmerged-pull-request) merged_at=- ;;
		wrong-merge) merge=$FAKE_ADMISSION_OTHER ;;
		wrong-base-repository) base_repository=attacker/git ;;
		wrong-base) base=master ;;
		wrong-head-repository) head_repository=attacker/git ;;
		wrong-head-ref) head_ref=cc/codex/unreviewed ;;
		wrong-head) head=$FAKE_ADMISSION_OTHER ;;
		draft-pull-request) draft=true ;;
		esac
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$number" "$state" "$merged_at" "$merge" \
			"$base_repository" "$base" "$head_repository" \
			"$head_ref" "$head" "$draft" "$author"
		if test "${FAKE_ADMISSION_MODE:-}" = duplicate-pull-request
		then
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
				43 "$state" "$merged_at" "$merge" \
				"$base_repository" "$base" "$head_repository" \
				"$head_ref" "$head" "$draft" "$author"
		fi
		exit 0
	fi

	test "${FAKE_ADMISSION_MODE:-}" != review-api-failure || exit 93
	test "${FAKE_ADMISSION_MODE:-}" != no-review || exit 0
	reviewer=trusted-reviewer
	review_state=APPROVED
	review_commit=$FAKE_ADMISSION_HEAD
	association=MEMBER
	case "${FAKE_ADMISSION_MODE:-}" in
	self-review) reviewer=${FAKE_ADMISSION_AUTHOR:-topic-author} ;;
	outsider-review) association=NONE ;;
	stale-review) review_commit=$FAKE_ADMISSION_OTHER ;;
	rejected-review) review_state=CHANGES_REQUESTED ;;
	esac
	printf '%s\t%s\t%s\t%s\n' \
		"$reviewer" "$review_state" "$review_commit" "$association"
	if test "${FAKE_ADMISSION_MODE:-}" = revoked-review
	then
		printf '%s\t%s\t%s\t%s\n' \
			"$reviewer" CHANGES_REQUESTED "$review_commit" "$association"
	elif test "${FAKE_ADMISSION_MODE:-}" = dismissed-review
	then
		printf '%s\t%s\t%s\t%s\n' \
			"$reviewer" DISMISSED "$review_commit" "$association"
	elif test "${FAKE_ADMISSION_MODE:-}" = commented-review
	then
		printf '%s\t%s\t%s\t%s\n' \
			"$reviewer" COMMENTED "$review_commit" "$association"
	fi
	EOF
	chmod +x "$directory/gh"
}

install_admission_gate_gh () {
	directory=$1 &&
	mkdir -p "$directory" &&
	cat >"$directory/gh" <<-'EOF_ADMISSION_GATE' &&
	#!/bin/sh

	set -eu

	if test "${1:-}" = pr
	then
		if test "${FAKE_GATE_MODE:-}" = unapproved
		then
			printf '%s\n' REVIEW_REQUIRED
		else
			printf '%s\n' APPROVED
		fi
		exit 0
	fi
	test "${1:-}" = api || exit 90
	shift
	endpoint=
	raw=
	while test $# -gt 0
	do
		case "$1" in
		repos/openai/git/*) endpoint=$1 ;;
		*application/vnd.github.raw+json*) raw=t ;;
		esac
		shift
	done
	test -n "$endpoint" || exit 91

	case "$endpoint" in
	repos/openai/git/git/ref/heads/meta)
		printf '%s\n' "$FAKE_GATE_META"
		;;
	repos/openai/git/git/ref/heads/codex)
		printf '%s\n' "$FAKE_GATE_CODEX"
		;;
	repos/openai/git/git/ref/heads/codex-unstable)
		printf '%s\n' "$FAKE_GATE_UNSTABLE"
		;;
	repos/openai/git/git/ref/heads/??/codex/*)
		if test "${FAKE_GATE_MODE:-}" = changed-topic
		then
			printf '%s\n' "$FAKE_GATE_OTHER"
		else
			printf '%s\n' "$FAKE_GATE_TOPIC"
		fi
		;;
	repos/openai/git/contents/codex.config\?ref=*)
		published_stable=$FAKE_GATE_CODEX
		published_unstable=$FAKE_GATE_UNSTABLE
		if test "${FAKE_GATE_MODE:-}" = pending
		then
			if test "${FAKE_GATE_LANE:-codex}" = codex-unstable
			then
				published_unstable=$FAKE_GATE_OTHER
			else
				published_stable=$FAKE_GATE_OTHER
			fi
		fi
		printf '[codex]\n\toutput-tip = %s\n' \
			"$published_stable"
		printf '[codex-unstable]\n\tbase-tip = %s\n\toutput-tip = %s\n' \
			"$published_stable" "$published_unstable"
		if test "${FAKE_GATE_MODE:-}" = hidden-enrolled-unstable
		then
			printf '[branch "cc/codex/private-parent-unstable"]\n'
			printf '\tcodex-tip = %s\n' "$FAKE_GATE_OTHER"
		fi
		;;
	repos/openai/git/git/commits/*)
		first=$FAKE_GATE_CODEX
		test "${FAKE_GATE_LANE:-codex}" != codex-unstable ||
			first=$FAKE_GATE_UNSTABLE
		test "${FAKE_GATE_MODE:-}" != wrong-parent ||
			first=$FAKE_GATE_OTHER
		printf '%s\t%s\t%s\t%s\n' \
			"$FAKE_GATE_CANDIDATE" 2 "$first" "$FAKE_GATE_TOPIC"
		;;
	repos/openai/git/commits/*/pulls*)
		printf '%s\t%s\t%s\n' 42 "$FAKE_GATE_BRANCH" \
			"$FAKE_GATE_TOPIC"
		if test "${FAKE_GATE_MODE:-}" = multiple-pulls
		then
			printf '%s\t%s\t%s\n' 43 "$FAKE_GATE_BRANCH" \
				"$FAKE_GATE_TOPIC"
		fi
		;;
	repos/openai/git/contents/.github/workflows/codex.yml\?ref=*)
		if test -n "$raw"
		then
			cat <<-'EOF_AUTOMATION'
			  pull_request:
			  merge_group:
			    uses: openai/git/.github/workflows/codex.yml@meta
			    uses: openai/git/.github/workflows/codex-admission.yml@meta
			EOF_AUTOMATION
		else
			case "${FAKE_GATE_MODE:-}:$endpoint" in
			changed-workflow:*"$FAKE_GATE_CANDIDATE")
				printf '%s\n' changed-automation
				;;
			*) printf '%s\n' trusted-automation ;;
			esac
		fi
		;;
	repos/openai/git/contents/.github/workflows/codex-release.yml\?ref=*)
		if test -n "$raw"
		then
			cat <<-'EOF_RELEASE'
			  publication:
			    published: ${{ steps.verify.outputs.published }}
			    needs: publication
			    if: needs.publication.outputs.published == 'true'
			    git/ref/heads/meta
			    codex.output-tip
			EOF_RELEASE
		else
			printf '%s\n' trusted-release
		fi
		;;
	repos/openai/git/contents/.github/workflows\?ref=*)
		printf '%s\n' trusted-workflow-directory
		;;
	repos/openai/git/branches\?per_page=100)
		printf '%s\t%s\n' "$FAKE_GATE_BRANCH" "$FAKE_GATE_TOPIC"
		case "${FAKE_GATE_MODE:-}" in
		hidden-prerequisite|newer-master)
			printf '%s\t%s\n' cc/codex/private-parent \
				"$FAKE_GATE_OTHER"
			;;
		hidden-wip|hidden-stale|hidden-unstable)
			suffix=${FAKE_GATE_MODE#hidden-}
			printf '%s\t%s\n' "cc/codex/private-parent-$suffix" \
				"$FAKE_GATE_OTHER"
			;;
		hidden-enrolled-unstable)
			printf '%s\t%s\n' cc/codex/private-parent-unstable \
				"$FAKE_GATE_OTHER"
			;;
		reviewed-shared-helper|reviewed-unstable-helper|\
		linear-shared-helper|ancestor-shared-helper|helper-api-failure)
			case "$FAKE_GATE_LANE:$FAKE_GATE_MODE" in
			codex:reviewed-unstable-helper)
				other_name=cc/codex/private-parent-unstable
				;;
			codex:*)
				other_name=cc/codex/private-parent
				;;
			*)
				other_name=cc/codex/private-parent-unstable
				;;
			esac
			printf '%s\t%s\n' "$other_name" "$FAKE_GATE_OTHER"
			;;
		descendant-checkpoint)
			printf '%s\t%s\n' cc/codex/checkpoint-unstable \
				"$FAKE_GATE_OTHER"
			;;
		same-tip-alias)
			printf '%s\t%s\n' cc/codex/same-tip \
				"$FAKE_GATE_TOPIC"
			;;
		esac
		;;
	repos/openai/git/compare/*)
		case "$endpoint" in
		*"$FAKE_GATE_BASE...$FAKE_GATE_TOPIC?per_page=100")
			case "${FAKE_GATE_MODE:-}" in
			reviewed-shared-helper|reviewed-unstable-helper)
				printf '%s\t%s\t%s\n' "$FAKE_GATE_MERGE" \
					"$FAKE_GATE_FIRST" "$FAKE_GATE_SHARED"
				;;
			helper-api-failure) exit 95 ;;
			*) : ;;
			esac
			;;
		*"$FAKE_GATE_OTHER...$FAKE_GATE_TOPIC")
			if test "${FAKE_GATE_MODE:-}" = descendant-checkpoint
			then
				printf '%s\n' "$FAKE_GATE_TOPIC"
			elif test "${FAKE_GATE_MODE:-}" = ancestor-shared-helper
			then
				printf '%s\n' "$FAKE_GATE_OTHER"
			else
				printf '%s\n' "$FAKE_GATE_SHARED"
			fi
			;;
		*"$FAKE_GATE_FIRST...$FAKE_GATE_SHARED")
			printf '%s\n' diverged
			;;
		*"$FAKE_GATE_SHARED...$FAKE_GATE_SHARED")
			printf '%s\n' identical
			;;
		*"master...$FAKE_GATE_OTHER")
			printf '%s\n' ahead
			;;
		*"...$FAKE_GATE_OTHER")
			printf '%s\n' ahead
			;;
		*"master...$FAKE_GATE_SHARED")
			if test "${FAKE_GATE_MODE:-}" = newer-master
			then
				printf '%s\n' behind
			else
				printf '%s\n' ahead
			fi
			;;
		*"...$FAKE_GATE_SHARED")
			printf '%s\n' ahead
			;;
		*) exit 92 ;;
		esac
		;;
	*)
		printf 'unexpected admission endpoint: %s\n' "$endpoint" >&2
		exit 93
		;;
	esac
	EOF_ADMISSION_GATE
	chmod +x "$directory/gh"
}

run_admission_gate () {
	mode=$1 &&
	event=$2 &&
	branch=${3:-bb/codex/reviewed} &&
	lane=${4:-codex} &&
	directory=$TRASH_DIRECTORY/admission-gate-bin &&
	meta=1111111111111111111111111111111111111111 &&
	codex=2222222222222222222222222222222222222222 &&
	unstable=7777777777777777777777777777777777777777 &&
	topic=3333333333333333333333333333333333333333 &&
	candidate=4444444444444444444444444444444444444444 &&
	other=5555555555555555555555555555555555555555 &&
	shared=6666666666666666666666666666666666666666 &&
	first=8888888888888888888888888888888888888888 &&
	merge=9999999999999999999999999999999999999999 &&
	if test "$lane" = codex-unstable
	then
		base=$unstable
	else
		base=$codex
	fi &&
	env PATH="$directory:$PATH" GH_TOKEN=not-a-real-token \
		GITHUB_REPOSITORY=openai/git GITHUB_EVENT_NAME="$event" \
		GITHUB_SHA="$candidate" WORKFLOW_REPOSITORY=openai/git \
		WORKFLOW_SHA="$meta" EVENT_ACTION=checks_requested \
		GROUP_BASE_REF="refs/heads/$lane" GROUP_BASE_SHA="$base" \
		GROUP_HEAD_REF="refs/heads/gh-readonly-queue/$lane/pr-42" \
		GROUP_HEAD_SHA="$candidate" PULL_NUMBER=42 \
		PULL_BASE_REF="$lane" PULL_BASE_SHA="$base" \
		PULL_HEAD_REF="$branch" PULL_HEAD_SHA="$topic" \
		PULL_HEAD_REPOSITORY=openai/git PULL_DRAFT=false \
		FAKE_GATE_MODE="$mode" FAKE_GATE_META="$meta" \
		FAKE_GATE_LANE="$lane" FAKE_GATE_CODEX="$codex" \
		FAKE_GATE_UNSTABLE="$unstable" FAKE_GATE_TOPIC="$topic" \
		FAKE_GATE_BASE="$base" \
		FAKE_GATE_CANDIDATE="$candidate" FAKE_GATE_OTHER="$other" \
		FAKE_GATE_SHARED="$shared" FAKE_GATE_FIRST="$first" \
		FAKE_GATE_MERGE="$merge" FAKE_GATE_BRANCH="$branch" \
		bash "$TRASH_DIRECTORY/admission-gate.sh"
}

setup_pending_admission () (
	fixture=$1
	topic=${2:-bb/codex/reviewed}
	style=${3:-merge}

	git init --bare "$fixture.git" &&
	test_create_repo "$fixture-source" &&
	(
		cd "$fixture-source" &&
		git remote add origin "../$fixture.git" &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m "admission base" &&
		git switch -c aa/codex/enrolled master &&
		write enrolled enrolled-file &&
		git add enrolled-file &&
		git commit -m "already enrolled topic" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&
		if git show-ref --verify --quiet "refs/heads/$topic"
		then
			git switch "$topic"
		else
			git switch -c "$topic" master
		fi &&
		write reviewed reviewed-file &&
		git add reviewed-file &&
		git commit -m "reviewed topic" &&
		git switch codex &&
		case "$style" in
		merge)
			git merge --no-ff "$topic" \
				-m "Merge pull request #42 from openai/$topic"
			;;
		squash)
			git merge --squash "$topic" &&
			git commit -m "squash an unadmitted topic"
			;;
		*) return 1 ;;
		esac &&
		if test "$topic" = aa/codex/enrolled
		then
			git push origin master meta codex "$topic"
		else
			git push origin master meta codex aa/codex/enrolled "$topic"
		fi
	) &&
	git clone "$fixture.git" "$fixture-runner" &&
	install_admission_gh "$TRASH_DIRECTORY/$fixture-bin"
)

admission_command () {
	fixture=$1 &&
	mode=${2:-success} &&
	shift 2 &&
	base=${ADMISSION_BASE:-codex} &&
	branch=${ADMISSION_TOPIC:-bb/codex/reviewed} &&
	merge=$(git rev-parse "refs/remotes/origin/$base") &&
	head=$(git rev-parse "refs/remotes/origin/$branch") &&
	other=$(git rev-parse refs/remotes/origin/master) &&
	env PATH="$TRASH_DIRECTORY/$fixture-bin:$PATH" \
		FAKE_ADMISSION_BASE="$base" \
		FAKE_ADMISSION_MERGE="$merge" \
		FAKE_ADMISSION_HEAD="$head" \
		FAKE_ADMISSION_OTHER="$other" \
		FAKE_ADMISSION_BRANCH="$branch" \
		FAKE_ADMISSION_MODE="$mode" \
		FAKE_ADMISSION_LOG="$TRASH_DIRECTORY/$fixture-gh.log" \
		sh "$codex_branch" "$@"
}

admission_rewrite () {
	fixture=$1 &&
	mode=${2:-success} &&
	shift 2 &&
	admission_command "$fixture" "$mode" \
		rewrite --remote origin \
			--base master --codex codex \
			--result result --updates updates --inputs inputs \
			--failure failure "$@"
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
		*-wip|*-stale|*-unstable|??/codex/*/*) continue ;;
		esac
		if git merge-base --is-ancestor "$oid" "$output_tip"
		then
			printf "%s\t%s\n" "$name" "$oid"
		else
			# Older graph fixtures start with a topic that has already been
			# enrolled but has grown since its last publication. Record its
			# published boundary, not its as-yet-unmerged current tip.
			published=$(git merge-base "$oid" "$output_tip") || exit 1
			printf "%s\t%s\n" "$name" "$published"
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
			test "$oid" = "$other_oid" && continue
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

install_unstable_meta_state () (
	meta_branch=$1
	base_branch=$2
	stable_branch=$3
	unstable_branch=$4
	install_meta_state "$meta_branch" "$base_branch" "$stable_branch" &&
	meta_parent=$(git rev-parse "$meta_branch") &&
	stable_tip=$(git rev-parse "$stable_branch") &&
	unstable_tip=$(git rev-parse "$unstable_branch") &&
	state_topics=.codex-unstable-state-topics &&
	state_config=.codex-unstable-state-config &&
	state_index=.codex-unstable-state-index &&
	git show "$meta_parent:codex.config" |
	awk -v stable="$stable_tip" -v unstable="$unstable_tip" '
		/^\tversion = 1$/ {
			$0 = "\tversion = 2"
		}
		/^\toutput-tip = / && !added {
			print
			print ""
			print "[codex-unstable]"
			print "\tbase-ref = refs/heads/codex"
			print "\tbase-tip = " stable
			print "\toutput-ref = refs/heads/codex-unstable"
			print "\toutput-tip = " unstable
			added = 1
			next
		}
		{ print }
	' >"$state_config" &&
	git for-each-ref --format="%(refname:short)%09%(objectname)" \
		refs/heads |
	while IFS="$(printf '\t')" read -r name oid
	do
		case "$name" in
		??/codex/?*-unstable) ;;
		*) continue ;;
		esac
		case "$name" in
		??/codex/*/*) continue ;;
		esac
		if git merge-base --is-ancestor "$oid" "$unstable_tip"
		then
			printf "%s\t%s\n" "$name" "$oid"
		fi
	done | LC_ALL=C sort >"$state_topics" &&
	while IFS="$(printf '\t')" read -r name oid
	do
		prerequisite=$stable_branch &&
		prerequisite_tip=$stable_tip &&
		while IFS="$(printf '\t')" read -r other_name other_oid
		do
			test "$name" = "$other_name" && continue
			test "$oid" = "$other_oid" && continue
			if git merge-base --is-ancestor "$other_oid" "$oid" &&
				git merge-base --is-ancestor \
					"$prerequisite_tip" "$other_oid"
			then
				prerequisite=$other_name &&
				prerequisite_tip=$other_oid
			fi
		done <"$state_topics" &&
		{
			printf "\n[branch \"%s\"]\n" "$name" &&
			printf "\tremote = .\n" &&
			printf "\tmerge = refs/heads/%s\n" "$prerequisite" &&
			printf "\tcodex-tip = %s\n" "$oid"
		} >>"$state_config"
	done <"$state_topics" &&
	blob=$(git hash-object -w "$state_config") &&
	helper_blob=$(git hash-object -w "$codex_branch") &&
	rm -f "$state_index" &&
	GIT_INDEX_FILE=$state_index git read-tree "$meta_parent^{tree}" &&
	GIT_INDEX_FILE=$state_index git update-index --add --cacheinfo \
		100644,"$blob",codex.config &&
	GIT_INDEX_FILE=$state_index git update-index --add --cacheinfo \
		100755,"$helper_blob",.github/workflows/codex-branch.sh &&
	tree=$(GIT_INDEX_FILE=$state_index git write-tree) &&
	meta_tip=$(printf "%s\n" "meta: initialize unstable Codex topic state" |
		git commit-tree "$tree" -p "$meta_parent") &&
	git update-ref "refs/heads/$meta_branch" "$meta_tip" "$meta_parent" &&
	rm -f "$state_topics" "$state_config" "$state_index"
)

create_unstable_sentinel () (
	base=$(git rev-parse "$1") &&
	tree=$(git rev-parse "$base^{tree}") &&
	sentinel=$(printf '%s\n' 'Initialize codex-unstable' |
		GIT_AUTHOR_NAME=$codex_bot_name \
		GIT_AUTHOR_EMAIL=$codex_bot_email \
		GIT_COMMITTER_NAME=$codex_bot_name \
		GIT_COMMITTER_EMAIL=$codex_bot_email \
		git -c commit.gpgSign=false commit-tree "$tree" -p "$base") &&
	git branch codex-unstable "$sentinel"
)

setup_pending_unstable () (
	fixture=$1
	topic=${2:-bb/codex/reviewed-unstable}
	style=${3:-merge}

	git init --bare "$fixture.git" &&
	test_create_repo "$fixture-source" &&
	(
		cd "$fixture-source" &&
		git remote add origin "../$fixture.git" &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m "unstable admission base" &&
		git switch -c aa/codex/enrolled master &&
		write enrolled enrolled-file &&
		git add enrolled-file &&
		git commit -m "already enrolled production topic" &&
		git branch codex &&
		create_unstable_sentinel codex &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		if test "$style" = sentinel
		then
			git push origin master meta codex codex-unstable \
				aa/codex/enrolled
		else
			git switch -c "$topic" codex &&
			write reviewed reviewed-unstable-file &&
			git add reviewed-unstable-file &&
			git commit -m "reviewed unstable topic" &&
			git switch codex-unstable &&
			case "$style" in
			merge)
				git merge --no-ff "$topic" \
					-m "Merge pull request #42 from openai/$topic"
				;;
			squash)
				git merge --squash "$topic" &&
				git commit -m "squash an unadmitted unstable topic"
				;;
			*) return 1 ;;
			esac &&
			git push origin master meta codex codex-unstable \
				aa/codex/enrolled "$topic"
		fi
	) &&
	git clone "$fixture.git" "$fixture-runner" &&
	install_admission_gh "$TRASH_DIRECTORY/$fixture-bin"
)

unstable_admission_rewrite () {
	fixture=$1 &&
	mode=${2:-success} &&
	shift 2 &&
	ADMISSION_BASE=codex-unstable \
	ADMISSION_TOPIC=${ADMISSION_TOPIC:-bb/codex/reviewed-unstable} \
		admission_rewrite "$fixture" "$mode" "$@"
}

apply_test_updates () (
	remote=$1
	updates=$2
	set -- git push --atomic --force "$remote"
	while IFS="$(printf '\t')" read -r ref old new
	do
		case "$new" in
		0000000000000000000000000000000000000000|\
		0000000000000000000000000000000000000000000000000000000000000000)
			set -- "$@" ":$ref"
			;;
		*)
			set -- "$@" "$new:$ref"
			;;
		esac || return 1
	done <"$updates"
	"$@"
)

updated_tip () {
	awk -F "$(printf '\t')" -v ref="refs/heads/$1" \
		'$1 == ref { print $3 }' "$2"
}

has_codex_bot_committer () (
	commit=$1
	test "$(git show -s --format=%cn "$commit")" = "$codex_bot_name" &&
	test "$(git show -s --format=%ce "$commit")" = "$codex_bot_email"
)

has_codex_bot_author () (
	commit=$1
	test "$(git show -s --format=%an "$commit")" = "$codex_bot_name" &&
	test "$(git show -s --format=%ae "$commit")" = "$codex_bot_email"
)

has_same_author () (
	old=$1
	new=$2
	test "$(git show -s --format="%an <%ae>" "$old")" = \
		"$(git show -s --format="%an <%ae>" "$new")"
)

make_test_integration () (
	name=$1
	oid=$2
	first_parent=$3
	tree=$4
	message=$(printf 'Merge %s into codex\n\nIntegrate the current %s topic into the internally distributed codex branch.\n\nCodex-Integration: %s@%s' \
		"$name" "$name" "$name" "$oid") &&
	printf '%s\n' "$message" |
	GIT_AUTHOR_NAME=$codex_bot_name GIT_AUTHOR_EMAIL=$codex_bot_email \
	GIT_COMMITTER_NAME=$codex_bot_name \
	GIT_COMMITTER_EMAIL=$codex_bot_email \
	git -c commit.gpgSign=false commit-tree "$tree" \
		-p "$first_parent" -p "$oid"
)

make_test_unstable_integration () (
	name=$1
	oid=$2
	first_parent=$3
	tree=$4
	message=$(printf 'Merge %s into codex-unstable\n\nIntegrate the current %s topic into the internally distributed codex-unstable branch.\n\nCodex-Integration: %s@%s' \
		"$name" "$name" "$name" "$oid") &&
	printf '%s\n' "$message" |
	GIT_AUTHOR_NAME=$codex_bot_name GIT_AUTHOR_EMAIL=$codex_bot_email \
	GIT_COMMITTER_NAME=$codex_bot_name \
	GIT_COMMITTER_EMAIL=$codex_bot_email \
	git -c commit.gpgSign=false commit-tree "$tree" \
		-p "$first_parent" -p "$oid"
)

write_test_output_tuple () (
	valid_meta=$1
	old_meta=$2
	valid_candidate=$3
	candidate=$4
	valid_updates=$5
	prefix=$6

	git show "$valid_meta:codex.config" |
		sed "s/output-tip = $valid_candidate/output-tip = $candidate/" \
			>"$prefix.config" &&
	test_grep "output-tip = $candidate" "$prefix.config" &&
	blob=$(git hash-object -w "$prefix.config") &&
	index=$PWD/$prefix.index &&
	rm -f "$index" &&
	GIT_INDEX_FILE=$index git read-tree "$old_meta^{tree}" &&
	GIT_INDEX_FILE=$index git update-index --add --cacheinfo \
		100644,"$blob",codex.config &&
	tree=$(GIT_INDEX_FILE=$index git write-tree) &&
	meta=$(printf '%s\n' "meta: test alternate integration history" |
		GIT_AUTHOR_NAME=$codex_bot_name \
		GIT_AUTHOR_EMAIL=$codex_bot_email \
		GIT_COMMITTER_NAME=$codex_bot_name \
		GIT_COMMITTER_EMAIL=$codex_bot_email \
		git -c commit.gpgSign=false commit-tree "$tree" -p "$old_meta") &&
	awk -F "$(printf '\t')" -v OFS="$(printf '\t')" \
		-v meta="$meta" -v candidate="$candidate" '
		$1 == "refs/heads/meta" { $3=meta }
		$1 == "refs/heads/codex" { $3=candidate }
		{ print }
	' "$valid_updates" >"$prefix.updates" &&
	printf '%s\n' "$candidate" >"$prefix.result"
)

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

test_expect_success 'generated commits use the Codex connector identity' '
	! grep -F "github-actions[bot]" "$codex_branch" &&
	! grep -F "github-actions[bot]" "$codex_workflow" &&
	grep -F "$codex_bot_name" "$codex_branch" &&
	grep -F "$codex_bot_email" "$codex_branch"
'

test_expect_success 'convenience wrappers forward to the pinned controller' '
	test -x "$codex_rebuild" &&
	test -x "$codex_publish" &&
	mkdir -p "wrapper forwarding/Meta" &&
	cp "$codex_rebuild" "wrapper forwarding/Meta/rebuild" &&
	cp "$codex_publish" "wrapper forwarding/Meta/publish" &&
	cat >"wrapper forwarding/Meta/codex" <<-\EOF &&
	#!/bin/sh
	printf "%s\\n" "$*" >>"$WRAPPER_LOG"
	exit "${WRAPPER_EXIT:-0}"
	EOF
	chmod +x "wrapper forwarding/Meta/codex" &&
	WRAPPER_LOG="$TRASH_DIRECTORY/wrapper.log" \
		"$TRASH_DIRECTORY/wrapper forwarding/Meta/rebuild" &&
	WRAPPER_LOG="$TRASH_DIRECTORY/wrapper.log" \
		"$TRASH_DIRECTORY/wrapper forwarding/Meta/rebuild" --local &&
	WRAPPER_LOG="$TRASH_DIRECTORY/wrapper.log" \
		"$TRASH_DIRECTORY/wrapper forwarding/Meta/publish" 4242 &&
	printf "%s\n" rebuild "rebuild --local" "publish 4242" \
		>wrapper.expect &&
	test_cmp wrapper.expect wrapper.log &&
	WRAPPER_LOG="$TRASH_DIRECTORY/wrapper.log" WRAPPER_EXIT=17 \
		test_expect_code 17 \
		"$TRASH_DIRECTORY/wrapper forwarding/Meta/publish" 9999
'

test_expect_success 'refresh only prepares an immutable local-publish artifact' '
	! grep -F "codex-topic.yml" "$codex_workflow" &&
	! grep -E "make -C|t9905-codex-branch.sh" "$codex_workflow" &&
	! grep -F "parallel worker" "$codex_branch" &&
	test_grep "clone --shared --no-checkout" "$codex_branch" &&
	! grep -E "CODEX_BRANCH_TOKEN|CODEX_BRANCH_MANAGER_TOKEN|CODEX_DEPLOY_KEY|secret-broker|id-token" \
		"$codex_workflow" &&
	! grep -F "environment: codex-publish" "$codex_workflow" &&
	! grep -E "^[[:space:]]+git .*push" "$codex_workflow" &&
	! grep -E "codex.* (stage|promote)([[:space:]]|$)" "$codex_workflow" &&
	! grep -F "Wait for CI on the exact staging SHA" "$codex_workflow" &&
	! grep -E "^  publish:" "$codex_workflow" &&
	test_grep "actions/upload-artifact" "$codex_workflow" &&
	test_grep "runner.temp }}/codex-run" "$codex_workflow" &&
	test_grep "GITHUB_RUN_ATTEMPT" "$codex_workflow" &&
	test_grep "Meta/publish" "$codex_workflow" &&
	sed -n "/^          path: |$/,/^          if-no-files-found:/p" \
		"$codex_workflow" |
	sed -n "s,.*runner.temp }}/\\(codex[^ ]*\\)$,\\1,p" |
	LC_ALL=C sort >artifact-files.actual &&
	printf "%s\n" codex.bundle codex-candidate codex-inputs codex-run \
		codex-updates | LC_ALL=C sort >artifact-files.expect &&
	test_cmp artifact-files.expect artifact-files.actual &&
	for ruleset in codex-branch codex-meta
	do
		rules="$codex_root/.github/rulesets/$ruleset.json" &&
		test 1 = "$(grep -c "301000140" "$rules")" &&
		test_grep "\"actor_type\": \"User\"" "$rules" &&
		! grep -F "DeployKey" "$rules" || return 1
	done
'

test_expect_success 'reviewed admission requires one app-authenticated queue entry' '
	test -f "$codex_admission_workflow" &&
	test_grep "name: Verify reviewed topic" \
		"$codex_admission_workflow" &&
	test_grep "pull_request)" "$codex_admission_workflow" &&
	test_grep "merge_group)" "$codex_admission_workflow" &&
	test_grep "codex.output-tip" "$codex_admission_workflow" &&
	test_grep "refs/heads/gh-readonly-queue/" \
		"$codex_admission_workflow" &&
	test_grep "pull-requests: read" "$codex_admission_workflow" &&
	! grep -E "contents: write|pull-requests: write|statuses: write|id-token|actions/checkout|git push" \
		"$codex_admission_workflow" &&
	test_grep "  pull_request:" "$codex_branch" &&
	test_grep "  merge_group:" "$codex_branch" &&
	test_grep "codex-admission.yml@meta" "$codex_branch" &&
	jq -e "
		(.rules[] | select(.type == \"merge_queue\") |
		 .parameters.merge_method == \"MERGE\" and
		 .parameters.grouping_strategy == \"ALLGREEN\" and
		 .parameters.max_entries_to_build == 1 and
		 .parameters.max_entries_to_merge == 1 and
		 .parameters.min_entries_to_merge == 1) and
		(.rules[] | select(.type == \"required_status_checks\") |
		 .parameters.strict_required_status_checks_policy == false and
		 .parameters.required_status_checks == [{
		   \"context\": \"Codex admission / Verify reviewed topic\",
		   \"integration_id\": 15368
		 }])
	" "$codex_root/.github/rulesets/codex-branch.json" &&
	if test -n "${CODEX_AUTOMATION_TOPIC:-}"
	then
		test_grep "  pull_request:" "$CODEX_AUTOMATION_TOPIC" &&
		test_grep "  merge_group:" "$CODEX_AUTOMATION_TOPIC" &&
		test_grep "codex-admission.yml@meta" "$CODEX_AUTOMATION_TOPIC"
	fi &&
	if test -n "${CODEX_RELEASE_TOPIC:-}"
	then
		test_grep "  publication:" "$CODEX_RELEASE_TOPIC" &&
		test_grep "    needs: publication" "$CODEX_RELEASE_TOPIC" &&
		test_grep "codex.output-tip" "$CODEX_RELEASE_TOPIC" &&
		! grep -F "git/ref/heads/codex" "$CODEX_RELEASE_TOPIC" &&
		test_grep "git/ref/heads/meta" "$CODEX_RELEASE_TOPIC"
	fi
'

test_expect_success 'admission workflow executes both pull-request and queue checks' '
	install_admission_gate_gh "$TRASH_DIRECTORY/admission-gate-bin" &&
	sed -n "/^        run: |\$/,/^        [^ ]/p" \
		"$codex_admission_workflow" |
	sed "1d; s/^          //" >"$TRASH_DIRECTORY/admission-gate.sh" &&
	test_grep "set -euo pipefail" "$TRASH_DIRECTORY/admission-gate.sh" &&
	bash -n "$TRASH_DIRECTORY/admission-gate.sh" &&
	run_admission_gate success pull_request >pull.out &&
	test_grep "Approved pull request #42" pull.out &&
	run_admission_gate pending pull_request >pending-pull.out &&
	test_grep "Approved pull request #42" pending-pull.out &&
	run_admission_gate success merge_group >queue.out &&
	test_grep "Approved pull request #42" queue.out &&
	run_admission_gate same-tip-alias merge_group >alias.out &&
	test_grep "Approved pull request #42" alias.out &&
	run_admission_gate newer-master merge_group >newer-master.out &&
	test_grep "Approved pull request #42" newer-master.out &&
	for mode in pending wrong-parent unapproved multiple-pulls \
		changed-topic changed-workflow hidden-prerequisite \
		hidden-wip hidden-stale hidden-unstable hidden-enrolled-unstable
	do
		test_expect_code 1 run_admission_gate "$mode" merge_group \
			>"queue-$mode.out" 2>"queue-$mode.err" || return 1
	done &&
	test_grep "pending topic" queue-pending.err &&
	test_grep "unenrolled history" queue-hidden-prerequisite.err &&
	test_expect_code 1 \
		run_admission_gate success pull_request \
			bb/codex/reviewed-unstable \
		>unstable-pull.out 2>unstable-pull.err &&
	test_grep "not eligible for production codex" unstable-pull.err
'

test_expect_success 'an unmerged topic is invisible to an enrolled rebuild' '
	setup_pending_admission ignored-topic &&
	previous=$(git --git-dir=ignored-topic.git \
		rev-parse refs/heads/aa/codex/enrolled) &&
	git --git-dir=ignored-topic.git update-ref \
		refs/heads/codex "$previous" &&
	(
		cd ignored-topic-runner &&
		fetch_all &&
		: >"$TRASH_DIRECTORY/ignored-topic-gh.log" &&
		snapshot_refs ../ignored-topic.git >before &&
		admission_rewrite ignored-topic api-failure &&
		candidate=$(cat result) &&
		git show origin/meta:codex.config >published.config &&
		test "$previous" = "$(git config --file published.config \
			codex.output-tip)" &&
		test "$(git rev-parse "$previous^{tree}")" = \
			"$(git rev-parse "$candidate^{tree}")" &&
		test enrolled = "$(git show "$candidate:enrolled-file")" &&
		test_must_fail git cat-file -e "$candidate:reviewed-file" &&
		! grep -F "bb/codex/reviewed" inputs &&
		! grep -F "bb/codex/reviewed" updates &&
		test_must_be_empty "$TRASH_DIRECTORY/ignored-topic-gh.log" &&
		snapshot_refs ../ignored-topic.git >after &&
		test_cmp before after
	)
'

test_expect_success 'an already-enrolled topic continues to track new commits' '
	setup_pending_admission enrolled-update &&
	previous=$(git --git-dir=enrolled-update.git \
		rev-parse refs/heads/aa/codex/enrolled) &&
	git --git-dir=enrolled-update.git update-ref \
		refs/heads/codex "$previous" &&
	(
		cd enrolled-update-source &&
		git switch aa/codex/enrolled &&
		write grown existing-topic-update &&
		git add existing-topic-update &&
		git commit -m "grow an enrolled topic" &&
		git push origin aa/codex/enrolled
	) &&
	(
		cd enrolled-update-runner &&
		fetch_all &&
		: >"$TRASH_DIRECTORY/enrolled-update-gh.log" &&
		admission_rewrite enrolled-update api-failure &&
		candidate=$(cat result) &&
		test grown = "$(git show "$candidate:existing-topic-update")" &&
		test_grep "refs/heads/aa/codex/enrolled" updates &&
		! grep -F "bb/codex/reviewed" updates &&
		test_must_be_empty "$TRASH_DIRECTORY/enrolled-update-gh.log"
	)
'

test_expect_success 'an enrolled topic cannot smuggle an unadmitted prerequisite' '
	setup_pending_admission hidden-prerequisite &&
	previous=$(git --git-dir=hidden-prerequisite.git \
		rev-parse refs/heads/aa/codex/enrolled) &&
	git --git-dir=hidden-prerequisite.git update-ref \
		refs/heads/codex "$previous" &&
	(
		cd hidden-prerequisite-source &&
		git switch -c cc/codex/private-parent master &&
		write secret private-parent-file &&
		git add private-parent-file &&
		git commit -m "unadmitted prerequisite" &&
		git rebase --onto cc/codex/private-parent master \
			aa/codex/enrolled &&
		git switch cc/codex/private-parent &&
		write advanced private-parent-tip &&
		git add private-parent-tip &&
		git commit -m "advance beyond the hidden prerequisite" &&
		git push origin cc/codex/private-parent &&
		git push --force origin aa/codex/enrolled
	) &&
	(
		cd hidden-prerequisite-runner &&
		fetch_all &&
		test_expect_code 1 \
			admission_rewrite hidden-prerequisite api-failure \
			>rewrite.out 2>rewrite.err &&
		test_grep "unadmitted Codex topic" rewrite.err
	)
'

test_expect_success 'inactive topic names cannot hide unreviewed shared history' '
	for suffix in wip stale unstable
	do
		fixture="hidden-$suffix" &&
		setup_pending_admission "$fixture" &&
		previous=$(git --git-dir="$fixture.git" \
			rev-parse refs/heads/aa/codex/enrolled) &&
		git --git-dir="$fixture.git" update-ref \
			refs/heads/codex "$previous" &&
		(
			cd "$fixture-source" &&
			private="cc/codex/private-parent-$suffix" &&
			git switch -c "$private" master &&
			write hidden "hidden-$suffix" &&
			git add "hidden-$suffix" &&
			git commit -m "inactive private ancestor" &&
			git rebase --onto "$private" master aa/codex/enrolled &&
			git switch "$private" &&
			write advanced "advanced-$suffix" &&
			git add "advanced-$suffix" &&
			git commit -m "advance inactive private topic" &&
			git push origin "$private" &&
			git push --force origin aa/codex/enrolled
		) &&
		(
			cd "$fixture-runner" &&
			fetch_all &&
			test_expect_code 1 \
				admission_rewrite "$fixture" api-failure \
				>rewrite.out 2>rewrite.err &&
			test_grep "unadmitted Codex topic" rewrite.err
		) || return 1
	done
'

test_expect_success 'an exact topic alias is not mistaken for a prerequisite' '
	setup_pending_admission same-topic-alias &&
	enrolled=$(git --git-dir=same-topic-alias.git \
		rev-parse refs/heads/aa/codex/enrolled) &&
	git --git-dir=same-topic-alias.git update-ref \
		refs/heads/codex "$enrolled" &&
	git --git-dir=same-topic-alias.git update-ref \
		refs/heads/cc/codex/alias "$enrolled" &&
	(
		cd same-topic-alias-runner &&
		fetch_all &&
		admission_rewrite same-topic-alias api-failure &&
		! grep -F "cc/codex/alias" updates &&
		test enrolled = "$(git show "$(cat result):enrolled-file")"
	)
'

test_expect_success 'shared current-master ancestry does not imply admission' '
	setup_pending_admission newer-master-ancestry &&
	enrolled=$(git --git-dir=newer-master-ancestry.git \
		rev-parse refs/heads/aa/codex/enrolled) &&
	git --git-dir=newer-master-ancestry.git update-ref \
		refs/heads/codex "$enrolled" &&
	(
		cd newer-master-ancestry-source &&
		old_master=$(git rev-parse master) &&
		git switch master &&
		write upstream upstream-file &&
		git add upstream-file &&
		git commit -m "advance upstream master" &&
		git switch -c cc/codex/unrelated master &&
		write private unrelated-file &&
		git add unrelated-file &&
		git commit -m "unadmitted independent topic" &&
		git rebase --onto master "$old_master" aa/codex/enrolled &&
		git push origin master cc/codex/unrelated &&
		git push --force origin aa/codex/enrolled
	) &&
	(
		cd newer-master-ancestry-runner &&
		fetch_all &&
		admission_rewrite newer-master-ancestry api-failure &&
		candidate=$(cat result) &&
		test upstream = "$(git show "$candidate:upstream-file")" &&
		test enrolled = "$(git show "$candidate:enrolled-file")" &&
		test_must_fail git cat-file -e "$candidate:unrelated-file" &&
		! grep -F "cc/codex/unrelated" updates
	)
'

test_expect_success 'an unstable-looking branch cannot enter the stable lane' '
	setup_pending_admission ignored-unstable &&
	previous=$(git --git-dir=ignored-unstable.git \
		rev-parse refs/heads/aa/codex/enrolled) &&
	git --git-dir=ignored-unstable.git update-ref \
		refs/heads/codex "$previous" &&
	(
		cd ignored-unstable-source &&
		git switch -c cc/codex/preview-unstable master &&
		write preview unstable-file &&
		git add unstable-file &&
		git commit -m "unadmitted unstable preview" &&
		git push origin cc/codex/preview-unstable
	) &&
	(
		cd ignored-unstable-runner &&
		fetch_all &&
		admission_rewrite ignored-unstable api-failure &&
		candidate=$(cat result) &&
		test_must_fail git cat-file -e "$candidate:unstable-file" &&
		! grep -F "cc/codex/preview-unstable" inputs &&
		! grep -F "cc/codex/preview-unstable" updates
	)
'

test_expect_success 'a reviewed merge enrolls exactly its retained topic' '
	setup_pending_admission reviewed-topic &&
	(
		cd reviewed-topic-runner &&
		fetch_all &&
		: >"$TRASH_DIRECTORY/reviewed-topic-gh.log" &&
		snapshot_refs ../reviewed-topic.git >before &&
		admission_rewrite reviewed-topic success &&
		candidate=$(cat result) &&
		test reviewed = "$(git show "$candidate:reviewed-file")" &&
		test enrolled = "$(git show "$candidate:enrolled-file")" &&
		test_grep "refs/heads/bb/codex/reviewed" inputs &&
		test_grep "refs/heads/bb/codex/reviewed" updates &&
		awk -F "$(printf "\t")" \
			"\$1 == \"admission\" && \$2 == \"refs/heads/bb/codex/reviewed\" && \$4 == 42 { found=1 } END { exit !found }" \
			inputs &&
		new_meta=$(updated_tip meta updates) &&
		git show "$new_meta:codex.config" >next.config &&
		test "$(updated_tip bb/codex/reviewed updates)" = \
			"$(git config --file next.config \
				--get branch.bb/codex/reviewed.codex-tip)" &&
		test_grep pulls "$TRASH_DIRECTORY/reviewed-topic-gh.log" &&
		test_grep reviews "$TRASH_DIRECTORY/reviewed-topic-gh.log" &&
		snapshot_refs ../reviewed-topic.git >after &&
		test_cmp before after
	)
'

test_expect_success 'a reviewed merge of an enrolled topic is normalized once' '
	setup_pending_admission reviewed-enrolled aa/codex/enrolled &&
	(
		cd reviewed-enrolled-runner &&
		fetch_all &&
		ADMISSION_TOPIC=aa/codex/enrolled \
			admission_rewrite reviewed-enrolled success &&
		candidate=$(cat result) &&
		test reviewed = "$(git show "$candidate:reviewed-file")" &&
		new_meta=$(updated_tip meta updates) &&
		git show "$new_meta:codex.config" >next.config &&
		git config --file next.config --get-regexp \
			"^branch\\..*\\.codex-tip$" >registered &&
		test_line_count = 1 registered &&
		test_grep "branch.aa/codex/enrolled.codex-tip" registered
	)
'

test_expect_success 'a pending merge requires one authentic merged pull request' '
	setup_pending_admission rejected-provenance &&
	(
		cd rejected-provenance-runner &&
		fetch_all &&
		snapshot_refs ../rejected-provenance.git >before &&
		for mode in no-pull-request duplicate-pull-request \
			open-pull-request unmerged-pull-request \
			wrong-merge wrong-base-repository wrong-base \
			wrong-head-repository wrong-head-ref wrong-head \
			draft-pull-request api-failure
		do
			test_expect_code 1 \
				admission_rewrite rejected-provenance "$mode" \
				>"$mode.out" 2>"$mode.err" || return 1
		done &&
		snapshot_refs ../rejected-provenance.git >after &&
		test_cmp before after
	)
'

test_expect_success 'a pending merge needs a current independent trusted review' '
	setup_pending_admission rejected-review &&
	(
		cd rejected-review-runner &&
		fetch_all &&
		snapshot_refs ../rejected-review.git >before &&
		for mode in no-review self-review outsider-review stale-review \
			rejected-review revoked-review dismissed-review \
			review-api-failure
		do
			test_expect_code 1 \
				admission_rewrite rejected-review "$mode" \
				>"$mode.out" 2>"$mode.err" || return 1
		done &&
		snapshot_refs ../rejected-review.git >after &&
		test_cmp before after
	)
'

test_expect_success 'comments do not invalidate an otherwise current approval' '
	setup_pending_admission commented-approval &&
	(
		cd commented-approval-runner &&
		fetch_all &&
		admission_rewrite commented-approval commented-review &&
		candidate=$(cat result) &&
		test reviewed = "$(git show "$candidate:reviewed-file")"
	)
'

test_expect_success 'a reviewed topic cannot advance after its pull request merged' '
	setup_pending_admission changed-reviewed-head &&
	(
		cd changed-reviewed-head-source &&
		git switch bb/codex/reviewed &&
		write unreviewed unreviewed-file &&
		git add unreviewed-file &&
		git commit -m "advance after review" &&
		git push origin bb/codex/reviewed
	) &&
	(
		cd changed-reviewed-head-runner &&
		fetch_all &&
		snapshot_refs ../changed-reviewed-head.git >before &&
		test_expect_code 1 \
			admission_rewrite changed-reviewed-head success \
			>rewrite.out 2>rewrite.err &&
		snapshot_refs ../changed-reviewed-head.git >after &&
		test_cmp before after
	)
'

test_expect_success 'a squash cannot enroll a topic without a merge parent' '
	setup_pending_admission squashed-admission bb/codex/reviewed squash &&
	(
		cd squashed-admission-runner &&
		fetch_all &&
		test_expect_code 1 \
			admission_rewrite squashed-admission success \
			>rewrite.out 2>rewrite.err &&
		test_grep "normal two-parent merge" rewrite.err
	)
'

test_expect_success 'a merged unstable topic cannot enroll in stable codex' '
	setup_pending_admission unstable-admission \
		bb/codex/reviewed-unstable &&
	(
		cd unstable-admission-runner &&
		fetch_all &&
		ADMISSION_TOPIC=bb/codex/reviewed-unstable \
			test_expect_code 1 \
			admission_rewrite unstable-admission success \
			>rewrite.out 2>rewrite.err
	)
'

test_expect_success 'two pending pull-request merges cannot share one rebuild' '
	setup_pending_admission double-admission &&
	(
		cd double-admission-source &&
		git switch -c cc/codex/second master &&
		write second second-file &&
		git add second-file &&
		git commit -m "second unadmitted topic" &&
		git switch codex &&
		git merge --no-ff cc/codex/second \
			-m "Merge pull request #43 from openai/cc/codex/second" &&
		git push origin codex cc/codex/second
	) &&
	(
		cd double-admission-runner &&
		fetch_all &&
		test_expect_code 1 \
			admission_rewrite double-admission success \
			>rewrite.out 2>rewrite.err &&
		test_grep "more than one pending Codex pull-request merge" \
			rewrite.err
	)
'

test_expect_success 'retiring the final enrolled topic fails closed' '
	setup_pending_admission missing-final-topic &&
	previous=$(git --git-dir=missing-final-topic.git \
		rev-parse refs/heads/aa/codex/enrolled) &&
	git --git-dir=missing-final-topic.git update-ref \
		refs/heads/codex "$previous" &&
	git --git-dir=missing-final-topic.git update-ref -d \
		refs/heads/aa/codex/enrolled &&
	(
		cd missing-final-topic-runner &&
		fetch_all &&
		test_expect_code 1 \
			admission_rewrite missing-final-topic api-failure \
			>rewrite.out 2>rewrite.err &&
		test_grep "enrolled Codex topics were removed" rewrite.err
	)
'

test_expect_success 'retiring an enrolled leaf never adopts its replacement' '
	setup_pending_admission retired-leaf &&
	(
		cd retired-leaf-source &&
		install_meta_state meta master codex &&
		git push origin meta &&
		git switch -c cc/codex/replacement master &&
		write replacement replacement-file &&
		git add replacement-file &&
		git commit -m "unreviewed replacement topic" &&
		git push origin cc/codex/replacement
	) &&
	git --git-dir=retired-leaf.git update-ref -d \
		refs/heads/bb/codex/reviewed &&
	(
		cd retired-leaf-runner &&
		fetch_all &&
		ADMISSION_TOPIC=aa/codex/enrolled \
			admission_rewrite retired-leaf api-failure &&
		candidate=$(cat result) &&
		test enrolled = "$(git show "$candidate:enrolled-file")" &&
		test_must_fail git cat-file -e "$candidate:reviewed-file" &&
		test_must_fail git cat-file -e "$candidate:replacement-file" &&
		! grep -F "bb/codex/reviewed" updates &&
		! grep -F "cc/codex/replacement" updates &&
		new_meta=$(updated_tip meta updates) &&
		git show "$new_meta:codex.config" >next.config &&
		! grep -F "bb/codex/reviewed" next.config &&
		! grep -F "cc/codex/replacement" next.config
	)
'

test_expect_success 'verified reviewed admission cannot survive a topic race' '
	setup_pending_admission admission-race &&
	(
		cd admission-race-runner &&
		fetch_all &&
		admission_rewrite admission-race success &&
		admission_command admission-race success \
			verify-output --inputs inputs --updates updates \
			--result result &&
		awk -F "$(printf "\t")" -v OFS="$(printf "\t")" \
			"\$1 == \"admission\" { \$4 = 43 } { print }" \
			inputs >forged-inputs &&
		test_expect_code 1 \
			admission_command admission-race success \
			verify-output --inputs forged-inputs --updates updates \
			--result result >forged.out 2>forged.err &&
		(
			cd ../admission-race-source &&
			git switch bb/codex/reviewed &&
			write later raced-review &&
			git add raced-review &&
			git commit -m "race the frozen reviewed head" &&
			git push origin bb/codex/reviewed
		) &&
		test_expect_code 1 \
			admission_command admission-race success \
			verify-inputs --remote origin inputs \
			>race.out 2>race.err
	)
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

test_expect_success 'topics cannot change the convenience wrappers' '
	git init --bare wrapper-control-path.git &&
	test_create_repo wrapper-control-path-source &&
	(
		cd wrapper-control-path-source &&
		git remote add origin ../wrapper-control-path.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch meta &&

		git switch -c aa/codex/rebuild-control master &&
		write untrusted rebuild &&
		git add rebuild &&
		git commit -m "change rebuild wrapper" &&
		install_meta_state meta master codex &&
		git push origin master meta codex aa/codex/rebuild-control
	) &&
	git clone wrapper-control-path.git wrapper-control-path-runner &&
	(
		cd wrapper-control-path-runner &&
		fetch_all &&
		snapshot_refs ../wrapper-control-path.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure \
			2>rebuild.err &&
		test_grep "meta-only controller files" rebuild.err &&
		snapshot_refs ../wrapper-control-path.git >after &&
		test_cmp before after
	) &&
	git --git-dir=wrapper-control-path.git update-ref -d \
		refs/heads/aa/codex/rebuild-control &&
	(
		cd wrapper-control-path-source &&
		git switch -c aa/codex/publish-control master &&
		write untrusted publish &&
		git add publish &&
		git commit -m "change publish wrapper" &&
		git branch -D aa/codex/rebuild-control &&
		install_meta_state meta master codex &&
		git push origin meta aa/codex/publish-control
	) &&
	(
		cd wrapper-control-path-runner &&
		fetch_all &&
		snapshot_refs ../wrapper-control-path.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure \
			2>publish.err &&
		test_grep "meta-only controller files" publish.err &&
		snapshot_refs ../wrapper-control-path.git >after &&
		test_cmp before after
	)
'

test_expect_success 'the reviewed automation trampoline cannot be downgraded' '
	for direction in upgrade stable-upgrade downgrade \
		stable-downgrade dual-downgrade
	do
		fixture="automation-$direction" &&
		git init --bare "$fixture.git" &&
		test_create_repo "$fixture-source" &&
		(
			cd "$fixture-source" &&
			git remote add origin "../$fixture.git" &&
			write base shared &&
			git add shared &&
			install_rerere_train &&
			git commit -m "automation migration base" &&
			git switch -c aa/codex/automation master &&
			mkdir -p .github/workflows &&
			case "$direction" in
			upgrade)
				write_automation_workflow \
					.github/workflows/codex.yml
				;;
			stable-upgrade|stable-downgrade)
				write_stable_reviewed_automation_workflow \
					.github/workflows/codex.yml
				;;
			downgrade|dual-downgrade)
				write_reviewed_automation_workflow \
					.github/workflows/codex.yml
				;;
			esac &&
			git add .github/workflows/codex.yml &&
			git commit -m "published automation" &&
			git branch codex &&
			git branch meta master &&
			install_meta_state meta master codex &&
			case "$direction" in
			upgrade|stable-upgrade)
				write_reviewed_automation_workflow \
					.github/workflows/codex.yml
				;;
			downgrade|stable-downgrade)
				write_automation_workflow \
					.github/workflows/codex.yml
				;;
			dual-downgrade)
				write_stable_reviewed_automation_workflow \
					.github/workflows/codex.yml
				;;
			esac &&
			git add .github/workflows/codex.yml &&
			git commit -m "change automation generation" &&
			git push origin master meta codex aa/codex/automation
		) &&
		git clone "$fixture.git" "$fixture-runner" &&
		(
			cd "$fixture-runner" &&
			fetch_all &&
			if test "$direction" = upgrade ||
				test "$direction" = stable-upgrade
			then
				sh "$codex_branch" rewrite --remote origin \
					--base master --codex codex \
					--result result --updates updates \
					--inputs inputs --failure failure \
					--require-automation &&
				git show "$(cat result):.github/workflows/codex.yml" \
					>candidate-workflow &&
				test_grep "  merge_group:" candidate-workflow
			else
				test_expect_code 1 \
					sh "$codex_branch" rewrite --remote origin \
						--base master --codex codex \
						--result result --updates updates \
						--inputs inputs --failure failure \
						--require-automation \
						>rewrite.out 2>rewrite.err &&
				test_grep "downgrades the canonical Codex admission workflow" \
					rewrite.err
			fi
		) || return 1
	done
'

test_expect_success 'published release provenance gates cannot be removed' '
	for change in publication version
	do
		fixture="release-guard-$change" &&
		git init --bare "$fixture.git" &&
		test_create_repo "$fixture-source" &&
		(
			cd "$fixture-source" &&
			git remote add origin "../$fixture.git" &&
			write base shared &&
			git add shared &&
			install_rerere_train &&
			git commit -m "release guard base" &&
			git switch -c aa/codex/release master &&
			mkdir -p .github/workflows &&
			write_guarded_release_workflow \
				.github/workflows/codex-release.yml &&
			git add .github/workflows/codex-release.yml &&
			git commit -m "publish guarded release workflow" &&
			git branch codex &&
			git branch meta master &&
			install_meta_state meta master codex &&
			if test "$change" = publication
			then
				write_release_workflow codex \
					.github/workflows/codex-release.yml
			else
				sed "/needs.publication.outputs.published/d" \
					.github/workflows/codex-release.yml \
					>release-without-gate &&
				mv release-without-gate \
					.github/workflows/codex-release.yml
			fi &&
			git add .github/workflows/codex-release.yml &&
			git commit -m "remove controller-only release guard" &&
			git push origin master meta codex aa/codex/release
		) &&
		git clone "$fixture.git" "$fixture-runner" &&
		(
			cd "$fixture-runner" &&
			fetch_all &&
			test_expect_code 1 \
				sh "$codex_branch" rewrite --remote origin \
					--base master --codex codex \
					--result result --updates updates \
					--inputs inputs --failure failure \
					>rewrite.out 2>rewrite.err &&
			test_grep "controller-only release publication guard" \
				rewrite.err
		) || return 1
	done
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

		git switch -c rebuild-control master &&
		write untrusted rebuild &&
		git add rebuild &&
		git commit -m "change rebuild wrapper" &&

		git switch -c publish-control master &&
		write untrusted publish &&
		git add publish &&
		git commit -m "change publish wrapper" &&

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
			workflow-extra:refs/heads/workflow-invalid \
			rebuild-control:refs/heads/rebuild-invalid \
			publish-control:refs/heads/publish-invalid
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
		sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result duplicate-result --updates duplicate-updates \
			--inputs duplicate-inputs --failure duplicate-failure \
			--require-automation 2>duplicate.err &&
		! grep -F "dd/codex/automation" duplicate-updates &&
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

		for wrapper in rebuild publish
		do
			wrapper_oid=$(git --git-dir=../automation.git \
				rev-parse "refs/heads/$wrapper-invalid") &&
			git --git-dir=../automation.git update-ref \
				refs/heads/bb/codex/control \
				"$wrapper_oid" &&
			fetch_all &&
			test_expect_code 1 sh "$codex_branch" rewrite \
				--remote origin --base master --codex codex \
				--result "$wrapper-result" \
				--updates "$wrapper-updates" \
				--inputs "$wrapper-inputs" \
				--failure "$wrapper-failure" \
				--require-automation 2>"$wrapper.err" &&
			test_grep "protected controller or CI file" \
				"$wrapper.err" &&
			git --git-dir=../automation.git update-ref -d \
				refs/heads/bb/codex/control \
				"$wrapper_oid" || return 1
		done &&

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

test_expect_success 'rewrite keeps canonical integrations when merge.log is enabled' '
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
		git config user.name "Configured Local User" &&
		git config user.email "configured-local-user@example.com" &&
		git config merge.log true &&

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
		has_same_author "$old_a" "$new_a" &&
		has_same_author "$old_b" "$new_b" &&
		has_same_author "$old_c" "$new_c" &&

		git rev-list --first-parent --reverse "$master..$candidate" \
			>integration-commits &&
		test_line_count = 3 integration-commits &&
		first_merge=$(sed -n "1p" integration-commits) &&
		second_merge=$(sed -n "2p" integration-commits) &&
		last_merge=$(sed -n "3p" integration-commits) &&
		new_meta=$(updated_tip meta updates) &&
		has_codex_bot_committer "$new_a" &&
		has_codex_bot_committer "$new_b" &&
		has_codex_bot_committer "$new_c" &&
		has_codex_bot_committer "$first_merge" &&
		has_codex_bot_committer "$second_merge" &&
		has_codex_bot_committer "$last_merge" &&
		has_codex_bot_committer "$new_meta" &&
		has_codex_bot_author "$first_merge" &&
		has_codex_bot_author "$second_merge" &&
		has_codex_bot_author "$last_merge" &&
		has_codex_bot_author "$new_meta" &&
		test "Merge aa/codex/a into codex" = \
			"$(git show -s --format=%s "$first_merge")" &&
		test "Merge bb/codex/b into codex" = \
			"$(git show -s --format=%s "$second_merge")" &&
		test "Merge cc/codex/c into codex" = \
			"$(git show -s --format=%s "$last_merge")" &&
		test "aa/codex/a@$new_a" = "$(git show -s \
			--format="%(trailers:key=Codex-Integration,valueonly)" \
			"$first_merge")" &&
		test "bb/codex/b@$new_b" = "$(git show -s \
			--format="%(trailers:key=Codex-Integration,valueonly)" \
			"$second_merge")" &&
		test "cc/codex/c@$new_c" = "$(git show -s \
			--format="%(trailers:key=Codex-Integration,valueonly)" \
			"$last_merge")" &&
		test "$master" = "$(git rev-parse "$first_merge^1")" &&
		test "$first_merge" = "$(git rev-parse "$second_merge^1")" &&
		test "$second_merge" = "$(git rev-parse "$last_merge^1")" &&
		test "$new_a" = "$(git rev-parse "$first_merge^2")" &&
		test "$new_b" = "$(git rev-parse "$second_merge^2")" &&
		test "$new_c" = "$(git rev-parse "$last_merge^2")" &&
		test 3 = "$(git rev-list --count --first-parent --merges \
			"$master..$candidate")" &&

		sh "$codex_branch" verify-inputs \
			--remote origin --base master --codex codex inputs &&
		git push --atomic --force origin \
			"${new_a}:refs/heads/aa/codex/a" \
			"${new_b}:refs/heads/bb/codex/b" \
			"${new_c}:refs/heads/cc/codex/c" \
			"${new_meta}:refs/heads/meta" \
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

test_expect_success 'tree-same legacy codex is canonicalized once' '
	git init --bare legacy-integrations.git &&
	test_create_repo legacy-integrations-source &&
	(
		cd legacy-integrations-source &&
		git remote add origin ../legacy-integrations.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&

		git switch -c aa/codex/a &&
		write A a &&
		git add a &&
		git commit -m "legacy topic A" &&

		git switch -c bb/codex/b &&
		write B b &&
		git add b &&
		git commit -m "legacy topic B" &&

		git switch -c cc/codex/c master &&
		write C c &&
		git add c &&
		git commit -m "legacy topic C" &&

		git switch -c codex master &&
		git merge --no-ff bb/codex/b -m "legacy maximal merge B" &&
		git merge --no-ff cc/codex/c -m "legacy maximal merge C" &&
		git branch meta master &&
		install_meta_state meta master codex &&
		git push origin master meta codex \
			aa/codex/a bb/codex/b cc/codex/c
	) &&

	git clone legacy-integrations.git legacy-integrations-runner &&
	(
		cd legacy-integrations-runner &&
		fetch_all &&
		legacy=$(git rev-parse origin/codex) &&
		master=$(git rev-parse origin/master) &&
		old_a=$(git rev-parse origin/aa/codex/a) &&
		old_b=$(git rev-parse origin/bb/codex/b) &&
		old_c=$(git rev-parse origin/cc/codex/c) &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		candidate=$(cat result) &&
		test "$legacy" != "$candidate" &&
		test "$(git rev-parse "$legacy^{tree}")" = \
			"$(git rev-parse "$candidate^{tree}")" &&
		git rev-list --first-parent --reverse "$master..$candidate" \
			>integration-commits &&
		test_line_count = 3 integration-commits &&
		first_merge=$(sed -n "1p" integration-commits) &&
		second_merge=$(sed -n "2p" integration-commits) &&
		last_merge=$(sed -n "3p" integration-commits) &&
		test "aa/codex/a@$old_a" = "$(git show -s \
			--format="%(trailers:key=Codex-Integration,valueonly)" \
			"$first_merge")" &&
		test "bb/codex/b@$old_b" = "$(git show -s \
			--format="%(trailers:key=Codex-Integration,valueonly)" \
			"$second_merge")" &&
		test "cc/codex/c@$old_c" = "$(git show -s \
			--format="%(trailers:key=Codex-Integration,valueonly)" \
			"$last_merge")" &&
		set -- git push --atomic --force origin &&
		while IFS="$(printf "\t")" read -r ref old new
		do
			set -- "$@" "$new:$ref" || return 1
		done <updates &&
		"$@"
	) &&

	git clone legacy-integrations.git legacy-integrations-noop &&
	(
		cd legacy-integrations-noop &&
		fetch_all &&
		published=$(git rev-parse origin/codex) &&
		snapshot_refs ../legacy-integrations.git >before &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		test "$published" = "$(cat result)" &&
		snapshot_refs ../legacy-integrations.git >after &&
		test_cmp before after
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

test_expect_success 'an advanced published prerequisite still owns both children' '
	git init --bare advanced-parent.git &&
	test_create_repo advanced-parent-source &&
	(
		cd advanced-parent-source &&
		git remote add origin ../advanced-parent.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&

		git switch -c aa/codex/parent &&
		write parent-zero parent-file &&
		git add parent-file &&
		git commit -m "published parent" &&

		git switch -c bb/codex/one &&
		write one child-one &&
		git add child-one &&
		git commit -m "first published child" &&

		git switch -c cc/codex/two aa/codex/parent &&
		write two child-two &&
		git add child-two &&
		git commit -m "second published child" &&

		git switch -c codex master &&
		git merge --no-ff aa/codex/parent \
			-m "Merge aa/codex/parent into codex" &&
		git merge --no-ff bb/codex/one \
			-m "Merge bb/codex/one into codex" &&
		git merge --no-ff cc/codex/two \
			-m "Merge cc/codex/two into codex" &&
		git branch meta master &&
		install_meta_state meta master codex &&

		git switch aa/codex/parent &&
		write parent-one parent-new-file &&
		git add parent-new-file &&
		git commit -m "advance published parent" &&
		git push origin master meta codex \
			aa/codex/parent bb/codex/one cc/codex/two
	) &&

	git clone advanced-parent.git advanced-parent-runner &&
	(
		cd advanced-parent-runner &&
		fetch_all &&
		snapshot_refs ../advanced-parent.git >before &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex \
			--result result --updates updates --inputs inputs \
			--failure failure &&
		sh "$codex_branch" verify-output --inputs inputs \
			--updates updates --result result &&

		new_parent=$(updated_tip aa/codex/parent updates) &&
		new_one=$(updated_tip bb/codex/one updates) &&
		new_two=$(updated_tip cc/codex/two updates) &&
		test "$new_parent" = "$(git rev-parse "$new_one^")" &&
		test "$new_parent" = "$(git rev-parse "$new_two^")" &&
		test parent-one = "$(git show "$new_one:parent-new-file")" &&
		test parent-one = "$(git show "$new_two:parent-new-file")" &&
		test one = "$(git show "$new_one:child-one")" &&
		test two = "$(git show "$new_two:child-two")" &&
		new_meta=$(updated_tip meta updates) &&
		git show "$new_meta:codex.config" >next.config &&
		test refs/heads/aa/codex/parent = \
			"$(git config --file next.config \
				--get branch.bb/codex/one.merge)" &&
		test refs/heads/aa/codex/parent = \
			"$(git config --file next.config \
				--get branch.cc/codex/two.merge)" &&
		snapshot_refs ../advanced-parent.git >after &&
		test_cmp before after
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
		git switch --detach refs/codex-output/candidate &&
		sh "$codex_branch" verify-output \
			--inputs ../bundle-builder/inputs \
			--updates ../bundle-builder/updates \
			--result ../bundle-builder/result \
			>verify.out 2>verify.err &&
		test_must_be_empty verify.err
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
		install_meta_state meta master codex &&
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
		candidate=$(cat result) &&
		master=$(git rev-parse origin/master) &&
		test "$master" != "$candidate" &&
		test "$master" = "$(git rev-parse "$candidate^2")" &&
		anchor=$(git rev-parse "$candidate^1") &&
		test "$master" = "$(git rev-parse "$anchor^1")" &&
		test "Begin codex integration" = \
			"$(git show -s --format=%s "$anchor")" &&
		test "Merge aa/codex/done into codex" = \
			"$(git show -s --format=%s "$candidate")" &&
		test "aa/codex/done@$master" = "$(git show -s \
			--format="%(trailers:key=Codex-Integration,valueonly)" \
			"$candidate")" &&
		test "$(git rev-parse "$master^{tree}")" = \
			"$(git rev-parse "$candidate^{tree}")" &&
		test 1 = "$(git rev-list --count --first-parent --merges \
			"$master..$candidate")" &&
		has_codex_bot_author "$anchor" &&
		has_codex_bot_committer "$anchor" &&
		has_codex_bot_author "$candidate" &&
		has_codex_bot_committer "$candidate" &&
		git bundle verify candidate.bundle &&
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
		old_conflicting=$(find_subject "conflicting root" "$root") &&
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
		test_grep "exact Meta/codex continue command printed by resolve" failure &&
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
		test_grep "continue --worktree ." resolve.out &&
		write resolved resolution/shared &&
		git -C resolution add shared &&
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
		new_conflicting=$(find_subject "conflicting root" "$new_root") &&
		test "$root" != "$new_root" &&
		test "$dependent" != "$new_dependent" &&
		test "$clean" != "$new_clean" &&
		test "$new_root" = "$(git rev-parse "$new_dependent^")" &&
		test "$base" = "$(git rev-parse "$new_clean^")" &&
		test before = "$(git show "$new_root:root-before")" &&
		test after = "$(git show "$new_root:root-after")" &&
		test resolved = "$(git show "$new_root:shared")" &&
		has_same_author "$old_conflicting" "$new_conflicting" &&
		has_codex_bot_committer "$new_conflicting" &&
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
		install_meta_state meta master codex &&
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
		has_codex_bot_committer "$new_topic" &&
		manifest_has aa/codex/rerere \
			"$old_topic" "$new_topic" updates &&
		manifest_has bb/codex/other \
			"$old_other" "$new_other" updates
	)
'

test_expect_success 'rewrite preserves a merge in an enrolled stable topic' '
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
		git switch master &&
		write advance advanced-base &&
		git add advanced-base &&
		git commit -m "advance master under private merge" &&
		git push origin master meta codex aa/codex/merged
	) &&

	git clone private.git private-runner &&
	(
		cd private-runner &&
		fetch_all &&
		snapshot_refs ../private.git >before &&
		old_merge=$(git rev-list --grep="^private merge$" \
			origin/master..origin/aa/codex/merged | sed -n 1p) &&
		sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result result --updates updates \
			--inputs inputs --failure failure \
			>out 2>err &&
		candidate=$(cat result) &&
		merged=$(updated_tip aa/codex/merged updates) &&
		new_merge=$(git rev-list --grep="^private merge$" \
			origin/master..$merged | sed -n 1p) &&
		test -n "$new_merge" &&
		test "$new_merge" != "$old_merge" &&
		test 2 = "$(git show -s --format=%P "$new_merge" |
			wc -w | tr -d " ")" &&
		test topic = "$(git show "$merged:topic-file")" &&
		test private = "$(git show "$merged:private-file")" &&
		git merge-base --is-ancestor "$merged" "$candidate" &&
		sh "$codex_branch" verify-output --inputs inputs \
			--updates updates --result result &&
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
		candidate=$(cat result) &&
		master=$(git rev-parse origin/master) &&
		new_parent=$(updated_tip aa/codex/parent updates) &&
		new_empty=$(updated_tip bb/codex/empty updates) &&
		test "$old_empty" != "$new_empty" &&
		test "$new_parent" = "$new_empty" &&
		test replacement = "$(git show "$new_empty:parent-file")" &&
		git rev-list --first-parent --reverse "$master..$candidate" \
			>integration-commits &&
		test_line_count = 2 integration-commits &&
		parent_merge=$(sed -n "1p" integration-commits) &&
		empty_merge=$(sed -n "2p" integration-commits) &&
		test "Merge aa/codex/parent into codex" = \
			"$(git show -s --format=%s "$parent_merge")" &&
		test "Merge bb/codex/empty into codex" = \
			"$(git show -s --format=%s "$empty_merge")" &&
		test "aa/codex/parent@$new_parent" = "$(git show -s \
			--format="%(trailers:key=Codex-Integration,valueonly)" \
			"$parent_merge")" &&
		test "bb/codex/empty@$new_empty" = "$(git show -s \
			--format="%(trailers:key=Codex-Integration,valueonly)" \
			"$empty_merge")" &&
		test "$master" = "$(git rev-parse "$parent_merge^1")" &&
		test "$parent_merge" = "$(git rev-parse "$empty_merge^1")" &&
		test "$new_parent" = "$(git rev-parse "$parent_merge^2")" &&
		test "$new_empty" = "$(git rev-parse "$empty_merge^2")" &&
		test "$(git rev-parse "$parent_merge^{tree}")" = \
			"$(git rev-parse "$empty_merge^{tree}")" &&
		has_codex_bot_author "$parent_merge" &&
		has_codex_bot_committer "$parent_merge" &&
		has_codex_bot_author "$empty_merge" &&
		has_codex_bot_committer "$empty_merge"
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
		test_grep "normal two-parent merge" err &&
		snapshot_refs ../direct-codex.git >after &&
		test_cmp before after
	)
'

test_expect_success 'a reviewed merge of an existing topic remains supported' '
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
	install_admission_gh "$TRASH_DIRECTORY/merged-codex-bin" &&
	(
		cd merged-codex-runner &&
		fetch_all &&
		ADMISSION_TOPIC=aa/codex/topic \
			admission_rewrite merged-codex success &&
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

test_expect_success 'initialize records a stable merge DAG' '
	git init --bare initialize-stable-dag.git &&
	test_create_repo initialize-stable-dag-source &&
	(
		cd initialize-stable-dag-source &&
		git remote add origin ../initialize-stable-dag.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git switch -c aa/codex/a &&
		write a a-file &&
		git add a-file &&
		git commit -m "initialize stable DAG parent A" &&
		git switch -c bb/codex/b master &&
		write b b-file &&
		git add b-file &&
		git commit -m "initialize stable DAG parent B" &&
		git switch -c cc/codex/fan aa/codex/a &&
		git merge --no-ff bb/codex/b \
			-m "Merge initialize stable DAG parents" &&
		write fan fan-file &&
		git add fan-file &&
		git commit -m "initialize stable DAG payload" &&
		git branch codex &&
		git branch meta master &&
		git push origin master meta codex \
			aa/codex/a bb/codex/b cc/codex/fan
	) &&

	git clone initialize-stable-dag.git initialize-stable-dag-runner &&
	(
		cd initialize-stable-dag-runner &&
		fetch_all &&
		sh "$codex_branch" initialize --remote origin \
			--base master --codex codex --output initialized.config &&
		git config --no-includes -f initialized.config --get-all \
			branch.cc/codex/fan.merge >actual-prerequisites &&
		printf "%s\n" refs/heads/aa/codex/a \
			refs/heads/bb/codex/b >expected-prerequisites &&
		test_cmp expected-prerequisites actual-prerequisites
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

test_expect_success 'Meta/codex pins every controller file to Meta HEAD' '
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
	cp "$codex_rebuild" wrapper-pin-Meta/rebuild &&
	cp "$codex_publish" wrapper-pin-Meta/publish &&
	cp "$codex_branch" \
		wrapper-pin-Meta/.github/workflows/codex-branch.sh &&
	chmod +x wrapper-pin-Meta/codex wrapper-pin-Meta/rebuild \
		wrapper-pin-Meta/publish \
		wrapper-pin-Meta/.github/workflows/codex-branch.sh &&
	git -C wrapper-pin-Meta add codex rebuild publish \
		.github/workflows/codex-branch.sh &&
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
	write dirty wrapper-pin-Meta/rebuild &&
	(
		cd wrapper-pin &&
		test_expect_code 1 ../wrapper-pin-Meta/codex \
			check-topic aa/codex/topic 2>../dirty-rebuild.err
	) &&
	test_grep "rebuild must match Meta/HEAD" dirty-rebuild.err &&
	git -C wrapper-pin-Meta restore rebuild &&
	write dirty wrapper-pin-Meta/publish &&
	(
		cd wrapper-pin &&
		test_expect_code 1 ../wrapper-pin-Meta/codex \
			check-topic aa/codex/topic 2>../dirty-publish.err
	) &&
	test_grep "publish must match Meta/HEAD" dirty-publish.err &&
	git -C wrapper-pin-Meta restore publish &&
	printf "\n# dirty\n" >>wrapper-pin-Meta/codex &&
	(
		cd wrapper-pin &&
		test_expect_code 1 ../wrapper-pin-Meta/codex \
			check-topic aa/codex/topic 2>../dirty-wrapper.err
	) &&
	test_grep "codex must match Meta/HEAD" dirty-wrapper.err
'

test_expect_success 'Meta/rebuild refreshes and executes a newer meta controller' '
	git init --bare meta-refresh.git &&
	test_create_repo meta-refresh-source &&
	(
		cd meta-refresh-source &&
		git remote add origin ../meta-refresh.git &&
		write base tracked &&
		git add tracked &&
		git commit -m base &&
		git branch meta
	) &&
	git -C meta-refresh-source worktree add ../meta-refresh-Meta meta &&
	mkdir -p meta-refresh-Meta/.github/workflows &&
	cp "$codex_entrypoint" meta-refresh-Meta/codex &&
	cp "$codex_rebuild" meta-refresh-Meta/rebuild &&
	cp "$codex_publish" meta-refresh-Meta/publish &&
	cp "$codex_branch" \
		meta-refresh-Meta/.github/workflows/codex-branch.sh &&
	chmod +x meta-refresh-Meta/codex meta-refresh-Meta/rebuild \
		meta-refresh-Meta/publish \
		meta-refresh-Meta/.github/workflows/codex-branch.sh &&
	git -C meta-refresh-Meta add codex rebuild publish \
		.github/workflows/codex-branch.sh &&
	git -C meta-refresh-Meta commit -m "install controller A" &&
	old_controller=$(git -C meta-refresh-Meta rev-parse HEAD) &&
	git -C meta-refresh-Meta push origin meta &&
	cat >meta-refresh-Meta/rebuild <<-\EOF &&
	#!/bin/sh
	printf "refreshed %s\\n" "$*" >"$META_REFRESH_MARKER"
	exit 23
	EOF
	chmod +x meta-refresh-Meta/rebuild &&
	git -C meta-refresh-Meta add rebuild &&
	git -C meta-refresh-Meta commit -m "install controller B" &&
	new_controller=$(git -C meta-refresh-Meta rev-parse HEAD) &&
	test "$old_controller" != "$new_controller" &&
	git -C meta-refresh-Meta push origin meta &&
	git -C meta-refresh-Meta switch --detach "$old_controller" &&
	mkdir meta-refresh-bin &&
	real_git=$(command -v git) &&
	cat >meta-refresh-bin/git <<-\EOF &&
	#!/bin/sh
	case "$*" in
	"remote get-url --all origin"|"remote get-url --push --all origin")
		printf "%s\\n" https://github.com/openai/git
		exit 0
		;;
	esac
	exec "$FAKE_REAL_GIT" "$@"
	EOF
	chmod +x meta-refresh-bin/git &&
	(
		cd meta-refresh-source &&
		PATH="$TRASH_DIRECTORY/meta-refresh-bin:$PATH" \
		FAKE_REAL_GIT="$real_git" \
		META_REFRESH_MARKER="$TRASH_DIRECTORY/meta-refresh.marker" \
		test_expect_code 23 ../meta-refresh-Meta/rebuild --local
	) &&
	test "$new_controller" = \
		"$(git -C meta-refresh-Meta rev-parse HEAD)" &&
	test_grep "refreshed --local" meta-refresh.marker
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

		git switch --detach "$valid_meta" &&
		git show "$valid_meta:codex.config" >codex.config &&
		git config --file codex.config --add \
			branch.aa/codex/topic.merge refs/heads/master &&
		git add codex.config &&
		git commit -m "duplicate stable prerequisite" &&
		git branch duplicate-merge-state &&

		git switch --detach "$valid_meta" &&
		git show "$valid_meta:codex.config" >codex.config &&
		git config --file codex.config --add \
			branch.aa/codex/topic.merge refs/heads/bb/codex/other &&
		git add codex.config &&
		git commit -m "mixed stable prerequisites" &&
		git branch mixed-merge-state &&
		git branch -f meta "$malformed" &&
		git push origin master meta codex aa/codex/topic \
			malformed-state noncanonical-state \
			duplicate-merge-state mixed-merge-state
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
		test_cmp before-noncanonical after-noncanonical &&

		duplicate=$(git rev-parse origin/duplicate-merge-state) &&
		git --git-dir=../invalid-state.git update-ref refs/heads/meta \
			"$duplicate" "$noncanonical" &&
		fetch_all &&
		snapshot_refs ../invalid-state.git >before-duplicate &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result duplicate-result \
			--updates duplicate-updates --inputs duplicate-inputs \
			--failure duplicate-failure >duplicate.out 2>duplicate.err &&
		test_grep "repeats prerequisite.*master" duplicate.err &&
		snapshot_refs ../invalid-state.git >after-duplicate &&
		test_cmp before-duplicate after-duplicate &&

		mixed=$(git rev-parse origin/mixed-merge-state) &&
		git --git-dir=../invalid-state.git update-ref refs/heads/meta \
			"$mixed" "$duplicate" &&
		fetch_all &&
		snapshot_refs ../invalid-state.git >before-mixed &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result mixed-result \
			--updates mixed-updates --inputs mixed-inputs \
			--failure mixed-failure >mixed.out 2>mixed.err &&
		test_grep "mixes master with topic prerequisites" mixed.err &&
		snapshot_refs ../invalid-state.git >after-mixed &&
		test_cmp before-mixed after-mixed
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

test_expect_success 'verify-output rejects alternate integration histories' '
	git init --bare integration-output.git &&
	test_create_repo integration-output-source &&
	(
		cd integration-output-source &&
		git remote add origin ../integration-output.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/a &&
		write A a &&
		git add a &&
		git commit -m "output topic A" &&

		git switch -c bb/codex/b &&
		write B b &&
		git add b &&
		git commit -m "output topic B" &&

		git switch -c cc/codex/c master &&
		write C c &&
		git add c &&
		git commit -m "output topic C" &&

		git switch master &&
		git branch meta &&
		install_meta_state meta master codex &&
		git push origin master meta codex \
			aa/codex/a bb/codex/b cc/codex/c
	) &&

	git clone integration-output.git integration-output-runner &&
	(
		cd integration-output-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result valid.result \
			--updates valid.updates --inputs inputs --failure failure &&
		sh "$codex_branch" verify-output --inputs inputs \
			--updates valid.updates --result valid.result &&

		base=$(git rev-parse origin/master) &&
		topic_a=$(updated_tip aa/codex/a valid.updates) &&
		topic_b=$(updated_tip bb/codex/b valid.updates) &&
		topic_c=$(updated_tip cc/codex/c valid.updates) &&
		old_meta=$(git rev-parse origin/meta) &&
		valid_meta=$(updated_tip meta valid.updates) &&
		valid_candidate=$(cat valid.result) &&
		valid_tree=$(git rev-parse "$valid_candidate^{tree}") &&

		missing_b=$(printf "%s\n" "Legacy maximal merge B" |
			GIT_AUTHOR_NAME=$codex_bot_name \
			GIT_AUTHOR_EMAIL=$codex_bot_email \
			GIT_COMMITTER_NAME=$codex_bot_name \
			GIT_COMMITTER_EMAIL=$codex_bot_email \
			git -c commit.gpgSign=false commit-tree \
				"$topic_b^{tree}" -p "$base" -p "$topic_b") &&
		missing=$(printf "%s\n" "Legacy maximal merge C" |
			GIT_AUTHOR_NAME=$codex_bot_name \
			GIT_AUTHOR_EMAIL=$codex_bot_email \
			GIT_COMMITTER_NAME=$codex_bot_name \
			GIT_COMMITTER_EMAIL=$codex_bot_email \
			git -c commit.gpgSign=false commit-tree \
				"$valid_tree" -p "$missing_b" -p "$topic_c") &&
		test "$valid_tree" = "$(git rev-parse "$missing^{tree}")" &&
		write_test_output_tuple "$valid_meta" "$old_meta" \
			"$valid_candidate" "$missing" valid.updates missing &&
		test_expect_code 1 sh "$codex_branch" verify-output \
			--inputs inputs --updates missing.updates \
			--result missing.result >missing.out 2>missing.err &&
		test_grep "one canonical integration merge per topic" missing.err &&

		c_merge=$(make_test_integration cc/codex/c "$topic_c" \
			"$base" "$topic_c^{tree}") &&
		ac_tree=$(git merge-tree --write-tree "$c_merge" "$topic_a") &&
		a_merge=$(make_test_integration aa/codex/a "$topic_a" \
			"$c_merge" "$ac_tree") &&
		acb_tree=$(git merge-tree --write-tree "$a_merge" "$topic_b") &&
		reordered=$(make_test_integration bb/codex/b "$topic_b" \
			"$a_merge" "$acb_tree") &&
		test "$valid_tree" = "$(git rev-parse "$reordered^{tree}")" &&
		write_test_output_tuple "$valid_meta" "$old_meta" \
			"$valid_candidate" "$reordered" valid.updates reordered &&
		test_expect_code 1 sh "$codex_branch" verify-output \
			--inputs inputs --updates reordered.updates \
			--result reordered.result >reordered.out 2>reordered.err &&
		test_grep "one canonical integration merge per topic" reordered.err &&

		before_c=$(git rev-parse "$valid_candidate^1") &&
		forged_message=$(printf "Merge cc/codex/c into codex\n\nIntegrate the current cc/codex/c topic into the internally distributed codex branch.\n\nCodex-Integration: cc/codex/c@%s" \
			"$topic_b") &&
		forged=$(printf "%s\n" "$forged_message" |
			GIT_AUTHOR_NAME=$codex_bot_name \
			GIT_AUTHOR_EMAIL=$codex_bot_email \
			GIT_COMMITTER_NAME=$codex_bot_name \
			GIT_COMMITTER_EMAIL=$codex_bot_email \
			git -c commit.gpgSign=false commit-tree "$valid_tree" \
				-p "$before_c" -p "$topic_c") &&
		test "$valid_tree" = "$(git rev-parse "$forged^{tree}")" &&
		write_test_output_tuple "$valid_meta" "$old_meta" \
			"$valid_candidate" "$forged" valid.updates forged &&
		test_expect_code 1 sh "$codex_branch" verify-output \
			--inputs inputs --updates forged.updates \
			--result forged.result >forged.out 2>forged.err &&
		test_grep "one canonical integration merge per topic" forged.err
	)
'

test_expect_success PYTHON 'publish-run authenticates the artifact and promotes its exact candidate' '
	git init --bare publish-run.git &&
	test_create_repo publish-run-source &&
	(
		cd publish-run-source &&
		git remote add origin ../publish-run.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c aa/codex/automation &&
		mkdir -p .github/workflows &&
		write_automation_workflow .github/workflows/codex.yml &&
		git add .github/workflows/codex.yml &&
		git commit -m "install refresh trampoline" &&

		git switch master &&
		write current master-file &&
		git add master-file &&
		git commit -m "publish-run master" &&
		git branch meta master &&
		install_meta_state meta master codex &&
		git worktree add ../publish-run-controller meta &&
		cp "$codex_entrypoint" ../publish-run-controller/codex &&
		cp "$codex_rebuild" ../publish-run-controller/rebuild &&
		cp "$codex_publish" ../publish-run-controller/publish &&
		chmod +x ../publish-run-controller/codex \
			../publish-run-controller/rebuild \
			../publish-run-controller/publish &&
		git -C ../publish-run-controller add codex rebuild publish &&
		git -C ../publish-run-controller commit -m \
			"install pinned controller entry points" &&
		git push origin master meta codex aa/codex/automation
	) &&

	git clone publish-run.git publish-run-runner &&
	(
		cd publish-run-runner &&
		fetch_all &&
		support="$TRASH_DIRECTORY/publish-run-support" &&
		mkdir -p "$support" &&
		controller=$(git rev-parse origin/meta) &&
		old_codex=$(git rev-parse origin/codex) &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --require-automation \
			--result "$support/codex-candidate" \
			--updates "$support/codex-updates" \
			--inputs "$support/codex-inputs" \
			--bundle "$support/codex.bundle" \
			--failure "$support/codex-failure" &&
		candidate=$(cat "$support/codex-candidate") &&
		new_meta=$(updated_tip meta "$support/codex-updates") &&
		{
			printf "repository\topenai/git\n" &&
			printf "run-id\t4242\n" &&
			printf "run-attempt\t1\n" &&
			printf "event\tworkflow_dispatch\n" &&
			printf "caller-ref\trefs/heads/codex\n" &&
			printf "caller-sha\t%s\n" "$old_codex" &&
			printf "workflow-path\t.github/workflows/codex.yml\n" &&
			printf "controller-oid\t%s\n" "$controller" &&
			printf "candidate\t%s\n" "$candidate" &&
			printf "artifact-name\tcodex-candidate-4242-1\n"
		} >"$support/codex-run" &&

		git update-ref refs/codex-output/candidate "$candidate" &&
		git update-ref refs/codex-output/meta "$new_meta" &&
		git update-ref refs/codex-output/unexpected "$candidate" &&
		git bundle create "$support/extra-head.bundle" \
			refs/codex-output/candidate refs/codex-output/meta \
			refs/codex-output/unexpected &&
		git update-ref -d refs/codex-output/candidate &&
		git update-ref -d refs/codex-output/meta &&
		git update-ref -d refs/codex-output/unexpected &&

		git init "$support/artifact" &&
		cp "$support/codex.bundle" "$support/codex-candidate" \
			"$support/codex-inputs" "$support/codex-run" \
			"$support/codex-updates" "$support/artifact" &&
		(
			cd "$support/artifact" &&
			git add codex.bundle codex-candidate codex-inputs \
				codex-run codex-updates &&
			git commit -m "good candidate artifact" &&
			good=$(git rev-parse HEAD) &&
			git archive --format=zip --output="$support/good.zip" \
				"$good" &&

			sed "s/^run-id.*4242$/run-id	9999/" codex-run \
				>codex-run.bad &&
			mv codex-run.bad codex-run &&
			git add codex-run &&
			git commit -m "bad artifact metadata" &&
			git archive --format=zip \
				--output="$support/bad-metadata.zip" HEAD &&

			git switch --detach "$good" &&
			write extra unexpected &&
			git add unexpected &&
			git commit -m "extra artifact member" &&
			git archive --format=zip --output="$support/extra.zip" \
				HEAD &&

			git switch --detach "$good" &&
			rm codex-candidate &&
			ln -s codex-run codex-candidate &&
			git add codex-candidate &&
			git commit -m "non-regular artifact member" &&
			git archive --format=zip --output="$support/symlink.zip" \
				HEAD &&

			git switch --detach "$good" &&
			cp "$support/extra-head.bundle" codex.bundle &&
			git add codex.bundle &&
			git commit -m "bundle with an extra advertised head" &&
			git archive --format=zip \
				--output="$support/extra-head.zip" HEAD
		) &&
		cat >"$support/duplicate.py" <<-\EOF &&
		import sys
		import zipfile

		source, target = sys.argv[1:]
		with zipfile.ZipFile(source) as src, zipfile.ZipFile(target, "w") as dst:
		    for item in src.infolist():
		        data = src.read(item.filename)
		        dst.writestr(item, data)
		        if item.filename == "codex-run":
		            dst.writestr(item, data)
		EOF
		python3 "$support/duplicate.py" "$support/good.zip" \
			"$support/duplicate.zip" 2>/dev/null &&

		mkdir -p "$support/bin" &&
		real_git=$(command -v git) &&
		cat >"$support/bin/git" <<-\EOF &&
		#!/bin/sh
		printf "%s\\n" "$*" >>"$FAKE_GIT_LOG"
		if test -n "${FAKE_LOCAL_PREP_ORIGIN:-}" && test "$1" = -C
		then
			case "$2" in
			*/local-prepare)
				if test "$3" = remote && test "$4" = set-url &&
					test "$5" = origin
				then
					exec "$FAKE_REAL_GIT" -C "$2" remote set-url \
						origin "$FAKE_LOCAL_PREP_ORIGIN"
				elif test "$3" = remote && test "$4" = set-url &&
					test "$5" = --push && test "$6" = origin
				then
					exec "$FAKE_REAL_GIT" -C "$2" remote set-url \
						--push origin "$FAKE_LOCAL_PREP_ORIGIN"
				fi
				;;
			esac
		fi
		if test "${FAKE_ASSERT_BUNDLE_IMPORT:-}" = 1 &&
			test "$1" = bundle && test "$2" = verify
		then
			bundle_candidate=$("$FAKE_REAL_GIT" bundle list-heads "$3" |
				sed -n "s/ refs\\/codex-output\\/candidate\$//p") ||
				exit 92
			test -n "$bundle_candidate" || exit 92
			if test ! -f "$FAKE_BUNDLE_ABSENT_MARKER"
			then
				! "$FAKE_REAL_GIT" cat-file -e \
					"$bundle_candidate^{commit}" 2>/dev/null || exit 91
				printf "%s\\n" "$bundle_candidate" \
					>"$FAKE_BUNDLE_ABSENT_MARKER"
			else
				test "$bundle_candidate" = \
					"$(sed -n "1p" "$FAKE_BUNDLE_ABSENT_MARKER")" ||
					exit 91
			fi
		fi
		if test "${FAKE_ASSERT_BUNDLE_IMPORT:-}" = 1 &&
			test "$1" = bundle && test "$2" = unbundle
		then
			"$FAKE_REAL_GIT" "$@" || exit
			bundle_candidate=$(sed -n "1p" \
				"$FAKE_BUNDLE_ABSENT_MARKER")
			"$FAKE_REAL_GIT" cat-file -e \
				"$bundle_candidate^{commit}" || exit 90
			: >"$FAKE_BUNDLE_IMPORTED_MARKER"
			exit 0
		fi
		case "$*" in
		"remote get-url --all origin")
			printf "%s\\n" https://github.com/openai/git
			exit 0
			;;
		"remote get-url --push --all origin")
			printf "%s\\n" https://github.com/openai/git
			if test "${FAKE_MULTIPLE_PUSHURLS:-}" = 1
			then
				printf "%s\\n" git@github.com:openai/git.git
			fi
			exit 0
			;;
		esac
		exec "$FAKE_REAL_GIT" "$@"
		EOF
		chmod +x "$support/bin/git" &&
		cat >"$support/bin/gh" <<-\EOF &&
		#!/bin/sh
		printf "%s\\n" "$*" >>"$FAKE_GH_LOG"
		if test "$1" = api && test "$2" = --hostname &&
			test "$3" = github.com && test "$4" = --method
		then
			test "$5" = POST || exit 96
			case "$*" in
			*"--header X-GitHub-Api-Version: 2026-03-10"*\
			*"--raw-field ref=codex"*\
			*"repos/openai/git/actions/workflows/codex.yml/dispatches"*) ;;
			*) exit 95 ;;
			esac
			test "${FAKE_GH_MODE:-}" != dispatch-error || exit 94
			if test "${FAKE_GH_MODE:-}" = dispatch-malformed
			then
				printf "4242\\thttps://api.github.com/repos/openai/git/actions/runs/9999\\thttps://github.com/openai/git/actions/runs/4242\\n"
			else
				printf "4242\\thttps://api.github.com/repos/openai/git/actions/runs/4242\\thttps://github.com/openai/git/actions/runs/4242\\n"
			fi
			exit
		fi
		test "$1" = api &&
		test "$2" = --hostname &&
		test "$3" = github.com || exit 96
		shift 3
		while test "$1" = --paginate || test "$1" = --slurp
		do
			test "$1" != --slurp || exit 93
			shift
		done
		endpoint=$1
		shift
		case "$endpoint" in
		repos/openai/git/actions/runs/4242)
			case "$*" in
			*referenced_workflows*)
				case "$*" in
				*"openai/git/.github/workflows/codex.yml@meta"*\
				*".ref == \"refs/heads/meta\""*\
				*".sha == \"$FAKE_CONTROLLER\""*) ;;
				*) exit 95 ;;
				esac
				if test "${FAKE_GH_MODE:-}" = wrong-controller
				then
					printf "0\\n"
				else
					printf "1\\n"
				fi
				;;
			*)
				api_id=4242
				test "${FAKE_GH_MODE:-}" != wrong-run || api_id=9999
				run_attempt=1
				status=completed
				conclusion=success
				if test "${FAKE_GH_MODE:-}" = post-ci-rerun &&
					test -f "$FAKE_GH_STATE.after-ci"
				then
					run_attempt=2
				fi
				case "${FAKE_GH_MODE:-}" in
				preparation-failure) conclusion=failure ;;
				preparation-rerun) run_attempt=2 ;;
				preparation-timeout)
					status=in_progress
					conclusion=-
					;;
				esac
				printf "%s\\t%s\\t%s\\t%s\\tworkflow_dispatch\\tcodex\\t%s\\t.github/workflows/codex.yml\\topenai/git\\thttps://example/run/4242\\n" \
					"$api_id" "$run_attempt" "$status" "$conclusion" \
					"$FAKE_OLD_CODEX"
				;;
			esac
			;;
		repos/openai/git/actions/runs/4242/artifacts?per_page=100)
			printf "9001\\tfalse\\n"
			;;
		repos/openai/git/actions/artifacts/9001/zip)
			cat "$FAKE_ARTIFACT_ZIP"
			;;
		repos/openai/git/actions/workflows/main.yml/runs*)
			case "$*" in
			*"max // 0"*) printf "100\\n" ;;
			*) printf "101\\n" ;;
			esac
			;;
		repos/openai/git/actions/runs/101)
			ci_candidate=$FAKE_CANDIDATE
			if test "${FAKE_DYNAMIC_CANDIDATE:-}" = 1
			then
				ci_candidate=$("$FAKE_REAL_GIT" \
					--git-dir="$FAKE_LOCAL_PREP_ORIGIN" \
					rev-parse refs/heads/codex-staging) || exit 98
			fi
			count=$(cat "$FAKE_GH_STATE" 2>/dev/null || :)
			count=${count:-0}
			count=$((count + 1))
			printf "%s\\n" "$count" >"$FAKE_GH_STATE"
			case "${FAKE_GH_MODE:-}" in
			staging-failure)
				status=completed
				conclusion=failure
				;;
			post-ci-rerun)
				if test "$count" -le 11
				then
					status=in_progress
					conclusion=-
				else
					status=completed
					conclusion=success
					: >"$FAKE_GH_STATE.after-ci"
				fi
				;;
			*)
				case "$count" in
				1|2) status=queued; conclusion=- ;;
				3|4) status=in_progress; conclusion=- ;;
				*) status=completed; conclusion=success ;;
				esac
				;;
			esac
			printf "101\\tpush\\tcodex-staging\\t%s\\t.github/workflows/main.yml\\t%s\\t%s\\thttps://example/ci/101\\n" \
				"$ci_candidate" "$status" "$conclusion"
			;;
		repos/openai/git/actions/runs/101/jobs?per_page=100)
			case "$*" in
			*"@tsv"*)
				count=$(cat "$FAKE_GH_STATE")
				if test "${FAKE_GH_MODE:-}" = staging-failure
				then
					printf "completed\\tsuccess\\n"
					printf "completed\\tfailure\\n"
				elif test "${FAKE_GH_MODE:-}" = post-ci-rerun
				then
					case "$count" in
					1|2|3|4|5|6|7|8|9|10|11)
						printf "completed\\tsuccess\\n"
						printf "in_progress\\t-\\n"
						;;
					*)
						printf "completed\\tsuccess\\n"
						printf "completed\\tsuccess\\n"
						;;
					esac
				else
					case "$count" in
					1|2)
						printf "queued\\t-\\n"
						printf "queued\\t-\\n"
						;;
					3)
						printf "completed\\tsuccess\\n"
						printf "in_progress\\t-\\n"
						;;
					*)
						printf "completed\\tsuccess\\n"
						printf "completed\\tsuccess\\n"
						;;
					esac
				fi
				;;
			*)
				printf "success\\n"
				;;
			esac
			;;
		user)
			printf "test-publisher\\n"
			;;
		*)
			printf "unexpected gh endpoint: %s\\n" "$endpoint" >&2
			exit 97
			;;
		esac
		EOF
		chmod +x "$support/bin/gh" &&
		cat >"$support/bin/sleep" <<-\EOF &&
		#!/bin/sh
		exit 0
		EOF
		chmod +x "$support/bin/sleep" &&

		git worktree add --detach Meta "$controller" &&
		local_origin=$(cd ../publish-run.git && pwd) &&
		git status --porcelain >"$support/nested-status" &&
		test_line_count = 1 "$support/nested-status" &&
		test_grep "?? Meta/" "$support/nested-status" &&
		run_prepared () {
			artifact=$1 &&
			shift &&
			active_controller=$(git -C Meta rev-parse HEAD) &&
			rm -f "$support/gh.state" &&
			rm -f "$support/gh.state.after-ci" &&
			env PATH="$support/bin:$PATH" GH_HOST=attacker.example \
				CODEX_CONTROLLER_OID="$active_controller" \
				CODEX_META_WORKTREE="$PWD/Meta" \
				FAKE_REAL_GIT="$real_git" \
				FAKE_GIT_LOG="$support/git.log" \
				FAKE_GH_LOG="$support/gh.log" \
				FAKE_GH_STATE="$support/gh.state" \
				FAKE_ARTIFACT_ZIP="$artifact" \
				FAKE_CONTROLLER="$active_controller" \
				FAKE_OLD_CODEX="$old_codex" \
				FAKE_CANDIDATE="$candidate" \
				FAKE_DYNAMIC_CANDIDATE="${FAKE_DYNAMIC_CANDIDATE:-}" \
				FAKE_LOCAL_PREP_ORIGIN="$local_origin" \
				FAKE_ASSERT_BUNDLE_IMPORT="${FAKE_ASSERT_BUNDLE_IMPORT:-}" \
				FAKE_BUNDLE_ABSENT_MARKER="$support/bundle-absent" \
				FAKE_BUNDLE_IMPORTED_MARKER="$support/bundle-imported" \
				FAKE_HOOK_MARKER="$support/inherited-hook-ran" \
				FAKE_ZIP_MARKER="${FAKE_ZIP_MARKER:-}" \
				GIT_CONFIG_COUNT="${FAKE_GIT_CONFIG_COUNT:-0}" \
				GIT_CONFIG_KEY_0=core.hooksPath \
				GIT_CONFIG_VALUE_0="$support/hooks" \
				FAKE_MULTIPLE_PUSHURLS="${FAKE_MULTIPLE_PUSHURLS:-}" \
				FAKE_GH_MODE="${FAKE_GH_MODE:-}" \
				sh "$codex_branch" "$@"
		} &&
		publish_prepared () {
			run_prepared "$1" publish-run 4242
		} &&
		rebuild_prepared () {
			run_prepared "$1" rebuild
		} &&
		snapshot_refs ../publish-run.git >"$support/before" &&

		write dirty dirty &&
		: >"$support/gh.log" &&
		test_expect_code 1 publish_prepared "$support/good.zip" \
			>"$support/dirty.out" 2>"$support/dirty.err" &&
		test_grep "must be clean" "$support/dirty.err" &&
		test_must_be_empty "$support/gh.log" &&
		rm dirty &&

		: >"$support/gh.log" &&
		FAKE_MULTIPLE_PUSHURLS=1 test_expect_code 1 \
			publish_prepared "$support/good.zip" \
			>"$support/pushurl.out" 2>"$support/pushurl.err" &&
		test_grep "origin must have exactly one push URL" \
			"$support/pushurl.err" &&
		test_must_be_empty "$support/gh.log" &&

		FAKE_GH_MODE=dispatch-error test_expect_code 1 \
			rebuild_prepared "$support/good.zip" \
			>"$support/dispatch-error.out" \
			2>"$support/dispatch-error.err" &&
		test_grep "could not dispatch Refresh codex" \
			"$support/dispatch-error.err" &&
		FAKE_GH_MODE=dispatch-malformed test_expect_code 1 \
			rebuild_prepared "$support/good.zip" \
			>"$support/dispatch-malformed.out" \
			2>"$support/dispatch-malformed.err" &&
		test_grep "dispatch returned unexpected run URLs" \
			"$support/dispatch-malformed.err" &&
		FAKE_GH_MODE=preparation-failure test_expect_code 1 \
			rebuild_prepared "$support/good.zip" \
			>"$support/preparation-failure.out" \
			2>"$support/preparation-failure.err" &&
		test_grep "Preparation: failure: https://example/run/4242" \
			"$support/preparation-failure.out" &&
		test_grep "finished with .failure." \
			"$support/preparation-failure.err" &&
		FAKE_GH_MODE=preparation-rerun test_expect_code 1 \
			rebuild_prepared "$support/good.zip" \
			>"$support/preparation-rerun.out" \
			2>"$support/preparation-rerun.err" &&
		test_grep "no longer identifies the dispatched Refresh codex attempt" \
			"$support/preparation-rerun.err" &&
		FAKE_GH_MODE=preparation-timeout test_expect_code 1 \
			rebuild_prepared "$support/good.zip" \
			>"$support/preparation-timeout.out" \
			2>"$support/preparation-timeout.err" &&
		test_grep "did not complete before the timeout" \
			"$support/preparation-timeout.err" &&
		snapshot_refs ../publish-run.git >"$support/after-dispatch-rejections" &&
		test_cmp "$support/before" \
			"$support/after-dispatch-rejections" &&

		FAKE_GH_MODE=wrong-run test_expect_code 1 \
			publish_prepared "$support/good.zip" \
			>"$support/wrong-run.out" 2>"$support/wrong-run.err" &&
		test_grep "Actions returned the wrong run" \
			"$support/wrong-run.err" &&
		FAKE_GH_MODE=wrong-controller test_expect_code 1 \
			publish_prepared "$support/good.zip" \
			>"$support/controller.out" 2>"$support/controller.err" &&
		test_grep "was not executed by the pinned meta controller" \
			"$support/controller.err" &&
		test_expect_code 1 publish_prepared "$support/bad-metadata.zip" \
			>"$support/metadata.out" 2>"$support/metadata.err" &&
		test_grep "run metadata does not exactly match" \
			"$support/metadata.err" &&
		test_expect_code 1 publish_prepared "$support/duplicate.zip" \
			>"$support/duplicate.out" 2>"$support/duplicate.err" &&
		test_grep "does not contain exactly the expected files" \
			"$support/duplicate.err" &&
		test_expect_code 1 publish_prepared "$support/extra.zip" \
			>"$support/extra.out" 2>"$support/extra.err" &&
		test_grep "does not contain exactly the expected files" \
			"$support/extra.err" &&
		test_expect_code 1 publish_prepared "$support/symlink.zip" \
			>"$support/symlink.out" 2>"$support/symlink.err" &&
		test_grep "contains a non-regular entry" "$support/symlink.err" &&
		test_expect_code 1 publish_prepared "$support/extra-head.zip" \
			>"$support/heads.out" 2>"$support/heads.err" &&
		test_grep "bundle heads do not match the frozen update manifest" \
			"$support/heads.err" &&
		snapshot_refs ../publish-run.git >"$support/after-rejections" &&
		test_cmp "$support/before" "$support/after-rejections" &&

		FAKE_GH_MODE=staging-failure test_expect_code 1 \
			run_prepared "$support/good.zip" publish 4242 \
			>"$support/staging-failure.out" \
			2>"$support/staging-failure.err" &&
		test_grep "Waiting for staging CI for $candidate" \
			"$support/staging-failure.out" &&
		test_grep "Staging CI run 101: https://example/ci/101" \
			"$support/staging-failure.out" &&
		test_grep "Staging CI: failure (2/2 jobs complete; 1 failed)" \
			"$support/staging-failure.out" &&
		test_grep "CI failed for exact staging SHA $candidate" \
			"$support/staging-failure.err" &&
		test "$candidate" = "$(git --git-dir=../publish-run.git \
			rev-parse refs/heads/codex-staging)" &&
		snapshot_without_staging ../publish-run.git \
			>"$support/after-staging-failure" &&
		test_cmp "$support/before" "$support/after-staging-failure" &&
		git --git-dir=../publish-run.git update-ref -d \
			refs/heads/codex-staging "$candidate" &&

		FAKE_GH_MODE=post-ci-rerun test_expect_code 1 \
			run_prepared "$support/good.zip" publish 4242 \
			>"$support/post-ci-rerun.out" \
			2>"$support/post-ci-rerun.err" &&
		grep -F "Staging CI: still in_progress after 5 minutes (1/2 jobs complete; 0 failed)" \
			"$support/post-ci-rerun.out" \
			>"$support/staging-heartbeat" &&
		test_line_count = 1 "$support/staging-heartbeat" &&
		test_grep "Actions run 4242 changed while staging CI ran" \
			"$support/post-ci-rerun.err" &&
		test "$candidate" = "$(git --git-dir=../publish-run.git \
			rev-parse refs/heads/codex-staging)" &&
		snapshot_without_staging ../publish-run.git \
			>"$support/after-post-ci-rerun" &&
		test_cmp "$support/before" "$support/after-post-ci-rerun" &&
		git --git-dir=../publish-run.git update-ref -d \
			refs/heads/codex-staging "$candidate" &&

		: >"$support/gh.log" &&
		rebuild_prepared "$support/good.zip" \
			>"$support/publish.out" 2>"$support/publish.err" &&
		test_grep "Refresh codex run 4242: https://github.com/openai/git/actions/runs/4242" \
			"$support/publish.out" &&
		test_grep "Preparation: success: https://example/run/4242" \
			"$support/publish.out" &&
		test_grep "Published codex candidate $candidate from Actions run 4242" \
			"$support/publish.out" &&
		test_grep "api --hostname github.com --method POST" \
			"$support/gh.log" &&
		test_grep "X-GitHub-Api-Version: 2026-03-10" \
			"$support/gh.log" &&
		test_grep "raw-field ref=codex" "$support/gh.log" &&
		! grep -F "actions/workflows/codex.yml/runs" \
			"$support/gh.log" &&
		test_grep "actions/artifacts/9001/zip" "$support/gh.log" &&
		test_grep ".github/workflows/codex.yml@meta" \
			"$support/gh.log" &&
		test_grep "refs/heads/meta" "$support/gh.log" &&
		test_grep "actions/workflows/main.yml/runs?branch=codex-staging&event=push&head_sha=$candidate&per_page=100" \
			"$support/gh.log" &&
		test_grep "actions/runs/101/jobs" "$support/gh.log" &&
		! grep -F -- "--slurp" "$support/gh.log" &&
		! grep -F "rewrite state is missing" "$support/publish.err" &&
		grep -F "Staging CI run 101: https://example/ci/101" \
			"$support/publish.out" >"$support/staging-url" &&
		test_line_count = 1 "$support/staging-url" &&
		grep -F "Staging CI: queued (0/2 jobs complete; 0 failed)" \
			"$support/publish.out" >"$support/staging-queued" &&
		test_line_count = 1 "$support/staging-queued" &&
		grep -F "Staging CI: in_progress (1/2 jobs complete; 0 failed)" \
			"$support/publish.out" >"$support/staging-one" &&
		test_line_count = 1 "$support/staging-one" &&
		grep -F "Staging CI: in_progress (2/2 jobs complete; 0 failed)" \
			"$support/publish.out" >"$support/staging-two" &&
		test_line_count = 1 "$support/staging-two" &&
		grep -F "Staging CI: success (2/2 jobs complete; 0 failed): https://example/ci/101" \
			"$support/publish.out" >"$support/staging-success" &&
		test_line_count = 1 "$support/staging-success" &&
		test_grep "Full staging CI passed." "$support/publish.out" &&
		while IFS="$(printf "\t")" read -r ref old new
		do
			test "$new" = "$(git --git-dir=../publish-run.git \
				rev-parse "$ref")" || return 1
		done <"$support/codex-updates" &&
		test_must_fail git --git-dir=../publish-run.git show-ref --verify \
			refs/heads/codex-staging &&

		# Local preparation must use its isolated repository, not the
		# rerere cache, hooks, temporary refs, or ZIP tooling in the
		# publisher clone.
		# Advance master only on the remote so it also has to import
		# a genuinely new candidate from the local bundle.
		git fetch --force origin \
			"+refs/heads/meta:refs/remotes/origin/meta" &&
		git -C Meta -c advice.detachedHead=false switch --detach \
			refs/remotes/origin/meta &&
		(
			cd ../publish-run-source &&
			git switch master &&
			write advanced local-master-update &&
			git add local-master-update &&
			git commit -m "advance master for local preparation" &&
			git push origin master
		) &&
		advanced_master=$(git --git-dir=../publish-run.git \
			rev-parse refs/heads/master) &&
		snapshot_refs ../publish-run.git >"$support/before-local" &&
		common_dir=$(git rev-parse --path-format=absolute \
			--git-common-dir) &&
		mkdir -p "$common_dir/rr-cache" "$support/hooks" &&
		write preserved "$common_dir/rr-cache/publisher-sentinel" &&
		cp "$common_dir/rr-cache/publisher-sentinel" \
			"$support/publisher-sentinel.before" &&
		cat >"$support/hooks/post-checkout" <<-\EOF &&
		#!/bin/sh
		: >"$FAKE_HOOK_MARKER"
		exit 89
		EOF
		chmod +x "$support/hooks/post-checkout" &&
		cat >"$support/bin/unzip" <<-\EOF &&
		#!/bin/sh
		: >"$FAKE_ZIP_MARKER"
		exit 89
		EOF
		cp "$support/bin/unzip" "$support/bin/zipinfo" &&
		chmod +x "$support/bin/unzip" "$support/bin/zipinfo" &&
		rm -f "$support/bundle-absent" \
			"$support/bundle-imported" \
			"$support/inherited-hook-ran" \
			"$support/zip-tool-ran" &&
		: >"$support/gh.log" &&
		FAKE_DYNAMIC_CANDIDATE=1 \
		FAKE_ASSERT_BUNDLE_IMPORT=1 \
		FAKE_GIT_CONFIG_COUNT=1 \
		FAKE_ZIP_MARKER="$support/zip-tool-ran" \
			run_prepared "$support/good.zip" rebuild --local \
			>"$support/local.out" 2>"$support/local.err" &&
		local_candidate=$(git --git-dir=../publish-run.git \
			rev-parse refs/heads/codex) &&
		test "$local_candidate" != "$candidate" &&
		test "$advanced_master" = "$(git --git-dir=../publish-run.git \
			rev-parse refs/heads/master)" &&
		test_grep "Local preparation session:" "$support/local.out" &&
		test_grep "Published codex candidate $local_candidate from local preparation session" \
			"$support/local.out" &&
		! grep -F "Refresh codex run" "$support/local.out" &&
		! grep -F "actions/workflows/codex.yml/dispatches" \
			"$support/gh.log" &&
		! grep -F "/artifacts" "$support/gh.log" &&
		test_grep "actions/workflows/main.yml/runs?branch=codex-staging&event=push&head_sha=$local_candidate" \
			"$support/gh.log" &&
		test_grep "actions/runs/101/jobs" "$support/gh.log" &&
		test "$local_candidate" = "$(cat "$support/bundle-absent")" &&
		test_path_is_file "$support/bundle-imported" &&
		test_path_is_missing "$support/inherited-hook-ran" &&
		test_path_is_missing "$support/zip-tool-ran" &&
		test_cmp "$support/publisher-sentinel.before" \
			"$common_dir/rr-cache/publisher-sentinel" &&
		local_session=$(sed -n \
			"s/^Local preparation session: //p" \
			"$support/local.out") &&
		test -n "$local_session" &&
		test_line_count = 1 "$support/bundle-absent" &&
		for name in codex.bundle codex-candidate codex-inputs codex-updates
		do
			test_path_is_file "$local_session/$name" || return 1
		done &&
		test_path_is_missing "$local_session/codex-run" &&
		while IFS="$(printf "\t")" read -r ref old new
		do
			test "$new" = "$(git --git-dir=../publish-run.git \
				rev-parse "$ref")" || return 1
		done <"$local_session/codex-updates" &&
		test_must_fail git show-ref --verify \
			refs/codex-output/candidate &&
		test_must_fail git show-ref --verify refs/codex-output/meta &&
		test_must_fail git --git-dir=../publish-run.git show-ref --verify \
			refs/heads/codex-staging
	)
'

test_expect_success 'unstable rules require one app-authenticated queue entry' '
	rules="$codex_root/.github/rulesets/codex-unstable-branch.json" &&
	test_path_is_file "$rules" &&
	jq -e "
		(.conditions.ref_name.include == [\"refs/heads/codex-unstable\"]) and
		(.rules[] | select(.type == \"merge_queue\") |
		 .parameters.merge_method == \"MERGE\" and
		 .parameters.grouping_strategy == \"ALLGREEN\" and
		 .parameters.max_entries_to_build == 1 and
		 .parameters.max_entries_to_merge == 1 and
		 .parameters.min_entries_to_merge == 1) and
		(.rules[] | select(.type == \"required_status_checks\") |
		 .parameters.required_status_checks == [{
		   \"context\": \"Codex unstable admission / Verify reviewed topic\",
		   \"integration_id\": 15368
		 }])
	" "$rules" &&
	test_grep "codex-unstable.output-tip" "$codex_admission_workflow" &&
	test_grep "codex-unstable.base-tip" "$codex_admission_workflow"
'

test_expect_success 'unstable admission executes both lane-specific checks' '
	install_admission_gate_gh "$TRASH_DIRECTORY/admission-gate-bin" &&
	sed -n "/^        run: |\$/,/^        [^ ]/p" \
		"$codex_admission_workflow" |
	sed "1d; s/^          //" >"$TRASH_DIRECTORY/admission-gate.sh" &&
	run_admission_gate success pull_request \
		bb/codex/reviewed-unstable codex-unstable >unstable-pull.out &&
	test_grep "Approved pull request #42" unstable-pull.out &&
	run_admission_gate success merge_group \
		bb/codex/reviewed-unstable codex-unstable >unstable-queue.out &&
	test_grep "Approved pull request #42" unstable-queue.out &&
	run_admission_gate descendant-checkpoint merge_group \
		bb/codex/reviewed-unstable codex-unstable \
		>unstable-descendant-queue.out &&
	test_grep "Approved pull request #42" \
		unstable-descendant-queue.out &&
	for mode in pending wrong-parent unapproved multiple-pulls \
		changed-topic changed-workflow hidden-prerequisite
	do
		test_expect_code 1 run_admission_gate "$mode" merge_group \
			bb/codex/reviewed-unstable codex-unstable \
			>"unstable-$mode.out" 2>"unstable-$mode.err" || return 1
	done &&
	test_expect_code 1 run_admission_gate success pull_request \
		bb/codex/reviewed codex-unstable \
		>stable-in-unstable.out 2>stable-in-unstable.err &&
	test_grep "unstable" stable-in-unstable.err
'

test_expect_success 'unadmitted unstable checkpoints leave v1 output unchanged' '
	setup_pending_admission inert-unstable-checkpoints &&
	enrolled=$(git --git-dir=inert-unstable-checkpoints.git \
		rev-parse refs/heads/aa/codex/enrolled) &&
	git --git-dir=inert-unstable-checkpoints.git update-ref \
		refs/heads/codex "$enrolled" &&
	(
		cd inert-unstable-checkpoints-runner &&
		fetch_all &&
		admission_rewrite inert-unstable-checkpoints api-failure &&
		apply_test_updates origin updates &&
		fetch_all &&
		stable=$(git rev-parse origin/codex) &&
		meta=$(git rev-parse origin/meta) &&
		(
			cd ../inert-unstable-checkpoints-source &&
			git switch -c tb/codex/status-part-01-unstable master &&
			write one status-one &&
			git add status-one &&
			git commit -m "unreviewed status checkpoint one" &&
			git switch -c tb/codex/status-part-02-unstable &&
			write two status-two &&
			git add status-two &&
			git commit -m "unreviewed status checkpoint two" &&
			git switch -c tb/codex/status-part-03-unstable master &&
			write three status-three &&
			git add status-three &&
			git commit -m "unreviewed parallel status checkpoint" &&
			git push origin tb/codex/status-part-01-unstable \
				tb/codex/status-part-02-unstable \
				tb/codex/status-part-03-unstable
		) &&
		fetch_all &&
		: >"$TRASH_DIRECTORY/inert-unstable-checkpoints-gh.log" &&
		snapshot_refs ../inert-unstable-checkpoints.git >before &&
		CODEX_UNSTABLE_MODE=enable \
			admission_rewrite inert-unstable-checkpoints api-failure &&
		test "$stable" = "$(cat result)" &&
		test "$meta" = "$(updated_tip meta updates)" &&
		! grep -F -- "-unstable" inputs &&
		! grep -F -- "-unstable" updates &&
		test_must_be_empty \
			"$TRASH_DIRECTORY/inert-unstable-checkpoints-gh.log" &&
		snapshot_refs ../inert-unstable-checkpoints.git >after &&
		test_cmp before after
	)
'

test_expect_success 'enabling unstable creates a strict empty sentinel' '
	setup_pending_admission enable-unstable &&
	enrolled=$(git --git-dir=enable-unstable.git \
		rev-parse refs/heads/aa/codex/enrolled) &&
	git --git-dir=enable-unstable.git update-ref \
		refs/heads/codex "$enrolled" &&
	(
		cd enable-unstable-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex \
			--result stable.result --updates stable.updates \
			--inputs stable.inputs --failure stable.failure &&
		apply_test_updates origin stable.updates &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --enable-unstable \
			--result result --updates updates --inputs inputs \
			--bundle candidate.bundle --failure failure &&
		stable=$(cat result) &&
		unstable=$(updated_tip codex-unstable updates) &&
		meta=$(updated_tip meta updates) &&
		test -n "$unstable" &&
		test "$stable" != "$unstable" &&
		test "$stable" = "$(git rev-parse "$unstable^")" &&
		test "$(git rev-parse "$stable^{tree}")" = \
			"$(git rev-parse "$unstable^{tree}")" &&
		test "Initialize codex-unstable" = \
			"$(git show -s --format=%s "$unstable")" &&
		has_codex_bot_author "$unstable" &&
		has_codex_bot_committer "$unstable" &&
		git show "$meta:codex.config" >enabled.config &&
		test 2 = "$(git config -f enabled.config --get codex.version)" &&
		test "$stable" = "$(git config -f enabled.config \
			--get codex-unstable.base-tip)" &&
		test "$unstable" = "$(git config -f enabled.config \
			--get codex-unstable.output-tip)" &&
		! grep -F -- "-unstable\"]" enabled.config &&
		sh "$codex_branch" verify-output \
			--inputs inputs --updates updates --result result &&
		git bundle verify candidate.bundle &&
		git bundle list-heads candidate.bundle >bundle-heads &&
		test_grep "refs/codex-output/unstable" bundle-heads &&
		sh "$codex_branch" stage --remote origin \
			--staging codex-staging \
			--inputs inputs --updates updates &&
		sh "$codex_branch" stage --remote origin \
			--staging codex-unstable-staging \
			--inputs inputs --updates updates &&
		GIT_TRACE=1 sh "$codex_branch" promote --remote origin \
			--staging codex-staging \
			--inputs inputs --updates updates \
			>promote.out 2>promote.trace &&
		test_grep "push --atomic --porcelain" promote.trace &&
		test "$stable" = \
			"$(git --git-dir=../enable-unstable.git \
				rev-parse refs/heads/codex)" &&
		test "$unstable" = \
			"$(git --git-dir=../enable-unstable.git \
				rev-parse refs/heads/codex-unstable)" &&
		test "$meta" = \
			"$(git --git-dir=../enable-unstable.git \
				rev-parse refs/heads/meta)" &&
		test_must_fail git --git-dir=../enable-unstable.git \
			show-ref --verify refs/heads/codex-staging &&
		test_must_fail git --git-dir=../enable-unstable.git \
			show-ref --verify refs/heads/codex-unstable-staging &&
		snapshot_refs ../enable-unstable.git >published &&
		GIT_TRACE=1 sh "$codex_branch" promote --remote origin \
			--staging codex-staging \
			--inputs inputs --updates updates \
			>retry.out 2>retry.trace &&
		! grep -F "push --atomic" retry.trace &&
		snapshot_refs ../enable-unstable.git >retried &&
		test_cmp published retried &&
		git --git-dir=../enable-unstable.git update-ref \
			refs/heads/codex-unstable "$stable" "$unstable" &&
		snapshot_refs ../enable-unstable.git >partial &&
		test_expect_code 1 sh "$codex_branch" promote --remote origin \
			--staging codex-staging \
			--inputs inputs --updates updates \
			>partial.out 2>partial.err &&
		snapshot_refs ../enable-unstable.git >after-partial &&
		test_cmp partial after-partial
	)
'

test_expect_success 'an empty unstable sentinel stays strict across rebuilds' '
	setup_pending_unstable empty-unstable \
		bb/codex/reviewed-unstable sentinel &&
	(
		cd empty-unstable-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex \
			--result result --updates updates --inputs inputs \
			--failure failure &&
		stable=$(cat result) &&
		unstable=$(updated_tip codex-unstable updates) &&
		test "$stable" != "$unstable" &&
		test "$stable" = "$(git rev-parse "$unstable^")" &&
		test "$(git rev-parse "$stable^{tree}")" = \
			"$(git rev-parse "$unstable^{tree}")" &&
		git show "$(updated_tip meta updates):codex.config" \
			>next.config &&
		! grep -F -- "-unstable\"]" next.config
	)
'

test_expect_success 'a reviewed unstable merge enrolls only its retained head' '
	setup_pending_unstable reviewed-unstable &&
	(
		cd reviewed-unstable-runner &&
		fetch_all &&
		unstable_admission_rewrite reviewed-unstable success &&
		stable=$(cat result) &&
		unstable=$(updated_tip codex-unstable updates) &&
		topic=$(updated_tip bb/codex/reviewed-unstable updates) &&
		meta=$(updated_tip meta updates) &&
		test -n "$unstable" &&
		git merge-base --is-ancestor "$stable" "$unstable" &&
		test_must_fail git cat-file -e "$stable:reviewed-unstable-file" &&
		test reviewed = "$(git show "$unstable:reviewed-unstable-file")" &&
		git show "$meta:codex.config" >next.config &&
		test "$topic" = "$(git config -f next.config \
			--get branch.bb/codex/reviewed-unstable.codex-tip)" &&
		test refs/heads/codex = "$(git config -f next.config \
			--get branch.bb/codex/reviewed-unstable.merge)" &&
		awk -F "$(printf "\t")" '\''
			$1 == "unstable-admission" &&
			$2 == "refs/heads/bb/codex/reviewed-unstable" &&
			$4 == 42 { found=1 }
			END { exit !found }
		'\'' inputs &&
		test_grep pulls "$TRASH_DIRECTORY/reviewed-unstable-gh.log" &&
		test_grep reviews "$TRASH_DIRECTORY/reviewed-unstable-gh.log" &&
		ADMISSION_BASE=codex-unstable \
		ADMISSION_TOPIC=bb/codex/reviewed-unstable \
			admission_command reviewed-unstable success \
				verify-output --inputs inputs --updates updates \
				--result result
	)
'

test_expect_success 'an unstable admission rejects wrong lane or provenance' '
	setup_pending_unstable unstable-provenance &&
	(
		cd unstable-provenance-runner &&
		fetch_all &&
		snapshot_refs ../unstable-provenance.git >before &&
		for mode in no-pull-request wrong-merge wrong-base \
			wrong-base-repository wrong-head-repository wrong-head-ref \
			wrong-head draft-pull-request duplicate-pull-request \
			open-pull-request unmerged-pull-request api-failure
		do
			test_expect_code 1 \
				unstable_admission_rewrite unstable-provenance "$mode" \
				>"$mode.out" 2>"$mode.err" || return 1
		done &&
		snapshot_refs ../unstable-provenance.git >after &&
		test_cmp before after
	)
'

test_expect_success 'an unstable admission requires a current trusted review' '
	setup_pending_unstable unstable-review &&
	(
		cd unstable-review-runner &&
		fetch_all &&
		for mode in no-review outsider-review self-review stale-review \
			rejected-review revoked-review dismissed-review \
			review-api-failure
		do
			test_expect_code 1 \
				unstable_admission_rewrite unstable-review "$mode" \
				>"$mode.out" 2>"$mode.err" || return 1
		done &&
		unstable_admission_rewrite unstable-review commented-review
	)
'

test_expect_success 'a squash cannot enroll an unstable preview' '
	setup_pending_unstable unstable-squash \
		bb/codex/reviewed-unstable squash &&
	(
		cd unstable-squash-runner &&
		fetch_all &&
		test_expect_code 1 \
			unstable_admission_rewrite unstable-squash success \
			>rewrite.out 2>rewrite.err &&
		test_grep "normal two-parent merge" rewrite.err
	)
'

test_expect_success 'an unadmitted unstable descendant remains inert' '
	setup_pending_unstable unstable-descendant &&
	(
		cd unstable-descendant-source &&
		git switch -c cc/codex/checkpoint-unstable \
			bb/codex/reviewed-unstable &&
		write unreviewed checkpoint-file &&
		git add checkpoint-file &&
		git commit -m "unreviewed descendant checkpoint" &&
		git push origin cc/codex/checkpoint-unstable
	) &&
	(
		cd unstable-descendant-runner &&
		fetch_all &&
		unstable_admission_rewrite unstable-descendant success &&
		unstable=$(updated_tip codex-unstable updates) &&
		test reviewed = "$(git show "$unstable:reviewed-unstable-file")" &&
		test_must_fail git cat-file -e "$unstable:checkpoint-file" &&
		! grep -F "cc/codex/checkpoint-unstable" updates &&
		! grep -F "cc/codex/checkpoint-unstable" inputs
	)
'

test_expect_success 'disabling an empty unstable lane removes it atomically' '
	setup_pending_unstable disable-empty-unstable \
		bb/codex/reviewed-unstable sentinel &&
	(
		cd disable-empty-unstable-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex \
			--result stable.result --updates stable.updates \
			--inputs stable.inputs --failure stable.failure &&
		apply_test_updates origin stable.updates &&
		fetch_all &&
		old=$(git rev-parse origin/codex-unstable) &&
		git --git-dir=../disable-empty-unstable.git update-ref \
			refs/heads/codex-unstable-staging "$old" &&
		zero=$(printf "%s\n" "$old" | tr "0123456789abcdef" 0) &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --disable-unstable \
			--result result --updates updates --inputs inputs \
			--failure failure &&
		test "$zero" = "$(updated_tip codex-unstable updates)" &&
		meta=$(updated_tip meta updates) &&
		git show "$meta:codex.config" >disabled.config &&
		test 1 = "$(git config -f disabled.config --get codex.version)" &&
		test_must_fail git config -f disabled.config \
			--get codex-unstable.output-tip &&
		sh "$codex_branch" verify-output \
			--inputs inputs --updates updates --result result &&
		sh "$codex_branch" stage \
			--remote origin --staging codex-staging \
			--inputs inputs --updates updates &&
		race_ref=refs/heads/codex-unstable-staging &&
		race_new=$(git rev-parse origin/master) &&
		test "$race_new" != "$old" &&
		real_git=$(command -v git) &&
		remote_git=$PWD/../disable-empty-unstable.git &&
		mkdir stale-preview-race-bin &&
		write "#!/bin/sh
case \" \$* \" in
*\" push \"*)
	\"$real_git\" --git-dir=\"$remote_git\" update-ref \\
		\"$race_ref\" \"$race_new\" \"$old\" || exit
	;;
esac
exec \"$real_git\" \"\$@\"" stale-preview-race-bin/git &&
		chmod +x stale-preview-race-bin/git &&
		snapshot_without_staging ../disable-empty-unstable.git \
			>before-stage-race &&
		test_expect_code 1 env PATH="$PWD/stale-preview-race-bin:$PATH" \
			sh "$codex_branch" promote \
				--remote origin --staging codex-staging \
				--inputs inputs --updates updates \
				>race.out 2>race.err &&
		test "$race_new" = \
			"$(git --git-dir=../disable-empty-unstable.git \
				rev-parse "$race_ref")" &&
		snapshot_without_staging ../disable-empty-unstable.git \
			>after-stage-race &&
		test_cmp before-stage-race after-stage-race &&
		git --git-dir=../disable-empty-unstable.git update-ref \
			"$race_ref" "$old" "$race_new" &&
		GIT_TRACE=1 sh "$codex_branch" promote \
			--remote origin --staging codex-staging \
			--inputs inputs --updates updates \
			>promote.out 2>promote.trace &&
		test_grep "push --atomic --porcelain" promote.trace &&
		test_grep \
			"force-with-lease=refs/heads/codex-unstable-staging:$old" \
			promote.trace &&
		test_grep ":refs/heads/codex-unstable-staging" promote.trace &&
		test_must_fail git --git-dir=../disable-empty-unstable.git \
			show-ref --verify refs/heads/codex-unstable &&
		test_must_fail git --git-dir=../disable-empty-unstable.git \
			show-ref --verify refs/heads/codex-unstable-staging &&
		test_must_fail git --git-dir=../disable-empty-unstable.git \
			show-ref --verify refs/heads/codex-staging
	)
'

test_expect_success 'disabling an enrolled unstable lane fails closed' '
	setup_pending_unstable disable-enrolled-unstable &&
	(
		cd disable-enrolled-unstable-runner &&
		fetch_all &&
		unstable_admission_rewrite disable-enrolled-unstable success &&
		apply_test_updates origin updates &&
		fetch_all &&
		snapshot_refs ../disable-enrolled-unstable.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --disable-unstable \
			--result disabled.result --updates disabled.updates \
			--inputs disabled.inputs --failure disabled.failure \
			>disabled.out 2>disabled.err &&
		test_grep "unstable" disabled.err &&
		snapshot_refs ../disable-enrolled-unstable.git >after &&
		test_cmp before after
	)
'

test_expect_success 'preview lane transitions require unchanged stable output' '
	setup_pending_admission dirty-unstable-enable &&
	(
		cd dirty-unstable-enable-runner &&
		fetch_all &&
		snapshot_refs ../dirty-unstable-enable.git >before &&
		test_expect_code 1 \
			admission_command dirty-unstable-enable success \
				rewrite --remote origin --base master --codex codex \
				--enable-unstable --result result --updates updates \
				--inputs inputs --failure failure \
				>enable.out 2>enable.err &&
		test_grep "stable\|codex" enable.err &&
		snapshot_refs ../dirty-unstable-enable.git >after &&
		test_cmp before after
	) &&

	setup_pending_unstable dirty-unstable-disable \
		bb/codex/reviewed-unstable sentinel &&
	(
		cd dirty-unstable-disable-source &&
		git switch aa/codex/enrolled &&
		write changed changed-stable-file &&
		git add changed-stable-file &&
		git commit -m "advance enrolled stable topic" &&
		git push origin aa/codex/enrolled
	) &&
	(
		cd dirty-unstable-disable-runner &&
		fetch_all &&
		snapshot_refs ../dirty-unstable-disable.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --disable-unstable \
			--result result --updates updates --inputs inputs \
			--failure failure >disable.out 2>disable.err &&
		test_grep "stable\|codex" disable.err &&
		snapshot_refs ../dirty-unstable-disable.git >after &&
		test_cmp before after
	)
'

test_expect_success 'an empty unstable sentinel cannot impersonate its bot' '
	setup_pending_unstable forged-unstable-sentinel \
		bb/codex/reviewed-unstable sentinel &&
	(
		cd forged-unstable-sentinel-source &&
		stable=$(git rev-parse codex) &&
		forged=$(
			GIT_AUTHOR_NAME="Untrusted Author" \
			GIT_AUTHOR_EMAIL=author@example.com \
			GIT_COMMITTER_NAME="Untrusted Committer" \
			GIT_COMMITTER_EMAIL=committer@example.com \
			git commit-tree "$stable^{tree}" -p "$stable" \
				-m "Initialize codex-unstable"
		) &&
		git update-ref refs/heads/codex-unstable "$forged" &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git push --force origin meta codex-unstable
	) &&
	(
		cd forged-unstable-sentinel-runner &&
		fetch_all &&
		snapshot_refs ../forged-unstable-sentinel.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex \
			--result result --updates updates --inputs inputs \
			--failure failure >rewrite.out 2>rewrite.err &&
		test_grep "sentinel\|unstable" rewrite.err &&
		test_path_is_missing result &&
		snapshot_refs ../forged-unstable-sentinel.git >after &&
		test_cmp before after
	)
'

test_expect_success 'a v2 snapshot cannot silently erase its preview lane' '
	setup_pending_unstable missing-unstable-snapshot \
		bb/codex/reviewed-unstable sentinel &&
	(
		cd missing-unstable-snapshot-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex \
			--result result --updates updates --inputs inputs \
			--failure failure &&
		awk -F "$(printf "\t")" '\''$1 != "unstable"'\'' \
			inputs >missing.inputs &&
		test_expect_code 1 sh "$codex_branch" verify-output \
			--inputs missing.inputs --updates updates --result result \
			>verify.out 2>verify.err &&
		test_grep "unstable\|snapshot" verify.err
	)
'

test_expect_success 'stable conflict recovery preserves an enabled preview lane' '
	git init --bare unstable-stable-recovery.git &&
	test_create_repo unstable-stable-recovery-source &&
	(
		cd unstable-stable-recovery-source &&
		git remote add origin ../unstable-stable-recovery.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git switch -c aa/codex/stable master &&
		write topic shared &&
		git add shared &&
		git commit -m "conflicting enrolled stable topic" &&
		git branch codex &&
		create_unstable_sentinel codex &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git switch master &&
		write upstream shared &&
		git add shared &&
		git commit -m "conflicting upstream base" &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable
	) &&

	git clone unstable-stable-recovery.git \
		unstable-stable-recovery-runner &&
	(
		cd unstable-stable-recovery-runner &&
		fetch_all &&
		stable=$(git rev-parse origin/codex) &&
		unstable=$(git rev-parse origin/codex-unstable) &&
		meta=$(git rev-parse origin/meta) &&
		old_topic=$(git rev-parse origin/aa/codex/stable) &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex \
			--result result --updates updates --inputs inputs \
			--failure failure >rewrite.out 2>rewrite.err &&
		test_grep "aa/codex/stable" failure &&
		digest=$(git hash-object inputs) &&
		sh "$codex_branch" resolve --remote origin \
			--base master --codex codex --inputs-oid "$digest" \
			--worktree resolution >resolve.out &&
		write resolved resolution/shared &&
		git -C resolution add shared &&
		sh "$codex_branch" continue --worktree resolution \
			>continue.out &&
		sh "$codex_branch" publish-topics --worktree resolution &&
		new_topic=$(git --git-dir=../unstable-stable-recovery.git \
			rev-parse refs/heads/aa/codex/stable) &&
		test "$old_topic" != "$new_topic" &&
		test resolved = "$(git show "$new_topic:shared")" &&
		test "$stable" = \
			"$(git --git-dir=../unstable-stable-recovery.git \
				rev-parse refs/heads/codex)" &&
		test "$unstable" = \
			"$(git --git-dir=../unstable-stable-recovery.git \
				rev-parse refs/heads/codex-unstable)" &&
		test "$meta" = \
			"$(git --git-dir=../unstable-stable-recovery.git \
				rev-parse refs/heads/meta)" &&
		git worktree remove --force resolution
	)
'

test_expect_success 'unstable parent rewrites replace old history when codex advances' '
	git init --bare unstable-parent.git &&
	test_create_repo unstable-parent-source &&
	(
		cd unstable-parent-source &&
		git remote add origin ../unstable-parent.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git switch -c bb/codex/parent-unstable codex &&
		write old unstable-old-parent-file &&
		git add unstable-old-parent-file &&
		git commit -m "old unstable parent" &&
		git switch -c cc/codex/child-unstable &&
		write child unstable-child-file &&
		git add unstable-child-file &&
		git commit -m "preserved unstable child" &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&

		git switch --detach codex &&
		write replacement unstable-new-parent-file &&
		git add unstable-new-parent-file &&
		git commit -m "replacement unstable parent" &&
		git branch -f bb/codex/parent-unstable HEAD &&
		git switch master &&
		write advanced unstable-advanced-base-file &&
		git add unstable-advanced-base-file &&
		git commit -m "advance codex underneath unstable topics" &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable bb/codex/parent-unstable \
			cc/codex/child-unstable
	) &&

	git clone unstable-parent.git unstable-parent-runner &&
	(
		cd unstable-parent-runner &&
		fetch_all &&
		old_stable=$(git rev-parse origin/codex) &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --bundle candidate.bundle \
			--failure failure &&
		stable=$(cat result) &&
		unstable=$(updated_tip codex-unstable updates) &&
		parent=$(updated_tip bb/codex/parent-unstable updates) &&
		child=$(updated_tip cc/codex/child-unstable updates) &&
		test "$old_stable" != "$stable" &&
		test "$stable" = "$(git rev-parse "$parent^")" &&
		test "$parent" = "$(git rev-parse "$child^")" &&
		test advanced = "$(git show "$unstable:unstable-advanced-base-file")" &&
		test replacement = "$(git show "$unstable:unstable-new-parent-file")" &&
		test child = "$(git show "$unstable:unstable-child-file")" &&
		test_must_fail git cat-file -e \
			"$unstable:unstable-old-parent-file" &&
		git log --format=%s "$stable..$child" >subjects &&
		test_grep "^replacement unstable parent$" subjects &&
		! grep -q "^old unstable parent$" subjects &&
		git merge-base --is-ancestor "$stable" "$unstable"
	)
'

test_expect_success 'rewinding an unstable parent does not leak its removed commit' '
	git init --bare unstable-rewind.git &&
	test_create_repo unstable-rewind-source &&
	(
		cd unstable-rewind-source &&
		git remote add origin ../unstable-rewind.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git switch -c bb/codex/parent-unstable codex &&
		write kept unstable-kept-file &&
		git add unstable-kept-file &&
		git commit -m "kept unstable parent commit" &&
		kept=$(git rev-parse HEAD) &&
		write removed unstable-removed-file &&
		git add unstable-removed-file &&
		git commit -m "removed unstable parent commit" &&
		git switch -c cc/codex/child-unstable &&
		write child unstable-child-file &&
		git add unstable-child-file &&
		git commit -m "unstable child after rewind" &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git branch -f bb/codex/parent-unstable "$kept" &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable bb/codex/parent-unstable \
			cc/codex/child-unstable
	) &&

	git clone unstable-rewind.git unstable-rewind-runner &&
	(
		cd unstable-rewind-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --bundle candidate.bundle \
			--failure failure &&
		stable=$(cat result) &&
		parent=$(updated_tip bb/codex/parent-unstable updates) &&
		child=$(updated_tip cc/codex/child-unstable updates) &&
		unstable=$(updated_tip codex-unstable updates) &&
		test "$stable" = "$(git rev-parse "$parent^")" &&
		test "$parent" = "$(git rev-parse "$child^")" &&
		test kept = "$(git show "$unstable:unstable-kept-file")" &&
		test child = "$(git show "$unstable:unstable-child-file")" &&
		test_must_fail git cat-file -e \
			"$unstable:unstable-removed-file" &&
		git log --format=%s "$stable..$child" >subjects &&
		! grep -q "^removed unstable parent commit$" subjects &&
		git bundle verify candidate.bundle &&
		git bundle list-heads candidate.bundle >bundle-heads &&
		test_grep "refs/codex-output/candidate" bundle-heads &&
		test_grep "refs/codex-output/unstable" bundle-heads &&
		git clone ../unstable-rewind.git ../unstable-rewind-import &&
		git -C ../unstable-rewind-import bundle unbundle \
			"$PWD/candidate.bundle" >imported-heads &&
		test_grep "refs/codex-output/candidate" imported-heads &&
		test_grep "refs/codex-output/unstable" imported-heads &&
		git -C ../unstable-rewind-import cat-file -e \
			"$unstable^{commit}"
	)
'

test_expect_success 'a coherent unstable restack can reverse topic dependencies' '
	git init --bare unstable-reorder.git &&
	test_create_repo unstable-reorder-source &&
	(
		cd unstable-reorder-source &&
		git remote add origin ../unstable-reorder.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git switch -c bb/codex/a-unstable codex &&
		write A unstable-a-file &&
		git add unstable-a-file &&
		git commit -m "unstable dependency A" &&
		old_a=$(git rev-parse HEAD) &&
		git switch -c cc/codex/b-unstable &&
		write B unstable-b-file &&
		git add unstable-b-file &&
		git commit -m "unstable dependency B" &&
		old_b=$(git rev-parse HEAD) &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&

		git switch --detach codex &&
		git cherry-pick "$old_b" &&
		new_b=$(git rev-parse HEAD) &&
		git branch -f cc/codex/b-unstable "$new_b" &&
		git cherry-pick "$old_a" &&
		git branch -f bb/codex/a-unstable HEAD &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable bb/codex/a-unstable \
			cc/codex/b-unstable
	) &&

	git clone unstable-reorder.git unstable-reorder-runner &&
	(
		cd unstable-reorder-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		stable=$(cat result) &&
		a=$(updated_tip bb/codex/a-unstable updates) &&
		b=$(updated_tip cc/codex/b-unstable updates) &&
		unstable=$(updated_tip codex-unstable updates) &&
		meta=$(updated_tip meta updates) &&
		test "$stable" = "$(git rev-parse "$b^")" &&
		test "$b" = "$(git rev-parse "$a^")" &&
		git show "$meta:codex.config" >next.config &&
		test refs/heads/codex = "$(git config -f next.config \
			--get branch.cc/codex/b-unstable.merge)" &&
		test refs/heads/cc/codex/b-unstable = \
			"$(git config -f next.config \
			--get branch.bb/codex/a-unstable.merge)" &&
		git rev-list --first-parent --reverse "$stable..$unstable" \
			>integrations &&
		first=$(sed -n 1p integrations) &&
		second=$(sed -n 2p integrations) &&
		test "Merge cc/codex/b-unstable into codex-unstable" = \
			"$(git show -s --format=%s "$first")" &&
		test "Merge bb/codex/a-unstable into codex-unstable" = \
			"$(git show -s --format=%s "$second")"
	)
'

test_expect_success 'removing an unstable prerequisite with a stale child fails closed' '
	git init --bare unstable-retired-parent.git &&
	test_create_repo unstable-retired-parent-source &&
	(
		cd unstable-retired-parent-source &&
		git remote add origin ../unstable-retired-parent.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git switch -c bb/codex/parent-unstable codex &&
		write parent unstable-parent-file &&
		git add unstable-parent-file &&
		git commit -m "retired unstable prerequisite" &&
		git switch -c cc/codex/child-unstable &&
		write child unstable-child-file &&
		git add unstable-child-file &&
		git commit -m "stale unstable child" &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable cc/codex/child-unstable
	) &&

	git clone unstable-retired-parent.git unstable-retired-parent-runner &&
	(
		cd unstable-retired-parent-runner &&
		fetch_all &&
		snapshot_refs ../unstable-retired-parent.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			>out 2>err &&
		test_grep "prerequisite.*retired" err &&
		test_path_is_missing result &&
		snapshot_refs ../unstable-retired-parent.git >after &&
		test_cmp before after
	)
'

test_expect_success 'unstable topics can be combined and split into a new prerequisite' '
	git init --bare unstable-combine.git &&
	test_create_repo unstable-combine-source &&
	(
		cd unstable-combine-source &&
		git remote add origin ../unstable-combine.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git switch -c bb/codex/parent-unstable codex &&
		write parent unstable-parent-file &&
		git add unstable-parent-file &&
		git commit -m "original unstable parent" &&
		old_parent=$(git rev-parse HEAD) &&
		git switch -c cc/codex/child-unstable &&
		write child unstable-child-file &&
		git add unstable-child-file &&
		git commit -m "original unstable child" &&
		old_child=$(git rev-parse HEAD) &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&

		git switch --detach codex &&
		git cherry-pick --no-commit "$old_parent" &&
		git commit -m "combined unstable prefix" &&
		git cherry-pick --no-commit "$old_child" &&
		git commit -m "combined unstable suffix" &&
		git branch -f cc/codex/child-unstable HEAD &&
		git branch -D bb/codex/parent-unstable &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable cc/codex/child-unstable
	) &&

	git clone unstable-combine.git unstable-combine-runner &&
	(
		cd unstable-combine-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		combined=$(updated_tip cc/codex/child-unstable updates) &&
		meta=$(updated_tip meta updates) &&
		git show "$meta:codex.config" >combined.config &&
		test refs/heads/codex = "$(git config -f combined.config \
			--get branch.cc/codex/child-unstable.merge)" &&
		test_must_fail git config -f combined.config \
			--get branch.bb/codex/parent-unstable.codex-tip &&
		test parent = "$(git show "$combined:unstable-parent-file")" &&
		test child = "$(git show "$combined:unstable-child-file")" &&
		apply_test_updates origin updates &&
		fetch_all &&

		prefix=$(git rev-parse \
			"origin/cc/codex/child-unstable^") &&
		git branch bb/codex/prefix-unstable "$prefix" &&
		git push origin bb/codex/prefix-unstable &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result ignored-result \
			--updates ignored-updates --inputs ignored-inputs \
			--failure ignored-failure &&
		test -z "$(updated_tip bb/codex/prefix-unstable \
			ignored-updates)" &&
		ignored_meta=$(updated_tip meta ignored-updates) &&
		git show "$ignored_meta:codex.config" >ignored.config &&
		test_must_fail git config -f ignored.config \
			--get branch.bb/codex/prefix-unstable.codex-tip &&

		old_child=$(git rev-parse origin/cc/codex/child-unstable) &&
		git switch bb/codex/prefix-unstable &&
		write reviewed unstable-reviewed-prefix-file &&
		git add unstable-reviewed-prefix-file &&
		git commit -m "reviewed unstable prerequisite" &&
		new_prefix=$(git rev-parse HEAD) &&
		git switch --detach "$new_prefix" &&
		git cherry-pick "$old_child" &&
		git branch -f cc/codex/child-unstable HEAD &&
		git switch --detach origin/codex-unstable &&
		git merge --no-ff "$new_prefix" \
			-m "Merge pull request #42 from openai/bb/codex/prefix-unstable" &&
		git push --force origin \
			HEAD:refs/heads/codex-unstable \
			bb/codex/prefix-unstable \
			cc/codex/child-unstable &&
		fetch_all &&
		install_admission_gh "$TRASH_DIRECTORY/unstable-combine-bin" &&
		ADMISSION_BASE=codex-unstable \
		ADMISSION_TOPIC=bb/codex/prefix-unstable \
		admission_command unstable-combine success rewrite --remote origin \
			--base master --codex codex --result split-result \
			--updates split-updates --inputs split-inputs \
			--failure split-failure &&
		parent=$(updated_tip bb/codex/prefix-unstable split-updates) &&
		child=$(updated_tip cc/codex/child-unstable split-updates) &&
		meta=$(updated_tip meta split-updates) &&
		test "$parent" = "$(git rev-parse "$child^")" &&
		git show "$meta:codex.config" >split.config &&
		test refs/heads/codex = "$(git config -f split.config \
			--get branch.bb/codex/prefix-unstable.merge)" &&
		test refs/heads/bb/codex/prefix-unstable = \
			"$(git config -f split.config \
			--get branch.cc/codex/child-unstable.merge)"
	)
'

test_expect_success 'retiring the last unstable topic retains an empty preview lane' '
	git init --bare unstable-delete.git &&
	test_create_repo unstable-delete-source &&
	(
		cd unstable-delete-source &&
		git remote add origin ../unstable-delete.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git switch -c bb/codex/last-unstable codex &&
		write preview unstable-last-file &&
		git add unstable-last-file &&
		git commit -m "last unstable topic" &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable
	) &&

	git clone unstable-delete.git unstable-delete-runner &&
	(
		cd unstable-delete-runner &&
		fetch_all &&
		old_unstable=$(git rev-parse origin/codex-unstable) &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		stable=$(cat result) &&
		unstable=$(updated_tip codex-unstable updates) &&
		test "$stable" = "$(git rev-parse "$unstable^")" &&
		test "$(git rev-parse "$stable^{tree}")" = \
			"$(git rev-parse "$unstable^{tree}")" &&
		test "Initialize codex-unstable" = \
			"$(git show -s --format=%s "$unstable")" &&
		manifest_has codex-unstable "$old_unstable" "$unstable" \
			updates &&
		meta=$(updated_tip meta updates) &&
		git show "$meta:codex.config" >next.config &&
		test 2 = "$(git config -f next.config --get codex.version)" &&
		test "$unstable" = "$(git config -f next.config \
			--get codex-unstable.output-tip)" &&
		test_must_fail git config -f next.config \
			--get branch.bb/codex/last-unstable.codex-tip &&
		sh "$codex_branch" verify-output \
			--inputs inputs --updates updates --result result &&
		apply_test_updates origin updates &&
		test "$unstable" = "$(git --git-dir=../unstable-delete.git \
			rev-parse refs/heads/codex-unstable)"
	)
'

test_expect_success 'an untracked unstable output cannot be silently retired' '
	git init --bare unstable-untracked.git &&
	test_create_repo unstable-untracked-source &&
	(
		cd unstable-untracked-source &&
		git remote add origin ../unstable-untracked.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git branch meta master &&
		install_meta_state meta master codex &&
		git switch -c codex-unstable codex &&
		write manual untracked-unstable-file &&
		git add untracked-unstable-file &&
		git commit -m "untracked unstable integration" &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable
	) &&

	git clone unstable-untracked.git unstable-untracked-runner &&
	(
		cd unstable-untracked-runner &&
		fetch_all &&
		snapshot_refs ../unstable-untracked.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			>out 2>err &&
		test_grep "codex-unstable" err &&
		test_path_is_missing result &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --enable-unstable \
			--result enabled.result --updates enabled.updates \
			--inputs enabled.inputs --failure enabled.failure \
			>enabled.out 2>enabled.err &&
		test_grep "codex-unstable" enabled.err &&
		test_path_is_missing enabled.result &&
		snapshot_refs ../unstable-untracked.git >after &&
		test_cmp before after
	)
'

test_expect_success 'retiring unstable output rejects unrecorded direct commits' '
	git init --bare unstable-retire-race.git &&
	test_create_repo unstable-retire-race-source &&
	(
		cd unstable-retire-race-source &&
		git remote add origin ../unstable-retire-race.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git switch -c bb/codex/retired-unstable codex &&
		write preview unstable-retired-file &&
		git add unstable-retired-file &&
		git commit -m "recorded unstable topic" &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git switch codex-unstable &&
		write direct unstable-direct-file &&
		git add unstable-direct-file &&
		git commit -m "direct commit after recorded unstable output" &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable
	) &&

	git clone unstable-retire-race.git unstable-retire-race-runner &&
	(
		cd unstable-retire-race-runner &&
		fetch_all &&
		snapshot_refs ../unstable-retire-race.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			>out 2>err &&
		test_grep \
			"codex-unstable\|unstable output\|normal two-parent merge" \
			err &&
		test_path_is_missing result &&
		snapshot_refs ../unstable-retire-race.git >after &&
		test_cmp before after
	)
'

test_expect_success 'unstable topics cannot hide workflow changes in a dependent revert' '
	git init --bare unstable-workflow.git &&
	test_create_repo unstable-workflow-source &&
	(
		cd unstable-workflow-source &&
		git remote add origin ../unstable-workflow.git &&
		write base shared &&
		mkdir -p .github/workflows &&
		write trusted .github/workflows/main.yml &&
		git add shared .github/workflows/main.yml &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git switch -c bb/codex/parent-unstable codex &&
		write malicious .github/workflows/main.yml &&
		git add .github/workflows/main.yml &&
		git commit -m "unstable topic changes protected workflow" &&
		git switch -c cc/codex/child-unstable &&
		write trusted .github/workflows/main.yml &&
		git add .github/workflows/main.yml &&
		git commit -m "unstable child hides protected workflow change" &&
		git diff --quiet codex HEAD -- .github/workflows/main.yml &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable bb/codex/parent-unstable \
			cc/codex/child-unstable
	) &&

	git clone unstable-workflow.git unstable-workflow-runner &&
	(
		cd unstable-workflow-runner &&
		fetch_all &&
		snapshot_refs ../unstable-workflow.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			>out 2>err &&
		test_grep "workflow\|controller\|protected" err &&
		test_path_is_missing result &&
		snapshot_refs ../unstable-workflow.git >after &&
		test_cmp before after
	)
'

test_expect_success 'stable DAG topics cannot hide workflow changes behind a secondary parent' '
	git init --bare stable-workflow-dag.git &&
	test_create_repo stable-workflow-dag-source &&
	(
		cd stable-workflow-dag-source &&
		git remote add origin ../stable-workflow-dag.git &&
		write base shared &&
		mkdir -p .github/workflows &&
		write_automation_workflow .github/workflows/codex.yml &&
		git add shared .github/workflows/codex.yml &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git switch -c aa/codex/automation codex &&
		write_stable_reviewed_automation_workflow \
			.github/workflows/codex.yml &&
		git add .github/workflows/codex.yml &&
		git commit -m "stable automation prerequisite" &&
		git switch -c bb/codex/clean codex &&
		write clean clean-file &&
		git add clean-file &&
		git commit -m "stable clean first parent" &&
		git switch -c cc/codex/fan bb/codex/clean &&
		git merge --no-ff aa/codex/automation \
			-m "Merge stable automation prerequisite" &&
		write_automation_workflow .github/workflows/codex.yml &&
		git add .github/workflows/codex.yml &&
		git commit -m "stable fan-in hides automation change" &&
		git diff --quiet codex HEAD -- .github/workflows/codex.yml &&
		git branch meta master &&
		install_meta_state meta master codex &&
		git push origin master meta codex \
			aa/codex/automation bb/codex/clean cc/codex/fan
	) &&

	git clone stable-workflow-dag.git stable-workflow-dag-runner &&
	(
		cd stable-workflow-dag-runner &&
		fetch_all &&
		snapshot_refs ../stable-workflow-dag.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			--require-automation \
			>out 2>err &&
		test_grep "workflow\|controller\|protected" err &&
		test_path_is_missing result &&
		snapshot_refs ../stable-workflow-dag.git >after &&
		test_cmp before after
	)
'

test_expect_success 'unstable topics cannot redirect or delete the production release workflow' '
	git init --bare unstable-release.git &&
	test_create_repo unstable-release-source &&
	(
		cd unstable-release-source &&
		git remote add origin ../unstable-release.git &&
		write base shared &&
		mkdir -p .github/workflows &&
		write_release_workflow codex .github/workflows/codex-release.yml &&
		git add shared .github/workflows/codex-release.yml &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git switch -c bb/codex/release-unstable codex &&
		write_release_workflow codex-unstable \
			.github/workflows/codex-release.yml &&
		git add .github/workflows/codex-release.yml &&
		git commit -m "release untrusted preview builds" &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git switch -c release-deleted codex &&
		git rm .github/workflows/codex-release.yml &&
		git commit -m "delete production release workflow" &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable bb/codex/release-unstable release-deleted
	) &&

	git clone unstable-release.git unstable-release-runner &&
	(
		cd unstable-release-runner &&
		fetch_all &&
		snapshot_refs ../unstable-release.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			>out 2>err &&
		test_grep "release\|workflow\|protected" err &&
		test_path_is_missing result &&
		snapshot_refs ../unstable-release.git >after &&
		test_cmp before after &&
		old=$(git rev-parse origin/bb/codex/release-unstable) &&
		deleted=$(git rev-parse origin/release-deleted) &&
		git --git-dir=../unstable-release.git update-ref \
			refs/heads/bb/codex/release-unstable "$deleted" "$old" &&
		fetch_all &&
		snapshot_refs ../unstable-release.git >before-deletion &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result deleted-result \
			--updates deleted-updates --inputs deleted-inputs \
			--failure deleted-failure >deleted.out 2>deleted.err &&
		test_grep "release\|workflow\|protected" deleted.err &&
		test_path_is_missing deleted-result &&
		snapshot_refs ../unstable-release.git >after-deletion &&
		test_cmp before-deletion after-deletion
	)
'

test_expect_success 'both candidates stage independently and publish under one atomic lease' '
	git init --bare unstable-promotion.git &&
	test_create_repo unstable-promotion-source &&
	(
		cd unstable-promotion-source &&
		git remote add origin ../unstable-promotion.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git switch -c aa/codex/stable master &&
		write stable stable-file &&
		git add stable-file &&
		git commit -m "atomic stable topic" &&
		git branch codex &&
		git switch -c bb/codex/preview-unstable codex &&
		write preview preview-file &&
		git add preview-file &&
		git commit -m "atomic unstable topic" &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable bb/codex/preview-unstable
	) &&

	git clone unstable-promotion.git unstable-promotion-runner &&
	(
		cd unstable-promotion-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		stable=$(cat result) &&
		unstable=$(updated_tip codex-unstable updates) &&
		snapshot_without_staging ../unstable-promotion.git >primary-before &&
		GIT_TRACE=1 sh "$codex_branch" stage \
			--remote origin --staging codex-staging \
			--inputs inputs --updates updates \
			>stable-stage.out 2>stable-stage.trace &&
		test "$stable" = "$(git --git-dir=../unstable-promotion.git \
			rev-parse refs/heads/codex-staging)" &&
		test_expect_code 1 sh "$codex_branch" promote \
			--remote origin --staging codex-staging \
			--inputs inputs --updates updates \
			>missing-stage.out 2>missing-stage.err &&
		snapshot_without_staging ../unstable-promotion.git \
			>after-missing-stage &&
		test_cmp primary-before after-missing-stage &&

		GIT_TRACE=1 sh "$codex_branch" stage \
			--remote origin --staging codex-unstable-staging \
			--inputs inputs --updates updates \
			>unstable-stage.out 2>unstable-stage.trace &&
		test "$unstable" = "$(git --git-dir=../unstable-promotion.git \
			rev-parse refs/heads/codex-unstable-staging)" &&
		snapshot_without_staging ../unstable-promotion.git \
			>after-both-stages &&
		test_cmp primary-before after-both-stages &&
		git --git-dir=../unstable-promotion.git update-ref \
			refs/heads/codex-unstable-staging "$stable" "$unstable" &&
		test_expect_code 1 sh "$codex_branch" promote \
			--remote origin --staging codex-staging \
			--inputs inputs --updates updates \
			>moved-stage.out 2>moved-stage.err &&
		snapshot_without_staging ../unstable-promotion.git \
			>after-stage-race &&
		test_cmp primary-before after-stage-race &&
		git --git-dir=../unstable-promotion.git update-ref \
			refs/heads/codex-unstable-staging "$unstable" "$stable" &&

		GIT_TRACE=1 sh "$codex_branch" promote \
			--remote origin --staging codex-staging \
			--inputs inputs --updates updates \
			>promote.out 2>promote.trace &&
		test_grep "push --atomic --porcelain" promote.trace &&
		test_grep \
			"force-with-lease=refs/heads/codex-staging:$stable" \
			promote.trace &&
		test_grep \
			"force-with-lease=refs/heads/codex-unstable-staging:$unstable" \
			promote.trace &&
		test_grep ":refs/heads/codex-staging" promote.trace &&
		test_grep ":refs/heads/codex-unstable-staging" promote.trace &&
		while IFS="$(printf "\t")" read -r ref old new
		do
			lease_old=$old &&
			case "$lease_old" in
			0000000000000000000000000000000000000000|\
			0000000000000000000000000000000000000000000000000000000000000000)
				lease_old=
				;;
			esac &&
			test_grep "force-with-lease=$ref:$lease_old" promote.trace &&
			test "$new" = "$(git --git-dir=../unstable-promotion.git \
				rev-parse "$ref")" || return 1
		done <updates &&
		test_must_fail git --git-dir=../unstable-promotion.git \
			show-ref --verify refs/heads/codex-staging &&
		test_must_fail git --git-dir=../unstable-promotion.git \
			show-ref --verify refs/heads/codex-unstable-staging
	)
'

test_expect_success 'unstable rebase conflicts preserve refs and give honest recovery guidance' '
	git init --bare unstable-conflict.git &&
	test_create_repo unstable-conflict-source &&
	(
		cd unstable-conflict-source &&
		git remote add origin ../unstable-conflict.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git switch -c bb/codex/conflict-unstable codex &&
		write preview shared &&
		git add shared &&
		git commit -m "conflicting unstable preview" &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git switch master &&
		write stable shared &&
		git add shared &&
		git commit -m "conflicting stable base" &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable bb/codex/conflict-unstable
	) &&

	git clone unstable-conflict.git unstable-conflict-runner &&
	(
		cd unstable-conflict-runner &&
		fetch_all &&
		snapshot_refs ../unstable-conflict.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			>out 2>err &&
		test_grep "bb/codex/conflict-unstable" err &&
		test_path_is_missing result &&
		if test -f failure
		then
			test_grep "bb/codex/conflict-unstable" failure &&
			! grep -E "resolve .*--base(=| )codex .*--codex(=| )codex-unstable" \
				failure
		else
			test_grep "restack\|rebase\|resolve" err
		fi &&
		snapshot_refs ../unstable-conflict.git >after &&
		test_cmp before after
	)
'

test_expect_success 'published stable topics cannot all disappear behind unstable previews' '
	git init --bare unstable-stable-retired.git &&
	test_create_repo unstable-stable-retired-source &&
	(
		cd unstable-stable-retired-source &&
		git remote add origin ../unstable-stable-retired.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git switch -c aa/codex/stable master &&
		write stable stable-file &&
		git add stable-file &&
		git commit -m "last published stable topic" &&
		git branch codex &&
		git branch meta master &&
		install_meta_state meta master codex &&
		git switch -c bb/codex/preview-unstable codex &&
		write preview preview-file &&
		git add preview-file &&
		git commit -m "unstable preview cannot replace stable" &&
		git push origin master meta codex bb/codex/preview-unstable
	) &&

	git clone unstable-stable-retired.git unstable-stable-retired-runner &&
	(
		cd unstable-stable-retired-runner &&
		fetch_all &&
		snapshot_refs ../unstable-stable-retired.git >before &&
		test_expect_code 1 sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			>out 2>err &&
		test_grep "all enrolled Codex topics were removed" err &&
		test_path_is_missing result &&
		snapshot_refs ../unstable-stable-retired.git >after &&
		test_cmp before after
	)
'

test_expect_success 'stable fan-in preserves internal merges and records its DAG' '
	git init --bare stable-fan-in.git &&
	test_create_repo stable-fan-in-source &&
	(
		cd stable-fan-in-source &&
		git remote add origin ../stable-fan-in.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&

		git switch -c shared-helper codex &&
		write helper helper-file &&
		git add helper-file &&
		git commit -m "shared stable helper" &&
		git switch -c aa/codex/a codex &&
		write a a-file &&
		git add a-file &&
		git commit -m "stable fan-in prerequisite A" &&
		git merge --no-ff shared-helper \
			-m "Merge shared helper into stable A" &&
		git switch -c bb/codex/b codex &&
		write b b-file &&
		git add b-file &&
		git commit -m "stable fan-in prerequisite B" &&
		git merge --no-ff shared-helper \
			-m "Merge shared helper into stable B" &&
		git switch -c cc/codex/c codex &&
		write c c-file &&
		git add c-file &&
		git commit -m "stable fan-in prerequisite C" &&
		git switch -c dd/codex/fan aa/codex/a &&
		git merge --no-ff bb/codex/b cc/codex/c \
			-m "Merge the stable fan-in prerequisites" &&
		write fan fan-file &&
		git add fan-file &&
		git commit -m "stable fan-in payload" &&

		git switch master &&
		write advance advanced-base &&
		git add advanced-base &&
		git commit -m "advance production underneath stable DAG" &&
		git branch meta master &&
		install_meta_state meta master codex &&
		git push origin master meta codex \
			aa/codex/a bb/codex/b cc/codex/c dd/codex/fan
	) &&

	git clone stable-fan-in.git stable-fan-in-runner &&
	(
		cd stable-fan-in-runner &&
		fetch_all &&
		old_helper=$(git rev-parse "origin/aa/codex/a^2") &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		candidate=$(cat result) &&
		master=$(git rev-parse origin/master) &&
		a=$(updated_tip aa/codex/a updates) &&
		b=$(updated_tip bb/codex/b updates) &&
		c=$(updated_tip cc/codex/c updates) &&
		fan=$(updated_tip dd/codex/fan updates) &&
		fan_merge=$(git rev-list \
			--grep="^Merge the stable fan-in prerequisites$" \
			"$master..$fan" | sed -n 1p) &&
		test "$a" = "$(git rev-parse "$fan_merge^1")" &&
		test "$b" = "$(git rev-parse "$fan_merge^2")" &&
		test "$c" = "$(git rev-parse "$fan_merge^3")" &&
		a_helper=$(git rev-list \
			--grep="^Merge shared helper into stable A$" \
			"$master..$a" | sed -n 1p) &&
		b_helper=$(git rev-list \
			--grep="^Merge shared helper into stable B$" \
			"$master..$b" | sed -n 1p) &&
		rewritten_helper=$(git rev-parse "$a_helper^2") &&
		test "$rewritten_helper" = \
			"$(git rev-parse "$b_helper^2")" &&
		test "$rewritten_helper" != "$old_helper" &&
		test "$master" = "$(git rev-parse "$rewritten_helper^")" &&
		git merge-base --is-ancestor "$fan" "$candidate" &&
		meta=$(updated_tip meta updates) &&
		git show "$meta:codex.config" >next.config &&
		git config --no-includes -f next.config --get-all \
			branch.dd/codex/fan.merge >fan-prerequisites &&
		printf "%s\n" refs/heads/aa/codex/a \
			refs/heads/bb/codex/b \
			refs/heads/cc/codex/c >expected-fan-prerequisites &&
		test_cmp expected-fan-prerequisites fan-prerequisites &&
		sh "$codex_branch" verify-output --inputs inputs \
			--updates updates --result result &&
		fan_parent=$(git rev-parse "$fan^") &&
		ab_tree=$(git merge-tree --write-tree "$a" "$b") &&
		ab=$(printf "%s\n" "tampered stable A+B fan-in" |
			git commit-tree "$ab_tree" -p "$a" -p "$b") &&
		abc=$(printf "%s\n" "tampered stable binary +C fan-in" |
			git commit-tree "$fan_parent^{tree}" -p "$ab" -p "$c") &&
		flattened=$(printf "%s\n" "tampered flattened stable fan-in payload" |
			git commit-tree "$fan^{tree}" -p "$abc") &&
		test "$(git rev-parse "$fan^{tree}")" = \
			"$(git rev-parse "$flattened^{tree}")" &&
		fake_candidate=$master &&
		for entry in aa:a bb:b cc:c dd:fan
		do
			prefix=$(printf "%s\n" "$entry" | cut -d: -f1) &&
			name=$(printf "%s\n" "$entry" | cut -d: -f2) &&
			case "$name" in
			a) tip=$a ;;
			b) tip=$b ;;
			c) tip=$c ;;
			fan) tip=$flattened ;;
			esac &&
			tree=$(git merge-tree --write-tree "$fake_candidate" \
				"$tip") &&
			fake_candidate=$(make_test_integration \
				"$prefix/codex/$name" "$tip" \
				"$fake_candidate" "$tree") || return 1
		done &&
		old_meta=$(git rev-parse origin/meta) &&
		git show "$meta:codex.config" |
			sed -e "s/$fan/$flattened/g" \
				-e "s/$candidate/$fake_candidate/g" \
				>flattened.config &&
		blob=$(git hash-object -w flattened.config) &&
		index=$PWD/flattened.index &&
		rm -f "$index" &&
		GIT_INDEX_FILE=$index git read-tree "$old_meta^{tree}" &&
		GIT_INDEX_FILE=$index git update-index --add --cacheinfo \
			100644,"$blob",codex.config &&
		tree=$(GIT_INDEX_FILE=$index git write-tree) &&
		fake_meta=$(printf "%s\n" "meta: forged flattened stable fan-in" |
			GIT_AUTHOR_NAME=$codex_bot_name \
			GIT_AUTHOR_EMAIL=$codex_bot_email \
			GIT_COMMITTER_NAME=$codex_bot_name \
			GIT_COMMITTER_EMAIL=$codex_bot_email \
			git -c commit.gpgSign=false commit-tree \
				"$tree" -p "$old_meta") &&
		awk -F "$(printf '\''\t'\'')" \
			-v OFS="$(printf '\''\t'\'')" \
			-v meta="$fake_meta" -v candidate="$fake_candidate" \
			-v fan="$flattened" '\''
			$1 == "refs/heads/meta" { $3=meta }
			$1 == "refs/heads/codex" { $3=candidate }
			$1 == "refs/heads/dd/codex/fan" { $3=fan }
			{ print }
		'\'' updates >flattened.updates &&
		printf "%s\n" "$fake_candidate" >flattened.result &&
		test_expect_code 1 sh "$codex_branch" verify-output \
			--inputs inputs --updates flattened.updates \
			--result flattened.result \
			>flattened.out 2>flattened.err &&
		test_grep "merge rewrite.*topology" flattened.err &&
		apply_test_updates origin updates &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result repeated-result \
			--updates repeated-updates --inputs repeated-inputs \
			--failure repeated-failure &&
		test "$candidate" = "$(cat repeated-result)" &&
		test "$fan" = "$(updated_tip dd/codex/fan repeated-updates)"
	)
'

test_expect_success 'reviewed internal stable merges can share a helper without admitting descendants' '
	for shape in explicit linear unstable-descendant
	do
		case "$shape" in
		unstable-descendant)
			hidden_ref=cc/codex/unadmitted-unstable
			;;
		*)
			hidden_ref=cc/codex/unadmitted
			;;
		esac &&
		fixture=stable-shared-$shape &&
		git init --bare "$fixture.git" &&
		test_create_repo "$fixture-source" &&
		(
			cd "$fixture-source" &&
			git remote add origin "../$fixture.git" &&
			write base shared &&
			git add shared &&
			install_rerere_train &&
			git commit -m base &&
			git switch -c aa/codex/enrolled master &&
			write enrolled enrolled-file &&
			git add enrolled-file &&
			git commit -m "already enrolled stable topic" &&
			git branch codex &&
			git branch meta master &&
			install_meta_state meta master codex &&
			git switch -c shared-helper codex &&
			write helper helper-file &&
			git add helper-file &&
			git commit -m "shared stable helper" &&
			if test "$shape" != linear
			then
				git switch -c bb/codex/reviewed codex &&
				write reviewed reviewed-file &&
				git add reviewed-file &&
				git commit -m "reviewed stable mainline" &&
				git merge --no-ff shared-helper \
					-m "Merge reviewed stable helper"
			else
				git switch -c bb/codex/reviewed \
					shared-helper &&
				write reviewed reviewed-file &&
				git add reviewed-file &&
				git commit -m "launder an unreviewed stable prerequisite"
			fi &&
			git switch -c "$hidden_ref" shared-helper &&
			write hidden hidden-file &&
			git add hidden-file &&
			git commit -m "unadmitted stable helper descendant" &&
			git switch codex &&
			git merge --no-ff bb/codex/reviewed \
				-m "Merge pull request #42 from openai/bb/codex/reviewed" &&
			git push origin master meta codex \
				aa/codex/enrolled bb/codex/reviewed \
				"$hidden_ref"
		) &&
		git clone "$fixture.git" "$fixture-runner" &&
		install_admission_gh "$TRASH_DIRECTORY/$fixture-bin" &&
		(
			cd "$fixture-runner" &&
			fetch_all &&
			if test "$shape" = explicit
			then
				admission_rewrite "$fixture" success &&
				candidate=$(cat result) &&
				test helper = "$(git show "$candidate:helper-file")" &&
				test_must_fail git cat-file -e "$candidate:hidden-file" &&
				test -z "$(updated_tip "$hidden_ref" updates)"
			else
				test_expect_code 1 admission_rewrite \
					"$fixture" success >out 2>err &&
				test_grep "unadmitted.*prerequisite" err &&
				test_path_is_missing result
			fi
		) || return 1
	done
'

test_expect_success 'unstable fan-in preserves internal merges and publishes its complete DAG atomically' '
	git init --bare unstable-fan-in.git &&
	test_create_repo unstable-fan-in-source &&
	(
		cd unstable-fan-in-source &&
		git remote add origin ../unstable-fan-in.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&

		git switch -c shared-helper codex &&
		write helper helper-file &&
		git add helper-file &&
		git commit -m "shared namespace helper" &&
		git switch -c bb/codex/a-unstable codex &&
		write a a-file &&
		git add a-file &&
		git commit -m "fan-in prerequisite A" &&
		git merge --no-ff shared-helper \
			-m "Merge shared helper into A" &&
		git switch -c cc/codex/b-unstable codex &&
		write b b-file &&
		git add b-file &&
		git commit -m "fan-in prerequisite B" &&
		git merge --no-ff shared-helper \
			-m "Merge shared helper into B" &&
		git switch -c dd/codex/c-unstable codex &&
		write c c-file &&
		git add c-file &&
		git commit -m "fan-in prerequisite C" &&
		git switch -c ee/codex/s05-unstable \
			bb/codex/a-unstable &&
		git merge --no-ff cc/codex/b-unstable \
			dd/codex/c-unstable -m "Merge the S05 prerequisites" &&
		write s05 s05-file &&
		git add s05-file &&
		git commit -m "S05 topic payload" &&
		git switch -c ff/codex/d-unstable codex &&
		write d d-file &&
		git add d-file &&
		git commit -m "nested fan-in prerequisite D" &&
		git switch -c gg/codex/s13-unstable \
			ee/codex/s05-unstable &&
		git merge --no-ff ff/codex/d-unstable \
			-m "Merge the S13 prerequisites" &&
		write s13 s13-file &&
		git add s13-file &&
		git commit -m "S13 topic payload" &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&

		git switch master &&
		write advance advanced-base &&
		write c c-file &&
		git add advanced-base c-file &&
		git commit -m "advance production underneath unstable DAG" &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable bb/codex/a-unstable \
			cc/codex/b-unstable dd/codex/c-unstable \
			ee/codex/s05-unstable ff/codex/d-unstable \
			gg/codex/s13-unstable
	) &&

	git clone unstable-fan-in.git unstable-fan-in-runner &&
	(
		cd unstable-fan-in-runner &&
		fetch_all &&
		old_helper=$(git rev-parse \
			"origin/bb/codex/a-unstable^2") &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --bundle candidate.bundle \
			--failure failure &&
		stable=$(cat result) &&
		a=$(updated_tip bb/codex/a-unstable updates) &&
		b=$(updated_tip cc/codex/b-unstable updates) &&
		c=$(updated_tip dd/codex/c-unstable updates) &&
		s05=$(updated_tip ee/codex/s05-unstable updates) &&
		d=$(updated_tip ff/codex/d-unstable updates) &&
		s13=$(updated_tip gg/codex/s13-unstable updates) &&
		unstable=$(updated_tip codex-unstable updates) &&
		meta=$(updated_tip meta updates) &&
		test "$stable" = "$(git rev-parse "$c^")" &&
		test "$(git rev-parse "$stable^{tree}")" = \
			"$(git rev-parse "$c^{tree}")" &&
		test "fan-in prerequisite C" = \
			"$(git show -s --format=%s "$c")" &&
		s05_merge=$(git rev-list --grep="^Merge the S05 prerequisites$" \
			"$stable..$s05" | sed -n 1p) &&
		test "$a" = "$(git rev-parse "$s05_merge^1")" &&
		test "$b" = "$(git rev-parse "$s05_merge^2")" &&
		test "$c" = "$(git rev-parse "$s05_merge^3")" &&
		s13_merge=$(git rev-list --grep="^Merge the S13 prerequisites$" \
			"$stable..$s13" | sed -n 1p) &&
		test "$s05" = "$(git rev-parse "$s13_merge^1")" &&
		test "$d" = "$(git rev-parse "$s13_merge^2")" &&
		a_helper=$(git rev-list --grep="^Merge shared helper into A$" \
			"$stable..$a" | sed -n 1p) &&
		b_helper=$(git rev-list --grep="^Merge shared helper into B$" \
			"$stable..$b" | sed -n 1p) &&
		rewritten_helper=$(git rev-parse "$a_helper^2") &&
		test "$rewritten_helper" = \
			"$(git rev-parse "$b_helper^2")" &&
		test "$rewritten_helper" != "$old_helper" &&
		test "$stable" = "$(git rev-parse "$rewritten_helper^")" &&
		git show "$meta:codex.config" >next.config &&
		git config --no-includes -f next.config --get-all \
			branch.ee/codex/s05-unstable.merge >s05-prerequisites &&
		printf "%s\n" refs/heads/bb/codex/a-unstable \
			refs/heads/cc/codex/b-unstable \
			refs/heads/dd/codex/c-unstable >expected-s05-prerequisites &&
		test_cmp expected-s05-prerequisites s05-prerequisites &&
		git config --no-includes -f next.config --get-all \
			branch.gg/codex/s13-unstable.merge >s13-prerequisites &&
		printf "%s\n" refs/heads/ee/codex/s05-unstable \
			refs/heads/ff/codex/d-unstable >expected-s13-prerequisites &&
		test_cmp expected-s13-prerequisites s13-prerequisites &&
		git bundle verify candidate.bundle &&
		sh "$codex_branch" stage --remote origin \
			--staging codex-staging --inputs inputs --updates updates &&
		sh "$codex_branch" stage --remote origin \
			--staging codex-unstable-staging \
			--inputs inputs --updates updates &&
		GIT_TRACE=1 sh "$codex_branch" promote --remote origin \
			--staging codex-staging --inputs inputs --updates updates \
			>promote.out 2>promote.trace &&
		test_grep "push --atomic --porcelain" promote.trace &&
		while IFS="$(printf "\t")" read -r ref old new
		do
			test_grep "force-with-lease=$ref:$old" promote.trace &&
			test "$new" = "$(git --git-dir=../unstable-fan-in.git \
				rev-parse "$ref")" || return 1
		done <updates &&
		git merge-base --is-ancestor "$stable" "$unstable" &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result repeated-result \
			--updates repeated-updates --inputs repeated-inputs \
			--failure repeated-failure &&
		test "$stable" = "$(cat repeated-result)" &&
		test "$unstable" = \
			"$(updated_tip codex-unstable repeated-updates)" &&
		test "$meta" = "$(updated_tip meta repeated-updates)" &&
		test "$s05" = \
			"$(updated_tip ee/codex/s05-unstable repeated-updates)" &&
		test "$s13" = \
			"$(updated_tip gg/codex/s13-unstable repeated-updates)" &&

		git --git-dir=../unstable-fan-in.git update-ref \
			refs/heads/dd/codex/c-unstable "$stable" "$c" &&
		fetch_all &&
		snapshot_refs ../unstable-fan-in.git >before-rewind &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result rewound-result --updates rewound-updates \
			--inputs rewound-inputs --failure rewound-failure \
			>rewound.out 2>rewound.err &&
		test_grep "prerequisite.*changed; restack" rewound.err &&
		test_path_is_missing rewound-result &&
		snapshot_refs ../unstable-fan-in.git >after-rewind &&
		test_cmp before-rewind after-rewind &&

		git --git-dir=../unstable-fan-in.git update-ref \
			refs/heads/dd/codex/c-unstable "$c" "$stable" &&
		git --git-dir=../unstable-fan-in.git update-ref -d \
			refs/heads/dd/codex/c-unstable "$c" &&
		fetch_all &&
		snapshot_refs ../unstable-fan-in.git >before-retirement &&
		test_expect_code 1 sh "$codex_branch" rewrite \
			--remote origin --base master --codex codex \
			--result retired-result --updates retired-updates \
			--inputs retired-inputs --failure retired-failure \
			>retired.out 2>retired.err &&
		test_grep "prerequisite.*retired" retired.err &&
		test_path_is_missing retired-result &&
		snapshot_refs ../unstable-fan-in.git >after-retirement &&
		test_cmp before-retirement after-retirement
	)
'

test_expect_success 'reviewed internal unstable merges can share a helper without admitting its descendants' '
	for shape in explicit linear
	do
		fixture=unstable-shared-$shape &&
		git init --bare "$fixture.git" &&
		test_create_repo "$fixture-source" &&
		(
			cd "$fixture-source" &&
			git remote add origin "../$fixture.git" &&
			write base shared &&
			git add shared &&
			install_rerere_train &&
			git commit -m base &&
			git branch codex &&
			git branch aa/codex/stable codex &&
			create_unstable_sentinel codex &&
			git branch meta master &&
			install_unstable_meta_state meta master codex codex-unstable &&
			git switch -c shared-helper codex &&
			write helper helper-file &&
			git add helper-file &&
			git commit -m "shared unregistered helper" &&
			if test "$shape" = explicit
			then
				git switch -c bb/codex/reviewed-unstable codex &&
				write reviewed reviewed-file &&
				git add reviewed-file &&
				git commit -m "reviewed mainline" &&
				git merge --no-ff shared-helper \
					-m "Merge reviewed shared helper"
			else
				git switch -c bb/codex/reviewed-unstable \
					shared-helper &&
				write reviewed reviewed-file &&
				git add reviewed-file &&
				git commit -m "launder an unreviewed prerequisite"
			fi &&
			git switch -c cc/codex/unadmitted-unstable shared-helper &&
			write hidden hidden-file &&
			git add hidden-file &&
			git commit -m "unadmitted helper descendant" &&
			git switch codex-unstable &&
			git merge --no-ff bb/codex/reviewed-unstable \
				-m "Merge pull request #42 from openai/bb/codex/reviewed-unstable" &&
			git push origin master meta codex codex-unstable \
				aa/codex/stable bb/codex/reviewed-unstable \
				cc/codex/unadmitted-unstable
		) &&
		git clone "$fixture.git" "$fixture-runner" &&
		install_admission_gh "$TRASH_DIRECTORY/$fixture-bin" &&
		(
			cd "$fixture-runner" &&
			fetch_all &&
			if test "$shape" = explicit
			then
				unstable_admission_rewrite "$fixture" success &&
				unstable=$(updated_tip codex-unstable updates) &&
				test helper = "$(git show "$unstable:helper-file")" &&
				test_must_fail git cat-file -e "$unstable:hidden-file" &&
				test -z "$(updated_tip \
					cc/codex/unadmitted-unstable updates)"
			else
				test_expect_code 1 unstable_admission_rewrite \
					"$fixture" success >out 2>err &&
				test_grep "unadmitted.*prerequisite" err &&
				test_path_is_missing result
			fi
		) || return 1
	done
'

test_expect_success 'the trusted admission gate permits only reviewed internal helper merges' '
	install_admission_gate_gh "$TRASH_DIRECTORY/admission-gate-bin" &&
	sed -n "/^        run: |\$/,/^        [^ ]/p" \
		"$codex_admission_workflow" |
	sed "1d; s/^          //" >"$TRASH_DIRECTORY/admission-gate.sh" &&
	bash -n "$TRASH_DIRECTORY/admission-gate.sh" &&
	for event in pull_request merge_group
	do
		run_admission_gate reviewed-shared-helper "$event" \
			bb/codex/reviewed-unstable codex-unstable \
			>"helper-$event.out" &&
		test_grep "Approved pull request #42" \
			"helper-$event.out" &&
		run_admission_gate reviewed-shared-helper "$event" \
			bb/codex/reviewed codex \
			>"stable-helper-$event.out" &&
		test_grep "Approved pull request #42" \
			"stable-helper-$event.out" || return 1
	done &&
	for mode in linear-shared-helper ancestor-shared-helper \
		helper-api-failure
	do
		test_expect_code 1 run_admission_gate "$mode" merge_group \
			bb/codex/reviewed-unstable codex-unstable \
			>"helper-$mode.out" 2>"helper-$mode.err" &&
			test_expect_code 1 run_admission_gate "$mode" merge_group \
			bb/codex/reviewed codex \
			>"stable-helper-$mode.out" \
			2>"stable-helper-$mode.err" || return 1
	done &&
	test_expect_code 1 run_admission_gate reviewed-unstable-helper \
		merge_group bb/codex/reviewed codex \
		>"stable-unstable-helper.out" \
		2>"stable-unstable-helper.err" &&
	test_grep "unenrolled history" stable-unstable-helper.err
'

test_expect_success 'an unstable merge graph cannot mix old and current production bases' '
	git init --bare unstable-mixed-bases.git &&
	test_create_repo unstable-mixed-bases-source &&
	(
		cd unstable-mixed-bases-source &&
		git remote add origin ../unstable-mixed-bases.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git switch -c bb/codex/a-unstable codex &&
		write A a-file &&
		git add a-file &&
		git commit -m "old-base prerequisite A" &&
		git switch -c cc/codex/b-unstable codex &&
		write B b-file &&
		git add b-file &&
		git commit -m "old-base prerequisite B" &&
		git switch -c dd/codex/fan-unstable \
			bb/codex/a-unstable &&
		git merge --no-ff cc/codex/b-unstable \
			-m "Merge mixed-base fan-in prerequisites" &&
		write fan fan-file &&
		git add fan-file &&
		git commit -m "mixed-base fan-in payload" &&
		git switch -c ee/codex/current-unstable codex &&
		write current current-file &&
		git add current-file &&
		git commit -m "independent current-base topic" &&
		git switch -c codex-unstable dd/codex/fan-unstable &&
		git merge --no-ff ee/codex/current-unstable \
			-m "Integrate the current-base topic" &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git switch master &&
		write advance advanced-base &&
		git add advanced-base &&
		git commit -m "advance production before a partial restack" &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable bb/codex/a-unstable \
			cc/codex/b-unstable dd/codex/fan-unstable \
			ee/codex/current-unstable
	) &&

	git clone unstable-mixed-bases.git unstable-mixed-bases-runner &&
	(
		cd unstable-mixed-bases-runner &&
		fetch_all &&
		fixed_date="2005-04-07T22:13:13+0000" &&
		GIT_AUTHOR_DATE=$fixed_date GIT_COMMITTER_DATE=$fixed_date \
			sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result valid-result \
			--updates valid-updates --inputs valid-inputs \
			--failure valid-failure &&
		candidate=$(cat valid-result) &&
		current_tree=$(git merge-tree --write-tree "$candidate" \
			origin/ee/codex/current-unstable) &&
		current=$(printf "%s\n" "partially restacked preview topic" |
			git commit-tree "$current_tree" -p "$candidate") &&
		git push --force origin \
			"$current:refs/heads/ee/codex/current-unstable" &&
		fetch_all &&
		snapshot_refs ../unstable-mixed-bases.git >before &&
		test_expect_code 1 env GIT_AUTHOR_DATE="$fixed_date" \
			GIT_COMMITTER_DATE="$fixed_date" \
			sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure \
			>out 2>err &&
		test_grep "mixes current and previous production bases" err &&
		test_path_is_missing result &&
		snapshot_refs ../unstable-mixed-bases.git >after &&
		test_cmp before after
	)
'

test_expect_success 'upstream-absorbed fan-in prerequisites leave canonical unstable state' '
	git init --bare unstable-absorbed-fan.git &&
	test_create_repo unstable-absorbed-fan-source &&
	(
		cd unstable-absorbed-fan-source &&
		git remote add origin ../unstable-absorbed-fan.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		git switch -c bb/codex/a-unstable codex &&
		write A a-file &&
		git add a-file &&
		git commit -m "upstream-absorbed prerequisite A" &&
		git switch -c cc/codex/b-unstable codex &&
		write B b-file &&
		git add b-file &&
		git commit -m "upstream-absorbed prerequisite B" &&
		git switch -c dd/codex/fan-unstable \
			bb/codex/a-unstable &&
		git merge --no-ff cc/codex/b-unstable \
			-m "Merge the upstream-absorbed prerequisites" &&
		write fan fan-file &&
		git add fan-file &&
		git commit -m "retain the downstream fan-in payload" &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git switch master &&
		git merge --no-ff bb/codex/a-unstable \
			cc/codex/b-unstable \
			-m "Upstream accepts both fan-in prerequisites" &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable bb/codex/a-unstable \
			cc/codex/b-unstable dd/codex/fan-unstable
	) &&

	git clone unstable-absorbed-fan.git unstable-absorbed-fan-runner &&
	(
		cd unstable-absorbed-fan-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		meta=$(updated_tip meta updates) &&
		git show "$meta:codex.config" >next.config &&
		git config --no-includes --file next.config --get-all \
			branch.dd/codex/fan-unstable.merge >fan-prerequisites &&
		printf "%s\n" refs/heads/codex >expected-prerequisites &&
		test_cmp expected-prerequisites fan-prerequisites &&
		apply_test_updates origin updates &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result next-result \
			--updates next-updates --inputs next-inputs \
			--failure next-failure &&
		test "$(cat result)" = "$(cat next-result)"
	)
'

test_expect_success 'verify-output rejects a flattened unstable fan-in merge' '
	git init --bare unstable-flattened-fan.git &&
	test_create_repo unstable-flattened-fan-source &&
	(
		cd unstable-flattened-fan-source &&
		git remote add origin ../unstable-flattened-fan.git &&
		write base shared &&
		git add shared &&
		install_rerere_train &&
		git commit -m base &&
		git branch codex &&
		git branch aa/codex/stable codex &&
		for entry in bb:a cc:b dd:c
		do
			prefix=${entry%:*} &&
			name=${entry#*:} &&
			git switch -c "$prefix/codex/$name-unstable" codex &&
			write "$name" "$name-file" &&
			git add "$name-file" &&
			git commit -m "fan-in prerequisite $name" || return 1
		done &&
		git switch -c ee/codex/fan-unstable bb/codex/a-unstable &&
		git merge --no-ff cc/codex/b-unstable \
			dd/codex/c-unstable \
			-m "Preserve the reviewed three-parent fan-in" &&
		write fan fan-file &&
		git add fan-file &&
		git commit -m "reviewed fan-in payload" &&
		git branch codex-unstable &&
		git branch meta master &&
		install_unstable_meta_state meta master codex codex-unstable &&
		git switch master &&
		write advance advanced-base &&
		git add advanced-base &&
		git commit -m "advance before preserving fan-in topology" &&
		git push origin master meta codex codex-unstable \
			aa/codex/stable bb/codex/a-unstable \
			cc/codex/b-unstable dd/codex/c-unstable \
			ee/codex/fan-unstable
	) &&

	git clone unstable-flattened-fan.git unstable-flattened-fan-runner &&
	(
		cd unstable-flattened-fan-runner &&
		fetch_all &&
		sh "$codex_branch" rewrite --remote origin \
			--base master --codex codex --result result \
			--updates updates --inputs inputs --failure failure &&
		stable=$(cat result) &&
		a=$(updated_tip bb/codex/a-unstable updates) &&
		b=$(updated_tip cc/codex/b-unstable updates) &&
		c=$(updated_tip dd/codex/c-unstable updates) &&
		fan=$(updated_tip ee/codex/fan-unstable updates) &&
		unstable=$(updated_tip codex-unstable updates) &&
		meta=$(updated_tip meta updates) &&
		old_meta=$(git rev-parse origin/meta) &&
		fan_merge=$(git rev-parse "$fan^") &&
		ab_tree=$(git merge-tree --write-tree "$a" "$b") &&
		ab=$(printf "%s\n" "tampered binary A+B fan-in" |
			git commit-tree "$ab_tree" -p "$a" -p "$b") &&
		abc=$(printf "%s\n" "tampered binary +C fan-in" |
			git commit-tree "$fan_merge^{tree}" -p "$ab" -p "$c") &&
		flattened=$(printf "%s\n" "tampered flattened fan-in payload" |
			git commit-tree "$fan^{tree}" -p "$abc") &&
		test "$(git rev-parse "$fan^{tree}")" = \
			"$(git rev-parse "$flattened^{tree}")" &&
		fake_unstable=$stable &&
		for entry in bb:a cc:b dd:c ee:fan
		do
			prefix=${entry%:*} &&
			name=${entry#*:} &&
			case "$name" in
			a) tip=$a ;;
			b) tip=$b ;;
			c) tip=$c ;;
			fan) tip=$flattened ;;
			esac &&
			tree=$(git merge-tree --write-tree "$fake_unstable" \
				"$tip") &&
			fake_unstable=$(make_test_unstable_integration \
				"$prefix/codex/$name-unstable" "$tip" \
				"$fake_unstable" "$tree") || return 1
		done &&
		git show "$meta:codex.config" |
			sed -e "s/$fan/$flattened/g" \
				-e "s/$unstable/$fake_unstable/g" \
				>flattened.config &&
		blob=$(git hash-object -w flattened.config) &&
		index=$PWD/flattened.index &&
		rm -f "$index" &&
		GIT_INDEX_FILE=$index git read-tree "$old_meta^{tree}" &&
		GIT_INDEX_FILE=$index git update-index --add --cacheinfo \
			100644,"$blob",codex.config &&
		tree=$(GIT_INDEX_FILE=$index git write-tree) &&
		fake_meta=$(printf "%s\n" "meta: forged flattened fan-in" |
			GIT_AUTHOR_NAME=$codex_bot_name \
			GIT_AUTHOR_EMAIL=$codex_bot_email \
			GIT_COMMITTER_NAME=$codex_bot_name \
			GIT_COMMITTER_EMAIL=$codex_bot_email \
			git -c commit.gpgSign=false commit-tree \
				"$tree" -p "$old_meta") &&
		awk -F "$(printf '\''\t'\'')" \
			-v OFS="$(printf '\''\t'\'')" \
			-v meta="$fake_meta" -v unstable="$fake_unstable" \
			-v fan="$flattened" '\''
			$1 == "refs/heads/meta" { $3=meta }
			$1 == "refs/heads/codex-unstable" { $3=unstable }
			$1 == "refs/heads/ee/codex/fan-unstable" { $3=fan }
			{ print }
		'\'' updates >flattened.updates &&
		test_expect_code 1 sh "$codex_branch" verify-output \
			--inputs inputs --updates flattened.updates --result result \
			>flattened.out 2>flattened.err &&
		test_grep "merge rewrite.*topology" flattened.err
	)
'

test_done
