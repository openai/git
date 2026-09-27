#!/bin/sh

test_description='exact push discovery over smart HTTP'

. ./test-lib.sh

if ! test_have_prereq LIBCURL,PERL,PIPE
then
	skip_all='exact push HTTP tests require curl, Perl and FIFOs'
	test_done
fi

if ! test_bool_env GIT_TEST_HTTPD true
then
	skip_all='network testing disabled (unset GIT_TEST_HTTPD to enable)'
	test_done
fi

# A dedicated server can advertise sparse receive-pack refs independently of
# the exact result, and retain the actual commands and PACK sent by Git.
setup_case () {
	case_name=$1 &&
	mkdir "server/$case_name" &&
	printf "%s\n" "${2:-normal}" >"server/$case_name/mode" &&
	printf "%s refs/heads/topic\n" "$stale" >"server/$case_name/initial" &&
	printf "%s refs/heads/topic\n" "$old" >"server/$case_name/exact" &&
	case_url="$server_url/$case_name/repo"
}

expect_command () {
	printf "%s %s %s\n" "$1" "$2" "$3" >expect &&
	test_cmp expect "server/$case_name/commands"
}

expect_no_push () {
	test_path_is_missing "server/$case_name/receive-body"
}

test_expect_success 'start exact ref server and create local history' '
	mkdir server &&
	test_oid algo >server/algo &&
	mkfifo server-ready &&
	exec 7<>server-ready &&
	{
		"$PERL_PATH" "$TEST_DIRECTORY/t5567/exact-push-server.pl" \
			"$TRASH_DIRECTORY/server" "$TRASH_DIRECTORY/server-ready" \
			>server.log 2>&1 &
		server_pid=$!
	} &&
	test_atexit "
		kill $server_pid 2>/dev/null || :
		wait $server_pid 2>/dev/null || :
		exec 7>&-
	" &&
	read server_port <&7 &&
	test "$server_port" != failed &&
	server_url="http://127.0.0.1:$server_port" &&
	test_commit initial &&
	stale=$(git rev-parse HEAD) &&
	test_commit observed &&
	old=$(git rev-parse HEAD) &&
	test_commit proposed &&
	new=$(git rev-parse HEAD)
'

test_expect_success 'exact discovery precedes matching and replaces cached send-pack old OID' '
	setup_case replace &&
	git push --force-with-lease=refs/heads/topic:$old \
		"$case_url" HEAD:refs/heads/topic &&
	expect_command "$old" "$new" refs/heads/topic &&
	printf "%s\n" version=2:explicit-haves >expect &&
	test_cmp expect server/replace/query-header &&
	cat >expect <<-EOF &&
	GET /replace/repo/info/refs?service=git-receive-pack
	GET /replace/session/info/refs?service=git-receive-pack
	POST /replace/session/git-upload-pack
	POST /replace/session/git-receive-pack
	EOF
	test_cmp expect server/replace/requests &&
	test_grep "^command=ls-refs$" server/replace/query &&
	test_grep "^object-format=$(test_oid algo)$" server/replace/query &&
	test_grep "^ref-prefix refs/heads/topic$" server/replace/query &&
	test_grep "explicit-haves" server/replace/receive-capabilities &&
	test_grep "pando-exact-refs" server/replace/receive-capabilities
'

test_expect_success 'each remote-helper push listing performs exact discovery' '
	setup_case relist &&
	cat >helper-input <<-EOF &&
	capabilities
	option push-exact-refs true
	option push-exact-ref refs/heads/topic
	list for-push
	option push-exact-refs true
	option push-exact-ref refs/heads/topic
	list for-push

	EOF
	git remote-http origin "$case_url" <helper-input >helper-output &&
	grep "^POST /relist/session/git-upload-pack$" server/relist/requests >queries &&
	test_line_count = 2 queries &&
	grep "^:push-exact-refs$" helper-output >markers &&
	test_line_count = 2 markers &&
	expect_no_push
'

