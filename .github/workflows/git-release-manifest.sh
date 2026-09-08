#!/usr/bin/env bash
# Record native artifacts, then combine only matching receipts into a manifest.
set -euo pipefail
test "$#" -ge 2
mode=$1 directory=$2
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ && "$RECIPE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
hash () {
	if command -v sha256sum >/dev/null
	then sha256sum "$1"
	else shasum -a 256 "$1"
	fi | awk '{print $1}'
}
record () {
	local target=$1 archive file sum bytes limit=67108864
	case "$target" in
	windows-arm64|windows-x64) limit=134217728 ;;
	macOS-arm64|macOS-x64|ubuntu-arm64|ubuntu-x64) ;;
	*) return 1 ;;
	esac
	: >"$scratch/assets"
	for extension in tar.gz lzma
	do
		archive=$directory/git-$VERSION-$target.$extension
		for file in "$archive" "$archive.sha256"
		do
			test -f "$file" && test ! -L "$file"
			sum=$(hash "$file"); bytes=$(wc -c <"$file")
			test "$bytes" -gt 0
			jq -n --arg name "${file##*/}" --arg hash "$sum" --argjson size "$bytes" \
				'{name:$name,sha256:$hash,size:$size}' >>"$scratch/assets"
		done
		test "$(tr -d '\r\n' <"$archive.sha256")" = "$(hash "$archive")"
	done
	test "$(wc -c <"$directory/git-$VERSION-$target.tar.gz")" -le "$limit"
	jq -S -a -s --arg repository "$GITHUB_REPOSITORY" --arg version "$VERSION" \
		--arg source "$SOURCE_SHA" --arg recipe "$RECIPE_SHA" --arg run "$GITHUB_RUN_ID" \
		--arg target "$target" '{repository:$repository,source_sha:$source,version:$version,
		recipe:{repository:"openai/git",sha:$recipe},run_id:$run,target:$target,assets:.}' "$scratch/assets"
}
case "$mode" in
record) record "${3:?target required}" >"$directory/git-$VERSION-$3.build.json" ;;
collect)
	for target in macOS-arm64 macOS-x64 ubuntu-arm64 ubuntu-x64 windows-arm64 windows-x64
	do
		receipt=$directory/git-$VERSION-$target.build.json
		test -f "$receipt" && test ! -L "$receipt"
		record "$target" >"$scratch/$target.json"
		cmp "$scratch/$target.json" "$receipt"
	done
	shopt -s nullglob dotglob
	files=("$directory"/*)
	test "${#files[@]}" -eq 30
	jq -S -a -s --arg channel "$CHANNEL" --arg tag "$UPSTREAM_TAG" --arg visibility "$VISIBILITY" '
		.[0] as $first | {schema_version:1,repository:$first.repository,visibility:$visibility,
		channel:$channel,version:$first.version,source_sha:$first.source_sha,upstream_tag:$tag,
		recipe:$first.recipe,targets:(map({key:.target,value:.assets}) | from_entries),
		builds:(map({key:.target,value:.}) | from_entries)}' "$scratch/"*.json
	;;
*) echo 'usage: git-release-manifest.sh record <directory> <target> | collect <directory>' >&2; exit 129 ;;
esac
