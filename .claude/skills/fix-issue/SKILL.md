---
name: fix-issue
description: >-
  Root-cause fix workflow for the TablePro macOS app. Use whenever the user wants to fix a
  GitHub issue (by number or URL) or a described bug, behaviour gap, or UX problem, and cares
  about doing it the right way: native AppKit/SwiftUI, Apple HIG, clean architecture, full
  scope, no quick patches. It orchestrates the investigation as a multi-agent workflow
  (codebase tracing, platform/API research, competitor UX, collateral defect hunting),
  synthesizes a refactor-aware blueprint, has that blueprint attacked, implements to
  TablePro's standards, agrees the approach with the user before writing code, builds and
  tests and lints through the verification wrapper, opens the pull request on its own, and
  reports every other defect it found with the evidence, shipping only the ones the primary
  fix is unsafe without.
  Trigger on things like "fix issue #1234", "fix this bug", "this should behave like a native
  app", "do this properly / natively", or any non-trivial defect or behaviour gap in the app.
  Prefer this over an ad-hoc fix when the change touches UI behaviour, architecture, or
  anything the user expects to match Apple conventions.
---

# Fix Issue

A disciplined way to fix a TablePro problem so the result is correct, native, and complete, not a patch over a symptom. The core idea: understand before you build, build the version Apple would ship, prove it against the artifact we actually ship, and leave the subsystem better than the issue found it.

Low-quality fixes fail for five reasons: the author did not trace how the code actually behaves, did not check what the platform documents as correct, believed a plausible claim instead of measuring it, stopped at the first change that made the symptom disappear, or never built the result. This skill attacks all five.

**It stops once, at one gate.** Invoking it is the authorization to investigate, design, implement, verify, commit, push and open the pull request without asking again. The single exception is the Phase 2 gate: once the blueprint has survived its critique you present the approach and wait, because the cheapest place to catch a wrong direction is before the diff rather than in review. Everything on either side of that gate proceeds on its own. Stop early only when verification fails, and then say exactly what failed.

## When to use this

Use it for any non-trivial fix: a bug, a wrong behaviour, a UX gap, "make this work like \<other app\>", or "do this the proper native way". It matters most when the change touches UI behaviour, AppKit/SwiftUI internals, a driver plugin, or anything the user expects to match Apple conventions.

Skip the investigation workflow for genuinely trivial edits (a typo, a renamed constant, a one-line guard with an obvious cause). Still run Phase 3 onward for those, because the branch, build, test, lint, and CHANGELOG rules apply to every change. If you are unsure whether a fix is trivial, it is not.

Run at high effort. The investigation and the adversarial passes are where the quality comes from, and they are worth their cost.

## The standard this skill holds to

`CLAUDE.md` at the repo root defines done: the principles, the mandatory rules (CHANGELOG, localization, docs, lint, tests, conventional commits, writing style), and the **Invariants** section listing the patterns that have already caused real bugs. Cite it rather than restating it; when the two disagree, `CLAUDE.md` wins.

The standing preference is the complete, Apple-correct fix grounded in documented APIs. Never pitch a phased, minimal, or quick-win version as the answer, and never implement the user's literal UI suggestion when research says a different native mechanism is correct. Say what the correct approach is, then build that. Native means documented AppKit, SwiftUI and system behaviour, with the HIG rule for the interaction quoted in the blueprint, and with keyboard access, focus, selection, undo and the responder chain still intact afterwards.

### Refactor or patch: the central decision

Every fix forces this call, and it is the one the gate exists to confirm. Make it explicit.

**Refactor** when the current structure cannot express the correct behaviour without a special case that fights the existing shape; when the bug is a symptom of a design that is wrong for the real requirement, such as a boolean where the state is multi-valued or logic in a view that belongs in a model; or when fixing only the reported case would leave the same class of bug latent elsewhere.

**Patch** when the design is sound and the bug is a genuine local mistake: an off-by-one, a missing guard, a wrong comparison, a stale mapping.

The failure mode to avoid is patching a symptom so the reported case disappears while the cause stays. A minimal stopgap is never offered as an equal alternative to the real fix. That is a different thing from the gate, which does present genuine design alternatives when the investigation found more than one defensible shape: choosing between two real designs is the user's call, choosing to do less than the correct fix is not.

