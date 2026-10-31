using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Drivers.PostgreSql;

namespace TablePro.Drivers.Tests.Live;

/// <summary>
/// PostgreSQL against TABLEPRO_POSTGRES, for example
/// <c>host=localhost;port=5432;user=postgres;password=TablePro-test-1;database=tablepro</c>.
/// </summary>
public sealed class PostgreSqlServerTests : RelationalServerTests
{
    protected override string Variable => "TABLEPRO_POSTGRES";

    protected override DatabaseEngine Engine => DatabaseEngine.PostgreSql;

    protected override IDatabaseDriver Driver { get; } = new PostgreSqlDriver();

    protected override string IntType => "integer";

    protected override string TextType => "varchar(100)";

    protected override string DecimalType => "numeric(10,2)";

    protected override string TimestampType => "timestamp";

    protected override string SleepStatement => "SELECT pg_sleep(30)";

    protected override string ConnectionIdStatement => "SELECT pg_backend_pid()";

    protected override string? MessageStatement => "DO $$BEGIN RAISE NOTICE 'tablepro says hello'; END$$";

    /// <summary>
    /// The grid hands a save the value its column's CLR type parses to, which for json, uuid, inet, enums and arrays is
    /// text; each must still land in its column.
    /// </summary>
    [Fact]
    public async Task SavesEveryCommonTypeAsTheGridParsesIt()
    {
        var type = NewName("tp_mood_");
        ObjectName table;
        await using (var setup = await ConnectAsync())
        {
            table = TableIn(setup, NewName("tp_types_"));
            await ExecAsync(
                setup,
                $"CREATE TYPE {type} AS ENUM ('sad', 'happy')",
                $"""
                CREATE TABLE {setup.Dialect.Qualify(table)} (
                  id integer PRIMARY KEY, doc jsonb, raw json, key uuid, addr inet, mood {type}, tags text[], blob bytea,
                  flag boolean, at timestamptz, day date, span interval, amount money, big bigint, ratio double precision
                )
                """);
        }

        // A new connection, as the app opens one: the enum exists before its types are read.
        await using var session = await ConnectAsync();
        try
        {
            var columns = (await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 0, 1), Ct)).Columns;
            object? Parse(string column, string text)
            {
                var clr = columns.Single(c => c.Name == column).ClrType;
                Assert.True(ValueParser.TryParse(text, clr, out var value), $"{column} ({clr}) did not parse '{text}'.");
                return value;
            }

            var values = new Dictionary<string, object?>
            {
                ["id"] = Parse("id", "1"),
                ["doc"] = Parse("doc", """{"a": [1, 2]}"""),
                ["raw"] = Parse("raw", """{"b":true}"""),
                ["key"] = Parse("key", "0190d0a5-2c1a-7c3e-9a8b-1234567890ab"),
                ["addr"] = Parse("addr", "10.1.2.3"),
                ["mood"] = Parse("mood", "happy"),
                ["tags"] = Parse("tags", "{x,y}"),
                ["flag"] = Parse("flag", "true"),
                ["at"] = Parse("at", "2024-05-01 10:00:00+00"),
                ["day"] = Parse("day", "2024-05-01"),
                ["big"] = Parse("big", "9007199254740993"),
                ["ratio"] = Parse("ratio", "0.5"),
            };
            await session.SaveChangesAsync(table, [new RowInsert(values)], Ct);
            await session.SaveChangesAsync(table, [new RowUpdate(new Dictionary<string, object?> { ["id"] = 1 }, new Dictionary<string, object?>
            {
                ["doc"] = Parse("doc", """{"a": 3}"""),
                ["mood"] = Parse("mood", "sad"),
                ["addr"] = Parse("addr", "192.168.0.0/16"),
            })], Ct);

