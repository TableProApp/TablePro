using Npgsql;
using TablePro.Core.Connections;
using TablePro.Core.Schema;
using TablePro.Drivers.PostgreSql;
using NpgsqlSslMode = Npgsql.SslMode;

namespace TablePro.Drivers.Tests;

public sealed class PostgreSqlTests
{
    private static readonly ObjectName Orders = new("sales", "orders");

    [Fact]
    public void TextValuesAreBoundUntypedSoTheServerReadsThemAsTheColumnsType()
    {
        // Typed as text, a value for a jsonb, uuid or enum column fails with 42804 and one compared with an integer
        // column with 42883.
        Assert.Equal(NpgsqlTypes.NpgsqlDbType.Unknown, PostgreSqlSession.Parameter("@p0", """{"a":1}""").NpgsqlDbType);
        Assert.Equal(NpgsqlTypes.NpgsqlDbType.Unknown, PostgreSqlSession.Parameter("@p0", 'x').NpgsqlDbType);
        Assert.Equal(5, PostgreSqlSession.Parameter("@p0", 5).Value);
        Assert.Equal(DBNull.Value, PostgreSqlSession.Parameter("@p0", null).Value);
    }

    /// <summary>
    /// The untyped binding is the base class's parameter hook, so browse, count, save, import matching and a sync all
    /// bind through it rather than through copies of the base class's methods.
    /// </summary>
    [Fact]
    public void BindsThroughTheBaseClassHookRatherThanCopiesOfItsMethods()
    {
        const System.Reflection.BindingFlags Declared = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public
            | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.DeclaredOnly;
        var declared = typeof(PostgreSqlSession).GetMethods(Declared).Select(m => m.Name).ToHashSet();

        Assert.Contains("CreateParameter", declared);
        Assert.Contains("HasUnreadableColumns", declared);
        Assert.DoesNotContain("BrowseAsync", declared);
        Assert.DoesNotContain("CountAsync", declared);
        Assert.DoesNotContain("ExecuteChangeAsync", declared);
    }

    [Theory]
    [InlineData("CREATE TYPE mood AS ENUM ('sad', 'happy')", true)]
    [InlineData("create domain positive as integer check (value > 0)", true)]
    [InlineData("ALTER TYPE mood ADD VALUE 'meh'", true)]
    [InlineData("-- why\nDROP TYPE mood", true)]
    [InlineData("CREATE EXTENSION IF NOT EXISTS hstore", true)]
    [InlineData("CREATE TABLE t (id int)", false)]
    [InlineData("SELECT 'CREATE TYPE x'", false)]
    [InlineData("INSERT INTO t VALUES (1)", false)]
    public void ReadsTheServersTypesAgainOnlyAfterATypeChanges(string sql, bool changes) =>
        Assert.Equal(changes, PostgreSqlDdl.ChangesTypes(sql));

    [Fact]
    public void ConnectionStringUsesTheRequestEndpointAndProfileSettings()
    {
        var builder = new NpgsqlConnectionStringBuilder(PostgreSqlConnectionStringFactory.Build(Profiles.Request(DatabaseEngine.PostgreSql)));

        Assert.Equal("127.0.0.1", builder.Host);
        Assert.Equal(15432, builder.Port);
        Assert.Equal("shop", builder.Database);
        Assert.Equal("app", builder.Username);
        Assert.Equal("s3cret;'x", builder.Password);
        Assert.Equal(7, builder.Timeout);
        Assert.True(builder.Pooling);
        Assert.Null(builder.Options);
    }

    [Fact]
    public void ConnectionStringFallsBackToThePostgresDatabaseAndDefaultUser()
    {
        var builder = new NpgsqlConnectionStringBuilder(
            PostgreSqlConnectionStringFactory.Build(Profiles.Request(DatabaseEngine.PostgreSql, user: null, database: null)));

        Assert.Equal("postgres", builder.Database);
        Assert.Equal("postgres", builder.Username);
    }

