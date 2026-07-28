#!/bin/sh

test_description='exact clean status sidecars'

. ./test-lib.sh

test_lazy_prereq LOCAL_APFS '
	test_have_prereq MACOS &&
	/bin/df -t apfs "$TRASH_DIRECTORY" >/dev/null
'

if ! test_have_prereq FSMONITOR_DAEMON,LOCAL_APFS,MACOS
then
	skip_all='clean status sidecars require local APFS and the macOS fsmonitor daemon'
	test_done
fi

test_lazy_prereq DURABLE_FSMONITOR '
	test_create_repo durable-fsmonitor-probe || return 1
	(
		cd durable-fsmonitor-probe &&
		test_commit base tracked &&
		git config core.fsmonitor true &&
		git fsmonitor--daemon start --start-timeout=10 &&
		git status --porcelain=v2 >/dev/null &&
		test-tool dump-fsmonitor >token &&
		grep "^fsmonitor last update builtin:" token
		result=$?
		git fsmonitor--daemon stop >/dev/null 2>&1 || :
		exit $result
	)
'

stop_daemon () {
	git -C "$1" fsmonitor--daemon stop 2>/dev/null || :
}

setup_repo () {
	repo=$1 &&
	test_create_repo "$repo" &&
	test_commit -C "$repo" base tracked &&
	test-tool chmtime -120 "$repo/tracked" &&
	git -C "$repo" update-index --refresh &&
	git -C "$repo" config core.fsmonitor true &&
	git -C "$repo" fsmonitor--daemon start --start-timeout=10
}

bulk_status () {
	GIT_TEST_PRELOAD_INDEX=1 \
	GIT_TEST_PRELOAD_INDEX_BULK=1 \
		git "$@"
}

prime_semantic_history () {
	repo=$1 &&
	bulk_status -C "$repo" status --porcelain=2 >actual.1 &&
	test_must_be_empty actual.1 &&
	bulk_status -C "$repo" status --porcelain=2 >actual.2 &&
	test_must_be_empty actual.2 &&
	test_grep FSCF "$repo/.git/index"
}

test_expect_success DURABLE_FSMONITOR \
	'exact clean status installs a sidecar without rewriting the index' '
	test_when_finished "stop_daemon sidecar-issue" &&
	setup_repo sidecar-issue &&
	test_env GIT_TRACE2_EVENT="$PWD/first-scan.trace" \
		bulk_status -C sidecar-issue status --porcelain=v2 \
		>actual.first &&
	test_must_be_empty actual.first &&
	test_path_is_missing sidecar-issue/.git/index.csts &&
	test_grep "\"value\":\"issue-coherent-history\"" first-scan.trace &&

	prime_semantic_history sidecar-issue &&
	git -C sidecar-issue config core.autocrlf false &&
	cp sidecar-issue/.git/index index.before &&

	test_env GIT_TRACE2_EVENT="$PWD/issue.trace" \
		bulk_status -C sidecar-issue status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_cmp index.before sidecar-issue/.git/index &&
	test_path_is_file sidecar-issue/.git/index.csts &&
	test_grep \
		"\"key\":\"preload/bulk_untracked_complete\",\"value\":\"1\"" \
		issue.trace &&
	test_grep "\"key\":\"preload/bulk_provider_applied\"" issue.trace &&
	test_grep "\"key\":\"clean-proof/sidecar\"" issue.trace &&
	test_grep ! "\"label\":\"do_write_index\"" issue.trace
'

test_expect_success DURABLE_FSMONITOR \
	'only an exact empty output installs a sidecar' '
	test_when_finished "stop_daemon sidecar-shape" &&
	setup_repo sidecar-shape &&
	prime_semantic_history sidecar-shape &&

	bulk_status -C sidecar-shape status --porcelain=2 >actual &&
	test_must_be_empty actual &&
	test_path_is_missing sidecar-shape/.git/index.csts &&

	bulk_status -C sidecar-shape status --porcelain=v2 --branch >actual &&
	test_grep "^# branch.oid " actual &&
	test_path_is_missing sidecar-shape/.git/index.csts &&

	echo changed >sidecar-shape/tracked &&
	bulk_status -C sidecar-shape status --porcelain=v2 >actual &&
	test_grep "^1 .M " actual &&
	test_path_is_missing sidecar-shape/.git/index.csts
'

test_expect_success DURABLE_FSMONITOR \
	'external attributes, untracked cache, and alternate indexes are rejected' '
	test_when_finished "stop_daemon sidecar-inputs" &&
	setup_repo sidecar-inputs &&
	prime_semantic_history sidecar-inputs &&

	test_write_lines "tracked -text" \
		>sidecar-inputs/.git/info/attributes &&
	bulk_status -C sidecar-inputs status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_path_is_missing sidecar-inputs/.git/index.csts &&

	rm sidecar-inputs/.git/info/attributes &&
	git -C sidecar-inputs config core.untrackedCache true &&
	bulk_status -C sidecar-inputs status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_path_is_missing sidecar-inputs/.git/index.csts &&

	cp sidecar-inputs/.git/index sidecar-inputs/.git/alternate-index &&
	test_env GIT_INDEX_FILE="$PWD/sidecar-inputs/.git/alternate-index" \
		bulk_status -C sidecar-inputs status --porcelain=v2 >actual &&
	test_must_be_empty actual &&
	test_path_is_missing sidecar-inputs/.git/alternate-index.csts
'

test_done
