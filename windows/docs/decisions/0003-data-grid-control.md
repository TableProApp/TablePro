# 0003: TablePro's own data grid control

- **Status**: Accepted
- **Date**: 2026-11-03

## Context

- WinUI 3 has no data grid. Its own TableView is in preview: it is in the 2.5.4-experimental tag, not in 2.6.4, and its spec leaves column virtualization out of v1. WinUI.TableView realized 159,039 elements at 200 columns (lane `wingates`).
- A result set can hold a million rows of 200 columns, read from the core as windows of display text ([core 0003](../../../core/docs/decisions/0003-result-windows-for-native-grids.md)).
- The spike of lane `wingates2` (2026-11-02, local branch `spike/wingates2`, `spikes/wingates2/SPIKE.md`) built an ItemsRepeater grid three ways on GitHub's `windows-2025` and `windows-11-arm` runners:
  - With a TextBlock per cell, no variant kept the UI thread under 50 ms on page right and on random x and y. The cells were already on XAML's text fast path; measuring them was the cost.
  - With rows that draw their cells' text with DirectWrite, every bar passed, random x and y by a thin margin: 48.3 ms (Arm64) and 37.0 ms (x64) at most, run 41461803591. Each drawn process's worst step held a GC, from Win2D's wrapper object per cell layout.
  - Four ItemsRepeater behaviors broke the grid without an error (Design, Virtualization).

## Decision

`TablePro.DataGrid` is a read-only WinUI 3 control of our own. ItemsRepeater virtualizes the rows, and each row draws its visible cells' text with DirectWrite into a composition surface, through `TablePro.Graphics`, the one drawing layer the editor uses too. Cells are UIA peers with no element. The data comes from the core through `TablePro.Interop`, formatted there.

## Design

### Model (`src/TablePro.DataGrid.Model`, net10.0, no WinUI)

- `IGridData` is a row count, columns and readers; `ResultSetData` is a core `ResultSet`. A reader belongs to one thread, as a core cursor does: the grid keeps one for its UI thread and a copy opens its own.
- `CellCache` holds windows of 32 rows by 8 columns as `CellBlock`s: the UTF-8 the core packed, decoded once into one UTF-16 buffer sized exactly, with a state per cell (NULL, cut, right to left, lossy). A full cache refills its least recently used block, so scrolling allocates nothing once it is full: a test reads 400 random screens of a million-row core result and measures 0 bytes.
- Blocks of 64 by 16 put long text on the large object heap, and the gen2 GCs it started were in the gate's worst steps; at 32 by 8 a GC is in 3 of the gate's 36 worst waits, at 26.1 ms at most (Gate).
- The core cuts each cell at a cap from the column width (at least 256 characters) and marks it; the grid ends a cut value with an ellipsis of its own color.
- `GridColumns` keeps widths and positions for two panes: the row numbers with the frozen columns, and the scrolling columns from x = 0.
- `GridSelection` is an anchor and a focused cell, as cells, whole rows or everything, so a selection of any size is two numbers.
- `GridNavigation` moves as Excel does in a block with no empty cells: arrows, Page Up and Down, Home and End, Ctrl to the edges, Shift to extend.
- `GridCopy` writes Excel's TSV: tabs, CRLF, values with a tab, line break or quote quoted with quotes doubled, NULL as an empty cell. It streams blocks of 16,384 cells from a reader of its own, at a 4,096-character cap, and reads a cut value whole. The core shows control characters as spaces, so a text value with a space is read whole too.

### Virtualization (`src/TablePro.DataGrid`)

