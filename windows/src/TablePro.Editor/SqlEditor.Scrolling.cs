using Microsoft.UI.Xaml;
using TablePro.Editor.Model;
using Windows.Foundation;

namespace TablePro.Editor;

// Geometry is by row: a row is a line unless lines wrap or fold (EditorModel.Rows).
public sealed partial class SqlEditor
{
    private const float GutterPadding = 12;

    private double _scrollX;
    private double _scrollY;
    private float _widest;
    private bool _syncingBars;

    public double VerticalOffset => _scrollY;

    public double HorizontalOffset => _scrollX;

    private double ViewHeight => _panel.ActualHeight;

    private double ViewWidth => _panel.ActualWidth;

    private int Digits => Math.Max(3, Document.LineCount.ToString(System.Globalization.CultureInfo.InvariantCulture).Length);

    // Where the line numbers end; at least three digits, as the macOS editor keeps.
    private float NumbersRight => _layouts is null ? 0 : GutterPadding + Digits * _layouts.CharWidth;

    // The chevron column after the numbers, only while folding is on.
    private float FoldColumnWidth => _layouts is null || !_foldingEnabled ? 0 : MathF.Round(_layouts.LineHeight * 0.9f);

    private float GutterWidth
    {
        get
        {
            if (_layouts is null)
            {
                return 0;
            }
            return _foldingEnabled ? NumbersRight + 4 + FoldColumnWidth + 4 : NumbersRight + GutterPadding;
        }
    }

    private float TextLeft => GutterWidth + 4;

    public void ScrollToLine(int line)
    {
        if (_layouts is null)
        {
            return;
        }
        SetScroll(_scrollX, _model.Rows.FirstRowOf(Math.Clamp(line, 0, Document.LineCount - 1)) * _layouts.LineHeight);
    }

    public void ScrollBy(double dx, double dy) => SetScroll(_scrollX + dx, _scrollY + dy);

    public void EnsureCaretVisible()
    {
        if (_layouts is null)
        {
            return;
        }
        var active = _model.Primary.Active;
        var row = _model.Rows.RowOf(active);
        var lineHeight = _layouts.LineHeight;
        var top = row * lineHeight;
        var y = _scrollY;
        if (top < y)
        {
            y = top;
        }
        else if (top + lineHeight > y + ViewHeight)
        {
            y = top + lineHeight - ViewHeight;
        }
        if (_wordWrap)
        {
            SetScroll(0, y);
            return;
        }
        var x = _scrollX;
        var caretX = CaretX(row, active);
        var textWidth = ViewWidth - TextLeft;
        if (caretX < x)
        {
            x = Math.Max(0, caretX - textWidth / 3);
        }
        else if (caretX > x + textWidth - _layouts.CharWidth * 2)
        {
            x = caretX - textWidth + _layouts.CharWidth * 4;
        }
        _widest = Math.Max(_widest, (float)caretX);
        SetScroll(x, y);
    }

    // The offset's x in its row, from the row's start.
    private double CaretX(int row, int offset)
    {
        var (_, start, end) = _model.Rows.RowSpan(row);
        var column = Math.Clamp(offset, start, end) - start;
        if (end - start <= TablePro.Graphics.TextLayouts.LongLine && _layouts is not null && _brushes is not null)
        {
            return LayoutFor(row, start, end).XAt(column);
        }
        return column * (_layouts?.CharWidth ?? 8);
    }

    // Columns a row holds once lines wrap: the text width less a column, so the caret at a row's end stays in view.
    private void UpdateWrap()
    {
        if (_layouts is null)
        {
            return;
        }
        var columns = 0;
        if (_wordWrap)
        {
            var width = ViewWidth - TextLeft;
            if (width < 1)
            {
                return;
            }
            columns = Math.Max(8, (int)((width - _layouts.CharWidth) / _layouts.CharWidth));
        }
        if (_model.Rows.SetWrap(columns, _model.Options.TabSize))
        {
            _frameLayouts.Clear();
            _frameVersion = -1;
            if (_wordWrap)
            {
                _scrollX = 0;
            }
            Invalidate();
        }
    }

    private void SetScroll(double x, double y)
    {
        if (_layouts is null)
        {
            return;
        }
        var maxY = Math.Max(0, (_model.Rows.RowCount - 1) * _layouts.LineHeight);
        var maxX = _wordWrap ? 0 : Math.Max(0, _widest + _layouts.CharWidth * 4 - (ViewWidth - TextLeft));
        x = Math.Clamp(x, 0, maxX);
        y = Math.Clamp(y, 0, maxY);
        if (x == _scrollX && y == _scrollY)
        {
            return;
        }
        _scrollX = x;
        _scrollY = y;
        UpdateScrollBars();
        Invalidate();
    }

