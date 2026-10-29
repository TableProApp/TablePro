using System.Diagnostics;
using System.Globalization;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Principals;
using TablePro.Core.Schema;
using TablePro.Drivers.MySql;

namespace TablePro.Drivers.Tests.Live;

/// <summary>What MySQL and MariaDB share; each runs against its own server.</summary>
public abstract class MySqlFamilyServerTests : RelationalServerTests
{
    protected override IDatabaseDriver Driver { get; } = new MySqlDriver();

    protected override string IntType => "INT";

    protected override string TextType => "VARCHAR(100)";

    protected override string DecimalType => "DECIMAL(10,2)";

    protected override string TimestampType => "DATETIME";

    // A join this large fails with "Query execution was interrupted" when killed. SLEEP returns 1 instead, which
    // ACancelledSleepIsReportedAsCancelled covers.
    protected override string SleepStatement =>
        "SELECT COUNT(*) FROM information_schema.columns a, information_schema.columns b, information_schema.columns c";

    protected override string ConnectionIdStatement => "SELECT CONNECTION_ID()";

    protected override PrivilegeScope TableScope(IDatabaseSession session, ObjectName table) =>
        PrivilegeScope.ForTable(table.Schema!, null, table.Name);

    /// <summary>
    /// KILL QUERY makes SLEEP return 1 instead of failing, which showed the cancelled statement as a success and the next
    /// one as cancelled. The tab reports the statement as cancelled, runs nothing after it and stays usable.
    /// </summary>
    [Fact]
    public async Task ACancelledSleepIsReportedAsCancelled()
    {
        await using var session = await ConnectAsync();
        await using var channel = await session.OpenChannelAsync(Ct);
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(Ct);
        cancel.CancelAfter(TimeSpan.FromMilliseconds(750));
        var clock = Stopwatch.StartNew();

        var results = await RunUntilAsync(channel, ["SELECT SLEEP(30)", SelectOne], stopOnError: false, cancel.Token);

        Assert.InRange(clock.Elapsed, TimeSpan.Zero, TimeSpan.FromSeconds(15));
        var cancelled = Assert.Single(results);
        Assert.False(cancelled.Succeeded);
        Assert.False(string.IsNullOrEmpty(cancelled.Error));

        var after = Assert.Single(await RunAsync(channel, ["SELECT 2"]));
        Assert.True(after.Succeeded, after.Error);
        Assert.Equal(2L, Convert.ToInt64(after.ResultSets[0][0, 0], CultureInfo.InvariantCulture));
    }

    [Fact]
    public async Task ListsViewsRoutinesAndTriggers()
    {
        await using var session = await ConnectAsync();
        var table = await CreateItemsAsync(session, 2);
        var view = TableIn(session, NewName("tp_view_"));
        var function = NewName("tp_fn_");
        var procedure = NewName("tp_proc_");
        var trigger = NewName("tp_trg_");
        var qualified = session.Dialect.Qualify(table);
        await ExecAsync(
            session,
            $"CREATE VIEW {session.Dialect.Qualify(view)} AS SELECT id, name FROM {qualified}",
            $"CREATE FUNCTION {function}(x INT) RETURNS INT DETERMINISTIC RETURN x * 2",
            $"CREATE PROCEDURE {procedure}() SELECT 1",
            $"CREATE TRIGGER {trigger} BEFORE INSERT ON {qualified} FOR EACH ROW SET NEW.note = COALESCE(NEW.note, 'auto')");
        try
        {
            var objects = await session.GetObjectsAsync(table.Schema, Ct);
            Assert.Equal(ObjectKind.View, Assert.Single(objects, o => o.Name == view).Kind);
            Assert.Equal(ObjectKind.Function, Assert.Single(objects, o => o.Name.Name == function).Kind);
            Assert.Equal(ObjectKind.Procedure, Assert.Single(objects, o => o.Name.Name == procedure).Kind);
            Assert.Equal(trigger, Assert.Single((await session.GetStructureAsync(table, Ct)).Triggers).Name);

            foreach (var obj in objects.Where(o => o.Name == view || o.Name.Name == function || o.Name.Name == procedure))
            {
                Assert.Contains("CREATE", await session.GetDefinitionAsync(obj, Ct), StringComparison.OrdinalIgnoreCase);
            }

            await session.SaveChangesAsync(table, [new RowInsert(new Dictionary<string, object?> { ["id"] = 3, ["name"] = "three" })], Ct);
            Assert.Equal(1, await session.CountAsync(table, new BrowseFilter([new FilterRule("note", FilterOperator.Equals, "auto")]), Ct));

            var viewPage = await session.BrowseAsync(new BrowseRequest(view, BrowseFilter.None, [new SortColumn("id", true)], 0, 2), Ct);
            Assert.Equal(2, viewPage.RowCount);
        }
        finally
        {
            await ExecAsync(session, $"DROP VIEW IF EXISTS {session.Dialect.Qualify(view)}", $"DROP FUNCTION IF EXISTS {function}", $"DROP PROCEDURE IF EXISTS {procedure}");
            await DropQuietlyAsync(session, table);
        }
    }

