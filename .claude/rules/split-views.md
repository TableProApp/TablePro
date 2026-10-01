---
paths:
  - "TablePro/**/*Split*.swift"
  - "TablePro/Core/Services/Infrastructure/WorkspacePane*.swift"
---

# Split views

- **A split item's `holdingPriority` stays below 490** (`dragThatCannotResizeWindow`), or a divider drag cannot win. Use `.splitPaneHolding` (260).
- **A hosting controller or view that a split item, a cell or a sized container hosts sets `sizingOptions = []`.** Otherwise its content's minimum width becomes a required constraint that pins the window's dividers. `WorkspacePanes` applies this for the window panes; a tab that needs more width declares it through `resolveDetailMinimumThickness(for:)`.
- **A split view controller hosted under SwiftUI subclasses `ResizeCursorSplitViewController`.** AppKit's divider cursor rects do not fire under an `NSHostingController`, so the divider drags but never shows the resize cursor.
