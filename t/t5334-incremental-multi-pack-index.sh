#!/bin/sh

test_description='incremental multi-pack-index'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-midx.sh
. "$TEST_DIRECTORY"/lib-chunk.sh

GIT_TEST_MULTI_PACK_INDEX=0
export GIT_TEST_MULTI_PACK_INDEX

objdir=.git/objects
packdir=$objdir/pack
midxdir=$packdir/multi-pack-index.d
midx_chain=$midxdir/multi-pack-index-chain

test_expect_success 'convert non-incremental MIDX to incremental' '
	test_commit base &&
	git config set maintenance.auto false &&
	git repack -ad &&
	git multi-pack-index write &&

	test_path_is_file $packdir/multi-pack-index &&
	old_hash="$(midx_checksum $objdir)" &&

	test_commit other &&
	git repack -d &&
	git multi-pack-index write --incremental &&

	test_path_is_missing $packdir/multi-pack-index &&
	test_path_is_file $midx_chain &&
	test_line_count = 2 $midx_chain &&
	test_grep $old_hash $midx_chain
'

compare_results_with_midx 'incremental MIDX'

test_expect_success 'convert incremental to non-incremental' '
	test_commit squash &&
	git repack -d &&
	git multi-pack-index write &&

	test_path_is_file $packdir/multi-pack-index &&
	test_dir_is_empty $midxdir
'

compare_results_with_midx 'non-incremental MIDX conversion'

write_midx_layer () {
	n=1
	if test -f $midx_chain
	then
		n="$(($(wc -l <$midx_chain) + 1))"
	fi

	for i in 1 2
	do
		test_commit $n.$i &&
		git repack -d || return 1
	done &&
	git multi-pack-index write --bitmap --incremental
}

test_expect_success 'write initial MIDX layer' '
	git repack -ad &&
	write_midx_layer
'

test_expect_success 'read bitmap from first MIDX layer' '
	git rev-list --test-bitmap 1.2
'

test_expect_success 'write another MIDX layer' '
	write_midx_layer
'

test_expect_success 'midx verify with multiple layers' '
	test_path_is_file "$midx_chain" &&
	test_line_count = 2 "$midx_chain" &&

	git multi-pack-index verify
'


test_expect_success 'verify checksum of base MIDX' '
	midx="$midxdir/multi-pack-index-$(sed -n 1p "$midx_chain").midx" &&
	cp "$midx" midx.bak &&
	test_when_finished "mv midx.bak \"$midx\"" &&
	chmod u+w "$midx" &&
	echo extra >>"$midx" &&
	test_must_fail git multi-pack-index verify 2>err &&
	test_grep "incorrect checksum" err
'

test_expect_success PERL_TEST_HELPERS 'verify OID order of base MIDX' '
	midx="$midxdir/multi-pack-index-$(sed -n 1p "$midx_chain").midx" &&
	cp "$midx" midx.bak &&
	test_when_finished "mv midx.bak \"$midx\"" &&
	corrupt_chunk_file "$midx" OIDL "$(test_oid rawsz)" "$(test_oid zero)" &&
	test_must_fail git multi-pack-index verify 2>err &&
	test_grep "oid lookup out of order" err
'

test_expect_success SHA1 'reject empty base MIDX layer' '
	cp "$midx_chain" chain.bak &&
	test_when_finished "mv chain.bak \"$midx_chain\"" &&
	cp "$TEST_DIRECTORY"/t5319/no-objects.midx $packdir/multi-pack-index &&
	test_when_finished "rm -f $packdir/multi-pack-index" &&
	empty=$(midx_checksum "$objdir") &&
	mv $packdir/multi-pack-index "$midxdir/multi-pack-index-$empty.midx" &&
	test_when_finished "rm -f \"$midxdir/multi-pack-index-$empty.midx\"" &&
	{
		echo "$empty" &&
		cat chain.bak
	} >"$midx_chain" &&
	test_must_fail git multi-pack-index verify 2>err &&
	test_grep "the midx contains no oid" err
'

