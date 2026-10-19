#!/bin/sh

test_description='fetch/push functionality using the HTTP protocol'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-httpd.sh
start_httpd

SERVER="$HTTPD_DOCUMENT_ROOT_PATH/server"
URI="$HTTPD_URL/smart/server"

grep_wrote () {
	object_count=$1
	file_name=$2
	grep 'write_pack_file/wrote.*"value":"'$1'"' $2
}

setup_client_and_server () {
	git init client &&
	test_when_finished 'rm -rf client' &&
	test_commit -C client first_commit &&
	test_commit -C client second_commit &&

	git init "$SERVER" &&
	test_when_finished 'rm -rf "$SERVER"' &&
	test_config -C "$SERVER" http.receivepack true &&
	test_commit -C "$SERVER" unrelated_commit &&
	git -C client push "$URI" first_commit:refs/remotes/origin/first_commit &&
	git -C "$SERVER" config receive.hideRefs refs/remotes/origin/first_commit
}

test_expect_success 'push without negotiation (for comparing object counts with the next test)' '
	setup_client_and_server &&

	GIT_TRACE2_EVENT="$(pwd)/event" git -C client -c protocol.version=2 \
		push "$URI" refs/heads/main:refs/remotes/origin/main &&
	test_when_finished "rm -f event" &&
	grep_wrote 6 event # 2 commits, 2 trees, 2 blobs
'

test_expect_success 'push with negotiation' '
	setup_client_and_server &&

	GIT_TRACE2_EVENT="$(pwd)/event" git -C client -c protocol.version=2 -c push.negotiate=1 \
		push "$URI" refs/heads/main:refs/remotes/origin/main &&
	test_when_finished "rm -f event" &&
	grep_wrote 3 event # 1 commit, 1 tree, 1 blob
'

test_expect_success 'push with negotiation proceeds anyway even if negotiation fails' '
	setup_client_and_server &&

	# Use protocol v0 to make negotiation fail (because protocol v0 does
	# not support the "wait-for-done" capability, which is required for
	# push negotiation)
	GIT_TEST_PROTOCOL_VERSION=0 GIT_TRACE2_EVENT="$(pwd)/event" git -C client -c push.negotiate=1 \
		push "$URI" refs/heads/main:refs/remotes/origin/main 2>err &&
	test_when_finished "rm -f event" &&
	grep_wrote 6 event && # 2 commits, 2 trees, 2 blobs

	cat >warning-expect <<-EOF &&
	warning: --negotiate-only requires protocol v2
	warning: push negotiation failed; proceeding anyway with push
EOF
	grep warning: err >warning-actual &&
	test_cmp warning-expect warning-actual
'

test_expect_success 'push with required negotiation' '
	setup_client_and_server &&
	test_when_finished "rm -f event" &&
	GIT_TRACE2_EVENT="$PWD/event" \
		git -C client -c protocol.version=2 -c push.negotiate=required \
		push "$URI" main:refs/remotes/origin/main &&
	grep_wrote 3 event
'

for status in 400 500
do
	for mode in true required
	do
		test_expect_success "push.negotiate=$mode with HTTP $status during negotiation" '
			setup_client_and_server &&
			test_when_finished "rm -f event \"$HTTPD_ROOT_PATH/one-time-script\"" &&
			write_script "$HTTPD_ROOT_PATH/one-time-script" <<-EOF &&
			if test "\$REQUEST_METHOD" = POST &&
			   test "\${PATH_INFO##*/}" = git-upload-pack
			then
				printf "Status: $status Test failure\\r\\n"
				printf "Content-Type: text/plain\\r\\n\\r\\n"
				echo "negotiation failed"
			else
				cat "\$1"
			fi
			EOF
			if test "$mode" = required
			then
				test_must_fail env GIT_TRACE2_EVENT="$PWD/event" \
					git -C client -c protocol.version=2 -c push.negotiate=$mode \
					push "$HTTPD_URL/one_time_script/server" \
					main:refs/remotes/origin/main 2>err &&
				test_grep "push negotiation failed; aborting push" err &&
				test_grep ! "proceeding anyway" err &&
				test_grep ! "pack-objects" event &&
				test_must_fail git -C "$SERVER" show-ref --verify refs/remotes/origin/main
			else
				GIT_TRACE2_EVENT="$PWD/event" \
					git -C client -c protocol.version=2 -c push.negotiate=$mode \
					push "$HTTPD_URL/one_time_script/server" \
					main:refs/remotes/origin/main 2>err &&
				test_grep "push negotiation failed; proceeding anyway" err &&
				grep_wrote 6 event
			fi &&
			test_grep "HTTP $status" err &&
			test_path_is_missing "$HTTPD_ROOT_PATH/one-time-script"
		'
	done
done

test_expect_success 'required negotiation rejects a missing wait-for-done capability' '
	setup_client_and_server &&
	test_when_finished "rm -f event \"$HTTPD_ROOT_PATH/one-time-script\"" &&
	write_script "$HTTPD_ROOT_PATH/one-time-script" <<-\EOF &&
	sed "s/ wait-for-done/ xxxx-xxx-xxxx/" "$1"
	EOF
	test_must_fail env GIT_TRACE2_EVENT="$PWD/event" \
		git -C client -c protocol.version=2 -c push.negotiate=required \
		push "$HTTPD_URL/one_time_script/server" \
		main:refs/remotes/origin/main 2>err &&
	test_grep "server does not support wait-for-done" err &&
	test_grep "push negotiation failed; aborting push" err &&
	test_grep ! "pack-objects" event &&
	test_must_fail git -C "$SERVER" show-ref --verify refs/remotes/origin/main
'

test_expect_success 'required negotiation rejects an invalid acknowledgments section' '
	setup_client_and_server &&
	test_when_finished "rm -f event \"$HTTPD_ROOT_PATH/one-time-script\"" &&
	write_script "$HTTPD_ROOT_PATH/one-time-script" <<-\EOF &&
	sed "s/acknowledgments/not-ack-section/" "$1"
	EOF
	test_must_fail env GIT_TRACE2_EVENT="$PWD/event" \
		git -C client -c protocol.version=2 -c push.negotiate=required \
		push "$HTTPD_URL/one_time_script/server" \
		main:refs/remotes/origin/main 2>err &&
	test_grep "expected .acknowledgments." err &&
	test_grep "push negotiation failed; aborting push" err &&
	test_grep ! "pack-objects" event &&
	test_must_fail git -C "$SERVER" show-ref --verify refs/remotes/origin/main
'

test_done
