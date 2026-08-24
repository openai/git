# Maintaining `codex` and `codex-unstable`

`master` stays equivalent to upstream. `codex` is the production Git
branch distributed with Codex. `codex-unstable` starts from the exact
generated `codex` commit and adds preview topics.

Both lane branches are outputs. Do not merge topic pull requests into them or
push ordinary updates to them. The orphan `meta` branch is the source of
truth and contains the controller, reusable workflows, ruleset recipes, and
two ordered desired-state files:

- `codex.plan` for production;
- `codex-unstable.plan` for preview.

Each plan row names a topic ref, its exact admitted source SHA, the source
boundary used to replay it, and one prerequisite. The controller retains each
admitted source object at `refs/heads/codex-pins/<sha>`. A mutable topic ref
may advance later; that does not change a published generation until another
approved plan transition pins the new head.

`codex.config` is the realized ledger. Version 3 records the plan blob,
source pins, generated topic tips, and lane output tips produced by the last
successful rebuild. Plans say what should be built; `codex.config` says what
was built.

## The review policy

Topics are named `??/codex/*`, where `??` is a two-character owner name.
Only names ending in `-unstable` belong in `codex-unstable`; all other
active topics belong in `codex`.

| Change | Human review | Bot action | Plan effect |
| --- | --- | --- | --- |
| Add | Review the topic PR against its lane | Pin its current head and open a plan PR | Append one topic with its uniquely inferred prerequisite |
| Alter | Keep the topic PR approved against its lane | Pin its current head and open a plan PR | Replace only that topic's source SHA and source boundary |
| Remove | Review the generated plan PR | Open a plan PR from the explicit workflow dispatch | Delete one plan row |
| Reorder | Review the generated plan PR | Open a plan PR from the explicit workflow dispatch | Move one existing row; keep its SHA, boundary, and prerequisite |

An add or alter has one human decision: the topic PR. The pull request is
review-only because the output-lane rulesets reject ordinary updates. When an
approval is submitted, a scheduled scanner on the trusted default branch
notices the approved topic and freezes its current head before running the
plan producer. Operators can dispatch the same scan immediately when waiting
five minutes is undesirable. That trusted run:

1. rechecks that the PR is open, same-repository, non-draft, aimed at the
   matching lane, and overall `APPROVED`;
2. requires an effective approval from a different repository writer;
3. asks the dedicated plan App to create immutable pins and a
   `codex-plan/*` branch;
4. opens a one-row plan PR against `meta`; and
5. runs the trusted admission check, which rechecks the topic approval and
   gives the mechanical plan approval.

An approval remains effective across later topic updates unless it is
dismissed or the reviewer supersedes it with a request for changes. The plan PR
auto-merges with rebase after its required check passes. If the topic head
changes before that happens, the pinned-head check fails; the next scan can
reuse the effective approval and create a new pin and plan transition. Once
the plan merges, the immutable pin remains authoritative even if the source
branch moves.

After publication, the publisher closes a review-only topic PR only when its
head still matches both the approved plan and the published source pin. A
rebased topic may not appear verbatim in the generated lane, so GitHub shows
that PR as closed rather than merged. Staging alone never closes a PR, and a
closure failure cannot undo an otherwise successful publication. A later
change to the same topic needs another topic PR.

## Pull request labels

Topic pull requests are review-only: approve them, but do not merge them.
Automatic add/alter plans, human remove/reorder plans, and ordinary controller
changes are distinct `meta` changes. Every open PR against `codex`,
`codex-unstable`, or `meta`, plus retained plan history, receives one role,
one build, and one lifecycle state:

- `kind:review-only`, `kind:auto-plan`, `kind:plan-policy`, or
  `kind:controller` identifies why the PR exists.
- `build:codex-stable`, `build:codex-unstable`, or
  `build:codex-controller` identifies what it affects.
- `codex:draft`, `codex:needs-review`, `codex:ready`,
  `codex:awaiting-plan`, `codex:planned`, `codex:staged`,
  `codex:integrated`, or `codex:superseded` identifies its lifecycle state.
- `codex:blocked` is additional when an invalid topic name, failed admission,
  merge conflict, or merge policy prevents the PR from advancing.

Labels are derived presentation, not admission or release policy. A topic is
planned only when its exact current head is recorded in its build plan, and
integrated only when `codex.config` records that same source head and its
output tip matches the live build branch. Staging a rebased topic requires
the frozen generation's verified candidate ledger; a rewritten integration
commit is not confused with the reviewed source commit. A moved source head
falls back to review or admission instead of inheriting an earlier state. The
reconciler refuses missing, duplicate, or contradictory classifications before
writing any labels.

The trusted default-branch scanner refreshes labels periodically. The local
publisher refreshes them after each candidate is staged and again after
atomic promotion; presentation failures warn but never change publication.
To inspect the current projection without changing labels:

