#!/bin/sh

test_description='push with snapshot prerequisites'
GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME
. ./test-lib.sh

test_expect_success 'create two snapshots and a merge restoring an ancestral tree' '
	mkdir -p archive/sub &&
	test_seq 2000 >archive/sub/old &&
	test_seq 4000 >edited &&
	echo unchanged >keep &&
	git add archive edited keep &&
	git commit -m ancestor &&
	ancestor=$(git rev-parse HEAD) &&
	git rm -r archive &&
	git commit -m left &&
	left=$(git rev-parse HEAD) &&
	git reset --hard "$ancestor" &&
	git rm -r archive &&
	echo right >sibling &&
	git add sibling &&
	git commit -m right &&
	right=$(git rev-parse HEAD) &&
	git checkout "$ancestor" -- archive &&
	echo new >>edited &&
	git add edited &&
	tree=$(git write-tree) &&
	merge=$(echo merge | git commit-tree "$tree" -p "$left" -p "$right") &&
	git reset --hard "$merge" &&
	test_commit tip &&
	want=$(git rev-parse HEAD) &&
	git repack -adb &&
	git commit-graph write --reachable &&
	token=$(printf "%064d" 1) &&
	rcvpck="${SQ}$(pwd)${SQ}/receive" &&
	write_script receive <<-\RECEIVE
	cat "$1/advertisement" &&
	exec git receive-pack --stateless-rpc "$1"
	RECEIVE
'

# The receiver owns only the explicitly listed commits and their trees.
# A named ref and a .have claim separately exercise ordinary negatives.
write_offer () {
	local receiver="$1" oid &&
	shift &&
	{
		printf "%s refs/heads/unrelated\0report-status explicit-haves shallow-haves=%s ofs-delta object-format=%s\n" \
			"$ancestor" "$token" "$test_hash_algo" | test-tool pkt-line pack-raw-stdin &&
		test-tool pkt-line pack "$ancestor .have" &&
		for oid in "$@"
		do
			test-tool pkt-line pack "$oid .shallow-have" || return 1
		done &&
		test-tool pkt-line pack 0000
	} >"$receiver/advertisement"
}

prepare_receiver () {
	local receiver="$1" oid &&
	shift &&
	git init --bare "$receiver" &&
	git -C "$receiver" config receive.unpackLimit 0 &&
	write_offer "$receiver" "$@" &&
	for oid in "$@"
	do
		{
			echo "$oid" &&
			git rev-parse "$oid^{tree}" &&
			git ls-tree -r -t --format="%(objectname)" "$oid"
		} >snapshot &&
		git pack-objects --stdout <snapshot >snapshot.pack &&
		git -C "$receiver" unpack-objects <snapshot.pack &&
		echo "$oid" >>"$receiver/shallow" || return 1
	done
}

for thin in thin no-thin
do
	test_expect_success "push --$thin restores a tree absent from both snapshots" '
		dst="remote-$thin" &&
		prepare_receiver "$dst" "$left" "$right" &&
		GIT_TRACE_PACKET="$(pwd)/trace-$thin" \
		git -c push.negotiate=true -c push.useBitmaps=true \
			push "--$thin" --receive-pack="$rcvpck" "$dst" HEAD:refs/heads/main &&
		test_grep "push> .* explicit-haves shallow-haves=$token" "trace-$thin" &&
		git -C "$dst" fsck --full &&
		test_cmp_rev "$want" "$(git -C "$dst" rev-parse main)" &&
		git -C "$dst" cat-file -e "$merge" &&
		git -C "$dst" cat-file -e "$want:archive/sub/old" &&
		test_must_fail git -C "$dst" cat-file -e "$ancestor" &&
		git show-index <"$(echo "$dst"/objects/pack/*.idx)" >index &&
		keep=$(git rev-parse HEAD:keep) &&
		test_grep ! "$keep" index &&
		test_grep ! "$left" index &&
		test_grep ! "$right" index
	'
done

