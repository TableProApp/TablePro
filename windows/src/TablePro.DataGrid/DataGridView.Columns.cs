using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TablePro.DataGrid.Model;
using Windows.Foundation;

namespace TablePro.DataGrid;

// The column order is the host's: the grid reports a header dropped in a new place and follows the order it is given.
public sealed partial class DataGridView
{
    private const double MoveLineWidth = 2;

    // A dragged header past this far inside the scrolling pane's edge scrolls it.
    private const double MoveScrollEdge = 24;

    private readonly Canvas _moveLayer = new() { IsHitTestVisible = false };
    private readonly Rectangle _moveLine = NewMoveLine();
    private readonly Rectangle _frozenMoveLine = NewMoveLine();
    private readonly DispatcherTimer _moveTimer = new() { Interval = TimeSpan.FromMilliseconds(30) };
    private HeaderCell? _moveHeader;
    private int _moveFrom = -1;
    private Point _movePoint;

    // Off, a header only sorts and resizes; on, one dragged sideways raises ColumnMoveRequested where it drops.
    public bool CanReorderColumns { get; set; }

    public event EventHandler<GridColumnMove>? ColumnMoveRequested;

    internal bool IsMovingColumn => _moveFrom >= 0;

    internal bool MoveLineShown =>
        _moveLine.Visibility == Visibility.Visible || _frozenMoveLine.Visibility == Visibility.Visible;

    // In place of SetData, so widths and the focus follow their columns; previous[i] is -1 for a column just shown.
    public void RearrangeColumns(IReadOnlyList<int> previous)
    {
        ArgumentNullException.ThrowIfNull(previous);
        if (_data is null)
        {
            return;
        }
        var count = _data.ColumnCount;
        if (previous.Count != count)
        {
            throw new ArgumentException("Each column the data shows needs its previous place.", nameof(previous));
        }
        var old = _columns;
        var moved = new int[old.Count];
        Array.Fill(moved, -1);
        for (var position = 0; position < count; position++)
        {
            var was = previous[position];
            ArgumentOutOfRangeException.ThrowIfLessThan(was, -1, nameof(previous));
            ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(was, old.Count, nameof(previous));
            if (was >= 0 && moved[was] >= 0)
            {
                throw new ArgumentException("A previous place is named twice.", nameof(previous));
            }
            if (was >= 0)
            {
                moved[was] = position;
            }
        }
        CancelColumnMove();
        ClearCellTip();
        // The host maps the editor's column with the new order now, so its text would land in another column.
        Cancel(EditorFocused);
        // A copy's range names display columns, which are other columns now.
        _copy?.Cancel();
        _cache?.Dispose();
        _cache = new CellCache(_data.OpenReader());

        var columns = new GridColumns(count, DefaultColumnWidth)
        {
            RowHeaderWidth = old.RowHeaderWidth,
            FrozenCount = old.FrozenCount,
        };
        var names = new string[count];
        var sizedByUser = new bool[count];
        var notes = new string?[_maskNotes.Length == 0 ? 0 : count];
        for (var position = 0; position < count; position++)
        {
            names[position] = _data.GetColumnName(position);
            var was = previous[position];
            if (was < 0)
            {
                continue;
            }
            columns.SetWidth(position, old.Width(was));
            sizedByUser[position] = _sizedByUser[was];
            if (notes.Length > 0)
            {
                notes[position] = MaskNote(was);
            }
        }
        _names = names;
        _sizedByUser = sizedByUser;
        _maskNotes = notes;
        _columns = columns;
        SizeShownColumns(previous);

        var focus = (_selection.FocusRow, _selection.FocusColumn);
        _selection.MoveColumns(NewPosition(moved, _selection.AnchorColumn), NewPosition(moved, _selection.FocusColumn));
        _selection.Clamp(RowCount, count);
        _selectionVersion++;
        // The header cells name their columns; a new source rebinds them (trap 5).
        _headerLayout.Forget();
        _columnItems = new IndexList(count);
        _header.ItemsSource = _columnItems;
        ColumnsChanged();
        var lastX = Math.Max(0, _columns.ScrollWidth - VisibleArea().Width);
        if (_viewX > lastX)
        {
            ScrollTo(lastX, _viewY);
        }
        RaiseStatusChanges();
        if (focus != (_selection.FocusRow, _selection.FocusColumn))
        {
            RaiseFocusChanged();
        }
        SelectedCellsChanged?.Invoke(this, EventArgs.Empty);
    }

    // The column of the header cell an element is in, for a host's header menu; -1 for the corner or anything else.
    public int HeaderColumnOf(object? originalSource)
    {
        for (var element = originalSource as DependencyObject; element is not null;
            element = VisualTreeHelper.GetParent(element))
        {
            if (element is HeaderCell header)
            {
                return ReferenceEquals(header.Owner, this) && header.Column >= 0 && header.Column < ColumnCount
                    ? header.Column
                    : -1;
            }
            if (ReferenceEquals(element, this))
            {
                return -1;
            }
        }
        return -1;
    }

    // From a header cell once its pointer has moved past the drag threshold; the cell keeps the capture.
    internal bool BeginColumnMove(HeaderCell header, int column, Point point)
    {
        if (!CanReorderColumns || column < 0 || column >= ColumnCount)
        {
            return false;
        }
        CancelColumnMove();
        ClearCellTip();
        // Escape reaches the grid's KeyDown only with the focus here.
        Focus(FocusState.Pointer);
        _moveHeader = header;
        _moveFrom = column;
        DragColumnMove(point);
        return true;
    }