```sh
Meta/codex reconcile-pr-state --dry-run
```

Remove and reorder are policy decisions rather than projections of a reviewed
topic head. Run **Actions > Refresh codex > Run workflow** with
`operation=remove` or `operation=reorder`; the resulting plan PR needs the
ordinary human `meta` review. For reorder, supply `after=root` or an
existing same-lane topic.

The controller rejects an ambiguous add, an alter that changes prerequisite
or order, a reorder that changes the source boundary, a missing prerequisite,
more or fewer than one automation topic, and any topic that changes protected
controller or workflow paths. A prerequisite change is deliberately not an
alter: retire and re-add the topic under a newly reviewed ancestry, or extend
the policy explicitly.

## Day-to-day commands

Start a production topic from `master`, or from its intended production
prerequisite:

```sh
git switch -c tb/codex/my-topic origin/master
# Edit, test, and commit.
git push -u origin HEAD
```

Start a preview topic from the published production lane, or from its intended
preview prerequisite:

```sh
git switch -c tb/codex/my-topic-unstable origin/codex
# Edit, test, and commit.
git push -u origin HEAD
```

Open the topic PR against `codex` or `codex-unstable` and obtain approval.
Do not click merge; the output branch cannot accept it. The next trusted
scan creates the pinned plan PR automatically.

For a local diagnostic of the same projection:

```sh
Meta/codex propose-plan --remote origin \
  --lane codex-unstable \
  --topic tb/codex/my-topic-unstable \
  --source-tip <full-current-sha> \
  --review-pr <topic-pr-number> \
  --action auto --no-push
```

For an explicit policy PR from the command line:

```sh
Meta/codex propose-plan --remote origin \
  --lane codex --topic tb/codex/my-topic \
  --action reorder --after root

Meta/codex propose-plan --remote origin \
  --lane codex --topic tb/codex/my-topic \
  --action remove
```

After a plan change lands, publish the new generation:

```sh
Meta/rebuild
# or run preparation locally:
Meta/rebuild --local
# or resume the printed frozen local session:
Meta/rebuild --resume <session-directory>
```

Both forms prepare an immutable snapshot, build and verify each candidate,
stage exact SHAs, wait for fresh staging CI, and atomically promote
`meta`, `codex`, and the enabled `codex-unstable` output with leases.
`Meta/codex refresh --require-automation` is a local preview only; it pushes
nothing.

Local preparation keeps the candidate bundle, input snapshot, and update
manifest in the printed session. A resumed release revalidates those exact
files and live inputs instead of rebuilding them. Existing staging refs reuse
their exact in-progress or successful CI run, and stable and unstable staging
start before either wait begins so their CI can run concurrently. An actual CI
failure still needs a successful rerun of that same run or a new candidate;
resume never treats failed CI as valid. Each attempt appends phase and total
durations to `codex-timings` in the session directory.

If a replay conflicts, the controller leaves published refs unchanged and
prints the pinned recovery command. Resolve only in that disposable worktree,
then run the printed `continue` and `publish-topics` commands. For pinned
plans, `publish-topics` keeps source refs immutable and freezes the verified
candidate, inputs, updates, and bundle in a local recovery session; stage
that exact session with `Meta/rebuild --resume`, wait for fresh staging CI,
and promote it atomically. For
a pinned merge-shaped source, the controller uses its reviewed `source-base`
as the exact old root and preserves the DAG across a moved generated base
only when the two changed-path sets are disjoint. A linear dependent topic
can extend that graph when its reviewed boundary is the exact pinned source
tip of a prerequisite already rooted in the graph. An overlapping base move,
an unrelated boundary, or another merge-shaped source with a different
reviewed root fails closed; restack the approved topic and pin its new head
instead of flattening or guessing.

## Required automation topic

Exactly one stable topic named `??/codex/automation` must be based directly
on `master` and change only `.github/workflows/codex.yml`. Its canonical
default-branch trampoline:

- dispatches ordinary refresh;
- scans approved topic PRs from the trusted default branch and creates
  one automatic add/alter proposal at a time;
- reconciles derived PR labels from the trusted `meta` controller;
- offers explicit remove/reorder dispatch inputs; and
- runs plan admission through `pull_request_target` while loading the
  reusable implementation from `meta`.

The reusable plan workflows stay on `meta`; the default branch contains only
that trampoline. During migration, the controller accepts the previous
trampoline as published history, but it refuses the first v3 refresh until the
plan pins the current trampoline.

The label-aware trampoline is a backward-compatible upgrade: the already
published pinned-plan trampoline remains valid while its reviewed automation
topic is updated. Once the label-aware trampoline is published, moving back to
the earlier version is rejected.

No topic merge ref runs the pinning path. The default-branch scanner checks
each open approved PR with the trusted `meta` controller, skips tips already
present in the active plans or represented by an open plan PR, and only then
calls the reusable producer from `meta`. The producer revalidates the exact
approval again before it writes a pin or plan branch.

