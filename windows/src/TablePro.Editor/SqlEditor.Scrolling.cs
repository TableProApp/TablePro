using Windows.Foundation;

namespace TablePro.Editor;

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

    // Room for at least three digits, as the macOS editor keeps, plus padding on both sides.
    private float GutterWidth
    {
        get
        {
            if (_layouts is null)
            {
                return 0;
            }
            var digits = Math.Max(3, Document.LineCount.ToString(System.Globalization.CultureInfo.InvariantCulture).Length);
            return GutterPadding * 2 + digits * _layouts.CharWidth;
        }
    }

    private float TextLeft => GutterWidth + 4;

    public void ScrollToLine(int line)
    {
        if (_layouts is null)
        {
            return;
        }
        SetScroll(_scrollX, Math.Clamp(line, 0, Document.LineCount - 1) * _layouts.LineHeight);
    }

    public void ScrollBy(double dx, double dy) => SetScroll(_scrollX + dx, _scrollY + dy);

    // Brings the primary caret into view, a line of margin above and below.
    public void EnsureCaretVisible()
    {
        if (_layouts is null)
        {
            return;
        }
        var (line, column) = Document.GetPosition(_model.Primary.Active);
        var lineHeight = _layouts.LineHeight;
        var top = line * lineHeight;
        var y = _scrollY;
        if (top < y)
        {
            y = top;
        }
        else if (top + lineHeight > y + ViewHeight)
        {
            y = top + lineHeight - ViewHeight;
        }
        var x = _scrollX;
        var caretX = CaretX(line, column);
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

    private double CaretX(int line, int column)
    {
        var text = LineText(line);
        if (text.Length <= Rendering.TextLayouts.LongLine && _layouts is not null && _brushes is not null)
        {
            return LayoutFor(line, text).XAt(column);
        }
        return column * (_layouts?.CharWidth ?? 8);
    }

    private void SetScroll(double x, double y)
    {
        if (_layouts is null)
        {
            return;
        }
        var maxY = Math.Max(0, (Document.LineCount - 1) * _layouts.LineHeight);
        var maxX = Math.Max(0, _widest + _layouts.CharWidth * 4 - (ViewWidth - TextLeft));
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
            _verticalBar.Minimum = 0;
            _verticalBar.Maximum = Math.Max(0, (Document.LineCount - 1) * lineHeight);
            _verticalBar.ViewportSize = Math.Max(1, ViewHeight);
            _verticalBar.SmallChange = lineHeight;
            _verticalBar.LargeChange = Math.Max(lineHeight, ViewHeight - lineHeight);
            _verticalBar.Value = _scrollY;
            var textWidth = Math.Max(1, ViewWidth - TextLeft);
            _horizontalBar.Minimum = 0;
            _horizontalBar.Maximum = Math.Max(0, _widest + _layouts.CharWidth * 4 - textWidth);
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

    // A point on the panel to a document offset: the line under it, then the column DirectWrite hits.
    internal int OffsetAt(Point point)
    {
        if (_layouts is null)
        {
            return 0;
        }
        var line = (int)Math.Floor((point.Y + _scrollY) / _layouts.LineHeight);
        line = Math.Clamp(line, 0, Document.LineCount - 1);
        return Document.GetLineStart(line) + ColumnAt(line, point.X);
    }

    internal int ColumnAt(int line, double x)
    {
        var text = LineText(line);
        var local = (float)(x - TextLeft + _scrollX);
        if (_layouts is null || _brushes is null)
        {
            return 0;
        }
        return Math.Clamp(LayoutFor(line, text).ColumnAt(local), 0, text.Length);
    }

    internal int VisualColumnAt(int line, double x)
    {
        var offset = Document.GetLineStart(line) + ColumnAt(line, x);
        return _model.VisualColumn(offset);
    }

    // The panel rectangle of an offset's caret, in DIPs.
    internal Rect CaretRect(int offset)
    {
        if (_layouts is null)
        {
            return default;
        }
        var (line, column) = Document.GetPosition(offset);
        var x = TextLeft - _scrollX + CaretX(line, column);
        var y = line * _layouts.LineHeight - _scrollY;
        return new Rect(x, y, 1, _layouts.LineHeight);
    }

    // Rectangles of a range on the visible lines, one per line, in panel DIPs.
    internal List<Rect> RangeRects(int start, int end)
    {
        var rects = new List<Rect>();
        if (_layouts is null)
        {
            return rects;
        }
        var first = Math.Max(Document.GetLineFromOffset(start), FirstVisibleLine);
        var last = Math.Min(Document.GetLineFromOffset(end), FirstVisibleLine + VisibleLineCount);
        for (var line = first; line <= last && line < Document.LineCount; line++)
        {
            var lineStart = Document.GetLineStart(line);
            var lineEnd = Document.GetLineEnd(line);
            var from = Math.Max(start, lineStart) - lineStart;
            var to = Math.Min(end, lineEnd) - lineStart;
            var x1 = TextLeft - _scrollX + CaretX(line, from);
            var x2 = TextLeft - _scrollX + CaretX(line, to);
            var y = line * _layouts.LineHeight - _scrollY;
            rects.Add(new Rect(x1, y, Math.Max(1, x2 - x1), _layouts.LineHeight));
        }
        return rects;
    }

    internal (int First, int Last) VisibleLines()
    {
        var first = FirstVisibleLine;
        return (first, Math.Min(Document.LineCount - 1, first + VisibleLineCount));
    }
}
