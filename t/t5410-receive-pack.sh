#!/bin/sh

test_description='git receive-pack'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

test_expect_success 'setup' '
	test_commit base &&
	git clone -s --bare . fork &&
	git checkout -b public/branch main &&
	test_commit public &&
	git checkout -b private/branch main &&
	test_commit private
'

extract_haves () {
	depacketize | sed -n 's/^\([^ ][^ ]*\) \.have/\1/p'
}

test_expect_success 'with core.alternateRefsCommand' '
	write_script fork/alternate-refs <<-\EOF &&
		git --git-dir="$1" for-each-ref \
			--format="%(objectname)" \
			refs/heads/public/
	EOF
	test_config -C fork core.alternateRefsCommand ./alternate-refs &&
	git rev-parse public/branch >expect &&
	printf "0000" | git receive-pack fork >actual &&
	extract_haves <actual >actual.haves &&
	test_cmp expect actual.haves
'

test_expect_success 'with core.alternateRefsPrefixes' '
	test_config -C fork core.alternateRefsPrefixes "refs/heads/private" &&
	git rev-parse private/branch >expect &&
	printf "0000" | git receive-pack fork >actual &&
	extract_haves <actual >actual.haves &&
	test_cmp expect actual.haves
'

# The `tee.exe` shipped in Git for Windows v2.49.0 is known to hang frequently
# when spawned from `git.exe` and piping its output to `git.exe`. This seems
# related to MSYS2 runtime bug fixes regarding the signal handling; Let's just
# skip the tests that need to exercise this when the faulty MSYS2 runtime is
# detected; The test cases are exercised enough in other matrix jobs of the CI
# runs.
test_lazy_prereq TEE_DOES_NOT_HANG '
	test_have_prereq !MINGW &&
	case "$(uname -a)" in *3.5.7-463ebcdc.x86_64*) false;; esac
'

test_expect_success TEE_DOES_NOT_HANG \
	'receive-pack missing objects fails connectivity check' '
	test_when_finished rm -rf repo remote.git setup.git &&

	git init repo &&
	git -C repo commit --allow-empty -m 1 &&
	git clone --bare repo setup.git &&
	git -C repo commit --allow-empty -m 2 &&

	# Capture git-send-pack(1) output sent to git-receive-pack(1).
	git -C repo send-pack ../setup.git --all \
		--receive-pack="tee ${SQ}$(pwd)/out${SQ} | git-receive-pack" &&

	# Replay captured git-send-pack(1) output on new empty repository.
	git init --bare remote.git &&
	git receive-pack remote.git <out >actual 2>err &&

	test_grep "missing necessary objects" actual &&
	test_grep "fatal: Failed to traverse parents" err &&
	test_must_fail git -C remote.git cat-file -e $(git -C repo rev-parse HEAD)
'

test_expect_success TEE_DOES_NOT_HANG \
	'receive-pack missing objects bypasses connectivity check' '
	test_when_finished rm -rf repo remote.git setup.git &&

	git init repo &&
	git -C repo commit --allow-empty -m 1 &&
	git clone --bare repo setup.git &&
	git -C repo commit --allow-empty -m 2 &&

	# Capture git-send-pack(1) output sent to git-receive-pack(1).
	git -C repo send-pack ../setup.git --all \
		--receive-pack="tee ${SQ}$(pwd)/out${SQ} | git-receive-pack" &&

	# Replay captured git-send-pack(1) output on new empty repository.
	git init --bare remote.git &&
	git receive-pack --skip-connectivity-check remote.git <out >actual 2>err &&

	test_grep ! "missing necessary objects" actual &&
	test_must_be_empty err &&
	git -C remote.git cat-file -e $(git -C repo rev-parse HEAD) &&
	test_must_fail git -C remote.git rev-list $(git -C repo rev-parse HEAD)
'

