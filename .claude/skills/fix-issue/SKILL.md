---
name: fix-issue
description: >-
  Root-cause fix workflow for the TablePro macOS app. Use whenever the user wants to fix a
  GitHub issue (by number or URL) or a described bug, behaviour gap, or UX problem, and cares
  about doing it the right way: native AppKit/SwiftUI, Apple HIG, clean architecture, full
  scope, no quick patches. It runs three investigators in parallel (codebase tracing, Apple
  platform research, competitor/UX research), synthesizes a refactor-aware implementation
  blueprint, gets the user's approval through the plan gate, implements to TablePro's
  standards, builds and tests and lints the result, then commits and opens the pull
  request. Trigger on things like "fix issue
  #1234", "fix this bug", "this should behave like a native app", "do this properly /
  natively", or any non-trivial defect or behaviour gap in the app. Prefer this over an ad-hoc
  fix when the change touches UI behaviour, architecture, or anything the user expects to
  match Apple conventions.
---

# Fix Issue

A disciplined way to fix a TablePro problem so the result is correct, native, and complete, not a patch over a symptom. The core idea: understand before you build, build the version Apple would ship, and prove it compiles and passes before handing it back.

Low-quality fixes fail for four reasons: the author did not trace how the code actually behaves, did not check what the platform documents as correct, stopped at the first change that made the symptom disappear, or never built the result. This workflow attacks all four.

It has one approval gate, at the plan in Phase 3. Everything after it runs to completion: implement, verify, commit, and open the pull request.

## When to use this

Use it for any non-trivial fix: a bug, a wrong behaviour, a UX gap, "make this work like \<other app\>", or "do this the proper native way". It matters most when the change touches UI behaviour, AppKit/SwiftUI internals, or anything the user expects to match Apple conventions.

Skip the investigation phase for genuinely trivial edits (a typo, a renamed constant, a one-line guard with an obvious cause). Still run Phase 4 onward for those, because the branch, build, test, lint, and CHANGELOG rules apply to every change. If you are unsure whether a fix is trivial, it is not.

## The standard this workflow holds to

Two documents define done, and neither is optional:

- `CLAUDE.md` at the repo root: principles, mandatory rules (CHANGELOG, localization, docs, lint, tests, conventional commits, writing style), and the **Invariants** section listing patterns that have caused real bugs.
- `references/quality-bar.md`: the condensed "is this fix actually done" checklist, the refactor-vs-patch decision, and the native/HIG bar.

Read `quality-bar.md` early. The user's standing preference is a complete, Apple-correct fix grounded in documented APIs. Never pitch a phased, minimal, or quick-win version as the answer, and never implement the user's literal UI suggestion when research says a different native mechanism is correct. Say what the correct approach is, then build that.

## Phase 0: Intake

Get a precise problem statement, and a safe place to work, before touching anything.

1. **Read the report.** Given an issue number or URL: `gh issue view <number> --repo TableProApp/TablePro --comments`. Read the body and every comment; reporters often clarify the real complaint in follow-ups. Given a chat description: restate it in one sentence naming the observable wrong behaviour against the expected behaviour.
2. **Capture the specifics.** Reproduction steps, screenshots, database type, macOS version. These shape what the investigators look for.
3. **Treat any code pointer in the issue as a hint, not a fact.** Reporters point at the wrong file often. Verify it and follow the evidence where it actually leads.
4. **Check the tree.** Run `git branch --show-current` and `git status --porcelain`. If the tree is dirty with unrelated work, ask the user how to proceed before creating a branch. Never silently stash someone else's uncommitted changes; a mid-session branch move drops uncommitted edits to tracked files.

End Phase 0 with a written problem statement: what happens now, what should happen, and the smallest reproduction. If the expected behaviour is genuinely ambiguous, meaning two reasonable readings lead to different fixes, resolve it with `AskUserQuestion` now, before spending the investigators' effort on a guess.

## Phase 1: Parallel investigation

Enter plan mode first (`EnterPlanMode`) unless the session is already in it. Plan mode makes the read-only investigation enforced rather than a convention, and it turns Phase 3 into a native approval gate.

Spawn three investigators with the `Agent` tool, **all in one message** so they run concurrently. Full charters and copy-paste prompt templates are in `references/investigators.md`; read it before spawning.

