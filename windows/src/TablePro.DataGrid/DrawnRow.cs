using System.Diagnostics;
using System.Globalization;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Hosting;
using TablePro.Graphics;
using TerraFX.Interop.DirectX;
using Windows.Foundation;
using Windows.Graphics;
using static TerraFX.Interop.DirectX.D2D1_DRAW_TEXT_OPTIONS;
using static TerraFX.Interop.DirectX.D2D1_TEXT_ANTIALIAS_MODE;

namespace TablePro.DataGrid;

// Keeps a layout per visible cell while the row stays, so a sideways scroll lays out only the columns coming in.
internal sealed unsafe partial class DrawnRow : Microsoft.UI.Xaml.Controls.Grid
{
    private readonly DataGridView _grid;
    private readonly bool _frozen;
    private readonly SpriteVisual _sprite;
    private readonly CompositionSurfaceBrush _brush;
    private readonly char[] _number = new char[12];
    private DrawingSurface? _surface;
    private CellSlot[] _cells = new CellSlot[16];
    private int _cellCount;
    private nint _numberLayout;
    private int _numberRow = -1;
    private int _layoutVersion = -1;
    private int _inkVersion = -1;
    private int _generation = -1;

    public DrawnRow(DataGridView grid, bool frozen)
    {
        _grid = grid;
        _frozen = frozen;
        var compositor = ElementCompositionPreview.GetElementVisual(grid).Compositor;
        _brush = compositor.CreateSurfaceBrush();
        _brush.Stretch = CompositionStretch.Fill;
        _sprite = compositor.CreateSpriteVisual();
        _sprite.Brush = _brush;
        ElementCompositionPreview.SetElementChildVisual(this, _sprite);
        Instances++;
    }

    public static int Instances { get; private set; }

    public bool IsFrozen => _frozen;

    // The row this element stands for.
    public int Row { get; private set; } = -1;

    // What the surface shows: the row, and the columns from First to Last.
    public int DrawnRowIndex { get; private set; } = -1;

    public int DrawnFirst { get; private set; }

    public int DrawnLast { get; private set; } = -1;

    public float SpriteX => _sprite.Offset.X;

    public Vector2 SpriteSize => _sprite.Size;

    public SizeInt32 SurfacePixels => _surface?.Pixels ?? default;

    public int CellCount => _cellCount;

    public void SetRow(int row)
    {
        if (row != Row)
        {
            Row = row;
            ReleaseCells();
            DrawnRowIndex = -1;
        }
        InvalidateMeasure();
    }

    public void Invalidate() => InvalidateMeasure();

    // The text hash and length drawn for a column, for the stale-cell checks; false when the column is not drawn.
    public bool TryGetDrawn(int column, out int hash, out int length)
    {
        for (var i = 0; i < _cellCount; i++)
        {
            if (_cells[i].Column == column)
            {
                hash = _cells[i].Hash;
                length = _cells[i].Length;
                return DrawnRowIndex == Row;
            }
        }
        hash = 0;
        length = 0;
        return false;
    }

    public void Release()
    {
        ReleaseCells();
        _surface?.Dispose();
        _surface = null;
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        Draw();
        return new Size(_grid.PaneWidth(_frozen), _grid.RowHeight);
    }

    protected override Size ArrangeOverride(Size finalSize) => finalSize;

