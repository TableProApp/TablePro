---
name: fix-issue
description: >-
  Root-cause fix workflow for the TablePro macOS app. Use whenever the user wants to fix a
  GitHub issue (by number or URL) or a described bug, behaviour gap, or UX problem, and cares
  about doing it the right way: native AppKit/SwiftUI, Apple HIG, clean architecture, full
  scope, no quick patches. It runs a parallel investigation team (codebase tracing + Apple
  platform research + competitor/UX research), synthesizes a refactor-aware implementation
  blueprint, gets the user's approval, then implements to TablePro's standards. Trigger on
  things like "fix issue #1234", "fix this bug", "this should behave like a native app", "do this
  properly / natively", or any non-trivial defect or behaviour gap in the app. Prefer this over
  an ad-hoc fix when the change touches UI behaviour, architecture, or anything the user expects
  to match Apple conventions.
---

# Fix Issue

A disciplined way to fix a TablePro problem so the result is correct, native, and complete, not a patch over a symptom. The core idea: understand before you build, and build the version Apple would ship.

Most low-quality fixes fail for one of three reasons: the author didn't trace how the code actually behaves, didn't check what the platform's documented behaviour should be, or stopped at the first change that made the symptom disappear. This workflow attacks all three by splitting investigation across a parallel team, then forcing an explicit architecture decision before any code is written.

## When to use this

Use it for any non-trivial fix: a bug, a wrong behaviour, a UX gap, "make this work like \<other app\>", or "do this the proper native way". It shines when the change touches UI behaviour, AppKit/SwiftUI internals, or anything the user expects to match Apple conventions.

Skip it for genuinely trivial edits (a typo, a renamed constant, a one-line guard with an obvious cause). Spinning up a research team for those wastes time. If you're unsure, lean toward using it: the cost is a few minutes of parallel research, and the payoff is not shipping a wrong fix.

## The standard this workflow holds to

The non-negotiables live in two places, and you should treat them as the definition of done:

- `CLAUDE.md` at the repo root: principles, mandatory rules (CHANGELOG, localization, docs, lint, tests, conventional commits, writing style), and the **Invariants** section that lists patterns that have caused real bugs.
- `references/quality-bar.md`: the condensed "is this fix actually done" checklist, the refactor-vs-patch decision, and the native/HIG bar.

Read `quality-bar.md` early. It's short, and it's what separates an accepted fix from a rejected one. The user's stated preference is a complete, Apple-correct fix grounded in documented APIs; never pitch a phased or quick-win version as the answer.

## Phase 0: Intake

Get a precise problem statement before touching anything.

- If given an issue number or URL, fetch it: `gh issue view <number> --repo TableProApp/TablePro --comments`. Read the body and every comment; users often clarify the real complaint in follow-ups.
- If described in chat, restate the problem in one sentence and name the observable wrong behaviour vs. the expected behaviour.
- Note any reproduction steps, screenshots, database type, or platform detail. These shape what the investigators look for.
- Treat any code pointer in the issue as a hint, not a fact. Reporters often point at the wrong file. Verify it during investigation and follow the evidence where it actually leads.

End Phase 0 with a written problem statement: what happens now, what should happen, and the smallest reproduction. If the expected behaviour is genuinely ambiguous (two reasonable interpretations that lead to different fixes), ask the user with `AskUserQuestion` now, before spending the team's effort on a guess.

## Phase 1: Parallel investigation team

Create a team and spawn three investigators that work at the same time. They are read-only research roles, so they can all run against the main checkout without conflict.

```
TeamCreate({ team_name: "fix-issue-<short-slug>", description: "Investigate <issue>" })
```

Then spawn the three roles in a single turn so they run concurrently. Full charters and copy-paste prompt templates are in `references/team-roles.md`; read it before spawning. In short:

| Role | Agent type | Answers |
| --- | --- | --- |
| Codebase Analyzer | `feature-dev:code-explorer` | How does the relevant code actually work today? Which files, types, and call paths are involved? Where is the real cause? |
| Apple Platform Researcher | `general-purpose` | What does Apple's documentation (HIG, AppKit, SwiftUI) say the correct behaviour and the right API are? |
| Competitor / UX Researcher | `general-purpose` | How do DataGrip, Postico, Sequel Ace, and similar native clients handle this? What's the expected UX? |

