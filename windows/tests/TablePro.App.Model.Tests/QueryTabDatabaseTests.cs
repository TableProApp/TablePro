using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class QueryTabDatabaseTests
{
    private static readonly CoreError BindsAtConnect = new(
        "driver.unsupported", ["operation.driver", "driver.unsupported"], "refused", null, null);

    private readonly FakeSession _session = new() { Layout = DatabaseLayout.AsSchemas };
    private readonly FakeQueryView _view = new();
    private readonly FakeResults _results = new();

    [Fact]
    public async Task ATabOpenedForADatabaseOpensItsEditorThere()
    {
        var tab = Tab("shop");

        await tab.RunAsync();
        await tab.RunAsync();

        var editor = Assert.Single(_session.Editors);
        Assert.Equal<string?>(["shop"], _session.EditorDatabases);
        Assert.Empty(editor.Databases);
        Assert.Equal<string>(["select * from Artist", "select * from Artist"], editor.Runs);
        Assert.Equal("shop", tab.Snapshot().Database);
    }

    [Fact]
    public async Task AnOpenTheEngineRefusesSendsNothingAndSaysWhy()
    {
        _session.DatabaseRefusal = BindsAtConnect;
        var tab = Tab("shop");

        await tab.RunAsync();

        Assert.Empty(_session.Editors);
        Assert.Equal<string?>(["shop"], _session.EditorDatabases);
        Assert.Contains("error driver.unsupported", _results.Shown);
        Assert.False(tab.IsRunning);
    }

    [Fact]
    public async Task ATabWithNoDatabaseRunsWhereTheConnectionIs()
    {
        var tab = Tab(null);

        await tab.RunAsync();

        var editor = Assert.Single(_session.Editors);
        Assert.Equal<string?>([null], _session.EditorDatabases);
        Assert.Empty(editor.Databases);
        Assert.Null(tab.Snapshot().Database);
    }

    [Fact]
    public void TheSwitcherShowsOnlyWhereTheServerHasMoreThanOneDatabase()
    {
        Assert.True(Tab(null).ShowsDatabases);

        _session.Layout = DatabaseLayout.WithSchemas;
        Assert.True(Tab(null).ShowsDatabases);

        _session.Layout = DatabaseLayout.OneDatabase;
        Assert.False(Tab(null).ShowsDatabases);
    }

    [Fact]
    public async Task TheSwitcherListsUserDatabasesBeforeTheEnginesOwnAndChecksTheListedDefault()
    {
        _session.ServerDatabases.AddRange(
        [
            new SchemaEntry("mysql", IsDefault: false, IsSystem: true),
            new SchemaEntry("shop", IsDefault: true, IsSystem: false),
            new SchemaEntry("inventory", IsDefault: false, IsSystem: false),
        ]);
        var tab = Tab(null);
        var changes = 0;
        tab.StateChanged += (_, _) => changes++;

        var choices = await tab.GetDatabaseChoicesAsync();

        Assert.NotNull(choices);
        Assert.Equal<string>(["shop", "inventory"], choices.UserDatabases);
        Assert.Equal<string>(["mysql"], choices.SystemDatabases);
        Assert.Equal("shop", choices.Current);
        Assert.Equal("shop", tab.ShownDatabase);
        Assert.Equal(1, changes);
    }

    [Fact]
    public async Task TheConnectionsOwnDatabaseIsTheOneShownUntilTheTabPicksAnother()
    {
        _session.Database = "shop";
        _session.ServerDatabases.Add(new SchemaEntry("inventory", IsDefault: true, IsSystem: false));
        var tab = Tab(null);

        var choices = await tab.GetDatabaseChoicesAsync();

        Assert.Equal("shop", choices?.Current);
        Assert.Equal("shop", tab.ShownDatabase);
    }

    [Fact]
    public async Task APickWithNoEditorOpenIsWhereTheFirstRunOpensIt()
    {
        var tab = Tab(null);

        await tab.PickDatabaseAsync("inventory");

        Assert.Empty(_session.Editors);
        Assert.Equal("inventory", tab.Database);
        Assert.Equal("inventory", tab.ShownDatabase);

        await tab.RunAsync();

        Assert.Equal<string?>(["inventory"], _session.EditorDatabases);
        Assert.Equal("inventory", tab.Snapshot().Database);
    }

    [Fact]
    public async Task APickMovesTheOpenEditorSoItKeepsItsConnection()
    {
        var tab = Tab(null);
        await tab.RunAsync();
        var editor = Assert.Single(_session.Editors);

        await tab.PickDatabaseAsync("inventory");
        await tab.RunAsync();

        Assert.Same(editor, Assert.Single(_session.Editors));
        Assert.Equal<string>(["inventory"], editor.Databases);
        Assert.Equal(0, editor.Disposals);
        Assert.Equal(2, editor.Runs.Count);
        Assert.Equal("inventory", tab.Database);
        Assert.False(tab.IsRunning);
    }

    // The rows came from the database before the switch, so running the statement again would read another's.
    [Fact]
    public async Task ASortAfterASwitchOrdersTheRowsHeldInsteadOfRunningAgain()
    {
        _session.Layout = DatabaseLayout.AsSchemas;
        _session.Sorted = (sql, columns, column, _) => $"{sql} order by {columns[column]}";
        var tab = Tab(null);
        await tab.RunAsync();
        var editor = Assert.Single(_session.Editors);

        await tab.PickDatabaseAsync("inventory");
        await tab.SortAsync(new GridSort(0, SortDirection.Ascending));

        Assert.Single(editor.Runs);
        Assert.Contains("sort held", _results.Shown);
    }

    [Fact]
    public async Task AnEngineThatBindsItsDatabaseAtConnectDropsTheEditorAndTheNextRunOpensOneThere()
    {
        _session.Layout = DatabaseLayout.WithSchemas;
        var tab = Tab(null);
        await tab.RunAsync();
        var first = Assert.Single(_session.Editors);
        first.DatabaseRefusal = BindsAtConnect;

        await tab.PickDatabaseAsync("analytics");

        Assert.Equal(1, first.Disposals);
        Assert.Equal("analytics", tab.Database);
        Assert.DoesNotContain(_results.Shown, shown => shown.StartsWith("error", StringComparison.Ordinal));

        await tab.RunAsync();

        Assert.Equal(2, _session.Editors.Count);
        Assert.Equal<string?>([null, "analytics"], _session.EditorDatabases);
        Assert.Single(first.Runs);
        Assert.Single(_session.Editors[1].Runs);
    }

    [Fact]
    public async Task AMoveTheServerRefusesKeepsTheOldDatabaseAndSaysWhy()
    {
        var tab = Tab("shop");
        await tab.RunAsync();
        var editor = Assert.Single(_session.Editors);
        editor.DatabaseRefusal = Errors.Of("driver.database_not_found");

        await tab.PickDatabaseAsync("inventory");

        Assert.Equal("shop", tab.Database);
        Assert.Equal(0, editor.Disposals);
        Assert.Contains("error driver.database_not_found", _results.Shown);
        Assert.True(tab.CanPickDatabase);
    }

    [Fact]
    public async Task APickWaitsWhileTheTabRuns()
    {
        var reading = new Gate();
        var run = FakeRun.Rows(1);
        run.Reading = reading;
        _session.Script = _ => run;
        var tab = Tab(null);

        var running = tab.RunAsync();
        await reading.Reached;
        Assert.False(tab.CanPickDatabase);
        await tab.PickDatabaseAsync("inventory");
        reading.Open();
        await running;

        Assert.Null(tab.Database);
        Assert.Empty(Assert.Single(_session.Editors).Databases);
        Assert.True(tab.CanPickDatabase);
    }

    [Fact]
    public async Task APickWaitsWhileTheTabHoldsATransaction()
    {
        _session.Script = _ => FakeRun.Rows(1, TransactionState.InTransaction);
        var tab = Tab(null);
        await tab.RunAsync();

        Assert.False(tab.CanPickDatabase);
        await tab.PickDatabaseAsync("inventory");

        Assert.Null(tab.Database);
        Assert.Empty(Assert.Single(_session.Editors).Databases);
    }

    [Fact]
    public async Task ATypedUseMovesTheTabWithItsEditor()
    {
        _session.Script = sql =>
        {
            if (sql == "use inventory")
            {
                _session.Editors[^1].Database = "inventory";
            }

            return FakeRun.Rows(0);
        };
        var tab = Tab(null);
        var changes = 0;
        tab.StateChanged += (_, _) => changes++;
        _view.WholeText = "use inventory";

        await tab.RunAsync();

        Assert.Equal("inventory", tab.Database);
        Assert.Equal("inventory", tab.ShownDatabase);
        Assert.Equal("inventory", tab.Snapshot().Database);
        Assert.True(changes >= 3);
        Assert.Equal("use inventory", tab.LastStatement);
    }

    [Fact]
    public async Task TheSnapshotKeepsADatabaseOnlyWhereItIsNotTheConnectionsOwn()
    {
        _session.Database = "shop";
        var tab = Tab("shop");
        Assert.Null(tab.Snapshot().Database);

        await tab.PickDatabaseAsync("inventory");
        Assert.Equal("inventory", tab.Snapshot().Database);

        await tab.PickDatabaseAsync("shop");
        Assert.Null(tab.Snapshot().Database);
        Assert.Equal("shop", tab.ShownDatabase);
    }

    private QueryTab Tab(string? database) =>
        new("Query 1", _session, _view, _results, DataModel.Relational, () => new AppSettings(), database: database);
}