    [Fact]
    public async Task SavesCommonTypesAsTheGridParsesThem()
    {
        await using var session = await ConnectAsync();
        var table = TableIn(session, NewName("tp_types_"));
        await ExecAsync(
            session,
            $"""
            CREATE TABLE {session.Dialect.Qualify(table)} (
              id INT PRIMARY KEY, doc JSON, mood ENUM('sad', 'happy'), flags SET('a', 'b'), bin VARBINARY(16),
              flag TINYINT(1), at TIMESTAMP NULL, day DATE, t TIME, y YEAR, big BIGINT UNSIGNED, ratio DOUBLE, bits BIT(8)
            )
            """);
        try
        {
            var columns = (await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 0, 1), Ct)).Columns;
            object? Parse(string column, string text)
            {
                var clr = columns.Single(c => c.Name == column).ClrType;
                Assert.True(ValueParser.TryParse(text, clr, out var value), $"{column} ({clr}) did not parse '{text}'.");
                return value;
            }

            await session.SaveChangesAsync(table, [new RowInsert(new Dictionary<string, object?>
            {
                ["id"] = Parse("id", "1"),
                ["doc"] = Parse("doc", """{"a": [1, 2]}"""),
                ["mood"] = Parse("mood", "happy"),
                ["flags"] = Parse("flags", "a,b"),
                ["flag"] = Parse("flag", "1"),
                ["at"] = Parse("at", "2024-05-01 10:00:00"),
                ["day"] = Parse("day", "2024-05-01"),
                ["t"] = Parse("t", "10:30:00"),
                ["y"] = Parse("y", "2024"),
                ["big"] = Parse("big", "18446744073709551615"),
                ["ratio"] = Parse("ratio", "0.5"),
            })], Ct);

            var row = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 0, 1), Ct);
            var key = new Dictionary<string, object?> { ["id"] = row.Rows[0][0] };
            await session.SaveChangesAsync(table, [new RowUpdate(key, new Dictionary<string, object?> { ["mood"] = Parse("mood", "sad"), ["doc"] = Parse("doc", """{"a": 3}""") })], Ct);
            Assert.Equal(1, await session.CountAsync(table, new BrowseFilter([new FilterRule("mood", FilterOperator.Equals, "sad")]), Ct));
            Assert.Equal(1, await session.CountAsync(table, new BrowseFilter([new FilterRule("big", FilterOperator.Equals, "18446744073709551615")]), Ct));
        }
        finally
        {
            await DropQuietlyAsync(session, table);
        }
    }
}

/// <summary>MySQL against TABLEPRO_MYSQL, for example <c>host=localhost;port=3306;user=root;password=TablePro-test-1;database=tablepro</c>.</summary>
public sealed class MySqlServerTests : MySqlFamilyServerTests
{
    protected override string Variable => "TABLEPRO_MYSQL";

    protected override DatabaseEngine Engine => DatabaseEngine.MySql;
}

/// <summary>MariaDB against TABLEPRO_MARIADB, for example <c>host=localhost;port=3307;user=root;password=TablePro-test-1;database=tablepro</c>.</summary>
public sealed class MariaDbServerTests : MySqlFamilyServerTests
{
    protected override string Variable => "TABLEPRO_MARIADB";

    protected override DatabaseEngine Engine => DatabaseEngine.MariaDb;
}
