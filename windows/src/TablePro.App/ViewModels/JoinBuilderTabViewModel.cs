using CommunityToolkit.Mvvm.ComponentModel;
using TablePro.App.Services;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.JoinBuilder;
using TablePro.Core.Schema;

namespace TablePro.App.ViewModels;

/// <summary>What changed in the join builder, so the view rebuilds only what it must and keeps the focus in a text box being typed in.</summary>
public enum JoinBuilderChange
{
    /// <summary>Tables, joins, columns, filters or sorts were added, removed or relinked.</summary>
    Structure,

    /// <summary>Only a filter's value or a sort's direction changed: the SQL, not the layout.</summary>
    Sql,
}

/// <summary>
/// The visual join builder of the macOS app, as a tab: tables of the current schema, joins suggested from their
/// foreign keys, chosen columns, filters and sort, written as one SELECT that opens in a query tab.
/// </summary>
public sealed partial class JoinBuilderTabViewModel : TabViewModel
{
    /// <summary>Each table costs a structure read; past this many the list stops growing and says so.</summary>
    public const int MaxTables = 400;

    private readonly WorkspaceContext _context;
    private readonly string[] _seed;

    public JoinBuilderTabViewModel(WorkspaceContext context, IEnumerable<string>? seedTables = null)
    {
        ArgumentNullException.ThrowIfNull(context);
        _context = context;
        _seed = seedTables?.ToArray() ?? [];
        Title = Strings.Get("Tools/JoinTabTitle");
        Subtitle = context.Session.CurrentSchema ?? context.Session.Profile.Name;
        Schema = context.Session.CurrentSchema;
        JoinKinds = Core.JoinBuilder.JoinKinds.SupportedBy(context.Session.Profile.Engine);
    }

    public override string Glyph => "";

    public event EventHandler<JoinBuilderChange>? Changed;

    public JoinGraph Graph { get; private set; } = JoinGraph.Empty;

    public JoinQueryDraft Draft { get; private set; } = new();

    /// <summary>The schema the tables come from; also the one the SQL names them in when the connection would not find them.</summary>
    public string? Schema { get; }

    public IReadOnlyList<JoinKind> JoinKinds { get; }

    [ObservableProperty]
    public partial bool IsLoaded { get; set; }

    [ObservableProperty]
    public partial string? LoadError { get; set; }

    [ObservableProperty]
    public partial string TableFilter { get; set; } = string.Empty;

    /// <summary>The tables the list shows: those matching the filter, and every picked one whatever the filter says.</summary>
    public IEnumerable<string> FilteredTables
    {
        get
        {
            var term = TableFilter.Trim();
            return term.Length == 0 ? Graph.TableNames : Graph.TableNames.Where(t => t.Contains(term, StringComparison.OrdinalIgnoreCase) || Draft.Contains(t));
        }
    }

    public string? Sql => new JoinQuerySqlWriter(_context.Session.Dialect, QualifyingSchema).Write(Draft, Graph);

    /// <summary>What the footer says: how to start, or which tables no key links.</summary>
    public string Hint
    {
        get
        {
            if (!IsLoaded)
            {
                return string.Empty;
            }

            if (Draft.IsEmpty)
            {
                return Strings.Get("Tools/JoinHintStart");
            }

            var crossJoined = Draft.CrossJoinedTables.ToArray();
            return crossJoined.Length == 0
                ? string.Empty
                : Strings.Plural("Tools/JoinHintCrossJoined", crossJoined.Length, string.Join(", ", crossJoined));
        }
    }

    // SQL Server resolves a bare name in the login's default schema whatever the sidebar shows, so the tables are named
    // in their schema whenever it is not the one a new query tab would search.
    private string? QualifyingSchema
    {
        get
        {
            var session = _context.Session;
            if (string.IsNullOrEmpty(Schema) || !session.Profile.Descriptor.HasSchemas)
            {
                return null;
            }

            return session.Profile.Engine == DatabaseEngine.SqlServer || !string.Equals(Schema, session.Database.DefaultSchema, StringComparison.OrdinalIgnoreCase)
                ? Schema
                : null;
        }
    }

    /// <summary>Opens a join builder tab in the workspace, seeded with the given tables of the current schema.</summary>
    public static JoinBuilderTabViewModel Open(WorkspaceViewModel workspace, IEnumerable<DatabaseObject>? seed = null)
    {
        ArgumentNullException.ThrowIfNull(workspace);
        var schema = workspace.Session.CurrentSchema;

        // One query joins one schema, so only the tables of the current one are seeded.
        var tables = seed?.Where(o => o.Kind == ObjectKind.Table && (string.IsNullOrEmpty(o.Name.Schema) || string.Equals(o.Name.Schema, schema, StringComparison.OrdinalIgnoreCase)))
            .Select(o => o.Name.Name);
        var tab = new JoinBuilderTabViewModel(workspace.Context, tables);
        workspace.Tabs.Add(tab);
        workspace.SelectedTab = tab;
        return tab;
    }

