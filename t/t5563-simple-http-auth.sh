#!/bin/sh

test_description='test http auth header and credential helper interop'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-httpd.sh

enable_cgipassauth
if ! test_have_prereq CGIPASSAUTH
then
	skip_all="no CGIPassAuth support"
	test_done
fi
start_httpd

test_expect_success 'setup_credential_helper' '
	mkdir "$TRASH_DIRECTORY/bin" &&
	PATH=$PATH:"$TRASH_DIRECTORY/bin" &&
	export PATH &&

	CREDENTIAL_HELPER="$TRASH_DIRECTORY/bin/git-credential-test-helper" &&
	write_script "$CREDENTIAL_HELPER" <<-\EOF
	cmd=$1
	teefile=$cmd-query-temp.cred
	catfile=$cmd-reply.cred
	sed -n -e "/^$/q" -e "p" >>$teefile
	state=$(sed -ne "s/^state\[\]=helper://p" "$teefile")
	if test -z "$state"
	then
		mv "$teefile" "$cmd-query.cred"
	else
		mv "$teefile" "$cmd-query-$state.cred"
		catfile="$cmd-reply-$state.cred"
	fi
	if test "$cmd" = "get"
	then
		cat $catfile
	fi
	EOF
'

set_credential_reply () {
	local suffix="$(test -n "$2" && echo "-$2")"
	cat >"$TRASH_DIRECTORY/$1-reply$suffix.cred"
}

expect_credential_query () {
	local suffix="$(test -n "$2" && echo "-$2")"
	cat >"$TRASH_DIRECTORY/$1-expect$suffix.cred" &&
	test_cmp "$TRASH_DIRECTORY/$1-expect$suffix.cred" \
		 "$TRASH_DIRECTORY/$1-query$suffix.cred"
}

per_test_cleanup () {
	rm -f *.cred &&
	rm -f "$HTTPD_ROOT_PATH"/custom-auth.valid \
	      "$HTTPD_ROOT_PATH"/custom-auth.challenge \
	      "$HTTPD_ROOT_PATH"/custom-auth.routes \
	      "$HTTPD_ROOT_PATH"/custom-auth.requests \
	      "$HTTPD_ROOT_PATH"/custom-auth.destination.valid \
	      "$HTTPD_ROOT_PATH"/custom-auth.destination.challenge
}

test_expect_success 'setup repository' '
	test_commit foo &&
	git init --bare "$HTTPD_DOCUMENT_ROOT_PATH/repo.git" &&
	git push --mirror "$HTTPD_DOCUMENT_ROOT_PATH/repo.git"
'

test_expect_success 'access using basic auth' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	username=alice
	password=secret-passwd
	EOF

	# Basic base64(alice:secret-passwd)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default response=WWW-Authenticate: Basic realm="example.com"
	EOF

	test_config_global credential.helper test-helper &&
	git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=Basic realm="example.com"
	EOF

	expect_credential_query store <<-EOF
	protocol=http
	host=$HTTPD_DEST
	username=alice
	password=secret-passwd
	EOF
'

test_expect_success 'access using basic auth via authtype' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	capability[]=authtype
	authtype=Basic
	credential=YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	# Basic base64(alice:secret-passwd)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default response=WWW-Authenticate: Basic realm="example.com"
	EOF

	test_config_global credential.helper test-helper &&
	GIT_CURL_VERBOSE=1 git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=Basic realm="example.com"
	EOF

	expect_credential_query store <<-EOF
	capability[]=authtype
	authtype=Basic
	credential=YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	protocol=http
	host=$HTTPD_DEST
	EOF
'

test_expect_success 'access using basic auth invalid credentials' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	username=baduser
	password=wrong-passwd
	EOF

	# Basic base64(alice:secret-passwd)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default response=WWW-Authenticate: Basic realm="example.com"
	EOF

	test_config_global credential.helper test-helper &&
	test_must_fail git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=Basic realm="example.com"
	EOF

	expect_credential_query erase <<-EOF
	protocol=http
	host=$HTTPD_DEST
	username=baduser
	password=wrong-passwd
	wwwauth[]=Basic realm="example.com"
	EOF
