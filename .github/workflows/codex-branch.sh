#!/bin/sh

set -eu

me=codex-branch
tmp_dir=
temporary_worktree=
preserve_worktree=
script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
script_path=$script_dir/$(basename "$0")
tab=$(printf '\t')

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
	   or: codex-branch rewrite [--remote <remote>] [--base <branch>]
		[--codex <branch>] [--rerere-from <branch>]
		[--result <path>] [--updates <path>] [--inputs <path>]
		[--bundle <path>] [--failure <path>] [--worktree <path>]
	   or: codex-branch verify-inputs [--remote <remote>]
		[--base <branch>] [--codex <branch>] <snapshot>
	   or: codex-branch verify-output --inputs <path>
		--updates <path> --result <path>
	   or: codex-branch publish [--remote <remote>]
		--inputs <path> --updates <path>
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

resolve_commit () {
	git rev-parse --verify "$1^{commit}" 2>/dev/null ||
		die "'$1' is not a commit"
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

control_paths_unchanged () (
	base_oid=$1
	head_oid=$2
	git diff --quiet "$base_oid" "$head_oid" -- \
		.github/CODEX.md \
		.github/rulesets/codex-branch.json \
		.github/rulesets/codex-topics.json \
		.github/workflows/codex.yml \
		.github/workflows/codex-branch.sh \
		t/t9905-codex-branch.sh
)

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
		printf 'controller\tmeta\t%s\n' "$controller_oid"
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
	controller_oid=${6:-}

	if test -z "$controller_oid"
	then
		controller_oid=$(resolve_commit HEAD)
	else
		controller_oid=$(resolve_commit "$controller_oid")
	fi
	remote_controller_oid=$(resolve_commit "$(remote_ref "$remote" meta)")
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

map_lookup () {
	map=$1
	old=$2
	awk -F '\t' -v old="$old" '$1 == old { value=$2 } END {
		if (value != "") print value
	}' "$map"
}

map_record () {
	map=$1
	old=$2
	new=$3
	existing=$(map_lookup "$map" "$old")
	if test -n "$existing"
	then
		test "$existing" = "$new" ||
			die "commit $old was mapped to both $existing and $new"
		return
	fi
	printf '%s\t%s\n' "$old" "$new" >>"$map" ||
		die "could not record rewritten commit $old"
}

prepare_plan () {
	base_oid=$1
	topics=$2
	state=$3
	raw=$state/revisions
	commits=$state/commits
	nodes=$state/nodes
	pending=$state/pending
	ready=$state/ready
	plan=$state/plan
	owners=$state/owners

	set -- git rev-list --parents
	while IFS="$tab" read -r name oid
	do
		set -- "$@" "$oid"
	done <"$topics"
	set -- "$@" "^$base_oid"
	"$@" >"$raw"
	awk '{ print $1 }' "$raw" >"$commits"
	: >"$nodes"

	while read -r line
	do
		set -- $line
		old=$1
		shift
		test $# = 1 || {
			owner=$(awk -F '\t' -v old="$old" '
				$2 == old { print $1; exit }
			' "$topics")
			test -n "$owner" || owner=$old
			die "topic history for '$owner' contains merge commit $old; linearize it before refreshing codex"
		}
		parent=$1
		if ! grep -Fqx "$parent" "$commits"
		then
			git merge-base --is-ancestor "$parent" "$base_oid" ||
				die "private commit $old is not based on master"
		fi

		: >"$owners" || die "could not prepare topic ownership"
		while IFS="$tab" read -r name tip
		do
			if git merge-base --is-ancestor "$old" "$tip"
			then
				distance=$(git rev-list --count "$old..$tip") ||
					die "could not measure topic ownership for $old"
				printf '%s\t%s\n' "$distance" "$name" >>"$owners" ||
					die "could not record topic ownership for $old"
			fi
		done <"$topics"
		owner=$(LC_ALL=C sort -t "$tab" -k1,1n -k2,2 "$owners" |
			awk -F '\t' 'NR == 1 { print $2 }')
		test -n "$owner" || die "could not assign private commit $old to a topic"
		printf '%s\t%s\t%s\n' "$old" "$parent" "$owner" >>"$nodes"
	done <"$raw"

	cp "$nodes" "$pending"
	: >"$plan"
	while test -s "$pending"
	do
		: >"$ready"
		while IFS="$tab" read -r old parent owner
		do
			if ! grep -Fqx "$parent" "$commits" ||
				awk -F '\t' -v parent="$parent" \
					'$1 == parent { found=1 } END { exit !found }' "$plan"
			then
				printf '%s\t%s\t%s\n' "$owner" "$old" "$parent" \
					>>"$ready"
			fi
		done <"$pending"
		test -s "$ready" || die "topic history contains an ancestry cycle"
		selected=$(LC_ALL=C sort -t "$tab" -k1,1 -k2,2 "$ready" |
			sed -n '1p')
		IFS="$tab" read -r owner old parent <<-EOF
		$selected
		EOF
		printf '%s\t%s\t%s\n' "$old" "$parent" "$owner" >>"$plan"
		awk -F '\t' -v selected="$old" '$1 != selected' "$pending" \
			>"$pending.next"
		mv "$pending.next" "$pending"
	done

	: >"$state/map"
	while IFS="$tab" read -r name oid
	do
		if git merge-base --is-ancestor "$oid" "$base_oid"
		then
			map_record "$state/map" "$oid" "$base_oid"
		fi
	done <"$topics"
}