    public async Task LoadAsync()
    {
        IsBusy = true;
        LoadError = null;
        StatusText = Strings.Get("Tools/JoinReadingTables");
        try
        {
            var session = _context.Session;
            var tables = session.Objects.Where(o => o.Kind == ObjectKind.Table).Take(MaxTables).ToArray();
            var structures = new List<TableStructure>(tables.Length);
            foreach (var table in tables)
            {
                structures.Add(await session.GetStructureAsync(table.Name, CancellationToken.None));
                StatusText = Strings.Format("Tools/JoinReadingTablesProgress", structures.Count, tables.Length);
            }

            Graph = JoinGraph.FromStructures(structures, Schema);
            var seeded = new JoinQueryDraft();
            foreach (var table in _seed.Concat(Draft.Tables.Select(t => t.Name)))
            {
                seeded.Add(table, Graph);
            }

            Draft = seeded;
            IsLoaded = true;
            var total = session.Objects.Count(o => o.Kind == ObjectKind.Table);
            StatusText = total > MaxTables ? Strings.Plural("Tools/JoinShowingTables", total, MaxTables) : Strings.Plural("Tools/JoinTableCount", total);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            LoadError = ex.Message;
            StatusText = ex.Message;
        }
        finally
        {
            IsBusy = false;
            Changed?.Invoke(this, JoinBuilderChange.Structure);
        }
    }

    public bool IsIncluded(string table) => Draft.Contains(table);

    public void SetIncluded(string table, bool included)
    {
        if (included)
        {
            Draft.Add(table, Graph);
        }
        else
        {
            Draft.Remove(table, Graph);
        }

        Raise();
    }

    public IReadOnlyList<JoinRelationship> Candidates(int index) => Draft.Candidates(index, Graph);

    public void SetKind(int index, JoinKind kind)
    {
        Draft.SetKind(index, kind);
        Raise(JoinBuilderChange.Sql);
    }

    public void SetCondition(int index, JoinRelationship? condition)
    {
        Draft.SetCondition(index, condition, Graph);
        Raise();
    }

    public bool IsSelected(JoinColumnRef column) => Draft.IsSelected(column);

    public void SetSelected(JoinColumnRef column, bool selected)
    {
        Draft.SetSelected(column, selected, Graph);
        Raise(JoinBuilderChange.Sql);
    }

    public IReadOnlyList<JoinColumnRef> AvailableColumns => [.. Draft.AvailableColumns(Graph)];

    public void AddFilter()
    {
        if (AvailableColumns.Count > 0)
        {
            Draft.Filters.Add(new JoinFilter(AvailableColumns[0]));
            Raise();
        }
    }

    public void RemoveFilter(JoinFilter filter)
    {
        Draft.Filters.Remove(filter);
        Raise();
    }

    /// <summary>A filter edited in place: a new column or operator changes the row's fields, a value only the SQL.</summary>
    public void UpdateFilter(JoinFilter filter, JoinColumnRef? column = null, FilterOperator? op = null, string? value = null, string? secondValue = null)
    {
        ArgumentNullException.ThrowIfNull(filter);
        var layout = (op is { } changed && changed != filter.Operator) || (column is { } moved && moved != filter.Column);
        filter.Column = column ?? filter.Column;
        filter.Operator = op ?? filter.Operator;
        filter.Value = value ?? filter.Value;
        filter.SecondValue = secondValue ?? filter.SecondValue;
        Raise(layout ? JoinBuilderChange.Structure : JoinBuilderChange.Sql);
    }

    public void AddSort()
    {
        if (AvailableColumns.Count > 0)
        {
            Draft.Sorts.Add(new JoinSort(AvailableColumns[0]));
            Raise();
        }
    }

    public void RemoveSort(JoinSort sort)
    {
        Draft.Sorts.Remove(sort);
        Raise();
    }

    public void UpdateSort(JoinSort sort, JoinColumnRef? column = null, bool? descending = null)
    {
        ArgumentNullException.ThrowIfNull(sort);
        sort.Column = column ?? sort.Column;
        sort.Descending = descending ?? sort.Descending;
        Raise(JoinBuilderChange.Sql);
    }

    public void Clear()
    {
        Draft = new JoinQueryDraft();
        Raise();
    }

    private void Raise(JoinBuilderChange change = JoinBuilderChange.Structure) => Changed?.Invoke(this, change);
}
