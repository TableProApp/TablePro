using System.Text;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TablePro.App.Helpers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;

namespace TablePro.App.Controls.DataGrid;

public sealed record GridCell(int Row, int Column);

public sealed class GridCellEventArgs(int row, int column, UIElement target, Point position) : EventArgs
{
    public int Row { get; } = row;

    public int Column { get; } = column;

    public UIElement Target { get; } = target;

    public Point Position { get; } = position;
}

public sealed class SortRequestedEventArgs(int column, bool addToExisting) : EventArgs
{
    public int Column { get; } = column;

    public bool AddToExisting { get; } = addToExisting;
}

/// <summary>
/// A spreadsheet-style grid for query results and table rows. Rows and columns are virtualized by hand on one canvas:
/// only the visible cells exist, their text slots are recycled, and the selection is a single rectangle however many
/// rows it spans. Row heights are fixed, so every hit test and scroll target is arithmetic.
/// </summary>
public sealed partial class DataGridView : UserControl
{
    private const double HeaderHeight = 32;
    private const double CellPadding = 10;
    private const int Overscan = 4;

    private readonly Grid _root = new();
    private readonly ScrollViewer _scroller;
    // Every canvas is pinned top-left: a sized canvas in a stretching parent is otherwise centered, which would
    // shift the cells away from their headers.
    private readonly Canvas _canvas = new() { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
    private readonly Canvas _headerCanvas = new() { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
    private readonly Canvas _rowNumberCanvas = new() { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
    private readonly Border _headerHost;
    private readonly Border _rowNumberHost;
    private readonly Border _corner;
    private readonly TranslateTransform _headerShift = new();
    private readonly TranslateTransform _rowNumberShift = new();
    private readonly Rectangle _selectionRect = new() { IsHitTestVisible = false, RadiusX = 2, RadiusY = 2 };
    private readonly Rectangle _focusRect = new() { IsHitTestVisible = false, StrokeThickness = 2, RadiusX = 2, RadiusY = 2 };
    private readonly Rectangle _rowNumberSelection = new() { IsHitTestVisible = false };
    private readonly TextBox _editor;
    private readonly Dictionary<int, GridRowPresenter> _realized = [];
    private readonly Stack<GridRowPresenter> _pool = new();
    private readonly Dictionary<int, TextBlock> _rowNumbers = [];
    private readonly Stack<TextBlock> _rowNumberPool = new();
    private readonly List<HeaderCell> _headers = [];
    private readonly List<Rectangle> _columnLines = [];

    private IGridSource? _source;
    private double[] _widths = [];
    private double[] _offsets = [0];
    private double _rowHeight = 28;
    private double _rowNumberWidth = 48;
    private int _anchorRow = -1;
    private int _anchorColumn = -1;
    private int _activeRow = -1;
    private int _activeColumn = -1;
    private bool _wholeRows;
    private bool _dragging;
    private bool _draggingRows;
    private int _editRow = -1;
    private int _editColumn = -1;
    private IReadOnlyList<(int Column, bool Descending)> _sort = [];
    private Brushes _brushes;

    // Created by the framework only once an automation client (Narrator, Inspect) looks at the grid; until then every
    // notification below is a null check.
    private DataGridAutomationPeer? _automation;

    public DataGridView()
    {
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        TabFocusNavigation = KeyboardNavigationMode.Once;

        _root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(HeaderHeight) });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        _corner = new Border { Width = _rowNumberWidth, BorderThickness = new Thickness(0, 0, 1, 1) };
        _corner.Tapped += (_, _) => SelectAll();
        ToolTipService.SetToolTip(_corner, Strings.Get("Grid/SelectAll"));
        _root.Children.Add(_corner);

        _headerCanvas.RenderTransform = _headerShift;
        _headerHost = new Border { Child = _headerCanvas, BorderThickness = new Thickness(0, 0, 0, 1) };
        Grid.SetColumn(_headerHost, 1);
        _root.Children.Add(_headerHost);

        _rowNumberCanvas.RenderTransform = _rowNumberShift;
        _rowNumberCanvas.Children.Add(_rowNumberSelection);
        _rowNumberHost = new Border { Child = _rowNumberCanvas, Width = _rowNumberWidth, BorderThickness = new Thickness(0, 0, 1, 0) };
        _rowNumberHost.PointerPressed += OnRowNumberPointerPressed;
        _rowNumberHost.PointerMoved += OnRowNumberPointerMoved;
        _rowNumberHost.PointerReleased += OnPointerReleased;
        Grid.SetRow(_rowNumberHost, 1);
        _root.Children.Add(_rowNumberHost);

        _canvas.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _canvas.Children.Add(_selectionRect);
        Canvas.SetZIndex(_selectionRect, 0);
        _canvas.Children.Add(_focusRect);
        Canvas.SetZIndex(_focusRect, 2);
        _editor = new TextBox
        {
            Visibility = Visibility.Collapsed,
            Padding = new Thickness(CellPadding - 2, 4, 4, 0),
            MinHeight = 0,
            BorderThickness = new Thickness(2),
            CornerRadius = new CornerRadius(2),
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
            AcceptsReturn = false,
        };
        _editor.KeyDown += OnEditorKeyDown;
        _editor.LostFocus += (_, _) => CommitEdit(move: null);
        _canvas.Children.Add(_editor);
        Canvas.SetZIndex(_editor, 3);
        _canvas.PointerPressed += OnCanvasPointerPressed;
        _canvas.PointerMoved += OnCanvasPointerMoved;
        _canvas.PointerReleased += OnPointerReleased;
        _canvas.DoubleTapped += OnCanvasDoubleTapped;
        _canvas.RightTapped += OnCanvasRightTapped;

        _scroller = new ScrollViewer
        {
            Content = _canvas,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Enabled,
            VerticalScrollMode = ScrollMode.Enabled,
            ZoomMode = ZoomMode.Disabled,
            IsTabStop = false,
        };
        _scroller.ViewChanged += (_, _) => UpdateViewport(force: false);
        _scroller.SizeChanged += (_, _) => UpdateViewport(force: false);
        Grid.SetColumn(_scroller, 1);
        Grid.SetRow(_scroller, 1);
        _root.Children.Add(_scroller);

        _headerHost.SizeChanged += (_, e) => _headerHost.Clip = new RectangleGeometry { Rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height) };
        _rowNumberHost.SizeChanged += (_, e) => _rowNumberHost.Clip = new RectangleGeometry { Rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height) };

