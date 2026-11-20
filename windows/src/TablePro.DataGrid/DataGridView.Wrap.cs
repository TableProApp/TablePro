using TablePro.DataGrid.Model;

namespace TablePro.DataGrid;

// Wrapped cells and the uneven rows they make: windows/docs/decisions/0023-wrapped-cells-and-uneven-rows.md.
public sealed partial class DataGridView
{
    // The most lines a wrapped cell shows; text past them ends in an ellipsis.
    public const int MaximumWrapLines = RowHeights.MaximumLines;

    // Null while cells do not wrap, so every row is the one pitch and no row is measured.
    private RowHeights? _heights;
    private bool _wrapsText;

    // The ScrollViewer's offset and the one the grid holds in its place, until the ScrollViewer takes it.
    private (double Asked, double Kept)? _held;

    // Rows measured ahead of a scroll moved the offset, which the next ScrollTo hands to the ScrollViewer.
    private bool _unsynced;

    // A measured row changed height, so the rows below it and the boxes over them sit elsewhere.
    private bool _rowsMoved;

    // On, a long value wraps, a line break in it breaks the line, and a row is as tall as its tallest cell.
    public bool WrapsText
    {
        get => _wrapsText;
        set
        {
            if (_wrapsText == value)
            {
                return;
            }
            // The editor's box is its row's, which is about to change height.
            CommitOrCancel(EditorFocused);
            var anchor = FirstRowAnchor();
            _wrapsText = value;
            if (_cache is not null)
            {
                _cache.KeepsLineBreaks = value;
            }
            // A grid with no painter yet has no data either; its rows are sized when it gets them or loads.
            _heights = value && _painter is not null ? NewHeights(RowCount) : null;
            if (_painter is not null)
            {
                ColumnsChanged(anchor);
            }
        }
    }

    // The painter first: making it sets the row pitch from the text scale.
    private RowHeights NewHeights(int count)
    {
        var lineHeight = Painter.WrapLineHeight;
        return new RowHeights(count, _rowHeight, lineHeight);
    }

    public double TotalHeight => _heights is null ? RowCount * _rowHeight : _heights.Total;

    // Where a row starts in its pane: the row times the pitch while cells do not wrap.
    public double RowTop(int row) => _heights is null ? row * _rowHeight : _heights.Top(row);

    public double RowHeightOf(int row) => _heights is null ? _rowHeight : _heights.HeightOf(row);

    // Not clamped to the rows while cells do not wrap, as the division it stands for is not.
    internal int RowAt(double y) => _heights is null ? (int)Math.Floor(y / _rowHeight) : _heights.RowAt(y);

    internal int RowLines(int row) => _heights?.LinesOf(row) ?? 1;

    // The height of a run of rows: their count times the pitch while cells do not wrap.
    private double RowsHeight(int first, int last) =>
        _heights is null ? (last - first + 1) * _rowHeight : _heights.Top(last + 1) - _heights.Top(first);

    // The last row with any part above a y, from a first row on.
    private int LastRowAbove(double y, int first)
    {
        if (_heights is not { } heights)
        {
            return Math.Clamp((int)Math.Ceiling(y / _rowHeight) - 1, first, RowCount - 1);
        }
        var last = Math.Clamp(heights.RowAt(y), first, RowCount - 1);
        return last > first && heights.Top(last) >= y ? last - 1 : last;
    }

    // NULL, DEFAULT and an unreadable value are one word on the first line, wrapped or not.
    internal static bool Wraps(CellState state) =>
        (state & (CellState.Null | CellState.Default | CellState.Unreadable | CellState.Missing)) == 0;

    // The first row in view and how far into it the view starts, as a part of its height.
    private (int Row, double Part) FirstRowAnchor()
    {
        if (RowCount == 0 || _viewY <= 0)
        {
            return (0, 0);
        }
        var row = Math.Clamp(RowAt(_viewY), 0, RowCount - 1);
        var height = RowHeightOf(row);
        return (row, height > 0 ? Math.Clamp((_viewY - RowTop(row)) / height, 0, 1) : 0);
    }

    // Row heights changed: the offset becomes the one that shows the same row at the same part. True when it moved.
    private bool PlaceFirstRow((int Row, double Part) anchor)
    {
        var y = 0.0;
        if (RowCount > 0)
        {
            var row = Math.Min(anchor.Row, RowCount - 1);
            MeasureRow(row);
            y = RowTop(row) + (anchor.Part * RowHeightOf(row));
        }
        if (Math.Abs(y - _viewY) < 0.5)
        {
            return false;
        }
        _viewY = y;
        return true;
    }