### Measure, do not assume

The single highest-value habit in this skill. When the fix depends on how a binary dependency, a C library, or a system framework actually behaves, **write a probe and run it against the artifact we ship**, rather than trusting documentation, an agent's report, or your own recall.

A probe is cheap: a C file compiled against the real `Libs/*.a` and the vendored header, a `swiftc` harness, a SQL statement run through the vendored CLI. It routinely overturns claims that three independent sources agreed on. Treat an unverified claim as a hypothesis no matter how confidently it was stated, including when you stated it.

When the probe settles a fact that the codebase then hard-codes by hand, commit the probe as a script under `scripts/` so a future dependency bump re-checks it instead of trusting a transcription. `scripts/check-pluginkit-abi.sh` and `scripts/check-duckdb-value-api.sh` are the shape.

## Phase 0: Intake

Get a precise problem statement, and a safe place to work, before touching anything.

When the session exposes `TodoWrite`, open a list here with the phases this run will actually use and keep it current: it is how the user follows a long run without asking, and it is what tells you where you were after a compaction. The tool is not present in every session, so fall back to stating the phase in the thread at each boundary rather than planning around it.

1. **Read the report.** Given an issue number or URL: `gh issue view <number> --repo TableProApp/TablePro --comments`. Read the body and every comment; reporters often clarify the real complaint in follow-ups. Given a chat description: restate it in one sentence naming the observable wrong behaviour against the expected behaviour.
2. **Capture the specifics.** Reproduction steps, screenshots, database type, macOS version. These shape what the investigators look for.
3. **Treat any code pointer in the issue as a hint, not a fact.** Reporters point at the wrong file often. Verify it and follow the evidence where it actually leads.
4. **Check the tree.** Run `git branch --show-current` and `git status --porcelain`. If the tree is dirty with unrelated work, ask the user how to proceed before creating a branch. Never silently stash someone else's uncommitted changes; a mid-session branch move drops uncommitted edits to tracked files.

End Phase 0 with a written problem statement: what happens now, what should happen, and the smallest reproduction. If the expected behaviour is genuinely ambiguous, meaning two reasonable readings lead to different fixes, resolve it with `AskUserQuestion` now, before spending the investigation on a guess. That is the one question worth asking, and it is about the requirement, never about permission to proceed.

## Phase 1: Investigation workflow

Run the investigation with the `Workflow` tool. This skill's instructions are the opt-in the tool requires, so no further user consent is needed. The full script, with the agent charters written out, is in `references/orchestration.md`. Read it before calling.

The script fans out four investigators, then adversarially verifies what the collateral hunter found:

| Role | Answers |
| --- | --- |
| Codebase tracer | How does the relevant code actually work today? Which files, types, and call paths are involved? Where is the real cause, as opposed to the symptom? |
| Platform researcher | What do Apple's HIG and framework docs, or the vendored header of the dependency in play, say the correct behaviour and the right API are? |
| Competitor / UX researcher | How do TablePlus, DataGrip, Postico, and Sequel Ace handle this? What interaction do users expect? |
| Collateral hunter | What **else** is wrong in the subsystem this fix touches? This feeds Phase 6, and it is the reason the skill leaves the area better than it found it. |

Give every agent the Phase 0 problem statement verbatim and a sharp question. A vague brief produces a vague report. Require concrete evidence: `file:line` for code, a doc URL or exact symbol name for platform claims, a named source for competitor behaviour, a reproduction for a collateral finding.

### Orchestration notes

- **Hardcode the inputs in the script.** The `args` parameter has failed to reach the script global before. Paste the problem statement into the script as a string.
- **The workflow runs in the background.** You are notified when it completes. Do not report, assume, or invent its results before the notification arrives.
- **Its report goes to you, not the user.** Relay what matters in your own words.
- **Verify load-bearing claims yourself.** An agent's confident report is evidence, not proof. Anything the design depends on gets a probe, a header grep, or a read of the actual file. Agents in this session have been wrong in both directions on exactly the facts that decided the architecture.
- **The three reporting lanes come back as a capped digest**, not prose: a verdict, a confidence label, and up to eight anchors. That schema is the only enforceable limit on what a lane can send, because a subagent's final message has none. Read each anchor the plan will depend on rather than trusting the claim beside it, and when a digest is thin on the one question you care about, ask that lane a narrow follow-up instead of re-running the phase. What did not fit is still in the lane transcript and in the run's `journal.jsonl`.
- **Do not chase parallelism at the cost of the brief.** If the `Workflow` tool is unavailable, run the same charters with the `Agent` tool in one message, or in sequence yourself. Parallelism is a latency optimization; the evidence bar is what determines the fix.

