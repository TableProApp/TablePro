# Quality Bar

The definition of done for a fix. Read this early: it's what separates an accepted fix from a rejected one. `CLAUDE.md` at the repo root is the authoritative source for the project's rules; this file is the fix-specific lens on top of it.

## The bar, in one sentence

Ship the version Apple would ship: native, correct behaviour, clean architecture, full scope, and no leftover patches. If the right fix is harder, do the right fix.

## Refactor vs. patch: the central decision

Every fix forces this call. Get it explicit in the blueprint.

Choose **refactor / rewrite** when:

- The current structure can't express the correct behaviour without a special case that fights the existing shape.
- The bug is a symptom of a design that's wrong for the real requirement (a boolean where state is actually multi-valued, an enum where the domain is open-ended, logic in a view that belongs in a model).
- Fixing only the reported case would leave the same class of bug latent elsewhere.

Choose **targeted patch** when:

- The design is sound and the bug is a genuine local mistake (an off-by-one, a missing guard, a wrong comparison).
- A small change fully resolves the root cause without distorting the surrounding code.

The failure mode to avoid is patching a symptom: making the reported case disappear while the underlying cause stays. The user's standing preference is the complete, root-cause refactor grounded in documented APIs, never a phased or quick-win version offered as the answer. Don't present a "minimal stopgap" alongside the real fix as if they were equal options.

## Native and HIG

- Use native macOS/iOS components (AppKit, SwiftUI, system frameworks). No cross-platform abstractions, no web views for native UI.
- Match the documented HIG behaviour for the interaction. Cite the guideline in the blueprint.
- Name the specific API the fix uses, and prefer the modern, non-deprecated one.
- **Prefer the documented native API over a hand-rolled equivalent.** If AppKit/SwiftUI already provides the behaviour (a text-completion contract, a dismissal action, a selection model, a tabbing API), use it instead of reimplementing it. A hand-rolled version can pass tests yet still mishandle the edge cases the platform API already handles: IME and marked text, the undo stack, Unicode and UTF-16 ranges, accessibility, focus. When the investigation surfaces a documented API that fits, that is the design, not a custom loop that approximates it.
- The behaviour should feel right to someone who uses native macOS apps daily, including keyboard affordances, focus, and selection.

## Clean code and architecture

From `CLAUDE.md` principles, the ones a fix most often violates:

- Self-explanatory naming; **no comments** (the codebase is comment-free by design).
- Early returns over nested conditionals; small focused functions.
- Proper separation of concerns; protocol-oriented design; dependency injection where it fits.
- `DatabaseType` is a string-based struct, not an enum: every `switch` over it needs `default:`.
- Explicit access control, no force-unwraps, OSLog (never `print`).
- Stay under the SwiftLint limits; extract into `TypeName+Category.swift` extensions when approaching them.

## Invariants

`CLAUDE.md` has an **Invariants** section listing patterns that have caused real bugs (sync delete ordering, WelcomeViewModel tree rebuild, tab replacement guard, window tab titles, schema loading task). If the fix touches one of those areas, the blueprint must show it respects the invariant. Re-read that section whenever the affected code is near one.

## Mandatory rules checklist (from CLAUDE.md)

A fix is not done until these are handled:

- [ ] **CHANGELOG.md**: entry under `[Unreleased]` in the right section, one user-facing line, no file paths or symbols, reference id in parens. (Docs-only changes are exempt.)
- [ ] **Localization**: `String(localized:)` for new user-facing strings; never with string interpolation. SwiftUI literals auto-localize. Don't localize technical terms.
- [ ] **Documentation**: update `docs/` for new shortcuts, UI/feature changes, settings, or driver changes.
- [ ] **Tests**: write the test that would have caught the bug. Fix source to make tests pass, never the reverse.
- [ ] **Lint**: `swiftlint lint --strict` clean on changed files; `swiftformat` if needed.
- [ ] **Commit message**: Conventional Commits, single line, correct scope (see the canonical scope list in CLAUDE.md).
- [ ] **Writing style**: no em dashes, no banned filler words. Run the `git diff --cached` grep from CLAUDE.md before committing user-facing strings.

## Build and verification

The user builds and runs Xcode themselves. Don't run `xcodebuild` to verify; report the change as ready and ask the user to surface any compile errors. Tests and lint are yours to run; the build is theirs.