        Content = _root;
        GotFocus += (_, e) =>
        {
            if (ReferenceEquals(e.OriginalSource, this))
            {
                _automation?.FocusEntered();
            }
        };
        KeyDown += OnKeyDown;
        CharacterReceived += OnCharacterReceived;
        ActualThemeChanged += (_, _) => ApplyTheme();
        Loaded += (_, _) => ApplyTheme();
        _brushes = default;
    }

    public event EventHandler? SelectionChanged;

    public event EventHandler<SortRequestedEventArgs>? SortRequested;

    public event EventHandler<GridCellEventArgs>? CellContextRequested;

    /// <summary>Delete or Backspace on a selection; the host decides what deleting means.</summary>
    public event EventHandler? DeleteRequested;

    /// <summary>A double click on a cell the grid cannot edit, such as a long value in a read-only result.</summary>
    public event EventHandler<GridCellEventArgs>? CellActivated;

    public event EventHandler<string>? EditRejected;

    public IGridSource? Source
    {
        get => _source;
        set
        {
            if (ReferenceEquals(_source, value))
            {
                return;
            }

            CancelEdit();
            if (_source is not null)
            {
                _source.Changed -= OnSourceChanged;
            }

            var sameShape = _source is not null && value is not null && SameColumns(_source.Columns, value.Columns);
            _source = value;
            if (_source is not null)
            {
                _source.Changed += OnSourceChanged;
            }

            if (!sameShape)
            {
                _anchorRow = _anchorColumn = _activeRow = _activeColumn = -1;
                _wholeRows = false;
                ComputeColumnWidths();
                BuildHeaders();
                _scroller.ChangeView(0, 0, null, disableAnimation: true);
            }
            else
            {
                ClampSelection();
            }

            UpdateExtent();
            UpdateViewport(force: true);
            _automation?.Invalidate();
            SelectionChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>The columns the server sorts by, drawn as glyphs on the headers.</summary>
    public IReadOnlyList<(int Column, bool Descending)> SortColumns
    {
        get => _sort;
        set
        {
            _sort = value;
            for (var i = 0; i < _headers.Count; i++)
            {
                var index = i;
                _headers[i].SetSort(_sort.Where(s => s.Column == index).Select(s => (bool?)s.Descending).FirstOrDefault());
            }
        }
    }

    public GridCell? ActiveCell => _activeRow >= 0 && _activeColumn >= 0 ? new GridCell(_activeRow, _activeColumn) : null;

    public bool HasSelection => _activeRow >= 0;

    /// <summary>The selected rectangle as inclusive row and column bounds.</summary>
    public (int FirstRow, int LastRow, int FirstColumn, int LastColumn) SelectionBounds
    {
        get
        {
            if (_activeRow < 0 || _source is null)
            {
                return (0, -1, 0, -1);
            }

            var firstColumn = _wholeRows ? 0 : Math.Min(_anchorColumn, _activeColumn);
            var lastColumn = _wholeRows ? _source.Columns.Count - 1 : Math.Max(_anchorColumn, _activeColumn);
            return (Math.Min(_anchorRow, _activeRow), Math.Max(_anchorRow, _activeRow), firstColumn, lastColumn);
        }
    }

    public IReadOnlyList<int> SelectedRows
    {
        get
        {
            var (first, last, _, _) = SelectionBounds;
            return last < first ? [] : Enumerable.Range(first, last - first + 1).ToArray();
        }
    }

    public void SelectCell(int row, int column, bool extend = false)
    {
        if (_source is null || _source.RowCount == 0 || _source.Columns.Count == 0)
        {
            return;
        }

        row = Math.Clamp(row, 0, _source.RowCount - 1);
        column = Math.Clamp(column, 0, _source.Columns.Count - 1);
        if (!extend || _anchorRow < 0)
        {
            _anchorRow = row;
            _anchorColumn = column;
            _wholeRows = false;
        }

        _activeRow = row;
        _activeColumn = column;
        UpdateSelectionVisuals();
        ScrollIntoView(row, column);
        _automation?.ActiveCellMoved(extend);
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SelectAll()
    {
        if (_source is null || _source.RowCount == 0)
        {
            return;
        }

        _anchorRow = 0;
        _activeRow = _source.RowCount - 1;
        _anchorColumn = 0;
        _activeColumn = _source.Columns.Count - 1;
        _wholeRows = true;
        UpdateSelectionVisuals();
        _automation?.ActiveCellMoved(extended: true);
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    public void ScrollIntoView(int row, int column)
    {
        if (_source is null || row < 0)
        {
            return;
        }

        var top = row * _rowHeight;
        var bottom = top + _rowHeight;
        var v = _scroller.VerticalOffset;
        var viewportHeight = _scroller.ViewportHeight;
        double? targetV = top < v ? top : bottom > v + viewportHeight ? bottom - viewportHeight : null;

        double? targetH = null;
        if (column >= 0 && column < _widths.Length)
        {
            var left = _offsets[column];
            var right = left + _widths[column];
            var h = _scroller.HorizontalOffset;
            var viewportWidth = _scroller.ViewportWidth;
            targetH = left < h ? left : right > h + viewportWidth ? Math.Min(left, right - viewportWidth) : null;
        }

        if (targetV is not null || targetH is not null)
        {
            _scroller.ChangeView(targetH ?? _scroller.HorizontalOffset, targetV ?? _scroller.VerticalOffset, null, disableAnimation: true);
        }
    }

    /// <summary>The selection as tab-separated text, the format spreadsheets paste.</summary>
    public string GetSelectionText(bool includeHeaders)
    {
        if (_source is null)
        {
            return string.Empty;
        }

        var (firstRow, lastRow, firstColumn, lastColumn) = SelectionBounds;
        var sb = new StringBuilder();
        if (includeHeaders)
        {
            for (var c = firstColumn; c <= lastColumn; c++)
            {
                sb.Append(_source.Columns[c].Name).Append(c < lastColumn ? '\t' : '\n');
            }
        }

        for (var r = firstRow; r <= lastRow; r++)
        {
            for (var c = firstColumn; c <= lastColumn; c++)
            {
                var value = _source.GetValue(r, c);
                sb.Append(value is null ? string.Empty : CellFormatter.Format(value));
                if (c < lastColumn)
                {
                    sb.Append('\t');
                }
            }

            if (r < lastRow)
            {
                sb.Append('\n');
            }
        }

        return sb.ToString();
    }

    public void CopySelection(bool includeHeaders = false)
    {
        var package = new DataPackage();
        package.SetText(GetSelectionText(includeHeaders));
        Clipboard.SetContent(package);
    }

    public void BeginEdit(string? initialText = null)
    {
        if (_source is not { IsEditable: true } || _activeRow < 0 || _activeColumn < 0)
        {
            return;
        }

        if (_source.GetRowState(_activeRow) == RowEditState.Deleted)
        {
            return;
        }

        ScrollIntoView(_activeRow, _activeColumn);
        _editRow = _activeRow;
        _editColumn = _activeColumn;
        var value = _source.GetValue(_editRow, _editColumn);
        _editor.Text = initialText ?? (value is null ? string.Empty : CellFormatter.Format(value));
        _editor.Width = _widths[_editColumn];
        _editor.Height = _rowHeight;
        Canvas.SetLeft(_editor, _offsets[_editColumn]);
        Canvas.SetTop(_editor, _editRow * _rowHeight);
        _editor.Visibility = Visibility.Visible;
        _editor.Focus(FocusState.Programmatic);
        _editor.SelectionStart = _editor.Text.Length;
        if (initialText is null)
        {
            _editor.SelectAll();
        }
    }

    public void SetActiveCellNull()
    {
        if (_source is { IsEditable: true } && _activeRow >= 0)
        {
            var (firstRow, lastRow, firstColumn, lastColumn) = SelectionBounds;
            for (var r = firstRow; r <= lastRow; r++)
            {
                for (var c = firstColumn; c <= lastColumn; c++)
                {
                    _source.TrySetValue(r, c, null, out _);
                }
            }
        }
    }

    public void Refresh() => UpdateViewport(force: true);

    internal IReadOnlyList<HeaderCell> HeaderElements => _headers;

    internal ScrollViewer Scroller => _scroller;

    internal TextBox EditorElement => _editor;

    /// <summary>The cells inside the viewport, without the overscan rows realized around it.</summary>
    internal (int FirstRow, int LastRow, int FirstColumn, int LastColumn) VisibleCellRange()
    {
        if (_source is null || _source.RowCount == 0 || _widths.Length == 0)
        {
            return (0, -1, 0, -1);
        }

        var top = _scroller.VerticalOffset;
        var height = _scroller.ViewportHeight > 0 ? _scroller.ViewportHeight : ActualHeight;
        var firstRow = Math.Clamp((int)(top / _rowHeight), 0, _source.RowCount - 1);
        var lastRow = Math.Clamp((int)Math.Ceiling((top + height) / _rowHeight) - 1, firstRow, _source.RowCount - 1);

        var left = _scroller.HorizontalOffset;
        var width = _scroller.ViewportWidth > 0 ? _scroller.ViewportWidth : ActualWidth;
        var found = Array.BinarySearch(_offsets, left);
        var firstColumn = Math.Clamp(found >= 0 ? found : ~found - 1, 0, _widths.Length - 1);
        var lastColumn = firstColumn;
        while (lastColumn < _widths.Length - 1 && _offsets[lastColumn + 1] < left + width)
        {
            lastColumn++;
        }

        return (firstRow, lastRow, firstColumn, lastColumn);
    }

    internal bool IsCellVisible(int row, int column)
    {
        var (firstRow, lastRow, firstColumn, lastColumn) = VisibleCellRange();
        return row >= firstRow && row <= lastRow && column >= firstColumn && column <= lastColumn;
    }

    internal string ColumnName(int column) => _source is { } source && column < source.Columns.Count ? source.Columns[column].Name : string.Empty;

    internal string ColumnType(int column) => _source is { } source && column < source.Columns.Count ? source.Columns[column].DataType : string.Empty;

    /// <summary>The cell's text as a screen reader should say it: the whole value, not the shortened one drawn.</summary>
    internal string CellText(int row, int column)
    {
        if (_source is not { } source || row >= source.RowCount || column >= source.Columns.Count)
        {
            return string.Empty;
        }

        var value = source.GetValue(row, column);
        return value is null ? CellFormatter.NullText : CellFormatter.Format(value) is { Length: > 0 } text ? text : Strings.Get("Grid/CellEmpty");
    }

    /// <summary>What the cell's color and decoration say to a sighted user: changed, a new or deleted row, NULL.</summary>
    internal string CellStatus(int row, int column)
    {
        if (_source is not { } source || row >= source.RowCount || column >= source.Columns.Count)
        {
            return string.Empty;
        }

        var parts = new List<string>(3);
        switch (source.GetRowState(row))
        {
            case RowEditState.Inserted:
                parts.Add(Strings.Get("Grid/StatusNewRow"));
                break;
            case RowEditState.Deleted:
                parts.Add(Strings.Get("Grid/StatusDeletedRow"));
                break;
        }

        if (source.IsCellModified(row, column))
        {
            parts.Add(Strings.Get("Grid/StatusModified"));
        }

        if (source.GetValue(row, column) is null)
        {
            parts.Add(Strings.Get("Grid/StatusNull"));
        }

        return string.Join(", ", parts);
    }

    /// <summary>
    /// The cell's rectangle as UI Automation wants it from a peer with no element of its own: relative to the window's
    /// client area in physical pixels, cut to the viewport, empty when scrolled away. The framework adds the window's
    /// screen position but does not scale, so the layout rectangle is scaled here.
    /// </summary>
    internal Rect CellBoundsForAutomation(int row, int column)
    {
        if (_source is null || column < 0 || column >= _widths.Length || row < 0 || row >= _source.RowCount || XamlRoot is null)
        {
            return Rect.Empty;
        }

        try
        {
            var cell = _canvas.TransformToVisual(null).TransformBounds(new Rect(_offsets[column], row * _rowHeight, _widths[column], _rowHeight));
            var viewport = _scroller.TransformToVisual(null).TransformBounds(new Rect(0, 0, _scroller.ViewportWidth, _scroller.ViewportHeight));
            var left = Math.Max(cell.Left, viewport.Left);
            var top = Math.Max(cell.Top, viewport.Top);
            var right = Math.Min(cell.Right, viewport.Right);
            var bottom = Math.Min(cell.Bottom, viewport.Bottom);
            var scale = XamlRoot.RasterizationScale;
            return right > left && bottom > top ? new Rect(left * scale, top * scale, (right - left) * scale, (bottom - top) * scale) : Rect.Empty;
        }
        catch (ArgumentException)
        {
            // The grid left the visual tree between the client's question and this answer.
            return Rect.Empty;
        }
    }

    /// <summary>The cell under a point given as <see cref="CellBoundsForAutomation"/> gives rectangles, or null outside the cells.</summary>
    internal GridCell? CellAt(Point automationPoint)
    {
        if (_source is null || XamlRoot is null)
        {
            return null;
        }

        try
        {
            var scale = XamlRoot.RasterizationScale;
            var windowPoint = new Point(automationPoint.X / scale, automationPoint.Y / scale);
            var point = TransformToVisual(null).Inverse.TransformPoint(windowPoint);
            var viewport = _scroller.TransformToVisual(this).TransformBounds(new Rect(0, 0, _scroller.ViewportWidth, _scroller.ViewportHeight));
            if (!viewport.Contains(point))
            {
                return null;
            }

            var (row, column) = HitTest(_canvas.TransformToVisual(null).Inverse.TransformPoint(windowPoint));
            return row < 0 ? null : new GridCell(row, column);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    protected override AutomationPeer OnCreateAutomationPeer() => _automation = new DataGridAutomationPeer(this);

    private static bool SameColumns(IReadOnlyList<ResultColumn> a, IReadOnlyList<ResultColumn> b)
    {
        if (a.Count != b.Count)
        {
            return false;
        }

        for (var i = 0; i < a.Count; i++)
        {
            if (!string.Equals(a[i].Name, b[i].Name, StringComparison.Ordinal))
            {
                return false;
            }
        }

        return true;
    }

    private void OnSourceChanged(object? sender, EventArgs e)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            ClampSelection();
            UpdateExtent();
            UpdateViewport(force: true);
            UpdateSelectionVisuals();
            _automation?.Invalidate();
        });
    }

    private void ClampSelection()
    {
        if (_source is null || _source.RowCount == 0)
        {
            _anchorRow = _activeRow = -1;
            return;
        }

        _anchorRow = Math.Min(_anchorRow, _source.RowCount - 1);
        _activeRow = Math.Min(_activeRow, _source.RowCount - 1);
    }

    private void ApplyTheme()
    {
        _brushes = new Brushes(
            Text: ThemeResources.Brush(this, "TextFillColorPrimaryBrush"),
            Muted: ThemeResources.Brush(this, "TextFillColorTertiaryBrush"),
            Secondary: ThemeResources.Brush(this, "TextFillColorSecondaryBrush"),
            Modified: ThemeResources.Brush(this, "GridModifiedCellBrush"),
            Alternate: ThemeResources.Brush(this, "GridAlternateRowBrush"),
            Line: ThemeResources.Brush(this, "GridLineBrush"),
            Selection: ThemeResources.Brush(this, "GridSelectionBrush"),
            Accent: ThemeResources.Brush(this, "AccentFillColorDefaultBrush"),
            Inserted: ThemeResources.Brush(this, "GridInsertedRowBrush"),
            Deleted: ThemeResources.Brush(this, "GridDeletedRowBrush"),
            HeaderBackground: ThemeResources.Brush(this, "LayerOnMicaBaseAltFillColorDefaultBrush"),
            Stroke: ThemeResources.Brush(this, "CardStrokeColorDefaultBrush"));

        _headerHost.Background = _brushes.HeaderBackground;
        _headerHost.BorderBrush = _brushes.Stroke;
        _corner.Background = _brushes.HeaderBackground;
        _corner.BorderBrush = _brushes.Stroke;
        _rowNumberHost.Background = _brushes.HeaderBackground;
        _rowNumberHost.BorderBrush = _brushes.Stroke;
        _selectionRect.Fill = _brushes.Selection;
        _rowNumberSelection.Fill = _brushes.Selection;
        _focusRect.Stroke = _brushes.Accent;
        _editor.BorderBrush = _brushes.Accent;
        foreach (var line in _columnLines)
        {
            line.Fill = _brushes.Line;
        }

        foreach (var header in _headers)
        {
            header.ApplyTheme(_brushes.Text, _brushes.Secondary);
        }

        foreach (var number in _rowNumbers.Values)
        {
            number.Foreground = _brushes.Muted;
        }

        if (Resources.TryGetValue("GridRowHeight", out var height) && height is double h)
        {
            _rowHeight = h;
        }
        else if (Application.Current.Resources.TryGetValue("GridRowHeight", out var appHeight) && appHeight is double ah)
        {
            _rowHeight = ah;
        }

        UpdateViewport(force: true);
    }

    private void ComputeColumnWidths()
    {
        if (_source is null)
        {
            _widths = [];
            _offsets = [0];
            return;
        }

        var columns = _source.Columns;
        var sample = Math.Min(_source.RowCount, 200);
        _widths = new double[columns.Count];
        for (var c = 0; c < columns.Count; c++)
        {
            var longest = columns[c].Name.Length + 3;
            for (var r = 0; r < sample; r++)
            {
                var value = _source.GetValue(r, c);
                var length = value switch
                {
                    null => 4,
                    string s => Math.Min(s.Length, 60),
                    _ => Math.Min(CellFormatter.FormatForCell(value).Length, 60),
                };
                if (length > longest)
                {
                    longest = length;
                }
            }

            // An average Segoe UI glyph at 13px is about 7 px wide; exact measuring would cost a layout per sample.
            _widths[c] = Math.Clamp((longest * 7.2) + (CellPadding * 2), 64, 420);
        }

        RecomputeOffsets();
        var digits = Math.Max(2, _source.RowCount.ToString(System.Globalization.CultureInfo.InvariantCulture).Length);
        _rowNumberWidth = Math.Max(40, (digits * 8) + 20);
        _rowNumberHost.Width = _rowNumberWidth;
        _corner.Width = _rowNumberWidth;
    }

    private void RecomputeOffsets()
    {
        _offsets = new double[_widths.Length + 1];
        for (var i = 0; i < _widths.Length; i++)
        {
            _offsets[i + 1] = _offsets[i] + _widths[i];
        }
    }

    private void BuildHeaders()
    {
        _headerCanvas.Children.Clear();
        _headers.Clear();
        foreach (var line in _columnLines)
        {
            _canvas.Children.Remove(line);
        }

        _columnLines.Clear();
        if (_source is null)
        {
            return;
        }

        for (var c = 0; c < _source.Columns.Count; c++)
        {
            var column = _source.Columns[c];
            var header = new HeaderCell(c, column.Name, $"{column.Name}  ·  {column.DataType}", column.IsNumeric);
            header.Clicked += (_, args) => SortRequested?.Invoke(this, args);
            header.Resized += OnHeaderResized;
            header.AutoFitRequested += (_, index) => AutoFit(index);
            if (_brushes.Text is not null)
            {
                header.ApplyTheme(_brushes.Text, _brushes.Secondary);
            }

            _headers.Add(header);
            _headerCanvas.Children.Add(header);

            var line = new Rectangle { Width = 1, IsHitTestVisible = false, Fill = _brushes.Line };
            Canvas.SetZIndex(line, 1);
            _columnLines.Add(line);
            _canvas.Children.Add(line);
        }

        LayoutHeaders();
        SortColumns = _sort.Where(s => s.Column < _headers.Count).ToArray();
    }

    private void LayoutHeaders()
    {
        for (var c = 0; c < _headers.Count; c++)
        {
            _headers[c].Width = _widths[c];
            _headers[c].Height = HeaderHeight;
            Canvas.SetLeft(_headers[c], _offsets[c]);
            Canvas.SetLeft(_columnLines[c], _offsets[c + 1] - 1);
        }

        _headerCanvas.Width = _offsets[^1];
    }

    private void OnHeaderResized(object? sender, (int Column, double Width) e)
    {
        _widths[e.Column] = Math.Max(40, e.Width);
        RecomputeOffsets();
        LayoutHeaders();
        UpdateExtent();
        foreach (var presenter in _realized.Values)
        {
            presenter.SetColumnRange(-1, -2);
        }

        UpdateViewport(force: true);
        UpdateSelectionVisuals();
    }

    private void AutoFit(int column)
    {
        if (_source is null)
        {
            return;
        }

        var longest = _source.Columns[column].Name.Length + 3;
        var (first, last) = VisibleRows();
        for (var r = first; r <= last; r++)
        {
            longest = Math.Max(longest, CellFormatter.FormatForCell(_source.GetValue(r, column)).Length);
        }

        OnHeaderResized(this, (column, Math.Clamp((longest * 7.2) + (CellPadding * 2), 48, 900)));
    }

    private void UpdateExtent()
    {
        var rows = _source?.RowCount ?? 0;
        _canvas.Width = Math.Max(_offsets[^1], 1);
        _canvas.Height = Math.Max(rows * _rowHeight, 1);
        foreach (var line in _columnLines)
        {
            line.Height = _canvas.Height;
        }
    }

    private (int First, int Last) VisibleRows()
    {
        if (_source is null || _source.RowCount == 0)
        {
            return (0, -1);
        }

        var first = Math.Max(0, (int)(_scroller.VerticalOffset / _rowHeight) - Overscan);
        var visible = (int)Math.Ceiling((_scroller.ViewportHeight > 0 ? _scroller.ViewportHeight : ActualHeight) / _rowHeight);
        var last = Math.Min(_source.RowCount - 1, first + visible + (Overscan * 2));
        return (first, last);
    }

    private (int First, int Last) VisibleColumns()
    {
        if (_widths.Length == 0)
        {
            return (0, -1);
        }

        var left = _scroller.HorizontalOffset;
        var right = left + (_scroller.ViewportWidth > 0 ? _scroller.ViewportWidth : ActualWidth);
        var found = Array.BinarySearch(_offsets, left);
        var first = Math.Max(0, found >= 0 ? found : ~found - 1);
        var last = first;
        while (last < _widths.Length - 1 && _offsets[last + 1] < right)
        {
            last++;
        }

        return (Math.Max(0, first - 1), Math.Min(_widths.Length - 1, last + 1));
    }

    private void UpdateViewport(bool force)
    {
        _headerShift.X = -_scroller.HorizontalOffset;
        _rowNumberShift.Y = -_scroller.VerticalOffset;
        if (_brushes.Text is null)
        {
            return;
        }

        var (firstRow, lastRow) = VisibleRows();
        var (firstColumn, lastColumn) = VisibleColumns();

        List<int>? stale = null;
        foreach (var row in _realized.Keys)
        {
            if (_source is null || row < firstRow || row > lastRow)
            {
                (stale ??= []).Add(row);
            }
        }

        if (stale is not null)
        {
            foreach (var row in stale)
            {
                var presenter = _realized[row];
                _realized.Remove(row);
                presenter.Visibility = Visibility.Collapsed;
                presenter.Row = -1;
                _pool.Push(presenter);
            }
        }

        if (force)
        {
            // An empty column range makes the loop below rebind every kept row with fresh values.
            foreach (var presenter in _realized.Values)
            {
                presenter.SetColumnRange(-1, -2);
            }
        }

        for (var row = firstRow; row <= lastRow; row++)
        {
            if (_realized.TryGetValue(row, out var presenter))
            {
                if (presenter.FirstColumn != firstColumn || presenter.LastColumn != lastColumn)
                {
                    BindRow(presenter, row, firstColumn, lastColumn);
                }

                continue;
            }

            presenter = _pool.Count > 0 ? _pool.Pop() : CreatePresenter();
            presenter.Visibility = Visibility.Visible;
            _realized[row] = presenter;
            BindRow(presenter, row, firstColumn, lastColumn);
        }

        UpdateRowNumbers(firstRow, lastRow);
        _automation?.Prune();
    }

    private GridRowPresenter CreatePresenter()
    {
        var presenter = new GridRowPresenter();
        Canvas.SetZIndex(presenter, 1);
        _canvas.Children.Add(presenter);
        return presenter;
    }

    private void BindRow(GridRowPresenter presenter, int row, int firstColumn, int lastColumn)
    {
        if (_source is null)
        {
            return;
        }

        presenter.Row = row;
        Canvas.SetTop(presenter, row * _rowHeight);
        presenter.Layout(_offsets[^1], _rowHeight, _brushes.Line);
        var state = _source.GetRowState(row);
        presenter.SetBackground(state switch
        {
            RowEditState.Inserted => _brushes.Inserted,
            RowEditState.Deleted => _brushes.Deleted,
            _ => row % 2 == 1 ? _brushes.Alternate : null,
        });

        presenter.SetColumnRange(firstColumn, lastColumn);
        var top = (_rowHeight - 19) / 2;
        var deleted = state == RowEditState.Deleted;
        for (var c = firstColumn; c <= lastColumn; c++)
        {
            var value = _source.GetValue(row, c);
            var isNull = value is null;
            var modified = _source.IsCellModified(row, c);
            var numeric = _source.Columns[c].IsNumeric;
            presenter.Slot(c).Update(
                isNull ? CellFormatter.NullText : CellFormatter.FormatForCell(value),
                _offsets[c] + CellPadding,
                _widths[c] - (CellPadding * 2),
                top,
                modified ? _brushes.Modified : isNull ? _brushes.Muted : _brushes.Text,
                isNull,
                deleted,
                numeric ? TextAlignment.Right : TextAlignment.Left);
        }
    }

    private void UpdateRowNumbers(int firstRow, int lastRow)
    {
        var stale = _rowNumbers.Keys.Where(r => r < firstRow || r > lastRow).ToArray();
        foreach (var row in stale)
        {
            var block = _rowNumbers[row];
            _rowNumbers.Remove(row);
            block.Visibility = Visibility.Collapsed;
            _rowNumberPool.Push(block);
        }

        for (var row = firstRow; row <= lastRow; row++)
        {
            if (_rowNumbers.TryGetValue(row, out var existing))
            {
                Canvas.SetTop(existing, (row * _rowHeight) + ((_rowHeight - 17) / 2));
                continue;
            }

            var block = _rowNumberPool.Count > 0 ? _rowNumberPool.Pop() : CreateRowNumber();
            block.Visibility = Visibility.Visible;
            block.Width = _rowNumberWidth - 12;
            block.Text = (row + 1).ToString(System.Globalization.CultureInfo.InvariantCulture);
            Canvas.SetTop(block, (row * _rowHeight) + ((_rowHeight - 17) / 2));
            _rowNumbers[row] = block;
        }
    }

    private TextBlock CreateRowNumber()
    {
        var block = new TextBlock
        {
            FontSize = 11,
            TextAlignment = TextAlignment.Right,
            Foreground = _brushes.Muted,
            IsHitTestVisible = false,
            IsTextScaleFactorEnabled = false,
        };
        Canvas.SetLeft(block, 4);
        _rowNumberCanvas.Children.Add(block);
        return block;
    }

    private void UpdateSelectionVisuals()
    {
        if (_source is null || _activeRow < 0 || _widths.Length == 0)
        {
            _selectionRect.Visibility = Visibility.Collapsed;
            _focusRect.Visibility = Visibility.Collapsed;
            _rowNumberSelection.Visibility = Visibility.Collapsed;
            return;
        }

        var (firstRow, lastRow, firstColumn, lastColumn) = SelectionBounds;
        var single = firstRow == lastRow && firstColumn == lastColumn;
        _selectionRect.Visibility = single ? Visibility.Collapsed : Visibility.Visible;
        Canvas.SetLeft(_selectionRect, _offsets[firstColumn]);
        Canvas.SetTop(_selectionRect, firstRow * _rowHeight);
        _selectionRect.Width = _offsets[lastColumn + 1] - _offsets[firstColumn];
        _selectionRect.Height = (lastRow - firstRow + 1) * _rowHeight;

        _focusRect.Visibility = Visibility.Visible;
        Canvas.SetLeft(_focusRect, _offsets[_activeColumn]);
        Canvas.SetTop(_focusRect, _activeRow * _rowHeight);
        _focusRect.Width = _widths[_activeColumn];
        _focusRect.Height = _rowHeight;

        _rowNumberSelection.Visibility = Visibility.Visible;
        _rowNumberSelection.Width = _rowNumberWidth;
        Canvas.SetTop(_rowNumberSelection, firstRow * _rowHeight);
        _rowNumberSelection.Height = (lastRow - firstRow + 1) * _rowHeight;
    }

    private (int Row, int Column) HitTest(Point point)
    {
        if (_source is null || _source.RowCount == 0 || _widths.Length == 0)
        {
            return (-1, -1);
        }

        var row = Math.Clamp((int)(point.Y / _rowHeight), 0, _source.RowCount - 1);
        var index = Array.BinarySearch(_offsets, point.X);
        var column = index >= 0 ? index : ~index - 1;
        return (row, Math.Clamp(column, 0, _widths.Length - 1));
    }

    private void OnCanvasPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(_canvas);
        if (!point.Properties.IsLeftButtonPressed)
        {
            return;
        }

        CommitEdit(move: null);
        Focus(FocusState.Pointer);
        var (row, column) = HitTest(point.Position);
        if (row < 0)
        {
            return;
        }

        var shift = (e.KeyModifiers & VirtualKeyModifiers.Shift) != 0;
        SelectCell(row, column, extend: shift);
        _dragging = true;
        _canvas.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnCanvasPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging)
        {
            return;
        }

        var (row, column) = HitTest(e.GetCurrentPoint(_canvas).Position);
        if (row >= 0 && (row != _activeRow || column != _activeColumn))
        {
            SelectCell(row, column, extend: true);
        }
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        _dragging = false;
        _draggingRows = false;
        ((UIElement)sender).ReleasePointerCapture(e.Pointer);
    }

    private void OnRowNumberPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_source is null || _source.RowCount == 0)
        {
            return;
        }

        CommitEdit(move: null);
        Focus(FocusState.Pointer);
        var y = e.GetCurrentPoint(_rowNumberHost).Position.Y + _scroller.VerticalOffset;
        var row = Math.Clamp((int)(y / _rowHeight), 0, _source.RowCount - 1);
        SelectRows(row, extend: (e.KeyModifiers & VirtualKeyModifiers.Shift) != 0);
        _draggingRows = true;
        _rowNumberHost.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnRowNumberPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_draggingRows || _source is null)
        {
            return;
        }

        var y = e.GetCurrentPoint(_rowNumberHost).Position.Y + _scroller.VerticalOffset;
        SelectRows(Math.Clamp((int)(y / _rowHeight), 0, _source.RowCount - 1), extend: true);
    }

    private void SelectRows(int row, bool extend)
    {
        if (_source is null)
        {
            return;
        }

        if (!extend || _anchorRow < 0)
        {
            _anchorRow = row;
        }

        _activeRow = row;
        _anchorColumn = 0;
        _activeColumn = Math.Max(0, _activeColumn);
        _wholeRows = true;
        UpdateSelectionVisuals();
        ScrollIntoView(row, -1);
        _automation?.ActiveCellMoved(extended: true);
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnCanvasDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        var (row, column) = HitTest(e.GetPosition(_canvas));
        if (row < 0)
        {
            return;
        }

        SelectCell(row, column);
        if (_source?.IsEditable == true)
        {
            BeginEdit();
        }
        else
        {
            CellActivated?.Invoke(this, new GridCellEventArgs(row, column, _canvas, e.GetPosition(_canvas)));
        }
    }

    private void OnCanvasRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var position = e.GetPosition(_canvas);
        var (row, column) = HitTest(position);
        if (row < 0)
        {
            return;
        }

        var (firstRow, lastRow, firstColumn, lastColumn) = SelectionBounds;
        if (row < firstRow || row > lastRow || column < firstColumn || column > lastColumn)
        {
            SelectCell(row, column);
        }

        CellContextRequested?.Invoke(this, new GridCellEventArgs(row, column, _canvas, position));
        e.Handled = true;
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_source is null || _editor.Visibility == Visibility.Visible)
        {
            return;
        }

        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var row = Math.Max(_activeRow, 0);
        var column = Math.Max(_activeColumn, 0);
        var page = Math.Max(1, (int)(_scroller.ViewportHeight / _rowHeight) - 1);
        var handled = true;
        switch (e.Key)
        {
            case VirtualKey.Up:
                SelectCell(ctrl ? 0 : row - 1, column, shift);
                break;
            case VirtualKey.Down:
                SelectCell(ctrl ? _source.RowCount - 1 : row + 1, column, shift);
                break;
            case VirtualKey.Left:
                SelectCell(row, ctrl ? 0 : column - 1, shift);
                break;
            case VirtualKey.Right:
                SelectCell(row, ctrl ? _source.Columns.Count - 1 : column + 1, shift);
                break;
            case VirtualKey.PageUp:
                SelectCell(row - page, column, shift);
                break;
            case VirtualKey.PageDown:
                SelectCell(row + page, column, shift);
                break;
            case VirtualKey.Home:
                SelectCell(ctrl ? 0 : row, 0, shift);
                break;
            case VirtualKey.End:
                SelectCell(ctrl ? _source.RowCount - 1 : row, _source.Columns.Count - 1, shift);
                break;
            case VirtualKey.Tab:
                SelectCell(row, shift ? column - 1 : column + 1);
                break;
            case VirtualKey.A when ctrl:
                SelectAll();
                break;
            case VirtualKey.C when ctrl:
                CopySelection(includeHeaders: shift);
                break;
            case VirtualKey.Enter or VirtualKey.F2:
                if (_source.IsEditable)
                {
                    BeginEdit();
                }
                else if (_activeRow >= 0)
                {
                    CellActivated?.Invoke(this, new GridCellEventArgs(_activeRow, _activeColumn, _canvas, default));
                }

                break;
            case VirtualKey.Delete or VirtualKey.Back:
                DeleteRequested?.Invoke(this, EventArgs.Empty);
                break;
            default:
                handled = false;
                break;
        }

        e.Handled = handled;
    }

    private void OnCharacterReceived(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        if (_editor.Visibility == Visibility.Visible || _source is not { IsEditable: true } || char.IsControl(e.Character))
        {
            return;
        }

        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (!ctrl)
        {
            BeginEdit(e.Character.ToString());
            e.Handled = true;
        }
    }

    private void OnEditorKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        switch (e.Key)
        {
            case VirtualKey.Enter:
                CommitEdit(move: (shift ? -1 : 1, 0));
                e.Handled = true;
                break;
            case VirtualKey.Tab:
                CommitEdit(move: (0, shift ? -1 : 1));
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                CancelEdit();
                Focus(FocusState.Programmatic);
                e.Handled = true;
                break;
        }
    }

    private void CommitEdit((int Rows, int Columns)? move)
    {
        if (_editRow < 0 || _source is null)
        {
            return;
        }

        var row = _editRow;
        var column = _editColumn;
        var text = _editor.Text;
        var current = _source.GetValue(row, column);
        var currentText = current is null ? string.Empty : CellFormatter.Format(current);
        _editRow = _editColumn = -1;
        _editor.Visibility = Visibility.Collapsed;

        if (!string.Equals(text, currentText, StringComparison.Ordinal))
        {
            if (_source.TrySetValue(row, column, text, out var error))
            {
                _automation?.ActiveValueChanged(currentText, text);
            }
            else
            {
                EditRejected?.Invoke(this, error ?? Strings.Get("Grid/ValueNotAccepted"));
            }
        }

        if (move is { } m)
        {
            SelectCell(row + m.Rows, column + m.Columns);
            Focus(FocusState.Programmatic);
        }
    }

    private void CancelEdit()
    {
        _editRow = _editColumn = -1;
        _editor.Visibility = Visibility.Collapsed;
    }

    private readonly record struct Brushes(
        Brush Text,
        Brush Muted,
        Brush Secondary,
        Brush Modified,
        Brush Alternate,
        Brush Line,
        Brush Selection,
        Brush Accent,
        Brush Inserted,
        Brush Deleted,
        Brush HeaderBackground,
        Brush Stroke);
}
