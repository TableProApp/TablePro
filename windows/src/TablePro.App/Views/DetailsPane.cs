using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.Interop;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TablePro.App.Views;

// A table tab's side pane, as macOS's inspector: the focused row's fields, each edited as its cell in the grid
// would be, and the table's own figures.
internal sealed partial class DetailsPane : UserControl
{
    private readonly TableTab _model;
    private readonly DataGridView _grid;
    private readonly Func<EditRefusal, string?> _refusalText;
    private readonly SelectorBar _views = new() { Margin = new Thickness(4, 0, 4, 0) };
    private readonly SelectorBarItem _rowItem = new() { IsSelected = true };
    private readonly SelectorBarItem _tableItem = new();
    private readonly StackPanel _rowPanel = new() { Spacing = 12, Padding = new Thickness(12, 4, 12, 12) };
    private readonly StackPanel _tablePanel = new() { Spacing = 12, Padding = new Thickness(12, 4, 12, 12) };
    private readonly ScrollViewer _scroller = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly List<FieldEntry> _entries = [];
    private int _shownRow = -1;
    private bool _refreshQueued;
    private int _infoReads;
    private TextBlock? _rowStatus;

    // Longer values open read only and whole in View value: a wrapping TextBox lays out every character it holds.
    private const int FieldCharacters = 10_000;

    public DetailsPane(TableTab model, DataGridView grid, Func<EditRefusal, string?> refusalText)
    {
        _model = model;
        _grid = grid;
        _refusalText = refusalText;
        Width = 320;
        AutomationProperties.SetAutomationId(this, "DetailsPane");
        AutomationProperties.SetName(this, Strings.Get("DetailsPaneName"));
        _rowItem.Text = Strings.Get("DetailsRowView");
        _tableItem.Text = Strings.Get("DetailsTableView");
        AutomationProperties.SetAutomationId(_rowItem, "DetailsRowView");
        AutomationProperties.SetAutomationId(_tableItem, "DetailsTableView");
        AutomationProperties.SetAutomationId(_views, "DetailsViews");
        _views.Items.Add(_rowItem);
        _views.Items.Add(_tableItem);
        _views.SelectionChanged += (_, _) => ShowView();
        _scroller.Content = _rowPanel;
        var root = new Grid
        {
            BorderBrush = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
            BorderThickness = new Thickness(1, 0, 0, 0),
        };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(_scroller, 1);
        root.Children.Add(_views);
        root.Children.Add(_scroller);
        Content = root;
        grid.FocusedCellChanged += (_, _) => QueueRefresh();
        model.StateChanged += (_, _) => QueueRefresh();
        model.ShownRowsChanged += (_, _) => QueueRefresh(rowsChanged: true);
    }

    // A field's text typed and not kept yet, which the tab counts as an open edit as it counts the grid's editor.
    public event EventHandler? DraftChanged;

    public bool HasDraft => _entries.Any(entry => entry.Changed);

    public CellDraft? Draft =>
        _entries.FirstOrDefault(entry => entry.Changed) is { } entry
            ? new CellDraft(entry.Row, entry.Field.Column, entry.Text)
            : null;

    private bool ShowsTable => ReferenceEquals(_views.SelectedItem, _tableItem);

    // Keeps what each field holds, as a save, a reload or a close keeps the grid's open editor first.
    public bool CommitDraft() => _entries.Where(entry => entry.Changed).ToList().All(Commit);

    // Discard was confirmed: what each field holds goes back to the value, a refused one too.
    public void CancelDraft()
    {
        foreach (var entry in _entries.Where(entry => entry.Changed))
        {
            entry.Box.Text = entry.Field.Text ?? string.Empty;
            entry.Box.Description = null;
        }

        _shownRow = -1;
        QueueRefresh();
    }

    public void Show()
    {
        _shownRow = -1;
        ShowView();
    }

    // After a refresh, the figures are stale with the rows.
    public void Reload()
    {
        if (ShowsTable && Visibility == Visibility.Visible)
        {
            LoadInfo(refresh: false);
        }
    }

