#!/bin/sh

test_description='release manifests, reviewed source composition and publication recovery'

release_tools=${GIT_RELEASE_TOOLS:-$(CDPATH='' cd "$(dirname "$0")/.." && pwd)}
. ./test-lib.sh

if ! command -v jq >/dev/null || ! command -v bash >/dev/null
then
	skip_all='jq and bash are required'
	test_done
fi

RELEASE_REAL_GIT=$(command -v git)
PATH="$release_tools/t/t9906:$PATH"
GITHUB_REPOSITORY=example/distribution
GITHUB_RUN_ID=42
export RELEASE_REAL_GIT PATH GITHUB_REPOSITORY GITHUB_RUN_ID
recipe=1111111111111111111111111111111111111111
. "$release_tools/t/t9906/lib.sh"

test_expect_success 'set up local transport and six native build fixtures' '
	setup_template
'

test_expect_success 'manifest records all six targets and exact build provenance' '
	reset_fixture && manifest &&
	jq -e --arg source "$base" "(.targets | length)==6 and (.builds | length)==6 and .source_sha==\$source" "$RELEASE_TEST_DIR/manifest.json"
'

test_expect_success 'missing artifact fails before publication' '
	reset_fixture && rm "$RELEASE_TEST_DIR/artifacts/"*.lzma &&
	reject "missing or non-regular" publish && test_must_be_empty "$RELEASE_TEST_DIR/events"
'

test_expect_success 'changed bytes with a matching sidecar still fail the build receipt' '
	reset_fixture && archive=$RELEASE_TEST_DIR/artifacts/git-v2.55.0-staff.1-macOS-arm64.tar.gz &&
	echo changed >"$archive" && digest "$archive" >"$archive.sha256" &&
	reject "differ from native build receipt" manifest
'

test_expect_success 'receipts must match source, recipe and workflow run' '
	for field in source_sha recipe.sha run_id
	do
		reset_fixture && receipt=$RELEASE_TEST_DIR/artifacts/git-v2.55.0-staff.1-macOS-arm64.build.json &&
		edit_json "$receipt" ".$field=\"wrong\"" &&
		reject "differs from candidate" manifest || return 1
	done
'

test_expect_success 'symlink, unexpected dotfile and empty archive are rejected' '
	reset_fixture && archive=$RELEASE_TEST_DIR/artifacts/git-v2.55.0-staff.1-macOS-arm64.tar.gz &&
	mv "$archive" "$RELEASE_TEST_DIR/real-archive" && ln -s "$RELEASE_TEST_DIR/real-archive" "$archive" &&
	reject "missing or non-regular" manifest &&
	rm "$archive" && mv "$RELEASE_TEST_DIR/real-archive" "$archive" &&
	touch "$RELEASE_TEST_DIR/artifacts/.extra" && reject "unexpected build artifacts" manifest &&
	rm "$RELEASE_TEST_DIR/artifacts/.extra" && : >"$archive" && digest "$archive" >"$archive.sha256" &&
	release_cmd record-build --repository example/distribution --recipe-repository example/recipes --recipe-sha "$recipe" \
		--source-sha "$base" --version v2.55.0-staff.1 --target macOS-arm64 --run-id 42 --artifacts "$RELEASE_TEST_DIR/artifacts" &&
	reject "invalid asset size" manifest
'

test_expect_success 'overlay configuration cannot name a public destination' '
	reset_fixture && edit_json "$RELEASE_TEST_DIR/config.json" ".visibility=\"public\"" &&
	reject "require a private repository" release_cmd check-config
'

