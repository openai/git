# Maintaining `codex` and `codex-unstable`

`master` stays equivalent to upstream. `codex` is the production integration
branch distributed with Codex. When enabled, `codex-unstable` starts at that
exact production commit and adds reviewed preview topics; it never publishes a
production release. The orphan `meta` branch contains the controller, reusable
workflows, tests, documentation, and ruleset recipes. Never merge `meta` into
`master`, `codex`, or `codex-unstable`.

Topics use branches named `??/codex/*`, where `??` is a two-character owner
name. A topic ending in `-unstable` belongs only in `codex-unstable`; other
active topics belong in `codex`. The existing rows in `meta:codex.config` stay
enrolled. A new topic enters either lane only after its reviewed pull request
merges into that lane and the controller enrolls its retained head. Merely
pushing a matching branch, including an `-unstable` branch, never includes it
in a build. The `-wip` and `-stale` suffixes are inactive.

The generated `codex.config` records each enrolled topic's prerequisites and
last published tip. A linear topic has one `branch.<name>.merge` value; a
merge-shaped topic records every reviewed parent edge as a repeated `merge`
value. When the preview lane is enabled, the file also records the exact
production commit underlying `codex-unstable` and its published preview tip.
Prerequisite edges form a partial order within each lane; there is no global
topic order. Rows are sorted only to give the generated file a stable
representation.

The saved tips are rebase boundaries, not another copy of the patches. They
let a fresh runner distinguish “the prerequisite was rewritten” from “these
are independent topics” after their current tips stop sharing ancestry. This
is what makes amending, dropping, or replacing an already-published commit
safe without relying on a runner's local reflogs.

The generated `codex` history contains one explicit two-parent integration
commit for every production topic, including prerequisites, fast-forwardable
topics, and empty topics. `codex-unstable` starts at the exact generated
`codex` commit and adds one explicit integration merge per enrolled preview
topic. It remains strictly ahead even before its first topic because enabling
it creates a tree-identical bootstrap commit. Prerequisites are integrated
before their dependents; lexical order only breaks ties among topics that are
ready at the same time. This makes the history deterministic without inventing
semantic dependencies.

## Add a production topic

Create a topic from `master`, or from the topic it depends on:

```sh
git switch -c tb/codex/my-topic origin/master
# Edit, test, and commit.
git push -u origin HEAD
```

Pushing this branch does not change `codex`. To include it:

1. Open a pull request from the topic to `codex` and obtain the required
   approval.
2. Select **Merge when ready**. The merge queue admits one reviewed topic at
   a time and creates a normal two-parent merge commit.
3. Run `Meta/rebuild` or `Meta/rebuild --local`. The controller verifies the
   merged pull request, enrolls its exact retained topic head, runs staging
   CI, and publishes the rebuilt branch.

The pull request merge leaves `codex` temporarily **pending**: its tip no
longer matches the output recorded in `meta:codex.config`. Release builds are
skipped, and another topic cannot pass the merge queue until the controller
atomically publishes the rebuilt `codex` and its matching `meta` state. The
pending commit remains visible to anyone fetching `codex` directly.

## Enable the preview lane

After deploying the updated controller, automation trampoline, and unstable
branch ruleset, initialize `codex-unstable` explicitly:

```sh
Meta/rebuild --local --enable-unstable
```

The controller creates a tree-identical `Initialize codex-unstable` commit
directly on top of `codex`, records the enabled lane in `meta:codex.config`,
and publishes both changes together. The production tip does not change, and
no existing `*-unstable` branch is enrolled. The preview branch now exists as
a pull-request target, is strictly ahead of production, and initially has
exactly the same contents.

Enabling and disabling are explicit, local-only operations; dispatching the
ordinary GitHub Action cannot change whether the lane exists. Once enabled,
both `Meta/rebuild` and `Meta/rebuild --local` maintain the preview lane.

## Add a preview topic

Create the topic from the published `codex`, or from another enrolled preview
topic it depends on:

