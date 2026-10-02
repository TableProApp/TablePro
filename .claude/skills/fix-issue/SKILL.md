---
name: fix-issue
description: >-
  Take a TablePro problem from report to one open pull request: read the GitHub issue,
  discussion, user feedback, screen recording or plain description, find the real cause, fix it
  together with every related defect the investigation proves, verify it, open one PR for all of
  it, and keep that PR green through CI. Use for bugs, behavior gaps, small features and "make
  this work the native macOS way" requests, whether phrased as "fix #1234", an issue or discussion
  URL, a pasted complaint, or a Vietnamese description ("sửa lỗi ...", "tại sao ... không chạy",
  "làm lại cho đúng native"). Full scope, the documented Apple approach and no quick patches are
  the defaults, so they never need to be asked for. Not for redesigning a whole screen
  (ui-revamp) or cutting a release.
---

# Fix Issue

One run ends in one open, green pull request that fixes the reported problem at its cause, plus every related defect the investigation proved.

The user's standing requirements are the defaults:

- **Full scope.** Fix every case the cause reaches, not only the reported one.
- **Related defects ship too**, inside the scope boundary (Phase 1).
- **Native and documented.** The AppKit or SwiftUI mechanism Apple documents and the HIG rule behind it. No hack, no custom reimplementation, no quick win in place of the real fix.
- **The reporter's proposed fix is input, not the spec.** When research shows a different native mechanism is correct, build that and say why.

`AGENTS.md` and the `.claude/rules/` files whose `paths:` match what you edit define done. This skill does not repeat them.

Before Phase 1, read the one harness file for where you run, and only that one: `references/claude-code.md` (Claude Code) or `references/codex.md` (Codex). Talk to the user, questions included, in their language; everything in the repo is English.

## Autonomy

