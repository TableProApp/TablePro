using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TablePro.DataGrid.Automation;
using TablePro.DataGrid.Model;
using TablePro.Graphics;
using Windows.Foundation;
using TerraFX.Interop.DirectX;
using TerraFX.Interop.Windows;
using Windows.UI.ViewManagement;
using static TerraFX.Interop.DirectX.DirectX;
using static TerraFX.Interop.DirectX.DWRITE_FACTORY_TYPE;

namespace TablePro.DataGrid;

// The design and its gate: windows/docs/decisions/0003-data-grid-control.md.
[System.Diagnostics.CodeAnalysis.SuppressMessage("Design", "CA1001",
    Justification = "The cache goes with the data: SetData replaces or drops it, and its cursor's handle frees itself.")]
public sealed partial class DataGridView : UserControl, IGridWindow
{
    private const double OriginStep = 4096;
    private const double BaseRowHeight = 32;
    private const float BaseFontSize = 14;

    [ThreadStatic]
    private static SurfaceDevice? s_device;

    private readonly ScrollViewer _scroller;
    private readonly PaneContent _content;
    private readonly RowWindow _window;
    private readonly ItemsRepeater _rows;
    private readonly PaneContent _frozenContent;
    private readonly RowWindow _frozenWindow;
    private readonly ItemsRepeater _frozenRows;
    private readonly ItemsRepeater _header;
    private readonly Canvas _corner;
    private readonly Rectangle _selectionBox;
    private readonly Rectangle _frozenSelectionBox;
    private readonly Border _focusBox;
    private readonly Border _frozenFocusBox;
    private readonly RowsLayout _rowsLayout;
    private readonly RowsLayout _frozenRowsLayout;
    private readonly HeaderLayout _headerLayout;
    private readonly ElementPool _rowPool;
    private readonly ElementPool _frozenRowPool;
    private readonly ElementPool _headerPool;
    private readonly List<HeaderCell> _cornerCells = [];
    private readonly GridSelection _selection = new();
    private readonly UISettings _settings = new();

    private IGridData? _data;
    private CellCache? _cache;
    private IndexList _items = new(0);
    private IndexList _columnItems = new(0);
    private string[] _names = [];
    private GridColumns _columns = new(0, 140);
    private GridSort _sort = GridSort.None;
    private CellPainter? _painter;
    private float _scale = 1;
    private double _textScale = 1;
    private double _rowHeight = BaseRowHeight;
    private double _viewX;
    private double _viewY;
    private double _originY;
    private double _insetLeft;
    private double _insetTop;
    private (int First, int Last) _rowWindow = (0, -1);
    private (int First, int Last) _columnWindow = (0, -1);
    private int _layoutVersion;
    private int _selectionVersion;
    private int _rowNumberDigits;
    private bool _redrawQueued;