test_expect_success 'named exact OID is not PACK omission authority' '
	git init --bare pack-check.git &&
	git -C pack-check.git index-pack --stdin <server/replace/pack &&
	git -C pack-check.git cat-file -e "$old" &&
	git -C pack-check.git fsck --full --no-dangling "$new"
'

test_expect_success 'explicit .have remains PACK omission authority' '
	setup_case have &&
	printf "%s .have\n" "$old" >>server/have/initial &&
	git push --no-thin "$case_url" HEAD:refs/heads/topic &&
	expect_command "$old" "$new" refs/heads/topic &&
	git init --bare have-pack-check.git &&
	git -C have-pack-check.git index-pack --stdin <server/have/pack &&
	git -C have-pack-check.git cat-file -e "$new" &&
	test_must_fail git -C have-pack-check.git cat-file -e "$old"
'

test_expect_success 'capability-only advertisement gains the exact target' '
	setup_case sentinel &&
	: >server/sentinel/initial &&
	git push --force-with-lease=refs/heads/topic:$old \
		"$case_url" HEAD:refs/heads/topic &&
	expect_command "$old" "$new" refs/heads/topic
'

test_expect_success 'shallow advertisement remains valid after replacing its first ref' '
	setup_case shallow &&
	printf "shallow %s\n" "$stale" >>server/shallow/initial &&
	git push "$case_url" HEAD:refs/heads/topic &&
	expect_command "$old" "$new" refs/heads/topic
'

test_expect_success 'exact observation prevents a stale advertisement from skipping an update' '
	setup_case stale-noop &&
	printf "%s refs/heads/topic\n" "$new" >server/stale-noop/initial &&
	git push "$case_url" HEAD:refs/heads/topic &&
	expect_command "$old" "$new" refs/heads/topic
'

test_expect_success 'exact absence removes a stale advertised target' '
	setup_case absent &&
	: >server/absent/exact &&
	git push --force-with-lease=refs/heads/topic: \
		"$case_url" HEAD:refs/heads/topic &&
	expect_command "$ZERO_OID" "$new" refs/heads/topic
'

test_expect_success 'exact presence rejects a stale force-with-lease before upload' '
	setup_case stale-lease &&
	test_must_fail git push --force-with-lease=refs/heads/topic:$stale \
		"$case_url" HEAD:refs/heads/topic 2>err &&
	test_grep "stale info" err &&
	test_path_is_file server/stale-lease/query &&
	expect_no_push
'

test_expect_success 'short delete uses the exact branch OID' '
	setup_case delete &&
	git push -d "$case_url" topic &&
	expect_command "$old" "$ZERO_OID" refs/heads/topic &&
	test_grep "pando-exact-refs" server/delete/receive-capabilities
'

test_expect_success 'exact discovery preserves ambiguity of a short destination' '
	setup_case ambiguous &&
	printf "%s refs/tags/topic\n" "$old" >>server/ambiguous/exact &&
	test_must_fail git push "$case_url" HEAD:topic 2>err &&
	test_grep "matches more than one" err &&
	expect_no_push
'

for state in present absent
do
	test_expect_success "point-prefix discovery ignores valid prefix neighbor when foo is $state" '
		setup_case "prefix-$state" &&
		printf "%s refs/heads/foobar\n" "$old" >"server/$case_name/exact" &&
		expected_old=$ZERO_OID &&
		if test "$state" = present
		then
			printf "%s refs/heads/foo\n" "$old" >>"server/$case_name/exact" &&
			expected_old=$old
		fi &&
		git push "$case_url" HEAD:refs/heads/foo &&
		expect_command "$expected_old" "$new" refs/heads/foo &&
		test_grep "^ref-prefix refs/heads/foo$" "server/$case_name/query" &&
		test_grep ! "^ref-prefix refs/heads/foobar$" "server/$case_name/query" &&
		test_grep ! "^pando-exact-ref " "server/$case_name/query"
	'
done

