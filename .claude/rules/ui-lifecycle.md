---
paths:
  - "apple/TablePro/Views/**/*"
  - "apple/TablePro/ViewModels/**/*"
  - "apple/TablePro/Core/Services/Infrastructure/**/*"
  - "apple/Packages/TableProEditor/**/*"
---

# Views and lifecycle

- Appearance is not lifetime. Switching connection unparents a pane without destroying it, so `onDisappear` fires on every switch; release there only what `onAppear` rebuilds. Real teardown belongs in `dismantleNSViewController` or `ConnectionWorkspace.teardown()`.
- Re-adding a pane fires `onAppear` again and restarts every `.task` and `.task(id:)`, even with an unchanged id, while `@State` survives. A load, fetch, cache reset or one-time setup started there is idempotent in its owner: it skips what is loaded and records a load as done only when it finished, so a load a switch cancelled runs again on return.
- Work that must outlive the pane, like the initial schema load, is an unstructured task the coordinator owns.
- A popover that edits data owns its editing model: a `@State` copy seeded in `init`, with edits reported through a callback. A popover's content does not re-render when the view presenting it does.
- A coupled edit is one whole-value write through a model method (`HighlightRule.selectingOperator(_:)` is the shape), never two field writes through a `Binding`: the second resolves against the same stale value and the first is lost.
- Never put `.accessibilityIdentifier` on a SwiftUI container alone: it replaces every descendant's identifier in that hosting tree. Pair it with `.accessibilityElement(children: .contain)` first. How a UI test queries a leaf control is in `.claude/rules/ui-tests.md`.
- Keep focus, selection, undo, the responder chain and IME working after the change, and keep UI state on the main actor (no `Task.detached` to escape it).
- An API newer than the deployment target (`apple/AGENTS.md`) needs `if #available` and a fallback.
- A view that is AppKit on purpose says why in its type comment (`FavoritesOutlineView`: a SwiftUI `List` cannot draw an emphasized selection under a bare `NSHostingController`). Read it before converting.