- A ScrollViewer holds four regions: the scrolling columns as content, their header row in `TopHeader`, the row numbers and frozen columns in `LeftHeader`, and their headers in `TopLeftHeader`. The headers need the content aligned left and top.
- `LeftHeader` lies over the content, which scrolls under it, so the frozen pane paints the grid's background.
- In each pane an ItemsRepeater realizes the rows in view through `RowsLayout`; the header row realizes the scrolling columns in view through `HeaderLayout`. Rows are arranged against an origin that moves in steps of 4,096 px, so arrange coordinates stay small in a 32M px grid.
- The five traps, each with a test in `tests/TablePro.DataGrid.Tests/ItemsRepeaterTrapTests.cs`:
  1. **Auto-recycle.** `ViewManager::GetElement` marks each element a layout gets for recycling unless the layout asks for it again in the same pass. The layouts keep elements across passes, so they pass `SuppressAutoRecycle`; without it one element served two rows.
  2. **The 10,000 px viewport.** `ViewportManager::UpdateViewport` takes an effective viewport past x and y 10,000 as cleared. The layouts take their windows from the grid's own scroll state, not `context.RealizationRect`, and the grid invalidates them on each scroll.
  3. **The O(n²) walk.** `ViewManager::GetElementIfAlreadyHeldByLayout` walks every child inside a cached index range that only grows. A repeater per row pane over row indices, and one over column indices for the headers, keeps each range small and contiguous.
  4. **Scroll anchoring.** ItemsRepeater makes each element it prepares an anchor candidate, and the ScrollViewer moved its offset after a recycled row. Rows have a fixed height, so the grid turns anchoring off: `HorizontalAnchorRatio` and `VerticalAnchorRatio` are NaN, each prepared row and header cell has `CanBeScrollAnchor` false, and the canvas that holds a pane's rows is an `IScrollAnchorProvider` that takes no candidates.
  5. **A new source.** Replacing the items left the elements the layouts held where they were, drawing the old rows under the new ones; the app's sorted results showed it. `SetData` hands the old elements to the layouts, which recycle them on the next measure.

### Drawing

- Each row is one element with a `SpriteVisual` painted from a `CompositionDrawingSurface` the width of the pane's visible columns. `TablePro.Graphics.SurfaceDevice` makes the composition graphics device from a Direct2D device through Windows App SDK's `ICompositorInterop`, whose IIDs and layout differ from the system's; a draw gets the surface's own device context through `ICompositionDrawingSurfaceInterop::BeginDraw`.
- A row keeps an `IDWriteTextLayout` per visible cell while it stays on screen, and lays out only the columns that come into view. Layouts are made from the block's spans: no string, wrapper or closure per cell.
- The font is what a TextBlock cell would use: Segoe UI Variable Text at the content size (Segoe UI before Windows 11), one line, cut with an ellipsis, centered, grayscale antialiased on a clear surface. The locale is the UI language's, so Han glyphs follow it.
- NULL is the word NULL in italic in the tertiary text color. A value the core cut ends with an ellipsis in the tertiary color.
- A value whose first strong character is right to left reads right to left from the cell's right edge, as TextBlock's `DetectFromContent` does.
- Color fonts draw in color: `D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT` on each layout's draw.
- Device loss: `D2DERR_RECREATE_TARGET` or a removed device from `BeginDraw` or `EndDraw` moves the composition device to a new Direct2D device (`ICompositionGraphicsDeviceInterop::SetRenderingDevice`), makes the brushes again and redraws every row.
- DPI: a surface is sized from `XamlRoot.RasterizationScale`, which `XamlRoot.Changed` follows, and the sprite shows it at that scale.
- Text scale: `UISettings.TextScaleFactor` scales the font, and the rows and header grow with it (32 px at 100%, 48 px at 150%).
- Font fallback and glyphs: the first draw of each glyph cost the gate's first process 57 to 247 ms for one column of mixed scripts, all of it in `DrawTextLayout`. `DataGridView.WarmUpFonts` at startup, and the first grid on its own Direct2D device, lay out and draw the common letters of each script, the most used Han characters, Hangul and emoji on a pool thread. It takes about half a second, more on a cold runner (Gate), and the first process's first non-Latin step fell to 11 to 14 ms.
- Colors come from WinUI's theme resources for the element's theme, switched live on `ActualThemeChanged`, and on `UISettings.ColorValuesChanged` for high contrast: `AccessibilitySettings.HighContrastChanged` fails with 0x80070490 in a window with no CoreWindow. In high contrast, the system colors: the selection is the highlight color, opaque, and selected text takes the highlight text color.

### Input, selection and copy

- Arrows, Page Up and Down, Home and End, Ctrl+Home and Ctrl+End, Shift to extend; Ctrl+A selects every cell; Ctrl+C and Ctrl+Insert copy.
- A click picks a cell and Shift+click extends; a drag extends; a click on a row number picks the row, and on the corner, everything.
- The selection and the focused cell are a Rectangle and a Border in each pane, cut to the realized rows.
- Ctrl+C builds the TSV on a pool thread, so the UI thread does not wait for a selection of any size, then sets the clipboard. A later copy cancels one still running.

### Header

- A header cell shows the column name and the sort indicator. Its right edge resizes the column by dragging, with the resize cursor, and fits the column to its header and the rows in view on a double-click.
- A click asks for a sort: `SortRequested` with the column, ascending, flipping on a repeat, as the macOS grid does. The core has no sort, so the host runs it on the server and sets `Sort`.

### Accessibility

