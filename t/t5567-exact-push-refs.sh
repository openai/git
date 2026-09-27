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
	test_grep "^pando-exact-ref refs/heads/topic$" server/replace/query &&
	test_grep "explicit-haves" server/replace/receive-capabilities
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
	expect_command "$old" "$ZERO_OID" refs/heads/topic
'

test_expect_success 'exact discovery preserves ambiguity of a short destination' '
	setup_case ambiguous &&
	printf "%s refs/tags/topic\n" "$old" >>server/ambiguous/exact &&
	test_must_fail git push "$case_url" HEAD:topic 2>err &&
	test_grep "matches more than one" err &&
	expect_no_push
'

test_expect_success 'all explicit destinations are discovered before matching' '
	setup_case multiple &&
	printf "%s refs/heads/other\n" "$stale" >>server/multiple/exact &&
	git push "$case_url" HEAD:refs/heads/topic HEAD:refs/heads/other &&
	printf "%s %s refs/heads/other\n%s %s refs/heads/topic\n" \
		"$stale" "$new" "$old" "$new" >expect &&
	sort server/multiple/commands >actual &&
	test_cmp expect actual &&
	test_grep "^pando-exact-ref refs/heads/topic$" server/multiple/query &&
	test_grep "^pando-exact-ref refs/heads/other$" server/multiple/query &&
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

for mode in mirror prune follow-tags
do
	test_expect_success "incomplete destination set ($mode) cannot use sparse advertisement" '
		setup_case "unsupported-$mode" &&
		case "$mode" in
		mirror) set -- --mirror ;;
		prune) set -- --prune HEAD:refs/heads/topic ;;
		follow-tags) set -- --follow-tags HEAD:refs/heads/topic ;;
		esac &&
		test_must_fail git push "$case_url" "$@" 2>err &&
		expect_no_push &&
		test_path_is_missing "server/$case_name/query"
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
		test_grep "^pando-exact-ref refs/heads/topic$" "server/$case_name/query" &&
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

test_expect_success 'candidate overflow fails before exact query or upload' '
	setup_case overflow &&
	set -- &&
	for i in $(test_seq 129)
	do
		set -- "$@" "HEAD:refs/heads/topic-$i" || return 1
	done &&
	test_must_fail git push "$case_url" "$@" 2>err &&
	expect_no_push &&
	test_path_is_missing server/overflow/query
'

test_expect_success 'configured follow-tags also rejects incomplete discovery' '
	setup_case configured-follow-tags &&
	test_must_fail git -c push.followTags=true push \
		"$case_url" HEAD:refs/heads/topic 2>err &&
	expect_no_push
'

test_expect_success 'stock receive-pack keeps its advertised old OID' '
	setup_case stock stock &&
	git push --force-with-lease=refs/heads/topic:$stale \
		"$case_url" HEAD:refs/heads/topic &&
	expect_command "$stale" "$new" refs/heads/topic &&
	test_path_is_missing server/stock/query
'

test_expect_success 'stock receive-pack still supports broad refspecs' '
	setup_case stock-all stock &&
	git push "$case_url" --all &&
	test_path_is_file server/stock-all/receive-body &&
	test_path_is_missing server/stock-all/query
'

test_done
