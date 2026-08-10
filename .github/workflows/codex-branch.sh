#!/bin/sh

set -eu

me=codex-branch
tmp_dir=
temporary_worktree=
preserve_worktree=
script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
script_path=${CODEX_ENTRYPOINT:-$script_dir/$(basename "$0")}
meta_config_path=codex.config
stable_plan_path=codex.plan
unstable_plan_path=codex-unstable.plan
release_recovery_path=codex.release-recovery
tab=$(printf '\t')
bot_name='chatgpt-codex-connector[bot]'
bot_email='199175422+chatgpt-codex-connector[bot]@users.noreply.github.com'

say () {
	printf '%s\n' "$*"
}

die () {
	printf '%s: %s\n' "$me" "$*" >&2
	exit 1
}

usage () {
	cat <<-\EOF
	usage: codex-branch check-topic <branch>
	   or: codex-branch rebuild [--local]
		[--enable-unstable | --disable-unstable]
	   or: codex-branch publish <run-id>
	   or: codex-branch initialize [--remote <remote>] [--base <branch>]
		[--codex <branch>] [--output <path>] [--require-automation]
	   or: codex-branch refresh [--session <directory>]
		[--remote <remote>] [--base <branch>] [--codex <branch>]
		[--rerere-from <branch>] [--require-automation]
		[--enable-unstable | --disable-unstable]
	   or: codex-branch rewrite [--remote <remote>] [--base <branch>]
		[--codex <branch>] [--rerere-from <branch>]
		[--result <path>] [--updates <path>] [--inputs <path>]
		[--bundle <path>] [--failure <path>]
		[--worktree <path>] [--require-automation]
		[--enable-unstable | --disable-unstable]
	   or: codex-branch verify-inputs [--remote <remote>]
		[--base <branch>] [--codex <branch>] <snapshot>
	   or: codex-branch validate-plan-transition [--remote <remote>]
		--base-commit <oid> --head-commit <oid>
	   or: codex-branch validate-topic-review
		--pull-request <number> --lane <codex|codex-unstable>
		--topic <branch> --source-tip <oid>
	   or: codex-branch reconcile-pr-state [--expected-meta <oid>]
		[--inputs <path> --updates <path>] [--dry-run]
	   or: codex-branch propose-plan [--remote <remote>]
		--lane <codex|codex-unstable> --topic <branch>
		[--source-tip <oid>] [--review-pr <number>]
		[--merge <branch>] [--after <branch>]
		[--action <auto|add|alter|remove|reorder>]
		[--expected-meta <oid>]
		[--plan-branch <codex-plan/name>]
		[--bootstrap-authorization <text>] [--no-push]
	   or: codex-branch recover-release-pin [--remote <remote>]
		--expected-meta <oid> --authorization <text> [--no-push]
	   or: codex-branch verify-output --inputs <path>
		--updates <path> --result <path> [--require-automation]
		[--stable-recovery]
	   or: codex-branch stage [--remote <remote>] [--staging <branch>]
		--inputs <path> --updates <path> [--require-automation]
	   or: codex-branch promote [--remote <remote>] [--staging <branch>]
		--inputs <path> --updates <path> [--require-automation]
	   or: codex-branch resolve [--remote <remote>] [--base <branch>]
		[--codex <branch>] --inputs-oid <oid> [--worktree <path>]
	   or: codex-branch continue --worktree <path>
	   or: codex-branch publish-topics --worktree <path>
	EOF
}

cleanup () {
	if test -n "$temporary_worktree" && test -z "$preserve_worktree"
	then
		git -c core.fsmonitor=false worktree remove --force \
			"$temporary_worktree" >/dev/null 2>&1 || :
	fi
	if test -n "$tmp_dir" && test -d "$tmp_dir"
	then
		rm -rf "$tmp_dir"
	fi
}

trap cleanup EXIT HUP INT TERM

make_tmp_dir () {
	test -z "$tmp_dir" || return 0
	tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-branch.XXXXXX") ||
		die "could not create temporary directory"
}

require_arg () {
	test $# -ge 2 || {
		usage >&2
		exit 129
	}
}

require_full_repository () {
	test "$(git rev-parse --is-shallow-repository)" = false ||
		die "a complete, non-shallow repository is required"
}

require_clean_worktree () (
	worktree=$1
	test -z "$(git -C "$worktree" -c core.fsmonitor=false status --porcelain)" ||
		die "worktree '$worktree' must be clean"
)

require_clean_publish_worktrees () (
	caller_top=$(git rev-parse --show-toplevel) ||
		die "could not find the publishing worktree"
	caller=$(CDPATH= cd "$caller_top" && pwd -P) ||
		die "could not resolve the publishing worktree"
	meta_input=$(CDPATH= cd "$1" && pwd -P) ||
		die "could not resolve the Meta worktree"
	meta_top=$(git -C "$meta_input" rev-parse --show-toplevel) ||
		die "could not find the Meta worktree"
	meta=$(CDPATH= cd "$meta_top" && pwd -P) ||
		die "could not resolve the Meta worktree"
	test "$meta" = "$meta_input" ||
		die "CODEX_META_WORKTREE is not a worktree root"
	caller_common=$(git -C "$caller" rev-parse --path-format=absolute \
		--git-common-dir) || die "could not locate the publishing repository"
	meta_common=$(git -C "$meta" rev-parse --path-format=absolute \
		--git-common-dir) || die "could not locate the Meta repository"
	test "$caller_common" = "$meta_common" ||
		die "Meta must be a linked worktree of the publishing repository"
	require_clean_worktree "$meta"
	if test "$caller" = "$meta"
	then
		exit 0
	fi
	case "$meta" in
	"$caller"/*)
		relative_meta=${meta#"$caller"/}
		test -n "$relative_meta" &&
			test "$relative_meta" != "$meta" ||
			die "could not locate the nested Meta worktree"
		dirty=$(git -C "$caller" -c core.fsmonitor=false status \
			--porcelain -- . ":(exclude,literal)$relative_meta") ||
			die "could not inspect the publishing worktree"
		;;
	*)
		dirty=$(git -C "$caller" -c core.fsmonitor=false status --porcelain) ||
			die "could not inspect the publishing worktree"
		;;
	esac
	test -z "$dirty" || die "worktree '$caller' must be clean"
)

resolve_commit () {
	git rev-parse --verify "$1^{commit}" 2>/dev/null ||
		die "'$1' is not a commit"
}

require_full_commit_oid () {
	oid=$1
	resolved=$(resolve_commit "$oid")
	test "$resolved" = "$oid" ||
		die "'$oid' is not a full commit object ID"
}

require_full_blob_oid () {
	oid=$1
	resolved=$(git rev-parse --verify "$oid^{blob}" 2>/dev/null) ||
		die "'$oid' is not a blob"
	test "$resolved" = "$oid" ||
		die "'$oid' is not a full blob object ID"
}

plan_path_for_lane () (
	case "$1" in
	codex) printf '%s\n' "$stable_plan_path" ;;
	codex-unstable) printf '%s\n' "$unstable_plan_path" ;;
	*) die "unknown Codex lane '$1'" ;;
	esac
)

pin_ref_for_tip () (
	printf 'refs/heads/codex-pins/%s\n' "$1"
)

require_bootstrap_pin_guard () {
	ruleset_ids=$(gh api --hostname github.com \
		"repos/openai/git/rulesets?includes_parents=false&targets=branch" \
		--paginate --jq '
			.[] |
			select(.name == "Keep Codex pins immutable" and
				.target == "branch" and .enforcement == "active") |
			.id
		') ||
		die "could not inspect the immutable Codex pin guard"
	test -n "$ruleset_ids" ||
		die "pre-v3 bootstrap requires active immutable Codex pin guard"
	test "$(printf '%s\n' "$ruleset_ids" | sed '/^$/d' |
		wc -l | tr -d ' ')" = 1 ||
		die "pre-v3 bootstrap found ambiguous immutable Codex pin guards"
	ruleset_id=$(printf '%s\n' "$ruleset_ids" | sed -n '1p')
	case "$ruleset_id" in
	''|*[!0-9]*) die "immutable Codex pin guard has invalid ID '$ruleset_id'" ;;
	esac
	guard=$(gh api --hostname github.com \
		"repos/openai/git/rulesets/$ruleset_id" --jq '
			.name == "Keep Codex pins immutable" and
			.target == "branch" and
			.enforcement == "active" and
			.conditions.ref_name.include ==
				["refs/heads/codex-pins/*"] and
			.conditions.ref_name.exclude == [] and
			([.rules[].type] | sort) == ["deletion", "update"] and
			([.rules[] | select(.type == "update") |
				.parameters.update_allows_fetch_and_merge]) ==
				[false] and
			all((.bypass_actors // [])[];
				.actor_type == "OrganizationAdmin")
		') ||
		die "could not verify the immutable Codex pin guard"
	test "$guard" = true ||
		die "pre-v3 bootstrap requires the checked-in immutable Codex pin guard"
}

remote_ref () {
	printf 'refs/remotes/%s/%s\n' "$1" "$2"
}

is_topic_name () (
	name=$1
	git check-ref-format "refs/heads/$name" >/dev/null 2>&1 || return 1

	case "$name" in
	??/codex/?*) ;;
	*) return 1 ;;
	esac

	topic=${name#??/codex/}
	case "$topic" in
	*/*) return 1 ;;
	esac
)

is_active_topic_name () (
	is_topic_name "$1" || return 1
	case "$1" in
	*-wip|*-stale) return 1 ;;
	esac
)

is_stable_topic_name () (
	is_active_topic_name "$1" || return 1
	case "$1" in
	*-unstable) return 1 ;;
	esac
)

is_unstable_topic_name () (
	is_active_topic_name "$1" || return 1
	case "$1" in
	*-unstable) ;;
	*) return 1 ;;
	esac
)

null_oid () {
	git hash-object --stdin </dev/null |
		sed 's/./0/g'
}

is_null_oid () (
	case "$1" in
	''|*[!0]*) return 1 ;;
	esac
	test "${#1}" = "$(git hash-object --stdin </dev/null | tr -d '\n' | wc -c | tr -d ' ')"
)

unstable_sentinel_is_canonical () (
	base=$1
	head=$2
	test "$(git show -s --format=%P "$head")" = "$base" &&
		test "$(git rev-parse "$head^{tree}")" = \
		"$(git rev-parse "$base^{tree}")" &&
		test "$(git show -s --format=%s "$head")" = \
		'Initialize codex-unstable' &&
		test "$(git show -s --format=%an "$head")" = "$bot_name" &&
		test "$(git show -s --format=%ae "$head")" = "$bot_email" &&
		test "$(git show -s --format=%cn "$head")" = "$bot_name" &&
		test "$(git show -s --format=%ce "$head")" = "$bot_email"
)

check_topic () {
	test $# = 1 || {
		usage >&2
		exit 129
	}

	is_topic_name "$1" || die "'$1' does not match ??/codex/*"
	case "$1" in
	*-wip|*-stale)
		die "'$1' is inactive because of its suffix"
		;;
	esac
}

contains_integration_marker () (
	base_oid=$1
	head_oid=$2
	markers=$(git log \
		--format='%(trailers:key=Codex-Integration,valueonly)' \
		"$base_oid..$head_oid")
	test -n "$markers"
)

legacy_control_paths_unchanged () (
	base_oid=$1
	head_oid=$2
	git diff --quiet "$base_oid" "$head_oid" -- \
		.github/CODEX.md \
		.github/rulesets/codex-branch.json \
		.github/rulesets/codex-meta.json \
		.github/rulesets/codex-pins.json \
		.github/rulesets/codex-pins-immutable.json \
		.github/rulesets/codex-plan-branches.json \
		.github/rulesets/codex-topics.json \
		.github/rulesets/codex-unstable-branch.json \
		.github/workflows/codex-admission.yml \
		.github/workflows/codex-plan-admission.yml \
		.github/workflows/codex-plan-propose.yml \
		.github/workflows/codex-pr-state.sh \
		.github/workflows/codex-pr-state.yml \
		.github/workflows/codex-topic.yml \
		.github/workflows/codex.yml \
		.github/workflows/codex-branch.sh \
		codex \
		publish \
		rebuild \
		codex.plan \
		codex-unstable.plan \
		codex.release-recovery \
		codex.config \
		t/t9905-codex-branch.sh
)

meta_control_paths_unchanged () (
	base_oid=$1
	head_oid=$2
	git diff --quiet "$base_oid" "$head_oid" -- \
		.github/CODEX.md \
		.github/rulesets/codex-branch.json \
		.github/rulesets/codex-meta.json \
		.github/rulesets/codex-pins.json \
		.github/rulesets/codex-pins-immutable.json \
		.github/rulesets/codex-plan-branches.json \
		.github/rulesets/codex-topics.json \
		.github/rulesets/codex-unstable-branch.json \
		.github/workflows/codex-admission.yml \
		.github/workflows/codex-plan-admission.yml \
		.github/workflows/codex-plan-propose.yml \
		.github/workflows/codex-pr-state.sh \
		.github/workflows/codex-pr-state.yml \
		.github/workflows/codex-topic.yml \
		.github/workflows/codex-branch.sh \
		.github/workflows/main.yml \
		codex \
		publish \
		rebuild \
		codex.plan \
		codex-unstable.plan \
		codex.release-recovery \
		codex.config \
		t/t9905-codex-branch.sh &&
	git diff --quiet "$base_oid" "$head_oid" -- \
		':(glob).github/workflows/*.yml' \
		':(glob).github/workflows/*.yaml' \
		':(exclude).github/workflows/codex.yml' \
		':(exclude).github/workflows/codex-release.yml'
)

write_automation_workflow () {
	cat <<-'EOF'
name: Refresh codex

on:
  schedule:
    - cron: '*/5 * * * *'
  workflow_dispatch:
    inputs:
      operation:
        description: Refresh, scan, remove, or reorder a pinned topic
        type: choice
        options:
          - refresh
          - scan
          - remove
          - reorder
        default: refresh
      lane:
        description: codex or codex-unstable for a plan operation
        required: false
        type: string
      topic:
        description: Exact topic branch for a plan operation
        required: false
        type: string
      after:
        description: Existing topic or root for reorder
        required: false
        type: string
      plan_branch:
        description: Optional codex-plan/* branch name
        required: false
        type: string
  pull_request_target:
    branches:
      - meta
    types:
      - opened
      - reopened
      - synchronize
      - ready_for_review

permissions:
  actions: read
  contents: read
  pull-requests: read

jobs:
  refresh:
    if: >-
      github.event_name == 'workflow_dispatch' &&
      github.ref == 'refs/heads/codex' &&
      inputs.operation == 'refresh'
    uses: openai/git/.github/workflows/codex.yml@meta
  topic_plan_scan:
    name: Find one approved topic plan
    if: >-
      github.event_name == 'schedule' ||
      (github.event_name == 'workflow_dispatch' &&
       github.ref == 'refs/heads/codex' &&
       inputs.operation == 'scan')
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      pull-requests: read
    concurrency:
      group: codex-topic-plan-scan
      cancel-in-progress: false
    outputs:
      lane: ${{ steps.reviewed.outputs.lane }}
      topic: ${{ steps.reviewed.outputs.topic }}
      source_tip: ${{ steps.reviewed.outputs.source_tip }}
      review_pr: ${{ steps.reviewed.outputs.review_pr }}
    env:
      GH_TOKEN: ${{ github.token }}
    steps:
      - name: Pin trusted meta
        id: meta
        run: |
          set -euo pipefail
          test "$GITHUB_REPOSITORY" = openai/git
          test "$GITHUB_REF" = refs/heads/codex
          sha=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/meta" \
            --jq .object.sha)
          case "$sha" in
          ''|*[!0-9a-f]*) exit 1 ;;
          esac
          test "${#sha}" = 40
          printf 'sha=%s\n' "$sha" >>"$GITHUB_OUTPUT"

      - name: Check out trusted meta
        uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          repository: ${{ github.repository }}
          ref: ${{ steps.meta.outputs.sha }}
          fetch-depth: 0
          persist-credentials: false

      - name: Find one exact approved topic PR
        id: reviewed
        env:
          META_SHA: ${{ steps.meta.outputs.sha }}
        run: |
          set -euo pipefail

          die () {
            printf '%s\n' "$*" >&2
            exit 1
          }

          test "$GITHUB_REPOSITORY" = openai/git
          test "$GITHUB_REF" = refs/heads/codex ||
            die "topic scan must run from the trusted default branch"
          test "$(git rev-parse HEAD)" = "$META_SHA" ||
            die "trusted checkout does not match pinned meta"
          gh auth setup-git
          mkdir -p "$RUNNER_TEMP/codex-plan-scan"
          for lane in codex codex-unstable
          do
            case "$lane" in
            codex) plan=codex.plan ;;
            codex-unstable) plan=codex-unstable.plan ;;
            esac
            test -f "$plan" ||
              die "trusted meta has no $plan"
            gh pr list --repo "$GITHUB_REPOSITORY" --state open \
              --base "$lane" --limit 1000 \
              --json number,isDraft,headRefName,headRefOid,headRepository,reviewDecision |
              jq -r --arg lane "$lane" '
                .[] |
                select(.isDraft | not) |
                select(.reviewDecision == "APPROVED") |
                select(.headRepository.nameWithOwner == "openai/git") |
                [$lane, .headRefName, .headRefOid,
                 (.number | tostring)] | @tsv
              '
          done | sort -k4,4n >"$RUNNER_TEMP/codex-plan-scan/candidates"

          while IFS=$'\t' read -r lane topic source_tip review_pr
          do
            test -n "$review_pr" || continue
            case "$review_pr" in
            *[!0-9]*) die "approved topic PR has invalid number '$review_pr'" ;;
            esac
            case "$source_tip" in
            *[!0-9a-f]*|'') die "approved topic PR has invalid source SHA" ;;
            esac
            test "${#source_tip}" = 40 ||
              die "approved topic PR has invalid source SHA"
            git check-ref-format "refs/heads/$topic" >/dev/null 2>&1 ||
              die "approved topic PR has invalid branch '$topic'"
            case "$topic" in
            ??/codex/*) ;;
            *) continue ;;
            esac
            suffix=${topic#??/codex/}
            case "$suffix" in
            ''|*/*|*-wip|*-stale) continue ;;
            esac
            case "$lane" in
            codex)
              case "$topic" in
              *-unstable) continue ;;
              esac
              plan=codex.plan
              ;;
            codex-unstable)
              case "$topic" in
              *-unstable) ;;
              *) continue ;;
              esac
              plan=codex-unstable.plan
              ;;
            *) die "approved topic PR has invalid lane '$lane'" ;;
            esac
            pinned=$(git config --no-includes \
              --file "$plan" \
              --get "branch.$topic.source-tip" || :)
            test "$pinned" = "$source_tip" && continue
            short=$(printf '%.12s' "$source_tip")
            slug=${topic##*/}
            plan_branch=codex-plan/$lane-$slug-$short
            pending=$(gh pr list --repo "$GITHUB_REPOSITORY" \
              --state open --base meta --head "$plan_branch" \
              --json number --jq '.[0].number // empty') ||
              die "could not inspect pending Codex plan PR"
            test -n "$pending" && continue
            if ! sh .github/workflows/codex-branch.sh propose-plan \
              --remote origin --lane "$lane" --topic "$topic" \
              --action auto --source-tip "$source_tip" \
              --review-pr "$review_pr" --expected-meta "$META_SHA" \
              --no-push >/dev/null
            then
              printf 'skipping approved topic PR #%s: preflight failed\n' \
                "$review_pr" >&2
              continue
            fi
            {
              printf 'lane=%s\n' "$lane"
              printf 'topic=%s\n' "$topic"
              printf 'source_tip=%s\n' "$source_tip"
              printf 'review_pr=%s\n' "$review_pr"
            } >>"$GITHUB_OUTPUT"
            exit 0
          done <"$RUNNER_TEMP/codex-plan-scan/candidates"
  topic_plan_propose:
    name: Propose reviewed topic plan
    needs: topic_plan_scan
    if: needs.topic_plan_scan.outputs.review_pr != ''
    permissions:
      contents: read
      pull-requests: read
    uses: openai/git/.github/workflows/codex-plan-propose.yml@meta
    with:
      lane: ${{ needs.topic_plan_scan.outputs.lane }}
      topic: ${{ needs.topic_plan_scan.outputs.topic }}
      action: auto
      source_tip: ${{ needs.topic_plan_scan.outputs.source_tip }}
      review_pr: ${{ needs.topic_plan_scan.outputs.review_pr }}
  policy_plan_propose:
    name: Propose explicit plan policy
    if: >-
      github.event_name == 'workflow_dispatch' &&
      github.ref == 'refs/heads/codex' &&
      (inputs.operation == 'remove' || inputs.operation == 'reorder')
    permissions:
      contents: read
      pull-requests: read
    uses: openai/git/.github/workflows/codex-plan-propose.yml@meta
    with:
      lane: ${{ inputs.lane }}
      topic: ${{ inputs.topic }}
      action: ${{ inputs.operation }}
      after: ${{ inputs.after }}
      plan_branch: ${{ inputs.plan_branch }}
  plan_admission:
    name: Codex plan admission
    if: >-
      github.event_name == 'pull_request_target' &&
      github.event.pull_request.base.ref == 'meta'
    permissions:
      contents: read
      pull-requests: write
    uses: openai/git/.github/workflows/codex-plan-admission.yml@meta
  pr_state:
    name: Reconcile Codex pull request state
    if: >-
      github.event_name == 'schedule' ||
      (github.event_name == 'workflow_dispatch' &&
       github.ref == 'refs/heads/codex' &&
       inputs.operation == 'scan')
    permissions:
      contents: read
      issues: write
      pull-requests: write
    uses: openai/git/.github/workflows/codex-pr-state.yml@meta
	EOF
}

write_previous_pinned_automation_workflow () {
	write_automation_workflow | sed '/^  pr_state:$/,$d'
}

write_previous_automation_workflow () {
	cat <<-'EOF'
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

write_stable_automation_workflow () {
	cat <<-'EOF'
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

write_legacy_automation_workflow () {
	cat <<-'EOF'
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

automation_workflow_is_latest () {
	head_oid=$1
	make_tmp_dir
	git show "$head_oid:.github/workflows/codex.yml" \
		>"$tmp_dir/actual-automation.yml" 2>/dev/null || return 1
	write_automation_workflow >"$tmp_dir/expected-automation.yml"
	cmp -s "$tmp_dir/expected-automation.yml" \
		"$tmp_dir/actual-automation.yml"
}

automation_workflow_is_current () {
	if automation_workflow_is_latest "$1"
	then
		return 0
	fi
	write_previous_pinned_automation_workflow \
		>"$tmp_dir/expected-automation.yml"
	cmp -s "$tmp_dir/expected-automation.yml" \
		"$tmp_dir/actual-automation.yml"
}

automation_workflow_is_reviewed () {
	head_oid=$1
	if automation_workflow_is_current "$head_oid"
	then
		return 0
	fi
	write_previous_automation_workflow >"$tmp_dir/expected-automation.yml"
	if cmp -s "$tmp_dir/expected-automation.yml" \
		"$tmp_dir/actual-automation.yml"
	then
		return 0
	fi
	write_stable_automation_workflow >"$tmp_dir/expected-automation.yml"
	cmp -s "$tmp_dir/expected-automation.yml" \
		"$tmp_dir/actual-automation.yml"
}

automation_workflow_matches () {
	head_oid=$1
	if automation_workflow_is_reviewed "$head_oid"
	then
		return 0
	fi
	write_legacy_automation_workflow >"$tmp_dir/expected-automation.yml"
	cmp -s "$tmp_dir/expected-automation.yml" \
		"$tmp_dir/actual-automation.yml"
}

extract_release_trigger () {
	head_oid=$1
	output=$2
	make_tmp_dir
	git show "$head_oid:.github/workflows/codex-release.yml" \
		>"$tmp_dir/codex-release.yml" 2>/dev/null || return 1
	test "$(grep -c '^on:$' "$tmp_dir/codex-release.yml")" = 1 || return 1
	awk '
		$0 == "on:" && !found {
			found = 1
			in_trigger = 1
		}
		in_trigger && $0 == "" { exit }
		in_trigger {
			if (seen && $0 !~ /^[[:space:]]/) exit
			print
			seen = 1
		}
		END { if (!found) exit 1 }
	' "$tmp_dir/codex-release.yml" >"$output"
}

release_workflow_has_codex_trigger () {
	head_oid=$1
	make_tmp_dir
	extract_release_trigger "$head_oid" "$tmp_dir/release-trigger" || return 1
	cat >"$tmp_dir/expected-release-trigger" <<-'EOF'
	on:
	  push:
	    branches:
	      - codex
	EOF
	cmp -s "$tmp_dir/expected-release-trigger" \
		"$tmp_dir/release-trigger"
}

release_workflow_has_dual_trigger () {
	head_oid=$1
	make_tmp_dir
	extract_release_trigger "$head_oid" "$tmp_dir/release-trigger" || return 1
	cat >"$tmp_dir/expected-release-trigger" <<-'EOF'
	on:
	  push:
	    branches:
	      - codex
	      - codex-unstable
	EOF
	cmp -s "$tmp_dir/expected-release-trigger" \
		"$tmp_dir/release-trigger"
}

release_workflow_is_reviewed () {
	head_oid=$1
	make_tmp_dir
	if ! git cat-file -e \
		"$head_oid:.github/workflows/codex-release.yml" 2>/dev/null
	then
		return 0
	fi
	if ! release_workflow_has_codex_trigger "$head_oid" &&
		! release_workflow_has_dual_trigger "$head_oid"
	then
		return 1
	fi
	git show "$head_oid:.github/workflows/codex-release.yml" \
		>"$tmp_dir/codex-release.yml" 2>/dev/null || return 1
	! grep -E \
		'CODEX_BRANCH_TOKEN|CODEX_BRANCH_MANAGER_TOKEN|CODEX_DEPLOY_KEY|codex-publish|ci-token-gh-installation-token-codex-branch-manager|secret-broker-github-action' \
		"$tmp_dir/codex-release.yml" >/dev/null &&
	! grep -F 'environment' "$tmp_dir/codex-release.yml" >/dev/null &&
	! grep -F 'secrets' "$tmp_dir/codex-release.yml" >/dev/null
}

extract_release_job () (
	workflow=$1
	name=$2
	output=$3
	awk -v name="$name" '
		$0 == "  " name ":" {
			if (found++) exit 1
			active = 1
		}
		active && $0 ~ /^  [^[:space:]]/ &&
			$0 != "  " name ":" { active = 0 }
		active { print }
		END { if (found != 1) exit 1 }
	' "$workflow" >"$output"
)

upgrade_release_publication_job () {
	old_job=$1
	output=$2
	test "$(grep -F -x -c '    runs-on: ubuntu-24.04' "$old_job")" = 1 ||
		return 1
	test "$(grep -F -x -c '          set -euo pipefail' "$old_job")" = 1 ||
		return 1
	test "$(grep -F -x -c \
		'              --get codex.output-tip)' "$old_job")" = 1 ||
		return 1
	awk '
		$0 == "    runs-on: ubuntu-24.04" {
			print
			print "    if: github.event.deleted == false"
			next
		}
		$0 == "          set -euo pipefail" {
			print
			print "          case \"$GITHUB_REF\" in"
			print "          refs/heads/codex)"
			print "            output_key=codex.output-tip"
			print "            ;;"
			print "          refs/heads/codex-unstable)"
			print "            output_key=codex-unstable.output-tip"
			print "            ;;"
			print "          *)"
			print "            printf \047unexpected release ref: %s\\n\047 \"$GITHUB_REF\" >&2"
			print "            exit 1"
			print "            ;;"
			print "          esac"
			next
		}
		$0 == "              --get codex.output-tip)" {
			print "              --get \"$output_key\")"
			next
		}
		{ print }
	' "$old_job" >"$output"
}

release_publication_job_is_dual () {
	job=$1
	test "$(grep -F -x -c \
		'    if: github.event.deleted == false' "$job")" = 1 &&
	test "$(grep -F -x -c \
		'          case "$GITHUB_REF" in' "$job")" = 1 &&
	test "$(grep -F -x -c \
		'          refs/heads/codex)' "$job")" = 1 &&
	test "$(grep -F -x -c \
		'            output_key=codex.output-tip' "$job")" = 1 &&
	test "$(grep -F -x -c \
		'          refs/heads/codex-unstable)' "$job")" = 1 &&
	test "$(grep -F -x -c \
		'            output_key=codex-unstable.output-tip' "$job")" = 1 &&
	test "$(grep -F -x -c \
		'              --get "$output_key")' "$job")" = 1
}

release_publication_controls_preserved () (
	published=$1
	candidate=$2
	make_tmp_dir
	old_workflow=$tmp_dir/published-release.yml
	new_workflow=$tmp_dir/candidate-release.yml
	if ! git show "$published:.github/workflows/codex-release.yml" \
		>"$old_workflow" 2>/dev/null
	then
		return 0
	fi
	if ! grep -F -x '  publication:' "$old_workflow" >/dev/null
	then
		return 0
	fi
	git show "$candidate:.github/workflows/codex-release.yml" \
		>"$new_workflow" 2>/dev/null || return 1
	extract_release_job "$old_workflow" publication \
		"$tmp_dir/published-publication" || return 1
	extract_release_job "$new_workflow" publication \
		"$tmp_dir/candidate-publication" || return 1
	if release_workflow_has_dual_trigger "$published"
	then
		release_workflow_has_dual_trigger "$candidate" || return 1
	fi
	if release_workflow_has_dual_trigger "$candidate"
	then
		if ! cmp -s "$tmp_dir/published-publication" \
			"$tmp_dir/candidate-publication"
		then
			release_workflow_has_codex_trigger "$published" || return 1
			upgrade_release_publication_job \
				"$tmp_dir/published-publication" \
				"$tmp_dir/expected-publication" || return 1
			cmp -s "$tmp_dir/expected-publication" \
				"$tmp_dir/candidate-publication" || return 1
		fi
		release_publication_job_is_dual \
			"$tmp_dir/candidate-publication" || return 1
	else
		cmp -s "$tmp_dir/published-publication" \
			"$tmp_dir/candidate-publication" || return 1
	fi
	extract_release_job "$old_workflow" version \
		"$tmp_dir/published-version" || return 1
	extract_release_job "$new_workflow" version \
		"$tmp_dir/candidate-version" || return 1
	for workflow in "$tmp_dir/published-version" \
		"$tmp_dir/candidate-version"
	do
		test "$(grep -c '^    needs:' "$workflow")" = 1 || return 1
		test "$(grep -c '^    if:' "$workflow")" = 1 || return 1
		test "$(grep -F -x -c '    needs: publication' "$workflow")" = 1 ||
			return 1
		test "$(grep -F -x -c \
			"    if: needs.publication.outputs.published == 'true'" \
			"$workflow")" = 1 || return 1
	done
)

authenticate_pending_codex_merge () (
	remote=$1
	published=$2
	current=$3
	output=$4
	snapshot_head=${5:-}
	lane=${6:-codex}
	state=$output.state
	mkdir -p "$state" || die "could not prepare Codex admission verification"

	git merge-base --is-ancestor "$published" "$current" ||
		die "current codex no longer contains the output recorded by $meta_config_path"
	git rev-list --first-parent "$published..$current" >"$state/delta" ||
		die "could not inspect pending Codex pull-request merges"
	count=$(wc -l <"$state/delta" | tr -d ' ')
	test "$count" -le 1 ||
		die "more than one pending Codex pull-request merge"
	test "$count" = 1 ||
		die "could not authenticate the merged Codex pull request"
	merge=$(sed -n '1p' "$state/delta")
	test "$merge" = "$current" ||
		die "could not authenticate the merged Codex pull request"
	parents=$(git show -s --format=%P "$merge") ||
		die "could not inspect the pending Codex pull-request merge"
	set -- $parents
	test $# = 2 && test "$1" = "$published" ||
		die "pending Codex merge is not a normal two-parent merge"
	head=$2
	if ! git merge-tree --write-tree "$published" "$head" \
		>"$state/merge-tree" 2>/dev/null
	then
		die "pending Codex merge contains an unreviewed conflict resolution"
	fi
	test "$(wc -l <"$state/merge-tree" | tr -d ' ')" = 1 &&
		test "$(sed -n '1p' "$state/merge-tree")" = \
		"$(git rev-parse "$merge^{tree}")" ||
		die "pending Codex merge contains changes outside its reviewed topic"

	if ! gh api --hostname github.com --paginate \
		"repos/openai/git/commits/$merge/pulls?per_page=100" \
		--jq '.[] | [.number, .state, (.merged_at // "-"),
			(.merge_commit_sha // "-"), (.base.repo.full_name // "-"),
			.base.ref, (.head.repo.full_name // "-"), .head.ref,
			.head.sha, (.draft | tostring), (.user.login // "-")] | @tsv' \
		>"$state/pull-requests"
	then
		die "could not authenticate the merged Codex pull request"
	fi
	awk -F '\t' -v merge="$merge" -v head="$head" -v base="$lane" '
		NF == 11 && $1 ~ /^[0-9]+$/ && $2 == "closed" &&
		$3 != "-" && $4 == merge && $5 == "openai/git" &&
		$6 == base && $7 == "openai/git" && $9 == head &&
		$10 == "false" && $11 != "-" { print }
	' "$state/pull-requests" >"$state/matching-pull-requests" ||
		die "could not authenticate the merged Codex pull request"
	test "$(wc -l <"$state/matching-pull-requests" | tr -d ' ')" = 1 ||
		die "could not authenticate the merged Codex pull request"
	IFS="$tab" read -r number pr_state merged_at merge_oid \
		base_repository base_name head_repository name head_oid draft author \
		<"$state/matching-pull-requests" ||
		die "could not authenticate the merged Codex pull request"
	case "$lane" in
	codex)
		is_stable_topic_name "$name" ||
			die "could not authenticate the merged Codex pull request"
		;;
	codex-unstable)
		is_unstable_topic_name "$name" ||
			die "could not authenticate the merged unstable Codex pull request"
		;;
	*) die "cannot authenticate unknown Codex output '$lane'" ;;
	esac
	if test "$remote" = -
	then
		current_head=$snapshot_head
	else
		current_head=$(git rev-parse --verify \
			"$(remote_ref "$remote" "$name")^{commit}" 2>/dev/null) ||
			die "could not authenticate the merged Codex pull request"
	fi
	test "$current_head" = "$head" ||
		die "could not authenticate the merged Codex pull request"

	if ! gh api --hostname github.com --paginate \
		"repos/openai/git/pulls/$number/reviews?per_page=100" \
		--jq '.[] | [.user.login, .state, (.commit_id // "-"),
			.author_association] | @tsv' >"$state/reviews"
	then
		die "could not authenticate the merged Codex pull request"
	fi
	has_qualifying_current_review "$state/reviews" "$author" "$head" \
		openai/git "$number" "$state/review-candidates" ||
		die "pending Codex pull request has no qualifying approval"
	printf '%s\t%s\t%s\t%s\n' "$name" "$head" "$number" "$merge" \
		>"$output" || die "could not record the reviewed Codex admission"
)

collect_topics () (
	remote=$1
	output=$2
	published_state=$3
	codex_oid=$4
	base_oid=$5
	lane=${6:-codex}
	root=refs/remotes/$remote/
	admission=$output.admission
	: >"$admission"

	if test -z "$published_state"
	then
		git for-each-ref --format='%(objectname)%09%(refname)' "$root" |
		while IFS="$tab" read -r oid ref
		do
			name=${ref#"$root"}
			if is_stable_topic_name "$name"
			then
				printf '%s\t%s\n' "$name" "$oid"
			fi
		done | LC_ALL=C sort >"$output"
		test -s "$output" ||
			die "no active ??/codex/* topic branches were found"
		exit 0
	fi

	if test "$lane" = codex-unstable
	then
		published=$published_state/published-unstable-topics
		if test "$(state_value "$published_state" config-version)" = 2
		then
			published_codex=$(state_value "$published_state" \
				published-unstable-oid)
		else
			published_codex=$(null_oid)
		fi
	else
		published=$published_state/published-topics
		published_codex=$(state_value "$published_state" published-codex-oid)
	fi
	if test "$published_codex" != "$codex_oid"
	then
		! is_null_oid "$published_codex" && ! is_null_oid "$codex_oid" ||
			die "the '$lane' output does not match its published state"
		authenticate_pending_codex_merge "$remote" "$published_codex" \
			"$codex_oid" "$admission" '' "$lane"
	fi

	: >"$output.unsorted"
	while IFS="$tab" read -r name published_tip prerequisite
	do
		ref=$(remote_ref "$remote" "$name")
		if oid=$(git rev-parse --verify "$ref^{commit}" 2>/dev/null)
		then
			printf '%s\t%s\n' "$name" "$oid" >>"$output.unsorted" ||
				die "could not collect enrolled Codex topic '$name'"
		fi
	done <"$published"
	if test -s "$admission"
	then
		IFS="$tab" read -r name oid number merge <"$admission" ||
			die "could not inspect the reviewed Codex admission"
		if ! awk -F '\t' -v name="$name" '$1 == name { found=1 }
			END { exit !found }' "$output.unsorted"
		then
			printf '%s\t%s\n' "$name" "$oid" >>"$output.unsorted" ||
				die "could not collect reviewed Codex topic '$name'"
		fi
	fi
	LC_ALL=C sort "$output.unsorted" >"$output" ||
		die "could not sort enrolled Codex topics"
	test "$lane" = codex-unstable || test -s "$output" ||
		die "all enrolled Codex topics were removed"

	if test -s "$output"
	then
		reject_unadmitted_topic_history "$remote" "$output" \
			"$published_codex" "$base_oid" "$lane" "$admission"
	fi
)

reviewed_internal_merge_contains () (
	selected=$1
	selected_oid=$2
	shared=$3
	unadmitted_oid=$4
	published_codex=$5
	base_oid=$6
	admission=$7
	state=$8

	test -n "$admission" && test -s "$admission" || return 1
	IFS="$tab" read -r admitted_name admitted_oid admitted_number \
		admitted_merge <"$admission" || return 1
	test "$admitted_name" = "$selected" &&
		test "$admitted_oid" = "$selected_oid" || return 1
	git merge-base --is-ancestor "$unadmitted_oid" "$selected_oid" &&
		return 1
	git rev-list --min-parents=2 "$selected_oid" \
		"^$published_codex" "^$base_oid" >"$state/reviewed-merges" ||
		return 1
	while read -r merge
	do
		parents=$(git show -s --format=%P "$merge") || return 1
		set -- $parents
		first=$1
		shift
		git merge-base --is-ancestor "$shared" "$first" && continue
		for secondary
		do
			if git merge-base --is-ancestor "$shared" "$secondary"
			then
				return 0
			fi
		done
	done <"$state/reviewed-merges"
	return 1
)

reject_unadmitted_topic_history () (
	remote=$1
	topics=$2
	published_codex=$3
	base_oid=$4
	lane=${5:-codex}
	admission=${6:-}
	root=refs/remotes/$remote/
	state=$topics.unadmitted-history
	mkdir -p "$state" ||
		die "could not prepare unadmitted Codex topic verification"
	git for-each-ref --format='%(objectname)%09%(refname)' "$root" |
	while IFS="$tab" read -r oid ref
	do
		name=${ref#"$root"}
		is_topic_name "$name" || continue
		if awk -F '\t' -v name="$name" '$1 == name { found=1 }
			END { exit !found }' "$topics"
		then
			continue
		fi
		if git merge-base --is-ancestor "$oid" "$published_codex" ||
			git merge-base --is-ancestor "$oid" "$base_oid"
		then
			continue
		fi
		while IFS="$tab" read -r selected selected_oid
		do
			test "$oid" = "$selected_oid" && continue
			if git merge-base --is-ancestor "$selected_oid" "$oid"
			then
				continue
			fi
			git merge-base --all "$oid" "$selected_oid" \
				>"$state/merge-bases" ||
				die "could not compare unadmitted Codex topic '$name' with '$selected'"
			while read -r shared
			do
				if ! git merge-base --is-ancestor "$shared" "$published_codex" &&
					! git merge-base --is-ancestor "$shared" "$base_oid"
				then
					if { test "$lane" = codex-unstable ||
						is_stable_topic_name "$name"; } &&
						reviewed_internal_merge_contains "$selected" \
							"$selected_oid" "$shared" "$oid" \
							"$published_codex" "$base_oid" \
							"$admission" "$state"
					then
						continue
					fi
					die "unadmitted Codex topic '$name' is an unmerged prerequisite of '$selected'"
				fi
			done <"$state/merge-bases"
		done <"$topics"
	done
)

fetch_heads () {
	remote=$1
	refspec=+refs/heads/\*:refs/remotes/$remote/\*
	git -c core.fsmonitor=false fetch --force --prune "$remote" "$refspec"
}

write_input_snapshot () (
	controller_oid=$1
	base_name=$2
	base_oid=$3
	codex_name=$4
	codex_oid=$5
	topics=$6
	output=$7
	admission=$8
	unstable_topics=${9:-}
	shift 9 || :
	unstable_oid=${1:-}
	unstable_admission=${2:-}
	lane_mode=${3:-}
	plan_blob=${4:-}
	unstable_plan_blob=${5:-}

	{
		printf 'controller\trefs/heads/meta\t%s\n' "$controller_oid"
		test -z "$plan_blob" ||
			printf 'plan\t%s\t%s\n' "$stable_plan_path" "$plan_blob"
		printf 'base\trefs/heads/%s\t%s\n' "$base_name" "$base_oid"
		printf 'codex\trefs/heads/%s\t%s\n' "$codex_name" "$codex_oid"
		if test -n "$lane_mode"
		then
			printf 'lane-mode\trefs/heads/codex-unstable\t%s\n' \
				"$lane_mode"
		fi
		if test -n "$unstable_oid"
		then
			printf 'unstable\trefs/heads/codex-unstable\t%s\n' \
				"$unstable_oid"
		fi
		test -z "$unstable_plan_blob" ||
			printf 'unstable-plan\t%s\t%s\n' \
				"$unstable_plan_path" "$unstable_plan_blob"
		if test -s "$admission"
		then
			IFS="$tab" read -r name oid number merge <"$admission" ||
				die "could not inspect the reviewed Codex admission"
			printf 'admission\trefs/heads/%s\t%s\t%s\t%s\n' \
				"$name" "$oid" "$number" "$merge"
		fi
		if test -n "$unstable_admission" && test -s "$unstable_admission"
		then
			IFS="$tab" read -r name oid number merge <"$unstable_admission" ||
				die "could not inspect the reviewed unstable Codex admission"
			printf 'unstable-admission\trefs/heads/%s\t%s\t%s\t%s\n' \
				"$name" "$oid" "$number" "$merge"
		fi
		while IFS="$tab" read -r name oid
		do
			printf 'topic\trefs/heads/%s\t%s\n' "$name" "$oid"
		done <"$topics"
		if test -n "$unstable_topics"
		then
			while IFS="$tab" read -r name oid
			do
				printf 'unstable-topic\trefs/heads/%s\t%s\n' \
					"$name" "$oid"
			done <"$unstable_topics"
		fi
		if test -n "$plan_blob"
		then
			{
				cut -f2 "$topics"
				test -z "$unstable_topics" ||
					cut -f2 "$unstable_topics"
			} | LC_ALL=C sort -u |
			while IFS= read -r oid
			do
				pin_ref=$(pin_ref_for_tip "$oid")
				printf 'pin\t%s\t%s\n' "$pin_ref" "$oid"
			done
		fi
	} >"$output"
)

snapshot_inputs () {
	remote=$1
	base_name=$2
	codex_name=$3
	output=$4
	topics_output=$5
	controller_oid=${6:-${CODEX_CONTROLLER_OID:-}}
	lane_mode=${7:-}
	remote_controller_oid=$(resolve_commit "$(remote_ref "$remote" meta)")

	if test -n "$controller_oid"
	then
		controller_oid=$(resolve_commit "$controller_oid")
	else
		controller_oid=$remote_controller_oid
	fi
	test "$remote_controller_oid" = "$controller_oid" ||
		die "current meta does not match the pinned controller"
	base_oid=$(resolve_commit "$(remote_ref "$remote" "$base_name")")
	codex_oid=$(resolve_commit "$(remote_ref "$remote" "$codex_name")")
	published_state=
	if git cat-file -e "$controller_oid:$meta_config_path" 2>/dev/null
	then
		published_state=$topics_output.published-state
		mkdir -p "$published_state" ||
			die "could not prepare published Codex membership"
	read_meta_config "$controller_oid" "$base_name" "$codex_name" \
			"$published_state"
	fi
	if test -n "$published_state" &&
		{ test "$(state_value "$published_state" config-version)" = 3 ||
			git cat-file -e "$controller_oid:$stable_plan_path" \
				2>/dev/null; }
	then
		test -z "$lane_mode" ||
			die "pinned plans control whether codex-unstable is enabled"
		published_codex=$(state_value "$published_state" published-codex-oid)
		test "$codex_oid" = "$published_codex" ||
			die "generated codex moved outside its published pinned-plan output"
		plan_state=$topics_output.plan-state
		legacy_sources=
		if test "$(state_value "$published_state" config-version)" != 3
		then
			legacy_sources=$published_state/published-source-topics
		fi
		read_lane_plan "$controller_oid" codex "$base_name" "$base_oid" \
			"$remote" "$topics_output" "$plan_state" "$legacy_sources"
		plan_blob=$(state_value "$plan_state" plan-blob)
		unstable_topics=
		unstable_oid=
		unstable_plan_blob=
		if test -f "$published_state/published-unstable-oid"
		then
			unstable_oid=$(git rev-parse --verify \
				"$(remote_ref "$remote" codex-unstable)^{commit}" \
				2>/dev/null || :)
			test -n "$unstable_oid" ||
				die "$meta_config_path records codex-unstable, but its output disappeared"
			test "$unstable_oid" = \
				"$(state_value "$published_state" published-unstable-oid)" ||
				die "generated codex-unstable moved outside its published pinned-plan output"
			unstable_topics=$topics_output.unstable
			unstable_plan_state=$topics_output.unstable-plan-state
			git cat-file -e "$controller_oid:$unstable_plan_path" \
				2>/dev/null ||
				die "pinned-plan migration must add $unstable_plan_path"
			legacy_unstable_sources=
			if test "$(state_value "$published_state" config-version)" != 3
			then
				legacy_unstable_sources=$published_state/published-unstable-source-topics
			fi
			read_lane_plan "$controller_oid" codex-unstable codex \
				"$codex_oid" "$remote" "$unstable_topics" \
				"$unstable_plan_state" "$legacy_unstable_sources"
			unstable_plan_blob=$(state_value "$unstable_plan_state" \
				plan-blob)
		fi
		write_input_snapshot "$controller_oid" "$base_name" "$base_oid" \
			"$codex_name" "$codex_oid" "$topics_output" "$output" \
			"$topics_output.admission" "$unstable_topics" "$unstable_oid" \
			"" "" "$plan_blob" "$unstable_plan_blob"
		return
	fi
	collect_topics "$remote" "$topics_output" "$published_state" \
		"$codex_oid" "$base_oid"
	unstable_topics=
	unstable_oid=
	unstable_admission=
	if test -n "$published_state"
	then
		version=$(state_value "$published_state" config-version)
		case "$lane_mode:$version" in
		enable:1|disable:2|:1|:2) ;;
		enable:2) die "codex-unstable is already enabled" ;;
		disable:1) die "codex-unstable is not enabled" ;;
		*) die "invalid unstable-lane mode '$lane_mode'" ;;
		esac
		if test "$version" = 1 && test "$lane_mode" != enable &&
			git rev-parse --verify \
				"$(remote_ref "$remote" codex-unstable)^{commit}" \
				>/dev/null 2>&1
		then
			die "$meta_config_path does not describe the existing codex-unstable output"
		fi
		if test "$version" = 2 || test "$lane_mode" = enable
		then
			unstable_topics=$topics_output.unstable
			unstable_oid=$(git rev-parse --verify \
				"$(remote_ref "$remote" codex-unstable)^{commit}" \
				2>/dev/null || :)
			if test "$version" = 1
			then
				test -z "$unstable_oid" ||
					die "codex-unstable already exists outside its published state"
				unstable_oid=$(null_oid)
				: >"$unstable_topics"
				: >"$unstable_topics.admission"
			else
				test -n "$unstable_oid" ||
					die "$meta_config_path records codex-unstable, but its output disappeared"
				collect_topics "$remote" "$unstable_topics" \
					"$published_state" "$unstable_oid" "$codex_oid" \
					codex-unstable
			fi
			unstable_admission=$unstable_topics.admission
			if test "$lane_mode" = disable
			then
				! test -s "$unstable_topics" ||
					die "cannot disable codex-unstable while enrolled topics remain"
				! test -s "$unstable_admission" ||
					die "cannot disable codex-unstable with a pending pull-request merge"
			fi
		fi
	fi
	write_input_snapshot "$controller_oid" "$base_name" "$base_oid" \
		"$codex_name" "$codex_oid" "$topics_output" "$output" \
		"$topics_output.admission" "$unstable_topics" "$unstable_oid" \
		"$unstable_admission" "$lane_mode"
}

input_oid () {
	git hash-object "$1"
}

shell_quote () (
	quoted=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
	printf "'%s'" "$quoted"
)

state_path () {
	worktree=$1
	git -C "$worktree" rev-parse --path-format=absolute \
		--git-path codex-rewrite-state
}

state_value () {
	state=$1
	key=$2
	test -f "$state/$key" || die "rewrite state is missing '$key'"
	sed -n '1p' "$state/$key"
}

require_state_controller () {
	state=$1
	expected=$(state_value "$state" controller-oid)
	input_controller=$(awk -F '\t' '$1 == "controller" { print $3 }' \
		"$state/inputs")
	test "$input_controller" = "$expected" ||
		die "recovery state controller does not match its pinned input snapshot"
	expected_helper=$(git rev-parse \
		"$expected:.github/workflows/codex-branch.sh" 2>/dev/null) ||
		die "pinned meta $expected has no controller helper"
	actual_helper=$(git hash-object "$script_dir/$(basename "$0")") ||
		die "could not verify the recovery controller helper"
	test "$actual_helper" = "$expected_helper" ||
		die "the executing controller helper does not match pinned meta $expected"
	actual=${CODEX_CONTROLLER_OID:-}
	if test -n "$actual"
	then
		actual=$(resolve_commit "$actual")
		test "$actual" = "$expected" ||
			die "this recovery session belongs to meta $expected; run continue or publish-topics through that pinned Meta/codex"
	fi
}

result_lookup () {
	results=$1
	name=$2
	awk -F '\t' -v name="$name" '$1 == name { value=$2 } END {
		if (value != "") print value
	}' "$results"
}

result_record () {
	results=$1
	name=$2
	new=$3
	existing=$(result_lookup "$results" "$name")
	if test -n "$existing"
	then
		test "$existing" = "$new" ||
			die "topic '$name' was rewritten to both $existing and $new"
		return
	fi
	printf '%s\t%s\n' "$name" "$new" >>"$results" ||
		die "could not record rewritten topic '$name'"
}

transform_lookup () {
	map=$1
	old=$2
	old_base=$3
	new_base=$4
	awk -F '\t' -v old="$old" -v old_base="$old_base" \
		-v new_base="$new_base" '
		$1 == old && $2 == old_base && $3 == new_base { value=$4 }
		END { if (value != "") print value }
	' "$map"
}

transform_record () {
	map=$1
	old=$2
	old_base=$3
	new_base=$4
	new=$5
	existing=$(transform_lookup "$map" "$old" "$old_base" "$new_base")
	if test -n "$existing"
	then
		test "$existing" = "$new" ||
			die "rewrite $old ($old_base -> $new_base) produced both $existing and $new"
		return
	fi
	printf '%s\t%s\t%s\t%s\n' "$old" "$old_base" "$new_base" "$new" \
		>>"$map" || die "could not cache rewrite of $old"
}

config_subsection_quote () (
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
)

write_meta_config () (
	base_name=$1
	base_oid=$2
	codex_name=$3
	codex_oid=$4
	rows=$5
	output=$6
	unstable_rows=${7:-}
	unstable_base=${8:-}
	unstable_output=${9:-}

	{
		printf '[codex]\n'
		if test -n "$unstable_rows"
		then
			printf '\tversion = 2\n'
		else
			printf '\tversion = 1\n'
		fi
		printf '\tbase-ref = refs/heads/%s\n' "$base_name"
		printf '\tbase-tip = %s\n' "$base_oid"
		printf '\toutput-ref = refs/heads/%s\n' "$codex_name"
		printf '\toutput-tip = %s\n' "$codex_oid"
		if test -n "$unstable_rows"
		then
			printf '\n[codex-unstable]\n'
			printf '\tbase-ref = refs/heads/%s\n' "$codex_name"
			printf '\tbase-tip = %s\n' "$unstable_base"
			printf '\toutput-ref = refs/heads/codex-unstable\n'
			printf '\toutput-tip = %s\n' "$unstable_output"
			cat "$rows" "$unstable_rows" | LC_ALL=C sort \
				>"$output.rows" ||
				die "could not sort stable and unstable topic state"
			rows=$output.rows
		fi
		while IFS="$tab" read -r name tip prerequisites
		do
			quoted=$(config_subsection_quote "$name")
			printf '\n[branch "%s"]\n' "$quoted"
			printf '\tremote = .\n'
			for prerequisite in $prerequisites
			do
				printf '\tmerge = refs/heads/%s\n' "$prerequisite"
			done
			printf '\tcodex-tip = %s\n' "$tip"
		done <"$rows"
	} >"$output" || die "could not write $meta_config_path"
	test -z "$unstable_rows" || rm -f "$output.rows"
)

write_meta_config_v3 () (
	base_name=$1
	base_oid=$2
	codex_name=$3
	codex_oid=$4
	rows=$5
	output=$6
	applied_plan=$7
	unstable_rows=${8:-}
	unstable_base=${9:-}
	unstable_output=${10:-}
	unstable_applied_plan=${11:-}

	{
		printf '[codex]\n'
		printf '\tversion = 3\n'
		printf '\tbase-ref = refs/heads/%s\n' "$base_name"
		printf '\tbase-tip = %s\n' "$base_oid"
		printf '\toutput-ref = refs/heads/%s\n' "$codex_name"
		printf '\toutput-tip = %s\n' "$codex_oid"
		printf '\tapplied-plan = %s\n' "$applied_plan"
		if test -n "$unstable_applied_plan"
		then
			printf '\n[codex-unstable]\n'
			printf '\tbase-ref = refs/heads/%s\n' "$codex_name"
			printf '\tbase-tip = %s\n' "$unstable_base"
			printf '\toutput-ref = refs/heads/codex-unstable\n'
			printf '\toutput-tip = %s\n' "$unstable_output"
			printf '\tapplied-plan = %s\n' "$unstable_applied_plan"
			cat "$rows" "$unstable_rows" | LC_ALL=C sort \
				>"$output.rows" ||
				die "could not sort stable and unstable topic state"
			rows=$output.rows
		fi
		while IFS="$tab" read -r name source_tip codex_tip prerequisites
		do
			quoted=$(config_subsection_quote "$name")
			printf '\n[branch "%s"]\n' "$quoted"
			printf '\tremote = .\n'
			printf '\tsource-ref = refs/heads/%s\n' "$name"
			printf '\tsource-tip = %s\n' "$source_tip"
			for prerequisite in $prerequisites
			do
				printf '\tmerge = refs/heads/%s\n' "$prerequisite"
			done
			printf '\tcodex-tip = %s\n' "$codex_tip"
		done <"$rows"
	} >"$output" || die "could not write $meta_config_path"
	test -z "$unstable_applied_plan" || rm -f "$output.rows"
)

read_meta_config_v3 () (
	controller_oid=$1
	base_name=$2
	codex_name=$3
	state=$4
	config=$state/published-config
	rows=$state/published-topics
	source_rows=$state/published-source-topics
	unstable_rows=$state/published-unstable-topics
	unstable_source_rows=$state/published-unstable-source-topics

	base_ref=$(config_get_one "$config" codex.base-ref)
	base_tip=$(config_get_one "$config" codex.base-tip)
	output_ref=$(config_get_one "$config" codex.output-ref)
	output_tip=$(config_get_one "$config" codex.output-tip)
	applied_plan=$(config_get_one "$config" codex.applied-plan)
	test "$base_ref" = "refs/heads/$base_name" ||
		die "$meta_config_path records base '$base_ref', not refs/heads/$base_name"
	test "$output_ref" = "refs/heads/$codex_name" ||
		die "$meta_config_path records output '$output_ref', not refs/heads/$codex_name"
	require_full_commit_oid "$base_tip"
	require_full_commit_oid "$output_tip"
	require_full_blob_oid "$applied_plan"
	unstable_enabled=
	if git config --no-includes --file "$config" \
		--get codex-unstable.output-tip >/dev/null 2>&1
	then
		unstable_enabled=t
		unstable_base_ref=$(config_get_one "$config" \
			codex-unstable.base-ref)
		unstable_base_tip=$(config_get_one "$config" \
			codex-unstable.base-tip)
		unstable_output_ref=$(config_get_one "$config" \
			codex-unstable.output-ref)
		unstable_output_tip=$(config_get_one "$config" \
			codex-unstable.output-tip)
		unstable_applied_plan=$(config_get_one "$config" \
			codex-unstable.applied-plan)
		test "$unstable_base_ref" = "refs/heads/$codex_name" ||
			die "$meta_config_path records unstable base '$unstable_base_ref', not refs/heads/$codex_name"
		test "$unstable_output_ref" = refs/heads/codex-unstable ||
			die "$meta_config_path records invalid unstable output '$unstable_output_ref'"
		require_full_commit_oid "$unstable_base_tip"
		require_full_commit_oid "$unstable_output_tip"
		require_full_blob_oid "$unstable_applied_plan"
		test "$unstable_base_tip" = "$output_tip" ||
			die "$meta_config_path unstable base does not match its published codex output"
		git merge-base --is-ancestor "$unstable_base_tip" \
			"$unstable_output_tip" ||
			die "$meta_config_path unstable output is not based on codex"
		test "$unstable_base_tip" != "$unstable_output_tip" ||
			die "$meta_config_path unstable output is not strictly ahead of codex"
	fi

	: >"$rows"
	: >"$source_rows"
	: >"$unstable_rows"
	: >"$unstable_source_rows"
	git config --no-includes --file "$config" --get-regexp \
		'^branch\..*\.codex-tip$' >"$state/published-tip-keys" || :
	while IFS=' ' read -r key codex_tip
	do
		name=${key#branch.}
		name=${name%.codex-tip}
		is_active_topic_name "$name" ||
			die "$meta_config_path records invalid topic '$name'"
		remote=$(config_get_one "$config" "branch.$name.remote")
		test "$remote" = . ||
			die "$meta_config_path gives '$name' non-local remote '$remote'"
		source_ref=$(config_get_one "$config" "branch.$name.source-ref")
		test "$source_ref" = "refs/heads/$name" ||
			die "$meta_config_path gives '$name' invalid source '$source_ref'"
		source_tip=$(config_get_one "$config" "branch.$name.source-tip")
		require_full_commit_oid "$source_tip"
		require_full_commit_oid "$codex_tip"
		merges=$(git config --no-includes --file "$config" \
			--get-all "branch.$name.merge" || :)
		test -n "$merges" ||
			die "$meta_config_path is missing 'branch.$name.merge'"
		prerequisites=
		for merge in $merges
		do
			case "$merge" in
			"refs/heads/$base_name") prerequisite=$base_name ;;
			"refs/heads/$codex_name") prerequisite=$codex_name ;;
			refs/heads/*) prerequisite=${merge#refs/heads/} ;;
			*) die "$meta_config_path gives '$name' invalid prerequisite '$merge'" ;;
			esac
			case " $prerequisites " in
			*" $prerequisite "*)
				die "$meta_config_path repeats prerequisite '$prerequisite' for '$name'"
				;;
			esac
			prerequisites=${prerequisites:+$prerequisites }$prerequisite
		done
		if is_unstable_topic_name "$name"
		then
			test -n "$unstable_enabled" ||
				die "$meta_config_path records unstable topic '$name' without an unstable lane"
			for prerequisite in $prerequisites
			do
				if test "$prerequisite" != "$codex_name"
				then
					is_unstable_topic_name "$prerequisite" ||
						die "$meta_config_path gives unstable topic '$name' invalid prerequisite '$prerequisite'"
				fi
			done
			target_rows=$unstable_rows
			target_source_rows=$unstable_source_rows
		else
			for prerequisite in $prerequisites
			do
				if test "$prerequisite" != "$base_name"
				then
					is_stable_topic_name "$prerequisite" ||
						die "$meta_config_path gives '$name' invalid prerequisite '$prerequisite'"
				fi
			done
			target_rows=$rows
			target_source_rows=$source_rows
		fi
		printf '%s\t%s\t%s\n' "$name" "$codex_tip" "$prerequisites" \
			>>"$target_rows" ||
			die "could not read '$name' from $meta_config_path"
		printf '%s\t%s\t%s\n' "$name" "$source_tip" "$prerequisites" \
			>>"$target_source_rows" ||
			die "could not read '$name' source from $meta_config_path"
	done <"$state/published-tip-keys"
	LC_ALL=C sort -o "$rows" "$rows"
	LC_ALL=C sort -o "$source_rows" "$source_rows"
	LC_ALL=C sort -o "$unstable_rows" "$unstable_rows"
	LC_ALL=C sort -o "$unstable_source_rows" "$unstable_source_rows"

	while IFS="$tab" read -r name codex_tip prerequisites
	do
		for prerequisite in $prerequisites
		do
			if test "$prerequisite" = "$base_name"
			then
				prerequisite_tip=$base_tip
			else
				prerequisite_tip=$(published_tip "$rows" "$prerequisite")
				test -n "$prerequisite_tip" ||
					die "$meta_config_path records missing prerequisite '$prerequisite' for '$name'"
			fi
			git merge-base --is-ancestor "$prerequisite_tip" "$codex_tip" ||
				die "$meta_config_path boundary for '$name' is not in its published history"
		done
		git merge-base --is-ancestor "$codex_tip" "$output_tip" ||
			die "$meta_config_path output does not contain published topic '$name'"
	done <"$rows"
	if test -n "$unstable_enabled"
	then
		if ! test -s "$unstable_rows"
		then
			unstable_sentinel_is_canonical "$unstable_base_tip" \
				"$unstable_output_tip" ||
				die "$meta_config_path empty unstable output is not its canonical sentinel"
		fi
		while IFS="$tab" read -r name codex_tip prerequisites
		do
			for prerequisite in $prerequisites
			do
				if test "$prerequisite" = "$codex_name"
				then
					prerequisite_tip=$unstable_base_tip
				else
					prerequisite_tip=$(published_tip "$unstable_rows" \
						"$prerequisite")
					test -n "$prerequisite_tip" ||
						die "$meta_config_path records missing unstable prerequisite '$prerequisite' for '$name'"
				fi
				git merge-base --is-ancestor "$prerequisite_tip" "$codex_tip" ||
					die "$meta_config_path boundary for unstable topic '$name' is not in its published history"
			done
			git merge-base --is-ancestor "$codex_tip" "$unstable_output_tip" ||
				die "$meta_config_path output does not contain published unstable topic '$name'"
		done <"$unstable_rows"
	fi
	git merge-base --is-ancestor "$base_tip" "$output_tip" ||
		die "$meta_config_path output is not based on its recorded base"

	: >"$state/canonical-v3-rows"
	while IFS="$tab" read -r name codex_tip prerequisites
	do
		source_tip=$(published_tip "$source_rows" "$name")
		printf '%s\t%s\t%s\t%s\n' "$name" "$source_tip" \
			"$codex_tip" "$prerequisites" >>"$state/canonical-v3-rows"
	done <"$rows"
	: >"$state/canonical-v3-unstable-rows"
	while IFS="$tab" read -r name codex_tip prerequisites
	do
		source_tip=$(published_tip "$unstable_source_rows" "$name")
		printf '%s\t%s\t%s\t%s\n' "$name" "$source_tip" \
			"$codex_tip" "$prerequisites" \
			>>"$state/canonical-v3-unstable-rows"
	done <"$unstable_rows"
	if test -n "$unstable_enabled"
	then
		write_meta_config_v3 "$base_name" "$base_tip" "$codex_name" \
			"$output_tip" "$state/canonical-v3-rows" \
			"$state/canonical-published-config" "$applied_plan" \
			"$state/canonical-v3-unstable-rows" \
			"$unstable_base_tip" "$unstable_output_tip" \
			"$unstable_applied_plan"
	else
		write_meta_config_v3 "$base_name" "$base_tip" "$codex_name" \
			"$output_tip" "$state/canonical-v3-rows" \
			"$state/canonical-published-config" "$applied_plan"
	fi
	if ! cmp -s "$config" "$state/canonical-published-config"
	then
		diff -u "$config" "$state/canonical-published-config" >&2 || :
		die "$meta_config_path is not in canonical form"
	fi
	printf '%s\n' 3 >"$state/config-version"
	printf '%s\n' "$base_tip" >"$state/published-base-oid"
	printf '%s\n' "$output_tip" >"$state/published-codex-oid"
	printf '%s\n' "$applied_plan" >"$state/published-plan-blob"
	if test -n "$unstable_enabled"
	then
		printf '%s\n' "$unstable_base_tip" \
			>"$state/published-unstable-base-oid"
		printf '%s\n' "$unstable_output_tip" \
			>"$state/published-unstable-oid"
		printf '%s\n' "$unstable_applied_plan" \
			>"$state/published-unstable-plan-blob"
	fi
)

config_get_one () (
	config=$1
	key=$2
	label=${3:-$meta_config_path}
	values=$(git config --no-includes --file "$config" --get-all "$key" || :)
	test -n "$values" || die "$label is missing '$key'"
	test "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" = 1 ||
		die "$label has more than one '$key'"
	printf '%s\n' "$values"
)

write_lane_plan () (
	lane=$1
	base_name=$2
	rows=$3
	source_bases=$4
	output=$5
	path=$(plan_path_for_lane "$lane")

	{
		printf '[plan]\n'
		printf '\tversion = 1\n'
		printf '\tlane = %s\n' "$lane"
		printf '\tbase-ref = refs/heads/%s\n' "$base_name"
		while IFS="$tab" read -r name tip prerequisites
		do
			printf '\ttopic = refs/heads/%s\n' "$name"
		done <"$rows"
		while IFS="$tab" read -r name tip prerequisites
		do
			quoted=$(config_subsection_quote "$name")
			printf '\n[branch "%s"]\n' "$quoted"
			printf '\tremote = .\n'
			printf '\tsource-ref = refs/heads/%s\n' "$name"
			printf '\tsource-tip = %s\n' "$tip"
			source_base=$(plan_source_base "$source_bases" "$name")
			test -n "$source_base" ||
				die "$path has no source boundary for '$name'"
			require_full_commit_oid "$source_base"
			printf '\tsource-base = %s\n' "$source_base"
			for prerequisite in $prerequisites
			do
				printf '\tmerge = refs/heads/%s\n' "$prerequisite"
			done
		done <"$rows"
	} >"$output" || die "could not write $path"
)

plan_tip () (
	rows=$1
	name=$2
	awk -F '\t' -v name="$name" '$1 == name { value=$2 }
		END { if (value != "") print value }' "$rows"
)

plan_prerequisites () (
	rows=$1
	name=$2
	awk -F '\t' -v name="$name" '$1 == name { value=$3 }
		END { if (value != "") print value }' "$rows"
)

plan_source_base () (
	rows=$1
	name=$2
	awk -F '\t' -v name="$name" '$1 == name { value=$2 }
		END { if (value != "") print value }' "$rows"
)

pinned_root_boundary () (
	current_base=$1
	published_base=$2
	tip=$3
	bases=$(git merge-base --all "$current_base" "$tip") ||
		return 1
	test -n "$bases" || return 1
	test "$(printf '%s\n' "$bases" | wc -l | tr -d ' ')" = 1 ||
		return 1
	boundary=$(printf '%s\n' "$bases" | sed -n '1p')
	git merge-base --is-ancestor "$published_base" "$boundary" ||
		return 1
	printf '%s\n' "$boundary"
)

select_nearest_plan_boundary () (
	candidates=$1
	tip=$2
	selected_name=
	selected_boundary=
	while IFS="$tab" read -r name boundary
	do
		test -n "$name" && test -n "$boundary" || continue
		git merge-base --is-ancestor "$boundary" "$tip" ||
			continue
		if test -z "$selected_boundary"
		then
			selected_name=$name
			selected_boundary=$boundary
			continue
		fi
		if test "$boundary" = "$selected_boundary"
		then
			test "$name" = "$selected_name" ||
				die "pinned topic has two equally near prerequisites '$selected_name' and '$name'"
			continue
		fi
		if git merge-base --is-ancestor "$selected_boundary" \
			"$boundary"
		then
			selected_name=$name
			selected_boundary=$boundary
		elif git merge-base --is-ancestor "$boundary" \
			"$selected_boundary"
		then
			:
		else
			die "pinned topic has incomparable prerequisites '$selected_name' and '$name'"
		fi
	done <"$candidates"
	test -n "$selected_boundary" || return 1
	printf '%s\t%s\n' "$selected_name" "$selected_boundary"
)

infer_added_plan_boundary () (
	rows=$1
	published_rows=$2
	lane_base=$3
	current_base=$4
	published_base=$5
	tip=$6
	candidates=$tmp_dir/add-boundary-candidates
	: >"$candidates"
	if boundary=$(pinned_root_boundary "$current_base" \
		"$published_base" "$tip")
	then
		printf '%s\t%s\n' "$lane_base" "$boundary" >>"$candidates"
	fi
	while IFS="$tab" read -r name source_tip prerequisites
	do
		printf '%s\t%s\n' "$name" "$source_tip" >>"$candidates"
		generated_tip=$(published_tip "$published_rows" "$name")
		test -z "$generated_tip" ||
			printf '%s\t%s\n' "$name" "$generated_tip" \
				>>"$candidates"
	done <"$rows"
	select_nearest_plan_boundary "$candidates" "$tip" ||
		die "new pinned topic is not based on a unique lane boundary"
)

infer_altered_plan_boundary () (
	rows=$1
	source_bases=$2
	published_rows=$3
	lane_base=$4
	current_base=$5
	published_base=$6
	topic=$7
	prerequisite=$8
	tip=$9
	candidates=$tmp_dir/alter-boundary-candidates
	: >"$candidates"
	old_source_base=$(plan_source_base "$source_bases" "$topic")
	test -z "$old_source_base" ||
		printf '%s\t%s\n' "$prerequisite" "$old_source_base" \
			>>"$candidates"
	if test "$prerequisite" = "$lane_base"
	then
		if boundary=$(pinned_root_boundary "$current_base" \
			"$published_base" "$tip")
		then
			printf '%s\t%s\n' "$prerequisite" "$boundary" \
				>>"$candidates"
		fi
	else
		parent_source=$(plan_tip "$rows" "$prerequisite")
		test -z "$parent_source" ||
			printf '%s\t%s\n' "$prerequisite" "$parent_source" \
				>>"$candidates"
		parent_generated=$(published_tip "$published_rows" \
			"$prerequisite")
		test -z "$parent_generated" ||
			printf '%s\t%s\n' "$prerequisite" \
				"$parent_generated" >>"$candidates"
	fi
	selected=$(select_nearest_plan_boundary "$candidates" "$tip") ||
		die "altered pinned topic '$topic' is outside its reviewed prerequisite"
	IFS="$tab" read -r selected_name boundary <<-EOF
	$selected
	EOF
	test "$selected_name" = "$prerequisite" ||
		die "altered pinned topic '$topic' changes prerequisite without a manifest review"
	printf '%s\n' "$boundary"
)

read_lane_plan () (
	controller_oid=$1
	lane=$2
	base_name=$3
	source_base_oid=$4
	remote=$5
	output=$6
	state=$7
	legacy_sources=${8:-}
	path=$(plan_path_for_lane "$lane")
	config=$state/plan-config
	rows=$state/desired-prerequisites
	source_bases=$state/desired-source-bases
	order=$state/desired-order
	label=$path

	mkdir -p "$state" || die "could not prepare $path state"
	git show "$controller_oid:$path" >"$config" 2>/dev/null ||
		die "meta has no $path"
	version=$(config_get_one "$config" plan.version "$label")
	test "$version" = 1 ||
		die "$path has unsupported version '$version'"
	actual_lane=$(config_get_one "$config" plan.lane "$label")
	test "$actual_lane" = "$lane" ||
		die "$path records lane '$actual_lane', not '$lane'"
	base_ref=$(config_get_one "$config" plan.base-ref "$label")
	test "$base_ref" = "refs/heads/$base_name" ||
		die "$path records base '$base_ref', not refs/heads/$base_name"
	plan_blob=$(git rev-parse "$controller_oid:$path" 2>/dev/null) ||
		die "could not resolve $path"
	require_full_blob_oid "$plan_blob"
	printf '%s\n' "$plan_blob" >"$state/plan-blob"

	: >"$output"
	: >"$rows"
	: >"$source_bases"
	: >"$order"
	git config --no-includes --file "$config" --get-all plan.topic \
		>"$state/plan-topic-refs" || :
	while IFS= read -r ref
	do
		case "$ref" in
		refs/heads/*) name=${ref#refs/heads/} ;;
		*) die "$path records invalid topic '$ref'" ;;
		esac
		case "$lane" in
		codex)
			is_stable_topic_name "$name" ||
				die "$path records invalid production topic '$name'"
			;;
		codex-unstable)
			is_unstable_topic_name "$name" ||
				die "$path records invalid unstable topic '$name'"
			;;
		esac
		if awk -F '\t' -v name="$name" '$1 == name { found=1 }
			END { exit !found }' "$rows"
		then
			die "$path records topic '$name' more than once"
		fi
		topic_remote=$(config_get_one "$config" \
			"branch.$name.remote" "$label")
		test "$topic_remote" = . ||
			die "$path gives '$name' non-local remote '$topic_remote'"
		source_ref=$(config_get_one "$config" \
			"branch.$name.source-ref" "$label")
		test "$source_ref" = "refs/heads/$name" ||
			die "$path gives '$name' source '$source_ref', not refs/heads/$name"
		tip=$(config_get_one "$config" \
			"branch.$name.source-tip" "$label")
		require_full_commit_oid "$tip"
		source_base=$(config_get_one "$config" \
			"branch.$name.source-base" "$label")
		require_full_commit_oid "$source_base"
		merges=$(git config --no-includes --file "$config" \
			--get-all "branch.$name.merge" || :)
		test -n "$merges" ||
			die "$path is missing 'branch.$name.merge'"
		prerequisites=
		for merge in $merges
		do
			case "$merge" in
			"refs/heads/$base_name") prerequisite=$base_name ;;
			refs/heads/*)
				prerequisite=${merge#refs/heads/}
				case "$lane" in
				codex) is_stable_topic_name "$prerequisite" ;;
				codex-unstable) is_unstable_topic_name "$prerequisite" ;;
				esac ||
					die "$path gives '$name' invalid prerequisite '$merge'"
				;;
			*) die "$path gives '$name' invalid prerequisite '$merge'" ;;
			esac
			case " $prerequisites " in
			*" $prerequisite "*)
				die "$path repeats prerequisite '$prerequisite' for '$name'"
				;;
			esac
			prerequisites=${prerequisites:+$prerequisites }$prerequisite
		done
		case " $prerequisites " in
		*" $base_name "*)
			test "$prerequisites" = "$base_name" ||
				die "$path mixes $base_name with topic prerequisites for '$name'"
			;;
		esac
		printf '%s\t%s\t%s\n' "$name" "$tip" "$prerequisites" \
			>>"$rows" || die "could not read '$name' from $path"
		printf '%s\t%s\n' "$name" "$source_base" \
			>>"$source_bases" ||
			die "could not read '$name' source boundary from $path"
		printf '%s\t%s\n' "$name" "$tip" >>"$output" ||
			die "could not pin '$name' from $path"
		printf '%s\n' "$name" >>"$order" ||
			die "could not retain $path order"
	done <"$state/plan-topic-refs"

	if test "$lane" = codex
	then
		test -s "$rows" || die "$path contains no production topics"
	fi
	git config --no-includes --file "$config" --get-regexp \
		'^branch\..*\.source-tip$' >"$state/plan-tip-keys" || :
	test "$(wc -l <"$state/plan-tip-keys" | tr -d ' ')" = \
		"$(wc -l <"$rows" | tr -d ' ')" ||
		die "$path has branch rows outside its ordered topic list"
	while IFS=' ' read -r key unused_tip
	do
		name=${key#branch.}
		name=${name%.source-tip}
		awk -F '\t' -v name="$name" '$1 == name { found=1 }
			END { exit !found }' "$rows" ||
			die "$path has unlisted branch '$name'"
	done <"$state/plan-tip-keys"

	position=0
	while IFS="$tab" read -r name tip prerequisites
	do
		position=$((position + 1))
		for prerequisite in $prerequisites
		do
			if test "$prerequisite" = "$base_name"
			then
				# The plan pins reviewed topic inputs, not a moving
				# lane base.  Root topics are replayed onto the
				# current base during preparation.
				continue
			else
				test -n "$(plan_tip "$rows" "$prerequisite")" ||
					die "$path records missing prerequisite '$prerequisite' for '$name'"
				prerequisite_position=$(awk -F '\t' \
					-v name="$prerequisite" '$1 == name { print NR; exit }' \
					"$rows")
				test "$prerequisite_position" -lt "$position" ||
					die "$path orders prerequisite '$prerequisite' after '$name'"
			fi
		done
		if test "$remote" != -
		then
			pin_ref=$(pin_ref_for_tip "$tip")
			pin_name=${pin_ref#refs/heads/}
			pin_oid=$(git rev-parse --verify \
				"$(remote_ref "$remote" "$pin_name")^{commit}" \
				2>/dev/null) ||
				die "$path has no immutable pin for '$name' at $tip"
			test "$pin_oid" = "$tip" ||
				die "$path immutable pin for '$name' does not name $tip"
		fi
	done <"$rows"
	write_lane_plan "$lane" "$base_name" "$rows" "$source_bases" \
		"$state/canonical-plan"
	cmp -s "$config" "$state/canonical-plan" ||
		die "$path is not in canonical form"
)

published_tip () (
	rows=$1
	name=$2
	awk -F '\t' -v name="$name" '$1 == name { value=$2 }
		END { if (value != "") print value }' "$rows"
)

published_prerequisite () (
	rows=$1
	name=$2
	awk -F '\t' -v name="$name" '$1 == name {
		split($3, prerequisites, " ")
		value=prerequisites[1]
	}
		END { if (value != "") print value }' "$rows"
)

published_prerequisites () (
	rows=$1
	name=$2
	awk -F '\t' -v name="$name" '$1 == name { value=$3 }
		END { if (value != "") print value }' "$rows"
)

planned_prerequisites () (
	state=$1
	name=$2
	if test -f "$state/prerequisites"
	then
		published_prerequisites "$state/prerequisites" "$name"
	else
		published_prerequisite "$state/plan" "$name"
	fi
)

read_meta_config () (
	controller_oid=$1
	base_name=$2
	codex_name=$3
	state=$4
	config=$state/published-config
	rows=$state/published-topics
	unstable_rows=$state/published-unstable-topics

	git show "$controller_oid:$meta_config_path" >"$config" 2>/dev/null ||
		die "meta has no $meta_config_path; run Meta/codex initialize before refreshing"
	version=$(config_get_one "$config" codex.version)
	test "$version" = 1 || test "$version" = 2 || test "$version" = 3 ||
		die "$meta_config_path has unsupported version '$version'"
	if test "$version" = 3
	then
		read_meta_config_v3 "$controller_oid" "$base_name" \
			"$codex_name" "$state"
		return
	fi
	base_ref=$(config_get_one "$config" codex.base-ref)
	base_tip=$(config_get_one "$config" codex.base-tip)
	output_ref=$(config_get_one "$config" codex.output-ref)
	output_tip=$(config_get_one "$config" codex.output-tip)
	test "$base_ref" = "refs/heads/$base_name" ||
		die "$meta_config_path records base '$base_ref', not refs/heads/$base_name"
	test "$output_ref" = "refs/heads/$codex_name" ||
		die "$meta_config_path records output '$output_ref', not refs/heads/$codex_name"
	require_full_commit_oid "$base_tip"
	require_full_commit_oid "$output_tip"
	if test "$version" = 2
	then
		unstable_base_ref=$(config_get_one "$config" \
			codex-unstable.base-ref)
		unstable_base_tip=$(config_get_one "$config" \
			codex-unstable.base-tip)
		unstable_output_ref=$(config_get_one "$config" \
			codex-unstable.output-ref)
		unstable_output_tip=$(config_get_one "$config" \
			codex-unstable.output-tip)
		test "$unstable_base_ref" = "refs/heads/$codex_name" ||
			die "$meta_config_path records unstable base '$unstable_base_ref', not refs/heads/$codex_name"
		test "$unstable_output_ref" = refs/heads/codex-unstable ||
			die "$meta_config_path records invalid unstable output '$unstable_output_ref'"
		require_full_commit_oid "$unstable_base_tip"
		require_full_commit_oid "$unstable_output_tip"
		test "$unstable_base_tip" = "$output_tip" ||
			die "$meta_config_path unstable base does not match its published codex output"
		git merge-base --is-ancestor "$unstable_base_tip" \
			"$unstable_output_tip" ||
			die "$meta_config_path unstable output is not based on codex"
		test "$unstable_base_tip" != "$unstable_output_tip" ||
			die "$meta_config_path unstable output is not strictly ahead of codex"
	fi

	: >"$rows"
	: >"$unstable_rows"
	git config --no-includes --file "$config" --get-regexp \
		'^branch\..*\.codex-tip$' >"$state/published-tip-keys" || :
	while IFS=' ' read -r key tip
	do
		name=${key#branch.}
		name=${name%.codex-tip}
		is_active_topic_name "$name" ||
			die "$meta_config_path records invalid topic '$name'"
		remote=$(config_get_one "$config" "branch.$name.remote")
		test "$remote" = . ||
			die "$meta_config_path gives '$name' non-local remote '$remote'"
		if is_unstable_topic_name "$name"
		then
			test "$version" = 2 ||
				die "$meta_config_path version 1 records unstable topic '$name'"
			merges=$(git config --no-includes --file "$config" \
				--get-all "branch.$name.merge" || :)
			test -n "$merges" ||
				die "$meta_config_path is missing 'branch.$name.merge'"
			prerequisites=
			for merge in $merges
			do
				case "$merge" in
				"refs/heads/$codex_name") prerequisite=$codex_name ;;
				refs/heads/*)
					prerequisite=${merge#refs/heads/}
					is_unstable_topic_name "$prerequisite" ||
						die "$meta_config_path gives unstable topic '$name' invalid prerequisite '$merge'"
					;;
				*) die "$meta_config_path gives '$name' invalid prerequisite '$merge'" ;;
				esac
				case " $prerequisites " in
				*" $prerequisite "*)
					die "$meta_config_path repeats prerequisite '$prerequisite' for '$name'"
					;;
				esac
				prerequisites=${prerequisites:+$prerequisites }$prerequisite
			done
			case " $prerequisites " in
			*" $codex_name "*)
				test "$prerequisites" = "$codex_name" ||
					die "$meta_config_path mixes codex with topic prerequisites for '$name'"
				;;
			esac
			target_rows=$unstable_rows
		else
			merges=$(git config --no-includes --file "$config" \
				--get-all "branch.$name.merge" || :)
			test -n "$merges" ||
				die "$meta_config_path is missing 'branch.$name.merge'"
			prerequisites=
			for merge in $merges
			do
				case "$merge" in
				"refs/heads/$base_name") prerequisite=$base_name ;;
				refs/heads/*)
					prerequisite=${merge#refs/heads/}
					is_stable_topic_name "$prerequisite" ||
						die "$meta_config_path gives '$name' invalid prerequisite '$merge'"
					;;
				*) die "$meta_config_path gives '$name' invalid prerequisite '$merge'" ;;
				esac
				case " $prerequisites " in
				*" $prerequisite "*)
					die "$meta_config_path repeats prerequisite '$prerequisite' for '$name'"
					;;
				esac
				prerequisites=${prerequisites:+$prerequisites }$prerequisite
			done
			case " $prerequisites " in
			*" $base_name "*)
				test "$prerequisites" = "$base_name" ||
					die "$meta_config_path mixes master with topic prerequisites for '$name'"
				;;
			esac
			target_rows=$rows
		fi
		require_full_commit_oid "$tip"
		printf '%s\t%s\t%s\n' "$name" "$tip" "$prerequisites" \
			>>"$target_rows" ||
			die "could not read '$name' from $meta_config_path"
	done <"$state/published-tip-keys"
	LC_ALL=C sort -o "$rows" "$rows"
	LC_ALL=C sort -o "$unstable_rows" "$unstable_rows"
	# Version 1/2 rewrote topic refs in place, so the published
	# generated boundary is also the only safe source boundary for a
	# one-shot pinned-plan migration.
	cp "$rows" "$state/published-source-topics" ||
		die "could not retain legacy source boundaries"
	cp "$unstable_rows" "$state/published-unstable-source-topics" ||
		die "could not retain legacy unstable source boundaries"
	test "$(cut -f1 "$rows" | sort -u | wc -l | tr -d ' ')" = \
		"$(wc -l <"$rows" | tr -d ' ')" ||
		die "$meta_config_path records a topic more than once"
	test "$(cut -f1 "$unstable_rows" | sort -u | wc -l | tr -d ' ')" = \
		"$(wc -l <"$unstable_rows" | tr -d ' ')" ||
		die "$meta_config_path records an unstable topic more than once"

	while IFS="$tab" read -r name tip prerequisites
	do
		for prerequisite in $prerequisites
		do
			test "$name" != "$prerequisite" ||
				die "$meta_config_path makes '$name' its own prerequisite"
			if published_depends_on "$rows" "$prerequisite" "$name"
			then
				die "$meta_config_path contains a dependency cycle through '$name'"
			fi
			if test "$prerequisite" = "$base_name"
			then
				prerequisite_tip=$base_tip
			else
				prerequisite_tip=$(published_tip "$rows" "$prerequisite")
				test -n "$prerequisite_tip" ||
					die "$meta_config_path records missing prerequisite '$prerequisite' for '$name'"
			fi
			git merge-base --is-ancestor "$prerequisite_tip" "$tip" ||
				die "$meta_config_path boundary for '$name' is not in its published history"
		done
		git merge-base --is-ancestor "$tip" "$output_tip" ||
			die "$meta_config_path output does not contain published topic '$name'"
	done <"$rows"
	if test "$version" = 2
	then
		if ! test -s "$unstable_rows"
		then
			unstable_sentinel_is_canonical "$unstable_base_tip" \
				"$unstable_output_tip" ||
				die "$meta_config_path empty unstable output is not its canonical sentinel"
		fi
		while IFS="$tab" read -r name tip prerequisites
		do
			for prerequisite in $prerequisites
			do
				test "$name" != "$prerequisite" ||
					die "$meta_config_path makes '$name' its own prerequisite"
				if published_depends_on "$unstable_rows" "$prerequisite" \
					"$name"
				then
					die "$meta_config_path contains an unstable dependency cycle through '$name'"
				fi
				if test "$prerequisite" = "$codex_name"
				then
					prerequisite_tip=$unstable_base_tip
				else
					prerequisite_tip=$(published_tip "$unstable_rows" \
						"$prerequisite")
					test -n "$prerequisite_tip" ||
						die "$meta_config_path records missing prerequisite '$prerequisite' for '$name'"
				fi
				git merge-base --is-ancestor "$prerequisite_tip" "$tip" ||
					die "$meta_config_path boundary for unstable topic '$name' is not in its published history"
			done
			git merge-base --is-ancestor "$tip" "$unstable_output_tip" ||
				die "$meta_config_path output does not contain published unstable topic '$name'"
		done <"$unstable_rows"
	fi
	git merge-base --is-ancestor "$base_tip" "$output_tip" ||
		die "$meta_config_path output is not based on its recorded base"

	if test "$version" = 2
	then
		write_meta_config "$base_name" "$base_tip" "$codex_name" \
			"$output_tip" "$rows" "$state/canonical-published-config" \
			"$unstable_rows" "$unstable_base_tip" "$unstable_output_tip"
	else
		write_meta_config "$base_name" "$base_tip" "$codex_name" \
			"$output_tip" "$rows" "$state/canonical-published-config"
	fi
	cmp -s "$config" "$state/canonical-published-config" ||
		die "$meta_config_path is not in canonical form"
	printf '%s\n' "$version" >"$state/config-version"
	printf '%s\n' "$base_tip" >"$state/published-base-oid"
	printf '%s\n' "$output_tip" >"$state/published-codex-oid"
	if test "$version" = 2
	then
		printf '%s\n' "$unstable_base_tip" \
			>"$state/published-unstable-base-oid"
		printf '%s\n' "$unstable_output_tip" \
			>"$state/published-unstable-oid"
	fi
)

topic_contains_commit () (
	topics=$1
	commit=$2
	while IFS="$tab" read -r name tip
	do
		if git merge-base --is-ancestor "$commit" "$tip"
		then
			return 0
		fi
	done <"$topics"
	return 1
)

validate_live_codex_delta () (
	published=$1
	current=$2
	topics=$3
	state=$4
	test "$published" != "$current" || return 0
	git merge-base --is-ancestor "$published" "$current" ||
		die "current codex no longer contains the output recorded by $meta_config_path"
	git rev-list --first-parent "$published..$current" \
		>"$state/codex-first-parent-delta" ||
		die "could not inspect commits added directly to codex"
	test "$(wc -l <"$state/codex-first-parent-delta" | tr -d ' ')" = 1 ||
		die "more than one pending Codex pull-request merge"
	commit=$(sed -n '1p' "$state/codex-first-parent-delta")
	parents=$(git show -s --format=%P "$commit") ||
		die "could not inspect codex commit $commit"
	set -- $parents
	test $# = 2 && test "$1" = "$published" ||
		die "pending Codex merge is not a normal two-parent merge"
	second=$2
	awk -F '\t' -v oid="$second" '$2 == oid { found=1 }
		END { exit !found }' "$topics" ||
		die "could not authenticate the merged Codex pull request"
	if ! git merge-tree --write-tree "$published" "$second" \
		>"$state/codex-merge-tree" 2>/dev/null
	then
		die "pending Codex merge contains an unreviewed conflict resolution"
	fi
	test "$(wc -l <"$state/codex-merge-tree" | tr -d ' ')" = 1 ||
		die "could not verify the tree of codex merge $commit"
	expected_tree=$(sed -n '1p' "$state/codex-merge-tree")
	actual_tree=$(git rev-parse "$commit^{tree}") ||
		die "could not inspect the tree of codex merge $commit"
	test "$expected_tree" = "$actual_tree" ||
		die "pending Codex merge contains changes outside its reviewed topic"
)

prepare_plan () {
	base_name=$1
	base_oid=$2
	topics=$3
	state=$4
	allow_merge_graph=${5:-}
	unique=$state/unique-topic-inputs
	pairs=$state/topic-pairs
	plan=$state/plan
	if test -n "$allow_merge_graph"
	then
		: >"$state/prerequisites"
	fi

	# Multiple refs may intentionally name the same topic tip.  Rewrite that
	# tip once and let finish_updates() apply the result to every alias.
	awk -F '\t' '!seen[$2]++ { print }' "$topics" >"$unique" ||
		die "could not collect unique topic tips"

	# Siblings may share private history only when that shared prefix is itself
	# an active topic.  Otherwise there is no single topic that owns the shared
	# commits, and independently rebasing the siblings would duplicate them.
	awk -F '\t' '
		{ name[NR]=$1; oid[NR]=$2 }
		END {
			for (i = 1; i <= NR; i++)
				for (j = i + 1; j <= NR; j++)
					printf "%s\t%s\t%s\t%s\n",
						name[i], oid[i], name[j], oid[j]
		}
	' "$unique" >"$pairs" || die "could not enumerate topic pairs"
	while IFS="$tab" read -r left_name left_oid right_name right_oid
	do
		if git merge-base --is-ancestor "$left_oid" "$right_oid" ||
			git merge-base --is-ancestor "$right_oid" "$left_oid"
		then
			continue
		fi
		git merge-base --all "$left_oid" "$right_oid" \
			>"$state/shared-bases" ||
			die "could not find the shared history of '$left_name' and '$right_name'"
		count=$(wc -l <"$state/shared-bases" | tr -d ' ')
		test "$count" = 1 ||
			die "topics '$left_name' and '$right_name' have multiple merge bases; restack them into a one-prerequisite topic graph"
		shared=$(sed -n '1p' "$state/shared-bases")
		if git merge-base --is-ancestor "$shared" "$base_oid" ||
			awk -F '\t' -v oid="$shared" '$2 == oid { found=1 }
				END { exit !found }' "$unique"
		then
			continue
		fi
		if test -n "$allow_merge_graph" &&
			topic_integrates_shared_helper "$left_oid" "$shared" \
				"$base_oid" "$state" &&
			topic_integrates_shared_helper "$right_oid" "$shared" \
				"$base_oid" "$state"
		then
			: >"$state/merge-graph"
			continue
		fi
		die "topics '$left_name' and '$right_name' share private commits through $shared; create an active ??/codex/* prerequisite topic at that shared prefix or restack the branches"
	done <"$pairs"

	: >"$plan"
	while IFS="$tab" read -r name old
	do
		git merge-base --all "$base_oid" "$old" \
			>"$state/root-bases" ||
			die "topic '$name' has no common history with master"
		count=$(wc -l <"$state/root-bases" | tr -d ' ')
		test "$count" = 1 ||
			die "topic '$name' has multiple merge bases with master; restack it before refreshing codex"
		root_base=$(sed -n '1p' "$state/root-bases")

		: >"$state/topic-ancestors"
		while IFS="$tab" read -r other_name other_oid
		do
			test "$other_oid" = "$old" && continue
			test "$other_oid" = "$root_base" && continue
			if git merge-base --is-ancestor "$root_base" "$other_oid" &&
				git merge-base --is-ancestor "$other_oid" "$old"
			then
				printf '%s\t%s\n' "$other_name" "$other_oid" \
					>>"$state/topic-ancestors" ||
					die "could not record a prerequisite for '$name'"
			fi
		done <"$unique"

		: >"$state/nearest-ancestors"
		while IFS="$tab" read -r ancestor_name ancestor_oid
		do
			near=t
			while IFS="$tab" read -r other_name other_oid
			do
				test "$ancestor_oid" = "$other_oid" && continue
				if git merge-base --is-ancestor \
					"$ancestor_oid" "$other_oid"
				then
					near=
					break
				fi
			done <"$state/topic-ancestors"
			test -z "$near" || printf '%s\t%s\n' \
				"$ancestor_name" "$ancestor_oid" \
				>>"$state/nearest-ancestors"
		done <"$state/topic-ancestors"

		count=$(wc -l <"$state/nearest-ancestors" | tr -d ' ')
		case "$count" in
		0)
			prerequisite=$base_name
			old_base=$root_base
			prerequisites=$base_name
			;;
		1)
			IFS="$tab" read -r prerequisite old_base \
				<"$state/nearest-ancestors"
			prerequisites=$prerequisite
			;;
		*)
			test -n "$allow_merge_graph" ||
				die "topic '$name' has more than one nearest prerequisite; restack it onto one prerequisite topic"
			LC_ALL=C sort -t "$tab" -k1,1 \
				"$state/nearest-ancestors" >"$state/sorted-nearest-ancestors" ||
				die "could not sort prerequisites for '$name'"
			IFS="$tab" read -r prerequisite old_base \
				<"$state/sorted-nearest-ancestors"
			prerequisites=$(cut -f1 "$state/sorted-nearest-ancestors" |
				tr '\n' ' ' | sed 's/ $//')
			: >"$state/merge-graph"
			;;
		esac

		git merge-base --is-ancestor "$old_base" "$old" ||
			die "prerequisite '$prerequisite' is not an ancestor of '$name'"
		merge_commit=$(git rev-list --min-parents=2 \
			"$old_base..$old" | sed -n '1p')
		if test -n "$merge_commit"
		then
			test -n "$allow_merge_graph" ||
				die "topic history for '$name' contains merge commit $merge_commit; linearize it before refreshing codex"
			: >"$state/merge-graph"
		fi
		if test -n "$allow_merge_graph"
		then
			printf '%s\t%s\t%s\n' "$name" "$old" "$prerequisites" \
				>>"$state/prerequisites" ||
				die "could not record merge-graph prerequisites for '$name'"
		fi
		printf '%s\t%s\t%s\t%s\t%s\n' \
			"$name" "$old" "$prerequisite" "$old_base" "$old_base" \
			>>"$plan" ||
			die "could not record the rewrite plan for '$name'"
	done <"$unique"

	: >"$state/map"
	: >"$state/results"
}

published_depends_on () (
	rows=$1
	child=$2
	ancestor=$3
	limit=$(wc -l <"$rows" | tr -d ' ')
	steps=0
	queue=$child
	visited=
	while test -n "$queue"
	do
		set -- $queue
		child=$1
		shift
		queue=$*
		case " $visited " in
		*" $child "*) continue ;;
		esac
		visited=${visited:+$visited }$child
		steps=$((steps + 1))
		test "$steps" -le "$limit" ||
			die "$meta_config_path contains a dependency cycle"
		for parent in $(published_prerequisites "$rows" "$child")
		do
			test "$parent" = "$ancestor" && return 0
			test -n "$(published_tip "$rows" "$parent")" || continue
			queue=${queue:+$queue }$parent
		done
	done
	return 1
)

published_shared_prerequisite () (
	published=$1
	graph=$2
	topics=$3
	left=$4
	right=$5
	shared=$6
	while IFS="$tab" read -r name tip prerequisite
	do
		test "$tip" = "$shared" || continue
		test -n "$(current_topic_tip "$topics" "$name")" || continue
		if published_depends_on "$graph" "$left" "$name" &&
			published_depends_on "$graph" "$right" "$name"
		then
			return 0
		fi
	done <"$published"
	return 1
)

current_topic_tip () (
	topics=$1
	name=$2
	awk -F '\t' -v name="$name" '$1 == name { value=$2 }
		END { if (value != "") print value }' "$topics"
)

effective_topic_tip () (
	topics=$1
	name=$2
	base_oid=$3
	tip=$(current_topic_tip "$topics" "$name")
	test -n "$tip" || return 0
	if git merge-base --is-ancestor "$tip" "$base_oid"
	then
		printf '%s\n' "$base_oid"
	else
		printf '%s\n' "$tip"
	fi
)

root_replay_boundary () (
	name=$1
	published_base=$2
	current_base=$3
	current_tip=$4
	state=$5
	if git merge-base --is-ancestor "$current_base" "$published_base" &&
		git merge-base --is-ancestor "$published_base" "$current_tip"
	then
		printf '%s\n' "$published_base"
		return
	fi
	if git merge-base --is-ancestor "$published_base" "$current_base" &&
		git merge-base --is-ancestor "$current_base" "$current_tip"
	then
		printf '%s\n' "$current_base"
		return
	fi
	if git merge-base --is-ancestor "$published_base" "$current_tip"
	then
		git merge-base --all "$current_base" "$current_tip" \
			>"$state/root-replay-bases" ||
			die "could not compare '$name' with current master"
		count=$(wc -l <"$state/root-replay-bases" | tr -d ' ')
		if test "$count" = 1
		then
			shared=$(sed -n '1p' "$state/root-replay-bases")
			if git merge-base --is-ancestor "$published_base" "$shared"
			then
				printf '%s\n' "$shared"
				return
			fi
		fi
		printf '%s\n' "$published_base"
		return
	fi
	if git merge-base --is-ancestor "$current_base" "$current_tip"
	then
		printf '%s\n' "$current_base"
		return
	fi
	git merge-base --all "$current_base" "$current_tip" \
		>"$state/root-replay-bases" ||
		die "topic '$name' has no common history with master"
	count=$(wc -l <"$state/root-replay-bases" | tr -d ' ')
	test "$count" = 1 ||
		die "topic '$name' has multiple merge bases with master; restack it before refreshing codex"
	shared=$(sed -n '1p' "$state/root-replay-bases")
	git merge-base --is-ancestor "$published_base" "$shared" ||
		die "topic '$name' forks before the last published master boundary"
	printf '%s\n' "$shared"
)

choose_replay_boundary () (
	name=$1
	old_base=$2
	current_base=$3
	current_tip=$4
	state=$5

	if git merge-base --is-ancestor "$current_base" "$old_base" &&
		git merge-base --is-ancestor "$old_base" "$current_tip"
	then
		# The prerequisite moved backwards.  Keep the old boundary so its
		# removed commits do not silently become part of the child topic.
		printf '%s\n' "$old_base"
		return
	fi
	if git merge-base --is-ancestor "$old_base" "$current_base" &&
		git merge-base --is-ancestor "$current_base" "$current_tip"
	then
		# The child was already advanced or restacked onto the current tip.
		printf '%s\n' "$current_base"
		return
	fi
	if git merge-base --is-ancestor "$old_base" "$current_tip"
	then
		git merge-base --all "$current_base" "$current_tip" \
			>"$state/replay-bases" ||
			die "could not compare the old and current prerequisite of '$name'"
		count=$(wc -l <"$state/replay-bases" | tr -d ' ')
		if test "$count" = 1
		then
			shared=$(sed -n '1p' "$state/replay-bases")
			if git merge-base --is-ancestor "$old_base" "$shared"
			then
				# The child contains an intermediate advance of its parent.
				printf '%s\n' "$shared"
				return
			fi
		fi
		# The prerequisite was rewritten while the child stayed on the
		# last published prerequisite.
		printf '%s\n' "$old_base"
		return
	fi
	if git merge-base --is-ancestor "$current_base" "$current_tip"
	then
		# The child was explicitly restacked and no longer contains the
		# old published boundary.
		printf '%s\n' "$current_base"
		return
	fi

	die "topic '$name' contains neither its last published nor current prerequisite; restack it explicitly before refreshing codex"
)

topic_integrates_shared_helper () (
	tip=$1
	shared=$2
	base=$3
	state=$4
	git rev-list --min-parents=2 "$tip" "^$base" \
		>"$state/internal-helper-merges" || return 1
	while read -r merge
	do
		parents=$(git show -s --format=%P "$merge") || return 1
		set -- $parents
		first=$1
		shift
		git merge-base --is-ancestor "$shared" "$first" && continue
		for parent
		do
			git merge-base --is-ancestor "$shared" "$parent" &&
				return 0
		done
	done <"$state/internal-helper-merges"
	return 1
)

prepare_stateful_plan () (
	base_name=$1
	base_oid=$2
	topics=$3
	state=$4
	allow_merge_graph=${5:-}
	published=$state/published-topics
	published_base=$(state_value "$state" published-base-oid)
	output_name=$(state_value "$state" codex-name)
	pairs=$state/topic-pairs
	plan=$state/plan
	if test -n "$allow_merge_graph"
	then
		: >"$state/prerequisites"
	fi

	# If two current tips are no longer comparable, their old recorded edge
	# still proves ownership across a prerequisite rewrite.  New incomparable
	# topics must not share an unrepresented private prefix.
	awk -F '\t' '
		{ name[NR]=$1; oid[NR]=$2 }
		END {
			for (i = 1; i <= NR; i++)
				for (j = i + 1; j <= NR; j++)
					printf "%s\t%s\t%s\t%s\n",
						name[i], oid[i], name[j], oid[j]
		}
	' "$topics" >"$pairs" || die "could not enumerate topic pairs"
	while IFS="$tab" read -r left_name left_oid right_name right_oid
	do
		test "$left_oid" = "$right_oid" && continue
		if git merge-base --is-ancestor "$left_oid" "$right_oid" ||
			git merge-base --is-ancestor "$right_oid" "$left_oid"
		then
			continue
		fi
		if published_depends_on "$published" "$left_name" "$right_name" ||
			published_depends_on "$published" "$right_name" "$left_name"
		then
			continue
		fi
		git merge-base --all "$left_oid" "$right_oid" \
			>"$state/shared-bases" ||
			die "could not find the shared history of '$left_name' and '$right_name'"
		count=$(wc -l <"$state/shared-bases" | tr -d ' ')
		test "$count" = 1 ||
			die "topics '$left_name' and '$right_name' have multiple merge bases; restack them into a one-prerequisite topic graph"
		shared=$(sed -n '1p' "$state/shared-bases")
		if git merge-base --is-ancestor "$shared" "$base_oid" ||
			awk -F '\t' -v oid="$shared" '$2 == oid { found=1 }
				END { exit !found }' "$topics" ||
			published_shared_prerequisite "$published" "$published" \
				"$topics" "$left_name" "$right_name" "$shared"
		then
			continue
		fi
		if test -n "$allow_merge_graph" &&
			topic_integrates_shared_helper "$left_oid" "$shared" \
				"$published_base" "$state" &&
			topic_integrates_shared_helper "$right_oid" "$shared" \
				"$published_base" "$state"
		then
			: >"$state/merge-graph"
			continue
		fi
		die "topics '$left_name' and '$right_name' share private commits through $shared; create an active ??/codex/* prerequisite topic at that shared prefix or restack the branches"
	done <"$pairs"

	: >"$plan"
	while IFS="$tab" read -r name current_tip
	do
		old_base=
		reparented=
		: >"$state/topic-ancestors"
		while IFS="$tab" read -r other_name other_tip
		do
			test "$other_name" = "$name" && continue
			test "$other_tip" = "$current_tip" && continue
			git merge-base --is-ancestor "$other_tip" "$base_oid" &&
				continue
			if git merge-base --is-ancestor "$other_tip" "$current_tip"
			then
				printf '%s\t%s\n' "$other_name" "$other_tip" \
					>>"$state/topic-ancestors" ||
					die "could not record a current prerequisite for '$name'"
			fi
		done <"$topics"
		: >"$state/nearest-ancestors"
		while IFS="$tab" read -r ancestor_name ancestor_tip
		do
			near=t
			while IFS="$tab" read -r other_name other_tip
			do
				test "$ancestor_tip" = "$other_tip" && continue
				if git merge-base --is-ancestor "$ancestor_tip" "$other_tip"
				then
					near=
					break
				fi
			done <"$state/topic-ancestors"
			test -z "$near" || printf '%s\t%s\n' \
				"$ancestor_name" "$ancestor_tip" \
				>>"$state/nearest-ancestors"
		done <"$state/topic-ancestors"
		published_tip_oid=$(published_tip "$published" "$name")
		count=$(wc -l <"$state/nearest-ancestors" | tr -d ' ')
		case "$count" in
		0) current_nearest= ; current_nearest_tip= ;;
		1) IFS="$tab" read -r current_nearest current_nearest_tip \
			<"$state/nearest-ancestors" ;;
		*)
			current_nearest=
			if test -n "$allow_merge_graph"
			then
				git rev-list --first-parent "$current_tip" \
					>"$state/first-parent-ancestry" ||
					die "could not inspect the first-parent prerequisite of '$name'"
				while read -r first_parent
				do
					first_parent_row=$(awk -F '\t' \
						-v oid="$first_parent" \
						'$2 == oid { print; exit }' \
						"$state/nearest-ancestors")
					test -n "$first_parent_row" || continue
					IFS="$tab" read -r current_nearest \
						current_nearest_tip <<-EOF
					$first_parent_row
					EOF
					break
				done <"$state/first-parent-ancestry"
				: >"$state/merge-graph"
			fi
			if test -z "$current_nearest" &&
				test -n "$published_tip_oid"
			then
				old_prerequisite=$(published_prerequisite "$published" "$name")
				current_nearest_tip=$(awk -F '\t' \
					-v name="$old_prerequisite" '$1 == name { print $2 }' \
					"$state/nearest-ancestors")
				test -z "$current_nearest_tip" ||
					current_nearest=$old_prerequisite
			fi
			if test -z "$current_nearest"
			then
				unique_nearest_tips=$(cut -f2 "$state/nearest-ancestors" |
					sort -u | wc -l | tr -d ' ')
				if test "$unique_nearest_tips" = 1
				then
					IFS="$tab" read -r current_nearest current_nearest_tip \
						<"$state/nearest-ancestors"
				fi
			fi
			if test -z "$current_nearest"
			then
				prerequisites=$(cut -f1 "$state/nearest-ancestors" |
					LC_ALL=C sort | tr '\n' ' ')
				die "topic '$name' has more than one nearest current prerequisite ($prerequisites); configure or restack it onto one topic"
			fi
			;;
		esac

		if test -n "$published_tip_oid"
		then
			old_prerequisite=$(published_prerequisite "$published" "$name")
			if test "$old_prerequisite" = "$base_name"
			then
				published_prerequisite_tip=$published_base
				old_prerequisite_tip=$base_oid
			else
				published_prerequisite_tip=$(published_tip \
					"$published" "$old_prerequisite")
				old_prerequisite_tip=$(effective_topic_tip "$topics" \
					"$old_prerequisite" "$base_oid")
			fi
			if test "$old_prerequisite" != "$base_name" &&
				test -n "$old_prerequisite_tip"
			then
				git merge-base --all "$old_prerequisite_tip" \
					"$published_tip_oid" >"$state/ownership-bases" ||
					die "could not verify ownership between '$old_prerequisite' and '$name'"
				if test "$(wc -l <"$state/ownership-bases" | tr -d ' ')" = 1
				then
					ownership_base=$(sed -n '1p' "$state/ownership-bases")
					if test "$ownership_base" != "$published_prerequisite_tip" &&
						git merge-base --is-ancestor \
							"$published_prerequisite_tip" "$ownership_base" &&
						! git merge-base --is-ancestor "$ownership_base" "$base_oid" &&
						test "$current_tip" != "$old_prerequisite_tip"
					then
						die "prerequisite '$old_prerequisite' now contains commits previously owned by '$name'; restack or retire the affected topic explicitly"
					fi
				fi
			fi
			published_parent_is_upstream=
			if test "$old_prerequisite" != "$base_name" &&
				git merge-base --is-ancestor "$published_prerequisite_tip" \
					"$base_oid"
			then
				published_parent_is_upstream=t
			fi
			if test -n "$current_nearest" &&
				test "$current_nearest" != "$old_prerequisite"
			then
				# An exact active topic tip in the current history is an
				# explicit restack (and may intentionally insert or reorder
				# a prerequisite).
				prerequisite=$current_nearest
				prerequisite_tip=$current_nearest_tip
				reparented=t
			elif test "$old_prerequisite" != "$base_name" &&
				test -n "$old_prerequisite_tip" &&
				test "$old_prerequisite_tip" = "$current_tip"
			then
				# Equal-tip aliases do not appear in the nearest-ancestor
				# search, but retain their configured edge.
				prerequisite=$old_prerequisite
				prerequisite_tip=$old_prerequisite_tip
				reparented=
			elif test "$old_prerequisite" != "$base_name" &&
				{ test -n "$published_parent_is_upstream" ||
					! git merge-base --is-ancestor \
						"$published_prerequisite_tip" "$current_tip"; } &&
				{ git merge-base --is-ancestor "$base_oid" "$current_tip" ||
					git merge-base --is-ancestor "$published_base" \
						"$current_tip"; }
			then
				# With the published prerequisite absent, a root history is
				# an explicit restack onto the current or published base.
				prerequisite=$base_name
				prerequisite_tip=$base_oid
				old_base=$(root_replay_boundary "$name" \
					"$published_base" "$base_oid" "$current_tip" "$state")
				reparented=t
			elif test "$old_prerequisite" = "$base_name" ||
				test -n "$old_prerequisite_tip"
			then
				prerequisite=$old_prerequisite
				prerequisite_tip=$old_prerequisite_tip
				reparented=
			else
				die "published prerequisite '$old_prerequisite' of '$name' was retired while '$name' still contains its old boundary; restack '$name' onto a surviving topic or current master first"
			fi

			if test "$reparented" = t
			then
				if ! git merge-base --is-ancestor "$prerequisite_tip" \
					"$current_tip"
				then
					test "$prerequisite" = "$base_name" &&
						test -n "$old_base" &&
						git merge-base --is-ancestor "$old_base" \
							"$current_tip" &&
						git merge-base --is-ancestor "$old_base" \
							"$prerequisite_tip" ||
						die "new prerequisite '$prerequisite' is not in '$name'"
				fi
				test -n "${old_base:-}" || old_base=$prerequisite_tip
			else
				old_base=$(choose_replay_boundary "$name" \
					"$published_prerequisite_tip" "$prerequisite_tip" \
					"$current_tip" "$state")
			fi
		else
			if test -n "$current_nearest"
			then
				prerequisite=$current_nearest
				prerequisite_tip=$current_nearest_tip
			else
				prerequisite=$base_name
				prerequisite_tip=$base_oid
			fi
			if test "$prerequisite" = "$base_name"
			then
				old_base=$(root_replay_boundary "$name" "$published_base" \
					"$prerequisite_tip" "$current_tip" "$state")
			elif git merge-base --is-ancestor "$prerequisite_tip" "$current_tip"
			then
				old_base=$prerequisite_tip
			else
				die "new topic '$name' is not based on '$prerequisite'"
			fi
		fi

		merge_commit=$(git rev-list --min-parents=2 \
			"$old_base..$current_tip" | sed -n '1p')
		if test -n "$merge_commit"
		then
			test -n "$allow_merge_graph" ||
				die "topic history for '$name' contains merge commit $merge_commit; linearize it before refreshing codex"
			: >"$state/merge-graph"
		fi
		printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$current_tip" \
			"$prerequisite" "$old_base" "$prerequisite_tip" >>"$plan" ||
			die "could not record the stateful rewrite plan for '$name'"
		if test -n "$allow_merge_graph"
		then
			prerequisites=$prerequisite
			if test "$prerequisite" != "$base_name"
			then
				while IFS="$tab" read -r ancestor_name ancestor_tip
				do
					test "$ancestor_name" = "$prerequisite" && continue
					case " $prerequisites " in
					*" $ancestor_name "*) continue ;;
					esac
					prerequisites="$prerequisites $ancestor_name"
				done <"$state/nearest-ancestors"
			fi
			for previous in $(published_prerequisites "$published" "$name")
			do
				test "$previous" = "$base_name" && continue
				previous_tip=$(published_tip "$published" "$previous")
				test -n "$previous_tip" || continue
				if git merge-base --is-ancestor "$previous_tip" "$base_oid"
				then
					continue
				fi
				git merge-base --is-ancestor "$previous_tip" \
					"$current_tip" || continue
				previous_current=$(current_topic_tip "$topics" "$previous")
				test -n "$previous_current" ||
					die "published prerequisite '$previous' of '$name' was retired while its merge remains in the topic"
				if test -n "$merge_commit" &&
					test "$previous_current" != "$previous_tip" &&
					{ ! git merge-base --is-ancestor "$previous_tip" \
							"$previous_current" ||
						! git merge-base --is-ancestor "$previous_current" \
							"$current_tip"; }
				then
					die "published prerequisite '$previous' of merge topic '$name' changed; restack '$name' explicitly before refreshing $output_name"
				fi
				case " $prerequisites " in
				*" $previous "*) continue ;;
				esac
				prerequisites="$prerequisites $previous"
			done
			printf '%s\t%s\t%s\n' "$name" "$current_tip" \
				"$prerequisites" >>"$state/prerequisites" ||
				die "could not record merge-graph prerequisites for '$name'"
		fi
	done <"$topics"
	while IFS="$tab" read -r name current_tip prerequisite old_base prerequisite_tip
	do
		test "$name" != "$prerequisite" ||
			die "topic '$name' cannot be its own prerequisite"
		if test "$prerequisite" != "$base_name"
		then
			if test -n "$allow_merge_graph"
			then
				prerequisites=$(planned_prerequisites "$state" "$name")
				dependency_rows=$state/prerequisites
			else
				prerequisites=$prerequisite
				dependency_rows=$plan
			fi
			for dependency in $prerequisites
			do
				test -n "$(current_topic_tip "$topics" "$dependency")" ||
					die "topic '$name' has missing prerequisite '$dependency'"
				if published_depends_on "$dependency_rows" \
					"$dependency" "$name"
				then
					die "current topic prerequisites contain a cycle through '$name'"
				fi
			done
		fi
	done <"$plan"
	if test -n "$allow_merge_graph"
	then
		dependency_rows=$state/prerequisites
	else
		dependency_rows=$plan
	fi
	while IFS="$tab" read -r left_name left_oid right_name right_oid
	do
		test "$left_oid" = "$right_oid" && continue
		if git merge-base --is-ancestor "$left_oid" "$right_oid" ||
			git merge-base --is-ancestor "$right_oid" "$left_oid" ||
			published_depends_on "$dependency_rows" \
				"$left_name" "$right_name" ||
			published_depends_on "$dependency_rows" \
				"$right_name" "$left_name"
		then
			continue
		fi
		git merge-base --all "$left_oid" "$right_oid" \
			>"$state/final-shared-bases" ||
			die "could not validate the final topic ownership graph"
		test "$(wc -l <"$state/final-shared-bases" | tr -d ' ')" = 1 ||
			die "topics '$left_name' and '$right_name' have multiple merge bases after reparenting"
		shared=$(sed -n '1p' "$state/final-shared-bases")
		if git merge-base --is-ancestor "$shared" "$base_oid" ||
			awk -F '\t' -v oid="$shared" '$2 == oid { found=1 }
				END { exit !found }' "$topics" ||
			published_shared_prerequisite "$published" "$dependency_rows" \
				"$topics" "$left_name" "$right_name" "$shared"
		then
			continue
		fi
		if test -n "$allow_merge_graph" &&
			topic_integrates_shared_helper "$left_oid" "$shared" \
				"$published_base" "$state" &&
			topic_integrates_shared_helper "$right_oid" "$shared" \
				"$published_base" "$state"
		then
			continue
		fi
		die "topics '$left_name' and '$right_name' would become siblings while sharing private commits through $shared; create a prerequisite topic at that prefix or restack them"
	done <"$pairs"

	# A removed topic is a valid retirement only when no surviving topic still
	# records it as its prerequisite.
	while IFS="$tab" read -r old_name old_tip old_prerequisite
	do
		current_topic_tip "$topics" "$old_name" >/dev/null && continue
		if test -n "$allow_merge_graph"
		then
			dependency_rows=$state/prerequisites
		else
			dependency_rows=$plan
		fi
		if awk -F '\t' -v prerequisite="$old_name" '
			{
				count=split($3, dependencies, " ")
				for (i=1; i<=count; i++)
					if (dependencies[i] == prerequisite) found=1
			}
			END { exit !found }
		' "$dependency_rows"
		then
			die "published topic '$old_name' was removed while an active topic still depends on it"
		fi
	done <"$published"
	if test -n "$allow_merge_graph" && test -f "$state/merge-graph"
	then
		current_base_topics=
		old_base_topics=
		while IFS="$tab" read -r name oid
		do
			if git merge-base --is-ancestor "$base_oid" "$oid"
			then
				current_base_topics=t
			else
				old_base_topics=t
			fi
		done <"$topics"
		test -z "$current_base_topics" || test -z "$old_base_topics" ||
			die "merge graph mixes current and previous production bases; restack every topic onto the same production base"
	fi
	: >"$state/map"
	: >"$state/results"
)

prepare_pinned_plan () (
	base_name=$1
	base_oid=$2
	topics=$3
	state=$4
	desired=$state/desired-prerequisites
	desired_source_bases=$state/desired-source-bases
	published=$state/published-topics
	published_sources=$state/published-source-topics
	published_base=$(state_value "$state" published-base-oid)
	source_base=$(state_value "$state" source-base-oid)
	pinned_merge_root=$state/pinned-merge-root
	plan=$state/plan

	: >"$plan"
	while IFS="$tab" read -r name current_tip
	do
		prerequisites=$(plan_prerequisites "$desired" "$name")
		test -n "$prerequisites" ||
			die "pinned plan has no prerequisite for '$name'"
		reviewed_source_base=$(plan_source_base "$desired_source_bases" \
			"$name")
		test -n "$reviewed_source_base" ||
			die "pinned plan has no source boundary for '$name'"
		set -- $prerequisites
		test $# = 1 ||
			die "pinned plan topic '$name' has more than one prerequisite; split merge-shaped topics before enrolling them"
		prerequisite=$1
		if test "$prerequisite" = "$base_name"
		then
			desired_source_base=$source_base
		else
			desired_source_base=$(current_topic_tip "$topics" \
				"$prerequisite")
			test -n "$desired_source_base" ||
				die "pinned plan topic '$name' has missing prerequisite '$prerequisite'"
		fi
		published_generated=$(published_tip "$published" "$name")
		published_source=$(published_tip "$published_sources" "$name")
		merge_commit=$(git rev-list --min-parents=2 \
			"$reviewed_source_base..$current_tip" | sed -n '1p')
		if test -n "$merge_commit"
		then
			git merge-base --is-ancestor "$reviewed_source_base" \
				"$current_tip" ||
				die "pinned merge-shaped topic '$name' is outside its reviewed source boundary"
			# A previously generated root is already safe when neither its
			# reviewed source nor its generated lane base moved.  Reuse it
			# instead of needlessly replaying the same merge graph.
			if test -n "$published_generated" &&
				test "$current_tip" = "$published_source" &&
				test "$prerequisites" = \
					"$(published_prerequisites "$published" "$name")" &&
				test "$prerequisite" = "$base_name" &&
				test "$published_base" = "$base_oid"
			then
				printf '%s\t%s\t%s\t%s\t%s\n' "$name" \
					"$published_generated" "$prerequisite" \
					"$base_oid" "$desired_source_base" >>"$plan" ||
					die "could not retain merge-shaped pinned topic '$name'"
				continue
			fi
			# Keep a reviewed merge-shaped source byte-for-byte only when
			# it already sits on the exact generated lane base.  Otherwise
			# replay the reviewed graph from its explicit source boundary;
			# inferring a merge base against a moved generated lane would
			# accidentally replay old integration commits.
			if test "$reviewed_source_base" = "$base_oid" &&
				git merge-base --is-ancestor "$base_oid" "$current_tip"
			then
				printf '%s\t%s\t%s\t%s\t%s\n' "$name" \
					"$current_tip" "$prerequisite" "$base_oid" \
					"$desired_source_base" >>"$plan" ||
					die "could not record merge-shaped pinned topic '$name'"
				continue
			fi
			if test -f "$pinned_merge_root"
			then
				test "$(state_value "$state" pinned-merge-root)" = \
					"$reviewed_source_base" ||
					die "pinned merge-shaped topics have different reviewed source boundaries; split them before publication"
			else
				printf '%s\n' "$reviewed_source_base" \
					>"$pinned_merge_root" ||
					die "could not retain the pinned merge replay root"
			fi
			: >"$state/merge-graph"
			printf '%s\t%s\t%s\t%s\t%s\n' "$name" \
				"$current_tip" "$prerequisite" \
				"$reviewed_source_base" "$desired_source_base" \
				>>"$plan" ||
				die "could not record merge-shaped pinned topic '$name'"
			continue
		fi

		if test -n "$published_generated"
		then
			test -n "$published_source" ||
				die "$meta_config_path has no source boundary for '$name'"
			old_prerequisites=$(published_prerequisites "$published" "$name")
			set -- $old_prerequisites
			test $# = 1 ||
				die "$meta_config_path records merge-shaped topic '$name'; migrate it before using pinned plans"
			old_prerequisite=$1
			if test "$old_prerequisite" = "$base_name"
			then
				old_source_base=$published_base
				old_generated_base=$published_base
			else
				old_source_base=$(published_tip "$published_sources" \
					"$old_prerequisite")
				old_generated_base=$(published_tip "$published" \
					"$old_prerequisite")
				test -n "$old_source_base" &&
					test -n "$old_generated_base" ||
					die "$meta_config_path has missing published prerequisite '$old_prerequisite' for '$name'"
			fi

			if test "$current_tip" = "$published_source" &&
				test "$prerequisites" = "$old_prerequisites"
			then
				# The reviewed source did not change. Rebase the already
				# generated topic only when its generated parent moves.
				old=$published_generated
				old_base=$old_generated_base
				elif test "$prerequisites" = "$old_prerequisites"
				then
					old=$current_tip
					if test "$desired_source_base" != "$old_source_base" &&
					git merge-base --is-ancestor \
						"$desired_source_base" "$current_tip"
				then
						# The author explicitly restacked onto the new
						# prerequisite source tip.
						old_base=$desired_source_base
					elif test "$reviewed_source_base" != \
						"$old_source_base" &&
						git merge-base --is-ancestor \
							"$reviewed_source_base" "$current_tip"
					then
						# The plan records the exact source boundary
						# reviewed with this new tip.  It may be an
						# older lane base if that base moved after
						# the plan was admitted.
						old_base=$reviewed_source_base
					elif git merge-base --is-ancestor \
					"$old_source_base" "$current_tip"
				then
					# Keep the old source boundary when a parent was
					# rewritten but this child was not restacked.
					old_base=$old_source_base
				else
					die "pinned topic '$name' is outside both its applied and desired source boundaries"
				fi
			else
				old=$current_tip
				git merge-base --is-ancestor "$reviewed_source_base" \
					"$current_tip" ||
					die "reordered topic '$name' is not based on its desired prerequisite '$prerequisite'"
				old_base=$reviewed_source_base
			fi
		else
			old=$current_tip
			git merge-base --is-ancestor "$reviewed_source_base" \
				"$current_tip" ||
				die "new pinned topic '$name' is not based on its desired prerequisite '$prerequisite'"
			old_base=$reviewed_source_base
		fi
		printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$old" \
			"$prerequisite" "$old_base" "$desired_source_base" \
			>>"$plan" || die "could not record pinned rewrite for '$name'"
	done <"$topics"

	while IFS="$tab" read -r old_name old_tip old_prerequisite
	do
		current_topic_tip "$topics" "$old_name" >/dev/null && continue
		if awk -F '\t' -v prerequisite="$old_name" \
			'$3 == prerequisite { found=1 } END { exit !found }' "$plan"
		then
			die "pinned plan removes '$old_name' while an active topic still depends on it"
		fi
	done <"$published"
	if test -f "$pinned_merge_root"
	then
		root=$(state_value "$state" pinned-merge-root)
		rooted=$state/pinned-merge-rooted-topics
		: >"$rooted"
		while IFS="$tab" read -r name current_tip
		do
			topic_source_base=$(plan_source_base \
				"$desired_source_bases" "$name")
			test -n "$topic_source_base" ||
				die "pinned merge graph has no source boundary for '$name'"
			git merge-base --is-ancestor "$topic_source_base" \
				"$current_tip" ||
				die "pinned merge graph topic '$name' is outside its reviewed source boundary"
			if test "$topic_source_base" != "$root"
			then
				# A linear child can extend the same reviewed graph.
				# Require its exact pinned parent, not merely an
				# ancestor of the child or a previously generated tip.
				# Plans list prerequisites first, so accepted rows
				# prove the chain back to the one replay root.
				prerequisites=$(plan_prerequisites "$desired" "$name")
				set -- $prerequisites
				test $# = 1 ||
					die "pinned merge graph topic '$name' has more than one prerequisite"
				prerequisite=$1
				prerequisite_tip=$(current_topic_tip "$topics" \
					"$prerequisite")
				test "$prerequisite" != "$base_name" &&
					test "$topic_source_base" = "$prerequisite_tip" &&
					grep -F -x -- "$prerequisite" "$rooted" >/dev/null ||
					die "pinned merge graph topic '$name' has a different reviewed source boundary; split it before publication"
				merge_commit=$(git rev-list --min-parents=2 \
					--max-count=1 "$topic_source_base..$current_tip") ||
					die "could not inspect pinned dependent topic '$name'"
				test -z "$merge_commit" ||
					die "pinned merge graph topic '$name' has a merge-shaped dependent range"
			fi
			printf '%s\n' "$name" >>"$rooted" ||
				die "could not retain rooted pinned topic '$name'"
		done <"$topics"
	fi
	: >"$state/map"
	: >"$state/results"
)

rebase_in_progress () {
	worktree=$1
	test -d "$(git -C "$worktree" rev-parse --path-format=absolute \
		--git-path rebase-merge)" ||
		test -d "$(git -C "$worktree" rev-parse --path-format=absolute \
		--git-path rebase-apply)"
}

continue_rerere_resolution () {
	worktree=$1

	while rebase_in_progress "$worktree" &&
		test -z "$(git -C "$worktree" -c core.fsmonitor=false ls-files -u)"
	do
		if ! GIT_COMMITTER_NAME=$bot_name \
			GIT_COMMITTER_EMAIL=$bot_email \
			GIT_EDITOR=true git -C "$worktree" \
			-c core.hooksPath=/dev/null \
			-c core.fsmonitor=false \
			-c commit.gpgSign=false \
			-c rerere.enabled=true \
			-c rerere.autoupdate=true \
			rebase --continue
		then
			rebase_in_progress "$worktree" ||
				die "git rebase --continue failed without recoverable state"
			test -n "$(git -C "$worktree" \
				-c core.fsmonitor=false ls-files -u)" && return 1
			die "git rebase --continue failed after rerere staged a resolution"
		fi
	done

	! rebase_in_progress "$worktree"
}

make_topic_sentinel () {
	worktree=$1
	name=$2
	old=$3
	tree=$(git -C "$worktree" rev-parse "$old^{tree}") ||
		die "could not read the tree for topic '$name'"
	message=$(printf 'Codex rewrite sentinel: %s\n\nCodex-Rewrite-Sentinel: %s@%s\n' \
		"$name" "$name" "$old")
	printf '%s' "$message" | GIT_AUTHOR_NAME=$bot_name \
		GIT_AUTHOR_EMAIL=$bot_email GIT_COMMITTER_NAME=$bot_name \
		GIT_COMMITTER_EMAIL=$bot_email git -C "$worktree" \
		commit-tree "$tree" -p "$old" ||
		die "could not create the completion sentinel for '$name'"
}

completed_topic_tip () {
	worktree=$1
	name=$2
	old=$3
	new_base=$4
	head=$(git -C "$worktree" rev-parse HEAD) ||
		die "could not read the completed rebase for '$name'"
	marker=$(git -C "$worktree" show -s \
		--format='%(trailers:key=Codex-Rewrite-Sentinel,valueonly)' "$head") ||
		die "could not inspect the completion sentinel for '$name'"
	test "$marker" = "$name@$old" ||
		die "the rebase for '$name' did not reach its completion sentinel; continue the pinned rebase instead of quitting it"
	parents=$(git -C "$worktree" rev-list --parents -n 1 "$head") ||
		die "could not inspect the completion sentinel for '$name'"
	set -- $parents
	test $# = 2 || die "the completion sentinel for '$name' is not linear"
	new=$2
	test "$new" != "$old" ||
		die "the stopped rebase for '$name' was aborted; run the pinned resolve command again"
	test "$(git -C "$worktree" rev-parse "$head^{tree}")" = \
		"$(git -C "$worktree" rev-parse "$new^{tree}")" ||
		die "the completion sentinel for '$name' unexpectedly changes the tree"
	git -C "$worktree" merge-base --is-ancestor "$new_base" "$new" ||
		die "the completed topic '$name' is not based on its rewritten prerequisite"
	merge_commit=$(git -C "$worktree" rev-list --min-parents=2 \
		"$new_base..$new" | sed -n '1p')
	test -z "$merge_commit" ||
		die "the completed topic '$name' contains merge commit $merge_commit"
	printf '%s\n' "$new"
}

rebase_topic () {
	worktree=$1
	name=$2
	old=$3
	old_base=$4
	new_base=$5
	sentinel=$(make_topic_sentinel "$worktree" "$name" "$old")

	git -C "$worktree" -c core.fsmonitor=false \
		-c advice.detachedHead=false switch --detach "$sentinel" \
		>/dev/null 2>&1 ||
		die "could not check out topic tip $old for rebasing"
	if GIT_COMMITTER_NAME=$bot_name GIT_COMMITTER_EMAIL=$bot_email \
		GIT_EDITOR=true git -C "$worktree" \
		-c core.hooksPath=/dev/null \
		-c core.fsmonitor=false \
		-c commit.gpgSign=false \
		-c rerere.enabled=true \
		-c rerere.autoupdate=true \
		rebase --merge --empty=drop --keep-empty --reapply-cherry-picks \
		--no-autostash --no-update-refs \
		--onto "$new_base" "$old_base"
	then
		return 0
	fi

	rebase_in_progress "$worktree" ||
		die "git rebase failed without leaving recoverable state"
	continue_rerere_resolution "$worktree"
}

record_rebase_failure () {
	worktree=$1
	state=$2
	name=$3
	old=$4
	old_base=$5
	new_base=$6
	failed_commit=$(git -C "$worktree" rev-parse --verify REBASE_HEAD \
		2>/dev/null || printf '%s\n' "$old")
	printf '%s\n' "$old" >"$state/failed-old" || return 1
	printf '%s\n' "$name" >"$state/failed-owner" || return 1
	printf '%s\n' "$old_base" >"$state/failed-parent" || return 1
	printf '%s\n' "$new_base" >"$state/failed-onto" || return 1
	printf '%s\n' "$failed_commit" >"$state/failed-commit" || return 1
}

process_ready_topics () {
	worktree=$1
	state=$2
	ready=$3
	while IFS="$tab" read -r name old prerequisite old_base new_base
	do
		new=$(transform_lookup "$state/map" "$old" "$old_base" \
			"$new_base")
		if test -n "$new"
		then
			result_record "$state/results" "$name" "$new"
			continue
		fi
		if test "$old" = "$old_base"
		then
			new=$new_base
		elif test "$old_base" = "$new_base"
		then
			new=$old
		elif rebase_topic "$worktree" "$name" "$old" "$old_base" "$new_base"
		then
			new=$(completed_topic_tip "$worktree" "$name" \
				"$old" "$new_base")
			git -C "$worktree" -c core.fsmonitor=false \
				-c advice.detachedHead=false switch --detach "$new" \
				>/dev/null 2>&1 ||
				die "could not detach at the rebased tip for '$name'"
		else
			record_rebase_failure "$worktree" "$state" "$name" \
				"$old" "$old_base" "$new_base" || return 1
			return 1
		fi
		transform_record "$state/map" "$old" "$old_base" "$new_base" \
			"$new"
		result_record "$state/results" "$name" "$new"
	done <"$ready"
}

train_rerere () (
	worktree=$1
	base_oid=$2
	tip_oid=$3
	toplevel=$(git -C "$worktree" rev-parse --show-toplevel) ||
		die "could not locate the reconstruction worktree"
	rereretrain=$toplevel/contrib/rerere-train.sh
	test -x "$rereretrain" ||
		die "master does not provide contrib/rerere-train.sh"

	cd "$worktree"
	GIT_CONFIG_COUNT=4 \
	GIT_CONFIG_KEY_0=rerere.enabled \
	GIT_CONFIG_VALUE_0=true \
	GIT_CONFIG_KEY_1=rerere.autoupdate \
	GIT_CONFIG_VALUE_1=true \
	GIT_CONFIG_KEY_2=core.fsmonitor \
	GIT_CONFIG_VALUE_2=false \
	GIT_CONFIG_KEY_3=core.hooksPath \
	GIT_CONFIG_VALUE_3=/dev/null \
		"$rereretrain" "$base_oid..$tip_oid"
)

finish_updates () {
	state=$1
	results=$state/results
	updates=$state/topic-updates
	: >"$updates" || die "could not prepare topic updates"
	if test -f "$state/pinned-plan-mode"
	then
		# Topic refs are reviewed inputs, not generated outputs.  The
		# App-owned codex-pins/<sha> ref retains the reviewed object; no
		# mutable source ref participates in publication.
		return
	fi
	while IFS="$tab" read -r name old
	do
		new=$(result_lookup "$results" "$name")
		test -n "$new" || die "topic '$name' was not rewritten"
		printf 'refs/heads/%s\t%s\t%s\n' "$name" "$old" "$new" \
			>>"$updates" || die "could not record update for '$name'"
	done <"$state/topics"
}

write_complete_updates () {
	state=$1
	candidate=$2
	output=$3
	codex_name=$(state_value "$state" codex-name)
	codex_oid=$(state_value "$state" codex-oid)
	controller_oid=$(state_value "$state" controller-oid)
	meta_oid=$(state_value "$state" meta-oid)

	cp "$state/topic-updates" "$output.unsorted" ||
		die "could not prepare complete update manifest"
	printf 'refs/heads/meta\t%s\t%s\n' \
		"$controller_oid" "$meta_oid" >>"$output.unsorted" ||
		die "could not record the meta state update"
	printf 'refs/heads/%s\t%s\t%s\n' \
		"$codex_name" "$codex_oid" "$candidate" >>"$output.unsorted" ||
		die "could not record the codex update"
	if test -f "$state/unstable-output-oid"
	then
		unstable_old=$(state_value "$state" unstable-oid)
		unstable_new=$(state_value "$state" unstable-output-oid)
		printf 'refs/heads/codex-unstable\t%s\t%s\n' \
			"$unstable_old" "$unstable_new" >>"$output.unsorted" ||
			die "could not record the codex-unstable update"
		if test -f "$state/unstable/topic-updates"
		then
			cat "$state/unstable/topic-updates" >>"$output.unsorted" ||
				die "could not record unstable topic updates"
		fi
	fi
	LC_ALL=C sort "$output.unsorted" >"$output" ||
		die "could not sort the complete update manifest"
	rm -f "$output.unsorted"
}

write_next_meta_config () (
	state=$1
	candidate=$2
	if test -f "$state/pinned-plan-mode"
	then
		rows=$state/next-published-topics
		: >"$rows"
		while IFS="$tab" read -r name source_tip
		do
			generated_tip=$(result_lookup "$state/results" "$name")
			test -n "$generated_tip" ||
				die "pinned topic '$name' has no generated tip"
			prerequisites=$(plan_prerequisites \
				"$state/desired-prerequisites" "$name")
			test -n "$prerequisites" ||
				die "pinned topic '$name' has no recorded prerequisite"
			printf '%s\t%s\t%s\t%s\n' "$name" "$source_tip" \
				"$generated_tip" "$prerequisites" >>"$rows" ||
				die "could not record next pinned state for '$name'"
		done <"$state/topics"
		LC_ALL=C sort -o "$rows" "$rows"
		unstable_rows=
		unstable_plan_blob=
		if test -f "$state/unstable-output-oid" &&
			! is_null_oid "$(state_value "$state" unstable-output-oid)"
		then
			unstable_state=$state/unstable
			unstable_rows=$state/next-published-unstable-topics
			: >"$unstable_rows"
			if test -d "$unstable_state" &&
				test -f "$unstable_state/pinned-plan-mode"
			then
				while IFS="$tab" read -r name source_tip
				do
					generated_tip=$(result_lookup \
						"$unstable_state/results" "$name")
					test -n "$generated_tip" ||
						die "pinned unstable topic '$name' has no generated tip"
					prerequisites=$(plan_prerequisites \
						"$unstable_state/desired-prerequisites" "$name")
					test -n "$prerequisites" ||
						die "pinned unstable topic '$name' has no recorded prerequisite"
					printf '%s\t%s\t%s\t%s\n' "$name" \
						"$source_tip" "$generated_tip" "$prerequisites" \
						>>"$unstable_rows" ||
						die "could not record next pinned unstable state for '$name'"
				done <"$unstable_state/topics"
				unstable_plan_blob=$(state_value "$unstable_state" \
					plan-blob)
			else
				unstable_plan_blob=$(state_value \
					"$state/desired-unstable-plan" plan-blob)
			fi
			LC_ALL=C sort -o "$unstable_rows" "$unstable_rows"
		fi
		if test -n "$unstable_plan_blob"
		then
			write_meta_config_v3 "$(state_value "$state" base-name)" \
				"$(state_value "$state" base-oid)" \
				"$(state_value "$state" codex-name)" "$candidate" \
				"$rows" "$state/next-meta-config" \
				"$(state_value "$state" plan-blob)" "$unstable_rows" \
				"$candidate" "$(state_value "$state" unstable-output-oid)" \
				"$unstable_plan_blob"
		else
			write_meta_config_v3 "$(state_value "$state" base-name)" \
				"$(state_value "$state" base-oid)" \
				"$(state_value "$state" codex-name)" "$candidate" \
				"$rows" "$state/next-meta-config" \
				"$(state_value "$state" plan-blob)"
		fi
		return
	fi
	rows=$state/next-published-topics
	: >"$rows"
	while IFS="$tab" read -r name old
	do
		new=$(result_lookup "$state/results" "$name")
		test -n "$new" || die "topic '$name' has no rewritten tip"
		prerequisites=$(planned_prerequisites "$state" "$name")
		test -n "$prerequisites" ||
			die "topic '$name' has no recorded prerequisite"
		printf '%s\t%s\t%s\n' "$name" "$new" "$prerequisites" >>"$rows" ||
			die "could not record next state for '$name'"
	done <"$state/topics"
	LC_ALL=C sort -o "$rows" "$rows"
	if test -f "$state/unstable-output-oid" &&
		! is_null_oid "$(state_value "$state" unstable-output-oid)"
	then
		unstable_state=$state/unstable
		unstable_rows=$state/next-published-unstable-topics
		: >"$unstable_rows"
		while IFS="$tab" read -r name old
		do
			new=$(result_lookup "$unstable_state/results" "$name")
			test -n "$new" ||
				die "unstable topic '$name' has no rewritten tip"
			prerequisites=$(planned_prerequisites "$unstable_state" "$name")
			test -n "$prerequisites" ||
				die "unstable topic '$name' has no recorded prerequisite"
			printf '%s\t%s\t%s\n' "$name" "$new" "$prerequisites" \
				>>"$unstable_rows" ||
				die "could not record next state for unstable topic '$name'"
		done <"$unstable_state/topics"
		LC_ALL=C sort -o "$unstable_rows" "$unstable_rows"
		write_meta_config "$(state_value "$state" base-name)" \
			"$(state_value "$state" base-oid)" \
			"$(state_value "$state" codex-name)" "$candidate" \
			"$rows" "$state/next-meta-config" "$unstable_rows" \
			"$candidate" "$(state_value "$state" unstable-output-oid)"
	else
		write_meta_config "$(state_value "$state" base-name)" \
			"$(state_value "$state" base-oid)" \
			"$(state_value "$state" codex-name)" "$candidate" \
			"$rows" "$state/next-meta-config"
	fi
)

create_meta_commit () (
	state=$1
	controller_oid=$(state_value "$state" controller-oid)
	write_next_meta_config "$state" "$2"

	if git diff --no-index --quiet "$state/published-config" \
		"$state/next-meta-config"
	then
		printf '%s\n' "$controller_oid" >"$state/meta-oid"
		return
	fi

	index=$state/meta-index
	rm -f "$index"
	blob=$(git hash-object -w "$state/next-meta-config") ||
		die "could not store the next $meta_config_path"
	GIT_INDEX_FILE=$index git read-tree "$controller_oid^{tree}" ||
		die "could not read the pinned meta tree"
	GIT_INDEX_FILE=$index git update-index --add --cacheinfo \
		100644,"$blob","$meta_config_path" ||
		die "could not add the next $meta_config_path"
	tree=$(GIT_INDEX_FILE=$index git write-tree) ||
		die "could not write the next meta tree"
	message=$(printf 'meta: record refreshed Codex topics\n\nUpdate the generated topic prerequisites and published boundaries after a successful Codex refresh.\n')
	meta_oid=$(printf '%s' "$message" | GIT_AUTHOR_NAME=$bot_name \
		GIT_AUTHOR_EMAIL=$bot_email GIT_COMMITTER_NAME=$bot_name \
		GIT_COMMITTER_EMAIL=$bot_email git -c commit.gpgSign=false \
		commit-tree "$tree" -p "$controller_oid") ||
		die "could not create the next meta state commit"
	printf '%s\n' "$meta_oid" >"$state/meta-oid"
	git diff-tree --no-commit-id --name-only -r \
		"$controller_oid" "$meta_oid" >"$state/meta-changed-paths" ||
		die "could not inspect the next meta commit"
	printf '%s\n' "$meta_config_path" >"$state/expected-meta-changed-paths"
	cmp -s "$state/meta-changed-paths" "$state/expected-meta-changed-paths" ||
		die "generated meta commit changes more than $meta_config_path"
)

process_plan () {
	worktree=$1
	state=$2
	base_oid=$(state_value "$state" base-oid)
	base_name=$(state_value "$state" base-name)
	plan=$state/plan
	ready=$state/ready
	pending=$state/pending

	while :
	do
		: >"$ready"
		: >"$pending"
		progress=
		while IFS="$tab" read -r name old prerequisite old_base prerequisite_tip
		do
			test -z "$(result_lookup "$state/results" "$name")" || continue
			printf '%s\n' "$name" >>"$pending"
			if test "$prerequisite" = "$base_name"
			then
				new_base=$base_oid
			else
				new_base=$(result_lookup "$state/results" "$prerequisite")
				test -n "$new_base" || continue
			fi
			if test "$old" = "$old_base"
			then
				result_record "$state/results" "$name" "$new_base"
				progress=t
				continue
			fi
			if test "$old_base" = "$new_base"
			then
				result_record "$state/results" "$name" "$old"
				progress=t
				continue
			fi
			printf '%s\t%s\t%s\t%s\t%s\n' \
				"$name" "$old" "$prerequisite" "$old_base" "$new_base" \
				>>"$ready"
		done <"$plan"

		test -s "$pending" || break
		if ! test -s "$ready"
		then
			test -n "$progress" && continue
			die "topic prerequisites contain an ancestry cycle"
		fi

		process_ready_topics "$worktree" "$state" "$ready" ||
			return 1
	done

	finish_updates "$state" || die "could not finish topic updates"
}

process_planned_graph () {
	worktree=$1
	state=$2
	if test -f "$state/merge-graph"
	then
		process_merge_graph "$worktree" "$state"
	else
		process_plan "$worktree" "$state"
	fi
}

prepare_pinned_merge_overlay () (
	state=$1
	root=$2
	base=$3
	topics=$state/topics
	base_paths=$state/pinned-merge-base-paths
	topic_paths=$state/pinned-merge-topic-paths
	overlap=$state/pinned-merge-overlap
	commits=$state/pinned-merge-source-commits

	rm -f "$state/pinned-merge-disjoint-base" ||
		die "could not reset pinned merge overlap state"
	git diff --no-renames --name-only "$root" "$base" >"$base_paths" ||
		die "could not inspect the moved pinned merge base"
	: >"$topic_paths"
	: >"$commits"
	while IFS="$tab" read -r name oid
	do
		git rev-list "$root..$oid" >>"$commits" ||
			die "could not enumerate pinned merge commits for '$name'"
	done <"$topics"
	LC_ALL=C sort -u -o "$commits" "$commits" ||
		die "could not retain pinned merge commits"
	git diff-tree --stdin -m --no-renames --no-commit-id --name-only -r \
		<"$commits" >"$topic_paths" ||
		die "could not inspect pinned merge paths"
	LC_ALL=C sort -u -o "$topic_paths" "$topic_paths" ||
		die "could not retain pinned merge paths"
	: >"$overlap"
	while IFS= read -r path
	do
		grep -F -x -- "$path" "$topic_paths" >/dev/null 2>&1 &&
			printf '%s\n' "$path" >>"$overlap"
	done <"$base_paths"
	if ! test -s "$overlap"
	then
		: >"$state/pinned-merge-disjoint-base"
	fi
)

write_pinned_merge_overlay_trees () (
	root=$1
	base=$2
	commits=$3
	trees=$4
	input=$trees.input
	raw=$trees.raw

	: >"$input"
	while IFS= read -r old
	do
		printf '%s -- %s %s\n' "$root" "$base" "$old" \
			>>"$input" ||
			die "could not prepare pinned merge tree input"
	done <"$commits"
	git merge-tree --write-tree --stdin -z <"$input" |
		tr '\000' '\n' >"$raw" ||
		die "could not compute pinned merge overlay trees"
	awk 'NR % 3 == 1 && $0 != "1" { bad=1 }
		END { exit bad }' "$raw" ||
		die "pinned merge graph overlaps its moved base"
	awk 'NR % 3 == 2 { print }' "$raw" >"$trees" ||
		die "could not retain pinned merge overlay trees"
	test "$(wc -l <"$trees" | tr -d ' ')" = \
		"$(wc -l <"$commits" | tr -d ' ')" ||
		die "pinned merge overlay tree count changed"
)

process_disjoint_pinned_merge_graph () (
	state=$1
	base_oid=$(state_value "$state" base-oid)
	root=$(state_value "$state" pinned-merge-root)
	output_name=$(state_value "$state" codex-name)
	topics=$state/topics
	commits=$state/pinned-merge-topological-commits
	trees=$state/pinned-merge-topological-trees
	map=$state/pinned-merge-replay-map

	set -- git rev-list --topo-order --reverse
	while IFS="$tab" read -r name oid
	do
		set -- "$@" "$oid"
	done <"$topics"
	set -- "$@" "^$root"
	"$@" >"$commits" ||
		die "could not order the pinned merge graph"
	write_pinned_merge_overlay_trees "$root" "$base_oid" \
		"$commits" "$trees"
	: >"$map"
	printf '%s\t%s\n' "$root" "$base_oid" >>"$map" ||
		die "could not map the pinned merge root"
	exec 3<"$trees"
	while IFS= read -r old
	do
		IFS= read -r tree <&3 ||
			die "could not read the replayed tree for $old"
		git show -s --format='%P%n%an%n%ae%n%aI%n%B' "$old" \
			>"$state/pinned-merge-commit" ||
			die "could not inspect pinned merge commit $old"
		{
			IFS= read -r parents ||
				die "could not read parents for $old"
			IFS= read -r author_name ||
				die "could not read author for $old"
			IFS= read -r author_email ||
				die "could not read author email for $old"
			IFS= read -r author_date ||
				die "could not read author date for $old"
			set -- git -c commit.gpgSign=false commit-tree "$tree"
			for parent in $parents
			do
				new_parent=$(awk -F '\t' -v oid="$parent" \
					'$1 == oid { print $2; exit }' "$map")
				if test -z "$new_parent"
				then
					git merge-base --is-ancestor "$parent" "$root" &&
						die "$output_name pinned merge graph crosses its reviewed replay root"
					die "$output_name pinned merge graph has an unmapped parent"
				fi
				set -- "$@" -p "$new_parent"
			done
			new=$(GIT_AUTHOR_NAME=$author_name \
				GIT_AUTHOR_EMAIL=$author_email \
				GIT_AUTHOR_DATE=$author_date \
				GIT_COMMITTER_NAME=$bot_name \
				GIT_COMMITTER_EMAIL=$bot_email \
				"$@") ||
				die "could not replay pinned merge commit $old"
		} <"$state/pinned-merge-commit"
		printf '%s\t%s\n' "$old" "$new" >>"$map" ||
			die "could not retain pinned merge replay mapping"
	done <"$commits"
	exec 3<&-
	while IFS="$tab" read -r name old
	do
		new=$(awk -F '\t' -v oid="$old" \
			'$1 == oid { print $2; exit }' "$map")
		test -n "$new" ||
			die "could not find replayed pinned topic '$name'"
		result_record "$state/results" "$name" "$new"
	done <"$topics"
	finish_updates "$state" ||
		die "could not finish pinned merge updates"
)

process_merge_graph () (
	worktree=$1
	state=$2
	base_oid=$(state_value "$state" base-oid)
	output_name=$(state_value "$state" codex-name)
	topics=$state/topics
	private=$state/private-merge-replay
	tracking=$state/private-topic-refs
	maximal=$state/maximal-topic-heads
	common=$state/merge-graph-root
	object_directory=$(git -C "$worktree" rev-parse \
		--path-format=absolute --git-path objects) ||
		die "could not locate the merge-replay object database"
	source=$(git -C "$worktree" rev-parse \
		--path-format=absolute --git-common-dir) ||
		die "could not locate the merge-replay source repository"

	if test -f "$state/pinned-merge-root"
	then
		root=$(state_value "$state" pinned-merge-root)
		require_full_commit_oid "$root"
		printf '%s\n' "$root" >"$common" ||
			die "could not retain the pinned merge replay root"
		while IFS="$tab" read -r name oid
		do
			git merge-base --is-ancestor "$root" "$oid" ||
				die "pinned merge graph topic '$name' is outside its reviewed source boundary"
		done <"$topics"
	else
		set -- git merge-base --all --octopus "$base_oid"
		while IFS="$tab" read -r name oid
		do
			set -- "$@" "$oid"
		done <"$topics"
		"$@" >"$common" ||
			die "$output_name merge graph has no common production ancestor"
		test "$(wc -l <"$common" | tr -d ' ')" = 1 ||
			die "$output_name merge graph has more than one production boundary"
		root=$(sed -n '1p' "$common")
		git merge-base --is-ancestor "$root" "$base_oid" ||
			die "$output_name merge graph is not rooted in the production candidate"
	fi
	if test -f "$state/pinned-merge-root"
	then
		prepare_pinned_merge_overlay "$state" "$root" "$base_oid"
		test -f "$state/pinned-merge-disjoint-base" ||
			die "pinned merge graph overlaps its moved base; restack it explicitly before publication"
		process_disjoint_pinned_merge_graph "$state"
		return 0
	fi

	if test "$root" = "$base_oid"
	then
		while IFS="$tab" read -r name oid
		do
			result_record "$state/results" "$name" "$oid"
		done <"$topics"
		finish_updates "$state"
		return 0
	fi

	: >"$maximal"
	while IFS="$tab" read -r name oid
	do
		if awk -F '\t' -v oid="$oid" '$2 == oid { found=1 }
			END { exit !found }' "$maximal"
		then
			continue
		fi
		dominated=
		while IFS="$tab" read -r other_name other_oid
		do
			test "$oid" = "$other_oid" && continue
			if git merge-base --is-ancestor "$oid" "$other_oid"
			then
				dominated=t
				break
			fi
		done <"$topics"
		test -n "$dominated" ||
			printf '%s\t%s\n' "$name" "$oid" >>"$maximal"
	done <"$topics"
	test -s "$maximal" ||
		die "$output_name merge graph has no maximal topic"
	first=$(awk -F '\t' 'NR == 1 { print $2 }' "$maximal")
	tree=$(git rev-parse "$first^{tree}") ||
		die "could not resolve the synthetic merge-replay tree"
	set -- git -c commit.gpgSign=false commit-tree "$tree"
	while IFS="$tab" read -r name oid
	do
		set -- "$@" -p "$oid"
	done <"$maximal"
	aggregate=$(printf 'Codex merge replay sentinel\n' |
		GIT_AUTHOR_NAME=$bot_name GIT_AUTHOR_EMAIL=$bot_email \
		GIT_COMMITTER_NAME=$bot_name GIT_COMMITTER_EMAIL=$bot_email \
		"$@") ||
		die "could not create the synthetic merge-replay sentinel"

	git -c core.fsmonitor=false clone --shared --no-checkout --no-tags \
		"$source" "$private" >/dev/null 2>&1 ||
		die "could not isolate the merge replay"
	: >"$tracking"
	index=0
	while IFS="$tab" read -r name oid
	do
		index=$((index + 1))
		ref=$(printf 'refs/heads/codex-private-rewrite/%06d' "$index")
		git -C "$private" update-ref "$ref" "$oid" ||
			die "could not track topic '$name' privately"
		printf '%s\t%s\t%s\n' "$name" "$oid" "$ref" \
			>>"$tracking" ||
			die "could not record the private merge-replay ref"
	done <"$topics"
	git -C "$private" -c core.fsmonitor=false \
		-c advice.detachedHead=false switch --detach "$aggregate" \
		>/dev/null 2>&1 ||
		die "could not check out the synthetic merge graph"
	if ! GIT_OBJECT_DIRECTORY=$object_directory \
		GIT_COMMITTER_NAME=$bot_name GIT_COMMITTER_EMAIL=$bot_email \
		GIT_SEQUENCE_EDITOR=true GIT_EDITOR=true git -C "$private" \
		-c core.hooksPath=/dev/null \
		-c core.fsmonitor=false \
		-c commit.gpgSign=false \
		-c rerere.enabled=true \
		-c rerere.autoupdate=true \
		rebase --rebase-merges=rebase-cousins --update-refs \
		--empty=keep \
		--keep-empty --reapply-cherry-picks --no-autostash \
		--onto "$base_oid" "$root"
	then
		owner=$(awk -F '\t' 'NR == 1 { print $1 }' "$state/plan")
		old=$(awk -F '\t' -v name="$owner" \
			'$1 == name { print $2; exit }' "$topics")
		record_rebase_failure "$private" "$state" "$owner" \
			"$old" "$root" "$base_oid" || return 1
		return 1
	fi
	while IFS="$tab" read -r name old ref
	do
		if test "$old" = "$root"
		then
			new=$base_oid
		else
			new=$(git -C "$private" rev-parse "$ref") ||
				die "could not read rewritten topic '$name'"
		fi
		git cat-file -e "$new^{commit}" ||
			die "topic '$name' was not imported into the main object database"
		git merge-base --is-ancestor "$base_oid" "$new" ||
			die "rewritten topic '$name' lost its production base"
		result_record "$state/results" "$name" "$new"
	done <"$tracking"
	finish_updates "$state"
)

verify_merge_topology () (
	base=$1
	state=$2
	topics=$state/topics
	root_file=$state/verified-merge-root
	source=$state/verified-source-commits
	rewritten=$state/verified-rewritten-commits
	map=$state/verified-commit-map
	pending=$state/verified-pending-commits
	round=$state/verified-current-commits

	if test -f "$state/pinned-merge-root"
	then
		root=$(state_value "$state" pinned-merge-root)
		require_full_commit_oid "$root"
		printf '%s\n' "$root" >"$root_file" ||
			die "could not retain the verified pinned merge root"
		while IFS="$tab" read -r name oid
		do
			git merge-base --is-ancestor "$root" "$oid" ||
				die "pinned merge graph topic '$name' is outside its reviewed source boundary"
		done <"$topics"
	else
		set -- git merge-base --all --octopus "$base"
		while IFS="$tab" read -r name oid
		do
			set -- "$@" "$oid"
		done <"$topics"
		"$@" >"$root_file" ||
			die "could not reconstruct the original merge-graph root"
		test "$(wc -l <"$root_file" | tr -d ' ')" = 1 ||
			die "merge graph has no unique verified production root"
		root=$(sed -n '1p' "$root_file")
	fi

	set -- git rev-list
	while IFS="$tab" read -r name oid
	do
		set -- "$@" "$oid"
	done <"$topics"
	set -- "$@" "^$root"
	"$@" >"$source" ||
		die "could not enumerate the original merge graph"

	set -- git rev-list
	while IFS="$tab" read -r name oid
	do
		new=$(result_lookup "$state/results" "$name")
		test -n "$new" ||
			die "merge graph has no rewritten tip for '$name'"
		set -- "$@" "$new"
	done <"$topics"
	set -- "$@" "^$base"
	"$@" >"$rewritten" ||
		die "could not enumerate the rewritten merge graph"

	: >"$map"
	printf '%s\t%s\n' "$root" "$base" >"$pending" ||
		die "could not map the merge-graph production root"
	while IFS="$tab" read -r name oid
	do
		new=$(result_lookup "$state/results" "$name")
		printf '%s\t%s\n' "$oid" "$new" >>"$pending" ||
			die "could not map merge topic '$name'"
	done <"$topics"

	while test -s "$pending"
	do
		mv "$pending" "$round" ||
			die "could not advance merge topology verification"
		: >"$pending"
		while IFS="$tab" read -r old new
		do
			mapped_new=$(awk -F '\t' -v oid="$old" \
				'$1 == oid { print $2; exit }' "$map")
			if test -n "$mapped_new"
			then
				test "$mapped_new" = "$new" ||
					die "merge rewrite duplicates a shared original commit"
				continue
			fi
			mapped_old=$(awk -F '\t' -v oid="$new" \
				'$2 == oid { print $1; exit }' "$map")
			test -z "$mapped_old" ||
				die "merge rewrite collapses distinct original commits"
			printf '%s\t%s\n' "$old" "$new" >>"$map" ||
				die "could not retain the verified commit mapping"

			if test "$old" = "$root"
			then
				test "$new" = "$base" ||
					die "merge rewrite changes its production root"
				continue
			fi
			if git merge-base --is-ancestor "$old" "$root"
			then
				git merge-base --is-ancestor "$new" "$base" ||
					die "merge rewrite introduces extra production ancestry"
				continue
			fi
			! git merge-base --is-ancestor "$new" "$base" ||
				die "merge rewrite drops an original topic commit"

			old_parents=$(git show -s --format=%P "$old") ||
				die "could not inspect an original merge-graph commit"
			new_parents=$(git show -s --format=%P "$new") ||
				die "could not inspect a rewritten merge-graph commit"
			set -- $old_parents
			old_count=$#
			set -- $new_parents
			test "$old_count" = "$#" ||
				die "merge rewrite changes commit parent topology"
			while test -n "$old_parents"
			do
				set -- $old_parents
				old_parent=$1
				shift
				old_parents=$*
				set -- $new_parents
				new_parent=$1
				shift
				new_parents=$*
				printf '%s\t%s\n' "$old_parent" "$new_parent" \
					>>"$pending" ||
					die "could not map a merge parent"
			done
		done <"$round"
	done

	if test -f "$state/pinned-merge-root"
	then
		prepare_pinned_merge_overlay "$state" "$root" "$base"
		test -f "$state/pinned-merge-disjoint-base" ||
			die "pinned merge graph overlaps its moved base"
		LC_ALL=C sort -u "$source" \
				>"$state/verified-tree-commits" ||
			die "could not sort verified merge commits"
		write_pinned_merge_overlay_trees "$root" "$base" \
				"$state/verified-tree-commits" \
				"$state/verified-expected-trees"
		exec 3<"$state/verified-expected-trees"
		while IFS= read -r old
		do
			IFS= read -r expected_tree <&3 ||
				die "could not read the expected replayed tree for $old"
			new=$(awk -F '\t' -v oid="$old" \
				'$1 == oid { print $2; exit }' "$map")
			test -n "$new" ||
				die "merge rewrite has no tree mapping for $old"
			actual_tree=$(git rev-parse "$new^{tree}") ||
				die "could not inspect replayed tree $new"
			test "$actual_tree" = "$expected_tree" ||
				die "pinned merge replay changes its reviewed tree outside the moved base"
		done <"$state/verified-tree-commits"
		exec 3<&-
	fi

	LC_ALL=C sort "$source" >"$source.sorted" ||
		die "could not sort the original merge graph"
	LC_ALL=C sort "$rewritten" >"$rewritten.sorted" ||
		die "could not sort the rewritten merge graph"
	awk -F '\t' 'NR == FNR { expected[$1]=1; next }
		$1 in expected { print $1 }' "$source" "$map" |
		LC_ALL=C sort >"$source.mapped" ||
		die "could not enumerate mapped original commits"
	awk -F '\t' 'NR == FNR { expected[$1]=1; next }
		$2 in expected { print $2 }' "$rewritten" "$map" |
		LC_ALL=C sort >"$rewritten.mapped" ||
		die "could not enumerate mapped rewritten commits"
	cmp -s "$source.sorted" "$source.mapped" &&
		cmp -s "$rewritten.sorted" "$rewritten.mapped" ||
		die "merge rewrite adds or removes topic commits"
)

write_failure () {
	path=$1
	state=$2
	worktree=$3
	test -n "$path" || return 0

	controller_oid=$(state_value "$state" controller-oid)
	remote=$(state_value "$state" remote)
	base_name=$(state_value "$state" base-name)
	codex_name=$(state_value "$state" codex-name)
	failed_owner=$(state_value "$state" failed-owner)
	failed_commit=$(state_value "$state" failed-commit)
	inputs_oid=$(input_oid "$state/inputs")
	require_automation=$(state_value "$state" require-automation)

	{
		say "## No refs were updated"
		say
		say "Rebasing \`$failed_owner\` stopped while applying \`$failed_commit\`."
		say "The controller did not push any topic branch or \`codex\`."
		say
		say "From a clean clone, reproduce the exact pinned rebase with:"
		say
		say '```sh'
		printf 'git fetch %s +refs/heads/\\*:refs/remotes/%s/\\*\n' \
			"$(shell_quote "$remote")" "$remote"
		printf 'git worktree add --detach Meta %s\n' \
			"$(shell_quote "$controller_oid")"
		printf 'Meta/codex resolve \\\n'
		printf '  --remote %s --base %s --codex %s \\\n' \
			"$(shell_quote "$remote")" \
			"$(shell_quote "$base_name")" \
			"$(shell_quote "$codex_name")"
		if test -n "$require_automation"
		then
			printf '  --require-automation \\\n'
		fi
		printf '  --inputs-oid %s\n' "$(shell_quote "$inputs_oid")"
		say '```'
		say
		say "The helper creates a disposable worktree and stops at this rebase."
		say "Inside that worktree:"
		say
		say '```sh'
		say 'git status'
		say 'git rebase --show-current-patch'
		say '# Edit the conflicted files.'
		say 'git add <files>'
		say 'git diff --cached --check'
		say '# Run the exact Meta/codex continue command printed by resolve.'
		say '```'
		say
		say "Repeat edit/add/\`Meta/codex continue\` if another conflict stops."
		say "The helper records the canonical Codex bot as committer, finishes"
		say "the remaining graph, and prints one exact-lease atomic topic push."
		say "That final command is a \`git push --force-with-lease=... --atomic\`"
		say "transaction covering every rewritten topic ref."
		say "Do not force-push only \`$failed_owner\`; that would sever its"
		say "ancestry relationship with downstream topics."
		if test -n "$(git -C "$worktree" -c core.fsmonitor=false \
			diff --name-only --diff-filter=U)"
		then
			say
			say "Conflicted paths:"
			git -C "$worktree" -c core.fsmonitor=false \
				diff --name-only --diff-filter=U |
				sed 's/^/- `/' | sed 's/$/`/'
		fi
	} >"$path"
}

write_unstable_failure () {
	path=$1
	state=$2
	worktree=$3
	test -n "$path" || return 0

	failed_owner=$(state_value "$state" failed-owner)
	failed_commit=$(state_value "$state" failed-commit)
	{
		say "## No refs were updated"
		say
		say "Rebasing unstable topic \`$failed_owner\` stopped while applying \`$failed_commit\`."
		say "Neither \`codex\`, \`codex-unstable\`, \`meta\`, nor a topic branch was updated."
		say
		say "Resolve this experimental conflict manually: restack the affected"
		say "unstable topic and its descendants onto their current prerequisite,"
		say "publish the coherent topic graph in one exact-lease atomic push,"
		say "and run \`Meta/rebuild\` again."
		say "The production-only \`resolve\`/\`continue\` recovery commands do not"
		say "reconstruct this nested unstable integration lane."
		if test -n "$(git -C "$worktree" -c core.fsmonitor=false \
			diff --name-only --diff-filter=U)"
		then
			say
			say "Conflicted paths:"
			git -C "$worktree" -c core.fsmonitor=false \
				diff --name-only --diff-filter=U |
				sed 's/^/- `/' | sed 's/$/`/'
		fi
	} >"$path"
}

write_merge_graph_failure () {
	path=$1
	state=$2
	worktree=$3
	test -n "$path" || return 0

	failed_owner=$(state_value "$state" failed-owner)
	failed_commit=$(state_value "$state" failed-commit)
	output_name=$(state_value "$state" codex-name)
	{
		say "## No refs were updated"
		say
		say "Rebasing merge-shaped topic \`$failed_owner\` stopped while applying \`$failed_commit\`."
		say "Neither \`$output_name\`, \`meta\`, nor a topic branch was updated."
		say
		say "Resolve this merge-graph conflict manually: restack the affected"
		say "topic and its descendants onto their current prerequisites,"
		say "publish the coherent topic graph in one exact-lease atomic push,"
		say "and run \`Meta/rebuild\` again."
		say "The linear \`resolve\`/\`continue\` recovery commands do not"
		say "reconstruct a merge-shaped topic graph."
		if test -n "$(git -C "$worktree" -c core.fsmonitor=false \
			diff --name-only --diff-filter=U)"
		then
			say
			say "Conflicted paths:"
			git -C "$worktree" -c core.fsmonitor=false \
				diff --name-only --diff-filter=U |
				sed 's/^/- `/' | sed 's/$/`/'
		fi
	} >"$path"
}

write_integration_failure () {
	path=$1
	state=$2
	worktree=$3
	test -n "$path" || return 0

	failed_name=$(state_value "$state" integration-failed-name)
	failed_oid=$(state_value "$state" integration-failed-oid)
	inputs_oid=$(input_oid "$state/inputs")
	{
		say "## No refs were updated"
		say
		say "The rewritten topic \`$failed_name\` at \`$failed_oid\`"
		say "conflicts with the topics already merged into the candidate."
		say "Input snapshot: \`$inputs_oid\`."
		say
		say "This is an integration conflict, not a stopped rebase. Do not merge"
		say "\`codex\` into the topic and do not choose an arbitrary merge order."
		say "Make the real dependency explicit by rebasing the conflicting topic"
		say "and its descendants onto the prerequisite topic, then push that"
		say "coherent topic graph and run \`Refresh codex\` again."
		if test -s "$state/integration-merged"
		then
			say
			say "Topics already merged, in order:"
			sed 's/^/- `/' "$state/integration-merged" | sed 's/$/`/'
		fi
		if test -n "$(git -C "$worktree" -c core.fsmonitor=false \
			diff --name-only --diff-filter=U)"
		then
			say
			say "Conflicted paths:"
			git -C "$worktree" -c core.fsmonitor=false \
				diff --name-only --diff-filter=U |
				sed 's/^/- `/' | sed 's/$/`/'
		fi
	} >"$path"
}

merge_topic () {
	worktree=$1
	name=$2
	oid=$3
	output_name=${4:-codex}
	before=$(git -C "$worktree" rev-parse HEAD) ||
		die "could not resolve the candidate before integrating '$name'"
	message=$(printf 'Merge %s into %s\n\nIntegrate the current %s topic into the internally distributed %s branch.\n\nCodex-Integration: %s@%s' \
		"$name" "$output_name" "$name" "$output_name" "$name" "$oid")

	if git -C "$worktree" merge-base --is-ancestor "$oid" "$before"
	then
		if test "$before" = "$oid"
		then
			tree=$(git -C "$worktree" rev-parse "$before^{tree}") ||
				die "could not resolve the integration base tree"
			anchor_message=$(printf 'Begin %s integration\n\nCreate a distinct first parent for explicit topic integration commits.\n' \
				"$output_name")
			anchor=$(printf '%s' "$anchor_message" | \
				GIT_AUTHOR_NAME=$bot_name GIT_AUTHOR_EMAIL=$bot_email \
				GIT_COMMITTER_NAME=$bot_name \
				GIT_COMMITTER_EMAIL=$bot_email \
				git -C "$worktree" -c commit.gpgSign=false \
				commit-tree "$tree" -p "$before") ||
				die "could not create the codex integration base"
			git -C "$worktree" reset --hard "$anchor" >/dev/null ||
				die "could not check out the codex integration base"
			before=$anchor
		fi
		tree=$(git -C "$worktree" rev-parse "$before^{tree}") ||
			die "could not resolve the candidate tree for '$name'"
		after=$(printf '%s\n' "$message" | \
			GIT_AUTHOR_NAME=$bot_name GIT_AUTHOR_EMAIL=$bot_email \
			GIT_COMMITTER_NAME=$bot_name \
			GIT_COMMITTER_EMAIL=$bot_email \
			git -C "$worktree" -c commit.gpgSign=false \
			commit-tree "$tree" -p "$before" -p "$oid") ||
			die "could not create the explicit integration for '$name'"
		git -C "$worktree" reset --hard "$after" >/dev/null ||
			die "could not check out the integration for '$name'"
	elif GIT_AUTHOR_NAME=$bot_name GIT_AUTHOR_EMAIL=$bot_email \
		GIT_COMMITTER_NAME=$bot_name GIT_COMMITTER_EMAIL=$bot_email \
		git -C "$worktree" \
		-c core.hooksPath=/dev/null \
		-c core.fsmonitor=false \
		-c commit.gpgSign=false \
		-c rerere.enabled=true \
		-c rerere.autoupdate=true \
		merge --no-ff --no-log --no-edit --no-gpg-sign \
		-m "$message" "$oid" >&2
	then
		:
	else
		git -C "$worktree" rev-parse --verify -q MERGE_HEAD >/dev/null &&
			test -z "$(git -C "$worktree" -c core.fsmonitor=false ls-files -u)" ||
			return 1
		git -C "$worktree" -c core.fsmonitor=false diff --cached --check ||
			return 1
		GIT_AUTHOR_NAME=$bot_name GIT_AUTHOR_EMAIL=$bot_email \
			GIT_COMMITTER_NAME=$bot_name GIT_COMMITTER_EMAIL=$bot_email \
			git -C "$worktree" \
			-c core.hooksPath=/dev/null \
			-c core.fsmonitor=false \
			-c commit.gpgSign=false \
			commit --no-edit --no-gpg-sign >&2 || return 1
	fi

	after=$(git -C "$worktree" rev-parse HEAD) ||
		die "could not resolve the integration commit for '$name'"
	set -- $(git -C "$worktree" show -s --format=%P "$after")
	test $# = 2 && test "$1" = "$before" && test "$2" = "$oid" ||
		die "integration for '$name' is not an explicit two-parent merge"
	marker=$(git -C "$worktree" show -s \
		--format='%(trailers:key=Codex-Integration,valueonly)' "$after") ||
		die "could not inspect the integration marker for '$name'"
	test "$marker" = "$name@$oid" ||
		die "integration for '$name' has the wrong marker"
}

integration_name_recorded () (
	file=$1
	name=$2
	awk -F '\t' -v name="$name" '$1 == name { found=1 }
		END { exit !found }' "$file"
)

write_integration_topics () {
	state=$1
	base_name=$(state_value "$state" base-name)
	plan=$state/integration-plan
	ready=$state/integration-ready
	merged=$state/integration-topics
	if test -f "$state/pinned-plan-mode"
	then
		: >"$merged" || die "could not prepare the topic integration order"
		while IFS= read -r name
		do
			plan_row=$(awk -F '\t' -v name="$name" \
				'$1 == name { print; exit }' "$state/plan")
			test -n "$plan_row" ||
				die "pinned plan order names missing topic '$name'"
			prerequisites=$(planned_prerequisites "$state" "$name")
			for dependency in $prerequisites
			do
				test "$dependency" = "$base_name" && continue
				integration_name_recorded "$merged" "$dependency" ||
					die "pinned plan orders '$name' before prerequisite '$dependency'"
			done
			oid=$(result_lookup "$state/results" "$name")
			test -n "$oid" || die "topic '$name' has no generated tip"
			printf '%s\t%s\n' "$name" "$oid" >>"$merged" ||
				die "could not retain pinned integration order"
		done <"$state/desired-order"
		return
	fi
	LC_ALL=C sort -t "$tab" -k1,1 "$state/plan" >"$plan" ||
		die "could not sort topics for integration"
	: >"$merged" || die "could not prepare the topic integration order"
	total=$(wc -l <"$plan" | tr -d ' ')
	while test "$(wc -l <"$merged" | tr -d ' ')" -lt "$total"
	do
		: >"$ready"
		while IFS="$tab" read -r name old prerequisite old_base prerequisite_tip
		do
			integration_name_recorded "$merged" "$name" && continue
			if test -f "$state/prerequisites"
			then
				prerequisites=$(planned_prerequisites "$state" "$name")
			else
				prerequisites=$prerequisite
			fi
			waiting=
			for dependency in $prerequisites
			do
				if test "$dependency" != "$base_name" &&
					! integration_name_recorded "$merged" "$dependency"
				then
					waiting=t
					break
				fi
			done
			test -z "$waiting" || continue
			oid=$(result_lookup "$state/results" "$name")
			test -n "$oid" || die "topic '$name' has no rewritten tip"
			printf '%s\t%s\n' "$name" "$oid" >>"$ready" ||
				die "could not record ready integration topic '$name'"
		done <"$plan"
		test -s "$ready" || die "topic integrations contain a dependency cycle"
		LC_ALL=C sort -t "$tab" -k1,1 -o "$ready" "$ready" ||
			die "could not sort ready integration topics"
		sed -n '1p' "$ready" >>"$merged" ||
			die "could not extend the topic integration order"
	done
}

codex_has_expected_integrations () (
	state=$1
	head_oid=$2
	base_oid=$(state_value "$state" base-oid)
	output_name=$(state_value "$state" codex-name)
	expected=$state/expected-integrations
	actual=$state/actual-integrations
	: >"$expected"
	while IFS="$tab" read -r name oid
	do
		printf '%s@%s\t%s\tMerge %s into %s\t%s\t%s\t%s\t%s\n' \
			"$name" "$oid" "$oid" "$name" "$output_name" \
			"$bot_name" "$bot_email" "$bot_name" "$bot_email" \
			>>"$expected" || return 1
	done <"$state/integration-topics"
	: >"$actual"
	git rev-list --first-parent --reverse "$base_oid..$head_oid" |
	while read -r commit
	do
		marker=$(git show -s \
			--format='%(trailers:key=Codex-Integration,valueonly)' \
			"$commit") || exit 1
		test -n "$marker" || continue
		set -- $(git show -s --format=%P "$commit")
		test $# = 2 || exit 1
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$marker" "$2" "$(git show -s --format=%s "$commit")" \
			"$(git show -s --format=%an "$commit")" \
			"$(git show -s --format=%ae "$commit")" \
			"$(git show -s --format=%cn "$commit")" \
			"$(git show -s --format=%ce "$commit")" \
			>>"$actual" || exit 1
	done || return 1
	cmp -s "$expected" "$actual"
)

assemble_candidate () {
	worktree=$1
	state=$2
	base_oid=$(state_value "$state" base-oid)
	output_name=$(state_value "$state" codex-name)
	rm -f "$state/integration-failed-name" \
		"$state/integration-failed-oid" ||
		die "could not clear old integration state"
	: >"$state/integration-merged" ||
		die "could not prepare integration progress"

	write_integration_topics "$state"

	git -C "$worktree" -c core.fsmonitor=false \
		-c advice.detachedHead=false switch --detach "$base_oid" >/dev/null ||
		die "could not check out the base while assembling $output_name"
	while IFS="$tab" read -r name oid
	do
		if ! merge_topic "$worktree" "$name" "$oid" "$output_name"
		then
			printf '%s\n' "$name" >"$state/integration-failed-name" ||
				die "could not record the conflicting integration topic"
			printf '%s\n' "$oid" >"$state/integration-failed-oid" ||
				die "could not record the conflicting integration commit"
			return 1
		fi
		printf '%s\n' "$name" >>"$state/integration-merged" ||
			die "could not record integration progress"
	done <"$state/integration-topics"

	if test -f "$state/pinned-plan-mode"
	then
		while IFS="$tab" read -r name source_tip
		do
			oid=$(result_lookup "$state/results" "$name")
			test -n "$oid" ||
				die "pinned topic '$name' has no generated tip"
			git -C "$worktree" merge-base --is-ancestor "$oid" HEAD ||
				die "candidate does not contain generated topic '$name'"
		done <"$state/topics"
	else
		while IFS="$tab" read -r ref old oid
		do
			git -C "$worktree" merge-base --is-ancestor "$oid" HEAD ||
				die "candidate does not contain '$ref'"
		done <"$state/topic-updates"
	fi
	candidate=$(git -C "$worktree" rev-parse HEAD) ||
		die "could not resolve the codex candidate"
	codex_has_expected_integrations "$state" "$candidate" ||
		die "candidate does not contain one canonical integration merge per topic"
	require_automation=$(state_value "$state" require-automation)
	if ! test -f "$state/initializing" &&
		test "$output_name" != codex-unstable
	then
		verify_control_paths "$state/inputs" "$state/topic-updates" \
			"$candidate" "$state" "$require_automation"
	fi

	printf '%s\n' "$candidate"
}

create_bundle () {
	bundle=$1
	state=$2
	candidate=$3
	base_oid=$(state_value "$state" base-oid)
	controller_oid=$(state_value "$state" controller-oid)
	meta_oid=$(state_value "$state" meta-oid)

	test ! -e "$bundle" || die "bundle path '$bundle' already exists"
	git update-ref refs/codex-output/candidate "$candidate" ||
		die "could not retain the bundle candidate"
	set -- git bundle create "$bundle" refs/codex-output/candidate
	if test -f "$state/unstable-output-oid" &&
		! is_null_oid "$(state_value "$state" unstable-output-oid)"
	then
		git update-ref refs/codex-output/unstable \
			"$(state_value "$state" unstable-output-oid)" ||
			die "could not retain the unstable bundle candidate"
		set -- "$@" refs/codex-output/unstable
	fi
	if test "$meta_oid" != "$controller_oid"
	then
		git update-ref refs/codex-output/meta "$meta_oid" ||
			die "could not retain the next meta state"
		set -- "$@" refs/codex-output/meta
		# Test and migration repositories may have a non-orphan meta whose
		# old history contains the candidate. Excluding that history would
		# also suppress the candidate head from the bundle.
		if ! git merge-base --is-ancestor "$candidate" "$controller_oid"
		then
			set -- "$@" "^$controller_oid"
		fi
	fi
	if test "$candidate" = "$base_oid"
	then
		parents=$(git show -s --format=%P "$candidate") ||
			die "could not inspect the bundle candidate parents"
		for parent in $parents
		do
			set -- "$@" "^$parent"
		done
	else
		set -- "$@" "^$base_oid"
	fi
	while IFS="$tab" read -r name old
	do
		test "$old" = "$candidate" || set -- "$@" "^$old"
	done <"$state/topics"
	if ! "$@"
	then
		git update-ref -d refs/codex-output/candidate || :
		git update-ref -d refs/codex-output/unstable || :
		git update-ref -d refs/codex-output/meta || :
		die "could not create candidate bundle"
	fi
	git update-ref -d refs/codex-output/candidate ||
		die "could not remove the temporary bundle ref"
	git update-ref -d refs/codex-output/unstable || :
	git update-ref -d refs/codex-output/meta || :
}

validate_lane_isolation () (
	state=$1
	stable_topics=$2
	unstable_topics=$3
	codex_oid=$4
	unstable_source_bases=${5:-}
	published_unstable_state=${6:-$state}

	if test -n "$unstable_source_bases"
	then
		# Pinned source refs remain immutable when their generated lane
		# moves.  A raw stable source therefore need not be an ancestor of
		# the current generated codex tip.  The reviewed source-base of
		# each active unstable topic is the ownership boundary: stable
		# sources may share history at or below it, but not private
		# unstable commits above it.
		while IFS="$tab" read -r unstable_name unstable_tip unstable_prerequisites
		do
			unstable_source_base=$(plan_source_base \
				"$unstable_source_bases" "$unstable_name")
			test -n "$unstable_source_base" ||
				die "pinned unstable topic '$unstable_name' has no reviewed source boundary"
			while IFS="$tab" read -r stable_name stable_tip stable_prerequisites
			do
				git merge-base --all "$unstable_tip" "$stable_tip" \
					>"$state/cross-lane-bases" ||
					die "could not compare stable topic '$stable_name' with unstable topic '$unstable_name'"
				while read -r shared
				do
					git merge-base --is-ancestor "$shared" \
						"$unstable_source_base" ||
						die "stable topic '$stable_name' contains private commits from unstable topic '$unstable_name'"
				done <"$state/cross-lane-bases"
			done <"$stable_topics"
		done <"$unstable_topics"
		# The raw pins above do not cover a stable source that was cut
		# directly from a previously generated unstable output.  Keep the
		# old generated-output ownership check too, but bound it by the
		# published unstable base rather than today's regenerated codex.
		if test -f "$published_unstable_state/published-unstable-base-oid"
		then
			published_unstable_base=$(state_value "$published_unstable_state" \
				published-unstable-base-oid)
			while IFS="$tab" read -r unstable_name unstable_tip prerequisites
			do
				while IFS="$tab" read -r stable_name stable_tip stable_prerequisites
				do
					git merge-base --all "$unstable_tip" \
						"$stable_tip" >"$state/cross-lane-bases" ||
						die "could not compare stable topic '$stable_name' with unstable topic '$unstable_name'"
					while read -r shared
					do
						git merge-base --is-ancestor "$shared" \
							"$published_unstable_base" ||
							die "stable topic '$stable_name' contains private commits from unstable topic '$unstable_name'"
					done <"$state/cross-lane-bases"
				done <"$stable_topics"
			done <"$published_unstable_state/published-unstable-topics"
		fi
		return
	fi

	cp "$unstable_topics" "$state/cross-lane-unstable-tips" ||
		die "could not prepare current unstable ownership checks"
	awk -F '\t' '{ printf "%s\t%s\n", $1, $2 }' \
		"$state/published-unstable-topics" \
		>>"$state/cross-lane-unstable-tips" ||
		die "could not prepare published unstable ownership checks"
	while IFS="$tab" read -r unstable_name unstable_tip
	do
		while IFS="$tab" read -r stable_name stable_tip
		do
			git merge-base --all "$unstable_tip" "$stable_tip" \
				>"$state/cross-lane-bases" ||
				die "could not compare stable topic '$stable_name' with unstable topic '$unstable_name'"
			while read -r shared
			do
				git merge-base --is-ancestor "$shared" "$codex_oid" ||
					die "stable topic '$stable_name' contains private commits from unstable topic '$unstable_name'"
			done <"$state/cross-lane-bases"
		done <"$stable_topics"
	done <"$state/cross-lane-unstable-tips"
)

initialize_rewrite () {
	remote=$1
	base_name=$2
	codex_name=$3
	rerere_name=$4
	worktree=$5
	state=$6
	inputs=$7
	topics=$8
	require_automation=$9

	mkdir -p "$state"
	cp "$inputs" "$state/inputs"
	cp "$topics" "$state/topics"
	if test -f "$topics.unstable"
	then
		cp "$topics.unstable" "$state/unstable-topics" ||
			die "could not retain unstable topic inputs"
	else
		: >"$state/unstable-topics"
	fi
	controller_oid=$(awk -F '\t' '$1 == "controller" { print $3 }' "$inputs")
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	base_ref=$(awk -F '\t' '$1 == "base" { print $2 }' "$inputs")
	base_name=${base_ref#refs/heads/}
	codex_oid=$(awk -F '\t' '$1 == "codex" { print $3 }' "$inputs")
	unstable_oid=$(awk -F '\t' '$1 == "unstable" { print $3 }' "$inputs")
	lane_mode=$(awk -F '\t' '$1 == "lane-mode" { print $3 }' "$inputs")
	printf '%s\n' "$controller_oid" >"$state/controller-oid"
	printf '%s\n' "$remote" >"$state/remote"
	printf '%s\n' "$base_name" >"$state/base-name"
	printf '%s\n' "$base_oid" >"$state/base-oid"
	printf '%s\n' "$codex_name" >"$state/codex-name"
	printf '%s\n' "$codex_oid" >"$state/codex-oid"
	test -z "$unstable_oid" ||
		printf '%s\n' "$unstable_oid" >"$state/unstable-oid"
	printf '%s\n' "$lane_mode" >"$state/unstable-mode"
	printf '%s\n' "$rerere_name" >"$state/rerere-name"
	printf '%s\n' "$require_automation" >"$state/require-automation"
	printf '%s\n' "$script_path" >"$state/helper"

	read_meta_config "$controller_oid" "$base_name" "$codex_name" "$state"
	if awk -F '\t' '$1 == "plan" { found=1 } END { exit !found }' \
		"$inputs"
	then
		plan_state=$state/desired-plan
		read_lane_plan "$controller_oid" codex "$base_name" "$base_oid" \
			- "$plan_state/topics" "$plan_state"
		cmp -s "$state/topics" "$plan_state/topics" ||
			die "input snapshot does not match the pinned production plan"
			cp "$plan_state/desired-prerequisites" \
				"$state/desired-prerequisites" ||
				die "could not retain pinned production prerequisites"
			cp "$plan_state/desired-source-bases" \
				"$state/desired-source-bases" ||
				die "could not retain pinned production source boundaries"
		cp "$plan_state/desired-order" "$state/desired-order" ||
			die "could not retain pinned production order"
		cp "$plan_state/plan-blob" "$state/plan-blob" ||
			die "could not retain pinned production plan"
		: >"$state/pinned-plan-mode"
		printf '%s\n' "$base_oid" >"$state/source-base-oid"
		published_codex_oid=$(state_value "$state" published-codex-oid)
		test "$codex_oid" = "$published_codex_oid" ||
			die "generated codex moved outside its published pinned-plan output"
		unstable_plan_state=
		if test -f "$state/published-unstable-oid"
		then
			unstable_plan_state=$state/desired-unstable-plan
			read_lane_plan "$controller_oid" codex-unstable codex \
				"$codex_oid" - "$unstable_plan_state/topics" \
				"$unstable_plan_state"
			cmp -s "$state/unstable-topics" \
				"$unstable_plan_state/topics" ||
				die "input snapshot does not match the pinned unstable plan"
		fi
		validate_lane_isolation "$state" "$state/topics" \
			"$state/unstable-topics" "$codex_oid" \
			"${unstable_plan_state:+$unstable_plan_state/desired-source-bases}"
		prepare_pinned_plan "$base_name" "$base_oid" "$state/topics" \
			"$state"
		if test -n "$rerere_name" && test "$codex_oid" != "$base_oid" &&
			git merge-base --is-ancestor "$base_oid" "$codex_oid"
		then
			train_rerere "$worktree" "$base_oid" "$codex_oid"
		fi
		return
	fi
	if test -s "$state/published-topics" && ! test -s "$state/topics"
	then
		die "all previously published production topics disappeared"
	fi
	validate_lane_isolation "$state" "$state/topics" \
		"$state/unstable-topics" "$codex_oid"
	published_codex_oid=$(state_value "$state" published-codex-oid)
	validate_live_codex_delta "$published_codex_oid" "$codex_oid" \
		"$state/topics" "$state"
	prepare_stateful_plan "$base_name" "$base_oid" "$state/topics" \
		"$state" stable
	if test -n "$rerere_name" && test "$codex_oid" != "$base_oid"
	then
		train_rerere "$worktree" "$base_oid" "$codex_oid"
	fi
}

create_unstable_sentinel () (
	base=$1
	tree=$(git rev-parse "$base^{tree}") ||
		die "could not resolve the codex-unstable sentinel tree"
	printf 'Initialize codex-unstable\n' |
		GIT_AUTHOR_NAME=$bot_name GIT_AUTHOR_EMAIL=$bot_email \
		GIT_COMMITTER_NAME=$bot_name GIT_COMMITTER_EMAIL=$bot_email \
		git -c commit.gpgSign=false commit-tree "$tree" -p "$base" ||
		die "could not create the empty codex-unstable sentinel"
)

prepare_unstable_candidate () (
	worktree=$1
	state=$2
	root_state=$state
	stable_candidate=$3
	failure_file=$4
	topics=$state/unstable-topics
	unstable_old=$(awk -F '\t' '$1 == "unstable" { print $3 }' \
		"$state/inputs")
	mode=$(state_value "$state" unstable-mode)
	version=$(state_value "$state" config-version)

	if ! test -s "$topics"
	then
		if test "$mode" = disable
		then
			test "$version" = 2 ||
				die "codex-unstable is not enabled"
			test "$unstable_old" = \
				"$(state_value "$state" published-unstable-oid)" ||
				die "cannot disable codex-unstable after its published output changed"
			printf '%s\n' "$(null_oid)" >"$state/unstable-output-oid" ||
				die "could not disable the empty codex-unstable output"
			return 0
		fi
			if test "$version" = 1 && test "$mode" != enable
			then
				return 0
			fi
			if test "$version" = 3 &&
				! test -f "$state/published-unstable-oid"
			then
				return 0
			fi
			test -n "$unstable_old" ||
			die "the enabled codex-unstable output was not snapshotted"
		mkdir -p "$state/unstable" ||
			die "could not prepare empty codex-unstable state"
		: >"$state/unstable/topics"
		: >"$state/unstable/topic-updates"
		if ! is_null_oid "$unstable_old" &&
			test "$(git show -s --format=%P "$unstable_old")" = \
			"$stable_candidate" &&
			test "$(git rev-parse "$unstable_old^{tree}")" = \
			"$(git rev-parse "$stable_candidate^{tree}")"
		then
			unstable_candidate=$unstable_old
		else
			unstable_candidate=$(create_unstable_sentinel \
				"$stable_candidate")
		fi
		printf '%s\n' "$unstable_candidate" \
			>"$state/unstable-output-oid" ||
			die "could not retain the empty codex-unstable sentinel"
		return 0
	fi
	test "$mode" != disable ||
		die "cannot disable codex-unstable while enrolled topics remain"

	test -n "$unstable_old" ||
		die "active unstable topics were not included in the input snapshot"
	if test "$version" = 1 && ! is_null_oid "$unstable_old"
	then
		die "$meta_config_path does not describe the existing codex-unstable output"
	fi
	if test "$version" = 2 && is_null_oid "$unstable_old"
	then
		die "$meta_config_path records codex-unstable, but its output disappeared"
	fi

	unstable_state=$state/unstable
	mkdir -p "$unstable_state" ||
		die "could not prepare unstable reconstruction state"
	cp "$state/inputs" "$unstable_state/inputs" ||
		die "could not pin unstable inputs"
	cp "$topics" "$unstable_state/topics" ||
		die "could not pin unstable topics"
	cp "$state/published-unstable-topics" \
		"$unstable_state/published-topics" ||
		die "could not retain published unstable topology"
	printf '%s\n' "$(state_value "$state" controller-oid)" \
		>"$unstable_state/controller-oid"
	printf '%s\n' "$(state_value "$state" remote)" \
		>"$unstable_state/remote"
	printf '%s\n' codex >"$unstable_state/base-name"
	printf '%s\n' "$stable_candidate" >"$unstable_state/base-oid"
	printf '%s\n' codex-unstable >"$unstable_state/codex-name"
	printf '%s\n' "$unstable_old" >"$unstable_state/codex-oid"
	printf '%s\n' "$(state_value "$state" require-automation)" \
		>"$unstable_state/require-automation"
	printf '%s\n' "$script_path" >"$unstable_state/helper"
	if test -f "$state/pinned-plan-mode"
	then
		plan_state=$state/desired-unstable-plan
			cp "$plan_state/desired-prerequisites" \
				"$unstable_state/desired-prerequisites" ||
				die "could not retain pinned unstable prerequisites"
			cp "$plan_state/desired-source-bases" \
				"$unstable_state/desired-source-bases" ||
				die "could not retain pinned unstable source boundaries"
		cp "$plan_state/desired-order" "$unstable_state/desired-order" ||
			die "could not retain pinned unstable order"
		cp "$plan_state/plan-blob" "$unstable_state/plan-blob" ||
			die "could not retain pinned unstable plan"
		cp "$state/published-unstable-source-topics" \
			"$unstable_state/published-source-topics" ||
			die "could not retain published unstable source boundaries"
		: >"$unstable_state/pinned-plan-mode"
		# Raw unstable sources are reviewed against the published codex
		# input.  The generated lane is reconstructed on the new stable
		# candidate below.
		printf '%s\n' "$(state_value "$state" codex-oid)" \
			>"$unstable_state/source-base-oid"
	fi
	if test -f "$state/pinned-plan-mode"
	then
		published_base=$(state_value "$state" published-unstable-base-oid)
		published_output=$(state_value "$state" published-unstable-oid)
	elif test "$version" = 2
	then
		published_base=$(state_value "$state" published-unstable-base-oid)
		published_output=$(state_value "$state" published-unstable-oid)
		validate_live_codex_delta "$published_output" "$unstable_old" \
			"$unstable_state/topics" "$unstable_state"
	else
		published_base=$(state_value "$state" codex-oid)
		published_output=$(null_oid)
	fi
	printf '%s\n' "$published_base" \
		>"$unstable_state/published-base-oid"
	printf '%s\n' "$published_output" \
		>"$unstable_state/published-codex-oid"
	if test -f "$unstable_state/pinned-plan-mode"
	then
		prepare_pinned_plan codex "$stable_candidate" \
			"$unstable_state/topics" "$unstable_state"
	else
		prepare_stateful_plan codex "$stable_candidate" \
			"$unstable_state/topics" "$unstable_state" unstable
	fi
	if ! process_planned_graph "$worktree" "$unstable_state"
	then
		if test -f "$unstable_state/merge-graph"
		then
			write_merge_graph_failure "$failure_file" \
				"$unstable_state" "$worktree"
		else
			write_unstable_failure "$failure_file" \
				"$unstable_state" "$worktree"
		fi
		die "conflict while rebasing unstable topic '$(state_value "$unstable_state" failed-owner)'; no refs were updated"
	fi
	if ! unstable_candidate=$(assemble_candidate "$worktree" \
		"$unstable_state")
	then
		if test -f "$unstable_state/integration-failed-name"
		then
			write_integration_failure "$failure_file" \
				"$unstable_state" "$worktree"
			die "codex-unstable integration conflicts while merging '$(state_value "$unstable_state" integration-failed-name)'; no refs were updated"
		fi
		die "codex-unstable candidate validation failed; no refs were updated"
	fi
	git merge-base --is-ancestor "$stable_candidate" \
		"$unstable_candidate" ||
		die "codex-unstable candidate does not contain its exact codex base"
	test "$stable_candidate" != "$unstable_candidate" ||
		die "codex-unstable candidate is not strictly ahead of codex"
	verify_unstable_control_paths "$stable_candidate" \
		"$unstable_candidate" "$unstable_state"
	if ! is_null_oid "$unstable_old" &&
		git merge-base --is-ancestor "$stable_candidate" "$unstable_old" &&
		test "$(git rev-parse "$unstable_candidate^{tree}")" = \
			"$(git rev-parse "$unstable_old^{tree}")" &&
		codex_has_expected_integrations "$unstable_state" "$unstable_old"
	then
		unstable_candidate=$unstable_old
	fi
	printf '%s\n' "$unstable_candidate" \
		>"$root_state/unstable-output-oid" ||
		die "could not retain the unstable output candidate"
)

initialize_config () {
	remote=origin
	base_name=master
	codex_name=codex
	initialize_output=
	require_automation=
	while test $# -gt 0
	do
		case "$1" in
		--remote) require_arg "$@"; remote=$2; shift 2 ;;
		--base) require_arg "$@"; base_name=$2; shift 2 ;;
		--codex) require_arg "$@"; codex_name=$2; shift 2 ;;
		--output) require_arg "$@"; initialize_output=$2; shift 2 ;;
		--require-automation) require_automation=t; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown initialize option '$1'" ;;
		esac
	done

	make_tmp_dir
	require_full_repository
	inputs=$tmp_dir/inputs
	topics=$tmp_dir/topics
	fetch_heads "$remote"
	snapshot_inputs "$remote" "$base_name" "$codex_name" "$inputs" \
		"$topics"
	controller_oid=$(awk -F '\t' '$1 == "controller" { print $3 }' "$inputs")
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	codex_oid=$(awk -F '\t' '$1 == "codex" { print $3 }' "$inputs")
	if git cat-file -e "$controller_oid:$meta_config_path" 2>/dev/null
	then
		die "meta already contains $meta_config_path; run refresh instead"
	fi

	set -- git merge-base --all --octopus "$base_oid" "$codex_oid"
	while IFS="$tab" read -r name tip
	do
		set -- "$@" "$tip"
	done <"$topics"
	"$@" >"$tmp_dir/initial-bases" ||
		die "could not infer the common published base"
	test "$(wc -l <"$tmp_dir/initial-bases" | tr -d ' ')" = 1 ||
		die "master, codex, and the active topics do not have one unambiguous common base"
	published_base=$(sed -n '1p' "$tmp_dir/initial-bases")
	require_full_commit_oid "$published_base"
	git merge-base --is-ancestor "$published_base" "$codex_oid" ||
		die "the inferred published base is not in codex"
	while IFS="$tab" read -r name tip
	do
		git merge-base --is-ancestor "$tip" "$codex_oid" ||
			die "active topic '$name' is not contained by the known-good codex branch"
	done <"$topics"

	worktree=$tmp_dir/initialize-worktree
	temporary_worktree=$worktree
	git -c core.fsmonitor=false worktree add --detach "$worktree" \
		"$published_base" >/dev/null ||
		die "could not create the initialization worktree"
	state=$(state_path "$worktree")
	mkdir -p "$state"
	cp "$topics" "$state/topics"
	awk -F '\t' -v OFS='\t' -v base="$published_base" \
		'$1 == "base" { $3=base } { print }' "$inputs" >"$state/inputs"
	printf '%s\n' "$controller_oid" >"$state/controller-oid"
	printf '%s\n' "$remote" >"$state/remote"
	printf '%s\n' "$base_name" >"$state/base-name"
	printf '%s\n' "$published_base" >"$state/base-oid"
	printf '%s\n' "$codex_name" >"$state/codex-name"
	printf '%s\n' "$codex_oid" >"$state/codex-oid"
	printf '%s\n' "$require_automation" >"$state/require-automation"
	printf '%s\n' "$script_path" >"$state/helper"
	: >"$state/initializing"
	prepare_plan "$base_name" "$published_base" "$state/topics" \
		"$state" stable
	mv "$state/plan" "$state/unique-plan" ||
		die "could not retain the inferred initialization plan"
	if test -f "$state/prerequisites"
	then
		mv "$state/prerequisites" "$state/unique-prerequisites" ||
			die "could not retain inferred merge-graph prerequisites"
		: >"$state/prerequisites"
	fi
	: >"$state/plan"
	while IFS="$tab" read -r name tip
	do
		row=$(awk -F '\t' -v tip="$tip" '$2 == tip { print; exit }' \
			"$state/unique-plan")
		test -n "$row" || die "could not infer a prerequisite for '$name'"
		IFS="$tab" read -r representative ignored prerequisite old_base prerequisite_tip <<-EOF
		$row
		EOF
		printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$tip" \
			"$prerequisite" "$old_base" "$prerequisite_tip" \
			>>"$state/plan"
		if test -f "$state/unique-prerequisites"
		then
			prerequisites=$(published_prerequisites \
				"$state/unique-prerequisites" "$representative")
			test -n "$prerequisites" ||
				die "could not infer merge-graph prerequisites for '$name'"
			printf '%s\t%s\t%s\n' "$name" "$tip" "$prerequisites" \
				>>"$state/prerequisites" ||
				die "could not retain merge-graph prerequisites for '$name'"
		fi
	done <"$state/topics"
	: >"$state/results"
	: >"$state/map"
	while IFS="$tab" read -r name tip prerequisite old_base prerequisite_tip
	do
		prerequisites=$(planned_prerequisites "$state" "$name")
		for prerequisite in $prerequisites
		do
			if test "$prerequisite" = "$base_name"
			then
				parent_tip=$published_base
			else
				parent_tip=$(current_topic_tip "$state/topics" "$prerequisite")
				test -n "$parent_tip" ||
					die "topic '$name' has no active prerequisite '$prerequisite'"
			fi
			git merge-base --is-ancestor "$parent_tip" "$tip" ||
				die "topic '$name' is not based on '$prerequisite'"
		done
		result_record "$state/results" "$name" "$tip"
	done <"$state/plan"
	finish_updates "$state"
	if test -f "$state/merge-graph"
	then
		verify_merge_topology "$published_base" "$state"
	fi
	if test "$codex_oid" != "$published_base"
	then
		train_rerere "$worktree" "$published_base" "$codex_oid"
	fi
	if ! candidate=$(assemble_candidate "$worktree" "$state")
	then
		die "active topics cannot reconstruct the known-good codex branch"
	fi
	test "$(git rev-parse "$candidate^{tree}")" = \
		"$(git rev-parse "$codex_oid^{tree}")" ||
		die "active topics do not reconstruct the known-good codex tree; extract every shipped patch into a topic before initializing"
	if test -n "$require_automation"
	then
		verify_control_paths "$state/inputs" "$state/topic-updates" \
			"$candidate" "$state" "$require_automation"
	fi

	: >"$state/initial-topics"
	while IFS="$tab" read -r name tip prerequisite old_base prerequisite_tip
	do
		prerequisites=$(planned_prerequisites "$state" "$name")
		printf '%s\t%s\t%s\n' "$name" "$tip" "$prerequisites" \
			>>"$state/initial-topics"
	done <"$state/plan"
	LC_ALL=C sort -o "$state/initial-topics" "$state/initial-topics"
	write_meta_config "$base_name" "$published_base" "$codex_name" \
		"$codex_oid" "$state/initial-topics" "$state/initial-config"
	if test -z "$initialize_output"
	then
		meta_worktree=${CODEX_META_WORKTREE:-}
		test -n "$meta_worktree" ||
			die "initialize must be run as Meta/codex (or with --output)"
		test -z "$(git -C "$meta_worktree" -c core.fsmonitor=false status --porcelain)" ||
			die "Meta worktree must be clean before initialization"
		initialize_output=$meta_worktree/$meta_config_path
	fi
	case "$initialize_output" in
	/*) ;;
	*) initialize_output=$(pwd)/$initialize_output ;;
	esac
	test ! -e "$initialize_output" ||
		die "initialization output '$initialize_output' already exists"
	cp "$state/initial-config" "$initialize_output" ||
		die "could not write initialization output '$initialize_output'"
	say "verified that the active topics reconstruct known-good codex tree $(git rev-parse "$codex_oid^{tree}")"
	say "wrote $initialize_output; no refs were updated"
	say "review and commit only $meta_config_path on meta before running Refresh codex"
}

choose_local_rebuild_session () {
	common_dir=$(git rev-parse --path-format=absolute --git-common-dir) ||
		die "could not locate the shared repository state"
	session_parent=$common_dir/codex-refresh
	mkdir -p "$session_parent" ||
		die "could not create local refresh storage"
	attempt=0
	while test "$attempt" -lt 100
	do
		attempt=$((attempt + 1))
		session_root=$session_parent/session.local.$$.${attempt}
		if mkdir "$session_root" 2>/dev/null
		then
			chmod 700 "$session_root" ||
				die "could not protect local refresh storage '$session_root'"
			session=$session_root/artifacts
			return 0
		fi
	done
	die "could not choose a unique local refresh session path"
}

local_refresh () {
	remote=origin
	base_name=master
	codex_name=codex
	rerere_name=codex
	session=
	require_automation=
	unstable_mode=
	while test $# -gt 0
	do
		case "$1" in
		--session) require_arg "$@"; session=$2; shift 2 ;;
		--remote) require_arg "$@"; remote=$2; shift 2 ;;
		--base) require_arg "$@"; base_name=$2; shift 2 ;;
		--codex) require_arg "$@"; codex_name=$2; shift 2 ;;
		--rerere-from) require_arg "$@"; rerere_name=$2; shift 2 ;;
		--require-automation) require_automation=t; shift ;;
		--enable-unstable)
			test -z "$unstable_mode" ||
				die "unstable lane mode was specified more than once"
			unstable_mode=enable
			shift
			;;
		--disable-unstable)
			test -z "$unstable_mode" ||
				die "unstable lane mode was specified more than once"
			unstable_mode=disable
			shift
			;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown refresh option '$1'" ;;
		esac
	done
	if test -z "$session"
	then
		common_dir=$(git rev-parse --path-format=absolute --git-common-dir) ||
			die "could not locate the shared repository state"
		mkdir -p "$common_dir/codex-refresh" ||
			die "could not create local refresh storage"
		session=$(mktemp -d "$common_dir/codex-refresh/session.XXXXXX") ||
			die "could not create a local refresh session"
	else
		case "$session" in
		/*) ;;
		*) session=$(pwd)/$session ;;
		esac
		test ! -e "$session" || die "refresh session '$session' already exists"
		mkdir -p "$session" || die "could not create refresh session '$session'"
	fi
	chmod 700 "$session" || die "could not protect refresh session '$session'"
	set -- --remote "$remote" --base "$base_name" --codex "$codex_name" \
		--rerere-from "$rerere_name" \
		--result "$session/codex-candidate" \
		--updates "$session/codex-updates" \
		--inputs "$session/codex-inputs" \
		--bundle "$session/codex.bundle" \
		--failure "$session/codex-conflict.md"
	test -z "$require_automation" || set -- "$@" --require-automation
	test -z "$unstable_mode" || set -- "$@" "--${unstable_mode}-unstable"
	fetch_heads "$remote"
	rewrite "$@"
	say "local refresh session: $session"
	say "no local branches or remote server refs were updated; inspect codex-updates and codex.bundle"
}

rewrite () {
	remote=origin
	base_name=master
	codex_name=codex
	rerere_name=codex
	result_file=
	updates_file=
	inputs_file=
	bundle_file=
	failure_file=
	worktree=
	require_automation=
	unstable_mode=

	while test $# -gt 0
	do
		case "$1" in
		--remote) require_arg "$@"; remote=$2; shift 2 ;;
		--base) require_arg "$@"; base_name=$2; shift 2 ;;
		--codex) require_arg "$@"; codex_name=$2; shift 2 ;;
		--rerere-from) require_arg "$@"; rerere_name=$2; shift 2 ;;
		--result) require_arg "$@"; result_file=$2; shift 2 ;;
		--updates) require_arg "$@"; updates_file=$2; shift 2 ;;
		--inputs) require_arg "$@"; inputs_file=$2; shift 2 ;;
		--bundle) require_arg "$@"; bundle_file=$2; shift 2 ;;
		--failure) require_arg "$@"; failure_file=$2; shift 2 ;;
		--worktree) require_arg "$@"; worktree=$2; shift 2 ;;
		--require-automation) require_automation=t; shift ;;
		--enable-unstable)
			test -z "$unstable_mode" ||
				die "unstable lane mode was specified more than once"
			unstable_mode=enable
			shift
			;;
		--disable-unstable)
			test -z "$unstable_mode" ||
				die "unstable lane mode was specified more than once"
			unstable_mode=disable
			shift
			;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown rewrite option '$1'" ;;
		esac
	done

	make_tmp_dir
	require_full_repository
	inputs=$tmp_dir/inputs
	topics=$tmp_dir/topics
	snapshot_inputs "$remote" "$base_name" "$codex_name" "$inputs" \
		"$topics" '' "$unstable_mode"
	test -z "$inputs_file" || cp "$inputs" "$inputs_file"
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")

	if test -z "$worktree"
	then
		worktree=$tmp_dir/worktree
	else
		case "$worktree" in
		/*) ;;
		*) worktree=$(pwd)/$worktree ;;
		esac
		test ! -e "$worktree" || die "worktree path '$worktree' already exists"
	fi
	temporary_worktree=$worktree
	git -c core.fsmonitor=false worktree add --detach "$worktree" "$base_oid" \
		>/dev/null
	state=$(state_path "$worktree")
	initialize_rewrite "$remote" "$base_name" "$codex_name" "$rerere_name" \
		"$worktree" "$state" "$inputs" "$topics" "$require_automation"

	if ! process_planned_graph "$worktree" "$state"
	then
		if test -f "$state/merge-graph"
		then
			write_merge_graph_failure "$failure_file" "$state" "$worktree"
		else
			write_failure "$failure_file" "$state" "$worktree"
		fi
		die "conflict while rebasing '$(state_value "$state" failed-owner)'; no refs were updated"
	fi

	if ! candidate=$(assemble_candidate "$worktree" "$state")
	then
		if test -f "$state/integration-failed-name"
		then
			write_integration_failure "$failure_file" "$state" "$worktree"
			die "codex integration conflicts while merging '$(state_value "$state" integration-failed-name)'; no refs were updated"
		fi
		die "codex candidate validation failed; no refs were updated"
	fi
	codex_oid=$(state_value "$state" codex-oid)
	contained=t
	git merge-base --is-ancestor "$base_oid" "$codex_oid" || contained=
	if test -f "$state/pinned-plan-mode"
	then
		while IFS="$tab" read -r name source_tip
		do
			generated_tip=$(result_lookup "$state/results" "$name")
			git merge-base --is-ancestor "$generated_tip" "$codex_oid" ||
				contained=
		done <"$state/topics"
	else
		while IFS="$tab" read -r ref old new
		do
			git merge-base --is-ancestor "$new" "$codex_oid" || contained=
		done <"$state/topic-updates"
	fi
	if test -n "$contained" &&
		test "$(git rev-parse "$candidate^{tree}")" = \
		"$(git rev-parse "$codex_oid^{tree}")" &&
		codex_has_expected_integrations "$state" "$codex_oid"
	then
		candidate=$codex_oid
	fi
	if test -n "$(state_value "$state" unstable-mode)"
	then
		published_codex=$(state_value "$state" published-codex-oid)
		test "$candidate" = "$codex_oid" &&
			test "$codex_oid" = "$published_codex" ||
			die "changing the codex-unstable lane requires a clean, unchanged production codex output"
	fi
	prepare_unstable_candidate "$worktree" "$state" "$candidate" \
		"$failure_file"
	create_meta_commit "$state" "$candidate"
	write_complete_updates "$state" "$candidate" "$tmp_dir/updates"

	test -z "$result_file" || printf '%s\n' "$candidate" >"$result_file"
	test -z "$updates_file" || cp "$tmp_dir/updates" "$updates_file"
	test -z "$bundle_file" || create_bundle "$bundle_file" "$state" "$candidate"
	say "rewrote all active topics and assembled codex candidate $candidate"
	if test -f "$state/unstable-output-oid" &&
		! is_null_oid "$(state_value "$state" unstable-output-oid)"
	then
		say "assembled codex-unstable candidate $(state_value "$state" unstable-output-oid)"
	fi
}

verify_inputs () {
	remote=origin
	base_name=master
	codex_name=codex

	while test $# -gt 1
	do
		case "$1" in
		--remote) test $# -ge 3 || die "--remote needs one argument"; remote=$2; shift 2 ;;
		--base) test $# -ge 3 || die "--base needs one argument"; base_name=$2; shift 2 ;;
		--codex) test $# -ge 3 || die "--codex needs one argument"; codex_name=$2; shift 2 ;;
		*) break ;;
		esac
	done
	test $# = 1 || { usage >&2; exit 129; }
	expected=$1
	test -f "$expected" || die "input snapshot '$expected' does not exist"

	make_tmp_dir
	require_full_repository
	fetch_heads "$remote"
	expected_controller=$(awk -F '\t' '$1 == "controller" { print $3 }' \
		"$expected")
	test -n "$expected_controller" ||
		die "input snapshot has no controller commit"
	expected_mode=$(awk -F '\t' '$1 == "lane-mode" { print $3 }' \
		"$expected")
	actual=$tmp_dir/actual-inputs
	topics=$tmp_dir/actual-topics
	snapshot_inputs "$remote" "$base_name" "$codex_name" "$actual" "$topics" \
		"$expected_controller" "$expected_mode"
	if ! cmp -s "$expected" "$actual"
	then
		diff -u "$expected" "$actual" >&2 || :
		die "meta, master, codex, or a Codex topic moved while the candidate was running"
	fi
}

plan_trailer_one () (
	commit=$1
	key=$2
	label=$3
	values=$(git show -s --format="%(trailers:key=$key,valueonly)" \
		"$commit") ||
		die "could not read $label from plan transition"
	test -n "$values" ||
		die "plan transition is missing $label"
	test "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" = 1 ||
		die "plan transition repeats $label"
	printf '%s\n' "$values"
)

plan_trailer_optional () (
	commit=$1
	key=$2
	label=$3
	values=$(git show -s --format="%(trailers:key=$key,valueonly)" \
		"$commit") ||
		die "could not read $label from plan transition"
	test "$(printf '%s\n' "$values" | sed '/^$/d' | wc -l |
		tr -d ' ')" -le 1 ||
		die "plan transition repeats $label"
	printf '%s\n' "$values" | sed -n '1p'
)

has_qualifying_current_review () {
	reviews=$1
	author=$2
	head=$3
	repository=$4
	pull_number=$5
	candidates=$6
	require_exact_head=${7:-true}
	awk -F '\t' -v author="$author" -v head="$head" \
		-v exact="$require_exact_head" '
		NF == 4 && $2 ~ /^(APPROVED|CHANGES_REQUESTED|DISMISSED)$/ {
			state[$1] = $2
			commit[$1] = $3
			association[$1] = $4
		}
		END {
			for (reviewer in state)
				if (reviewer != author &&
					state[reviewer] == "APPROVED" &&
					(exact == "false" || commit[reviewer] == head))
					print reviewer "\t" association[reviewer]
		}
	' "$reviews" >"$candidates" || return 1
	while IFS="$tab" read -r reviewer association
	do
		case "$association" in
		OWNER|MEMBER|COLLABORATOR) return 0 ;;
		esac
	done <"$candidates"
	# author_association is relative to the API caller.  The Actions
	# token can see an organization member as NONE, so ask GitHub for
	# the latest reviews from writers instead of trusting that field.
	owner=${repository%%/*}
	name=${repository#*/}
	gh api --hostname github.com graphql \
		-f 'query=query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){latestOpinionatedReviews(first:100,writersOnly:true){nodes{author{login}state commit{oid}}}}}}' \
		-F owner="$owner" -F name="$name" -F number="$pull_number" \
		--jq '.data.repository.pullRequest.latestOpinionatedReviews.nodes[] |
			[(.author.login // "-"), .state,
			(.commit.oid // "-")] | @tsv' \
		>"$candidates-writers" 2>/dev/null || return 1
	awk -F '\t' -v author="$author" -v head="$head" \
		-v exact="$require_exact_head" '
		NF == 3 && $1 != author && $2 == "APPROVED" &&
			(exact == "false" || $3 == head) { approved++ }
		END { exit !approved }
	' "$candidates-writers"
}

validate_topic_review () {
	repository=openai/git
	pull_number=
	lane=
	topic=
	source_tip=
	while test $# -gt 0
	do
		case "$1" in
		--repository) require_arg "$@"; repository=$2; shift 2 ;;
		--pull-request) require_arg "$@"; pull_number=$2; shift 2 ;;
		--lane) require_arg "$@"; lane=$2; shift 2 ;;
		--topic) require_arg "$@"; topic=$2; shift 2 ;;
		--source-tip) require_arg "$@"; source_tip=$2; shift 2 ;;
		*) die "unknown validate-topic-review option '$1'" ;;
		esac
	done
	test "$repository" = openai/git ||
		die "reviewed Codex topics must belong to openai/git"
	case "$pull_number" in
	''|*[!0-9]*) die "validate-topic-review needs a pull request number" ;;
	esac
	topic=${topic#refs/heads/}
	case "$lane" in
	codex)
		is_stable_topic_name "$topic" ||
			die "'$topic' is not a production Codex topic"
		;;
	codex-unstable)
		is_unstable_topic_name "$topic" ||
			die "'$topic' is not an unstable Codex topic"
		;;
	*) die "unknown Codex lane '$lane'" ;;
	esac
	require_full_commit_oid "$source_tip"
	make_tmp_dir
	gh api --hostname github.com \
		"repos/$repository/pulls/$pull_number" \
		--jq '[.state, (.draft | tostring), .base.ref,
			(.head.repo.full_name // "-"), .head.ref, .head.sha,
			(.user.login // "-")] | @tsv' >"$tmp_dir/topic-pr" ||
		die "could not inspect reviewed topic pull request #$pull_number"
	IFS="$tab" read -r state draft base head_repository head_ref \
		head_sha author <"$tmp_dir/topic-pr" ||
		die "could not parse reviewed topic pull request #$pull_number"
	test "$state" = open ||
		die "reviewed topic pull request #$pull_number is not open"
	test "$draft" = false ||
		die "reviewed topic pull request #$pull_number is draft"
	test "$base" = "$lane" ||
		die "reviewed topic pull request #$pull_number targets '$base', not '$lane'"
	test "$head_repository" = "$repository" ||
		die "reviewed topic pull request #$pull_number is not same-repository"
	test "$head_ref" = "$topic" ||
		die "reviewed topic pull request #$pull_number names '$head_ref', not '$topic'"
	test "$head_sha" = "$source_tip" ||
		die "reviewed topic pull request #$pull_number moved from $source_tip to $head_sha"
	review_decision=$(gh pr view "$pull_number" --repo "$repository" \
		--json reviewDecision --jq '.reviewDecision') ||
		die "could not read review decision for topic pull request #$pull_number"
	test "$review_decision" = APPROVED ||
		die "topic pull request #$pull_number is not approved"
	gh api --hostname github.com --paginate \
		"repos/$repository/pulls/$pull_number/reviews?per_page=100" \
		--jq '.[] | [.user.login, .state, (.commit_id // "-"),
			.author_association] | @tsv' >"$tmp_dir/topic-reviews" ||
		die "could not inspect reviews for topic pull request #$pull_number"
	has_qualifying_current_review "$tmp_dir/topic-reviews" "$author" \
		"$source_tip" "$repository" "$pull_number" \
		"$tmp_dir/topic-review-candidates" false ||
		die "topic pull request #$pull_number has no qualifying approval"
	say "validated reviewed topic pull request #$pull_number at $source_tip"
}

validate_plan_transition_core () {
	recovery_pin_mode=$1
	recovery_expected_blob=$2
	shift 2
	remote=origin
	base_commit=
	head_commit=
	while test $# -gt 0
	do
		case "$1" in
		--remote) require_arg "$@"; remote=$2; shift 2 ;;
		--base-commit) require_arg "$@"; base_commit=$2; shift 2 ;;
		--head-commit) require_arg "$@"; head_commit=$2; shift 2 ;;
		*) die "unknown validate-plan-transition option '$1'" ;;
		esac
	done
	test -n "$base_commit" && test -n "$head_commit" ||
		die "validate-plan-transition requires --base-commit and --head-commit"
	make_tmp_dir
	require_full_repository
	base_commit=$(resolve_commit "$base_commit")
	head_commit=$(resolve_commit "$head_commit")
	parents=$(git show -s --format=%P "$head_commit") ||
		die "could not inspect plan transition head"
	test "$parents" = "$base_commit" ||
		die "plan transition head is not one direct child of its meta base"
	git diff-tree --no-commit-id --name-only -r "$base_commit" \
		"$head_commit" | LC_ALL=C sort >"$tmp_dir/changed-paths" ||
		die "could not inspect plan transition paths"
	recovery=$(plan_trailer_optional "$head_commit" Codex-Plan-Recovery \
		"Codex-Plan-Recovery")
	recovery_pr=$(plan_trailer_optional "$head_commit" \
		Codex-Plan-Recovery-PR "Codex-Plan-Recovery-PR")

	git show "$base_commit:$meta_config_path" >"$tmp_dir/base-config" \
		2>/dev/null ||
		die "plan transition base has no $meta_config_path"
	base_ref=$(config_get_one "$tmp_dir/base-config" codex.base-ref)
	base_name=${base_ref#refs/heads/}
	codex_ref=$(config_get_one "$tmp_dir/base-config" codex.output-ref)
	codex_name=${codex_ref#refs/heads/}
	mkdir -p "$tmp_dir/base-state" ||
		die "could not prepare plan transition state"
	read_meta_config "$base_commit" "$base_name" "$codex_name" \
		"$tmp_dir/base-state"
	version=$(state_value "$tmp_dir/base-state" config-version)
	base_has_plan=
	git cat-file -e "$base_commit:$stable_plan_path" 2>/dev/null &&
		base_has_plan=t
	base_has_unstable_plan=
	git cat-file -e "$base_commit:$unstable_plan_path" 2>/dev/null &&
		base_has_unstable_plan=t
	if test -z "$recovery"
	then
		test -z "$recovery_pr" ||
			die "plan recovery PR appears without a recovery marker"
	fi
	if test -n "$recovery"
	then
		test "$recovery" = release-source-ref-2026-08-06 ||
			die "plan transition names unknown release recovery"
		test -n "$base_has_plan" ||
			die "release recovery requires a published v3 plan"
		{
			printf '%s\n' "$stable_plan_path"
			printf '%s\n' "$release_recovery_path"
		} >"$tmp_dir/expected-paths"
		LC_ALL=C sort -o "$tmp_dir/expected-paths" \
			"$tmp_dir/expected-paths"
	elif test -z "$base_has_plan"
	then
		test "$version" = 1 || test "$version" = 2 ||
			die "only a v1/v2 controller may bootstrap pinned plans"
		{
			printf '%s\n' "$stable_plan_path"
			if test -f "$tmp_dir/base-state/published-unstable-oid"
			then
				printf '%s\n' "$unstable_plan_path"
			fi
		} >"$tmp_dir/expected-paths"
		LC_ALL=C sort -o "$tmp_dir/expected-paths" \
			"$tmp_dir/expected-paths"
	else
		count=$(wc -l <"$tmp_dir/changed-paths" | tr -d ' ')
		test "$count" = 1 ||
			die "a normal plan transition must change exactly one lane plan"
		case "$(sed -n '1p' "$tmp_dir/changed-paths")" in
		"$stable_plan_path"|"$unstable_plan_path") ;;
		*) die "a normal plan transition may change only one lane plan" ;;
		esac
		cp "$tmp_dir/changed-paths" "$tmp_dir/expected-paths"
	fi
	cmp -s "$tmp_dir/changed-paths" "$tmp_dir/expected-paths" ||
		die "plan transition changes paths outside its pinned manifest"

	base_oid=$(resolve_commit "$(remote_ref "$remote" "$base_name")")
	codex_oid=$(resolve_commit "$(remote_ref "$remote" "$codex_name")")
	legacy_sources=
	legacy_unstable_sources=
	if test -z "$base_has_plan"
	then
		legacy_sources=$tmp_dir/base-state/published-source-topics
		legacy_unstable_sources=$tmp_dir/base-state/published-unstable-source-topics
	fi
	head_plan_remote=$remote
	if test -n "$recovery" && test "$recovery_pin_mode" = will-create
	then
		head_plan_remote=-
	fi
	read_lane_plan "$head_commit" codex "$base_name" "$base_oid" \
		"$head_plan_remote" "$tmp_dir/head-topics" "$tmp_dir/head-plan" \
		"$legacy_sources"
	head_unstable_state=-
	if test -f "$tmp_dir/base-state/published-unstable-oid"
	then
		read_lane_plan "$head_commit" codex-unstable "$codex_name" \
			"$codex_oid" "$head_plan_remote" "$tmp_dir/head-unstable-topics" \
			"$tmp_dir/head-unstable-plan" "$legacy_unstable_sources"
		head_unstable_state=$tmp_dir/head-unstable-plan
	fi
	validate_pinned_plan_policy "$tmp_dir/head-plan" \
		"$head_unstable_state" "$base_name" "$version" \
		"$tmp_dir/base-state"

	base_stable_rows=$tmp_dir/base-stable-rows
	base_unstable_rows=$tmp_dir/base-unstable-rows
	base_stable_source_bases=$tmp_dir/base-stable-source-bases
	base_unstable_source_bases=$tmp_dir/base-unstable-source-bases
	has_unstable=
	if test -n "$base_has_plan"
	then
		read_lane_plan "$base_commit" codex "$base_name" "$base_oid" - \
			"$tmp_dir/base-topics" "$tmp_dir/base-plan"
		cp "$tmp_dir/base-plan/desired-prerequisites" \
			"$base_stable_rows"
		cp "$tmp_dir/base-plan/desired-source-bases" \
			"$base_stable_source_bases"
		if test -n "$base_has_unstable_plan"
		then
			has_unstable=t
			read_lane_plan "$base_commit" codex-unstable "$codex_name" \
				"$codex_oid" - "$tmp_dir/base-unstable-topics" \
				"$tmp_dir/base-unstable-plan"
			cp "$tmp_dir/base-unstable-plan/desired-prerequisites" \
				"$base_unstable_rows"
			cp "$tmp_dir/base-unstable-plan/desired-source-bases" \
				"$base_unstable_source_bases"
		fi
	else
		published_plan_rows "$tmp_dir/base-state" codex \
			"$base_stable_rows"
		published_source_base_rows "$tmp_dir/base-state" codex \
			"$base_name" "$base_stable_source_bases"
		if test -f "$tmp_dir/base-state/published-unstable-oid"
		then
			has_unstable=t
			published_plan_rows "$tmp_dir/base-state" \
				codex-unstable "$base_unstable_rows"
			published_source_base_rows "$tmp_dir/base-state" \
				codex-unstable "$codex_name" \
				"$base_unstable_source_bases"
		fi
	fi

	lane=$(plan_trailer_one "$head_commit" Codex-Plan-Lane \
		"Codex-Plan-Lane")
	action=$(plan_trailer_one "$head_commit" Codex-Plan-Action \
		"Codex-Plan-Action")
	topic=$(plan_trailer_one "$head_commit" Codex-Plan-Topic \
		"Codex-Plan-Topic")
	topic=${topic#refs/heads/}
	source_tip=$(plan_trailer_optional "$head_commit" \
		Codex-Plan-Source-Tip "Codex-Plan-Source-Tip")
	source_base=$(plan_trailer_optional "$head_commit" \
		Codex-Plan-Source-Base "Codex-Plan-Source-Base")
	merge=$(plan_trailer_optional "$head_commit" Codex-Plan-Merge \
		"Codex-Plan-Merge")
	after=$(plan_trailer_optional "$head_commit" Codex-Plan-After \
		"Codex-Plan-After")
	review_pr=$(plan_trailer_optional "$head_commit" Codex-Plan-Review \
		"Codex-Plan-Review")
	bootstrap=$(plan_trailer_optional "$head_commit" Codex-Plan-Bootstrap \
		"Codex-Plan-Bootstrap")
	authorization=$(plan_trailer_optional "$head_commit" \
		Codex-Plan-Authorization "Codex-Plan-Authorization")
	merge=${merge#refs/heads/}
	if test -n "$after" && test "$after" != root
	then
		after=${after#refs/heads/}
	fi
	case "$lane" in
	codex)
		is_stable_topic_name "$topic" ||
			die "plan transition names invalid production topic '$topic'"
		rows=$base_stable_rows
		source_bases=$base_stable_source_bases
		published_rows=$tmp_dir/base-state/published-topics
		lane_root=$base_name
		lane_root_oid=$base_oid
		lane_published_base_oid=$(state_value "$tmp_dir/base-state" \
			published-base-oid)
		;;
	codex-unstable)
		test -n "$has_unstable" ||
			die "plan transition names disabled codex-unstable lane"
		is_unstable_topic_name "$topic" ||
			die "plan transition names invalid unstable topic '$topic'"
		rows=$base_unstable_rows
		source_bases=$base_unstable_source_bases
		published_rows=$tmp_dir/base-state/published-unstable-topics
		lane_root=$codex_name
		lane_root_oid=$codex_oid
		lane_published_base_oid=$(state_value "$tmp_dir/base-state" \
			published-unstable-base-oid)
		;;
	*) die "plan transition names unknown lane '$lane'" ;;
	esac
	current_prerequisites=$(plan_prerequisites "$rows" "$topic")
	old_source_base=$(plan_source_base "$source_bases" "$topic")
	if test -n "$recovery"
	then
		validate_release_recovery_transition_metadata "$base_commit" \
			"$head_commit" "$remote"
		: # The exact recovery checks above own this authorization.
	elif test -n "$bootstrap"
	then
		test "$bootstrap" = true && test -n "$authorization" &&
			{ test "$version" = 1 || test "$version" = 2; } ||
			die "plan bootstrap needs a v1/v2 base and explicit authorization"
		test "$action" = alter ||
			die "plan bootstrap may alter only an already-published topic"
		if test -n "$base_has_plan"
		then
			test "$(plan_trailer_optional "$base_commit" \
				Codex-Plan-Bootstrap "Codex-Plan-Bootstrap")" = true ||
				die "plan bootstrap may continue only from an earlier bootstrap commit"
		fi
		test -z "$review_pr" ||
			die "plan bootstrap cannot claim a topic review"
	else
		test -z "$authorization" ||
			die "plan authorization appears without a bootstrap marker"
	fi
	case "$action" in
	add|alter)
		test -n "$source_tip" && test -n "$source_base" &&
			test -n "$merge" &&
			{ test -n "$review_pr" || test "$bootstrap" = true ||
				test -n "$recovery"; } ||
			die "plan transition '$action' needs source-tip, source-base, merge, and review or bootstrap trailers"
		if test -n "$review_pr"
		then
			case "$review_pr" in
			*[!0-9]*|'') die "plan transition has invalid review '$review_pr'" ;;
			esac
		fi
		require_full_commit_oid "$source_tip"
		require_full_commit_oid "$source_base"
		if test "$action" = alter
		then
			test -z "$after" ||
				die "plan transition alter cannot also reorder"
		fi
		;;
	remove)
		test -z "$source_tip" && test -z "$source_base" &&
			test -z "$merge" &&
			test -z "$after" && test -z "$review_pr" &&
			test -z "$bootstrap" ||
			die "plan transition remove has unexpected row trailers"
		;;
	reorder)
		test -z "$source_tip" && test -z "$source_base" &&
			test -z "$merge" &&
			test -n "$after" && test -z "$review_pr" &&
			test -z "$bootstrap" ||
			die "plan transition reorder needs only an after trailer"
		source_tip=$(plan_tip "$rows" "$topic")
		merge=$(plan_prerequisites "$rows" "$topic")
		source_base=$(plan_source_base "$source_bases" "$topic")
		;;
	*) die "plan transition names unknown action '$action'" ;;
	esac
	case "$action" in
	add)
		test -z "$current_prerequisites" ||
			die "plan transition adds already-enrolled topic '$topic'"
		test -z "$after" ||
			die "bot-projected add may only append its inferred topic"
		inferred=$(infer_added_plan_boundary "$rows" "$published_rows" \
			"$lane_root" "$lane_root_oid" \
			"$lane_published_base_oid" "$source_tip")
		IFS="$tab" read -r inferred_merge inferred_source_base <<-EOF
		$inferred
		EOF
		test "$merge" = "$inferred_merge" &&
			test "$source_base" = "$inferred_source_base" ||
			die "plan transition add is not the reviewed topic's inferred projection"
		;;
	alter)
		test -n "$current_prerequisites" ||
			die "plan transition alters missing topic '$topic'"
		test "$merge" = "$current_prerequisites" ||
			die "bot-projected alter may not change a topic prerequisite"
		set -- $merge
		test $# = 1 ||
			die "bot-projected alter cannot change a merge-shaped topic"
		inferred_source_base=$(infer_altered_plan_boundary "$rows" \
			"$source_bases" "$published_rows" "$lane_root" \
			"$lane_root_oid" "$lane_published_base_oid" "$topic" \
			"$merge" "$source_tip")
		test "$source_base" = "$inferred_source_base" ||
			die "plan transition alter is not the reviewed topic's inferred projection"
		;;
	reorder)
		test "$source_base" = "$old_source_base" ||
			die "plan transition reorder changes the topic source boundary"
		;;
	remove) ;;
	esac
	if test "$action" != remove
	then
		git merge-base --is-ancestor "$source_base" "$source_tip" ||
			die "plan transition source tip is outside its source boundary"
	fi
	test "$after" != "$topic" ||
		die "plan transition orders '$topic' after itself"
	cp "$base_stable_rows" "$tmp_dir/expected-stable-rows"
	cp "$base_stable_source_bases" \
		"$tmp_dir/expected-stable-source-bases"
	if test -n "$has_unstable"
	then
		cp "$base_unstable_rows" "$tmp_dir/expected-unstable-rows"
		cp "$base_unstable_source_bases" \
			"$tmp_dir/expected-unstable-source-bases"
	fi
	if test "$lane" = codex
	then
		expected_rows=$tmp_dir/expected-stable-rows
		expected_source_bases=$tmp_dir/expected-stable-source-bases
	else
		expected_rows=$tmp_dir/expected-unstable-rows
		expected_source_bases=$tmp_dir/expected-unstable-source-bases
	fi
	replace_plan_row "$expected_rows" "$expected_rows.next" "$topic" \
		"$source_tip" "$merge" "$action" "$after"
	mv "$expected_rows.next" "$expected_rows"
	replace_plan_source_base "$expected_source_bases" \
		"$expected_source_bases.next" "$topic" "$source_base" \
		"$action"
	mv "$expected_source_bases.next" "$expected_source_bases"
	write_lane_plan codex "$base_name" "$tmp_dir/expected-stable-rows" \
		"$tmp_dir/expected-stable-source-bases" \
		"$tmp_dir/expected-$stable_plan_path"
	git show "$head_commit:$stable_plan_path" \
		>"$tmp_dir/actual-$stable_plan_path" 2>/dev/null ||
		die "plan transition head has no $stable_plan_path"
	cmp -s "$tmp_dir/expected-$stable_plan_path" \
		"$tmp_dir/actual-$stable_plan_path" ||
		die "plan transition is not exactly one declared $action"
	if test -n "$has_unstable"
	then
		write_lane_plan codex-unstable "$codex_name" \
			"$tmp_dir/expected-unstable-rows" \
			"$tmp_dir/expected-unstable-source-bases" \
			"$tmp_dir/expected-$unstable_plan_path"
		git show "$head_commit:$unstable_plan_path" \
			>"$tmp_dir/actual-$unstable_plan_path" 2>/dev/null ||
			die "plan transition head has no $unstable_plan_path"
		cmp -s "$tmp_dir/expected-$unstable_plan_path" \
			"$tmp_dir/actual-$unstable_plan_path" ||
			die "plan transition is not exactly one declared $action"
	fi
	say "validated pinned plan transition $base_commit..$head_commit"
}

validate_plan_transition () {
	validate_plan_transition_core require-pin \
		"$(release_recovery_expected_blob)" "$@"
}

published_plan_rows () (
	state=$1
	lane=$2
	output=$3
	case "$lane" in
	codex)
		rows=$state/published-topics
		base_oid=$(state_value "$state" published-base-oid)
		output_oid=$(state_value "$state" published-codex-oid)
		;;
	codex-unstable)
		rows=$state/published-unstable-topics
		base_oid=$(state_value "$state" published-unstable-base-oid)
		output_oid=$(state_value "$state" published-unstable-oid)
		;;
	*) die "unknown Codex lane '$lane'" ;;
	esac
	: >"$output"
	git rev-list --first-parent --reverse "$base_oid..$output_oid" |
	while IFS= read -r commit
	do
		marker=$(git show -s \
			--format='%(trailers:key=Codex-Integration,valueonly)' \
			"$commit") || exit 1
		test -n "$marker" || continue
		name=${marker%@*}
		row=$(awk -F '\t' -v name="$name" '$1 == name {
			print; exit
		}' "$rows")
		test -n "$row" || continue
		IFS="$tab" read -r row_name tip prerequisites <<-EOF
		$row
		EOF
		printf '%s\t%s\t%s\n' "$row_name" "$tip" "$prerequisites"
	done >"$output"
	test "$(wc -l <"$output" | tr -d ' ')" = \
		"$(wc -l <"$rows" | tr -d ' ')" ||
	die "could not recover the published $lane integration order"
)

published_source_base_rows () (
	state=$1
	lane=$2
	root=$3
	output=$4
	case "$lane" in
	codex)
		rows=$state/published-topics
		source_rows=$state/published-source-topics
		root_tip=$(state_value "$state" published-base-oid)
		;;
	codex-unstable)
		rows=$state/published-unstable-topics
		source_rows=$state/published-unstable-source-topics
		root_tip=$(state_value "$state" published-unstable-base-oid)
		;;
	*) die "unknown Codex lane '$lane'" ;;
	esac
	: >"$output"
	while IFS="$tab" read -r name tip prerequisites
	do
		set -- $prerequisites
		test $# = 1 ||
			die "cannot recover source boundary for merge-shaped '$name'"
		if test "$1" = "$root"
		then
			source_base=$root_tip
		else
			source_base=$(published_tip "$source_rows" "$1")
			test -n "$source_base" ||
				die "cannot recover source boundary for '$name'"
		fi
		printf '%s\t%s\n' "$name" "$source_base"
	done <"$rows" >"$output"
)

replace_plan_row () (
	input=$1
	output=$2
	topic=$3
	tip=$4
	prerequisites=$5
	action=$6
	after=${7:-}
	case "$action" in
	add)
		! awk -F '\t' -v topic="$topic" '$1 == topic { found=1 }
			END { exit !found }' "$input" ||
			die "plan already contains '$topic'; use --action alter"
		;;
	alter|reorder)
		awk -F '\t' -v topic="$topic" '$1 == topic { found=1 }
			END { exit !found }' "$input" ||
			die "plan does not contain '$topic'; use --action add"
		;;
	remove)
		awk -F '\t' -v topic="$topic" '$1 == topic { found=1 }
			END { exit !found }' "$input" ||
			die "plan does not contain '$topic'"
		;;
	*) die "unknown plan action '$action'" ;;
	esac
	: >"$output.without"
	while IFS="$tab" read -r name old_tip old_prerequisites
	do
		test "$name" = "$topic" && continue
		printf '%s\t%s\t%s\n' "$name" "$old_tip" "$old_prerequisites" \
			>>"$output.without"
	done <"$input"
	if test "$action" = remove
	then
		cp "$output.without" "$output"
		rm -f "$output.without"
		return
	fi
	row=$(printf '%s\t%s\t%s\n' "$topic" "$tip" "$prerequisites")
	if test -z "$after"
	then
		if test "$action" = alter
		then
			: >"$output"
			while IFS="$tab" read -r name old_tip old_prerequisites
			do
				if test "$name" = "$topic"
				then
					printf '%s\n' "$row" >>"$output"
				else
					printf '%s\t%s\t%s\n' "$name" "$old_tip" \
						"$old_prerequisites" >>"$output"
				fi
			done <"$input"
			rm -f "$output.without"
			return
		fi
		cat "$output.without" >"$output"
		printf '%s\n' "$row" >>"$output"
		rm -f "$output.without"
		return
	fi
	: >"$output"
	inserted=
	if test "$after" = root
	then
		printf '%s\n' "$row" >>"$output"
		inserted=t
	fi
	while IFS="$tab" read -r name old_tip old_prerequisites
	do
		printf '%s\t%s\t%s\n' "$name" "$old_tip" "$old_prerequisites" \
			>>"$output"
		if test "$name" = "$after"
		then
			printf '%s\n' "$row" >>"$output"
			inserted=t
		fi
	done <"$output.without"
	test -n "$inserted" ||
		die "plan has no --after topic '$after'"
	rm -f "$output.without"
)

replace_plan_source_base () (
	input=$1
	output=$2
	topic=$3
	source_base=$4
	action=$5
	: >"$output"
	while IFS="$tab" read -r name old_source_base
	do
		test "$name" = "$topic" && continue
		printf '%s\t%s\n' "$name" "$old_source_base" >>"$output"
	done <"$input"
	if test "$action" != remove
	then
		test -n "$source_base" ||
			die "plan action '$action' has no source boundary for '$topic'"
		printf '%s\t%s\n' "$topic" "$source_base" >>"$output"
	fi
)

release_recovery_expected_blob () (
	printf '%s\n' 8ef04578ac791a3499b1406a1d0ae9884bacd559
)

release_recovery_value () (
	manifest=$1
	key=$2
	config_get_one "$manifest" "recovery.$key" "$release_recovery_path"
)

require_release_recovery_baseline () (
	baseline=$1
	meta_oid=$2
	paths=$tmp_dir/release-recovery-intervening-paths

	require_full_commit_oid "$baseline"
	git merge-base --is-ancestor "$baseline" "$meta_oid" ||
		die "release recovery meta does not descend from its exact baseline"
	for path in "$meta_config_path" "$stable_plan_path" "$unstable_plan_path"
	do
		test "$(git rev-parse "$baseline:$path")" = \
			"$(git rev-parse "$meta_oid:$path")" ||
			die "release recovery is no longer at its exact pinned-plan baseline"
	done
	git diff --name-only "$baseline" "$meta_oid" >"$paths" ||
		die "could not inspect release recovery controller changes"
	while IFS= read -r path
	do
		case "$path" in
		.github/CODEX.md|.github/workflows/codex-branch.sh|\
		t/t9905-codex-branch.sh|codex.release-recovery) ;;
		*) die "release recovery baseline has unrelated path '$path'" ;;
		esac
	done <"$paths"
)

validate_release_recovery_pr () {
	pull_number=$1
	topic=$2
	new_tip=$3
	head_ref=$4
	head_tip=$5
	head_ref=${head_ref#refs/heads/}
	gh api --hostname github.com \
		"repos/openai/git/pulls/$pull_number" \
		--jq '[.state, (.merged | tostring), .base.ref,
			(.head.repo.full_name // "-"), .head.ref, .head.sha,
			(.merge_commit_sha // "-")] | @tsv' \
		>"$tmp_dir/release-recovery-pr" ||
		die "could not inspect release recovery pull request #$pull_number"
	IFS="$tab" read -r state merged base head_repository \
		actual_head_ref actual_head_tip merge_commit \
		<"$tmp_dir/release-recovery-pr" ||
		die "could not parse release recovery pull request #$pull_number"
	test "$state" = closed && test "$merged" = true ||
		die "release recovery pull request #$pull_number is not merged"
	test "$base" = "$topic" ||
		die "release recovery pull request #$pull_number targets '$base', not '$topic'"
	test "$head_repository" = openai/git ||
		die "release recovery pull request #$pull_number is not same-repository"
	test "$actual_head_ref" = "$head_ref" &&
		test "$actual_head_tip" = "$head_tip" ||
		die "release recovery pull request #$pull_number has unexpected head"
	test "$merge_commit" = "$new_tip" ||
		die "release recovery pull request #$pull_number did not merge as $new_tip"
}

validate_release_recovery_transition_metadata () {
	base_commit=$1
	head_commit=$2
	remote=$3
	manifest=$tmp_dir/release-recovery-manifest

	test "$version" = 3 && test -n "$base_has_plan" &&
		test -n "$base_has_unstable_plan" ||
		die "release recovery requires the exact published v3 plans"
	test "$recovery" = release-source-ref-2026-08-06 ||
		die "plan transition names unknown release recovery"
	test "$recovery_pr" = 22 ||
		die "release recovery names unexpected pull request"
	test "$lane" = codex && test "$action" = alter &&
		test "$topic" = tb/codex/release ||
		die "release recovery is not the exact stable release transition"
	test -z "$after" && test -z "$review_pr" &&
		test -z "$bootstrap" ||
		die "release recovery cannot claim review, bootstrap, or reorder"
	test -n "$authorization" &&
		test "$(printf '%s\n' "$authorization" | wc -l |
			tr -d ' ')" = 1 ||
		die "release recovery needs one-line explicit authorization"

	git show "$base_commit:$release_recovery_path" >"$manifest" \
		2>/dev/null ||
		die "release recovery manifest is absent from its meta base"
	expected_blob=$recovery_expected_blob
	require_full_blob_oid "$expected_blob"
	test "$(git hash-object "$manifest")" = "$expected_blob" ||
		die "release recovery manifest is not the exact reviewed incident"
	git cat-file -e "$head_commit:$release_recovery_path" 2>/dev/null &&
		die "release recovery manifest survived its one-shot transition"

	test "$(release_recovery_value "$manifest" version)" = 1 ||
		die "release recovery manifest has unsupported version"
	recovery_baseline=$(release_recovery_value "$manifest" baseline-meta)
	recovery_lane=$(release_recovery_value "$manifest" lane)
	recovery_topic=$(release_recovery_value "$manifest" topic)
	recovery_old_tip=$(release_recovery_value "$manifest" old-source-tip)
	recovery_new_tip=$(release_recovery_value "$manifest" new-source-tip)
	recovery_source_base=$(release_recovery_value "$manifest" source-base)
	recovery_merge=$(release_recovery_value "$manifest" merge)
	recovery_pull_number=$(release_recovery_value "$manifest" pull-request)
	recovery_head_ref=$(release_recovery_value "$manifest" \
		pull-request-head-ref)
	recovery_head_tip=$(release_recovery_value "$manifest" \
		pull-request-head-tip)
	recovery_topic=$(printf '%s\n' "$recovery_topic" |
		sed 's|^refs/heads/||')
	recovery_merge=$(printf '%s\n' "$recovery_merge" |
		sed 's|^refs/heads/||')
	test "$recovery_lane" = codex &&
		test "$recovery_topic" = tb/codex/release &&
		test "$recovery_merge" = master &&
		test "$recovery_pull_number" = 22 ||
		die "release recovery manifest is not the exact stable release incident"
	require_full_commit_oid "$recovery_old_tip"
	require_full_commit_oid "$recovery_new_tip"
	require_full_commit_oid "$recovery_source_base"
	require_full_commit_oid "$recovery_head_tip"
	require_release_recovery_baseline "$recovery_baseline" "$base_commit"
	test "$source_tip" = "$recovery_new_tip" &&
		test "$source_base" = "$recovery_source_base" &&
		test "$merge" = "$recovery_merge" ||
		die "release recovery trailers do not match their exact manifest"
	test "$(plan_tip "$rows" "$topic")" = "$recovery_old_tip" &&
		test "$current_prerequisites" = "$recovery_merge" &&
		test "$old_source_base" = "$recovery_source_base" ||
		die "release recovery base row is not its exact reviewed row"
	test "$(git show -s --format=%P "$recovery_new_tip")" = \
		"$recovery_old_tip" ||
		die "release recovery source is not its exact one-parent step"
	recovery_live=$(git rev-parse --verify \
		"$(remote_ref "$remote" "$topic")^{commit}" 2>/dev/null) ||
		die "release recovery topic ref '$topic' does not exist"
	test "$recovery_live" = "$recovery_new_tip" ||
		die "release recovery topic ref '$topic' is $recovery_live, not $recovery_new_tip"
	validate_release_recovery_pr "$recovery_pull_number" "$topic" \
		"$recovery_new_tip" "$recovery_head_ref" \
		"$recovery_head_tip"
	recovery_pin_ref=$(pin_ref_for_tip "$recovery_new_tip")
	recovery_pin_name=${recovery_pin_ref#refs/heads/}
	recovery_pin_oid=$(git rev-parse --verify \
		"$(remote_ref "$remote" "$recovery_pin_name")^{commit}" \
		2>/dev/null || :)
	if test "$recovery_pin_mode" = will-create
	then
		test -z "$recovery_pin_oid" ||
			die "release recovery pin '$recovery_pin_ref' already exists"
	else
		test "$recovery_pin_oid" = "$recovery_new_tip" ||
			die "release recovery pin '$recovery_pin_ref' is missing or wrong"
	fi
	test "$(git rev-parse "$base_commit:$meta_config_path")" = \
		"$(git rev-parse "$head_commit:$meta_config_path")" &&
		test "$(git rev-parse "$base_commit:$unstable_plan_path")" = \
			"$(git rev-parse "$head_commit:$unstable_plan_path")" ||
		die "release recovery changes state outside its stable plan row"
}

recover_release_pin_core () {
	expected_blob=$1
	shift
	require_full_blob_oid "$expected_blob"
	remote=origin
	expected_meta=
	authorization=
	no_push=
	while test $# -gt 0
	do
		case "$1" in
		--remote) require_arg "$@"; remote=$2; shift 2 ;;
		--expected-meta)
			require_arg "$@"
			expected_meta=$2
			shift 2
			;;
		--authorization)
			require_arg "$@"
			authorization=$2
			shift 2
			;;
		--no-push) no_push=t; shift ;;
		*) die "unknown recover-release-pin option '$1'" ;;
		esac
	done
	test -n "$expected_meta" && test -n "$authorization" ||
		die "recover-release-pin requires --expected-meta and --authorization"
	require_full_commit_oid "$expected_meta"
	test "$(printf '%s\n' "$authorization" | wc -l | tr -d ' ')" = 1 ||
		die "--authorization must be one line"

	make_tmp_dir
	require_full_repository
	fetch_heads "$remote"
	meta_oid=$(resolve_commit "$(remote_ref "$remote" meta)")
	test "$meta_oid" = "$expected_meta" ||
		die "meta moved from expected $expected_meta to $meta_oid"
	git show "$meta_oid:$release_recovery_path" \
		>"$tmp_dir/$release_recovery_path" 2>/dev/null ||
		die "release recovery manifest is absent; this one-shot path is closed"
	test "$(git hash-object "$tmp_dir/$release_recovery_path")" = \
		"$expected_blob" ||
		die "release recovery manifest is not the exact reviewed incident"
	manifest=$tmp_dir/$release_recovery_path
	test "$(release_recovery_value "$manifest" version)" = 1 ||
		die "release recovery manifest has unsupported version"
	baseline=$(release_recovery_value "$manifest" baseline-meta)
	lane=$(release_recovery_value "$manifest" lane)
	topic=$(release_recovery_value "$manifest" topic)
	old_tip=$(release_recovery_value "$manifest" old-source-tip)
	new_tip=$(release_recovery_value "$manifest" new-source-tip)
	source_base=$(release_recovery_value "$manifest" source-base)
	merge=$(release_recovery_value "$manifest" merge)
	pull_number=$(release_recovery_value "$manifest" pull-request)
	head_ref=$(release_recovery_value "$manifest" pull-request-head-ref)
	head_tip=$(release_recovery_value "$manifest" pull-request-head-tip)
	topic=${topic#refs/heads/}
	merge=${merge#refs/heads/}
	test "$lane" = codex && test "$topic" = tb/codex/release &&
		test "$merge" = master ||
		die "release recovery manifest is not the exact stable release incident"
	require_full_commit_oid "$old_tip"
	require_full_commit_oid "$new_tip"
	require_full_commit_oid "$source_base"
	require_full_commit_oid "$head_tip"
	case "$pull_number" in
	22) ;;
	*) die "release recovery manifest has unexpected pull request" ;;
	esac
	require_release_recovery_baseline "$baseline" "$meta_oid"

	git show "$meta_oid:$meta_config_path" >"$tmp_dir/base-config" \
		2>/dev/null ||
		die "meta has no $meta_config_path"
	test "$(config_get_one "$tmp_dir/base-config" codex.version)" = 3 ||
		die "release recovery requires a published v3 controller"
	base_ref=$(config_get_one "$tmp_dir/base-config" codex.base-ref)
	base_name=${base_ref#refs/heads/}
	codex_ref=$(config_get_one "$tmp_dir/base-config" codex.output-ref)
	codex_name=${codex_ref#refs/heads/}
	base_oid=$(resolve_commit "$(remote_ref "$remote" "$base_name")")
	codex_oid=$(resolve_commit "$(remote_ref "$remote" "$codex_name")")
	mkdir -p "$tmp_dir/published-state" ||
		die "could not prepare release recovery state"
	read_meta_config "$meta_oid" "$base_name" "$codex_name" \
		"$tmp_dir/published-state"
	read_lane_plan "$meta_oid" codex "$base_name" "$base_oid" \
		"$remote" "$tmp_dir/existing-topics" "$tmp_dir/existing-plan"
	git cat-file -e "$meta_oid:$unstable_plan_path" 2>/dev/null ||
		die "release recovery requires the exact unstable plan"
	read_lane_plan "$meta_oid" codex-unstable "$codex_name" \
		"$codex_oid" "$remote" "$tmp_dir/existing-unstable-topics" \
		"$tmp_dir/existing-unstable-plan"
	cp "$tmp_dir/existing-plan/desired-prerequisites" \
		"$tmp_dir/stable-rows"
	cp "$tmp_dir/existing-plan/desired-source-bases" \
		"$tmp_dir/stable-source-bases"
	cp "$tmp_dir/existing-unstable-plan/desired-prerequisites" \
		"$tmp_dir/unstable-rows"
	cp "$tmp_dir/existing-unstable-plan/desired-source-bases" \
		"$tmp_dir/unstable-source-bases"
	test "$(plan_tip "$tmp_dir/stable-rows" "$topic")" = "$old_tip" ||
		die "release recovery old pinned source is no longer present"
	test "$(plan_prerequisites "$tmp_dir/stable-rows" "$topic")" = \
		"$merge" ||
		die "release recovery would change the release prerequisite"
	test "$(plan_source_base "$tmp_dir/stable-source-bases" "$topic")" = \
		"$source_base" ||
		die "release recovery would change the release source boundary"
	live=$(git rev-parse --verify \
		"$(remote_ref "$remote" "$topic")^{commit}" 2>/dev/null) ||
		die "release recovery topic ref '$topic' does not exist"
	test "$live" = "$new_tip" ||
		die "release recovery topic ref '$topic' is $live, not $new_tip"
	test "$(git show -s --format=%P "$new_tip")" = "$old_tip" ||
		die "release recovery source is not the exact ba107 to 40589 step"
	validate_release_recovery_pr "$pull_number" "$topic" "$new_tip" \
		"$head_ref" "$head_tip"
	pin_ref=$(pin_ref_for_tip "$new_tip")
	pin_name=${pin_ref#refs/heads/}
	pin_oid=$(git rev-parse --verify \
		"$(remote_ref "$remote" "$pin_name")^{commit}" \
		2>/dev/null || :)
	test -z "$pin_oid" ||
		die "release recovery pin '$pin_ref' already exists"

	replace_plan_row "$tmp_dir/stable-rows" "$tmp_dir/stable-rows.next" \
		"$topic" "$new_tip" "$merge" alter
	mv "$tmp_dir/stable-rows.next" "$tmp_dir/stable-rows"
	replace_plan_source_base "$tmp_dir/stable-source-bases" \
		"$tmp_dir/stable-source-bases.next" "$topic" \
		"$source_base" alter
	mv "$tmp_dir/stable-source-bases.next" \
		"$tmp_dir/stable-source-bases"
	write_lane_plan codex "$base_name" "$tmp_dir/stable-rows" \
		"$tmp_dir/stable-source-bases" "$tmp_dir/$stable_plan_path"
	write_lane_plan codex-unstable "$codex_name" \
		"$tmp_dir/unstable-rows" "$tmp_dir/unstable-source-bases" \
		"$tmp_dir/$unstable_plan_path"
	git show "$meta_oid:$unstable_plan_path" \
		>"$tmp_dir/original-$unstable_plan_path" ||
		die "could not inspect the exact unstable plan"
	cmp -s "$tmp_dir/original-$unstable_plan_path" \
		"$tmp_dir/$unstable_plan_path" ||
		die "release recovery changes the unstable plan"

	index=$tmp_dir/recovery.index
	GIT_INDEX_FILE=$index git read-tree "$meta_oid" ||
		die "could not prepare release recovery index"
	stable_blob=$(git hash-object -w "$tmp_dir/$stable_plan_path") ||
		die "could not write release recovery plan blob"
	GIT_INDEX_FILE=$index git update-index --add --cacheinfo \
		100644 "$stable_blob" "$stable_plan_path" ||
		die "could not stage release recovery plan"
	GIT_INDEX_FILE=$index git update-index --force-remove \
		"$release_recovery_path" ||
		die "could not close release recovery manifest"
	tree=$(GIT_INDEX_FILE=$index git write-tree) ||
		die "could not write release recovery tree"
	message=$tmp_dir/recovery-message
	{
		printf 'Codex plan: recover merged release metadata pin\n\n'
		printf 'This one-shot transition records the exact merged release\n'
		printf 'metadata commit missed by the v2 to v3 bootstrap.\n\n'
		printf 'Codex-Plan-Lane: codex\n'
		printf 'Codex-Plan-Action: alter\n'
		printf 'Codex-Plan-Topic: %s\n' "$topic"
		printf 'Codex-Plan-Source-Tip: %s\n' "$new_tip"
		printf 'Codex-Plan-Merge: %s\n' "$merge"
		printf 'Codex-Plan-Source-Base: %s\n' "$source_base"
		printf 'Codex-Plan-Recovery: release-source-ref-2026-08-06\n'
		printf 'Codex-Plan-Recovery-PR: %s\n' "$pull_number"
		printf 'Codex-Plan-Authorization: %s\n' "$authorization"
	} >"$message"
	plan_commit=$(
		env GIT_AUTHOR_NAME="$bot_name" GIT_AUTHOR_EMAIL="$bot_email" \
			GIT_COMMITTER_NAME="$bot_name" \
			GIT_COMMITTER_EMAIL="$bot_email" \
			git commit-tree "$tree" -p "$meta_oid" <"$message"
	) || die "could not create release recovery plan commit"
	(
		validate_plan_transition_core will-create "$expected_blob" \
			--remote "$remote" \
			--base-commit "$meta_oid" --head-commit "$plan_commit"
	) || die "release recovery did not pass canonical pre-push validation"
	git diff-tree --no-commit-id --name-only -r "$meta_oid" \
		"$plan_commit" | LC_ALL=C sort \
		>"$tmp_dir/recovery-changed-paths" ||
		die "could not inspect release recovery transition"
	{
		printf '%s\n' "$stable_plan_path"
		printf '%s\n' "$release_recovery_path"
	} | LC_ALL=C sort >"$tmp_dir/recovery-expected-paths"
	cmp -s "$tmp_dir/recovery-changed-paths" \
		"$tmp_dir/recovery-expected-paths" ||
		die "release recovery changes paths outside its exact manifest"
	read_lane_plan "$plan_commit" codex "$base_name" "$base_oid" - \
		"$tmp_dir/proposed-topics" "$tmp_dir/proposed-plan"
	read_lane_plan "$plan_commit" codex-unstable "$codex_name" \
		"$codex_oid" - "$tmp_dir/proposed-unstable-topics" \
		"$tmp_dir/proposed-unstable-plan"
	(
		validate_pinned_plan_policy "$tmp_dir/proposed-plan" \
			"$tmp_dir/proposed-unstable-plan" "$base_name" 3 \
			"$tmp_dir/published-state"
	) || die "release recovery did not pass pinned plan policy"
	test "$(plan_tip "$tmp_dir/proposed-plan/desired-prerequisites" \
		"$topic")" = "$new_tip" ||
		die "release recovery did not retain the exact new source"
	test "$(plan_prerequisites \
		"$tmp_dir/proposed-plan/desired-prerequisites" "$topic")" = \
		"$merge" ||
		die "release recovery changed the release prerequisite"
	test "$(plan_source_base \
		"$tmp_dir/proposed-plan/desired-source-bases" "$topic")" = \
		"$source_base" ||
		die "release recovery changed the release source boundary"

	if test -n "$no_push"
	then
		say "proposed one-shot release recovery $plan_commit"
		say "pin $pin_ref $new_tip"
		return
	fi
	require_bootstrap_pin_guard
	git push --atomic \
		"--force-with-lease=refs/heads/meta:$meta_oid" \
		"--force-with-lease=$pin_ref:" \
		"$remote" "$plan_commit:refs/heads/meta" \
		"$new_tip:$pin_ref" ||
		die "could not atomically publish one-shot release recovery"
	fetch_heads "$remote"
	test "$(git rev-parse "$(remote_ref "$remote" meta)")" = \
		"$plan_commit" ||
		die "remote meta does not name the release recovery commit"
	test "$(git rev-parse "$(remote_ref "$remote" "$pin_name")")" = \
		"$new_tip" ||
		die "remote release recovery pin does not name $new_tip"
	(
		validate_plan_transition_core require-pin "$expected_blob" \
			--remote "$remote" --base-commit "$meta_oid" \
			--head-commit "$plan_commit"
	) || die "published release recovery did not pass canonical validation"
	git cat-file -e "$plan_commit:$release_recovery_path" 2>/dev/null &&
		die "release recovery manifest survived its one-shot transition"
	say "published one-shot release recovery $plan_commit"
}

recover_release_pin () {
	recover_release_pin_core "$(release_recovery_expected_blob)" "$@"
}

require_release_recovery_fixture () {
	# t9905 needs synthetic object IDs to exercise the atomic transition.
	# Keep that escape hatch off the public command surface and behind an
	# explicit test-only entrypoint; recover-release-pin always uses the
	# checked-in incident blob above.
	test "${GIT_TEST_CODEX_RELEASE_RECOVERY_FIXTURE:-}" = t ||
		die "release recovery fixture entrypoint is test-only"
}

recover_release_pin_fixture () {
	require_release_recovery_fixture
	test $# -gt 0 || die "release recovery fixture needs a manifest blob"
	fixture_blob=$1
	shift
	recover_release_pin_core "$fixture_blob" "$@"
}

validate_plan_transition_fixture () {
	require_release_recovery_fixture
	test $# -gt 0 || die "release recovery fixture needs a manifest blob"
	fixture_blob=$1
	shift
	validate_plan_transition_core require-pin "$fixture_blob" "$@"
}

propose_plan () {
	remote=origin
	lane=
	topic=
	source_tip=
	review_pr=
	merge=
	after=
	action=
	plan_branch=
	expected_meta=
	bootstrap_authorization=
	no_push=
	while test $# -gt 0
	do
		case "$1" in
		--remote) require_arg "$@"; remote=$2; shift 2 ;;
		--lane) require_arg "$@"; lane=$2; shift 2 ;;
		--topic) require_arg "$@"; topic=$2; shift 2 ;;
		--source-tip) require_arg "$@"; source_tip=$2; shift 2 ;;
		--review-pr) require_arg "$@"; review_pr=$2; shift 2 ;;
		--merge) require_arg "$@"; merge=$2; shift 2 ;;
		--after) require_arg "$@"; after=$2; shift 2 ;;
		--action) require_arg "$@"; action=$2; shift 2 ;;
		--expected-meta) require_arg "$@"; expected_meta=$2; shift 2 ;;
		--plan-branch) require_arg "$@"; plan_branch=$2; shift 2 ;;
		--bootstrap-authorization)
			require_arg "$@"
			bootstrap_authorization=$2
			shift 2
			;;
		--no-push) no_push=t; shift ;;
		*) die "unknown propose-plan option '$1'" ;;
		esac
	done
	test -n "$lane" && test -n "$topic" && test -n "$action" ||
		die "propose-plan requires --lane, --topic, and --action"
	topic=${topic#refs/heads/}
	case "$lane" in
	codex)
		is_stable_topic_name "$topic" ||
			die "'$topic' is not a production Codex topic"
		;;
	codex-unstable)
		is_unstable_topic_name "$topic" ||
			die "'$topic' is not an unstable Codex topic"
		;;
	*) die "unknown Codex lane '$lane'" ;;
	esac
	case "$action" in
	auto|add|alter|remove|reorder) ;;
	*) die "unknown plan action '$action'" ;;
	esac
	case "$action" in
	auto|add|alter)
		if test -n "$bootstrap_authorization"
		then
			test "$action" != auto ||
				die "pre-v3 bootstrap requires an explicit alter action"
			test -z "$review_pr" ||
				die "pre-v3 bootstrap does not accept --review-pr"
		else
			test -n "$review_pr" ||
				die "--action $action requires --review-pr"
			case "$review_pr" in
			*[!0-9]*|'') die "--review-pr must be a pull request number" ;;
			esac
		fi
		;;
	remove|reorder)
		test -z "$source_tip" && test -z "$review_pr" &&
			test -z "$bootstrap_authorization" ||
			die "--action $action does not accept source review or bootstrap options"
		;;
	esac
	if test -n "$bootstrap_authorization"
	then
		test "$(printf '%s\n' "$bootstrap_authorization" | wc -l |
			tr -d ' ')" = 1 ||
			die "--bootstrap-authorization must be one line"
	fi
	case "$action" in
	auto|add|alter)
		test -z "$merge" && test -z "$after" ||
			die "--action $action derives order and prerequisite from the reviewed topic"
		;;
	remove)
		test -z "$merge" && test -z "$after" ||
			die "--action remove does not accept --merge or --after"
		;;
	reorder)
		test -z "$merge" ||
			die "--action reorder does not accept --merge"
		test -n "$after" ||
			die "--action reorder requires --after"
		;;
	esac
	if test -n "$merge"
	then
		merge=${merge#refs/heads/}
	fi
	if test -n "$after" && test "$after" != root
	then
		after=${after#refs/heads/}
	fi
	test "$after" != "$topic" ||
		die "a topic cannot be ordered after itself"

	make_tmp_dir
	require_full_repository
	fetch_heads "$remote"
	meta_oid=$(resolve_commit "$(remote_ref "$remote" meta)")
	if test -n "$expected_meta"
	then
		require_full_commit_oid "$expected_meta"
		test "$meta_oid" = "$expected_meta" ||
			die "meta moved from expected $expected_meta to $meta_oid"
	fi
	git show "$meta_oid:$meta_config_path" >"$tmp_dir/base-config" \
		2>/dev/null ||
		die "meta has no $meta_config_path"
	base_ref=$(config_get_one "$tmp_dir/base-config" codex.base-ref)
	base_name=${base_ref#refs/heads/}
	codex_ref=$(config_get_one "$tmp_dir/base-config" codex.output-ref)
	codex_name=${codex_ref#refs/heads/}
	base_oid=$(resolve_commit "$(remote_ref "$remote" "$base_name")")
	codex_oid=$(resolve_commit "$(remote_ref "$remote" "$codex_name")")
	mkdir -p "$tmp_dir/published-state" ||
		die "could not prepare published plan state"
	read_meta_config "$meta_oid" "$base_name" "$codex_name" \
		"$tmp_dir/published-state"
	version=$(state_value "$tmp_dir/published-state" config-version)
	stable_rows=$tmp_dir/stable-rows
	unstable_rows=$tmp_dir/unstable-rows
	stable_source_bases=$tmp_dir/stable-source-bases
	unstable_source_bases=$tmp_dir/unstable-source-bases
	has_unstable=
	has_existing_plan=
	if git cat-file -e "$meta_oid:$stable_plan_path" 2>/dev/null
	then
		has_existing_plan=t
		read_lane_plan "$meta_oid" codex "$base_name" "$base_oid" \
			"$remote" "$tmp_dir/existing-topics" \
			"$tmp_dir/existing-plan"
		cp "$tmp_dir/existing-plan/desired-prerequisites" "$stable_rows"
		cp "$tmp_dir/existing-plan/desired-source-bases" \
			"$stable_source_bases"
		if git cat-file -e "$meta_oid:$unstable_plan_path" 2>/dev/null
		then
			has_unstable=t
			read_lane_plan "$meta_oid" codex-unstable "$codex_name" \
				"$codex_oid" "$remote" \
				"$tmp_dir/existing-unstable-topics" \
				"$tmp_dir/existing-unstable-plan"
			cp "$tmp_dir/existing-unstable-plan/desired-prerequisites" \
				"$unstable_rows"
			cp "$tmp_dir/existing-unstable-plan/desired-source-bases" \
				"$unstable_source_bases"
		fi
	else
		test "$version" = 1 || test "$version" = 2 ||
			die "cannot bootstrap plans from config version '$version'"
		published_plan_rows "$tmp_dir/published-state" codex \
			"$stable_rows"
		published_source_base_rows "$tmp_dir/published-state" codex \
			"$base_name" "$stable_source_bases"
		if test -f "$tmp_dir/published-state/published-unstable-oid"
		then
			has_unstable=t
			published_plan_rows "$tmp_dir/published-state" \
				codex-unstable "$unstable_rows"
			published_source_base_rows "$tmp_dir/published-state" \
				codex-unstable "$codex_name" "$unstable_source_bases"
		fi
	fi
	if test -n "$bootstrap_authorization"
	then
		test "$action" = alter ||
			die "pre-v3 bootstrap may alter only an already-published topic"
		test "$version" = 1 || test "$version" = 2 ||
			die "pre-v3 bootstrap requires a v1/v2 controller"
		if test -n "$has_existing_plan"
		then
			test "$(plan_trailer_optional "$meta_oid" \
				Codex-Plan-Bootstrap "Codex-Plan-Bootstrap")" = true ||
				die "pre-v3 bootstrap may continue only from an earlier bootstrap commit"
		fi
		test -z "$plan_branch" ||
			die "pre-v3 bootstrap publishes meta directly, not a plan branch"
	fi
	if test "$lane" = codex-unstable
	then
		test -n "$has_unstable" ||
			die "codex-unstable is not enabled in published meta"
		rows=$unstable_rows
		source_bases=$unstable_source_bases
		published_rows=$tmp_dir/published-state/published-unstable-topics
		lane_base=$codex_name
		lane_base_oid=$codex_oid
		lane_published_base_oid=$(state_value "$tmp_dir/published-state" \
			published-unstable-base-oid)
	else
		rows=$stable_rows
		source_bases=$stable_source_bases
		published_rows=$tmp_dir/published-state/published-topics
		lane_base=$base_name
		lane_base_oid=$base_oid
		lane_published_base_oid=$(state_value "$tmp_dir/published-state" \
			published-base-oid)
	fi
	current_tip=$(plan_tip "$rows" "$topic")
	current_prerequisites=$(plan_prerequisites "$rows" "$topic")
	if test "$action" = auto
	then
		if test -n "$current_tip"
		then
			action=alter
		else
			action=add
		fi
	fi
	case "$action" in
	add)
		test -z "$current_tip" ||
			die "plan already contains '$topic'; use --action alter"
		;;
	alter)
		test -n "$current_tip" ||
			die "plan does not contain '$topic'; use --action add"
		merge=$current_prerequisites
		;;
	reorder)
		test -n "$current_tip" ||
			die "plan does not contain '$topic'"
		source_tip=$current_tip
		merge=$current_prerequisites
		;;
	remove)
		test -n "$current_tip" ||
			die "plan does not contain '$topic'"
		;;
	esac
	if test "$action" = add || test "$action" = alter
	then
		live=$(git rev-parse --verify \
			"$(remote_ref "$remote" "$topic")^{commit}" 2>/dev/null) ||
			die "topic ref '$topic' does not exist"
		if test -z "$source_tip"
		then
			source_tip=$live
		else
			require_full_commit_oid "$source_tip"
		fi
		test "$live" = "$source_tip" ||
			die "topic ref '$topic' is $live, not requested source tip $source_tip"
		if test -z "$bootstrap_authorization"
		then
			validate_topic_review --pull-request "$review_pr" \
				--lane "$lane" --topic "$topic" \
				--source-tip "$source_tip"
		fi
	fi
	new_source_base=
	case "$action" in
	add)
		inferred=$(infer_added_plan_boundary "$rows" "$published_rows" \
			"$lane_base" "$lane_base_oid" \
			"$lane_published_base_oid" "$source_tip")
		IFS="$tab" read -r merge new_source_base <<-EOF
		$inferred
		EOF
		;;
	alter)
		set -- $merge
		test $# = 1 ||
			die "altered pinned topic '$topic' has a merge-shaped prerequisite"
		new_source_base=$(infer_altered_plan_boundary "$rows" \
			"$source_bases" "$published_rows" "$lane_base" \
			"$lane_base_oid" "$lane_published_base_oid" "$topic" \
			"$merge" "$source_tip")
		;;
	reorder)
		new_source_base=$(plan_source_base "$source_bases" "$topic")
		;;
	remove) ;;
	esac
	replace_plan_row "$rows" "$rows.next" "$topic" "$source_tip" \
		"$merge" "$action" "$after"
	mv "$rows.next" "$rows"
	replace_plan_source_base "$source_bases" "$source_bases.next" \
		"$topic" "$new_source_base" "$action"
	mv "$source_bases.next" "$source_bases"
	write_lane_plan codex "$base_name" "$stable_rows" \
		"$stable_source_bases" "$tmp_dir/$stable_plan_path"
	if test -n "$has_unstable"
	then
		write_lane_plan codex-unstable "$codex_name" "$unstable_rows" \
			"$unstable_source_bases" "$tmp_dir/$unstable_plan_path"
	fi

	index=$tmp_dir/plan.index
	GIT_INDEX_FILE=$index git read-tree "$meta_oid" ||
		die "could not prepare plan commit index"
	stable_blob=$(git hash-object -w "$tmp_dir/$stable_plan_path") ||
		die "could not write $stable_plan_path blob"
	GIT_INDEX_FILE=$index git update-index --add --cacheinfo \
		100644 "$stable_blob" "$stable_plan_path" ||
		die "could not stage $stable_plan_path"
	if test -n "$has_unstable"
	then
		unstable_blob=$(git hash-object -w "$tmp_dir/$unstable_plan_path") ||
			die "could not write $unstable_plan_path blob"
		GIT_INDEX_FILE=$index git update-index --add --cacheinfo \
			100644 "$unstable_blob" "$unstable_plan_path" ||
			die "could not stage $unstable_plan_path"
	fi
	tree=$(GIT_INDEX_FILE=$index git write-tree) ||
		die "could not write pinned plan tree"
	message=$tmp_dir/plan-message
	{
		printf 'Codex plan: %s %s in %s\n\n' \
			"$action" "$topic" "$lane"
		printf 'Codex-Plan-Lane: %s\n' "$lane"
		printf 'Codex-Plan-Action: %s\n' "$action"
		printf 'Codex-Plan-Topic: %s\n' "$topic"
			case "$action" in
			add|alter)
				printf 'Codex-Plan-Source-Tip: %s\n' "$source_tip"
				printf 'Codex-Plan-Merge: %s\n' "$merge"
				printf 'Codex-Plan-Source-Base: %s\n' \
					"$new_source_base"
				if test -n "$bootstrap_authorization"
				then
					printf 'Codex-Plan-Bootstrap: true\n'
					printf 'Codex-Plan-Authorization: %s\n' \
						"$bootstrap_authorization"
				else
					printf 'Codex-Plan-Review: %s\n' "$review_pr"
				fi
				;;
			esac
		test -z "$after" ||
			printf 'Codex-Plan-After: %s\n' "$after"
	} >"$message"
	plan_commit=$(
		env GIT_AUTHOR_NAME="$bot_name" GIT_AUTHOR_EMAIL="$bot_email" \
			GIT_COMMITTER_NAME="$bot_name" \
			GIT_COMMITTER_EMAIL="$bot_email" \
			git commit-tree "$tree" -p "$meta_oid" <"$message"
	) || die "could not create pinned plan commit"

	read_lane_plan "$plan_commit" codex "$base_name" "$base_oid" - \
		"$tmp_dir/proposed-topics" "$tmp_dir/proposed-plan"
	proposed_unstable_state=-
	if test -n "$has_unstable"
	then
		read_lane_plan "$plan_commit" codex-unstable "$codex_name" \
			"$codex_oid" - "$tmp_dir/proposed-unstable-topics" \
			"$tmp_dir/proposed-unstable-plan"
		proposed_unstable_state=$tmp_dir/proposed-unstable-plan
	fi
	validate_pinned_plan_policy "$tmp_dir/proposed-plan" \
		"$proposed_unstable_state" "$base_name" "$version" \
		"$tmp_dir/published-state"
	{
		cut -f2 "$stable_rows"
		test -z "$has_unstable" || cut -f2 "$unstable_rows"
	} | LC_ALL=C sort -u >"$tmp_dir/pin-tips"
	: >"$tmp_dir/missing-pins"
	while IFS= read -r tip
	do
		test -n "$tip" || continue
		require_full_commit_oid "$tip"
		pin_ref=$(pin_ref_for_tip "$tip")
		pin_name=${pin_ref#refs/heads/}
		pin_oid=$(git rev-parse --verify \
			"$(remote_ref "$remote" "$pin_name")^{commit}" \
			2>/dev/null || :)
		if test -n "$pin_oid"
		then
			test "$pin_oid" = "$tip" ||
				die "immutable pin '$pin_ref' names $pin_oid, not $tip"
		else
			printf '%s\t%s\n' "$tip" "$pin_ref" \
				>>"$tmp_dir/missing-pins"
		fi
	done <"$tmp_dir/pin-tips"

	if test -n "$bootstrap_authorization"
	then
		if test -n "$no_push"
		then
			say "proposed pre-v3 bootstrap commit $plan_commit"
			while IFS="$tab" read -r tip pin_ref
			do
				say "pin $pin_ref $tip"
			done <"$tmp_dir/missing-pins"
			return
		fi
		require_bootstrap_pin_guard
		set -- --atomic \
			"--force-with-lease=refs/heads/meta:$meta_oid"
		while IFS="$tab" read -r tip pin_ref
		do
			set -- "$@" "--force-with-lease=$pin_ref:"
		done <"$tmp_dir/missing-pins"
		set -- "$@" "$remote" "$plan_commit:refs/heads/meta"
		while IFS="$tab" read -r tip pin_ref
		do
			set -- "$@" "$tip:$pin_ref"
		done <"$tmp_dir/missing-pins"
		git push "$@" ||
			die "could not atomically publish pre-v3 pinned-plan bootstrap"
		fetch_heads "$remote"
		test "$(git rev-parse "$(remote_ref "$remote" meta)")" = \
			"$plan_commit" ||
			die "remote meta does not name the bootstrap commit"
		validate_plan_transition --remote "$remote" \
			--base-commit "$meta_oid" --head-commit "$plan_commit"
		say "published pre-v3 pinned-plan bootstrap $plan_commit"
		return
	fi

	if test -z "$plan_branch"
	then
		short=${source_tip:-$meta_oid}
		short=$(printf '%.12s' "$short")
		slug=${topic##*/}
		plan_branch=codex-plan/$lane-$slug-$short
	fi
	plan_branch=${plan_branch#refs/heads/}
	case "$plan_branch" in
	codex-plan/*/*)
		die "plan branch '$plan_branch' has a nested suffix"
		;;
	codex-plan/*) ;;
	*) die "plan branch '$plan_branch' is not under codex-plan/" ;;
	esac
	git check-ref-format "refs/heads/$plan_branch" >/dev/null 2>&1 ||
		die "plan branch '$plan_branch' is invalid"

	if test -n "$no_push"
	then
		say "proposed pinned plan commit $plan_commit"
		say "plan branch refs/heads/$plan_branch"
		while IFS="$tab" read -r tip pin_ref
		do
			say "pin $pin_ref $tip"
		done <"$tmp_dir/missing-pins"
		return
	fi

	plan_old=$(git rev-parse --verify \
		"$(remote_ref "$remote" "$plan_branch")^{commit}" 2>/dev/null || :)
	if test -n "$plan_old"
	then
		lease=--force-with-lease=refs/heads/$plan_branch:$plan_old
	else
		lease=--force-with-lease=refs/heads/$plan_branch:
	fi
	set -- --atomic "$lease"
	while IFS="$tab" read -r tip pin_ref
	do
		set -- "$@" "--force-with-lease=$pin_ref:"
	done <"$tmp_dir/missing-pins"
	set -- "$@" "$remote" "$plan_commit:refs/heads/$plan_branch"
	while IFS="$tab" read -r tip pin_ref
	do
		set -- "$@" "$tip:$pin_ref"
	done <"$tmp_dir/missing-pins"
	git push "$@" ||
		die "could not atomically publish immutable pins and plan branch"
	fetch_heads "$remote"
	test "$(git rev-parse "$(remote_ref "$remote" "$plan_branch")")" = \
		"$plan_commit" ||
		die "remote plan branch does not name the proposed commit"
	validate_plan_transition --remote "$remote" --base-commit "$meta_oid" \
		--head-commit "$plan_commit"
	body=$tmp_dir/plan-body
	{
		printf 'Bot-generated pinned plan transition.\n\n'
		printf -- '- Lane: `%s`\n' "$lane"
		printf -- '- Action: `%s`\n' "$action"
		printf -- '- Topic: `refs/heads/%s`\n' "$topic"
		if test "$action" != remove
		then
			printf -- '- Source tip: `%s`\n' "$source_tip"
			printf -- '- Prerequisite: `refs/heads/%s`\n' "$merge"
		fi
		test -z "$review_pr" ||
			printf -- '- Reviewed topic PR: `#%s`\n' "$review_pr"
		printf '\nThe plan blob and immutable `codex-pins/*` refs are authoritative.\n'
	} >"$body"
	pr_url=$(gh pr create --repo openai/git --base meta \
		--head "$plan_branch" \
		--title "Codex plan: $action $topic in $lane" \
		--body-file "$body") ||
		die "plan branch was published, but its pull request could not be created"
	say "opened pinned plan pull request $pr_url"
	gh pr merge "$pr_url" --repo openai/git --auto --rebase \
		--match-head-commit "$plan_commit" ||
		die "plan pull request was opened, but auto-merge could not be requested"
	say "requested auto-merge for pinned plan $plan_commit"
}

prepare_input_graph () {
	inputs=$1
	graph=$2
	mkdir -p "$graph" || die "could not prepare input graph verification"
	awk -F '\t' '
		$1 == "controller" || $1 == "plan" || $1 == "pin" ||
		$1 == "base" || $1 == "codex" ||
		$1 == "topic" || $1 == "unstable" ||
		$1 == "unstable-plan" || $1 == "unstable-topic" ||
		$1 == "lane-mode" {
			if (NF != 3) exit 1
			next
		}
		$1 == "admission" || $1 == "unstable-admission" {
			if (NF != 5) exit 1
			next
		}
		{ exit 1 }
	' "$inputs" || die "input snapshot contains an invalid record"
	for kind in controller base codex
	do
		test "$(awk -F '\t' -v kind="$kind" '$1 == kind { count++ }
			END { print count + 0 }' "$inputs")" = 1 ||
			die "input snapshot must contain exactly one '$kind' record"
	done
	for kind in plan unstable unstable-plan lane-mode admission unstable-admission
	do
		test "$(awk -F '\t' -v kind="$kind" '$1 == kind { count++ }
			END { print count + 0 }' "$inputs")" -le 1 ||
			die "input snapshot contains more than one '$kind' record"
	done
	lane_mode=$(awk -F '\t' '$1 == "lane-mode" { print $3 }' "$inputs")
	case "$lane_mode" in
	''|enable|disable) ;;
	*) die "input snapshot contains an invalid unstable lane mode" ;;
	esac
	if test -n "$lane_mode"
	then
		test "$(awk -F '\t' '$1 == "lane-mode" { print $2 }' \
			"$inputs")" = refs/heads/codex-unstable ||
			die "input snapshot contains an invalid unstable lane ref"
	fi
	awk -F '\t' '$1 == "topic" {
		name=$2
		sub("^refs/heads/", "", name)
		printf "%s\t%s\n", name, $3
	}' "$inputs" | LC_ALL=C sort >"$graph/topics" ||
		die "could not read topics from the input snapshot"
	test -s "$graph/topics" || die "input snapshot contains no topics"
	test "$(cut -f1 "$graph/topics" | sort -u | wc -l | tr -d ' ')" = \
		"$(wc -l <"$graph/topics" | tr -d ' ')" ||
		die "input snapshot contains duplicate Codex topics"
	while IFS="$tab" read -r name oid
	do
		is_stable_topic_name "$name" ||
			die "input snapshot contains invalid active topic '$name'"
		require_full_commit_oid "$oid"
	done <"$graph/topics"
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	test -n "$base_oid" || die "input snapshot has no base commit"
	base_ref=$(awk -F '\t' '$1 == "base" { print $2 }' "$inputs")
	base_name=${base_ref#refs/heads/}
	base_ref=$(awk -F '\t' '$1 == "base" { print $2 }' "$inputs")
	codex_ref=$(awk -F '\t' '$1 == "codex" { print $2 }' "$inputs")
	controller_oid=$(awk -F '\t' '$1 == "controller" { print $3 }' "$inputs")
	base_name=${base_ref#refs/heads/}
	codex_name=${codex_ref#refs/heads/}
	printf '%s\n' "$codex_name" >"$graph/codex-name" ||
		die "could not retain the snapshotted Codex output name"
	read_meta_config "$controller_oid" "$base_name" "$codex_name" "$graph"
	config_version=$(state_value "$graph" config-version)
	if awk -F '\t' '$1 == "plan" { found=1 } END { exit !found }' \
		"$inputs"
	then
		test -z "$lane_mode" ||
			die "pinned plans cannot use an unstable lane mode"
		plan_blob=$(awk -F '\t' '$1 == "plan" { print $3 }' "$inputs")
		test -n "$plan_blob" ||
			die "pinned input snapshot has no production plan"
		read_lane_plan "$controller_oid" codex "$base_name" "$base_oid" \
			- "$graph/plan-topics" "$graph/pinned-plan"
		test "$plan_blob" = "$(state_value "$graph/pinned-plan" plan-blob)" ||
			die "input snapshot does not match its pinned production plan blob"
		awk -F '\t' '$1 == "topic" {
			name=$2
			sub("^refs/heads/", "", name)
			printf "%s\t%s\n", name, $3
		}' "$inputs" >"$graph/snapshot-topics" ||
			die "could not read pinned topics from the input snapshot"
		cmp -s "$graph/snapshot-topics" "$graph/plan-topics" ||
			die "input snapshot topics do not match the pinned production plan"
		{
			cut -f2 "$graph/plan-topics"
			awk -F '\t' '$1 == "unstable-topic" { print $3 }' "$inputs"
		} | LC_ALL=C sort -u |
		while IFS= read -r oid
		do
			printf 'pin\t%s\t%s\n' "$(pin_ref_for_tip "$oid")" "$oid"
		done >"$graph/expected-pins"
		awk -F '\t' '$1 == "pin" { print }' "$inputs" |
			LC_ALL=C sort >"$graph/snapshot-pins"
		cmp -s "$graph/expected-pins" "$graph/snapshot-pins" ||
			die "input snapshot does not retain every immutable plan pin"
		cp "$graph/plan-topics" "$graph/topics" ||
			die "could not retain pinned production topics"
			cp "$graph/pinned-plan/desired-prerequisites" \
				"$graph/desired-prerequisites" ||
				die "could not retain pinned production prerequisites"
			cp "$graph/pinned-plan/desired-source-bases" \
				"$graph/desired-source-bases" ||
				die "could not retain pinned production source boundaries"
		cp "$graph/pinned-plan/desired-order" "$graph/desired-order" ||
			die "could not retain pinned production order"
		cp "$graph/pinned-plan/plan-blob" "$graph/plan-blob" ||
			die "could not retain pinned production plan"
		: >"$graph/pinned-plan-mode"
		printf '%s\n' "$base_name" >"$graph/base-name"
		printf '%s\n' "$base_oid" >"$graph/base-oid"
		printf '%s\n' "$base_oid" >"$graph/source-base-oid"
		codex_oid=$(awk -F '\t' '$1 == "codex" { print $3 }' "$inputs")
		test "$codex_oid" = "$(state_value "$graph" published-codex-oid)" ||
			die "pinned input snapshot moves generated codex outside published state"
		awk -F '\t' '$1 == "unstable-topic" {
			name=$2
			sub("^refs/heads/", "", name)
			printf "%s\t%s\n", name, $3
		}' "$inputs" >"$graph/unstable-current-topics" ||
			die "could not prepare pinned unstable ownership verification"
		prepare_pinned_plan "$base_name" "$base_oid" "$graph/topics" \
			"$graph"
		return
	fi
	unstable_count=$(awk -F '\t' '$1 == "unstable" { count++ }
		END { print count + 0 }' "$inputs")
	case "$config_version:$lane_mode" in
	1:)
		test "$unstable_count" = 0 ||
			die "version 1 input snapshot invents an unstable output"
		;;
	1:enable|2:|2:disable)
		test "$unstable_count" = 1 ||
			die "enabled unstable lane is missing its snapshotted output"
		test "$(awk -F '\t' '$1 == "unstable" { print $2 }' \
			"$inputs")" = refs/heads/codex-unstable ||
			die "input snapshot records an invalid unstable output ref"
		;;
	*) die "input snapshot changes the unstable lane without authorization" ;;
	esac
	codex_oid=$(awk -F '\t' '$1 == "codex" { print $3 }' "$inputs")
	awk -F '\t' '$1 == "unstable-topic" {
		name=$2
		sub("^refs/heads/", "", name)
		printf "%s\t%s\n", name, $3
	}' "$inputs" | LC_ALL=C sort >"$graph/unstable-current-topics" ||
		die "could not prepare unstable ownership verification"
	validate_lane_isolation "$graph" "$graph/topics" \
		"$graph/unstable-current-topics" "$codex_oid"
	published_codex=$(state_value "$graph" published-codex-oid)
	awk -F '\t' '$1 == "admission" { print }' "$inputs" \
		>"$graph/snapshot-admissions" ||
		die "could not inspect reviewed Codex admissions"
	if test "$published_codex" = "$codex_oid"
	then
		test ! -s "$graph/snapshot-admissions" ||
			die "input snapshot records an admission without a pending Codex merge"
		admitted_name=
	else
		test "$(wc -l <"$graph/snapshot-admissions" | tr -d ' ')" = 1 ||
			die "input snapshot does not contain exactly one reviewed Codex admission"
		IFS="$tab" read -r kind admitted_ref admitted_oid admitted_number \
			admitted_merge <"$graph/snapshot-admissions" ||
			die "could not inspect the reviewed Codex admission"
		admitted_name=${admitted_ref#refs/heads/}
		test "$admitted_ref" = "refs/heads/$admitted_name" &&
			is_stable_topic_name "$admitted_name" &&
			test "$admitted_merge" = "$codex_oid" ||
			die "input snapshot contains an invalid reviewed Codex admission"
		snapshot_head=$(awk -F '\t' -v name="$admitted_name" \
			'$1 == name { print $2 }' "$graph/topics")
		test "$snapshot_head" = "$admitted_oid" ||
			die "input snapshot contains an invalid reviewed Codex admission"
		authenticate_pending_codex_merge - "$published_codex" \
			"$codex_oid" "$graph/verified-admission" "$snapshot_head"
		printf '%s\t%s\t%s\t%s\n' "$admitted_name" "$admitted_oid" \
			"$admitted_number" "$admitted_merge" \
			>"$graph/expected-admission"
		cmp -s "$graph/expected-admission" "$graph/verified-admission" ||
			die "input snapshot does not match the reviewed Codex admission"
	fi
	while IFS="$tab" read -r name oid
	do
		if ! awk -F '\t' -v name="$name" '$1 == name { found=1 }
			END { exit !found }' "$graph/published-topics" &&
			test "$name" != "$admitted_name"
		then
			die "input snapshot contains unadmitted Codex topic '$name'"
		fi
	done <"$graph/topics"
	graph_remote=
	git remote >"$graph/remotes" ||
		die "could not inspect remotes for the snapshotted Codex graph"
	while IFS= read -r candidate_remote
	do
		remote_controller=$(git rev-parse --verify \
			"$(remote_ref "$candidate_remote" meta)^{commit}" \
			2>/dev/null || :)
		remote_base=$(git rev-parse --verify \
			"$(remote_ref "$candidate_remote" "$base_name")^{commit}" \
			2>/dev/null || :)
		remote_codex=$(git rev-parse --verify \
			"$(remote_ref "$candidate_remote" "$codex_name")^{commit}" \
			2>/dev/null || :)
		if test "$remote_controller" = "$controller_oid" &&
			test "$remote_base" = "$base_oid" &&
			test "$remote_codex" = "$codex_oid"
		then
			graph_remote=$candidate_remote
			break
		fi
	done <"$graph/remotes"
	test -n "$graph_remote" ||
		die "could not locate the snapshotted Codex remote"
	if test "$config_version" = 1 &&
		git rev-parse --verify \
			"$(remote_ref "$graph_remote" codex-unstable)^{commit}" \
			>/dev/null 2>&1
	then
		die "$meta_config_path does not describe the existing codex-unstable output"
	fi
	printf '%s\n' "$graph_remote" >"$graph/remote"
	reject_unadmitted_topic_history "$graph_remote" "$graph/topics" \
		"$published_codex" "$base_oid" codex "$graph/verified-admission"
	validate_live_codex_delta "$published_codex" \
		"$codex_oid" "$graph/topics" "$graph"
	prepare_stateful_plan "$base_name" "$base_oid" "$graph/topics" \
		"$graph" stable
}

prepare_unstable_input_graph () (
	inputs=$1
	stable_candidate=$2
	stable_graph=$3
	graph=$4
	mkdir -p "$graph" ||
		die "could not prepare unstable input graph verification"
	awk -F '\t' '$1 == "unstable-topic" {
		name=$2
		sub("^refs/heads/", "", name)
		printf "%s\t%s\n", name, $3
	}' "$inputs" | LC_ALL=C sort >"$graph/topics" ||
		die "could not read unstable topics from the input snapshot"
	test "$(cut -f1 "$graph/topics" | sort -u | wc -l | tr -d ' ')" = \
		"$(wc -l <"$graph/topics" | tr -d ' ')" ||
		die "input snapshot contains duplicate unstable Codex topics"
	while IFS="$tab" read -r name oid
	do
		is_unstable_topic_name "$name" ||
			die "input snapshot contains invalid unstable topic '$name'"
		require_full_commit_oid "$oid"
	done <"$graph/topics"
	cp "$stable_graph/published-unstable-topics" \
		"$graph/published-topics" ||
		die "could not retain published unstable topology for verification"
	version=$(state_value "$stable_graph" config-version)
	mode=$(awk -F '\t' '$1 == "lane-mode" { print $3 }' "$inputs")
	unstable_oid=$(awk -F '\t' '$1 == "unstable" { print $3 }' "$inputs")
	test -n "$unstable_oid" ||
		die "unstable topics have no snapshotted output ref"
	if awk -F '\t' '$1 == "unstable-plan" { found=1 }
		END { exit !found }' "$inputs"
	then
		test -z "$mode" ||
			die "pinned unstable plans cannot use a lane mode"
		controller_oid=$(awk -F '\t' '$1 == "controller" { print $3 }' \
			"$inputs")
		codex_oid=$(awk -F '\t' '$1 == "codex" { print $3 }' "$inputs")
		plan_blob=$(awk -F '\t' '$1 == "unstable-plan" { print $3 }' \
			"$inputs")
		test -n "$plan_blob" ||
			die "pinned input snapshot has no unstable plan"
		read_lane_plan "$controller_oid" codex-unstable codex \
			"$codex_oid" - "$graph/plan-topics" "$graph/pinned-plan"
		test "$plan_blob" = "$(state_value "$graph/pinned-plan" plan-blob)" ||
			die "input snapshot does not match its pinned unstable plan blob"
		awk -F '\t' '$1 == "unstable-topic" {
			name=$2
			sub("^refs/heads/", "", name)
			printf "%s\t%s\n", name, $3
		}' "$inputs" >"$graph/snapshot-topics" ||
			die "could not read pinned unstable topics from the input snapshot"
		cmp -s "$graph/snapshot-topics" "$graph/plan-topics" ||
			die "input snapshot topics do not match the pinned unstable plan"
		cp "$graph/plan-topics" "$graph/topics" ||
			die "could not retain pinned unstable topics"
		cp "$stable_graph/published-unstable-source-topics" \
			"$graph/published-source-topics" ||
			die "could not retain published unstable source boundaries"
			cp "$graph/pinned-plan/desired-prerequisites" \
				"$graph/desired-prerequisites" ||
				die "could not retain pinned unstable prerequisites"
			cp "$graph/pinned-plan/desired-source-bases" \
				"$graph/desired-source-bases" ||
				die "could not retain pinned unstable source boundaries"
		cp "$graph/pinned-plan/desired-order" "$graph/desired-order" ||
			die "could not retain pinned unstable order"
		cp "$graph/pinned-plan/plan-blob" "$graph/plan-blob" ||
			die "could not retain pinned unstable plan"
		: >"$graph/pinned-plan-mode"
		printf '%s\n' codex >"$graph/base-name"
		printf '%s\n' "$stable_candidate" >"$graph/base-oid"
		printf '%s\n' codex-unstable >"$graph/codex-name"
		printf '%s\n' "$(state_value "$stable_graph" \
			published-unstable-base-oid)" >"$graph/published-base-oid"
		printf '%s\n' "$(state_value "$stable_graph" \
			published-unstable-oid)" >"$graph/published-codex-oid"
		printf '%s\n' "$codex_oid" >"$graph/source-base-oid"
		test "$unstable_oid" = \
			"$(state_value "$stable_graph" published-unstable-oid)" ||
			die "pinned input snapshot moves generated codex-unstable outside published state"
		if test -s "$graph/topics"
		then
			prepare_pinned_plan codex "$stable_candidate" \
				"$graph/topics" "$graph"
		else
			: >"$graph/plan"
			: >"$graph/results"
		fi
		return
	fi
	awk -F '\t' '$1 == "unstable-admission" { print }' "$inputs" \
		>"$graph/snapshot-admissions" ||
		die "could not inspect reviewed unstable Codex admissions"
	if test "$version" = 2
	then
		! is_null_oid "$unstable_oid" ||
			die "published codex-unstable output is missing"
		published_base=$(state_value "$stable_graph" \
			published-unstable-base-oid)
		published_output=$(state_value "$stable_graph" \
			published-unstable-oid)
		if test "$published_output" = "$unstable_oid"
		then
			test ! -s "$graph/snapshot-admissions" ||
				die "input snapshot records an unstable admission without a pending merge"
			admitted_name=
		else
			test "$(wc -l <"$graph/snapshot-admissions" | tr -d ' ')" = 1 ||
				die "input snapshot does not contain exactly one reviewed unstable admission"
			IFS="$tab" read -r kind admitted_ref admitted_oid \
				admitted_number admitted_merge <"$graph/snapshot-admissions" ||
				die "could not inspect the reviewed unstable Codex admission"
			admitted_name=${admitted_ref#refs/heads/}
			test "$admitted_ref" = "refs/heads/$admitted_name" &&
				is_unstable_topic_name "$admitted_name" &&
				test "$admitted_merge" = "$unstable_oid" ||
				die "input snapshot contains an invalid reviewed unstable admission"
			snapshot_head=$(awk -F '\t' -v name="$admitted_name" \
				'$1 == name { print $2 }' "$graph/topics")
			test "$snapshot_head" = "$admitted_oid" ||
				die "input snapshot contains an invalid reviewed unstable admission"
			authenticate_pending_codex_merge - "$published_output" \
				"$unstable_oid" "$graph/verified-admission" \
				"$snapshot_head" codex-unstable
			printf '%s\t%s\t%s\t%s\n' "$admitted_name" \
				"$admitted_oid" "$admitted_number" "$admitted_merge" \
				>"$graph/expected-admission"
			cmp -s "$graph/expected-admission" \
				"$graph/verified-admission" ||
				die "input snapshot does not match the reviewed unstable admission"
		fi
	else
		test "$mode" = enable && is_null_oid "$unstable_oid" ||
			die "$meta_config_path does not describe the existing codex-unstable output"
		test ! -s "$graph/topics" &&
			test ! -s "$graph/snapshot-admissions" ||
			die "a newly enabled unstable lane cannot enroll unreviewed topics"
		published_base=$(awk -F '\t' '$1 == "codex" { print $3 }' \
			"$inputs")
		published_output=$(null_oid)
		admitted_name=
	fi
	while IFS="$tab" read -r name oid
	do
		if ! awk -F '\t' -v name="$name" '$1 == name { found=1 }
			END { exit !found }' "$graph/published-topics" &&
			test "$name" != "$admitted_name"
		then
			die "input snapshot contains unadmitted unstable topic '$name'"
		fi
	done <"$graph/topics"
	if test "$mode" = disable
	then
		test "$version" = 2 && ! test -s "$graph/topics" &&
			test ! -s "$graph/snapshot-admissions" ||
			die "cannot disable codex-unstable while reviewed topics remain"
	fi
	if test -s "$graph/topics"
	then
		graph_remote=$(state_value "$stable_graph" remote)
		codex_oid=$(awk -F '\t' '$1 == "codex" { print $3 }' "$inputs")
		reject_unadmitted_topic_history "$graph_remote" "$graph/topics" \
			"$published_output" "$codex_oid" codex-unstable \
			"$graph/verified-admission"
		validate_live_codex_delta "$published_output" "$unstable_oid" \
			"$graph/topics" "$graph"
	fi
	printf '%s\n' codex >"$graph/base-name"
	printf '%s\n' "$stable_candidate" >"$graph/base-oid"
	printf '%s\n' codex-unstable >"$graph/codex-name"
	printf '%s\n' "$published_base" >"$graph/published-base-oid"
	printf '%s\n' "$published_output" >"$graph/published-codex-oid"
	if test -s "$graph/topics"
	then
		prepare_stateful_plan codex "$stable_candidate" \
			"$graph/topics" "$graph" unstable
	else
		: >"$graph/plan"
	fi
)

topic_control_paths_unchanged () (
	base_oid=$1
	head_oid=$2
	git diff --quiet "$base_oid" "$head_oid" -- \
		.github/CODEX.md \
		.github/rulesets/codex-branch.json \
		.github/rulesets/codex-meta.json \
		.github/rulesets/codex-pins.json \
		.github/rulesets/codex-pins-immutable.json \
		.github/rulesets/codex-plan-branches.json \
		.github/rulesets/codex-topics.json \
		.github/rulesets/codex-unstable-branch.json \
		.github/workflows/codex-admission.yml \
		.github/workflows/codex-plan-admission.yml \
		.github/workflows/codex-plan-propose.yml \
		.github/workflows/codex-pr-state.sh \
		.github/workflows/codex-pr-state.yml \
		.github/workflows/codex-topic.yml \
		.github/workflows/codex.yml \
		.github/workflows/codex-branch.sh \
		.github/workflows/main.yml \
		codex \
		publish \
		rebuild \
		codex.plan \
		codex-unstable.plan \
		codex.release-recovery \
		codex.config \
		t/t9905-codex-branch.sh &&
	git diff --quiet "$base_oid" "$head_oid" -- \
		':(glob).github/workflows/*.yml' \
		':(glob).github/workflows/*.yaml' \
		':(exclude).github/workflows/codex-release.yml'
)

verify_unstable_control_paths () (
	base_oid=$1
	unstable_candidate=$2
	state=$3

	topic_control_paths_unchanged "$base_oid" "$unstable_candidate" ||
		die "codex-unstable changes a protected controller or CI file"
	git diff --quiet "$base_oid" "$unstable_candidate" -- \
		':(glob).github/workflows/*.yml' \
		':(glob).github/workflows/*.yaml' ||
		die "codex-unstable changes a GitHub Actions workflow"
	release_workflow_is_reviewed "$unstable_candidate" ||
		die "codex-unstable changes the reviewed release trigger"
	while IFS="$tab" read -r name old prerequisite old_base prerequisite_tip
	do
		is_unstable_topic_name "$name" ||
			die "unstable integration contains stable topic '$name'"
		tip=$(result_lookup "$state/results" "$name")
		test -n "$tip" || die "unstable topic '$name' has no rewritten tip"
		prerequisites=$(planned_prerequisites "$state" "$name")
		for prerequisite in $prerequisites
		do
			if test "$prerequisite" != codex
			then
				is_unstable_topic_name "$prerequisite" ||
					die "unstable topic '$name' has non-unstable prerequisite '$prerequisite'"
				dependency=$(result_lookup "$state/results" "$prerequisite")
				test -n "$dependency" ||
					die "unstable topic '$name' has no rewritten prerequisite"
			else
				dependency=$base_oid
			fi
			topic_control_paths_unchanged "$dependency" "$tip" ||
				die "unstable topic '$name' changes a protected controller or CI file"
			git diff --quiet "$dependency" "$tip" -- \
				':(glob).github/workflows/*.yml' \
				':(glob).github/workflows/*.yaml' ||
				die "unstable topic '$name' changes a GitHub Actions workflow"
		done
	done <"$state/plan"
)

validate_pinned_plan_policy () {
	stable_state=$1
	unstable_state=$2
	base_name=$3
	version=$4
	published_state=${5:-$stable_state}
	automation_count=0
	while IFS="$tab" read -r name source_tip prerequisites
	do
		source_base=$(plan_source_base \
			"$stable_state/desired-source-bases" "$name")
		test -n "$source_base" ||
			die "pinned plan has no source boundary for '$name'"
		case "$name" in
		??/codex/automation)
			automation_count=$((automation_count + 1))
			test "$prerequisites" = "$base_name" ||
				die "automation topic '$name' must be based directly on $base_name"
			make_tmp_dir
			git diff --name-only "$source_base" "$source_tip" \
				>"$tmp_dir/automation-paths" ||
				die "could not inspect automation topic '$name'"
			printf '%s\n' .github/workflows/codex.yml \
				>"$tmp_dir/expected-automation-paths"
			cmp -s "$tmp_dir/expected-automation-paths" \
				"$tmp_dir/automation-paths" ||
				die "automation topic '$name' must change only .github/workflows/codex.yml"
			if test "$version" = 3
			then
				automation_workflow_is_current "$source_tip" ||
					die "automation topic '$name' does not contain the current Refresh codex workflow"
			else
				automation_workflow_matches "$source_tip" ||
					die "automation topic '$name' does not contain the canonical Refresh codex workflow"
			fi
			;;
		*)
			topic_control_paths_unchanged "$source_base" "$source_tip" ||
				die "topic '$name' changes a protected controller or CI file"
			;;
		esac
	done <"$stable_state/desired-prerequisites"
	test "$automation_count" = 1 ||
		die "exactly one active ??/codex/automation topic is required"

	test "$unstable_state" = - && return
	while IFS="$tab" read -r name source_tip prerequisites
	do
		source_base=$(plan_source_base \
			"$unstable_state/desired-source-bases" "$name")
		test -n "$source_base" ||
			die "pinned unstable plan has no source boundary for '$name'"
		topic_control_paths_unchanged "$source_base" "$source_tip" ||
			die "unstable topic '$name' changes a protected controller or CI file"
		git diff --quiet "$source_base" "$source_tip" -- \
			':(glob).github/workflows/*.yml' \
			':(glob).github/workflows/*.yaml' ||
			die "unstable topic '$name' changes a GitHub Actions workflow"
	done <"$unstable_state/desired-prerequisites"
	validate_lane_isolation "$stable_state" \
		"$stable_state/desired-prerequisites" \
		"$unstable_state/desired-prerequisites" - \
		"$unstable_state/desired-source-bases" \
		"$published_state"
}

verify_control_paths () {
	inputs=$1
	updates=$2
	candidate=$3
	graph=$4
	require_automation=$5
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	base_ref=$(awk -F '\t' '$1 == "base" { print $2 }' "$inputs")
	base_name=${base_ref#refs/heads/}
	if test -f "$graph/published-codex-oid"
	then
		published_codex=$(state_value "$graph" published-codex-oid)
		release_publication_controls_preserved "$published_codex" \
			"$candidate" ||
			die "candidate changes the controller-only release publication guard"
		if automation_workflow_is_latest "$published_codex" &&
			! automation_workflow_is_latest "$candidate"
		then
			die "candidate downgrades the canonical Codex admission workflow"
		fi
		if automation_workflow_is_current "$published_codex" &&
			! automation_workflow_is_current "$candidate"
		then
			die "candidate downgrades the canonical Codex admission workflow"
		fi
		if automation_workflow_is_reviewed "$published_codex" &&
			! automation_workflow_is_reviewed "$candidate"
		then
			die "candidate downgrades the canonical Codex admission workflow"
		fi
	fi

	if test -z "$require_automation" &&
		! test -f "$graph/pinned-plan-mode"
	then
		legacy_control_paths_unchanged "$base_oid" "$candidate" ||
			die "candidate changes meta-only controller files"
		return
	fi

	if test -f "$graph/pinned-plan-mode"
	then
		meta_control_paths_unchanged "$base_oid" "$candidate" ||
			die "candidate changes a protected controller or CI file"
		automation_workflow_matches "$candidate" ||
			die "candidate does not contain the canonical Refresh codex workflow"
		release_workflow_is_reviewed "$candidate" ||
			die "candidate release workflow must use the reviewed Codex branch triggers and must not obtain promotion credentials"
		automation_count=0
		while IFS="$tab" read -r name source_tip prerequisites
		do
			source_base=$(plan_source_base \
				"$graph/desired-source-bases" "$name")
			test -n "$source_base" ||
				die "pinned plan has no source boundary for '$name'"
			case "$name" in
			??/codex/automation)
				automation_count=$((automation_count + 1))
				test "$prerequisites" = master ||
					die "automation topic '$name' must be based directly on master"
				make_tmp_dir
				git diff --name-only "$source_base" "$source_tip" \
					>"$tmp_dir/automation-paths" ||
					die "could not inspect automation topic '$name'"
				printf '%s\n' .github/workflows/codex.yml \
					>"$tmp_dir/expected-automation-paths"
				cmp -s "$tmp_dir/expected-automation-paths" \
					"$tmp_dir/automation-paths" ||
					die "automation topic '$name' must change only .github/workflows/codex.yml"
				if test "$(state_value "$graph" config-version)" != 3
				then
					automation_workflow_is_current "$source_tip" ||
						die "pre-v3 pinned plan must pin the current automation workflow before refresh"
				else
					automation_workflow_matches "$source_tip" ||
						die "automation topic '$name' does not contain the canonical Refresh codex workflow"
				fi
				continue
				;;
			esac
			topic_control_paths_unchanged "$source_base" "$source_tip" ||
				die "topic '$name' changes a protected controller or CI file"
		done <"$graph/desired-prerequisites"
		test "$automation_count" = 1 ||
			die "exactly one active ??/codex/automation topic is required"
		return
	fi

	meta_control_paths_unchanged "$base_oid" "$candidate" ||
		die "candidate changes a protected controller or CI file"
	automation_workflow_matches "$candidate" ||
		die "candidate does not contain the canonical Refresh codex workflow"
	release_workflow_is_reviewed "$candidate" ||
		die "candidate release workflow must use the reviewed Codex branch triggers and must not obtain promotion credentials"

	automation_count=0
	while IFS="$tab" read -r ref old new
	do
		case "$ref" in
		refs/heads/meta|refs/heads/codex|refs/heads/codex-unstable) continue ;;
		refs/heads/??/codex/*-unstable) continue ;;
		esac
		name=${ref#refs/heads/}
		plan_row=$(awk -F '\t' -v name="$name" '$1 == name { print; exit }' \
			"$graph/plan")
		test -n "$plan_row" ||
			die "input graph has no rewrite range for '$ref'"
		IFS="$tab" read -r canonical_name plan_old prerequisite old_base prerequisite_tip <<-EOF
		$plan_row
		EOF
		prerequisites=$(planned_prerequisites "$graph" "$name")

		case "$name" in
		??/codex/automation)
			automation_count=$((automation_count + 1))
			test "$prerequisites" = master ||
				die "automation topic '$name' must be based directly on master"
			dependency_new=$base_oid
			make_tmp_dir
			git diff --name-only "$dependency_new" "$new" \
				>"$tmp_dir/automation-paths" ||
				die "could not inspect automation topic '$name'"
			printf '%s\n' .github/workflows/codex.yml \
				>"$tmp_dir/expected-automation-paths"
			cmp -s "$tmp_dir/expected-automation-paths" \
				"$tmp_dir/automation-paths" ||
				die "automation topic '$name' must change only .github/workflows/codex.yml"
			automation_workflow_matches "$new" ||
				die "automation topic '$name' does not contain the canonical Refresh codex workflow"
			;;
		*)
			for prerequisite in $prerequisites
			do
				if test "$prerequisite" = "$base_name"
				then
					dependency_new=$base_oid
				else
					dependency_ref=refs/heads/$prerequisite
					dependency_new=$(awk -F '\t' -v ref="$dependency_ref" \
						'$1 == ref { print $3 }' "$updates")
					test -n "$dependency_new" ||
						die "updates do not contain prerequisite '$dependency_ref'"
				fi
				topic_control_paths_unchanged "$dependency_new" "$new" ||
					die "topic '$name' changes a protected controller or CI file"
			done
			;;
		esac
	done <"$updates"
	test "$automation_count" = 1 ||
		die "exactly one active ??/codex/automation topic is required"
}

candidate_generated_tip () (
	base_oid=$1
	head_oid=$2
	name=$3
	for commit in $(git rev-list --first-parent --reverse \
		"$base_oid..$head_oid")
	do
		marker=$(git show -s \
			--format='%(trailers:key=Codex-Integration,valueonly)' \
			"$commit") || return 1
		case "$marker" in
		"$name@"*)
			set -- $(git show -s --format=%P "$commit")
			test $# = 2 || return 1
			printf '%s\n' "$2"
			return 0
			;;
		esac
	done
	return 1
)

verify_meta_update () (
	inputs=$1
	updates=$2
	candidate=$3
	graph=$4
	unstable_graph=${5:-}
	unstable_candidate=${6:-}
	old_meta=$(awk -F '\t' '$1 == "controller" { print $3 }' "$inputs")
	new_meta=$(awk -F '\t' '$1 == "refs/heads/meta" { print $3 }' "$updates")
	test -n "$new_meta" || die "updates contain no meta state commit"
	resolve_commit "$new_meta" >/dev/null
	if test "$new_meta" != "$old_meta"
	then
		parents=$(git show -s --format=%P "$new_meta") ||
			die "could not inspect the next meta state commit"
		test "$parents" = "$old_meta" ||
			die "next meta state is not a direct child of the pinned controller"
		git diff-tree --no-commit-id --name-only -r \
			"$old_meta" "$new_meta" >"$graph/meta-changed-paths" ||
			die "could not inspect changed meta paths"
		printf '%s\n' "$meta_config_path" >"$graph/expected-meta-changed-paths"
		cmp -s "$graph/meta-changed-paths" \
			"$graph/expected-meta-changed-paths" ||
			die "next meta state changes more than $meta_config_path"
	fi
	git ls-tree "$new_meta" -- "$meta_config_path" \
		>"$graph/meta-config-entry" ||
		die "could not inspect $meta_config_path in the next meta state"
	awk -v path="$meta_config_path" '
		{
			actual=$0
			sub(/^[^\t]*\t/, "", actual)
			if ($1 == "100644" && $2 == "blob" && actual == path)
				valid++
		}
		END { exit !(NR == 1 && valid == 1) }
	' "$graph/meta-config-entry" ||
		die "next meta state must contain $meta_config_path as one regular blob"

	if test -f "$graph/pinned-plan-mode"
	then
		: >"$graph/expected-meta-v3-topics"
		while IFS="$tab" read -r name source_tip
		do
			generated_tip=$(candidate_generated_tip \
				"$(state_value "$graph" base-oid)" "$candidate" "$name") ||
				die "candidate has no generated integration for '$name'"
			prerequisites=$(plan_prerequisites \
				"$graph/desired-prerequisites" "$name")
			printf '%s\t%s\t%s\t%s\n' "$name" "$source_tip" \
				"$generated_tip" "$prerequisites" \
				>>"$graph/expected-meta-v3-topics"
		done <"$graph/topics"
		LC_ALL=C sort -o "$graph/expected-meta-v3-topics" \
			"$graph/expected-meta-v3-topics"
		base_ref=$(awk -F '\t' '$1 == "base" { print $2 }' "$inputs")
		base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
		codex_ref=$(awk -F '\t' '$1 == "codex" { print $2 }' "$inputs")
		base_name=${base_ref#refs/heads/}
		codex_name=${codex_ref#refs/heads/}
		plan_blob=$(awk -F '\t' '$1 == "plan" { print $3 }' "$inputs")
		test -n "$plan_blob" ||
			die "pinned input snapshot has no production plan blob"
		if test -n "$unstable_candidate" &&
			! is_null_oid "$unstable_candidate"
		then
			test -n "$unstable_graph" ||
				die "unstable output has no verified pinned graph"
			: >"$graph/expected-meta-v3-unstable-topics"
			while IFS="$tab" read -r name source_tip
			do
				generated_tip=$(candidate_generated_tip "$candidate" \
					"$unstable_candidate" "$name") ||
					die "unstable candidate has no generated integration for '$name'"
				prerequisites=$(plan_prerequisites \
					"$unstable_graph/desired-prerequisites" "$name")
				printf '%s\t%s\t%s\t%s\n' "$name" \
					"$source_tip" "$generated_tip" "$prerequisites" \
					>>"$graph/expected-meta-v3-unstable-topics"
			done <"$unstable_graph/topics"
			LC_ALL=C sort -o "$graph/expected-meta-v3-unstable-topics" \
				"$graph/expected-meta-v3-unstable-topics"
			unstable_plan_blob=$(awk -F '\t' \
				'$1 == "unstable-plan" { print $3 }' "$inputs")
			test -n "$unstable_plan_blob" ||
				die "pinned input snapshot has no unstable plan blob"
			write_meta_config_v3 "$base_name" "$base_oid" "$codex_name" \
				"$candidate" "$graph/expected-meta-v3-topics" \
				"$graph/expected-meta-config" "$plan_blob" \
				"$graph/expected-meta-v3-unstable-topics" \
				"$candidate" "$unstable_candidate" \
				"$unstable_plan_blob"
		else
			write_meta_config_v3 "$base_name" "$base_oid" "$codex_name" \
				"$candidate" "$graph/expected-meta-v3-topics" \
				"$graph/expected-meta-config" "$plan_blob"
		fi
		git show "$new_meta:$meta_config_path" \
			>"$graph/actual-meta-config" 2>/dev/null ||
			die "next meta state has no $meta_config_path"
		cmp -s "$graph/expected-meta-config" \
			"$graph/actual-meta-config" ||
			die "next meta state does not describe the verified pinned output"
		return
	fi

	: >"$graph/expected-meta-topics"
	while IFS="$tab" read -r name old
	do
		ref=refs/heads/$name
		new=$(awk -F '\t' -v ref="$ref" '$1 == ref { print $3 }' "$updates")
		test -n "$new" || die "updates contain no rewritten tip for '$name'"
		prerequisites=$(planned_prerequisites "$graph" "$name")
		test -n "$prerequisites" ||
			die "verified graph contains no prerequisite for '$name'"
		printf '%s\t%s\t%s\n' "$name" "$new" "$prerequisites" \
			>>"$graph/expected-meta-topics"
	done <"$graph/topics"
	LC_ALL=C sort -o "$graph/expected-meta-topics" \
		"$graph/expected-meta-topics"
	base_ref=$(awk -F '\t' '$1 == "base" { print $2 }' "$inputs")
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	codex_ref=$(awk -F '\t' '$1 == "codex" { print $2 }' "$inputs")
	base_name=${base_ref#refs/heads/}
	codex_name=${codex_ref#refs/heads/}
	if test -n "$unstable_candidate" &&
		! is_null_oid "$unstable_candidate"
	then
		test -n "$unstable_graph" ||
			die "unstable output has no verified topic graph"
		: >"$graph/expected-meta-unstable-topics"
		while IFS="$tab" read -r name old
		do
			ref=refs/heads/$name
			new=$(awk -F '\t' -v ref="$ref" \
				'$1 == ref { print $3 }' "$updates")
			test -n "$new" ||
				die "updates contain no rewritten unstable tip for '$name'"
			prerequisites=$(planned_prerequisites "$unstable_graph" "$name")
			test -n "$prerequisites" ||
				die "verified unstable graph contains no prerequisite for '$name'"
			printf '%s\t%s\t%s\n' "$name" "$new" "$prerequisites" \
				>>"$graph/expected-meta-unstable-topics"
		done <"$unstable_graph/topics"
		LC_ALL=C sort -o "$graph/expected-meta-unstable-topics" \
			"$graph/expected-meta-unstable-topics"
		write_meta_config "$base_name" "$base_oid" "$codex_name" \
			"$candidate" "$graph/expected-meta-topics" \
			"$graph/expected-meta-config" \
			"$graph/expected-meta-unstable-topics" \
			"$candidate" "$unstable_candidate"
	else
		write_meta_config "$base_name" "$base_oid" "$codex_name" \
			"$candidate" "$graph/expected-meta-topics" \
			"$graph/expected-meta-config"
	fi
	git show "$new_meta:$meta_config_path" >"$graph/actual-meta-config" \
		2>/dev/null || die "next meta state has no $meta_config_path"
	cmp -s "$graph/expected-meta-config" "$graph/actual-meta-config" ||
		die "next meta state does not describe the verified Codex output"
)

verify_output () {
	inputs=
	updates=
	result=
	require_automation=
	stable_recovery=
	while test $# -gt 0
	do
		case "$1" in
		--inputs) require_arg "$@"; inputs=$2; shift 2 ;;
		--updates) require_arg "$@"; updates=$2; shift 2 ;;
		--result) require_arg "$@"; result=$2; shift 2 ;;
		--require-automation) require_automation=t; shift ;;
		--stable-recovery) stable_recovery=t; shift ;;
		*) die "unknown verify-output option '$1'" ;;
		esac
	done
	test -n "$inputs" && test -f "$inputs" || die "verify-output requires --inputs"
	test -n "$updates" && test -f "$updates" || die "verify-output requires --updates"
	test -n "$result" && test -f "$result" || die "verify-output requires --result"
	make_tmp_dir
	require_full_repository

	candidate=$(resolve_commit "$(sed -n '1p' "$result")")
	test "$(awk -F '\t' '$1 == "refs/heads/codex" { print $3 }' "$updates")" = "$candidate" ||
		die "candidate does not match the codex update"
	unstable_candidate=$(awk -F '\t' \
		'$1 == "refs/heads/codex-unstable" { print $3 }' "$updates")
	unstable_input=$(awk -F '\t' '$1 == "unstable" { print $3 }' \
		"$inputs")
	lane_mode=$(awk -F '\t' '$1 == "lane-mode" { print $3 }' "$inputs")
	unstable_topic_count=$(awk -F '\t' \
		'$1 == "unstable-topic" { count++ } END { print count + 0 }' \
		"$inputs")
	if test -n "$stable_recovery"
	then
		test -n "$unstable_input" &&
			! is_null_oid "$unstable_input" &&
			test -z "$unstable_candidate" &&
			test -z "$lane_mode" ||
			die "production recovery cannot change its enabled unstable lane"
		test "$(awk -F '\t' '$1 == "unstable-admission" { count++ }
			END { print count + 0 }' "$inputs")" = 0 ||
			die "production recovery cannot bypass a pending unstable admission"
	elif test -z "$unstable_input"
	then
		test -z "$unstable_candidate" && test "$unstable_topic_count" = 0 &&
			test -z "$lane_mode" ||
			die "disabled unstable lane has unsnapshotted output or topics"
	elif test "$lane_mode" = enable
	then
		is_null_oid "$unstable_input" &&
			test -n "$unstable_candidate" &&
			! is_null_oid "$unstable_candidate" &&
			test "$unstable_topic_count" = 0 ||
			die "enabling codex-unstable requires an empty reviewed sentinel"
	elif test "$lane_mode" = disable
	then
		! is_null_oid "$unstable_input" &&
			is_null_oid "$unstable_candidate" &&
			test "$unstable_topic_count" = 0 ||
			die "disabling codex-unstable requires an empty published lane"
	else
		! is_null_oid "$unstable_input" &&
			test -n "$unstable_candidate" &&
			! is_null_oid "$unstable_candidate" ||
			die "enabled unstable lane must retain its generated output"
	fi
	LC_ALL=C sort -c "$updates" || die "updates are not canonically sorted"
	test "$(cut -f1 "$updates" | sort -u | wc -l | tr -d ' ')" = \
		"$(wc -l <"$updates" | tr -d ' ')" || die "updates contain duplicate refs"
	pinned_inputs=$(awk -F '\t' '$1 == "plan" { print $3 }' "$inputs")
	awk -F '\t' -v recovery="$stable_recovery" -v pinned="$pinned_inputs" '
		$1 == "controller" || $1 == "codex" ||
		(pinned == "" && $1 == "topic") ||
		(recovery == "" && ($1 == "unstable" ||
			(pinned == "" && $1 == "unstable-topic"))) {
			print $2
		}
	' "$inputs" \
		| LC_ALL=C sort >"$tmp_dir/expected-update-refs"
	cut -f1 "$updates" | LC_ALL=C sort >"$tmp_dir/actual-update-refs"
	cmp -s "$tmp_dir/expected-update-refs" "$tmp_dir/actual-update-refs" ||
		die "updates do not cover exactly every snapshotted output and topic"
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	test -n "$base_oid" || die "input snapshot has no base commit"
	prepare_input_graph "$inputs" "$tmp_dir/topic-graph"
	if test -n "$lane_mode"
	then
		input_codex=$(awk -F '\t' '$1 == "codex" { print $3 }' "$inputs")
		published_codex=$(state_value "$tmp_dir/topic-graph" \
			published-codex-oid)
		test "$candidate" = "$input_codex" &&
			test "$input_codex" = "$published_codex" ||
			die "changing the codex-unstable lane cannot publish a production update"
	fi
	unstable_graph=
	if test -n "$unstable_input" && test -z "$stable_recovery"
	then
		unstable_graph=$tmp_dir/unstable-topic-graph
		prepare_unstable_input_graph "$inputs" "$candidate" \
			"$tmp_dir/topic-graph" "$unstable_graph"
	fi
	if test -f "$tmp_dir/topic-graph/pinned-plan-mode" &&
		test -n "$unstable_graph" &&
		test -f "$unstable_graph/pinned-plan-mode"
	then
		validate_lane_isolation "$tmp_dir/topic-graph" \
			"$tmp_dir/topic-graph/topics" \
			"$unstable_graph/topics" "$candidate" \
			"$unstable_graph/desired-source-bases"
	fi
	git merge-base --is-ancestor "$base_oid" "$candidate" ||
		die "candidate is not based on the snapshotted master"
	if test -n "$stable_recovery"
	then
		test "$(state_value "$tmp_dir/topic-graph" config-version)" = 2 &&
			test "$unstable_input" = "$(state_value \
			"$tmp_dir/topic-graph" published-unstable-oid)" ||
			die "production recovery cannot change the published unstable output"
		old_meta=$(awk -F '\t' '$1 == "controller" { print $3 }' \
			"$inputs")
		new_meta=$(awk -F '\t' '$1 == "refs/heads/meta" { print $3 }' \
			"$updates")
		test "$old_meta" = "$new_meta" ||
			die "production recovery cannot change published meta state"
	else
		verify_meta_update "$inputs" "$updates" "$candidate" \
			"$tmp_dir/topic-graph" "$unstable_graph" "$unstable_candidate"
	fi
	verify_control_paths "$inputs" "$updates" "$candidate" \
		"$tmp_dir/topic-graph" "$require_automation"
	while IFS="$tab" read -r ref old new
	do
		git check-ref-format "$ref" >/dev/null || die "invalid update ref '$ref'"
		expected_old=$(awk -F '\t' -v ref="$ref" \
			'($1 == "controller" || $1 == "codex" ||
			  $1 == "topic" || $1 == "unstable" ||
			  $1 == "unstable-topic") && $2 == ref { print $3 }' \
			"$inputs")
		test "$old" = "$expected_old" ||
			die "old value for '$ref' does not match the input snapshot"
		if ! is_null_oid "$old"
		then
			resolve_commit "$old" >/dev/null
		fi
		if ! is_null_oid "$new"
		then
			require_full_commit_oid "$new"
		fi
		case "$ref" in
		refs/heads/meta) ;;
		refs/heads/codex) ;;
		refs/heads/codex-unstable)
			if ! is_null_oid "$new"
			then
				git merge-base --is-ancestor "$candidate" "$new" ||
					die "codex-unstable does not contain its exact codex candidate"
				test "$new" != "$candidate" ||
					die "codex-unstable is not strictly ahead of codex"
			fi
			;;
		refs/heads/??/codex/*-unstable)
			if test -n "$unstable_graph" &&
				test -f "$unstable_graph/pinned-plan-mode"
			then
				test "$new" = "$old" ||
					die "pinned unstable source ref '$ref' must be a no-op lease"
				continue
			fi
			test -n "$unstable_candidate" &&
				! is_null_oid "$unstable_candidate" ||
				die "unstable topic update has no unstable output"
			git merge-base --is-ancestor "$candidate" "$new" ||
				die "rewritten '$ref' is not based on codex"
			git merge-base --is-ancestor "$new" "$unstable_candidate" ||
				die "codex-unstable does not contain '$ref'"
			;;
		refs/heads/??/codex/?*)
			is_stable_topic_name "${ref#refs/heads/}" ||
				die "unstable topic '$ref' entered the stable update set"
			if test -f "$tmp_dir/topic-graph/pinned-plan-mode"
			then
				test "$new" = "$old" ||
					die "pinned source ref '$ref' must be a no-op lease"
				continue
			fi
			git merge-base --is-ancestor "$base_oid" "$new" ||
				die "rewritten '$ref' is not based on master"
			git merge-base --is-ancestor "$new" "$candidate" ||
				die "candidate does not contain '$ref'"
			;;
		*) die "unexpected update ref '$ref'" ;;
		esac
	done <"$updates"
	if ! test -f "$tmp_dir/topic-graph/pinned-plan-mode"
	then
		while IFS="$tab" read -r name old prerequisite old_base prerequisite_tip
		do
			ref=refs/heads/$name
			new=$(awk -F '\t' -v ref="$ref" '$1 == ref { print $3 }' \
				"$updates")
			prerequisites=$(planned_prerequisites "$tmp_dir/topic-graph" "$name")
			for prerequisite in $prerequisites
			do
				if test "$prerequisite" = "$base_name"
				then
					new_prerequisite=$base_oid
				else
					prerequisite_ref=refs/heads/$prerequisite
					new_prerequisite=$(awk -F '\t' -v ref="$prerequisite_ref" \
						'$1 == ref { print $3 }' "$updates")
					test -n "$new_prerequisite" ||
						die "updates contain no configured prerequisite '$prerequisite_ref'"
				fi
				git merge-base --is-ancestor "$new_prerequisite" "$new" ||
					die "rewrite lost configured dependency '$prerequisite' -> '$name'"
			done
		done <"$tmp_dir/topic-graph/plan"
	fi

	# Reconstruct the canonical integration order independently from the
	# artifact producer.  The source trees alone cannot prove that every topic
	# has its own explicit merge, because contained and empty topics make no
	# tree change.
	printf '%s\n' "$base_name" >"$tmp_dir/topic-graph/base-name" ||
		die "could not prepare integration verification"
	printf '%s\n' "$base_oid" >"$tmp_dir/topic-graph/base-oid" ||
		die "could not prepare integration base verification"
	printf '%s\n' codex >"$tmp_dir/topic-graph/codex-name" ||
		die "could not prepare integration output verification"
	: >"$tmp_dir/topic-graph/results" ||
		die "could not prepare rewritten topic verification"
	while IFS="$tab" read -r name old
	do
		if test -f "$tmp_dir/topic-graph/pinned-plan-mode"
		then
			new=$(candidate_generated_tip "$base_oid" "$candidate" "$name") ||
				die "candidate has no generated tip for pinned topic '$name'"
		else
			ref=refs/heads/$name
			new=$(awk -F '\t' -v ref="$ref" '$1 == ref { print $3 }' \
				"$updates")
			test -n "$new" ||
				die "updates contain no rewritten tip for '$name'"
		fi
		result_record "$tmp_dir/topic-graph/results" "$name" "$new"
	done <"$tmp_dir/topic-graph/topics"
	if test -f "$tmp_dir/topic-graph/pinned-plan-mode"
	then
		while IFS="$tab" read -r name old prerequisite old_base prerequisite_tip
		do
			new=$(result_lookup "$tmp_dir/topic-graph/results" "$name")
			prerequisites=$(planned_prerequisites "$tmp_dir/topic-graph" "$name")
			for prerequisite in $prerequisites
			do
				if test "$prerequisite" = "$base_name"
				then
					new_prerequisite=$base_oid
				else
					new_prerequisite=$(result_lookup \
						"$tmp_dir/topic-graph/results" "$prerequisite")
					test -n "$new_prerequisite" ||
						die "pinned topic '$name' has no generated prerequisite '$prerequisite'"
				fi
				git merge-base --is-ancestor "$new_prerequisite" "$new" ||
					die "pinned rewrite lost dependency '$prerequisite' -> '$name'"
			done
		done <"$tmp_dir/topic-graph/plan"
	fi
	if test -f "$tmp_dir/topic-graph/merge-graph"
	then
		verify_merge_topology "$base_oid" "$tmp_dir/topic-graph"
	fi
	write_integration_topics "$tmp_dir/topic-graph"
	codex_has_expected_integrations "$tmp_dir/topic-graph" "$candidate" ||
		die "candidate does not contain one canonical integration merge per topic"
	if test -n "$unstable_graph"
	then
		if is_null_oid "$unstable_candidate"
		then
			return 0
		fi
		: >"$unstable_graph/results" ||
			die "could not prepare rewritten unstable topic verification"
		while IFS="$tab" read -r name old
		do
			if test -f "$unstable_graph/pinned-plan-mode"
			then
				new=$(candidate_generated_tip "$candidate" \
					"$unstable_candidate" "$name") ||
					die "unstable candidate has no generated tip for pinned topic '$name'"
			else
				ref=refs/heads/$name
				new=$(awk -F '\t' -v ref="$ref" \
					'$1 == ref { print $3 }' "$updates")
				test -n "$new" ||
					die "updates contain no rewritten unstable tip for '$name'"
			fi
			result_record "$unstable_graph/results" "$name" "$new"
		done <"$unstable_graph/topics"
		if test -f "$unstable_graph/merge-graph"
		then
			verify_merge_topology "$candidate" "$unstable_graph"
		fi
		while IFS="$tab" read -r name old prerequisite old_base prerequisite_tip
		do
			new=$(result_lookup "$unstable_graph/results" "$name")
			prerequisites=$(planned_prerequisites "$unstable_graph" "$name")
			for prerequisite in $prerequisites
			do
				if test "$prerequisite" = codex
				then
					new_prerequisite=$candidate
				else
					new_prerequisite=$(result_lookup \
						"$unstable_graph/results" "$prerequisite")
					test -n "$new_prerequisite" ||
						die "unstable topic '$name' has no rewritten prerequisite '$prerequisite'"
				fi
				git merge-base --is-ancestor "$new_prerequisite" "$new" ||
					die "unstable rewrite lost dependency '$prerequisite' -> '$name'"
			done
		done <"$unstable_graph/plan"
		if test -s "$unstable_graph/topics"
		then
			write_integration_topics "$unstable_graph"
			codex_has_expected_integrations "$unstable_graph" \
				"$unstable_candidate" ||
				die "codex-unstable does not contain one canonical integration merge per topic"
		else
			unstable_sentinel_is_canonical "$candidate" \
				"$unstable_candidate" ||
				die "empty codex-unstable output is not its canonical sentinel"
		fi
		verify_unstable_control_paths "$candidate" \
			"$unstable_candidate" "$unstable_graph"
	fi
}

push_updates () {
	remote=$1
	updates=$2
	filter=$3

	set -- git -c core.hooksPath=/dev/null push --atomic --porcelain
	while IFS="$tab" read -r ref old new
	do
		case "$filter:$ref" in
		topics:refs/heads/meta|topics:refs/heads/codex|topics:refs/heads/codex-unstable) continue ;;
		esac
		if is_null_oid "$old"
		then
			set -- "$@" "--force-with-lease=$ref:"
		else
			set -- "$@" "--force-with-lease=$ref:$old"
		fi
	done <"$updates"
	set -- "$@" "$remote"
	while IFS="$tab" read -r ref old new
	do
		case "$filter:$ref" in
		topics:refs/heads/meta|topics:refs/heads/codex|topics:refs/heads/codex-unstable) continue ;;
		esac
		if is_null_oid "$new"
		then
			set -- "$@" ":$ref"
		else
			set -- "$@" "$new:$ref"
		fi
	done <"$updates"
	"$@"
}

staging_ref () {
	name=$1
	git check-ref-format "refs/heads/$name" >/dev/null 2>&1 ||
		die "invalid staging branch '$name'"
	case "$name" in
	??/codex/*|codex|codex-unstable|master|meta)
		die "staging branch '$name' overlaps a protected input or output"
		;;
	esac
	printf 'refs/heads/%s\n' "$name"
}

remote_head_oid () {
	remote=$1
	ref=$2
	git ls-remote --refs "$remote" "$ref" |
		awk -v ref="$ref" '$2 == ref { print $1; exit }'
}

published_updates_match () (
	remote=$1
	updates=$2
	staging=$3
	unstable_staging=$(staging_ref codex-unstable-staging)
	refs=$tmp_dir/published-update-refs

	set -- git ls-remote --refs "$remote" "$staging" "$unstable_staging"
	while IFS="$tab" read -r ref old new
	do
		set -- "$@" "$ref"
	done <"$updates"
	"$@" >"$refs" || return 1

	for ref in "$staging" "$unstable_staging"
	do
		if awk -v ref="$ref" '$2 == ref { found=1 }
			END { exit !found }' "$refs"
		then
			return 1
		fi
	done
	while IFS="$tab" read -r ref old new
	do
		current=$(awk -v ref="$ref" '$2 == ref { print $1; exit }' \
			"$refs")
		if is_null_oid "$new"
		then
			test -z "$current" || return 1
		else
			test "$current" = "$new" || return 1
		fi
	done <"$updates"
)

stage_candidate () {
	remote=origin
	staging=codex-staging
	inputs=
	updates=
	require_automation=
	while test $# -gt 0
	do
		case "$1" in
		--remote) require_arg "$@"; remote=$2; shift 2 ;;
		--staging) require_arg "$@"; staging=$2; shift 2 ;;
		--inputs) require_arg "$@"; inputs=$2; shift 2 ;;
		--updates) require_arg "$@"; updates=$2; shift 2 ;;
		--require-automation) require_automation=t; shift ;;
		*) die "unknown stage option '$1'" ;;
		esac
	done
	test -n "$inputs" && test -n "$updates" ||
		die "stage requires --inputs and --updates"
	test -f "$inputs" || die "input snapshot '$inputs' does not exist"
	test -f "$updates" || die "update manifest '$updates' does not exist"
	make_tmp_dir
	stable_candidate=$(awk -F '\t' \
		'$1 == "refs/heads/codex" { print $3 }' "$updates")
	test -n "$stable_candidate" ||
		die "update manifest has no codex candidate"
	if test "$staging" = codex-unstable-staging
	then
		candidate=$(awk -F '\t' \
			'$1 == "refs/heads/codex-unstable" { print $3 }' \
			"$updates")
		test -n "$candidate" && ! is_null_oid "$candidate" ||
			die "update manifest has no codex-unstable candidate"
	else
		candidate=$stable_candidate
	fi
	stage_target=$candidate
	printf '%s\n' "$stable_candidate" >"$tmp_dir/stage-result" ||
		die "could not prepare staging verification"
	set -- --inputs "$inputs" --updates "$updates" \
		--result "$tmp_dir/stage-result"
	test -z "$require_automation" || set -- "$@" --require-automation
	verify_output "$@"
	verify_inputs --remote "$remote" "$inputs"
	ref=$(staging_ref "$staging")
	old=$(remote_head_oid "$remote" "$ref")

	# A failed CI run intentionally leaves staging behind. Recreate an
	# identical ref so a new user-authenticated push starts fresh push CI.
	if test -n "$old" && test "$old" = "$stage_target"
	then
		git -c core.hooksPath=/dev/null push --atomic --porcelain \
			"--force-with-lease=$ref:$old" "$remote" ":$ref"
		old=
	fi
	git -c core.hooksPath=/dev/null push --atomic --porcelain \
		"--force-with-lease=$ref:$old" "$remote" "$stage_target:$ref"
}

promote_updates () {
	remote=$1
	updates=$2
	ref=$3
	candidate=$4
	unstable_ref=${5:-}
	unstable_candidate=${6:-}

	set -- git -c core.hooksPath=/dev/null push --atomic --porcelain
	while IFS="$tab" read -r update_ref old new
	do
		if is_null_oid "$old"
		then
			set -- "$@" "--force-with-lease=$update_ref:"
		else
			set -- "$@" "--force-with-lease=$update_ref:$old"
		fi
	done <"$updates"
	set -- "$@" "--force-with-lease=$ref:$candidate"
	if test -n "$unstable_ref"
	then
		set -- "$@" \
			"--force-with-lease=$unstable_ref:$unstable_candidate"
	fi
	set -- "$@" "$remote"
	while IFS="$tab" read -r update_ref old new
	do
		if is_null_oid "$new"
		then
			set -- "$@" ":$update_ref"
		else
			set -- "$@" "$new:$update_ref"
		fi
	done <"$updates"
	set -- "$@" ":$ref"
	test -z "$unstable_ref" || set -- "$@" ":$unstable_ref"
	"$@"
}

promote () {
	remote=origin
	staging=codex-staging
	inputs=
	updates=
	require_automation=
	while test $# -gt 0
	do
		case "$1" in
		--remote) require_arg "$@"; remote=$2; shift 2 ;;
		--staging) require_arg "$@"; staging=$2; shift 2 ;;
		--inputs) require_arg "$@"; inputs=$2; shift 2 ;;
		--updates) require_arg "$@"; updates=$2; shift 2 ;;
		--require-automation) require_automation=t; shift ;;
		*) die "unknown promote option '$1'" ;;
		esac
	done
	test -n "$inputs" && test -n "$updates" ||
		die "promote requires --inputs and --updates"
	test -f "$inputs" || die "input snapshot '$inputs' does not exist"
	test -f "$updates" || die "update manifest '$updates' does not exist"
	make_tmp_dir
	candidate=$(awk -F '\t' '$1 == "refs/heads/codex" { print $3 }' \
		"$updates")
	test -n "$candidate" || die "update manifest has no codex candidate"
	ref=$(staging_ref "$staging")
	if published_updates_match "$remote" "$updates" "$ref"
	then
		say "Codex candidate $candidate was already published; all output refs match and staging is absent."
		return 0
	fi
	printf '%s\n' "$candidate" >"$tmp_dir/promote-result" ||
		die "could not prepare promotion verification"
	set -- --inputs "$inputs" --updates "$updates" \
		--result "$tmp_dir/promote-result"
	test -z "$require_automation" || set -- "$@" --require-automation
	verify_output "$@"
	# Keep the remote snapshot check next to the staging read and atomic push.
	verify_inputs --remote "$remote" "$inputs"
	ref=$(staging_ref "$staging")
	staged=$(remote_head_oid "$remote" "$ref")
	test "$staged" = "$candidate" ||
		die "staging ref '$ref' moved or disappeared before promotion"
	unstable_candidate=$(awk -F '\t' \
		'$1 == "refs/heads/codex-unstable" { print $3 }' "$updates")
	unstable_ref=
	unstable_staged=
	if test -n "$unstable_candidate" &&
		! is_null_oid "$unstable_candidate"
	then
		unstable_ref=$(staging_ref codex-unstable-staging)
		test "$ref" != "$unstable_ref" ||
			die "stable and unstable staging refs must be distinct"
		unstable_staged=$(remote_head_oid "$remote" "$unstable_ref")
		test "$unstable_staged" = "$unstable_candidate" ||
			die "unstable staging ref '$unstable_ref' moved or disappeared before promotion"
	elif test -n "$unstable_candidate" &&
		test "$(awk -F '\t' '$1 == "lane-mode" { print $3 }' \
			"$inputs")" = disable
	then
		candidate_unstable_ref=$(staging_ref codex-unstable-staging)
		unstable_staged=$(remote_head_oid "$remote" \
			"$candidate_unstable_ref")
		if test -n "$unstable_staged"
		then
			unstable_ref=$candidate_unstable_ref
		fi
	fi
	promote_updates "$remote" "$updates" "$ref" "$candidate" \
		"$unstable_ref" "$unstable_staged"
	base_ref=$(awk -F '\t' '$1 == "base" { print $2 }' "$inputs")
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	current_base=$(remote_head_oid "$remote" "$base_ref")
	if test "$current_base" != "$base_oid"
	then
		say "warning: $base_ref moved to $current_base during the final push; the published candidate passed CI at the pinned base $base_oid, so run Refresh codex again"
	fi
}

require_openai_git_origin () (
	fetch_urls=$(git remote get-url --all origin 2>/dev/null) ||
		die "origin has no fetch URL"
	push_urls=$(git remote get-url --push --all origin 2>/dev/null) ||
		die "origin has no push URL"
	test -n "$fetch_urls" &&
		test "$(printf '%s\n' "$fetch_urls" | wc -l | tr -d ' ')" = 1 ||
		die "origin must have exactly one fetch URL"
	test -n "$push_urls" &&
		test "$(printf '%s\n' "$push_urls" | wc -l | tr -d ' ')" = 1 ||
		die "origin must have exactly one push URL"
	for url in "$fetch_urls" "$push_urls"
	do
		case "$url" in
		git@github.com:openai/git|git@github.com:openai/git.git|\
		ssh://git@github.com/openai/git|ssh://git@github.com/openai/git.git|\
		https://github.com/openai/git|https://github.com/openai/git.git) ;;
		*) die "origin must fetch from and push to the canonical openai/git repository" ;;
		esac
	done
)

require_operator_context () {
	controller_oid=${CODEX_CONTROLLER_OID:-}
	test -n "$controller_oid" ||
		die "run this command through a pinned Meta entry point"
	meta_worktree=${CODEX_META_WORKTREE:-}
	test -n "$meta_worktree" && test -d "$meta_worktree" ||
		die "this command requires its pinned Meta worktree"
	require_full_commit_oid "$controller_oid"
	test "$(git -C "$meta_worktree" rev-parse --verify HEAD^{commit})" = \
		"$controller_oid" || die "Meta/HEAD does not match the pinned controller"
	require_full_repository
	require_clean_publish_worktrees "$meta_worktree"
	require_openai_git_origin
	command -v gh >/dev/null 2>&1 || die "this command requires the GitHub CLI (gh)"
}

refresh_meta_controller () {
	git fetch --force origin \
		'+refs/heads/meta:refs/remotes/origin/meta' >/dev/null ||
		die "could not refresh the meta controller"
	current_meta=$(git rev-parse --verify refs/remotes/origin/meta^{commit}) ||
		die "origin/meta is not a commit"
	test "$current_meta" != "$controller_oid" || return 0

	say "Updating Meta from $controller_oid to $current_meta."
	git -C "$meta_worktree" -c advice.detachedHead=false \
		switch --detach "$current_meta" >/dev/null ||
		die "could not update the Meta worktree"
	test -x "$meta_worktree/rebuild" ||
		die "updated meta does not contain Meta/rebuild"
	exec "$meta_worktree/rebuild" "$@"
}

read_refresh_run () {
	gh_command=$1
	repository=$2
	run_id=$3
	output=$4
	"$gh_command" api --hostname github.com \
		"repos/$repository/actions/runs/$run_id" --jq \
		'[.id, .run_attempt, .status, (.conclusion // "-"), .event, .head_branch, .head_sha, .path, .repository.full_name, .html_url] | @tsv' \
		>"$output" || die "could not inspect Refresh codex run $run_id"
	test "$(wc -l <"$output" | tr -d ' ')" = 1 ||
		die "Refresh codex run $run_id returned malformed metadata"
}

wait_for_refresh_run () (
	gh_command=$1
	repository=$2
	run_id=$3
	expected_attempt=$4
	attempt=0
	previous=
	while test "$attempt" -lt 180
	do
		attempt=$((attempt + 1))
		read_refresh_run "$gh_command" "$repository" "$run_id" \
			"$tmp_dir/rebuild-run"
		IFS="$tab" read -r actual_id run_attempt status conclusion event \
			branch sha path api_repository url <"$tmp_dir/rebuild-run"
		test "$actual_id" = "$run_id" &&
			test "$run_attempt" = "$expected_attempt" &&
			test "$event" = workflow_dispatch && test "$branch" = codex &&
			test "$path" = .github/workflows/codex.yml &&
			test "$api_repository" = "$repository" ||
			die "run $run_id no longer identifies the dispatched Refresh codex attempt"
		current=$status:$conclusion
		if test "$current" != "$previous"
		then
			if test "$status" = completed
			then
				say "Preparation: $conclusion: $url"
			else
				say "Preparation: $status: $url"
			fi
			previous=$current
		fi
		test "$status" != completed || break
		sleep 10
	done
	test "$status" = completed ||
		die "Refresh codex run $run_id did not complete before the timeout"
	test "$conclusion" = success ||
		die "Refresh codex run $run_id finished with '$conclusion'; start a fresh Meta/rebuild: $url"
)

rebuild_codex () {
	local_preparation=
	rebuild_unstable_mode=
	for option in "$@"
	do
		case "$option" in
		--local)
			test -z "$local_preparation" || { usage >&2; exit 129; }
			local_preparation=t
			;;
		--enable-unstable)
			test -z "$rebuild_unstable_mode" || { usage >&2; exit 129; }
			rebuild_unstable_mode=enable
			;;
		--disable-unstable)
			test -z "$rebuild_unstable_mode" || { usage >&2; exit 129; }
			rebuild_unstable_mode=disable
			;;
		*) usage >&2; exit 129 ;;
		esac
	done
	test -z "$rebuild_unstable_mode" || test -n "$local_preparation" ||
		die "changing the codex-unstable lane requires Meta/rebuild --local"
	require_operator_context
	if test -z "$local_preparation"
	then
		command -v unzip >/dev/null 2>&1 ||
			die "Meta/rebuild requires unzip"
		command -v zipinfo >/dev/null 2>&1 ||
			die "Meta/rebuild requires zipinfo"
	fi
	refresh_meta_controller "$@"
	if test -n "$local_preparation"
	then
		rebuild_codex_locally
		return
	fi

	make_tmp_dir
	repository=openai/git
	endpoint="repos/$repository/actions/workflows/codex.yml/dispatches"
	gh api --hostname github.com --method POST \
		--header 'Accept: application/vnd.github+json' \
		--header 'X-GitHub-Api-Version: 2026-03-10' \
		--raw-field ref=codex "$endpoint" --jq \
		'[.workflow_run_id, .run_url, .html_url] | @tsv' \
		>"$tmp_dir/dispatch" || die "could not dispatch Refresh codex"
	test "$(wc -l <"$tmp_dir/dispatch" | tr -d ' ')" = 1 ||
		die "Refresh codex dispatch returned malformed metadata"
	IFS="$tab" read -r run_id run_url html_url <"$tmp_dir/dispatch"
	case "$run_id" in
	''|*[!0-9]*) die "Refresh codex dispatch returned no numeric run ID" ;;
	esac
	test "$run_url" = \
		"https://api.github.com/repos/$repository/actions/runs/$run_id" &&
		test "$html_url" = \
		"https://github.com/$repository/actions/runs/$run_id" ||
		die "Refresh codex dispatch returned unexpected run URLs"
	say "Refresh codex run $run_id: $html_url"
	wait_for_refresh_run gh "$repository" "$run_id" 1
	CODEX_EXPECTED_RUN_ATTEMPT=1
	export CODEX_EXPECTED_RUN_ATTEMPT
	publish_run "$run_id"
}

artifact_value () (
	key=$1
	file=$2
	count=$(awk -F '\t' -v key="$key" '$1 == key { count++ }
		END { print count + 0 }' "$file")
	test "$count" = 1 || die "artifact metadata needs exactly one '$key' row"
	awk -F '\t' -v key="$key" '$1 == key { print substr($0, length($1) + 2) }' \
		"$file"
)

extract_candidate_artifact () (
	archive=$1
	output=$2
	names=$3
	expected=$4

	unzip -t "$archive" >/dev/null || die "candidate artifact is not a valid ZIP archive"
	unzip -Z1 "$archive" >"$names" ||
		die "could not list the candidate artifact"
	{
		printf '%s\n' codex.bundle codex-candidate codex-inputs \
			codex-run codex-updates
	} | LC_ALL=C sort >"$expected"
	LC_ALL=C sort "$names" >"$names.sorted" ||
		die "could not inspect the candidate artifact"
	cmp -s "$expected" "$names.sorted" ||
		die "candidate artifact does not contain exactly the expected files"
	regular=$(zipinfo -s "$archive" | awk '
		$1 ~ /^-/ { regular++ }
		$1 ~ /^[dl]/ { bad=1 }
		END {
			if (bad) exit 1
			print regular + 0
		}
	') || die "candidate artifact contains a non-regular entry"
	test "$regular" = 5 ||
		die "candidate artifact entries are not five regular files"
	mkdir -p "$output" || die "could not create candidate artifact directory"
	umask 077
	while read -r name
	do
		unzip -p "$archive" "$name" >"$output/$name" ||
			die "could not extract '$name' from the candidate artifact"
		test -f "$output/$name" && test ! -L "$output/$name" ||
			die "candidate artifact member '$name' is not a regular file"
	done <"$expected"
)

wait_for_staging_ci () (
	gh_command=$1
	repository=$2
	candidate=$3
	baseline=$4
	staging=${5:-codex-staging}
	workflow_runs="repos/$repository/actions/workflows/main.yml/runs?branch=$staging&event=push&head_sha=$candidate&per_page=100"

	if test "$staging" = codex-staging
	then
		say "Waiting for staging CI for $candidate..."
	else
		say "Waiting for $staging CI for $candidate..."
	fi
	run_id=
	attempt=0
	while test "$attempt" -lt 60
	do
		attempt=$((attempt + 1))
		run_id=$("$gh_command" api --hostname github.com "$workflow_runs" --jq \
			".workflow_runs | map(select(.id > ($baseline | tonumber) and .head_branch == \"$staging\" and .head_sha == \"$candidate\" and .event == \"push\" and .path == \".github/workflows/main.yml\")) | sort_by(.id) | .[0].id // empty") ||
			die "could not query staging CI"
		test -z "$run_id" || break
		sleep 5
	done
	test -n "$run_id" ||
		die "no new CI run appeared for $staging at $candidate"
	case "$run_id" in
	''|*[!0-9]*) die "staging CI returned an invalid run ID" ;;
	esac

	attempt=0
	status=
	conclusion=
	url=
	previous=
	while test "$attempt" -lt 180
	do
		attempt=$((attempt + 1))
		"$gh_command" api --hostname github.com \
			"repos/$repository/actions/runs/$run_id" --jq \
			'[.id, .event, .head_branch, .head_sha, .path, .status, (.conclusion // "-"), .html_url] | @tsv' \
			>"$tmp_dir/ci-run" || die "could not inspect staging CI run $run_id"
		test "$(wc -l <"$tmp_dir/ci-run" | tr -d ' ')" = 1 ||
			die "staging CI returned malformed run metadata"
		IFS="$tab" read -r actual_id event branch sha path status \
			conclusion url <"$tmp_dir/ci-run"
		test "$actual_id" = "$run_id" && test "$event" = push &&
			test "$branch" = "$staging" && test "$sha" = "$candidate" &&
			test "$path" = .github/workflows/main.yml ||
			die "staging CI run $run_id no longer identifies the exact candidate"
		"$gh_command" api --hostname github.com --paginate \
			"repos/$repository/actions/runs/$run_id/jobs?per_page=100" --jq \
			'.jobs[] | [.status, (.conclusion // "-")] | @tsv' \
			>"$tmp_dir/ci-job-rows" ||
			die "could not inspect jobs for staging CI run $run_id"
		awk -F '\t' '
			{
				total++
				if ($1 == "completed") {
					completed++
					if ($2 != "success" && $2 != "skipped" &&
					    $2 != "neutral")
						failed++
				}
			}
			END {
				printf "%d\t%d\t%d\n", total, completed, failed
			}
		' "$tmp_dir/ci-job-rows" >"$tmp_dir/ci-jobs" ||
			die "could not summarize jobs for staging CI run $run_id"
		test "$(wc -l <"$tmp_dir/ci-jobs" | tr -d ' ')" = 1 ||
			die "staging CI returned malformed job progress"
		IFS="$tab" read -r total completed failed <"$tmp_dir/ci-jobs"
		case "$total:$completed:$failed" in
		*[!0-9:]*) die "staging CI returned invalid job progress" ;;
		esac
		current=$status:$total:$completed:$failed
		if test "$current" != "$previous"
		then
			if test -z "$previous"
			then
				say "Staging CI run $run_id: $url"
			fi
			if test "$status" = completed
			then
				say "Staging CI: $conclusion ($completed/$total jobs complete; $failed failed): $url"
			else
				say "Staging CI: $status ($completed/$total jobs complete; $failed failed)"
			fi
			previous=$current
		elif test "$attempt" -gt 1 &&
			test $(((attempt - 1) % 10)) = 0
		then
			minutes=$(((attempt - 1) / 2))
			say "Staging CI: still $status after $minutes minutes ($completed/$total jobs complete; $failed failed)"
		fi
		test "$status" != completed || break
		sleep 30
	done
	test "$status" = completed ||
		die "CI run $run_id did not complete before the timeout"
	test "$conclusion" = success ||
		die "CI failed for exact staging SHA $candidate: $url"

	config_conclusion=$("$gh_command" api --hostname github.com --paginate \
		"repos/$repository/actions/runs/$run_id/jobs?per_page=100" --jq \
		'.jobs[] | select(.name == "config") | .conclusion') ||
		die "could not inspect jobs for staging CI run $run_id"
	test "$(printf '%s\n' "$config_conclusion" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 &&
		test "$config_conclusion" = success ||
		die "CI config did not run successfully on $staging"
	if test "$staging" = codex-staging
	then
		say "Full staging CI passed."
	else
		say "Full $staging CI passed."
	fi
)

freeze_local_candidate () {
	source=$1
	target=$2
	mkdir -p "$target" ||
		die "could not create the frozen local candidate directory"
	chmod 700 "$target" ||
		die "could not protect the frozen local candidate directory"
	for name in codex.bundle codex-candidate codex-inputs codex-updates
	do
		test -f "$source/$name" && test ! -L "$source/$name" ||
			die "local preparation did not produce regular file '$name'"
		cp "$source/$name" "$target/$name" ||
			die "could not freeze local candidate file '$name'"
		chmod 600 "$target/$name" ||
			die "could not protect frozen local candidate file '$name'"
	done
}

verify_candidate_bundle () {
	bundle=$1
	candidate=$2
	updates=$3
	controller=$4

	git bundle verify "$bundle" >/dev/null ||
		die "candidate bundle failed verification"
	git bundle unbundle "$bundle" >"$tmp_dir/bundle-heads" ||
		die "could not import the candidate bundle"
	printf '%s refs/codex-output/candidate\n' "$candidate" \
		>"$tmp_dir/expected-bundle-heads"
	new_meta=$(awk -F '\t' '$1 == "refs/heads/meta" { print $3 }' \
		"$updates")
	test -n "$new_meta" || die "candidate updates contain no meta state"
	if test "$new_meta" != "$controller"
	then
		printf '%s refs/codex-output/meta\n' "$new_meta" \
			>>"$tmp_dir/expected-bundle-heads"
	fi
	unstable_candidate=$(awk -F '\t' \
		'$1 == "refs/heads/codex-unstable" { print $3 }' "$updates")
	if test -n "$unstable_candidate" &&
		! is_null_oid "$unstable_candidate"
	then
		printf '%s refs/codex-output/unstable\n' "$unstable_candidate" \
			>>"$tmp_dir/expected-bundle-heads"
	fi
	LC_ALL=C sort -o "$tmp_dir/bundle-heads" "$tmp_dir/bundle-heads"
	LC_ALL=C sort -o "$tmp_dir/expected-bundle-heads" \
		"$tmp_dir/expected-bundle-heads"
	cmp -s "$tmp_dir/expected-bundle-heads" "$tmp_dir/bundle-heads" ||
		die "candidate bundle heads do not match the frozen update manifest"
}

verify_local_candidate () {
	metadata=$1
	inputs=$metadata/codex-inputs
	updates=$metadata/codex-updates
	result=$metadata/codex-candidate
	bundle=$metadata/codex.bundle

	test "$(wc -l <"$result" | tr -d ' ')" = 1 ||
		die "local candidate file must contain exactly one OID"
	candidate=$(sed -n '1p' "$result")
	input_controller=$(awk -F '\t' '$1 == "controller" { print $3 }' \
		"$inputs")
	test -n "$input_controller" && test "$input_controller" = "$controller_oid" ||
		die "local candidate input snapshot does not match Meta/HEAD"
	# Fetch and validate every prerequisite before importing the generated
	# objects.  The local bundle intentionally excludes the snapshotted
	# master, codex, and topic tips.
	verify_inputs --remote origin --base master --codex codex "$inputs"
	verify_candidate_bundle "$bundle" "$candidate" "$updates" \
		"$controller_oid"
	require_full_commit_oid "$candidate"
	update_candidate=$(awk -F '\t' '$1 == "refs/heads/codex" { print $3 }' \
		"$updates")
	test "$candidate" = "$update_candidate" ||
		die "local candidate and update manifest disagree"
	verify_output --inputs "$inputs" --updates "$updates" \
		--result "$result" --require-automation
}

with_isolated_git_environment () (
	unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR \
		GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM \
		GIT_DIR GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY \
		GIT_PREFIX GIT_QUARANTINE_PATH GIT_SHALLOW_FILE \
		GIT_TEMPLATE_DIR GIT_WORK_TREE
	GIT_CONFIG_NOSYSTEM=1
	GIT_CONFIG_SYSTEM=/dev/null
	GIT_CONFIG_GLOBAL=/dev/null
	GIT_ATTR_NOSYSTEM=1
	export GIT_CONFIG_NOSYSTEM GIT_CONFIG_SYSTEM GIT_CONFIG_GLOBAL \
		GIT_ATTR_NOSYSTEM
	"$@"
)

prepare_local_candidate () {
	make_tmp_dir
	publisher_top=$(git rev-parse --show-toplevel) ||
		die "could not locate the publisher worktree"
	frozen_helper=$tmp_dir/pinned-codex-branch.sh
	expected_helper=$(git rev-parse \
		"$controller_oid:.github/workflows/codex-branch.sh" 2>/dev/null) ||
		die "pinned meta $controller_oid has no controller helper"
	git cat-file blob \
		"$controller_oid:.github/workflows/codex-branch.sh" \
		>"$frozen_helper" || die "could not materialize the pinned controller"
	test "$(git hash-object "$frozen_helper")" = "$expected_helper" ||
		die "materialized controller does not match pinned meta $controller_oid"
	chmod 700 "$frozen_helper" ||
		die "could not protect the pinned controller helper"
	prepare_repository=$tmp_dir/local-prepare
	origin_fetch_url=$(git remote get-url --all origin) ||
		die "could not read the canonical origin fetch URL"
	origin_push_url=$(git remote get-url --push --all origin) ||
		die "could not read the canonical origin push URL"
	with_isolated_git_environment git clone --shared --no-checkout \
		"$publisher_top" "$prepare_repository" >/dev/null ||
		die "could not create the isolated local preparation repository"
	with_isolated_git_environment git -C "$prepare_repository" \
		remote set-url origin \
		"$origin_fetch_url" || die "could not set the preparation fetch URL"
	with_isolated_git_environment git -C "$prepare_repository" \
		remote set-url --push origin \
		"$origin_push_url" || die "could not set the preparation push URL"
	choose_local_rebuild_session
	say "Local preparation session: $session"
	(
		cd "$prepare_repository" || exit 1
		set -- "$frozen_helper" refresh \
			--session "$session" --remote origin --base master \
			--codex codex --rerere-from codex --require-automation
		test -z "${rebuild_unstable_mode:-}" ||
			set -- "$@" "--${rebuild_unstable_mode}-unstable"
		with_isolated_git_environment "$@"
	) || die "local Codex preparation failed; inspect '$session'"
	local_candidate_dir=$tmp_dir/local-candidate
	freeze_local_candidate "$session" "$local_candidate_dir"
}

reconcile_candidate_pr_state () (
	inputs=$1
	updates=$2
	helper=$script_dir/codex-pr-state.sh
	test -f "$helper" || return 0
	if ! sh "$helper" --inputs "$inputs" --updates "$updates"
	then
		printf '%s\n' \
			'warning: could not reconcile derived Codex pull request labels' \
			>&2
	fi
)

stage_and_wait_for_ci () {
	repository=$1
	candidate=$2
	inputs=$3
	updates=$4
	staging=codex-staging
	workflow_runs="repos/$repository/actions/workflows/main.yml/runs?branch=$staging&event=push&head_sha=$candidate&per_page=100"
	baseline=$(gh api --hostname github.com "$workflow_runs" --jq \
		'[.workflow_runs[].id] | max // 0') ||
		die "could not record the staging CI baseline"
	case "$baseline" in
	''|*[!0-9]*) die "staging CI baseline is not a numeric run ID" ;;
	esac
	publisher=$(gh api --hostname github.com user --jq .login) ||
		die "could not identify the GitHub CLI user"
	test -n "$publisher" || die "GitHub CLI returned no authenticated user"
	say "Publishing the prepared candidate with the credentials for origin."
	say "GitHub API user: $publisher"
	stage_candidate --remote origin --staging "$staging" \
		--inputs "$inputs" --updates "$updates" --require-automation
	reconcile_candidate_pr_state "$inputs" "$updates"
	wait_for_staging_ci gh "$repository" "$candidate" "$baseline" \
		"$staging"
	unstable_candidate=$(awk -F '\t' \
		'$1 == "refs/heads/codex-unstable" { print $3 }' "$updates")
	if test -n "$unstable_candidate" &&
		! is_null_oid "$unstable_candidate"
	then
		staging=codex-unstable-staging
		workflow_runs="repos/$repository/actions/workflows/main.yml/runs?branch=$staging&event=push&head_sha=$unstable_candidate&per_page=100"
		baseline=$(gh api --hostname github.com "$workflow_runs" --jq \
			'[.workflow_runs[].id] | max // 0') ||
			die "could not record the unstable staging CI baseline"
		case "$baseline" in
		''|*[!0-9]*) die "unstable staging CI baseline is not a numeric run ID" ;;
		esac
		stage_candidate --remote origin --staging "$staging" \
			--inputs "$inputs" --updates "$updates" --require-automation
		reconcile_candidate_pr_state "$inputs" "$updates"
		wait_for_staging_ci gh "$repository" "$unstable_candidate" \
			"$baseline" "$staging"
	fi
}

close_published_topic_review () (
	controller=$1
	updates=$2
	plan_commit=$3
	seen=$4
	review=$(plan_trailer_optional "$plan_commit" Codex-Plan-Review \
		"Codex-Plan-Review") || return 1
	test -n "$review" || return 0
	case "$review" in
	*[!0-9]*) return 1 ;;
	esac
	action=$(plan_trailer_one "$plan_commit" Codex-Plan-Action \
		"Codex-Plan-Action") || return 1
	case "$action" in
	add|alter) ;;
	*) return 0 ;;
	esac
	lane=$(plan_trailer_one "$plan_commit" Codex-Plan-Lane \
		"Codex-Plan-Lane") || return 1
	case "$lane" in
	codex|codex-unstable) ;;
	*) return 1 ;;
	esac
	topic=$(plan_trailer_one "$plan_commit" Codex-Plan-Topic \
		"Codex-Plan-Topic") || return 1
	topic=${topic#refs/heads/}
	source_tip=$(plan_trailer_one "$plan_commit" Codex-Plan-Source-Tip \
		"Codex-Plan-Source-Tip") || return 1
	published_meta=$(awk -F '\t' \
		'$1 == "refs/heads/meta" { print $3 }' "$updates") || return 1
	published_output=$(awk -F '\t' -v ref="refs/heads/$lane" \
		'$1 == ref { print $3 }' "$updates") || return 1
	test -n "$published_meta" && test -n "$published_output" || return 1
	make_tmp_dir
	review_state=$tmp_dir/published-topic-review
	mkdir -p "$review_state" || return 1
	git show "$published_meta:$lane.plan" >"$review_state/plan" || return 1
	git show "$published_meta:$meta_config_path" \
		>"$review_state/config" || return 1
	planned_tip=$(git config --no-includes --file "$review_state/plan" \
		--get "branch.$topic.source-tip" || :)
	test "$planned_tip" = "$source_tip" || return 0
	ledger_tip=$(git config --no-includes --file "$review_state/config" \
		--get "branch.$topic.source-tip" || :)
	ledger_output=$(git config --no-includes --file "$review_state/config" \
		--get "$lane.output-tip" || :)
	generated_tip=$(git config --no-includes --file "$review_state/config" \
		--get "branch.$topic.codex-tip" || :)
	test "$ledger_tip" = "$source_tip" &&
		test "$ledger_output" = "$published_output" &&
		test -n "$generated_tip" || return 1
	git merge-base --is-ancestor "$generated_tip" \
		"$published_output" || return 1
	test "$(remote_head_oid origin refs/heads/meta)" = \
		"$published_meta" || return 1
	test "$(remote_head_oid origin "refs/heads/$lane")" = \
		"$published_output" || return 1
	test "$(remote_head_oid origin "refs/heads/$topic")" = \
		"$source_tip" || return 0
	if grep -F -x "$review" "$seen" >/dev/null
	then
		return 0
	fi
	printf '%s\n' "$review" >>"$seen" || return 1
	gh api --hostname github.com "repos/openai/git/pulls/$review" \
		--jq '[.state, (.draft | tostring), .base.ref,
			(.head.repo.full_name // "-"), .head.ref, .head.sha] | @tsv' \
		>"$review_state/pull-request" || return 1
	IFS="$tab" read -r pull_state draft base head_repository \
		head_ref head_sha <"$review_state/pull-request" || return 1
	test "$pull_state" != closed || return 0
	test "$pull_state" = open && test "$draft" = false &&
		test "$base" = "$lane" && test "$head_repository" = openai/git &&
		test "$head_ref" = "$topic" && test "$head_sha" = "$source_tip" ||
		return 0
	gh pr close "$review" --repo github.com/openai/git || return 1
	say "Closed reviewed topic pull request #$review after publishing $lane."
)

close_published_topic_reviews () (
	controller=$1
	updates=$2
	make_tmp_dir
	review_history=$tmp_dir/published-topic-review-history
	reviewed=$tmp_dir/published-topic-review-seen
	: >"$reviewed" || return 1
	git rev-list --first-parent --max-count=64 "$controller" -- \
		codex.plan codex-unstable.plan >"$review_history" || return 1
	while IFS= read -r plan_commit
	do
		close_published_topic_review "$controller" "$updates" \
			"$plan_commit" "$reviewed" || return 1
	done <"$review_history"
)

rebuild_codex_locally () {
	prepare_local_candidate
	verify_local_candidate "$local_candidate_dir"
	candidate=$(sed -n '1p' "$local_candidate_dir/codex-candidate")
	stage_and_wait_for_ci openai/git "$candidate" \
		"$local_candidate_dir/codex-inputs" \
		"$local_candidate_dir/codex-updates"
	require_operator_context
	verify_local_candidate "$local_candidate_dir"
	promote --remote origin --staging codex-staging \
		--inputs "$local_candidate_dir/codex-inputs" \
		--updates "$local_candidate_dir/codex-updates" \
		--require-automation
	reconcile_candidate_pr_state "$local_candidate_dir/codex-inputs" \
		"$local_candidate_dir/codex-updates"
	say "Published codex candidate $candidate from local preparation session $session."
	if ! close_published_topic_reviews "$controller_oid" \
		"$local_candidate_dir/codex-updates"
	then
		say "warning: publication succeeded, but its reviewed topic pull request could not be closed."
	fi
	say "Generated commits identify $bot_name <$bot_email>; the push uses your configured origin credentials."
}

publish_run () {
	test $# = 1 || { usage >&2; exit 129; }
	run_id=$1
	case "$run_id" in
	''|*[!0-9]*) die "Meta/publish requires a numeric Actions run ID" ;;
	esac

	require_operator_context
	command -v unzip >/dev/null 2>&1 || die "Meta/publish requires unzip"
	command -v zipinfo >/dev/null 2>&1 || die "Meta/publish requires zipinfo"

	make_tmp_dir
	repository=openai/git
	endpoint="repos/$repository/actions/runs/$run_id"
	gh api --hostname github.com "$endpoint" --jq \
		'[.id, .run_attempt, .status, .conclusion, .event, .head_branch, .head_sha, .path, .repository.full_name, .html_url] | @tsv' \
		>"$tmp_dir/run" || die "could not read Actions run $run_id"
	test "$(wc -l <"$tmp_dir/run" | tr -d ' ')" = 1 ||
		die "Actions run $run_id returned malformed metadata"
	IFS="$tab" read -r api_id run_attempt status conclusion event \
		head_branch head_sha workflow_path api_repository run_url \
		<"$tmp_dir/run"
	test "$api_id" = "$run_id" || die "Actions returned the wrong run"
	case "$run_attempt" in
	''|*[!0-9]*) die "Actions run has an invalid attempt" ;;
	esac
	expected_run_attempt=${CODEX_EXPECTED_RUN_ATTEMPT:-}
	test -z "$expected_run_attempt" ||
		test "$run_attempt" = "$expected_run_attempt" ||
		die "Actions run $run_id moved from expected attempt $expected_run_attempt to attempt $run_attempt; start a fresh Meta/rebuild"
	test "$status" = completed && test "$conclusion" = success ||
		die "Actions run $run_id has not completed successfully"
	test "$event" = workflow_dispatch && test "$head_branch" = codex &&
		test "$workflow_path" = .github/workflows/codex.yml &&
		test "$api_repository" = "$repository" ||
		die "Actions run $run_id is not a Refresh codex dispatch from openai/git:codex"

	artifact_name=codex-candidate-$run_id-$run_attempt
	gh api --hostname github.com "$endpoint/artifacts?per_page=100" \
		--paginate --jq \
		".artifacts[] | select(.name == \"$artifact_name\") | [.id, .expired] | @tsv" \
		>"$tmp_dir/artifacts" || die "could not list artifacts for Actions run $run_id"
	test "$(wc -l <"$tmp_dir/artifacts" | tr -d ' ')" = 1 ||
		die "Actions run $run_id does not have exactly one '$artifact_name' artifact"
	IFS="$tab" read -r artifact_id expired <"$tmp_dir/artifacts"
	case "$artifact_id" in
	''|*[!0-9]*) die "Actions returned an invalid artifact ID" ;;
	esac
	test "$expired" = false || die "candidate artifact '$artifact_name' has expired"
	gh api --hostname github.com \
		"repos/$repository/actions/artifacts/$artifact_id/zip" \
		>"$tmp_dir/artifact.zip" || die "could not download '$artifact_name'"
	metadata=$tmp_dir/candidate
	extract_candidate_artifact "$tmp_dir/artifact.zip" "$metadata" \
		"$tmp_dir/artifact-names" "$tmp_dir/expected-artifact-names"

	run_controller=$(artifact_value controller-oid "$metadata/codex-run")
	artifact_candidate=$(artifact_value candidate "$metadata/codex-run")
	test "$(wc -l <"$metadata/codex-candidate" | tr -d ' ')" = 1 ||
		die "candidate artifact must contain exactly one candidate OID"
	test "$run_controller" = "$controller_oid" ||
		die "prepared run uses a different meta controller than Meta/HEAD"
	input_controller=$(awk -F '\t' '$1 == "controller" { print $3 }' \
		"$metadata/codex-inputs")
	input_codex=$(awk -F '\t' '$1 == "codex" { print $3 }' \
		"$metadata/codex-inputs")
	update_candidate=$(awk -F '\t' '$1 == "refs/heads/codex" { print $3 }' \
		"$metadata/codex-updates")
	test -n "$input_controller" && test "$input_controller" = "$run_controller" ||
		die "candidate input snapshot does not match its controller"
	test -n "$input_codex" && test "$head_sha" = "$input_codex" ||
		die "Actions caller SHA does not match the snapshotted codex input"
	test "$artifact_candidate" = "$(sed -n '1p' "$metadata/codex-candidate")" &&
		test "$artifact_candidate" = "$update_candidate" ||
		die "candidate metadata and update manifest disagree"

	controller_matches=$(gh api --hostname github.com "$endpoint" --jq \
		"[.referenced_workflows[] | select(.path == \"openai/git/.github/workflows/codex.yml@meta\" and .ref == \"refs/heads/meta\" and .sha == \"$run_controller\")] | length") ||
		die "could not verify the reusable controller for Actions run $run_id"
	test "$controller_matches" = 1 ||
		die "Actions run $run_id was not executed by the pinned meta controller"
	{
		printf 'repository\t%s\n' "$repository"
		printf 'run-id\t%s\n' "$run_id"
		printf 'run-attempt\t%s\n' "$run_attempt"
		printf 'event\t%s\n' "$event"
		printf 'caller-ref\trefs/heads/%s\n' "$head_branch"
		printf 'caller-sha\t%s\n' "$head_sha"
		printf 'workflow-path\t%s\n' "$workflow_path"
		printf 'controller-oid\t%s\n' "$run_controller"
		printf 'candidate\t%s\n' "$artifact_candidate"
		printf 'artifact-name\t%s\n' "$artifact_name"
	} >"$tmp_dir/expected-run"
	cmp -s "$tmp_dir/expected-run" "$metadata/codex-run" ||
		die "candidate run metadata does not exactly match the live Actions run"

	verify_inputs --remote origin --base master --codex codex \
		"$metadata/codex-inputs"
	verify_candidate_bundle "$metadata/codex.bundle" "$artifact_candidate" \
		"$metadata/codex-updates" "$run_controller"
	verify_output --inputs "$metadata/codex-inputs" \
		--updates "$metadata/codex-updates" \
		--result "$metadata/codex-candidate" --require-automation
	read_refresh_run gh "$repository" "$run_id" "$tmp_dir/run-current"
	cmp -s "$tmp_dir/run" "$tmp_dir/run-current" ||
		die "Actions run $run_id changed after artifact validation; start a fresh Meta/rebuild"

	stage_and_wait_for_ci "$repository" "$artifact_candidate" \
		"$metadata/codex-inputs" "$metadata/codex-updates"
	read_refresh_run gh "$repository" "$run_id" "$tmp_dir/run-after-ci"
	cmp -s "$tmp_dir/run" "$tmp_dir/run-after-ci" ||
		die "Actions run $run_id changed while staging CI ran; start a fresh Meta/rebuild"
	promote --remote origin --staging codex-staging \
		--inputs "$metadata/codex-inputs" \
		--updates "$metadata/codex-updates" --require-automation
	reconcile_candidate_pr_state "$metadata/codex-inputs" \
		"$metadata/codex-updates"
	say "Published codex candidate $artifact_candidate from Actions run $run_id."
	if ! close_published_topic_reviews "$run_controller" \
		"$metadata/codex-updates"
	then
		say "warning: publication succeeded, but its reviewed topic pull request could not be closed."
	fi
	say "Generated commits identify $bot_name <$bot_email>; the push uses your configured origin credentials."
}

resolve_rebase () {
	remote=origin
	base_name=master
	codex_name=codex
	inputs_oid=
	worktree=
	require_automation=

	while test $# -gt 0
	do
		case "$1" in
		--remote) require_arg "$@"; remote=$2; shift 2 ;;
		--base) require_arg "$@"; base_name=$2; shift 2 ;;
		--codex) require_arg "$@"; codex_name=$2; shift 2 ;;
		--inputs-oid) require_arg "$@"; inputs_oid=$2; shift 2 ;;
		--worktree) require_arg "$@"; worktree=$2; shift 2 ;;
		--require-automation) require_automation=t; shift ;;
		*) die "unknown resolve option '$1'" ;;
		esac
	done
	test -n "$inputs_oid" || die "resolve requires --inputs-oid"

	make_tmp_dir
	require_full_repository
	fetch_heads "$remote"
	inputs=$tmp_dir/inputs
	topics=$tmp_dir/topics
	snapshot_inputs "$remote" "$base_name" "$codex_name" "$inputs" "$topics"
	test "$(input_oid "$inputs")" = "$inputs_oid" ||
		die "the pinned input snapshot moved; rerun the refresh Action"
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")

	if test -z "$worktree"
	then
		resolve_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-resolve.XXXXXX") ||
			die "could not create resolution directory"
		worktree=$resolve_root/worktree
	else
		case "$worktree" in
		/*) ;;
		*) worktree=$(pwd)/$worktree ;;
		esac
		test ! -e "$worktree" || die "worktree path '$worktree' already exists"
	fi
	temporary_worktree=$worktree
	preserve_worktree=t
	git -c core.fsmonitor=false worktree add --detach "$worktree" "$base_oid" \
		>/dev/null
	state=$(state_path "$worktree")
	initialize_rewrite "$remote" "$base_name" "$codex_name" "$codex_name" \
		"$worktree" "$state" "$inputs" "$topics" "$require_automation"
	test ! -f "$state/merge-graph" ||
		die "resolve does not reconstruct merge-shaped topic graphs; restack the reviewed graph and rerun Meta/rebuild"

	if process_plan "$worktree" "$state"
	then
		die "the pinned rewrite no longer conflicts; rerun the refresh Action"
	fi

	say
	say "Resolution worktree: $worktree"
	say "Resolve the stopped rebase there:"
	say
	say "  cd $(shell_quote "$worktree")"
	say "  git status"
	say "  git rebase --show-current-patch"
	say "  # Edit the conflicted files."
	say "  git add <files>"
	say "  git diff --cached --check"
	say
	say "Continue the rebase with the canonical Codex committer:"
	say
	say "  $(shell_quote "$script_path") continue --worktree ."
	say
	say "If another conflict stops, repeat edit/add/check and run that command again."
}

resolved_rebase_tip () {
	worktree=$1
	state=$2
	failed_owner=$(state_value "$state" failed-owner)
	failed_old=$(state_value "$state" failed-old)
	failed_onto=$(state_value "$state" failed-onto)
	completed_topic_tip "$worktree" "$failed_owner" \
		"$failed_old" "$failed_onto"
}

continue_rewrite () {
	worktree=
	while test $# -gt 0
	do
		case "$1" in
		--worktree) require_arg "$@"; worktree=$2; shift 2 ;;
		*) die "unknown continue option '$1'" ;;
		esac
	done
	test -n "$worktree" || die "continue requires --worktree"
	state=$(state_path "$worktree")
	test -d "$state" || die "'$worktree' has no Codex rewrite state"
	require_state_controller "$state"
	test ! -f "$state/merge-graph" ||
		die "continue does not reconstruct merge-shaped topic graphs; restack the reviewed graph and rerun Meta/rebuild"
	if rebase_in_progress "$worktree"
	then
		if test -n "$(git -C "$worktree" -c core.fsmonitor=false ls-files -u)"
		then
			die "the rebase still has unresolved paths; edit them, git add them, and rerun this command"
		fi
		if ! continue_rerere_resolution "$worktree"
		then
			say "Another commit conflicts in the current topic."
			say "Edit the conflicted paths, git add them, and rerun:"
			say "  $(shell_quote "$script_path") continue --worktree $(shell_quote "$worktree")"
			return 1
		fi
	fi
	require_clean_worktree "$worktree"
	failed_old=$(state_value "$state" failed-old)
	failed_owner=$(state_value "$state" failed-owner)
	failed_parent=$(state_value "$state" failed-parent)
	failed_onto=$(state_value "$state" failed-onto)
	new=$(resolved_rebase_tip "$worktree" "$state") ||
		die "could not validate the resolved rebase"
	transform_record "$state/map" "$failed_old" "$failed_parent" \
		"$failed_onto" "$new"
	result_record "$state/results" "$failed_owner" "$new"
	rm -f "$state/failed-old" "$state/failed-owner" \
		"$state/failed-parent" "$state/failed-onto" \
		"$state/failed-commit"
	git -C "$worktree" -c core.fsmonitor=false \
		-c advice.detachedHead=false switch --detach "$new" \
		>/dev/null 2>&1 ||
		die "could not detach at the resolved topic tip"

	if ! process_plan "$worktree" "$state"
	then
		owner=$(state_value "$state" failed-owner)
		say "Another rebase conflict stopped in '$owner'."
		say "Resolve it with git status, edit, git add, and git diff --cached --check."
		say "Then rerun: $(shell_quote "$script_path") continue --worktree $(shell_quote "$worktree")"
		return 1
	fi

	if test -f "$state/pinned-plan-mode"
	then
		say "All topic branches were rewritten. Review them, then freeze the candidate with:"
	else
		say "All topic branches were rewritten. Review them, then publish atomically with:"
	fi
	say
	say "  $(shell_quote "$script_path") publish-topics --worktree $(shell_quote "$worktree")"
}

publish_topics () {
	worktree=
	while test $# -gt 0
	do
		case "$1" in
		--worktree) require_arg "$@"; worktree=$2; shift 2 ;;
		*) die "unknown publish-topics option '$1'" ;;
		esac
	done
	test -n "$worktree" || die "publish-topics requires --worktree"
	state=$(state_path "$worktree")
	test -f "$state/topic-updates" ||
		die "the topic rewrite has not completed"
	require_state_controller "$state"
	if rebase_in_progress "$worktree"
	then
		die "a rebase is still in progress in '$worktree'"
	fi
	require_clean_worktree "$worktree"
	remote=$(state_value "$state" remote)
	base_name=$(state_value "$state" base-name)
	codex_name=$(state_value "$state" codex-name)
	base_oid=$(state_value "$state" base-oid)

	make_tmp_dir
	candidate_worktree=$tmp_dir/candidate-worktree
	git -C "$worktree" -c core.fsmonitor=false worktree add --detach \
		"$candidate_worktree" "$base_oid" >/dev/null ||
		die "could not create a candidate verification worktree"
	temporary_worktree=$candidate_worktree
	if ! candidate=$(assemble_candidate "$candidate_worktree" "$state")
	then
		if test -f "$state/integration-failed-name"
		then
			write_integration_failure "$tmp_dir/integration-conflict" \
				"$state" "$candidate_worktree"
			cat "$tmp_dir/integration-conflict" >&2
			die "topic graph cannot be integrated; no refs were updated"
		fi
		die "rewritten topic graph failed candidate validation; no refs were updated"
	fi
	if test -f "$state/pinned-plan-mode"
	then
		prepare_unstable_candidate "$worktree" "$state" "$candidate" \
			"$tmp_dir/codex-conflict.md"
	fi
	stable_recovery=
	if test "$(state_value "$state" config-version)" = 2
	then
		stable_recovery=t
		printf '%s\n' "$(state_value "$state" controller-oid)" \
			>"$state/meta-oid" ||
			die "could not preserve published meta state during recovery"
	else
		create_meta_commit "$state" "$candidate"
	fi
	write_complete_updates "$state" "$candidate" "$tmp_dir/updates"
	printf '%s\n' "$candidate" >"$tmp_dir/result" ||
		die "could not prepare topic verification"
	require_automation=$(state_value "$state" require-automation)
	(
		cd "$worktree" || exit 1
		set -- --inputs "$state/inputs" --updates "$tmp_dir/updates" \
			--result "$tmp_dir/result"
		test -z "$require_automation" || set -- "$@" --require-automation
		test -z "$stable_recovery" || set -- "$@" --stable-recovery
		verify_output "$@"
	) || die "rewritten topic graph failed output verification"
	git -C "$worktree" -c core.fsmonitor=false worktree remove --force \
		"$candidate_worktree" >/dev/null ||
		die "could not remove the candidate verification worktree"
	temporary_worktree=

	if test -f "$state/pinned-plan-mode"
	then
		(
			cd "$worktree" || exit 1
			verify_inputs --remote "$remote" --base "$base_name" \
				--codex "$codex_name" "$state/inputs"
		) || die "pinned recovery inputs moved; no refs were updated"
		choose_local_rebuild_session
		mkdir -p "$session" ||
			die "could not create pinned recovery session"
		chmod 700 "$session" ||
			die "could not protect pinned recovery session"
		recovery_inputs=$session/codex-inputs
		recovery_updates=$session/codex-updates
		cp "$state/inputs" "$recovery_inputs" ||
			die "could not freeze pinned recovery inputs"
		cp "$tmp_dir/updates" "$recovery_updates" ||
			die "could not freeze pinned recovery updates"
		printf '%s\n' "$candidate" >"$session/codex-candidate" ||
			die "could not freeze pinned recovery candidate"
		create_bundle "$session/codex.bundle" "$state" "$candidate"
		for name in codex.bundle codex-candidate codex-inputs \
			codex-updates
		do
			chmod 600 "$session/$name" ||
				die "could not protect pinned recovery file '$name'"
		done
		say "Pinned recovery session: $session"
		say "No refs were updated. Stage the verified candidate with:"
		say "  $(shell_quote "$script_path") stage \\"
		say "    --remote $(shell_quote "$remote") --staging codex-staging \\"
		say "    --inputs $(shell_quote "$recovery_inputs") \\"
		say "    --updates $(shell_quote "$recovery_updates")${require_automation:+ --require-automation}"
		unstable_candidate=$(awk -F '\t' \
			'$1 == "refs/heads/codex-unstable" { print $3 }' \
			"$tmp_dir/updates")
		if test -n "$unstable_candidate" &&
			! is_null_oid "$unstable_candidate"
		then
			say "  $(shell_quote "$script_path") stage \\"
			say "    --remote $(shell_quote "$remote") \\"
			say "    --staging codex-unstable-staging \\"
			say "    --inputs $(shell_quote "$recovery_inputs") \\"
			say "    --updates $(shell_quote "$recovery_updates")${require_automation:+ --require-automation}"
		fi
		say "After fresh staging CI passes, promote the same session with:"
		say "  $(shell_quote "$script_path") promote \\"
		say "    --remote $(shell_quote "$remote") --staging codex-staging \\"
		say "    --inputs $(shell_quote "$recovery_inputs") \\"
		say "    --updates $(shell_quote "$recovery_updates")${require_automation:+ --require-automation}"
		return
	fi

	(
		cd "$worktree" || exit 1
		verify_inputs --remote "$remote" --base "$base_name" \
			--codex "$codex_name" "$state/inputs" || exit 1
		push_updates "$remote" "$state/topic-updates" topics
	) || die "topic publication failed; no topic refs were updated by this transaction"
	say "Topic refs updated. Run Refresh codex from the Actions page to rebuild codex."
}

test $# -gt 0 || { usage >&2; exit 129; }
command=$1
shift
case "$command" in
check-topic) check_topic "$@" ;;
rebuild) rebuild_codex "$@" ;;
publish) publish_run "$@" ;;
initialize) initialize_config "$@" ;;
refresh) local_refresh "$@" ;;
rewrite) rewrite "$@" ;;
verify-inputs) verify_inputs "$@" ;;
validate-plan-transition) validate_plan_transition "$@" ;;
test-validate-plan-transition) validate_plan_transition_fixture "$@" ;;
validate-topic-review) validate_topic_review "$@" ;;
reconcile-pr-state) sh "$script_dir/codex-pr-state.sh" "$@" ;;
propose-plan) propose_plan "$@" ;;
recover-release-pin) recover_release_pin "$@" ;;
test-recover-release-pin) recover_release_pin_fixture "$@" ;;
verify-output) verify_output "$@" ;;
stage) stage_candidate "$@" ;;
promote) promote "$@" ;;
publish-run) publish_run "$@" ;; # compatibility for previously printed commands
resolve) resolve_rebase "$@" ;;
continue) continue_rewrite "$@" ;;
publish-topics) publish_topics "$@" ;;
-h|--help) usage ;;
*) usage >&2; die "unknown command '$command'" ;;
esac
