---
name: fix-issue
description: >-
  Take a TablePro problem from report to an open pull request: read the GitHub issue,
  discussion, user feedback, screen recording or plain description, find the real cause, fix it
  together with every defect the investigation and review prove, verify it, open one PR per app
  for all of it, and keep it green through CI. Use for bugs, behavior gaps, small features and "make
  this work the native way" requests on any TablePro app, whether phrased as "fix #1234", an issue
  or discussion URL, a pasted complaint, or a Vietnamese description ("sửa lỗi ...", "tại sao ...
  không chạy", "làm lại cho đúng native"). The repo's documented standard decides every step over
  any request, so full scope, the platform's documented approach and no quick patches never need
  to be asked for. Not for redesigning a whole screen (ui-revamp) or cutting a release.
---

# Fix Issue

One run ends in an open, green pull request per app that fixes the reported problem at its cause, plus every defect the run proved.

## The standard decides

The documented standard decides every step of a run: the root `AGENTS.md`, the platform guide and its area rules, this skill and its references, `RELEASING.md`, and the platform's design guidelines and documented APIs. A request is input to it, whoever makes it: the reporter, a commenter, the user or the maintainer running the skill.

- **Full scope.** Fix every case the cause reaches, not only the reported one.
- **Every proven defect ships.** What the investigation or review proves gets fixed in this run, wherever it sits, never parked in the PR body (Phase 1, What ships).
- **Native and documented.** The mechanism the platform documents and the design guideline behind it. No hack, no custom reimplementation, no quick patch in place of the real fix.
- **A proposed fix is input, not the spec.** When research shows a different mechanism is correct, build that and say why.
- **A request never overrides a rule.** When one conflicts, follow the rule and name it in one line. Changing a rule is its own docs pull request, never an exception made inside a run.
- **Never offer a choice the standard settles**: a label, a backport, a changelog fragment, a test target, the scope. Apply the rule and name it. A question about a step gets the rule that decided it, not an offer to undo it.

The platform's guide and its area rules define done.

Before Phase 1, read the one harness file for where you run, and only that one: `references/claude-code.md` (Claude Code) or `references/codex.md` (Codex). Talk to the user in their language, questions included; everything in the repo is English.

## Platform

TablePro is one native app per platform, each with its own code, toolchain, base branch and design guidelines. What differs lives in a profile, `references/platform-<name>.md`, so this file reads the same for every platform.

Pick the platform from the report: the issue's Platform field, a `platform-*` label, the operating system the reporter names, or the app the user means. Ask when the report does not say. Then read the one profile whose Covers section matches. It gives the base branch, the guide that defines done, the native standard, the verify steps and how to capture the screen. It names two more files, each read only when needed: `references/research-<name>.md` for the research lane, and `references/verification-<name>.md` when a verdict or a red check needs reading.

- **No profile, no run.** A platform with no profile in this checkout cannot be fixed from it: say so and stop. The same goes for a value the profile leaves empty. Never borrow another platform's base branch, commands or guidelines.
- **One pull request per app.** The code, the base branch and the verify steps of two apps are separate, so a defect the run proves in another app ships in a second pull request from the same run, built and verified under that app's profile.
- `verify.sh` runs the steps of the machine's own platform unless `--platform <name>` names another.

## Autonomy

Invoking the skill authorizes the whole run: investigate, branch, implement, verify, commit, push, open the PR and keep it green. There is no approval gate. Ask only when the standard leaves the expected behavior with two reasonable readings, or a finding needs a product decision the standard does not make: once, recommendation first, and keep working on what does not depend on the answer. Never ask about the environment (a peer's build, a wedged test runner, a full disk): handle it and mention it in the report.

Never, even in an authorized run: force-push, rewrite published history, touch release tags or `release/*` branches, publish plugins or libraries, deploy a CloudKit schema, or discard changes you did not make. When the fix needs one of these, build everything else and name what is left for the user.

## Phase 0: Intake

1. **Read the report.** An issue: `gh issue view <n> --repo TableProApp/TablePro --comments`; the comments often hold the real complaint. A URL: fetch it. A screen recording: `ffmpeg -i <file> -vf "fps=1,scale=1280:-1" <scratch>/frames/%03d.png`, then look at the frames around the action. Open every image.
2. **Pick the platform** and read its profile.
3. **Make a worktree**, since several sessions share the main checkout:
   ```bash
   .claude/skills/fix-issue/scripts/worktree.sh --prune-merged          # reclaims trees whose PRs are merged or closed
   .claude/skills/fix-issue/scripts/worktree.sh <type>/<slug> <base>    # prints the tree's path on its last line
   ```
   `<base>` is the profile's worktree base, and the tree starts from a fresh fetch of it. From here on everything runs in the tree, every git call as `git -C <tree>`, and the main checkout is left alone. What the script links and when it prunes a tree: the profile's verification file, Worktrees.
4. **Write the problem statement** to `<tree>/.analysis/<slug>/problem.md`. `<slug>` is the branch with `/` turned into `-`, the folder `verify.sh` logs to; the file survives a compaction or a usage limit. It holds what happens, what should happen, the smallest reproduction, the platform and the environment. A code pointer from the reporter is a hint, not a fact.
5. **Choose the mode.** *Direct* when, after reading the code yourself, you can point at the line that causes it, the correct behavior is not in doubt, and the fix stays in one subsystem without changing an interaction or adding a feature: you investigate alone. *Full* otherwise, or when unsure: the investigation fans out to lanes. A Direct run that finds the cause elsewhere switches to Full.

## Phase 1: Investigate

Answer three questions. Full mode gives each to a lane (`references/lanes.md`).

- **Cause** (`trace`). The code path the reported scenario takes, proven from the dispatch code when several paths exist; the mechanism, apart from the symptom; the blast radius, meaning every input, type, engine and sibling surface the same cause reaches.
- **Correct behavior** (`research`, skipped for purely internal logic). For UI, the design guideline and the documented API, checked against the platform's API ground truth and its version floor. For a driver, the dependency's own source at the version we ship. For a new feature or a changed interaction, also comparable clients. Sources: the profile's research file.
- **Related defects** (`hunt`). What else is broken in the code this change touches, and where else the same cause or pattern lives. Only defects with a concrete failure scenario count.

**What ships.** Every verified defect ships, wherever it sits: in code the change touches, in code that shares its cause or pattern, or in code a lane or reviewer walked past. So does every gap a lane finds in the behavior the report asks for. A defect in this app ships in this PR; one in another app ships in that app's PR (Platform). There is no "Not in this PR" list.

- **A trade-off is not a reason to leave a defect.** When every fix seems to break something else, keep looking for the design that holds both; when none exists, it is a product decision: ask (Autonomy).
- **Only a forbidden step is left for the user**: a library or plugin publish, a CloudKit schema deploy, a tag (Autonomy). Build and verify everything up to it, and name the step in the PR body under "Needs the maintainer".

**Verify each related defect before it enters scope**: read the cited code, check nothing upstream prevents the failure, check the path is reachable. In Full mode one `verify` lane takes the whole list.

**Measure, do not assume.** When the fix rests on how a library, a binary dependency or a framework behaves, run a probe against what we ship; the profile's research file says how. An unmeasured claim is a hypothesis, a lane's and your own alike. A probe that settles a fact the code hard-codes by hand is committed where the profile's Ship section says.

## Phase 2: Plan

Write `<tree>/.analysis/<slug>/plan.md`, under 80 lines, opening with a progress log you keep current:

- the root cause, as a mechanism;
- **refactor or patch**, with the reason: refactor when the current shape cannot express the correct behavior without a special case, the bug comes from a wrong model, or a patch leaves the same class of bug alive; patch when the design is sound and the mistake is local;
- the design: the API or pattern, its ownership boundary, the design guideline;
- the scope as a checklist: files in order, blast-radius cases, each verified defect with `file:line` and the app whose PR it ships in;
- the tests that fail before the fix, in the targets the profile's Done section says to check first;
- the changelog fragment, docs, localization and screenshots the change needs.

**Rules read.** List the files `plan.md` touches. Read `<tree>/AGENTS.md` and the platform guide the profile's Done section names, then every `<tree>/.claude/rules/*.md` whose `paths:` header matches one of them, and name them on a `Rules read:` line in `plan.md`. A file added later gets the same check before you edit it. The tree's copies are the ones that apply; a harness may have loaded another checkout's.

In Full mode the `critic` lane attacks the plan; fold in what survives an evidence check. Then implement.

## Phase 3: Implement

- When the change is visible on screen, build the fresh tree and capture the "before" shots first.
- Follow the plan's order and do the refactor it calls for. Apply the guide's per-change checklist while you write, not afterwards.
- **A large change may be split across implementers**: when the plan spans areas that share no files, give up to six subagents a disjoint file list each in `plan.md`. Each prompt names the tree, `plan.md` and the exact files the implementer owns, and says to edit nothing else, build nothing, and finish with the files it changed. You read every diff, integrate and verify. The harness file says which agent runs them.
- Competitors are research only: never name another client in code, commits, the PR, a changelog fragment or docs.

## Phase 4: Verify

Run every step through the tree's wrapper, written out in full each time, since a variable holding the command does not word-split in zsh:

```bash
<tree>/.claude/skills/fix-issue/scripts/verify.sh --root <tree> --no-wait <step>
```

The profile lists the platform's steps and when each runs; the guide's Every change section adds the rest.

- Check that the `root:` line names your tree, then read the verdict line. What each verdict means is in the platform guide's Commands section.
- **Verify in batches**: build once after a coherent set of edits, then re-run only a failed step.
- **Never run two builds in one tree.** `--no-wait` does not wait for a build already running there, and the second one fails on the locked build database.
- **Pick tests by what you changed**, not by the test files you edited, and compare the executed count with what you meant to run.
- **INCONCLUSIVE is the environment**: report it, never debug your code for it. The profile's verification file has the remedies.
- When cheap, show the new test failing on the old code.

## Phase 5: Review

A model that did not write the diff reviews all of it; the harness file names the reviewer. In Full mode the first round adds an adversarial pass on the design. Add a security pass when the change touches credentials, SQL construction, query execution, plugin loading, MCP or AI permissions, or sync, and any pass the profile names.

Fix every real finding without asking, pre-existing behavior included (Phase 1, What ships). Re-verify and review again until a round finds nothing real. When a fourth round still finds new defects in this change's own code, the design is wrong: go back to Phase 2.

## Phase 6: Ship

1. **Stage explicit paths**, never `git add -A`, `.` or a directory, and compare `git -C <tree> diff --cached --stat` with what you changed.
2. **Run `scripts/check-banned-words.sh --staged`**, and the same script over the PR body file.
3. **Commit, then push, in separate calls**, after `git -C <tree> branch --show-current` in a call of its own. The PR title becomes the squash commit subject; its format and types are in the top comment of `.github/pull_request_template.md`. Never override the git identity. If SSH fails: `git -c credential.helper='!gh auth git-credential' push https://github.com/TableProApp/TablePro.git <branch>`.
4. **Open the PR, ready for review**: `gh pr create --repo TableProApp/TablePro --base <base> --head <branch> --title "<subject>" --body-file <file>`, where `<base>` is the profile's pull request base. The body follows `.github/pull_request_template.md` and reads in under a minute. It is not a log: no investigation story, no review history, no list of every test run.
5. **Screenshots**, only when the change is visible: before and after, light and dark, from an isolated build captured the way the profile's Screen section says. Look at each one before using it. Attach with `gh pr create --attach './after.png#After'` and reference it as `![After](./after.png)`.

## Phase 7: Land

Watch the checks until they finish. `gh pr checks <n> --repo TableProApp/TablePro --watch --interval 60` exits when every check is done, nonzero when one failed; `gh run view <run-id> --log-failed` prints a failed job's log. The harness file says how to wait without spending tokens.

- A red check: read it with the profile's verification file (Reading CI) before changing anything.
- A check this PR broke: fix it, re-verify, push a new commit.
- A merge conflict: `git -C <tree> fetch origin <base> && git -C <tree> merge origin/<base>`, resolve, re-run the profile's first step (the base may have added files), re-verify, push. Never rebase or force-push.
- A check that is not this PR's (red on the base branch too, a runner fault), or one still queued after 45 minutes with no job started: leave it and report it.

Stop after two rounds of CI fixes. Never merge the PR.

## Phase 8: Report

At most eight lines, in the user's language: the PR links first, what they fix (the issue and each bundled defect, one line each at most), the root cause in one sentence, the CI state, who reviewed it, and any step that needs the maintainer.