'

test_expect_success 'access using basic proactive auth' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	username=alice
	password=secret-passwd
	EOF

	# Basic base64(alice:secret-passwd)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default status=403
	EOF

	test_config_global credential.helper test-helper &&
	test_config_global http.proactiveAuth basic &&
	git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=Basic
	EOF

	expect_credential_query store <<-EOF
	protocol=http
	host=$HTTPD_DEST
	username=alice
	password=secret-passwd
	EOF
'

test_expect_success 'access using auto proactive auth with basic default' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	username=alice
	password=secret-passwd
	EOF

	# Basic base64(alice:secret-passwd)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default status=403
	EOF

	test_config_global credential.helper test-helper &&
	test_config_global http.proactiveAuth auto &&
	git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	EOF

	expect_credential_query store <<-EOF
	protocol=http
	host=$HTTPD_DEST
	username=alice
	password=secret-passwd
	EOF
'

test_expect_success 'access using auto proactive auth with authtype from credential helper' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	capability[]=authtype
	authtype=Bearer
	credential=YS1naXQtdG9rZW4=
	EOF

	# Basic base64(a-git-token)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Bearer YS1naXQtdG9rZW4=
	EOF

	CHALLENGE="$HTTPD_ROOT_PATH/custom-auth.challenge" &&

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default status=403
	EOF

	test_config_global credential.helper test-helper &&
	test_config_global http.proactiveAuth auto &&
	git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	EOF

	expect_credential_query store <<-EOF
	capability[]=authtype
	authtype=Bearer
	credential=YS1naXQtdG9rZW4=
	protocol=http
	host=$HTTPD_DEST
	EOF
'

test_expect_success 'access using basic auth with extra challenges' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	username=alice
	password=secret-passwd
	EOF

	# Basic base64(alice:secret-passwd)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default response=WWW-Authenticate: FooBar param1="value1" param2="value2"
	id=default response=WWW-Authenticate: Bearer authorize_uri="id.example.com" p=1 q=0
	id=default response=WWW-Authenticate: Basic realm="example.com"
	EOF

	test_config_global credential.helper test-helper &&
	git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=FooBar param1="value1" param2="value2"
	wwwauth[]=Bearer authorize_uri="id.example.com" p=1 q=0
	wwwauth[]=Basic realm="example.com"
	EOF

	expect_credential_query store <<-EOF
	protocol=http
	host=$HTTPD_DEST
	username=alice
	password=secret-passwd
	EOF
'

test_expect_success 'access using basic auth mixed-case wwwauth header name' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	username=alice
	password=secret-passwd
	EOF

	# Basic base64(alice:secret-passwd)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default response=www-authenticate: foobar param1="value1" param2="value2"
	id=default response=WWW-AUTHENTICATE: BEARER authorize_uri="id.example.com" p=1 q=0
	id=default response=WwW-aUtHeNtIcAtE: baSiC realm="example.com"
	EOF

	test_config_global credential.helper test-helper &&
	git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=foobar param1="value1" param2="value2"
	wwwauth[]=BEARER authorize_uri="id.example.com" p=1 q=0
	wwwauth[]=baSiC realm="example.com"
	EOF

	expect_credential_query store <<-EOF
	protocol=http
	host=$HTTPD_DEST
	username=alice
	password=secret-passwd
	EOF
'

test_expect_success 'access using basic auth with wwwauth header continuations' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	username=alice
	password=secret-passwd
	EOF

	# Basic base64(alice:secret-passwd)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	# Note that leading and trailing whitespace is important to correctly
	# simulate a continuation/folded header.
	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default response=WWW-Authenticate: FooBar param1="value1"
	id=default response= param2="value2"
	id=default response=WWW-Authenticate: Bearer authorize_uri="id.example.com"
	id=default response= p=1
	id=default response= q=0
	id=default response=WWW-Authenticate: Basic realm="example.com"
	EOF

	test_config_global credential.helper test-helper &&
	git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=FooBar param1="value1" param2="value2"
	wwwauth[]=Bearer authorize_uri="id.example.com" p=1 q=0
	wwwauth[]=Basic realm="example.com"
	EOF

	expect_credential_query store <<-EOF
	protocol=http
	host=$HTTPD_DEST
	username=alice
	password=secret-passwd
	EOF
