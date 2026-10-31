using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace TablePro.App.Controls.DataGrid;

/// <summary>
/// One realized row: a canvas of pooled text slots for the visible columns only. Every property write is skipped when
/// the value has not changed, because each one crosses into the XAML runtime.
/// </summary>
internal sealed partial class GridRowPresenter : Canvas
{
    private readonly List<CellSlot> _slots = [];
    private readonly Microsoft.UI.Xaml.Shapes.Rectangle _bottomLine;
    private Brush? _background;

    public GridRowPresenter()
    {
        _bottomLine = new Microsoft.UI.Xaml.Shapes.Rectangle { Height = 1, IsHitTestVisible = false };
        Children.Add(_bottomLine);
        IsHitTestVisible = false;
    }

    public int Row { get; set; } = -1;

    public int FirstColumn { get; private set; } = -1;

    public int LastColumn { get; private set; } = -1;

    public void SetBackground(Brush? brush)
    {
        if (!ReferenceEquals(_background, brush))
        {
            _background = brush;
            Background = brush;
        }
    }

    public void Layout(double width, double height, Brush lineBrush)
    {
        if (Width != width)
        {
            Width = width;
            _bottomLine.Width = width;
        }

        if (Height != height)
        {
            Height = height;
            SetTop(_bottomLine, height - 1);
        }

        if (!ReferenceEquals(_bottomLine.Fill, lineBrush))
        {
            _bottomLine.Fill = lineBrush;
        }
    }

    public void SetColumnRange(int first, int last)
    {
        FirstColumn = first;
        LastColumn = last;
        var needed = last < first ? 0 : last - first + 1;
        while (_slots.Count < needed)
        {
            var slot = new CellSlot();
            _slots.Add(slot);
            Children.Add(slot.Text);
        }

        for (var i = 0; i < _slots.Count; i++)
        {
            _slots[i].SetVisible(i < needed);
        }
    }

    public CellSlot Slot(int column) => _slots[column - FirstColumn];

    internal sealed class CellSlot
    {
        private string? _text;
        private double _left = double.NaN;
        private double _width = double.NaN;
        private Brush? _foreground;
        private bool _italic;
        private bool _strike;
        private TextAlignment _alignment = TextAlignment.Left;
        private bool _visible = true;

        public CellSlot()
        {
            Text = new TextBlock
            {
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.NoWrap,
                MaxLines = 1,
                IsTextScaleFactorEnabled = false,
                IsHitTestVisible = false,
            };
        }

        public TextBlock Text { get; }

        public void SetVisible(bool visible)
        {
            if (_visible != visible)
            {
                _visible = visible;
                Text.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
            }
        }

        public void Update(string text, double left, double width, double top, Brush foreground, bool italic, bool strike, TextAlignment alignment)
        {
            if (!string.Equals(_text, text, StringComparison.Ordinal))
            {
                _text = text;
                Text.Text = text;
            }

            if (_left != left)
            {
                _left = left;
                SetLeft(Text, left);
                SetTop(Text, top);
            }

            if (_width != width)
            {
                _width = width;
                Text.Width = Math.Max(0, width);
            }

            if (!ReferenceEquals(_foreground, foreground))
            {
                _foreground = foreground;
                Text.Foreground = foreground;
            }

            if (_italic != italic)
            {
                _italic = italic;
                Text.FontStyle = italic ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal;
            }

            if (_strike != strike)
            {
                _strike = strike;
                Text.TextDecorations = strike ? Windows.UI.Text.TextDecorations.Strikethrough : Windows.UI.Text.TextDecorations.None;
            }

            if (_alignment != alignment)
            {
                _alignment = alignment;
                Text.TextAlignment = alignment;
            }
        }

        public void Reset() => _left = _width = double.NaN;
    }
}
