using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using TablePro.App.Services;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;
using TablePro.Core.Search;
using TablePro.Storage.Workspace;

namespace TablePro.App.ViewModels;

/// <summary>A row of the sidebar: a section header or a database object.</summary>
public sealed class SidebarEntry
{
    private SidebarEntry(string text, string glyph, DatabaseObject? obj, string? detail)
    {
        Text = text;
        Glyph = glyph;
        Object = obj;
        Detail = detail;
    }

    public string Text { get; }

    public string Glyph { get; }

    public string? Detail { get; }

    public DatabaseObject? Object { get; }

    public bool IsHeader => Object is null;

    // ListView announces an item by its ToString, so screen readers read the object's name.
    public override string ToString() => Object is null ? Text : Strings.Format("Workspace/SidebarItemAccessibleName", KindName(Object.Kind), Text);

    // Upper-cased in the UI language, so a Turkish "i" becomes its dotted capital.
    public static SidebarEntry Header(string text, int count) => new(text.ToUpper(CultureInfo.CurrentUICulture), string.Empty, null, count.ToString(CultureInfo.CurrentCulture));

    /// <summary>The name of one object of a kind, as the quick switcher and screen readers show it.</summary>
    public static string KindName(ObjectKind kind) => kind switch
    {
        ObjectKind.Table => Strings.Get("Workspace/KindTable"),
        ObjectKind.View => Strings.Get("Workspace/KindView"),
        ObjectKind.MaterializedView => Strings.Get("Workspace/KindMaterializedView"),
        ObjectKind.Function => Strings.Get("Workspace/KindFunction"),
        ObjectKind.Procedure => Strings.Get("Workspace/KindProcedure"),
        ObjectKind.Sequence => Strings.Get("Workspace/KindSequence"),
        ObjectKind.Trigger => Strings.Get("Workspace/KindTrigger"),
        ObjectKind.Collection => Strings.Get("Workspace/KindCollection"),
        ObjectKind.Key => Strings.Get("Workspace/KindKey"),
        ObjectKind.Topic => Strings.Get("Workspace/KindTopic"),
        _ => kind.ToString(),
    };

    public static SidebarEntry For(DatabaseObject obj) => new(obj.Name.Name, GlyphFor(obj.Kind), obj, obj.RowEstimate is > 0 ? FormatCount(obj.RowEstimate.Value) : null);

    public static string GlyphFor(ObjectKind kind) => kind switch
    {
        ObjectKind.Table => "",
        ObjectKind.View => "",
        ObjectKind.MaterializedView => "",
        ObjectKind.Function => "",
        ObjectKind.Procedure => "",
        ObjectKind.Sequence => "",
        ObjectKind.Trigger => "",
        _ => "",
    };

    private static string FormatCount(long count) => count switch
    {
        >= 1_000_000_000 => Strings.Format("Workspace/CountBillions", count / 1e9),
        >= 1_000_000 => Strings.Format("Workspace/CountMillions", count / 1e6),
        >= 10_000 => Strings.Format("Workspace/CountThousands", count / 1e3),
        _ => count.ToString("N0", CultureInfo.CurrentCulture),
    };
}

/// <summary>One workspace window: a connection, its sidebar and its tabs.</summary>
public sealed partial class WorkspaceViewModel : ObservableObject, IAsyncDisposable
{
    private readonly IDatabaseDriver _driver;
    private readonly Func<ConnectionProfile, string?, Task<ConnectionRequest>> _requestFactory;
    private int _queryNumber;
    private bool _switching;

    public WorkspaceViewModel(WorkspaceContext context, IDatabaseDriver driver, Func<ConnectionProfile, string?, Task<ConnectionRequest>> requestFactory)
    {
        Context = context;
        _driver = driver;
        _requestFactory = requestFactory;
        context.SchemaChanged += async (_, _) => await RefreshAsync();
        context.Notified += (_, message) => Notification = message;
    }

    public WorkspaceContext Context { get; }

    public ConnectionSession Session => Context.Session;

    public ConnectionProfile Profile => Session.Profile;

    public ObservableCollection<TabViewModel> Tabs { get; } = [];

    public ObservableCollection<SidebarEntry> Sidebar { get; } = [];

    public ObservableCollection<string> Databases { get; } = [];

    public ObservableCollection<string> Schemas { get; } = [];

    /// <summary>What the quick switcher opened and when, saved with the workspace so recent picks rank first.</summary>
    public Frecency Opened { get; } = new();