'

test_expect_success 'access using basic auth with wwwauth header empty continuations' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	username=alice
	password=secret-passwd
	EOF

	# Basic base64(alice:secret-passwd)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	CHALLENGE="$HTTPD_ROOT_PATH/custom-auth.challenge" &&

	# Note that leading and trailing whitespace is important to correctly
	# simulate a continuation/folded header.
	printf "id=1 status=200\n" >"$CHALLENGE" &&
	printf "id=default response=WWW-Authenticate: FooBar param1=\"value1\"\r\n" >>"$CHALLENGE" &&
	printf "id=default response= \r\n" >>"$CHALLENGE" &&
	printf "id=default response= param2=\"value2\"\r\n" >>"$CHALLENGE" &&
	printf "id=default response=WWW-Authenticate: Bearer authorize_uri=\"id.example.com\"\r\n" >>"$CHALLENGE" &&
	printf "id=default response= p=1\r\n" >>"$CHALLENGE" &&
	printf "id=default response= \r\n" >>"$CHALLENGE" &&
	printf "id=default response= q=0\r\n" >>"$CHALLENGE" &&
	printf "id=default response=WWW-Authenticate: Basic realm=\"example.com\"\r\n" >>"$CHALLENGE" &&

	test_config_global credential.helper test-helper &&
	git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=FooBar param1="value1" param2="value2"
	wwwauth[]=Bearer authorize_uri="id.example.com" p=1 q=0
	wwwauth[]=Basic realm="example.com"
	EOF

	expect_credential_query store <<-EOF
	protocol=http
	host=$HTTPD_DEST
	username=alice
	password=secret-passwd
	EOF
'

test_expect_success 'access using basic auth with wwwauth header mixed continuations' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	username=alice
	password=secret-passwd
	EOF

	# Basic base64(alice:secret-passwd)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	CHALLENGE="$HTTPD_ROOT_PATH/custom-auth.challenge" &&

	# Note that leading and trailing whitespace is important to correctly
	# simulate a continuation/folded header.
	printf "id=1 status=200\n" >"$CHALLENGE" &&
	printf "id=default response=WWW-Authenticate: FooBar param1=\"value1\"\r\n" >>"$CHALLENGE" &&
	printf "id=default response= \r\n" >>"$CHALLENGE" &&
	printf "id=default response=\tparam2=\"value2\"\r\n" >>"$CHALLENGE" &&
	printf "id=default response=WWW-Authenticate: Basic realm=\"example.com\"\r\n" >>"$CHALLENGE" &&

	test_config_global credential.helper test-helper &&
	git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=FooBar param1="value1" param2="value2"
	wwwauth[]=Basic realm="example.com"
	EOF

	expect_credential_query store <<-EOF
	protocol=http
	host=$HTTPD_DEST
	username=alice
	password=secret-passwd
	EOF
'

test_expect_success 'access using bearer auth' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	capability[]=authtype
	authtype=Bearer
	credential=YS1naXQtdG9rZW4=
	EOF

	# Basic base64(a-git-token)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Bearer YS1naXQtdG9rZW4=
	EOF

	CHALLENGE="$HTTPD_ROOT_PATH/custom-auth.challenge" &&

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default response=WWW-Authenticate: FooBar param1="value1" param2="value2"
	id=default response=WWW-Authenticate: Bearer authorize_uri="id.example.com" p=1 q=0
	id=default response=WWW-Authenticate: Basic realm="example.com"
	EOF

	test_config_global credential.helper test-helper &&
	git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=FooBar param1="value1" param2="value2"
	wwwauth[]=Bearer authorize_uri="id.example.com" p=1 q=0
	wwwauth[]=Basic realm="example.com"
	EOF

	expect_credential_query store <<-EOF
	capability[]=authtype
	authtype=Bearer
	credential=YS1naXQtdG9rZW4=
	protocol=http
	host=$HTTPD_DEST
	EOF
