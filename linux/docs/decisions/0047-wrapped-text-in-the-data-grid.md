# 0047: Wrapped text in the data grid, with the height owned by the cell

- **Status**: Accepted
- **Date**: 2026-11-20
- **Supersedes**: [0027](0027-one-data-grid.md), one line per row only

## Context

0027 kept every row one line tall. A long value is cut at the column's edge, and reading it means widening the column or opening Row Details (#4329). The maintainer decided on a Wrap Text option for the whole grid, per tab, with a default for new tabs in Preferences: rows fit their tallest cell up to 10 lines, text past that ends in an ellipsis, and a line break in the value breaks the line.

`GtkColumnView` already lays out rows of different heights: it measures each row that has a widget height-for-width and gives the rest the median. Three things kept the grid at one line:

- `GridCell` asked for a constant size, so GTK never told it a width.
- `GtkInscription` sizes by `min-lines` and `nat-lines`, never by its text, on purpose.
- A new text queues a draw, never a resize.

## Decision

`GtkInscription` stays the widget that draws a value, and `GridCell` owns the height: while its grid wraps, it asks for height-for-width and measures the text it is bound to at the column's width, capped at 10 lines.

- **State.** One flag per `DataGrid`, behind the stateful action `grid.wrap-text`, read from the GSettings key `grid-wrap-text` once when the grid is built. A settings change never reaches an open grid. An editor tab builds a grid per result, so its `ResultsPane` holds the tab's flag and gives it to every grid it builds, across result pages and runs. A grid offers the action only where `GridConfig::wrap_text` says so, which the key tab leaves off.
- **Height.** The cell lays the text out with Pango at the width GTK passes, and answers the extents of its first 10 lines as minimum and natural, since the list takes a row's minimum. The height comes from laid-out lines, since the font's metric line is shorter and `min-lines` would hide the last one. With no width, as between Size to Fit and the next width, it answers one line.
- **Text.** The 1,000-character cut comes first, so Pango never shapes a whole value. Then the eight line break forms (LF, CRLF as one, CR, VT, FF, NEL, LS, PS) become LF and one trailing break is dropped, in the app, since Pango breaks at only some of them and the marks would label the rest. Other invisible characters keep their marks.
- **Cap.** When the layout has more than 10 lines the cell cuts the text where line 11 starts and appends the ellipsis itself, since Pango draws none when the cut falls on a line break.
- **Cost.** A text change queues a resize only when the old or the new text can take more than one line: it holds a line break or a tab, or its byte length times twice the font's character width passes the column's width. Number columns and placeholders never wrap. With wrap off the cell asks for a constant size and none of this runs.
- **Alignment.** In a tall row the value, the row number and the inline editor sit on the first line.
- **Tooltip.** A cell is cut when it leaves text out or its text takes more lines than it shows.

## Rationale

- The Inscription is the toolkit's widget for text in a list, every `cell.display()` reader keeps working, and `GridCell` was already a custom widget with its own `measure`.
- A positive Pango height caps the total lines, measured: a 1,000-character value and 50 one-line paragraphs both stop at the row's height.
- With wrap off nothing changes, so the default grid keeps the cost 0027 measured.

## Consequences

- Rows without a widget take the median height, so with mixed heights the scrollbar's length is an estimate that settles as rows come into view. Scrolling to a row is by position and stays exact.
- A column resize measures the column's cells again, up to about 200 of them, each at most 1,000 characters.
- The inline editor stays one line; a value with line breaks opens in Row Details as before.
- The flag is not saved with the tab: a restored tab opens with the setting.
- The Pango facts were measured on Pango 1.58.2; `crates/app/src/ui/data_grid/tests/wrap.rs` keeps them as tests.

## Alternatives considered

- **`GtkLabel` with `wrap`, `lines` and `ellipsize`.** `lines` is a negative Pango height, which caps lines per paragraph: a value of 50 line breaks made a 51-line row. It also replaces the widget every reader reaches through `display()`.
- **`Inscription::set_min_lines(10)`.** It sizes by the font's metric line, 15.52 px against a laid-out 17 px, so 10 lines' worth of height showed 9, and it takes the height whatever the text.
- **Leaving the cap's ellipsis to Pango.** It ellipsizes only inside a line, so text cut at a line break ended with no sign of the cut.