```sh
git switch -c tb/codex/my-topic-unstable origin/codex
# Edit, test, and commit.
git push -u origin HEAD
```

Pushing this branch does not change `codex-unstable`. Open a pull request from
the topic to `codex-unstable`, obtain the required approval, and select
**Merge when ready**. Its separate one-at-a-time merge queue accepts only a
same-repository `??/codex/*-unstable` topic. Run `Meta/rebuild` or
`Meta/rebuild --local` to authenticate the reviewed merge, enroll the exact
topic head, run staging CI, and publish the rebuilt generation.

While a preview merge is pending, another preview topic cannot pass its merge
queue. Production and preview admission are tracked independently; a single
controller run can consume one pending merge from each lane. An unreviewed
preview branch, including a whole preexisting stack of matching branches,
remains excluded until its own pull request is merged.

Production topics may never depend on preview topics. Root preview topics are
based on `codex`; their prerequisites, when present, must be other enrolled
preview topics. Update, rebase, replace, or reorder a preview topic using the
same ancestry rules as a production topic, substituting `codex` for `master`.
Before retiring a preview prerequisite, restack its children onto a surviving
preview topic or `codex`.

When the lane is no longer needed, first retire every enrolled preview topic,
then explicitly remove the generated branch and its recorded state:

```sh
Meta/rebuild --local --disable-unstable
```

Topic-branch deletion still requires an authorized bypass of the topic ruleset.
Creating a separate inactive copy without removing the enrolled ref does not
retire that topic.

## Update, reorder, or remove a topic

Already enrolled topics remain active across rebuilds. You may push an update
and run the controller directly, or use another reviewed topic pull request
before rebuilding.

Keep topic history explicit. A topic may retain a reviewed merge-shaped DAG,
including fan-in from other enrolled same-lane topics, but never merge either
generated branch into a topic or use GitHub's **Update branch** button on
these pull requests. The controller preserves the reviewed ordered merge
parents and shared ancestry; it does not flatten them into a guessed linear
stack.

For a new topic, the controller infers its nearest enrolled same-lane
topic-tip ancestors, or that lane's root when none exists. The production root
is `master`; the preview root is the exact generated `codex`. After
publication it keeps those recorded edges across prerequisite rewrites. If
sibling topics share private commits, either represent that shared prefix as
an enrolled topic or bring it in through an explicit reviewed non-first-parent
merge. Linear hidden prerequisites and unapproved descendant tips remain
rejected.

You may append, amend, reorder, or drop commits on an existing topic. If it
has dependents, you may leave them at the last published prerequisite tip; the
controller uses the recorded boundary to restack them. To change a topic's
prerequisite, rebase it so the new topic's exact current tip is in its history.
To make it a root topic, rebase it onto the current `master` or `codex`, as
appropriate, and remove the old private prerequisite from its history. Those
exact ancestry changes are the reordering signal; patch similarity and
lexical branch order are never used. If a merge-shaped rewrite conflicts,
the controller stops without moving refs; restack the reviewed graph and run
`Meta/rebuild` again instead of using the linear `resolve`/`continue` path.

Before making a prerequisite inactive, first restack every child onto a
surviving topic in the same lane or that lane's root. The controller refuses
to guess whether the retired topic's commits should be discarded or
transferred to a child.
Deleting or renaming an enrolled active ref explicitly retires it on the next
rebuild; because topic refs are protected against deletion, this requires an
authorized ruleset bypass. Creating a separate `-stale` copy without removing
the enrolled active ref does not retire it.

Every admission pull request must have a same-repository `??/codex/*` head and
target the matching lane: ordinary topics go to `codex`; `-unstable` topics go
to `codex-unstable`. The topic ruleset retains that head after the merge. Do
not delete, force-rewrite, or otherwise change the reviewed head before the
controller rebuilds it. Each lane rejects squash commits, unrelated direct
commits, multiple pending integration merges, octopus integration merges, and
merge-only edits.

## Keep dispatch and admission on the generated branches