'

test_expect_success 'access using bearer auth with invalid credentials' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	capability[]=authtype
	authtype=Bearer
	credential=incorrect-token
	EOF

	# Basic base64(a-git-token)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Bearer YS1naXQtdG9rZW4=
	EOF

	CHALLENGE="$HTTPD_ROOT_PATH/custom-auth.challenge" &&

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default response=WWW-Authenticate: FooBar param1="value1" param2="value2"
	id=default response=WWW-Authenticate: Bearer authorize_uri="id.example.com" p=1 q=0
	id=default response=WWW-Authenticate: Basic realm="example.com"
	EOF

	test_config_global credential.helper test-helper &&
	test_must_fail git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=FooBar param1="value1" param2="value2"
	wwwauth[]=Bearer authorize_uri="id.example.com" p=1 q=0
	wwwauth[]=Basic realm="example.com"
	EOF

	expect_credential_query erase <<-EOF
	capability[]=authtype
	authtype=Bearer
	credential=incorrect-token
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=FooBar param1="value1" param2="value2"
	wwwauth[]=Bearer authorize_uri="id.example.com" p=1 q=0
	wwwauth[]=Basic realm="example.com"
	EOF
'

test_expect_success 'clone with bearer auth and probe_rpc' '
	test_when_finished "per_test_cleanup" &&
	test_when_finished "rm -rf large.git" &&

	# Set up a repository large enough to trigger probe_rpc
	git init large.git &&
	(
		cd large.git &&
		git config set maintenance.auto false &&
		git commit --allow-empty --message "initial" &&
		# Create many refs to trigger probe_rpc, which is called when
		# the request body is larger than http.postBuffer.
		#
		# In the test later, http.postBuffer is set to 70000. Each
		# "want" line is ~45 bytes, so we need at least 70000/45 = ~1600
		# refs
		test_seq -f "create refs/heads/branch-%d @" 2000 |
		git update-ref --stdin
	) &&
	git clone --bare large.git "$HTTPD_DOCUMENT_ROOT_PATH/large.git" &&

	# Clone it through HTTP with a Bearer token
	set_credential_reply get <<-EOF &&
	capability[]=authtype
	authtype=Bearer
	credential=YS1naXQtdG9rZW4=
	EOF

	# Bearer token
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Bearer YS1naXQtdG9rZW4=
	EOF

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default response=WWW-Authenticate: Bearer authorize_uri="id.example.com"
	EOF

	# Set a small buffer to force probe_rpc to be called
	# Must be > LARGE_PACKET_MAX (65520)
	test_config_global http.postBuffer 70000 &&
	test_config_global credential.helper test-helper &&
	git clone "$HTTPD_URL/custom_auth/large.git" partial-auth-clone 2>clone-error
'

test_expect_success 'access using three-legged auth' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	capability[]=authtype
	capability[]=state
	authtype=Multistage
	credential=YS1naXQtdG9rZW4=
	state[]=helper:foobar
	continue=1
	EOF

	set_credential_reply get foobar <<-EOF &&
	capability[]=authtype
	capability[]=state
	authtype=Multistage
	credential=YW5vdGhlci10b2tlbg==
	state[]=helper:bazquux
	EOF

	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Multistage YS1naXQtdG9rZW4=
	id=2 creds=Multistage YW5vdGhlci10b2tlbg==
	EOF

	CHALLENGE="$HTTPD_ROOT_PATH/custom-auth.challenge" &&

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=401 response=WWW-Authenticate: Multistage challenge="456"
	id=1 status=401 response=WWW-Authenticate: Bearer authorize_uri="id.example.com" p=1 q=0
	id=2 status=200
	id=default response=WWW-Authenticate: Multistage challenge="123"
	id=default response=WWW-Authenticate: Bearer authorize_uri="id.example.com" p=1 q=0
	EOF

	test_config_global credential.helper test-helper &&
	git ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	expect_credential_query get <<-EOF &&
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=Multistage challenge="123"
	wwwauth[]=Bearer authorize_uri="id.example.com" p=1 q=0
	EOF

	expect_credential_query get foobar <<-EOF &&
	capability[]=authtype
	capability[]=state
	authtype=Multistage
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=Multistage challenge="456"
	wwwauth[]=Bearer authorize_uri="id.example.com" p=1 q=0
	state[]=helper:foobar
	EOF

	expect_credential_query store bazquux <<-EOF
	capability[]=authtype
	capability[]=state
	authtype=Multistage
	credential=YW5vdGhlci10b2tlbg==
	protocol=http
	host=$HTTPD_DEST
	state[]=helper:bazquux
	EOF
