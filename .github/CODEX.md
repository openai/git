# Maintaining `codex`

`master` stays equivalent to upstream. The orphan `meta` branch contains the
controller, reusable workflows, tests, documentation, and ruleset recipes.
Never merge `meta` into `master` or `codex`.

Topics use branches named `??/codex/*`, where `??` is a two-character owner
name. The existing rows in `meta:codex.config` stay enrolled. After this
migration, a new branch becomes an active input only after its reviewed pull
request has merged into `codex` and the controller has enrolled it there.
Merely pushing a matching branch never includes it in a build. The `-wip`,
`-stale`, and reserved `-unstable` suffixes cannot enter the production
branch.

The generated `codex.config` records each enrolled topic's prerequisite and
last published tip. Those prerequisite edges form a partial order; there is
no global topic order. Rows are sorted only so the generated file has a
stable representation.

The saved tips are rebase boundaries, not another copy of the patches. They
let a fresh runner distinguish “the prerequisite was rewritten” from “these
are independent topics” after their current tips stop sharing ancestry. This
is what makes amending, dropping, or replacing an already-published commit
safe without relying on a runner's local reflogs.

The generated `codex` history contains one explicit two-parent integration
commit for every active topic, including prerequisites, fast-forwardable
topics, and empty topics. Prerequisites are integrated before their dependents;
lexical order only breaks ties among topics that are ready at the same time.
This order makes the history deterministic but does not add semantic edges to
the topic graph. When the first topic is empty because its tip equals the base,
the controller first creates a tree-identical `Begin codex integration` commit
so that topic can still have two distinct parents.

## Topic branches and pull requests

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

Already enrolled topics remain active across rebuilds. You may push an update
and run the controller directly, or use another reviewed topic pull request
before rebuilding.

Keep topic history linear. Rebase a dependent topic onto its prerequisite;
never merge `codex` into a topic or use GitHub's **Update branch** button on
these pull requests.

For a new topic, the controller infers one prerequisite: its nearest active
topic-tip ancestor, or `master` for a root topic. After publication it keeps
that recorded edge across prerequisite rewrites. If sibling topics share
private commits, create an active topic at that shared prefix and base both
siblings on it. Otherwise the controller rejects the ambiguous overlap.

You may append, amend, reorder, or drop commits on an existing topic. If it
has dependents, you may leave them at the last published prerequisite tip; the
controller uses the recorded boundary to restack them. To change a topic's
prerequisite, rebase it so the new topic's exact current tip is in its history.
To make it a root topic, rebase it onto current `master` and remove the old
private prerequisite from its history. Those exact ancestry changes are the
reordering signal; patch similarity and lexical branch order are never used.

Before making a prerequisite inactive, first restack every child onto a
surviving topic or current `master`. The controller refuses to guess whether
the retired topic's commits should be discarded or transferred to a child.
Deleting or renaming an enrolled active ref explicitly retires it on the next
rebuild; because topic refs are protected against deletion, this requires an
authorized ruleset bypass. Creating a separate `-stale` copy without removing
the enrolled active ref does not retire it.

Every admission pull request must have a same-repository `??/codex/*` head
and target `codex`. The topic ruleset retains that head after the merge. Do
not delete, force-rewrite, or otherwise change the reviewed head before the
controller rebuilds it. The controller rejects squash commits, unrelated
direct commits, multiple pending merges, octopus merges, and merge-only edits.

## Keep the dispatch and admission workflows on `codex`

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
    if: github.event_name == 'pull_request' || github.event_name == 'merge_group'
    permissions:
      contents: read
      pull-requests: read
    uses: openai/git/.github/workflows/codex-admission.yml@meta
```

The admission job handles both ordinary pull-request checks and merge-group
checks. It accepts a queued merge only while the published output and `meta`
agree, verifies that the group introduces exactly one eligible reviewed topic,
and rejects changes to the trusted dispatch or release workflows. The
controller accepts the old dispatch-only trampoline during rollout; once the
updated automation topic is published, this exact file remains in every
generated `codex` tree. Both implementations stay on orphan `meta`. No
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

## Refresh `codex`

From a clean, complete clone with a linked `Meta` worktree, run:

```sh
Meta/rebuild
```

`Meta/rebuild` updates the clean `Meta` worktree to current `origin/meta`,
dispatches **Refresh codex**, and prints the exact run ID and URL returned by
GitHub. It reports preparation status, validates the successful artifact,
pushes the candidate to `codex-staging`, reports staging-CI job progress, and
performs the atomic promotion only after that exact candidate passes. Leave
the command running until it reports the published candidate.

To do the rebase and assembly on your machine instead of in the preparation
Action, run:

```sh
Meta/rebuild --local
```

This skips only the preparation Action. It fetches the current heads from
GitHub, prepares the topics, integration commits, `codex`, and the next
`codex.config` state in an isolated temporary repository, then imports and
verifies the resulting bundle in the publisher clone. The temporary
repository has its own rerere cache and Git configuration, so an old local
resolution, hook, or concurrent local preparation cannot leak through shared
repository state. The command prints the path of a persistent local session
containing the input snapshot, update manifest, candidate OID, bundle, and any
conflict report.

`--local` does not skip CI or make a private local-only publication. After
preparation, it uses the same user-authenticated `codex-staging` push, waits
for the same fresh `main.yml` run for the exact candidate SHA, and performs
the same atomic exact-lease promotion to GitHub. Use `Meta/codex refresh
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
assemble codex** succeeds, finish that exact run from the same kind of clean
clone:

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

