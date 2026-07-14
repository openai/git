#!/bin/sh

test_description='bitmap commit selection'

. ./test-lib.sh

write_fast_import_commit () {
	local ref="$1" mark="$2" timestamp="$3" &&
	printf "commit %s\n" "$ref" &&
	printf "mark :%s\n" "$mark" &&
	printf "author A U Thor <author@example.com> %s +0000\n" \
		"$timestamp" &&
	printf "committer C O Mitter <committer@example.com> %s +0000\n" \
		"$timestamp" &&
	printf "data %s\n%s\n" "${#mark}" "$mark"
}

bitmap_max_selection_gap () {
	local bitmaps="$1" commits="$2" &&
	awk '
		NR == FNR {
			selected[$1] = 1
			next
		}
		$1 in selected {
			if (seen)
				gap++
			if (max < gap)
				max = gap
			gap = 0
			seen = 1
			next
		}
		{
			gap++
		}
		END {
			if (max < gap)
				max = gap
			print max
		}
	' "$bitmaps" "$commits"
}

test_expect_success 'selection follows ancestry despite alternating clock skew' '
	git init --bare skew.git &&
	(
		cd skew.git &&
		{
			i=1 &&
			while test $i -le 1000
			do
				if test $((i % 2)) = 1
				then
					timestamp=$((2000000000 - i))
				else
					timestamp=$((1000000000 + i))
				fi &&
				write_fast_import_commit refs/heads/main \
					"$i" "$timestamp" &&
				if test $i -gt 1
				then
					printf "from :%s\n" "$((i - 1))"
				fi &&
				printf "\n" &&
				i=$((i + 1)) || return 1
			done
		} | git fast-import --quiet &&
		git symbolic-ref HEAD refs/heads/main &&
		git repack -adb &&
		test-tool bitmap list-commits >bitmaps &&
		git rev-list --first-parent --reverse main >commits &&
		bitmap_max_selection_gap bitmaps commits >actual &&
		test "$(cat actual)" -le 16 &&

		: >trace &&
		distance=1 &&
		while test $distance -le 512
		do
			GIT_TRACE2_EVENT="$(pwd)/trace" \
				git rev-list --use-bitmap-index --objects \
				main "^main~$distance" >/dev/null &&
			distance=$((distance * 2)) || return 1
		done &&
		sed -n '"'"'s/.*"key":"bitmap\/misses","value":"\([0-9][0-9]*\)".*/\1/p'"'"' \
			trace >misses &&
		test_line_count = 10 misses &&
		awk '"'"'{
			sum += $1
			if (max < $1)
				max = $1
		}
		END { exit sum > 4 || max > 2 }'"'"' misses
	)
'

test_expect_success 'shallow merge tips do not crowd out deep history' '
	git init --bare shallow-merges.git &&
	(
		cd shallow-merges.git &&
		{
			i=1 &&
			while test $i -le 1000
			do
				write_fast_import_commit refs/heads/main "$i" \
					"$((1400000000 + i))" &&
				if test $i -gt 1
				then
					printf "from :%s\n" "$((i - 1))"
				fi &&
				printf "\n" &&
				i=$((i + 1)) || return 1
			done &&
			i=1 &&
			while test $i -le 256
			do
				mark=$((1000 + i)) &&
				write_fast_import_commit "refs/heads/root-$i" \
					"$mark" "$((1500000000 + mark))" &&
				printf "\n" &&
				i=$((i + 1)) || return 1
			done &&
			i=1 &&
			while test $i -le 128
			do
				mark=$((1256 + i)) &&
				left=$((1000 + 2 * i - 1)) &&
				right=$((left + 1)) &&
				write_fast_import_commit "refs/heads/merge-$i" \
					"$mark" "$((1600000000 + mark))" &&
				printf "from :%s\nmerge :%s\n\n" \
					"$left" "$right" &&
				i=$((i + 1)) || return 1
			done
		} | git fast-import --quiet &&
		git symbolic-ref HEAD refs/heads/main &&
		test "$(git rev-list --all --count)" = 1384 &&
		git repack -adb &&
		test-tool bitmap list-commits >bitmaps &&
		git rev-list --first-parent --reverse \
			refs/heads/main >main-commits &&
		bitmap_max_selection_gap bitmaps main-commits >actual &&
		test "$(cat actual)" -le 16
	)
'

test_expect_success 'reflog-only descendants do not displace advertised history' '
	git init --bare reflog-descendants.git &&
	(
		cd reflog-descendants.git &&
		git config core.logAllRefUpdates true &&
		{
			i=1 &&
			while test $i -le 1000
			do
				write_fast_import_commit refs/heads/main "$i" \
					"$((1400000000 + i))" &&
				if test $i -gt 1
				then
					printf "from :%s\n" "$((i - 1))"
				fi &&
				printf "\n" &&
				i=$((i + 1)) || return 1
			done
		} | git fast-import --quiet &&
		git symbolic-ref HEAD refs/heads/main &&
		old_tip=$(git rev-parse refs/heads/main) &&
		live_tip=$(git rev-parse refs/heads/main~900) &&
		git update-ref -m reset refs/heads/main "$live_tip" "$old_tip" &&
		test "$(git rev-list --all --count)" = 100 &&
		test "$(git rev-list --all --reflog --count)" = 1000 &&

		git repack -adb &&
		test-tool bitmap list-commits >bitmaps &&
		git rev-list refs/heads/main | sort >live &&
		git rev-list "$old_tip" --not refs/heads/main | sort \
			>reflog-only &&
		sort bitmaps >bitmaps.sorted &&
		comm -12 live bitmaps.sorted >selected-live &&
		comm -12 reflog-only bitmaps.sorted >selected-reflog-only &&
		test_line_count -ge 100 selected-live &&
		test_line_count -le 14 selected-reflog-only
	)
'

test_done