    // Wrapped rows measure again, and with an anchor held the first row in view stays. True when the offset moved.
    private bool RemeasureRows((int Row, double Part)? held = null)
    {
        if (held is null && _heights is null)
        {
            return false;
        }
        var anchor = held ?? FirstRowAnchor();
        if (_heights is { } heights)
        {
            var lineHeight = Painter.WrapLineHeight;
            // A column drag asks on every move, so the store is cleared in place when its shape still fits.
            if (heights.Count == RowCount && heights.Pitch == _rowHeight && heights.LineHeight == lineHeight)
            {
                heights.Reset();
            }
            else
            {
                _heights = NewHeights(RowCount);
            }
        }
        return PlaceFirstRow(anchor);
    }

    // The grid moved its own offset to hold a row; the ScrollViewer takes it once its extent is the new one.
    private void SyncScroller()
    {
        UpdateExtent();
        _scroller.UpdateLayout();
        ScrollTo(_viewX, _viewY);
    }

    // The ScrollViewer's own offset, which lags the grid's by what the rows above grew until it takes the held one.
    private void FollowScroller(double x, double y) =>
        Follow(x, _held is { } held ? y + (held.Kept - held.Asked) : y);

    // Rows that grew above the first row moved the offset inside a scroll event; the ScrollViewer takes it after.
    private void KeepOffset(double from)
    {
        var lag = _held is { } before ? before.Kept - before.Asked : 0;
        var held = (Asked: from - lag, Kept: _viewY);
        _held = held;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_held is not { } now || now != held)
            {
                return;
            }
            SyncScroller();
        });
    }

    // Over every column, in view or not, so a row's height never changes on a sideways scroll. Returns the growth.
    private double MeasureRow(int row)
    {
        if (_heights is not { } heights || row < 0 || row >= heights.Count || heights.IsMeasured(row))
        {
            return 0;
        }
        var painter = Painter;
        var lines = 1;
        // A cell at the cap ends the row's measure: no other cell can make it taller.
        for (var column = 0; column < ColumnCount && lines < MaximumWrapLines; column++)
        {
            var cell = Cell(row, column);
            if (!Wraps(cell.State) || cell.Text.IsEmpty)
            {
                continue;
            }
            // Nine line breaks are ten lines with no layout.
            var width = (float)(_columns.Width(column) - (CellPainter.Padding * 2));
            lines = Math.Max(lines, cell.Text.Count('\n') >= MaximumWrapLines - 1
                ? MaximumWrapLines
                : painter.CountLines(cell.Text, cell.State, width));
        }
        var grown = heights.Set(row, Math.Min(lines, MaximumWrapLines));
        _rowsMoved |= grown != 0;
        return grown;
    }

    // Rows outside the view too: what the rows above it grow by is added to the offset, so the rows in view stay put.
    private void MeasureRows(int from, int step, double span)
    {
        if (_heights is not { } heights)
        {
            return;
        }
        var shift = 0.0;
        var used = 0.0;
        for (var row = from; row >= 0 && row < RowCount && used < span; row += step)
        {
            var above = heights.Top(row) < _viewY + shift;
            var grown = MeasureRow(row);
            if (above)
            {
                shift += grown;
            }
            used += heights.HeightOf(row);
        }
        if (shift != 0)
        {
            _viewY += shift;
            _unsynced = true;
        }
    }

    // The rows the view shows, measured as they come in. Rows that grow above the row that was first move the offset.
    private (int First, int Last) MeasureWindow(double height)
    {
        var heights = _heights!;
        var first = Math.Clamp(heights.RowAt(_viewY), 0, RowCount - 1);
        var (wasFirst, wasLast) = _rowWindow;
        if (wasLast >= wasFirst && first < wasFirst && wasFirst < RowCount)
        {
            var before = heights.Top(wasFirst);
            // Scrolling up with that row still in view: it stays where the scroll put it.
            if (before < _viewY + height)
            {
                for (var row = wasFirst - 1; row >= first; row--)
                {
                    MeasureRow(row);
                }
                _viewY += heights.Top(wasFirst) - before;
                first = Math.Clamp(heights.RowAt(_viewY), 0, RowCount - 1);
            }
        }
        MeasureRow(first);
        var bottom = _viewY + height;
        var last = first;
        var end = heights.Top(first) + heights.HeightOf(first);
        while (end < bottom && last < RowCount - 1)
        {
            last++;
            MeasureRow(last);
            end += heights.HeightOf(last);
        }
        return (first, last);
    }

    // Rows a page key moves from the focused row; wrapped rows on the way are measured first.
    private int PageRows(bool down)
    {
        var viewport = VisibleArea().Height;
        if (_heights is not { } heights)
        {
            return GridNavigation.PageRows(viewport, _rowHeight);
        }
        MeasureRows(_selection.FocusRow, down ? 1 : -1, viewport + _rowHeight);
        return GridNavigation.PageRows(heights, _selection.FocusRow, viewport, down);
    }
}