test_expect_success TEE_DOES_NOT_HANG \
	'explicit-haves does not infer haves from named refs' '
	test_when_finished "rm -rf explicit-haves-*" &&

	git init explicit-haves-src &&
	test_commit -C explicit-haves-src B &&
	git clone --bare explicit-haves-src explicit-haves-base.git &&
	test_commit -C explicit-haves-src F1 &&
	test_commit -C explicit-haves-src F2 &&
	git -C explicit-haves-src reset --hard F1 &&
	test_commit -C explicit-haves-src F3 &&
	B=$(git -C explicit-haves-src rev-parse B) &&
	F1=$(git -C explicit-haves-src rev-parse F1) &&
	F2=$(git -C explicit-haves-src rev-parse F2) &&
	F3=$(git -C explicit-haves-src rev-parse F3) &&
	S=$(git -C explicit-haves-src rev-parse F1:F1.t) &&

	for variant in no-cap capability
	do
		git clone --bare --shared explicit-haves-base.git \
			explicit-haves-setup-$variant.git &&
		git -C explicit-haves-setup-$variant.git update-ref -d \
			refs/heads/main &&
		git -C explicit-haves-setup-$variant.git update-ref -d \
			refs/tags/B &&
		git -C explicit-haves-src push --no-thin \
			../explicit-haves-setup-$variant.git \
			F2:refs/heads/feature &&
		git clone --bare explicit-haves-base.git \
			explicit-haves-replay-$variant.git &&
		old_pack=$(printf "%s\n^%s\n" "$F2" "$B" | \
			git -C explicit-haves-src pack-objects --revs \
			../explicit-haves-replay-$variant.git/objects/pack/old) &&
		echo "$old_pack" >explicit-haves-old-$variant &&
		git -C explicit-haves-replay-$variant.git update-ref \
			refs/heads/feature "$F2" &&
		git -C explicit-haves-replay-$variant.git config \
			receive.unpackLimit 0 &&
		git -C explicit-haves-replay-$variant.git config \
			maintenance.auto false ||
			exit 1
	done &&

	# Without the capability, the named F2 ref is used as a negative.
	# The resulting pack has F3 but omits its F1 parent and the blob
	# introduced by F1.
	rcvpck="unset GIT_TRACE2_EVENT; tee ${SQ}$(pwd)/explicit-haves-no-cap.req${SQ} | git receive-pack" &&
	GIT_TRACE2_EVENT="$(pwd)/explicit-haves-no-cap.event" \
	git -C explicit-haves-src push --no-thin \
		--force-with-lease=refs/heads/feature:$F2 \
		--receive-pack="$rcvpck" \
		../explicit-haves-setup-no-cap.git \
		F3:refs/heads/feature &&
	test_grep "write_pack_file/wrote.*\"value\":\"3\"" \
		explicit-haves-no-cap.event &&
	git receive-pack explicit-haves-replay-no-cap.git \
		<explicit-haves-no-cap.req \
		>explicit-haves-no-cap.out 2>explicit-haves-no-cap.err &&
	echo "$F3" >expect &&
	git -C explicit-haves-replay-no-cap.git \
		rev-parse refs/heads/feature >actual &&
	test_cmp expect actual &&
	old_pack=$(cat explicit-haves-old-no-cap) &&
	rm -f explicit-haves-replay-no-cap.git/objects/pack/old-"$old_pack".* &&
	test_path_is_missing \
		explicit-haves-replay-no-cap.git/objects/pack/old-"$old_pack".pack &&
	test_must_fail git -C explicit-haves-replay-no-cap.git fsck --full \
		>explicit-haves-no-cap.fsck 2>&1 &&
	test_grep "missing commit $F1" explicit-haves-no-cap.fsck &&
	test_grep "missing blob $S" explicit-haves-no-cap.fsck &&

	# The advertised ref is still used to reject a stale lease.
	test_must_fail git -C explicit-haves-src push --no-thin \
		--force-with-lease=refs/heads/feature:$F1 \
		--receive-pack="git receive-pack --advertise-explicit-haves-for-testing" \
		../explicit-haves-setup-capability.git \
		F3:refs/heads/feature &&
	test "$F2" = "$(git -C explicit-haves-setup-capability.git \
		rev-parse refs/heads/feature)" &&

	# With the capability, only the explicit .have for B is a negative.
	# The pack therefore includes both F1 and F3, along with their trees
	# and blobs, and can replace a receiver which has only B.
	rcvpck="unset GIT_TRACE_PACKET GIT_TRACE2_EVENT; tee ${SQ}$(pwd)/explicit-haves-capability.req${SQ} | git receive-pack --advertise-explicit-haves-for-testing" &&
	GIT_TRACE_PACKET="$(pwd)/explicit-haves-capability.trace" \
	GIT_TRACE2_EVENT="$(pwd)/explicit-haves-capability.event" \
	git -C explicit-haves-src push --no-thin \
		--force-with-lease=refs/heads/feature:$F2 \
		--receive-pack="$rcvpck" \
		../explicit-haves-setup-capability.git \
		F3:refs/heads/feature &&
	test_grep "push< $B \\.have" explicit-haves-capability.trace &&
	test_grep "push> .* explicit-haves" explicit-haves-capability.trace &&
	test_grep "write_pack_file/wrote.*\"value\":\"6\"" \
		explicit-haves-capability.event &&
	git receive-pack --advertise-explicit-haves-for-testing \
		explicit-haves-replay-capability.git \
		<explicit-haves-capability.req \
		>explicit-haves-capability.out \
		2>explicit-haves-capability.err &&
	echo "$F3" >expect &&
	git -C explicit-haves-replay-capability.git \
		rev-parse refs/heads/feature >actual &&
	test_cmp expect actual &&
	old_pack=$(cat explicit-haves-old-capability) &&
	rm -f explicit-haves-replay-capability.git/objects/pack/old-"$old_pack".* &&
	test_path_is_missing \
		explicit-haves-replay-capability.git/objects/pack/old-"$old_pack".pack &&
	git -C explicit-haves-replay-capability.git fsck --full
'

test_done