for missing in 1 2
do
	test_expect_success "verify missing MIDX layer $missing" '
		midx="$midxdir/multi-pack-index-$(sed -n "${missing}p" "$midx_chain").midx" &&
		mv "$midx" missing.midx &&
		test_when_finished "mv missing.midx \"$midx\"" &&
		test_must_fail git multi-pack-index verify 2>err &&
		test_grep "one or more multi-pack-index chain files could not be loaded" err &&
		git cat-file -e 1.1 &&
		git cat-file -e 2.2
	'
done

test_expect_success 'read bitmap from second MIDX layer' '
	git rev-list --test-bitmap 2.2
'

test_expect_success 'read earlier bitmap from second MIDX layer' '
	git rev-list --test-bitmap 1.2
'

test_expect_success 'show object from first pack' '
	git cat-file -p 1.1
'

test_expect_success 'show object from second pack' '
	git cat-file -p 2.2
'

test_expect_success 'write MIDX layer with --no-write-chain-file' '
	test_commit no-write-chain-file &&
	git repack -d &&

	cp "$midx_chain" "$midx_chain.bak" &&
	layer="$(git multi-pack-index write --bitmap --incremental \
		--no-write-chain-file)" &&

	test_cmp "$midx_chain.bak" "$midx_chain" &&
	test_path_is_file "$midxdir/multi-pack-index-$layer.midx"
'

test_expect_success 'write non-incremental MIDX layer with --no-write-chain-file' '
	test_must_fail git multi-pack-index write --bitmap --no-write-chain-file 2>err &&
	test_grep "cannot use --no-write-chain-file without --incremental" err
'

test_expect_success 'write MIDX layer with --base without --no-write-chain-file' '
	test_must_fail git multi-pack-index write --bitmap --incremental \
		--base=none 2>err &&
	test_grep "cannot use --base without --no-write-chain-file" err
'

test_expect_success 'write MIDX layer with --base=none and --no-write-chain-file' '
	test_commit base-none &&
	git repack -d &&

	cp "$midx_chain" "$midx_chain.bak" &&
	layer="$(git multi-pack-index write --bitmap --incremental \
		--no-write-chain-file --base=none)" &&

	test_cmp "$midx_chain.bak" "$midx_chain" &&
	test_path_is_file "$midxdir/multi-pack-index-$layer.midx" &&

	echo "$layer" >"$midx_chain" &&
	test-tool read-midx --show-objects "$objdir" "$layer" >midx.objects &&
	test_grep "^$(git rev-parse 2.2) " midx.objects &&
	cp "$midx_chain.bak" "$midx_chain"
'

test_expect_success 'write MIDX layer with --base=<hash> and --no-write-chain-file' '
	test_commit base-hash &&
	git repack -d &&

	cp "$midx_chain" "$midx_chain.bak" &&
	base="$(nth_line 1 "$midx_chain")" &&
	layer="$(git multi-pack-index write --bitmap --incremental \
		--no-write-chain-file --base="$base")" &&

	test_cmp "$midx_chain.bak" "$midx_chain" &&
	test_path_is_file "$midxdir/multi-pack-index-$layer.midx" &&

	{
		echo "$base" &&
		echo "$layer"
	} >"$midx_chain" &&
	test-tool read-midx --show-objects "$objdir" "$layer" >midx.objects &&
	test_grep "^$(git rev-parse 2.2) " midx.objects &&
	cp "$midx_chain.bak" "$midx_chain"
'

test_expect_success 'write MIDX layer with --stdin-packs and a custom base' '
	base="$(nth_line 1 "$midx_chain")" &&
	test-tool read-midx "$objdir" "$base" >base.midx &&
	test-tool read-midx "$objdir" >tip.midx &&
	sed -n "/^pack-.*\\.idx$/p" base.midx >base.packs &&
	sed -n "/^pack-.*\\.idx$/p" tip.midx >tip.packs &&
	test_line_count = 2 tip.packs &&
	sed -n 1p tip.packs >expect &&
	cat base.packs expect >packs &&
	layer="$(git multi-pack-index write --incremental --stdin-packs \
		--no-write-chain-file --base="$base" <packs)" &&
	cp "$midx_chain" chain.bak &&
	test_when_finished "mv chain.bak \"$midx_chain\"" &&
	{
		echo "$base" &&
		echo "$layer"
	} >"$midx_chain" &&
	test-tool read-midx "$objdir" >layer.midx &&
	sed -n "/^pack-.*\\.idx$/p" layer.midx >actual &&
	test_cmp expect actual
