using System.Data.Common;
using System.Diagnostics;
using System.Globalization;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Plans;
using TablePro.Core.Principals;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Tests.Live;

/// <summary>
/// What every relational engine must do against a real server, run once per engine by the derived classes. Each is
/// skipped unless its variable holds <c>host=...;port=...;user=...;password=...;database=...</c>, with any other key
/// passed on as an engine option. <c>windows/tests/live/compose.yaml</c> starts the servers.
/// </summary>
public abstract class RelationalServerTests
{
    protected static CancellationToken Ct => TestContext.Current.CancellationToken;

    protected abstract string Variable { get; }

    protected abstract DatabaseEngine Engine { get; }

    protected abstract IDatabaseDriver Driver { get; }

    protected abstract string IntType { get; }

    protected abstract string TextType { get; }

    protected abstract string DecimalType { get; }

    protected abstract string TimestampType { get; }

    /// <summary>A statement that runs for about thirty seconds unless cancelled.</summary>
    protected abstract string SleepStatement { get; }

    /// <summary>A statement returning the id the activity list shows for the connection that runs it.</summary>
    protected abstract string ConnectionIdStatement { get; }

    /// <summary>
    /// A statement naming the session that runs it uniquely over time. A process id is reused, and SQL Server hands the
    /// lowest free one to the next session, so an ended session's id can come straight back.
    /// </summary>
    protected virtual string SessionMarkerStatement => ConnectionIdStatement;

    /// <summary>A statement that makes the server send an informational message, or null when the engine has none.</summary>
    protected virtual string? MessageStatement => null;

    protected virtual bool SupportsCheckConstraints => true;

    /// <summary>The smallest query the engine takes.</summary>
    protected virtual string SelectOne => "SELECT 1";

    /// <summary>What opens a transaction in the editor, or null where one opens with the first change.</summary>
    protected virtual string? BeginStatement => Engine == DatabaseEngine.SqlServer ? "BEGIN TRANSACTION" : "BEGIN";

    /// <summary>
    /// Whether each editor statement commits on its own with no way to open a transaction, so a ROLLBACK typed in the
    /// editor undoes nothing. ODP.NET commits every command run outside a transaction it was asked to begin.
    /// </summary>
    protected virtual bool EditorAutoCommits => false;

    /// <summary>Whether the server's error for a missing table names it.</summary>
    protected virtual bool ErrorNamesTheMissingTable => true;

    /// <summary>Whether the server itself refuses writes on a read-only connection, rather than only the app's Safe Mode.</summary>
    protected virtual bool ServerEnforcesReadOnly => true;

    protected static string NewName(string prefix) => prefix + Guid.NewGuid().ToString("N")[..8];

    protected async Task<IDatabaseSession> ConnectAsync(SafeModeLevel safeMode = SafeModeLevel.Silent)
    {
        var value = Environment.GetEnvironmentVariable(Variable);
        Assert.SkipWhen(string.IsNullOrWhiteSpace(value), $"Set {Variable} to run the {Engine} server tests.");
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

        var profile = new ConnectionProfile
        {
            Name = Variable,
            Engine = Engine,
            Host = Take("host") ?? "localhost",
            Port = int.Parse(Take("port") ?? "0", CultureInfo.InvariantCulture),
            Username = Take("user"),
            Database = Take("database"),
            SslMode = Enum.Parse<SslMode>(Take("ssl") ?? nameof(SslMode.Disabled), ignoreCase: true),
            SafeMode = safeMode,
        };
        var password = Take("password");
        profile = profile with { AdditionalOptions = parts.Keys.Cast<string>().ToDictionary(k => k, k => Convert.ToString(parts[k], CultureInfo.InvariantCulture) ?? string.Empty) };
        return await Driver.ConnectAsync(ConnectionRequest.Direct(profile, password), Ct);
    }

    protected static Task<List<StatementResult>> RunAsync(IQueryChannel channel, IReadOnlyList<string> statements, bool stopOnError = false) =>
        RunUntilAsync(channel, statements, stopOnError, Ct);

