extern alias hana;

using System.Data.Common;
using System.Globalization;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Dameng;
using HanaDriver = hana::TablePro.Drivers.Hana.HanaDriver;

namespace TablePro.Drivers.Odbc.Tests;

/// <summary>
/// Against real servers, only when their environment variable holds a connection string; otherwise each test is
/// skipped. TABLEPRO_DAMENG and TABLEPRO_HANA take <c>host=...;port=...;user=...;password=...;schema=...</c>, and any
/// other key is passed to the ODBC driver as an option (for example <c>tenant=HXE</c> or <c>odbcDriver=...</c>). The
/// schema must be one the login may create and drop tables in.
/// </summary>
public sealed class IntegrationTests
{
    [Fact]
    public Task DamengRoundTrips() =>
        RoundTripAsync(new DamengDriver(), Request("TABLEPRO_DAMENG", DatabaseEngine.Dameng), "SELECT 1", "INT");

    [Fact]
    public Task HanaRoundTrips() =>
        RoundTripAsync(new HanaDriver(), Request("TABLEPRO_HANA", DatabaseEngine.SapHana), "SELECT 1 FROM DUMMY", "INTEGER");

    private static ConnectionRequest Request(string variable, DatabaseEngine engine)
    {
        var value = Environment.GetEnvironmentVariable(variable);
        Assert.SkipWhen(string.IsNullOrWhiteSpace(value), $"{variable} is not set.");

        var builder = new DbConnectionStringBuilder { ConnectionString = value };
        string? Take(string key)
        {
            if (!builder.TryGetValue(key, out var found))
            {
                return null;
            }

            builder.Remove(key);
            return Convert.ToString(found, CultureInfo.InvariantCulture);
        }

        var host = Take("host") ?? "localhost";
        var port = int.TryParse(Take("port"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var p) ? p : 0;
        var user = Take("user");
        var password = Take("password");
        var schema = Take("schema");
        var options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string key in builder.Keys)
        {
            options[key] = Convert.ToString(builder[key], CultureInfo.InvariantCulture) ?? string.Empty;
        }

        var profile = new ConnectionProfile
        {
            Name = "integration",
            Engine = engine,
            Host = host,
            Port = port,
            Username = user,
            Database = schema,
            SslMode = SslMode.Disabled,
            AdditionalOptions = options,
        };
        return ConnectionRequest.Direct(profile, password);
    }

    private static async Task RoundTripAsync(IDatabaseDriver driver, ConnectionRequest request, string selectOne, string intType)
    {
        var ct = TestContext.Current.CancellationToken;
        await using var session = await driver.ConnectAsync(request, ct);
        await session.PingAsync(ct);
        Assert.NotNull(session.DefaultSchema);
        Assert.Contains(session.DefaultSchema!, await session.GetSchemasAsync(ct));

        await using var channel = await session.OpenChannelAsync(ct);
        var single = Assert.Single(await RunAsync(channel, [selectOne], ct));
        Assert.True(single.Succeeded, single.Error);
        Assert.Equal(1, Convert.ToInt32(Assert.Single(single.ResultSets)[0, 0], CultureInfo.InvariantCulture));

        var failed = Assert.Single(await RunAsync(channel, ["SELECT * FROM \"TABLEPRO_NO_SUCH_TABLE\""], ct));
        Assert.False(failed.Succeeded);
        Assert.DoesNotContain("ERROR [", failed.Error, StringComparison.Ordinal);

        var ddl = (ISchemaDdlProvider)session;
        var table = new ObjectName(session.DefaultSchema, "TABLEPRO_ODBC_" + Guid.NewGuid().ToString("N")[..8].ToUpperInvariant());
        var create = ddl.BuildDdl(table, new CreateTable(table, [new ColumnDefinition("ID", intType, false, IsPrimaryKey: true), new ColumnDefinition("NAME", "VARCHAR(50)", Comment: "who")]));
        Assert.All(await RunAsync(channel, create, ct), r => Assert.True(r.Succeeded, r.Error));
        try
        {
            var saved = await session.SaveChangesAsync(
                table,
                [
                    new RowInsert(new Dictionary<string, object?> { ["ID"] = 1, ["NAME"] = "o'neil" }),
                    new RowInsert(new Dictionary<string, object?> { ["ID"] = 2, ["NAME"] = null }),
                    new RowUpdate(new Dictionary<string, object?> { ["ID"] = 2 }, new Dictionary<string, object?> { ["NAME"] = "two" }),
                ],
                ct);
            Assert.Equal(3, saved);

            var filter = new BrowseFilter([new FilterRule("NAME", FilterOperator.Equals, "two")]);
            Assert.Equal(1, await session.CountAsync(table, filter, ct));
            var page = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("ID", false)], 0, 10), ct);
            Assert.Equal(2, page.Rows.Count);

            await Assert.ThrowsAsync<RowCountMismatchException>(() =>
                session.SaveChangesAsync(table, [new RowDelete(new Dictionary<string, object?> { ["ID"] = 99 })], ct));

            var structure = await session.GetStructureAsync(table, ct);
            Assert.Equal(["ID"], structure.PrimaryKey);
            Assert.Equal("who", structure.Columns[1].Comment);
            Assert.Contains(await session.GetObjectsAsync(table.Schema, ct), o => o.Name == table && o.Kind == ObjectKind.Table);
            Assert.Contains("CREATE", await session.GetDefinitionAsync(new DatabaseObject(table, ObjectKind.Table), ct), StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            await RunAsync(channel, ddl.BuildDdl(table, new DropObject(new DatabaseObject(table, ObjectKind.Table))), CancellationToken.None);
        }

        var activity = (IServerActivityProvider)session;
        var sessions = await activity.GetActivityAsync(ct);
        Assert.Contains(sessions.Columns, c => string.Equals(c.Name, activity.ProcessIdColumn, StringComparison.OrdinalIgnoreCase));
        _ = await ((IUserListProvider)session).GetUsersAsync(ct);
    }

    private static async Task<List<StatementResult>> RunAsync(IQueryChannel channel, IReadOnlyList<string> statements, CancellationToken ct)
    {
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(), ct))
        {
            results.Add(result);
        }

        return results;
    }
}