    public string Title => Profile.Name;

    public string ServerText => $"{Profile.Descriptor.DisplayName} {Session.Database.ServerVersion}".Trim();

    public bool HasSchemas => Profile.Descriptor.HasSchemas;

    public bool CanSwitchDatabase => !Profile.Descriptor.IsFileBased;

    // Engines whose databases are listed as schemas (Redis's numbered ones) return none, so the empty box is hidden.
    public bool ShowDatabaseSwitcher => CanSwitchDatabase && Databases.Count > 0;

    public string SafeModeText => Profile.SafeMode switch
    {
        SafeModeLevel.Silent => string.Empty,
        SafeModeLevel.ReadOnly => Strings.Get("Workspace/BadgeReadOnly"),
        _ => Strings.Get("Workspace/BadgeSafeMode"),
    };

    [ObservableProperty]
    public partial TabViewModel? SelectedTab { get; set; }

    [ObservableProperty]
    public partial string SearchText { get; set; } = string.Empty;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SelectedDatabaseItem))]
    public partial string? SelectedDatabase { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SelectedSchemaItem))]
    public partial string? SelectedSchema { get; set; }

    // Window-level x:Bind cannot use converters, so selectors bind through object-typed adapters.
    public object? SelectedDatabaseItem
    {
        get => SelectedDatabase;
        set => SelectedDatabase = value as string;
    }

    public object? SelectedSchemaItem
    {
        get => SelectedSchema;
        set => SelectedSchema = value as string;
    }

    public bool HasSidebarError => !string.IsNullOrEmpty(SidebarError);

    [ObservableProperty]
    public partial bool IsLoading { get; set; }

    [ObservableProperty]
    public partial string? Notification { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSidebarError))]
    public partial string? SidebarError { get; set; }

    /// <summary>The tabs to reopen, read from the last session when the Restore setting is on.</summary>
    public WorkspaceState? RestoreState { get; set; }

    public async Task InitializeAsync()
    {
        await RefreshAsync();
        Restore();
        if (CanSwitchDatabase)
        {
            try
            {
                var databases = await Session.Database.GetDatabasesAsync(CancellationToken.None);
                Databases.Clear();
                foreach (var database in databases)
                {
                    Databases.Add(database);
                }

                _switching = true;
                SelectedDatabase = Session.Database.CurrentDatabase;
                _switching = false;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // A login without rights to list databases still works in the one it connected to.
                Databases.Clear();
            }

            OnPropertyChanged(nameof(ShowDatabaseSwitcher));
        }

        if (Tabs.Count == 0)
        {
            NewQuery();
        }
    }

    /// <summary>What the window holds, so the next connect can reopen it.</summary>
    public WorkspaceState CaptureState() => new()
    {
        ConnectionId = Profile.Id,
        Database = Session.Database.CurrentDatabase,
        Schema = Session.CurrentSchema,
        Opened = Opened.Snapshot(),
        SelectedIndex = SelectedTab is null ? 0 : Math.Max(0, Tabs.IndexOf(SelectedTab)),
        Tabs = Tabs.Select(tab => tab switch
        {
            QueryTabViewModel query => new WorkspaceTab { Kind = WorkspaceTabKind.Query, Title = query.Title, QueryText = query.Text, FilePath = query.FilePath },
            TableTabViewModel table => new WorkspaceTab { Kind = WorkspaceTabKind.Table, Title = table.Title, Schema = table.Table.Name.Schema, ObjectName = table.Table.Name.Name },
            _ => null,
        }).OfType<WorkspaceTab>().ToArray(),
    };

    private void Restore()
    {
        if (RestoreState is not { } state)
        {
            return;
        }

        RestoreState = null;
        foreach (var tab in state.Tabs)
        {
            if (tab.Kind == WorkspaceTabKind.Query)
            {
                NewQuery(tab.QueryText, tab.FilePath);
            }
            else if (Session.Objects.FirstOrDefault(o => o.Name.Name == tab.ObjectName && (tab.Schema is null || o.Name.Schema == tab.Schema)) is { } obj)
            {
                OpenTable(obj);
            }
        }

        if (Tabs.Count > 0)
        {
            SelectedTab = Tabs[Math.Clamp(state.SelectedIndex, 0, Tabs.Count - 1)];
        }
    }

    [RelayCommand]
    public async Task RefreshAsync()
    {
        IsLoading = true;
        SidebarError = null;
        try
        {
            await Session.RefreshAsync(CancellationToken.None);
            _switching = true;
            Schemas.Clear();
            foreach (var schema in Session.Schemas)
            {
                Schemas.Add(schema);
            }

            SelectedSchema = Session.CurrentSchema;
            _switching = false;
            RebuildSidebar();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            SidebarError = ex.Message;
        }
        finally
        {
            IsLoading = false;
        }
    }

    [RelayCommand]
    private void NewQueryTab() => NewQuery(null);

    public QueryTabViewModel NewQuery() => NewQuery(null);

    public QueryTabViewModel NewQuery(string? text, string? filePath = null)
    {
        var tab = new QueryTabViewModel(Context, ++_queryNumber, text, filePath);
        Tabs.Add(tab);
        SelectedTab = tab;
        return tab;
    }

    public TableTabViewModel OpenTable(DatabaseObject table, TableTabSection section = TableTabSection.Data)
    {
        var existing = Tabs.OfType<TableTabViewModel>().FirstOrDefault(t => t.Table.Name == table.Name);
        if (existing is not null)
        {
            SelectedTab = existing;
            existing.Section = section;
            return existing;
        }

        var tab = new TableTabViewModel(Context, table) { Section = section };
        Tabs.Add(tab);
        SelectedTab = tab;
        return tab;
    }

    public async Task<bool> CloseTabAsync(TabViewModel tab)
    {
        if (tab.UnsavedWork is { } unsaved && !await Context.Dialogs.ConfirmAsync(Strings.Get("Workspace/CloseTabTitle"), Strings.Format("Workspace/CloseTabMessage", unsaved), Strings.Get("Common/Close"), destructive: true))
        {
            return false;
        }

        var index = Tabs.IndexOf(tab);
        Tabs.Remove(tab);
        await tab.DisposeAsync();
        if (Tabs.Count > 0)
        {
            SelectedTab = Tabs[Math.Clamp(index, 0, Tabs.Count - 1)];
        }

        return true;
    }

    /// <summary>The statement a "Select rows" or a "Show definition" action writes into a new editor tab.</summary>
    public void QueryObject(DatabaseObject obj, int limit = 1000) => NewQuery(StarterQuery(obj, limit));

    /// <summary>The first statement a "Query" action writes, in the engine's own language.</summary>
    public string StarterQuery(DatabaseObject obj, int limit = 1000)
    {
        var dialect = Session.Dialect;
        var name = obj.Name.Name;
        var page = Math.Min(limit, 100);
        return Profile.Engine switch
        {
            DatabaseEngine.MongoDb => $"db.getCollection({dialect.StringLiteral(name)}).find({{}}).limit({page})",
            DatabaseEngine.Redis => (obj.Comment ?? string.Empty).ToLowerInvariant() switch
            {
                "hash" => $"HGETALL {Quote(name)}",
                "list" => $"LRANGE {Quote(name)} 0 {page - 1}",
                "set" => $"SSCAN {Quote(name)} 0 COUNT {page}",
                "zset" => $"ZRANGE {Quote(name)} 0 {page - 1} WITHSCORES",
                "stream" => $"XRANGE {Quote(name)} - + COUNT {page}",
                "rejson-rl" or "json" => $"JSON.GET {Quote(name)} $",
                _ => $"GET {Quote(name)}",
            },
            DatabaseEngine.Elasticsearch => $"GET /{name}/_search\n{{\n  \"query\": {{ \"match_all\": {{}} }},\n  \"size\": {page}\n}}",
            DatabaseEngine.Typesense => $"GET /collections/{name}/documents/export",
            DatabaseEngine.Weaviate => $"{{\n  Get {{\n    {name}(limit: {page}) {{\n      _additional {{ id }}\n    }}\n  }}\n}}",
            DatabaseEngine.Kafka => $"CONSUME {name} FROM OLDEST LIMIT {page}",
            DatabaseEngine.Etcd => $"get {Quote(name)} --prefix --limit {page}",
            DatabaseEngine.SurrealDb => $"SELECT * FROM {dialect.QuoteIdentifier(name)} LIMIT {page};",
            DatabaseEngine.DynamoDb => $"SELECT * FROM \"{name}\"",
            DatabaseEngine.SqlServer or DatabaseEngine.Teradata => $"SELECT TOP {limit} * FROM {dialect.Qualify(obj.Name)};",
            DatabaseEngine.Oracle or DatabaseEngine.Dameng => $"SELECT * FROM {dialect.Qualify(obj.Name)} FETCH FIRST {limit} ROWS ONLY;",
            _ => $"SELECT * FROM {dialect.Qualify(obj.Name)} LIMIT {limit};",
        };

        static string Quote(string key) => key.Any(c => char.IsWhiteSpace(c) || c is '"' or '\'') ? "\"" + key.Replace("\"", "\\\"", StringComparison.Ordinal) + "\"" : key;
    }

    /// <summary>The structure editor and Create Table need DDL the engine can express in SQL.</summary>
    public bool CanEditStructure => Session.Database is ISchemaDdlProvider && Session.Dialect.IsSql && !Profile.IsReadOnly;

    public bool IsSql => Session.Dialect.IsSql;

    public async Task<bool> DropObjectAsync(DatabaseObject obj)
    {
        if (Session.Database is not ISchemaDdlProvider ddl)
        {
            return false;
        }

        var statements = ddl.BuildDdl(obj.Name, new DropObject(obj));
        if (statements.Count == 0 || Profile.IsReadOnly || !await Context.Dialogs.ReviewSqlAsync(Strings.Format("Workspace/DropTitle", obj.Name.Name), statements, Strings.Get("Workspace/Drop")))
        {
            return false;
        }

        return await RunDdlAsync(statements);
    }

    public async Task<bool> TruncateAsync(DatabaseObject obj)
    {
        if (Session.Database is not ISchemaDdlProvider ddl)
        {
            return false;
        }

        var statements = ddl.BuildDdl(obj.Name, new TruncateTable());
        if (statements.Count == 0 || Profile.IsReadOnly || !await Context.Dialogs.ReviewSqlAsync(Strings.Format("Workspace/TruncateTitle", obj.Name.Name), statements, Strings.Get("Workspace/Truncate")))
        {
            return false;
        }

        return await RunDdlAsync(statements);
    }

    public async Task<bool> RenameAsync(DatabaseObject obj)
    {
        if (Session.Database is not ISchemaDdlProvider ddl)
        {
            return false;
        }

        var name = await Context.Dialogs.PromptAsync(Strings.Format("Workspace/RenameTitle", obj.Name.Name), Strings.Get("Workspace/RenameNewName"), obj.Name.Name, Strings.Get("Common/Rename"));
        if (string.IsNullOrWhiteSpace(name) || name == obj.Name.Name)
        {
            return false;
        }

        var statements = ddl.BuildDdl(obj.Name, new RenameTable(name.Trim()));
        return statements.Count > 0 && !Profile.IsReadOnly && await Context.Dialogs.ReviewSqlAsync(Strings.Get("Common/Rename"), statements, Strings.Get("Common/Rename")) && await RunDdlAsync(statements);
    }

    public async Task<bool> CreateTableAsync(ObjectName name, IReadOnlyList<ColumnDefinition> columns)
    {
        if (Session.Database is not ISchemaDdlProvider ddl)
        {
            return false;
        }

        var statements = ddl.BuildDdl(name, new CreateTable(name, columns));
        return statements.Count > 0 && !Profile.IsReadOnly && await Context.Dialogs.ReviewSqlAsync(Strings.Get("Workspace/CreateTableReviewTitle"), statements, Strings.Get("Workspace/Create")) && await RunDdlAsync(statements);
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var tab in Tabs.ToArray())
        {
            await tab.DisposeAsync();
        }

        Tabs.Clear();
        await Session.DisposeAsync();
    }

    async partial void OnSearchTextChanged(string value)
    {
        if (Session.Database is not IKeySearchProvider keys)
        {
            RebuildSidebar();
            return;
        }

        // Keys are searched on the server, which can match a pattern over millions of them; the list only has a sample.
        _keySearch?.Cancel();
        _keySearch = new CancellationTokenSource();
        var token = _keySearch.Token;
        if (string.IsNullOrWhiteSpace(value))
        {
            _keyMatches = null;
            RebuildSidebar();
            return;
        }

        try
        {
            await Task.Delay(300, token);
            var pattern = value.Contains('*', StringComparison.Ordinal) || value.Contains('?', StringComparison.Ordinal) ? value : $"*{value}*";
            var result = await keys.SearchKeysAsync(Session.CurrentSchema, pattern, KeySearchLimit, token);
            if (!token.IsCancellationRequested)
            {
                _keyMatches = result;
                RebuildSidebar();
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            SidebarError = ex.Message;
        }
    }

    private const int KeySearchLimit = 2000;
    private CancellationTokenSource? _keySearch;
    private KeySearchResult? _keyMatches;

    async partial void OnSelectedSchemaChanged(string? value)
    {
        if (_switching || value is null || value == Session.CurrentSchema)
        {
            return;
        }

        Session.CurrentSchema = value;
        IsLoading = true;
        try
        {
            await Session.RefreshAsync(CancellationToken.None);
            RebuildSidebar();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            SidebarError = ex.Message;
        }
        finally
        {
            IsLoading = false;
        }
    }

    async partial void OnSelectedDatabaseChanged(string? value)
    {
        if (_switching || value is null || value == Session.Database.CurrentDatabase)
        {
            return;
        }

        if (Tabs.Any(t => t.UnsavedWork is not null) && !await Context.Dialogs.ConfirmAsync(Strings.Get("Workspace/SwitchDatabaseTitle"), Strings.Get("Workspace/SwitchDatabaseMessage"), Strings.Get("Workspace/SwitchDatabaseButton"), destructive: true))
        {
            _switching = true;
            SelectedDatabase = Session.Database.CurrentDatabase;
            _switching = false;
            return;
        }

        IsLoading = true;
        try
        {
            foreach (var tab in Tabs.ToArray())
            {
                await tab.DisposeAsync();
            }

            Tabs.Clear();
            var request = await _requestFactory(Profile, value);
            await Session.SwitchDatabaseAsync(_driver, request, CancellationToken.None);
            OnPropertyChanged(nameof(ServerText));
            await RefreshAsync();
            NewQuery();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            await Context.Dialogs.ShowErrorAsync(Strings.Get("Workspace/SwitchDatabaseFailed"), ex.Message);
        }
        finally
        {
            IsLoading = false;
        }
    }

    private async Task<bool> RunDdlAsync(IReadOnlyList<string> statements)
    {
        await using var channel = await Session.Database.OpenChannelAsync(CancellationToken.None);
        await foreach (var result in channel.ExecuteAsync(statements, new Core.Results.ExecuteOptions(), CancellationToken.None))
        {
            Context.History.Record(Profile, Session.Database.CurrentDatabase, result, Core.Sql.StatementKind.Ddl, "sidebar");
            if (!result.Succeeded)
            {
                await Context.Dialogs.ShowErrorAsync(Strings.Get("Workspace/StatementFailed"), result.Error!);
                await RefreshAsync();
                return false;
            }
        }

        await RefreshAsync();
        return true;
    }

    private void RebuildSidebar()
    {
        var query = SearchText.Trim();
        var source = _keyMatches is { } matches && query.Length > 0 ? matches.Keys : Session.Objects;
        var filterLocally = _keyMatches is null || query.Length == 0;
        var objects = source
            .Where(o => !filterLocally || query.Length == 0 || o.Name.Name.Contains(query, StringComparison.OrdinalIgnoreCase))
            .OrderBy(o => o.Name.Name, StringComparer.OrdinalIgnoreCase)
            .GroupBy(o => o.Kind)
            .OrderBy(g => g.Key);

        Sidebar.Clear();
        foreach (var group in objects)
        {
            var items = group.ToArray();
            Sidebar.Add(SidebarEntry.Header(SectionName(group.Key), items.Length));
            foreach (var obj in items)
            {
                Sidebar.Add(SidebarEntry.For(obj));
            }
        }
    }

    internal static string SectionName(ObjectKind kind) => kind switch
    {
        ObjectKind.Table => Strings.Get("Workspace/SectionTables"),
        ObjectKind.View => Strings.Get("Workspace/SectionViews"),
        ObjectKind.MaterializedView => Strings.Get("Workspace/SectionMaterializedViews"),
        ObjectKind.Function => Strings.Get("Workspace/SectionFunctions"),
        ObjectKind.Procedure => Strings.Get("Workspace/SectionProcedures"),
        ObjectKind.Sequence => Strings.Get("Workspace/SectionSequences"),
        ObjectKind.Trigger => Strings.Get("Workspace/SectionTriggers"),
        ObjectKind.Collection => Strings.Get("Workspace/SectionCollections"),
        ObjectKind.Key => Strings.Get("Workspace/SectionKeys"),
        ObjectKind.Topic => Strings.Get("Workspace/SectionTopics"),
        _ => kind.ToString(),
    };
}