    public DataGridView()
    {
        Brushes = new GridBrushes();
        _rowsLayout = new RowsLayout(this, frozen: false, Counters.Layout);
        _frozenRowsLayout = new RowsLayout(this, frozen: true, Counters.FrozenLayout);
        _headerLayout = new HeaderLayout(this);
        _rowPool = new ElementPool(() => new DrawnRow(this, frozen: false));
        _frozenRowPool = new ElementPool(() => new DrawnRow(this, frozen: true));
        _headerPool = new ElementPool(() => new HeaderCell(this));

        _rows = new ItemsRepeater { Layout = _rowsLayout, ItemTemplate = _rowPool, ItemsSource = _items };
        _frozenRows = new ItemsRepeater { Layout = _frozenRowsLayout, ItemTemplate = _frozenRowPool, ItemsSource = _items };
        _header = new ItemsRepeater
        {
            Layout = _headerLayout,
            ItemTemplate = _headerPool,
            ItemsSource = _columnItems,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        _selectionBox = new Rectangle { IsHitTestVisible = false, Visibility = Visibility.Collapsed, Fill = Brushes.Selection };
        _frozenSelectionBox = new Rectangle { IsHitTestVisible = false, Visibility = Visibility.Collapsed, Fill = Brushes.Selection };
        _focusBox = new Border
        {
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
            BorderThickness = new Thickness(2),
            BorderBrush = Brushes.Focus,
        };
        _frozenFocusBox = new Border
        {
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
            BorderThickness = new Thickness(2),
            BorderBrush = Brushes.Focus,
        };

        // Selection under the rows, focus over them, all in a window moved by the 4,096 px origin.
        _window = new RowWindow();
        _window.Children.Add(_selectionBox);
        _window.Children.Add(_rows);
        _window.Children.Add(_focusBox);
        // ScrollViewer's headers require left-aligned content.
        _content = new PaneContent(this, frozen: false)
        {
            Background = Brushes.Clear,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
        };
        _content.Children.Add(_window);

        _frozenWindow = new RowWindow();
        _frozenWindow.Children.Add(_frozenSelectionBox);
        _frozenWindow.Children.Add(_frozenRows);
        _frozenWindow.Children.Add(_frozenFocusBox);
        _frozenContent = new PaneContent(this, frozen: true)
        {
            Background = Brushes.Clear,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
        };
        _frozenContent.Children.Add(_frozenWindow);

        _corner = new Canvas { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };

        _scroller = new ScrollViewer
        {
            Content = _content,
            TopHeader = _header,
            LeftHeader = _frozenContent,
            TopLeftHeader = _corner,
            HorizontalScrollMode = ScrollMode.Enabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Visible,
            VerticalScrollMode = ScrollMode.Enabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Visible,
            ZoomMode = ZoomMode.Disabled,
            IsTabStop = false,
        };
        _scroller.ViewChanging += (_, e) => Follow(e.NextView.HorizontalOffset, e.NextView.VerticalOffset);
        _scroller.ViewChanged += (_, _) => Follow(_scroller.HorizontalOffset, _scroller.VerticalOffset);
        _scroller.SizeChanged += (_, _) => MeasureInsets();
        _header.SizeChanged += (_, _) => MeasureInsets();
        _frozenContent.SizeChanged += (_, _) => MeasureInsets();
        Content = _scroller;
        Background = Brushes.Background;

        IsTabStop = true;
        UseSystemFocusVisuals = false;
        AutomationProperties.SetName(this, "Results");
        GotFocus += (_, _) => UpdateFocusBox();
        LostFocus += (_, _) => UpdateFocusBox();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        ActualThemeChanged += (_, _) => RefreshTheme();
        InitializeInput();
    }

    // For the app's startup, so the first non-Latin cell finds its fallback fonts loaded even in the first grid.
    public static unsafe void WarmUpFonts()
    {
        IDWriteFactory* factory;
        if (DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, NativeCom.Iid<IDWriteFactory>(), (IUnknown**)&factory).FAILED)
        {
            return;
        }
        FontWarmupTask = FontWarmup.Start(factory, CellPainter.PickFamily(factory), BaseFontSize);
        factory->Release();
    }

    // Draws with WARP even when a GPU is there. Read when the first grid of a thread is made.
    public static bool PreferSoftwareRendering { get; set; }

    public IGridData? Data => _data;

    public int RowCount { get; private set; }

    public int ColumnCount => _columns.Count;

    public double DefaultColumnWidth { get; set; } = 140;

    public int FrozenColumnCount
    {
        get => _columns.FrozenCount;
        set
        {
            _columns.FrozenCount = value;
            ColumnsChanged();
        }
    }

    public GridSort Sort
    {
        get => _sort;
        set
        {
            _sort = value;
            RebindHeaders();
        }
    }

    public CellRange SelectionRange => _selection.Range(RowCount, ColumnCount);

    public SelectionKind SelectionKind => _selection.Kind;

    public int FocusedRow => _selection.FocusRow;

    public int FocusedColumn => _selection.FocusColumn;

    public double RowHeight => _rowHeight;

    public double HeaderHeight => _rowHeight;

    public static bool IsSoftwareRendering => s_device?.IsSoftware ?? false;

    public event EventHandler<GridSort>? SortRequested;

    public event EventHandler? FocusedCellChanged;

    internal GridColumns Columns => _columns;

    internal GridBrushes Brushes { get; }

    internal GridCounters Counters { get; } = new();

    internal CellPainter Painter => _painter ??= CreatePainter();

    internal float RenderScale => _scale;

