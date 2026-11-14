using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TablePro.DataGrid.Automation;
using TablePro.DataGrid.Model;
using TablePro.Graphics;
using Windows.Foundation;
using Windows.System;
using Windows.UI.Core;

namespace TablePro.DataGrid;

public sealed partial class DataGridView
{
    private CancellationTokenSource? _copy;
    private bool _dragging;
    private bool _dragFrozen;

    public int Copies { get; private set; }

    // Moves the focused cell for a key, as OnKeyDown does; false when the key is not the grid's or an editor is open.
    public bool HandleKey(VirtualKey key, bool control, bool shift)
    {
        if (_data is null || RowCount == 0 || ColumnCount == 0 || IsEditing)
        {
            return false;
        }
        GridKey move;
        switch (key)
        {
            case VirtualKey.Up:
                move = GridKey.Up;
                break;
            case VirtualKey.Down:
                move = GridKey.Down;
                break;
            case VirtualKey.Left:
                move = GridKey.Left;
                break;
            case VirtualKey.Right:
                move = GridKey.Right;
                break;
            case VirtualKey.PageUp:
                move = GridKey.PageUp;
                break;
            case VirtualKey.PageDown:
                move = GridKey.PageDown;
                break;
            case VirtualKey.Home:
                move = GridKey.Home;
                break;
            case VirtualKey.End:
                move = GridKey.End;
                break;
            case VirtualKey.A when control:
                SelectAll();
                return true;
            case VirtualKey.C when control:
            case VirtualKey.Insert when control:
                _ = CopySelectionAsync();
                return true;
            // Typing does not start an edit, as on macOS.
            case VirtualKey.F2 when !control && !shift:
            case VirtualKey.Enter when !control && !shift:
                if (!IsEditable)
                {
                    return false;
                }
                BeginEditAfterKey();
                return true;
            case VirtualKey.Delete when !control && !shift:
                if (!IsEditable)
                {
                    return false;
                }
                DeleteRequested?.Invoke(this, EventArgs.Empty);
                return true;
            default:
                return false;
        }
        var page = GridNavigation.PageRows(VisibleArea().Height, _rowHeight);
        var (row, column) = GridNavigation.Move(move, control, _selection.FocusRow, _selection.FocusColumn, RowCount, ColumnCount, page);
        SelectCell(row, column, shift);
        return true;
    }

    public void SelectCell(int row, int column, bool extend)
    {
        if (RowCount == 0 || ColumnCount == 0)
        {
            return;
        }
        _selection.Select(Math.Clamp(row, 0, RowCount - 1), Math.Clamp(column, 0, ColumnCount - 1), extend);
        SelectionChanged();
        ScrollIntoView(_selection.FocusRow, _selection.FocusColumn);
        RaiseFocusChanged();
    }

    public void SelectRows(int row, bool extend)
    {
        if (RowCount == 0 || ColumnCount == 0)
        {
            return;
        }
        _selection.SelectRows(Math.Clamp(row, 0, RowCount - 1), extend, _selection.FocusColumn);
        SelectionChanged();
        ScrollIntoView(_selection.FocusRow, _selection.FocusColumn);
        RaiseFocusChanged();
    }

    public void SelectAll()
    {
        _selection.SelectAll();
        SelectionChanged();
    }

    public void ScrollIntoView(int row, int column)
    {
        if (RowCount == 0)
        {
            return;
        }
        var visible = VisibleArea();
        var x = _viewX;
        var y = _viewY;
        if (column >= _columns.FrozenCount && column < _columns.Count)
        {
            var left = _columns.PaneX(column);
            var right = left + _columns.Width(column);
            if (left < visible.Left)
            {
                x = left;
            }
            else if (right > visible.Right)
            {
                x = Math.Min(left, right - visible.Width);
            }
        }
        var top = row * _rowHeight;
        var bottom = top + _rowHeight;
        if (top < visible.Top)
        {
            y = top;
        }
        else if (bottom > visible.Bottom)
        {
            y = bottom - visible.Height;
        }
        if (x != _viewX || y != _viewY)
        {
            ScrollTo(x, y);
        }
    }