Give each investigator the Phase 0 problem statement and a sharp question. Tell them to report findings as a structured message back to you, citing concrete evidence (`file:line` for code, doc URLs or API names for platform research). `references/research-sources.md` lists the documentation map and the tools each researcher should reach for (`mcp__xcode__DocumentationSearch`, `WebSearch`, `WebFetch`).

Wait for all three to report. Don't start synthesizing on partial data, and don't nag idle teammates. Idle means "done with this turn", not "stuck".

**If team tools aren't available** (for example you are already running inside a subagent that has no `TeamCreate`/`Agent`), don't fake teammate calls. Run the four role charters yourself, in order, holding each to the same evidence bar in `references/team-roles.md`. The parallel team is a latency optimization; the investigation quality, not the parallelism, is what determines the fix.

## Phase 2: Architecture synthesis

Now decide what the correct fix is. Spawn a `feature-dev:code-architect` teammate as the **Architect**, handing it all three investigation reports plus the problem statement. Its job (charter in `references/team-roles.md`) is to produce an implementation blueprint that answers:

- **Root cause**, stated plainly, distinguished from the symptom.
- **Refactor vs. patch.** Does the current structure support the correct fix, or does the relevant code need to be refactored or rewritten to do this properly? This is the most important call in the whole workflow. If the existing design can't express the right behaviour cleanly, the blueprint must say "refactor X" rather than bolting a special case onto a broken shape. See the decision criteria in `references/quality-bar.md`.
- **The native, HIG-correct design**, naming the specific AppKit/SwiftUI APIs and the documented behaviour it follows. Prefer a documented platform API over hand-rolling an equivalent (see `references/quality-bar.md`).
- **Full scope.** Every file to create or change, the order to do them in, and the edge cases and TablePro invariants the change must respect.
- **Tests** that would have caught the bug, and which docs/CHANGELOG entries the fix requires.

The Architect is read-only; it returns the blueprint as its message. You own the final blueprint: review it, fill any gap, and make sure it actually clears `quality-bar.md`.

Once you have the blueprint, shut the team down (`SendMessage` with `{type: "shutdown_request"}` to each teammate). Implementation happens next in the main checkout, not in the team.

## Phase 3: Plan gate

Present the blueprint and get approval before writing code. This gate exists because the costliest mistake is implementing the wrong scope correctly.

Write the blueprint to a plan and request approval with `ExitPlanMode` (if the session is in plan mode) or by presenting the plan clearly and pausing for an explicit go-ahead. Lead with the root cause and the refactor-vs-patch call, since that's what the user most needs to weigh in on. Keep it skimmable: what's wrong, the fix, the files, the tests, anything you're unsure about.

Do not start implementing until the user approves. If they push back on scope or approach, revise the blueprint, don't argue for the quick version.

## Phase 4: Implementation

Implement the approved blueprint.

- **Branch first.** Create a fresh branch off `main` in the main checkout (not a worktree) for a bug fix; reserve worktrees for net-new feature work. Run `git branch --show-current` first if the session has been long, since a mid-session merge can silently land you back on `main`.
- Follow the blueprint's file order. Do the refactor it calls for; don't quietly downgrade to a patch because the refactor is more work.
- Honour the mandatory rules in `CLAUDE.md` as you go, not as an afterthought: `String(localized:)` for user-facing strings, `CHANGELOG.md` under `[Unreleased]`, `docs/` updates for feature/shortcut/setting changes, OSLog not `print`, no comments, early returns, explicit access control.
- Write the tests the blueprint specified. When a test fails, fix the source, never bend the test to match wrong output.

## Phase 5: Verify and hand off

- **Lint:** `swiftlint lint --strict` on the changed files, and `swiftformat` if formatting drifted. Fix what it reports.
- **Build:** the user builds and runs Xcode themselves. Don't run `xcodebuild` to "verify"; instead tell the user it's ready to build and ask them to report any compile errors (they'll paste them as one-liners).
- **Writing-style gate** before committing anything user-facing: run the `git diff --cached` grep from `CLAUDE.md` for em dashes and banned filler words, and rewrite any hits.
- Summarize what changed and why, mapped back to the root cause. Offer to commit with a Conventional Commits message (single line, correct scope). Commit or push only when the user asks.

## Reference files

- `references/quality-bar.md`: definition of done, refactor-vs-patch criteria, native/HIG bar, mandatory-rules checklist. Read this early.
- `references/team-roles.md`: charters and prompt templates for the four roles. Read before Phase 1.
- `references/research-sources.md`: Apple documentation map, research tools, and competitor apps. The researchers use this.
