using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Results;
using TablePro.Core.Sql;
using TablePro.Mcp.Audit;

namespace TablePro.Mcp.Tests;

public sealed class ConnectionToolTests
{
    [Fact]
    public async Task BlockedConnectionsAreInvisible()
    {
        await using var harness = await ServerHarness.StartAsync();
        var visible = ServerHarness.Profile("Analytics", ExternalAccessLevel.ReadOnly);
        var writable = ServerHarness.Profile("billing", ExternalAccessLevel.ReadWrite, DatabaseEngine.MySql);
        var blocked = ServerHarness.Profile("Payroll", ExternalAccessLevel.Blocked);
        harness.Host.Add(visible);
        harness.Host.Add(writable, open: false);
        harness.Host.Add(blocked);

        var list = await harness.CallAsync("list_connections");
        var blockedCall = await harness.CallAsync("describe_table", new JsonObject { ["connection_id"] = blocked.Id.ToString(), ["table"] = "salaries" });
        var missingCall = await harness.CallAsync("list_schemas", new JsonObject { ["connection_id"] = Guid.NewGuid().ToString() });

        var connections = list.Json.GetProperty("connections").EnumerateArray().ToArray();
        Assert.False(list.IsError);
        Assert.Equal(["Analytics", "billing"], connections.Select(c => c.GetProperty("name").GetString()));
        Assert.True(connections[0].GetProperty("is_open").GetBoolean());
        Assert.False(connections[1].GetProperty("is_open").GetBoolean());
        Assert.Equal("read_only", connections[0].GetProperty("external_access").GetString());
        Assert.Equal("read_write", connections[1].GetProperty("external_access").GetString());
        Assert.Equal("PostgreSQL", connections[0].GetProperty("type").GetString());
        Assert.DoesNotContain("Payroll", list.Text, StringComparison.Ordinal);
        Assert.True(blockedCall.IsError);
        Assert.StartsWith("not_found:", blockedCall.Text, StringComparison.Ordinal);
        Assert.Equal(missingCall.Text.Split(' ')[0], blockedCall.Text.Split(' ')[0]);
    }

    [Fact]
    public async Task HostFailureBecomesAnAuditedToolError()
    {
        await using var harness = await ServerHarness.StartAsync();
        harness.Host.ProfilesFailure = new FormatException("connections.json is damaged");

        var result = await harness.CallAsync("list_connections");

        Assert.True(result.IsError);
        Assert.Equal("internal_failure: connections.json is damaged", result.Text);
        var entry = Assert.Single(harness.Server.AuditLog.Snapshot());
        Assert.Equal(McpAuditOutcome.Failed, entry.Outcome);
        Assert.Equal("list_connections", entry.Tool);
    }

    [Fact]
    public async Task UnknownArgumentIsRefused()
    {
        await using var harness = await ServerHarness.StartAsync();

        var result = await harness.CallAsync("list_connections", new JsonObject { ["filter"] = "x" });

        Assert.True(result.IsError);
        Assert.StartsWith("invalid_argument: unknown argument filter", result.Text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ConnectOpensThroughTheHost()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadOnly);
        harness.Host.Add(profile, open: false);
        var opened = new FakeSession(profile);
        var attempts = 0;
        harness.Host.Open = _ => ++attempts == 1 ? McpOpenResult.Connecting() : McpOpenResult.Open(opened);

        var first = await harness.CallAsync("connect", new JsonObject { ["connection_id"] = profile.Id.ToString() });
        var second = await harness.CallAsync("connect", new JsonObject { ["connection_id"] = profile.Id.ToString() });

        Assert.Equal("connecting", first.Json.GetProperty("status").GetString());
        Assert.Equal("open", second.Json.GetProperty("status").GetString());
        Assert.Equal("16.4", second.Json.GetProperty("server_version").GetString());
    }

    [Fact]
    public async Task ToolsOnAClosedConnectionAskForConnect()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadOnly);
        harness.Host.Add(profile, open: false);

        var result = await harness.CallAsync("list_tables", new JsonObject { ["connection_id"] = profile.Id.ToString() });

        Assert.True(result.IsError);
        Assert.StartsWith("not_connected:", result.Text, StringComparison.Ordinal);
        Assert.Contains("call connect first", result.Text, StringComparison.Ordinal);
    }
}

