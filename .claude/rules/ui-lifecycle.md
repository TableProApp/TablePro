---
paths:
  - "TablePro/Views/**/*"
  - "TablePro/ViewModels/**/*"
  - "TablePro/Core/Services/Infrastructure/**/*"
  - "TableProUITests/**/*"
---

# UI and lifecycle changes

Read the `### Invariants` section of `CLAUDE.md` and find the paragraph that names the view, coordinator, window, tab, split pane, header, focus, or selection you are touching. Each one is there because it shipped a bug, and several shipped the same bug more than once. `### Main Coordinator Pattern`, `### Window Close (Cmd+W)`, and `### Editor Architecture` in the same file hold the ownership map for those areas.

Binding constraints for this path:

- Native AppKit and SwiftUI ownership. The app runs the AppKit lifecycle and AppKit owns the menu bar. Do not reintroduce a SwiftUI `App`.
- The responder chain, focus, selection, undo, IME, and UTF-16 range handling survive the change.
- Accessibility identifiers stay on the controls that need them. Never put one on a SwiftUI container by itself; it replaces the identifier of every descendant in the same hosting tree.
- Actor isolation holds. Keep UI state mutation on the correct actor and never use `Task.detached` to escape it.
- A user flow that runs deterministically gets `TableProUITests` coverage, and every suite subclasses `UITestCase`. A bare `XCUIApplication()` or `: XCTestCase` under `TableProUITests/` fails a source-scanning guard test, because storage isolation depends on the launch path.

For view work, load `$swiftui` as well. This rule adds domain constraints and does not pick your workflow.
