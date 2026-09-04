#!/usr/bin/env bash
# Coordinate releases; source builds run separately without publisher tokens.
# jq expressions contain literal dollar signs; chained tests deliberately fail
# when either condition is false.
# shellcheck disable=SC2016,SC2015
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tool_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
config=$script_dir/config.json
config_path=.github/release/config.json
worktree=.
command=
channel='' source_sha='' version='' upstream_tag='' recipe_sha='' output=''
candidate='' artifacts='' source_ref='' review_pr='' target='' run_id=''
repository_arg='' recipe_repository='' directory='' base_version=''
stage=false

die () { printf 'git-release: %s\n' "$*" >&2; exit 1; }
usage () {
	cat <<-EOF
	usage: release.sh [--config <file>] [--worktree <path>] <command> [options]
	commands: check-config, validate-plan, pin, prepare, sync, record-build,
	          manifest, publish, rollback, download
	EOF
}
while test $# -gt 0
do
	case "$1" in
	-h|--help) usage; exit 0 ;;
	--stage) stage=true; shift; continue ;;
	check-config|validate-plan|pin|prepare|sync|record-build|manifest|publish|rollback|download)
		test -z "$command" || die 'more than one command'
		command=$1; shift; continue ;;
	esac
	test $# -ge 2 || die "missing value for $1"
	case "$1" in
	--config) config=$2 ;; --worktree) worktree=$2 ;;
	--channel) channel=$2 ;; --source-sha) source_sha=$2 ;;
	--version) version=$2 ;; --upstream-tag) upstream_tag=$2 ;;
	--recipe-sha) recipe_sha=$2 ;; --output) output=$2 ;;
	--candidate) candidate=$2 ;; --artifacts) artifacts=$2 ;;
	--source-ref) source_ref=$2 ;; --review-pr) review_pr=$2 ;;
	--target) target=$2 ;; --run-id) run_id=$2 ;;
	--repository) repository_arg=$2 ;; --recipe-repository) recipe_repository=$2 ;;
	--directory) directory=$2 ;; --base-version) base_version=$2 ;;
	*) die "unknown option: $1" ;;
	esac
	shift 2
