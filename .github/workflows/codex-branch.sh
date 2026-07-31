#!/bin/sh

set -eu

me=codex-branch
tmp_dir=
script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
rerere_train_script=$script_dir/../../contrib/rerere-train.sh

say () {
	printf '%s\n' "$*"
}

die () {
	printf '%s: %s\n' "$me" "$*" >&2
	exit 1
}

usage () {
	cat <<-\EOF
	usage: $me check-topic <branch>
	   or: $me check-pr <branch> <head-oid> <codex-oid> <master-oid>
	   or: $me assemble [--remote <remote>] [--base <branch>]
		[--rerere-from <branch>] [--result <path>]
		[--inputs <path>] [--failure <path>]
	   or: $me verify-inputs [--remote <remote>] [--base <branch>] <path>
	   or: $me resolve [--remote <remote>] --base <branch> <oid>
		[--rerere-from <branch> <oid>]
		[--merged <topic> <oid>]...
		--failed <topic> <oid> --prefix-tree <oid>
		[--new-topic <topic>] [--worktree <path>]
	EOF
}

cleanup () {
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

	return 0
)

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
		.github/workflows/codex.yml \
		.github/workflows/codex-branch.sh
)

is_active_topic_name () (
	is_topic_name "$1" || return 1
	case "$1" in
	*-wip|*-stale) return 1 ;;
	esac
	return 0
)

check_topic () {
	test $# = 1 || {
		usage >&2
		exit 129
	}

	if ! is_topic_name "$1"
	then
		die "'$1' does not match ??/codex/*"
	fi
	case "$1" in
	*-wip|*-stale)
		die "'$1' is inactive because of its suffix"
		;;
	esac
}

check_pr () {
	test $# = 4 || {
		usage >&2
		exit 129
	}

	name=$1
	head_oid=$(resolve_commit "$2")
	codex_oid=$(resolve_commit "$3")
	master_oid=$(resolve_commit "$4")
	check_topic "$name"
	fork_oid=$(git merge-base "$master_oid" "$head_oid") ||
		die "'$name' has no common ancestor with master"

	if ! git merge-base --is-ancestor "$codex_oid" "$master_oid" &&
		git merge-base --is-ancestor "$codex_oid" "$head_oid"
	then
		die "'$name' contains codex; rebuild it from master or its real topic dependencies"
	fi
	! contains_integration_marker "$master_oid" "$head_oid" ||
		die "'$name' contains a generated codex integration commit"
	control_paths_unchanged "$fork_oid" "$head_oid" ||
		die "'$name' changes the Codex branch control files"
}

require_full_repository () {
	test "$(git rev-parse --is-shallow-repository)" = false ||
		die "a complete, non-shallow repository is required"
}

require_clean_worktree () {
	test -z "$(git -c core.fsmonitor=false status --porcelain)" ||
		die "the current worktree must be clean"
}

remote_ref () {
	printf 'refs/remotes/%s/%s\n' "$1" "$2"
}

resolve_commit () {
	git rev-parse --verify "$1^{commit}" 2>/dev/null ||
		die "'$1' is not a commit"
}

train_rerere () (
	worktree=$1
	base_oid=$2
	tip_oid=$3

	cd "$worktree"
	GIT_CONFIG_COUNT=3 \
	GIT_CONFIG_KEY_0=rerere.enabled \
	GIT_CONFIG_VALUE_0=true \
	GIT_CONFIG_KEY_1=rerere.autoupdate \
	GIT_CONFIG_VALUE_1=true \
	GIT_CONFIG_KEY_2=core.fsmonitor \
	GIT_CONFIG_VALUE_2=false \
		"$rerere_train_script" "$base_oid..$tip_oid"
)

