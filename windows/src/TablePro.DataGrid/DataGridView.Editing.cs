using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.DataGrid.Automation;
using TablePro.DataGrid.Model;
using Windows.System;

namespace TablePro.DataGrid;

// The grid opens the editor and shows the pending changes; the host checks, keeps and saves them.
public sealed partial class DataGridView
{
    private const int EditorMaxRows = 4;

    private TextBox? _editor;
    private ToolTip? _editorTip;
    private (int Row, int Column)? _edit;
    private string _editText = string.Empty;
    private string _newline = "\r";
    private int _editSession;
    private bool _committing;
    private bool _isEditable;
    private string _defaultText = "DEFAULT";

    public bool IsEditable
    {
        get => _isEditable;
        set
        {
            _isEditable = value;
            if (!value)
            {
                CancelEdit();
            }
        }
    }

    public bool IsEditing => _edit is not null;

    public string DefaultText
    {
        get => _defaultText;
        set
        {
            ArgumentNullException.ThrowIfNull(value);
            if (string.Equals(_defaultText, value, StringComparison.Ordinal))
            {
                return;
            }
            _defaultText = value;
            if (_painter is not null)
            {
                _painter.DefaultText = value;
                InvalidateRows();
            }
        }
    }

    public string EditedStatus { get; set; } = "edited";

    public string NewRowStatus { get; set; } = "new row";

    public string DeletedStatus { get; set; } = "marked for deletion";

    public event EventHandler<GridEditStartingEventArgs>? CellEditStarting;

    public event EventHandler<GridEditCommittingEventArgs>? CellEditCommitting;

    public event EventHandler? DeleteRequested;

    internal TextBox? Editor => _editor;

    private bool EditorFocused => _editor is not null && _editor.FocusState != FocusState.Unfocused;

    public void BeginEdit()
    {
        if (!IsEditable || (IsEditing && !Commit(EditorFocused)))
        {
            return;
        }
        var (row, column) = (FocusedRow, FocusedColumn);
        if (_cache is null || !Contains(row, column))
        {
            return;
        }
        var args = new GridEditStartingEventArgs(row, column, _cache.ReadWhole(row, column) ?? string.Empty);
        CellEditStarting?.Invoke(this, args);
        // A TextBox cannot hold NUL, so such a value would come back changed.
        if (args.Cancel || args.Text.Contains('\0', StringComparison.Ordinal) || IsEditing || !Contains(row, column))
        {
            return;
        }
        ScrollIntoView(row, column);
        OpenEditor(row, column, args.Text);
    }

    // True when no editor is open or the host took the text; false keeps the editor open with the host's Error.
    public bool CommitEdit() => Commit(EditorFocused);

    public void CancelEdit() => Cancel(EditorFocused);

    public void FocusCell(int row, int column) => SelectCell(row, column, extend: false);

    public void EditsChanged()
    {
        if (_data is null)
        {
            return;
        }
        if (_edit is { } open && !_committing && _data.RowCount != RowCount)
        {
            // The host's new rows have moved already, so a new row's index may name another one now.
            if (_edited is null || open.Row < _edited.Data.RowCount)
            {
                CommitOrCancel(EditorFocused);
            }
            else
            {
                Cancel(EditorFocused);
            }
        }
        _cache?.Dispose();
        _cache = new CellCache(_data.OpenReader());
        var count = _data.RowCount;
        if (count != RowCount)
        {
            var focus = (_selection.FocusRow, _selection.FocusColumn);
            if (count < RowCount)
            {
                // IndexList only grows. A new source, as SetData gives, takes the rows that went (trap 5).
                _rowsLayout.Forget();
                _frozenRowsLayout.Forget();
                _items = new IndexList(count);
                _rows.ItemsSource = _items;
                _frozenRows.ItemsSource = _items;
            }
            else
            {
                _items.Grow(count);
            }
            RowCount = count;
            _selection.Clamp(count, ColumnCount);
            _selectionVersion++;
            UpdateRowNumberWidth();
            UpdateExtent();
            UpdateSelectionBoxes();
            UpdateFocusBox();
            if (focus != (_selection.FocusRow, _selection.FocusColumn))
            {
                RaiseFocusChanged();
            }
        }
        if (_edit is { } edit && !Contains(edit.Row, edit.Column))
        {
            Cancel(EditorFocused);
        }
        _layoutVersion++;
        InvalidateRows();
        Follow(_viewX, _viewY);
        RaiseStatusChanges();
    }

    internal bool HandleEditorKey(VirtualKey key, bool control, bool shift)
    {
        if (_editor is null || _edit is not { } edit)
        {
            return false;
        }
        switch (key)
        {
            case VirtualKey.Escape:
                Cancel(refocus: true);
                return true;
            case VirtualKey.Enter when control || !_editor.AcceptsReturn:
                Commit(refocus: true);
                return true;
            case VirtualKey.Tab:
                // As NSTableView moves a field editor on: the next cell in the row is edited.
                var next = edit.Column + (shift ? -1 : 1);
                if (Commit(refocus: true) && Contains(edit.Row, next))
                {
                    SelectCell(edit.Row, next, extend: false);
                    BeginEditAfterKey();
                }
                return true;
            default:
                return false;
        }
    }

