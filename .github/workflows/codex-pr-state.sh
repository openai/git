#!/bin/sh

set -eu

me=codex-pr-state
repository=${GITHUB_REPOSITORY:-openai/git}
expected_meta=
inputs=
updates=
dry_run=
tab=$(printf '\t')
script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
state_dir=

die () {
	printf '%s: %s\n' "$me" "$*" >&2
	exit 1
}

cleanup () {
	test -z "$state_dir" || rm -rf "$state_dir"
}

trap cleanup EXIT HUP INT TERM

require_arg () {
	test $# -ge 2 || die "$1 needs one argument"
}

while test $# -gt 0
do
	case "$1" in
	--expected-meta)
		require_arg "$@"
		expected_meta=$2
		shift 2
		;;
	--inputs)
		require_arg "$@"
		inputs=$2
		shift 2
		;;
	--updates)
		require_arg "$@"
		updates=$2
		shift 2
		;;
	--dry-run)
		dry_run=t
		shift
		;;
	*) die "unknown option '$1'" ;;
	esac
done

test "$repository" = openai/git ||
	die "pull request state can only be reconciled for openai/git"
if test -n "$inputs" || test -n "$updates"
then
	test -n "$inputs" && test -n "$updates" ||
		die "candidate provenance requires both --inputs and --updates"
	test -f "$inputs" || die "input snapshot '$inputs' does not exist"
	test -f "$updates" || die "update manifest '$updates' does not exist"
fi

state_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-pr-state.XXXXXX") ||
	die "could not create temporary state"

labels () {
	cat <<-'EOF'
	kind:review-only	5319e7	Reviewed topic; do not merge this pull request
	kind:auto-plan	c5def5	Automatically admitted Codex plan transition
	kind:plan-policy	d4c5f9	Human-reviewed Codex plan policy change
	kind:controller	bfd4f2	Codex release controller change
	build:codex-stable	0e8a16	Production Codex Git build
	build:codex-unstable	fbca04	Preview Codex Git build
	build:codex-controller	8250df	Codex release controller
	codex:draft	ededed	Draft; no review action requested
	codex:needs-review	d93f0b	Current topic head needs a qualifying review
	codex:ready	0e8a16	Approved ordinary change is ready for normal merge
	codex:awaiting-plan	fbca04	Reviewed head is waiting for a pinned plan
	codex:planned	c2e0c6	Reviewed head is pinned in the desired build plan
	codex:staged	1d76db	Exact planned head is in a staged build
	codex:integrated	0e8a16	Exact planned head is in the published build
	codex:superseded	cfd3d7	Plan proposal has been replaced or closed
	codex:blocked	b60205	Current state needs intervention before it can advance
	EOF
}

is_full_oid () {
	case "$1" in
	''|*[!0-9a-f]*) return 1 ;;
	esac
	test "${#1}" = 40
}