rebase_in_progress () {
	worktree=$1
	test -d "$(git -C "$worktree" rev-parse --git-path rebase-merge)" ||
		test -d "$(git -C "$worktree" rev-parse --git-path rebase-apply)"
}

continue_rerere_resolution () {
	worktree=$1

	if rebase_in_progress "$worktree" &&
		test -z "$(git -C "$worktree" -c core.fsmonitor=false ls-files -u)"
	then
		GIT_EDITOR=true git -C "$worktree" \
			-c core.hooksPath=/dev/null \
			-c core.fsmonitor=false \
			-c commit.gpgSign=false \
			-c rerere.enabled=true \
			-c rerere.autoupdate=true \
			rebase --continue ||
			die "git rebase --continue failed after rerere staged a resolution"
		if rebase_in_progress "$worktree"
		then
			die "one-commit rebase unexpectedly remained in progress"
		fi
		return 0
	fi

	! rebase_in_progress "$worktree"
}

rebase_one () {
	worktree=$1
	old=$2
	old_parent=$3
	new_parent=$4

	git -C "$worktree" -c core.fsmonitor=false \
		-c advice.detachedHead=false switch --detach "$old" >/dev/null ||
		die "could not check out commit $old for rebasing"
	if GIT_EDITOR=true git -C "$worktree" \
		-c core.hooksPath=/dev/null \
		-c core.fsmonitor=false \
		-c commit.gpgSign=false \
		-c rerere.enabled=true \
		-c rerere.autoupdate=true \
		rebase --merge --empty=drop --reapply-cherry-picks \
		--no-autostash --no-update-refs \
		--onto "$new_parent" "$old_parent"
	then
		return 0
	fi

	rebase_in_progress "$worktree" ||
		die "git rebase failed without leaving recoverable state"
	continue_rerere_resolution "$worktree"
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
	map=$state/map
	updates=$state/topic-updates
	: >"$updates" || die "could not prepare topic updates"
	while IFS="$tab" read -r name old
	do
		new=$(map_lookup "$map" "$old")
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

	cp "$state/topic-updates" "$output.unsorted" ||
		die "could not prepare complete update manifest"
	printf 'refs/heads/%s\t%s\t%s\n' \
		"$codex_name" "$codex_oid" "$candidate" >>"$output.unsorted" ||
		die "could not record the codex update"
	LC_ALL=C sort "$output.unsorted" >"$output" ||
		die "could not sort the complete update manifest"
	rm -f "$output.unsorted"
}

