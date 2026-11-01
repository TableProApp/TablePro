using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;
using TablePro.Drivers.MySql;

namespace TablePro.Drivers.Tests;

/// <summary>The catalog read behind the sync review's note on MyISAM and other tables that ignore ROLLBACK.</summary>
public sealed class MySqlStorageEngineTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public void TheCatalogQueryBindsTheDatabaseAndEveryName()
    {
        var (sql, parameters) = MySqlSession.StorageEngineQuery("shop", [new ObjectName("shop", "orders"), new ObjectName("shop", "it's; DROP TABLE x")]);

        Assert.Equal(
            "SELECT TABLE_NAME, ENGINE\nFROM information_schema.TABLES\n"
            + "WHERE TABLE_SCHEMA = COALESCE(@schema, DATABASE()) AND ENGINE IS NOT NULL AND TABLE_NAME IN (@t0, @t1)",
            sql.ReplaceLineEndings("\n"));
        Assert.Equal([("@schema", (object?)"shop"), ("@t0", "orders"), ("@t1", "it's; DROP TABLE x")], parameters);
    }

    [Fact]
    public void AnUnqualifiedTableAsksTheConnectionsOwnDatabase()
    {
        var (_, parameters) = MySqlSession.StorageEngineQuery(null, [new ObjectName(null, "orders")]);

        Assert.Equal(("@schema", (object?)null), parameters[0]);
        Assert.Throws<ArgumentOutOfRangeException>(() => MySqlCatalog.StorageEngines(0));
    }

    [Fact]
    public void RowsAreKeyedByTheNameAsAskedPreferringAnExactSpelling()
    {
        ObjectName orders = new("shop", "Orders"), logs = new("shop", "logs"), missing = new("shop", "missing"), view = new("shop", "v");
        var engines = new Dictionary<ObjectName, string>();

        // lower_case_table_names = 1 stores "orders" and answers it for "Orders"; a view's ENGINE is NULL.
        MySqlSession.MatchStorageEngines([orders, logs, missing, view], [("orders", "MyISAM"), ("logs", "MEMORY"), ("v", null)], engines);

        Assert.Equal(new Dictionary<ObjectName, string> { [orders] = "MyISAM", [logs] = "MEMORY" }, engines);
    }

    [Fact]
    public void AnExactSpellingWinsOverACaseFoldedOne()
    {
        ObjectName lower = new(null, "t"), upper = new(null, "T");
        var engines = new Dictionary<ObjectName, string>();

        MySqlSession.MatchStorageEngines([lower, upper], [("T", "MyISAM"), ("t", "InnoDB")], engines);

        Assert.Equal("InnoDB", engines[lower]);
        Assert.Equal("MyISAM", engines[upper]);
    }

    [Theory]
    [InlineData(DatabaseEngine.TiDb)]
    [InlineData(DatabaseEngine.OceanBase)]
    [InlineData(DatabaseEngine.Databend)]
    public async Task EnginesWhoseEngineColumnSaysNothingAboutRollbackAreNotAsked(DatabaseEngine engine)
    {
        // Nothing listens on the profile's port, so an attempt to read the catalog would throw.
        await using var session = new MySqlSession(Profiles.Request(engine));

        Assert.Empty(await ((IStorageEngineProvider)session).GetStorageEnginesAsync([new ObjectName("shop", "orders")], Ct));
    }

    [Fact]
    public async Task NoTablesMeansNoRoundTrip()
    {
        await using var session = new MySqlSession(Profiles.Request(DatabaseEngine.MySql));

        Assert.Empty(await session.GetStorageEnginesAsync([], Ct));
    }
}