'

test_lazy_prereq SPNEGO 'curl --version | grep -qi "SPNEGO\|GSS-API\|Kerberos\|negotiate"'

test_expect_success SPNEGO 'http.emptyAuth=auto attempts Negotiate before credential_fill' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	username=alice
	password=secret-passwd
	EOF

	# Basic base64(alice:secret-passwd)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default response=WWW-Authenticate: Negotiate
	id=default response=WWW-Authenticate: Basic realm="example.com"
	EOF

	test_config_global credential.helper test-helper &&
	GIT_TRACE_CURL="$TRASH_DIRECTORY/trace-auto" \
		git -c http.emptyAuth=auto \
		ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	# In auto mode with a Negotiate+Basic server, there should be
	# three 401 responses: (1) initial no-auth request, (2) empty-auth
	# retry where Negotiate fails (no Kerberos ticket), (3) libcurl
	# internal Negotiate retry. The fourth attempt uses Basic
	# credentials from credential_fill and succeeds.
	grep "HTTP/[0-9.]* 401" "$TRASH_DIRECTORY/trace-auto" >actual_401s &&
	test_line_count = 3 actual_401s &&

	expect_credential_query get <<-EOF
	capability[]=authtype
	capability[]=state
	protocol=http
	host=$HTTPD_DEST
	wwwauth[]=Negotiate
	wwwauth[]=Basic realm="example.com"
	EOF
'

test_expect_success SPNEGO 'http.emptyAuth=false skips Negotiate' '
	test_when_finished "per_test_cleanup" &&

	set_credential_reply get <<-EOF &&
	username=alice
	password=secret-passwd
	EOF

	# Basic base64(alice:secret-passwd)
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	EOF

	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=200
	id=default response=WWW-Authenticate: Negotiate
	id=default response=WWW-Authenticate: Basic realm="example.com"
	EOF

	test_config_global credential.helper test-helper &&
	GIT_TRACE_CURL="$TRASH_DIRECTORY/trace-false" \
		git -c http.emptyAuth=false \
		ls-remote "$HTTPD_URL/custom_auth/repo.git" &&

	# With emptyAuth=false, Negotiate is stripped immediately and
	# credential_fill is called right away. Only one 401 response.
	grep "HTTP/[0-9.]* 401" "$TRASH_DIRECTORY/trace-false" >actual_401s &&
	test_line_count = 1 actual_401s
'