    // A point in the ScrollViewer's coordinates, as each move here takes it.
    internal void DragColumnMove(Point point)
    {
        if (_moveFrom < 0)
        {
            return;
        }
        _movePoint = point;
        PlaceMoveLine();
        if (MoveScrollStep() != 0 && !_moveTimer.IsEnabled)
        {
            _moveTimer.Start();
        }
    }

    internal void EndColumnMove(Point point)
    {
        if (_moveFrom < 0)
        {
            return;
        }
        var move = GridColumnMove.Dropped(_moveFrom, MoveTarget(point).Boundary);
        StopColumnMove();
        if (move is { } requested)
        {
            ColumnMoveRequested?.Invoke(this, requested);
        }
    }

    // Escape, a lost capture, new data or a new order.
    internal void CancelColumnMove()
    {
        if (_moveFrom < 0)
        {
            return;
        }
        var header = _moveHeader;
        StopColumnMove();
        header?.StopMove();
    }

    // From the grid's own offset, which the drag's scrolling moves before a layout pass moves the header.
    internal (bool Frozen, int Boundary) MoveTarget(Point point)
    {
        var frozenX = point.X - CornerLeft();
        if (frozenX < _columns.FrozenWidth)
        {
            return (true, _columns.BoundaryAt(frozen: true, frozenX));
        }
        return (false, _columns.BoundaryAt(frozen: false, _viewX + point.X - _insetLeft));
    }

    private static Rectangle NewMoveLine() => new()
    {
        Width = MoveLineWidth,
        IsHitTestVisible = false,
        Visibility = Visibility.Collapsed,
    };

    private void InitializeColumnMoves()
    {
        _moveLine.Fill = Brushes.Focus;
        _frozenMoveLine.Fill = Brushes.Focus;
        _moveLayer.Children.Add(_moveLine);
        // Over the frozen header cells, which RebuildCorner adds after it.
        Canvas.SetZIndex(_frozenMoveLine, 1);
        _corner.Children.Add(_frozenMoveLine);
        _moveTimer.Tick += (_, _) => ScrollWhileMoving();
    }

    private void StopColumnMove()
    {
        _moveFrom = -1;
        _moveHeader = null;
        _moveTimer.Stop();
        _moveLine.Visibility = Visibility.Collapsed;
        _frozenMoveLine.Visibility = Visibility.Collapsed;
    }

    private void PlaceMoveLine()
    {
        var (frozen, boundary) = MoveTarget(_movePoint);
        var line = frozen ? _frozenMoveLine : _moveLine;
        (frozen ? _moveLine : _frozenMoveLine).Visibility = Visibility.Collapsed;
        var paneWidth = frozen ? _columns.FrozenWidth : _columns.ScrollWidth;
        Canvas.SetLeft(line, Math.Clamp(_columns.BoundaryX(frozen, boundary) - (MoveLineWidth / 2), 0,
            Math.Max(0, paneWidth - MoveLineWidth)));
        line.Height = HeaderHeight;
        line.Visibility = Visibility.Visible;
    }

    // Deeper into an edge band scrolls faster; 0 outside the bands or at that end.
    private double MoveScrollStep()
    {
        var left = _insetLeft;
        var right = _insetLeft + VisibleArea().Width;
        var x = _movePoint.X;
        if (x > right - MoveScrollEdge && _viewX < _scroller.ScrollableWidth)
        {
            return Math.Min(x - (right - MoveScrollEdge), MoveScrollEdge * 2);
        }
        if (x >= left && x < left + MoveScrollEdge && _viewX > 0)
        {
            return x - (left + MoveScrollEdge);
        }
        return 0;
    }

    private void ScrollWhileMoving()
    {
        var before = _viewX;
        var step = _moveFrom < 0 ? 0 : MoveScrollStep();
        if (step != 0)
        {
            ScrollTo(_viewX + step, _viewY);
        }
        if (_viewX == before)
        {
            _moveTimer.Stop();
            return;
        }
        PlaceMoveLine();
    }

    private double CornerLeft()
    {
        try
        {
            return _corner.TransformToVisual(_scroller).TransformPoint(default).X;
        }
        catch (ArgumentException)
        {
            return 0;
        }
    }

    // A column just shown starts as SetData starts one.
    private void SizeShownColumns(IReadOnlyList<int> previous)
    {
        if (!SizeColumnsToContent)
        {
            return;
        }
        if (!_sizedToRows)
        {
            SizeToContent();
            return;
        }
        var rows = ContentSampleRowCount;
        for (var position = 0; position < previous.Count; position++)
        {
            if (previous[position] < 0)
            {
                SizeColumnToContent(position, rows);
            }
        }
    }

    // Where a column went; a hidden one gives the nearest column still shown, the one to its right first.
    private static int NewPosition(int[] moved, int column)
    {
        for (var distance = 0; distance < moved.Length; distance++)
        {
            var right = column + distance;
            if (right >= 0 && right < moved.Length && moved[right] >= 0)
            {
                return moved[right];
            }
            var left = column - distance;
            if (left >= 0 && left < moved.Length && moved[left] >= 0)
            {
                return moved[left];
            }
        }
        return 0;
    }
}