'

for reuse in false single multi
do
	test_expect_success "full clone (pack.allowPackReuse=$reuse)" '
		rm -fr clone.git &&

		git config pack.allowPackReuse $reuse &&
		git clone --no-local --bare . clone.git
	'
done

test_expect_success 'relink existing MIDX layer' '
	rm -fr "$midxdir" &&

	GIT_TEST_MIDX_WRITE_REV=1 git multi-pack-index write --bitmap &&

	midx_hash="$(test-tool read-midx --checksum $objdir)" &&

	test_path_is_file "$packdir/multi-pack-index" &&
	test_path_is_file "$packdir/multi-pack-index-$midx_hash.bitmap" &&
	test_path_is_file "$packdir/multi-pack-index-$midx_hash.rev" &&

	test_commit another &&
	git repack -d &&
	git multi-pack-index write --bitmap --incremental &&

	test_path_is_missing "$packdir/multi-pack-index" &&
	test_path_is_missing "$packdir/multi-pack-index-$midx_hash.bitmap" &&
	test_path_is_missing "$packdir/multi-pack-index-$midx_hash.rev" &&

	test_path_is_file "$midxdir/multi-pack-index-$midx_hash.midx" &&
	test_path_is_file "$midxdir/multi-pack-index-$midx_hash.bitmap" &&
	test_path_is_file "$midxdir/multi-pack-index-$midx_hash.rev" &&
	test_line_count = 2 "$midx_chain"

'

test_expect_success 'non-incremental write with existing incremental chain' '
	git init non-incremental-write-with-existing &&
	test_when_finished "rm -fr non-incremental-write-with-existing" &&

	(
		cd non-incremental-write-with-existing &&

		git config set maintenance.auto false &&

		write_midx_layer &&
		write_midx_layer &&

		git multi-pack-index write
	)
'

test_expect_success 'skip initial MIDX layer with no objects' '
	git init empty &&
	(
		cd empty &&
		git config maintenance.auto false &&
		git pack-objects $packdir/pack </dev/null &&

		for bitmap in --bitmap --no-bitmap
		do
			git multi-pack-index write --incremental "$bitmap" >out 2>&1 &&
			test_must_be_empty out &&
			test_dir_is_empty "$midxdir" || return 1
		done &&

		write_midx_layer &&
		test_line_count = 1 "$midx_chain" &&
		git multi-pack-index verify
	)
'

test_expect_success 'skip MIDX layer with empty pack' '
	git init empty-pack &&
	(
		cd empty-pack &&
		git config maintenance.auto false &&
		write_midx_layer &&

		git pack-objects $packdir/pack </dev/null &&
		cp "$midx_chain" chain.expect &&
		ls "$packdir" "$midxdir" >files.expect &&

		for bitmap in --bitmap --no-bitmap
		do
			git multi-pack-index write --incremental "$bitmap" >out 2>&1 &&
			test_must_be_empty out &&
			test_cmp chain.expect "$midx_chain" &&
			ls "$packdir" "$midxdir" >files.actual &&
			test_cmp files.expect files.actual || return 1
		done &&

		write_midx_layer &&
		test_line_count = 2 "$midx_chain" &&
		git multi-pack-index verify &&
		git rev-list --test-bitmap 2.2
	)
'

test_expect_success 'skip MIDX layer with duplicate pack' '
	git init duplicate-pack &&
	(
		cd duplicate-pack &&
		git config maintenance.auto false &&
		write_midx_layer &&

		git rev-parse HEAD^{tree} >in &&
		git pack-objects $packdir/pack <in &&
		cp "$midx_chain" chain.expect &&
		ls "$packdir" "$midxdir" >files.expect &&

		for bitmap in --bitmap --no-bitmap
		do
			git multi-pack-index write --incremental "$bitmap" >out 2>&1 &&
			test_must_be_empty out &&
			test_cmp chain.expect "$midx_chain" &&
			ls "$packdir" "$midxdir" >files.actual &&
			test_cmp files.expect files.actual || return 1
		done &&

		write_midx_layer &&
		test_line_count = 2 "$midx_chain" &&
		git multi-pack-index verify &&
		git rev-list --test-bitmap 2.2
	)
'

test_done