1. reads the published enrollment from `meta/codex.config`, verifies any one
   pending reviewed pull-request merge, and snapshots `meta`, `master`,
   `codex`, the enrolled topics, and the newly admitted topic if present;
2. reads the published boundaries, infers only a newly admitted topic or
   explicitly restacked edges, and rebases topics sequentially in dependency
   order, using rerere resolutions learned from the old `codex`;
3. integrates every active topic at its rewritten tip with an explicit merge
   commit and freezes the result without building or executing candidate code,
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

Only then does it record the existing CI run ID and push the exact candidate
to the fixed `codex-staging` branch. That user-authenticated push starts
ordinary push CI, including when the candidate changes a workflow file. The
helper binds to a newer `main.yml` push run whose branch and SHA exactly match
the staged candidate. While it waits, it prints the run URL and reports changes
in status, completed-job count, and failure count, plus a heartbeat every five
minutes when those values do not change. After the full run and its unique
`config` job succeed, it revalidates the snapshot and atomically updates
`meta`, every topic, and `codex` with exact leases while deleting
`codex-staging`.

Every push to `codex` starts the inexpensive release-publication check. The
expensive build and release jobs proceed only when the triggering SHA is the
output recorded on the current `meta` branch. A reviewed pull-request merge
therefore publishes no release; the controller's atomic `codex`/`meta`
promotion does. The check does not require that SHA to remain the live
`codex` tip, so a later pending merge cannot suppress a release that the
controller already triggered. A canonical no-op reuses the existing tips, and
staging never releases. Ordinary CI may reuse its own earlier successful
result when the commit or tree is identical.

Until the final push, `meta`, `codex`, and all topic refs remain unchanged. A
CI, validation, lease, or promotion failure after staging leaves
`codex-staging` at the candidate for inspection. Successful promotion updates
all primary refs and deletes staging as one atomic transaction.

Git can place server-side leases only on refs included in the push. The
controller therefore refetches `meta`, `master`, `codex`, and the complete
topic namespace immediately before promotion, then places exact leases on
every ref it mutates or deletes in the atomic transaction. The generated
state can therefore never describe a different published generation. A new
input created in the final fetch-to-push window is handled by the next run.

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

A failed Action summary says **No refs were updated** and prints a pinned
`Meta/codex resolve` command. A failed `Meta/rebuild --local` prints the
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
3. In the existing **Protect generated Codex branch** ruleset and the
   **Protect Codex controller branch** ruleset, add an **always** bypass for
   each exact human publisher. The checked-in recipes authorize only the
   `ttaylorr-oai` user (`301000140`) plus the existing organization-admin
   break-glass actor. Import the `meta` recipe only if that ruleset is absent.

The bypass is intentionally personal and visible. The Action cannot publish;
it only prepares an immutable artifact. Running `Meta/rebuild`,
`Meta/rebuild --local`, or `Meta/publish` is the approval, and Git records the
configured user as the pusher. To add or remove a publisher, change the exact
`User` actor in both rulesets. Do not replace it with a broad repository role
or a shared long-lived credential.

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
machines or credentials. A failed CI run leaves `codex-staging` for
inspection; it exposes no publishing secret.

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
pusher. Integration subjects remain `Merge <topic> into codex`.

## Repository rulesets

Create or update the repository rulesets to match the three JSON files. Do not
layer a duplicate over an existing matching ruleset: a bypass in the new
ruleset does not bypass another applicable ruleset. For a missing ruleset, use
**Settings > Rules > Rulesets > New ruleset > Import a ruleset**.

In `openai/git`, edit the existing **Protect generated Codex branch** ruleset
to add the exact-user publisher bypass, keep the existing topic ruleset aligned
with its recipe, and import only the missing `meta` ruleset. Verify that exactly
one active ruleset covers each of `codex`, `??/codex/*`, and `meta`.

- `.github/rulesets/codex-topics.json` matches `??/codex/*` and blocks
  deletion, preserving topic heads after pull-request merges.
- `.github/rulesets/codex-branch.json` protects `codex` with pull-request,
  review, deletion, force-push, one-at-a-time merge-queue, and trusted
  admission-check rules. Its exact `ttaylorr-oai` user bypass permits local
  publication; the organization-admin entry remains for break-glass access.
- `.github/rulesets/codex-meta.json` protects the `meta` controller with
  pull-request, review, deletion, and force-push rules. Its matching exact-user
  bypass lets the same atomic push advance the generated state; the
  organization-admin entry remains for break-glass access.

The trusted admission check verifies that the pull-request head matches the
eligible `??/codex/*` namespace. Do not require topic heads to be up to date
with `codex`: the merge queue checks the proposed merge against the current
base without copying the generated aggregate into a topic. An actor with an
explicit ruleset bypass can still override the queue; keep publisher bypasses
narrow and reserve organization-admin access for emergencies.

The required check is pinned to the GitHub Actions App, but a repository
ruleset cannot pin the source workflow file. SCM review is therefore still the
boundary for a topic that changes GitHub Actions files. If hostile writers with
workflow-editing access are in scope, add an organization-level required
workflow rule or use a dedicated admission App before enabling this flow.

Deploy these changes in order:

1. Merge the new controller and admission workflow into `meta`.
2. Update the enrolled automation and release topics, then run
   `Meta/rebuild --local` once to publish the new trampoline and release guard.
3. Update the existing `codex` ruleset from its checked-in recipe to require
   the one-at-a-time merge queue and trusted admission check.

Do not merge a new topic pull request before all three steps are complete.