## Phase 2: Synthesis and challenge

You own the blueprint. You have every report plus the conversation context the subagents never saw, so write it yourself rather than handing it to a fresh agent that would re-derive everything.

The blueprint must answer:

- **Root cause**, stated plainly and separated from the symptom.
- **Refactor vs. patch.** Can the current structure express the correct behaviour cleanly, or does the relevant code need restructuring to do this properly? This is the most important call in the skill. If the existing design cannot express the right behaviour, say "refactor X" instead of bolting a special case onto a broken shape. The criteria are in "Refactor or patch" above.
- **The native, HIG-correct design**, naming the specific AppKit/SwiftUI API or dependency call and the documented behaviour it follows. Prefer a documented platform API over a hand-rolled equivalent.
- **Full scope.** Every file to create or change, in implementation order, plus the edge cases and the TablePro invariants from `CLAUDE.md` the change must respect.
- **Blast radius.** The reported symptom is usually one instance of a class. Say how many cases the root cause actually covers, and cover all of them.
- **Tests** that would have caught the bug: the unit test always, plus `TableProUITests` automation when the fix changes a user flow and that flow runs deterministically. If it does not run deterministically, say so and why, so it can go in the PR description. Name the CHANGELOG and `docs/` updates the fix requires.
- **The collateral register.** Every finding that is real but is not the reported bug, with its evidence and its disposition. Phase 6 consumes this.

**Then have the blueprint attacked**, with a second `Workflow` call that runs three critics on distinct lenses: does it fight existing codebase patterns, what scope is missing, and is the refactor-vs-patch call right. Script in `references/orchestration.md`. Fold what survives into the blueprint. Skip the challenge only for a contained single-file fix.

### Gate: agree the approach before writing code

Once the blueprint has survived the challenge, present it and wait. This is the one approval gate in the skill, and it exists because the cheapest place to catch a wrong direction is before the diff, not in the PR.

Keep it short enough to read in a minute. Not the blueprint itself, which is long: the decision inside it.

- **The root cause**, as a mechanism rather than a symptom, in one or two sentences.
- **The approach you recommend**, named as the ownership boundary it sits at and the API or pattern it follows. When the investigation surfaced a genuine alternative, give two or three with the trade-off between them and say which you would take and why. When there is only one correct native answer, say that plainly instead of inventing options.
- **The refactor-vs-patch call**, with its reason. This is where a wrong answer costs the most, so it gets its own line.
- **Scope and non-goals**: how many cases the root cause covers, and what you are deliberately not doing.
- **What you will verify**, and any question the investigation itself raised.

**Present it with `ExitPlanMode`.** That is the native approval affordance: the user gets an accept or reject control instead of having to type a reply, and rejecting keeps you out of the edit. Put the summary above in the plan body. Use `AskUserQuestion` instead only when the decision is a choice between named options that needs answering before a plan can be written at all, and put your recommendation first.

Two things this gate is not. It is not a request for permission to investigate, verify, or ship, all of which you already have. And it is not an invitation to pitch a smaller version: the recommendation is still the complete, Apple-correct fix, and a phased or quick-win option only appears if the user asks for one.

Skip the gate for a contained single-file fix whose cause is proven and whose fix is mechanical, the same bar that skips the challenge pass. Report the direction alongside the diff instead.

## Phase 3: Implementation