snapshot_refs () {
	query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){meta:ref(qualifiedName:"refs/heads/meta"){target{oid}}stable:ref(qualifiedName:"refs/heads/codex"){target{oid}}unstable:ref(qualifiedName:"refs/heads/codex-unstable"){target{oid}}stableStage:ref(qualifiedName:"refs/heads/codex-staging"){target{oid}}unstableStage:ref(qualifiedName:"refs/heads/codex-unstable-staging"){target{oid}}}}'
	gh api --hostname github.com graphql \
		-F owner=openai -F name=git -f "query=$query" \
		--jq '[.data.repository.meta.target.oid,
			(.data.repository.stable.target.oid // "-"),
			(.data.repository.unstable.target.oid // "-"),
			(.data.repository.stableStage.target.oid // "-"),
			(.data.repository.unstableStage.target.oid // "-")] | @tsv' \
		>"$state_dir/refs" ||
		die "could not inspect Codex controller and output refs"
	test "$(wc -l <"$state_dir/refs" | tr -d ' ')" = 1 ||
		die "GitHub returned an ambiguous Codex ref snapshot"
	IFS="$tab" read -r meta stable unstable stable_stage unstable_stage \
		<"$state_dir/refs" || die "could not parse Codex ref snapshot"
	is_full_oid "$meta" || die "meta is not a full commit object ID"
	is_full_oid "$stable" || die "codex is not a full commit object ID"
	for oid in "$unstable" "$stable_stage" "$unstable_stage"
	do
		test "$oid" = - || is_full_oid "$oid" ||
			die "Codex ref snapshot contains an invalid object ID"
	done
	test -z "$expected_meta" || test "$meta" = "$expected_meta" ||
		die "meta moved from $expected_meta to $meta"
	git cat-file -e "$meta^{commit}" ||
		die "trusted meta commit '$meta' is not available locally"
	git show "$meta:codex.plan" >"$state_dir/codex.plan" ||
		die "trusted meta has no stable plan"
	git show "$meta:codex.config" >"$state_dir/codex.config" ||
		die "trusted meta has no published-state ledger"
	if test "$unstable" != -
	then
		git show "$meta:codex-unstable.plan" \
			>"$state_dir/codex-unstable.plan" ||
			die "trusted meta has no unstable plan"
	fi
	if test -n "$updates"
	then
		candidate_controller=$(awk -F '\t' \
			'$1 == "controller" { print $3 }' "$inputs")
		candidate_meta=$(awk -F '\t' \
			'$1 == "refs/heads/meta" { print $3 }' "$updates")
		if test "$candidate_controller" = "$meta" &&
			is_full_oid "$candidate_meta"
		then
			git show "$candidate_meta:codex.config" \
				>"$state_dir/candidate.config" ||
				die "candidate meta has no realized-state ledger"
		fi
	fi
}

ensure_labels () {
	test -z "$dry_run" || return 0
	gh api --hostname github.com \
		"repos/$repository/labels?per_page=100" --paginate \
		--jq '.[].name' >"$state_dir/existing-labels" ||
		die "could not inspect repository labels"
	while IFS="$tab" read -r label color description
	do
		if grep -F -x "$label" "$state_dir/existing-labels" \
			>/dev/null
		then
			continue
		fi
		gh api --hostname github.com --method POST \
			"repos/$repository/labels" \
			-f "name=$label" -f "color=$color" \
			-f "description=$description" >/dev/null ||
			die "could not create repository label '$label'"
	done <"$state_dir/managed-labels"
}

has_label () {
	printf '%s\n' "$1" |
	jq -e --arg label "$2" 'index($label) != null' >/dev/null
}

lane_plan () {
	case "$1" in
	codex) printf '%s\n' "$state_dir/codex.plan" ;;
	codex-unstable) printf '%s\n' "$state_dir/codex-unstable.plan" ;;
	*) die "unknown Codex build '$1'" ;;
	esac
}

lane_output () {
	case "$1" in
	codex) printf '%s\n' "$stable" ;;
	codex-unstable) printf '%s\n' "$unstable" ;;
	*) die "unknown Codex build '$1'" ;;
	esac
}

lane_staging () {
	case "$1" in
	codex) printf '%s\n' "$stable_stage" ;;
	codex-unstable) printf '%s\n' "$unstable_stage" ;;
	*) die "unknown Codex build '$1'" ;;
	esac
}

build_label () {
	case "$1" in
	codex) printf '%s\n' build:codex-stable ;;
	codex-unstable) printf '%s\n' build:codex-unstable ;;
	meta) printf '%s\n' build:codex-controller ;;
	*) die "unknown Codex build '$1'" ;;
	esac
}

planned_tip () {
	plan=$(lane_plan "$1")
	test -f "$plan" || return 0
	git config --no-includes --file "$plan" \
		--get "branch.$2.source-tip" || :
}

published_tip () {
	git config --no-includes --file "$state_dir/codex.config" \
		--get "branch.$1.source-tip" || :
}

published_output () {
	git config --no-includes --file "$state_dir/codex.config" \
		--get "$1.output-tip" || :
}

