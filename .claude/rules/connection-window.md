---
paths:
  - "TablePro/Core/Services/Infrastructure/**/*"
  - "TablePro/Models/Connection/**/*"
  - "TablePro/Core/Database/DatabaseManager*.swift"
  - "Packages/TableProCore/Sources/TableProDatabase/**/*"
  - "TablePro/Views/Main/**/*"
---

# Connection windows and sessions

- **A workspace's content comes from its own `ConnectionWindowPhase`**, never from `activeSessions` membership, which cannot tell connecting from failed from canceled. `ConnectionWindowPhaseMachine` owns the transitions (every phase has an exit), `ConnectionWindowPaneResolver` picks the pane, and a connect failure shows inline in `ConnectionUnavailableView`, never as an alert.
- **A cancel updates the UI at once and is fenced by the workspace's `attemptToken`**, because the driver may finish late. Closing a window cancels the attempt of every workspace it hosts.
- **`transition(to:for:)` is the only phase writer and ends in `syncPanes(of:)`** for the workspace it names, selected or not, so a background connection repaints. Panes rebuild only when their `WorkspacePaneRenderKey` changes, so a repaint request is cheap.
- **An installed driver is a handle, not a live connection.** Health comes from `ConnectionSession.liveness`, set only through `markSessionUnreachable(_:startedWith:info:)` and `markSessionLive`, and every UI reads `reportedStatus`, never `status` or `hasDriver`. Never nil the driver to signal an outage: metadata reads, queries and the reconnect still go through it.
- **A failed connect keeps its place in "Reopen Last Session"; a canceled one leaves it** (`retainsRestoreIntent`).
- **Window titles go through `WindowTitleResolver`** and editor tab labels through `EditorTabLabelResolver`. Never write `window.title`; change `tab.title` and call `QueryTabManager.markTabRenamed(_:)`. A title must be right and non-blank from creation, because AppKit draws background tabs that never activate.
- **Only `closeTabsByUser` may clear saved tabs.** A lost session empties the tab manager without the user closing anything, so teardown saves (`saveAggregatedSync`) skip an empty list.
- **`openTableTab` never replaces a tab with unsaved edits, filters or sorting**; it opens a new editor tab instead.
- **Window tabbing stays the user's choice**: `TabWindowController` leaves `tabbingMode` at `.automatic` and never forces `.preferred`.
- **Cmd+W** reaches `EditorWindow.performClose(_:)`, which closes the frontmost editor tab before the window.
