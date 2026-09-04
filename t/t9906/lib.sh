# Shared fixtures for t9906. All remote state is stored in local bare repos.
# The test entrypoint supplies release_tools and recipe.
# shellcheck disable=SC2154

release_cmd () {
	"${RELEASE_BASH:-bash}" "$release_tools/.github/release/release.sh" \
		--config "$RELEASE_TEST_DIR/config.json" \
		--worktree "$RELEASE_TEST_DIR/client" "$@"
}

reject () {
	pattern=$1 && shift &&
	if "$@" >"$RELEASE_TEST_DIR/rejected" 2>&1
	then
		cat "$RELEASE_TEST_DIR/rejected" &&
		echo "unexpected success: $*" >&2 && return 1
	else
		status=$? && test "$status" -lt 128 &&
		grep "$pattern" "$RELEASE_TEST_DIR/rejected"
	fi
}

digest () {
	if command -v sha256sum >/dev/null
	then sha256sum "$1"
	else shasum -a 256 "$1"
	fi | awk '{print $1}'
}

edit_json () {
	file=$1 && shift &&
	jq "$@" "$file" >"$file.new" && mv "$file.new" "$file"
}

db () { "$RELEASE_REAL_GIT" --git-dir="$RELEASE_TEST_DIR/remote.git" "$@"; }
client () { "$RELEASE_REAL_GIT" -C "$RELEASE_TEST_DIR/client" "$@"; }

set_control () {
	cp "$RELEASE_TEST_DIR/config.json" "$RELEASE_TEST_DIR/client/.github/release/config.json" &&
	client add .github/release/config.json &&
	client commit --allow-empty -m control &&
	client push origin HEAD:refs/heads/meta
}

make_artifacts () {
	artifact_candidate=$1 && artifact_directory=$2 &&
	mkdir -p "$artifact_directory" &&
	artifact_version=$(jq -r .version "$artifact_candidate") &&
	for native_target in macOS-arm64 macOS-x64 ubuntu-arm64 ubuntu-x64 windows-arm64 windows-x64
	do
		for extension in tar.gz lzma
		do
			archive=$artifact_directory/git-$artifact_version-$native_target.$extension &&
			printf 'synthetic fixture %s\n' "${archive##*/}" >"$archive" &&
			digest "$archive" >"$archive.sha256" || return 1
		done &&
		release_cmd record-build --repository "$(jq -r .repository "$artifact_candidate")" \
			--recipe-repository example/recipes --recipe-sha "$recipe" \
			--source-sha "$(jq -r .source_sha "$artifact_candidate")" \
			--version "$artifact_version" --target "$native_target" --run-id 42 \
			--artifacts "$artifact_directory" || return 1
	done
}

setup_template () {
	mkdir template && RELEASE_TEST_DIR="$TRASH_DIRECTORY/template" && export RELEASE_TEST_DIR &&
	git init --bare "$RELEASE_TEST_DIR/upstream.git" &&
	git init --bare "$RELEASE_TEST_DIR/remote.git" &&
	git init "$RELEASE_TEST_DIR/client" &&
	client config user.name Fixture && client config user.email fixture@example.invalid &&
	echo base >"$RELEASE_TEST_DIR/client/file" &&
	client add file && client commit -m base &&
	base=$(client rev-parse HEAD) &&
	client tag v2.55.0 &&
	client push "$RELEASE_TEST_DIR/upstream.git" HEAD:refs/heads/main refs/tags/v2.55.0 &&
	client remote add origin "$RELEASE_TEST_DIR/remote.git" &&
	client push origin HEAD:refs/heads/source &&
	client checkout --orphan meta && client rm -rf . &&
	mkdir -p "$RELEASE_TEST_DIR/client/.github/release" &&
	jq -n --arg recipe "$recipe" '{schema_version:1,repository:"example/distribution",visibility:"private",
	 control_ref:"refs/heads/meta",catalog_ref:"refs/heads/release-catalog",
	 recipe_repository:"example/recipes",recipe_sha:$recipe,
	 channels:{staff:{kind:"overlay",enabled:true,ref:"refs/heads/staff",prerelease:false,
	   upstream:{repository:"example/upstream",channel:"stable"},topic_sets:["common"]},
	 "staff-preview":{kind:"overlay",enabled:true,ref:"refs/heads/staff-preview",prerelease:true,
	   upstream:{repository:"example/upstream",channel:"preview"},topic_sets:["common","preview"]}},
	 topic_sets:{common:[],preview:[]}}' >"$RELEASE_TEST_DIR/config.json" &&
	set_control &&
	jq -n --arg source "$base" --arg recipe "$recipe" '{repository:"example/distribution",visibility:"private",
	 channel:"staff",recipe:{repository:"example/recipes",sha:$recipe},
	 base:{repository:"example/upstream",channel:"stable",version:"v2.55.0-public.1",
	 source_sha:$source,manifest_sha256:("3"*64)},topics:[],build_revision:1}' >"$RELEASE_TEST_DIR/inputs.json" &&
	jq -S -a . "$RELEASE_TEST_DIR/inputs.json" >"$RELEASE_TEST_DIR/canonical.json" &&
	jq -S -a --arg hash "$(digest "$RELEASE_TEST_DIR/canonical.json")" --arg source "$base" \
		--arg control "$(client rev-parse HEAD)" --arg tree "$(client rev-parse 'HEAD^{tree}')" \
		'. + {schema_version:1,inputs_sha256:$hash,source_sha:$source,control_sha:$control,control_tree:$tree,
		version:"v2.55.0-staff.1",upstream_tag:"v2.55.0",previous_source:null,previous_release:null,run_id:"42"}' \
		"$RELEASE_TEST_DIR/inputs.json" >"$RELEASE_TEST_DIR/candidate.json" &&
	db update-ref "refs/heads/release-candidates/$(jq -r .inputs_sha256 "$RELEASE_TEST_DIR/candidate.json")" "$base" &&
	make_artifacts "$RELEASE_TEST_DIR/candidate.json" "$RELEASE_TEST_DIR/artifacts" &&
	: >"$RELEASE_TEST_DIR/events"
}