process_plan () {
	worktree=$1
	state=$2
	base_oid=$(state_value "$state" base-oid)
	map=$state/map
	plan=$state/plan

	while IFS="$tab" read -r old old_parent owner
	do
		test -z "$(map_lookup "$map" "$old")" || continue
		if grep -Fqx "$old_parent" "$state/commits"
		then
			new_parent=$(map_lookup "$map" "$old_parent")
			test -n "$new_parent" ||
				die "parent $old_parent was not rewritten before $old"
		else
			new_parent=$base_oid
		fi

		if test "$old_parent" = "$new_parent"
		then
			map_record "$map" "$old" "$old" ||
				die "could not preserve commit $old"
			continue
		fi

		if rebase_one "$worktree" "$old" "$old_parent" "$new_parent"
		then
			new=$(git -C "$worktree" rev-parse HEAD) ||
				die "could not read the rebased commit for $old"
			map_record "$map" "$old" "$new" ||
				die "could not record the rebased commit for $old"
		else
			printf '%s\n' "$old" >"$state/failed-old" || return 1
			printf '%s\n' "$owner" >"$state/failed-owner" || return 1
			printf '%s\n' "$old_parent" >"$state/failed-parent" || return 1
			printf '%s\n' "$new_parent" >"$state/failed-onto" || return 1
			return 1
		fi
	done <"$plan"

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
	failed_old=$(state_value "$state" failed-old)
	inputs_oid=$(input_oid "$state/inputs")

	{
		say "## No refs were updated"
		say
		say "Rebasing \`$failed_owner\` stopped at \`$failed_old\`."
		say "The controller did not push any topic branch or \`codex\`."
		say
		say "From a clean clone, reproduce the exact pinned rebase with:"
		say
		say '```sh'
		printf 'git fetch %s +refs/heads/\\*:refs/remotes/%s/\\*\n' \
			"$(shell_quote "$remote")" "$remote"
		printf 'git switch --detach %s\n' "$(shell_quote "$controller_oid")"
		printf './.github/workflows/codex-branch.sh resolve \\\n'
		printf '  --remote %s --base %s --codex %s \\\n' \
			"$(shell_quote "$remote")" \
			"$(shell_quote "$base_name")" \
			"$(shell_quote "$codex_name")"
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
		say 'git rebase --continue'
		say '```'
		say
		say "Repeat edit/add/continue until that rebase finishes, then run the"
		say "\`codex-branch continue\` command printed by the helper. It finishes"
		say "the remaining graph and prints one exact-lease atomic topic push."
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
		say "coherent topic graph and rerun the latest \`meta\` workflow."
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

	if git -C "$worktree" \
		-c user.name='github-actions[bot]' \
		-c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
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
	git -C "$worktree" \
		-c user.name='github-actions[bot]' \
		-c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
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
	control_paths_unchanged "$base_oid" "$candidate" ||
		die "a Codex topic changes meta-only controller files"

	printf '%s\n' "$candidate"
}

create_bundle () {
	bundle=$1
	state=$2
	candidate=$3
	base_oid=$(state_value "$state" base-oid)

	test ! -e "$bundle" || die "bundle path '$bundle' already exists"
	git update-ref refs/codex-output/candidate "$candidate" ||
		die "could not retain the bundle candidate"
	set -- git bundle create "$bundle" refs/codex-output/candidate
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
		die "could not create candidate bundle"
	fi
	git update-ref -d refs/codex-output/candidate ||
		die "could not remove the temporary bundle ref"
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

	mkdir -p "$state"
	cp "$inputs" "$state/inputs"
	cp "$topics" "$state/topics"
	controller_oid=$(awk -F '\t' '$1 == "controller" { print $3 }' "$inputs")
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	codex_oid=$(awk -F '\t' '$1 == "codex" { print $3 }' "$inputs")
	printf '%s\n' "$controller_oid" >"$state/controller-oid"
	printf '%s\n' "$remote" >"$state/remote"
	printf '%s\n' "$base_name" >"$state/base-name"
	printf '%s\n' "$base_oid" >"$state/base-oid"
	printf '%s\n' "$codex_name" >"$state/codex-name"
	printf '%s\n' "$codex_oid" >"$state/codex-oid"
	printf '%s\n' "$rerere_name" >"$state/rerere-name"
	printf '%s\n' "$script_path" >"$state/helper"

	prepare_plan "$base_oid" "$state/topics" "$state"
	if test -n "$rerere_name" && test "$codex_oid" != "$base_oid"
	then
		train_rerere "$worktree" "$base_oid" "$codex_oid"
	fi
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
		"$worktree" "$state" "$inputs" "$topics"

	if ! process_plan "$worktree" "$state"
	then
		write_failure "$failure_file" "$state" "$worktree"
		die "conflict while rebasing '$(state_value "$state" failed-owner)'; no refs were updated"
	fi

	if ! candidate=$(assemble_candidate "$worktree" "$state")
	then
		write_integration_failure "$failure_file" "$state" "$worktree"
		die "codex integration conflicts while merging '$(state_value "$state" integration-failed-name)'; no refs were updated"
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

verify_output () {
	inputs=
	updates=
	result=
	while test $# -gt 0
	do
		case "$1" in
		--inputs) require_arg "$@"; inputs=$2; shift 2 ;;
		--updates) require_arg "$@"; updates=$2; shift 2 ;;
		--result) require_arg "$@"; result=$2; shift 2 ;;
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
	awk -F '\t' '$1 == "codex" || $1 == "topic" { print $2 }' "$inputs" \
		| LC_ALL=C sort >"$tmp_dir/expected-update-refs"
	cut -f1 "$updates" | LC_ALL=C sort >"$tmp_dir/actual-update-refs"
	cmp -s "$tmp_dir/expected-update-refs" "$tmp_dir/actual-update-refs" ||
		die "updates do not cover exactly codex and every snapshotted topic"
	base_oid=$(awk -F '\t' '$1 == "base" { print $3 }' "$inputs")
	test -n "$base_oid" || die "input snapshot has no base commit"
	git merge-base --is-ancestor "$base_oid" "$candidate" ||
		die "candidate is not based on the snapshotted master"
	control_paths_unchanged "$base_oid" "$candidate" ||
		die "candidate changes meta-only controller files"
	while IFS="$tab" read -r ref old new
	do
		git check-ref-format "$ref" >/dev/null || die "invalid update ref '$ref'"
		expected_old=$(awk -F '\t' -v ref="$ref" '$2 == ref { print $3 }' \
			"$inputs")
		test "$old" = "$expected_old" ||
			die "old value for '$ref' does not match the input snapshot"
		resolve_commit "$old" >/dev/null
		resolve_commit "$new" >/dev/null
		case "$ref" in
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
	while IFS="$tab" read -r ref_a old_a new_a
	do
		case "$ref_a" in refs/heads/codex) continue ;; esac
		while IFS="$tab" read -r ref_b old_b new_b
		do
			case "$ref_b" in refs/heads/codex) continue ;; esac
			if git merge-base --is-ancestor "$old_a" "$old_b"
			then
				git merge-base --is-ancestor "$new_a" "$new_b" ||
					die "rewrite lost dependency '$ref_a' -> '$ref_b'"
			fi
		done <"$updates"
	done <"$updates"
}

