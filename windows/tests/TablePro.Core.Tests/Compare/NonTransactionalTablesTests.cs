using TablePro.Core.Compare;
using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Compare;

/// <summary>MySQL and MariaDB tables on a storage engine that ignores ROLLBACK, named in the sync review as macOS names them.</summary>
public sealed class NonTransactionalTablesTests
{
    private static readonly ObjectName Orders = new("shop", "orders");
    private static readonly ObjectName Logs = new("shop", "logs");
    private static readonly ObjectName Users = new("shop", "users");

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    private static InMemoryDatabaseSession Session(params (string Table, string Engine)[] engines)
    {
        var session = new InMemoryDatabaseSession();
        foreach (var (table, engine) in engines)
        {
            session.StorageEngines[table] = engine;
        }

        return session;
    }

    [Theory]
    [InlineData("InnoDB", true)]
    [InlineData("innodb", true)]
    [InlineData("XtraDB", true)]
    [InlineData("ndbcluster", true)]
    [InlineData("RocksDB", true)]
    [InlineData("MyISAM", false)]
    [InlineData("MEMORY", false)]
    [InlineData("ARCHIVE", false)]
    [InlineData("Aria", false)]
    [InlineData("CSV", false)]
    [InlineData(null, true)]
    [InlineData("", true)]
    public void OnlyTransactionalStorageEnginesRollBack(string? engine, bool canRollBack) =>
        Assert.Equal(canRollBack, DataSyncTransactionality.CanRollBack(engine));

    [Fact]
    public async Task TablesOnEnginesThatIgnoreRollbackAreNamedInTheOrderGiven()
    {
        var session = Session(("orders", "MyISAM"), ("users", "InnoDB"), ("logs", "MEMORY"));

        var found = await DataSyncTransactionality.NonTransactionalTablesAsync(session, [Orders, Users, Logs, new ObjectName("shop", "views_have_none")], Token);

        Assert.Equal([new NonTransactionalTable(Orders, "MyISAM"), new NonTransactionalTable(Logs, "MEMORY")], found);
    }

    [Fact]
    public async Task ASessionWhoseTablesChooseNoEngineIsNotAsked()
    {
        var table = new InMemoryTableSession(InMemoryTableSession.Table("orders", ["id"], "id"), []);
        var session = Session(("orders", "MyISAM"));

        Assert.Empty(await DataSyncTransactionality.NonTransactionalTablesAsync(table, [Orders], Token));
        Assert.Empty(await DataSyncTransactionality.NonTransactionalTablesAsync(session, [], Token));
        Assert.Equal(0, session.StorageEngineReads);
    }

    [Fact]
    public async Task AllTransactionalTablesLeaveNoNote()
    {
        var session = Session(("orders", "InnoDB"));

        var found = await DataSyncTransactionality.NonTransactionalTablesAsync(session, [Orders, Orders], Token);

        Assert.Empty(found);
        Assert.Null(DataSyncTransactionality.ReviewNote(found));
    }

    [Fact]
    public void TheReviewNoteNamesEachTableWithItsEngine()
    {
        Assert.Equal(
            "shop.orders (MyISAM) uses a storage engine that cannot roll back, so if the sync fails, the rows already written there stay.",
            DataSyncTransactionality.ReviewNote([new NonTransactionalTable(Orders, "MyISAM")]));
        Assert.Equal(
            "shop.orders (MyISAM), shop.logs (MEMORY) use storage engines that cannot roll back, so if the sync fails, the rows already written there stay.",
            DataSyncTransactionality.ReviewNote([new NonTransactionalTable(Orders, "MyISAM"), new NonTransactionalTable(Logs, "MEMORY")]));
    }

    [Fact]
    public void AfterARollbackOnlyTheTablesWrittenToAreNamed()
    {
        NonTransactionalTable[] tables = [new(Orders, "MyISAM"), new(Logs, "MEMORY")];

        Assert.Equal(
            "The run was rolled back, but shop.logs cannot roll back, so the rows already written there stay. Compare again to see where the target stands.",
            DataSyncTransactionality.RollbackLeftWritesNote(tables, [Users, Logs]));
        Assert.Null(DataSyncTransactionality.RollbackLeftWritesNote(tables, [Users]));
        Assert.Null(DataSyncTransactionality.RollbackLeftWritesNote([], [Orders]));
    }
}
