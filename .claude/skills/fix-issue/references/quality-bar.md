# Quality Bar

The definition of done for a fix. Read this early: it is what separates an accepted fix from a rejected one. `CLAUDE.md` at the repo root is the authoritative source for the project's rules; this file is the fix-specific lens on top of it.

## The bar, in one sentence

Ship the version Apple would ship: native, correct behaviour, clean architecture, full scope, no leftover patches, and proof that it builds and passes. If the right fix is harder, do the right fix.

## Refactor vs. patch: the central decision

Every fix forces this call. Make it explicit in the blueprint.

Choose **refactor or rewrite** when:

- The current structure cannot express the correct behaviour without a special case that fights the existing shape.
- The bug is a symptom of a design that is wrong for the real requirement: a boolean where the state is actually multi-valued, an enum where the domain is open-ended, logic in a view that belongs in a model.
- Fixing only the reported case would leave the same class of bug latent elsewhere.

Choose **targeted patch** when:

- The design is sound and the bug is a genuine local mistake: an off-by-one, a missing guard, a wrong comparison.
- A small change fully resolves the root cause without distorting the surrounding code.

The failure mode to avoid is patching a symptom: making the reported case disappear while the underlying cause stays. The user's standing preference is the complete, root-cause fix grounded in documented APIs, never a phased or quick-win version offered as the answer. Do not present a minimal stopgap alongside the real fix as if they were equal options.

## Native and HIG

- Use native macOS/iOS components (AppKit, SwiftUI, system frameworks). No cross-platform abstractions, no web views for native UI.
- Match the documented HIG behaviour for the interaction, and cite the guideline in the blueprint.
- Name the specific API the fix uses, and prefer the modern, non-deprecated one. Confirm it exists and check its `@available` against our macOS 14 target in the SDK `.swiftinterface` (see `research-sources.md`).
- **Prefer the documented native API over a hand-rolled equivalent.** If AppKit or SwiftUI already provides the behaviour (a text-completion contract, a dismissal action, a selection model, a tabbing API), use it instead of reimplementing it. A hand-rolled version can pass tests and still mishandle what the platform API already handles: IME and marked text, the undo stack, Unicode and UTF-16 ranges, accessibility, focus. When the investigation surfaces a documented API that fits, that is the design, not a custom loop that approximates it.
- **Research the approach, then commit to it.** Do not ship a guess, wait for a screenshot, and guess again. For focus and keyboard work specifically, that means the AppKit key view loop, the responder chain, Full Keyboard Access, and SwiftUI's `@FocusState` and `.focusSection`, not custom `makeFirstResponder` calls that steal focus on an event.
- **Treat the user's UI suggestions as input, not instructions.** When their sketch conflicts with the native convention, say what the correct approach is and why, then build that.
- The behaviour should feel right to someone who uses native macOS apps daily, including keyboard affordances, focus, and selection.

## Clean code and architecture

From the `CLAUDE.md` principles, the ones a fix most often violates:

- Self-explanatory naming, and **no comments** (the codebase is comment-free by design).
- Early returns over nested conditionals; small focused functions.
- Separation of concerns, protocol-oriented design, dependency injection where it fits.
- `DatabaseType` is a string-based struct, not an enum: every `switch` over it needs `default:`.
- Explicit access control, no force unwraps, OSLog and never `print`.
- Stay under the SwiftLint limits; extract into `TypeName+Category.swift` extensions when approaching them.

## Invariants

`CLAUDE.md` has an **Invariants** section listing patterns that have caused real bugs: sync field deployment, sync delete ordering, the tab replacement guard, window tab titles, schema loading, refresh never clearing its own cache, display-position selection indices, connection cancel semantics, split pane holding priority, and more. Several of them shipped the same bug more than once.

If the fix touches one of those areas, the blueprint must show it respects the invariant, quoting the relevant rule. Re-read that section whenever the affected code is near one, rather than trusting memory of it.

## Mandatory rules checklist (from CLAUDE.md)

A fix is not done until these are handled:

- [ ] **CHANGELOG.md**: entry under `[Unreleased]` in the right canonical section, one user-facing line, no file paths or symbols, reference id in parens. Docs-only changes are exempt, and do not add a "Fixed" entry for something that is itself still unreleased.
- [ ] **Localization**: `String(localized:)` for new user-facing strings, never with interpolation (use `String(format:)`). SwiftUI literals auto-localize. Do not localize technical terms.
- [ ] **Documentation**: update `docs/` for new shortcuts, UI or feature changes, settings, or driver changes.
- [ ] **Tests**: write the test that would have caught the bug. Fix the source to make tests pass, never the reverse. UI and user-flow changes also get `TableProUITests` automation where the flow runs deterministically; if it cannot, say why in the PR description. UI suites subclass `UITestCase`, never `XCTestCase` directly (`verification.md` explains why, and what breaks if you do).
- [ ] **Build**: the app scheme compiles, plus `AllPlugins` if a registry plugin changed.
- [ ] **Lint**: `swiftlint lint --strict` clean on the changed files.
- [ ] **Commit message**: Conventional Commits, single line, canonical scope from the list in `CLAUDE.md`.
- [ ] **Writing style**: no em dashes, no banned filler words. Run the `git diff --cached` grep from `CLAUDE.md` before committing.

## Verification

You build, test, and lint the fix yourself before reporting it done. `references/verification.md` has the environment setup that makes local `xcodebuild` and `swiftlint` work, which failures are environmental rather than yours, and the branch-safety rules for committing.