            // A keyed save finds its row by the values the browse returned, json and enum included.
            var row = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 0, 1), Ct);
            Assert.Equal("sad", row.Rows[0][row.ColumnIndex("mood")]);
            Assert.Contains("3", row.Rows[0][row.ColumnIndex("doc")]?.ToString(), StringComparison.Ordinal);
            Assert.Equal(1, await session.CountAsync(table, new BrowseFilter([new FilterRule("mood", FilterOperator.Equals, "sad")]), Ct));
            Assert.Equal(1, await session.CountAsync(table, new BrowseFilter([new FilterRule("doc", FilterOperator.Contains, "a")]), Ct));
            Assert.Equal(1, await session.CountAsync(table, new BrowseFilter([new FilterRule("key", FilterOperator.Equals, "0190d0a5-2c1a-7c3e-9a8b-1234567890ab")]), Ct));
            await session.SaveChangesAsync(table, [new RowDelete(new Dictionary<string, object?> { ["id"] = 1 })], Ct);
        }
        finally
        {
            await DropQuietlyAsync(session, table);
            await ExecAsync(session, $"DROP TYPE IF EXISTS {type}");
        }
    }

    [Fact]
    public async Task BrowsesAnEnumCreatedAfterConnecting()
    {
        await using var session = await ConnectAsync();
        await session.PingAsync(Ct);
        var type = NewName("tp_late_");
        var table = TableIn(session, NewName("tp_late_"));
        await ExecAsync(session, $"CREATE TYPE {type} AS ENUM ('on', 'off')", $"CREATE TABLE {session.Dialect.Qualify(table)} (id integer PRIMARY KEY, state {type})", $"INSERT INTO {session.Dialect.Qualify(table)} VALUES (1, 'off')");
        try
        {
            var page = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 0, 10), Ct);
            Assert.Equal("off", page.Rows[0][1]);
        }
        finally
        {
            await DropQuietlyAsync(session, table);
            await ExecAsync(session, $"DROP TYPE IF EXISTS {type}");
        }
    }

    /// <summary>
    /// An editor tab keeps one connection, and Npgsql read the server's types when it opened, so an enum or domain the
    /// tab creates had no reader there until reconnect. One made by another connection is read on first sight.
    /// </summary>
    [Fact]
    public async Task ReadsTypesCreatedInTheEditorOnTheSameTab()
    {
        await using var session = await ConnectAsync();
        await using var channel = await session.OpenChannelAsync(Ct);
        var mood = NewName("tp_mood_");
        var positive = NewName("tp_pos_");
        var late = NewName("tp_other_");
        var table = TableIn(session, NewName("tp_typed_"));
        var qualified = session.Dialect.Qualify(table);
        try
        {
            Assert.True(Assert.Single(await RunAsync(channel, [SelectOne])).Succeeded);
            var setup = await RunAsync(channel, [
                $"CREATE TYPE {mood} AS ENUM ('sad', 'happy')",
                $"CREATE DOMAIN {positive} AS integer CHECK (VALUE > 0)",
                $"CREATE TABLE {qualified} (id integer PRIMARY KEY, mood {mood}, score {positive})",
                $"INSERT INTO {qualified} VALUES (1, 'happy', 7)",
            ]);
            Assert.All(setup, r => Assert.True(r.Succeeded, r.Sql + "\n" + r.Error));

            var read = Assert.Single(await RunAsync(channel, [$"SELECT mood, score FROM {qualified}"]));
            Assert.True(read.Succeeded, read.Error);
            Assert.Equal("happy", read.ResultSets[0][0, 0]);
            Assert.Equal(7, read.ResultSets[0][0, 1]);

            await ExecAsync(session, $"CREATE TYPE {late} AS ENUM ('on', 'off')");
            var other = Assert.Single(await RunAsync(channel, [$"SELECT 'off'::{late} AS state"]));
            Assert.True(other.Succeeded, other.Error);
            Assert.Equal("off", other.ResultSets[0][0, 0]);
        }
        finally
        {
            await DropQuietlyAsync(session, table);
            await ExecAsync(session, $"DROP TYPE IF EXISTS {mood}", $"DROP DOMAIN IF EXISTS {positive}", $"DROP TYPE IF EXISTS {late}");
        }
    }

    [Fact]
    public async Task ListsViewsRoutinesSequencesAndPartitions()
    {
        await using var session = await ConnectAsync();
        var schema = NewName("tp_schema_");
        await ExecAsync(
            session,
            $"CREATE SCHEMA {schema}",
            $"CREATE TABLE {schema}.events (id bigint GENERATED ALWAYS AS IDENTITY, at date NOT NULL, kind text CHECK (kind <> ''), PRIMARY KEY (id, at)) PARTITION BY RANGE (at)",
            $"CREATE TABLE {schema}.events_2024 PARTITION OF {schema}.events FOR VALUES FROM ('2024-01-01') TO ('2025-01-01')",
            $"CREATE VIEW {schema}.recent AS SELECT * FROM {schema}.events WHERE at > now() - interval '7 days'",
            $"CREATE MATERIALIZED VIEW {schema}.totals AS SELECT kind, count(*) AS n FROM {schema}.events GROUP BY kind",
            $"CREATE SEQUENCE {schema}.ticket START 100",
            $"CREATE FUNCTION {schema}.twice(x integer) RETURNS integer LANGUAGE sql AS 'SELECT x * 2'",
            $"CREATE PROCEDURE {schema}.touch() LANGUAGE sql AS 'SELECT 1'",
            $"CREATE FUNCTION {schema}.stamp() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$",
            $"CREATE TRIGGER events_stamp BEFORE INSERT ON {schema}.events_2024 FOR EACH ROW EXECUTE FUNCTION {schema}.stamp()",
            $"COMMENT ON TABLE {schema}.events IS 'all events'");
        try
        {
            Assert.Contains(schema, await session.GetSchemasAsync(Ct));
            var objects = await session.GetObjectsAsync(schema, Ct);
            ObjectKind KindOf(string name) => Assert.Single(objects, o => o.Name.Name == name).Kind;
            Assert.Equal(ObjectKind.Table, KindOf("events"));
            Assert.Equal(ObjectKind.View, KindOf("recent"));
            Assert.Equal(ObjectKind.MaterializedView, KindOf("totals"));
            Assert.Equal(ObjectKind.Sequence, KindOf("ticket"));
            Assert.Equal(ObjectKind.Function, KindOf("twice"));
            Assert.Equal(ObjectKind.Procedure, KindOf("touch"));
            Assert.Equal("all events", objects.Single(o => o.Name.Name == "events").Comment);

            var events = new ObjectName(schema, "events");
            var structure = await session.GetStructureAsync(events, Ct);
            Assert.Equal(["id", "at"], structure.PrimaryKey);
            Assert.True(structure.Columns[0].IsIdentity);
            Assert.Single((await session.GetStructureAsync(new ObjectName(schema, "events_2024"), Ct)).Triggers);

            var details = await ((ITableDetailsProvider)session).GetTableDetailsAsync(events, Ct);
            Assert.Single(details.CheckConstraints);
            Assert.Equal("events_2024", Assert.Single(details.Partitioning!.Partitions).Name);

            foreach (var name in (string[])["events", "recent", "totals", "ticket", "twice", "touch"])
            {
                var definition = await session.GetDefinitionAsync(objects.Single(o => o.Name.Name == name), Ct);
                Assert.Contains("CREATE", definition, StringComparison.Ordinal);
            }

            Assert.Contains("PARTITION BY RANGE", await session.GetDefinitionAsync(objects.Single(o => o.Name.Name == "events"), Ct), StringComparison.Ordinal);
        }
        finally
        {
            await ExecAsync(session, $"DROP SCHEMA {schema} CASCADE");
        }
    }

    [Fact]
    public async Task CreatesAndDropsADatabase()
    {
        await using var session = await ConnectAsync();
        var admin = (IDatabaseAdministration)session;
        var name = NewName("tp_db_");

        await ExecAsync(session, admin.BuildCreateDatabase(name));
        Assert.Contains(name, await session.GetDatabasesAsync(Ct));
        await ExecAsync(session, admin.BuildDropDatabase(name));
        Assert.DoesNotContain(name, await session.GetDatabasesAsync(Ct));
    }
}
