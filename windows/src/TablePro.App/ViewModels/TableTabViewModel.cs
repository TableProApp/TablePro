using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using TablePro.App.Controls.DataGrid;
using TablePro.App.Services;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.App.ViewModels;

public enum TableTabSection
{
    Data,
    Structure,
    Definition,
}

/// <summary>One editable filter row of the filter strip.</summary>
public sealed partial class FilterRuleViewModel(IReadOnlyList<string> columns) : ObservableObject
{
    public static IReadOnlyList<FilterOperator> AllOperators { get; } = Enum.GetValues<FilterOperator>();

    public IReadOnlyList<string> Columns { get; } = columns;

    public IReadOnlyList<FilterOperator> Operators => AllOperators;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ColumnItem))]
    public partial string? Column { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(OperatorItem))]
    public partial FilterOperator Operator { get; set; } = FilterOperator.Contains;

    // ComboBox selections are objects; these adapters let compiled bindings stay two-way without a converter.
    public object? ColumnItem
    {
        get => Column;
        set => Column = value as string;
    }

    public object OperatorItem
    {
        get => Operator;
        set
        {
            if (value is FilterOperator op)
            {
                Operator = op;
            }
        }
    }

    [ObservableProperty]
    public partial string? Value { get; set; }

    [ObservableProperty]
    public partial string? SecondValue { get; set; }

    [ObservableProperty]
    public partial bool Enabled { get; set; } = true;

    public FilterRule ToRule() => new(Column == AllColumns ? null : Column, Operator, Value, SecondValue, Enabled);

    public const string AllColumns = "Any column";
}

/// <summary>
/// A table or view tab: pages of rows from the server with filters and sorting, edits held in a buffer until saved,
/// and the structure and definition of the object.
/// </summary>
public sealed partial class TableTabViewModel : TabViewModel
{
    private readonly WorkspaceContext _context;
    private CancellationTokenSource? _load;
    private TableEditBuffer? _buffer;

    public TableTabViewModel(WorkspaceContext context, DatabaseObject table)
    {
        _context = context;
        Table = table;
        Title = table.Name.Name;
        Subtitle = table.Name.Schema;
        PageSize = context.Preferences.BrowsePageSize;
    }

    public DatabaseObject Table { get; }

    public WorkspaceContext Context => _context;

    public ObservableCollection<FilterRuleViewModel> Filters { get; } = [];

    public ObservableCollection<string> FilterColumns { get; } = [FilterRuleViewModel.AllColumns];


    public List<SortColumn> Sort { get; } = [];

    public override string Glyph => Table.Kind == ObjectKind.Table ? "" : "";

    [ObservableProperty]
    public partial TableTabSection Section { get; set; }

    [ObservableProperty]
    public partial IGridSource? Rows { get; set; }

    [ObservableProperty]
    public partial TableStructure? Structure { get; set; }

    [ObservableProperty]
    public partial IGridSource? ColumnsGrid { get; set; }

    [ObservableProperty]
    public partial IGridSource? IndexesGrid { get; set; }

    [ObservableProperty]
    public partial IGridSource? ForeignKeysGrid { get; set; }

    [ObservableProperty]
    public partial IGridSource? TriggersGrid { get; set; }

    [ObservableProperty]
    public partial string Definition { get; set; } = string.Empty;

    [ObservableProperty]
    public partial string? RawWhere { get; set; }

