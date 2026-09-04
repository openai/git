# Git distribution releases

`.github/release/config.json` describes each repository's release channels. The existing
Codex controller still admits source topics, builds the generated branches,
and records their exact tips in `codex.config`. The release layer consumes
those outputs, builds native packages, and records completed releases.

The command is `bash .github/release/release.sh`. It uses Git and `gh` for
repository operations and `jq` for JSON validation and release records. The
JSON filters and repository configuration live beside the script. No Python
runtime is required by the release tooling.

The public source workflow calls `git-build.yml` and `git-publish.yml` at one
full `meta` commit ID. The build recipe is the existing six-platform recipe:
native macOS, Linux, and Windows builds for arm64 and x64, with the same
PGO/LTO configuration, runtime dependencies, package layout, size checks,
source stamping, and native smoke tests. Publication credentials are confined
to the publisher job.

## What constitutes a release

Every native build uploads its two archives, checksum sidecars, and a build
receipt. The publisher requires all six targets and checks their source,
recipe, workflow run, sizes, and hashes. It creates a draft release, uploads
missing assets, reads them back, and publishes only after the set is complete.
An existing asset must match byte for byte; retries never overwrite it.

The release's `manifest.json` records the repository, visibility, channel,
source commit, recipe commit, upstream release, ordered source pins, build
receipts, and all artifact hashes. Consumers read
`channels/<channel>.json` on `release-catalog` to find the last completed
release and the hash of its manifest. Do not use GitHub's `/releases/latest`:
the two Codex channels both publish prereleases.

Stable package versions retain their existing format. Preview versions add
`.codex-unstable`, so both channels can release the same source commit without
colliding on a tag or a channel-specific manifest.

Public publication rechecks the exact `codex.config` output and source ref
before publishing. A complete release can exist without a channel update if
the inputs or channel moved in the meantime. The previous current release
remains usable. Retry the failed publication job with its original artifacts;
if another release won, prepare fresh inputs.

## Repository configuration

`kind: ledger` reads an existing controller's exact output from a Git config
file. `kind: overlay` composes ordered, reviewed source pins on a completed
upstream release. Overlay channels require a private destination and an exact
public build-recipe pin. A repository or visibility mismatch stops before
publication. The origin fetch and push URLs must both name that repository.

An overlay can share one topic set across its stable and preview channels:

```json
{
  "common": [
    {
      "name": "feature",
      "source_ref": "refs/heads/feature",
      "source_sha": "<full reviewed commit ID>",
      "source_base": "<full reviewed boundary commit ID>",
      "review_pr": 123,
      "dependency": "release-base"
    }
  ],
  "preview": []
}
```

The stable channel uses `common`; the preview channel uses `common` followed
by `preview`. Dependencies must precede their dependents. A dependent's
boundary must equal its prerequisite's reviewed source pin. Retain the source
object at `release-pins/<full source ID>`. Source review PRs stay open, are
not merged into generated outputs, and need an independent writer approval
at the exact pinned revision. A changes request or dismissed approval blocks
publication. Review the control-plan change separately.

`bash .github/release/release.sh sync` resolves the upstream channel's completed manifest, replays
the private source pins, and saves the candidate inputs. It does not push
unless `--stage` is supplied. Staging creates an immutable candidate ref;
the distribution and source test jobs then run with read-only credentials.
If the current channel already contains those inputs, sync reports no change.
Private topic names, source IDs, logs, and artifacts stay in the caller's
private repository. No private input is sent to the upstream controller.

The local `codex-branch assemble-plan` interface reuses pinned topic replay
without invoking admission or publication. Its tab-separated plan contains
name, source ID, reviewed boundary, and prerequisite. It disables hooks,
uses deterministic generated commit dates, checks merge topology, and never
moves reviewed topic refs. Conflicts preserve the local replay session. Fix
and review the source topic, pin the new revision, and rerun; publication
does not accept an unreviewed edit to a stopped worktree.