merge_topic () (
	worktree=$1
	name=$2
	oid=$3
	message=$(printf 'Merge %s into codex\n\nCodex-Integration: %s@%s' \
		"$name" "$name" "$oid")

	if git -C "$worktree" \
		-c user.name='Codex conflict resolver' \
		-c user.email='codex-conflict@localhost' \
		-c core.fsmonitor=false \
		-c rerere.enabled=true -c rerere.autoupdate=true \
		merge --no-ff --no-edit --no-gpg-sign -m "$message" "$oid"
	then
		return 0
	fi
	git -C "$worktree" rev-parse --verify -q MERGE_HEAD >/dev/null &&
		test -z "$(git -C "$worktree" -c core.fsmonitor=false ls-files -u)" ||
		return 1
	git -C "$worktree" -c core.fsmonitor=false diff --cached --check
	git -C "$worktree" \
		-c user.name='Codex conflict resolver' \
		-c user.email='codex-conflict@localhost' \
		-c core.fsmonitor=false \
		commit --no-edit --no-gpg-sign
)

collect_topics () (
	remote=$1
	output=$2
	root=refs/remotes/$remote/
	tab=$(printf '\t')

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

write_input_snapshot () (
	base_name=$1
	base_oid=$2
	candidates=$3
	output=$4

	{
		printf 'base\t%s\t%s\n' "$base_name" "$base_oid"
		sed 's/^/topic\t/' "$candidates"
	} >"$output"
)

discover_topics () {
	remote=$1
	base_oid=$2
	plan=$3
	tab=$(printf '\t')
	candidates=$tmp_dir/candidates
	unique=$tmp_dir/unique
	not_in_base=$tmp_dir/not-in-base

	collect_topics "$remote" "$candidates"

	# Equal tips are aliases. Keep the first name as their stable display
	# name before doing any ancestry reduction.
	awk -F '\t' '!seen[$2]++ { print }' "$candidates" >"$unique"
	: >"$not_in_base"
	while IFS="$tab" read -r name oid
	do
		fork_oid=$(git merge-base "$base_oid" "$oid") ||
			die "topic '$name' has no common ancestor with the base"
		! contains_integration_marker "$base_oid" "$oid" ||
			die "topic '$name' contains a generated codex integration commit"
		control_paths_unchanged "$fork_oid" "$oid" ||
			die "topic '$name' changes the Codex branch control files"
		if ! git merge-base --is-ancestor "$oid" "$base_oid"
		then
			printf '%s\t%s\n' "$name" "$oid" >>"$not_in_base"
		fi
	done <"$unique"

	: >"$plan"
	while IFS="$tab" read -r name oid
	do
		dominated=
		while IFS="$tab" read -r other_name other_oid
		do
			test "$oid" = "$other_oid" && continue
			if git merge-base --is-ancestor "$oid" "$other_oid"
			then
				dominated=t
				break
			fi
		done <"$not_in_base"
		test -n "$dominated" ||
			printf '%s\t%s\n' "$name" "$oid" >>"$plan"
	done <"$not_in_base"
}

shell_quote () (
	quoted=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
	printf "'%s'" "$quoted"
)

write_failure () (
	path=$1
	remote=$2
	base_name=$3
	base_oid=$4
	failed_name=$5
	failed_oid=$6
	prefix_tree=$7
	completed=$8
	rerere_name=$9
	rerere_oid=${10}

	test -n "$path" || return 0
	{
		say "## codex was not changed"
		say
		say "The candidate conflicted while merging \`$failed_name\` at \`$failed_oid\`."
		say "Resolve it from a clean clone with:"
		say
		say '```sh'
		printf './.github/workflows/codex-branch.sh resolve \\\n'
		printf '  --remote %s \\\n' "$(shell_quote "$remote")"
		printf '  --base %s %s \\\n' \
			"$(shell_quote "$base_name")" "$(shell_quote "$base_oid")"
		if test -n "$rerere_name"
		then
			printf '  --rerere-from %s %s \\\n' \
				"$(shell_quote "$rerere_name")" \
				"$(shell_quote "$rerere_oid")"
		fi
		while IFS="$(printf '\t')" read -r name oid
		do
			printf '  --merged %s %s \\\n' \
				"$(shell_quote "$name")" "$(shell_quote "$oid")"
		done <"$completed"
		printf '  --failed %s %s \\\n' \
			"$(shell_quote "$failed_name")" "$(shell_quote "$failed_oid")"
		printf '  --prefix-tree %s\n' "$(shell_quote "$prefix_tree")"
		say '```'
		say
		say "The helper will print the worktree path and the exact commit and push commands."
		say "Push the resolution to \`$failed_name\`, or pass \`--new-topic ??/codex/name\`"
		say "to create a successor. Never push a resolution directly to \`codex\`."
		if test -n "$(git -c core.fsmonitor=false \
			diff --name-only --diff-filter=U)"
		then
			say
			say "Conflicted paths:"
			git -c core.fsmonitor=false diff --name-only --diff-filter=U |
				sed 's/^/- `/' | sed 's/$/`/'
		fi
	} >"$path"
)

assemble () {
	remote=origin
	base_name=master
	rerere_from=
	result_file=
	inputs_file=
	failure_file=

	while test $# -gt 0
	do
		case "$1" in
		--remote)
			require_arg "$@"
			remote=$2
			shift 2
			;;
		--base)
			require_arg "$@"
			base_name=$2
			shift 2
			;;
		--rerere-from)
			require_arg "$@"
			rerere_from=$2
			shift 2
			;;
		--result)
			require_arg "$@"
			result_file=$2
			shift 2
			;;
		--inputs)
			require_arg "$@"
			inputs_file=$2
			shift 2
			;;
		--failure)
			require_arg "$@"
			failure_file=$2
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown assemble option '$1'"
			;;
		esac
	done

	make_tmp_dir
	require_full_repository
	require_clean_worktree
	base_ref=$(remote_ref "$remote" "$base_name")
	base_oid=$(resolve_commit "$base_ref")
	plan=$tmp_dir/plan
	completed=$tmp_dir/completed
	: >"$completed"
	rerere_name=
	rerere_oid=
	discover_topics "$remote" "$base_oid" "$plan"
	if test -n "$inputs_file"
	then
		write_input_snapshot "$base_name" "$base_oid" \
			"$tmp_dir/candidates" "$inputs_file"
	fi

	if test -n "$rerere_from"
	then
		rerere_ref=$(remote_ref "$remote" "$rerere_from")
		if git rev-parse --verify -q "$rerere_ref^{commit}" >/dev/null
		then
			rerere_name=$rerere_from
			rerere_oid=$(resolve_commit "$rerere_ref")
			train_rerere . "$base_oid" "$rerere_oid"
		fi
	fi

	git -c core.fsmonitor=false switch --detach "$base_oid"
	while IFS="$(printf '\t')" read -r name oid
	do
		before=$(git rev-parse HEAD)
		if merge_topic . "$name" "$oid"
		then
			:
		else
			prefix_tree=$(git rev-parse "$before^{tree}")
			write_failure "$failure_file" "$remote" "$base_name" \
				"$base_oid" "$name" "$oid" "$prefix_tree" "$completed" \
				"$rerere_name" "$rerere_oid"
			die "conflict while merging '$name'; codex was not changed"
		fi
		printf '%s\t%s\n' "$name" "$oid" >>"$completed"
	done <"$plan"

	# The plan contains only maximal tips, but verify every active topic as
	# a final guard against discovery or ancestry-reduction mistakes.
	while IFS="$(printf '\t')" read -r name oid
	do
		git merge-base --is-ancestor "$oid" HEAD ||
			die "assembled candidate does not contain '$name'"
	done <"$tmp_dir/candidates"
	control_paths_unchanged "$base_oid" HEAD ||
		die "a Codex topic changes the branch control files"

	candidate=$(git rev-parse HEAD)
	if test -n "$result_file"
	then
		printf '%s\n' "$candidate" >"$result_file"
	fi
	say "assembled codex candidate $candidate"
}

