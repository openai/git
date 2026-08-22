#!/bin/sh

test_description='bounded first-pass index-pack hash workers'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-pack.sh

run_index () {
	name=$1 &&
	input=$2 &&
	shift 2 &&
	git init --bare "$name.git" &&
	GIT_TRACE2_EVENT="$TRASH_DIRECTORY/$name.trace" \
		git -C "$name.git" "$@" <"$input" >"$name.out"
}

trace_value () {
	key=$1 &&
	value=$2 &&
	file=$3 &&
	test_grep "\"key\":\"first_pass_hash/$key\",\"value\":\"$value\"" "$file"
}

compare_pack_files () {
	left=$1 &&
	right=$2 &&
	pack_hash=$(cut -f2 "$left.out") &&
	test_cmp "$left.out" "$right.out" &&
	for suffix in pack idx rev
	do
		test_cmp_bin "$left.git/objects/pack/pack-$pack_hash.$suffix" \
			"$right.git/objects/pack/pack-$pack_hash.$suffix" || return 1
	done
}

test_expect_success 'make a pack of full blobs' '
	for i in $(test_seq 1 8)
	do
		test-tool genrandom "hash-pipeline-$i" 65536 >"blob-$i" &&
		git hash-object -w "blob-$i" || return 1
	done >oids &&
	git pack-objects --stdout --window=0 <oids >input.pack &&
	run_index serial input.pack index-pack --stdin --fix-thin &&
	trace_value threads 0 serial.trace
'

test_expect_success PTHREADS 'workers preserve pack, index and reverse index' '
	run_index parallel input.pack \
		-c indexPack.hashThreads=2 \
		-c indexPack.hashBufferSize=131074 \
		index-pack --stdin --fix-thin &&
	compare_pack_files serial parallel &&
	trace_value threads 2 parallel.trace &&
	trace_value jobs 8 parallel.trace
'

test_expect_success PTHREADS 'an object must fit including its trailing byte' '
	run_index too-small input.pack \
		-c indexPack.hashThreads=2 \
		-c indexPack.hashBufferSize=65536 \
		-c indexPack.hashMinSize=0 \
		index-pack --stdin --fix-thin &&
	compare_pack_files serial too-small &&
	trace_value jobs 0 too-small.trace
'

test_expect_success PTHREADS 'streamed large blobs retain the serial path' '
	run_index streamed input.pack \
		-c indexPack.hashThreads=2 \
		-c indexPack.hashMinSize=0 \
		-c core.bigFileThreshold=1 \
		index-pack --stdin --fix-thin &&
	compare_pack_files serial streamed &&
	trace_value jobs 0 streamed.trace
'

test_expect_success PTHREADS 'validation modes retain the serial path' '
	for mode in strict fsck-objects promisor
	do
		run_index "$mode" input.pack \
			-c indexPack.hashThreads=2 \
			-c indexPack.hashMinSize=0 \
			index-pack --stdin --fix-thin "--$mode" &&
		trace_value threads 0 "$mode.trace" || return 1
	done
'

test_expect_success PTHREADS 'existing-object collision check is not skipped' '
	git init --bare collision.git &&
	a=$(git -C collision.git hash-object -w ../blob-1) &&
	b=$(git -C collision.git hash-object -w ../blob-2) &&
	a_path=$(echo "$a" | sed "s!^..!&/!") &&
	b_path=$(echo "$b" | sed "s!^..!&/!") &&
	cp -f "collision.git/objects/$b_path" "collision.git/objects/$a_path" &&
	test_env GIT_TRACE2_EVENT="$TRASH_DIRECTORY/collision.trace" \
		test_must_fail git -C collision.git \
		-c indexPack.hashThreads=2 \
		index-pack --stdin --fix-thin <input.pack 2>collision.err &&
	trace_value threads 2 collision.trace &&
	test_grep "SHA1 COLLISION FOUND" collision.err
'

test_expect_success PTHREADS 'duplicate full blobs preserve native acceptance' '
	{
		pack_header 2 &&
		pack_obj "$EMPTY_BLOB" &&
		pack_obj "$EMPTY_BLOB"
	} >duplicates.pack &&
	pack_trailer duplicates.pack &&
	run_index duplicate-serial duplicates.pack index-pack --stdin &&
	run_index duplicate-parallel duplicates.pack \
		-c indexPack.hashThreads=2 \
		-c indexPack.hashBufferSize=2 \
		-c indexPack.hashMinSize=0 \
		index-pack --stdin &&
	compare_pack_files duplicate-serial duplicate-parallel &&
	trace_value jobs 2 duplicate-parallel.trace &&
	git init --bare duplicate-strict.git &&
	test_must_fail git -C duplicate-strict.git \
		-c indexPack.hashThreads=2 \
		-c indexPack.hashMinSize=0 \
		index-pack --strict --stdin <duplicates.pack
'

test_expect_success PTHREADS 'deferred base hashes finish before REF/OFS resolution' '
	A=$(test_oid packlib_7_0) &&
	B=$(test_oid packlib_7_76) &&
	{
		pack_header 2 &&
		pack_obj "$A" "$B" &&
		pack_obj "$B"
	} >ref.pack &&
	pack_trailer ref.pack &&
	pack_obj "$A" "$B" >ref-entry &&
	{
		pack_header 2 &&
		pack_obj "$B" &&
		# The full B entry is eleven bytes; the delta data is five.
		printf "\145\013" &&
		dd if=ref-entry bs=1 skip=$((1 + $(test_oid rawsz)))
	} >ofs.pack &&
	pack_trailer ofs.pack &&
	for kind in ref ofs
	do
		run_index "$kind" "$kind.pack" \
			-c indexPack.hashThreads=2 \
			-c indexPack.hashMinSize=0 \
			index-pack --stdin --fix-thin &&
		trace_value jobs 1 "$kind.trace" &&
		git -C "$kind.git" cat-file blob "$A" >actual &&
		test "$(git hash-object actual)" = "$A" || return 1
	done
'

test_expect_success PTHREADS 'bad input cannot publish an index' '
	length=$(wc -c <input.pack) &&
	dd if=input.pack of=truncated.pack bs=1 count=$((length - 1)) &&
	cp input.pack corrupt.pack &&
	printf "xxxx" | dd of=corrupt.pack bs=1 seek=20 conv=notrunc &&
	for kind in truncated corrupt
	do
		git init --bare "bad-$kind.git" &&
		test_must_fail git -C "bad-$kind.git" \
			-c indexPack.hashThreads=2 \
			-c indexPack.hashMinSize=0 \
			index-pack --stdin --fix-thin <"$kind.pack" &&
		find "bad-$kind.git/objects/pack" -name "*.idx" >actual &&
		test_must_be_empty actual || return 1
	done
'

test_expect_success 'invalid worker counts are rejected' '
	test_must_fail git -c indexPack.hashThreads=-1 index-pack input.pack &&
	test_must_fail git -c indexPack.hashThreads=33 index-pack input.pack
'

test_done
