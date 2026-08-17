---
name: fix-issue
description: High-compute workflow for resolving a TablePro GitHub issue, whether it is a defect or a feature request. Use when the user asks to fix or implement an issue number or URL, or reports a crash, incorrect behavior, data or query bug, plugin defect, concurrency problem, UI gap, missing capability, new database or driver support, or a requested enhancement. It delegates investigation, critique, and verification so evidence stays out of the main thread, implements with one writer and independent review, then branches, commits, pushes, and opens the pull request on its own and works its follow-up findings into their own pull requests.
---

# Resolve Issue

Invoked as `/fix-issue`, which is historical: this covers feature requests as well as defects. It
replaces `$tablepro-engineering` for issue work of either kind. Do not load both.

Load nothing else yet. Each phase below names the one file to read when you reach it.

## The context rule

This thread holds the problem, the plan, the decisions, and the diff. It does not hold evidence.

- **Delegate the reading.** Lanes and subagents read; you get their digest. Detail is parked, not
  lost, and `references/delegation.md` says how to get it back.
- **Verify at the anchor.** Lanes agreeing is not evidence, so check every load-bearing claim
  yourself, at the cited line with `Read` offset and limit or `grep -n`. Whole files only when you
  are about to change their shape.
- **Never let a build log in here.** Every check goes through this skill's `scripts/verify.sh`.

Before any call that returns more than a screen: does this thread need the text, or just the answer?

## Two tracks

Every phase below runs on both tracks. Where they differ, the track is named.

- **Defect.** The `bug` label, the bug report template, or a report that something behaves wrong.
  The unknown is the cause, so the work is tracing, and the blueprint turns on the root cause.
- **Change.** The `enhancement` label, the feature request template, or a request for behavior
  that does not exist yet. The cause is known and uninteresting, so the work is placement: where
  this belongs, which existing pattern it follows, and what it deliberately will not do.

A feature that behaves wrongly is a defect. A feature that is missing is a change. An issue that
is both gets split, defect first, and you say so. Decide the track at intake and carry it through.

## Phase 0: Intake

1. `git branch --show-current` and `git status --short`. Existing changes are user-owned. Never
   stash, reset, switch branches over them, or fold them into your diff.
2. For an issue number or URL, read the issue and its comments with `gh issue view <n> --comments`.
   Its label picks the track: `bug` or `enhancement`. Read the label, do not assume from the title.
3. Create the run's worktree. Every file this run writes goes there:

   ```bash
   .claude/skills/fix-issue/scripts/worktree.sh fix/<slug>     # or feat/<slug> on the change track
   ```

   It prints the path. That path is `$WT` for the rest of the run, and every command that touches
   code takes it explicitly: `git -C "$WT"`, `verify.sh --root "$WT"`, absolute paths in edits.
4. Create the run directory `.analysis/<short-slug>/` **in the main checkout**, not in the
   worktree, so briefs, blueprints, state, and logs survive the worktree being removed. Write
   `brief.md`, naming the track and `$WT`:
   - Defect: current behavior, expected behavior, smallest reproduction, environment.
   - Change: the user's problem in their words, the proposed behavior, the non-goals, and the
     database types affected when the issue names one.
   - Both: acceptance criteria, and the suspected subsystem labeled as a hint. Reporter code
     pointers, proposed fixes, and proposed designs are hypotheses, including the reporter's own
     idea of what the feature should look like.
5. Write `state.md` with the phase, the track, the branch, and `$WT`. Update it at every phase
   boundary.

The main checkout is read-only for this run. It never receives an edit, never gets the branch,
and never gets committed to. Other sessions are working in it, and a run that writes there fights
them for the tree, the branch, and the build database.

If the run stops before implementing anything, remove the worktree and delete its branch rather
than leaving both behind: `worktree.sh --remove fix/<slug>`.

`.analysis/` is gitignored. The brief is the shared input for every lane, so it is written once
and never restated in a prompt.