done
test -n "$command" || { usage >&2; exit 129; }
command -v jq >/dev/null || die 'jq is required'
scratch=$(mktemp -d "${TMPDIR:-/tmp}/git-release.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

json () { jq -L "$script_dir" "$@"; }
canonical () { jq -S -a . "$1"; }
new_file () { mktemp "$scratch/data.XXXXXX"; }
field () { jq -r "$2 | if . == null then error(\"missing field\") else . end" "$1"; }
check_json () { json -e "$@" >/dev/null; }
require_value () {
	json -en --arg value "$1" "include \"release\"; \$value | $2" >/dev/null ||
		die "$3"
}
same_json () { jq -e -s '.[0] == .[1]' "$1" "$2" >/dev/null || die "$3"; }
hash_file () {
	if command -v sha256sum >/dev/null
	then sha256sum "$1"
	else shasum -a 256 "$1"
	fi | awk '{print $1}'
}
hash_json () {
	local normalized
	normalized=$(new_file)
	canonical "$1" >"$normalized"
	hash_file "$normalized"
}
git_cmd () {
	git -c core.hooksPath=/dev/null -c core.fsmonitor=false \
		-c commit.gpgSign=false -C "$worktree" "$@"
}

# Keep authentication with gh. Every API destination is constructed from the
# reviewed config, never from an uploaded URL or artifact.
api () {
	local path=$1 destination=$2 method=${3:-GET} payload=${4:-}
	local raw=${5:-false} optional=${6:-false} error
	local args=(api --hostname github.com "$path" --method "$method")
	error=$(new_file)
	test -z "$payload" || args+=(--input "$payload")
	test "$raw" = false || args+=(-H 'Accept: application/octet-stream')
	if gh "${args[@]}" >"$destination" 2>"$error"
	then return
	fi
	if test "$optional" = true && grep -q 'HTTP 404' "$error"
	then printf 'null\n' >"$destination"; return
	fi
	cat "$error" >&2
	die "GitHub request failed: $method $path"
}
get_ref () {
	local repository=$1 ref=$2 response
	response=$(new_file)
	api "repos/$repository/git/ref/${ref#refs/}" "$response" GET '' false true
	if test "$(cat "$response")" = null
	then printf 'null\n'; return
	fi
	json -er --arg ref "$ref" 'include "release";
		require(.ref == $ref and (.object.sha | oid); "ambiguous GitHub ref") |
		.object.sha' "$response"
}
get_content () {
	local repository=$1 ref=$2 path=$3 destination=$4 optional=${5:-false} response
	response=$(new_file)
	api "repos/$repository/contents/$path?ref=$ref" "$response" GET '' false "$optional"
	if test "$(cat "$response")" = null
	then printf 'null\n' >"$destination"; return
	fi
	jq -e '.type == "file" and .encoding == "base64"' "$response" >/dev/null ||
		die 'expected a small configuration file'
	jq -j '.content | @base64d' "$response" >"$destination"
}
get_release () {
	require_value "$2" name 'invalid release version'
	api "repos/$1/releases/tags/$2" "$3" GET '' false true
}
tag_commit () {
	local repository=$1 tag=$2 commit response attempts=0
	commit=$(get_ref "$repository" "refs/tags/$tag")
	test "$commit" != null || { printf 'null\n'; return; }
	while test "$attempts" -lt 8
	do
		attempts=$((attempts + 1))
		response=$(new_file)
		api "repos/$repository/git/tags/$commit" "$response" GET '' false true
		if test "$(cat "$response")" = null
		then printf '%s\n' "$commit"; return
		fi
		commit=$(field "$response" '.object.sha')
		require_value "$commit" oid 'invalid tag object'
		case "$(field "$response" '.object.type')" in
		commit) printf '%s\n' "$commit"; return ;;
		tag) ;;
		*) die 'release tag does not name a commit' ;;
		esac
	done
	die 'release tag nesting is too deep'
}
get_asset () {
	require_value "$2" 'tonumber | positive_integer' 'invalid asset ID'
	api "repos/$1/releases/assets/$2" "$3" GET '' true
}
destination () {
	local actual urls mode
	test -z "${GITHUB_REPOSITORY:-}" || test "$GITHUB_REPOSITORY" = "$repo" ||
		die 'caller repository differs from release destination'
	actual=$(new_file)
	api "repos/$repo" "$actual"
	jq -e --arg repo "$repo" --arg visibility "$visibility" \
		'.full_name == $repo and .visibility == $visibility' "$actual" >/dev/null ||
		die 'repository identity or visibility changed'
	for mode in fetch push
	do
		if test "$mode" = push
		then urls=$(git_cmd remote get-url --push --all origin)
		else urls=$(git_cmd remote get-url --all origin)
		fi
		case "$urls" in
		"https://github.com/$repo"|"https://github.com/$repo.git"|"git@github.com:$repo"|"git@github.com:$repo.git") ;;
		*) die 'origin does not point only to the configured release repository' ;;
		esac
	done
}
control () {
	local current live
	current=$(get_ref "$repo" "$control_ref")
	test "$current" != null || die 'release control branch is missing'
	live=$(new_file)
	get_content "$repo" "$current" "$config_path" "$live"
	same_json "$live" "$config" 'local configuration differs from current reviewed configuration'
	printf '%s\n' "$current"
}
control_tree () {
	local response
	response=$(new_file)
	api "repos/$repo/git/commits/$1" "$response"
	field "$response" '.tree.sha'
}
lane () {
	jq -e --arg channel "$1" '.channels[$channel].enabled == true' "$config" >/dev/null ||
		die 'channel is not enabled; enroll reviewed topics and enable it in a control PR'
	jq -r --arg channel "$1" '.channels[$channel].kind' "$config"
}
lane_field () { jq -r --arg channel "$1" ".channels[\$channel] | $2 | if . == null then error(\"missing lane field\") else . end" "$config"; }
valid_recipe () {
	require_value "$1" oid 'expected a full recipe commit'
	jq -e --arg sha "$1" '(.recipe_sha // $sha) == $sha' "$config" >/dev/null ||
		die 'build recipe differs from configured pin'
}
pointer_at () {
	local repository=$1 selected=$2 ref=$3 destination=$4
	if test "$ref" = null
	then printf 'null\n' >"$destination"
	else get_content "$repository" "$ref" "channels/$selected.json" "$destination" true
	fi
}
pointer () {
	local repository=$1 selected=$2 destination=$3 catalog=${4:-$catalog_ref} ref
	ref=$(get_ref "$repository" "$catalog")
	pointer_at "$repository" "$selected" "$ref" "$destination"
}
released_manifest () {
	local repository=$1 selected=$2 wanted=$3 record=$4 manifest=$5 release=$6
	local id actual_source
	if test -z "$wanted"
	then wanted=$(field "$record" '.version') || die 'channel has no complete release record'
	fi
	get_release "$repository" "$wanted" "$release"
	jq -e '. != null and .draft == false' "$release" >/dev/null || die 'release is absent or incomplete'
	id=$(jq -er '[.assets[] | select(.name == "manifest.json")] |
		if length == 1 then .[0].id else error("release has no unique manifest") end' "$release")
	get_asset "$repository" "$id" "$manifest"
	check_json --arg repo "$repository" --arg channel "$selected" \
		'include "release"; validate_manifest($repo; $channel)' "$manifest"
	test "$(field "$manifest" '.version')" = "$wanted" || die 'release tag/manifest mismatch'
	actual_source=$(tag_commit "$repository" "$wanted")
	test "$actual_source" = "$(field "$manifest" '.source_sha')" || die 'release tag moved'
	if test "$(jq -r '.version // empty' "$record")" = "$wanted"
	then
		test "$(field "$record" '.manifest_sha256')" = "$(hash_file "$manifest")" &&
		test "$(field "$record" '.source_sha')" = "$actual_source" || die 'release record/manifest mismatch'
	fi
	check_json --slurpfile manifest "$manifest" 'include "release";
		verify_asset_metadata($manifest[0])' "$release"
}

check_review () {
	local topic=$1 need_pin=${2:-true} pr reviews response effective author user state
	local tip branch number page permission approved=false count
	tip=$(field "$topic" '.source_sha'); branch=$(field "$topic" '.source_ref')
	number=$(field "$topic" '.review_pr')
	pr=$(new_file); api "repos/$repo/pulls/$number" "$pr"
	jq -e --arg repo "$repo" --arg tip "$tip" --arg branch "$branch" '
		.state == "open" and .draft == false and .head.repo.full_name == $repo and
		.head.sha == $tip and "refs/heads/" + .head.ref == $branch' "$pr" >/dev/null ||
		die 'source review no longer matches the reviewed topic pin'
	author=$(field "$pr" '.user.login')
	reviews=$(new_file); printf '[]\n' >"$reviews"
	page=1
	while :
	do
		response=$(new_file)
		api "repos/$repo/pulls/$number/reviews?per_page=100&page=$page" "$response"
		count=$(jq length "$response")
		effective=$(new_file); jq -s '.[0] + .[1]' "$reviews" "$response" >"$effective"
		reviews=$effective
		test "$count" -eq 100 || break
		page=$((page + 1))
	done
	effective=$(new_file)
	jq -r --arg author "$author" 'reduce .[] as $r ({};
		if $r.state == "COMMENTED" or $r.state == "PENDING" then .
		else .[$r.user.login] = $r end) | to_entries[] |
		select(.key != $author) | [.key, .value.state, .value.commit_id] | @tsv' "$reviews" >"$effective"
	while IFS=$'\t' read -r user state review_tip
	do
		test -n "$user" || continue
		require_value "$user" name 'invalid reviewer name'
		response=$(new_file); api "repos/$repo/collaborators/$user/permission" "$response"
		permission=$(field "$response" '.permission')
		case "$permission" in admin|maintain|write) ;; *) continue ;; esac
		test "$state" != CHANGES_REQUESTED || die 'a source reviewer has requested changes'
		if test "$state" = APPROVED && test "$review_tip" = "$tip"
		then approved=true
		fi
	done <"$effective"
	test "$approved" = true || die 'source pin needs an independent writer approval at its current commit'
	if test "$need_pin" = true
	then test "$(get_ref "$repo" "refs/heads/release-pins/$tip")" = "$tip" || die 'immutable source pin is missing or changed'
	fi
}
retain_pin () {
	local topic existing payload response ref
	destination
	test "$visibility" = private || die 'overlay pins require a private repository'
	require_value "$source_sha" oid 'expected a full source commit'
	require_value "$source_ref" branch 'source must be a branch ref'
	require_value "$review_pr" 'tonumber | positive_integer' 'source review is missing'
	topic=$(new_file)
	jq -n --arg source_ref "$source_ref" --arg source_sha "$source_sha" --argjson review_pr "$review_pr" \
		'{source_ref:$source_ref,source_sha:$source_sha,review_pr:$review_pr}' >"$topic"
	check_review "$topic" false
	ref=refs/heads/release-pins/$source_sha; existing=$(get_ref "$repo" "$ref")
	test "$existing" = null || test "$existing" = "$source_sha" || die 'immutable source pin changed'
	if test "$existing" = null
	then
		payload=$(new_file); response=$(new_file)
		jq -n --arg ref "$ref" --arg sha "$source_sha" '{ref:$ref,sha:$sha}' >"$payload"
		destination; api "repos/$repo/git/refs" "$response" POST "$payload"
	fi
	test "$(get_ref "$repo" "$ref")" = "$source_sha" || die 'could not confirm source pin'
}
check_ledger () {
	local selected=$1 control=$2 source=$3 ledger path key
	path=$(lane_field "$selected" '.ledger_path'); key=$(lane_field "$selected" '.ledger_key')
	ledger=$(new_file); get_content "$repo" "$control" "$path" "$ledger"
	test "$(git config --no-includes --file "$ledger" --get "$key")" = "$source" &&
		test "$(get_ref "$repo" "refs/heads/$selected")" = "$source" ||
		die 'source is no longer the controller-published channel output'
}

