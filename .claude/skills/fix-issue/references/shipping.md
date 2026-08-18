# Shipping and the Follow-up Queue

This skill carries a standing authorization the rest of the repository does not: a run that
finishes clean branches, commits, pushes, and opens a pull request on its own, then works its
follow-up queue to empty without stopping to ask. That authorization is narrow. It covers exactly
those actions, only inside a `$fix-issue` run, and only when every gate below passes.

It never covers merging, tagging, publishing, releasing, force pushing, editing another branch,
rewriting history, or touching anything a peer session owns.

## Why the gates are strict

This checkout is shared. Other sessions edit files, create and revert them mid-run, and hold
branches for their own in-flight pull requests. Automation that stages broadly, or that assumes
the current branch is yours, does damage that is hard to undo and easy to miss. A chained commit
and push in this repository once went straight to `main` after a squash merge moved the checkout.
Every rule below exists because of something that already happened.

## Everything happens in the worktree

The run created `$WT` at intake with this skill's `scripts/worktree.sh`, which also created the
branch. The main checkout is never edited, never carries this branch, and is never committed to.
Every command below takes the worktree explicitly:

```bash
git -C "$WT" …
gh pr create …          # run with $WT as the working directory
verify.sh --root "$WT" --run .analysis/<slug> …
```

Use absolute paths. The shell's working directory resets to the main checkout on its own, and a
relative path then commits, builds, or tests the wrong tree. The symptoms look like your own bug:
a test filter that matches nothing, or a regenerated project that does not contain your file.

One branch per pull request, and never reuse one across two. Do not stack a follow-up on the
primary pull request unless it genuinely depends on it, in which case the body says so.

## Gate: may this run ship at all

Stop and report instead of shipping when any of these is true:

- A verification step is `FAIL`, or `INCONCLUSIVE` and never rerun to a `PASS`.
- `git -C "$WT" branch --show-current` is not the branch this run created.
- A file is dirty inside `$WT` that the blueprint does not list. A fresh worktree starts clean, so
  anything unexpected there is an edit nobody planned.
- The blueprint's completion checks are not all satisfied: test, changelog, docs, localization.
- The change is high risk and independent review has not run or has unresolved P0 to P2 findings.

A stop is a normal outcome. Report what blocked shipping, leave the worktree in place, and say
what would unblock it.

## Stage

Stage the blueprint's file list by explicit path. Never `git add -A`, never `git add .`, never
`git add -u`.

```bash
git -C "$WT" add <path> <path> …
git -C "$WT" status --short
```

Read that `status --short` output before committing. Anything staged that the blueprint does not
list comes back out with `git -C "$WT" restore --staged <path>`.

Leave `TablePro/Resources/Localizable.xcstrings` out unless your change is the reason it moved.
It is shared, it is frequently dirty from other work, and new keys fall back to the English key
until a build regenerates it.

## Before the commit

Run these and act on what they say. They are in `verification.md` too, because they matter whether
or not shipping is automatic.

```bash
grep -n '^## \[' "$WT/CHANGELOG.md"
git -C "$WT" diff --cached -U0 | grep -nE '—|seamless|robust|comprehensive|intuitive|effortless|streamlined|leverage|elevate|delve|utilize|facilitate'
```

The first confirms an `Edit` did not swallow a released version heading and fold that release into
`[Unreleased]`. The second catches writing-style violations on added lines. Rewrite every hit that
lands on a line you added.

Then `Skill(code-review)` over the staged diff, and fix what it finds on your own lines.

## Commit

One atomic commit, one-line Conventional Commit subject, canonical scope, matching the style of
`git log --oneline`.

```
fix(sidebar): keep the database switcher list through a refresh
feat(editor): save a query for reuse from the command menu
```

Check the branch in the same message as the commit, never several turns earlier:

```bash
git -C "$WT" branch --show-current
git -C "$WT" commit -m "fix(scope): …"
```

## Push, as its own call

Never chain commit and push. If SSH fails, port 22 is blocked here:

```bash
git -C "$WT" push -u origin <branch>
git -C "$WT" -c credential.helper='!gh auth git-credential' push -u https://github.com/TableProApp/TablePro.git <branch>
```

## Pull request

Write the body to a file first, so it can be checked before it is sent, then run the same
writing-style grep over that file.

```bash
cd "$WT" && gh pr create --title "<the commit subject>" \
  --body-file "<main checkout>/.analysis/<slug>/pr-body.md"
```

`gh` reads the repository from the working directory, so run it inside the worktree. The body file
lives in the run directory in the main checkout, which is why that path is absolute.

The body carries: what the user sees now, the root cause on a defect or the design decision and
its non-goals on a change, the files and ownership boundaries touched, every verification verdict
with its result, the independent review outcome, known limitations and anything not verified, and
`Closes #<n>` when the run started from an issue.

Never `--web`, never auto-merge, never merge, never tag, never release. The pull request is where
your authorization ends.

## The follow-up queue

Findings recorded in the blueprint's collateral register become their own pull requests, one at a
time, after the primary pull request is open.

A finding enters the queue only if it clears the same bar it always had: confirmed at `file:line`,
with a reachable failure scenario, and evidence that no upstream guard already prevents it. Drop
speculation, unreachable code, style preferences, and anything that is a product decision for the
user to make. Re-verify the finding against the tree before building it, because the primary fix
may have already resolved it.

Order by severity, then by independence. Take one at a time and never hold two branches at once.

### Each follow-up gets its own worktree

Same as the primary work: its own worktree, its own branch, created together.

```bash
.claude/skills/fix-issue/scripts/worktree.sh fix/<slug>
```

That links `Secrets.xcconfig`, `Libs/*.a`, `Libs/dylibs`, and `Libs/ios`, without which the
worktree cannot build. Remove the previous worktree before creating the next one, so only one
exists at a time and the machine is not carrying a dozen half-finished trees.

Run `verify.sh generate` inside a new worktree before its first build. It has its own generated
Xcode project, and XcodeGen globs sources at generation time.

### Each follow-up gets the whole playbook

A collateral fix nobody asked for is the one most likely to be judged on its rigour, so shipping
it unverified is worse than not shipping it. Each one gets its own brief, blueprint, regression
test, changelog entry, documentation update, verification run, review at its risk level, and pull
request. No batching, no "small enough to skip the test".

### Stopping the queue

Work the queue to empty without asking. Stop it, and report, when:

- A finding turns out to need a product decision.
- A finding's verification fails twice for a reason that is not environmental.
- A finding is no longer reachable, in which case say so and drop it.
- A finding is large enough to be its own blueprint-level design rather than a fix.

Report after each item: what shipped, its pull request number, and what remains queued. Remove the
worktree when its pull request is open.