GitHub shows **Run workflow** only for a workflow present on the default
branch. Exactly one active `??/codex/automation` topic must therefore be based
directly on `master` and change only `.github/workflows/codex.yml` to this exact
trampoline:

```yaml
name: Refresh codex

on:
  workflow_dispatch:
  pull_request:
    branches:
      - codex
      - codex-unstable
    types:
      - opened
      - reopened
      - synchronize
      - ready_for_review
  merge_group:
    types:
      - checks_requested

permissions:
  actions: read
  contents: read
  pull-requests: read

jobs:
  refresh:
    if: github.event_name == 'workflow_dispatch'
    uses: openai/git/.github/workflows/codex.yml@meta
  admission:
    name: Codex admission
    if: >-
      (github.event_name == 'pull_request' &&
       github.event.pull_request.base.ref == 'codex') ||
      (github.event_name == 'merge_group' &&
       github.event.merge_group.base_ref == 'refs/heads/codex')
    permissions:
      contents: read
      pull-requests: read
    uses: openai/git/.github/workflows/codex-admission.yml@meta
  unstable_admission:
    name: Codex unstable admission
    if: >-
      (github.event_name == 'pull_request' &&
       github.event.pull_request.base.ref == 'codex-unstable') ||
      (github.event_name == 'merge_group' &&
       github.event.merge_group.base_ref == 'refs/heads/codex-unstable')
    permissions:
      contents: read
      pull-requests: read
    uses: openai/git/.github/workflows/codex-admission.yml@meta
```

Each lane's admission job handles both ordinary pull-request checks and
merge-group checks. It accepts a queued merge only while that lane's published
output and `meta` agree, verifies that the group introduces exactly one
eligible reviewed topic, and rejects changes to every GitHub Actions workflow.
The production and preview jobs have separate required-check names. Once the
updated automation topic is published, this exact file remains in both
generated branch trees. The implementations stay on orphan `meta`; no
controller files or custom patches belong on `master`.

## Initialize the published topology once

Normal refreshes fail closed when `meta` has no `codex.config`; they never
infer replacement state silently. For the one-time migration, make a linked
worktree whose path is `Meta`, then run:

```sh
git fetch origin '+refs/heads/*:refs/remotes/origin/*'
git worktree add -b meta Meta origin/meta
Meta/codex initialize
git -C Meta add -N codex.config
git -C Meta diff --check
git -C Meta diff -- codex.config
```

`initialize` pushes nothing. It finds the common published base, reconstructs
the aggregate from the retained topic tips, and writes `Meta/codex.config`
only if that reconstruction has exactly the same tree as the live known-good
`codex`. Commit that file on `meta` only after reviewing the inferred edges.
If the trees differ, first extract every already-shipped patch into an active
topic; do not bless the mismatch. Initialization deliberately accepts the
currently shipped legacy automation file when its tree is known-good; every
normal refresh still requires the automation topic to contain the exact new
trampoline above.

The same entry point supports a local dry run at any time:

```sh
Meta/codex refresh --require-automation
```

It creates a session below the repository's shared Git directory containing
the pinned inputs, update manifest, candidate bundle, and conflict report. It
updates the clone's `origin/*` tracking refs, but it does not update local
branches or refs on GitHub. The low-level `rewrite`, `stage`, and `promote`
commands are also available through `Meta/codex`. Use local refresh for
inspection and conflict recovery. Normal publication uses `Meta/rebuild` or
`Meta/rebuild --local`; use `Meta/publish <run-id>` only to finish a
preparation started through GitHub.

## Refresh the enabled branches

From a clean, complete clone with a linked `Meta` worktree, run:

```sh
Meta/rebuild
```

`Meta/rebuild` updates the clean `Meta` worktree to current `origin/meta`,
dispatches **Refresh codex**, and prints the exact run ID and URL returned by
GitHub. It reports preparation status, validates the successful artifact, and
stages each generated candidate separately: `codex-staging` for production
and, when enabled, `codex-unstable-staging` for preview. It reports staging-CI
job progress and performs one atomic promotion only after every exact
candidate passes. Leave the command running until it reports publication.