    [Theory]
    [InlineData(Core.Connections.SslMode.Disabled, NpgsqlSslMode.Disable)]
    [InlineData(Core.Connections.SslMode.Preferred, NpgsqlSslMode.Prefer)]
    [InlineData(Core.Connections.SslMode.Required, NpgsqlSslMode.Require)]
    [InlineData(Core.Connections.SslMode.VerifyCa, NpgsqlSslMode.VerifyCA)]
    [InlineData(Core.Connections.SslMode.VerifyIdentity, NpgsqlSslMode.VerifyFull)]
    public void MapsEverySslMode(Core.Connections.SslMode mode, NpgsqlSslMode expected)
    {
        // Direct, since behind a tunnel Verify identity checks the chain only.
        var request = Core.Drivers.ConnectionRequest.Direct(Profiles.Request(DatabaseEngine.PostgreSql, ssl: mode).Profile, null);
        var builder = new NpgsqlConnectionStringBuilder(PostgreSqlConnectionStringFactory.Build(request));

        Assert.Equal(expected, builder.SslMode);
    }

    [Fact]
    public void ReadOnlyProfileSetsTheSessionDefaultAlongsideTheUsersOptions()
    {
        var request = Profiles.Request(
            DatabaseEngine.PostgreSql,
            safeMode: SafeModeLevel.ReadOnly,
            options: new Dictionary<string, string> { ["Options"] = "-c search_path=sales", ["Maximum Pool Size"] = "5" });

        var builder = new NpgsqlConnectionStringBuilder(PostgreSqlConnectionStringFactory.Build(request));

        Assert.Equal("-c search_path=sales -c default_transaction_read_only=on", builder.Options);
        Assert.Equal(5, builder.MaxPoolSize);
    }

    [Fact]
    public void CreatesATableWithIdentityCompositeKeyAndComments()
    {
        var ddl = PostgreSqlDdl.Build(Orders, new CreateTable(Orders, [
            new ColumnDefinition("id", "bigint", IsNullable: false, IsPrimaryKey: true, IsIdentity: true),
            new ColumnDefinition("line", "integer", IsNullable: false, IsPrimaryKey: true),
            new ColumnDefinition("note", "text", DefaultExpression: "''", Comment: "It's free text"),
        ]));

        Assert.Equal(
            "CREATE TABLE \"sales\".\"orders\" (\n  \"id\" bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,\n  \"line\" integer NOT NULL,\n"
            + "  \"note\" text DEFAULT '',\n  PRIMARY KEY (\"id\", \"line\")\n)",
            ddl[0]);
        Assert.Equal("COMMENT ON COLUMN \"sales\".\"orders\".\"note\" IS 'It''s free text'", ddl[1]);
    }

    [Fact]
    public void AltersAColumnInOneStatementThenCommentsAndRenames()
    {
        var before = new ColumnDefinition("qty", "text", IsNullable: true, DefaultExpression: null, Comment: "old");
        var after = new ColumnDefinition("quantity", "integer", IsNullable: false, DefaultExpression: "0", Comment: null);

        var ddl = PostgreSqlDdl.Build(Orders, new AlterColumn(before, after));

        Assert.Equal(
            [
                "ALTER TABLE \"sales\".\"orders\" ALTER COLUMN \"qty\" TYPE integer USING \"qty\"::integer, ALTER COLUMN \"qty\" SET NOT NULL, "
                    + "ALTER COLUMN \"qty\" SET DEFAULT 0",
                "COMMENT ON COLUMN \"sales\".\"orders\".\"qty\" IS NULL",
                "ALTER TABLE \"sales\".\"orders\" RENAME COLUMN \"qty\" TO \"quantity\"",
            ],
            ddl);
    }

    [Fact]
    public void AnUnchangedColumnNeedsNoStatement()
    {
        var column = new ColumnDefinition("qty", "integer");

        Assert.Empty(PostgreSqlDdl.Build(Orders, new AlterColumn(column, column)));
    }

