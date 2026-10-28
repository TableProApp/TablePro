using System.Data.Common;
using System.Globalization;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.ClickHouse;
using TablePro.Drivers.Oracle;
using TablePro.Drivers.Teradata;

namespace TablePro.Drivers.Analytics.Tests;

/// <summary>
/// Runs against a live server only when its variable is set, as <c>host=...;port=...;user=...;password=...;database=...</c>
/// with optional <c>ssl=Required</c> and any engine option such as <c>sid=ORCL</c>:
/// TABLEPRO_CLICKHOUSE, TABLEPRO_ORACLE and TABLEPRO_TERADATA.
/// </summary>
public sealed class IntegrationTests
{
    private static readonly CancellationToken Token = TestContext.Current.CancellationToken;

    [Fact]
    public async Task ClickHouseCatalogBrowseAndMutations()
    {
        await using var session = await ConnectAsync("TABLEPRO_CLICKHOUSE", DatabaseEngine.ClickHouse, new ClickHouseDriver());
        var database = session.DefaultSchema!;
        var table = new ObjectName(database, "tablepro_it_" + Guid.NewGuid().ToString("N")[..8]);
        await RunAsync(session, $"CREATE TABLE {session.Dialect.Qualify(table)} (id UInt32, name String, note Nullable(String)) ENGINE = MergeTree ORDER BY id");
        try
        {
            Assert.Contains(database, await session.GetSchemasAsync(Token));
            Assert.Contains(await session.GetObjectsAsync(database, Token), o => o.Name == table && o.Kind == ObjectKind.Table);

            var structure = await session.GetStructureAsync(table, Token);
            Assert.Equal(["id"], structure.PrimaryKey);
            Assert.True(structure.Columns.Single(c => c.Name == "note").IsNullable);
            Assert.Contains(structure.Indexes, i => i.IsPrimary);

            await session.SaveChangesAsync(table, [new RowInsert(new Dictionary<string, object?> { ["id"] = "1", ["name"] = "a" })], Token);
            await session.SaveChangesAsync(table, [new RowUpdate(new Dictionary<string, object?> { ["id"] = 1 }, new Dictionary<string, object?> { ["name"] = "b" })], Token);

            var page = await session.BrowseAsync(new BrowseRequest(table, new BrowseFilter([new FilterRule("name", FilterOperator.Equals, "b")]), [], 0, 10), Token);
            Assert.Single(page.Rows);
            Assert.Equal(1, await session.CountAsync(table, new BrowseFilter([new FilterRule("id", FilterOperator.Equals, "1")]), Token));

            await Assert.ThrowsAsync<RowCountMismatchException>(() =>
                session.SaveChangesAsync(table, [new RowDelete(new Dictionary<string, object?> { ["id"] = 2 })], Token));
            await session.SaveChangesAsync(table, [new RowDelete(new Dictionary<string, object?> { ["id"] = 1 })], Token);
            Assert.Equal(0, await session.CountAsync(table, BrowseFilter.None, Token));

            Assert.StartsWith("CREATE TABLE", await session.GetDefinitionAsync(new DatabaseObject(table, ObjectKind.Table), Token), StringComparison.Ordinal);
            Assert.NotEmpty((await ((IServerVariablesProvider)session).GetVariablesAsync(Token)).Rows);
        }
        finally
        {
            await RunAsync(session, "DROP TABLE IF EXISTS " + session.Dialect.Qualify(table));
        }
    }

    [Fact]
    public async Task OracleCatalogBrowseAndPlSql()
    {
        await using var session = (OracleSession)await ConnectAsync("TABLEPRO_ORACLE", DatabaseEngine.Oracle, new OracleDriver());
        var schema = session.DefaultSchema!;
        var name = "TP_IT_" + Guid.NewGuid().ToString("N")[..8].ToUpperInvariant();
        var table = new ObjectName(schema, name);
        await RunAsync(session, $"CREATE TABLE {session.Dialect.Qualify(table)} (ID NUMBER(10) PRIMARY KEY, NAME VARCHAR2(50 CHAR) DEFAULT 'x' NOT NULL, CREATED DATE)");
        try
        {
            await session.PingAsync(Token);
            Assert.Contains(schema, await session.GetSchemasAsync(Token));
            Assert.Contains(await session.GetObjectsAsync(schema, Token), o => o.Name == table && o.Kind == ObjectKind.Table);

            var structure = await session.GetStructureAsync(table, Token);
            Assert.Equal(["ID"], structure.PrimaryKey);
            Assert.Equal("NUMBER(10)", structure.Columns[0].DataType);
            Assert.Equal("'x'", structure.Columns[1].DefaultValue);

            await session.SaveChangesAsync(table, [new RowInsert(new Dictionary<string, object?> { ["ID"] = "1", ["NAME"] = "a", ["CREATED"] = "2024-01-02 03:04:05" })], Token);
            var page = await session.BrowseAsync(new BrowseRequest(table, new BrowseFilter([new FilterRule("NAME", FilterOperator.Equals, "a")]), [], 0, 10), Token);
            Assert.Single(page.Rows);

            await using var channel = await session.OpenChannelAsync(Token);
            var statements = OracleScript.Split($"BEGIN\n  UPDATE {session.Dialect.Qualify(table)} SET NAME = 'b';\n  COMMIT;\nEND;\n/\nSELECT NAME FROM {session.Dialect.Qualify(table)};").Select(s => s.Text).ToArray();
            var results = new List<StatementResult>();
            await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(), Token))
            {
                results.Add(result);
            }

