---
name: fix-issue
description: >-
  Take a TablePro problem from report to one open pull request: read the GitHub issue,
  discussion, user feedback, screen recording or plain description, find the real cause, fix it
  together with every related defect the investigation proves, verify it, open one PR for all of
  it, and keep that PR green through CI. Use for bugs, behaviour gaps, small features and "make this work the native macOS way"
  requests, whether phrased as "fix #1234", an issue or discussion URL, a pasted complaint, or a
  Vietnamese description ("sửa lỗi ...", "tại sao ... không chạy", "làm lại cho đúng native").
  Full scope, the documented Apple approach and no quick patches are the defaults, so they never
  need to be asked for. Not for redesigning a whole screen (ui-revamp) or cutting a release.
---

# Fix Issue

One run ends in one open pull request that fixes the reported problem at its cause, plus every related defect the investigation proved, in the same PR.

These are the user's standing requirements, so treat them as defaults rather than waiting to be told:

- **Full scope, full path.** Fix every case the cause reaches, not only the reported one.
- **Related defects ship too.** What the investigation proves is broken nearby, or broken elsewhere by the same cause or pattern, goes in this PR.
- **Native and documented.** Use the AppKit/SwiftUI mechanism Apple documents and the HIG rule behind it. No hack, no custom reimplementation of something the platform already provides, no quick win in place of the real fix.
- **The reporter's proposed fix is input, not the spec.** When research shows a different native mechanism is correct, build that one and say why.

`CLAUDE.md` defines done: principles, mandatory rules, invariants. This skill does not restate it. Read the sections your change touches, and the `.claude/rules/*.md` file whose `paths:` cover the files you edit.

## Harness

This skill runs under Claude Code and under Codex. Before Phase 1, read the one file for the harness you are in, and only that one:

- Claude Code: `references/claude-code.md`
- Codex: `references/codex.md`

Each maps the steps below onto its own tools: subagents, long-running commands, the independent review, and asking the user.

Talk to the user, questions included, in the language they wrote in. Everything that lands in the repo (code, commits, PR, CHANGELOG, docs) is English and follows CLAUDE.md's writing style.

## Autonomy

Invoking the skill authorizes the whole run: investigate, branch, implement, verify, commit, push, open the PR, and keep it green until CI passes. There is no approval gate. Ask the user only when:

- the expected behaviour has two reasonable readings that lead to different fixes, or
- a finding needs a product decision, meaning what should happen is a choice rather than a fact.

