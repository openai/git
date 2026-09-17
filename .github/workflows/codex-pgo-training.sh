#!/bin/sh

# Keep this workload short and biased toward the local Git operations Codex
# invokes frequently. The full Git test suite is too slow for each release
# target and would weight test-harness paths more heavily than status, diff,
# clone, fetch, and repository maintenance.

set -eu

git_bin="$PWD/bin-wrappers/git"
training_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-git-pgo.XXXXXX")
repo="$training_dir/repo"
clone="$training_dir/clone"

cleanup () {
	rm -rf "$training_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$training_dir/home"
export HOME="$training_dir/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0

"$git_bin" clone --quiet --no-local "$PWD" "$repo"
"$git_bin" -C "$repo" config user.name "Codex Git PGO"
"$git_bin" -C "$repo" config user.email "codex-git-pgo@openai.com"

i=0
while test "$i" -lt 256
do
	dir="$repo/training/$((i % 16))"
	mkdir -p "$dir"
	printf '%s\n' "$i" >"$dir/file-$i"
	i=$((i + 1))
done

"$git_bin" -C "$repo" status --porcelain=v2 --branch >/dev/null
"$git_bin" -C "$repo" status --porcelain=v2 --branch --untracked-files=all >/dev/null
"$git_bin" -C "$repo" ls-files --others --exclude-standard >/dev/null
"$git_bin" -C "$repo" add training
"$git_bin" -C "$repo" diff --cached --stat >/dev/null
"$git_bin" -C "$repo" commit --quiet -m "add training files"

printf 'changed\n' >>"$repo/training/0/file-0"
rm "$repo/training/1/file-1"
mkdir -p "$repo/untracked"
printf 'new\n' >"$repo/untracked/file"

"$git_bin" -C "$repo" status --porcelain=v2 --branch >/dev/null
"$git_bin" -C "$repo" diff --stat >/dev/null
"$git_bin" -C "$repo" diff --name-status >/dev/null
"$git_bin" -C "$repo" ls-files --stage >/dev/null
"$git_bin" -C "$repo" log --oneline --decorate -20 >/dev/null
"$git_bin" -C "$repo" rev-list --objects --all >/dev/null
"$git_bin" -C "$repo" for-each-ref --format='%(refname) %(objectname)' >/dev/null
"$git_bin" -C "$repo" repack -ad
"$git_bin" clone --quiet --no-local "$repo" "$clone"
"$git_bin" -C "$clone" status --porcelain=v2 --branch >/dev/null
"$git_bin" -C "$clone" fetch --quiet "$repo"
