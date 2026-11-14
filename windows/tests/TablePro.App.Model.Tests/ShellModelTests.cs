using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ShellModelTests
{
    private static DatabaseEngine Engine(string id, string name, EngineCategory category) =>
        new(id, name, DataModel.Relational, 1, [], category);

    [Fact]
    public void TheChooserListsEnginesByFamilyInTheMacOrderAndByNameInside()
    {
        DatabaseEngine[] engines =
        [
            Engine("sqlite", "SQLite", EngineCategory.Relational),
            Engine("cassandra", "Cassandra / ScyllaDB", EngineCategory.WideColumn),
            Engine("duckdb", "DuckDB", EngineCategory.Analytical),
            Engine("mysql", "MySQL", EngineCategory.Relational),
            Engine("redis", "Redis", EngineCategory.KeyValue),
            Engine("mongodb", "MongoDB", EngineCategory.Document),
            Engine("clickhouse", "ClickHouse", EngineCategory.Analytical),
        ];

        var sections = EngineCatalog.Sections(engines, null);

        Assert.Equal(
            [EngineCategory.Relational, EngineCategory.Document, EngineCategory.KeyValue, EngineCategory.Analytical, EngineCategory.WideColumn],
            sections.Select(section => section.Category));
        Assert.Equal(["MySQL", "SQLite"], sections[0].Engines.Select(engine => engine.DisplayName));
        Assert.Equal(["ClickHouse", "DuckDB"], sections[3].Engines.Select(engine => engine.DisplayName));
        Assert.Equal("cassandra", Assert.Single(sections[4].Engines).Id);
    }

    [Fact]
    public void AChooserSearchKeepsOnlyTheFamiliesThatHoldAMatch()
    {
        DatabaseEngine[] engines =
        [
            Engine("cassandra", "Cassandra / ScyllaDB", EngineCategory.WideColumn),
            Engine("mysql", "MySQL", EngineCategory.Relational),
        ];

        var section = Assert.Single(EngineCatalog.Sections(engines, "  scylla "));

        Assert.Equal(EngineCategory.WideColumn, section.Category);
    }

    [Fact]
    public void ReopeningAClosedTabTakesTheNewestFirstAndKeepsALimit()
    {
        var closed = new ClosedTabs();
        for (var number = 0; number < ClosedTabs.Limit + 5; number++)
        {
            closed.Push(new SessionTab { Title = $"Query {number}" }, number);
        }

        var newest = closed.Pop();

        Assert.Equal($"Query {ClosedTabs.Limit + 4}", newest?.Tab.Title);
        Assert.Equal(ClosedTabs.Limit + 4, newest?.Index);
        Assert.Equal(ClosedTabs.Limit - 1, closed.Count);
        closed.Clear();
        Assert.Null(closed.Pop());
    }

    [Fact]
    public void AFullPageWithoutACountMayHaveMoreAfterIt()
    {
        var page = TablePage.First(1000) with { Rows = 1000 };

        Assert.Equal(1, page.FirstRow);
        Assert.Equal(1000, page.LastRow);
        Assert.False(page.HasPrevious);
        Assert.True(page.HasNext);
        Assert.False(page.HasLast);
        Assert.Equal(1000, page.NextOffset);
    }

    [Fact]
    public void ACountGivesTheLastPageAndEndsNextThere()
    {
        var page = new TablePage(2000, 1000, 1000, 3503, true);
        var last = page.At(page.LastOffset) with { Rows = 503 };

        Assert.True(page.HasLast);
        Assert.Equal(3000, page.LastOffset);
        Assert.Equal(1000, page.PreviousOffset);
        Assert.Equal(3001, last.FirstRow);
        Assert.Equal(3503, last.LastRow);
        Assert.False(last.HasNext);
        Assert.False(last.HasLast);
        Assert.True(last.HasPrevious);
    }

    [Fact]
    public void AnEngineThatCannotSeekStepsAPageAtATimeUntilTheServerSaysNothingFollows()
    {
        var page = new TablePage(1000, 100, 100, null, CanSeek: false);
        var ends = page with { EndsTable = true };

        Assert.True(page.HasPrevious);
        Assert.True(page.HasNext);
        Assert.True(page.IsPaged);
        Assert.False(ends.HasNext);
        Assert.True(ends.IsPaged);
        Assert.False(ends.At(page.PreviousOffset).EndsTable);
        Assert.False((page with { Total = 5000 }).HasLast);
    }

    [Fact]
    public void AnEmptyTableShowsNoRowsAndNoPager()
    {
        var page = new TablePage(0, 100, 0, 0, true);

        Assert.Equal(0, page.FirstRow);
        Assert.False(page.IsPaged);
        Assert.Equal(0, page.LastOffset);
    }

    [Fact]
    public void ANewPageSizeKeepsThePageThatHoldsTheFirstRowShown()
    {
        var page = new TablePage(2000, 1000, 1000, 3503, true);

        var smaller = page.Resized(100);
        var larger = new TablePage(2500, 500, 500, 3503, true).Resized(1000);

        Assert.Equal(2000, smaller.Offset);
        Assert.Equal(21, smaller.Number);
        Assert.Equal(36, smaller.Count);
        Assert.Equal(2000, larger.Offset);
        Assert.Equal(0, smaller.Rows);
        Assert.Equal(1, page.Resized(0).Size);
        Assert.Equal(TablePage.MaximumSize, page.Resized(int.MaxValue).Size);
    }

    [Fact]
    public void GoingToAPageNeedsTheCountAndStaysInsideIt()
    {
        var counted = new TablePage(0, 100, 100, 3503, true);
        var uncounted = counted with { Total = null };

        Assert.Equal(36, counted.Count);
        Assert.True(counted.Accepts(36));
        Assert.False(counted.Accepts(37));
        Assert.False(counted.Accepts(0));
        Assert.Equal(200, counted.OffsetOf(3));
        Assert.Equal(3, counted.At(counted.OffsetOf(3)).Number);
        Assert.Null(uncounted.Count);
        Assert.False(uncounted.Accepts(2));
        Assert.False((counted with { CanSeek = false }).Accepts(2));
        Assert.Equal(1, (counted with { Total = 0 }).Count);
        Assert.Equal(35, (counted with { Total = 3500 }).Count);
    }

    [Fact]
    public void AllRowsPutsTheCountedTableOnOnePage()
    {
        var page = new TablePage(2000, 1000, 1000, 3503, true);

        var all = page.AllRows();

        Assert.Equal(3503, all.Size);
        Assert.Equal(0, all.Offset);
        Assert.Equal(1, all.Count);
        Assert.Equal(page with { Total = null }, (page with { Total = null }).AllRows());
        Assert.Equal(TablePage.LargestSize, (page with { Total = long.MaxValue }).AllRows().Size);
        Assert.Equal(2_000_000, TablePage.First(2_000_000).Size);
    }

    [Fact]
    public void ThePageSizeMenuOffersTheMacSizes()
    {
        Assert.Equal([5, 10, 20, 100, 500, 1_000], TablePage.Presets);
        Assert.Equal(1_000, TablePage.First(AppSettings.DefaultPageSize).Size);
    }

    [Fact]
    public void TheBarOverTheTabsNamesTheFirstOtherTabHoldingATransaction()
    {
        HeldTab[] tabs =
        [
            new("Query 1", TransactionState.InTransaction, Selected: true),
            new("Query 2", TransactionState.Idle, Selected: false),
            new("Query 3", TransactionState.Failed, Selected: false),
            new("Query 4", TransactionState.InTransaction, Selected: false),
        ];

        var elsewhere = WorkspaceNotices.Elsewhere(tabs);

        Assert.Equal(new TransactionElsewhere(2, "Query 3", TransactionState.Failed, 2), elsewhere);
        Assert.Null(WorkspaceNotices.Elsewhere([tabs[0], tabs[1]]));
    }

    [Fact]
    public void OnlyAConnectionThatIsNotOnlineHasABarAndAParkedOneOffersReconnect()
    {
        var reason = new CoreError("driver.auth", ["connect.driver", "driver.auth"], "refused", null, null);

        Assert.Null(WorkspaceNotices.For(new SessionHealth.Online()));
        Assert.Equal(new HealthNotice(HealthNoticeKind.Reconnecting, 3, null), WorkspaceNotices.For(new SessionHealth.Reconnecting(3)));
        Assert.False(WorkspaceNotices.For(new SessionHealth.Reconnecting(1))!.OffersReconnect);
        Assert.True(WorkspaceNotices.For(new SessionHealth.Offline())!.OffersReconnect);
        var failed = WorkspaceNotices.For(new SessionHealth.Failed(FailureCause.Authentication, reason));
        Assert.True(failed!.OffersReconnect);
        Assert.Equal(reason, failed.Reason);
    }

    [Fact]
    public void AKeyValueEngineEndsItsQueueWithExecOrDiscard()
    {
        Assert.Equal("COMMIT", WorkspaceNotices.EndTransaction(DataModel.Relational, commit: true));
        Assert.Equal("ROLLBACK", WorkspaceNotices.EndTransaction(DataModel.Relational, commit: false));
        Assert.Equal("EXEC", WorkspaceNotices.EndTransaction(DataModel.KeyValue, commit: true));
        Assert.Equal("DISCARD", WorkspaceNotices.EndTransaction(DataModel.KeyValue, commit: false));
    }

    [Fact]
    public void TheWindowAndThePaneWidthOutliveTheConnections()
    {
        var state = new SessionState
        {
            Window = new WindowPlacement { X = 10, Y = 20, Width = 1400, Height = 900, Maximized = true },
            ObjectPaneWidth = 5000,
        };

        var restored = state.Restorable();

        Assert.Equal(state.Window, restored.Window);
        Assert.Equal(ObjectPane.MaxWidth, restored.ObjectPaneWidth);
        Assert.Null((state with { Window = new WindowPlacement() }).Restorable().Window);
        Assert.Equal(ObjectPane.DefaultWidth, ObjectPane.Clamp(double.NaN));
    }
}
