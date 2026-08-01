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
	   or: codex-branch initialize [--remote <remote>] [--base <branch>]
		[--codex <branch>] [--output <path>] [--require-automation]
	   or: codex-branch refresh [--session <directory>]
		[--remote <remote>] [--base <branch>] [--codex <branch>]
		[--rerere-from <branch>] [--require-automation]
	   or: codex-branch rewrite [--remote <remote>] [--base <branch>]
		[--codex <branch>] [--rerere-from <branch>]
		[--result <path>] [--updates <path>] [--inputs <path>]
		[--bundle <path>] [--failure <path>]
		[--worktree <path>] [--require-automation]
	   or: codex-branch verify-inputs [--remote <remote>]
		[--base <branch>] [--codex <branch>] <snapshot>
	   or: codex-branch verify-output --inputs <path>
		--updates <path> --result <path> [--require-automation]
	   or: codex-branch stage [--remote <remote>] [--staging <branch>]
		--inputs <path> --updates <path> [--require-automation]
	   or: codex-branch promote [--remote <remote>] [--staging <branch>]
		--inputs <path> --updates <path> [--require-automation]
	   or: codex-branch publish-run <run-id>
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
		.github/workflows/codex-topic.yml \
		.github/workflows/codex.yml \
		.github/workflows/codex-branch.sh \
		codex \
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
		.github/workflows/codex-topic.yml \
		.github/workflows/codex-branch.sh \
		.github/workflows/main.yml \
		codex \
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

	on: workflow_dispatch

	permissions:
	  actions: read
	  contents: read

	jobs:
	  refresh:
	    uses: openai/git/.github/workflows/codex.yml@meta
	EOF
}

