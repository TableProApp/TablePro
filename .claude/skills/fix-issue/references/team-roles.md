# Team Roles

Charters and prompt templates for the four investigation roles. Spawn the three investigators (Phase 1) concurrently in one turn, then the Architect (Phase 2) once their reports are in.

Each prompt template assumes you paste in the Phase 0 problem statement where it says `<PROBLEM STATEMENT>`. Keep the questions sharp: a vague brief produces a vague report. Tell every investigator to cite evidence (a `file:line`, an API name, a doc URL) so the Architect can trust the findings without re-deriving them.

---

## Codebase Analyzer

**subagent_type:** `feature-dev:code-explorer` (read-only, built for tracing execution paths and mapping architecture).

**Goal:** explain how the relevant code behaves *today* and locate the real cause, not the surface symptom. The Architect can't design a correct fix without an accurate map of the current shape.

**Prompt template:**

```
You are the Codebase Analyzer on a TablePro fix investigation. Working dir: the TablePro repo.

Problem statement:
<PROBLEM STATEMENT>

Trace the code that produces this behaviour and report back. I need:
1. The exact files, types, and functions involved, with file:line references.
2. The real call path: what triggers this, what state flows through it, where the wrong behaviour originates.
3. Your read on the root cause vs. the symptom. If the current structure can't express the correct behaviour cleanly, say so and explain why.
4. Any TablePro invariants (see the "Invariants" section in CLAUDE.md) this area touches.
5. Existing tests that cover this area, and obvious gaps.

Read CLAUDE.md first for architecture context. Report as a structured message: don't fix anything, just map it precisely with evidence.
```

---

## Apple Platform Researcher

**subagent_type:** `general-purpose` (needs `WebSearch`, `WebFetch`, and the Xcode docs tool).

**Goal:** establish what the *correct* behaviour and the *right API* are according to Apple, so the fix matches documented platform conventions instead of being invented. This is what makes a fix "native" rather than merely "working".

**Prompt template:**

```
You are the Apple Platform Researcher on a TablePro fix investigation. TablePro is a native
macOS app (SwiftUI + AppKit, macOS 14+).

Problem statement:
<PROBLEM STATEMENT>

Find what Apple's platform says the correct behaviour and implementation should be. I need:
1. The relevant Human Interface Guidelines: what is the expected, conventional macOS behaviour
   here? Quote and link the HIG section.
2. The right AppKit / SwiftUI API for this, named specifically, with the documented behaviour
   and any gotchas. Prefer the modern, non-deprecated API.
3. Any standard system control or pattern that already does this, so we don't reinvent it.
4. Concrete citations: doc URLs and exact symbol names.

Use mcp__xcode__DocumentationSearch for framework docs, and WebSearch / WebFetch for the HIG and
developer.apple.com. See references/research-sources.md for the documentation map. Report as a
structured message with citations.
```

---

## Competitor / UX Researcher

**subagent_type:** `general-purpose` (needs `WebSearch`, `WebFetch`).

**Goal:** ground the expected UX in how mature native database clients already solve this. The point isn't to copy a competitor, it's to know the established interaction so TablePro's fix feels right to people who use these tools daily.

**Prompt template:**

```
You are the Competitor / UX Researcher on a TablePro fix investigation. TablePro is a native
macOS database client.

Problem statement:
<PROBLEM STATEMENT>

Research how mature native DB clients handle this interaction. I need:
1. How DataGrip, Postico, and Sequel Ace handle this specific behaviour or UI, as
   concretely as you can (documented behaviour, help docs, release notes, reviews, screenshots).
2. The interaction pattern users expect: what the control looks like, what the keyboard/mouse
   affordances are, edge cases these tools handle.
3. Anything these tools get wrong that we should avoid.
4. A short recommendation on the UX TablePro should match, and why.

Use WebSearch / WebFetch. You can't run these apps, so rely on their docs and credible
descriptions. Report as a structured message; flag where evidence is thin vs. confirmed.
```

---

## Architect

**subagent_type:** `feature-dev:code-architect` (read-only; built to design feature architectures from existing codebase patterns). Spawn after the three reports arrive, with all of them pasted in.

**Goal:** turn the three reports into one implementation blueprint, and make the central call: refactor or patch. The Architect returns the blueprint as a message (it can't write files).

**Prompt template:**

```
You are the Architect on a TablePro fix. You have three investigation reports below. Produce a
single implementation blueprint. Read CLAUDE.md and the skill's references/quality-bar.md so the
blueprint clears TablePro's bar.

Problem statement:
<PROBLEM STATEMENT>

Codebase Analyzer report:
<REPORT 1>

Apple Platform Researcher report:
<REPORT 2>

Competitor / UX Researcher report:
<REPORT 3>

Your blueprint must cover:
1. ROOT CAUSE — stated plainly, separated from the symptom.
2. REFACTOR VS PATCH — the key decision. Can the current structure express the correct behaviour
   cleanly? If not, specify the refactor or rewrite needed. Do not bolt a special case onto a
   broken shape. Justify the call against quality-bar.md.
3. DESIGN — the native, HIG-correct approach, naming the specific AppKit/SwiftUI APIs and the
   documented behaviour it follows. Prefer a documented platform API over hand-rolling an
   equivalent that only approximates it (the platform API already handles IME, undo, Unicode,
   accessibility, and focus edge cases).
4. SCOPE — every file to create or change, in implementation order, with the edge cases and
   TablePro invariants the change must respect.
5. TESTS — the tests that would have caught this bug, and the CHANGELOG / docs updates required.

Be specific (files, types, APIs). This blueprint goes to the user for approval, then becomes the
implementation plan, so it must be complete and unambiguous.
```

---

## Notes on orchestration

- Spawn the three investigators in **one** turn (multiple `Agent` calls in a single message) so they run in parallel. Pass `team_name` and a distinct `name` to each so they join the team.
- The investigators are read-only, so the main checkout is safe; no worktree needed.
- After the Architect returns, send each teammate a `shutdown_request` before moving to implementation.
- You, the lead, own the final blueprint and the plan gate. The Architect drafts; you verify it against `quality-bar.md` and present it.