for auth in challenged preauthenticated redirected
do
test_expect_success "push follows discovery redirects ($auth)" '
	test_when_finished per_test_cleanup &&
	test_config -C "$HTTPD_DOCUMENT_ROOT_PATH/repo.git" http.receivepack true &&
	set_credential_reply get <<-EOF &&
	capability[]=authtype
	authtype=Bearer
	credential=redirect-token
	EOF
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Bearer redirect-token
	EOF
	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=302 response=Location: $HTTPD_URL/smart/repo.git/info/refs?service=git-receive-pack
	id=default response=WWW-Authenticate: Bearer realm="example.com"
	EOF
	test_config_global credential.helper test-helper &&
	url="$HTTPD_URL/custom_auth/repo.git" &&
	>expect &&
	if test "$auth" = redirected
	then
		url="$HTTPD_URL/redir-to/custom_auth/repo.git" &&
		cat >>expect <<-EOF
		GET  /redir-to/custom_auth/repo.git/info/refs?service=git-receive-pack HTTP/1.1 302
		GET  /really-redir-to?path=custom_auth/repo.git/info/refs&qs=service=git-receive-pack HTTP/1.1 302
		EOF
	fi &&
	if test "$auth" = preauthenticated
	then
		test_config_global http.extraHeader "Authorization: Bearer redirect-token"
	else
		echo "GET  /custom_auth/repo.git/info/refs?service=git-receive-pack HTTP/1.1 200 -" >>expect
	fi &&
	cat >>expect <<-EOF &&
	GET  /custom_auth/repo.git/info/refs?service=git-receive-pack HTTP/1.1 200 -
	GET  /smart/repo.git/info/refs?service=git-receive-pack HTTP/1.1 200
	POST /smart/repo.git/git-receive-pack HTTP/1.1 200
	EOF
	>"$HTTPD_ROOT_PATH/access.log" &&
	GIT_TRACE_CURL="$TRASH_DIRECTORY/redirect-$auth.trace" \
	git -c http.followRedirects=initial push \
		"$url" HEAD:refs/heads/redirect-$auth &&
	# Apache does not record the status written by the NPH CGI.
	test_grep "Recv header: HTTP/1.1 302" "redirect-$auth.trace" &&
	if test "$auth" = preauthenticated
	then
		test_grep ! "Recv header: HTTP/1.1 401" "redirect-$auth.trace"
	else
		test_grep "Recv header: HTTP/1.1 401" "redirect-$auth.trace"
	fi &&
	check_access_log expect &&
	git rev-parse HEAD >expect-oid &&
	git -C "$HTTPD_DOCUMENT_ROOT_PATH/repo.git" \
		rev-parse refs/heads/redirect-$auth >actual-oid &&
	test_cmp expect-oid actual-oid
'
done

for extra_header in none cookie
do
test_expect_success "select credentials after cross-host retry redirect ($extra_header)" '
	test_when_finished per_test_cleanup &&
	test_config -C "$HTTPD_DOCUMENT_ROOT_PATH/repo.git" http.receivepack true &&
	write_script "$TRASH_DIRECTORY/bin/git-credential-redirect-helper" <<-\EOF &&
	test "$1" = get || exit 0
	host=
	while IFS= read -r line
	do
		case "$line" in host=*) host=${line#host=} ;; esac
	done
	case "$host" in
	"$ORIGIN_HOST") echo username=alice ;;
	"$DESTINATION_HOST") echo username=bob ;;
	*) exit 1 ;;
	esac
	echo password=secret-passwd
	EOF
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Basic YWxpY2U6c2VjcmV0LXBhc3N3ZA==
	id=2 creds=Basic Ym9iOnNlY3JldC1wYXNzd2Q=
	EOF
	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=302 response=Location: $HTTPD_PROTO://localhost:$LIB_HTTPD_PORT/custom_auth/repo.git/info/refs?service=git-receive-pack
	id=2 status=200
	id=default response=WWW-Authenticate: Basic realm="example.com"
	EOF
	test_config_global credential.helper redirect-helper &&
	if test "$extra_header" = cookie
	then
		test_config_global "http.$HTTPD_URL/.extraHeader" "Cookie: origin-secret"
	fi &&
	>"$HTTPD_ROOT_PATH/access.log" &&
	ORIGIN_HOST=$HTTPD_DEST DESTINATION_HOST=localhost:$LIB_HTTPD_PORT \
	git -c http.followRedirects=initial push \
		"$HTTPD_URL/custom_auth/repo.git" \
		HEAD:refs/heads/cross-host-$extra_header 2>err &&
	cat >expect <<-EOF &&
	GET  /custom_auth/repo.git/info/refs?service=git-receive-pack HTTP/1.1 200 -
	GET  /custom_auth/repo.git/info/refs?service=git-receive-pack HTTP/1.1 200 -
	GET  /custom_auth/repo.git/info/refs?service=git-receive-pack HTTP/1.1 200 -
	GET  /custom_auth/repo.git/info/refs?service=git-receive-pack HTTP/1.1 200 -
	POST /custom_auth/repo.git/git-receive-pack HTTP/1.1 200 -
	EOF
	check_access_log expect &&
	git rev-parse HEAD >expect-oid &&
	git -C "$HTTPD_DOCUMENT_ROOT_PATH/repo.git" \
		rev-parse refs/heads/cross-host-$extra_header >actual-oid &&
	test_cmp expect-oid actual-oid