test_expect_success 'visibility, caller and both origin URLs are checked before writes' '
	reset_fixture &&
	(RELEASE_TEST_VISIBILITY=public && export RELEASE_TEST_VISIBILITY && reject "visibility changed" publish) &&
	(GITHUB_REPOSITORY=example/other && export GITHUB_REPOSITORY && reject "caller repository" publish) &&
	(RELEASE_TEST_ORIGIN=https://github.com/example/other.git && export RELEASE_TEST_ORIGIN && reject "origin does not point" publish) &&
	test_must_be_empty "$RELEASE_TEST_DIR/events"
'

test_expect_success 'configuration edits and moved candidate pins reject stale inputs' '
	reset_fixture && edit_json "$RELEASE_TEST_DIR/config.json" ".channels.staff.build_revision=2" &&
	set_control && : >"$RELEASE_TEST_DIR/events" &&
	reject "configuration changed" publish && test_must_be_empty "$RELEASE_TEST_DIR/events"
'

test_expect_success 'missing candidate pin rejects publication' '
	reset_fixture && db update-ref -d "refs/heads/release-candidates/$(jq -r .inputs_sha256 "$RELEASE_TEST_DIR/candidate.json")" &&
	reject "candidate ref changed" publish && test_must_be_empty "$RELEASE_TEST_DIR/events"
'

test_expect_success 'failed source tests block complete native builds' '
	reset_fixture &&
	(RELEASE_TEST_SOURCE_RESULT=failure && export RELEASE_TEST_SOURCE_RESULT && reject "did not pass" publish) &&
	test_must_be_empty "$RELEASE_TEST_DIR/events"
'

test_expect_success 'draft completion precedes atomic source, catalog and control promotion' '
	reset_fixture && publish &&
	jq -e ".draft==false and (.assets | length)==25" "$(release_file)" &&
	test "$(db rev-parse refs/heads/staff)" = "$base" &&
	test "$(db rev-parse refs/heads/meta^{tree})" = "$(jq -r .control_tree "$RELEASE_TEST_DIR/candidate.json")" &&
	tail -2 "$RELEASE_TEST_DIR/events" >actual &&
	printf "PATCH repos/example/distribution/releases/100\npush\n" >expect && test_cmp expect actual &&
	cp -R "$RELEASE_TEST_DIR" "$TRASH_DIRECTORY/published"
'

test_expect_success 'successful publication is idempotent and download verifies bytes' '
	RELEASE_TEST_DIR=$TRASH_DIRECTORY/published && export RELEASE_TEST_DIR &&
	client remote set-url origin "$RELEASE_TEST_DIR/remote.git" && : >"$RELEASE_TEST_DIR/events" &&
	publish && test_must_be_empty "$RELEASE_TEST_DIR/events" &&
	release_cmd download --channel staff --target macOS-arm64 --directory "$RELEASE_TEST_DIR/download" &&
	test_cmp "$RELEASE_TEST_DIR/artifacts/git-v2.55.0-staff.1-macOS-arm64.tar.gz" "$RELEASE_TEST_DIR/download/git-v2.55.0-staff.1-macOS-arm64.tar.gz"
'

test_expect_success 'corrupt downloaded bytes fail before destination creation' '
	asset_id=$(jq -r ".assets[] | select(.name==\"git-v2.55.0-staff.1-macOS-arm64.tar.gz\") | .id" "$(release_file)") &&
	echo corrupt >"$RELEASE_TEST_DIR/github/example/distribution/assets/$asset_id" &&
	reject "download checksum mismatch" release_cmd download --channel staff --target macOS-arm64 --directory "$RELEASE_TEST_DIR/corrupt-download" &&
	test_path_is_missing "$RELEASE_TEST_DIR/corrupt-download"
'

test_expect_success 'partial upload resumes without overwriting existing assets' '
	reset_fixture &&
	(RELEASE_TEST_FAIL_AFTER=2 && export RELEASE_TEST_FAIL_AFTER && reject "interrupted upload" publish) &&
	jq -e ".draft and (.assets | length)==2" "$(release_file)" &&
	publish && test "$(grep -c "^upload " "$RELEASE_TEST_DIR/events")" = 25
'

test_expect_success 'changed draft asset cannot be clobbered' '
	reset_fixture &&
	(RELEASE_TEST_FAIL_AFTER=1 && export RELEASE_TEST_FAIL_AFTER && reject "interrupted upload" publish) &&
	echo changed >"$RELEASE_TEST_DIR/github/example/distribution/assets/1" &&
	: >"$RELEASE_TEST_DIR/events" && reject "assets are immutable" publish &&
	test_must_be_empty "$RELEASE_TEST_DIR/events"
'

test_expect_success 'existing wrong tag and incomplete published releases are immutable' '
	reset_fixture && db update-ref refs/tags/v2.55.0-staff.1 "$(client rev-parse meta)" &&
	reject "tag already names different source" publish && test_must_be_empty "$RELEASE_TEST_DIR/events" &&
	db update-ref -d refs/tags/v2.55.0-staff.1 &&
	(RELEASE_TEST_FAIL_AFTER=1 && export RELEASE_TEST_FAIL_AFTER && reject "interrupted upload" publish) &&
	edit_json "$(release_file)" ".draft=false" &&
	db update-ref refs/tags/v2.55.0-staff.1 "$base" && : >"$RELEASE_TEST_DIR/events" &&
	reject "published release is incomplete" publish && test_must_be_empty "$RELEASE_TEST_DIR/events"
'

test_expect_success 'reviewed pins are retained once and validate-plan uses the exact review head' '
	reset_fixture && setup_topic &&
	release_cmd pin --source-sha "$tip" --source-ref refs/heads/feature --review-pr 7 &&
	release_cmd pin --source-sha "$tip" --source-ref refs/heads/feature --review-pr 7 &&
	test "$(grep -c "POST repos/example/distribution/git/refs" "$RELEASE_TEST_DIR/events")" = 1 &&
	enroll_topic && release_cmd validate-plan &&
	edit_json "$RELEASE_TEST_DIR/pr.json" --arg base "$base" ".head.sha=\$base" &&
	reject "review no longer matches" release_cmd validate-plan
'

test_expect_success 'stale, dismissed, self and changes-requested reviews cannot approve source' '
	reset_fixture && setup_topic && enroll_topic &&
	for edit in ".[0].commit_id=\"stale\"" ".[0].state=\"DISMISSED\"" ".[0].user.login=\"author\"" ". += [.[0] | .state=\"CHANGES_REQUESTED\"]"
	do
		cp "$RELEASE_TEST_DIR/reviews.json" "$RELEASE_TEST_DIR/reviews.saved" &&
		edit_json "$RELEASE_TEST_DIR/reviews.json" "$edit" &&
		reject "approval\|requested changes" release_cmd validate-plan &&
		mv "$RELEASE_TEST_DIR/reviews.saved" "$RELEASE_TEST_DIR/reviews.json" || return 1
	done
'

test_expect_success 'topic sets preserve dependency order and exact prerequisite boundaries' '
	reset_fixture && setup_topic && enroll_topic &&
	edit_json "$RELEASE_TEST_DIR/config.json" --arg tip "$tip" ".topic_sets.preview=[.topic_sets.common[0] | .name=\"child\" | .dependency=\"feature\" | .source_base=\$tip]" &&
	release_cmd check-config &&
	edit_json "$RELEASE_TEST_DIR/config.json" ".topic_sets.preview[0].source_base=\"2222222222222222222222222222222222222222\"" &&
	reject "prerequisite boundary" release_cmd check-config &&
	edit_json "$RELEASE_TEST_DIR/config.json" ".topic_sets.common[0].dependency=\"child\"" &&
	reject "follow their prerequisites" release_cmd check-config
'

test_expect_success 'sync imports the completed public source and preserves a reviewed topic' '
	reset_fixture && setup_topic && enroll_topic && setup_upstream_release &&
	sync_release first &&
	test "$(client show "$(cat "$RELEASE_TEST_DIR/first/source-sha"):feature")" = feature &&
	cp "$RELEASE_TEST_DIR/first/candidate.json" "$RELEASE_TEST_DIR/candidate.json" &&
	rm -rf "$RELEASE_TEST_DIR/artifacts" && make_artifacts "$RELEASE_TEST_DIR/candidate.json" "$RELEASE_TEST_DIR/artifacts" &&
	publish && sync_release second &&
	jq -e .noop "$RELEASE_TEST_DIR/second/candidate.json" &&
	edit_json "$RELEASE_TEST_DIR/config.json" ".channels.staff.build_revision=2" &&
	client fetch origin meta && client reset --hard FETCH_HEAD && set_control && sync_release third &&
	jq -e ".noop==false" "$RELEASE_TEST_DIR/third/candidate.json" &&
	test "$(jq -r .version "$RELEASE_TEST_DIR/first/candidate.json")" != "$(jq -r .version "$RELEASE_TEST_DIR/third/candidate.json")"
'

test_expect_success 'workflow changes in a source topic stop composition' '
	reset_fixture && setup_topic && client checkout feature &&
	mkdir -p "$RELEASE_TEST_DIR/client/.github/workflows" && echo unreviewed >"$RELEASE_TEST_DIR/client/.github/workflows/example.yml" &&
	client add .github && client commit -m workflow && tip=$(client rev-parse HEAD) &&
	client push origin feature && client checkout meta &&
	edit_json "$RELEASE_TEST_DIR/pr.json" --arg tip "$tip" ".head.sha=\$tip" &&
	edit_json "$RELEASE_TEST_DIR/reviews.json" --arg tip "$tip" ".[0].commit_id=\$tip" &&
	enroll_topic && setup_upstream_release &&
	reject "may not change workflow" sync_release blocked
'

test_expect_success 'a concurrent control receipt rejects the transaction and permits a safe retry' '
	reset_fixture &&
	client commit --allow-empty -m concurrent &&
	client push origin HEAD:refs/heads/concurrent && client rev-parse HEAD >"$RELEASE_TEST_DIR/race" &&
	reject "stale info" publish &&
	test_must_fail git --git-dir="$RELEASE_TEST_DIR/remote.git" show-ref --verify refs/heads/staff &&
	test_must_fail git --git-dir="$RELEASE_TEST_DIR/remote.git" show-ref --verify refs/heads/release-catalog &&
	jq -e ".draft==false" "$(release_file)" &&
	publish
'

test_expect_success 'rollback uses an existing complete release without rebuilding or uploading' '
	: >"$RELEASE_TEST_DIR/events" &&
	release_cmd rollback --channel staff --version v2.55.0-staff.1 &&
	test "$(cat "$RELEASE_TEST_DIR/events")" = push
'

test_expect_success 'empty replay uses the exact base and leaves refs unchanged' '
	reset_fixture && : >"$RELEASE_TEST_DIR/plan.tsv" &&
	client for-each-ref >before && replay "$base" empty &&
	test "$(cat "$RELEASE_TEST_DIR/empty.sha")" = "$base" &&
	client for-each-ref >after && test_cmp before after
'

test_expect_success 'replay is deterministic on a new public base and disables hooks' '
	reset_fixture && setup_topic && client checkout -b newer "$base" &&
	echo upstream >"$RELEASE_TEST_DIR/client/upstream" && client add upstream && client commit -m upstream &&
	newbase=$(client rev-parse HEAD) &&
	printf "feature\t%s\t%s\trelease-base\n" "$tip" "$base" >"$RELEASE_TEST_DIR/plan.tsv" &&
	printf "#!/bin/sh\ntouch %s/hook-ran\n" "$RELEASE_TEST_DIR" >"$RELEASE_TEST_DIR/client/.git/hooks/post-checkout" &&
	chmod +x "$RELEASE_TEST_DIR/client/.git/hooks/post-checkout" &&
	client for-each-ref >before && replay "$newbase" one && replay "$newbase" two &&
	test_cmp "$RELEASE_TEST_DIR/one.sha" "$RELEASE_TEST_DIR/two.sha" &&
	test "$(client show "$(cat "$RELEASE_TEST_DIR/one.sha"):upstream")" = upstream &&
	test_path_is_missing "$RELEASE_TEST_DIR/hook-ran" && client for-each-ref >after && test_cmp before after
'

test_expect_success 'a conflict preserves its session and ignores local rerere resolutions' '
	reset_fixture && client checkout -b conflict "$base" &&
	echo topic >"$RELEASE_TEST_DIR/client/file" && client commit -am topic && tip=$(client rev-parse HEAD) &&
	client checkout -b upstream "$base" && echo upstream >"$RELEASE_TEST_DIR/client/file" && client commit -am upstream &&
	newbase=$(client rev-parse HEAD) &&
	if client -c rerere.enabled=true merge conflict; then return 1; fi &&
	echo cached >"$RELEASE_TEST_DIR/client/file" && client -c rerere.enabled=true rerere && client merge --abort &&
	printf "feature\t%s\t%s\trelease-base\n" "$tip" "$base" >"$RELEASE_TEST_DIR/plan.tsv" &&
	client for-each-ref >before && reject "conflict\|failed" replay "$newbase" conflict-session &&
	test_path_is_dir "$RELEASE_TEST_DIR/conflict-session/worktree" &&
	test_path_is_file "$RELEASE_TEST_DIR/conflict-session/state/failed-owner" &&
	client for-each-ref >after && test_cmp before after
'

test_expect_success 'ledger preparation requires both the recorded output and generated ref' '
	reset_fixture &&
	edit_json "$RELEASE_TEST_DIR/config.json" ".visibility=\"public\" | .channels={stable:{kind:\"ledger\",enabled:true,ref:\"refs/heads/stable\",prerelease:true,ledger_path:\"codex.config\",ledger_key:\"codex.output-tip\"}}" &&
	client config --file "$RELEASE_TEST_DIR/client/codex.config" codex.output-tip "$base" &&
	client add codex.config && set_control && db update-ref refs/heads/stable "$base" &&
	(
		RELEASE_TEST_VISIBILITY=public && export RELEASE_TEST_VISIBILITY &&
		release_cmd prepare --channel stable --source-sha "$base" --recipe-sha "$recipe" \
			--version v2.55.0-public.1 --upstream-tag v2.55.0 --output "$RELEASE_TEST_DIR/prepared" &&
		jq -e ".base==null and .topics==[]" "$RELEASE_TEST_DIR/prepared/candidate.json" &&
		db update-ref refs/heads/stable "$(client rev-parse meta)" &&
		reject "controller-published channel output" release_cmd prepare --channel stable --source-sha "$base" \
			--recipe-sha "$recipe" --version v2.55.0-public.1 --upstream-tag v2.55.0 --output "$RELEASE_TEST_DIR/stale"
	)
'

test_expect_success 'candidate input edits and cross-run publication are rejected before writes' '
	reset_fixture && edit_json "$RELEASE_TEST_DIR/candidate.json" ".base.version=\"tampered\"" &&
	reject "input checksum mismatch" publish &&
	cp "$TRASH_DIRECTORY/template/candidate.json" "$RELEASE_TEST_DIR/candidate.json" &&
	(GITHUB_RUN_ID=43 && export GITHUB_RUN_ID && reject "original workflow artifacts" publish) &&
	test_must_be_empty "$RELEASE_TEST_DIR/events"
'

test_expect_success 'oversized distribution is rejected even with an accurate build receipt' '
	reset_fixture && archive=$RELEASE_TEST_DIR/artifacts/git-v2.55.0-staff.1-macOS-arm64.tar.gz &&
	dd if=/dev/zero of="$archive" bs=1 count=1 seek=67108864 && digest "$archive" >"$archive.sha256" &&
	release_cmd record-build --repository example/distribution --recipe-repository example/recipes --recipe-sha "$recipe" \
		--source-sha "$base" --version v2.55.0-staff.1 --target macOS-arm64 --run-id 42 --artifacts "$RELEASE_TEST_DIR/artifacts" &&
	reject "size limit" manifest
'

test_expect_success 'later comments preserve an effective approval but a later dismissal does not' '
	reset_fixture && setup_topic && enroll_topic &&
	edit_json "$RELEASE_TEST_DIR/reviews.json" ". += [.[0] | .state=\"COMMENTED\"]" &&
	release_cmd validate-plan &&
	edit_json "$RELEASE_TEST_DIR/reviews.json" ". += [.[0] | .state=\"DISMISSED\"]" &&
	reject "independent writer approval" release_cmd validate-plan
'

test_expect_success 'merge topology survives replay onto a moved public base' '
	reset_fixture && setup_topic && left=$tip &&
	client checkout -b right "$base" && echo right >"$RELEASE_TEST_DIR/client/right" &&
	client add right && client commit -m right && client merge --no-ff -m join "$left" &&
	tip=$(client rev-parse HEAD) && client checkout -b newer "$base" &&
	echo upstream >"$RELEASE_TEST_DIR/client/upstream" && client add upstream && client commit -m upstream &&
	newbase=$(client rev-parse HEAD) &&
	printf "graph\t%s\t%s\trelease-base\n" "$tip" "$base" >"$RELEASE_TEST_DIR/plan.tsv" &&
	replay "$newbase" graph && graph=$(client rev-parse "$(cat "$RELEASE_TEST_DIR/graph.sha")^2") &&
	test "$(client show -s --format=%P "$graph" | wc -w | tr -d " ")" = 2 &&
	test "$(client show "$graph:feature")" = feature && test "$(client show "$graph:right")" = right &&
	test "$(client show "$graph:upstream")" = upstream
'

test_expect_success 'stable and preview compose their own base and ordered topic sets' '
	reset_fixture && setup_topic && feature=$tip &&
	client checkout -b preview feature && echo preview >"$RELEASE_TEST_DIR/client/preview" &&
	client add preview && client commit -m preview && preview=$(client rev-parse HEAD) &&
	client checkout -b public-preview "$base" && echo public >"$RELEASE_TEST_DIR/client/public-preview" &&
	client add public-preview && client commit -m public-preview && preview_base=$(client rev-parse HEAD) &&
	printf "feature\t%s\t%s\trelease-base\n" "$feature" "$base" >"$RELEASE_TEST_DIR/plan.tsv" &&
	replay "$base" stable &&
	printf "preview\t%s\t%s\tfeature\n" "$preview" "$feature" >>"$RELEASE_TEST_DIR/plan.tsv" &&
	replay "$preview_base" preview &&
	test "$(client show "$(cat "$RELEASE_TEST_DIR/stable.sha"):feature")" = feature &&
	test_must_fail git -C "$RELEASE_TEST_DIR/client" cat-file -e "$(cat "$RELEASE_TEST_DIR/stable.sha"):preview" &&
	test "$(client show "$(cat "$RELEASE_TEST_DIR/preview.sha"):preview")" = preview &&
	test "$(client show "$(cat "$RELEASE_TEST_DIR/preview.sha"):public-preview")" = public
'

test_expect_success 'new release directory and fixtures are protected controller paths' '
	reset_fixture &&
	for function in legacy_control_paths_unchanged meta_control_paths_unchanged topic_control_paths_unchanged
	do
		sed -n "/^$function () (/,/^)/p" "$release_tools/.github/workflows/codex-branch.sh" >"$RELEASE_TEST_DIR/protected.sh" &&
		printf "\n%s \"\0441\" \"\0442\"\n" "$function" >>"$RELEASE_TEST_DIR/protected.sh" &&
		for path in .github/release/config.json .github/release/release.sh .github/release/release.jq t/t9906-git-release.sh t/t9906/gh
		do
			client checkout -f --detach "$base" &&
			mkdir -p "$RELEASE_TEST_DIR/client/$(dirname "$path")" &&
			echo changed >"$RELEASE_TEST_DIR/client/$path" && client add "$path" && client commit -m control-change &&
			if (cd "$RELEASE_TEST_DIR/client" && sh "$RELEASE_TEST_DIR/protected.sh" "$base" HEAD)
			then return 1
			fi || return 1
		done || return 1
	done
'

test_done
