---
paths:
  - "TablePro/Views/**/*"
  - "TablePro/ViewModels/**/*"
  - "TablePro/Core/Services/Infrastructure/**/*"
  - "Packages/TableProEditor/**/*"
  - "TableProUITests/**/*"
---

# Views and lifecycle

- **Appearance is not lifetime.** Switching connection unparents a pane without destroying it, so `onDisappear` fires on every switch; release there only what `onAppear` rebuilds. Real teardown belongs in `dismantleNSViewController` or `ConnectionWorkspace.teardown()`.
- **A popover that edits data owns its editing model**: a `@State` copy seeded in `init`, with edits reported through a callback. A popover's content does not re-render when the view presenting it does.
- **A coupled edit is one whole-value write** through a model method (`HighlightRule.selectingOperator(_:)` is the shape), never two field writes through a `Binding`: the second resolves against the same stale value and the first is lost.
- **Never put `.accessibilityIdentifier` on a SwiftUI container alone**; it replaces every descendant's identifier in that hosting tree. Pair it with `.accessibilityElement(children: .contain)` first.
- **Keep focus, selection, undo, the responder chain and IME working** after the change, and keep UI state on the main actor (no `Task.detached` to escape it).
- **SwiftUI targets macOS 13.** An API from a later release needs `if #available` and a fallback. Several views are AppKit on purpose because the SwiftUI version misbehaves; check before converting one.
