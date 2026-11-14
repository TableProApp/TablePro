using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using TablePro.DataGrid.Model;
using TerraFX.Interop.Windows;
using Windows.Foundation;
using static TerraFX.Interop.Windows.Windows;

namespace TablePro.DataGrid;

// ToolTipService arms a tooltip only on its owner's PointerEntered, so one owned by a pane would open for the first
// cell alone. Each cut cell gets its own, timed as ToolTipService times a pointer's (ToolTipService_Partial.cpp).
public sealed partial class DataGridView
{
    private const int TipCharacters = 1_000;
    private const long ReshowWindowMilliseconds = 200;
    private const uint DefaultHoverMilliseconds = 400;

    private readonly DispatcherTimer _tipTimer = new();
    private ToolTip? _tip;
    private (bool Frozen, int Row, int Column)? _tipCell;
    private long _tipClosedAt = long.MinValue / 2;

    internal ToolTip? OpenTip => _tip;

    private void InitializeCellTips()
    {
        _tipTimer.Tick += (_, _) => OpenCellTip();
        _content.PointerExited += (_, _) => ClearCellTip();
        _frozenContent.PointerExited += (_, _) => ClearCellTip();
    }

    // The pointer rests over a cell of a pane, or over none.
    internal void TrackCellTip(bool frozen, (int Row, int Column)? hit)
    {
        (bool, int, int)? cell = hit is { Column: >= 0 } at ? (frozen, at.Row, at.Column) : null;
        if (cell == _tipCell)
        {
            return;
        }
        ClearCellTip();
        if (cell is not { } over || !ShowsCellTips || IsEditing || !IsCut(over.Item2, over.Item3))
        {
            return;
        }
        _tipCell = over;
        _tipTimer.Interval = TipDelay();
        _tipTimer.Start();
    }

    internal void ClearCellTip()
    {
        _tipTimer.Stop();
        _tipCell = null;
        if (_tip is { } tip)
        {
            _tip = null;
            if (tip.IsOpen)
            {
                tip.IsOpen = false;
                _tipClosedAt = Environment.TickCount64;
            }
        }
    }

    // Opened now rather than after the hover time, as the tests do.
    internal void OpenCellTip()
    {
        _tipTimer.Stop();
        if (_tipCell is not { } at || IsEditing || XamlRoot is null || CellTipText(at.Row, at.Column) is not { } text)
        {
            return;
        }
        var pane = at.Frozen ? (UIElement)_frozenContent : _content;
        // A tooltip opened by code has no pointer to follow, so it docks to the cell's rectangle.
        _tip = new ToolTip
        {
            Content = text,
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            PlacementTarget = pane,
            PlacementRect = new Rect(_columns.PaneX(at.Column), at.Row * _rowHeight, _columns.Width(at.Column), _rowHeight),
            Placement = PlacementMode.Top,
        };
        _tip.IsOpen = true;
    }

    // Null where nothing is cut: a NULL, a DEFAULT and text the column shows whole have no tip.
    internal string? CellTipText(int row, int column)
    {
        if (!IsCut(row, column))
        {
            return null;
        }
        var cell = Cell(row, column);
        if (!cell.IsTruncated)
        {
            return cell.Text.ToString();
        }
        using var reader = _data!.OpenReader();
        var block = new CellBlock();
        reader.Read(row, 1, column, 1, TipCharacters, block);
        var read = block.Get(row, column);
        return read.IsTruncated ? string.Concat(read.Text, "…") : read.Text.ToString();
    }

    private bool IsCut(int row, int column)
    {
        if (_data is null || !Contains(row, column))
        {
            return false;
        }
        var cell = Cell(row, column);
        return !cell.IsNull && !cell.IsDefault && !cell.Text.IsEmpty
            && (cell.IsTruncated || Painter.Measure(cell.Text) > _columns.Width(column) - (CellPainter.Padding * 2));
    }

    // Twice the hover time, or one and a half within the reshow window after a tip closed.
    private unsafe TimeSpan TipDelay()
    {
        uint hover = 0;
        bool read = SystemParametersInfoW(SPI.SPI_GETMOUSEHOVERTIME, 0, &hover, 0);
        if (!read || hover == 0)
        {
            hover = DefaultHoverMilliseconds;
        }
        var reshow = Environment.TickCount64 - _tipClosedAt < ReshowWindowMilliseconds;
        return TimeSpan.FromMilliseconds(hover * (reshow ? 1.5 : 2));
    }
}