    // On a pool thread with a reader of its own, so a selection of any size copies without blocking the UI thread.
    public async Task<bool> CopySelectionAsync()
    {
        if (_data is null)
        {
            return false;
        }
        var range = SelectionRange;
        if (range.IsEmpty)
        {
            return false;
        }
        if (_copy is not null)
        {
            await _copy.CancelAsync().ConfigureAwait(true);
        }
        using var cancel = new CancellationTokenSource();
        _copy = cancel;
        var data = _data;
        var edited = _edited;
        // Taken with the range, so a later swap of the edits cannot move the rows it names.
        var edits = edited?.Edits ?? GridEdits.None;
        try
        {
            var text = await Task.Run(() =>
            {
                using var reader = edited is null ? data.OpenReader() : edited.OpenReader(edits);
                return GridCopy.Tsv(reader, range, cancel.Token);
            }, cancel.Token).ConfigureAwait(true);
            if (cancel.IsCancellationRequested || !ClipboardText.TrySet(text))
            {
                return false;
            }
            Copies++;
            return true;
        }
        catch (OperationCanceledException)
        {
            return false;
        }
        catch (ObjectDisposedException) when (cancel.IsCancellationRequested)
        {
            // The host let go of the data it replaced while this read it.
            return false;
        }
        finally
        {
            if (ReferenceEquals(_copy, cancel))
            {
                _copy = null;
            }
        }
    }

    internal void SortBy(int column)
    {
        var next = _sort.Clicked(column);
        Sort = next;
        SortRequested?.Invoke(this, next);
    }

    internal void ResizeColumn(int column, double width)
    {
        _columns.SetWidth(column, width);
        _sizedByUser[column] = true;
        ColumnsChanged();
    }

    // Fits a column to its header and the rows in view; a result set may hold far more rows than can be read here.
    internal void FitColumn(int column)
    {
        var (first, last) = _rowWindow;
        ResizeColumn(column, ContentWidth(column, first, last, int.MaxValue));
    }

    // As the macOS grid sizes a new result, from its first rows: the rest may still be arriving.
    private bool SizeToContent()
    {
        if (!SizeColumnsToContent || _data is null)
        {
            return false;
        }
        var rows = Math.Min(RowCount, ColumnCount > ContentSampleWideColumns ? ContentSampleRowsWide : ContentSampleRows);
        for (var column = 0; column < ColumnCount; column++)
        {
            if (!_sizedByUser[column])
            {
                _columns.SetWidth(column, Math.Clamp(ContentWidth(column, 0, rows - 1, ContentSampleCharacters),
                    ContentMinimumWidth, Math.Max(ContentMinimumWidth, MaximumContentColumnWidth)));
            }
        }
        _sizedToRows = rows > 0;
        return true;
    }

    private double ContentWidth(int column, int firstRow, int lastRow, int maxCharacters)
    {
        var painter = Painter;
        // Room for the sort glyph, and for the masked mark on a column that has one.
        var widest = painter.Measure(Head(_names[column], maxCharacters)) + 24 + (MaskNote(column) is null ? 0 : 20);
        for (var row = firstRow; row <= lastRow; row++)
        {
            var cell = Cell(row, column);
            widest = Math.Max(widest, cell.IsNull
                ? painter.Measure(_nullText, placeholder: true)
                : cell.IsDefault ? painter.MeasureDefault() : painter.Measure(Head(cell.Text, maxCharacters)));
        }
        return Math.Ceiling(widest + (CellPainter.Padding * 2) + 2);
    }

    private static ReadOnlySpan<char> Head(ReadOnlySpan<char> text, int maxCharacters)
    {
        if (text.Length <= maxCharacters)
        {
            return text;
        }
        var end = char.IsHighSurrogate(text[maxCharacters - 1]) ? maxCharacters - 1 : maxCharacters;
        return text[..end];
    }

    // The cells in view, row by row, the frozen ones first: what the automation tree lists.
    internal IEnumerable<(int Row, int Column)> VisibleCells()
    {
        var (first, last) = VisibleRows();
        var (scrollFirst, scrollLast) = _columnWindow;
        for (var row = first; row <= last; row++)
        {
            for (var column = 0; column < _columns.FrozenCount; column++)
            {
                yield return (row, column);
            }
            for (var column = scrollFirst; column <= scrollLast; column++)
            {
                yield return (row, column);
            }
        }
    }

    internal bool IsCellVisible(int row, int column)
    {
        if (!Contains(row, column))
        {
            return false;
        }
        var (first, last) = VisibleRows();
        if (row < first || row > last)
        {
            return false;
        }
        return column < _columns.FrozenCount || (column >= _columnWindow.First && column <= _columnWindow.Last);
    }

    internal bool HasFocusedCell(int row, int column) =>
        FocusState != FocusState.Unfocused && _selection.FocusRow == row && _selection.FocusColumn == column;