Put those in one short question with your recommendation first, and keep working on everything that does not depend on the answer. Never ask about the environment (another session's build, a wedged test runner, a full disk): the user has no context for it, so handle it yourself and mention it in the report.

Never do these, even inside an authorized run: force-push, rewrite published history, touch release tags, publish plugins or libraries, deploy a CloudKit schema, or discard changes you did not make. When the fix needs one of them (a breaking PluginKit bump that needs every plugin re-released, a CloudKit field), build everything else and name what is left for the user.

## Phase 0: Intake

1. **Read the report.**
   - Issue: `gh issue view <n> --repo TableProApp/TablePro --comments`. The comments often hold the real complaint.
   - Discussion or other URL: fetch the page.
   - Screen recording: `ffmpeg -i <file> -vf "fps=1,scale=1280:-1" <scratch>/frames/%03d.png`, then look at the frames around the action. A recording is often the only exact reproduction.
   - Images in the issue: open them. They usually show the app version and the exact state.
2. **Make a worktree.** Several sessions work in this repo at once and have moved the shared checkout under each other, so every run gets its own tree:
   ```bash
   .claude/skills/fix-issue/scripts/worktree.sh --prune-merged   # reclaim trees whose PRs are merged or closed
   .claude/skills/fix-issue/scripts/worktree.sh <type>/<slug>    # prints the new tree's path
   ```
   The new tree starts from a fresh `origin/main` and has the untracked libraries and secrets linked. From here on, every command runs in it: `git -C <tree>`, `verify.sh --root <tree> --no-wait`. The main checkout is left alone, including whatever is uncommitted there.
3. **Write the problem statement** to `<tree>/.analysis/<branch>/problem.md` (the folder is gitignored and survives a context compaction or a usage limit): what happens, what should happen, the smallest reproduction, and the environment (database, macOS, app version). A code pointer from the reporter is a hint to check, not a fact.
4. **Choose the mode.**

### Mode

**Direct**, when all of these hold after you read the code yourself: you can point at the line that causes it and explain the mechanism, the correct behaviour is not in doubt, and the fix stays inside one subsystem without changing how the user interacts with a surface or adding a feature. You investigate alone, with no subagents.

**Full**, otherwise: the cause is still unknown after a first read, the fix crosses subsystems, it changes a user-visible interaction or adds a feature, it rests on how a dependency or the platform behaves, or it touches PluginKit, sync or a security boundary. The investigation fans out to lanes.

If you are unsure, choose Full. A Direct run that finds the cause somewhere other than where it looked switches to Full.

## Phase 1: Investigate

Both modes answer the same three questions. Full mode splits them across lanes.

- **Cause.** Which code path does the reported scenario actually take? When several paths reach the behaviour (buffered or streaming, grid or export, one engine or another), prove which one from the dispatch code. Separate the mechanism from the symptom, then find the blast radius: every input, type, state, engine and sibling surface the same cause reaches. The fix covers all of them.
- **Correct behaviour.** For UI and interaction, quote the HIG rule and name the documented AppKit or SwiftUI API, checked against the SDK `.swiftinterface` and the macOS 13 deployment target. For a driver or dependency, the source is the vendored header and the library we ship. For a new feature or a changed interaction, also check how comparable clients behave. `references/research-sources.md` says where to look.
- **Related defects.** What else is broken in the code this fix touches, and where else the same cause or pattern lives: sibling plugins, `TableProMobile`, `scripts/`. Only real defects with a concrete failure scenario count. Naming and taste do not.

In Full mode, run the lanes `trace` (cause), `research` (correct behaviour, skipped for purely internal logic) and `hunt` (related defects). Their briefs are in `references/lanes.md`. Each lane returns a short digest and leaves its full report where your harness file says, so reports never flood your context. Open the parts your plan depends on.

**Verify every related-defect finding before it enters scope**, because everything verified ships. Read the cited code, check that nothing upstream already prevents the failure, and check that the path is reachable in the shipping app. In Full mode the `verify` lane does this for the whole list at once. Drop what does not survive, and keep the reason.

**Measure, do not assume.** When the fix rests on how a C library, a binary dependency or a system framework actually behaves, write a probe and run it against what we ship: C compiled against `Libs/*.a` and the vendored header, a `swiftc` harness, or a query through the vendored CLI. An unmeasured claim is a hypothesis, including a lane's confident one and your own. Probes live in the scratchpad. A probe that settles a fact the code then hard-codes by hand gets committed as a `scripts/check-*.sh`, in the shape of `scripts/check-pluginkit-abi.sh`.

## Phase 2: Plan

Write `<tree>/.analysis/<branch>/plan.md`, aiming for under 80 lines:

- **Root cause**, stated as a mechanism.
- **Refactor or patch**, with the reason. Refactor when the current shape cannot express the correct behaviour without a special case, when the bug comes from a wrong model (a boolean where the state has several values, logic in a view that belongs in a model), or when patching the reported case leaves the same class of bug alive. Patch when the design is sound and the mistake is local. Never ship a symptom patch because the refactor is more work.
- **Design**: the API or pattern, the ownership boundary it sits at, and the HIG rule it follows.
- **Scope**: files in implementation order, the blast-radius cases, and each verified related defect with its `file:line` and failure scenario, plus the CLAUDE.md invariants in play.
- **Tests**: the unit test that fails before the fix, and UI automation when a flow changed and runs deterministically (or why it cannot).
- **Also needed**: CHANGELOG entries, docs pages, localization, screenshots.

Write the scope as a checklist and tick items as they land. A run stopped by a usage limit or a compaction resumes from this file, not from memory.

In Full mode, have the `critic` lane attack the plan: where it fights existing patterns, what scope is missing, whether refactor-or-patch is the right call. Fold in whatever survives an evidence check. Then implement. There is no approval step.

## Phase 3: Implement

- When the change is visible on screen, build the fresh tree and capture the "before" shots first (see Phase 6). That build also warms the tree's DerivedData for every later one.
- Follow the plan's order and do the refactor it calls for.
- After adding, moving or deleting a source file, or editing `project.yml`, run `verify.sh generate` before building. Otherwise a file the project never picked up shows as `cannot find 'X' in scope` in its callers.
- Apply CLAUDE.md's mandatory rules while you write, not as cleanup afterwards. The ones most often missed:
  - **CHANGELOG**: one fragment per user-visible change under `[Unreleased]`, in the section that already exists, naming the bug and not the fix. Each bundled defect a user could hit gets its own entry. After any edit, `grep -n '^## \[' CHANGELOG.md` must still list every released heading.
  - **Docs**: read `docs/STYLE.md` before writing a page, write docs last, then run `verify.sh docs`.
  - **Tests**: no top-level `@Suite` without a trait in `TableProTests`. UI suites subclass `UITestCase`.
  - **Competitors are research only.** Never name TablePlus or any other client in code, commits, the PR, CHANGELOG or docs.
- When you add or rework SwiftUI views, check them against the `swiftui` skill in `.claude/skills/swiftui/`.

## Phase 4: Verify

Build, test and lint it yourself, and run every step through the wrapper. It keeps the full log on disk and prints about thirty lines ending in `PASS`, `FAIL` or `INCONCLUSIVE`, with exit code 0, 1 or 2. Put `--root <tree> --no-wait` before the step.

```bash
.claude/skills/fix-issue/scripts/verify.sh generate
.claude/skills/fix-issue/scripts/verify.sh build
.claude/skills/fix-issue/scripts/verify.sh test <SuiteType> [SuiteType...]
.claude/skills/fix-issue/scripts/verify.sh uitest <SuiteType> [SuiteType...]
.claude/skills/fix-issue/scripts/verify.sh plugins            # Plugins/ changed
.claude/skills/fix-issue/scripts/verify.sh abi <merge-base>   # TableProPluginKit changed
.claude/skills/fix-issue/scripts/verify.sh lint <file> [file...]
.claude/skills/fix-issue/scripts/verify.sh docs               # docs/ changed
```

- **Verify in batches.** Finish a coherent set of edits, then build once and run the suites together. After a failure, fix it and re-run only the failed step. Past runs averaged 29 builds and test runs each, most of them after one-line edits.
- **Pick suites by the types you changed**, not by the test files you edited. `grep -rl <TypeName> TableProTests` names the suites that will judge a shared model you never opened. Pass Swift type names: a filter naming a file or a test function runs nothing and still looks green, so check the executed count is plausible.
- **`INCONCLUSIVE` is the environment** (a wedged host, a locked build database, the network), never a pass and never a reason to debug your code. Re-run it, and state it if it persists.
- **Show the new test failing on the old code when that is cheap**: revert just the fix hunk, run that suite, reapply.
- When a verdict needs interpreting, read `references/verification.md` for the known traps.

## Phase 5: Review

Have the complete diff reviewed by a model that did not write it: fix, bundled defects, tests and docs together. Your harness file names the reviewer. Add a security pass when the change touches credentials, the keychain, SQL construction, query execution, plugin loading, MCP or AI permissions, or sync. Add the PluginKit ABI pass when the kit changed.

Act on the findings without asking. Fix what is real, and note why a finding does not apply. Re-run the affected verify steps, then review again. Stop after three review rounds: whatever is still open after the third goes into the PR body under "Known issues" with its evidence, and the PR ships with everything else. Do not cut scope to escape the loop.

## Phase 6: Ship

1. **Stage explicit file paths**, never `git add -A`, `.` or a directory. Leave `Localizable.xcstrings` and `InfoPlist.xcstrings` out unless your change is what moved them. Compare `git -C <tree> diff --cached --stat` with the files you changed: nothing missing, nothing foreign.
2. **Style gate**: run CLAUDE.md's banned-word and em-dash grep over the staged diff and over the PR body file. Rewrite every hit on an added line.
3. **Commit, then push in a separate call.**
   - Run `git -C <tree> branch --show-current` in its own call first. A chained `commit && push` has pushed straight to `main` before.
   - Commit with Conventional Commits: one line, a canonical scope, and never an overridden git identity.
   - Push: `git push -u origin <branch>`. If SSH fails, use `git -c credential.helper='!gh auth git-credential' push https://github.com/TableProApp/TablePro.git <branch>`.
4. **Open the PR**, ready for review rather than a draft: `gh pr create --repo TableProApp/TablePro --base main --head <branch> --title "<commit subject>" --body-file <file>`. The body holds:
   - A summary, `Fixes #<n>`, and a Fixes line for every other issue the PR resolves.
   - The root cause, stated as a mechanism.
   - What changed: the primary fix first, then "Also fixed" with one entry per bundled defect (what was wrong, its failure scenario, how it was verified).
   - The tests and the verification verdicts, and any flow left without UI automation, with the reason.
   - Before and after screenshots when the change is visible on screen.
   - Known issues, when the review cap left any.

**Screenshots** only when the change is visible (a pane, dialog, toolbar, menu, cell or empty state):

- Capture from a Debug build launched with `TABLEPRO_UI_TEST_SANDBOX` pointing at a scratch directory, so it never touches the user's real connections. Take "before" on the fresh tree and "after" on the finished one, in light and dark, with the window at the size the existing `docs/images/` shots use.
- Look at every shot before using it: the right state, the right appearance, no stray dialog left open.
- Upload with `gh pr create --attach './before.png#Before'`, referenced from the body as `![Before](./before.png)`. Never tell the user to add images by hand.
- Reuse the same shots as `docs/images/<name>.png` and `-dark.png` when a docs page shows that surface.
- When capture is truly impossible, name the pending state in the PR body and move on.

## Phase 7: Land

A PR that is red or conflicted is not done, and fixing it later has cost more than the fix itself. Watch the checks until they finish (your harness file says how to wait without spending tokens), then:

- **A check this PR broke**: fix it, re-verify locally, and push a new commit.
- **A merge conflict**: `git -C <tree> fetch origin main && git -C <tree> merge origin/main`, resolve it, re-verify, push. Never rebase or force-push a pushed branch.
- **A check that is not this PR's** (red on `main` too, a quarantined suite, a runner fault): leave it and say so in the report.

Stop after two rounds of CI fixes. Whatever is still red then goes into the report with the failing job's link. Never merge the PR: that is the user's call.

## Phase 8: Report

Tell the user briefly, in their language:

- the PR link on the first line, then what it fixes: the primary issue and each bundled defect
- the root cause, in two sentences
- the verification verdicts, the CI state, and which reviewer read the diff, including any fallback
- known issues left open, and the findings you dropped with the reason
- anything that could not run, or that needs the user (the "never" list above)