    [ObservableProperty]
    public partial bool MatchAllFilters { get; set; } = true;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PageText))]
    public partial int Offset { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PageText))]
    public partial int PageSize { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PageText))]
    public partial long? TotalRows { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PageText))]
    public partial int LoadedRows { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SaveText))]
    [NotifyCanExecuteChangedFor(nameof(SaveCommand), nameof(DiscardCommand))]
    public partial int PendingChanges { get; set; }

    [ObservableProperty]
    public partial bool IsEditable { get; set; }

    [ObservableProperty]
    public partial string? ReadOnlyReason { get; set; }

    public bool HasPendingChanges => PendingChanges > 0;

    public string SaveText => PendingChanges == 0 ? "Save" : string.Create(CultureInfo.CurrentCulture, $"Save {PendingChanges:N0}");

    public string PageText
    {
        get
        {
            if (LoadedRows == 0)
            {
                return TotalRows is 0 ? "No rows" : "No rows on this page";
            }

            var first = Offset + 1;
            var last = Offset + LoadedRows;
            return TotalRows is { } total
                ? string.Create(CultureInfo.CurrentCulture, $"{first:N0}–{last:N0} of {total:N0}")
                : string.Create(CultureInfo.CurrentCulture, $"{first:N0}–{last:N0}");
        }
    }

    public override string? UnsavedWork => PendingChanges > 0 ? $"{Title} has {PendingChanges} unsaved changes." : null;

    public TableEditBuffer? Buffer => _buffer;

    public async Task InitializeAsync()
    {
        await LoadStructureAsync(refresh: false);
        await LoadAsync();
    }

    [RelayCommand]
    public async Task LoadAsync()
    {
        if (PendingChanges > 0 && !await _context.Dialogs.ConfirmAsync("Discard changes?", $"Reloading drops {PendingChanges} unsaved changes.", "Discard", destructive: true))
        {
            return;
        }

        _load?.Cancel();
        _load = new CancellationTokenSource();
        var token = _load.Token;
        IsBusy = true;
        StatusText = "Loading…";
        try
        {
            var filter = BuildFilter();
            var request = new BrowseRequest(Table.Name, filter, Sort.ToArray(), Offset, PageSize);
            var rowsTask = _context.Session.Database.BrowseAsync(request, token);
            var countTask = _context.Session.Database.CountAsync(Table.Name, filter, token);
            var result = await rowsTask;
            if (token.IsCancellationRequested)
            {
                return;
            }

            AttachBuffer(result);
            LoadedRows = result.RowCount;
            StatusText = null;
            try
            {
                TotalRows = await countTask;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // A count can time out on a huge table; the page is still useful without it.
                TotalRows = null;
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            StatusText = ex.Message;
            await _context.Dialogs.ShowErrorAsync($"Could not load {Title}", ex.Message);
        }
        finally
        {
            IsBusy = false;
        }
    }

    public async Task SortByAsync(int column, bool addToExisting)
    {
        if (Rows is null || column < 0 || column >= Rows.Columns.Count)
        {
            return;
        }

        var name = Rows.Columns[column].Name;
        var existing = Sort.FindIndex(s => s.Column == name);

        // Each click cycles one column through ascending, descending and unsorted.
        SortColumn? next = existing < 0 ? new SortColumn(name, false) : Sort[existing].Descending ? null : new SortColumn(name, true);
        if (!addToExisting)
        {
            Sort.Clear();
        }
        else if (existing >= 0)
        {
            Sort.RemoveAt(existing);
        }

        if (next is { } sort)
        {
            Sort.Add(sort);
        }

        Offset = 0;
        await LoadAsync();
    }

    public IReadOnlyList<(int Column, bool Descending)> SortIndicators =>
        Rows is null ? [] : Sort.Select(s => (Rows.Columns.ToList().FindIndex(c => c.Name == s.Column), s.Descending)).Where(s => s.Item1 >= 0).ToArray();

    [RelayCommand]
    private async Task NextPageAsync()
    {
        if (LoadedRows < PageSize)
        {
            return;
        }

        Offset += PageSize;
        await LoadAsync();
    }

    [RelayCommand]
    private async Task PreviousPageAsync()
    {
        if (Offset == 0)
        {
            return;
        }

        Offset = Math.Max(0, Offset - PageSize);
        await LoadAsync();
    }

    [RelayCommand]
    private async Task FirstPageAsync()
    {
        Offset = 0;
        await LoadAsync();
    }

    [RelayCommand]
    private async Task LastPageAsync()
    {
        if (TotalRows is not { } total || total == 0)
        {
            return;
        }

        Offset = (int)Math.Max(0, (total - 1) / PageSize * PageSize);
        await LoadAsync();
    }

    [RelayCommand]
    private void AddFilter() => Filters.Add(new FilterRuleViewModel(FilterColumns) { Column = FilterRuleViewModel.AllColumns });

    [RelayCommand]
    private void RemoveFilter(FilterRuleViewModel rule) => Filters.Remove(rule);

    [RelayCommand]
    private async Task ApplyFiltersAsync()
    {
        Offset = 0;
        await LoadAsync();
    }

    [RelayCommand]
    private async Task ClearFiltersAsync()
    {
        Filters.Clear();
        RawWhere = null;
        Offset = 0;
        await LoadAsync();
    }

    /// <summary>Adds an equality filter from a grid cell, as the macOS grid's "Filter by this value" does.</summary>
    public async Task FilterByValueAsync(int row, int column, bool exclude)
    {
        if (Rows is null)
        {
            return;
        }

        var value = Rows.GetValue(row, column);
        Filters.Add(new FilterRuleViewModel(FilterColumns)
        {
            Column = Rows.Columns[column].Name,
            Operator = value is null ? (exclude ? FilterOperator.IsNotNull : FilterOperator.IsNull) : (exclude ? FilterOperator.NotEquals : FilterOperator.Equals),
            Value = value is null ? null : CellFormatter.Format(value),
        });
        Offset = 0;
        await LoadAsync();
    }

    [RelayCommand]
    public void AddRow()
    {
        if (_buffer is not null && IsEditable)
        {
            _buffer.InsertRow();
        }
    }

    public void DuplicateRow(int row)
    {
        if (_buffer is not null && IsEditable)
        {
            _buffer.DuplicateRow(row);
        }
    }

    public void ToggleDeleteRows(IReadOnlyList<int> rows)
    {
        if (_buffer is not null && IsEditable && rows.Count > 0)
        {
            _buffer.ToggleDelete(rows);
        }
    }

    [RelayCommand]
    public void Undo() => _buffer?.Undo();

    [RelayCommand]
    public void Redo() => _buffer?.Redo();

    [RelayCommand(CanExecute = nameof(HasPendingChanges))]
    public async Task SaveAsync()
    {
        if (_buffer is null || !_buffer.HasChanges)
        {
            return;
        }

        var changes = _buffer.BuildChanges();
        var profile = _context.Session.Profile;
        if (profile.SafeMode.BlocksAllWrites())
        {
            await _context.Dialogs.ShowErrorAsync("Read-only connection", "Safe Mode is Read-Only on this connection, so edits cannot be saved.");
            return;
        }

        var preview = changes.Select(c => ChangeSqlBuilder.Preview(_context.Session.Dialect, Table.Name, c)).ToArray();
        if (profile.SafeMode.RequiresConfirmation() && !await _context.Dialogs.ReviewSqlAsync("Save changes", preview, "Save"))
        {
            return;
        }

        IsBusy = true;
        StatusText = "Saving…";
        var started = DateTime.UtcNow;
        try
        {
            var affected = await _context.Session.Database.SaveChangesAsync(Table.Name, changes, CancellationToken.None);
            foreach (var statement in preview)
            {
                _context.History.Record(profile, _context.Session.Database.CurrentDatabase, new StatementResult(statement, [], 1, DateTime.UtcNow - started), StatementKind.Write, "grid");
            }

            _buffer.Discard();
            _context.Notify(string.Create(CultureInfo.CurrentCulture, $"Saved {changes.Count:N0} changes ({affected:N0} rows)."));
            await LoadAsync();
        }
        catch (Exception ex)
        {
            StatusText = ex.Message;
            await _context.Dialogs.ShowErrorAsync("Nothing was saved", ex.Message);
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand(CanExecute = nameof(HasPendingChanges))]
    public void Discard() => _buffer?.Discard();

    [RelayCommand]
    public async Task RefreshStructureAsync()
    {
        await LoadStructureAsync(refresh: true);
    }

    /// <summary>Runs DDL from the structure editor after the review sheet, then reloads what it changed.</summary>
    public async Task<bool> ApplySchemaChangeAsync(SchemaChange change)
    {
        if (_context.Session.Database is not ISchemaDdlProvider ddl)
        {
            await _context.Dialogs.ShowErrorAsync("Not supported", "This engine cannot change structure from the app.");
            return false;
        }

        var statements = ddl.BuildDdl(Table.Name, change);
        if (statements.Count == 0)
        {
            await _context.Dialogs.ShowErrorAsync("Not supported", "This engine cannot express that change.");
            return false;
        }

        if (_context.Session.Profile.SafeMode.BlocksAllWrites())
        {
            await _context.Dialogs.ShowErrorAsync("Read-only connection", "Safe Mode is Read-Only on this connection.");
            return false;
        }

        if (!await _context.Dialogs.ReviewSqlAsync("Review structure change", statements, "Apply"))
        {
            return false;
        }

        IsBusy = true;
        try
        {
            await using var channel = await _context.Session.Database.OpenChannelAsync(CancellationToken.None);
            await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(), CancellationToken.None))
            {
                _context.History.Record(_context.Session.Profile, _context.Session.Database.CurrentDatabase, result, StatementKind.Ddl, "structure");
                if (!result.Succeeded)
                {
                    await _context.Dialogs.ShowErrorAsync("The change failed", result.Error!);
                    return false;
                }
            }

            _context.NotifySchemaChanged();
            if (change is not (DropObject or RenameTable))
            {
                await LoadStructureAsync(refresh: true);
                await LoadAsync();
            }

            return true;
        }
        finally
        {
            IsBusy = false;
        }
    }

    public async ValueTask<string> GetFullTableSqlAsync()
    {
        if (string.IsNullOrEmpty(Definition))
        {
            await LoadStructureAsync(refresh: false);
        }

        return Definition;
    }

    public override ValueTask DisposeAsync()
    {
        _load?.Cancel();
        _load?.Dispose();
        return base.DisposeAsync();
    }

    private async Task LoadStructureAsync(bool refresh)
    {
        try
        {
            var structure = await _context.Session.GetStructureAsync(Table.Name, CancellationToken.None, refresh);
            Structure = structure;
            FilterColumns.Clear();
            FilterColumns.Add(FilterRuleViewModel.AllColumns);
            foreach (var column in structure.Columns)
            {
                FilterColumns.Add(column.Name);
            }

            ColumnsGrid = new ResultGridSource(StructureTables.Columns(structure));
            IndexesGrid = new ResultGridSource(StructureTables.Indexes(structure));
            ForeignKeysGrid = new ResultGridSource(StructureTables.ForeignKeys(structure));
            TriggersGrid = new ResultGridSource(StructureTables.Triggers(structure));
            UpdateEditability();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            StatusText = ex.Message;
        }

        try
        {
            Definition = await _context.Session.Database.GetDefinitionAsync(Table, CancellationToken.None);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            Definition = "-- " + ex.Message;
        }
    }

    private BrowseFilter BuildFilter()
    {
        var rules = Filters.Where(f => f.Enabled && (f.Value is not null || !f.Operator.TakesValue())).Select(f => f.ToRule()).ToArray();
        var columns = Structure?.Columns.Select(c => c.Name).ToArray() ?? [];
        return new BrowseFilter(rules, RawWhere, MatchAllFilters) { SearchColumns = columns };
    }

    private void AttachBuffer(ResultSet result)
    {
        if (_buffer is not null)
        {
            _buffer.Changed -= OnBufferChanged;
        }

        _buffer = new TableEditBuffer(result, Structure?.PrimaryKey ?? []);
        _buffer.Changed += OnBufferChanged;
        PendingChanges = 0;
        UpdateEditability();
        Rows = new EditableGridSource(_buffer, IsEditable);
    }

    private void OnBufferChanged(object? sender, EventArgs e)
    {
        PendingChanges = _buffer?.ChangeCount ?? 0;
        OnPropertyChanged(nameof(UnsavedWork));
    }

    private void UpdateEditability()
    {
        var profile = _context.Session.Profile;
        (IsEditable, ReadOnlyReason) = (Table.Kind, profile.SafeMode, Structure?.PrimaryKey.Count ?? 0) switch
        {
            (not ObjectKind.Table, _, _) => (false, "Views are read-only."),
            (_, SafeModeLevel.ReadOnly, _) => (false, "Safe Mode is Read-Only on this connection."),
            (_, _, 0) => (true, "No primary key: rows are matched on every column, and a save that hits duplicates is refused."),
            _ => (true, null),
        };
    }
}