artifact_rows () {
	local version=$1 target=$2 folder=$3 result=$4 archive file rows size sum sidecar
	rows=$(new_file)
	for extension in tar.gz lzma
	do
		archive=git-$version-$target.$extension
		for file in "$archive" "$archive.sha256"
		do
			test -f "$folder/$file" && test ! -L "$folder/$file" || die 'missing or non-regular artifact'
			size=$(wc -c <"$folder/$file"); sum=$(hash_file "$folder/$file")
			jq -n --arg name "$file" --argjson size "$size" --arg sha256 "$sum" \
				'{name:$name,size:$size,sha256:$sha256}' >>"$rows"
		done
		sidecar=$(tr -d '\r\n' <"$folder/$archive.sha256")
		test "$sidecar" = "$(hash_file "$folder/$archive")" || die 'archive does not match checksum sidecar'
	done
	jq -s . "$rows" >"$result"
}
record_build () {
	local rows receipt
	require_value "$repository_arg" repository 'invalid build repository'
	require_value "$recipe_repository" repository 'invalid recipe repository'
	require_value "$source_sha" oid 'expected a full source commit'
	require_value "$recipe_sha" oid 'expected a full recipe commit'
	require_value "$version" name 'invalid release version'
	require_value "$target" '. as $target | targets | index($target) != null' 'unknown target'
	test -n "$run_id" || die 'workflow run ID is missing'
	rows=$(new_file); artifact_rows "$version" "$target" "$artifacts" "$rows"
	receipt=$artifacts/git-$version-$target.build.json
	jq -S -a -n --arg repository "$repository_arg" --arg source_sha "$source_sha" \
		--arg version "$version" --arg target "$target" --arg run_id "$run_id" \
		--arg recipe_repository "$recipe_repository" --arg recipe_sha "$recipe_sha" --slurpfile rows "$rows" '
		{repository:$repository,source_sha:$source_sha,version:$version,target:$target,run_id:$run_id,
		 recipe:{repository:$recipe_repository,sha:$recipe_sha},assets:$rows[0]}' >"$receipt"
}
build_manifest () {
	local candidate=$1 folder=$2 result=$3 version records rows receipt target size limit expected actual file
	version=$(field "$candidate" '.version'); require_value "$version" name 'invalid release version'
	test -d "$folder" || die 'artifact directory is missing'
	records=$(new_file); expected=$(new_file); actual=$(new_file)
	for target in macOS-arm64 macOS-x64 ubuntu-arm64 ubuntu-x64 windows-arm64 windows-x64
	do
		receipt=git-$version-$target.build.json
		test -f "$folder/$receipt" && test ! -L "$folder/$receipt" || die 'missing native build receipt'
		rows=$(new_file); artifact_rows "$version" "$target" "$folder" "$rows"
		jq -e --arg target "$target" --slurpfile rows "$rows" \
			'.target == $target and .assets == $rows[0]' "$folder/$receipt" >/dev/null ||
			die 'artifact bytes differ from native build receipt'
		limit=67108864; case "$target" in windows-*) limit=134217728 ;; esac
		size=$(wc -c <"$folder/git-$version-$target.tar.gz")
		test "$size" -le "$limit" || die 'distribution exceeds platform size limit'
		jq -c . "$folder/$receipt" >>"$records"
		printf '%s\n' "$receipt" >>"$expected"
		jq -r '.[].name' "$rows" >>"$expected"
	done
	# Include dotfiles and reject every unexpected directory or symlink too.
	(shopt -s nullglob dotglob; for file in "$folder"/*; do printf '%s\n' "${file##*/}"; done) |
		LC_ALL=C sort >"$actual"
	LC_ALL=C sort "$expected" -o "$expected"
	cmp -s "$expected" "$actual" || die 'unexpected build artifacts'
	json -S -a -n --slurpfile candidate "$candidate" --slurpfile records "$records" \
		'include "release"; manifest_from($candidate[0]; $records)' >"$result"
}

