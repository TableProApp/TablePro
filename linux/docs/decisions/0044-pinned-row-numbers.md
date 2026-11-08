# 0044: Row numbers share the grid's scrolling and input

- **Status**: Accepted
- **Date**: 2026-11-08
- **Supersedes**: [0027](0027-one-data-grid.md), row-number scrolling only

## Context

GTK 4.22 has no frozen column or row-header widget API. Its ColumnView moves all
columns by the horizontal adjustment. Two interactive lists would have separate
selection anchors, rubberbands and focus even with the same MultiSelection.

## Decision

Keep the main ColumnView as the only input and accessibility surface. A passive
ColumnView projects its row numbers over the left edge when scrolled horizontally.
Both use the same selection model and vertical adjustment inside one GtkScrollable
container and one ScrolledWindow. Numbers use the data font and reserve pending-icon height, so ordinary rows have
the same height. Per-row SizeGroups pair the number cells and active editor without
copying an allocated height or grouping every data cell. Native header widgets
share a height group; their documented header CSS node is located in the composite.

The projection cannot take input or focus and is hidden from accessibility. Pointer
events reach the main native list, which keeps its selection anchor, drag gestures
and keyboard navigation. Inline editors are allocated only in the uncovered part of their cell so their
native gestures cannot take a gutter gesture. The grid resolves gutter clicks as rows
and uses its existing row and header menus. Keyboard focus scrolls clear of the gutter.

## Consequences

The row-number column stays first. Existing saved data-column order remains usable;
loading a layout does not write storage. Numbering, pending icons and stripes use
the same factory in both views. The gutter adds one column's visible row widgets.

The geometry and gesture probes live in
`crates/app/src/ui/data_grid/tests/gutter.rs`. A toolkit upgrade must keep them
passing. If GTK adds a native frozen-column API, use it and remove the projection.

## Sources

- [GTK 4.22 column API](https://github.com/GNOME/gtk/blob/4.22.0/gtk/gtkcolumnviewcolumn.h)
- [GTK 4.22 column allocation](https://github.com/GNOME/gtk/blob/4.22.0/gtk/gtkcolumnview.c)
- [GTK 4.22 list input and scrolling](https://github.com/GNOME/gtk/blob/4.22.0/gtk/gtklistbase.c)