    private void ShowView()
    {
        if (ShowsTable)
        {
            _scroller.Content = _tablePanel;
            LoadInfo(refresh: false);
        }
        else
        {
            _scroller.Content = _rowPanel;
            _shownRow = -1;
            RefreshRow();
        }
    }

    // Edits and focus moves come in bursts, so the fields are built once after them.
    private void QueueRefresh(bool rowsChanged = false)
    {
        if (rowsChanged)
        {
            _shownRow = -1;
        }

        if (_refreshQueued || Visibility != Visibility.Visible || ShowsTable)
        {
            return;
        }

        _refreshQueued = true;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            _refreshQueued = false;
            RefreshRow();
        });
    }

    // The same row's fields are updated in place, so the focus and a field being typed in stay; another row's are
    // built anew.
    private void RefreshRow()
    {
        if (Visibility != Visibility.Visible || ShowsTable || _model.IsClosed)
        {
            return;
        }

        var row = _grid.RowCount > 0 ? _grid.FocusedRow : -1;
        var fields = row >= 0 ? _model.FieldsAt(row, FieldCharacters) : [];
        if (row == _shownRow && _rowStatus is { } shownStatus && fields.Count == _entries.Count
            && fields.Select(field => field.Column).SequenceEqual(_entries.Select(entry => entry.Field.Column)))
        {
            shownStatus.Text = RowStatus(row);
            for (var index = 0; index < fields.Count; index++)
            {
                var entry = _entries[index];
                if (!entry.Changed)
                {
                    entry.Show(fields[index]);
                }

                entry.Box.IsReadOnly = !Editable(entry);
                ShowMark(entry);
            }

            return;
        }

        _shownRow = row;
        _rowPanel.Children.Clear();
        _entries.Clear();
        _rowStatus = null;
        if (fields.Count == 0)
        {
            _rowPanel.Children.Add(Note(Strings.Get("DetailsNoRow")));
            return;
        }

        var status = new TextBlock
        {
            Text = RowStatus(row),
            Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
        };
        AutomationProperties.SetAutomationId(status, "DetailsRowStatus");
        AutomationProperties.SetHeadingLevel(status, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        _rowStatus = status;
        _rowPanel.Children.Add(status);
        foreach (var field in fields)
        {
            _rowPanel.Children.Add(FieldView(row, field));
        }
    }

    private string RowStatus(int row) => _model.Edits switch
    {
        { } edits when edits.IsAdded(row) => Strings.Get("DetailsNewRow"),
        { } edits when edits.IsDeleted(row) => Strings.Get("DetailsDeletedRow"),
        _ => Strings.Format("DetailsRowNumber", _model.Page.Offset + row + 1),
    };

    private StackPanel FieldView(int row, RowField field)
    {
        var name = new TextBlock
        {
            Text = field.Name,
            Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var type = new TextBlock
        {
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            VerticalAlignment = VerticalAlignment.Center,
        };
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        title.Children.Add(name);
        title.Children.Add(type);

        // Multi-line before the text: a single-line TextBox keeps only a value's first line.
        var box = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MaxHeight = 200,
            IsSpellCheckEnabled = false,
        };
        var entry = new FieldEntry(row, box, type);
        entry.Show(field);
        _entries.Add(entry);
        box.IsReadOnly = !Editable(entry);
        ShowMark(entry);
        AutomationProperties.SetName(box, field.Name);
        var id = field.Column.ToString(CultureInfo.InvariantCulture);
        AutomationProperties.SetAutomationId(box, "DetailsField_" + id);

        box.TextChanged += (_, _) => DraftChanged?.Invoke(this, EventArgs.Empty);
        box.LostFocus += (_, _) => Commit(entry);
        box.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Escape && !box.IsReadOnly && entry.Changed)
            {
                e.Handled = true;
                box.Text = entry.Field.Text ?? string.Empty;
                box.Description = null;
            }
            else if (e.Key == VirtualKey.Enter && Microsoft.UI.Input.InputKeyboardSource
                .GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down))
            {
                e.Handled = true;
                Commit(entry);
            }
        };

        var more = new Button
        {
            Content = new SymbolIcon(Symbol.More),
            VerticalAlignment = VerticalAlignment.Top,
            Flyout = FieldMenu(entry),
        };
        AutomationProperties.SetName(more, Strings.Format("DetailsFieldMenu", field.Name));
        AutomationProperties.SetAutomationId(more, "DetailsFieldMenu_" + id);
        var line = new Grid { ColumnSpacing = 4 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(more, 1);
        line.Children.Add(box);
        line.Children.Add(more);

        var view = new StackPanel { Spacing = 4 };
        view.Children.Add(title);
        view.Children.Add(line);
        return view;
    }

    // A data row's field with a pending value says so; a new row's are all new.
    private void ShowMark(FieldEntry entry)
    {
        var edited = _model.Edits is { } edits && !edits.IsAdded(entry.Row)
            && edits.GetCell(entry.Row, entry.Field.Column) is not null;
        entry.Type.Text = edited ? Strings.Format("DetailsTypeEdited", entry.Field.TypeName) : entry.Field.TypeName;
        entry.Type.Foreground = (Brush)Application.Current.Resources[
            edited ? "AccentTextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"];
    }

    // Kept in place, so the field the focus moved to, or this one after Ctrl+Enter, stays as it is. False when the
    // value was refused, which the field then says.
    private bool Commit(FieldEntry entry)
    {
        var box = entry.Box;
        if (!entry.Changed)
        {
            box.Description = null;
            return true;
        }

        // The grid's own editor keeps its text first, so two edits of one cell cannot cross.
        if (!_grid.CommitEdit())
        {
            return false;
        }

        var text = entry.Text;
        if (_model.CommitEdit(entry.Row, entry.Field.Column, text) is { } refusal)
        {
            box.Description = _refusalText(refusal) ?? Strings.Get("EditCellReadOnly");
            return false;
        }

        box.Description = null;
        entry.Keep(text);
        ShowMark(entry);
        DraftChanged?.Invoke(this, EventArgs.Empty);
        return true;
    }

    // Read as it opens, so it acts on what the field holds now, a value just kept included.
    private MenuFlyout FieldMenu(FieldEntry entry)
    {
        var menu = new MenuFlyout();
        var values = new[]
        {
            ValueItem("GridMenuEmpty", entry, CellValueKind.Empty),
            ValueItem("GridMenuNull", entry, CellValueKind.Null),
            ValueItem("GridMenuDefault", entry, CellValueKind.Default),
        };
        foreach (var (item, _) in values)
        {
            menu.Items.Add(item);
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        var copy = new MenuFlyoutItem { Text = Strings.Get("DetailsCopyValue"), Icon = new SymbolIcon(Symbol.Copy) };
        copy.Click += (_, _) =>
        {
            var package = new DataPackage();
            package.SetText(entry.Shown ?? string.Empty);
            Clipboard.SetContent(package);
            Clipboard.Flush();
        };
        menu.Items.Add(copy);
        menu.Opening += (_, _) =>
        {
            foreach (var (item, kind) in values)
            {
                item.IsEnabled = Editable(entry) && _model.CanSetValue(entry.Row, entry.Field.Column, kind);
            }

            copy.IsEnabled = entry.Shown is not null && !entry.Field.TextCut;
        };
        return menu;
    }

    private (MenuFlyoutItem Item, CellValueKind Kind) ValueItem(string text, FieldEntry entry, CellValueKind kind)
    {
        var item = new MenuFlyoutItem { Text = Strings.Get(text) };
        item.Click += (_, _) =>
        {
            if (_grid.CommitEdit() && _model.SetValue(entry.Row, entry.Field.Column, kind) is null)
            {
                _shownRow = -1;
                QueueRefresh();
            }
        };
        return (item, kind);
    }

    // As the tab allows now: a save or a reload under way takes edits from every field, the focused one too.
    private bool Editable(FieldEntry entry) => entry.Field.CanEdit && !entry.Field.TextCut && _model.CanEdit;

    private TextBox? FocusedBox() =>
        XamlRoot is { } root && FocusManager.GetFocusedElement(root) is TextBox box && IsInside(box) ? box : null;

    private bool IsInside(DependencyObject element)
    {
        for (var node = element; node is not null; node = VisualTreeHelper.GetParent(node))
        {
            if (ReferenceEquals(node, this))
            {
                return true;
            }
        }

        return false;
    }

    // A read a refresh overtook answers last with the older figures, so only the newest read shows.
    private async void LoadInfo(bool refresh)
    {
        var reading = ++_infoReads;
        ShowInfo(_model.Info, loading: true);
        var info = await _model.LoadInfoAsync(refresh).ConfigureAwait(true);
        if (reading == _infoReads)
        {
            ShowInfo(info, loading: false);
        }
    }

    // A figure the engine keeps none of says so, rather than leaving a gap.
    private void ShowInfo(TableInfo? info, bool loading)
    {
        _tablePanel.Children.Clear();
        if (info is null)
        {
            _tablePanel.Children.Add(Note(Strings.Get(loading ? "DetailsTableLoading" : "DetailsTableUnavailable")));
            return;
        }

        var none = Strings.Get("DetailsNotKept");
        string Size(long? bytes) => bytes is { } value ? ByteSize.Format(value, Strings.Get("DetailsBytes")) : none;
        var rows = info.Rows is { } estimate
            ? Strings.Format(estimate.IsExact ? "DetailsRowsExact" : "DetailsRowsAbout", estimate.Rows)
            : none;
        _tablePanel.Children.Add(Figure("DetailsRows", rows, "DetailsRowsValue"));
        _tablePanel.Children.Add(Figure("DetailsDataSize", Size(info.DataBytes), "DetailsDataSizeValue"));
        _tablePanel.Children.Add(Figure("DetailsIndexSize", Size(info.IndexBytes), "DetailsIndexSizeValue"));
        _tablePanel.Children.Add(Figure("DetailsTotalSize", Size(info.TotalBytes), "DetailsTotalSizeValue"));
        _tablePanel.Children.Add(Figure("DetailsComment", info.Comment ?? none, "DetailsCommentValue"));
    }

    private static StackPanel Figure(string label, string value, string automationId)
    {
        var title = new TextBlock
        {
            Text = Strings.Get(label),
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        };
        var text = new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        AutomationProperties.SetAutomationId(text, automationId);
        AutomationProperties.SetName(text, $"{title.Text}: {value}");
        var figure = new StackPanel { Spacing = 2 };
        figure.Children.Add(title);
        figure.Children.Add(text);
        return figure;
    }

    private static TextBlock Note(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
    };

    private sealed class FieldEntry(int row, TextBox box, TextBlock type)
    {
        private string _newline = "\n";
        private string _kept = string.Empty;

        public int Row => row;

        public RowField Field { get; private set; } = null!;

        public TextBox Box => box;

        public TextBlock Type => type;

        // With the line breaks the value had, which a TextBox turns into CR.
        public string Text => LineBreaks.Restore(box.Text, _newline);

        // An empty box over NULL or DEFAULT is no edit: Set to Empty makes one.
        public bool Changed => !box.IsReadOnly && !string.Equals(Text, _kept, StringComparison.Ordinal)
            && !(Field.Text is null && box.Text.Length == 0);

        // What Copy takes: the text typed, else the value.
        public string? Shown => Changed ? Text : Field.Text;

        // A NUL would end the TextBox's text, so it shows as the symbol for one, in a field that is read only.
        public void Show(RowField field)
        {
            Field = field;
            _newline = LineBreaks.Of(field.Text);
            var text = (field.Text ?? string.Empty).Replace('\0', '\u2400');
            // Set only when it differs, so a field holding the focus keeps its caret.
            if (!string.Equals(LineBreaks.Restore(box.Text, _newline), text, StringComparison.Ordinal))
            {
                box.Text = text;
            }

            _kept = LineBreaks.Restore(box.Text, _newline);
            box.PlaceholderText = field.IsDefault ? Strings.Get("GridDefaultText")
                : field.IsNull ? Strings.Get("DetailsNullText")
                : string.Empty;
            ToolTipService.SetToolTip(box, field.TextCut ? Strings.Get("DetailsTextCut") : null);
        }

        public void Keep(string text)
        {
            _kept = text;
            Field = Field with { Text = text, IsDefault = false };
        }
    }
}
