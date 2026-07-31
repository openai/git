# Maintaining `codex`

`master` stays equivalent to upstream. The orphan `meta` branch contains the
controller, reusable workflows, tests, documentation, and ruleset recipes.
Never merge `meta` into `master` or `codex`.

The active inputs are every branch matching `??/codex/*`, where `??` is a
two-character owner name. A `-wip` or `-stale` suffix makes a branch inactive.
The commit graph supplies the dependency order; there is no topic list, order
file, or other maintained state.

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

The controller infers one prerequisite for each topic: its nearest active
topic-tip ancestor, or `master` for a root topic. If sibling topics share
private commits, create an active topic at that shared prefix and base both
siblings on it. Otherwise the controller rejects the ambiguous overlap.

A topic may be the head of a pull request whose base is `codex`. Use a
same-repository `??/codex/*` head. The topic ruleset keeps these branches after
their pull requests are merged.

## Keep the dispatch workflow on `codex`

GitHub shows **Run workflow** only for a workflow present on the default
branch. Exactly one active `??/codex/automation` topic must therefore be based
directly on `master` and change only `.github/workflows/codex.yml` to this
exact trampoline:

```yaml
name: Refresh codex

on: workflow_dispatch

permissions:
  contents: read

jobs:
  refresh:
    uses: openai/git/.github/workflows/codex.yml@meta
    secrets: inherit
```

The controller enforces that exact file. It remains in each generated `codex`
tree, while the implementation stays on orphan `meta`. No controller files or
custom patches belong on `master`.

## Refresh `codex`

1. Open **Actions > Refresh codex**.
2. Choose **Run workflow**, select `codex`, and run it.

Always start a fresh dispatch. Do not use **Re-run failed jobs**: a retry must
snapshot the current refs and stage a fresh candidate.

The reusable controller then:

1. snapshots `meta`, `master`, `codex`, and every active topic;
2. infers dependencies from ancestry and rebases ready topics in parallel
   topological waves, using rerere resolutions learned from the old `codex`;
3. merges the rewritten maximal tips and runs the controller tests;
4. uses `CODEX_BRANCH_TOKEN` to push the exact candidate to the fixed
   `codex-staging` branch;
5. waits for the ordinary full CI workflow to succeed for that exact staging
   commit;
6. fans out one API-only validation square per topic; and
7. revalidates the snapshot, then atomically updates every topic and `codex`
   with exact leases while deleting `codex-staging` in the same push.

The topic squares do not check out or execute candidate code. They read refs
and compare commits through the GitHub API, verifying the live topic tip, its
rewritten prerequisite, and its containment in the exact staging candidate.
The ordinary CI workflow may reuse its own earlier successful result when the
commit or tree is identical; that is CI's existing redundancy policy.

Until the final push, `codex` and all topic refs remain unchanged. A CI,
validation, lease, or promotion failure after staging leaves `codex-staging`
at the candidate for inspection. Successful promotion updates all primary refs
and deletes staging as one atomic transaction.

Git can place server-side leases only on refs included in the push. The
controller therefore refetches `meta`, `master`, `codex`, and the complete
topic namespace immediately before promotion, then places exact leases on
every ref it mutates or deletes in the atomic transaction. A new input created
in the final fetch-to-push window is handled by the next run.

## Resolve a rebase conflict

The failed run summary says **No refs were updated** and prints a pinned
`codex-branch resolve` command. From a clean clone:

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
4. Run the exact `codex-branch continue --worktree ...` command printed by the
   helper. If another topic conflicts, resolve it the same way and run
   `continue` again.
5. Review the rewritten topic tips, then run the printed `publish-topics`
   command. It rechecks the original snapshot and atomically pushes every
   rewritten topic with an exact lease.
6. Start a new **Actions > Refresh codex > Run workflow** dispatch to stage,
   test, and promote the resulting `codex`.

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

Create a protected environment named `codex-publish`:

1. Restrict deployment branches to `codex`.
2. Add at least one required reviewer and disable self-review.
3. Add a repository or organization Actions secret named
   `CODEX_BRANCH_TOKEN` for an organization-admin bot matching the ruleset
   bypass actor. Give it **Actions: read**, **Contents: read and write**, and
   **Workflows: read and write** for this repository.

The staging job uses the secret to trigger ordinary push CI. The
`codex-publish` environment gates only the final promotion, so one approval is
enough. Candidate CI and the API-only topic jobs never receive this token.
Topics may change only `.github/workflows/codex-release.yml`; its trigger must
remain exactly a push to `codex`, and it may not reference the publisher token.
The controller rejects every other topic-controlled workflow change.

Generated merge commits use GitHub's standard `github-actions[bot]` identity
and subjects of the form `Merge <topic> into codex`.

## Repository rulesets

Import both JSON files under **Settings > Rules > Rulesets > New ruleset >
Import a ruleset**.

- `.github/rulesets/codex-topics.json` matches `??/codex/*` and blocks
  deletion, preserving topic heads after pull-request merges.
- `.github/rulesets/codex-branch.json` protects `codex` with pull-request,
  review, deletion, and force-push rules while allowing the publisher's
  organization-admin bot to bypass them.

Rulesets cannot require a pull request head to match `??/codex/*`; reviewers
must enforce that convention. Do not require topic heads to be up to date with
`codex`, because that would copy the generated aggregate into an input.
