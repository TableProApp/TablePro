# Investigators

Charters and prompt templates for the three Phase 1 investigators, plus the optional architect challenge in Phase 2.

Spawn the three investigators with the `Agent` tool in a **single message** so they run concurrently. Paste the Phase 0 problem statement where each template says `<PROBLEM STATEMENT>`. Keep the questions sharp: a vague brief produces a vague report. Every investigator must cite evidence (a `file:line`, an exact symbol name, a doc URL) so you can trust the finding without re-deriving it.

They are read-only, so they are safe against the main checkout. Do not pass `isolation: "worktree"`.

---

## Codebase Analyzer

**subagent_type:** `feature-dev:code-explorer` (read-only, built for tracing execution paths and mapping architecture layers).

**Goal:** explain how the relevant code behaves *today* and locate the real cause, not the surface symptom. A correct fix cannot be designed without an accurate map of the current shape.

**Prompt template:**

```
You are the Codebase Analyzer on a TablePro fix investigation. Working dir: the TablePro repo.

Problem statement:
<PROBLEM STATEMENT>

Trace the code that produces this behaviour and report back. I need:
1. The exact files, types, and functions involved, with file:line references.
2. The real call path: what triggers this, what state flows through it, where the wrong
   behaviour originates.
3. Your read on the root cause vs. the symptom. If the current structure cannot express the
   correct behaviour cleanly, say so and explain why.
4. Any TablePro invariants (see the "Invariants" section in CLAUDE.md) this area touches, and
   whether the area is one the invariant list already says has broken before.
5. Existing tests covering this area, and the obvious gaps.
6. Whether the fix would land in the app, a bundled plugin, or a registry-only plugin. Name it.

Read CLAUDE.md first for architecture context. Report as structured text: do not change anything,
just map it precisely with evidence. Say "not confirmed" rather than guessing.
```

---

## Apple Platform Researcher

**subagent_type:** `general-purpose` (needs `WebSearch`, `WebFetch`, `Bash`, `Grep`).

**Goal:** establish what the *correct* behaviour and the *right API* are according to Apple, so the fix matches documented platform conventions instead of being invented. This is what makes a fix native rather than merely working.

**Prompt template:**

```
You are the Apple Platform Researcher on a TablePro fix investigation. TablePro is a native
macOS app (SwiftUI + AppKit, macOS 14+), built with the Xcode at
/Applications/Xcode-beta.app.

Problem statement:
<PROBLEM STATEMENT>

Find what Apple's platform says the correct behaviour and implementation should be. I need:
1. The relevant Human Interface Guidelines: what is the expected, conventional macOS behaviour
   here? Quote and link the section.
2. The right AppKit / SwiftUI API for this, named specifically, with its documented behaviour,
   its availability (we target macOS 14+), and any gotchas. Prefer the modern, non-deprecated
   API; if the only option is deprecated, say so and name the replacement.
3. Any standard system control or pattern that already does this, so we do not reinvent it.
4. Concrete citations: doc URLs and exact symbol names.

Sources, in order of authority:
- The local SDK interfaces, which are exact for our toolchain and greppable offline:
  /Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/<Framework>.framework/Modules/<Framework>.swiftmodule/arm64e-apple-macos.swiftinterface
  Use this to confirm a symbol exists, its exact signature, and its @available annotations.
- developer.apple.com/documentation and the HIG, via WebSearch and WebFetch, for described
  behaviour and design intent.

Report as structured text with citations. Distinguish what you confirmed from what you inferred.
```

---

## Competitor / UX Researcher

**subagent_type:** `general-purpose` (needs `WebSearch`, `WebFetch`).

**Goal:** ground the expected UX in how mature native database clients already solve this. The point is not to copy a competitor, it is to know the established interaction so TablePro's fix feels right to people who use these tools daily.

**Prompt template:**

```
You are the Competitor / UX Researcher on a TablePro fix investigation. TablePro is a native
macOS database client.

Problem statement:
<PROBLEM STATEMENT>

Research how mature native DB clients handle this interaction. I need:
1. How TablePlus, DataGrip, Postico, and Sequel Ace handle this specific behaviour or UI, as
   concretely as you can (documented behaviour, help docs, release notes, screenshots, credible
   reviews). Start with TablePlus: TablePro is positioned as a lightweight alternative to it, so
   most of our users arrive with its habits and often describe it when they say "how it should
   work".
2. The interaction pattern users expect: what the control looks like, the keyboard and mouse
   affordances, the edge cases these tools handle.
3. Anything these tools get wrong that we should avoid. Matching TablePlus is not a goal in
   itself; where it conflicts with the macOS HIG, say so.
4. A short recommendation on the UX TablePro should match, and why.

Use WebSearch and WebFetch. You cannot run these apps, so rely on their docs and credible
descriptions. Report as structured text, and flag every claim as confirmed or inferred.
```

---

## Architect challenge (Phase 2, conditional)

**subagent_type:** `feature-dev:code-architect` (read-only; designs against existing codebase patterns).

**When:** the fix is a refactor, touches a documented invariant, or spans more than about three files. Skip it for a contained fix.

**Goal:** attack your draft blueprint before the user sees it. You keep ownership; this is a second opinion, not a handoff.

**Prompt template:**

```
You are reviewing a draft implementation blueprint for a TablePro fix. Read CLAUDE.md, paying
particular attention to the Invariants section, and the skill reference at
.claude/skills/fix-issue/references/quality-bar.md.

Problem statement:
<PROBLEM STATEMENT>

Draft blueprint:
<BLUEPRINT>

Attack it. I want the weaknesses, not a summary. Specifically:
1. Where does this design fight existing patterns in the codebase instead of following them?
   Cite the pattern with file:line.
2. What scope is missing? Files that also need changing, callers that break, edge cases,
   persistence or state that goes stale.
3. Is there a better-fitting documented AppKit/SwiftUI API than the one chosen? Name it.
4. Is the refactor-vs-patch call right? If this patches a symptom while the underlying cause
   survives, say so plainly.
5. Does it violate any invariant in CLAUDE.md?

If a part of the blueprint is sound, say so in one line and move on. Report as structured text.
```

---

## Orchestration notes

- Subagents run in the background. You get a notification when each finishes. Do not act on, summarize, or invent a report before its notification arrives.
- Their final reports go to you, not the user. Relay what matters in your own words.
- If a report has a gap, `SendMessage` that agent by name rather than spawning a new one. It keeps its context and answers cheaply. `ListAgents` shows who is reachable.
- There is no team lifecycle to manage. An agent ends when it returns; `TaskStop` cancels one that is no longer useful.
- Do not reach for the `Workflow` tool. It needs explicit user opt-in and a three-way fan-out does not need deterministic scripting.