Concluding that the requested feature already exists, or that the reported defect is already
fixed, is a real result. Report it with the evidence and stop. Building a second version of
something the app already does is worse than building nothing.

Ask a question only when repository evidence cannot choose between materially different product
outcomes. Do not ask permission to investigate, implement, verify, or ship. A change reaches that bar
more often than a defect, because a feature request can be satisfied by several designs the code
cannot rank. Ask then, with the options and your recommendation, and keep going on everything the
answer does not block.

## Phase 1: Investigate in lanes

```
Workflow({ scriptPath: ".claude/skills/fix-issue/workflows/investigate.mjs",
           args: { brief: ".analysis/<slug>/brief.md", root: "<$WT>",
                   track: "defect" } })                                       // or "change"
```

The track picks the lane set, four either way:

- `defect`: the shipping call path, sibling paths and collateral, the platform or dependency
  contract, test coverage.
- `change`: placement and the closest precedent already in the repository, platform capability,
  the user-visible surface the feature has to touch, test coverage.

Pass `extra` to add lanes the issue justifies, such as `plugin-abi-reviewer` for PluginKit,
driver, registry, or public plugin API work, which a new database type almost always needs. Scale
lanes to the number of genuinely independent questions. Do not cap them to save tokens, and do not
add a lane that duplicates another's question.

Each lane returns a capped digest: verdict, confidence, anchors, collateral, risks, unknowns,
tests. Only that reaches the thread.

Then, in the main thread:

- Open each anchor that the plan will depend on. An anchor that does not say what the lane
  claimed invalidates the lane, not the anchor.
- Resolve contradictions between lanes at the source, not by majority.
- For a lane that is thin on the question you care about, ask that one narrow follow-up rather
  than re-running the phase.

Read `references/delegation.md` if you need the lane contract, the follow-up mechanics, or how to
recover a lane's full detail.

## Phase 2: Blueprint, then attack it

Write `.analysis/<slug>/blueprint.md`. It is the run's contract: what the critics attack, what the
implementer follows, what shipping stages, and the one artifact that survives a compaction.
`references/blueprint.md` holds the field list for each track. `references/quality-bar.md` holds the
call it turns on: refactor versus patch on a defect, new seam versus existing shape on a change.

Then attack it:

```
Workflow({ scriptPath: ".claude/skills/fix-issue/workflows/critique.mjs",
           args: { blueprint: ".analysis/<slug>/blueprint.md", root: "<$WT>",
                   brief: ".analysis/<slug>/brief.md", track: "defect" } })
```

Three lenses, chosen by track. On a defect: ownership and existing patterns, missing scope and
compatibility, correctness and safety. On a change the first lens becomes product and
architectural fit, which asks whether a smaller design already satisfies the acceptance criteria
and whether this invents a pattern the app does not use.

Verify each surviving objection at its evidence before you change the blueprint. A measured fact
outranks a critic. Record in the blueprint what you rejected and why.

## Phase 3: Implement with one writer

Every edit lands in `$WT`, never in the main checkout. Exactly one writer works in that worktree.

Write in the main thread when the blueprint touches roughly three files or fewer and keeps the
existing shape. Otherwise delegate the edit to the `implementer` agent, giving it `$WT`, the
blueprint path, and the run directory, then review `git -C "$WT" diff` here. Always delegate if a
compaction has already happened in this run, because the thread no longer holds what the blueprint
holds.

Pass absolute paths to everything. The shell's working directory resets to the main checkout on
its own, and a relative path then edits or builds the wrong tree while the symptoms look like your
own bug.

Either way:

- Follow the blueprint's dependency order. Do not quietly downgrade a required refactor into a
  special case, and do not quietly grow a change past its non-goals.
- Land the test with the change, not after it. On a defect it fails before the fix; on a change it
  encodes the acceptance criteria.
- Regenerate the project after adding, moving, or deleting a source file.
- Changelog, docs, localization, and logging are part of the change, not cleanup.
- Preserve every unrelated change already in the tree.