- **Branch first.** `git checkout -b <type>/<slug>` off the current base in the main checkout. Default to the main checkout, not a worktree; use a worktree only when the tree already holds unrelated in-flight work and the fix needs its own PR, and say so before doing it. When you do need one, create it with `.claude/skills/fix-issue/scripts/worktree.sh <branch>`, which also symlinks `Secrets.xcconfig`, `Libs/*.a`, `Libs/dylibs`, and `Libs/ios`. Without those a fresh worktree fails before it compiles, with an "Unable to open base configuration reference file" error that reads like a broken toolchain. Then pass `--root <worktree>` to `verify.sh`, and run its `generate` step before the first build, because the worktree has its own generated project.
- **Follow the blueprint's file order.** Do the refactor it calls for. Do not quietly downgrade to a patch because the refactor turned out to be more work.
- **Regenerate after adding a file.** A new `.swift` file is not compiled until `scripts/generate-project.sh` runs. The symptom is `cannot find 'X' in scope` from the callers, which reads like the code was never written.
- **Honour the mandatory rules as you go**, not as cleanup: `String(localized:)` for user-facing strings and never with interpolation, `CHANGELOG.md` under `[Unreleased]`, `docs/` for shortcut, UI, settings, or driver changes, OSLog instead of `print`, no comments, early returns, explicit access control.
- **A docs page that describes UI carries a screenshot.** Prose alone does not show a user what a pane looks like, and every existing feature page in `docs/features/` pairs its description with one. When the change adds a screen, pane, tab, dialog or toolbar, add a `<Frame>` with the light and dark pair the docs use, `docs/images/<name>.png` and `docs/images/<name>-dark.png`, referenced as `className="block dark:hidden"` and `className="hidden dark:block"`. When the change alters a screen an existing page already pictures, the old shot is now wrong: re-capture it or say in the PR that it needs re-capturing. Real shots come from a running Debug build driven with `osascript` and captured with `screencapture`, launched with `TABLEPRO_UI_TEST_SANDBOX` pointed at a throwaway directory so it never touches your own connections; Screen Recording has to be granted to whatever runs it. When you cannot capture one, still add the `<Frame>` and commit a placeholder at the same 1560x960 the other shots use so the page renders, and call it out in the PR body as pending. Never leave the markup pointing at a file that does not exist; a broken image ships to the docs site.
- **Write the tests the blueprint specified**, unit and UI both. UI suites subclass `UITestCase`; a bare `XCUIApplication()` or `: XCTestCase` under `TableProUITests/` fails a source-scanning guard test, because storage isolation depends on the launch path. When a test fails, fix the source. Never bend a test to match wrong output.
- **Run `Skill(swiftui-pro)`** when the change adds or reworks SwiftUI views, before you consider the code done.

## Phase 4: Verify

You build and test this yourself. Do not hand unverified code back and ask the user to surface compile errors. The full playbook, including the environment setup that makes local `xcodebuild` and `swiftlint` work, is in `references/verification.md`.

**Run every step through the wrapper.** It keeps the full log on disk and prints at most about thirty lines, ending in a verdict of `PASS`, `FAIL`, or `INCONCLUSIVE`:

```bash
.claude/skills/fix-issue/scripts/verify.sh generate
.claude/skills/fix-issue/scripts/verify.sh build
.claude/skills/fix-issue/scripts/verify.sh test <SuiteYouTouched> [Suite…]
.claude/skills/fix-issue/scripts/verify.sh uitest <SuiteYouTouched>
.claude/skills/fix-issue/scripts/verify.sh plugins            # AllPlugins aggregate
.claude/skills/fix-issue/scripts/verify.sh abi <merge-base>
.claude/skills/fix-issue/scripts/verify.sh lint <path> [path…]
.claude/skills/fix-issue/scripts/verify.sh tail <log> [n]     # re-read a stored log
```

This is not a convenience. A raw `xcodebuild` failure returns roughly 10,000 characters as a head-and-tail excerpt **with no log file path**, so the one case where you need the whole output is the one case you cannot get it back. The wrapper also exports `DEVELOPER_DIR`, resolves the project explicitly so a drifting shell cannot build the wrong checkout, waits for any other `xcodebuild` on the machine, and cross-references both quarantine lists before it calls anything a failure. Exit codes are `0` pass, `1` fail, `2` inconclusive.

