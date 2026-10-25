---
paths:
  - "apple/TablePro/Theme/**/*"
  - "apple/TablePro/Views/**/*"
  - "apple/TablePro/Core/Services/Infrastructure/*Window*"
  - "apple/Packages/TableProCore/Sources/TableProTheme/**/*"
---

# Theme

## Content, never chrome

- **A theme colors content and the window backdrop, never chrome.** Content: code, the grid, values and wells (an editable value is a `ValueTextField`, not a bezeled control), value trees, diffs, record tables, diagrams, charts, and their stand-in states. Chrome: controls, Accent, Highlight, sidebar, inspector frame, toolbar, titlebar, tab strip, bars, Settings, Welcome, the connection form, sheets, popovers, and `List`, `Form` and `Table` backgrounds. `NSApp.appearance` is the only lever on chrome.
- **Chrome never reads a slot.** It asks `ThemeBackdropState.isThemed` and picks a system style: `.paneBarBackground(_:ignoresSafeAreaEdges:)` on a pane bar (nothing while themed; no edges, so a top bar never reaches under the toolbar), `.statusBarChrome()` on a status bar, `.splitItemGlassBackground()` on a list filling a glass sidebar or inspector item. No `.tint` with a theme color.
- **The slot family follows the surface.** Code, values, trees, wells: `editor.*`, so a code field in a form (Startup Commands, Agent SQL) wears it while the form stays system. Records, schema objects, diagram nodes, chart plots, grid stand-ins: `dataGrid.*`. Diff rows: `dataGrid.inserted`, `modified`, `deleted`. Behind panes: `window.background`. Identity, severity and status hues stay system.
- **Every call site passes the exact system color it drew before as the fallback**, so an unset slot draws an unthemed app. A default changes only on purpose, named in the PR and a changelog fragment.

## Model

- `TableProTheme` is Foundation only, so the iOS app can adopt it; AppKit and SwiftUI code stays in `apple/TablePro/Theme`.
- **`ThemeSlot` is the one registry.** A slot exists only while a view reads it: removing its last reader removes the slot.
- `isOverridden(_:)` means the slot draws a theme color, set or derived: ask it before swapping a native drawing path (a code table's selection, the caret). Only the theme editor asks `hasExplicitColor(_:)`.
- **Adding a slot bumps `ThemeSchema.current`.** `ThemeFileFormat` reads only the current schema: an older or newer one, or an unknown key, is refused rather than loaded without colors its author wrote, so a bump stops every older file from loading. The bump renames the sync content kind (Sync).
- **An imported file is untrusted.** `ThemeFileImporter` checks the size before it reads, mints a fresh id every time, and never follows a VS Code `include` out of the file's folder.

## Reading colors

- **A scoped carrier reads through its `ThemeScope`, never `ThemeEngine.shared`.** Only the theme editor preview uses `.fixed(_:)`, and a new definition is a new scope.
- `palette.color(_:otherwise:)` returns a new object on every call: never compare it to skip a write. Bake `resolved` into a `CGColor` only inside the drawing view's appearance (`resolved.cgColor(_:otherwise:in:)`).
- **Hold every AppKit carrier** (`ThemeTextViewStyle`, `ThemeTableChrome`, never on a source list) **as a stored property.** Its subscription and row views hold it weakly, so one held in a local stops at the first theme change.
- **A records table's header and selection have one drawing path.** The header band, its titles, the selection, the inactive selection, selected text and the data grid's active-cell border always draw `dataGrid.headerBackground`, `headerText`, `selection`, `inactiveSelection`, `selectionText` and `focusBorder`; an unset slot resolves to the system color. AppKit's header cell paints an opaque band and colors a title only from its attributes, so a records header is a `ThemeTableHeaderView` with `ThemeTableHeaderCell` columns: the cell paints the band and AppKit's interior draws the title and sort arrow, which the view styles before each draw. A code table recolors its selection with `editor.selection` only while the theme sets it.
- **A theme change has to reach the view.** SwiftUI caches `Color(nsColor:)` by object identity, so a view reading the engine holds `@ObservedObject private var themeEngine = ThemeEngine.shared`; an AppKit view that bakes a color re-bakes on `AppEvents.shared.themeChanged`. `withAlphaComponent` on a system color outside `NSColor(name:dynamicProvider:)` freezes it.
- **No theme color on selectable-row text**: it does not turn white on the emphasized selection. Never put `.themeForeground` on a container of selectable rows; `ThemeTableChrome.recordsTextSlot(...)` picks a records cell's slot.

## Windows

- **A content window subclasses `ContentWindow`** and holds a `ThemeWindowBackdrop`. On macOS 26 and later the backdrop sets `window.background` only while the theme sets it; earlier the window keeps its own color. Code asks `ThemeWindowBackdrop.canReachChrome`, never an `#available` of its own.
- `ContentWindow` owns the titlebar. Before macOS 26 it stays opaque: a transparent one there swaps its material for a flat fill.
- The detail column sits on `DetailColumnBackdrop`, so a pane that draws nothing shows `window.background`. `DetailPaneBackdropFill` goes only there.

## Engine and catalog

- **`ThemeEngine` never writes settings and follows `ThemeCatalog.$themes` itself**: a view never asks it to reapply. A burst resolves once per run loop turn, scheduled in the common modes, since a color well drag runs the event-tracking mode.
- **`ThemeResolver` is pure.** A missing, rejected or wrong-appearance theme draws the default and the saved id stays, so the theme returns with its file.
- A user theme is its JSON `id`, whatever its file name.
- **A file changed on disk wins.** Save, rename or trash of a theme whose file changed or vanished since it was read throws `changedOnDisk` or `deletedOnDisk` and reloads; it never overwrites or recreates the file. Two themes with one name show as "Name 2" in the list only, never in the file, so a display fix never syncs.

## Theme editor

- The preview is a real `SourceEditor` and `DataGridView` on `ThemeScope.fixed(_:)`. It never takes focus: its editor and grid answer Undo with their own histories.
- **Set the window's delegate before its content.** A window whose undo manager was read with no delegate keeps its own and never asks `windowWillReturnUndoManager(_:)`.

## Sync

- **Each user theme syncs as the `AppSettings` record `theme.<id>`** holding `ThemeFileFormat.encode(_:)` bytes. A user edit marks it dirty, a trash marks it deleted once the trash lands, and a load or migration marks nothing. Built-ins never sync.
- **A synced theme is untrusted.** `ThemeCatalog.applyRemote(category:data:)` checks the category id (never a built-in), a 64 KB cap, nesting depth, a full decode and the file id, and never writes over bytes it has not read. A validation failure is a logged skip; only a disk failure returns `.failed`, which withholds the change token so the pull replays. A remote delete trashes the file through `removeWithoutSync(ids:)`.
- The light and dark theme ids sync. The appearance mode and fonts are device-local, and a received `appearance` record never changes them.
- `SyncCoordinator.themeContentKind` names `ThemeSchema.current`, so a Mac upgraded past a bump refetches the zone once. After the first full pull, only local themes the server lacks are marked dirty, once.
