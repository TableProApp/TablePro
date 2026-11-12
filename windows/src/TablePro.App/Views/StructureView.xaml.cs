using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Interop;
using Windows.ApplicationModel.DataTransfer;

namespace TablePro.App.Views;

// A table's columns, indexes, foreign keys and CREATE script, read through its tab and shown read only, as on macOS.
public sealed partial class StructureView : UserControl
{
    private static readonly string[] ColumnHeaders =
    [
        "StructureHeaderName",
        "StructureHeaderType",
        "StructureHeaderNullable",
        "StructureHeaderDefault",
        "StructureHeaderPrimaryKey",
        "StructureHeaderAutoIncrement",
        "StructureHeaderComment",
    ];

    private static readonly string[] IndexHeaders =
    [
        "StructureHeaderName",
        "StructureHeaderColumns",
        "StructureHeaderUnique",
        "StructureHeaderCondition",
    ];

    private static readonly string[] ForeignKeyHeaders =
    [
        "StructureHeaderName",
        "StructureHeaderColumns",
        "StructureHeaderRefTable",
        "StructureHeaderRefColumns",
        "StructureHeaderRefSchema",
        "StructureHeaderOnDelete",
        "StructureHeaderOnUpdate",
    ];

    private readonly TableTab _tab;
    private TableStructure? _shown;
    private Section _section;
    private int _reading;
    private string[] _headers = [];
    private List<string?[]> _rows = [];

    internal StructureView(TableTab tab)
    {
        InitializeComponent();
        _tab = tab;
        StructureGrid.SizeColumnsToContent = true;
        StructureGrid.SortedAscendingStatus = Strings.Get("GridSortedAscending");
        StructureGrid.SortedDescendingStatus = Strings.Get("GridSortedDescending");
        // The rows are held here, so a header click sorts them here, as the macOS structure grid sorts.
        StructureGrid.SortRequested += (_, sort) => ShowRows(sort);
    }

    private enum Section
    {
        Columns,
        Indexes,
        ForeignKeys,
        Ddl,
    }

    internal DataGridView Grid => StructureGrid;

    // The script while it shows, so Copy and Select All in the Edit menu reach it.
    internal TextBox? TextTarget => DdlText.Visibility == Visibility.Visible ? DdlText : null;

    // Reads that overlap share one in the tab; only the last asked for is shown.
    internal async Task LoadAsync(bool refresh)
    {
        var reading = ++_reading;
        ErrorBar.IsOpen = false;
        RefreshButton.IsEnabled = false;
        ShowLoading(_shown is null);
        var structure = await _tab.LoadStructureAsync(refresh).ConfigureAwait(true);
        if (reading != _reading)
        {
            return;
        }

        RefreshButton.IsEnabled = true;
        ShowLoading(false);
        // Null when the read failed, which ShowFailure says, or the tab closed.
        if (structure is null)
        {
            return;
        }

        // An older read that failed while this one ran said so; this one stands.
        ErrorBar.IsOpen = false;
        if (!ReferenceEquals(structure, _shown))
        {
            _shown = structure;
            ShowSection();
        }
    }

    // What was shown before stays under the bar.
    internal void ShowFailure(CoreError failure)
    {
        ShowLoading(false);
        ErrorBar.Message = Strings.Error(failure);
        // Narrator reads an InfoBar when it opens, not when its text changes.
        ErrorBar.IsOpen = false;
        ErrorBar.IsOpen = true;
    }

    internal void FocusContent()
    {
        if (DdlText.Visibility == Visibility.Visible)
        {
            DdlText.Focus(FocusState.Programmatic);
        }
        else if (StructureGrid.Visibility == Visibility.Visible)
        {
            StructureGrid.Focus(FocusState.Programmatic);
        }
        else
        {
            Sections.Focus(FocusState.Programmatic);
        }
    }

