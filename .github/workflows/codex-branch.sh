#!/bin/sh

set -eu

me=codex-branch
tmp_dir=
temporary_worktree=
preserve_worktree=
script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
script_path=${CODEX_ENTRYPOINT:-$script_dir/$(basename "$0")}
meta_config_path=codex.config
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
		.github/rulesets/codex-topics.json \
		.github/rulesets/codex-unstable-branch.json \
		.github/workflows/codex-admission.yml \
		.github/workflows/codex-topic.yml \
		.github/workflows/codex.yml \
		.github/workflows/codex-branch.sh \
		codex \
		publish \
		rebuild \
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
		.github/rulesets/codex-topics.json \
		.github/rulesets/codex-unstable-branch.json \
		.github/workflows/codex-admission.yml \
		.github/workflows/codex-topic.yml \
		.github/workflows/codex-branch.sh \
		.github/workflows/main.yml \
		codex \
		publish \
		rebuild \
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

automation_workflow_is_current () {
	head_oid=$1
	make_tmp_dir
	git show "$head_oid:.github/workflows/codex.yml" \
		>"$tmp_dir/actual-automation.yml" 2>/dev/null || return 1
	write_automation_workflow >"$tmp_dir/expected-automation.yml"
	cmp -s "$tmp_dir/expected-automation.yml" \
		"$tmp_dir/actual-automation.yml"
}

automation_workflow_is_reviewed () {
	head_oid=$1
	if automation_workflow_is_current "$head_oid"
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

release_workflow_is_codex_only () {
	head_oid=$1
	make_tmp_dir
	if ! git cat-file -e \
		"$head_oid:.github/workflows/codex-release.yml" 2>/dev/null
	then
		return 0
	fi
	git show "$head_oid:.github/workflows/codex-release.yml" \
		>"$tmp_dir/codex-release.yml" 2>/dev/null || return 1
	test "$(grep -c '^on:$' "$tmp_dir/codex-release.yml")" = 1 || return 1
	awk '
		$0 == "on:" && !found {
			found = 1
			in_trigger = 1
		}
		in_trigger && $0 != "" {
			if (seen && $0 !~ /^[[:space:]]/) exit
			print
			seen = 1
		}
		END { if (!found) exit 1 }
	' "$tmp_dir/codex-release.yml" >"$tmp_dir/release-trigger" || return 1
	cat >"$tmp_dir/expected-release-trigger" <<-'EOF'
	on:
	  push:
	    branches:
	      - codex
	EOF
	cmp -s "$tmp_dir/expected-release-trigger" \
		"$tmp_dir/release-trigger" || return 1
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
	cmp -s "$tmp_dir/published-publication" \
		"$tmp_dir/candidate-publication" || return 1
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
	awk -F '\t' -v author="$author" -v head="$head" '
		NF == 4 && $2 ~ /^(APPROVED|CHANGES_REQUESTED|DISMISSED)$/ {
			state[$1] = $2
			commit[$1] = $3
			association[$1] = $4
		}
		END {
			for (reviewer in state)
				if (reviewer != author &&
					state[reviewer] == "APPROVED" &&
					commit[reviewer] == head &&
					association[reviewer] ~ /^(OWNER|MEMBER|COLLABORATOR)$/)
					approved++
			exit !approved
		}
	' "$state/reviews" ||
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

	{
		printf 'controller\trefs/heads/meta\t%s\n' "$controller_oid"
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

config_get_one () (
	config=$1
	key=$2
	values=$(git config --no-includes --file "$config" --get-all "$key" || :)
	test -n "$values" || die "$meta_config_path is missing '$key'"
	test "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" = 1 ||
		die "$meta_config_path has more than one '$key'"
	printf '%s\n' "$values"
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
	test "$version" = 1 || test "$version" = 2 ||
		die "$meta_config_path has unsupported version '$version'"
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

	while IFS="$tab" read -r ref old oid
	do
		git -C "$worktree" merge-base --is-ancestor "$oid" HEAD ||
			die "candidate does not contain '$ref'"
	done <"$state/topic-updates"
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
	if test "$version" = 2
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
	prepare_stateful_plan codex "$stable_candidate" \
		"$unstable_state/topics" "$unstable_state" unstable
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
	while IFS="$tab" read -r ref old new
	do
		git merge-base --is-ancestor "$new" "$codex_oid" || contained=
	done <"$state/topic-updates"
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

prepare_input_graph () {
	inputs=$1
	graph=$2
	mkdir -p "$graph" || die "could not prepare input graph verification"
	awk -F '\t' '
		$1 == "controller" || $1 == "base" || $1 == "codex" ||
		$1 == "topic" || $1 == "unstable" ||
		$1 == "unstable-topic" || $1 == "lane-mode" {
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
	for kind in unstable lane-mode admission unstable-admission
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
		.github/rulesets/codex-topics.json \
		.github/rulesets/codex-unstable-branch.json \
		.github/workflows/codex-admission.yml \
		.github/workflows/codex-topic.yml \
		.github/workflows/codex.yml \
		.github/workflows/codex-branch.sh \
		.github/workflows/main.yml \
		codex \
		publish \
		rebuild \
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
	release_workflow_is_codex_only "$unstable_candidate" ||
		die "codex-unstable changes the production-only release trigger"
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

verify_control_paths () {
	inputs=$1
	updates=$2
	candidate=$3
	graph=$4
	require_automation=$5
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	if test -f "$graph/published-codex-oid"
	then
		published_codex=$(state_value "$graph" published-codex-oid)
		release_publication_controls_preserved "$published_codex" \
			"$candidate" ||
			die "candidate changes the controller-only release publication guard"
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

	if test -z "$require_automation"
	then
		legacy_control_paths_unchanged "$base_oid" "$candidate" ||
			die "candidate changes meta-only controller files"
		return
	fi

	meta_control_paths_unchanged "$base_oid" "$candidate" ||
		die "candidate changes a protected controller or CI file"
	automation_workflow_matches "$candidate" ||
		die "candidate does not contain the canonical Refresh codex workflow"
	release_workflow_is_codex_only "$candidate" ||
		die "candidate release workflow must run only for pushes to codex and must not obtain promotion credentials"

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
	awk -F '\t' -v recovery="$stable_recovery" '
		$1 == "controller" || $1 == "codex" || $1 == "topic" ||
		(recovery == "" && ($1 == "unstable" || $1 == "unstable-topic")) {
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
			git merge-base --is-ancestor "$base_oid" "$new" ||
				die "rewritten '$ref' is not based on master"
			git merge-base --is-ancestor "$new" "$candidate" ||
				die "candidate does not contain '$ref'"
			;;
		*) die "unexpected update ref '$ref'" ;;
		esac
	done <"$updates"
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
		ref=refs/heads/$name
		new=$(awk -F '\t' -v ref="$ref" '$1 == ref { print $3 }' \
			"$updates")
		test -n "$new" || die "updates contain no rewritten tip for '$name'"
		result_record "$tmp_dir/topic-graph/results" "$name" "$new"
	done <"$tmp_dir/topic-graph/topics"
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
			ref=refs/heads/$name
			new=$(awk -F '\t' -v ref="$ref" \
				'$1 == ref { print $3 }' "$updates")
			test -n "$new" ||
				die "updates contain no rewritten unstable tip for '$name'"
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
		wait_for_staging_ci gh "$repository" "$unstable_candidate" \
			"$baseline" "$staging"
	fi
}

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
	say "Published codex candidate $candidate from local preparation session $session."
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
	say "Published codex candidate $artifact_candidate from Actions run $run_id."
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

	say "All topic branches were rewritten. Review them, then publish atomically with:"
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