`INCONCLUSIVE` means the environment failed, not your change. The wrapper names the cause. Never record it as a pass, and never start debugging your own code on one: the nastiest signature is a locked build database, where every case reports `failed` at `0.000 seconds` and reads exactly like a mass regression.

**Run the slow steps in the background.** A Debug build and the `plugins` aggregate take minutes, and a foreground `Bash` call blocks the whole session for them. Pass `run_in_background: true` and you are re-invoked when the step exits, so the wait costs nothing. Keep `generate` and short `lint` runs in the foreground, where the round trip is not worth it. Background steps still run one at a time: never have two `xcodebuild` processes in flight, backgrounded or not.

Non-obvious rules that decide whether the result means anything: run only the suites you touched and their neighbours, never the whole target; run the steps serially; and build the `plugins` aggregate yourself if the change touched a registry-only plugin, because PR CI never compiles those.

Where the fix rests on how a dependency behaves, finish with the before-and-after probe from "Measure, do not assume". A probe that reproduces the bug on the old path and shows every case correct on the new one is the strongest evidence a PR can carry.

UI tests have their own trap list, including an accessibility tree that differs between this machine and the CI runner, and a SwiftUI container identifier that silently erases every child's. Read `references/verification.md` before writing one.

## Phase 5: Review, commit, and open the primary PR

1. **Self-review the diff.** Run `Skill(code-review)` on the change. Fix what it finds, or say why a finding does not apply. Treat its findings on your own edits as seriously as its findings on old code; this pass has already caught a CHANGELOG heading deleted by a careless `Edit`.
   - **`Skill(security-review)`** as well whenever the change touches a security boundary: credentials, keychain, SQL construction, query execution, plugin loading, MCP, AI tool permissions, sync, or anything that widens what a user or a plugin can do. It reviews the pending changes on the branch, so run it after the diff is complete and before the commit.
   - **`Skill(simplify)`** when the change grew past a couple of files. It is a quality pass for reuse and duplication rather than a bug hunt, which is the gap `code-review` leaves.
   - Each of these reads the diff itself. Do not paste the diff into the thread to prepare for them.
2. **Check the CHANGELOG survived.** After any edit to `CHANGELOG.md`, run `grep -n '^## \[' CHANGELOG.md` and confirm the released version headings are still there. An `Edit` whose `new_string` drops the trailing context silently folds a shipped release into `[Unreleased]`, and the next release notes then re-ship it.
3. **Writing-style gate.** Stage the change, then run the grep from `CLAUDE.md` over the staged diff for em dashes and banned filler words. Rewrite every hit that is on an added line.
4. **Verify the branch, in its own call, immediately before committing.** `git branch --show-current`. The checkout can move between turns, and chaining `commit && push` has already pushed straight to `main` once. Never chain them.
5. **Commit.** Conventional Commits: single line, no body, canonical scope from `CLAUDE.md`. Never pass `-c user.email` or `-c user.name`; the repo identity is already correct and overriding it has shipped unattributed commits.
6. **Push.** `git push -u origin <branch>`. If SSH fails, port 22 is blocked here; push over HTTPS with the `gh` credential helper instead:
   ```bash
   git -c credential.helper='!gh auth git-credential' push https://github.com/TableProApp/TablePro.git <branch>
   ```
7. **Open the PR.**
   ```bash
   gh pr create --repo TableProApp/TablePro --base main --head <branch> --title "<commit subject>" --body-file <file>
   ```
   Write the body to a file rather than passing it inline, so the writing-style grep can run over it first. The body states the root cause, the fix, and what you built and tested, and it closes the issue with `Fixes #<number>`. If a UI flow could not get deterministic automation, say so here: the PR description is the only place that exemption is recorded.

   **A change the user can see gets before-and-after screenshots in the body.** Any change to a pane, tab, dialog, toolbar, menu, cell, row or empty state is a visual claim, and a reviewer cannot check a visual claim by reading a diff. Put the two shots side by side under a `## Before / After` heading, captioned with what to look at, so the reviewer sees the difference rather than reconstructing it. For a brand-new screen there is no before: show the after alone and say so. Capture from a running Debug build, driven with `osascript` and captured with `screencapture`, launched with `TABLEPRO_UI_TEST_SANDBOX` so it runs against throwaway storage. Upload with `gh pr comment` or drag into the PR, and never link a file that only exists on your machine. When a shot is genuinely impossible, say in the body which state could not be captured and why, rather than omitting the section silently. The same shots usually belong in `docs/` too, so take them once and use them twice.