test_expect_success 'valid prefix extras do not impose a candidate-derived response size limit' '
	setup_case many-extras &&
	for i in $(test_seq 20000)
	do
		printf "%s refs/heads/topic-neighbor-%s\n" "$old" "$i" || return 1
	done >>server/many-extras/exact &&
	git push "$case_url" HEAD:refs/heads/topic &&
	expect_command "$old" "$new" refs/heads/topic
'

test_expect_success 'all explicit destinations are discovered before matching' '
	setup_case multiple &&
	printf "%s refs/heads/other\n" "$stale" >>server/multiple/exact &&
	git push "$case_url" HEAD:refs/heads/topic HEAD:refs/heads/other &&
	printf "%s %s refs/heads/other\n%s %s refs/heads/topic\n" \
		"$stale" "$new" "$old" "$new" >expect &&
	sort server/multiple/commands >actual &&
	test_cmp expect actual &&
	test_grep "^ref-prefix refs/heads/topic$" server/multiple/query &&
	test_grep "^ref-prefix refs/heads/other$" server/multiple/query &&
	sort server/multiple/query | uniq -d >duplicates &&
	test_must_be_empty duplicates
'

test_expect_success 'each push URL gets its own exact observation' '
	setup_case url-one &&
	first_url=$case_url &&
	setup_case url-two &&
	second_url=$case_url &&
	printf "%s refs/heads/topic\n" "$stale" >server/url-two/exact &&
	git remote add multiple "$first_url" &&
	git remote set-url --add --push multiple "$first_url" &&
	git remote set-url --add --push multiple "$second_url" &&
	git push --force multiple HEAD:refs/heads/topic &&
	case_name=url-one &&
	expect_command "$old" "$new" refs/heads/topic &&
	case_name=url-two &&
	expect_command "$stale" "$new" refs/heads/topic
'

for mode in duplicate extra bad-oid truncated trailing error oversized http-error
do
	test_expect_success "invalid exact response ($mode) aborts before upload" '
		setup_case "$mode" "$mode" &&
		test_must_fail git push --force "$case_url" HEAD:refs/heads/topic 2>err &&
		test_path_is_file "server/$mode/query" &&
		expect_no_push
	'
done

test_expect_success 'exact capability requires explicit-haves' '
	setup_case no-explicit-haves no-explicit-haves &&
	test_must_fail git push "$case_url" HEAD:refs/heads/topic 2>err &&
	expect_no_push
'

test_expect_success 'mirror deletes remote-only selected refs without discovering unselected refs' '
	setup_case mirror &&
	printf "%s refs/heads/stale-selection\n" "$stale" >server/mirror/initial &&
	printf "%s refs/heads/remote-only\n" "$old" >server/mirror/selected &&
	printf "%s refs/heads/unselected\n" "$old" >server/mirror/exact &&
	printf "%s refs/heads/remote-only\n" "$old" >>server/mirror/exact &&
	git push --mirror "$case_url" &&
	test_grep "^ref-prefix refs/$" server/mirror/query-selected &&
	test_grep "^$old $ZERO_OID refs/heads/remote-only$" server/mirror/commands &&
	test_grep "^$ZERO_OID $new $(git symbolic-ref HEAD)$" server/mirror/commands &&
	test_grep ! "refs/heads/unselected" server/mirror/commands &&
	test_grep ! "refs/heads/stale-selection" server/mirror/commands
'

test_expect_success 'prune deletes selected refs only in the mapped namespace' '
	setup_case prune &&
	{
		printf "%s refs/heads/mapped/remote-only\n" "$old" &&
		printf "%s refs/heads/outside\n" "$old" &&
		printf "%s refs/tags/protected\n" "$old"
	} >server/prune/selected &&
	cp server/prune/selected server/prune/exact &&
	git push --prune "$case_url" "refs/heads/*:refs/heads/mapped/*" &&
	test_grep "^ref-prefix refs/$" server/prune/query-selected &&
	test_grep "^$old $ZERO_OID refs/heads/mapped/remote-only$" server/prune/commands &&
	test_grep "^$ZERO_OID $new refs/heads/mapped/$(git symbolic-ref --short HEAD)$" server/prune/commands &&
	test_grep ! "refs/heads/outside" server/prune/commands &&
	test_grep ! "refs/tags/protected" server/prune/commands