    internal ScrollViewer Scroller => _scroller;

    internal ItemsRepeater RowsRepeater => _rows;

    internal ItemsRepeater FrozenRowsRepeater => _frozenRows;

    internal ItemsRepeater HeaderRepeater => _header;

    internal UIElement ScrollingPane => _content;

    internal UIElement FrozenPane => _frozenContent;

    internal Dictionary<int, UIElement> RealizedRows => _rowsLayout.Realized;

    internal Dictionary<int, UIElement> RealizedFrozenRows => _frozenRowsLayout.Realized;

    internal Dictionary<int, UIElement> RealizedHeaders => _headerLayout.Realized;

    // The background layout of every script for this grid's font, which the first non-Latin cell would pay for.
    internal static Task FontWarmupTask { get; private set; } = Task.CompletedTask;

    internal static double FontWarmupMilliseconds => FontWarmup.LastMilliseconds;

    internal int DuplicateRecycles => _rowPool.DuplicateRecycles + _frozenRowPool.DuplicateRecycles + _headerPool.DuplicateRecycles;

    internal int RowElementsCreated => _rowPool.Created + _frozenRowPool.Created;

    internal (double Left, double Top) Insets => (_insetLeft, _insetTop);

    internal double OriginYValue => _originY;

    public (int First, int Last) RowWindow => _rowWindow;

    public (int First, int Last) ColumnWindow => _columnWindow;

    public double OriginY => _originY;

    public double TotalHeight => RowCount * _rowHeight;

    // Fonts, colors, widths, the device or the data changed: every drawn row lays out again.
    internal int LayoutVersion => unchecked((_layoutVersion * 397) ^ Painter.Version);

    // Selected cells are drawn in other colors only in high contrast; the row numbers always mark selected rows.
    internal int InkVersion(bool frozen) => frozen || Painter.Colors.HighContrast ? _selectionVersion : 0;

    public double PaneWidth(bool frozen) => frozen ? _columns.FrozenWidth : _columns.ScrollWidth;

    public double ColumnX(int column) => _columns.PaneX(column);

    public double ColumnWidth(int column) => _columns.Width(column);

    void IGridWindow.PrepareRow(UIElement row, int index) => ((DrawnRow)row).SetRow(index);

    void IGridWindow.PrepareHeader(UIElement header, int column) =>
        ((HeaderCell)header).Bind(column, _names[column], column == _sort.Column ? _sort.Direction : SortDirection.None);

    // Shows data, or nothing for null. The grid opens its own reader on this thread and disposes it with the data.
    public void SetData(IGridData? data)
    {
        _cache?.Dispose();
        _cache = null;
        _data = data;
        if (data is not null)
        {
            _cache = new CellCache(data.OpenReader());
        }
        RowCount = data?.RowCount ?? 0;
        var columnCount = data?.ColumnCount ?? 0;
        _names = new string[columnCount];
        for (var column = 0; column < columnCount; column++)
        {
            _names[column] = data!.GetColumnName(column);
        }
        var frozen = _columns.FrozenCount;
        _columns = new GridColumns(columnCount, DefaultColumnWidth) { FrozenCount = frozen };
        _selection.Select(0, 0, extend: false);
        _sort = GridSort.None;
        _rowsLayout.Forget();
        _frozenRowsLayout.Forget();
        _headerLayout.Forget();
        _items = new IndexList(RowCount);
        _columnItems = new IndexList(columnCount);
        _rows.ItemsSource = _items;
        _frozenRows.ItemsSource = _items;
        _header.ItemsSource = _columnItems;
        _rowNumberDigits = 0;
        UpdateRowNumberWidth();
        ColumnsChanged();
        _scroller.ChangeView(0, 0, null, true);
        Follow(0, 0);
    }

    // The data's RowCount grew, as rows of a running query arrived.
    public void RowsChanged()
    {
        if (_data is null)
        {
            return;
        }
        var count = _data.RowCount;
        if (count == RowCount)
        {
            return;
        }
        RowCount = count;
        _cache?.RowsChanged();
        _items.Grow(count);
        UpdateRowNumberWidth();
        UpdateExtent();
        Follow(_viewX, _viewY);
    }

