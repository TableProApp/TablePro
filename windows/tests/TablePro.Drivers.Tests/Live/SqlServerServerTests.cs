using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.SqlServer;

namespace TablePro.Drivers.Tests.Live;

/// <summary>
/// SQL Server against TABLEPRO_SQLSERVER, for example
/// <c>host=localhost;port=1433;user=sa;password=TablePro-test-1;database=tablepro;trustServerCertificate=true</c>.
/// The database must exist; the test creates it when it can.
/// </summary>
public sealed class SqlServerServerTests : RelationalServerTests
{
    protected override string Variable => "TABLEPRO_SQLSERVER";

    protected override DatabaseEngine Engine => DatabaseEngine.SqlServer;

    protected override IDatabaseDriver Driver { get; } = new SqlServerDriver();

    protected override string IntType => "int";

    protected override string TextType => "nvarchar(100)";

    protected override string DecimalType => "decimal(10,2)";

    protected override string TimestampType => "datetime2";

    protected override string SleepStatement => "WAITFOR DELAY '00:00:30'";

    protected override string ConnectionIdStatement => "SELECT @@SPID";

    protected override string SessionMarkerStatement => "SELECT CONVERT(nvarchar(36), connection_id) FROM sys.dm_exec_connections WHERE session_id = @@SPID";

    protected override string? MessageStatement => "PRINT 'tablepro says hello'";

    protected override bool ServerEnforcesReadOnly => false;

    /// <summary>A count after GO sends the batch that many times, as sqlcmd and the macOS app do.</summary>
    [Fact]
    public async Task RepeatsABatchEndedByGoWithACount()
    {
        await using var session = await ConnectAsync();
        var table = await CreateItemsAsync(session, 0);
        await using var channel = await session.OpenChannelAsync(Ct);
        try
        {
            var qualified = session.Dialect.Qualify(table);
            var script = $"INSERT INTO {qualified} (id, name) SELECT COALESCE(MAX(id), 0) + 1, N'again' FROM {qualified}\nGO 3\nSELECT COUNT(*) FROM {qualified}";
            var results = await RunAsync(channel, [.. SqlScript.Runs(SqlScript.Split(script, session.Dialect))], stopOnError: true);

            Assert.Equal(4, results.Count);
            Assert.All(results, r => Assert.True(r.Succeeded, r.Error));
            Assert.Equal(3, Convert.ToInt32(results[3].ResultSets[0][0, 0], System.Globalization.CultureInfo.InvariantCulture));
        }
        finally
        {
            await DropQuietlyAsync(session, table);
        }
    }

    [Fact]
    public async Task ListsViewsRoutinesAndSchemas()
    {
        await using var session = await ConnectAsync();
        var schema = NewName("tp_schema_");
        await ExecAsync(session, $"CREATE SCHEMA {schema}");
        await ExecAsync(
            session,
            $"CREATE TABLE {schema}.orders (id int IDENTITY PRIMARY KEY, total money NOT NULL, placed datetimeoffset, tag uniqueidentifier DEFAULT NEWID(), note nvarchar(max), CONSTRAINT ck_total CHECK (total >= 0))",
            $"CREATE VIEW {schema}.big AS SELECT id, total FROM {schema}.orders WHERE total > 100",
            $"CREATE FUNCTION {schema}.twice(@x int) RETURNS int AS BEGIN RETURN @x * 2 END",
            $"CREATE PROCEDURE {schema}.touch AS SELECT 1",
            $"CREATE TRIGGER {schema}.orders_audit ON {schema}.orders AFTER INSERT AS SET NOCOUNT ON",
            $"CREATE INDEX ix_placed ON {schema}.orders (placed DESC) INCLUDE (total)");
        try
        {
            Assert.Contains(schema, await session.GetSchemasAsync(Ct));
            var objects = await session.GetObjectsAsync(schema, Ct);
            ObjectKind KindOf(string name) => Assert.Single(objects, o => o.Name.Name == name).Kind;
            Assert.Equal(ObjectKind.Table, KindOf("orders"));
            Assert.Equal(ObjectKind.View, KindOf("big"));
            Assert.Equal(ObjectKind.Function, KindOf("twice"));
            Assert.Equal(ObjectKind.Procedure, KindOf("touch"));

            var orders = new ObjectName(schema, "orders");
            var structure = await session.GetStructureAsync(orders, Ct);
            Assert.True(structure.Columns[0].IsIdentity);
            Assert.Contains(structure.Indexes, i => i.Name == "ix_placed");
            Assert.Single(structure.Triggers);
            Assert.Single((await ((ITableDetailsProvider)session).GetTableDetailsAsync(orders, Ct)).CheckConstraints);

            // The identity column is left to the server on insert, and the save still counts the row.
            Assert.Equal(1, await session.SaveChangesAsync(orders, [new RowInsert(new Dictionary<string, object?> { ["total"] = 150m, ["placed"] = DateTimeOffset.Parse("2024-05-01T10:00:00+02:00", System.Globalization.CultureInfo.InvariantCulture), ["note"] = new string('x', 5000) })], Ct));
            var page = await session.BrowseAsync(new BrowseRequest(orders, BrowseFilter.None, [], 0, 10), Ct);
            Assert.Equal(5000, ((string)page.Rows[0][page.ColumnIndex("note")]!).Length);
            Assert.Equal(1, await session.CountAsync(new ObjectName(schema, "big"), BrowseFilter.None, Ct));
            var tag = page.Rows[0][page.ColumnIndex("tag")];
            Assert.Equal(1, await session.SaveChangesAsync(orders, [new RowUpdate(new Dictionary<string, object?> { ["id"] = page.Rows[0][0] }, new Dictionary<string, object?> { ["tag"] = tag, ["total"] = 0m })], Ct));

            foreach (var name in (string[])["orders", "big", "twice", "touch"])
            {
                Assert.Contains("CREATE", await session.GetDefinitionAsync(objects.Single(o => o.Name.Name == name), Ct), StringComparison.OrdinalIgnoreCase);
            }
        }
        finally
        {
            await ExecAsync(
                session,
                $"DROP VIEW IF EXISTS {schema}.big",
                $"DROP FUNCTION IF EXISTS {schema}.twice",
                $"DROP PROCEDURE IF EXISTS {schema}.touch",
                $"DROP TABLE IF EXISTS {schema}.orders",
                $"DROP SCHEMA {schema}");
        }
    }

    [Fact]
    public async Task RunsGoBatchesThatShareTheTabsTemporaryTables()
    {
        await using var session = await ConnectAsync();
        await using var channel = await session.OpenChannelAsync(Ct);
        var batches = session.Dialect.Split("CREATE TABLE #t (n int)\nGO\nINSERT INTO #t VALUES (1); INSERT INTO #t VALUES (2)\nGO\nSELECT COUNT(*) FROM #t\nPRINT 'done'\nGO").Select(s => s.Text).ToArray();

        var results = await RunAsync(channel, batches);

        Assert.Equal(3, results.Count);
        Assert.All(results, r => Assert.True(r.Succeeded, r.Error));
        Assert.Equal(2, Convert.ToInt32(results[^1].ResultSets[0][0, 0], System.Globalization.CultureInfo.InvariantCulture));
        Assert.Contains("done", results[^1].Messages ?? []);
    }
}