'

for configured in no yes
do
	test_expect_success "follow-tags includes tags reachable only from selected remote tips (configured=$configured)" '
		setup_case "follow-tags-$configured" &&
		remote_tip=$(echo remote-only | git commit-tree "HEAD^{tree}") &&
		git tag -a -m remote-only remote-only-tag "$remote_tip" &&
		test_when_finished "git tag -d remote-only-tag" &&
		unreachable_tip=$(echo unreachable | git commit-tree "HEAD^{tree}") &&
		git tag -a -m unreachable unreachable-tag "$unreachable_tip" &&
		test_when_finished "git tag -d unreachable-tag" &&
		tag_oid=$(git rev-parse refs/tags/remote-only-tag) &&
		printf "%s refs/heads/remote-tip\n" "$remote_tip" >"server/$case_name/selected" &&
		printf "%s refs/heads/topic\n" "$old" >>"server/$case_name/selected" &&
		cp "server/$case_name/selected" "server/$case_name/exact" &&
		if test "$configured" = yes
		then
			git -c push.followTags=true push "$case_url" HEAD:refs/heads/topic
		else
			git push --follow-tags "$case_url" HEAD:refs/heads/topic
		fi &&
		test_grep "^ref-prefix refs/$" "server/$case_name/query-selected" &&
		test_grep "^$old $new refs/heads/topic$" "server/$case_name/commands" &&
		test_grep "^$ZERO_OID $tag_oid refs/tags/remote-only-tag$" "server/$case_name/commands" &&
		test_grep ! "refs/heads/remote-tip$" "server/$case_name/commands" &&
		test_grep ! "refs/tags/unreachable-tag$" "server/$case_name/commands"
	'
done

for mode in all matching wildcard
do
	test_expect_success "finite expanded destination set ($mode) uses exact discovery" '
		setup_case "expanded-$mode" &&
		git branch topic &&
		test_when_finished "git branch -D topic" &&
		case "$mode" in
		all) set -- --all ;;
		matching) set -- : ;;
		wildcard) set -- "refs/heads/*:refs/heads/*" ;;
		esac &&
		git push "$case_url" "$@" &&
		test_grep "^ref-prefix refs/heads/topic$" "server/$case_name/query" &&
		printf "%s %s refs/heads/topic\n" "$old" "$new" >expect &&
		if test "$mode" != matching
		then
			printf "%s %s %s\n" "$ZERO_OID" "$new" "$(git symbolic-ref HEAD)" >>expect
		fi &&
		sort expect >expect.sorted &&
		sort "server/$case_name/commands" >actual &&
		test_cmp expect.sorted actual
	'
done

test_expect_success 'more than 128 candidates use bounded exact requests before matching' '
	setup_case batches batch &&
	: >server/batches/initial &&
	: >server/batches/exact &&
	: >expect &&
	set -- &&
	for i in $(test_seq 129)
	do
		set -- "$@" "HEAD:refs/heads/topic-$i" &&
		printf "%s refs/heads/topic-%s\n" "$new" "$i" >>server/batches/initial &&
		printf "%s refs/heads/topic-%s\n" "$old" "$i" >>server/batches/exact &&
		printf "%s %s refs/heads/topic-%s\n" "$old" "$new" "$i" >>expect || return 1
	done &&
	git push "$case_url" "$@" &&
	sort expect >expect.sorted &&
	sort server/batches/commands >actual &&
	test_cmp expect.sorted actual &&
	cat server/batches/query-[0-9]* | sort >queried &&
	test_line_count = 774 queried &&
	uniq -d queried >duplicates &&
	test_must_be_empty duplicates &&
	for query in server/batches/query-[0-9]*
	do
		test_line_count -le 128 "$query" || return 1
	done &&
	grep "^POST /batches/session/git-upload-pack$" server/batches/requests >requests &&
	test_line_count = 7 requests &&
	git init --bare batch-pack-check.git &&
	git -C batch-pack-check.git index-pack --stdin <server/batches/pack &&
	git -C batch-pack-check.git fsck --full --no-dangling "$new"