push_updates () {
	remote=$1
	updates=$2
	filter=$3

	set -- git -c core.hooksPath=/dev/null push --atomic --porcelain
	while IFS="$tab" read -r ref old new
	do
		case "$filter:$ref" in
		topics:refs/heads/codex) continue ;;
		esac
		set -- "$@" "--force-with-lease=$ref:$old"
	done <"$updates"
	set -- "$@" "$remote"
	while IFS="$tab" read -r ref old new
	do
		case "$filter:$ref" in
		topics:refs/heads/codex) continue ;;
		esac
		set -- "$@" "$new:$ref"
	done <"$updates"
	"$@"
}

publish () {
	remote=origin
	inputs=
	updates=
	while test $# -gt 0
	do
		case "$1" in
		--remote) require_arg "$@"; remote=$2; shift 2 ;;
		--inputs) require_arg "$@"; inputs=$2; shift 2 ;;
		--updates) require_arg "$@"; updates=$2; shift 2 ;;
		*) die "unknown publish option '$1'" ;;
		esac
	done
	test -n "$inputs" && test -n "$updates" ||
		die "publish requires --inputs and --updates"
	test -f "$inputs" || die "input snapshot '$inputs' does not exist"
	test -f "$updates" || die "update manifest '$updates' does not exist"
	make_tmp_dir
	candidate=$(awk -F '\t' '$1 == "refs/heads/codex" { print $3 }' \
		"$updates")
	test -n "$candidate" || die "update manifest has no codex candidate"
	printf '%s\n' "$candidate" >"$tmp_dir/publish-result" ||
		die "could not prepare publication verification"
	verify_output --inputs "$inputs" --updates "$updates" \
		--result "$tmp_dir/publish-result"
	verify_inputs --remote "$remote" "$inputs"
	push_updates "$remote" "$updates" all
}

