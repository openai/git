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
`promote` commands used by Actions are also available through `Meta/codex`,
but ordinary credentials cannot publish the protected `meta` and `codex`
refs. Use local refresh for inspection and conflict recovery, then use the
Action for the approved staging/CI/atomic-publish path.

## Refresh `codex`

1. Open **Actions > Refresh codex**.
2. Choose **Run workflow**, select `codex`, and run it.

Always start a fresh dispatch after a preparation, staging, CI, lease, or
promotion failure. Do not use **Re-run failed jobs** for those failures: a
retry must snapshot the current refs and stage a fresh candidate.

The reusable controller then:

1. snapshots `meta`, `master`, `codex`, and every active topic;
2. reads the published boundaries from `meta/codex.config`, infers only new or
   explicitly restacked edges, and rebases topics sequentially in dependency
   order, using rerere resolutions learned from the old `codex`;
3. merges the rewritten maximal tips and freezes the result without building
   or executing candidate code, and creates a direct child of the pinned
   `meta` tip that changes only `codex.config`;
4. waits for approval in the `codex-publish` environment;
5. uses the repository deploy key to push the exact candidate to the fixed
   `codex-staging` branch and waits for ordinary full CI on that exact commit;
   and
6. revalidates the snapshot, then atomically updates `meta`, every topic, and
   `codex` with exact leases while deleting `codex-staging`.

The deploy-key staging push starts ordinary push CI, including when a candidate
changes a workflow file. Before pushing, the controller records the largest
matching run ID; it accepts only a newer `main.yml` push run whose branch and
SHA exactly match the staged candidate. The final push to `codex` starts the
existing push-triggered release workflow. A release never runs from staging.
The ordinary CI workflow may reuse its own earlier successful result when the
commit or tree is identical; that is CI's existing redundancy policy.

Until the final push, `meta`, `codex`, and all topic refs remain unchanged. A CI,
validation, lease, or promotion failure after staging leaves `codex-staging`
at the candidate for inspection. Successful promotion updates all primary refs
and deletes staging as one atomic transaction.

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
passed staging CI, but it is based on the preceding `master`; the job prints a
warning and the next refresh advances it. Literal atomic comparison of an
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
   git rebase --continue
   ```

3. Repeat the edit/add/check/continue sequence until the rebase finishes.
4. Run the exact `Meta/codex continue --worktree ...` command printed by the
   helper. If another topic conflicts, resolve it the same way and run
   `continue` again.
5. Review the rewritten topic tips, then run the printed `publish-topics`
   command. It rechecks the original snapshot and atomically pushes every
   rewritten topic with an exact lease.
6. Start a new **Actions > Refresh codex > Run workflow** dispatch to stage the
   result, wait for ordinary CI, and promote it to `codex`.

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

Use one repository-specific SSH deploy key. It is not tied to a person's
GitHub account and needs no organization-level App or token provisioning.
A repository admin can complete the one-time setup if the organization or
enterprise permits deploy keys. If that policy disables new deploy keys, an
organization owner must enable them first:

1. Generate a new Ed25519 key pair used only by `openai/git`:

   ```sh
   umask 077
   ssh-keygen -t ed25519 -N '' \
     -C 'openai/git Codex branch publisher' \
     -f codex-branch-publisher
   ```

2. Under **Settings > Deploy keys**, add `codex-branch-publisher.pub` as
   **Codex branch publisher** and select **Allow write access**.
3. Under **Settings > Environments**, configure `codex-publish` to allow only
   `codex`, add the desired required reviewers, and add the private key from
   `codex-branch-publisher` as the environment secret `CODEX_DEPLOY_KEY`. Allow
   self-review if the person who starts a refresh should also be able to
   approve it; disable self-review to require a second person.
4. Update the existing `codex` ruleset and the `meta` ruleset to match the
   recipes below, adding the deploy-key bypass to both. Import a recipe only
   when that ruleset does not exist yet.
5. Delete both local key files after the environment secret is saved. If setup
   is abandoned, remove any deploy key already added to the repository.

A ruleset can exempt deploy keys only as a class, not by individual key ID.
Keep this as the repository's only deploy key and review **Settings > Deploy
keys** when changing the publisher. The key is long-lived, so rotate it by
replacing both the deploy key and environment secret together.

In the intended flow, only the approved publish job receives the key. It
verifies the frozen bundle, stages it, waits for CI, and performs the
exact-lease promotion; it never checks out or executes candidate code. A
failed CI run leaves `codex-staging` for inspection and removes the private
key from the runner. A fresh dispatch deletes and recreates an identical
staging ref so GitHub emits a new push event.

GitHub environments are repository-wide, not restricted to one workflow.
Treat the `codex-publish` approval as the credential boundary: approve only
the **Stage, verify, and publish codex** job from an expected **Refresh codex**
run. Confirm that the run event is `workflow_dispatch`, its ref is `codex`,
and the controller commit in the preparation summary is the expected `meta`
tip. Display names alone are not sufficient. Reject any other deployment
request for that environment.

Granting the deploy key a bypass on `meta` is an explicit tradeoff of keeping
state beside the controller. GitHub rulesets cannot limit a bypass to
`codex.config`; possession of the key is technically authority to replace any
file on `meta`. The pinned controller verifies that its generated successor is
a direct child changing only a regular `100644` `codex.config`, but that check
does not constrain a stolen key. Keep the key only in the reviewed environment
and keep this repository free of other deploy keys. A separate state-only ref
is the alternative if path-independent controller authority is unacceptable.

The automation topic is the only topic allowed to change the dispatch
trampoline. Other topics may change only
`.github/workflows/codex-release.yml`, whose trigger must remain exactly a push
to `codex` and may not mention an environment or the `secrets` context. That
check is defense in depth, not a sandbox for untrusted workflow code: review
the release topic, including any reusable workflows it calls. The controller
rejects every other topic-controlled workflow change.

Rebased topic commits preserve their original authors. Generated commits and
rebase committers use GitHub's standard `github-actions[bot]` identity. GitHub
records the repository administrator who verified the deploy key when it was
added as the pusher for deploy-key push events. The deploy key and protected
environment are the actual publication authority; the workflow does not claim
to have authenticated as the Codex GitHub App. Integration subjects remain
`Merge <topic> into codex`.

## Repository rulesets

Create or update the repository rulesets to match the three JSON files. Do not
layer a duplicate over an existing matching ruleset: a bypass in the new
ruleset does not bypass another applicable ruleset. For a missing ruleset, use
**Settings > Rules > Rulesets > New ruleset > Import a ruleset**.

In `openai/git`, edit the existing **Protect generated Codex branch** ruleset
to add the deploy-key bypass, keep the existing topic ruleset aligned with its
recipe, and import only the missing `meta` ruleset. Verify that exactly one
active ruleset covers each of `codex`, `??/codex/*`, and `meta`.

- `.github/rulesets/codex-topics.json` matches `??/codex/*` and blocks
  deletion, preserving topic heads after pull-request merges.
- `.github/rulesets/codex-branch.json` protects `codex` with pull-request,
  review, deletion, and force-push rules. Its deploy-key bypass permits the
  approved publisher; the organization-admin entry remains for break-glass
  access.
- `.github/rulesets/codex-meta.json` protects the `meta` controller with
  pull-request, review, deletion, and force-push rules. Its deploy-key bypass
  permits the same approved atomic publisher to advance only the generated
  state during normal operation; the organization-admin entry remains for
  break-glass access.

Rulesets cannot require a pull request head to match `??/codex/*`; reviewers
must enforce that convention. Do not require topic heads to be up to date with
`codex`, because that would copy the generated aggregate into an input.
