# Maintaining the `codex` branch

`codex` is the generated distribution branch. Its inputs are the active
branches matching `??/codex/*`, where `??` is a two-character owner name.
Branches ending in `-wip` or `-stale` are ignored.

There is no topic list or maintained merge order. If one topic depends on
another, base the dependent topic on it. The commit graph then records the
dependency. Independent topics receive a stable internal tie-break only so
that rebuilds are reproducible.

## Create and review a topic

Create the topic from `master`, or from another topic that it depends on:

```sh
git switch -c tb/codex/my-topic origin/master
# Make and test the change.
git push -u origin HEAD
```

Never merge `codex` into a topic and never use GitHub's **Update branch** button
on one of these pull requests. That would copy the generated aggregate into a
topic and turn unrelated patches into permanent dependencies. Rebase onto
`master`, or merge only the specific topic that this one depends on.

A topic can be reviewed and promoted through a pull request whose base is
`codex`. The required pull-request check accepts only an active `??/codex/*`
branch in this repository and rejects a head containing the generated `codex`
history. Merging that pull request updates `codex` immediately; the retained
topic branch makes the change reproducible the next time `codex` is rebuilt.

Do not merge a pull request from a temporary branch outside this namespace.
The next rebuild would have no durable source for that change.

## Rebuild `codex`

Run **Actions > Codex branch > Run workflow** from `master`. The workflow:

1. starts from the current `master`;
2. discovers all active topics;
3. removes topics already contained by another topic;
4. merges the remaining tips into a detached candidate;
5. builds and tests the candidate; and
6. updates `codex` with an exact lease.

Before publishing, the workflow also verifies that `master` and every active
topic still have their original object IDs. The final push uses a lease so it
cannot overwrite a pull request merged into `codex` while it was running.
Rerun the workflow if either check fails. A source branch can still move in
the small interval after the final verification; the published candidate is a
coherent tested snapshot, and a later run will incorporate that move.

Leave **Update codex after the candidate passes** disabled for a dry run.
Enable it only after the existing `codex` changes have been extracted into
complete topic branches and a historical rebuild has reproduced the current
`codex` tree.

Publishing uses a protected environment so that topic branches cannot read the
credential:

1. Create an environment named `codex-publish`.
2. Restrict its deployment branches to the selected branch `master`.
3. Add an environment secret named `CODEX_BRANCH_TOKEN` containing a
   fine-grained personal access token owned by an organization administrator.
   Give it **Contents: read and write** and **Workflows: read and write** for
   this repository.

The administrator identity lets the generated update bypass the `codex`
ruleset below. Do not use a repository secret: a workflow dispatched from a
topic branch could otherwise request it. Do not use the workflow's
`GITHUB_TOKEN`, because pushes made with it do not start the existing release
workflow.

Any repository writer who can run Actions can request publication. If that is
too broad, add the release owners as required reviewers on `codex-publish` and
disable self-review.

## Resolve a conflict

The failed workflow leaves `codex` unchanged. Its summary contains one exact
command with the pinned base, old `codex` rerere source, completed topics,
failed topic, and expected tree. Run that command from a clean clone. The
helper first proves that those refs still contain the pinned commits.

The helper creates a temporary worktree, reproduces the exact successful
prefix, and condenses that prefix into a resolution-only prerequisite commit.
It then starts the inverse merge: the failed topic is the first parent and the
prerequisite commit is the second. It prints commands of this form:

```sh
cd /tmp/codex-resolve.example/worktree
# Edit the conflicted files.
git add <files>
git diff --cached --check
git commit
git push --force-with-lease=refs/heads/tb/codex/my-topic:PINNED_TOPIC_OID \
  origin HEAD:refs/heads/tb/codex/my-topic
```

That merge commit stores both the dependency and its resolution on the topic.
Rerun the workflow after pushing it.

If you cannot update the original topic, add
`--new-topic xy/codex/my-topic-fix` to the command from the workflow. The
helper will prepare a successor branch that contains the original topic and
its prerequisites. Its printed lease also requires that the successor does
not already exist.

If the leased push says that the branch moved, do not force it. Rerun the
refresh workflow and use its new conflict command.

Never resolve a conflict by pushing directly to `codex`.

## One-time cutover

The existing private delta has already been split into these local topic refs:

- `tb/codex/release` at `83a728de1eb6337bf80488948afafec275bd658e`;
- `dr/codex/dugite` at `7d769388b90645512fec59cb467c2d6834853f47`;
- `tb/codex/lto-pgo` at `ba099830983b25f519048c1c8b35217b16a62fe5`.

Starting at the historical base `f60db8d575adb79761d363e026fb49bddf330c73`,
merging those maximal topic tips reproduces tree
`1c5cd2459fae68a247ec5869f1cbd8b688204141`, exactly the tree of the pre-cutover
`codex` tip
`0d01927a0b4d162c3932681b5bbd8ade749bd2ec`. The refs and proof are local only
until explicitly pushed.

Cut over in this order:

1. Push the three topic refs.
2. Land this manager on `master`. This intentionally ends pure fast-forward
   mirroring of upstream `master`; GitHub requires the dispatch workflow on the
   default branch. Replace the fast-forward-only sync before cutover; thereafter
   advance `master` by merging the current upstream `master` into it.
3. Configure `codex-publish` and its token, then run with publishing disabled.
   The workflow summary shows both object IDs and a diffstat. Confirm that the
   candidate differs from old `codex` only by the intended upstream advance and
   manager files.
4. Run once with publishing enabled.
5. Import the topic-retention ruleset. After the validation check has appeared
   on a pull request, import the `codex` protection ruleset and verify a sample
   topic pull request.

## Repository rulesets

Import both JSON files under
**Settings > Rules > Rulesets > New ruleset > Import a ruleset**.

`.github/rulesets/codex-topics.json` keeps topic branches after merging. It:

- includes branches matching `??/codex/*`;
- enables **Restrict deletions**; and
- leaves creation and ordinary updates unrestricted.

Organization administrators retain bypass permission so that an intentionally
retired topic can still be deleted.

GitHub does not automatically delete a protected pull-request head branch, so
the topic remains available to future rebuilds even when automatic deletion is
enabled for other branches.

`.github/rulesets/codex-branch.json` protects the generated branch. It requires
pull requests, one approval from someone other than the last pusher, and the
**Validate Codex topic** check. It blocks deletion and ordinary force-pushes,
and lets organization administrators bypass those rules for a rebuild. A
merged topic pull request updates the distribution immediately and therefore
bypasses the `codex-publish` environment; its reviewer is the publication gate.
Do not enable **Require branches to be up to date** for these pull requests;
topic heads must not absorb `codex`.