    protected static async Task<List<StatementResult>> RunUntilAsync(IQueryChannel channel, IReadOnlyList<string> statements, bool stopOnError, CancellationToken cancellationToken)
    {
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(StopOnError: stopOnError), cancellationToken))
        {
            results.Add(result);
        }

        return results;
    }

    protected static async Task ExecAsync(IDatabaseSession session, params string[] statements)
    {
        await using var channel = await session.OpenChannelAsync(Ct);
        foreach (var result in await RunAsync(channel, statements, stopOnError: true))
        {
            Assert.True(result.Succeeded, result.Sql + "\n" + result.Error);
        }
    }

    protected static async Task ExecDdlAsync(IDatabaseSession session, ObjectName table, SchemaChange change)
    {
        var statements = ((ISchemaDdlProvider)session).BuildDdl(table, change);
        Assert.NotEmpty(statements);
        await ExecAsync(session, [.. statements]);
    }

    protected static async Task DropQuietlyAsync(IDatabaseSession session, params ObjectName[] tables)
    {
        await using var channel = await session.OpenChannelAsync(CancellationToken.None);
        foreach (var table in tables)
        {
            var drop = ((ISchemaDdlProvider)session).BuildDdl(table, new DropObject(new DatabaseObject(table, ObjectKind.Table)));
            await RunUntilAsync(channel, drop, stopOnError: false, CancellationToken.None);
        }
    }

    protected static ObjectName TableIn(IDatabaseSession session, string name) => new(session.DefaultSchema ?? session.CurrentDatabase, name);

    /// <summary>A table of <paramref name="rows"/> rows: id 1..n, a name, a price, a timestamp and a nullable note.</summary>
    protected async Task<ObjectName> CreateItemsAsync(IDatabaseSession session, int rows)
    {
        var table = TableIn(session, NewName("tp_items_"));
        await ExecDdlAsync(session, table, new CreateTable(table,
        [
            new ColumnDefinition("id", IntType, false, IsPrimaryKey: true),
            new ColumnDefinition("name", TextType, false),
            new ColumnDefinition("price", DecimalType),
            new ColumnDefinition("created", TimestampType),
            new ColumnDefinition("note", TextType),
        ]));
        if (rows > 0)
        {
            var start = new DateTime(2024, 1, 1, 0, 0, 0, DateTimeKind.Unspecified);
            await session.SaveChangesAsync(table, [.. Enumerable.Range(1, rows).Select(i => new RowInsert(new Dictionary<string, object?>
            {
                ["id"] = i,
                ["name"] = "item " + i.ToString("D3", CultureInfo.InvariantCulture),
                ["price"] = i * 1.25m,
                ["created"] = start.AddHours(i),
                ["note"] = i % 10 == 0 ? null : "n" + (i % 7).ToString(CultureInfo.InvariantCulture),
            }))], Ct);
        }

        return table;
    }

    [Fact]
    public async Task ConnectsAndReadsTheCatalog()
    {
        await using var session = await ConnectAsync();
        var table = await CreateItemsAsync(session, 3);
        try
        {
            await session.PingAsync(Ct);
            Assert.False(string.IsNullOrWhiteSpace(session.ServerVersion));
            Assert.NotNull(session.CurrentDatabase);
            Assert.Contains(session.CurrentDatabase!, await session.GetDatabasesAsync(Ct), StringComparer.OrdinalIgnoreCase);
            if (session.DefaultSchema is { } schema)
            {
                Assert.Contains(schema, await session.GetSchemasAsync(Ct), StringComparer.OrdinalIgnoreCase);
            }

            var objects = await session.GetObjectsAsync(table.Schema, Ct);
            var listed = Assert.Single(objects, o => o.Name == table);
            Assert.Equal(ObjectKind.Table, listed.Kind);

            var structure = await session.GetStructureAsync(table, Ct);
            Assert.Equal(["id", "name", "price", "created", "note"], structure.Columns.Select(c => c.Name));
            Assert.Equal(["id"], structure.PrimaryKey);
            Assert.False(structure.Columns[1].IsNullable);
            Assert.True(structure.Columns[4].IsNullable);
            Assert.Contains(structure.Indexes, i => i.IsPrimary && i.Columns.SequenceEqual(["id"]));

            var definition = await session.GetDefinitionAsync(listed, Ct);
            Assert.Contains("CREATE", definition, StringComparison.OrdinalIgnoreCase);
            Assert.Contains(table.Name, definition, StringComparison.Ordinal);
        }
        finally
        {
            await DropQuietlyAsync(session, table);
        }
    }

    [Fact]
    public async Task BrowsesPagesSortsFiltersAndCounts()
    {
        await using var session = await ConnectAsync();
        var table = await CreateItemsAsync(session, 120);
        try
        {
            var first = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("id", false)], 0, 50), Ct);
            Assert.Equal(50, first.RowCount);
            Assert.Equal(1, Convert.ToInt32(first.Rows[0][0], CultureInfo.InvariantCulture));

            var deep = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("id", true)], 100, 50), Ct);
            Assert.Equal(20, deep.RowCount);
            Assert.Equal(20, Convert.ToInt32(deep.Rows[0][0], CultureInfo.InvariantCulture));
            Assert.Equal(1, Convert.ToInt32(deep.Rows[^1][0], CultureInfo.InvariantCulture));

            var price = first.ColumnIndex("price");
            var created = first.ColumnIndex("created");
            Assert.Equal(1.25m, Convert.ToDecimal(first.Rows[0][price], CultureInfo.InvariantCulture));
            Assert.Equal(new DateTime(2024, 1, 1, 1, 0, 0), first.Rows[0][created] switch
            {
                DateTimeOffset offset => offset.DateTime,
                var other => Convert.ToDateTime(other, CultureInfo.InvariantCulture),
            });

            // Engines disagree on where NULLs sort, so the order is checked over the rows that have a note.
            var byNote = await session.BrowseAsync(new BrowseRequest(table, new BrowseFilter([new FilterRule("note", FilterOperator.IsNotNull)]), [new SortColumn("note", true), new SortColumn("id", false)], 0, 5), Ct);
            Assert.Equal("n6", byNote.Rows[0][byNote.ColumnIndex("note")]);

            async Task Expect(long count, params FilterRule[] rules)
            {
                var filter = new BrowseFilter(rules);
                Assert.Equal(count, await session.CountAsync(table, filter, Ct));
                Assert.Equal(count, (await session.BrowseAsync(new BrowseRequest(table, filter, [], 0, 500), Ct)).RowCount);
            }

            await Expect(1, new FilterRule("name", FilterOperator.Equals, "item 042"));
            await Expect(12, new FilterRule("note", FilterOperator.IsNull));
            await Expect(108, new FilterRule("note", FilterOperator.IsNotNull));
            await Expect(11, new FilterRule("id", FilterOperator.Between, "10", "20"));
            await Expect(21, new FilterRule("name", FilterOperator.StartsWith, "item 1"));
            await Expect(2, new FilterRule("name", FilterOperator.Contains, "item 11"), new FilterRule("id", FilterOperator.LessThan, "112"));
            await Expect(4, new FilterRule("price", FilterOperator.GreaterOrEqual, "146.25"));
            await Expect(0, new FilterRule("name", FilterOperator.Contains, "it'em"));
            Assert.Equal(13, await session.CountAsync(table, new BrowseFilter([new FilterRule("note", FilterOperator.IsNull), new FilterRule("id", FilterOperator.Equals, "1")], MatchAll: false), Ct));
            Assert.Equal(120, await session.CountAsync(table, BrowseFilter.None, Ct));
        }
        finally
        {
            await DropQuietlyAsync(session, table);
        }
    }

    [Fact]
    public async Task SavesInOneTransactionAndRollsBackAMissedRow()
    {
        await using var session = await ConnectAsync();
        var table = await CreateItemsAsync(session, 5);
        try
        {
            var saved = await session.SaveChangesAsync(table, [
                new RowUpdate(new Dictionary<string, object?> { ["id"] = 1 }, new Dictionary<string, object?> { ["name"] = "it's renamed", ["note"] = null }),
                new RowInsert(new Dictionary<string, object?> { ["id"] = 6, ["name"] = "six", ["price"] = 9.99m }),
                new RowDelete(new Dictionary<string, object?> { ["id"] = 2 }),
            ], Ct);
            Assert.Equal(3, saved);

            var page = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("id", false)], 0, 10), Ct);
            Assert.Equal([1, 3, 4, 5, 6], page.Rows.Select(r => Convert.ToInt32(r[0], CultureInfo.InvariantCulture)));
            Assert.Equal("it's renamed", page.Rows[0][1]);
            Assert.Null(page.Rows[0][4]);

            // The update before the miss rolls back with it.
            await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(table, [
                new RowUpdate(new Dictionary<string, object?> { ["id"] = 3 }, new Dictionary<string, object?> { ["name"] = "lost" }),
                new RowDelete(new Dictionary<string, object?> { ["id"] = 99 }),
            ], Ct));
            Assert.Equal(0, await session.CountAsync(table, new BrowseFilter([new FilterRule("name", FilterOperator.Equals, "lost")]), Ct));

            // A duplicate key fails on the server and rolls back the insert before it.
            await Assert.ThrowsAnyAsync<DbException>(() => session.SaveChangesAsync(table, [
                new RowInsert(new Dictionary<string, object?> { ["id"] = 7, ["name"] = "seven" }),
                new RowInsert(new Dictionary<string, object?> { ["id"] = 1, ["name"] = "dup" }),
            ], Ct));
            Assert.Equal(5, await session.CountAsync(table, BrowseFilter.None, Ct));
        }
        finally
        {
            await DropQuietlyAsync(session, table);
        }
    }

    [Fact]
    public async Task AppliesStructureEdits()
    {
        await using var session = await ConnectAsync();
        var parent = await CreateItemsAsync(session, 2);
        var child = TableIn(session, NewName("tp_child_"));
        var renamed = TableIn(session, NewName("tp_renamed_"));
        try
        {
            await ExecDdlAsync(session, child, new CreateTable(child,
            [
                new ColumnDefinition("id", IntType, false, IsPrimaryKey: true),
                new ColumnDefinition("item_id", IntType),
                new ColumnDefinition("qty", IntType, true, "1"),
            ]));

            await ExecDdlAsync(session, child, new AddColumn(new ColumnDefinition("label", TextType, Comment: "what it is")));
            await ExecDdlAsync(session, child, new RenameColumn("label", "title"));
            await ExecDdlAsync(session, child, new CreateIndex(new IndexDefinition(child.Name + "_title", ["title"], IsUnique: true)));
            await ExecDdlAsync(session, child, new AddForeignKey(new ForeignKeyDefinition(child.Name + "_fk", ["item_id"], parent, ["id"], OnDelete: "CASCADE")));

            var structure = await session.GetStructureAsync(child, Ct);
            Assert.Equal(["id", "item_id", "qty", "title"], structure.Columns.Select(c => c.Name));
            Assert.Contains(structure.Indexes, i => i.IsUnique && i.Columns.SequenceEqual(["title"]));
            var fk = Assert.Single(structure.ForeignKeys);
            Assert.Equal(["item_id"], fk.Columns);
            Assert.Equal(parent.Name, fk.ReferencedTable.Name);
            Assert.Equal("CASCADE", fk.OnDelete);
            Assert.Contains("1", structure.Columns[2].DefaultValue ?? string.Empty, StringComparison.Ordinal);

            await session.SaveChangesAsync(child, [new RowInsert(new Dictionary<string, object?> { ["id"] = 1, ["item_id"] = 1, ["title"] = "a" })], Ct);
            await Assert.ThrowsAnyAsync<DbException>(() => session.SaveChangesAsync(child, [new RowInsert(new Dictionary<string, object?> { ["id"] = 2, ["item_id"] = 404, ["title"] = "b" })], Ct));

            var before = ColumnDefinition.From(structure.Columns[2]);
            await ExecDdlAsync(session, child, new AlterColumn(before, before with { DataType = DecimalType, IsNullable = false, DefaultExpression = "2" }));
            var altered = (await session.GetStructureAsync(child, Ct)).Columns[2];
            Assert.False(altered.IsNullable);
            Assert.Contains("2", altered.DefaultValue ?? string.Empty, StringComparison.Ordinal);

            if (SupportsCheckConstraints && session is ITableDetailsProvider details)
            {
                await ExecDdlAsync(session, child, new AddCheckConstraint(new CheckConstraintDefinition(child.Name + "_qty", session.Dialect.QuoteIdentifier("qty") + " >= 0")));
                Assert.Contains((await details.GetTableDetailsAsync(child, Ct)).CheckConstraints, c => c.Name == child.Name + "_qty");
                await Assert.ThrowsAnyAsync<DbException>(() => session.SaveChangesAsync(child, [new RowUpdate(new Dictionary<string, object?> { ["id"] = 1 }, new Dictionary<string, object?> { ["qty"] = -1m })], Ct));
                await ExecDdlAsync(session, child, new DropCheckConstraint(child.Name + "_qty"));
            }

            await ExecDdlAsync(session, child, new DropForeignKey(child.Name + "_fk"));
            await ExecDdlAsync(session, child, new DropIndex(child.Name + "_title"));
            await ExecDdlAsync(session, child, new DropColumn("title"));
            await ExecDdlAsync(session, child, new RenameTable(renamed.Name));

            var after = await session.GetStructureAsync(renamed, Ct);
            Assert.Equal(["id", "item_id", "qty"], after.Columns.Select(c => c.Name));
            Assert.Empty(after.ForeignKeys);
            Assert.DoesNotContain(after.Indexes, i => i.Columns.Contains("title"));
            Assert.Equal(1, await session.CountAsync(renamed, BrowseFilter.None, Ct));

            await ExecDdlAsync(session, renamed, new TruncateTable());
            Assert.Equal(0, await session.CountAsync(renamed, BrowseFilter.None, Ct));
        }
        finally
        {
            await DropQuietlyAsync(session, child, renamed, parent);
        }
    }

    [Fact]
    public async Task RunsScriptsReportsErrorsAndKeepsSessionState()
    {
        await using var session = await ConnectAsync();
        var table = await CreateItemsAsync(session, 10);
        await using var channel = await session.OpenChannelAsync(Ct);
        try
        {
            var qualified = session.Dialect.Qualify(table);
            string Q(string name) => session.Dialect.QuoteIdentifier(name);
            var results = await RunAsync(channel, [
                $"SELECT {Q("id")}, {Q("name")} FROM {qualified} WHERE {Q("id")} <= 3 ORDER BY {Q("id")}",
                $"UPDATE {qualified} SET {Q("note")} = 'x' WHERE {Q("id")} > 8",
                "SELECT * FROM tp_no_such_table_at_all",
                $"SELECT COUNT(*) FROM {qualified}",
            ]);

            Assert.Equal(4, results.Count);
            Assert.True(results[0].Succeeded, results[0].Error);
            Assert.Equal(3, Assert.Single(results[0].ResultSets).RowCount);
            Assert.Equal(["id", "name"], results[0].ResultSets[0].Columns.Select(c => c.Name));
            Assert.Equal(2, results[1].RecordsAffected);
            Assert.False(results[2].Succeeded);
            Assert.False(string.IsNullOrWhiteSpace(results[2].Error));
            if (ErrorNamesTheMissingTable)
            {
                Assert.Contains("tp_no_such_table_at_all", results[2].Error, StringComparison.OrdinalIgnoreCase);
            }
            Assert.Equal(10L, Convert.ToInt64(results[3].ResultSets[0][0, 0], CultureInfo.InvariantCulture));

            var stopped = await RunAsync(channel, ["SELECT * FROM tp_no_such_table_at_all", SelectOne], stopOnError: true);
            Assert.Single(stopped);

            // A transaction opened in the editor stays on the tab's connection until it ends.
            if (!EditorAutoCommits)
            {
                string[] rollback = BeginStatement is { } begin ? [begin, $"DELETE FROM {qualified}", "ROLLBACK"] : [$"DELETE FROM {qualified}", "ROLLBACK"];
                Assert.All(await RunAsync(channel, rollback), r => Assert.True(r.Succeeded, r.Error));
                Assert.Equal(10, await session.CountAsync(table, BrowseFilter.None, Ct));
            }

            if (MessageStatement is { } message)
            {
                var noticed = Assert.Single(await RunAsync(channel, [message]));
                Assert.True(noticed.Succeeded, noticed.Error);
                Assert.Contains(noticed.Messages ?? [], m => m.Contains("tablepro says hello", StringComparison.Ordinal));
            }

            var limited = Assert.Single(await RunAsyncWithLimit(channel, $"SELECT * FROM {qualified}", 4));
            Assert.Equal(4, limited.ResultSets[0].RowCount);
            Assert.True(limited.ResultSets[0].IsTruncated);
            Assert.True(Assert.Single(await RunAsync(channel, [SelectOne])).Succeeded);
        }
        finally
        {
            await DropQuietlyAsync(session, table);
        }
    }

    private static async Task<List<StatementResult>> RunAsyncWithLimit(IQueryChannel channel, string sql, int limit)
    {
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync([sql], new ExecuteOptions(limit, StopOnError: false), Ct))
        {
            results.Add(result);
        }

        return results;
    }

    [Fact]
    public async Task CancelsARunningStatementAndTheTabStaysUsable()
    {
        await using var session = await ConnectAsync();
        await using var channel = await session.OpenChannelAsync(Ct);
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(Ct);
        cancel.CancelAfter(TimeSpan.FromMilliseconds(750));
        var clock = Stopwatch.StartNew();

        var results = await RunUntilAsync(channel, [SleepStatement, SelectOne], stopOnError: false, cancel.Token);

        Assert.InRange(clock.Elapsed, TimeSpan.Zero, TimeSpan.FromSeconds(15));
        var cancelled = Assert.Single(results);
        Assert.False(cancelled.Succeeded);
        Assert.False(string.IsNullOrEmpty(cancelled.Error));

        var after = Assert.Single(await RunAsync(channel, [SelectOne]));
        Assert.True(after.Succeeded, after.Error);
    }

    [Fact]
    public async Task DrawsEstimatedAndMeasuredPlans()
    {
        await using var session = await ConnectAsync();
        var table = await CreateItemsAsync(session, 20);
        await using var channel = await session.OpenChannelAsync(Ct);
        try
        {
            string Q(string name) => session.Dialect.QuoteIdentifier(name);
            var select = $"SELECT {Q("name")} FROM {session.Dialect.Qualify(table)} WHERE {Q("id")} > 5 ORDER BY {Q("name")}";
            foreach (var analyze in (bool[])[false, true])
            {
                var request = session.Dialect.PlanStatements(select, analyze);
                if (request is null && analyze)
                {
                    // The engine has no measured plan; the action is not offered.
                    continue;
                }

                Assert.NotNull(request);
                var results = await RunAsync(channel, request!.Statements);
                Assert.All(results, r => Assert.True(r.Succeeded, r.Sql + "\n" + r.Error));

                var text = PlanText.FromResults(request.Format, [.. results.SelectMany(r => r.ResultSets)]);
                Assert.False(string.IsNullOrWhiteSpace(text));
                var plan = QueryPlanParser.Parse(text, request.Format);
                Assert.NotNull(plan);
                Assert.True(plan!.NodeCount > 0);
            }

            // The plan switch must be off again, so the next statement returns its rows.
            var rows = Assert.Single(await RunAsync(channel, [select]));
            Assert.Equal(15, rows.ResultSets[0].RowCount);
        }
        finally
        {
            await DropQuietlyAsync(session, table);
        }
    }

    [Fact]
    public async Task ListsActivityVariablesAndUsersAndEndsASession()
    {
        await using var session = await ConnectAsync();
        var activity = (IServerActivityProvider)session;
        await using var victim = await session.OpenChannelAsync(Ct);
        var id = Assert.Single(await RunAsync(victim, [ConnectionIdStatement])).ResultSets[0][0, 0];
        var marker = Assert.Single(await RunAsync(victim, [SessionMarkerStatement])).ResultSets[0][0, 0];

        var sessions = await activity.GetActivityAsync(Ct);
        var column = sessions.ColumnIndex(activity.ProcessIdColumn);
        Assert.True(column >= 0, $"No {activity.ProcessIdColumn} column.");
        Assert.Contains(sessions.Rows, r => Convert.ToString(r[column], CultureInfo.InvariantCulture) == Convert.ToString(id, CultureInfo.InvariantCulture));

        await activity.TerminateAsync(id!, Ct);

        // The tab's next statement fails, or SqlClient's connection resiliency reconnects under it; either way the tab
        // must then run statements again, on a session other than the ended one.
        var next = Assert.Single(await RunAsync(victim, [SessionMarkerStatement]));
        if (!next.Succeeded)
        {
            next = Assert.Single(await RunAsync(victim, [SessionMarkerStatement]));
        }

        Assert.True(next.Succeeded, next.Error);
        Assert.NotEqual(Convert.ToString(marker, CultureInfo.InvariantCulture), Convert.ToString(next.ResultSets[0][0, 0], CultureInfo.InvariantCulture));

        Assert.NotEmpty((await ((IServerVariablesProvider)session).GetVariablesAsync(Ct)).Rows);
        Assert.NotEmpty((await ((IUserListProvider)session).GetUsersAsync(Ct)).Rows);
    }

    [Fact]
    public async Task CreatesAndDropsAUserThroughTheEditor()
    {
        await using var session = await ConnectAsync();
        Assert.SkipUnless(session is IUserAdministration { Features: not null }, $"{Engine} has no user editor.");
        var users = (IUserAdministration)session;
        var features = users.Features!;
        var snapshot = await users.LoadPrincipalsAsync(Ct);
        Assert.NotEmpty(snapshot.Principals);

        var table = await CreateItemsAsync(session, 1);
        var name = NewName("tp_user_");
        var principal = new PrincipalRef(name, features.HostScoping ? "%" : null);
        var create = users.BuildStatements([new CreatePrincipal(new PrincipalDefinition(principal, "TablePro-test-1-User", canLogin: true))]);
        await ApplyAsync(session, features, create);
        try
        {
            Assert.Contains((await users.LoadPrincipalsAsync(Ct)).Principals, p => p.Ref.Name == name);
            var scope = TableScope(session, table);
            var grant = users.BuildStatements([new ModifyGrants(new PrincipalGrantChanges(principal, [new PrincipalGrant("SELECT", scope)], []))]);
            await ApplyAsync(session, features, grant);
            Assert.Contains(await users.LoadGrantsAsync(principal, Ct), g => g.Privilege == "SELECT" && g.Scope.Table == table.Name);
        }
        finally
        {
            // A role that holds grants needs them dropped first, which the editor offers when this says so.
            var options = features.OwnedObjectReassignment && await users.OwnsObjectsAsync(principal, Ct) ? new PrincipalDropOptions(DropOwned: true) : PrincipalDropOptions.None;
            await ApplyAsync(session, features, users.BuildStatements([new DropPrincipal(principal, options)]));
            await DropQuietlyAsync(session, table);
        }

        Assert.DoesNotContain((await users.LoadPrincipalsAsync(Ct)).Principals, p => p.Ref.Name == name);
    }

    /// <summary>How the user editor names a table: database, schema and table where the engine has schemas.</summary>
    protected virtual PrivilegeScope TableScope(IDatabaseSession session, ObjectName table) =>
        PrivilegeScope.ForTable(session.CurrentDatabase!, table.Schema, table.Name);

    private static async Task ApplyAsync(IDatabaseSession session, UserAdministrationFeatures features, IReadOnlyList<PrincipalStatement> statements)
    {
        IEnumerable<string> sql = statements.Select(s => s.Sql);
        if (features.Transaction is { } transaction)
        {
            sql = sql.Prepend(transaction.Begin).Append(transaction.Commit);
        }

        await ExecAsync(session, [.. sql]);
    }

    [Fact]
    public async Task WritesSeveralTablesInOneChangeTransaction()
    {
        await using var session = await ConnectAsync();
        var provider = ChangeTransactions.For(session);
        Assert.NotNull(provider);
        var left = await CreateItemsAsync(session, 3);
        var right = await CreateItemsAsync(session, 3);
        try
        {
            await using (var transaction = await provider!.BeginChangesAsync(Ct))
            {
                Assert.Equal(1, await transaction.SaveChangesAsync(left, [new RowUpdate(new Dictionary<string, object?> { ["id"] = 1 }, new Dictionary<string, object?> { ["name"] = "left" })], Ct));
                Assert.Equal(3, await transaction.DeleteAllRowsAsync(right, Ct));
                Assert.Equal(1, await transaction.SaveChangesAsync(right, [new RowInsert(new Dictionary<string, object?> { ["id"] = 10, ["name"] = "fresh" })], Ct));
                await transaction.CommitAsync(Ct);
            }

            Assert.Equal(1, await session.CountAsync(left, new BrowseFilter([new FilterRule("name", FilterOperator.Equals, "left")]), Ct));
            Assert.Equal(1, await session.CountAsync(right, BrowseFilter.None, Ct));

            // Dropped without a commit after a miss: nothing of it stays, in either table.
            await using (var transaction = await provider.BeginChangesAsync(Ct))
            {
                await transaction.DeleteAllRowsAsync(left, Ct);
                await Assert.ThrowsAsync<RowCountMismatchException>(() => transaction.SaveChangesAsync(right, [new RowDelete(new Dictionary<string, object?> { ["id"] = 404 })], Ct));
            }

            Assert.Equal(3, await session.CountAsync(left, BrowseFilter.None, Ct));
            Assert.Equal(1, await session.CountAsync(right, BrowseFilter.None, Ct));
        }
        finally
        {
            await DropQuietlyAsync(session, left, right);
        }
    }

    [Fact]
    public async Task ReadOnlyConnectionRefusesWrites()
    {
        await using var writer = await ConnectAsync();
        Assert.SkipUnless(ServerEnforcesReadOnly, $"{Engine} has no session-wide read-only switch; Safe Mode refuses writes in the app.");
        var table = await CreateItemsAsync(writer, 2);
        try
        {
            await using var session = await ConnectAsync(SafeModeLevel.ReadOnly);
            Assert.Equal(2, (await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 0, 10), Ct)).RowCount);

            await Assert.ThrowsAnyAsync<Exception>(() => session.SaveChangesAsync(table, [new RowDelete(new Dictionary<string, object?> { ["id"] = 1 })], Ct));
            await using var channel = await session.OpenChannelAsync(Ct);
            var write = Assert.Single(await RunAsync(channel, [$"DELETE FROM {session.Dialect.Qualify(table)}"]));
            Assert.False(write.Succeeded, "A read-only connection deleted rows.");
            Assert.Equal(2, await writer.CountAsync(table, BrowseFilter.None, Ct));
        }
        finally
        {
            await DropQuietlyAsync(writer, table);
        }
    }
}