verify_inputs () {
	remote=origin
	base_name=master

	while test $# -gt 1
	do
		case "$1" in
		--remote)
			test $# -ge 3 || die "--remote needs one argument"
			remote=$2
			shift 2
			;;
		--base)
			test $# -ge 3 || die "--base needs one argument"
			base_name=$2
			shift 2
			;;
		*)
			break
			;;
		esac
	done
	test $# = 1 || {
		usage >&2
		exit 129
	}
	expected=$1
	test -f "$expected" || die "input snapshot '$expected' does not exist"

	make_tmp_dir
	require_full_repository
	refspec=+refs/heads/\*:refs/remotes/$remote/\*
	git -c core.fsmonitor=false fetch --force --prune "$remote" "$refspec"
	base_ref=$(remote_ref "$remote" "$base_name")
	base_oid=$(resolve_commit "$base_ref")
	candidates=$tmp_dir/verify-candidates
	actual=$tmp_dir/verify-inputs
	collect_topics "$remote" "$candidates"
	write_input_snapshot "$base_name" "$base_oid" "$candidates" "$actual"

	if ! cmp -s "$expected" "$actual"
	then
		diff -u "$expected" "$actual" >&2 || :
		die "master or a Codex topic moved while the candidate was running"
	fi
}

verify_pinned_ref () (
	remote=$1
	name=$2
	expected=$3
	ref=$(remote_ref "$remote" "$name")
	actual=$(resolve_commit "$ref")
	test "$actual" = "$expected" ||
		die "'$name' moved from $expected to $actual; rerun the refresh Action"
)