make_candidate () {
	local selected=$1 source=$2 version=$3 tag=$4 recipe=$5 base=$6 topics=$7 result=$8
	local current kind inputs previous source_before tree
	destination; kind=$(lane "$selected"); valid_recipe "$recipe"
	require_value "$source" oid 'expected a full source commit'
	require_value "$version" name 'invalid release version'
	current=$(control)
	if test "$kind" = ledger
	then check_ledger "$selected" "$current" "$source"
	fi
	inputs=$(new_file)
	jq --arg channel "$selected" --arg recipe "$recipe" --slurpfile base "$base" \
		--slurpfile topics "$topics" '
		{repository,visibility,channel:$channel,
		 recipe:{repository:.recipe_repository,sha:$recipe},base:$base[0],topics:$topics[0],
		 build_revision:(.channels[$channel].build_revision // 1)}' "$config" >"$inputs"
	previous=$(new_file); pointer "$repo" "$selected" "$previous"
	source_before=$(get_ref "$repo" "refs/heads/$selected")
	tree=$(control_tree "$current")
	jq -S -a --arg source "$source" --arg version "$version" --arg tag "$tag" \
		--arg control "$current" --arg tree "$tree" --arg hash "$(hash_json "$inputs")" \
		--arg previous_source "$source_before" --slurpfile previous "$previous" \
		--arg run "${GITHUB_RUN_ID:-local}" '. + {schema_version:1,source_sha:$source,
		version:$version,upstream_tag:$tag,control_sha:$control,control_tree:$tree,inputs_sha256:$hash,
		previous_source:(if $previous_source == "null" then null else $previous_source end),
		previous_release:$previous[0],run_id:$run}' "$inputs" >"$result"
}
valid_control () {
	local candidate=$1 selected=$2 current
	current=$(control)
	if test "$current" != "$(field "$candidate" '.control_sha')"
	then
		test "$(lane "$selected")" = overlay &&
			test "$(control_tree "$current")" = "$(field "$candidate" '.control_tree')" ||
			die 'release configuration changed; prepare fresh inputs'
	fi
	printf '%s\n' "$current"
}
check_candidate () {
	local candidate=$1 staged=${2:-true} selected kind source inputs topics topic current pointer_file
	destination
	jq -e --arg repo "$repo" --arg visibility "$visibility" '
		.schema_version == 1 and .repository == $repo and .visibility == $visibility' "$candidate" >/dev/null ||
		die 'candidate destination mismatch'
	selected=$(field "$candidate" '.channel'); kind=$(lane "$selected")
	current=$(valid_control "$candidate" "$selected")
	valid_recipe "$(field "$candidate" '.recipe.sha')"
	test "$(field "$candidate" '.recipe.repository')" = "$(field "$config" '.recipe_repository')" ||
		die 'recipe repository mismatch'
	inputs=$(new_file); json 'include "release"; inputs' "$candidate" >"$inputs"
	test "$(hash_json "$inputs")" = "$(field "$candidate" '.inputs_sha256')" || die 'candidate input checksum mismatch'
	test "$(field "$candidate" '.build_revision')" = "$(lane_field "$selected" '.build_revision // 1')" || die 'build revision changed'
	source=$(field "$candidate" '.source_sha'); require_value "$source" oid 'invalid candidate source'
	require_value "$(field "$candidate" '.version')" name 'invalid release version'
	if test "$kind" = ledger
	then
		check_ledger "$selected" "$current" "$source"
		jq -e '.base == null and .topics == []' "$candidate" >/dev/null || die 'ledger candidate has overlay inputs'
	else
		topics=$(new_file); json --arg channel "$selected" 'include "release"; topics_for($channel)' "$config" >"$topics"
		jq -e --slurpfile topics "$topics" --slurpfile config "$config" --arg channel "$selected" '
			.topics == $topics[0] and .base.repository == $config[0].channels[$channel].upstream.repository and
			.base.channel == $config[0].channels[$channel].upstream.channel' "$candidate" >/dev/null || die 'topic plan or upstream channel changed'
		while IFS= read -r topic
		do
			pointer_file=$(new_file); printf '%s\n' "$topic" >"$pointer_file"; check_review "$pointer_file"
		done < <(jq -c '.[]' "$topics")
		if test "$staged" = true
		then
			test "$(get_ref "$repo" "refs/heads/release-candidates/$(field "$candidate" '.inputs_sha256')")" = "$source" || die 'candidate ref changed'
		fi
		test "$(get_ref "$repo" "refs/heads/$selected")" = "$(jq -r '.previous_source' "$candidate")" || die 'channel source changed'
	fi
	pointer_file=$(new_file); pointer "$repo" "$selected" "$pointer_file"
	jq -e --slurpfile pointer "$pointer_file" '.previous_release == $pointer[0]' "$candidate" >/dev/null ||
		die 'channel release changed; prepare fresh inputs'
}
sync_source () {
	local kind current upstream upstream_channel catalog record manifest release base topics topic topic_file
	local source boundary plan result inputs tag version candidate existing ref published rows
	destination; kind=$(lane "$channel"); test "$kind" = overlay || die 'sync is for overlay channels'
	current=$(control); valid_recipe "$recipe_sha"
	upstream=$(lane_field "$channel" '.upstream.repository')
	upstream_channel=$(lane_field "$channel" '.upstream.channel')
	catalog=$(lane_field "$channel" '.upstream.catalog_ref // "refs/heads/release-catalog"')
	record=$(new_file); manifest=$(new_file); release=$(new_file)
	pointer "$upstream" "$upstream_channel" "$record" "$catalog"
	released_manifest "$upstream" "$upstream_channel" "$base_version" "$record" "$manifest" "$release"
	test "$(field "$manifest" '.visibility')" = public || die 'overlay upstream must be public'
	test -n "$output" || die 'output directory is missing'
	mkdir -m 700 -- "$output"; output=$(CDPATH='' cd -- "$output" && pwd)
	base=$output/public-base.json
	jq -S -a --arg hash "$(hash_file "$manifest")" \
		'{repository,channel,version,source_sha,manifest_sha256:$hash}' "$manifest" >"$base"
	topics=$(new_file); json --arg channel "$channel" 'include "release"; topics_for($channel)' "$config" >"$topics"
	git_cmd fetch --no-tags "https://github.com/$upstream.git" "$(field "$base" '.source_sha')"
	while IFS= read -r topic
	do
		topic_file=$(new_file); printf '%s\n' "$topic" >"$topic_file"; check_review "$topic_file"
		source=$(field "$topic_file" '.source_sha'); boundary=$(field "$topic_file" '.source_base')
		git_cmd fetch --no-tags origin "refs/heads/release-pins/$source"
		test "$(git_cmd rev-parse "$boundary^{commit}")" = "$boundary" || die 'reviewed source boundary is unavailable'
		test -z "$(git_cmd diff --name-only "$boundary" "$source" -- .github)" || die 'overlay topics may not change workflow or controller files'
	done < <(jq -c '.[]' "$topics")
	plan=$output/plan.tsv; result=$output/source-sha
	jq -r '.[] | [.name,.source_sha,.source_base,.dependency] | @tsv' "$topics" >"$plan"
	(cd -- "$worktree" && sh "$tool_root/.github/workflows/codex-branch.sh" assemble-plan \
		--base "$(field "$base" '.source_sha')" --name "$channel" --plan "$plan" \
		--session "$output/replay" --result "$result")
	source=$(cat "$result"); require_value "$source" oid 'invalid composed source'
	test -z "$(git_cmd diff --name-only "$(field "$base" '.source_sha')" "$source" -- .github)" || die 'generated source changed workflow or controller files'
	test "$(control)" = "$current" || die 'release configuration moved during composition'
	# The source pin, recipe, public release and reviewed build revision define
	# the immutable version; workflow retries do not allocate a new version.
	inputs=$(new_file)
	jq --arg channel "$channel" --arg recipe "$recipe_sha" --slurpfile base "$base" --slurpfile topics "$topics" '
		{repository,visibility,channel:$channel,recipe:{repository:.recipe_repository,sha:$recipe},
		base:$base[0],topics:$topics[0],build_revision:(.channels[$channel].build_revision // 1)}' "$config" >"$inputs"
	tag=$(field "$manifest" '.upstream_tag'); require_value "$tag" name 'invalid upstream release tag'
	version=$tag-$channel.$(hash_json "$inputs" | cut -c1-20)
	candidate=$output/candidate.json
	make_candidate "$channel" "$source" "$version" "$tag" "$recipe_sha" "$base" "$topics" "$candidate"
	rows=$(new_file); jq '.noop = false' "$candidate" >"$rows"; mv "$rows" "$candidate"
	if test "$(jq -r '.previous_release.version // empty' "$candidate")" = "$version"
	then
		published=$(new_file); record=$(new_file); jq '.previous_release' "$candidate" >"$record"
		released_manifest "$repo" "$channel" "$version" "$record" "$published" "$release"
		jq -e --slurpfile published "$published" '
			.inputs_sha256 == $published[0].inputs_sha256 and .source_sha == $published[0].source_sha and
			.previous_source == .source_sha' "$candidate" >/dev/null || die 'same release version has different inputs or source'
		rows=$(new_file); jq '.noop = true' "$candidate" >"$rows"; mv "$rows" "$candidate"
	fi
	if test "$stage" = true && test "$(jq .noop "$candidate")" = false
	then
		check_candidate "$candidate" false
		ref=refs/heads/release-candidates/$(field "$candidate" '.inputs_sha256')
		existing=$(get_ref "$repo" "$ref")
		test "$existing" = null || test "$existing" = "$source" || die 'same inputs produced a different candidate'
		if test "$existing" = null
		then destination; git_cmd push "--force-with-lease=$ref:" origin "$source:$ref"
		fi
	fi
}
check_build_jobs () {
	local candidate=$1 kind=$2 run page=1 jobs batch combined
	run=$(field "$candidate" '.run_id')
	require_value "$run" 'test("^[0-9]+$")' 'publication needs its original workflow run'
	test "${GITHUB_RUN_ID:-}" = "$run" || die 'publication needs its original workflow artifacts'
	jobs=$(new_file); printf '[]\n' >"$jobs"
	while :
	do
		batch=$(new_file); combined=$(new_file)
		api "repos/$repo/actions/runs/$run/jobs?filter=all&per_page=100&page=$page" "$batch"
		jq -s '.[0] + .[1].jobs' "$jobs" "$batch" >"$combined"; jobs=$combined
		test "$(jq '.jobs | length' "$batch")" -eq 100 || break
		page=$((page + 1))
	done
	jq -e --arg kind "$kind" 'sort_by(.id) | (reduce .[] as $job
		({}; .[$job.name | split(" / ") | last] = $job.conclusion)) as $latest |
		["macOS arm64","macOS x64","Linux arm64","Linux x64","Windows arm64","Windows x64"] +
		(if $kind == "overlay" then ["Git test suite"] else [] end) |
		all(.[]; $latest[.] == "success")' "$jobs" >/dev/null || die 'required native builds or source tests did not pass'
}
advance () {
	local selected=$1 manifest=$2 previous_source=$3 previous_release=$4 current=$5
	local kind old actual blob tree commit receipt temp record version source
	local GIT_INDEX_FILE GIT_AUTHOR_NAME='Git release controller' GIT_COMMITTER_NAME='Git release controller'
	local GIT_AUTHOR_EMAIL=git-release@users.noreply.github.com GIT_COMMITTER_EMAIL=git-release@users.noreply.github.com
	local args=() updates=()
	kind=$(lane "$selected"); destination
	test "$(control)" = "$current" || die 'configuration changed before channel promotion'
	# Read the catalog pointer from the same commit used by the push lease.
	old=$(get_ref "$repo" "$catalog_ref"); actual=$(new_file)
	pointer_at "$repo" "$selected" "$old" "$actual"
	same_json "$actual" "$previous_release" 'channel moved before promotion'
	test "$(get_ref "$repo" "refs/heads/$selected")" = "$previous_source" || die 'channel source moved before promotion'
	test "$old" = null || git_cmd fetch --no-tags origin "$old"
	source=$(field "$manifest" '.source_sha'); version=$(field "$manifest" '.version')
	git_cmd fetch --no-tags origin "$source"
	record=$(new_file)
	jq -S -a --arg hash "$(hash_file "$manifest")" \
		'{schema_version:1,repository,channel,version,source_sha,manifest_sha256:$hash}' "$manifest" >"$record"
	temp=$(mktemp -d "$scratch/catalog.XXXXXX"); GIT_INDEX_FILE=$temp/index
	export GIT_INDEX_FILE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
	if test "$old" = null
	then git_cmd read-tree --empty
	else git_cmd read-tree "$old"
	fi
	blob=$(git_cmd hash-object -w --stdin <"$record")
	git_cmd update-index --add --cacheinfo 100644 "$blob" "channels/$selected.json"
	tree=$(git_cmd write-tree)
	if test "$old" = null
	then commit=$(printf 'release: publish %s %s\n' "$selected" "$version" | git_cmd commit-tree "$tree")
	else commit=$(printf 'release: publish %s %s\n' "$selected" "$version" | git_cmd commit-tree "$tree" -p "$old")
	fi
	args=(push --atomic "--force-with-lease=$catalog_ref:${old/null/}")
	updates=("$commit:$catalog_ref")
	if test "$kind" = overlay
	then
		git_cmd fetch --no-tags origin "$current"
		tree=$(git_cmd rev-parse "$current^{tree}")
		receipt=$(printf 'release: record %s %s\n' "$selected" "$version" | git_cmd commit-tree "$tree" -p "$current")
		args+=("--force-with-lease=refs/heads/$selected:${previous_source/null/}" "--force-with-lease=$control_ref:$current")
		updates+=("$source:refs/heads/$selected" "$receipt:$control_ref")
	fi
	destination
	test "$(control)" = "$current" || die 'configuration moved before channel update'
	git_cmd "${args[@]}" origin "${updates[@]}"
	pointer "$repo" "$selected" "$actual"
	same_json "$actual" "$record" 'could not confirm channel release record'
}
verify_remote_asset () {
	local repository=$1 asset=$2 path=$3 downloaded
	test "$(field "$asset" '.size')" -eq "$(wc -c <"$path")" || die 'existing release asset differs; assets are immutable'
	downloaded=$(new_file); get_asset "$repository" "$(field "$asset" '.id')" "$downloaded"
	cmp -s "$downloaded" "$path" || die 'existing release asset differs; assets are immutable'
}
publish_release () {
	local manifest record release selected kind version tag files expected filename asset remote completed current previous
	destination
	manifest=$scratch/manifest.json; build_manifest "$candidate" "$artifacts" "$manifest"
	selected=$(field "$manifest" '.channel'); version=$(field "$manifest" '.version')
	record=$(new_file); release=$(new_file); pointer "$repo" "$selected" "$record"
	if test "$(jq -r '.version // empty' "$record")" = "$version" &&
		test "$(field "$record" '.manifest_sha256')" = "$(hash_file "$manifest")"
	then
		completed=$(new_file); released_manifest "$repo" "$selected" "$version" "$record" "$completed" "$release"
		lane "$selected" >/dev/null
		test "$(get_ref "$repo" "refs/heads/$selected")" = "$(field "$manifest" '.source_sha')" || die 'channel source no longer matches this release'
		return
	fi
	check_candidate "$candidate"; kind=$(lane "$selected"); check_build_jobs "$candidate" "$kind"
	get_release "$repo" "$version" "$release"; tag=$(tag_commit "$repo" "$version")
	test "$tag" = null || test "$tag" = "$(field "$candidate" '.source_sha')" || die 'release tag already names different source'
	if test "$(cat "$release")" = null
	then
		remote=$(new_file)
		jq --arg ref "refs/heads/$selected" --argjson prerelease "$(lane_field "$selected" '.prerelease')" '
			{tag_name:.version,target_commitish:.source_sha,name:.version,draft:true,prerelease:$prerelease,
			 make_latest:"false",body:("source_ref="+$ref+"\nsource_sha="+.source_sha+"\n\nSee manifest.json for source and artifact checksums.")}' "$candidate" >"$remote"
		destination; api "repos/$repo/releases" "$release" POST "$remote"
	fi
	test "$(jq .prerelease "$release")" = "$(lane_field "$selected" '.prerelease')" || die 'release classification changed'
	if test "$(jq .draft "$release")" = true
	then test "$(field "$release" '.target_commitish')" = "$(field "$candidate" '.source_sha')" || die 'draft targets different source'
	fi
	expected=$(new_file); jq '[.targets[][] | .name] + ["manifest.json"]' "$manifest" >"$expected"
	jq -e --slurpfile expected "$expected" '([.assets[].name] - $expected[0] | length) == 0' "$release" >/dev/null || die 'release contains unexpected assets'
	# manifest.json is deliberately last; an interrupted draft remains resumable.
	while IFS= read -r filename
	do
		asset=$(new_file); jq --arg name "$filename" '[.assets[] | select(.name == $name)] |
			if length > 1 then error("duplicate release asset") else .[0] end' "$release" >"$asset"
		if test "$filename" = manifest.json
		then files=$manifest
		else files=$artifacts/$filename
		fi
		if test "$(cat "$asset")" != null
		then verify_remote_asset "$repo" "$asset" "$files"
		else
			test "$(jq .draft "$release")" = true || die 'published release is incomplete; refusing to change it'
			destination; GH_HOST=github.com gh release upload "$version" "$files" --repo "$repo"
		fi
	done < <(jq -r '.[]' "$expected")
	completed=$(new_file); get_release "$repo" "$version" "$completed"
	check_json --slurpfile manifest "$manifest" 'include "release"; verify_asset_metadata($manifest[0])' "$completed"
	while IFS= read -r remote
	do
		asset=$(new_file); printf '%s\n' "$remote" >"$asset"; filename=$(field "$asset" '.name')
		if test "$filename" = manifest.json
		then files=$manifest
		else files=$artifacts/$filename
		fi
		verify_remote_asset "$repo" "$asset" "$files"
	done < <(jq -c '.assets[]' "$completed")
	check_candidate "$candidate"
	if test "$(jq .draft "$completed")" = true
	then
		remote=$(new_file); asset=$(new_file); printf '{"draft":false,"make_latest":"false"}\n' >"$remote"
		api "repos/$repo/releases/$(field "$completed" '.id')" "$asset" PATCH "$remote"
	fi
	test "$(tag_commit "$repo" "$version")" = "$(field "$candidate" '.source_sha')" || die 'published release tag differs'
	check_candidate "$candidate"; current=$(valid_control "$candidate" "$selected")
	previous=$(new_file); jq '.previous_release' "$candidate" >"$previous"
	advance "$selected" "$manifest" "$(jq -r '.previous_source' "$candidate")" "$previous" "$current"
}

case "$command" in
record-build) record_build; exit ;;
manifest) build_manifest "$candidate" "$artifacts" "$output"; exit ;;
esac
check_json 'include "release"; validate_config' "$config"
repo=$(field "$config" '.repository'); visibility=$(field "$config" '.visibility')
control_ref=$(field "$config" '.control_ref'); catalog_ref=$(field "$config" '.catalog_ref')
worktree=$(CDPATH='' cd -- "$worktree" && pwd)
case "$command" in
check-config) printf 'Release configuration is valid.\n' ;;
validate-plan)
	destination
	rows=$(new_file)
	json 'include "release"; [.channels | keys[]] as $channels | . as $c |
		[ $channels[] as $channel | select($c.channels[$channel].kind == "overlay") |
		  $c | topics_for($channel)[] ]' "$config" >"$rows"
	while IFS= read -r row
	do topic=$(new_file); printf '%s\n' "$row" >"$topic"; check_review "$topic"
	done < <(jq -c 'unique_by([.source_sha,.review_pr])[]' "$rows")
	printf 'Release plan source pins and reviews are valid.\n'
	;;