    // Empty where the server gave no default, comment, condition or action, since the grid words a null cell NULL.
    private static (string[] Headers, List<string?[]> Rows, string Empty) ListFor(
        TableStructure structure,
        Section section) => section switch
        {
            Section.Indexes => (
                Headers(IndexHeaders),
                structure.Indexes.Select(index => Row(
                    index.Name,
                    string.Join(", ", index.Keys),
                    YesNo(index.Unique),
                    index.Predicate ?? string.Empty)).ToList(),
                Strings.Get("StructureNoIndexes")),
            Section.ForeignKeys => (
                Headers(ForeignKeyHeaders),
                structure.ForeignKeys.Select(key => Row(
                    key.Name,
                    string.Join(", ", key.Columns),
                    key.ReferencedTable,
                    string.Join(", ", key.ReferencedColumns),
                    key.ReferencedSchema ?? string.Empty,
                    key.OnDelete ?? string.Empty,
                    key.OnUpdate ?? string.Empty)).ToList(),
                Strings.Get("StructureNoForeignKeys")),
            _ => (
                Headers(ColumnHeaders),
                structure.Columns.Select(column => Row(
                    column.Name,
                    column.TypeName,
                    YesNo(column.Nullable),
                    column.DefaultValue ?? string.Empty,
                    YesNo(column.PrimaryKey),
                    YesNo(column.AutoIncrement),
                    column.Comment ?? string.Empty)).ToList(),
                Strings.Get("StructureNoColumns")),
        };

    private static string[] Headers(string[] names) => [.. names.Select(Strings.Get)];

    private static string?[] Row(params string?[] cells) => cells;

    private static string YesNo(bool value) => Strings.Get(value ? "StructureYes" : "StructureNo");

    private void ShowSection()
    {
        CopyButton.Visibility = Visibility.Collapsed;
        if (_shown is not { } structure)
        {
            return;
        }

        if (_section == Section.Ddl)
        {
            // The grid lets go of its rows, so a copy from the menu cannot reach a list no longer shown.
            StructureGrid.SetData(null);
            StructureGrid.Visibility = Visibility.Collapsed;
            DdlText.Text = structure.Ddl ?? string.Empty;
            DdlText.Visibility = structure.Ddl is null ? Visibility.Collapsed : Visibility.Visible;
            CopyButton.Visibility = DdlText.Visibility;
            ShowEmpty(structure.Ddl is null ? Strings.Get("StructureNoDdl") : null);
            return;
        }

        DdlText.Visibility = Visibility.Collapsed;
        var (headers, rows, empty) = ListFor(structure, _section);
        _headers = headers;
        _rows = rows;
        if (rows.Count == 0)
        {
            StructureGrid.SetData(null);
            StructureGrid.Visibility = Visibility.Collapsed;
            ShowEmpty(empty);
            return;
        }

        ShowEmpty(null);
        StructureGrid.Visibility = Visibility.Visible;
        ShowRows(GridSort.None);
    }

    // The grid keeps its column widths across a sort, since the headers stay the same.
    private void ShowRows(GridSort sort)
    {
        IEnumerable<string?[]> rows = _rows;
        if (sort.Direction != SortDirection.None && sort.Column >= 0 && sort.Column < _headers.Length)
        {
            var column = sort.Column;
            rows = sort.Direction == SortDirection.Ascending
                ? _rows.OrderBy(row => row[column], StringComparer.CurrentCultureIgnoreCase)
                : _rows.OrderByDescending(row => row[column], StringComparer.CurrentCultureIgnoreCase);
        }

        StructureGrid.SetData(new TextGridData(_headers, [.. rows]));
        StructureGrid.Sort = sort;
    }

    private void ShowEmpty(string? text)
    {
        EmptyText.Text = text ?? string.Empty;
        EmptyText.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ShowLoading(bool loading)
    {
        LoadingRing.IsActive = loading;
        LoadingRing.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnSectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var item = sender.SelectedItem;
        if (item is null)
        {
            return;
        }

        Section section;
        if (ReferenceEquals(item, IndexesItem))
        {
            section = Section.Indexes;
        }
        else if (ReferenceEquals(item, ForeignKeysItem))
        {
            section = Section.ForeignKeys;
        }
        else if (ReferenceEquals(item, DdlItem))
        {
            section = Section.Ddl;
        }
        else
        {
            section = Section.Columns;
        }

        if (section != _section)
        {
            _section = section;
            ShowSection();
        }
    }

    private void OnCopyDdl(object sender, RoutedEventArgs e)
    {
        if (_shown?.Ddl is not { } ddl)
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(ddl);
        try
        {
            Clipboard.SetContent(package);
            Clipboard.Flush();
        }
        catch (COMException)
        {
            // Another program holds the clipboard open; pressing the button again copies once it lets go.
        }
    }

    private async void OnRefresh(object sender, RoutedEventArgs e) =>
        await LoadAsync(refresh: true).ConfigureAwait(true);

    private async void OnRetry(object sender, RoutedEventArgs e) =>
        await LoadAsync(refresh: true).ConfigureAwait(true);
}