Invoking the skill authorizes the whole run: investigate, branch, implement, verify, commit, push, open the PR and keep it green. There is no approval gate. Ask only when the expected behavior has two reasonable readings, or a finding needs a product decision; ask once, recommendation first, and keep working on what does not depend on the answer. Never ask about the environment (a peer's build, a wedged test runner, a full disk): handle it and mention it in the report.

Never, even in an authorized run: force-push, rewrite published history, touch release tags, publish plugins or libraries, deploy a CloudKit schema, or discard changes you did not make. When the fix needs one of these, build everything else and name what is left for the user.

## Phase 0: Intake

1. **Read the report.** An issue: `gh issue view <n> --repo TableProApp/TablePro --comments` (the comments often hold the real complaint). A URL: fetch it. A screen recording: `ffmpeg -i <file> -vf "fps=1,scale=1280:-1" <scratch>/frames/%03d.png` and look at the frames around the action. Open every image.
2. **Make a worktree**, because several sessions share the main checkout:
   ```bash
   .claude/skills/fix-issue/scripts/worktree.sh --prune-merged   # reclaims trees whose PRs are merged or closed
   .claude/skills/fix-issue/scripts/worktree.sh <type>/<slug>    # prints the tree's path on its last line
   ```
   The tree starts from a fresh `origin/main` with libraries and secrets linked. From here on everything runs in it (`git -C <tree>`, the tree's own `verify.sh`), and the main checkout is left alone.
3. **Write the problem statement** to `<tree>/.analysis/<slug>/problem.md` (`<slug>` is the branch with `/` turned into `-`, the folder `verify.sh` logs to; it survives a compaction or a usage limit): what happens, what should happen, the smallest reproduction, the environment. A code pointer from the reporter is a hint, not a fact.
4. **Choose the mode.** *Direct* when, after reading the code yourself, you can point at the line that causes it, the correct behavior is not in doubt, and the fix stays in one subsystem without changing an interaction or adding a feature: you investigate alone. *Full* otherwise, or when unsure: the investigation fans out to lanes. A Direct run that finds the cause elsewhere switches to Full.

## Phase 1: Investigate

Answer three questions; Full mode gives each to a lane (`references/lanes.md`).

- **Cause** (`trace`). The code path the reported scenario actually takes, proven from the dispatch code when several paths exist; the mechanism, separate from the symptom; the blast radius, every input, type, engine and sibling surface the same cause reaches.
- **Correct behavior** (`research`, skipped for purely internal logic). For UI, the HIG rule and the documented API, checked against the SDK `.swiftinterface` and macOS 13. For a driver, the vendored header and the library we ship. For a new feature or changed interaction, also comparable clients. Sources: `references/research-sources.md`.
- **Related defects** (`hunt`). What else is broken in the code this change touches, and where else the same cause or pattern lives. Only defects with a concrete failure scenario count.

**Scope boundary.** A verified defect ships in this PR when it sits in code the change touches, or shares its root cause or pattern, anywhere in the repo. A pre-existing defect outside that code goes under "Left open" in the PR with its evidence, unfixed.

**Verify each related defect before it enters scope**: read the cited code, check nothing upstream prevents the failure, check the path is reachable. In Full mode one `verify` lane does the whole list.

**Measure, do not assume.** When the fix rests on how a C library, a binary dependency or a framework behaves, run a probe against what we ship (C against `Libs/*.a`, a `swiftc` harness, the vendored CLI). An unmeasured claim is a hypothesis, including a lane's and your own. A probe that settles a fact the code hard-codes by hand gets committed under `scripts/probes/`.

## Phase 2: Plan

Write `<tree>/.analysis/<slug>/plan.md`, under 80 lines, opening with a progress log you keep current:

- the root cause, as a mechanism;
- **refactor or patch**, with the reason: refactor when the current shape cannot express the correct behavior without a special case, the bug comes from a wrong model, or a patch leaves the same class of bug alive; patch when the design is sound and the mistake is local;
- the design: the API or pattern, its ownership boundary, the HIG rule;
- the scope as a checklist: files in order, blast-radius cases, each verified related defect with `file:line`;
- the tests that fail before the fix, and UI automation when a flow changed;
- CHANGELOG, docs, localization and screenshots needed.

In Full mode, the `critic` lane attacks the plan; fold in what survives an evidence check. Then implement.

## Phase 3: Implement

- When the change is visible on screen, build the fresh tree and capture the "before" shots first.
- Follow the plan's order and do the refactor it calls for. Apply AGENTS.md "Every change" as you write, not afterwards.
- **A large change may be implemented in parallel**: when the plan spans areas that share no files, split it across up to six subagents, each owning a disjoint file list in `plan.md`, editing only those and building nothing. You read every diff, integrate and verify. Your harness file says how.
- Competitors are research only: never name another client in code, commits, the PR, CHANGELOG or docs.

## Phase 4: Verify

Run every step through the tree's wrapper, written out in full each time (the variable shortcut does not word-split in zsh):

```bash
<tree>/.claude/skills/fix-issue/scripts/verify.sh --root <tree> --no-wait <step>
```

| Step | When |
| --- | --- |
| `generate` | a new tree; a new, moved or deleted file; `project.yml` |
| `build`, `test <SuiteType>...` | always |
| `uitest <SuiteType>...` | a user flow changed |
| `package <Package> [filter]` | `Packages/` changed |
| `ios <SuiteType>...` | `TableProMobile/` or a file it shares changed |
| `plugins` | `Plugins/` changed |
| `abi <merge-base>` | `TableProPluginKit` changed (commit first) |
| `lint <file>...` | every changed Swift file |
| `l10n` | strings or plugin messages changed |
| `docs`, `agent-docs` | `docs/`, or `AGENTS.md` and `.claude/` changed |

- Check the `root:` line names your tree. The verdict is `PASS`, `FAIL` or `INCONCLUSIVE` (exit 0, 1, 2), also written to `<log>.verdict`.
- **Verify in batches**: build once after a coherent set of edits, then re-run only a failed step.
- **Pick suites by the types you changed** (`grep -rl <TypeName> TableProTests`), not by the test files you edited, and check the executed count.
- **`INCONCLUSIVE` is the environment**, never a pass and never a reason to debug your code. `references/verification.md` has the remedies.
- When cheap, show the new test failing on the old code.

## Phase 5: Review

Have the complete diff reviewed by a model that did not write it; your harness file names the reviewer. In Full mode the first round adds an adversarial pass on the design. Add a security pass when the change touches credentials, SQL construction, query execution, plugin loading, MCP or AI permissions, or sync, and the ABI pass when PluginKit changed.

Fix what is real and inside the scope boundary without asking; a real finding about pre-existing behavior outside it goes under "Left open". Re-verify, review again, and stop after three rounds: what is still open goes under "Left open".

## Phase 6: Ship

1. **Stage explicit paths**, never `git add -A`, `.` or a directory, and compare `git -C <tree> diff --cached --stat` with what you changed. Stage a string catalog only for the keys you added.
2. **Run `scripts/check-banned-words.sh --staged`** and the same check over the PR body file.
3. **Commit, then push, in separate calls**, after `git -C <tree> branch --show-current` in its own call. The PR title is the squash commit subject: Conventional Commits, at most 72 characters. Never override the git identity. If SSH fails: `git -c credential.helper='!gh auth git-credential' push https://github.com/TableProApp/TablePro.git <branch>`.
4. **Open the PR, ready for review**: `gh pr create --repo TableProApp/TablePro --base main --head <branch> --title "<subject>" --body-file <file>`, the body following `.github/pull_request_template.md` and readable in under a minute. It is not a log: no investigation story, no review history, no list of every test run.
5. **Screenshots**, only when the change is visible: from a Debug build launched with `TABLEPRO_UI_TEST_SANDBOX` set to a scratch directory, before and after, light and dark. Look at each before using it. Attach with `gh pr create --attach './after.png#After'` and reference it as `![After](./after.png)`. Reuse them in `docs/images/` when a page shows that surface. A registry-only plugin cannot load in a sandboxed Debug build; say so when that blocks a shot.

## Phase 7: Land

Watch the checks until they finish (the harness file says how, without spending tokens):

- a check this PR broke: fix it, re-verify, push a new commit;
- a merge conflict: `git -C <tree> fetch origin main && git -C <tree> merge origin/main`, resolve, run `generate` (main may have added files), re-verify, push; never rebase or force-push;
- a check that is not this PR's (red on `main` too, a runner fault), or one still queued after 45 minutes with no job started: leave it and report it.

Stop after two rounds of CI fixes. Never merge the PR.

## Phase 8: Report

At most eight lines, in the user's language: the PR link first, what it fixes (the issue and each bundled defect, one line each at most), the root cause in one sentence, the CI state, who reviewed it, and what is left open or needs the user.
