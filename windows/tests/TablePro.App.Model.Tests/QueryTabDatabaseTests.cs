using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class QueryTabDatabaseTests
{
    private readonly FakeSession _session = new();
    private readonly FakeQueryView _view = new();
    private readonly FakeResults _results = new();

    [Fact]
    public async Task ATabOpenedForADatabaseMovesItsEditorThereBeforeTheFirstRun()
    {
        var tab = Tab("shop");

        await tab.RunAsync();
        await tab.RunAsync();

        var editor = Assert.Single(_session.Editors);
        Assert.Equal<string>(["shop"], editor.Databases);
        Assert.Equal<string>(["select * from Artist", "select * from Artist"], editor.Runs);
        Assert.Equal("shop", tab.Snapshot().Database);
    }

    [Fact]
    public async Task AMoveTheEngineRefusesSendsNothingAndSaysWhy()
    {
        _session.DatabaseRefusal = new CoreError(
            "driver.unsupported", ["operation.driver", "driver.unsupported"], "refused", null, null);
        var tab = Tab("shop");

        await tab.RunAsync();

        var editor = Assert.Single(_session.Editors);
        Assert.Empty(editor.Runs);
        Assert.Equal(1, editor.Disposals);
        Assert.Contains("error driver.unsupported", _results.Shown);
        Assert.False(tab.IsRunning);
    }

    [Fact]
    public async Task ATabWithNoDatabaseRunsWhereTheConnectionIs()
    {
        var tab = Tab(null);

        await tab.RunAsync();

        var editor = Assert.Single(_session.Editors);
        Assert.Empty(editor.Databases);
        Assert.Null(tab.Snapshot().Database);
    }

    private QueryTab Tab(string? database) =>
        new("Query 1", _session, _view, _results, DataModel.Relational, () => new AppSettings(), database: database);
}