'

test_expect_success 'a later exact batch error aborts before matching or upload' '
	setup_case batch-error batch-error &&
	cp server/batches/initial server/batch-error/initial &&
	cp server/batches/exact server/batch-error/exact &&
	set -- &&
	for i in $(test_seq 129)
	do
		set -- "$@" "HEAD:refs/heads/topic-$i" || return 1
	done &&
	test_must_fail git push "$case_url" "$@" 2>err &&
	test_grep "exact refs unavailable" err &&
	expect_no_push &&
	printf "2\n" >expect &&
	test_cmp expect server/batch-error/query-count
'

test_expect_success 'a later batch error exposes no partial remote-helper ref list' '
	setup_case batch-list-error batch-error &&
	cp server/batches/initial server/batch-list-error/initial &&
	cp server/batches/exact server/batch-list-error/exact &&
	{
		echo "option push-exact-refs true" &&
		for i in $(test_seq 129)
		do
			echo "option push-exact-ref refs/heads/topic-$i" || return 1
		done &&
		echo "list for-push"
	} >helper-input &&
	test_must_fail git remote-http origin "$case_url" <helper-input >helper-output 2>err &&
	test_grep "exact refs unavailable" err &&
	test_grep ! "^:push-exact-refs$" helper-output &&
	test_grep ! "refs/heads/" helper-output &&
	expect_no_push
'

test_expect_success 'a failed point query exposes none of the preceding selected view' '
	setup_case selected-point-error selected-point-error &&
	printf "%s refs/heads/remote-only\n" "$old" >server/selected-point-error/selected &&
	cat >helper-input <<-EOF &&
	option push-exact-refs selected
	option push-exact-ref refs/heads/topic
	list for-push
	EOF
	test_must_fail git remote-http origin "$case_url" <helper-input >helper-output 2>err &&
	test_grep "exact refs unavailable" err &&
	test_path_is_file server/selected-point-error/query-selected &&
	test_grep ! "^:push-exact-refs$" helper-output &&
	test_grep ! "refs/heads/" helper-output &&
	expect_no_push
'

test_expect_success 'receive-pack rejection of the exact contract fails the push' '
	setup_case receive-reject receive-reject &&
	test_must_fail git push "$case_url" HEAD:refs/heads/topic 2>err &&
	test_path_is_file server/receive-reject/query &&
	expect_command "$old" "$new" refs/heads/topic &&
	test_grep "pando-exact-refs" server/receive-reject/receive-capabilities &&
	test_grep "exact contract unavailable" err
'

for capability in explicit-haves pando-exact-refs
do
	test_expect_success "send-pack exact mode requires both capabilities ($capability alone)" '
		{
			printf "%s refs/heads/topic\0report-status %s object-format=%s\n" \
				"$old" "$capability" "$(test_oid algo)" | packetize_raw &&
			printf 0000
		} >advertisement &&
		test_must_fail git send-pack --stateless-rpc --push-exact-refs \
			example.invalid HEAD:refs/heads/topic <advertisement >sent 2>err &&
		test_grep "exact push ref discovery capabilities are no longer available" err &&
		test_must_be_empty sent
	'
done

test_expect_success 'stock receive-pack keeps its advertised old OID' '
	setup_case stock stock &&
	git push --force-with-lease=refs/heads/topic:$stale \
		"$case_url" HEAD:refs/heads/topic &&
	expect_command "$stale" "$new" refs/heads/topic &&
	test_path_is_missing server/stock/query &&
	test_grep ! "pando-exact-refs" server/stock/receive-capabilities
'

test_expect_success 'stock receive-pack still supports broad refspecs' '
	setup_case stock-all stock &&
	git push "$case_url" --all &&
	test_path_is_file server/stock-all/receive-body &&
	test_path_is_missing server/stock-all/query
'

test_done