    [Fact]
    public void WritesIndexKeyAndObjectStatements()
    {
        Assert.Equal(["CREATE UNIQUE INDEX \"ux\" ON \"sales\".\"orders\" (\"a\", \"b\")"], PostgreSqlDdl.Build(Orders, new CreateIndex(new IndexDefinition("ux", ["a", "b"], true))));
        Assert.Equal(["DROP INDEX \"sales\".\"ux\""], PostgreSqlDdl.Build(Orders, new DropIndex("ux")));
        Assert.Equal(
            ["ALTER TABLE \"sales\".\"orders\" ADD CONSTRAINT \"fk\" FOREIGN KEY (\"customer_id\") REFERENCES \"sales\".\"customers\" (\"id\") ON DELETE CASCADE"],
            PostgreSqlDdl.Build(Orders, new AddForeignKey(new ForeignKeyDefinition("fk", ["customer_id"], new ObjectName(null, "customers"), ["id"], "cascade", "NO ACTION"))));
        Assert.Equal(["ALTER TABLE \"sales\".\"orders\" DROP CONSTRAINT \"fk\""], PostgreSqlDdl.Build(Orders, new DropForeignKey("fk")));
        Assert.Equal(["ALTER TABLE \"sales\".\"orders\" RENAME TO \"orders_old\""], PostgreSqlDdl.Build(Orders, new RenameTable("orders_old")));
        Assert.Equal(["TRUNCATE TABLE \"sales\".\"orders\" CASCADE"], PostgreSqlDdl.Build(Orders, new TruncateTable(Cascade: true)));
        Assert.Equal(
            ["DROP MATERIALIZED VIEW \"sales\".\"totals\" CASCADE"],
            PostgreSqlDdl.Build(Orders, new DropObject(new DatabaseObject(new ObjectName("sales", "totals"), ObjectKind.MaterializedView), Cascade: true)));
        Assert.Equal(
            ["DROP TRIGGER \"audit\" ON \"sales\".\"orders\""],
            PostgreSqlDdl.Build(Orders, new DropObject(new DatabaseObject(new ObjectName("sales", "audit"), ObjectKind.Trigger))));
    }

    [Fact]
    public void QuotesIdentifiersThatContainQuotes()
    {
        var ddl = PostgreSqlDdl.Build(new ObjectName("we\"ird", "t"), new DropColumn("a\"b"));

        Assert.Equal(["ALTER TABLE \"we\"\"ird\".\"t\" DROP COLUMN \"a\"\"b\""], ddl);
        Assert.Equal("CREATE DATABASE \"x\"\"y\"", PostgreSqlDdl.CreateDatabase("x\"y"));
        Assert.Equal("DROP DATABASE \"x\"", PostgreSqlDdl.DropDatabase("x"));
    }

    [Fact]
    public void WritesASequenceDefinition()
    {
        Assert.Equal(
            "CREATE SEQUENCE \"s\".\"q\" AS bigint INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1 NO CYCLE;",
            PostgreSqlDdl.Sequence("\"s\".\"q\"", "bigint", 1, 1, 1, long.MaxValue, 1, cycle: false));
    }

    [Theory]
    [InlineData((short)(2 | 4 | 1), "BEFORE", "INSERT")]
    [InlineData((short)(16 | 8), "AFTER", "UPDATE OR DELETE")]
    [InlineData((short)(64 | 4 | 1), "INSTEAD OF", "INSERT")]
    [InlineData((short)32, "AFTER", "TRUNCATE")]
    public void DecodesTriggerTypes(short type, string timing, string events)
    {
        Assert.Equal(timing, PostgreSqlSession.TriggerTiming(type));
        Assert.Equal(events, PostgreSqlSession.TriggerEvents(type));
    }

    [Theory]
    [InlineData("a", "NO ACTION")]
    [InlineData("r", "RESTRICT")]
    [InlineData("c", "CASCADE")]
    [InlineData("n", "SET NULL")]
    [InlineData("d", "SET DEFAULT")]
    public void DecodesReferentialActions(string code, string action) => Assert.Equal(action, PostgreSqlDdl.ReferentialAction(code));
}