## One-time v2 to v3 rollout

Do not commit `codex.plan` or `codex-unstable.plan` in the controller PR.
They must be created together with their immutable pins by the bootstrap
transaction.

Roll out in this order:

1. Land the controller, reusable plan workflows, docs, and ruleset recipes on
   `meta`, without plan files and without enabling the new meta, output-lane,
   plan-branch, or pin-creation rulesets.
2. Enable only `codex-pins-immutable.json`. It blocks update and deletion
   while still allowing the bootstrap transaction to create new pins.
3. Update and push the `??/codex/automation` source branch to the exact new
   trampoline.
4. From a clean publisher clone, run one explicit pre-v3 bootstrap alter for
   the automation topic, then one for each other already-published topic whose
   source SHA is intentionally being overridden. Do not refresh between these
   commits.
5. Run one rebuild and publish. That writes version 3 `codex.config` and
   closes the bootstrap path.
6. Provision the plan App and environment, seed one harmless plan-admission
   check run, then activate the pin-creation, plan-branch, `meta`, and
   output-lane rulesets.
7. Smoke-test one automatic add or alter and one explicit remove or reorder.

The pre-v3 command is intentionally narrow. It may only alter a topic already
present in v1/v2 published state, records the exact authorization in commit
trailers, creates pins and `meta` in one atomic push, and may continue only
from the immediately preceding bootstrap commit while `codex.config` is
still v1/v2:

```sh
Meta/codex propose-plan --remote origin \
  --lane codex \
  --topic tb/codex/automation \
  --source-tip <full-new-automation-sha> \
  --action alter \
  --bootstrap-authorization '<explicit authorization>'

Meta/codex propose-plan --remote origin \
  --lane codex-unstable \
  --topic tb/codex/status-preview-unstable \
  --source-tip <full-approved-bootstrap-sha> \
  --action alter \
  --bootstrap-authorization '<explicit authorization>'
```

Bootstrap is a deployment exception performed before the pin-creation
ruleset is active. The immutable-pin rule must already be active, so an
earlier bootstrap commit cannot lose one of its retained objects while the
next direct transition is prepared. After the first v3 publication, ordinary
topic approval or explicit plan review is required.

The checked-in `codex.release-recovery` file is a one-shot rollout
exception for the release-metadata commit that landed after the v2 snapshot
but before this first v3 publication. After landing its controller support,
run:

```sh
Meta/codex recover-release-pin --remote origin \
  --expected-meta <exact-post-controller-meta-sha> \
  --authorization '<explicit authorization>'
```

The command accepts only the exact reviewed manifest: unchanged v3 plan
blobs from the recorded baseline, the `ba107` to `40589` release step, merged
PR #22, an absent new pin, and an unchanged release row shape. It atomically
creates that one pin, changes only `codex.plan`, and deletes the manifest.
Once used, it cannot authorize another transition.

## Repository settings

Apply the checked-in ruleset recipes after the v3 publication:

- `codex-branch.json` and `codex-unstable-branch.json` make generated lanes
  output-only; only the narrow publisher and organization-admin break-glass
  actors bypass them.
- `codex-pins.json` lets only the dedicated plan App create
  `codex-pins/*`; `codex-pins-immutable.json` lets only break-glass update
  or delete them.
- `codex-plan-branches.json` lets only the dedicated plan App write
  `codex-plan/*`.
- `codex-meta.json` keeps one ordinary review, stale-review dismissal,
  last-push approval, and the required
  **Codex plan admission / Verify pinned manifest** check. The plan App has no
  `meta` bypass.

The dedicated App is integration `1144995` and needs Contents and Pull
requests write for `openai/git`. Store its private key only in the
`codex-plan` environment and restrict that environment to the trusted
`refs/heads/codex` caller. Enable repository auto-merge and allow GitHub Actions
to approve pull requests; otherwise the mechanical add/alter approval cannot
complete.

GitHub only offers a required check source after it has run recently. After
publishing the new trampoline, run a harmless `meta` PR once and verify the
exact check context before activating the new `meta` ruleset.

The local publisher remains the only actor that promotes generated outputs.
Its staging and promotion path uses exact SHA checks and atomic leases. Do not
replace it with a shared `GITHUB_TOKEN`; pushes made with that token do not
trigger the staging and release workflows needed by this design.

## Releases

Release jobs run only for the exact lane output recorded in the current
`meta:codex.config`. A topic PR, plan PR, staging ref, or stale output SHA
does not publish a release. Stable and unstable promotions may happen in one
atomic transaction, but each lane gets its own release matrix.

An unstable release records both
`source_ref=refs/heads/codex-unstable` and its exact `source_sha` in the
release body. New releases therefore say plainly that they came from the
unstable lane.
