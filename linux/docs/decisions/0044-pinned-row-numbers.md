# 0044: Row numbers share the grid's scrolling and input

- **Status**: Accepted
- **Date**: 2026-11-08
- **Supersedes**: [0027](0027-one-data-grid.md), row-number scrolling only

## Context

GTK 4.22 has no frozen column or row-header widget API. Its ColumnView moves all
columns by the horizontal adjustment. Two lists would have separate selection
anchors and row-height estimates even with the same model and adjustment.

## Decision

Keep one ColumnView as the only row layout, input and accessibility surface.
After its normal snapshot, the scrollable container draws the native row-number
cells and header again at the fixed edge. It snapshots each native row through
its actual parent into a fresh, untransformed snapshot, then clips and translates
the resulting node. A passive themed background covers the underlying data.

This preserves the actual row height, selection background, pending icons, stripes
and CSS without another row model or copied measurements. Descendant redraws
invalidate the container, so both drawings use the same frame. The documented
header and row CSS hierarchy identifies the source widgets.

Pointer events reach the main native list, which keeps its selection anchor,
rubberband and keyboard navigation. Inline editors are allocated only in the
uncovered part of their cell. The grid resolves gutter clicks as rows and uses
its existing row and header menus. Keyboard focus is revealed after allocation,
when the new horizontal geometry is available.

## Consequences

The row-number column stays first. Existing saved data-column order remains usable;
loading a layout does not write storage. There is no second list, adjustment,
height group or accessibility tree to synchronize.

Pixel and gesture tests live in `crates/app/src/ui/data_grid/tests/gutter.rs`.
A toolkit upgrade must keep them passing. If GTK adds a native frozen-column API,
use it and remove the extra snapshot.

## Sources

- [GTK 4.22 column API](https://github.com/GNOME/gtk/blob/4.22.0/gtk/gtkcolumnviewcolumn.h)
- [GTK 4.22 column allocation](https://github.com/GNOME/gtk/blob/4.22.0/gtk/gtkcolumnview.c)
- [GTK snapshot_child contract](https://docs.gtk.org/gtk4/method.Widget.snapshot_child.html)
- [GTK 4.22 child snapshots and redraw propagation](https://github.com/GNOME/gtk/blob/4.22.0/gtk/gtkwidget.c)