reset_fixture () {
	reset_number=$((${reset_number:-0} + 1)) &&
	RELEASE_TEST_DIR="$TRASH_DIRECTORY/fixture-$reset_number" && export RELEASE_TEST_DIR &&
	cp -R "$TRASH_DIRECTORY/template" "$RELEASE_TEST_DIR" &&
	client remote set-url origin "$RELEASE_TEST_DIR/remote.git" &&
	: >"$RELEASE_TEST_DIR/events"
}

manifest () {
	release_cmd manifest --candidate "$RELEASE_TEST_DIR/candidate.json" \
		--artifacts "$RELEASE_TEST_DIR/artifacts" --output "$RELEASE_TEST_DIR/manifest.json"
}

publish () {
	release_cmd publish --candidate "$RELEASE_TEST_DIR/candidate.json" --artifacts "$RELEASE_TEST_DIR/artifacts"
}

release_file () { echo "$RELEASE_TEST_DIR/github/example/distribution/releases/v2.55.0-staff.1.json"; }

setup_topic () {
	client checkout -b feature "$base" &&
	echo feature >"$RELEASE_TEST_DIR/client/feature" &&
	client add feature && client commit -m feature &&
	tip=$(client rev-parse HEAD) &&
	client push origin HEAD:refs/heads/feature &&
	client checkout meta &&
	jq -n --arg tip "$tip" '{state:"open",draft:false,user:{login:"author"},
		head:{repo:{full_name:"example/distribution"},sha:$tip,ref:"feature"}}' >"$RELEASE_TEST_DIR/pr.json" &&
	jq -n --arg tip "$tip" '[{user:{login:"reviewer"},state:"APPROVED",commit_id:$tip}]' >"$RELEASE_TEST_DIR/reviews.json"
}

enroll_topic () {
	db update-ref "refs/heads/release-pins/$tip" "$tip" &&
	edit_json "$RELEASE_TEST_DIR/config.json" --arg tip "$tip" --arg base "$base" \
		'.topic_sets.common=[{name:"feature",source_sha:$tip,source_base:$base,source_ref:"refs/heads/feature",review_pr:7}]' &&
	set_control
}

setup_upstream_release () {
	jq '.repository="example/upstream" | .visibility="public" | .channel="stable" |
		.version="v2.55.0-public.1" | .base=null' "$RELEASE_TEST_DIR/candidate.json" >"$RELEASE_TEST_DIR/public.json" &&
	make_artifacts "$RELEASE_TEST_DIR/public.json" "$RELEASE_TEST_DIR/public-assets" &&
	release_cmd manifest --candidate "$RELEASE_TEST_DIR/public.json" \
		--artifacts "$RELEASE_TEST_DIR/public-assets" --output "$RELEASE_TEST_DIR/manifest.json" &&
	jq '{tag_name:.version,target_commitish:.source_sha,prerelease:true,draft:true}' \
		"$RELEASE_TEST_DIR/public.json" >"$RELEASE_TEST_DIR/payload.json" &&
	gh api repos/example/upstream/releases --method POST --input "$RELEASE_TEST_DIR/payload.json" &&
	for asset in "$RELEASE_TEST_DIR/public-assets"/*
	do
		case "$asset" in *.build.json) continue ;; esac &&
		gh release upload v2.55.0-public.1 "$asset" --repo example/upstream || return 1
	done &&
	gh release upload v2.55.0-public.1 "$RELEASE_TEST_DIR/manifest.json" --repo example/upstream &&
	echo '{"draft":false}' >"$RELEASE_TEST_DIR/payload.json" &&
	gh api repos/example/upstream/releases/100 --method PATCH --input "$RELEASE_TEST_DIR/payload.json" &&
	(
		GIT_INDEX_FILE=$RELEASE_TEST_DIR/catalog-index && export GIT_INDEX_FILE &&
		client read-tree --empty &&
		jq --arg hash "$(digest "$RELEASE_TEST_DIR/manifest.json")" \
			'{schema_version:1,repository,channel,version,source_sha,manifest_sha256:$hash}' \
			"$RELEASE_TEST_DIR/manifest.json" >"$RELEASE_TEST_DIR/pointer.json" &&
		blob=$(client hash-object -w "$RELEASE_TEST_DIR/pointer.json") &&
		client update-index --add --cacheinfo 100644 "$blob" channels/stable.json &&
		tree=$(client write-tree) && commit=$(echo catalog | client commit-tree "$tree") &&
		client push "$RELEASE_TEST_DIR/upstream.git" "$commit:refs/heads/release-catalog"
	)
}

sync_release () {
	release_cmd sync --channel staff --recipe-sha "$recipe" --output "$RELEASE_TEST_DIR/$1" --stage
}

replay () {
	(
		cd "$RELEASE_TEST_DIR/client" &&
		sh "$release_tools/.github/workflows/codex-branch.sh" assemble-plan \
			--base "$1" --name staff --plan "$RELEASE_TEST_DIR/plan.tsv" \
			--session "$RELEASE_TEST_DIR/$2" --result "$RELEASE_TEST_DIR/$2.sha"
	)
}