The local release interface also disables cached conflict resolutions; they
are not part of the reviewed source pins. Overlay channels can increment
`build_revision` through a reviewed configuration change when an expired or
non-reproducible build needs a new immutable version for the same source.

For overlays, publication atomically updates the generated channel, catalog,
and an empty receipt commit on the control branch, each with its expected
old value. The receipt has the same tree as the reviewed control commit.
Another channel's receipt does not invalidate unchanged inputs; a reviewed
configuration or workflow change does. A concurrent ref change rejects the
whole transaction.

Promote a preview **source pin** into the common plan, then rebuild against
the stable public base. Promoting the preview binary would also promote its
public preview changes. `bash .github/release/release.sh rollback` moves an overlay channel back to
an existing complete release without rebuilding or replacing any artifact.

`bash .github/release/release.sh download` authenticates through `gh`, downloads the selected archive,
and verifies it against the manifest before creating the destination. Package
builders can pass `--version` to lock an exact release instead of following
the channel at package time. Keep any package containing private binaries in
an authenticated distribution system too.

## Activation

1. Land the shared release tools on `meta`. Keep the public release wrapper's
   reusable-workflow references and `recipe_sha` on that full commit ID.
2. Configure a dedicated GitHub App with Contents write, Pull requests read,
   and Actions read on each destination. An overlay repository also needs
   Workflows write: importing reviewed upstream commits carries their workflow
   files. Set `import_workflows: true` in that private publisher call. Store
   the App key as `RELEASE_APP_PRIVATE_KEY` and
   its ID as `RELEASE_APP_ID` in that repository's `git-release` environment.
   Tokens are explicitly limited to the caller repository. Do not install a
   private publisher App on a public repository.
3. Restrict the environment to the reviewed release entrypoint branches:
   `codex` and `codex-unstable` for this public repository; the control branch
   for an overlay repository. Build jobs do not use the environment or App.
4. Protect the catalog and generated overlay refs so only the publisher App
   can write them; prevent source-pin and candidate-ref updates/deletion.
   Protect release tags against replacement and deletion. Protect private
   control changes with independent review, permitting the publisher App's
   unchanged-tree receipt commits. Do not grant the general GitHub Actions
   identity a ruleset bypass.
5. Admit the consolidated release source through the normal topic/plan review
   and staging process. It replaces `tb/codex/release`, `dr/codex/dugite`, and
   `tb/codex/lto-pgo` together. It retains the PGO configuration and training
   source, while the shared recipe retains Dugite selection and all platform
   settings. Keeping the three old workflow-editing topics enrolled would
   create needless conflicts with the replacement wrapper. The source
   boundary is the original release/PGO production base; the publication
   gate is unchanged. The first successful release creates the catalog.
6. Check the overlay plan, environment, and protections before enabling a
   preview canary. Qualify that canary before enabling stable publication.
   Empty bootstrap plans do not implicitly enroll any existing private branch.

The public source controller remains repository-specific. This change makes
its **release** controller and build/publish jobs reusable; it does not port
the Codex topic-admission monolith to a second repository.

## Validation

Run `t/t9906-git-release.sh` from a complete Git source tree's `t` directory
with `GIT_RELEASE_TOOLS` pointing at this control checkout. It uses real local
Git repositories and a local GitHub fixture that rejects network destinations.
Set `RELEASE_BASH=/bin/bash` to exercise macOS Bash 3.2. Run
`t/t9905-codex-branch.sh` in the same harness with `CODEX_BRANCH` pointing at
this checkout's helper. Check reusable and
caller workflows with `actionlint`. The first hosted canary must still build
and run all six native distributions; local metadata tests cannot certify
runner images, environment permissions, or the packaged runtime.

GitHub documents [repository-scoped App tokens](https://github.com/actions/create-github-app-token),
[App permissions for HTTP Git and workflow imports](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app),
[environment branch restrictions](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments),
and [authenticated release-asset downloads](https://docs.github.com/en/rest/releases/assets#get-a-release-asset).