test_expect_success 'thin delta refers to the base blob in the granted snapshot' '
	test-tool pack-deltas --list-deltas remote-thin/objects/pack/*.idx >deltas &&
	base=$(git rev-parse "$left:edited") &&
	target=$(git rev-parse HEAD:edited) &&
	test_grep "$target REF_DELTA $base" deltas
'

test_expect_success 'ungranted merge side supplies a shared ancestor with window zero' '
	prepare_receiver one-parent.git "$left" &&
	git -c pack.window=0 -c pack.allowPackReuse=multi \
		push --receive-pack="$rcvpck" one-parent.git HEAD:refs/heads/main &&
	git -C one-parent.git fsck --full &&
	git -C one-parent.git cat-file -e "$right" &&
	git -C one-parent.git cat-file -e "$ancestor"
'

test_expect_success 'empty offer sends ordinary complete history despite other negatives' '
	prepare_receiver empty.git &&
	git send-pack --receive-pack="$rcvpck" empty.git HEAD:refs/heads/main &&
	git -C empty.git fsck --full &&
	git rev-list --objects "$want" >expect &&
	git -C empty.git rev-list --objects refs/heads/main >actual &&
	test_cmp expect actual
'

test_expect_success 'a missing object and an annotated tag cannot exclude history' '
	prepare_receiver unknown.git &&
	git tag -a -m tag snapshot-tag "$left" &&
	tag=$(git rev-parse snapshot-tag) &&
	missing=$(echo unknown | git hash-object --stdin) &&
	write_offer unknown.git "$tag" "$missing" &&
	git push --receive-pack="$rcvpck" unknown.git HEAD:refs/heads/main &&
	git -C unknown.git fsck --full &&
	git -C unknown.git cat-file -e "$ancestor"
'

test_expect_success 'local grafts cannot hide an ungranted parent' '
	prepare_receiver grafted.git &&
	echo "$want" >grafts &&
	GIT_GRAFT_FILE="$(pwd)/grafts" git push --receive-pack="$rcvpck" \
		grafted.git HEAD:refs/heads/main &&
	git -C grafted.git fsck --full &&
	git -C grafted.git cat-file -e "$ancestor"
'

test_expect_success 'an ungranted local shallow root cannot hide a missing parent' '
	prepare_receiver incomplete.git &&
	git clone --depth=1 file://"$(pwd)" shallow-src &&
	test_must_fail git -C shallow-src push --receive-pack="$rcvpck" \
		../incomplete.git HEAD:refs/heads/main 2>err &&
	test_grep "Failed to traverse parents" err &&
	test_must_fail git -C incomplete.git rev-parse --verify refs/heads/main
'

test_expect_success 'a second receiver cannot inherit the first receiver token' '
	prepare_receiver first.git "$left" "$right" &&
	git init --bare second.git &&
	{
		# Empty SHA-1 repositories can send just a flush. SHA-256
		# repositories must identify their object format.
		if ! test_have_prereq SHA1
		then
			printf "%s capabilities^{}\0object-format=%s\n" \
				"$ZERO_OID" "$test_hash_algo" | test-tool pkt-line pack-raw-stdin
		fi &&
		test-tool pkt-line pack 0000
	} >second.git/advertisement &&
	git remote add both first.git &&
	git remote set-url --add --push both first.git &&
	git remote set-url --add --push both second.git &&
	GIT_TRACE_PACKET="$(pwd)/multi.trace" \
		git push --receive-pack="$rcvpck" both HEAD:refs/heads/main &&
	grep "push> .* shallow-haves=$token" multi.trace >echoes &&
	test_line_count = 1 echoes &&
	git -C second.git fsck --full &&
	git -C second.git cat-file -e "$ancestor"
'

test_expect_success 'malformed token cannot be echoed' '
	token=wrong &&
	prepare_receiver malformed.git &&
	test_must_fail git push --receive-pack="$rcvpck" malformed.git \
		HEAD:refs/heads/main 2>err &&
	test_grep "invalid shallow-haves advertisement" err
'

test_done
