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
- `CellCache` holds windows of 64 rows by 16 columns as `CellBlock`s: the UTF-8 the core packed, decoded once into one UTF-16 buffer, with a state per cell (NULL, cut, right to left, lossy). A full cache refills its least recently used block, so scrolling allocates nothing once it is full: a test reads 400 random screens of a million-row core result and measures 0 bytes.
- The core cuts each cell at a cap from the column width (at least 256 characters) and marks it; the grid ends a cut value with an ellipsis of its own color.
- `GridColumns` keeps widths and positions for two panes: the row numbers with the frozen columns, and the scrolling columns from x = 0.
- `GridSelection` is an anchor and a focused cell, as cells, whole rows or everything, so a selection of any size is two numbers.
- `GridNavigation` moves as Excel does in a block with no empty cells: arrows, Page Up and Down, Home and End, Ctrl to the edges, Shift to extend.
- `GridCopy` writes Excel's TSV: tabs, CRLF, values with a tab, line break or quote quoted with quotes doubled, NULL as an empty cell. It streams blocks of 16,384 cells from a reader of its own, at a 4,096-character cap, and reads a cut value whole. The core shows control characters as spaces, so a text value with a space is read whole too.

### Virtualization (`src/TablePro.DataGrid`)

- A ScrollViewer holds four regions: the scrolling columns as content, their header row in `TopHeader`, the row numbers and frozen columns in `LeftHeader`, and their headers in `TopLeftHeader`.
- In each pane an ItemsRepeater realizes the rows in view through `RowsLayout`; the header row realizes the scrolling columns in view through `HeaderLayout`. Rows are arranged against an origin that moves in steps of 4,096 px, so arrange coordinates stay small in a 32M px grid.
- The four traps, each with a test in `tests/TablePro.DataGrid.Tests/ItemsRepeaterTrapTests.cs`:
  1. **Auto-recycle.** `ViewManager::GetElement` marks each element a layout gets for recycling unless the layout asks for it again in the same pass. The layouts keep elements across passes, so they pass `SuppressAutoRecycle`; without it one element served two rows.
  2. **The 10,000 px viewport.** `ViewportManager::UpdateViewport` takes an effective viewport past x and y 10,000 as cleared. The layouts take their windows from the grid's own scroll state, not `context.RealizationRect`, and the grid invalidates them on each scroll.
  3. **The O(n²) walk.** `ViewManager::GetElementIfAlreadyHeldByLayout` walks every child inside a cached index range that only grows. A repeater per row pane over row indices, and one over column indices for the headers, keeps each range small and contiguous.
  4. **Scroll anchoring.** Realized rows registered as anchor candidates, and the ScrollViewer moved its offset after recycled rows. The canvas that holds a pane's rows is the `IScrollAnchorProvider` the repeaters find first, and takes no candidates.

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
- Font fallback: `FontWarmup` lays out and draws a string of every common script once per font on a pool thread when the first grid is made, as the editor does for its font.
- Colors come from WinUI's theme resources for the element's theme, switched live on `ActualThemeChanged`. In high contrast, the system colors: the selection is the highlight color, opaque, and selected text takes the highlight text color.

### Input, selection and copy

- Arrows, Page Up and Down, Home and End, Ctrl+Home and Ctrl+End, Shift to extend; Ctrl+A selects every cell; Ctrl+C and Ctrl+Insert copy.
- A click picks a cell and Shift+click extends; a drag extends; a click on a row number picks the row, and on the corner, everything.
- The selection and the focused cell are a Rectangle and a Border in each pane, cut to the realized rows.
- Ctrl+C builds the TSV on a pool thread, so the UI thread does not wait for a selection of any size, then sets the clipboard.

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
- `TablePattern.ColumnHeaders` reads empty for clients on Windows App SDK 2.6.4: `CUIATableProviderWrapper::GetColumnHeaders` releases its SAFEARRAY before filling it. microsoft/microsoft-ui-xaml#11820 fixed it after 2.6.4. The grid returns its header peers; each cell's TableItem header reaches clients.
- The core has no sort; the grid raises `SortRequested` and the host sorts on the server.
- A UI in a right-to-left language would need the grid mirrored; only values read right to left today.
- Not yet: editing, column reorder, sizing columns to their content on load, row header peers, find, tooltips for cut cells.

## Alternatives considered

- **A TextBlock per cell.** Failed page right and random x and y in every variant (Context).
- **Win2D for the drawn rows.** What the spike used. A second text stack beside the editor's and a wrapper object per layout, which put a GC in every worst step.
- **One SwapChainPanel over the viewport.** One surface, but no element per row for ItemsRepeater to recycle, so virtualization, hit testing and the frozen pane would be ours too.
- **WinUI's TableView.** Preview, not in 2.6.4, no column virtualization in v1.
- **A single 2D repeater of cells.** The O(n²) walk: 66.7 ms per random step finding elements on x64 (spike run 41435447241).

## Gate

GATE_PLACEHOLDER