staged_topic () {
	lane=$1
	topic=$2
	source_tip=$3
	staging=$(lane_staging "$lane")
	test "$staging" != - || return 1

	if test -f "$state_dir/candidate.config"
	then
		candidate_tip=$(git config --no-includes \
			--file "$state_dir/candidate.config" \
			--get "branch.$topic.source-tip" || :)
		candidate_output=$(git config --no-includes \
			--file "$state_dir/candidate.config" \
			--get "$lane.output-tip" || :)
		candidate_plan=$(git config --no-includes \
			--file "$state_dir/candidate.config" \
			--get "$lane.applied-plan" || :)
		candidate_update=$(awk -F '\t' \
			-v ref="refs/heads/$lane" \
			'$1 == ref { print $3 }' "$updates")
		plan_path=$(lane_plan "$lane")
		expected_plan=$(git hash-object "$plan_path")
		test "$candidate_tip" = "$source_tip" &&
			test "$candidate_output" = "$staging" &&
			test "$candidate_update" = "$staging" &&
			test "$candidate_plan" = "$expected_plan" && return 0
	fi

	git cat-file -e "$staging^{commit}" 2>/dev/null || return 1
	generated_tip=$(git log --first-parent --max-count=256 \
		--format='%(trailers:key=Codex-Integration,valueonly)' \
		"$staging" |
		awk -v prefix="$topic@" '
			index($0, prefix) == 1 {
				print substr($0, length(prefix) + 1)
				exit
			}
		') || return 1
	test -n "$generated_tip" || return 1
	test "$generated_tip" = "$source_tip"
}

qualifying_approved () {
	pull_number=$1
	lane=$2
	topic=$3
	source_tip=$4
	sh "$script_dir/codex-branch.sh" validate-topic-review \
		--pull-request "$pull_number" --lane "$lane" \
		--topic "$topic" --source-tip "$source_tip" \
		>"$state_dir/review.out" 2>"$state_dir/review.err" &&
		return 0
	if grep -Eq 'could not (inspect|read)' "$state_dir/review.err"
	then
		cat "$state_dir/review.err" >&2
		die "could not verify pull request #$pull_number approval"
	fi
	return 1
}

state_for_topic () {
	lane=$1
	topic=$2
	source_tip=$3
	planned=$(planned_tip "$lane" "$topic")
	if test "$planned" != "$source_tip"
	then
		computed_state=
		return
	fi
	published=$(published_tip "$topic")
	recorded_output=$(published_output "$lane")
	live_output=$(lane_output "$lane")
	if test "$published" = "$source_tip" &&
		test "$recorded_output" = "$live_output"
	then
		computed_state=codex:integrated
	elif staged_topic "$lane" "$topic" "$source_tip"
	then
		computed_state=codex:staged
	else
		computed_state=codex:planned
	fi
}

is_desired_label () {
	label=$1
	test "$label" = "$desired_role" && return 0
	test "$label" = "$desired_build" && return 0
	test "$label" = "$desired_state" && return 0
	test "$label" = codex:blocked && test "$desired_blocked" = true
}

sync_labels () {
	pull_number=$1
	expected_head=$2
	current_labels=$3
	desired_role=$4
	desired_build=$5
	desired_state=$6
	desired_blocked=$7
	block_reason=$8

	if test -n "$dry_run"
	then
		printf '#%s\t%s\t%s\t%s' "$pull_number" "$desired_role" \
			"$desired_build" "$desired_state"
		test "$desired_blocked" != true || printf '\tcodex:blocked'
		test "$block_reason" = - || printf '\t%s' "$block_reason"
		printf '\n'
		return
	fi

	actual_head=$(gh api --hostname github.com \
		"repos/$repository/pulls/$pull_number" --jq .head.sha) ||
		die "could not recheck the head of pull request #$pull_number"
	if test "$actual_head" != "$expected_head"
	then
		printf 'Skipping pull request #%s: its head moved.\n' \
			"$pull_number" >&2
		return
	fi

	while IFS="$tab" read -r label color description
	do
		if is_desired_label "$label"
		then
			if ! has_label "$current_labels" "$label"
			then
				gh api --hostname github.com --method POST \
					"repos/$repository/issues/$pull_number/labels" \
					-f "labels[]=$label" >/dev/null ||
					die "could not add '$label' to pull request #$pull_number"
			fi
		elif has_label "$current_labels" "$label"
		then
			encoded=$(jq -nr --arg label "$label" '$label | @uri')
			gh api --hostname github.com --method DELETE \
				"repos/$repository/issues/$pull_number/labels/$encoded" \
				>/dev/null ||
				die "could not remove '$label' from pull request #$pull_number"
		fi
	done <"$state_dir/managed-labels"
	printf '#%s: %s %s %s\n' "$pull_number" "$desired_role" \
		"$desired_build" "$desired_state"
}

record_classification () {
	pull_number=$1
	expected_head=$2
	current_labels=$3
	desired_role=$4
	desired_build=$5
	desired_state=$6
	desired_blocked=$7
	block_reason=${8:--}
	case "$pull_number" in
	''|*[!0-9]*) die "invalid pull request number '$pull_number'" ;;
	esac
	is_full_oid "$expected_head" ||
		die "pull request #$pull_number has an invalid head SHA"
	case "$desired_role" in
	kind:review-only|kind:auto-plan|kind:plan-policy|kind:controller) ;;
	*) die "pull request #$pull_number has unknown role '$desired_role'" ;;
	esac
	case "$desired_build" in
	build:codex-stable|build:codex-unstable|build:codex-controller) ;;
	*) die "pull request #$pull_number has unknown build '$desired_build'" ;;
	esac
	case "$desired_state" in
	codex:draft|codex:needs-review|codex:ready|codex:awaiting-plan|\
	codex:planned|codex:staged|codex:integrated|codex:superseded) ;;
	*) die "pull request #$pull_number has unknown state '$desired_state'" ;;
	esac
	case "$desired_blocked:$block_reason" in
	false:-|true:blocked:*) ;;
	*) die "pull request #$pull_number has an invalid blocker '$block_reason'" ;;
	esac
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$pull_number" "$expected_head" "$current_labels" "$desired_role" \
		"$desired_build" "$desired_state" "$desired_blocked" \
		"$block_reason" >>"$state_dir/classifications" ||
		die "could not record pull request #$pull_number classification"
}

