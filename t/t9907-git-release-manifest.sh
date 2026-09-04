#!/bin/sh

test_description='native Git release receipts and manifest'
. ./test-lib.sh
if ! command -v jq >/dev/null || ! command -v bash >/dev/null
then
	skip_all='jq and bash are required'
	test_done
fi
manifest_script=${RELEASE_MANIFEST_SCRIPT:-$TEST_DIRECTORY/../.github/workflows/git-release-manifest.sh}
GITHUB_REPOSITORY=example/distribution GITHUB_RUN_ID=42
SOURCE_SHA=1111111111111111111111111111111111111111
RECIPE_SHA=2222222222222222222222222222222222222222
VERSION=v2.55.0-example CHANNEL=example UPSTREAM_TAG=v2.55.0 VISIBILITY=public
export GITHUB_REPOSITORY GITHUB_RUN_ID SOURCE_SHA RECIPE_SHA VERSION CHANNEL UPSTREAM_TAG VISIBILITY
run_manifest () { "${RELEASE_BASH:-bash}" "$manifest_script" "$@"; }
hash () {
	if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}
restore () { rm -rf artifacts && cp -R original artifacts; }
reject () { if run_manifest collect artifacts >actual; then return 1; fi; }

test_expect_success 'record all six native builds' '
	mkdir original &&
	for target in macOS-arm64 macOS-x64 ubuntu-arm64 ubuntu-x64 windows-arm64 windows-x64
	do
		for extension in tar.gz lzma
		do
			file=original/git-$VERSION-$target.$extension &&
			printf "%s\n" "$file" >"$file" && hash "$file" >"$file.sha256" || return 1
		done &&
		run_manifest record original "$target" || return 1
	done
'

test_expect_success 'manifest identifies the source, recipe and all 24 assets' '
	restore && run_manifest collect artifacts >actual &&
	jq -e --arg source "$SOURCE_SHA" --arg recipe "$RECIPE_SHA" ".source_sha==\$source and .recipe.sha==\$recipe and (.targets|length)==6 and ([.targets[][]]|length)==24 and all(.builds[]; .run_id==\"42\")" actual
'

test_expect_success 'incomplete targets and mismatching sidecars are rejected' '
	restore && rm artifacts/git-$VERSION-macOS-arm64.lzma && reject &&
	restore && echo changed >artifacts/git-$VERSION-macOS-arm64.lzma && reject
'

test_expect_success 'matching sidecars cannot disguise a changed native artifact' '
	restore && file=artifacts/git-$VERSION-macOS-arm64.lzma &&
	echo changed >"$file" && hash "$file" >"$file.sha256" && reject
'

test_expect_success 'receipts must match the requested source, recipe and original run' '
	for edit in ".source_sha=\"wrong\"" ".recipe.sha=\"wrong\"" ".run_id=\"wrong\""
	do
		restore && receipt=artifacts/git-$VERSION-macOS-arm64.build.json &&
		jq "$edit" "$receipt" >changed && mv changed "$receipt" && reject || return 1
	done
'

test_expect_success 'symlinks and unexpected files are rejected' '
	restore && file=artifacts/git-$VERSION-macOS-arm64.tar.gz &&
	mv "$file" archive && ln -s "$TRASH_DIRECTORY/archive" "$file" && reject &&
	restore && touch artifacts/.unexpected && reject
'

test_expect_success 'recording rejects empty archives and unknown targets' '
	restore && file=artifacts/git-$VERSION-macOS-arm64.tar.gz &&
	: >"$file" && hash "$file" >"$file.sha256" &&
	if run_manifest record artifacts macOS-arm64; then return 1; fi &&
	if run_manifest record artifacts unknown; then return 1; fi
'

test_done