automation_workflow_matches () {
	head_oid=$1
	make_tmp_dir
	write_automation_workflow >"$tmp_dir/expected-automation.yml"
	git show "$head_oid:.github/workflows/codex.yml" \
		>"$tmp_dir/actual-automation.yml" 2>/dev/null || return 1
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

collect_topics () (
	remote=$1
	output=$2
	root=refs/remotes/$remote/

	: >"$output"
	git for-each-ref --format='%(objectname)%09%(refname)' "$root" |
	while IFS="$tab" read -r oid ref
	do
		name=${ref#"$root"}
		if is_active_topic_name "$name"
		then
			printf '%s\t%s\n' "$name" "$oid"
		fi
	done | LC_ALL=C sort >"$output"

	test -s "$output" ||
		die "no active ??/codex/* topic branches were found"
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

	{
		printf 'controller\trefs/heads/meta\t%s\n' "$controller_oid"
		printf 'base\trefs/heads/%s\t%s\n' "$base_name" "$base_oid"
		printf 'codex\trefs/heads/%s\t%s\n' "$codex_name" "$codex_oid"
		while IFS="$tab" read -r name oid
		do
			printf 'topic\trefs/heads/%s\t%s\n' "$name" "$oid"
		done <"$topics"
	} >"$output"
)

snapshot_inputs () {
	remote=$1
	base_name=$2
	codex_name=$3
	output=$4
	topics_output=$5
	controller_oid=${6:-${CODEX_CONTROLLER_OID:-}}
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
	collect_topics "$remote" "$topics_output"
	write_input_snapshot "$controller_oid" "$base_name" "$base_oid" \
		"$codex_name" "$codex_oid" "$topics_output" "$output"
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

	{
		printf '[codex]\n'
		printf '\tversion = 1\n'
		printf '\tbase-ref = refs/heads/%s\n' "$base_name"
		printf '\tbase-tip = %s\n' "$base_oid"
		printf '\toutput-ref = refs/heads/%s\n' "$codex_name"
		printf '\toutput-tip = %s\n' "$codex_oid"
		while IFS="$tab" read -r name tip prerequisite
		do
			quoted=$(config_subsection_quote "$name")
			printf '\n[branch "%s"]\n' "$quoted"
			printf '\tremote = .\n'
			printf '\tmerge = refs/heads/%s\n' "$prerequisite"
			printf '\tcodex-tip = %s\n' "$tip"
		done <"$rows"
	} >"$output" || die "could not write $meta_config_path"
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
	awk -F '\t' -v name="$name" '$1 == name { value=$3 }
		END { if (value != "") print value }' "$rows"
)

read_meta_config () (
	controller_oid=$1
	base_name=$2
	codex_name=$3
	state=$4
	config=$state/published-config
	rows=$state/published-topics

	git show "$controller_oid:$meta_config_path" >"$config" 2>/dev/null ||
		die "meta has no $meta_config_path; run Meta/codex initialize before refreshing"
	version=$(config_get_one "$config" codex.version)
	test "$version" = 1 ||
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

	: >"$rows"
	git config --no-includes --file "$config" --get-regexp \
		'^branch\..*\.codex-tip$' >"$state/published-tip-keys" || :
	while IFS=' ' read -r key tip
	do
		name=${key#branch.}
		name=${name%.codex-tip}
		is_active_topic_name "$name" ||
			die "$meta_config_path records invalid topic '$name'"
		remote=$(config_get_one "$config" "branch.$name.remote")
		merge=$(config_get_one "$config" "branch.$name.merge")
		test "$remote" = . ||
			die "$meta_config_path gives '$name' non-local remote '$remote'"
		case "$merge" in
		"refs/heads/$base_name") prerequisite=$base_name ;;
		refs/heads/*)
			prerequisite=${merge#refs/heads/}
			is_active_topic_name "$prerequisite" ||
				die "$meta_config_path gives '$name' invalid prerequisite '$merge'"
			;;
		*) die "$meta_config_path gives '$name' invalid prerequisite '$merge'" ;;
		esac
		require_full_commit_oid "$tip"
		printf '%s\t%s\t%s\n' "$name" "$tip" "$prerequisite" >>"$rows" ||
			die "could not read '$name' from $meta_config_path"
	done <"$state/published-tip-keys"
	LC_ALL=C sort -o "$rows" "$rows"
	test "$(cut -f1 "$rows" | sort -u | wc -l | tr -d ' ')" = \
		"$(wc -l <"$rows" | tr -d ' ')" ||
		die "$meta_config_path records a topic more than once"

	while IFS="$tab" read -r name tip prerequisite
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
		git merge-base --is-ancestor "$tip" "$output_tip" ||
			die "$meta_config_path output does not contain published topic '$name'"
	done <"$rows"
	git merge-base --is-ancestor "$base_tip" "$output_tip" ||
		die "$meta_config_path output is not based on its recorded base"

	write_meta_config "$base_name" "$base_tip" "$codex_name" "$output_tip" \
		"$rows" "$state/canonical-published-config"
	cmp -s "$config" "$state/canonical-published-config" ||
		die "$meta_config_path is not in canonical form"
	printf '%s\n' "$base_tip" >"$state/published-base-oid"
	printf '%s\n' "$output_tip" >"$state/published-codex-oid"
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
	git rev-list --first-parent --reverse "$published..$current" \
		>"$state/codex-first-parent-delta" ||
		die "could not inspect commits added directly to codex"
	previous=$published
	while read -r commit
	do
		parents=$(git show -s --format=%P "$commit") ||
			die "could not inspect codex commit $commit"
		set -- $parents
		test $# -ge 1 && test "$1" = "$previous" ||
			die "codex first-parent history is not based on its recorded output"
		case "$#" in
		1)
			topic_contains_commit "$topics" "$commit" ||
				die "codex commit $commit is not represented by an active ??/codex/* topic"
			;;
		2)
			second=$2
			topic_contains_commit "$topics" "$second" ||
				die "codex merge $commit has no active ??/codex/* topic containing its second parent"
			if ! git merge-tree --write-tree "$previous" "$second" \
				>"$state/codex-merge-tree" 2>/dev/null
			then
				die "codex merge $commit contains a conflict resolution not represented by a topic; extract it into an active topic before refreshing"
			fi
			test "$(wc -l <"$state/codex-merge-tree" | tr -d ' ')" = 1 ||
				die "could not verify the tree of codex merge $commit"
			expected_tree=$(sed -n '1p' "$state/codex-merge-tree")
			actual_tree=$(git rev-parse "$commit^{tree}") ||
				die "could not inspect the tree of codex merge $commit"
			test "$expected_tree" = "$actual_tree" ||
				die "codex merge $commit contains changes not represented by its topic"
			;;
		*)
			die "codex commit $commit is an octopus merge; reconstruct it from one-prerequisite topics before refreshing"
			;;
		esac
		previous=$commit
	done <"$state/codex-first-parent-delta"
)

prepare_plan () {
	base_name=$1
	base_oid=$2
	topics=$3
	state=$4
	unique=$state/unique-topic-inputs
	pairs=$state/topic-pairs
	plan=$state/plan

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
			;;
		1)
			IFS="$tab" read -r prerequisite old_base \
				<"$state/nearest-ancestors"
			;;
		*)
			prerequisites=$(cut -f1 "$state/nearest-ancestors" |
				LC_ALL=C sort | tr '\n' ' ')
			die "topic '$name' has more than one nearest prerequisite ($prerequisites); restack it onto one prerequisite topic"
			;;
		esac

		git merge-base --is-ancestor "$old_base" "$old" ||
			die "prerequisite '$prerequisite' is not an ancestor of '$name'"
		merge_commit=$(git rev-list --min-parents=2 \
			"$old_base..$old" | sed -n '1p')
		test -z "$merge_commit" ||
			die "topic history for '$name' contains merge commit $merge_commit; linearize it before refreshing codex"
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
	while test "$steps" -le "$limit"
	do
		parent=$(published_prerequisite "$rows" "$child")
		test -n "$parent" || return 1
		test "$parent" = "$ancestor" && return 0
		published_tip "$rows" "$parent" >/dev/null || return 1
		child=$parent
		steps=$((steps + 1))
	done
	die "$meta_config_path contains a dependency cycle"
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

prepare_stateful_plan () (
	base_name=$1
	base_oid=$2
	topics=$3
	state=$4
	published=$state/published-topics
	published_base=$(state_value "$state" published-base-oid)
	pairs=$state/topic-pairs
	plan=$state/plan

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
				END { exit !found }' "$topics"
		then
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
			if test -n "$published_tip_oid"
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
				git merge-base --is-ancestor "$base_oid" "$current_tip"
			then
				# With the published prerequisite absent, a root history is
				# an explicit restack onto master.
				prerequisite=$base_name
				prerequisite_tip=$base_oid
				old_base=$base_oid
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
				git merge-base --is-ancestor "$prerequisite_tip" \
					"$current_tip" ||
					die "new prerequisite '$prerequisite' is not in '$name'"
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
		test -z "$merge_commit" ||
			die "topic history for '$name' contains merge commit $merge_commit; linearize it before refreshing codex"
		printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$current_tip" \
			"$prerequisite" "$old_base" "$prerequisite_tip" >>"$plan" ||
			die "could not record the stateful rewrite plan for '$name'"
	done <"$topics"
	while IFS="$tab" read -r name current_tip prerequisite old_base prerequisite_tip
	do
		test "$name" != "$prerequisite" ||
			die "topic '$name' cannot be its own prerequisite"
		if test "$prerequisite" != "$base_name"
		then
			current_topic_tip "$topics" "$prerequisite" >/dev/null ||
				die "topic '$name' has missing prerequisite '$prerequisite'"
			if published_depends_on "$plan" "$prerequisite" "$name"
			then
				die "current topic prerequisites contain a cycle through '$name'"
			fi
		fi
	done <"$plan"
	while IFS="$tab" read -r left_name left_oid right_name right_oid
	do
		test "$left_oid" = "$right_oid" && continue
		if git merge-base --is-ancestor "$left_oid" "$right_oid" ||
			git merge-base --is-ancestor "$right_oid" "$left_oid" ||
			published_depends_on "$plan" "$left_name" "$right_name" ||
			published_depends_on "$plan" "$right_name" "$left_name"
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
				END { exit !found }' "$topics"
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
		if awk -F '\t' -v prerequisite="$old_name" \
			'$3 == prerequisite { found=1 } END { exit !found }' "$plan"
		then
			die "published topic '$old_name' was removed while an active topic still depends on it"
		fi
	done <"$published"
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
		prerequisite=$(awk -F '\t' -v name="$name" \
			'$1 == name { value=$3 } END { if (value != "") print value }' \
			"$state/plan")
		test -n "$prerequisite" ||
			die "topic '$name' has no recorded prerequisite"
		printf '%s\t%s\t%s\n' "$name" "$new" "$prerequisite" >>"$rows" ||
			die "could not record next state for '$name'"
	done <"$state/topics"
	LC_ALL=C sort -o "$rows" "$rows"
	write_meta_config "$(state_value "$state" base-name)" \
		"$(state_value "$state" base-oid)" \
		"$(state_value "$state" codex-name)" "$candidate" \
		"$rows" "$state/next-meta-config"
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
		say "The rewritten maximal topic \`$failed_name\` at \`$failed_oid\`"
		say "conflicts with the maximal topics already merged into the candidate."
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
			say "Maximal topics already merged, in order:"
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
	message=$(printf 'Merge %s into codex\n\nIntegrate the current %s topic into the internally distributed codex branch.\n\nCodex-Integration: %s@%s' \
		"$name" "$name" "$name" "$oid")

	if GIT_AUTHOR_NAME=$bot_name GIT_AUTHOR_EMAIL=$bot_email \
		GIT_COMMITTER_NAME=$bot_name GIT_COMMITTER_EMAIL=$bot_email \
		git -C "$worktree" \
		-c core.hooksPath=/dev/null \
		-c core.fsmonitor=false \
		-c commit.gpgSign=false \
		-c rerere.enabled=true \
		-c rerere.autoupdate=true \
		merge --no-ff --no-edit --no-gpg-sign -m "$message" "$oid" >&2
	then
		return 0
	fi

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
		commit --no-edit --no-gpg-sign >&2
}

assemble_candidate () {
	worktree=$1
	state=$2
	base_oid=$(state_value "$state" base-oid)
	unique=$state/unique-topics
	maximal=$state/maximal-topics
	rm -f "$state/integration-failed-name" \
		"$state/integration-failed-oid" ||
		die "could not clear old integration state"
	: >"$state/integration-merged" ||
		die "could not prepare integration progress"

	awk -F '\t' '!seen[$3]++ { print }' "$state/topic-updates" >"$unique" ||
		die "could not collect unique topic tips"
	: >"$maximal" || die "could not prepare maximal topic list"
	while IFS="$tab" read -r ref old oid
	do
		dominated=
		while IFS="$tab" read -r other_ref other_old other_oid
		do
			test "$oid" = "$other_oid" && continue
			if git merge-base --is-ancestor "$oid" "$other_oid"
			then
				dominated=t
				break
			fi
		done <"$unique"
		if test -z "$dominated"
		then
			printf '%s\t%s\n' "${ref#refs/heads/}" "$oid" >>"$maximal" ||
				die "could not record maximal topic '$ref'"
		fi
	done <"$unique"

	git -C "$worktree" -c core.fsmonitor=false \
		-c advice.detachedHead=false switch --detach "$base_oid" >/dev/null ||
		die "could not check out master while assembling codex"
	while IFS="$tab" read -r name oid
	do
		if ! merge_topic "$worktree" "$name" "$oid"
		then
			printf '%s\n' "$name" >"$state/integration-failed-name" ||
				die "could not record the conflicting integration topic"
			printf '%s\n' "$oid" >"$state/integration-failed-oid" ||
				die "could not record the conflicting integration commit"
			return 1
		fi
		printf '%s\n' "$name" >>"$state/integration-merged" ||
			die "could not record integration progress"
	done <"$maximal"

	while IFS="$tab" read -r ref old oid
	do
		git -C "$worktree" merge-base --is-ancestor "$oid" HEAD ||
			die "candidate does not contain '$ref'"
	done <"$state/topic-updates"
	candidate=$(git -C "$worktree" rev-parse HEAD) ||
		die "could not resolve the codex candidate"
	require_automation=$(state_value "$state" require-automation)
	if ! test -f "$state/initializing"
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
		git update-ref -d refs/codex-output/meta || :
		die "could not create candidate bundle"
	fi
	git update-ref -d refs/codex-output/candidate ||
		die "could not remove the temporary bundle ref"
	git update-ref -d refs/codex-output/meta || :
}

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
	controller_oid=$(awk -F '\t' '$1 == "controller" { print $3 }' "$inputs")
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	base_ref=$(awk -F '\t' '$1 == "base" { print $2 }' "$inputs")
	base_name=${base_ref#refs/heads/}
	codex_oid=$(awk -F '\t' '$1 == "codex" { print $3 }' "$inputs")
	printf '%s\n' "$controller_oid" >"$state/controller-oid"
	printf '%s\n' "$remote" >"$state/remote"
	printf '%s\n' "$base_name" >"$state/base-name"
	printf '%s\n' "$base_oid" >"$state/base-oid"
	printf '%s\n' "$codex_name" >"$state/codex-name"
	printf '%s\n' "$codex_oid" >"$state/codex-oid"
	printf '%s\n' "$rerere_name" >"$state/rerere-name"
	printf '%s\n' "$require_automation" >"$state/require-automation"
	printf '%s\n' "$script_path" >"$state/helper"

	read_meta_config "$controller_oid" "$base_name" "$codex_name" "$state"
	published_codex_oid=$(state_value "$state" published-codex-oid)
	validate_live_codex_delta "$published_codex_oid" "$codex_oid" \
		"$state/topics" "$state"
	prepare_stateful_plan "$base_name" "$base_oid" "$state/topics" "$state"
	if test -n "$rerere_name" && test "$codex_oid" != "$base_oid"
	then
		train_rerere "$worktree" "$base_oid" "$codex_oid"
	fi
}

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
	prepare_plan "$base_name" "$published_base" "$state/topics" "$state"
	mv "$state/plan" "$state/unique-plan" ||
		die "could not retain the inferred initialization plan"
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
	done <"$state/topics"
	: >"$state/results"
	: >"$state/map"
	while IFS="$tab" read -r name tip prerequisite old_base prerequisite_tip
	do
		if test "$prerequisite" = "$base_name"
		then
			test "$old_base" = "$published_base" ||
				die "root topic '$name' is not based on the inferred published base"
		else
			parent_tip=$(current_topic_tip "$state/topics" "$prerequisite")
			test -n "$parent_tip" && test "$old_base" = "$parent_tip" ||
				die "topic '$name' is not based on the exact tip of '$prerequisite'"
		fi
		result_record "$state/results" "$name" "$tip"
	done <"$state/plan"
	finish_updates "$state"
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
		printf '%s\t%s\t%s\n' "$name" "$tip" "$prerequisite" \
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

local_refresh () {
	remote=origin
	base_name=master
	codex_name=codex
	rerere_name=codex
	session=
	require_automation=
	while test $# -gt 0
	do
		case "$1" in
		--session) require_arg "$@"; session=$2; shift 2 ;;
		--remote) require_arg "$@"; remote=$2; shift 2 ;;
		--base) require_arg "$@"; base_name=$2; shift 2 ;;
		--codex) require_arg "$@"; codex_name=$2; shift 2 ;;
		--rerere-from) require_arg "$@"; rerere_name=$2; shift 2 ;;
		--require-automation) require_automation=t; shift ;;
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
	set -- --remote "$remote" --base "$base_name" --codex "$codex_name" \
		--rerere-from "$rerere_name" \
		--result "$session/codex-candidate" \
		--updates "$session/codex-updates" \
		--inputs "$session/codex-inputs" \
		--bundle "$session/codex.bundle" \
		--failure "$session/codex-conflict.md"
	test -z "$require_automation" || set -- "$@" --require-automation
	fetch_heads "$remote"
	rewrite "$@"
	say "local refresh session: $session"
	say "no refs were updated; inspect codex-updates and codex.bundle"
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
		-h|--help) usage; exit 0 ;;
		*) die "unknown rewrite option '$1'" ;;
		esac
	done

	make_tmp_dir
	require_full_repository
	inputs=$tmp_dir/inputs
	topics=$tmp_dir/topics
	snapshot_inputs "$remote" "$base_name" "$codex_name" "$inputs" "$topics"
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

	if ! process_plan "$worktree" "$state"
	then
		write_failure "$failure_file" "$state" "$worktree"
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
		"$(git rev-parse "$codex_oid^{tree}")"
	then
		candidate=$codex_oid
	fi
	create_meta_commit "$state" "$candidate"
	write_complete_updates "$state" "$candidate" "$tmp_dir/updates"

	test -z "$result_file" || printf '%s\n' "$candidate" >"$result_file"
	test -z "$updates_file" || cp "$tmp_dir/updates" "$updates_file"
	test -z "$bundle_file" || create_bundle "$bundle_file" "$state" "$candidate"
	say "rewrote all active topics and assembled codex candidate $candidate"
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
	actual=$tmp_dir/actual-inputs
	topics=$tmp_dir/actual-topics
	snapshot_inputs "$remote" "$base_name" "$codex_name" "$actual" "$topics" \
		"$expected_controller"
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
	awk -F '\t' '$1 == "topic" {
		name=$2
		sub("^refs/heads/", "", name)
		printf "%s\t%s\n", name, $3
	}' "$inputs" | LC_ALL=C sort >"$graph/topics" ||
		die "could not read topics from the input snapshot"
	test -s "$graph/topics" || die "input snapshot contains no topics"
	while IFS="$tab" read -r name oid
	do
		is_active_topic_name "$name" ||
			die "input snapshot contains invalid active topic '$name'"
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
	read_meta_config "$controller_oid" "$base_name" "$codex_name" "$graph"
	codex_oid=$(awk -F '\t' '$1 == "codex" { print $3 }' "$inputs")
	validate_live_codex_delta "$(state_value "$graph" published-codex-oid)" \
		"$codex_oid" "$graph/topics" "$graph"
	prepare_stateful_plan "$base_name" "$base_oid" "$graph/topics" "$graph"
}

topic_control_paths_unchanged () (
	base_oid=$1
	head_oid=$2
	git diff --quiet "$base_oid" "$head_oid" -- \
		.github/CODEX.md \
		.github/rulesets/codex-branch.json \
		.github/rulesets/codex-meta.json \
		.github/rulesets/codex-topics.json \
		.github/workflows/codex-topic.yml \
		.github/workflows/codex.yml \
		.github/workflows/codex-branch.sh \
		.github/workflows/main.yml \
		codex \
		codex.config \
		t/t9905-codex-branch.sh &&
	git diff --quiet "$base_oid" "$head_oid" -- \
		':(glob).github/workflows/*.yml' \
		':(glob).github/workflows/*.yaml' \
		':(exclude).github/workflows/codex-release.yml'
)

verify_control_paths () {
	inputs=$1
	updates=$2
	candidate=$3
	graph=$4
	require_automation=$5
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")

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
		refs/heads/meta|refs/heads/codex) continue ;;
		esac
		name=${ref#refs/heads/}
		plan_row=$(awk -F '\t' -v name="$name" '$1 == name { print; exit }' \
			"$graph/plan")
		test -n "$plan_row" ||
			die "input graph has no rewrite range for '$ref'"
		IFS="$tab" read -r canonical_name plan_old prerequisite old_base prerequisite_tip <<-EOF
		$plan_row
		EOF
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

		case "$name" in
		??/codex/automation)
			automation_count=$((automation_count + 1))
			test "$prerequisite" = master ||
				die "automation topic '$name' must be based directly on master"
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
			topic_control_paths_unchanged "$dependency_new" "$new" ||
				die "topic '$name' changes a protected controller or CI file"
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
		prerequisite=$(awk -F '\t' -v name="$name" \
			'$1 == name { value=$3 } END { if (value != "") print value }' \
			"$graph/plan")
		test -n "$prerequisite" ||
			die "verified graph contains no prerequisite for '$name'"
		printf '%s\t%s\t%s\n' "$name" "$new" "$prerequisite" \
			>>"$graph/expected-meta-topics"
	done <"$graph/topics"
	LC_ALL=C sort -o "$graph/expected-meta-topics" \
		"$graph/expected-meta-topics"
	base_ref=$(awk -F '\t' '$1 == "base" { print $2 }' "$inputs")
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	codex_ref=$(awk -F '\t' '$1 == "codex" { print $2 }' "$inputs")
	base_name=${base_ref#refs/heads/}
	codex_name=${codex_ref#refs/heads/}
	write_meta_config "$base_name" "$base_oid" "$codex_name" "$candidate" \
		"$graph/expected-meta-topics" "$graph/expected-meta-config"
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
	while test $# -gt 0
	do
		case "$1" in
		--inputs) require_arg "$@"; inputs=$2; shift 2 ;;
		--updates) require_arg "$@"; updates=$2; shift 2 ;;
		--result) require_arg "$@"; result=$2; shift 2 ;;
		--require-automation) require_automation=t; shift ;;
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
	LC_ALL=C sort -c "$updates" || die "updates are not canonically sorted"
	test "$(cut -f1 "$updates" | sort -u | wc -l | tr -d ' ')" = \
		"$(wc -l <"$updates" | tr -d ' ')" || die "updates contain duplicate refs"
	awk -F '\t' '$1 == "controller" || $1 == "codex" || $1 == "topic" { print $2 }' "$inputs" \
		| LC_ALL=C sort >"$tmp_dir/expected-update-refs"
	cut -f1 "$updates" | LC_ALL=C sort >"$tmp_dir/actual-update-refs"
	cmp -s "$tmp_dir/expected-update-refs" "$tmp_dir/actual-update-refs" ||
		die "updates do not cover exactly codex and every snapshotted topic"
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	test -n "$base_oid" || die "input snapshot has no base commit"
	prepare_input_graph "$inputs" "$tmp_dir/topic-graph"
	git merge-base --is-ancestor "$base_oid" "$candidate" ||
		die "candidate is not based on the snapshotted master"
	verify_meta_update "$inputs" "$updates" "$candidate" \
		"$tmp_dir/topic-graph"
	verify_control_paths "$inputs" "$updates" "$candidate" \
		"$tmp_dir/topic-graph" "$require_automation"
	while IFS="$tab" read -r ref old new
	do
		git check-ref-format "$ref" >/dev/null || die "invalid update ref '$ref'"
		expected_old=$(awk -F '\t' -v ref="$ref" '$2 == ref { print $3 }' \
			"$inputs")
		test "$old" = "$expected_old" ||
			die "old value for '$ref' does not match the input snapshot"
		resolve_commit "$old" >/dev/null
		require_full_commit_oid "$new"
		case "$ref" in
		refs/heads/meta) ;;
		refs/heads/codex) ;;
		refs/heads/??/codex/?*)
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
	done <"$tmp_dir/topic-graph/plan"
}

push_updates () {
	remote=$1
	updates=$2
	filter=$3

	set -- git -c core.hooksPath=/dev/null push --atomic --porcelain
	while IFS="$tab" read -r ref old new
	do
		case "$filter:$ref" in
		topics:refs/heads/meta|topics:refs/heads/codex) continue ;;
		esac
		set -- "$@" "--force-with-lease=$ref:$old"
	done <"$updates"
	set -- "$@" "$remote"
	while IFS="$tab" read -r ref old new
	do
		case "$filter:$ref" in
		topics:refs/heads/meta|topics:refs/heads/codex) continue ;;
		esac
		set -- "$@" "$new:$ref"
	done <"$updates"
	"$@"
}

staging_ref () {
	name=$1
	git check-ref-format "refs/heads/$name" >/dev/null 2>&1 ||
		die "invalid staging branch '$name'"
	case "$name" in
	??/codex/*|codex|master|meta)
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
	candidate=$(awk -F '\t' '$1 == "refs/heads/codex" { print $3 }' \
		"$updates")
	test -n "$candidate" || die "update manifest has no codex candidate"
	printf '%s\n' "$candidate" >"$tmp_dir/stage-result" ||
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
	if test -n "$old" && test "$old" = "$candidate"
	then
		git -c core.hooksPath=/dev/null push --atomic --porcelain \
			"--force-with-lease=$ref:$old" "$remote" ":$ref"
		old=
	fi
	git -c core.hooksPath=/dev/null push --atomic --porcelain \
		"--force-with-lease=$ref:$old" "$remote" "$candidate:$ref"
}

promote_updates () {
	remote=$1
	updates=$2
	ref=$3
	candidate=$4

	set -- git -c core.hooksPath=/dev/null push --atomic --porcelain
	while IFS="$tab" read -r update_ref old new
	do
		set -- "$@" "--force-with-lease=$update_ref:$old"
	done <"$updates"
	set -- "$@" "--force-with-lease=$ref:$candidate" "$remote"
	while IFS="$tab" read -r update_ref old new
	do
		set -- "$@" "$new:$update_ref"
	done <"$updates"
	set -- "$@" ":$ref"
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
	promote_updates "$remote" "$updates" "$ref" "$candidate"
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
	workflow_runs="repos/$repository/actions/workflows/main.yml/runs?branch=codex-staging&event=push&head_sha=$candidate&per_page=100"

	run_id=
	attempt=0
	while test "$attempt" -lt 60
	do
		attempt=$((attempt + 1))
		run_id=$("$gh_command" api --hostname github.com "$workflow_runs" --jq \
			".workflow_runs | map(select(.id > ($baseline | tonumber) and .head_branch == \"codex-staging\" and .head_sha == \"$candidate\" and .event == \"push\" and .path == \".github/workflows/main.yml\")) | sort_by(.id) | .[0].id // empty") ||
			die "could not query staging CI"
		test -z "$run_id" || break
		sleep 5
	done
	test -n "$run_id" ||
		die "no new CI run appeared for codex-staging at $candidate"
	case "$run_id" in
	''|*[!0-9]*) die "staging CI returned an invalid run ID" ;;
	esac

	attempt=0
	status=
	conclusion=
	url=
	while test "$attempt" -lt 180
	do
		attempt=$((attempt + 1))
		"$gh_command" api --hostname github.com \
			"repos/$repository/actions/runs/$run_id" --jq \
			'[.id, .event, .head_branch, .head_sha, .path, .status, (.conclusion // ""), .html_url] | @tsv' \
			>"$tmp_dir/ci-run" || die "could not inspect staging CI run $run_id"
		test "$(wc -l <"$tmp_dir/ci-run" | tr -d ' ')" = 1 ||
			die "staging CI returned malformed run metadata"
		IFS="$tab" read -r actual_id event branch sha path status \
			conclusion url <"$tmp_dir/ci-run"
		test "$actual_id" = "$run_id" && test "$event" = push &&
			test "$branch" = codex-staging && test "$sha" = "$candidate" &&
			test "$path" = .github/workflows/main.yml ||
			die "staging CI run $run_id no longer identifies the exact candidate"
		test "$status" != completed || break
		sleep 30
	done
	test "$status" = completed ||
		die "CI run $run_id did not complete before the timeout"
	test "$conclusion" = success ||
		die "CI failed for exact staging SHA $candidate: $url"

	config_conclusion=$("$gh_command" api --hostname github.com \
		"repos/$repository/actions/runs/$run_id/jobs?per_page=100" --jq \
		'[.jobs[] | select(.name == "config") | .conclusion] | if length == 1 then .[0] else "" end') ||
		die "could not inspect jobs for staging CI run $run_id"
	test "$config_conclusion" = success ||
		die "CI config did not run successfully on codex-staging"
	say "Full staging CI passed: $url"
)

publish_run () {
	test $# = 1 || { usage >&2; exit 129; }
	run_id=$1
	case "$run_id" in
	''|*[!0-9]*) die "publish-run requires a numeric Actions run ID" ;;
	esac

	controller_oid=${CODEX_CONTROLLER_OID:-}
	test -n "$controller_oid" ||
		die "run publish-run through the pinned Meta/codex entry point"
	meta_worktree=${CODEX_META_WORKTREE:-}
	test -n "$meta_worktree" && test -d "$meta_worktree" ||
		die "publish-run requires its pinned Meta worktree"
	require_full_commit_oid "$controller_oid"
	test "$(git -C "$meta_worktree" rev-parse --verify HEAD^{commit})" = \
		"$controller_oid" || die "Meta/HEAD does not match the pinned controller"
	require_full_repository
	require_clean_publish_worktrees "$meta_worktree"
	require_openai_git_origin
	command -v gh >/dev/null 2>&1 || die "publish-run requires the GitHub CLI (gh)"
	command -v unzip >/dev/null 2>&1 || die "publish-run requires unzip"
	command -v zipinfo >/dev/null 2>&1 || die "publish-run requires zipinfo"

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
	git bundle verify "$metadata/codex.bundle" >/dev/null ||
		die "candidate bundle failed verification"
	git bundle unbundle "$metadata/codex.bundle" >"$tmp_dir/bundle-heads" ||
		die "could not import the candidate bundle"
	printf '%s refs/codex-output/candidate\n' "$artifact_candidate" \
		>"$tmp_dir/expected-bundle-heads"
	new_meta=$(awk -F '\t' '$1 == "refs/heads/meta" { print $3 }' \
		"$metadata/codex-updates")
	test -n "$new_meta" || die "candidate updates contain no meta state"
	if test "$new_meta" != "$run_controller"
	then
		printf '%s refs/codex-output/meta\n' "$new_meta" \
			>>"$tmp_dir/expected-bundle-heads"
	fi
	LC_ALL=C sort -o "$tmp_dir/bundle-heads" "$tmp_dir/bundle-heads"
	LC_ALL=C sort -o "$tmp_dir/expected-bundle-heads" \
		"$tmp_dir/expected-bundle-heads"
	cmp -s "$tmp_dir/expected-bundle-heads" "$tmp_dir/bundle-heads" ||
		die "candidate bundle heads do not match the frozen update manifest"
	verify_output --inputs "$metadata/codex-inputs" \
		--updates "$metadata/codex-updates" \
		--result "$metadata/codex-candidate" --require-automation

	workflow_runs="repos/$repository/actions/workflows/main.yml/runs?branch=codex-staging&event=push&head_sha=$artifact_candidate&per_page=100"
	baseline=$(gh api --hostname github.com "$workflow_runs" --jq \
		'[.workflow_runs[].id] | max // 0') || die "could not record the staging CI baseline"
	case "$baseline" in
	''|*[!0-9]*) die "staging CI baseline is not a numeric run ID" ;;
	esac
	publisher=$(gh api --hostname github.com user --jq .login) ||
		die "could not identify the GitHub CLI user"
	test -n "$publisher" || die "GitHub CLI returned no authenticated user"
	say "Publishing the prepared candidate with the credentials for origin."
	say "GitHub API user: $publisher"
	stage_candidate --remote origin --staging codex-staging \
		--inputs "$metadata/codex-inputs" \
		--updates "$metadata/codex-updates" --require-automation
	wait_for_staging_ci gh "$repository" "$artifact_candidate" "$baseline"
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
	create_meta_commit "$state" "$candidate"
	write_complete_updates "$state" "$candidate" "$tmp_dir/updates"
	printf '%s\n' "$candidate" >"$tmp_dir/result" ||
		die "could not prepare topic verification"
	require_automation=$(state_value "$state" require-automation)
	(
		cd "$worktree" || exit 1
		set -- --inputs "$state/inputs" --updates "$tmp_dir/updates" \
			--result "$tmp_dir/result"
		test -z "$require_automation" || set -- "$@" --require-automation
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
initialize) initialize_config "$@" ;;
refresh) local_refresh "$@" ;;
rewrite) rewrite "$@" ;;
verify-inputs) verify_inputs "$@" ;;
verify-output) verify_output "$@" ;;
stage) stage_candidate "$@" ;;
promote) promote "$@" ;;
publish-run) publish_run "$@" ;;
resolve) resolve_rebase "$@" ;;
continue) continue_rewrite "$@" ;;
publish-topics) publish_topics "$@" ;;
-h|--help) usage ;;
*) usage >&2; die "unknown command '$command'" ;;
esac