apply_classifications () {
	cut -f1 "$state_dir/classifications" | LC_ALL=C sort | uniq -d \
		>"$state_dir/duplicate-classifications" ||
		die "could not validate pull request classifications"
	test ! -s "$state_dir/duplicate-classifications" ||
		die "a pull request received more than one classification"
	ensure_labels
	while IFS="$tab" read -r pull_number expected_head current_labels \
		desired_role desired_build desired_state desired_blocked block_reason
	do
		test -n "$pull_number" || continue
		sync_labels "$pull_number" "$expected_head" "$current_labels" \
			"$desired_role" "$desired_build" "$desired_state" \
			"$desired_blocked" "$block_reason"
	done <"$state_dir/classifications"
}

valid_topic_name () {
	lane=$1
	topic=$2
	case "$topic" in
	??/codex/*) ;;
	*) return 1 ;;
	esac
	case "$topic" in
	*-wip|*-stale|??/codex/*/*) return 1 ;;
	esac
	case "$lane:$topic" in
	codex:*-unstable) return 1 ;;
	codex:*) ;;
	codex-unstable:*-unstable) ;;
	*) return 1 ;;
	esac
}

classify_topics () {
	lane=$1
	test "$lane" != codex-unstable || test "$unstable" != - || return 0
	gh pr list --repo "$repository" --state open --base "$lane" \
		--limit 1000 \
		--json number,isDraft,headRefName,headRefOid,headRepository,reviewDecision,labels \
		>"$state_dir/$lane-topics.json" ||
		die "could not list $lane topic pull requests"
	jq -r '
		.[] |
		[(.number | tostring), (.isDraft | tostring),
		 .headRefName, .headRefOid,
		 (.headRepository.nameWithOwner // "-"),
		 (.reviewDecision |
			if . == null or . == "" then "-" else . end),
		 ([.labels[].name] | @json)] | @tsv
	' "$state_dir/$lane-topics.json" >"$state_dir/$lane-topics" ||
		die "could not parse $lane topic pull requests"
	while IFS="$tab" read -r pull_number draft topic source_tip \
		head_repository review_decision current_labels
	do
		test -n "$pull_number" || continue
		blocked=false
		block_reason=-
		if test "$head_repository" != "$repository"
		then
			blocked=true
			block_reason=blocked:foreign-head-repository
		elif ! valid_topic_name "$lane" "$topic"
		then
			blocked=true
			block_reason=blocked:invalid-topic-name
		fi
		state_for_topic "$lane" "$topic" "$source_tip"
		if test -z "$computed_state"
		then
			if test "$draft" = true
			then
				computed_state=codex:draft
			else
				computed_state=codex:needs-review
			fi
			if test "$blocked" = false && test "$draft" = false &&
				test "$review_decision" = APPROVED &&
				qualifying_approved "$pull_number" "$lane" \
					"$topic" "$source_tip"
			then
				computed_state=codex:awaiting-plan
			fi
		fi
		record_classification "$pull_number" "$source_tip" \
			"$current_labels" kind:review-only "$(build_label "$lane")" \
			"$computed_state" "$blocked" "$block_reason"
	done <"$state_dir/$lane-topics"
}

classify_controller () {
	pull_number=$1
	draft=$2
	head_oid=$3
	current_labels=$4
	review_decision=$5
	merge_state=$6

	phase=codex:needs-review
	test "$draft" != true || phase=codex:draft
	test "$draft" = true ||
		test "$review_decision" != APPROVED ||
		phase=codex:ready
	blocked=false
	block_reason=-
	if test "$phase" = codex:ready
	then
		case "$merge_state" in
		DIRTY)
			blocked=true
			block_reason=blocked:merge-conflict
			;;
		BLOCKED)
			blocked=true
			block_reason=blocked:merge-policy
			;;
		esac
	fi
	record_classification "$pull_number" "$head_oid" \
		"$current_labels" kind:controller "$(build_label meta)" \
		"$phase" "$blocked" "$block_reason"
}