    internal CellText Cell(int row, int column) =>
        _cache is null ? new CellText([], CellState.Missing) : _cache.Get(row, column, CapFor(column));

    internal string CellName(int row, int column)
    {
        var cell = Cell(row, column);
        return cell.IsNull ? CellPainter.NullText : cell.Text.ToString();
    }

    internal void OnDeviceLost()
    {
        _layoutVersion++;
        QueueRedraw();
    }

    internal void SimulateDeviceLoss()
    {
        if (s_device is not null)
        {
            s_device.FailNextDraw = true;
        }
        _layoutVersion++;
        InvalidateRows();
    }

    internal static int DevicesLost => s_device?.DevicesLost ?? 0;

    // The text scale factor, as Windows' Make text bigger sets it; also how the tests try other sizes.
    internal void ApplyTextScale(double scale)
    {
        scale = Math.Clamp(scale, 1, 3);
        if (Math.Abs(scale - _textScale) < 0.001 && _painter is not null)
        {
            return;
        }
        _textScale = scale;
        _rowHeight = Math.Ceiling(BaseRowHeight * scale);
        _painter?.Configure((float)(BaseFontSize * scale), _painter.Colors);
        _rowNumberDigits = 0;
        UpdateRowNumberWidth();
        ColumnsChanged();
    }

    internal void ApplyRasterizationScale(double scale)
    {
        if (Math.Abs(scale - _scale) < 0.0001 || scale <= 0)
        {
            return;
        }
        _scale = (float)scale;
        _layoutVersion++;
        InvalidateRows();
    }

    internal IEnumerable<HeaderCell> HeaderCells()
    {
        foreach (var cell in _cornerCells)
        {
            yield return cell;
        }
        foreach (var (_, element) in _headerLayout.Realized)
        {
            yield return (HeaderCell)element;
        }
    }

    internal HeaderCell? HeaderCell(int column)
    {
        if (column < _columns.FrozenCount)
        {
            return column + 1 < _cornerCells.Count ? _cornerCells[column + 1] : null;
        }
        return _headerLayout.Realized.TryGetValue(column, out var element) ? (HeaderCell)element : null;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new DataGridAutomationPeer(this);

    private unsafe CellPainter CreatePainter()
    {
        s_device ??= new SurfaceDevice(ElementCompositionPreview.GetElementVisual(this).Compositor, PreferSoftwareRendering);
        _textScale = _settings.TextScaleFactor;
        _rowHeight = Math.Ceiling(BaseRowHeight * _textScale);
        var painter = new CellPainter(s_device, (float)(BaseFontSize * _textScale), GridColors.Resolve(ActualTheme));
        FontWarmupTask = FontWarmup.Start(s_device.DWrite, painter.FamilyName, BaseFontSize);
        Brushes.Apply(painter.Colors);
        return painter;
    }

    // Characters the core keeps per cell: enough to fill the column with the narrowest glyphs, a quarter em each.
    internal int CapFor(int column) =>
        Math.Max(256, (int)Math.Ceiling(_columns.Width(column) / (0.25 * Painter.FontSize)) + 4);

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _ = Painter;
        MeasureInsets();
        _settings.TextScaleFactorChanged += OnTextScaleChanged;
        _settings.ColorValuesChanged += OnColorsChanged;
        if (XamlRoot is not null)
        {
            XamlRoot.Changed += OnXamlRootChanged;
            ApplyRasterizationScale(XamlRoot.RasterizationScale);
        }
        ApplyTextScale(_settings.TextScaleFactor);
        RefreshTheme();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _settings.TextScaleFactorChanged -= OnTextScaleChanged;
        _settings.ColorValuesChanged -= OnColorsChanged;
        if (XamlRoot is not null)
        {
            XamlRoot.Changed -= OnXamlRootChanged;
        }
    }

    // UISettings calls back on its own thread; AccessibilitySettings.HighContrastChanged needs a CoreWindow (0x80070490).
    private void OnTextScaleChanged(UISettings sender, object args) =>
        DispatcherQueue.TryEnqueue(() => ApplyTextScale(_settings.TextScaleFactor));

    private void OnColorsChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(RefreshTheme);