    // The key's character goes to whatever has focus once KeyDown returns, so the editor opens after it.
    private void BeginEditAfterKey()
    {
        var data = _data;
        var cell = (FocusedRow, FocusedColumn);
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!IsEditing && ReferenceEquals(data, _data) && cell == (FocusedRow, FocusedColumn))
            {
                BeginEdit();
            }
        });
    }

    internal RowMark MarkOf(int row) => _edited?.GetRowMark(row) ?? RowMark.None;

    // Read from the edits, not the cells, so a peer off screen fetches nothing.
    internal string CellStatus(int row, int column)
    {
        if (_edited is null || !Contains(row, column))
        {
            return string.Empty;
        }
        return _edited.GetRowMark(row) switch
        {
            RowMark.Deleted => DeletedStatus,
            RowMark.Inserted => NewRowStatus,
            RowMark.Modified when _edited.Edits.TryGetCell(row, column, out _) => EditedStatus,
            _ => string.Empty,
        };
    }

    // The TextBox shows its own menu for a request from inside it, which starts on a part of its template.
    public bool IsInEditor(object? source)
    {
        if (_editor is null)
        {
            return false;
        }
        for (var element = source as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
        {
            if (ReferenceEquals(element, _editor))
            {
                return true;
            }
        }
        return false;
    }

    internal UIElement? EditorIn(bool frozen) =>
        IsEditing && _editor is not null && ReferenceEquals(_editor.Parent, frozen ? _frozenWindow : _window)
            ? _editor
            : null;

    private void RaiseStatusChanges()
    {
        if (FrameworkElementAutomationPeer.FromElement(this) is DataGridAutomationPeer peer)
        {
            peer.RefreshStatuses(AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged));
        }
    }

    private bool Commit(bool refocus)
    {
        if (_editor is null || _edit is not { } edit)
        {
            return true;
        }
        if (_committing)
        {
            return false;
        }
        var text = EditorText(_editor);
        // Text the editor opened with is no change: a NULL cell stays NULL.
        if (string.Equals(text, _editText, StringComparison.Ordinal))
        {
            CloseEditor(refocus);
            return true;
        }
        var session = _editSession;
        var args = new GridEditCommittingEventArgs(edit.Row, edit.Column, text);
        _committing = true;
        try
        {
            CellEditCommitting?.Invoke(this, args);
        }
        finally
        {
            _committing = false;
        }
        if (session != _editSession || !IsEditing)
        {
            return true;
        }
        if (!string.IsNullOrEmpty(args.Error))
        {
            ShowEditError(args.Error);
            return false;
        }
        CloseEditor(refocus);
        return true;
    }

    private void Cancel(bool refocus)
    {
        if (IsEditing)
        {
            CloseEditor(refocus);
        }
    }

    // The editor closes either way, its ToolTip with it, so the host shows a refused commit's Error itself.
    private void CommitOrCancel(bool refocus)
    {
        if (!Commit(refocus))
        {
            Cancel(refocus);
        }
    }

    private void OpenEditor(int row, int column, string text)
    {
        var editor = _editor ??= CreateEditor();
        var window = column < _columns.FrozenCount ? _frozenWindow : _window;
        if (!ReferenceEquals(editor.Parent, window))
        {
            (editor.Parent as Panel)?.Children.Remove(editor);
            window.Children.Add(editor);
        }
        _editSession++;
        _edit = (row, column);
        ClearEditError();
        // Before the text: a TextBox that takes no returns keeps only the first line.
        editor.AcceptsReturn = text.AsSpan().IndexOfAny('\r', '\n') >= 0;
        _newline = text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n"
            : text.Contains('\n', StringComparison.Ordinal) ? "\n"
            : "\r";
        editor.Text = text;
        // What the TextBox holds, so a value with mixed line breaks opened and left is no change.
        _editText = EditorText(editor);
        AutomationProperties.SetName(editor, _names[column]);
        editor.Visibility = Visibility.Visible;
        PlaceEditor();
        if (editor.IsLoaded)
        {
            FocusEditor(editor);
        }
        else
        {
            editor.Loaded -= OnEditorLoaded;
            editor.Loaded += OnEditorLoaded;
        }
    }

    // A new editor, or one moved to the other pane, takes focus once it is in the tree.
    private void OnEditorLoaded(object sender, RoutedEventArgs e)
    {
        var editor = (TextBox)sender;
        editor.Loaded -= OnEditorLoaded;
        if (IsEditing)
        {
            FocusEditor(editor);
        }
    }

    private static void FocusEditor(TextBox editor)
    {
        editor.Focus(FocusState.Programmatic);
        editor.SelectAll();
    }

    // In the window the rows sit in, so it scrolls with them; called wherever the focus box moves.
    private void PlaceEditor()
    {
        if (_editor is null || _edit is not { } edit || !Contains(edit.Row, edit.Column))
        {
            return;
        }
        Canvas.SetLeft(_editor, _columns.PaneX(edit.Column));
        Canvas.SetTop(_editor, (edit.Row * _rowHeight) - _originY);
        _editor.Width = _columns.Width(edit.Column);
        if (_editor.AcceptsReturn)
        {
            _editor.Height = double.NaN;
            _editor.MinHeight = _rowHeight;
            _editor.MaxHeight = _rowHeight * EditorMaxRows;
        }
        else
        {
            _editor.Height = _rowHeight;
            _editor.MinHeight = 0;
            _editor.MaxHeight = double.PositiveInfinity;
        }
    }

    private void CloseEditor(bool refocus)
    {
        _edit = null;
        if (_editor is null)
        {
            return;
        }
        ClearEditError();
        // Before the editor hides, so the focus stays in the grid rather than moving on.
        if (refocus)
        {
            Focus(FocusState.Programmatic);
        }
        _editor.Visibility = Visibility.Collapsed;
        UpdateFocusBox();
    }

    // TextBox keeps a line break as CR; the value gets back the line break style it opened with.
    private string EditorText(TextBox editor)
    {
        var text = editor.Text;
        if (!editor.AcceptsReturn)
        {
            return text;
        }
        return text.Replace("\r\n", "\r", StringComparison.Ordinal).Replace('\n', '\r')
            .Replace("\r", _newline, StringComparison.Ordinal);
    }

    private TextBox CreateEditor()
    {
        var editor = new TextBox
        {
            FontFamily = new FontFamily(Painter.FamilyName),
            // TextBox scales its text with the text scale factor, as the painter's size already is.
            FontSize = BaseFontSize,
            MinWidth = 0,
            MinHeight = 0,
            TextWrapping = TextWrapping.NoWrap,
            Visibility = Visibility.Collapsed,
        };
        editor.PreviewKeyDown += OnEditorKeyDown;
        // Arrows and paging the TextBox leaves would reach the ScrollViewer around it and scroll the grid.
        editor.KeyDown += (_, e) => e.Handled |= e.Key is VirtualKey.Up or VirtualKey.Down or VirtualKey.Left
            or VirtualKey.Right or VirtualKey.PageUp or VirtualKey.PageDown or VirtualKey.Home or VirtualKey.End;
        editor.LostFocus += OnEditorLostFocus;
        // The grid has put the cell in view; for an editor in the frozen header the ScrollViewer would move too.
        editor.BringIntoViewRequested += (_, e) => e.Handled = true;
        return editor;
    }

    private void OnEditorKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (HandleEditorKey(e.Key, IsDown(VirtualKey.Control), IsDown(VirtualKey.Shift)))
        {
            e.Handled = true;
        }
    }

    // Focus moving to the editor's own menus comes back.
    private void OnEditorLostFocus(object sender, RoutedEventArgs e)
    {
        if (_editor is null || !IsEditing || EditorFocused
            || _editor.ContextFlyout is { IsOpen: true } || _editor.SelectionFlyout is { IsOpen: true })
        {
            return;
        }
        CommitOrCancel(refocus: false);
    }

    private void ShowEditError(string error)
    {
        if (_editor is null)
        {
            return;
        }
        var tip = _editorTip ??= new ToolTip();
        tip.Content = error;
        ToolTipService.SetToolTip(_editor, tip);
        tip.IsOpen = true;
        AutomationProperties.SetFullDescription(_editor, error);
        // The focus stays in the editor, so a screen reader hears the error only from this.
        FrameworkElementAutomationPeer.FromElement(_editor)?.RaiseNotificationEvent(AutomationNotificationKind.ActionAborted,
            AutomationNotificationProcessing.ImportantMostRecent, error, "TablePro.DataGrid.EditRefused");
    }

    private void ClearEditError()
    {
        if (_editor is null)
        {
            return;
        }
        if (_editorTip is not null)
        {
            _editorTip.IsOpen = false;
        }
        ToolTipService.SetToolTip(_editor, null);
        AutomationProperties.SetFullDescription(_editor, string.Empty);
    }
}

public sealed class GridEditStartingEventArgs(int row, int column, string text) : EventArgs
{
    public int Row { get; } = row;

    public int Column { get; } = column;

    // The editor's text: the cell's whole value until the host sets it.
    public string Text { get; set; } = text;

    public bool Cancel { get; set; }
}

public sealed class GridEditCommittingEventArgs(int row, int column, string text) : EventArgs
{
    public int Row { get; } = row;

    public int Column { get; } = column;

    public string Text { get; } = text;

    // Set to refuse the text: the editor stays open and shows it.
    public string? Error { get; set; }
}
