using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TablePro.Editor.Model;
using TablePro.Graphics;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.Storage;
using Windows.System;
using static TerraFX.Interop.Windows.SM;
using static TerraFX.Interop.Windows.SPI;
using static TerraFX.Interop.Windows.Windows;

namespace TablePro.Editor;

public sealed partial class SqlEditor
{
    private enum DragMode
    {
        None,
        Characters,
        Words,
        Lines,
        Column,
        PendingTextDrag,
    }

    private DragMode _drag;
    private Selection _dragOrigin;
    private int _columnAnchorRow;
    private int _columnAnchorColumn;
    private Point _pressPoint;
    private ulong _lastClickTime;
    private Point _lastClickPoint;
    private int _clickCount;
    private bool _draggingTextOut;

    private void HookPointer()
    {
        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += OnPointerReleased;
        PointerCaptureLost += (_, _) => _drag = DragMode.None;
        PointerExited += (_, _) => ShowChevrons(false);
        PointerWheelChanged += OnPointerWheelChanged;
        AllowDrop = true;
        DragOver += OnDragOver;
        Drop += OnDrop;
        DragStarting += OnDragStarting;
        DropCompleted += OnDropCompleted;
        ContextFlyout = BuildContextMenu();
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(_panel);
        if (!point.Properties.IsLeftButtonPressed || point.Position.X >= ViewWidth || point.Position.Y >= ViewHeight)
        {
            return;
        }
        Focus(FocusState.Pointer);
        RestartBlink();
        // A click splits an insert's undo step, as Vim splits it where the caret moves.
        _vim?.BreakInsertUndo();
        var position = point.Position;
        if (FoldClickedAt(position))
        {
            e.Handled = true;
            return;
        }
        CountClick(point.Timestamp, position);
        var offset = OffsetAt(position);
        var shift = (e.KeyModifiers & VirtualKeyModifiers.Shift) != 0;
        var alt = (e.KeyModifiers & VirtualKeyModifiers.Menu) != 0;
        _pressPoint = position;
        CapturePointer(e.Pointer);
        e.Handled = true;

        if (alt && _clickCount == 1)
        {
            (_columnAnchorRow, _columnAnchorColumn) = _model.RowColumnOf(offset);
            _model.AddSelection(Selection.Caret(offset));
            _drag = DragMode.Column;
            return;
        }
        if (_clickCount == 1 && !shift && _model.Selections.Any(s => !s.IsEmpty && offset > s.Start && offset < s.End))
        {
            _drag = DragMode.PendingTextDrag;
            return;
        }
        switch (_clickCount)
        {
            case 1 when shift:
                var primary = _model.Primary;
                _model.SetSelection(primary.Anchor, offset);
                _dragOrigin = new Selection(primary.Anchor, primary.Anchor);
                _drag = DragMode.Characters;
                break;
            case 1:
                _model.SetCaret(offset);
                _dragOrigin = Selection.Caret(offset);
                _drag = DragMode.Characters;
                break;
            case 2:
                _model.SelectRunAt(offset);
                _dragOrigin = _model.Primary;
                _drag = DragMode.Words;
                break;
            default:
                _model.SelectLineAt(offset);
                _dragOrigin = _model.Primary;
                _drag = DragMode.Lines;
                break;
        }
        Invalidate();
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_drag == DragMode.None)
        {
            var at = e.GetCurrentPoint(_panel).Position;
            ShowChevrons(at.X >= 0 && at.X < GutterWidth && at.Y >= 0 && at.Y < ViewHeight);
            return;
        }
        var position = e.GetCurrentPoint(_panel).Position;
        AutoScroll(position);
        var offset = OffsetAt(position);
        switch (_drag)
        {
            case DragMode.PendingTextDrag:
                if (Math.Abs(position.X - _pressPoint.X) + Math.Abs(position.Y - _pressPoint.Y) > 6)
                {
                    _drag = DragMode.None;
                    ReleasePointerCaptures();
                    _ = StartDragAsync(e.GetCurrentPoint(this));
                }
                return;
            case DragMode.Column:
                var (row, column) = _model.RowColumnOf(offset);
                _model.SetRowColumnSelection(_columnAnchorRow, _columnAnchorColumn, row, column);
                break;
            case DragMode.Characters:
                _model.SetSelection(_dragOrigin.Anchor, offset);
                break;
            case DragMode.Words:
            case DragMode.Lines:
                ExtendByUnit(offset);
                break;
        }
        e.Handled = true;
        Invalidate();
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_drag == DragMode.PendingTextDrag)
        {
            // A click inside a selection that never became a drag places the caret.
            _model.SetCaret(OffsetAt(e.GetCurrentPoint(_panel).Position));
        }
        _drag = DragMode.None;
        ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    private void OnPointerWheelChanged(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        var delta = point.Properties.MouseWheelDelta / 120.0;
        if ((e.KeyModifiers & VirtualKeyModifiers.Control) != 0)
        {
            Zoom += (float)(0.1 * Math.Sign(delta));
            e.Handled = true;
            return;
        }
        var horizontal = point.Properties.IsHorizontalMouseWheel || (e.KeyModifiers & VirtualKeyModifiers.Shift) != 0;
        if (horizontal)
        {
            ScrollBy(delta * (_layouts?.CharWidth ?? 8) * 8 * (point.Properties.IsHorizontalMouseWheel ? 1 : -1), 0);
        }
        else
        {
            ScrollBy(0, -delta * WheelLines() * LineHeight);
        }
        e.Handled = true;
    }

    // The chevrons show while the pointer is over the gutter, as the macOS editor and VS Code reveal them.
    private void ShowChevrons(bool show)
    {
        if (_pointerInGutter == show)
        {
            return;
        }
        _pointerInGutter = show;
        if (_foldingEnabled && RegionsNow().Count > 0)
        {
            Invalidate();
        }
    }

    // A chevron in the gutter folds or opens its region, and a click on a folded line's chip opens it.
    private bool FoldClickedAt(Windows.Foundation.Point position)
    {
        if (!_foldingEnabled || _layouts is null)
        {
            return false;
        }
        foreach (var (box, line) in _chips)
        {
            if (box.Contains(position))
            {
                return _model.Rows.Folds.Unfold(line);
            }
        }
        var left = NumbersRight + 4;
        if (position.X < left || position.X >= GutterWidth)
        {
            return false;
        }
        var (rowLine, rowStart, _) = _model.Rows.RowSpan(RowAt(position.Y));
        return rowStart == Document.GetLineStart(rowLine) && ToggleFold(rowLine);
    }

    private void ExtendByUnit(int offset)
    {
        var origin = _dragOrigin;
        (int Start, int End) unit;
        if (_drag == DragMode.Words)
        {
            unit = TextUnits.RunAt(Document, offset);
        }
        else
        {
            var line = Document.GetLineFromOffset(offset);
            unit = (Document.GetLineStart(line), line + 1 < Document.LineCount ? Document.GetLineStart(line + 1) : Document.Length);
        }
        _model.SetSelection(unit.Start < origin.Start ? origin.End : origin.Start, unit.Start < origin.Start ? unit.Start : Math.Max(unit.End, origin.End));
    }

    private void AutoScroll(Point position)
    {
        if (position.Y < 0)
        {
            ScrollBy(0, position.Y);
        }
        else if (position.Y > ViewHeight)
        {
            ScrollBy(0, position.Y - ViewHeight);
        }
        if (position.X < TextLeft)
        {
            ScrollBy(position.X - TextLeft, 0);
        }
        else if (position.X > ViewWidth)
        {
            ScrollBy(position.X - ViewWidth, 0);
        }
    }

    private void CountClick(ulong timestamp, Point position)
    {
        var interval = GetDoubleClickTime() * 1000UL;
        var slopX = GetSystemMetrics(SM_CXDOUBLECLK) / 2.0;
        var slopY = GetSystemMetrics(SM_CYDOUBLECLK) / 2.0;
        var near = Math.Abs(position.X - _lastClickPoint.X) <= slopX && Math.Abs(position.Y - _lastClickPoint.Y) <= slopY;
        _clickCount = timestamp - _lastClickTime <= interval && near ? _clickCount % 3 + 1 : 1;
        _lastClickTime = timestamp;
        _lastClickPoint = position;
    }

    private static unsafe int WheelLines()
    {
        uint lines = 3;
        SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
        return lines is 0 or uint.MaxValue ? 3 : (int)lines;
    }

    private void OnDragStarting(UIElement sender, DragStartingEventArgs args)
    {
        _draggingTextOut = true;
        args.Data.SetText(_model.GetSelectedText());
        args.Data.RequestedOperation = DataPackageOperation.Copy | DataPackageOperation.Move;
    }

    private void OnDropCompleted(UIElement sender, DropCompletedEventArgs args)
    {
        // Moved to another app: the text leaves this document. A move inside the editor was done by Drop.
        if (_draggingTextOut && args.DropResult == DataPackageOperation.Move)
        {
            Edit(() => _model.Backspace());
        }
        _draggingTextOut = false;
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (TakesFiles(e.DataView))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.Handled = true;
            return;
        }
        if (!e.DataView.Contains(StandardDataFormats.Text))
        {
            return;
        }
        var copy = (e.Modifiers & Windows.ApplicationModel.DataTransfer.DragDrop.DragDropModifiers.Control) != 0;
        e.AcceptedOperation = _draggingTextOut && !copy ? DataPackageOperation.Move : DataPackageOperation.Copy;
        e.Handled = true;
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (TakesFiles(e.DataView))
        {
            await DropFilesAsync(e);
            return;
        }
        if (!e.DataView.Contains(StandardDataFormats.Text))
        {
            return;
        }
        e.Handled = true;
        var deferral = e.GetDeferral();
        try
        {
            string text;
            try
            {
                text = await e.DataView.GetTextAsync();
            }
            catch (System.Runtime.InteropServices.COMException)
            {
                // The program the text was dragged from no longer answers, so nothing is dropped.
                return;
            }

            var target = OffsetAt(e.GetPosition(_panel));
            var move = _draggingTextOut && e.AcceptedOperation == DataPackageOperation.Move;
            Edit(() => _model.DropText(text, target, move));
            // The source is already gone, so the DropCompleted that follows must not remove anything.
            _draggingTextOut = false;
            Focus(FocusState.Pointer);
        }
        finally
        {
            deferral.Complete();
        }
    }

    // Only when the host listens, so a drop it would ignore is refused instead.
    private bool TakesFiles(DataPackageView data) =>
        FilesDropped is not null && !_draggingTextOut && data.Contains(StandardDataFormats.StorageItems);

    private async Task DropFilesAsync(DragEventArgs e)
    {
        e.Handled = true;
        var deferral = e.GetDeferral();
        List<string> paths;
        try
        {
            var items = await e.DataView.GetStorageItemsAsync();
            paths = items.Where(item => item.IsOfType(StorageItemTypes.File) && !string.IsNullOrEmpty(item.Path))
                .Select(item => item.Path)
                .ToList();
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            // The program the files were dragged from no longer answers, so nothing is dropped.
            return;
        }
        finally
        {
            deferral.Complete();
        }
        if (paths.Count > 0)
        {
            FilesDropped?.Invoke(this, paths);
        }
    }

    private MenuFlyout BuildContextMenu()
    {
        var menu = new MenuFlyout();
        // The editor handles these keys itself, so the items only show them.
        MenuFlyoutItem Add(string name, Action action)
        {
            var item = new MenuFlyoutItem
            {
                Text = HostStrings.Get(name),
                KeyboardAcceleratorTextOverride = HostStrings.Get(name + "Keys"),
            };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
            return item;
        }
        Add("EditorMenuUndo", () => Edit(_model.Undo));
        Add("EditorMenuRedo", () => Edit(_model.Redo));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("EditorMenuCut", Cut);
        Add("EditorMenuCopy", Copy);
        Add("EditorMenuPaste", () => _ = PasteAsync());
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("EditorMenuSelectAll", () => _model.SelectAll());
        Add("EditorMenuToggleComment", () => Edit(_model.ToggleLineComment));
        var foldSeparator = new MenuFlyoutSeparator();
        menu.Items.Add(foldSeparator);
        var fold = Add("EditorMenuFold", () => FoldAtCaret());
        var unfold = Add("EditorMenuUnfold", () => UnfoldAtCaret());
        var foldAll = Add("EditorMenuFoldAll", () => FoldAll());
        var unfoldAll = Add("EditorMenuUnfoldAll", () => UnfoldAll());
        var own = menu.Items.Count;
        menu.Opening += (_, _) =>
        {
            while (menu.Items.Count > own)
            {
                menu.Items.RemoveAt(menu.Items.Count - 1);
            }
            // Fold reads the caret's line, as Ctrl+Shift+[ does; Unfold opens the fold on it.
            var regions = RegionsNow();
            var folding = _foldingEnabled && regions.Count > 0;
            var shown = folding ? Visibility.Visible : Visibility.Collapsed;
            foldSeparator.Visibility = shown;
            fold.Visibility = shown;
            unfold.Visibility = shown;
            foldAll.Visibility = shown;
            unfoldAll.Visibility = shown;
            var line = Document.GetLineFromOffset(_model.Primary.Active);
            fold.IsEnabled = regions.Any(region => region.StartLine <= line && line <= region.EndLine
                && !_model.Rows.Folds.IsFolded(region.StartLine));
            unfold.IsEnabled = _model.Rows.Folds.IsFolded(line);
            unfoldAll.IsEnabled = _model.Rows.Folds.Count > 0;
            ContextMenuOpening?.Invoke(this, menu.Items);
        };
        return menu;
    }
}
