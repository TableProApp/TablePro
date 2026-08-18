# Quality Bar

## Definition of done

The change sits at the correct ownership boundary, preserves native behavior and project
invariants, lands with its test, builds, passes targeted verification, survives independent
review, and reports its limitations honestly. A defect is done when the root cause is gone, not
when the symptom is. A feature is done when a user can find it, use it, undo it, and read about
it, not when the happy path compiles.

## Refactor versus targeted fix

Refactor when the current shape cannot express correct behavior without a special case, models a
multi-state domain as a boolean, puts ownership in the wrong layer, or leaves the same failure
class in sibling paths.

Take the targeted fix when the architecture is sound and the defect is local: a wrong comparison,
a missing guard, a stale mapping, an incorrect ordering. Small is good only when it is complete.

Decide this once, in the blueprint, with the reason written down. Discovering halfway through the
edit that the shape cannot hold the behavior is how a fix becomes a special case.

## New seam versus existing shape

The same decision on the change track. Extend the abstraction that already owns this behavior.
Add a seam only when the existing one cannot express the feature without lying about what it
models, and say in the blueprint what it could not express. A parallel system that duplicates an
existing one is the expensive mistake here, because both halves then have to be maintained and
they drift.

Copy a precedent rather than inventing one. The repository has a shipping example of almost every
kind of surface: a settings pane, a menu command with a shortcut, a sidebar section, a sheet, a
plugin-backed capability. Find the nearest one and follow its structure, including where it puts
persistence and where it registers itself. Departing from it is allowed and has to be argued.

Ship the smallest version that satisfies the acceptance criteria, and write the non-goals down.
An unwritten non-goal is an invitation for a critic, a reviewer, and the implementer to each
invent a different larger feature.

Requests are not designs. A reporter asking for a button is describing a need, and the button may
not be the answer. The HIG and the app's existing interaction language decide the surface.

## Evidence

- Cite code as `file:line` plus the state transition that reaches it.
- Cite platform behavior with the exact API and authoritative documentation, and check
  availability in the installed SDK for the deployment target.
- Verify C and database behavior against the vendored header and the shipped artifact, not the
  upstream project's current documentation.
- Measure ambiguous behavior with a minimal probe.
- Treat lane reports, review findings, and competitor descriptions as hypotheses until verified at
  the source. Agreement between agents is not evidence.
- Verify at the anchor. Open the cited lines rather than re-reading whole files, and read a file
  end to end only when you are about to change its structure.

## Native UX

- Prefer documented AppKit, SwiftUI, and system behavior over a hand-rolled approximation.
- Preserve keyboard access, focus, selection, undo, IME, UTF-16 range handling, accessibility, and
  the responder chain.
- Use AppKit where the repository deliberately uses it to avoid a known SwiftUI lifecycle or
  sizing failure. Check before replacing one with the other.
- Competitor behavior is research input. The HIG and verified user requirements decide the design.

## Completion checks

Both tracks:

- Changelog entry under `[Unreleased]` for user-visible behavior, in the right section: `Added`
  for a new capability, `Changed` for altered behavior, `Fixed` for a defect. A fix to a feature
  that has not shipped yet folds into that feature's existing entry instead of adding a new one.
- The relevant `docs/` page for a feature, shortcut, setting, external API, or driver behavior.
- Localization through `String(localized:)` with no interpolation inside a key.
- Unit coverage, and deterministic UI automation where the flow allows it.
- Project regeneration after any source or configuration change.
- Build, targeted tests, strict lint, and the plugin or ABI checks the change requires.
- Independent other-vendor review for high-risk changes.
- A diff read end to end, preserving unrelated work already in the tree.

A new user-visible feature also needs:

- Discoverability: the menu item, keyboard shortcut, or entry point a user reaches it by, placed
  where comparable commands already live.
- An empty state, an error state, and cancellation for anything that can take time or fail.
- Settings defaults chosen for existing users, plus whatever migration keeps their stored state
  valid. A new key that silently changes behavior on upgrade is a regression.
- Undo, or an explicit note in the blueprint that the action is not undoable and why that is safe.
- A decision about the iOS target, even when the decision is that it does not apply.
- For a new database type: the string-backed `DatabaseType` stays open, unknown types round-trip,
  every switch keeps a fallback, and the registry-only build and ABI checks run.

## Collateral findings

Fold a finding into this change only when it is required for the correctness, safety, or
verification of the requested behavior. Everything else verified goes into the register with its
evidence, and the register is the follow-up queue: a qualifying finding ships as its own pull
request after the primary one, never as an unannounced addition to this diff. Mixing them makes
the diff hard to review and impossible to revert cleanly.

The bar for entering the queue is the evidence bar above. A hunch is not a queue item.
