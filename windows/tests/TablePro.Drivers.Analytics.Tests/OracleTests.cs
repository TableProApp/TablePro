using Oracle.ManagedDataAccess.Client;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Oracle;

namespace TablePro.Drivers.Analytics.Tests;

public sealed class OracleTests
{
    private static readonly ObjectName Orders = new("SALES", "ORDERS");

    private static IReadOnlyList<string> Build(SchemaChange change) => OracleDdl.Build(Orders, change);

    [Fact]
    public void ConnectionStringUsesAThinDescriptorAndTheLogin()
    {
        var builder = new OracleConnectionStringBuilder(OracleConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.Oracle)));

        Assert.Equal("(DESCRIPTION=(CONNECT_TIMEOUT=7)(ADDRESS=(PROTOCOL=TCP)(HOST=127.0.0.1)(PORT=15432))(CONNECT_DATA=(SERVICE_NAME=shop)))", builder.DataSource);
        Assert.Equal("app", builder.UserID);
        Assert.Equal(Profiles.Password, builder.Password);
        Assert.Equal(7, builder.ConnectionTimeout);
        Assert.True(builder.Pooling);
    }

    [Theory]
    [InlineData(SslMode.Disabled, "TCP", null)]
    [InlineData(SslMode.Preferred, "TCP", null)]
    [InlineData(SslMode.Required, "TCPS", "FALSE")]
    [InlineData(SslMode.VerifyCa, "TCPS", "FALSE")]
    [InlineData(SslMode.VerifyIdentity, "TCPS", "TRUE")]
    public void DescriptorFollowsEverySslMode(SslMode mode, string protocol, string? dnMatch)
    {
        var descriptor = OracleConnectionStringFactory.Descriptor(Profiles.Tunnelled(DatabaseEngine.Oracle, ssl: mode));

        Assert.Contains($"(PROTOCOL={protocol})", descriptor, StringComparison.Ordinal);
        if (dnMatch is null)
        {
            Assert.DoesNotContain("SECURITY", descriptor, StringComparison.Ordinal);
        }
        else
        {
            Assert.EndsWith($"(SECURITY=(SSL_SERVER_DN_MATCH={dnMatch})))", descriptor, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void SidOptionReplacesTheServiceName()
    {
        var options = new Dictionary<string, string> { ["sid"] = "ORCL" };

        var descriptor = OracleConnectionStringFactory.Descriptor(Profiles.Tunnelled(DatabaseEngine.Oracle, options: options));

        Assert.Contains("(CONNECT_DATA=(SID=ORCL))", descriptor, StringComparison.Ordinal);
        Assert.DoesNotContain("SERVICE_NAME", descriptor, StringComparison.Ordinal);
    }

    [Fact]
    public void NoServiceLeavesTheListenerDefault()
    {
        Assert.Contains("(CONNECT_DATA=)", OracleConnectionStringFactory.Descriptor(Profiles.Tunnelled(DatabaseEngine.Oracle, database: null)), StringComparison.Ordinal);
    }

    [Fact]
    public void DirectConnectionDialsTheDefaultPort()
    {
        var descriptor = OracleConnectionStringFactory.Descriptor(Profiles.Direct(Profiles.Profile(DatabaseEngine.Oracle)));

        Assert.Contains("(HOST=db.example.com)(PORT=1521)", descriptor, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("svc)(HOST=evil")]
    [InlineData("a=b")]
    public void DescriptorRefusesCharactersThatWouldEndAValue(string service)
    {
        Assert.Throws<ArgumentException>(() => OracleConnectionStringFactory.Descriptor(Profiles.Tunnelled(DatabaseEngine.Oracle, database: service)));
    }

    [Fact]
    public void OptionsSetPrivilegeAndWalletAndPassTheRestThrough()
    {
        var options = new Dictionary<string, string>
        {
            ["sid"] = "ORCL",
            ["dbaPrivilege"] = "sysdba",
            ["walletLocation"] = @"C:\wallet",
            ["Statement Cache Size"] = "40",
        };

        var builder = new OracleConnectionStringBuilder(OracleConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.Oracle, options: options)));

        Assert.Equal("SYSDBA", builder.DBAPrivilege);
        Assert.Equal(@"C:\wallet", builder.WalletLocation);
        Assert.Equal(40, builder.StatementCacheSize);
        Assert.Contains("(SID=ORCL)", builder.DataSource, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("app", "APP")]
    [InlineData("\"Mixed\"", "Mixed")]
    [InlineData("sys as sysdba", "SYS")]
    [InlineData(null, null)]
    [InlineData(" ", null)]
    public void DefaultSchemaIsTheLoginFoldedToUpperCase(string? user, string? expected)
    {
        Assert.Equal(expected, OracleConnectionStringFactory.DefaultSchema(user));
    }

    [Fact]
    public void CoreParametersBindByPositionInTextOrder()
    {
        // ODP.NET binds by position unless BindByName is set, so the names Core writes only have to appear in the order
        // they are added, each once.
        var filter = new BrowseFilter([new FilterRule("ID", FilterOperator.In, "1, 2"), new FilterRule("NAME", FilterOperator.StartsWith, "a")]);
        var browse = OracleDialect.Instance.BuildBrowse(new BrowseRequest(Orders, filter, [new SortColumn("ID", false)], 100, 50));
        var update = ChangeSqlBuilder.Build(OracleDialect.Instance, Orders, new RowUpdate(
            new Dictionary<string, object?> { ["ID"] = 1 },
            new Dictionary<string, object?> { ["NAME"] = "x", ["QTY"] = 3 }));

        foreach (var spec in new[] { browse, update })
        {
            Assert.Equal(spec.Parameters.Select(p => p.Key), ParameterTokens(spec.Text));
        }

        Assert.EndsWith(" OFFSET 100 ROWS FETCH NEXT 50 ROWS ONLY", browse.Text, StringComparison.Ordinal);
        using var command = new OracleCommand();
        Assert.False(command.BindByName);
    }

    [Fact]
    public void CreateTableWithIdentityPrimaryKeyAndComments()
    {
        var change = new CreateTable(Orders,
        [
            new ColumnDefinition("ID", "NUMBER(19)", IsPrimaryKey: true, IsIdentity: true),
            new ColumnDefinition("NAME", "VARCHAR2(100 CHAR)", IsNullable: false, DefaultExpression: "'x'"),
            new ColumnDefinition("NOTE", "CLOB", Comment: "it's"),
        ]);

        Assert.Equal(
            [
                "CREATE TABLE \"SALES\".\"ORDERS\" (\n  \"ID\" NUMBER(19) GENERATED BY DEFAULT ON NULL AS IDENTITY PRIMARY KEY,\n  \"NAME\" VARCHAR2(100 CHAR) DEFAULT 'x' NOT NULL,\n  \"NOTE\" CLOB\n)",
                "COMMENT ON COLUMN \"SALES\".\"ORDERS\".\"NOTE\" IS 'it''s'",
            ],
            Build(change));
    }

    [Fact]
    public void CompositePrimaryKeyIsAConstraint()
    {
        var change = new CreateTable(Orders, [new ColumnDefinition("A", "NUMBER", IsPrimaryKey: true), new ColumnDefinition("B", "DATE", IsPrimaryKey: true)]);

        Assert.Equal(
            "CREATE TABLE \"SALES\".\"ORDERS\" (\n  \"A\" NUMBER,\n  \"B\" DATE,\n  CONSTRAINT \"PK_ORDERS\" PRIMARY KEY (\"A\", \"B\")\n)",
            Build(change)[0]);
    }

    [Fact]
    public void ColumnStatements()
    {
        Assert.Equal(
            ["ALTER TABLE \"SALES\".\"ORDERS\" ADD (\"QTY\" NUMBER(10) DEFAULT 0 NOT NULL)", "COMMENT ON COLUMN \"SALES\".\"ORDERS\".\"QTY\" IS 'count'"],
            Build(new AddColumn(new ColumnDefinition("QTY", "NUMBER(10)", false, "0", Comment: "count"))));
        Assert.Equal(["ALTER TABLE \"SALES\".\"ORDERS\" DROP COLUMN \"QTY\""], Build(new DropColumn("QTY")));
        Assert.Equal(["ALTER TABLE \"SALES\".\"ORDERS\" RENAME COLUMN \"A\" TO \"B\""], Build(new RenameColumn("A", "B")));
    }

    [Fact]
    public void AlterColumnNamesOnlyWhatChanged()
    {
        var before = new ColumnDefinition("QTY", "NUMBER(10)", false, "0");

        Assert.Equal(["ALTER TABLE \"SALES\".\"ORDERS\" MODIFY (\"QTY\" NUMBER(12))"], Build(new AlterColumn(before, before with { DataType = "NUMBER(12)" })));
        Assert.Equal(["ALTER TABLE \"SALES\".\"ORDERS\" MODIFY (\"QTY\" DEFAULT NULL)"], Build(new AlterColumn(before, before with { DefaultExpression = null })));
        Assert.Equal(["ALTER TABLE \"SALES\".\"ORDERS\" MODIFY (\"QTY\" NULL)"], Build(new AlterColumn(before, before with { IsNullable = true })));
        Assert.Equal(
            ["ALTER TABLE \"SALES\".\"ORDERS\" MODIFY (\"QTY\" NUMBER(12) DEFAULT 1 NULL)"],
            Build(new AlterColumn(before, before with { DataType = "NUMBER(12)", DefaultExpression = "1", IsNullable = true })));
        Assert.Equal(
            ["COMMENT ON COLUMN \"SALES\".\"ORDERS\".\"QTY\" IS ''", "ALTER TABLE \"SALES\".\"ORDERS\" RENAME COLUMN \"QTY\" TO \"QUANTITY\""],
            Build(new AlterColumn(before with { Comment = "old" }, before with { Name = "QUANTITY" })));
        Assert.Empty(Build(new AlterColumn(before, before with { DataType = "number(10)" })));
    }

    [Fact]
    public void IndexStatementsQualifyTheIndexWithTheTablesSchema()
    {
        Assert.Equal(
            ["CREATE UNIQUE INDEX \"SALES\".\"IX_A\" ON \"SALES\".\"ORDERS\" (\"A\", \"B\")"],
            Build(new CreateIndex(new IndexDefinition("IX_A", ["A", "B"], true))));
        Assert.Equal(["CREATE INDEX \"SALES\".\"IX_C\" ON \"SALES\".\"ORDERS\" (\"C\")"], Build(new CreateIndex(new IndexDefinition("IX_C", ["C"]))));
        Assert.Equal(["DROP INDEX \"SALES\".\"IX_A\""], Build(new DropIndex("IX_A")));
    }

    [Fact]
    public void ForeignKeysHaveOnDeleteButNoOnUpdate()
    {
        var key = new ForeignKeyDefinition("FK_C", ["CUSTOMER_ID"], new ObjectName(null, "CUSTOMERS"), ["ID"], OnDelete: "cascade", OnUpdate: "CASCADE");

        Assert.Equal(
            ["ALTER TABLE \"SALES\".\"ORDERS\" ADD CONSTRAINT \"FK_C\" FOREIGN KEY (\"CUSTOMER_ID\") REFERENCES \"SALES\".\"CUSTOMERS\" (\"ID\") ON DELETE CASCADE"],
            Build(new AddForeignKey(key)));
        Assert.EndsWith("(\"ID\")", Build(new AddForeignKey(key with { OnDelete = "NO ACTION" }))[0], StringComparison.Ordinal);
        Assert.Equal(["ALTER TABLE \"SALES\".\"ORDERS\" DROP CONSTRAINT \"FK_C\""], Build(new DropForeignKey("FK_C")));
    }

    [Fact]
    public void RenameAndTruncate()
    {
        Assert.Equal(["ALTER TABLE \"SALES\".\"ORDERS\" RENAME TO \"ORDERS_OLD\""], Build(new RenameTable("ORDERS_OLD")));
        Assert.Equal(["TRUNCATE TABLE \"SALES\".\"ORDERS\""], Build(new TruncateTable()));
        Assert.Equal(["TRUNCATE TABLE \"SALES\".\"ORDERS\" CASCADE"], Build(new TruncateTable(true)));
    }

    [Theory]
    [InlineData(ObjectKind.Table, null, false, "DROP TABLE \"SALES\".\"ORDERS\"")]
    [InlineData(ObjectKind.Table, null, true, "DROP TABLE \"SALES\".\"ORDERS\" CASCADE CONSTRAINTS")]
    [InlineData(ObjectKind.View, null, false, "DROP VIEW \"SALES\".\"ORDERS\"")]
    [InlineData(ObjectKind.View, "Synonym for HR.EMP", false, "DROP SYNONYM \"SALES\".\"ORDERS\"")]
    [InlineData(ObjectKind.MaterializedView, null, false, "DROP MATERIALIZED VIEW \"SALES\".\"ORDERS\"")]
    [InlineData(ObjectKind.Procedure, null, false, "DROP PROCEDURE \"SALES\".\"ORDERS\"")]
    [InlineData(ObjectKind.Procedure, "Package", false, "DROP PACKAGE \"SALES\".\"ORDERS\"")]
    [InlineData(ObjectKind.Function, null, false, "DROP FUNCTION \"SALES\".\"ORDERS\"")]
    [InlineData(ObjectKind.Sequence, null, false, "DROP SEQUENCE \"SALES\".\"ORDERS\"")]
    [InlineData(ObjectKind.Trigger, null, false, "DROP TRIGGER \"SALES\".\"ORDERS\"")]
    public void DropObjectByKind(ObjectKind kind, string? comment, bool cascade, string expected)
    {
        Assert.Equal([expected], Build(new DropObject(new DatabaseObject(Orders, kind, null, comment), cascade)));
    }

    [Fact]
    public void SynonymCommentNamesItsTarget()
    {
        Assert.Equal("Synonym for HR.EMP", OracleSession.SynonymComment("HR", "EMP"));
        Assert.Equal("Synonym for DUAL", OracleSession.SynonymComment(null, "DUAL"));
    }

    [Theory]
    [InlineData("VARCHAR2", 400, 100, "C", null, null, "VARCHAR2(100 CHAR)")]
    [InlineData("VARCHAR2", 100, 100, "B", null, null, "VARCHAR2(100 BYTE)")]
    [InlineData("CHAR", 1, 1, "B", null, null, "CHAR(1 BYTE)")]
    [InlineData("NVARCHAR2", 200, 100, "C", null, null, "NVARCHAR2(100)")]
    [InlineData("NUMBER", 22, 0, null, null, null, "NUMBER")]
    [InlineData("NUMBER", 22, 0, null, null, 0, "NUMBER(*,0)")]
    [InlineData("NUMBER", 22, 0, null, 10, 0, "NUMBER(10)")]
    [InlineData("NUMBER", 22, 0, null, 18, 2, "NUMBER(18,2)")]
    [InlineData("FLOAT", 22, 0, null, 126, null, "FLOAT")]
    [InlineData("FLOAT", 22, 0, null, 63, null, "FLOAT(63)")]
    [InlineData("RAW", 16, 0, null, null, null, "RAW(16)")]
    [InlineData("TIMESTAMP(6) WITH TIME ZONE", 13, 0, null, null, 6, "TIMESTAMP(6) WITH TIME ZONE")]
    [InlineData("DATE", 7, 0, null, null, null, "DATE")]
    public void TypesAreSpelledAsDdl(string type, int length, int charLength, string? charUsed, int? precision, int? scale, string expected)
    {
        Assert.Equal(expected, OracleDdl.FormatType(type, length, charLength, charUsed, precision, scale));
    }

    [Theory]
    [InlineData("123,45", "ALTER SYSTEM KILL SESSION '123,45' IMMEDIATE")]
    [InlineData(" 7, 9 ", "ALTER SYSTEM KILL SESSION '7,9' IMMEDIATE")]
    public void KillNamesTheSessionAndSerial(string id, string expected)
    {
        Assert.Equal(expected, OracleDdl.Kill(id));
    }

    [Theory]
    [InlineData("123")]
    [InlineData("1,")]
    [InlineData("1,2' --")]
    [InlineData("a,b")]
    public void KillRefusesAnythingElse(string id)
    {
        Assert.Throws<ArgumentException>(() => OracleDdl.Kill(id));
    }

    [Theory]
    [InlineData("BEFORE EACH ROW", "BEFORE")]
    [InlineData("AFTER STATEMENT", "AFTER")]
    [InlineData("INSTEAD OF", "INSTEAD OF")]
    [InlineData("COMPOUND", "AFTER")]
    public void TriggerTiming(string type, string expected)
    {
        Assert.Equal(expected, OracleDdl.Timing(type));
    }

    [Fact]
    public void TriggerDefinitionRestoresWhenAndDisable()
    {
        var sql = OracleDdl.TriggerDefinition(
            "TRG", "sales.trg BEFORE INSERT ON sales.orders FOR EACH ROW\n", "new.id IS NULL", "DISABLED", "PL/SQL     ", "BEGIN :new.id := 1; END;");

        Assert.Equal("CREATE OR REPLACE TRIGGER sales.trg BEFORE INSERT ON sales.orders FOR EACH ROW\nDISABLE\nWHEN (new.id IS NULL)\nBEGIN :new.id := 1; END;", sql);
    }

    [Fact]
    public void CallTriggerGetsItsCallKeywordBack()
    {
        var sql = OracleDdl.TriggerDefinition("TRG", "trg AFTER DELETE ON orders", null, "ENABLED", "CALL", "audit_pkg.log(1);\n");

        Assert.Equal("CREATE OR REPLACE TRIGGER trg AFTER DELETE ON orders\nCALL audit_pkg.log(1)", sql);
    }

    [Fact]
    public void TriggerWithoutDescriptionUsesItsName()
    {
        Assert.Equal("CREATE OR REPLACE TRIGGER \"TRG\"\nBEGIN NULL; END;", OracleDdl.TriggerDefinition("TRG", null, null, null, null, "BEGIN NULL; END;"));
        Assert.Equal(string.Empty, OracleDdl.TriggerDefinition("TRG", " ", null, null, null, null));
    }

    [Fact]
    public void MetadataTypesUseUnderscores()
    {
        Assert.Equal("MATERIALIZED_VIEW", OracleDdl.MetadataType("MATERIALIZED VIEW"));
        Assert.Equal("PACKAGE", OracleDdl.MetadataType("PACKAGE"));
    }

    private static List<string> ParameterTokens(string text)
    {
        var tokens = new List<string>();
        var span = text.AsSpan();
        var lexer = new SqlLexer(span, OracleDialect.Instance.LexerFeatures);
        while (lexer.TryRead(out var token))
        {
            if (token.Kind == SqlTokenKind.Parameter)
            {
                tokens.Add(token.Slice(span).ToString());
            }
        }

        return tokens;
    }
}
