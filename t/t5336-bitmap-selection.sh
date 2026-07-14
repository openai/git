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

test_expect_success 'criss-cross histories retain graph-path coverage' '
	git init --bare criss-cross.git &&
	(
		cd criss-cross.git &&
		{
			write_fast_import_commit refs/heads/base 1 1400000001 &&
			printf "\n" &&
			write_fast_import_commit refs/heads/a 2 1400000002 &&
			printf "from :1\n\n" &&
			write_fast_import_commit refs/heads/b 3 1400000003 &&
			printf "from :1\n\n" &&
			a=2 && b=3 && mark=3 && round=1 &&
			while test $round -le 200
			do
				old_a=$a && old_b=$b &&
				mark=$((mark + 1)) && new_a=$mark &&
				write_fast_import_commit refs/heads/a \
					"$new_a" "$((1400000000 + new_a))" &&
				printf "from :%s\nmerge :%s\n\n" "$old_a" "$old_b" &&
				mark=$((mark + 1)) && new_b=$mark &&
				write_fast_import_commit refs/heads/b \
					"$new_b" "$((1400000000 + new_b))" &&
				printf "from :%s\nmerge :%s\n\n" "$old_b" "$old_a" &&
				a=$new_a && b=$new_b &&
				round=$((round + 1)) || return 1
			done
		} | git fast-import --quiet &&
		git update-ref -d refs/heads/base &&
		git symbolic-ref HEAD refs/heads/a &&
		test "$(git rev-list --all --count)" = 403 &&
		git repack -adb &&

		: >trace &&
		distance=1 &&
		while test $distance -le 128
		do
			for ref in a b
			do
				GIT_TRACE2_EVENT="$(pwd)/trace" \
					git rev-list --use-bitmap-index --objects \
					"refs/heads/$ref" \
					"^refs/heads/$ref~$distance" >/dev/null ||
					return 1
			done &&
			distance=$((distance * 2)) || return 1
		done &&
		sed -n '"'"'s/.*"key":"bitmap\/misses","value":"\([0-9][0-9]*\)".*/\1/p'"'"' \
			trace >misses &&
		test_line_count = 16 misses &&
		awk '"'"'{
			sum += $1
			if (max < $1)
				max = $1
		}
		END { exit sum > 80 || max > 8 }'"'"' misses
	)
'

test_expect_success 'path coverage follows dominated history, not hop count' '
	git init --bare dominated-path.git &&
	(
		cd dominated-path.git &&
		{
			write_fast_import_commit refs/heads/base 1 1400000001 &&
			printf "\n" &&
			mark=1 && a=$mark && i=1 &&
			while test $i -le 40
			do
				mark=$((mark + 1)) &&
				write_fast_import_commit refs/heads/a "$mark" \
					"$((1400000000 + mark))" &&
				printf "from :%s\n\n" "$a" &&
				a=$mark && i=$((i + 1)) || return 1
			done &&
			b=1 && round=1 &&
			while test $round -le 10
			do
				old=$b && first=0 && side=1 &&
				while test $side -le 16
				do
					mark=$((mark + 1)) &&
					write_fast_import_commit refs/heads/side \
						"$mark" "$((1400000000 + mark))" &&
					printf "from :%s\n\n" "$old" &&
					if test "$first" = 0
					then
						first=$mark
					fi &&
					side=$((side + 1)) || return 1
				done &&
				mark=$((mark + 1)) &&
				write_fast_import_commit refs/heads/b "$mark" \
					"$((1400000000 + mark))" &&
				printf "from :%s\n" "$old" &&
				side_mark=$first &&
				while test $side_mark -lt "$mark"
				do
					printf "merge :%s\n" "$side_mark" &&
					side_mark=$((side_mark + 1)) || return 1
				done &&
				printf "\n" &&
				b=$mark && round=$((round + 1)) || return 1
			done &&
			mark=$((mark + 1)) &&
			write_fast_import_commit refs/heads/main "$mark" \
				"$((1400000000 + mark))" &&
			printf "from :%s\nmerge :%s\n\n" "$a" "$b"
		} | git fast-import --quiet &&
		git update-ref -d refs/heads/base &&
		git update-ref -d refs/heads/a &&
		git update-ref -d refs/heads/b &&
		git update-ref -d refs/heads/side &&
		git symbolic-ref HEAD refs/heads/main &&
		test "$(git rev-list --all --count)" = 212 &&
		git rev-list --parents --all |
			awk '"'"'NF > 10 {
				for (i = 3; i <= NF; i++)
					print $i
			}'"'"' >side-tips &&
		test_line_count = 160 side-tips &&

		git repack -adb &&
		: >trace &&
		while read tip
		do
			GIT_TRACE2_EVENT="$(pwd)/trace" \
				git rev-list --use-bitmap-index --objects "$tip" \
				>/dev/null || return 1
		done <side-tips &&
		sed -n '"'"'s/.*"key":"bitmap\/misses","value":"\([0-9][0-9]*\)".*/\1/p'"'"' \
			trace >misses &&
		test_line_count = 160 misses &&
		awk '"'"'{ sum += $1 } END { exit sum > 190 }'"'"' misses
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