pin) retain_pin; printf 'Reviewed source pin retained.\n' ;;
prepare)
	test "$(lane "$channel")" = ledger || die 'overlay channels use sync'
	test -n "$output" || die 'output directory is missing'
	mkdir -m 700 -- "$output"
	base=$(new_file); topics=$(new_file); printf 'null\n' >"$base"; printf '[]\n' >"$topics"
	make_candidate "$channel" "$source_sha" "$version" "$upstream_tag" "$recipe_sha" "$base" "$topics" "$output/candidate.json"
	;;
sync) sync_source ;;
publish) publish_release; printf 'Complete release and channel record published.\n' ;;
rollback)
	destination; test "$(lane "$channel")" = overlay || die 'ledger channels roll back through their source controller'
	current=$(control); previous=$(new_file); pointer "$repo" "$channel" "$previous"
	previous_source=$(get_ref "$repo" "refs/heads/$channel")
	manifest=$(new_file); release=$(new_file)
	released_manifest "$repo" "$channel" "$version" "$previous" "$manifest" "$release"
	test "$(field "$manifest" '.visibility')" = "$visibility" || die 'rollback visibility mismatch'
	advance "$channel" "$manifest" "$previous_source" "$previous" "$current"
	printf 'Channel restored to existing release.\n'
	;;