'
done

setup_redirect_credentials () {
	test_when_finished per_test_cleanup &&
	test_when_finished "unset REDIRECT_HELPER_LOG" &&
	REDIRECT_HELPER_LOG="$TRASH_DIRECTORY/redirect-helper.calls" &&
	export REDIRECT_HELPER_LOG &&
	>"$REDIRECT_HELPER_LOG" &&
	>"$HTTPD_ROOT_PATH/custom-auth.requests" &&
	origin_url="$HTTPD_URL/custom_auth/repo.git" &&
	destination_url="$HTTPD_PROTO://$1/custom_auth/$2" &&
	if ! test -d "$HTTPD_DOCUMENT_ROOT_PATH/other.git"
	then
		git clone --bare "$HTTPD_DOCUMENT_ROOT_PATH/repo.git" \
			"$HTTPD_DOCUMENT_ROOT_PATH/other.git"
	fi &&
	test_config -C "$HTTPD_DOCUMENT_ROOT_PATH/$2" http.receivepack true &&
	test_config_global credential.helper "" &&
	write_script "$TRASH_DIRECTORY/bin/git-credential-redirect-trace" <<-\EOF &&
	provider=$1
	operation=$2
	path=
	while IFS= read -r line
	do
		case "$line" in path=*) path=${line#path=} ;; esac
	done
	if test "$provider" = by-path
	then
		case "$path" in
		custom_auth/other.git) provider=destination ;;
		*) provider=origin ;;
		esac
	fi
	echo "$provider $operation" >>"$REDIRECT_HELPER_LOG"
	if test "$operation" = get
	then
		echo "capability[]=authtype"
		echo "authtype=Bearer"
		echo "credential=$provider-token"
	fi
	EOF
	cat >"$HTTPD_ROOT_PATH/custom-auth.valid" <<-EOF &&
	id=1 creds=Bearer origin-token
	EOF
	cat >"$HTTPD_ROOT_PATH/custom-auth.challenge" <<-EOF &&
	id=1 status=302 response=Location: $destination_url/info/refs?service=git-receive-pack
	id=default response=WWW-Authenticate: Bearer realm="origin"
	EOF
	cat >"$HTTPD_ROOT_PATH/custom-auth.destination.valid" <<-EOF &&
	id=1 creds=Bearer $3-token
	EOF
	cat >"$HTTPD_ROOT_PATH/custom-auth.destination.challenge" <<-EOF &&
	id=1 status=200
	id=default response=WWW-Authenticate: Bearer realm="destination"
	EOF
	echo "$1/$2 custom-auth.destination" >"$HTTPD_ROOT_PATH/custom-auth.routes"
}

test_expect_success 'same credential identity retains Bearer auth after redirect' '
	setup_redirect_credentials "$HTTPD_DEST" other.git origin &&
	test_config_global credential.helper "redirect-trace origin" &&
	git push "$origin_url" HEAD:refs/heads/same-identity &&
	cat >expect <<-EOF &&
	GET $HTTPD_DEST /repo.git/info/refs|||
	GET $HTTPD_DEST /repo.git/info/refs|Bearer origin-token||
	GET $HTTPD_DEST /other.git/info/refs|Bearer origin-token||
	POST $HTTPD_DEST /other.git/git-receive-pack|Bearer origin-token||
	EOF
	test_cmp expect "$HTTPD_ROOT_PATH/custom-auth.requests" &&
	grep " get$" "$REDIRECT_HELPER_LOG" >actual &&
	echo "origin get" >expect &&
	test_cmp expect actual &&
	test_grep ! " erase$" "$REDIRECT_HELPER_LOG"