To do the rebase and assembly on your machine instead of in the preparation
Action, run:

```sh
Meta/rebuild --local
```

This skips only the preparation Action. It fetches the current heads from
GitHub, prepares the topics, integration commits, enabled output branches,
and the next `codex.config` state in an isolated temporary repository, then
imports and verifies the resulting bundle in the publisher clone. The
temporary repository has its own rerere cache and Git configuration, so an
old local resolution, hook, or concurrent local preparation cannot leak
through shared repository state. The command prints the path of a persistent
local session containing the input snapshot, update manifest, candidate OID,
bundle, and any conflict report.

`--local` does not skip CI or make a private local-only publication. After
preparation, it uses the same user-authenticated staging pushes, waits for a
fresh `main.yml` run for each exact candidate SHA, and performs the same
atomic exact-lease promotion to GitHub. Use `Meta/codex refresh
--require-automation` when you want only a local preview with no server-side
ref update.

Create the linked worktree once if it does not exist:

```sh
git fetch origin '+refs/heads/meta:refs/remotes/origin/meta'
git worktree add --detach Meta refs/remotes/origin/meta
```

If an older `Meta/rebuild` rejects `--local` before it can refresh itself,
update the existing `Meta` worktree once:

```sh
git fetch origin '+refs/heads/meta:refs/remotes/origin/meta'
git -C Meta switch --detach refs/remotes/origin/meta
Meta/rebuild --local
```

After that bootstrap, both rebuild forms refresh `Meta` and re-execute the
new pinned controller automatically.

Both the publishing worktree and `Meta` must be clean. When `Meta/` is nested
in the publishing worktree, the helper permits that linked-worktree directory
but rejects every other change.

To start preparation in the GitHub UI instead, open **Actions > Refresh
codex**, select `codex`, and choose **Run workflow**. After **Rebase topics and
assemble Codex branches** succeeds, finish that exact run from the same kind
of clean clone:

```sh
Meta/publish <run-id>
```

The Action summary prints this command. Prepared artifacts expire after seven
days. `Meta/publish` stays pinned to the controller used by the selected run;
it does not update the `Meta` worktree underneath that run.

Start a fresh `Meta/rebuild` or `Meta/rebuild --local`, using the same mode you
want for the retry, after a preparation, staging, CI, lease, or promotion
failure. The manual alternative is a fresh UI dispatch followed by
`Meta/publish <run-id>`. Do not use **Re-run failed jobs**: a retry must
snapshot the current refs and stage a fresh candidate.

The Action:

1. reads the published enrollment from `meta/codex.config`, verifies at most
   one pending reviewed pull-request merge per enabled lane, and snapshots
   `meta`, `master`, both outputs, their enrolled topics, and any newly
   admitted heads;
2. reads the published boundaries, infers only a newly admitted topic or
   explicitly restacked edges, and rebases topics sequentially in dependency
   order, using rerere resolutions learned from the old `codex`;
3. integrates each enrolled production topic with an explicit merge, then
   integrates enrolled preview topics on top of the exact generated `codex`
   commit; freezes both results without building or executing candidate code;
   and, when state changed, creates a direct child of the pinned `meta` tip
   that changes only `codex.config`;
4. uploads the bundle, pinned input snapshot, update manifest, and canonical
   run metadata as one attempt-specific artifact; and
5. pushes nothing.

With `Meta/rebuild --local`, those preparation steps run in the isolated local
repository instead. There is no Actions run, server artifact, or run-attempt
attestation for that phase. The helper instead pins the exact `Meta` commit,
materializes the controller from that commit, freezes the local session,
checks the complete GitHub input snapshot, verifies the bundle and generated
history, and then relies on the same exact-SHA staging CI and ref leases.
Generated commit OIDs may differ from an Actions preparation because the
local Git version and commit timestamps may differ; the staged candidate is
the exact object that CI verifies.

