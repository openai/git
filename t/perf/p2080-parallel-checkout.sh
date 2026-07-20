#!/bin/sh

test_description='Test parallel checkout performance'
. ./perf-lib.sh

test_perf_fresh_repo
test_export repo

test_expect_success 'setup path-clustered large blobs' '
	(
		cd "$repo" &&
		git config core.fsmonitor false &&
		git config checkout.workers 4 &&
		git config checkout.thresholdForParallelism 0 &&
		large_oid=$(test-tool genzeros $((8 * 1024 * 1024)) |
			git hash-object -w --stdin) &&
		small_oid=$(printf x | git hash-object -w --stdin) &&
		{
			for i in $(test_seq 0 63)
			do
				printf "100644 %s\ta%03d\n" "$large_oid" "$i" ||
					return 1
			done &&
			for i in $(test_seq 0 191)
			do
				printf "100644 %s\tb%03d\n" "$small_oid" "$i" ||
					return 1
			done
		} |
		git update-index --index-info
	)
'

test_perf 'checkout path-clustered large blobs' \
	--setup '
		(
			cd "$repo" &&
			rm -f a* b*
		)
	' '
		(
			cd "$repo" &&
			git checkout-index --all --force
		)
	'

test_done
