# Maintaining `codex`

`master` stays equivalent to upstream. The orphan `meta` branch contains the
controller, reusable workflows, tests, documentation, and ruleset recipes.
Never merge `meta` into `master` or `codex`.

The active inputs are every branch matching `??/codex/*`, where `??` is a
two-character owner name. A `-wip` or `-stale` suffix makes a branch inactive.
The generated `codex.config` on `meta` records one prerequisite and the last
published tip for each active topic. The prerequisite edges form a partial
order; there is no global topic order. Rows are sorted only so the generated
file has a stable representation.

The saved tips are rebase boundaries, not another copy of the patches. They
let a fresh runner distinguish “the prerequisite was rewritten” from “these
are independent topics” after their current tips stop sharing ancestry. This
is what makes amending, dropping, or replacing an already-published commit
safe without relying on a runner's local reflogs.

## Topic branches and pull requests

Create a topic from `master`, or from the topic it depends on:

```sh
git switch -c tb/codex/my-topic origin/master
# Edit, test, and commit.
git push -u origin HEAD
```

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

A topic may be the head of a pull request whose base is `codex`. Use a
same-repository `??/codex/*` head. The topic ruleset keeps these branches after
their pull requests are merged. Run a refresh before force-rewriting a topic
whose pull request was merged directly into `codex`: commits above the last
recorded output must still be reachable from an active topic. A clean merge or
fast-forward from a retained topic is accepted; squash commits, unrelated
direct commits, octopus merges, and merge-only edits must first be extracted
into an active topic.

## Keep the dispatch workflow on `codex`

GitHub shows **Run workflow** only for a workflow present on the default
branch. Exactly one active `??/codex/automation` topic must therefore be based
directly on `master` and change only `.github/workflows/codex.yml` to this exact
trampoline:

```yaml
name: Refresh codex

on: workflow_dispatch

permissions:
  actions: read
  contents: read

jobs:
  refresh:
    uses: openai/git/.github/workflows/codex.yml@meta
```

The controller enforces that exact file. It remains in each generated `codex`
tree, while the implementation stays on orphan `meta`. No controller files or
custom patches belong on `master`.

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
does not update local or remote refs. The low-level `rewrite`, `stage`, and
`promote` commands are also available through `Meta/codex`. Use local refresh
for inspection and conflict recovery. Normal publication starts with the
Action and finishes through the pinned `publish-run` command described below.

## Refresh `codex`

1. Open **Actions > Refresh codex**.
2. Choose **Run workflow**, select `codex`, and run it.
3. When **Rebase topics and assemble codex** succeeds, run the exact command
   printed in its summary from a clean clone with a current `Meta` worktree:

   ```sh
   Meta/codex publish-run <run-id>
   ```

   If the clone does not already have that linked worktree, create it once:

   ```sh
   git fetch origin '+refs/heads/meta:refs/remotes/origin/meta'
   git worktree add --detach Meta refs/remotes/origin/meta
   ```

   An existing `Meta` worktree must be clean and at the controller commit shown
   in the run summary. When `Meta/` is nested in the caller, the helper permits
   that one linked-worktree directory but rejects every other caller change.
   Prepared artifacts expire after seven days.

Always start a fresh dispatch after a preparation, staging, CI, lease, or
promotion failure. Do not use **Re-run failed jobs** for those failures: a
retry must snapshot the current refs and stage a fresh candidate.

The Action:

1. snapshots `meta`, `master`, `codex`, and every active topic;
2. reads the published boundaries from `meta/codex.config`, infers only new or
   explicitly restacked edges, and rebases topics sequentially in dependency
   order, using rerere resolutions learned from the old `codex`;
3. merges the rewritten maximal tips and freezes the result without building
   or executing candidate code, and creates a direct child of the pinned
   `meta` tip that changes only `codex.config`;
4. uploads the bundle, pinned input snapshot, update manifest, and canonical
   run metadata as one attempt-specific artifact; and
5. pushes nothing.

`publish-run` uses the current user's existing `gh` and Git credentials. It
accepts only a successful `workflow_dispatch` run on `openai/git:codex`, the
attempt-specific artifact from that run, and the exact reusable controller
recorded by GitHub for `meta`. It checks the caller SHA against the snapshotted
`codex`, requires the artifact controller to equal `Meta/HEAD`, validates the
ZIP allowlist and bundle heads, and revalidates the complete input snapshot.

