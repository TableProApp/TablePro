# 0024: Wrapped cells and rows of uneven height

- **Status**: Accepted
- **Date**: 2026-11-20

## Context

[0003](0003-data-grid-control.md) draws every cell on one line, cut with an ellipsis and centered, in rows of one height, and turns scroll anchoring off because "rows have a fixed height". Reading a long value meant widening its column or opening the value. #4329 asks for cells that wrap, with each row as tall as its tallest cell.

The maintainer decided (2026-11-20): the whole grid wraps or does not, per tab; View and the column headers' menu switch it; Settings holds the start for new tabs; a row fits its tallest cell up to 10 lines, and text past that ends in an ellipsis; a line break in a value breaks the line while cells wrap, and stays a space while they do not.

Three parts of 0003 could not hold a tall row: the core's text had no line breaks left, the text formats were `NO_WRAP`, and a row's place was `row * pitch` at about twenty sites.

## Decision

`DataGridView.WrapsText` wraps the cells of a grid. While it is off, nothing below runs: no height store exists, every site computes `row * pitch` as before, the fetch, its cap and the formats are 0003's. This supersedes 0003's one line per cell (Drawing), its fixed row height (Virtualization, trap 4's reason), the editor's four-row growth in a wrapped grid (Editing) and the tip's rule in a wrapped grid (Accessibility). The five traps and anchoring off stay.

### Text

- The grid's reader asks the core for windows that keep line breaks ([core 0041](../../../core/docs/decisions/0041-a-result-window-can-keep-its-line-breaks.md)): every break form is one LF, every other control a space. `CellBlock.AddTyped` shows pending text by the same set of forms, so a typed NEL or U+2028 is a space with wrap off and a break with it on, as a saved one is.
- A value's last line break is dropped from the cell's text, so it starts no empty line. Core Text gives such a value one line and Pango two; the grid does not ask DirectWrite.
- In a kept-breaks read a text cell that holds a space or a line break is `Lossy`, since an LF may stand for CR LF or another form. A copy reads such a cell whole, so it writes the value's own break.
- `CellCache` drops every block when the mode changes: its key has no mode, and a block read on one line must not serve a wrapped grid.
- The per-cell cap is ten lines of the narrowest glyphs, at least 256 characters. The core cuts there, so DirectWrite never lays out a multi-megabyte value.

### Row heights (`RowHeights`, in the model project)

- One byte per row: its lines, 1 to 10, or 0 for not measured, which counts as one line. A million rows is 1 MB. Sums of extra lines per 256 rows give `Top(row)` and `RowAt(y)` in one multiply, one sum and a walk of at most 256 bytes; a change marks the later sums stale and the next read sums forward.
- A row is one pitch plus one line height per line after the first. The line height is the wrap format's, set with `DWRITE_LINE_SPACING_METHOD_UNIFORM`, so a line that falls back to a Han or emoji font is no taller and a row's height is its line count.
- A row is measured once, when it first comes into the row window, over every column: a row's height must not change on a sideways scroll, and the frozen pane's row and the scrolling pane's row are two elements that read one height. A cell is one line with no layout when the sum of its characters' advances fits the column (ASCII from a table measured per font, two ems for anything else) and it holds no LF. A cell with nine LFs is ten lines with no layout. The measure stops at the first cell that reaches ten lines.
- Heights reset when a column's width, the column set, the font, the text scale, the data or the edits change, and when wrap is switched.

### Holding the first row

Anchoring stays off (trap 4), so the grid holds its own place. Before row heights change it takes the first row in view and how far into it the view starts, as a part of the row's height, and afterwards scrolls to that row at that part. This runs for a wrap switch, a column resize, an edit, and for a font size or text scale change with wrap off too: before this, `ApplyFont` kept the pixel offset, so at row 5,000 a font size change from 14 to 20 showed row 3,478.

Scrolling up brings in rows not yet measured, which grow as they come in. The grid measures them, adds their growth to its offset in the same pass so the rows in view stay where the scroll put them, and hands the offset to the ScrollViewer once the scroll event is over. `ScrollIntoView` and the page keys measure the rows that will share the view with their target first, so the target is exact.

### Drawing

- Wrap formats use `DWRITE_WORD_WRAPPING_EMERGENCY_BREAK` (Windows 8.1 and later), so a URL, a hash or JSON with no space breaks inside itself, near paragraph alignment and uniform line spacing. The first line starts `(pitch - line height) / 2` down, where the one centered line sat.
- The cap. DirectWrite has no line limit, and what trimming does to a wrapped layout is not documented (`SetTrimming` says "the layout width", `DWRITE_TRIMMING` "the layout box"). So the grid lays the text out, reads `GetLineMetrics`, cuts the text where line ten ends, drops trailing white space, appends one ellipsis and lays out again; while the ellipsis pushes the text onto an eleventh line it drops one more character. Only cells past the cap pay for the second layout. Text the core cut already ends in an ellipsis, so none is added.
- In a tall row the row number, NULL, DEFAULT and an unreadable value sit on the first line.
- With wrap on a row's surface is as tall as its row and shrinks, since a recycled element may have held ten lines.

### Around the rows

- Hit testing, the visible rows, scroll into view, the selection and focus boxes, the keyboard menu's point, the cell tip's rectangle and the UIA bounds of cells and row numbers read `RowTop`, `RowHeightOf` and `RowAt`.
- The editor opens over the whole row with `TextWrapping.Wrap`, at least as tall as the row.
- A wrapped cell has a tip when the core cut it or it has more than ten lines, not when one line would pass the column. The tip's text keeps the line breaks. A tip of a value past 1,000 characters ended in two ellipses, the block's and one the tip added; it ends in one.
- Column sizing is as before: a column fits the widest line of a value.

### The app

- `AppSettings.GridWrapText`, off, with a card under Settings, Data grid. It is read once when a tab is made; `DisplaySettings` does not push it, so an open tab never follows it.
- `TableTab` and `QueryTab` hold a `bool`, saved as `SessionTab.WrapText`. A session written before has none, and the tab then reads the setting once.
- View has Wrap text, a `ToggleMenuFlyoutItem`, as the menus guidance lists for "switching an option on or off". A table tab's header menu has it too, and a query result's header now has a menu of its own that holds it. Structure, key and share grids do not wrap.

## Rationale

- Height from every column is what the macOS and Linux grids give, where no column is virtualized. Height from the columns in view would change rows on a sideways scroll and let the two panes disagree.
- The cut uses documented calls only. Trimming a wrapped layout to a height would be one layout, but its result is not specified.
- The store lives in the model project, so its arithmetic is tested on every runner; the control's tests run on Windows only.

## Consequences

- The extent is known only for measured rows, so the scroll thumb drifts while a result with many tall rows is first scrolled.
- Correcting the offset during a wheel or touch scroll calls `ChangeView`, which may end the scroll's own animation the first time unmeasured rows come in from above. Not measured.
- A block of a wrapped grid can hold ten times the text. 0003 chose 32 by 8 blocks to keep long text off the large object heap at a one-line cap; the gate's wrap phases are how that is measured.
- A million rows of ten lines is an extent ten times the 32M px the gate proved.
- `IGridReader` gained `KeepsLineBreaks`, with a default that reads on one line, so a host's reader keeps working and its grid wraps at soft breaks only.

## Alternatives considered

- **Trimming with a maximum height.** Undocumented for a wrapped layout.
- **ScrollViewer anchoring.** What anchoring is for, but trap 4 measured it moving the offset after recycled rows in 350 of 600 steps.
- **A fixed number of lines for every row.** No measuring, but every row pays for the longest value.
- **Measuring every row up front.** A column resize changes every wrap width and would start it again over a million rows.

## Gate

`tests/TablePro.DataGrid.Gate` runs three more phases with `WrapsText` on, after the six of 0003 and under the same 50 ms bar: down 3 rows per frame, page down and random x and y. The six phases of 0003 run first with wrap off and are unchanged. The wrap phases have not run yet: the gate runs by dispatch (`.github/workflows/windows-grid-gate.yml`), and their numbers belong here with the run id.