    private void OnXamlRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) =>
        ApplyRasterizationScale(sender.RasterizationScale);

    internal void RefreshTheme()
    {
        var colors = GridColors.Resolve(ActualTheme);
        Painter.Configure(Painter.FontSize, colors);
        Brushes.Apply(colors);
        foreach (var header in HeaderCells())
        {
            header.ApplyBrushes();
        }
        _layoutVersion++;
        InvalidateRows();
    }

    private void ColumnsChanged()
    {
        _layoutVersion++;
        _content.Width = _columns.ScrollWidth;
        _frozenContent.Width = _columns.FrozenWidth;
        _corner.Width = _columns.FrozenWidth;
        _corner.Height = HeaderHeight;
        _header.Height = HeaderHeight;
        RebuildCorner();
        UpdateExtent();
        _columnWindow = (0, -1);
        Follow(_viewX, _viewY);
        UpdateSelectionBoxes();
        UpdateFocusBox();
        InvalidateRows();
    }

    private void UpdateExtent()
    {
        _content.Height = TotalHeight;
        _frozenContent.Height = TotalHeight;
    }

    private void RebuildCorner()
    {
        var needed = _columns.FrozenCount + 1;
        while (_cornerCells.Count < needed)
        {
            var cell = new HeaderCell(this);
            _cornerCells.Add(cell);
            _corner.Children.Add(cell);
        }
        while (_cornerCells.Count > needed)
        {
            var last = _cornerCells[^1];
            _cornerCells.RemoveAt(_cornerCells.Count - 1);
            _corner.Children.Remove(last);
        }
        _cornerCells[0].Bind(-1, "", SortDirection.None);
        _cornerCells[0].Width = _columns.RowHeaderWidth;
        _cornerCells[0].Height = HeaderHeight;
        for (var column = 0; column < _columns.FrozenCount; column++)
        {
            var cell = _cornerCells[column + 1];
            cell.Bind(column, _names[column], column == _sort.Column ? _sort.Direction : SortDirection.None);
            cell.Width = _columns.Width(column);
            cell.Height = HeaderHeight;
            Canvas.SetLeft(cell, _columns.PaneX(column));
        }
    }

    private void RebindHeaders()
    {
        RebuildCorner();
        foreach (var (column, element) in _headerLayout.Realized)
        {
            ((HeaderCell)element).Bind(column, _names[column], column == _sort.Column ? _sort.Direction : SortDirection.None);
        }
    }

    private void UpdateRowNumberWidth()
    {
        var digits = Math.Max(3, RowCount.ToString(System.Globalization.CultureInfo.InvariantCulture).Length);
        if (digits == _rowNumberDigits && _painter is not null)
        {
            return;
        }
        _rowNumberDigits = digits;
        Span<char> zeros = stackalloc char[digits];
        zeros.Fill('0');
        _columns.RowHeaderWidth = Math.Ceiling(Painter.Measure(zeros)) + (CellPainter.RowNumberPadding * 2) + 1;
        _layoutVersion++;
    }

    // Measured, because how ScrollViewer's headers share its viewport is not documented.
    private void MeasureInsets()
    {
        if (_content.XamlRoot is null)
        {
            return;
        }
        try
        {
            var origin = _content.TransformToVisual(_scroller).TransformPoint(new Point(_scroller.HorizontalOffset, _scroller.VerticalOffset));
            var headerBottom = _header.TransformToVisual(_scroller).TransformPoint(default).Y + _header.ActualHeight;
            var frozenRight = _frozenContent.TransformToVisual(_scroller).TransformPoint(default).X + _frozenContent.ActualWidth;
            _insetTop = Math.Max(Math.Max(0, origin.Y), headerBottom);
            _insetLeft = Math.Max(Math.Max(0, origin.X), frozenRight);
        }
        catch (ArgumentException)
        {
            return;
        }
        Follow(_viewX, _viewY);
    }

    // The content area in view, in content coordinates.
    internal Rect VisibleArea() => new(
        _viewX,
        _viewY,
        Math.Max(0, _scroller.ViewportWidth - _insetLeft),
        Math.Max(0, _scroller.ViewportHeight - _insetTop));

    internal void ScrollTo(double x, double y)
    {
        x = Math.Clamp(x, 0, Math.Max(0, _scroller.ScrollableWidth));
        y = Math.Clamp(y, 0, Math.Max(0, _scroller.ScrollableHeight));
        Follow(x, y);
        _scroller.ChangeView(x, y, null, true);
    }

    private void Follow(double x, double y)
    {
        _viewX = x;
        _viewY = y;
        var origin = Math.Floor(y / OriginStep) * OriginStep;
        var visible = VisibleArea();
        var originMoved = origin != _originY;
        if (originMoved)
        {
            _originY = origin;
            Canvas.SetTop(_window, origin);
            Canvas.SetTop(_frozenWindow, origin);
        }
        var columns = _columns.ScrollRange(x, visible.Width);
        if (columns != _columnWindow)
        {
            _columnWindow = columns;
            _header.InvalidateMeasure();
            foreach (var (_, row) in _rowsLayout.Realized)
            {
                ((DrawnRow)row).Invalidate();
            }
        }
        var rows = (0, -1);
        if (RowCount > 0 && visible.Height > 0)
        {
            var first = Math.Clamp((int)Math.Floor(y / _rowHeight), 0, RowCount - 1);
            var last = Math.Clamp((int)Math.Ceiling((y + visible.Height) / _rowHeight) - 1, first, RowCount - 1);
            rows = (first, last);
        }
        if (rows != _rowWindow || originMoved)
        {
            _rowWindow = rows;
            UpdateSelectionBoxes();
            UpdateFocusBox();
        }
        _rows.InvalidateMeasure();
        _frozenRows.InvalidateMeasure();
    }

    private void InvalidateRows()
    {
        foreach (var (_, row) in _rowsLayout.Realized)
        {
            ((DrawnRow)row).Invalidate();
        }
        foreach (var (_, row) in _frozenRowsLayout.Realized)
        {
            ((DrawnRow)row).Invalidate();
        }
        _rows.InvalidateMeasure();
        _frozenRows.InvalidateMeasure();
        _header.InvalidateMeasure();
    }

    // After a lost device, outside the layout pass that found it.
    private void QueueRedraw()
    {
        if (_redrawQueued)
        {
            return;
        }
        _redrawQueued = true;
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Normal, () =>
        {
            _redrawQueued = false;
            InvalidateRows();
        });
    }
}