If the fix is stacked on another in-flight branch, base the PR on that branch instead of `main` and say so, rather than dragging the other work into this PR.

## Phase 6: Dispose of the collateral findings

**An investigation that finds three defects and reports one has failed at the part that mattered most.** The hunt is not optional and neither is saying what it found. What is optional is building it: only a finding the primary fix is unsafe or incomplete without ships on its own. Everything else is reported precisely and left for the user to decide.

### Disposition

Sort every register entry into exactly one of three:

1. **Blocking, so it ships with the fix.** The primary fix is wrong, unsafe, or incomplete without it, which is the `blocksPrimaryFix` flag from the investigation. The test: would shipping the primary fix alone make this defect more likely to bite, or leave the same class of bug latent? If yes it is not collateral, it is scope, and it ships without asking. Fold it into the primary diff by default. When it is genuinely separable and large enough to deserve its own review, make it a prerequisite PR and base the primary on that branch, saying so in both bodies. In the DuckDB timestamp fix, routing common types through an existing cast path made that path's row-misalignment and unbound-parameter bugs go from rare to routine, so both belonged with the primary change.
2. **Verified but independent, so report it and stop.** A real defect the primary fix does not depend on. Do not open a PR for it, do not fold it in, and do not file it as an issue. Write it into the final report and let the user choose. This is the default for anything that clears the bar.
3. **Drop it.** The evidence did not survive verification, the path is not reachable in the shipping app, or fixing it needs a product decision. Say so plainly with what you found and why you stopped.

### The bar for reporting one at all

All of these, or it is noise and goes unmentioned:

- It is a **defect or a concrete correctness risk**, with a failure scenario someone could actually hit. Not naming, not taste, not "I would have structured this differently".
- The evidence **survived verification**. A plausible-sounding claim nobody confirmed is a hypothesis. Probe it or drop it.
- Nothing upstream already prevents it.
- It lives **in this repository**. Another target counts: `TableProMobile`, a registry-only plugin, and `scripts/` are all in scope.

### How to report them

Each entry gets its `file:line`, one line on the defect, the concrete failure scenario, how it was verified, and a size estimate. That is enough for the user to say yes or no without reopening the investigation, which is the whole point of writing it down properly.

Say explicitly when the register is empty. A clean subsystem is a real result, not a gap in the report.

### When a blocking finding ships

- **Primary PR first, always.** It is what the user asked for.
- **Run Phases 3 through 5 in full**, including the prerequisite PR when there is one. Tests, build, `plugins` when a registry plugin moved, lint, CHANGELOG, code review, style gate. Code nobody asked for is not exempt from the quality bar; it is the most likely to be judged on it.
- **Say why it exists** in the body: found while investigating `#<issue>`, what the defect is, its failure scenario, how it was verified, and why the primary fix is not safe without it.
- **Autonomy is not a licence for risk.** The standing safety rules hold: nothing destructive or irreversible, no force-push, no rewriting history, no touching release tags, no publishing plugins or libraries. Those still get asked about.

## Phase 7: Report

Close with the pull request opened, what it fixes, and its verification verdicts with their log paths. Then, in your own words, the root cause and how the fix maps to it, and plainly what you built and tested.

Then the collateral register, which is the part the user cannot reconstruct: every verified finding at disposition 2, each with its `file:line`, the failure scenario, how it was verified, and a size estimate, so a yes or no does not need the investigation reopened. Say when the register is empty. List what was dropped at disposition 3 with the reason.

If part of the work was blocked, say which part and why, and confirm everything else shipped. State every check that could not run.

## Reference files

- `references/orchestration.md`: the investigation and challenge workflow scripts, with the agent charters written out. Read before Phase 1.
- `references/research-sources.md`: Apple documentation map, dependency headers, research tools, competitor apps, and what counts as evidence. The investigators use this.
- `references/verification.md`: build, test, and lint playbook, including the environment setup and the failures that are not yours. Read before Phase 4.
