#!/bin/sh

test_description='Test index-pack first-pass hash worker performance

GIT_PERF_5352_NR_BLOBS controls the number of full blobs in the input pack.
GIT_PERF_5352_BLOB_SIZE controls the size of each blob in bytes.
Keep the blob size between 65536 and 67108863 to exercise the worker path.
'

. ./perf-lib.sh

test_perf_fresh_repo

: ${GIT_PERF_5352_NR_BLOBS:=128}
: ${GIT_PERF_5352_BLOB_SIZE:=1048576}

test_expect_success 'create a pack of full blobs' '
	for i in $(test_seq 1 "$GIT_PERF_5352_NR_BLOBS")
	do
		test-tool genrandom "index-pack-hash-$i" \
			"$GIT_PERF_5352_BLOB_SIZE" |
		git hash-object -w --stdin || return 1
	done >oids &&
	git pack-objects --stdout --window=0 <oids >input.pack
'

test_size 'pack size' '
	test_file_size input.pack
'

test_perf 'index-pack, serial hash' \
	--setup 'rm -rf repo.git && git init --bare -q repo.git' '
	git -C repo.git -c indexPack.hashThreads=0 \
		index-pack --threads=1 --stdin <input.pack >/dev/null
'

test_perf 'index-pack, one hash worker' --prereq PTHREADS \
	--setup 'rm -rf repo.git && git init --bare -q repo.git' '
	git -C repo.git -c indexPack.hashThreads=1 \
		index-pack --threads=1 --stdin <input.pack >/dev/null
'

test_perf 'index-pack, two hash workers' --prereq PTHREADS \
	--setup 'rm -rf repo.git && git init --bare -q repo.git' '
	git -C repo.git -c indexPack.hashThreads=2 \
		index-pack --threads=1 --stdin <input.pack >/dev/null
'

test_done