- The grid is a DataGrid with Grid, Table and Selection; a cell is a DataItem with GridItem, TableItem, SelectionItem and ScrollItem, its Name the value. The peer shapes follow WinUI.TableView's (MIT, v1.5.1).
- `GetItem` reaches any cell without scrolling; the cell's ScrollItem brings it into view. The tree lists the cells on screen, and the grid keeps one peer per cell in use, so both hand a client the same provider.
- `ISelectionProvider.GetSelection` reads the model, so cells off the screen are in it, up to 10,000 cells.
- A point query reaches a drawn cell through the pane's peer, which maps the point to the cell.

## Rationale

- The drawn rows are the only variant that passed page right and random x and y in the spike. Its GC came from a managed wrapper per cell layout; with TerraFX and the core's spans the hot path makes none.
- One text stack for the app: the editor's DirectWrite layer, not Win2D, which is a dependency over the same Direct2D.
- The model has no WinUI, so its tests, including those over the real core, run on every runner.

## Consequences

- Text, hit testing, high contrast, text scale, DPI, device loss, right to left and color fonts are ours to keep right; a TextBlock would do them. Each has a test or a gate check.
- `TablePattern.ColumnHeaders` reads empty for clients on Windows App SDK 2.6.4: `CUIATableProviderWrapper::GetColumnHeaders` releases its SAFEARRAY before filling it. microsoft/microsoft-ui-xaml#11820 fixed it after 2.6.4. The grid returns the header peers on screen, and a cell's TableItem names its column header while that header is realized.
- The core has no sort; the grid raises `SortRequested` and the host sorts on the server.
- A UI in a right-to-left language would need the grid mirrored; only values read right to left today.
- The gate runs WARP on hosted runners; no machine with a GPU is measured yet.
- Not yet: editing, column reorder, sizing columns to their content on load, row header peers, find, tooltips for cut cells.

## Alternatives considered

- **A TextBlock per cell.** Failed page right and random x and y in every variant (Context).
- **Win2D for the drawn rows.** What the spike used. A second text stack beside the editor's and a wrapper object per layout, which put a GC in every worst step.
- **One SwapChainPanel over the viewport.** One surface, but no element per row for ItemsRepeater to recycle, so virtualization, hit testing and the frozen pane would be ours too.
- **WinUI's TableView.** Preview, not in 2.6.4, no column virtualization in v1.
- **A single 2D repeater of cells.** The O(n²) walk: 66.7 ms per random step finding elements on x64 (spike run 41435447241).

## Gate

`tests/TablePro.DataGrid.Gate` is the grid in a WinUI window over the real core, with `TablePro.DataGrid.Gate.Uia` as a UIA client (FlaUI). `ci/run-gate.ps1` builds and runs both. `.github/workflows/windows-grid-gate.yml` runs it by dispatch only: it takes most of an hour per runner, and hosted runners' timings move from job to job. The control's tests run in `windows.yml` on every change; the solution's 152 tests passed on both runners as it runs them (run 41525752990).

### Setup

- GitHub's `windows-11-arm` (Arm64) and `windows-2025` (x64), WARP, 1920 by 1080 at 100%, a viewport of 1424 by 826 px.
- A million rows from SQLite through the core: 20 columns shown as 200, the first frozen beside the row numbers. The text is the spike's: Latin, Vietnamese, Han, Cyrillic, Arabic and emoji, with one value in twenty past the display cap; then numbers, dates, NULLs and blobs.
- Three processes per runner, each started once the runner's CPU is idle: `first` (cold), `gate` (the phases, then the behavior checks) and `repeat`.
- A step sets the scroll offset and runs layout in a frame callback. The measure is the spike's: how late a UI-thread heartbeat runs. The bar is 50 ms at most in each phase.

### Timing (run 41530931997)

UI-thread block in ms, p50 / p95 / max:

| Phase (steps) | Arm64 first | Arm64 gate | Arm64 repeat | x64 first | x64 gate | x64 repeat |
|---|---|---|---|---|---|---|
| Down 3 rows per frame (600) | 0.14 / 9.26 / 37.23 | 2.91 / 9.81 / 21.49 | 0.12 / 5.99 / 8.35 | 0.17 / 5.31 / 11.63 | 0.16 / 5.19 / 7.11 | 0.16 / 5.15 / 12.81 |
| Page down (200) | 5.61 / 14.85 / 25.46 | 6.44 / 16.75 / 22.6 | 0.2 / 14.35 / 28.51 | 7.82 / 12.02 / 13.83 | 5.54 / 11.92 / 15.85 | 7.12 / 12.2 / 16.12 |
| Random rows (200) | 7.58 / 17.34 / 24.46 | 9.18 / 19.91 / 25.3 | 1.02 / 16.35 / 25.73 | 6.78 / 12.85 / 14.08 | 6.68 / 13.32 / 13.95 | 7.11 / 13.28 / 17.45 |
| Right 48 DIP per frame (400) | 6.61 / 12.53 / 26.78 | 4.93 / 11.98 / 15.61 | 0.27 / 11.23 / 20.67 | 0.21 / 8.94 / 11.7 | 0.2 / 8.5 / 20.97 | 0.2 / 8.65 / 15.97 |
| Page right (100) | 7.89 / 26.46 / 28.69 | 10.69 / 27.35 / 29.98 | 7.29 / 21.27 / 24.02 | 3.52 / 20.11 / 21.61 | 3.82 / 21.39 / 22.85 | 3.59 / 20.35 / 23.83 |
| Random x and y (200) | 11.25 / 25.36 / 29.29 | 10.98 / 25.4 / 32.45 | 11.08 / 23.07 / 35.2 | 10.63 / 22.07 / 26.06 | 11.27 / 22.32 / 27.91 | 10.57 / 22.45 / 25.57 |

- The spike's drawn rows reached 48.3 (Arm64) and 37.0 ms (x64) on random x and y; the grid's worst is 35.2 and 27.9 ms.
- Stale, missing or misplaced cells: 0 in each process, of 51,620 checked over 100 page downs and 109,902 over 200 random jumps, right after each step and one frame later.
- Realized: 250 cells at rest against a bound of 260 from the viewport, and 286 of 286 in random x and y. 52 row elements in all, 184 visual elements in the grid.
- GC was in the worst wait of 3 of the 36 phases run, at 8.4, 12.8 and 26.1 ms.
- Font warm-up on a pool thread: 510 to 594 ms, and 2.4 s (x64) and 5.9 s (Arm64) in each runner's first process. Cell glyphs on the rows' device: 84 to 101 ms.

### Behavior (the gate process, Arm64 | x64)

- Keys through `SendInput`: 41 presses (arrows, Page Up and Down, Home, End, Ctrl to the edges), 0 on a wrong cell, 0 off screen; input to frame p50 3.5 | 5.8 ms, max 33.4 | 44.4 ms. Shift extends; Ctrl+A selects all 200,000,000 cells.
- A click, a Shift+click and a click in the frozen pane select as expected; Ctrl+C puts the TSV the core's values make on the clipboard.
- Ctrl+C of 2,000 rows by 40 columns: 127 | 112 ms on a pool thread, the UI thread's longest wait 0.14 | 10.5 ms, the text as the core has it.
- Header: a drag on the edge takes the column from 140 to 200 px, a double-click fits it at 96 px, and two clicks ask for ascending, then descending.
- UIA: a DataGrid with Grid, Table and Selection, 1,000,000 rows by 200 columns. `GetItem(999999, 199)` reaches an unrealized cell with ScrollItem; a point query returns cell (2, 3); the focused element is the focused cell. `GetSelection` of a 10,000-cell selection takes 1,363 | 490 ms. `TablePattern.ColumnHeaders` has length 0 (Consequences).
- Theme: text #FFFFFFFF dark and #E4000000 light. High contrast turned on through `SystemParametersInfo`: background #FF202020, selection #FF8EE3F0 opaque, selected text #FF263B50.
- Text scale 150%: rows of 48 px, a 21 px font. DPI from 100% to 150% through `DisplayConfigSetDeviceInfo`: surfaces of 48 px. A lost device recovered. 0 stale cells after each.
- Right-to-left values sit at the right (ink centroid 0.53 Arabic, 0.80 Hebrew), emoji draw in color, NULL is italic in #72000000, and a cut value of 257 characters ends with the cut mark.

### Runner noise

- Runs 41522807557, 41525518800 and 41528085391 failed on Arm64 only, each by one or two steps: 56.5, 83.7, 61.5 and 76.7 ms. x64 passed every run from 41519410177.
- From 41528085391 each worst step records the UI thread's cycles per ms and the other processes' CPU time. In the 61.5 ms step the UI thread ran 67,000 cycles per ms against 2.1 million at the phase's median, while other processes used 938 ms of CPU.
- `run-gate.ps1` waits for an idle CPU before each process, names the processes that used the CPU during it, and turns Defender's real-time scanning off, which takes on x64 only.
- A step the runner took the core from fails the bar as any other: the gate is rerun, not the bar raised.
