#!/bin/sh

test_description='retry transient HTTP packfile download failures'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-httpd.sh

enable_cgipassauth
start_httpd

test_lazy_prereq CURL_RETRY_AFTER '
	version=$(git version --build-options | sed -n "s/^libcurl: //p") &&
	major=${version%%.*} &&
	minor=${version#*.} &&
	minor=${minor%%.*} &&
	{ test "$major" -gt 7 || { test "$major" = 7 && test "$minor" -ge 66; }; }
'

test_expect_success 'setup packfile' '
	test_commit one &&
	git clone --bare . "$HTTPD_DOCUMENT_ROOT_PATH/repo.git" &&
	git -C "$HTTPD_DOCUMENT_ROOT_PATH/repo.git" repack -ad &&
	pack=$(echo "$HTTPD_DOCUMENT_ROOT_PATH/repo.git/objects/pack/"*.pack) &&
	pack_hash=${pack##*/pack-} &&
	pack_hash=${pack_hash%.pack} &&
	pack_url="$HTTPD_URL/pack_retry/repo.git/objects/pack/pack-$pack_hash.pack"
'

pack_responses () {
	printf "%s\n" "$@" >"$HTTPD_ROOT_PATH/pack-retry.responses" &&
	>"$HTTPD_ROOT_PATH/pack-retry.requests"
}

fetch_pack () {
	"$@" git -C client -c http.minSessions=0 http-fetch \
		--packfile="$pack_hash" \
		--index-pack-arg=index-pack --index-pack-arg=--stdin "$pack_url"
}

for status in 502 503 504
do
	test_expect_success "packfile download retries HTTP $status" '
		test_when_finished "rm -rf client" &&
		git init client &&
		pack_responses "$status" 200 &&
		fetch_pack &&
		test_line_count = 2 "$HTTPD_ROOT_PATH/pack-retry.requests" &&
		test_cmp "$pack" "client/.git/objects/pack/pack-$pack_hash.pack"
	'
done

test_expect_success 'exhausted retries preserve the partial pack' '
	test_when_finished "rm -rf client" &&
	git init client &&
	partial="client/.git/objects/pack/pack-$pack_hash.pack.temp" &&
	dd if="$pack" of=prefix bs=1 count=12 &&
	cp prefix "$partial" &&
	pack_responses 503 503 503 200 &&
	fetch_pack test_must_fail &&
	test_line_count = 3 "$HTTPD_ROOT_PATH/pack-retry.requests" &&
	test_cmp prefix "$partial" &&
	printf "GET|bytes=12-|\nGET|bytes=12-|\nGET|bytes=12-|\n" >expect &&
	test_cmp expect "$HTTPD_ROOT_PATH/pack-retry.requests"
'

test_expect_success 'resumed download survives two transient errors' '
	test_when_finished "rm -rf client" &&
	git init client &&
	dd if="$pack" of="client/.git/objects/pack/pack-$pack_hash.pack.temp" \
		bs=1 count=12 &&
	pack_responses 503 502 200 &&
	fetch_pack &&
	printf "GET|bytes=12-|\nGET|bytes=12-|\nGET|bytes=12-|\n" >expect &&
	test_cmp expect "$HTTPD_ROOT_PATH/pack-retry.requests" &&
	test_cmp "$pack" "client/.git/objects/pack/pack-$pack_hash.pack"
'

test_expect_success 'permanent HTTP errors are not retried' '
	test_when_finished "rm -rf client" &&
	git init client &&
	pack_responses 403 200 &&
	fetch_pack test_must_fail &&
	test_line_count = 1 "$HTTPD_ROOT_PATH/pack-retry.requests"
'

test_expect_success 'an interrupted response is not retried or truncated' '
	test_when_finished "rm -rf client" &&
	git init client &&
	pack_responses truncated 200 &&
	fetch_pack test_must_fail &&
	test_line_count = 1 "$HTTPD_ROOT_PATH/pack-retry.requests" &&
	dd if="$pack" of=prefix bs=1 count=12 &&
	test_cmp prefix "client/.git/objects/pack/pack-$pack_hash.pack.temp"
'

test_expect_success CURL_RETRY_AFTER 'packfile download honors Retry-After' '
	test_when_finished "rm -rf client" &&
	git init client &&
	pack_responses "503 3" 200 &&
	start=$(test-tool date getnanos) &&
	fetch_pack &&
	duration=$(test-tool date getnanos "$start") &&
	test "${duration%.*}" -ge 3 &&
	test_line_count = 2 "$HTTPD_ROOT_PATH/pack-retry.requests" &&
	test_cmp "$pack" "client/.git/objects/pack/pack-$pack_hash.pack"
'

test_expect_success CURL_RETRY_AFTER 'excessive Retry-After fails without retrying early' '
	test_when_finished "rm -rf client" &&
	git init client &&
	pack_responses "503 3600" 200 &&
	fetch_pack test_must_fail &&
	test_line_count = 1 "$HTTPD_ROOT_PATH/pack-retry.requests"
'

test_expect_success CGIPASSAUTH 'authentication does not consume transient retries' '
	test_when_finished "rm -rf client" &&
	git init client &&
	write_script helper <<-\EOF &&
	echo "$1" >>"$HOME/helper-operations"
	if test "$1" = get
	then
		echo capability[]=authtype
		echo authtype=Bearer
		echo credential=pack-token
	fi
	EOF
	test_config_global credential.helper "!\"$TRASH_DIRECTORY/helper\"" &&
	pack_responses 503 401 503 200 &&
	fetch_pack &&
	printf "get\nstore\n" >expect &&
	test_cmp expect helper-operations &&
	printf "GET||\nGET||\nGET||Bearer pack-token\nGET||Bearer pack-token\n" >expect &&
	test_cmp expect "$HTTPD_ROOT_PATH/pack-retry.requests"
'

test_expect_success 'parallel packfile URI fetch completes after HTTP 503' '
	test_when_finished "rm -rf client" &&
	server="$HTTPD_DOCUMENT_ROOT_PATH/uri" &&
	git init "$server" &&
	test_commit -C "$server" uri &&
	git -C "$server" config uploadpack.allowsidebandall true &&
	git -C "$server" config uploadpack.allowNoRefDelta true &&
	blob=$(git -C "$server" rev-parse HEAD:uri.t) &&
	uri_hash=$(echo "$blob" | git -C "$server" pack-objects \
		"$HTTPD_DOCUMENT_ROOT_PATH/uri-pack") &&
	git -C "$server" config uploadpack.blobpackfileuri \
		"$blob $uri_hash $HTTPD_URL/pack_retry/uri-pack-$uri_hash.pack" &&
	test_commit -C "$server" other &&
	blob=$(git -C "$server" rev-parse HEAD:other.t) &&
	other_hash=$(echo "$blob" | git -C "$server" pack-objects \
		"$HTTPD_DOCUMENT_ROOT_PATH/other-pack") &&
	git -C "$server" config --add uploadpack.blobpackfileuri \
		"$blob $other_hash $HTTPD_URL/dumb/other-pack-$other_hash.pack" &&
	pack_responses 503 200 &&
	GIT_TEST_SIDEBAND_ALL=1 git -c protocol.version=2 \
		-c fetch.uriprotocols=http -c fetch.packfileUriJobs=2 \
		clone "$HTTPD_URL/smart/uri" client &&
	test_line_count = 2 "$HTTPD_ROOT_PATH/pack-retry.requests" &&
	test_cmp "$server/uri.t" client/uri.t &&
	test_cmp "$server/other.t" client/other.t &&
	test_cmp "$HTTPD_DOCUMENT_ROOT_PATH/other-pack-$other_hash.pack" \
		"client/.git/objects/pack/pack-$other_hash.pack" &&
	git -C client fsck
'

test_done