/// <summary>Shapes structure into result sets so the same grid shows columns, indexes, keys and triggers.</summary>
internal static class StructureTables
{
    private static readonly ResultColumn Text = new("x", "text", typeof(string));

    public static ResultSet Columns(TableStructure s) => Build(
        ["#", "Name", "Type", "Nullable", "Default", "Key", "Identity", "Comment"],
        // Positions count from 1 here whatever the engine's catalog uses, and empty flags stay blank rather than NULL.
        s.Columns.Select((c, i) => new object?[] { i + 1, c.Name, c.DataType, c.IsNullable ? "YES" : "NO", c.DefaultValue, c.IsPrimaryKey ? "PRI" : string.Empty, c.IsIdentity ? "YES" : string.Empty, c.Comment ?? string.Empty }));

    public static ResultSet Indexes(TableStructure s) => Build(
        ["Name", "Columns", "Unique", "Primary", "Method"],
        s.Indexes.Select(i => new object?[] { i.Name, string.Join(", ", i.Columns), i.IsUnique ? "YES" : "NO", i.IsPrimary ? "YES" : "NO", i.Method }));

    public static ResultSet ForeignKeys(TableStructure s) => Build(
        ["Name", "Columns", "References", "Referenced Columns", "On Update", "On Delete"],
        s.ForeignKeys.Select(f => new object?[] { f.Name, string.Join(", ", f.Columns), f.ReferencedTable.ToString(), string.Join(", ", f.ReferencedColumns), f.OnUpdate, f.OnDelete }));

    public static ResultSet Triggers(TableStructure s) => Build(
        ["Name", "Timing", "Event", "Definition"],
        s.Triggers.Select(t => new object?[] { t.Name, t.Timing, t.Event, t.Definition }));

    private static ResultSet Build(string[] names, IEnumerable<object?[]> rows)
    {
        var columns = names.Select(n => Text with { Name = n, ClrType = n == "#" ? typeof(int) : typeof(string) }).ToArray();
        return new ResultSet(columns, rows.ToList());
    }
}