public sealed class SchemaToolTests
{
    [Fact]
    public async Task SchemaToolsDescribeTheCatalog()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadOnly);
        var session = harness.Host.Add(profile);
        session.AddTable(ServerHarness.Users());
        var id = profile.Id.ToString();

        var schemas = await harness.CallAsync("list_schemas", new JsonObject { ["connection_id"] = id });
        var tables = await harness.CallAsync("list_tables", new JsonObject { ["connection_id"] = id });
        var described = await harness.CallAsync("describe_table", new JsonObject { ["connection_id"] = id, ["table"] = "users" });
        var ddl = await harness.CallAsync("get_table_ddl", new JsonObject { ["connection_id"] = id, ["table"] = "users", ["schema"] = "public" });
        var missing = await harness.CallAsync("describe_table", new JsonObject { ["connection_id"] = id, ["table"] = "nope" });

        Assert.Equal("public", schemas.Json.GetProperty("default_schema").GetString());
        Assert.Equal(2, schemas.Json.GetProperty("schemas").GetArrayLength());
        var table = Assert.Single(tables.Json.GetProperty("tables").EnumerateArray());
        Assert.Equal("users", table.GetProperty("name").GetString());
        Assert.Equal(42, table.GetProperty("row_estimate").GetInt64());
        var columns = described.Json.GetProperty("columns").EnumerateArray().ToArray();
        Assert.Equal(["id", "Email", "age"], columns.Select(c => c.GetProperty("name").GetString()));
        Assert.True(columns[0].GetProperty("primary_key").GetBoolean());
        Assert.Equal("id", described.Json.GetProperty("primary_key")[0].GetString());
        Assert.StartsWith("CREATE TABLE public.users", ddl.Json.GetProperty("ddl").GetString(), StringComparison.Ordinal);
        Assert.True(missing.IsError);
        Assert.StartsWith("not_found:", missing.Text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task BrowseBindsFiltersOnKnownColumnsOnly()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadOnly);
        var session = harness.Host.Add(profile);
        session.AddTable(ServerHarness.Users());
        var id = profile.Id.ToString();

        var ok = await harness.CallAsync("browse_table", new JsonObject
        {
            ["connection_id"] = id,
            ["table"] = "users",
            ["filters"] = new JsonArray(
                new JsonObject { ["column"] = "email", ["operator"] = "contains", ["value"] = "@example.com" },
                new JsonObject { ["column"] = "age", ["operator"] = "between", ["values"] = new JsonArray("18", "30" ) },
                new JsonObject { ["column"] = "id", ["operator"] = "in", ["values"] = new JsonArray("1", "2", "3") }),
            ["logic"] = "or",
            ["sort"] = new JsonArray(new JsonObject { ["column"] = "age", ["direction"] = "descending" }),
            ["limit"] = 10,
            ["offset"] = 20,
        });
        var unknownColumn = await harness.CallAsync("browse_table", new JsonObject
        {
            ["connection_id"] = id,
            ["table"] = "users",
            ["filters"] = new JsonArray(new JsonObject { ["column"] = "1=1; DROP TABLE users; --", ["operator"] = "eq", ["value"] = "x" }),
        });
        var tooMany = await harness.CallAsync("browse_table", new JsonObject { ["connection_id"] = id, ["table"] = "users", ["limit"] = 1001 });

        Assert.False(ok.IsError, ok.Text);
        var request = Assert.Single(session.BrowseRequests);
        Assert.Equal(10, request.Limit);
        Assert.Equal(20, request.Offset);
        Assert.False(request.Filter.MatchAll);
        Assert.Null(request.Filter.RawWhere);
        Assert.Equal([("Email", FilterOperator.Contains), ("age", FilterOperator.Between), ("id", FilterOperator.In)], request.Filter.Rules.Select(r => (r.Column!, r.Operator)));
        Assert.Equal("30", request.Filter.Rules[1].SecondValue);
        Assert.Equal("1,2,3", request.Filter.Rules[2].Value);
        Assert.Equal(new SortColumn("age", true), Assert.Single(request.Sort));
        var result = ok.Json.GetProperty("result");
        Assert.Equal(10, result.GetProperty("row_count").GetInt32());
        Assert.True(result.GetProperty("truncated").GetBoolean());
        Assert.True(unknownColumn.IsError);
        Assert.StartsWith("invalid_argument:", unknownColumn.Text, StringComparison.Ordinal);
        Assert.True(tooMany.IsError);
        Assert.Contains("limit must be 1 to 1000", tooMany.Text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CountRowsAnswersTheCount()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadOnly);
        harness.Host.Add(profile).AddTable(ServerHarness.Users());

        var result = await harness.CallAsync("count_rows", new JsonObject { ["connection_id"] = profile.Id.ToString(), ["table"] = "users" });

        Assert.Equal(1234, result.Json.GetProperty("row_count").GetInt64());
    }
}