verify_pinned_ancestor () (
	remote=$1
	name=$2
	expected=$3
	ref=$(remote_ref "$remote" "$name")
	actual=$(resolve_commit "$ref")
	git merge-base --is-ancestor "$expected" "$actual" ||
		die "'$name' no longer contains pinned commit $expected; rerun the refresh Action"
)

resolve_conflict () {
	remote=origin
	base_name=
	base_oid=
	rerere_name=
	rerere_oid=
	failed_name=
	failed_oid=
	prefix_tree=
	new_topic=
	worktree=

	make_tmp_dir
	merged=$tmp_dir/merged
	: >"$merged"

	while test $# -gt 0
	do
		case "$1" in
		--remote)
			test $# -ge 2 || die "--remote needs one argument"
			remote=$2
			shift 2
			;;
		--base)
			test $# -ge 3 || die "--base needs a branch and an object ID"
			base_name=$2
			base_oid=$3
			shift 3
			;;
		--rerere-from)
			test $# -ge 3 ||
				die "--rerere-from needs a branch and an object ID"
			rerere_name=$2
			rerere_oid=$3
			shift 3
			;;
		--merged)
			test $# -ge 3 || die "--merged needs a topic and an object ID"
			printf '%s\t%s\n' "$2" "$3" >>"$merged"
			shift 3
			;;
		--failed)
			test $# -ge 3 || die "--failed needs a topic and an object ID"
			failed_name=$2
			failed_oid=$3
			shift 3
			;;
		--prefix-tree)
			test $# -ge 2 || die "--prefix-tree needs an object ID"
			prefix_tree=$2
			shift 2
			;;
		--new-topic)
			test $# -ge 2 || die "--new-topic needs a branch"
			new_topic=$2
			shift 2
			;;
		--worktree)
			test $# -ge 2 || die "--worktree needs a path"
			worktree=$2
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown resolve option '$1'"
			;;
		esac
	done

	test -n "$base_name" && test -n "$base_oid" ||
		die "resolve requires --base"
	test -n "$failed_name" && test -n "$failed_oid" ||
		die "resolve requires --failed"
	test -n "$prefix_tree" || die "resolve requires --prefix-tree"
	is_active_topic_name "$failed_name" ||
		die "failed topic '$failed_name' does not match active ??/codex/*"
	target=$failed_name
	if test -n "$new_topic"
	then
		is_active_topic_name "$new_topic" ||
			die "new topic '$new_topic' does not match active ??/codex/*"
		target=$new_topic
	fi

	require_full_repository
	refspec=+refs/heads/\*:refs/remotes/$remote/\*
	git -c core.fsmonitor=false fetch --force --prune "$remote" "$refspec"
	verify_pinned_ref "$remote" "$base_name" "$base_oid"
	verify_pinned_ref "$remote" "$failed_name" "$failed_oid"
	if test -n "$rerere_name"
	then
		verify_pinned_ancestor "$remote" "$rerere_name" "$rerere_oid"
	fi
	while IFS="$(printf '\t')" read -r name oid
	do
		is_active_topic_name "$name" ||
			die "merged topic '$name' does not match active ??/codex/*"
		verify_pinned_ref "$remote" "$name" "$oid"
	done <"$merged"
	if test -n "$new_topic" &&
		git show-ref --verify --quiet "refs/remotes/$remote/$new_topic"
	then
		die "new topic '$new_topic' already exists"
	fi

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

	git -c core.fsmonitor=false worktree add --detach "$worktree" "$base_oid"
	if test -n "$rerere_name"
	then
		train_rerere "$worktree" "$base_oid" "$rerere_oid"
	fi
	while IFS="$(printf '\t')" read -r name oid
	do
		merge_topic "$worktree" "$name" "$oid" ||
			die "could not reconstruct completed topic '$name'"
	done <"$merged"
	actual_tree=$(git -C "$worktree" rev-parse HEAD^{tree})
	test "$actual_tree" = "$prefix_tree" ||
		die "reconstructed prefix tree is $actual_tree, expected $prefix_tree"
	parent_args=$(awk -F '\t' -v base="$base_oid" '
		BEGIN { printf "-p %s", base }
		{ printf " -p %s", $2 }
	' "$merged")
	prefix_message=$(printf 'Codex conflict-resolution prefix\n\nCodex-Resolution-Prefix: %s' \
		"$prefix_tree")
	# parent_args contains only object IDs resolved above.
	prefix_oid=$(printf '%s\n' "$prefix_message" |
		git -C "$worktree" \
			-c user.name='Codex conflict resolver' \
			-c user.email='codex-conflict@localhost' \
			-c core.fsmonitor=false \
			-c commit.gpgsign=false \
			commit-tree "$prefix_tree" $parent_args)

	git -C "$worktree" -c core.fsmonitor=false \
		switch --detach "$failed_oid"
	if git -C "$worktree" -c core.fsmonitor=false \
		merge --no-ff --no-commit "$prefix_oid"
	then
		:
	else
		git -C "$worktree" rev-parse --verify -q MERGE_HEAD >/dev/null ||
			die "could not start the resolution merge"
	fi
	git -C "$worktree" rev-parse --verify -q MERGE_HEAD >/dev/null ||
		die "the failed topic already contains the reconstructed prefix"

	say
	say "Resolution worktree: $worktree"
	say "Resolve and publish with:"
	say
	say "  cd $(shell_quote "$worktree")"
	say "  # Edit the conflicted files."
	say "  git add <files>"
	say "  git diff --cached --check"
	say "  git commit"
	if test -n "$new_topic"
	then
		lease="refs/heads/$target:"
	else
		lease="refs/heads/$target:$failed_oid"
	fi
	say "  git push --force-with-lease=$(shell_quote "$lease") $(shell_quote "$remote") HEAD:$(shell_quote "refs/heads/$target")"
	say
	say "This records the dependency and resolution on '$target'."
	say "Do not push this resolution to codex. Rerun the refresh Action instead."
}

test $# -gt 0 || {
	usage >&2
	exit 129
}

command=$1
shift
case "$command" in
check-topic) check_topic "$@" ;;
check-pr) check_pr "$@" ;;
assemble) assemble "$@" ;;
verify-inputs) verify_inputs "$@" ;;
resolve) resolve_conflict "$@" ;;
-h|--help) usage ;;
*)
	usage >&2
	die "unknown command '$command'"
	;;
esac
