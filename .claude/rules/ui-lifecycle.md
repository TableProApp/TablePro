---
paths:
  - "TablePro/Views/**/*"
  - "TablePro/ViewModels/**/*"
  - "TablePro/Core/Services/Infrastructure/**/*"
  - "TableProUITests/**/*"
---

# UI and lifecycle changes

Search `.agents/skills/tablepro-engineering/references/invariants-ui.md` for the affected view, coordinator, window, tab, split view, header, focus, selection, or issue number, and read the full matching invariant. `architecture.md` in the same directory holds the window-close and storage map. Preserve native AppKit and SwiftUI ownership, responder-chain behavior, accessibility identifiers, actor isolation, and deterministic `UITestCase` coverage.

This rule adds domain constraints. It does not pick your workflow: `AGENTS.md` decides whether you are in `$fix-issue` or `$tablepro-engineering`, and you never load both.