| Role | `subagent_type` | Answers |
| --- | --- | --- |
| Codebase Analyzer | `feature-dev:code-explorer` | How does the relevant code actually work today? Which files, types, and call paths are involved? Where is the real cause? |
| Apple Platform Researcher | `general-purpose` | What do Apple's HIG and framework docs say the correct behaviour and the right API are? |
| Competitor / UX Researcher | `general-purpose` | How do TablePlus, DataGrip, Postico, and Sequel Ace handle this? What interaction do users expect? |

Give each one the Phase 0 problem statement and a sharp question. A vague brief produces a vague report. Require concrete evidence: `file:line` for code, a doc URL or exact symbol name for platform claims, a named source for competitor behaviour.

### Orchestration mechanics

- **One message, three `Agent` calls.** Separate messages run them in sequence and waste the parallelism.
- **Subagents run in the background.** You are notified when each finishes. Do not guess at or fabricate a report before its notification arrives; if the user asks in the meantime, say it is still running.
- **Their reports are not shown to the user.** Relay what matters in your own words.
- **Follow up instead of respawning.** If a report has a gap, `SendMessage` that agent by name. It keeps its context and answers cheaply. `ListAgents` shows who is available.
- **No worktree isolation.** The investigators are read-only, so they are safe against the main checkout. `isolation: "worktree"` costs setup time and buys nothing here.
- **Do not use the `Workflow` tool.** It requires explicit user opt-in and this fan-out does not need deterministic scripting.

**If the `Agent` tool is unavailable** (for example you are already running inside a subagent), do not fake the calls. Run the three charters yourself in sequence, holding each to the same evidence bar. Parallelism is a latency optimization; the investigation quality is what determines the fix.

## Phase 2: Synthesis

You own the blueprint. You have all three reports plus the conversation context the subagents never saw, so write it yourself rather than handing it to a fresh agent that would re-derive everything.

The blueprint must answer:

- **Root cause**, stated plainly and separated from the symptom.
- **Refactor vs. patch.** Can the current structure express the correct behaviour cleanly, or does the relevant code need restructuring to do this properly? This is the most important call in the workflow. If the existing design cannot express the right behaviour, say "refactor X" instead of bolting a special case onto a broken shape. Decision criteria are in `references/quality-bar.md`.
- **The native, HIG-correct design**, naming the specific AppKit/SwiftUI APIs and the documented behaviour it follows. Prefer a documented platform API over a hand-rolled equivalent.
- **Full scope.** Every file to create or change, in implementation order, plus the edge cases and the TablePro invariants from `CLAUDE.md` the change must respect.
- **Tests** that would have caught the bug: the unit test always, plus `TableProUITests` automation when the fix changes a user flow and that flow runs deterministically. If it does not run deterministically, say so and why, so it can go in the PR description. Name the CHANGELOG and `docs/` updates the fix requires.

**Challenge the blueprint before presenting it** when the fix is a refactor, touches a documented invariant, or spans more than about three files. Spawn one `feature-dev:code-architect` with the full draft pasted in and ask it to attack the design: where does it fight existing patterns, what scope is missing, is there a better-fitting native API. Template in `references/investigators.md`. Fold what holds up into the blueprint. For a contained fix, skip this and go straight to the gate.

## Phase 3: Plan gate

Present the blueprint and get approval before writing code. The costliest mistake is implementing the wrong scope correctly.

Call `ExitPlanMode` with the blueprint. Lead with the root cause and the refactor-vs-patch call, since that is what the user most needs to weigh in on. Keep it skimmable: what is wrong, the fix, the files, the tests, and anything you are unsure about.

Do not start implementing until the user approves. If they push back on scope or approach, revise the blueprint. Do not argue for the quick version.

## Phase 4: Implementation