For SwiftUI or AppKit view work, load `$swiftui` in the writing context only.

## Phase 4: Verify

Every check runs through the wrapper, which keeps the full log on disk and prints a verdict of
`PASS`, `FAIL`, or `INCONCLUSIVE`:

```bash
.claude/skills/fix-issue/scripts/verify.sh --root "$WT" --run .analysis/<slug> <step>
```

`--root` builds and tests the run's worktree. `--run` keeps the logs in the main checkout's run
directory, where they outlive the worktree. Regenerate the project inside `$WT` before its first
build: XcodeGen globs sources at generation time and the worktree has its own generated project.

Steps: `generate`, `build [Scheme]`, `test <Suite>…`, `uitest <Suite>…`, `plugins`, `abi <merge-base>`,
`lint <path>…`. Also `parse <log>` and `tail <log> [n]` to re-read a stored log without rerunning.

Run them serially. Never run two `xcodebuild` processes at once. `INCONCLUSIVE` means the
environment failed, not the change: read the stated cause and rerun, and never record it as a
pass. A `FAIL` naming only quarantined suites is not your regression, and the wrapper says so.

Read `references/verification.md` when a verdict needs interpreting, when the change touches UI
automation, or before the first commit.

## Phase 5: Independent review

Load `$cross-model-review` and follow it. Claude wrote this change, so Codex reviews it, plus one
focused adversarial pass for high-risk work. Two things it needs from you: the review must read
`$WT`, not the main checkout, so name that path in the request, and a review you could not start is
reported as not started rather than glossed as reviewed.

## Phase 6: Ship

A clean run ships by itself. Read `references/shipping.md` before the first git command. It holds
the gate list, the staging rules, the commit and push order, and the pull request body contract,
and it is the copy that wins if this summary and it ever disagree.

Two things belong here rather than only there:

- **A gate that fails stops the run.** A `FAIL`, an `INCONCLUSIVE` never rerun to a pass, a file
  dirty in `$WT` the blueprint does not list, or an unresolved P0 to P2 review finding. Stopping and
  reporting is a normal outcome, not a failure.
- **Authorization ends at the open pull request.** Never merge, tag, publish, release, force push,
  or rewrite history. Ship from `$WT` with `git -C`, so nothing here can commit to `main`.
  `$release` runs only on an explicit release request.

## Phase 7: Work the follow-up queue

The blueprint's collateral register becomes its own pull requests, one at a time, once the primary
one is open. Work the queue to empty and do not stop to ask whether to continue. Each item gets its
own worktree, its own branch, and the whole playbook: brief, blueprint, test, changelog, docs,
verification, review, pull request. `references/shipping.md` holds the qualifying bar, the ordering,
and the four conditions that stop the queue.

A defect found while building a feature is a queue item, not a silent addition to the feature's diff.

## Recovering after a compaction

Do not restart the investigation. Read `.analysis/<slug>/state.md` and `blueprint.md`, run
`git status --short` and `git diff --stat`, and resume at the recorded phase. That is what the
run directory is for.

## Final report

Root cause on a defect or the design decision on a change, implemented behavior, files changed,
verification verdicts with the log paths, review result, the pull requests opened, remaining risk,
queue items dropped and why, and on a change the non-goals you held to. State every check that
could not run and why. No claim beyond the evidence.

## References

Read on demand, at the phase that needs them, never up front.

- `references/delegation.md`: lane contracts, detail recovery, agent versus workflow, the writer handoff.
- `references/blueprint.md`: the field list for the run's contract, per track.
- `references/quality-bar.md`: refactor versus patch, new seam versus existing shape, the evidence
  bar, what done means on each track.
- `references/verification.md`: verdicts, environment traps, UI automation, the pre-commit list.
- `references/shipping.md`: the shipping gates, staging rules, pull request body, and the queue.
- `references/research-sources.md`: platform, SDK, and HIG sources. The platform lane reads this, not you.