download)
	destination; lane "$channel" >/dev/null
	require_value "$target" '. as $target | targets | index($target) != null' 'unknown target'
	previous=$(new_file); manifest=$(new_file); release=$(new_file); pointer "$repo" "$channel" "$previous"
	released_manifest "$repo" "$channel" "$version" "$previous" "$manifest" "$release"
	test "$(field "$manifest" '.visibility')" = "$visibility" || die 'download visibility mismatch'
	filename=git-$(field "$manifest" '.version')-$target.tar.gz
	asset=$(new_file); expected=$(new_file)
	jq --arg name "$filename" '.assets[] | select(.name == $name)' "$release" >"$asset"
	get_asset "$repo" "$(field "$asset" '.id')" "$expected"
	test "$(hash_file "$expected")" = "$(jq -r --arg target "$target" --arg name "$filename" '.targets[$target][] | select(.name == $name) | .sha256' "$manifest")" || die 'download checksum mismatch'
	test -n "$directory" || die 'download directory is missing'
	mkdir -m 700 -- "$directory"; cp "$expected" "$directory/$filename"; cp "$manifest" "$directory/manifest.json"
	printf '%s\n' "$directory/$filename"
	;;
esac
if test "$command" = sync || test "$command" = prepare
then
	candidate=$output/candidate.json
	if test -n "${GITHUB_OUTPUT:-}"
	then
		jq -r 'to_entries[] | select(.key == "source_sha" or .key == "version" or .key == "upstream_tag") |
			if (.value | test("[\r\n]")) then error("invalid workflow output") else .key+"="+.value end' "$candidate" >>"$GITHUB_OUTPUT"
		jq -r '"changed=" + (if .noop then "false" else "true" end)' "$candidate" >>"$GITHUB_OUTPUT"
	fi
	printf 'Prepared %s %s.\n' "$(field "$candidate" '.channel')" "$(field "$candidate" '.version')"
fi