- **Branch first.** `git checkout -b <type>/<slug>` off the current base in the main checkout. Default to the main checkout, not a worktree; use a worktree only when the tree already holds unrelated in-flight work and the fix needs its own PR, and say so before doing it.
- **Follow the blueprint's file order.** Do the refactor it calls for. Do not quietly downgrade to a patch because the refactor turned out to be more work.
- **Regenerate after adding a file.** A new `.swift` file is not compiled until `scripts/generate-project.sh` runs. The symptom is `cannot find 'X' in scope` from the callers, which reads like the code was never written.
- **Honour the mandatory rules as you go**, not as cleanup: `String(localized:)` for user-facing strings and never with interpolation, `CHANGELOG.md` under `[Unreleased]`, `docs/` for shortcut, UI, settings, or driver changes, OSLog instead of `print`, no comments, early returns, explicit access control.
- **Write the tests the blueprint specified**, unit and UI both. UI suites subclass `UITestCase`; a bare `XCUIApplication()` or `: XCTestCase` under `TableProUITests/` fails a source-scanning guard test, because storage isolation depends on the launch path. When a test fails, fix the source. Never bend a test to match wrong output.
- **Run `Skill(swiftui-pro)`** when the change adds or reworks SwiftUI views, before you consider the code done.

## Phase 5: Verify

You build and test this yourself. Do not hand unverified code back and ask the user to surface compile errors. The full playbook, including the environment setup that makes local `xcodebuild` and `swiftlint` work, is in `references/verification.md`.

The short form:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation -only-testing:TableProTests/<SuiteYouTouched>
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation -only-testing:TableProUITests/<SuiteYouTouched>
swiftlint lint --strict <changed files>
```

Non-obvious rules that decide whether the result means anything: run only the suites you touched and their neighbours, never the whole target; check the executed-test count before believing `TEST FAILED`; cross-reference `.github/macos-test-quarantine.txt` and `.github/macos-ui-test-quarantine.txt` before blaming yourself for a failure; never run two `xcodebuild` invocations at once; and build the `AllPlugins` scheme yourself if the change touched a registry-only plugin, because PR CI never compiles those.

UI tests have their own trap list, including an accessibility tree that differs between this machine and the CI runner, and a SwiftUI container identifier that silently erases every child's. Read `references/verification.md` before writing one.

## Phase 6: Review, commit, and open the PR

**This workflow ends at an open pull request, not at a summary asking for permission.** Invoking the skill is the authorization to commit, push, and open the PR once Phase 5 is green. Do not stop after the last edit and ask whether to commit; the answer is already yes. Stop only if verification did not pass, and say what failed.

1. **Self-review the diff.** Run `Skill(code-review)` on the change. Fix what it finds, or say why a finding does not apply.
2. **Writing-style gate.** Stage the change, then run the grep from `CLAUDE.md` over the staged diff for em dashes and banned filler words. Rewrite every hit that is on an added line.
3. **Verify the branch, in its own call, immediately before committing.** `git branch --show-current`. The checkout can move between turns, and chaining `commit && push` has already pushed straight to `main` once. Never chain them.
4. **Commit.** Conventional Commits: single line, no body, canonical scope from `CLAUDE.md`. Never pass `-c user.email` or `-c user.name`; the repo identity is already correct and overriding it has shipped unattributed commits.
5. **Push.** `git push -u origin <branch>`. If SSH fails, port 22 is blocked here; push over HTTPS with the `gh` credential helper instead:
   ```bash
   git -c credential.helper='!gh auth git-credential' push https://github.com/TableProApp/TablePro.git <branch>
   ```
6. **Open the PR.**
   ```bash
   gh pr create --repo TableProApp/TablePro --base main --head <branch> --title "<commit subject>" --body-file <file>
   ```
   Write the body to a file rather than passing it inline, so the writing-style grep can run over it first. The body states the root cause, the fix, and what you built and tested, and it closes the issue with `Fixes #<number>`. If a UI flow could not get deterministic automation, say so here: the PR description is the only place that exemption is recorded.
7. **Report back** with the PR link, what changed and why mapped to the root cause, and plainly what you built and tested.

If the fix is stacked on another in-flight branch, base the PR on that branch instead of `main` and say so, rather than dragging the other work into this PR.

## Reference files

- `references/quality-bar.md`: definition of done, refactor-vs-patch criteria, native/HIG bar, mandatory-rules checklist. Read early.
- `references/investigators.md`: charters and prompt templates for the three investigators and the architect challenge. Read before Phase 1.
- `references/research-sources.md`: Apple documentation map, research tools, competitor apps, and what counts as evidence. The investigators use this.
- `references/verification.md`: build, test, and lint playbook, including the environment setup and the failures that are not yours. Read before Phase 5.