resolve_rebase () {
	remote=origin
	base_name=master
	codex_name=codex
	inputs_oid=
	worktree=

	while test $# -gt 0
	do
		case "$1" in
		--remote) require_arg "$@"; remote=$2; shift 2 ;;
		--base) require_arg "$@"; base_name=$2; shift 2 ;;
		--codex) require_arg "$@"; codex_name=$2; shift 2 ;;
		--inputs-oid) require_arg "$@"; inputs_oid=$2; shift 2 ;;
		--worktree) require_arg "$@"; worktree=$2; shift 2 ;;
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
		"$worktree" "$state" "$inputs" "$topics"

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
	say "  git rebase --continue"
	say
	say "Repeat until the rebase completes, then run:"
	say
	say "  $(shell_quote "$script_path") continue --worktree ."
}

resolved_rebase_tip () {
	worktree=$1
	state=$2
	failed_old=$(state_value "$state" failed-old)
	failed_onto=$(state_value "$state" failed-onto)
	new=$(git -C "$worktree" rev-parse HEAD) ||
		die "could not read the resolved rebase tip"
	test "$new" != "$failed_old" ||
		die "the stopped rebase was aborted; run the pinned resolve command again"

	if test "$new" != "$failed_onto"
	then
		parents=$(git -C "$worktree" rev-list --parents -n 1 "$new") ||
			die "could not inspect the resolved rebase tip"
		set -- $parents
		test $# = 2 && test "$2" = "$failed_onto" ||
			die "resolved rebase tip must be one commit on the pinned parent $failed_onto"
	fi
	printf '%s\n' "$new"
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
	if rebase_in_progress "$worktree"
	then
		die "the rebase is still in progress; resolve it and run git rebase --continue"
	fi
	require_clean_worktree "$worktree"
	failed_old=$(state_value "$state" failed-old)
	new=$(resolved_rebase_tip "$worktree" "$state") ||
		die "could not validate the resolved rebase"
	map_record "$state/map" "$failed_old" "$new"
	rm -f "$state/failed-old" "$state/failed-owner" \
		"$state/failed-parent" "$state/failed-onto"

	if ! process_plan "$worktree" "$state"
	then
		owner=$(state_value "$state" failed-owner)
		say "Another rebase conflict stopped in '$owner'."
		say "Resolve it with git status, edit, git add, and git rebase --continue."
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
		write_integration_failure "$tmp_dir/integration-conflict" \
			"$state" "$candidate_worktree"
		cat "$tmp_dir/integration-conflict" >&2
		die "topic graph cannot be integrated; no refs were updated"
	fi
	write_complete_updates "$state" "$candidate" "$tmp_dir/updates"
	printf '%s\n' "$candidate" >"$tmp_dir/result" ||
		die "could not prepare topic verification"
	(
		cd "$worktree" || exit 1
		verify_output --inputs "$state/inputs" \
			--updates "$tmp_dir/updates" --result "$tmp_dir/result"
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
	say "Topic refs updated. Re-run all jobs on the latest meta workflow run to rebuild codex."
}

test $# -gt 0 || { usage >&2; exit 129; }
command=$1
shift
case "$command" in
check-topic) check_topic "$@" ;;
rewrite) rewrite "$@" ;;
verify-inputs) verify_inputs "$@" ;;
verify-output) verify_output "$@" ;;
publish) publish "$@" ;;
resolve) resolve_rebase "$@" ;;
continue) continue_rewrite "$@" ;;
publish-topics) publish_topics "$@" ;;
-h|--help) usage ;;
*) usage >&2; die "unknown command '$command'" ;;
esac