public sealed class ExecuteQueryTests
{
    [Fact]
    public async Task ReadOnlyRefusesWritesWithoutRunningThem()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadOnly);
        var session = harness.Host.Add(profile);

        var delete = await Execute(harness, profile, "DELETE FROM users WHERE id = 1");
        var hidden = await Execute(harness, profile, "WITH gone AS (DELETE FROM users RETURNING *) SELECT * FROM gone");

        Assert.StartsWith("denied:", delete.Text, StringComparison.Ordinal);
        Assert.StartsWith("denied:", hidden.Text, StringComparison.Ordinal);
        Assert.Empty(session.Executed);
        Assert.Empty(harness.Host.ApprovalRequests);
        Assert.Empty(harness.Host.History);
        var audit = harness.Server.AuditLog.Snapshot();
        Assert.All(audit, e => Assert.Equal(McpAuditOutcome.Denied, e.Outcome));
        Assert.Equal("DELETE FROM users WHERE id = 1", audit[0].Sql);
        Assert.Equal(profile.Id, audit[0].ConnectionId);
    }

    [Fact]
    public async Task ReadRunsInsideAReadOnlyTransactionWithoutAsking()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadOnly);
        var session = harness.Host.Add(profile);

        var result = await Execute(harness, profile, "SELECT 1;");

        Assert.False(result.IsError, result.Text);
        Assert.Equal(["BEGIN READ ONLY", "SELECT 1", "ROLLBACK"], session.Executed);
        Assert.All(session.Channels, c => Assert.True(c.Disposed));
        Assert.Empty(harness.Host.ApprovalRequests);
        Assert.Equal("read", result.Json.GetProperty("statement_kind").GetString());
        var history = Assert.Single(harness.Host.History);
        Assert.True(history.Succeeded);
        Assert.Equal("SELECT 1", history.Sql);
    }

    [Fact]
    public async Task SqliteReadSetsAndClearsQueryOnly()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Local", ExternalAccessLevel.ReadOnly, DatabaseEngine.Sqlite);
        var session = harness.Host.Add(profile);
        session.Execute = (sql, _) => sql == "SELECT boom"
            ? new StatementResult(sql, [], -1, TimeSpan.Zero, "no such column: boom")
            : new StatementResult(sql, [], -1, TimeSpan.Zero);

        var failed = await Execute(harness, profile, "SELECT boom");

        Assert.StartsWith("query_failed: no such column: boom", failed.Text, StringComparison.Ordinal);
        Assert.Equal(["PRAGMA query_only = ON", "SELECT boom", "PRAGMA query_only = OFF"], session.Executed);
        Assert.Equal("no such column: boom", Assert.Single(harness.Host.History).Error);
    }

    [Fact]
    public async Task ReadWriteAsksForEachWriteAndRunsItOnApproval()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadWrite);
        var session = harness.Host.Add(profile);
        session.Execute = (sql, _) => new StatementResult(sql, [], 3, TimeSpan.Zero);
        harness.Host.Approve = (_, _) => Task.FromResult(true);

        var result = await Execute(harness, profile, "UPDATE users SET age = age + 1");

        Assert.False(result.IsError, result.Text);
        var approval = Assert.Single(harness.Host.ApprovalRequests);
        Assert.Equal("UPDATE users SET age = age + 1", approval.Sql);
        Assert.Equal(StatementKind.Write, approval.Kind);
        Assert.True(approval.IsDestructive);
        Assert.Equal(["UPDATE users SET age = age + 1"], session.Executed);
        Assert.Equal(int.MaxValue, session.Channels[0].Options[0].RowLimit);
        Assert.Equal(3, result.Json.GetProperty("rows_affected").GetInt32());
        Assert.Equal(3, Assert.Single(harness.Host.History).RowsAffected);
    }

    [Fact]
    public async Task DeclinedWriteNeverRuns()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadWrite);
        var session = harness.Host.Add(profile);
        harness.Host.Approve = (_, _) => Task.FromResult(false);

        var result = await Execute(harness, profile, "DELETE FROM users WHERE id = 7");

        Assert.StartsWith("user_cancelled:", result.Text, StringComparison.Ordinal);
        Assert.Empty(session.Executed);
        Assert.Equal(McpAuditOutcome.Cancelled, Assert.Single(harness.Server.AuditLog.Snapshot()).Outcome);
    }

    [Fact]
    public async Task LevelLoweredWhileTheQuestionWasOpenWins()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadWrite);
        var session = harness.Host.Add(profile);
        harness.Host.Approve = (_, _) =>
        {
            harness.Host.Replace(profile with { ExternalAccess = ExternalAccessLevel.ReadOnly });
            return Task.FromResult(true);
        };

        var result = await Execute(harness, profile, "INSERT INTO users (id) VALUES (1)");

        Assert.StartsWith("denied:", result.Text, StringComparison.Ordinal);
        Assert.Empty(session.Executed);
    }

    [Fact]
    public async Task SafeModeReadOnlyRefusesWritesEvenWithReadWriteAccess()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadWrite, safeMode: SafeModeLevel.ReadOnly);
        var session = harness.Host.Add(profile);
        harness.Host.Approve = (_, _) => Task.FromResult(true);

        var result = await Execute(harness, profile, "DROP TABLE users");

        Assert.StartsWith("denied:", result.Text, StringComparison.Ordinal);
        Assert.Contains("Safe Mode", result.Text, StringComparison.Ordinal);
        Assert.Empty(harness.Host.ApprovalRequests);
        Assert.Empty(session.Executed);
    }

    [Fact]
    public async Task MultipleStatementsAreRefused()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadWrite);
        var session = harness.Host.Add(profile);

        var result = await Execute(harness, profile, "SELECT 1; DROP TABLE users");

        Assert.StartsWith("invalid_argument:", result.Text, StringComparison.Ordinal);
        Assert.Empty(session.Executed);
    }

    [Fact]
    public async Task AnswerKeepsTwentyResultSetsOfTheAskedRows()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadOnly);
        var session = harness.Host.Add(profile);
        session.Execute = (sql, options) => sql == "SELECT * FROM many"
            ? new StatementResult(sql, [.. Enumerable.Range(0, 25).Select(_ => Rows(options.RowLimit + 1))], -1, TimeSpan.Zero)
            : new StatementResult(sql, [], -1, TimeSpan.Zero);

        var result = await Execute(harness, profile, "SELECT * FROM many", maxRows: 7, timeout: 60);

        Assert.False(result.IsError, result.Text);
        var sets = result.Json.GetProperty("result_sets").EnumerateArray().ToArray();
        Assert.Equal(20, sets.Length);
        Assert.Equal(5, result.Json.GetProperty("result_sets_omitted").GetInt32());
        Assert.All(sets, s =>
        {
            Assert.Equal(7, s.GetProperty("rows").GetArrayLength());
            Assert.True(s.GetProperty("truncated").GetBoolean());
        });
        var options = session.Channels[0].Options[1];
        Assert.Equal(7, options.RowLimit);
        Assert.Equal(60, options.CommandTimeoutSeconds);
    }

    [Theory]
    [InlineData(0, 30)]
    [InlineData(1001, 30)]
    [InlineData(100, 0)]
    [InlineData(100, 301)]
    public async Task LimitsOutsideTheirRangeAreRefused(int maxRows, int timeout)
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadOnly);
        var session = harness.Host.Add(profile);

        var result = await Execute(harness, profile, "SELECT 1", maxRows, timeout);

        Assert.StartsWith("invalid_argument:", result.Text, StringComparison.Ordinal);
        Assert.Empty(session.Executed);
    }

    [Fact]
    public async Task DefaultsAndMaximumsMatchTheDocumentedLimits()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadOnly);
        var session = harness.Host.Add(profile);

        await harness.CallAsync("execute_query", new JsonObject { ["connection_id"] = profile.Id.ToString(), ["query"] = "SELECT 1" });
        await Execute(harness, profile, "SELECT 2", maxRows: 1000, timeout: 300);

        Assert.Equal(100, session.Channels[0].Options[1].RowLimit);
        Assert.Equal(30, session.Channels[0].Options[1].CommandTimeoutSeconds);
        Assert.Equal(1000, session.Channels[1].Options[1].RowLimit);
        Assert.Equal(300, session.Channels[1].Options[1].CommandTimeoutSeconds);
    }

    [Fact]
    public async Task ValuesKeepTheirJsonTypes()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadOnly, DatabaseEngine.SqlServer);
        var session = harness.Host.Add(profile);
        session.Execute = (sql, _) => new StatementResult(sql,
            [new ResultSet(
                [new("i", "int", typeof(int)), new("d", "float", typeof(double)), new("b", "bit", typeof(bool)), new("n", "text", typeof(string)), new("x", "varbinary", typeof(byte[])), new("t", "datetime2", typeof(DateTime)), new("nan", "float", typeof(double))],
                [[42, 1.5, true, null, new byte[] { 0xCA, 0xFE }, new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Unspecified), double.NaN]])],
            -1, TimeSpan.Zero);

        var result = await Execute(harness, profile, "SELECT * FROM t");

        var row = result.Json.GetProperty("result_sets")[0].GetProperty("rows")[0];
        Assert.Equal(42, row[0].GetInt32());
        Assert.Equal(1.5, row[1].GetDouble());
        Assert.True(row[2].GetBoolean());
        Assert.Equal(JsonValueKind.Null, row[3].ValueKind);
        Assert.Equal("0xCAFE", row[4].GetString());
        Assert.Equal("2026-01-02T03:04:05.0000000", row[5].GetString());
        Assert.Equal("NaN", row[6].GetString());
        Assert.Equal(["SELECT * FROM t"], session.Executed);
    }

    [Fact]
    public async Task StatementPastItsTimeoutReportsATimeout()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Shop", ExternalAccessLevel.ReadOnly, DatabaseEngine.DuckDb);
        var session = harness.Host.Add(profile);
        session.Delay = ct => Task.Delay(Timeout.Infinite, ct);

        var result = await Execute(harness, profile, "SELECT slow()", timeout: 1);

        Assert.StartsWith("timeout: the statement ran past 1 seconds", result.Text, StringComparison.Ordinal);
        Assert.True(Assert.Single(harness.Host.History).Error is not null);
    }

    private static Task<ToolResult> Execute(ServerHarness harness, ConnectionProfile profile, string sql, int? maxRows = null, int? timeout = null)
    {
        var args = new JsonObject { ["connection_id"] = profile.Id.ToString(), ["query"] = sql };
        if (maxRows is not null)
        {
            args["max_rows"] = maxRows;
        }

        if (timeout is not null)
        {
            args["timeout_seconds"] = timeout;
        }

        return harness.CallAsync("execute_query", args);
    }

    private static ResultSet Rows(int count) => new(
        [new ResultColumn("n", "int", typeof(int))],
        [.. Enumerable.Range(0, count).Select(i => new object?[] { i })],
        isTruncated: true);
}