classify_meta () {
	: >"$state_dir/controller-heads" ||
		die "could not prepare controller stack inventory"
	gh pr list --repo "$repository" --state all --base meta \
		--limit 1000 \
		--json number,state,isDraft,headRefName,headRefOid,body,labels,reviewDecision,mergeStateStatus,statusCheckRollup \
		>"$state_dir/plans.json" ||
		die "could not list Codex meta pull requests"
	jq -r '
		def field($name):
			[(.body // "" | split("\n")[]) |
			 select(startswith("- " + $name + ": `")) |
			 ltrimstr("- " + $name + ": `") |
			 rtrimstr("`")] | .[0] // "-";
		.[] |
		[(.number | tostring), .state, (.isDraft | tostring),
		 .headRefName, .headRefOid,
		 field("Lane"), field("Action"),
		 (field("Topic") | sub("^refs/heads/"; "")),
		 field("Source tip"),
		 ([.labels[].name] | @json),
		 (any(.statusCheckRollup[]?;
			(.name // .context // "") ==
				"Codex plan admission / Verify pinned manifest" and
			(.conclusion // .state // "") == "FAILURE") | tostring),
		 (.reviewDecision |
			if . == null or . == "" then "-" else . end),
		 (.mergeStateStatus |
			if . == null or . == "" then "-" else . end)] | @tsv
	' "$state_dir/plans.json" >"$state_dir/plans" ||
		die "could not parse Codex meta pull requests"
	while IFS="$tab" read -r pull_number pull_state draft head_ref head_oid \
		lane action topic source_tip current_labels admission_failed \
		review_decision merge_state
	do
		test -n "$pull_number" || continue
		case "$head_ref" in
		codex-plan/*) ;;
		*)
			test "$pull_state" = OPEN || continue
			classify_controller "$pull_number" "$draft" "$head_oid" \
				"$current_labels" "$review_decision" "$merge_state"
			printf '%s\n' "$head_ref" >>"$state_dir/controller-heads" ||
				die "could not retain controller stack root '$head_ref'"
			continue
			;;
		esac
		case "$lane" in
		codex) ;;
		codex-unstable)
			test "$unstable" != - ||
				die "plan pull request #$pull_number targets a disabled preview build"
			;;
		*) die "plan pull request #$pull_number has unknown build '$lane'" ;;
		esac
		case "$action" in
		add|alter) role=kind:auto-plan ;;
		remove|reorder) role=kind:plan-policy ;;
		*) die "plan pull request #$pull_number has unknown action '$action'" ;;
		esac
		blocked=false
		block_reason=-
		case "$pull_state" in
		CLOSED) phase=codex:superseded ;;
		MERGED)
			phase=codex:superseded
			if test "$source_tip" != -
			then
				state_for_topic "$lane" "$topic" "$source_tip"
				test -z "$computed_state" || phase=$computed_state
			fi
			;;
		OPEN)
			if test "$draft" = true
			then
				phase=codex:draft
			elif test "$role" = kind:plan-policy
			then
				phase=codex:needs-review
				test "$review_decision" != APPROVED || phase=codex:ready
			else
				phase=codex:awaiting-plan
			fi
			if test "$source_tip" != - &&
				test "$(planned_tip "$lane" "$topic")" = \
					"$source_tip"
			then
				phase=codex:superseded
			fi
			if test "$phase" != codex:superseded &&
				test "$admission_failed" = true
			then
				blocked=true
				block_reason=blocked:admission-failed
			fi
			;;
		*) die "pull request #$pull_number has unknown state '$pull_state'" ;;
		esac
		record_classification "$pull_number" "$head_oid" \
			"$current_labels" "$role" "$(build_label "$lane")" \
			"$phase" "$blocked" "$block_reason"
	done <"$state_dir/plans"
}

classify_stacked_controllers () {
	gh pr list --repo "$repository" --state open --limit 1000 \
		--json number,isDraft,baseRefName,headRefName,headRefOid,labels,reviewDecision,mergeStateStatus \
		>"$state_dir/open-pull-requests.json" ||
		die "could not list open pull requests for controller stacks"
	jq -r '
		.[] |
		[(.number | tostring), (.isDraft | tostring),
		 .baseRefName, .headRefName, .headRefOid,
		 ([.labels[].name] | @json),
		 (.reviewDecision |
		 if . == null or . == "" then "-" else . end),
		 (.mergeStateStatus |
		 if . == null or . == "" then "-" else . end)] | @tsv
	' "$state_dir/open-pull-requests.json" \
		>"$state_dir/open-pull-requests" ||
		die "could not parse open pull requests for controller stacks"
	: >"$state_dir/stacked-controllers" ||
		die "could not prepare stacked controller inventory"
	while :
	do
		progress=
		while IFS="$tab" read -r pull_number draft base_ref head_ref \
			head_oid current_labels review_decision merge_state
		do
			test -n "$pull_number" || continue
			grep -F -x "$pull_number" "$state_dir/stacked-controllers" \
				>/dev/null 2>&1 && continue
			grep -F -x "$base_ref" "$state_dir/controller-heads" \
				>/dev/null 2>&1 || continue
			classify_controller "$pull_number" "$draft" "$head_oid" \
				"$current_labels" "$review_decision" "$merge_state"
			printf '%s\n' "$pull_number" \
				>>"$state_dir/stacked-controllers" ||
				die "could not retain stacked controller #$pull_number"
			printf '%s\n' "$head_ref" >>"$state_dir/controller-heads" ||
				die "could not retain controller stack head '$head_ref'"
			progress=t
		done <"$state_dir/open-pull-requests"
		test -n "$progress" || break
	done
}

labels >"$state_dir/managed-labels"
: >"$state_dir/classifications"
snapshot_refs
classify_topics codex
classify_topics codex-unstable
classify_meta
classify_stacked_controllers
apply_classifications