    private void UpdateScrollBars()
    {
        if (_layouts is null)
        {
            return;
        }
        _syncingBars = true;
        try
        {
            var lineHeight = _layouts.LineHeight;
            var maxY = Math.Max(0, (_model.Rows.RowCount - 1) * lineHeight);
            // Folding or a narrower wrap can leave the view past the last row.
            if (_scrollY > maxY)
            {
                _scrollY = maxY;
            }
            _verticalBar.Minimum = 0;
            _verticalBar.Maximum = maxY;
            _verticalBar.ViewportSize = Math.Max(1, ViewHeight);
            _verticalBar.SmallChange = lineHeight;
            _verticalBar.LargeChange = Math.Max(lineHeight, ViewHeight - lineHeight);
            _verticalBar.Value = _scrollY;
            _horizontalBar.Visibility = _wordWrap ? Visibility.Collapsed : Visibility.Visible;
            var textWidth = Math.Max(1, ViewWidth - TextLeft);
            _horizontalBar.Minimum = 0;
            _horizontalBar.Maximum = _wordWrap ? 0 : Math.Max(0, _widest + _layouts.CharWidth * 4 - textWidth);
            _horizontalBar.ViewportSize = textWidth;
            _horizontalBar.SmallChange = _layouts.CharWidth * 4;
            _horizontalBar.LargeChange = textWidth;
            _horizontalBar.Value = _scrollX;
        }
        finally
        {
            _syncingBars = false;
        }
    }

    private void ScrollFromBar(bool vertical, double value)
    {
        if (_syncingBars)
        {
            return;
        }
        if (vertical)
        {
            SetScroll(_scrollX, value);
        }
        else
        {
            SetScroll(value, _scrollY);
        }
    }

    private int RowAt(double y) =>
        _layouts is null ? 0 : Math.Clamp((int)Math.Floor((y + _scrollY) / _layouts.LineHeight), 0, _model.Rows.RowCount - 1);

    // Past the end of a wrapped row the caret stays on that row, one step before the next row starts.
    internal int OffsetAt(Point point)
    {
        if (_layouts is null || _brushes is null)
        {
            return 0;
        }
        var row = RowAt(point.Y);
        var (_, start, end) = _model.Rows.RowSpan(row);
        var local = (float)(point.X - TextLeft + _scrollX);
        var offset = start + Math.Clamp(LayoutFor(row, start, end).ColumnAt(local), 0, end - start);
        if (offset >= end && end > start && !_model.Rows.IsLastRowOfLine(row))
        {
            offset = TextUnits.PreviousCaretStop(Document, end);
        }
        return offset;
    }

    internal Rect CaretRect(int offset)
    {
        if (_layouts is null)
        {
            return default;
        }
        var row = _model.Rows.RowOf(offset);
        var x = TextLeft - _scrollX + CaretX(row, offset);
        var y = row * _layouts.LineHeight - _scrollY;
        return new Rect(x, y, 1, _layouts.LineHeight);
    }

    // One rectangle per row on screen, so a wrapped line gives several and a folded one none.
    internal List<Rect> RangeRects(int start, int end)
    {
        var rects = new List<Rect>();
        if (_layouts is null)
        {
            return rects;
        }
        var rows = _model.Rows;
        var first = Math.Max(rows.RowOf(start), FirstVisibleRow);
        var last = Math.Min(rows.RowOf(end), FirstVisibleRow + VisibleLineCount);
        for (var row = first; row <= last && row < rows.RowCount; row++)
        {
            var (_, rowStart, rowEnd) = rows.RowSpan(row);
            var from = Math.Max(start, rowStart);
            var to = Math.Min(end, rowEnd);
            if (to < from)
            {
                continue;
            }
            var x1 = TextLeft - _scrollX + CaretX(row, from);
            var x2 = TextLeft - _scrollX + CaretX(row, to);
            var y = row * _layouts.LineHeight - _scrollY;
            rects.Add(new Rect(x1, y, Math.Max(1, x2 - x1), _layouts.LineHeight));
        }
        return rects;
    }

    // Each run of rows on screen whose lines follow one another, so a fold between them splits the ranges.
    internal List<(int Start, int End)> VisibleRanges()
    {
        var first = Math.Min(FirstVisibleRow, _model.Rows.RowCount - 1);
        return RowRanges(first, Math.Min(_model.Rows.RowCount - 1, first + VisibleLineCount));
    }

    private List<(int Start, int End)> RowRanges(int first, int last)
    {
        var ranges = new List<(int Start, int End)>();
        var rows = _model.Rows;
        var previousLine = -1;
        for (var row = first; row <= last; row++)
        {
            var (line, start, end) = rows.RowSpan(row);
            if (ranges.Count > 0 && (line == previousLine || line == previousLine + 1))
            {
                ranges[^1] = (ranges[^1].Start, end);
            }
            else
            {
                ranges.Add((start, end));
            }
            previousLine = line;
        }
        return ranges;
    }

    // For UIA's ScrollIntoView: the offset's row at the top, or brought into view only when off screen.
    internal void ScrollIntoView(int offset, bool alignToTop)
    {
        if (_layouts is null)
        {
            return;
        }
        var row = _model.Rows.RowOf(offset);
        var first = FirstVisibleRow;
        var last = first + VisibleLineCount - 1;
        if (alignToTop || row < first || row > last)
        {
            var top = alignToTop ? row : Math.Max(0, row - VisibleLineCount + 1);
            SetScroll(_scrollX, top * _layouts.LineHeight);
        }
    }
}
