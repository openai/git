# Maintaining `codex`

`master` stays equivalent to upstream. This orphan `meta` branch contains the
controller, workflow, tests, documentation, and ruleset recipes. Never merge
`meta` into `master` or `codex`.

The active inputs are every branch matching `??/codex/*`, where `??` is a
two-character owner name. A `-wip` or `-stale` suffix makes a branch inactive.
There is no topic list, order file, or other maintained state.

## Topic branches and pull requests

Create a topic from `master`, or from the topic it depends on:

```sh
git switch -c tb/codex/my-topic origin/master
# Edit, test, and commit.
git push -u origin HEAD
```

The commit graph is the dependency graph. Keep topic history linear; rebase a
dependent topic onto its prerequisite instead of merging. Never merge `codex`
into a topic and never use GitHub's **Update branch** button on these pull
requests.

Each topic has one inferred prerequisite: its nearest active topic-tip
ancestor, or `master` when it has none. If two sibling topics share private
commits, put an active topic ref at that shared prefix and base both siblings
on it. Otherwise the controller rejects the ambiguous overlap and asks you to
create that prerequisite topic or restack the branches.

A topic may be the head of a pull request whose base is `codex`. Use a
same-repository `??/codex/*` head. The topic-retention ruleset prevents GitHub
from deleting that branch after the pull request is merged.

## Refresh `codex`

The workflow lives only on `meta`, so GitHub cannot show its **Run workflow**
button on the default branch. To request a publication:

1. Open **Actions > Codex branch**.
2. Open the newest run on `meta`.
3. Choose **Re-run jobs > Re-run all jobs**.

A push to `meta` creates a new seed run. Attempt 1 prepares the candidate,
validates each topic in its own workflow job, and builds and tests the result.
Re-running all jobs is the explicit publication request. Re-running only
failed jobs cannot publish. Use a new `meta` push if the seed is too old for
GitHub to rerun or if its preparation job failed before saving the immutable
attempt-1 candidate.

Each run:

1. snapshots `meta`, `master`, `codex`, and every active topic;
2. derives all dependencies from commit ancestry;
3. rebases each whole topic onto its rewritten prerequisite, processing ready
   sibling topics concurrently in topological waves;
4. lets rerere reuse resolutions recorded by the old `codex` history;
5. merges the rewritten maximal tips into a candidate `codex`;
6. freezes the exact candidate and rewritten topics in a Git bundle;
7. fans out one structural validation job per rewritten topic;
8. builds the candidate once, tests the controller against it, then runs the
   full candidate test suite; and
9. atomically pushes every topic update and `codex`, with an exact lease for
   each of those refs.

The per-topic jobs run independently and appear separately in the Actions
summary. They verify each rewritten tip and its inferred prerequisite. The
controller performs the actual parallel waves, and it never starts a dependent
topic until its prerequisite has been rewritten. A failed topic square names
the rewritten ref whose ancestry or containment check failed; the integrated
build and test remain a single gate.

Any conflict, build failure, test failure, detected moved input, rejected
lease, or server without atomic-push support updates nothing. The publisher
rechecks `meta`, `master`, `codex`, and the complete topic namespace immediately
before its single push; Git places server-side exact leases on every topic and
`codex` ref in that atomic transaction.

## Resolve a rebase conflict

The failed run's summary says **No refs were updated** and contains one pinned
`codex-branch resolve` command. Run that command from a clean clone. It verifies
the exact input snapshot, creates a disposable worktree, reconstructs the
successful prefix, and stops in the same ordinary rebase.

In the printed worktree:

```sh
git status
git rebase --show-current-patch
# Edit the conflicted files.
git add <files>
git diff --cached --check
git rebase --continue
```

Repeat edit/add/continue until the rebase finishes. To abandon the attempt,
run `git rebase --abort` and delete the disposable worktree.

Then run the exact `codex-branch continue --worktree ...` command printed by
the helper. If another topic conflicts, resolve it the same way and run
`continue` again. When the whole ancestry graph is coherent, the helper prints
one `publish-topics` command. Review the rewritten tips and run that command;
it verifies the original snapshot again and performs one atomic push with an
exact lease for every topic ref. Finally, **Re-run all jobs** on the latest
`meta` seed to build, test, and publish `codex`.

Do not force-push only the branch that first conflicted. If `A -> B -> C`,
replacing only `B` makes neither the old `A -> B` nor the old `B -> C`
relationship true. With no order manifest, the controller must finish and
publish the coherent topic graph together.

If a lease fails, do not add `+` or use an unqualified force push. Start again
from the newest workflow run.

If the rewritten maximal topics conflict while assembling `codex`, the run
summary names the topic, the maximal topics already integrated, and the
conflicted paths. This means two topics declared independent by ancestry are
not actually independent. Rebase the conflicting topic and its descendants
onto the real prerequisite topic, push that coherent topic graph, and rerun.
Do not resolve this by merging `codex` into a topic or by inventing an order.

## Configure publishing

Create a protected environment named `codex-publish`:

1. Restrict deployment branches to `meta`.
2. Add at least one required reviewer and disable self-review.
3. Add an environment secret named `CODEX_BRANCH_TOKEN` with repository
   **Contents: read and write** and **Workflows: read and write**.

Use an organization-admin bot account, matching the bypass actor in the
provided rulesets. Do not use a repository secret. The workflow gives
candidate code no credential; only the fresh publisher job can read the
environment secret.

Generated merge commits use GitHub's standard `github-actions[bot]` identity
and subjects of the form `Merge <topic> into codex`.

## Repository rulesets

Import both JSON files under **Settings > Rules > Rulesets > New ruleset >
Import a ruleset**.

- `.github/rulesets/codex-topics.json` matches `??/codex/*` and blocks deletion,
  which keeps topic heads after pull-request merges.
- `.github/rulesets/codex-branch.json` protects `codex` with pull-request,
  review, deletion, and force-push rules while allowing the administrator used
  by the publisher to bypass them.

Rulesets cannot require that a pull request's head matches `??/codex/*`.
Reviewers must enforce that convention. Do not require topic heads to be up to
date with `codex`; that would copy the generated aggregate into an input.