`Meta/publish` uses the current user's existing `gh` and Git credentials. It
accepts only a successful `workflow_dispatch` run on `openai/git:codex`, the
attempt-specific artifact from that run, and the exact reusable controller
recorded by GitHub for `meta`. It checks the caller SHA against the snapshotted
`codex`, requires the artifact controller to equal `Meta/HEAD`, validates the
ZIP allowlist and bundle heads, and revalidates the complete input snapshot.

Only then does it record the existing CI run IDs and push the exact production
candidate to `codex-staging`. When preview is enabled, it also stages the
exact preview candidate at `codex-unstable-staging`. Each user-authenticated
push starts ordinary CI, including when its candidate changes a workflow file.
The helper binds each candidate to a newer `main.yml` push run whose branch and
SHA match exactly. While waiting, it prints each run URL and reports changes
in status, completed-job count, and failure count, plus a heartbeat every five
minutes when those values do not change.

After every required run and its unique `config` job succeeds, the helper
revalidates the snapshot and atomically updates `meta`, every enrolled topic,
`codex`, and the enabled `codex-unstable` branch with exact leases while
deleting both staging refs. A failed preview build cannot publish production;
a failed production build cannot publish preview.

Every push to `codex` starts the inexpensive release-publication check. The
expensive build and release jobs proceed only when the triggering SHA is the
output recorded on the current `meta` branch. A reviewed pull-request merge
therefore publishes no release; the controller's atomic `codex`/`meta`
promotion does. The check does not require that SHA to remain the live
`codex` tip, so a later pending merge cannot suppress a release that the
controller already triggered. A canonical no-op reuses the existing tips, and
staging never releases. `codex-unstable` also never releases: the release
workflow listens only for pushes to `codex`. Ordinary CI may reuse its own
earlier successful result when the commit or tree is identical.

Until the final push, `meta`, both generated outputs, and all topic refs remain
unchanged. A CI, validation, lease, or promotion failure after staging leaves
the affected staging refs available for inspection. Successful promotion
updates all primary refs and deletes every staging ref as one atomic
transaction.

Git can place server-side leases only on refs included in the push. The
controller therefore refetches `meta`, `master`, both enabled outputs, and the
complete topic namespace immediately before promotion, then places exact
leases on every ref it mutates or deletes in the atomic transaction. The
generated state can therefore never describe a different published generation.
A newly created but unadmitted topic remains excluded; a newly merged topic is
handled by the next verified snapshot.

Both preparation modes use `refs/remotes/origin/master` after fetching the
current `openai/git` heads. They do not use the caller's local `master`
branch, which may be absent or stale.

`master` is a read-only input, so Git's push protocol cannot include it as a
compare-only command in the final ref transaction. The controller verifies it
immediately before the push and checks it again afterward. If `master` moves
in that narrow interval, the published candidate is still the exact tree that
passed staging CI, but it is based on the preceding `master`; the helper prints
a warning and the next refresh advances it. Literal atomic comparison of an
unchanged ref would require server-side transaction support.

## Resolve a rebase conflict

A production-topic conflict leaves every published ref unchanged and prints a
pinned `Meta/codex resolve` command. A failed `Meta/rebuild --local` prints the
persistent session path and leaves the same conflict report there. In either
case, follow the exact commands in that report. For Action preparation, start
from a clean clone that does not already have a `Meta` worktree; the printed
commands create one at the exact controller commit for the failed run:

1. Run the exact fetch, detached checkout, and `resolve` commands from the
   summary. The helper verifies the original snapshot, creates a disposable
   worktree, and stops at the same rebase conflict.
2. Change to the printed worktree and run:

   ```sh
   git status
   git rebase --show-current-patch
   # Edit every conflicted file.
   git add <files>
   git diff --cached --check
   /path/to/Meta/codex continue --worktree .
   ```