    // Where a menu opened from the keyboard (Shift+F10, the Menu key) goes: under the focused cell, in this grid's
    // coordinates, as a pointer's menu opens where it was clicked. Null when the cell is scrolled out of view.
    public Point? FocusedCellMenuPoint()
    {
        var (row, column) = (_selection.FocusRow, _selection.FocusColumn);
        if (!IsCellVisible(row, column) || XamlRoot is null)
        {
            return null;
        }
        var pane = column < _columns.FrozenCount ? (UIElement)_frozenContent : _content;
        var bounds = pane.TransformToVisual(this).TransformBounds(new Rect(_columns.PaneX(column), row * _rowHeight,
            _columns.Width(column), _rowHeight));
        return new Point(bounds.Left, bounds.Bottom);
    }

    // Physical pixels from the window's client area, which is what XAML's UIA bridge expects of a peer.
    internal Rect CellBoundsPhysical(int row, int column)
    {
        if (!IsCellVisible(row, column) || XamlRoot is null)
        {
            return default;
        }
        var pane = column < _columns.FrozenCount ? (UIElement)_frozenContent : _content;
        var bounds = pane.TransformToVisual(null).TransformBounds(new Rect(_columns.PaneX(column), row * _rowHeight,
            _columns.Width(column), _rowHeight));
        var scale = XamlRoot.RasterizationScale;
        return new Rect(bounds.X * scale, bounds.Y * scale, bounds.Width * scale, bounds.Height * scale);
    }