            Assert.All(results, r => Assert.True(r.Succeeded, r.Error));
            Assert.Contains("CREATE TABLE", await session.GetDefinitionAsync(new DatabaseObject(table, ObjectKind.Table), Token), StringComparison.Ordinal);
        }
        finally
        {
            await RunAsync(session, $"DROP TABLE {session.Dialect.Qualify(table)} PURGE");
        }
    }

    [Fact]
    public async Task TeradataCatalogAndBrowse()
    {
        await using var session = await ConnectAsync("TABLEPRO_TERADATA", DatabaseEngine.Teradata, new TeradataDriver());
        var schema = session.DefaultSchema!;
        var table = new ObjectName(schema, "tp_it_" + Guid.NewGuid().ToString("N")[..8]);
        await RunAsync(session, $"CREATE MULTISET TABLE {session.Dialect.Qualify(table)} (id INTEGER NOT NULL, name VARCHAR(50)) UNIQUE PRIMARY INDEX (id)");
        try
        {
            await session.PingAsync(Token);
            Assert.Contains(await session.GetObjectsAsync(schema, Token), o => o.Name.Name.Equals(table.Name, StringComparison.OrdinalIgnoreCase));
            var structure = await session.GetStructureAsync(table, Token);
            Assert.Equal(["id"], structure.PrimaryKey, StringComparer.OrdinalIgnoreCase);

            await session.SaveChangesAsync(table, [new RowInsert(new Dictionary<string, object?> { ["id"] = 1, ["name"] = "a" })], Token);
            Assert.Equal(1, await session.CountAsync(table, new BrowseFilter([new FilterRule("name", FilterOperator.Equals, "a")]), Token));
            Assert.Contains("CREATE", await session.GetDefinitionAsync(new DatabaseObject(table, ObjectKind.Table), Token), StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            await RunAsync(session, "DROP TABLE " + session.Dialect.Qualify(table));
        }
    }

    private static async Task<IDatabaseSession> ConnectAsync(string variable, DatabaseEngine engine, IDatabaseDriver driver)
    {
        var value = Environment.GetEnvironmentVariable(variable);
        Assert.SkipWhen(string.IsNullOrWhiteSpace(value), $"{variable} is not set.");

        var parts = new DbConnectionStringBuilder { ConnectionString = value };
        string? Take(string key)
        {
            if (!parts.TryGetValue(key, out var found))
            {
                return null;
            }

            parts.Remove(key);
            return Convert.ToString(found, CultureInfo.InvariantCulture);
        }

        var host = Take("host") ?? "localhost";
        var port = int.Parse(Take("port") ?? "0", CultureInfo.InvariantCulture);
        var user = Take("user");
        var password = Take("password");
        var database = Take("database");
        var ssl = Enum.Parse<SslMode>(Take("ssl") ?? nameof(SslMode.Disabled), ignoreCase: true);
        var options = parts.Keys.Cast<string>().ToDictionary(k => k, k => Convert.ToString(parts[k], CultureInfo.InvariantCulture) ?? string.Empty);

        var profile = new ConnectionProfile
        {
            Name = variable,
            Engine = engine,
            Host = host,
            Port = port,
            Username = user,
            Database = database,
            SslMode = ssl,
            AdditionalOptions = options,
        };

        return await driver.ConnectAsync(ConnectionRequest.Direct(profile, password), Token);
    }

    private static async Task RunAsync(IDatabaseSession session, string sql)
    {
        await using var channel = await session.OpenChannelAsync(Token);
        await foreach (var result in channel.ExecuteAsync([sql], new ExecuteOptions(), Token))
        {
            Assert.True(result.Succeeded, result.Error);
        }
    }
}