3. Use the exact `Meta/codex` path printed by `resolve`. If that command reaches
   another conflict, repeat the edit/add/check sequence and run it again. The
   helper, not a plain
   `git rebase --continue`, creates each resolved commit with the canonical
   Codex committer identity while preserving its original author.
4. Review the rewritten topic tips, then run the printed `publish-topics`
   command. It rechecks the original snapshot and atomically pushes every
   rewritten topic with an exact lease.
5. Run `Meta/rebuild` or `Meta/rebuild --local` to prepare, verify, and publish
   the repaired graph. The manual alternative is a fresh **Actions > Refresh
   codex > Run workflow** dispatch followed by its printed `Meta/publish
   <run-id>` command.

To abandon recovery, run `git rebase --abort` and delete the disposable
worktree. Do not use `git rebase --quit`, push only the first conflicted topic,
add `+` to a failed push, or use an unqualified force push. If a lease fails,
start again from a fresh dispatch.

If topics conflict while the controller assembles `codex`, the graph declared
them independent at that integration point when they are not independent in
practice. Rebase the conflicting topic and its descendants onto the real
prerequisite, push that coherent graph, and start a fresh dispatch. Do not fix
this by merging `codex` into a topic or by maintaining a manual order.

A preview-topic conflict also leaves every published ref unchanged, but the
production-only `resolve`, `continue`, and `publish-topics` commands do not
reconstruct the nested preview lane. Manually restack the affected
`*-unstable` topic and its descendants onto their current prerequisite, push
that coherent topic graph atomically with exact leases, and run
`Meta/rebuild` or `Meta/rebuild --local` again.

## Configure publishing

Publishing needs no repository secret, deploy key, GitHub App, or protected
environment. It uses the publisher's ordinary credentials:

1. Authenticate `gh` as the publishing user. `Meta/rebuild` needs permission
   to dispatch Actions; `Meta/publish` needs permission to read the selected
   run and its artifact. `Meta/rebuild --local` does neither, but it still
   reads the exact staging-CI run and jobs:

   ```sh
   gh auth status
   ```

2. Configure the canonical `origin` with that user's normal Git credentials.
   `Meta/rebuild`, `Meta/rebuild --local`, and `Meta/publish` accept only the
   standard SSH or HTTPS URL for `openai/git`. None reads a token from the
   repository, local session, or artifact.
3. In **Protect generated Codex branch**, **Protect generated unstable Codex
   branch**, and **Protect Codex controller branch**, add an **always** bypass
   for each exact human publisher. The checked-in recipes authorize only the
   `ttaylorr-oai` user (`301000140`) plus the existing organization-admin
   break-glass actor. Update existing rulesets; import a recipe only when its
   matching ruleset is absent.

The bypass is intentionally personal and visible. The Action cannot publish;
it only prepares an immutable artifact. Running `Meta/rebuild`,
`Meta/rebuild --local`, or `Meta/publish` is the approval, and Git records the
configured user as the pusher. To add or remove a publisher, change the exact
`User` actor in each generated-output and controller ruleset. Do not replace
it with a broad repository role or a shared long-lived credential.

The final push runs from the operator's machine. Preparation runs either in
Actions or in the isolated local repository; staging CI still runs in Actions.
The operator's existing Git credentials authorize the atomic ref update.