// What the grid has done, for the gate and the tests.
internal sealed class GridCounters
{
    public LayoutCounters Layout { get; } = new();

    public LayoutCounters FrozenLayout { get; } = new();

    public long RowsDrawn;
    public long CellsBound;
    public double DrawMilliseconds;

    public void Reset()
    {
        Layout.Reset();
        FrozenLayout.Reset();
        RowsDrawn = 0;
        CellsBound = 0;
        DrawMilliseconds = 0;
    }
}

// The brushes of the grid's XAML parts. Their colors change in place with the theme, so every element follows.
internal sealed class GridBrushes
{
    public SolidColorBrush Background { get; } = new();

    public SolidColorBrush Clear { get; } = new(Microsoft.UI.Colors.Transparent);

    public SolidColorBrush HeaderBackground { get; } = new();

    public SolidColorBrush HeaderHover { get; } = new();

    public SolidColorBrush HeaderPressed { get; } = new();

    public SolidColorBrush HeaderText { get; } = new();

    public SolidColorBrush Divider { get; } = new();

    public SolidColorBrush Selection { get; } = new();

    public SolidColorBrush Focus { get; } = new();

    public void Apply(GridColors colors)
    {
        Background.Color = colors.Background;
        HeaderBackground.Color = colors.HeaderBackground;
        HeaderHover.Color = colors.HeaderHover;
        HeaderPressed.Color = colors.HeaderPressed;
        HeaderText.Color = colors.HeaderText;
        Divider.Color = colors.Divider;
        Selection.Color = colors.Selection;
        Focus.Color = colors.Focus;
    }
}

// A pane's canvas the size of the whole table. Point queries from UIA reach the drawn cells through its peer.
internal sealed partial class PaneContent(DataGridView grid, bool frozen) : Canvas
{
    public bool IsFrozen => frozen;

    protected override AutomationPeer OnCreateAutomationPeer() => new PaneAutomationPeer(this, grid);
}