'

test_expect_success 'destination proactive auth applies to the first redirected GET' '
	setup_redirect_credentials "localhost:$LIB_HTTPD_PORT" repo.git destination &&
	test_config_global "credential.$origin_url.helper" "redirect-trace origin" &&
	test_config_global "credential.$destination_url.helper" "redirect-trace destination" &&
	test_config_global "http.$origin_url.proactiveAuth" none &&
	test_config_global "http.$destination_url.proactiveAuth" auto &&
	git push "$origin_url" HEAD:refs/heads/destination-proactive &&
	cat >expect <<-EOF &&
	GET $HTTPD_DEST /repo.git/info/refs|||
	GET $HTTPD_DEST /repo.git/info/refs|Bearer origin-token||
	GET localhost:$LIB_HTTPD_PORT /repo.git/info/refs|Bearer destination-token||
	POST localhost:$LIB_HTTPD_PORT /repo.git/git-receive-pack|Bearer destination-token||
	EOF
	test_cmp expect "$HTTPD_ROOT_PATH/custom-auth.requests" &&
	test_grep ! " erase$" "$REDIRECT_HELPER_LOG"
'

for scope in useHttpPath helper
do
test_expect_success "redirect selects path-scoped credentials ($scope)" '
	setup_redirect_credentials "$HTTPD_DEST" other.git destination &&
	if test "$scope" = useHttpPath
	then
		test_config_global credential.useHttpPath true &&
		test_config_global credential.helper "redirect-trace by-path"
	else
		test_config_global credential.useHttpPath false &&
		test_config_global "credential.$origin_url.helper" "redirect-trace origin" &&
		test_config_global "credential.$destination_url.helper" "redirect-trace destination"
	fi &&
	git push "$origin_url" HEAD:refs/heads/path-$scope &&
	cat >expect <<-EOF &&
	GET $HTTPD_DEST /repo.git/info/refs|||
	GET $HTTPD_DEST /repo.git/info/refs|Bearer origin-token||
	GET $HTTPD_DEST /other.git/info/refs|||
	GET $HTTPD_DEST /other.git/info/refs|Bearer destination-token||
	POST $HTTPD_DEST /other.git/git-receive-pack|Bearer destination-token||
	EOF
	test_cmp expect "$HTTPD_ROOT_PATH/custom-auth.requests" &&
	test_grep ! " erase$" "$REDIRECT_HELPER_LOG"
'
done

test_expect_success 'redirect selects destination headers before its first GET' '
	setup_redirect_credentials "localhost:$LIB_HTTPD_PORT" repo.git destination &&
	test_config_global "credential.$origin_url.helper" "redirect-trace origin" &&
	test_config_global "credential.$destination_url.helper" "redirect-trace destination" &&
	test_config_global "http.$origin_url.extraHeader" "X-Origin-Secret: origin-only" &&
	test_config_global "http.$destination_url.extraHeader" "X-Destination-Secret: destination-only" &&
	git config --global --add "http.$origin_url.extraHeader" "Authorization: Bearer origin-token" &&
	git config --global --add "http.$destination_url.extraHeader" "Authorization: Bearer destination-token" &&
	git push "$origin_url" HEAD:refs/heads/destination-headers &&
	cat >expect <<-EOF &&
	GET $HTTPD_DEST /repo.git/info/refs|Bearer origin-token|origin-only|
	GET localhost:$LIB_HTTPD_PORT /repo.git/info/refs|Bearer destination-token||destination-only
	POST localhost:$LIB_HTTPD_PORT /repo.git/git-receive-pack|Bearer destination-token||destination-only
	EOF
	test_cmp expect "$HTTPD_ROOT_PATH/custom-auth.requests" &&
	test_grep ! " erase$" "$REDIRECT_HELPER_LOG"
'

test_done