    private void Draw()
    {
        var (first, last) = _frozen ? (0, _grid.Columns.FrozenCount - 1) : _grid.ColumnWindow;
        if (Row < 0 || Row >= _grid.RowCount || (!_frozen && last < first))
        {
            return;
        }
        var painter = _grid.Painter;
        var device = painter.Device;
        painter.EnsureBrushes();
        var layoutVersion = _grid.LayoutVersion;
        var inkVersion = _grid.InkVersion(_frozen);
        if (Row == DrawnRowIndex && first == DrawnFirst && last == DrawnLast && layoutVersion == _layoutVersion
            && inkVersion == _inkVersion && _generation == device.Generation)
        {
            return;
        }
        var started = Stopwatch.GetTimestamp();
        if (layoutVersion != _layoutVersion || DrawnRowIndex != Row)
        {
            ReleaseCells();
            _layoutVersion = layoutVersion;
        }
        KeepColumns(first, last);
        var rowHeight = (float)_grid.RowHeight;
        var columns = _grid.Columns;
        for (var column = first; column <= last; column++)
        {
            if (IndexOf(column) < 0)
            {
                AddCell(column, painter, rowHeight);
            }
        }
        var x0 = _frozen ? 0 : columns.PaneX(first);
        var width = _frozen ? columns.FrozenWidth : columns.PaneX(last) + columns.Width(last) - x0;
        var scale = _grid.RenderScale;
        var need = new SizeInt32((int)Math.Ceiling(width * scale), (int)Math.Ceiling(rowHeight * scale));
        if (need.Width <= 0 || need.Height <= 0)
        {
            return;
        }
        if (_surface is null)
        {
            _surface = device.CreateSurface(need);
            _brush.Surface = _surface.Surface;
        }
        else if (_surface.Pixels.Width < need.Width || _surface.Pixels.Height < need.Height)
        {
            _surface.Resize(new SizeInt32(Math.Max(need.Width, _surface.Pixels.Width), Math.Max(need.Height, _surface.Pixels.Height)));
        }
        // The surface only grows, so it may be larger than the row; past what is drawn it is clear.
        _sprite.Size = new Vector2(_surface.Pixels.Width / scale, _surface.Pixels.Height / scale);
        _sprite.Offset = new Vector3((float)x0, 0, 0);

        var generation = device.Generation;
        var context = _surface.Begin(scale);
        if (context is null)
        {
            _grid.OnDeviceLost();
            return;
        }
        var clear = default(DXGI_RGBA);
        context->Clear(&clear);
        context->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        var selection = _grid.SelectionRange;
        var rowSelected = Row >= selection.FirstRow && Row <= selection.LastRow;
        if (_frozen)
        {
            DrawRowNumber(context, painter, rowHeight, rowSelected && selection.FirstColumn == 0 && selection.LastColumn == columns.Count - 1);
        }
        for (var i = 0; i < _cellCount; i++)
        {
            ref var cell = ref _cells[i];
            var x = (float)(columns.PaneX(cell.Column) - x0);
            var w = (float)columns.Width(cell.Column);
            if (cell.Layout != 0)
            {
                var selected = rowSelected && cell.Column >= selection.FirstColumn && cell.Column <= selection.LastColumn;
                context->DrawTextLayout(new D2D_POINT_2F(x + CellPainter.Padding, 0), (IDWriteTextLayout*)cell.Layout,
                    painter.InkBrush(cell.Ink, selected), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
            }
            var divider = new D2D_RECT_F(x + w - 1, 0, x + w, rowHeight);
            context->FillRectangle(&divider, painter.DividerBrush);
        }
        var bottom = new D2D_RECT_F(0, rowHeight - 1, (float)width, rowHeight);
        context->FillRectangle(&bottom, painter.DividerBrush);
        if (_frozen)
        {
            var edge = new D2D_RECT_F((float)width - 1, 0, (float)width, rowHeight);
            context->FillRectangle(&edge, painter.FrozenEdgeBrush);
        }
        if (!_surface.End(context) || device.Generation != generation)
        {
            _grid.OnDeviceLost();
            return;
        }
        DrawnRowIndex = Row;
        DrawnFirst = first;
        DrawnLast = last;
        _inkVersion = inkVersion;
        _generation = device.Generation;
        _grid.Counters.RowsDrawn++;
        _grid.Counters.DrawMilliseconds += Stopwatch.GetElapsedTime(started).TotalMilliseconds;
    }

    private void DrawRowNumber(ID2D1DeviceContext* context, CellPainter painter, float rowHeight, bool selected)
    {
        var width = (float)_grid.Columns.RowHeaderWidth;
        var back = new D2D_RECT_F(0, 0, width, rowHeight);
        context->FillRectangle(&back, painter.HeaderBrush);
        if (_numberRow != Row || _numberLayout == 0)
        {
            ReleaseNumber();
            (Row + 1).TryFormat(_number, out var length, provider: CultureInfo.CurrentCulture);
            _numberLayout = (nint)painter.CreateRowNumber(_number.AsSpan(0, length), width - CellPainter.RowNumberPadding * 2, rowHeight);
            _numberRow = Row;
        }
        if (_numberLayout != 0)
        {
            context->DrawTextLayout(new D2D_POINT_2F(CellPainter.RowNumberPadding, 0), (IDWriteTextLayout*)_numberLayout,
                painter.InkBrush(CellInk.RowNumber, selected), D2D1_DRAW_TEXT_OPTIONS_NONE);
        }
        var edge = new D2D_RECT_F(width - 1, 0, width, rowHeight);
        context->FillRectangle(&edge, painter.DividerBrush);
    }

    private void AddCell(int column, CellPainter painter, float rowHeight)
    {
        var cell = _grid.Cell(Row, column);
        var width = (float)(_grid.Columns.Width(column) - CellPainter.Padding * 2);
        var layout = painter.CreateLayout(cell.Text, cell.State, width, rowHeight, out var ink);
        if (_cellCount == _cells.Length)
        {
            Array.Resize(ref _cells, _cells.Length * 2);
        }
        _cells[_cellCount++] = new CellSlot
        {
            Column = column,
            Layout = (nint)layout,
            Ink = ink,
            Hash = string.GetHashCode(cell.Text),
            Length = cell.Text.Length,
        };
        _grid.Counters.CellsBound++;
    }

    private void KeepColumns(int first, int last)
    {
        var kept = 0;
        for (var i = 0; i < _cellCount; i++)
        {
            if (_cells[i].Column >= first && _cells[i].Column <= last)
            {
                _cells[kept++] = _cells[i];
            }
            else
            {
                Release(ref _cells[i]);
            }
        }
        _cellCount = kept;
    }

    private int IndexOf(int column)
    {
        for (var i = 0; i < _cellCount; i++)
        {
            if (_cells[i].Column == column)
            {
                return i;
            }
        }
        return -1;
    }

    private void ReleaseCells()
    {
        for (var i = 0; i < _cellCount; i++)
        {
            Release(ref _cells[i]);
        }
        _cellCount = 0;
        ReleaseNumber();
    }

    private void ReleaseNumber()
    {
        if (_numberLayout != 0)
        {
            ((IDWriteTextLayout*)_numberLayout)->Release();
            _numberLayout = 0;
        }
        _numberRow = -1;
    }

    private static void Release(ref CellSlot cell)
    {
        if (cell.Layout != 0)
        {
            ((IDWriteTextLayout*)cell.Layout)->Release();
            cell.Layout = 0;
        }
    }

    private struct CellSlot
    {
        public int Column;
        public nint Layout;
        public CellInk Ink;
        public int Hash;
        public int Length;
    }
}