Only then does it record the existing CI run ID and push the exact candidate
to the fixed `codex-staging` branch. That user-authenticated push starts
ordinary push CI, including when the candidate changes a workflow file. The
helper accepts only a newer `main.yml` push run whose branch and SHA exactly
match the staged candidate, requires that full run and its `config` job to
succeed, then revalidates the snapshot and atomically updates `meta`, every
topic, and `codex` with exact leases while deleting `codex-staging`.

The final push to `codex` starts the existing push-triggered release workflow.
A release never runs from staging. The ordinary CI workflow may reuse its own
earlier successful result when the commit or tree is identical; that is CI's
existing redundancy policy.

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

`master` is a read-only input, so Git's push protocol cannot include it as a
compare-only command in the final ref transaction. The controller verifies it
immediately before the push and checks it again afterward. If `master` moves
in that narrow interval, the published candidate is still the exact tree that
passed staging CI, but it is based on the preceding `master`; the helper prints
a warning and the next refresh advances it. Literal atomic comparison of an
unchanged ref would require server-side transaction support.

## Resolve a rebase conflict

The failed run summary says **No refs were updated** and prints a pinned
`Meta/codex resolve` command. Start from a clean clone that does not already
have a `Meta` worktree; the printed commands create one at the exact controller
commit for the failed run:

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
5. Start a new **Actions > Refresh codex > Run workflow** dispatch to prepare
   a publishable artifact; then run the printed `publish-run` command to stage,
   verify, and promote it to `codex`.

To abandon recovery, run `git rebase --abort` and delete the disposable
worktree. Do not use `git rebase --quit`, push only the first conflicted topic,
add `+` to a failed push, or use an unqualified force push. If a lease fails,
start again from a fresh dispatch.

If maximal topics conflict while the controller assembles `codex`, the topics
were declared independent by ancestry but are not independent in practice.
Rebase the conflicting topic and its descendants onto the real prerequisite,
push that coherent graph, and start a fresh dispatch. Do not fix this by
merging `codex` into a topic or by maintaining a manual order.

## Configure publishing

Publishing needs no repository secret, deploy key, GitHub App, or protected
environment. It uses the publisher's ordinary credentials:

1. Authenticate `gh` as the publishing user and make sure that account can
   read Actions runs and artifacts for `openai/git`:

   ```sh
   gh auth status
   ```

2. Configure the canonical `origin` with that user's normal Git credentials.
   `Meta/codex publish-run` accepts only the standard SSH or HTTPS URL for
   `openai/git`; it never reads a token from the repository or artifact.
3. In the existing **Protect generated Codex branch** ruleset and the
   **Protect Codex controller branch** ruleset, add an **always** bypass for
   each exact human publisher. The checked-in recipes authorize only the
   `ttaylorr-oai` user (`301000140`) plus the existing organization-admin
   break-glass actor. Import the `meta` recipe only if that ruleset is absent.

The bypass is intentionally personal and visible. The Action cannot publish;
it only prepares an immutable artifact. Running `publish-run` is the approval
and Git records the configured user as the pusher. To add or remove a
publisher, change the exact `User` actor in both rulesets. Do not replace it
with a broad repository role or a shared long-lived credential.

The local helper downloads the artifact through `gh`, but pushes through
`origin`. Those credentials can theoretically identify different users, so
the helper prints the authenticated `gh` login before staging. Verify the
configured Git identity when changing machines or credentials. A failed CI
run leaves `codex-staging` for inspection; it exposes no publishing secret.

The automation topic is the only topic allowed to change the dispatch
trampoline. Other topics may change only
`.github/workflows/codex-release.yml`, whose trigger must remain exactly a push
to `codex` and may not mention an environment or the `secrets` context. That
check is defense in depth, not a sandbox for untrusted workflow code: review
the release topic, including any reusable workflows it calls. The controller
rejects every other topic-controlled workflow change.

Rebased topic commits preserve their original authors. Generated commits and
rebase committers use
`ChatGPT Codex Connector <199175422+chatgpt-codex-connector[bot]@users.noreply.github.com>`.
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
  review, deletion, and force-push rules. Its exact `ttaylorr-oai` user bypass
  permits local publication; the organization-admin entry remains for
  break-glass access.
- `.github/rulesets/codex-meta.json` protects the `meta` controller with
  pull-request, review, deletion, and force-push rules. Its matching exact-user
  bypass lets the same atomic push advance the generated state; the
  organization-admin entry remains for break-glass access.

Rulesets cannot require a pull request head to match `??/codex/*`; reviewers
must enforce that convention. Do not require topic heads to be up to date with
`codex`, because that would copy the generated aggregate into an input.