The built-in `GITHUB_TOKEN` is not a substitute for the local publisher.
[GitHub suppresses push-triggered workflows for pushes made with that
token](https://docs.github.com/en/actions/concepts/security/github_token), so
it would skip both the exact staging CI run and the final release workflow.
Giving the shared GitHub Actions App a ruleset bypass would also authorize it
outside this controller. Moving publication into Actions therefore requires a
separate, narrowly scoped GitHub App credential; until one is provisioned, the
local publisher remains the security and audit boundary.

For an Actions preparation, the local helper downloads the artifact through
`gh`, but pushes through `origin`. Those credentials can theoretically
identify different users, so every publishing path prints the authenticated
`gh` login before staging. Verify the configured Git identity when changing
machines or credentials. A failed CI run leaves its production or preview
staging branch for inspection; neither exposes a publishing secret.

The automation topic is the only topic allowed to change the dispatch and
admission trampoline. A directly merged topic pull request may change neither
that trampoline nor `.github/workflows/codex-release.yml`; otherwise it could
bypass the release guard before the controller runs. Update the enrolled
automation and release topics through a normal controller rebuild instead.
The release trigger remains exactly a push to `codex`, and its workflow may
not mention an environment or the `secrets` context. These checks are not a
sandbox for untrusted build code: review the release topic and its reusable
workflows. The controller rejects other topic-controlled workflow changes.

Rebased topic commits preserve their original authors. Generated commits and
rebase committers use
`chatgpt-codex-connector[bot] <199175422+chatgpt-codex-connector[bot]@users.noreply.github.com>`.
Generated merge and `meta` state commits use that identity as both author and
committer. These commits are deliberately unsigned and do not claim verified
GitHub App authentication. GitHub records the local credential owner as the
pusher. Integration subjects are `Merge <topic> into codex` or
`Merge <topic> into codex-unstable`.

## Repository rulesets

Create or update the repository rulesets to match the checked-in JSON files.
Do not layer a duplicate over an existing matching ruleset: a bypass in one
ruleset does not bypass another applicable ruleset. For a missing ruleset, use
**Settings > Rules > Rulesets > New ruleset > Import a ruleset**.

In `openai/git`, update the existing production, preview, topic, and controller
rulesets in place. Verify that exactly one active policy ruleset covers each
of `codex`, `codex-unstable`, `??/codex/*`, and `meta`.

- `.github/rulesets/codex-topics.json` matches `??/codex/*` and blocks
  deletion, preserving topic heads after pull-request merges.
- `.github/rulesets/codex-branch.json` protects `codex` with pull-request,
  review, deletion, force-push, one-at-a-time merge-queue, and trusted
  admission-check rules. Its exact `ttaylorr-oai` user bypass permits local
  publication; the organization-admin entry remains for break-glass access.
- `.github/rulesets/codex-unstable-branch.json` gives `codex-unstable` the
  same review and one-at-a-time merge-queue protections, but requires the
  distinct **Codex unstable admission / Verify reviewed topic** check. It
  retains the same narrowly scoped publication bypasses.
- `.github/rulesets/codex-meta.json` protects the `meta` controller with
  pull-request, review, deletion, and force-push rules. Its matching exact-user
  bypass lets the same atomic push advance the generated state; the
  organization-admin entry remains for break-glass access.

Each trusted admission check verifies that the pull-request head matches the
eligible `??/codex/*` namespace and belongs to its target lane. Do not require
topic heads to be up to date with either generated branch: the merge queue
checks the proposed merge against the current base without copying the
aggregate into a topic. An actor with an explicit ruleset bypass can still
override the queue; keep publisher bypasses narrow and reserve
organization-admin access for emergencies.

The required check is pinned to the GitHub Actions App, but a repository
ruleset cannot pin the source workflow file. SCM review is therefore still the
boundary for a topic that changes GitHub Actions files. If hostile writers with
workflow-editing access are in scope, add an organization-level required
workflow rule or use a dedicated admission App before enabling this flow.

Deploy these changes in order:

1. Merge the controller, lane-aware trusted admission workflow, and ruleset
   recipe into `meta` without creating a merge commit there.
2. Update the already-enrolled automation topic, then run
   `Meta/rebuild --local` once to publish the exact two-lane trampoline while
   preserving the production release guard and stable merge-queue settings.
3. Update the existing **Protect generated unstable Codex branch** ruleset
   from its recipe, including its separate required check and serial queue.
4. Run `Meta/rebuild --local --enable-unstable` to create the protected,
   strictly-ahead preview target without enrolling any preexisting topic.
5. Open reviewed `*-unstable` pull requests against `codex-unstable`, merge
   them through its queue, and run the controller to publish each generation.

Do not merge a preview pull request until all four setup steps are complete.