    internal AutomationPeer? CellPeerAt(Point physical)
    {
        if (XamlRoot is null || FrameworkElementAutomationPeer.CreatePeerForElement(this) is not DataGridAutomationPeer peer)
        {
            return null;
        }
        var scale = XamlRoot.RasterizationScale;
        var point = new Point(physical.X / scale, physical.Y / scale);
        foreach (var frozen in new[] { true, false })
        {
            var pane = frozen ? (UIElement)_frozenContent : _content;
            var local = pane.TransformToVisual(null).Inverse.TransformPoint(point);
            if (HitTest(frozen, local) is { Column: >= 0 } hit && IsCellVisible(hit.Row, hit.Column))
            {
                return peer.Cell(hit.Row, hit.Column);
            }
        }
        return null;
    }

    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        // The editor's keys bubble here, the Enter that committed it among them.
        if (e.Handled || (_editor is not null && ReferenceEquals(e.OriginalSource, _editor)))
        {
            base.OnKeyDown(e);
            return;
        }
        if (HandleKey(e.Key, IsDown(VirtualKey.Control), IsDown(VirtualKey.Shift)))
        {
            e.Handled = true;
            return;
        }
        base.OnKeyDown(e);
    }

    private void InitializeInput()
    {
        _content.PointerPressed += (_, e) => OnPanePressed(e, frozen: false);
        _frozenContent.PointerPressed += (_, e) => OnPanePressed(e, frozen: true);
        _content.PointerMoved += (_, e) => OnPaneMoved(e, frozen: false);
        _frozenContent.PointerMoved += (_, e) => OnPaneMoved(e, frozen: true);
        _content.PointerReleased += (_, _) => _dragging = false;
        _frozenContent.PointerReleased += (_, _) => _dragging = false;
        _content.PointerCaptureLost += (_, _) => _dragging = false;
        _frozenContent.PointerCaptureLost += (_, _) => _dragging = false;
        _content.DoubleTapped += (_, e) => OnPaneDoubleTapped(e, frozen: false);
        _frozenContent.DoubleTapped += (_, e) => OnPaneDoubleTapped(e, frozen: true);
        _content.ContextRequested += (_, e) => OnPaneContextRequested(e, frozen: false);
        _frozenContent.ContextRequested += (_, e) => OnPaneContextRequested(e, frozen: true);
    }

    // The panes see the request before the host's handler on the grid; a key's request has no position.
    private void OnPaneContextRequested(ContextRequestedEventArgs e, bool frozen)
    {
        if (e.Handled || IsInEditor(e.OriginalSource))
        {
            return;
        }
        var pane = frozen ? (UIElement)_frozenContent : _content;
        Point? point = e.TryGetPosition(pane, out var at) ? at : null;
        HandleContextRequest(frozen, point);
    }

    // As File Explorer and Excel: a right-click outside the selection selects the cell first. Also how the tests right-click.
    internal void HandleContextRequest(bool frozen, Point? point)
    {
        if (point is not { } at || HitTest(frozen, at) is not { } hit)
        {
            return;
        }
        Focus(FocusState.Pointer);
        var range = SelectionRange;
        var inside = hit.Column >= 0
            ? range.Contains(hit.Row, hit.Column)
            : range.Contains(hit.Row, 0) && range.LastColumn == ColumnCount - 1;
        if (inside)
        {
            return;
        }
        if (hit.Column < 0)
        {
            SelectRows(hit.Row, extend: false);
        }
        else
        {
            SelectCell(hit.Row, hit.Column, extend: false);
        }
    }

    private void OnPaneDoubleTapped(DoubleTappedRoutedEventArgs e, bool frozen)
    {
        var pane = frozen ? (UIElement)_frozenContent : _content;
        if (!IsEditable || HitTest(frozen, e.GetPosition(pane)) is not { Column: >= 0 } hit)
        {
            return;
        }
        SelectCell(hit.Row, hit.Column, extend: false);
        BeginEdit();
        e.Handled = true;
    }

    // A press picks a cell, or a row on the row numbers; Shift extends from the anchor. Dragging extends too.
    private void OnPanePressed(PointerRoutedEventArgs e, bool frozen)
    {
        var pane = frozen ? (UIElement)_frozenContent : _content;
        var point = e.GetCurrentPoint(pane);
        if (!point.Properties.IsLeftButtonPressed)
        {
            return;
        }
        // Pointer modifiers missed a Shift sent by SendInput on the runners; the thread's key state has it (wingates2).
        var shift = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Shift) || IsDown(VirtualKey.Shift);
        Focus(FocusState.Pointer);
        HandlePress(frozen, point.Position, shift);
        _dragging = pane.CapturePointer(e.Pointer);
        _dragFrozen = frozen;
        e.Handled = true;
    }

    private void OnPaneMoved(PointerRoutedEventArgs e, bool frozen)
    {
        var pane = frozen ? (UIElement)_frozenContent : _content;
        if (!_dragging && ShowsCellTips)
        {
            ShowCellTip(pane, HitTest(frozen, e.GetCurrentPoint(pane).Position));
        }
        if (!_dragging || frozen != _dragFrozen)
        {
            return;
        }
        if (HitTest(frozen, e.GetCurrentPoint(pane).Position) is not { } hit)
        {
            return;
        }
        if (hit.Column < 0 || _selection.Kind == SelectionKind.Rows)
        {
            if (hit.Row != _selection.FocusRow)
            {
                SelectRows(hit.Row, extend: true);
            }
        }
        else if (hit.Row != _selection.FocusRow || hit.Column != _selection.FocusColumn)
        {
            SelectCell(hit.Row, hit.Column, extend: true);
        }
    }

    // One tooltip per pane, its text following the cell under the pointer; none over a NULL or the row numbers.
    private void ShowCellTip(UIElement pane, (int Row, int Column)? hit)
    {
        string? text = null;
        if (hit is { Column: >= 0 } at)
        {
            var cell = Cell(at.Row, at.Column);
            text = cell.IsNull || cell.IsDefault ? null
                : cell.IsTruncated ? _cache?.ReadWhole(at.Row, at.Column)
                : cell.Text.ToString();
        }
        if (string.IsNullOrEmpty(text))
        {
            ToolTipService.SetToolTip(pane, null);
            return;
        }
        var tip = ToolTipService.GetToolTip(pane) as ToolTip ?? new ToolTip();
        if (!string.Equals(tip.Content as string, text, StringComparison.Ordinal))
        {
            tip.Content = text;
        }
        ToolTipService.SetToolTip(pane, tip);
    }

    // A press at a point in a pane, in that pane's coordinates. Also how the tests click.
    internal void HandlePress(bool frozen, Point point, bool shift)
    {
        if (HitTest(frozen, point) is not { } hit)
        {
            return;
        }
        if (hit.Column < 0)
        {
            SelectRows(hit.Row, shift);
        }
        else
        {
            SelectCell(hit.Row, hit.Column, shift);
        }
    }

    // The cell under a point of a pane; Column is -1 over the row numbers.
    internal (int Row, int Column)? HitTest(bool frozen, Point point)
    {
        if (RowCount == 0 || point.Y < 0 || point.Y >= TotalHeight)
        {
            return null;
        }
        var row = Math.Clamp((int)Math.Floor(point.Y / _rowHeight), 0, RowCount - 1);
        if (frozen)
        {
            return point.X < 0 || point.X >= _columns.FrozenWidth ? null : (row, _columns.FrozenColumnAt(point.X));
        }
        if (_columns.FrozenCount >= _columns.Count || point.X < 0 || point.X >= _columns.ScrollWidth)
        {
            return null;
        }
        return (row, _columns.ScrollColumnAt(point.X));
    }

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private (int First, int Last) VisibleRows()
    {
        var visible = VisibleArea();
        if (RowCount == 0 || visible.Height <= 0)
        {
            return (0, -1);
        }
        var first = Math.Clamp((int)Math.Floor(visible.Top / _rowHeight), 0, RowCount - 1);
        var last = Math.Clamp((int)Math.Ceiling(visible.Bottom / _rowHeight) - 1, first, RowCount - 1);
        return (first, last);
    }

    private void SelectionChanged()
    {
        _selectionVersion++;
        UpdateSelectionBoxes();
        UpdateFocusBox();
        foreach (var (_, row) in _frozenRowsLayout.Realized)
        {
            ((DrawnRow)row).Invalidate();
        }
        var highContrast = Painter.Colors.HighContrast;
        if (highContrast || _edited is not null)
        {
            foreach (var (_, row) in _rowsLayout.Realized)
            {
                var drawn = (DrawnRow)row;
                if (highContrast || drawn.IsWashed)
                {
                    drawn.Invalidate();
                }
            }
        }
        if (AutomationPeer.ListenerExists(AutomationEvents.SelectionItemPatternOnElementSelected)
            && FrameworkElementAutomationPeer.CreatePeerForElement(this) is DataGridAutomationPeer peer)
        {
            peer.Cell(_selection.FocusRow, _selection.FocusColumn).RaiseAutomationEvent(AutomationEvents.SelectionItemPatternOnElementSelected);
        }
    }

    private void RaiseFocusChanged()
    {
        FocusedCellChanged?.Invoke(this, EventArgs.Empty);
        if (FocusState != FocusState.Unfocused && AutomationPeer.ListenerExists(AutomationEvents.AutomationFocusChanged)
            && FrameworkElementAutomationPeer.CreatePeerForElement(this) is DataGridAutomationPeer peer)
        {
            peer.Cell(_selection.FocusRow, _selection.FocusColumn).RaiseAutomationEvent(AutomationEvents.AutomationFocusChanged);
        }
    }

    // Cut to the realized rows: a million-row rectangle is past what float coordinates hold.
    private void UpdateSelectionBoxes()
    {
        var range = SelectionRange;
        var (first, last) = _rowWindow;
        var rows = (First: Math.Max(range.FirstRow, first), Last: Math.Min(range.LastRow, last));
        var single = range.RowCount == 1 && range.ColumnCount == 1 && _selection.Kind == SelectionKind.Cells;
        if (range.IsEmpty || single || rows.Last < rows.First)
        {
            _selectionBox.Visibility = Visibility.Collapsed;
            _frozenSelectionBox.Visibility = Visibility.Collapsed;
            return;
        }
        var top = (rows.First * _rowHeight) - _originY;
        var height = (rows.Last - rows.First + 1) * _rowHeight;
        PlaceSelection(_frozenSelectionBox, range.FirstColumn, Math.Min(range.LastColumn, _columns.FrozenCount - 1), frozen: true, top, height);
        PlaceSelection(_selectionBox, Math.Max(range.FirstColumn, _columns.FrozenCount), range.LastColumn, frozen: false, top, height);
    }

    private void PlaceSelection(Microsoft.UI.Xaml.Shapes.Rectangle box, int firstColumn, int lastColumn, bool frozen, double top,
        double height)
    {
        if (lastColumn < firstColumn)
        {
            box.Visibility = Visibility.Collapsed;
            return;
        }
        var left = frozen && _selection.Kind != SelectionKind.Cells ? 0 : _columns.PaneX(firstColumn);
        Canvas.SetLeft(box, left);
        Canvas.SetTop(box, top);
        box.Width = _columns.PaneX(lastColumn) + _columns.Width(lastColumn) - left;
        box.Height = height;
        box.Visibility = Visibility.Visible;
    }

    private void UpdateFocusBox()
    {
        PlaceEditor();
        var row = _selection.FocusRow;
        var column = _selection.FocusColumn;
        var show = FocusState != FocusState.Unfocused && column < ColumnCount && row < RowCount
            && row >= _rowWindow.First && row <= _rowWindow.Last;
        var frozen = column < _columns.FrozenCount;
        var box = frozen ? _frozenFocusBox : _focusBox;
        (frozen ? _focusBox : _frozenFocusBox).Visibility = Visibility.Collapsed;
        if (!show)
        {
            box.Visibility = Visibility.Collapsed;
            return;
        }
        Canvas.SetLeft(box, _columns.PaneX(column));
        Canvas.SetTop(box, (row * _rowHeight) - _originY);
        box.Width = _columns.Width(column);
        box.Height = _rowHeight;
        box.Visibility = Visibility.Visible;
    }
}
