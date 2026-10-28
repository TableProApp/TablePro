using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Dameng;

namespace TablePro.Drivers.Odbc.Tests;

public sealed class DamengTests
{
    private static readonly ObjectName Orders = new("SALES", "ORDERS");

    private static IReadOnlyList<string> Build(SchemaChange change, bool backslashEscapes = false) => DamengDdl.Build(Orders, change, backslashEscapes);

    [Fact]
    public void ConnectionStringDialsTheTunnelWithTheLogin()
    {
        var pairs = Profiles.Parse(DamengConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.Dameng)));

        Assert.Equal("DM8 ODBC DRIVER", pairs["DRIVER"]);
        Assert.Equal("127.0.0.1", pairs["SERVER"]);
        Assert.Equal("15432", pairs["TCP_PORT"]);
        Assert.Equal("app", pairs["UID"]);
        Assert.Equal(Profiles.Password, pairs["PWD"]);
        Assert.False(pairs.ContainsKey("SSL_PATH"));
    }

    [Fact]
    public void DefaultPortComesFromTheDescriptor()
    {
        var request = ConnectionRequest.Direct(Profiles.Profile(DatabaseEngine.Dameng), "pw") with { Port = 0 };

        Assert.Equal("5236", Profiles.Parse(DamengConnectionStringFactory.Build(request))["TCP_PORT"]);
    }

    [Fact]
    public void OptionsOverrideTheDriverAndPassThroughEscaped()
    {
        var options = new Dictionary<string, string> { ["odbcDriver"] = "DM ODBC DRIVER", ["CHAR_CODE"] = "PG;UTF8" };

        var text = DamengConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.Dameng, options: options));
        var pairs = Profiles.Parse(text);

        Assert.StartsWith("DRIVER={DM ODBC DRIVER};", text, StringComparison.Ordinal);
        Assert.Equal("PG;UTF8", pairs["CHAR_CODE"]);
        Assert.False(pairs.ContainsKey("odbcDriver"));
    }

    [Fact]
    public void AnOptionCannotReplaceTheLogin()
    {
        var options = new Dictionary<string, string> { ["UID"] = "SYSDBA" };

        Assert.Throws<ArgumentException>(() => DamengConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.Dameng, options: options)));
    }

    [Theory]
    [InlineData(SslMode.Disabled, false)]
    [InlineData(SslMode.Preferred, true)]
    [InlineData(SslMode.Required, true)]
    [InlineData(SslMode.VerifyCa, true)]
    public void SslPathIsSentForEveryModeButDisabled(SslMode mode, bool sent)
    {
        var options = new Dictionary<string, string> { ["SSL_PATH"] = @"C:\dm\client_ssl", ["SSL_PWD"] = "k}ey" };

        var pairs = Profiles.Parse(DamengConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.Dameng, ssl: mode, options: options)));

        Assert.Equal(sent, pairs.ContainsKey("SSL_PATH"));
        Assert.Equal(sent, pairs.ContainsKey("SSL_PWD"));
        if (sent)
        {
            Assert.Equal(@"C:\dm\client_ssl", pairs["SSL_PATH"]);
            Assert.Equal("k}ey", pairs["SSL_PWD"]);
        }
    }

    [Fact]
    public void PreferredWithoutCertificatesDialsPlain()
    {
        var pairs = Profiles.Parse(DamengConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.Dameng, ssl: SslMode.Preferred)));

        Assert.False(pairs.ContainsKey("SSL_PATH"));
    }

    [Theory]
    [InlineData(SslMode.Required)]
    [InlineData(SslMode.VerifyCa)]
    public void RequiredModesNeedCertificates(SslMode mode)
    {
        var error = Assert.Throws<ArgumentException>(() => DamengConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.Dameng, ssl: mode)));

        Assert.Contains("SSL_PATH", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void VerifyIdentityIsRefusedSinceNothingChecksTheHostName()
    {
        var options = new Dictionary<string, string> { ["SSL_PATH"] = @"C:\dm" };

        Assert.Throws<ArgumentException>(() => DamengConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.Dameng, ssl: SslMode.VerifyIdentity, options: options)));
    }

    [Fact]
    public void EveryConnectionSetsTheSchemaThenReadOnly()
    {
        Assert.Equal(["SET SCHEMA \"Shop\"\"s\"", "CALL SP_SET_SESSION_READONLY(1)"], DamengSession.Setup("Shop\"s", readOnly: true));
        Assert.Empty(DamengSession.Setup(null, readOnly: false));
    }

    [Fact]
    public void SessionDefaultsToTheDatabaseFieldsSchema()
    {
        var session = new DamengSession(Profiles.Tunnelled(DatabaseEngine.Dameng, startup: "SET TIME ZONE '+08:00';\nSELECT 1"));

        Assert.Equal("SHOP", session.DefaultSchema);
        Assert.Same(OracleDialect.Instance, session.Dialect);
        Assert.Equal("SESS_ID", session.ProcessIdColumn);
        Assert.Equal("ALTER TABLE \"SHOP\".\"T\" DROP COLUMN \"C\"", Assert.Single(session.BuildDdl(new ObjectName(null, "T"), new DropColumn("C"))));
    }

    [Fact]
    public void ExplainRunsDamengsOwnExplainForTheDialectsPair()
    {
        var session = new DamengSession(Profiles.Tunnelled(DatabaseEngine.Dameng));
        var pair = OracleDialect.Instance.Explain("SELECT * FROM T");

        var batch = session.PrepareBatch([.. pair]);

        Assert.Equal(["EXPLAIN SELECT * FROM T"], batch.Statements);
        Assert.Empty(batch.Cleanup);
        Assert.Equal(["EXPLAIN PLAN FOR X"], session.PrepareBatch(["EXPLAIN PLAN FOR X"]).Statements);
    }

    [Fact]
    public void SavePreviewBindsCoresNamedMarkers()
    {
        var session = new DamengSession(Profiles.Tunnelled(DatabaseEngine.Dameng));
        var update = new RowUpdate(new Dictionary<string, object?> { ["ID"] = 7 }, new Dictionary<string, object?> { ["NAME"] = "o'neil", ["NOTE"] = null });

        var preview = Assert.Single(session.PreviewChanges(Orders, [update]));

        Assert.Equal("UPDATE \"SALES\".\"ORDERS\" SET \"NAME\" = 'o''neil', \"NOTE\" = NULL WHERE \"ID\" = 7", preview);
    }

    [Fact]
    public async Task ReadOnlyProfilesRefuseToSave()
    {
        var session = new DamengSession(Profiles.Tunnelled(DatabaseEngine.Dameng, safeMode: SafeModeLevel.ReadOnly));

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            session.SaveChangesAsync(Orders, [new RowInsert(new Dictionary<string, object?> { ["ID"] = 1 })], TestContext.Current.CancellationToken));
    }

    [Fact]
    public void CreateTableInlinesASinglePrimaryKeyAndAddsComments()
    {
        var create = new CreateTable(
            Orders,
            [
                new ColumnDefinition("ID", "BIGINT", IsNullable: false, IsPrimaryKey: true, IsIdentity: true),
                new ColumnDefinition("NAME", "VARCHAR(100)", IsNullable: false, DefaultExpression: "'x'", Comment: "Customer's name"),
            ]);

        var statements = Build(create);

        Assert.Equal(
            "CREATE TABLE \"SALES\".\"ORDERS\" (\n  \"ID\" BIGINT IDENTITY(1,1) PRIMARY KEY,\n  \"NAME\" VARCHAR(100) DEFAULT 'x' NOT NULL\n)",
            statements[0]);
        Assert.Equal("COMMENT ON COLUMN \"SALES\".\"ORDERS\".\"NAME\" IS 'Customer''s name'", statements[1]);
    }

    [Fact]
    public void CompositeKeysGetATableConstraint()
    {
        var create = new CreateTable(Orders, [new ColumnDefinition("A", "INT", IsPrimaryKey: true), new ColumnDefinition("B", "INT", IsPrimaryKey: true)]);

        Assert.EndsWith(",\n  PRIMARY KEY (\"A\", \"B\")\n)", Build(create)[0], StringComparison.Ordinal);
    }

    [Fact]
    public void AlterColumnRenamesFirstThenRestatesTheWholeColumn()
    {
        var before = new ColumnDefinition("NAME", "VARCHAR(50)", IsNullable: false, DefaultExpression: "'a'");
        var after = new ColumnDefinition("FULL_NAME", "VARCHAR(100)", IsNullable: true, Comment: "C:\\path");

        var statements = Build(new AlterColumn(before, after), backslashEscapes: true);

        Assert.Equal(
            [
                "ALTER TABLE \"SALES\".\"ORDERS\" RENAME COLUMN \"NAME\" TO \"FULL_NAME\"",
                "ALTER TABLE \"SALES\".\"ORDERS\" MODIFY \"FULL_NAME\" VARCHAR(100) DEFAULT NULL NULL",
                "COMMENT ON COLUMN \"SALES\".\"ORDERS\".\"FULL_NAME\" IS 'C:\\\\path'",
            ],
            statements);
    }

    [Fact]
    public void AlterColumnOnlyCommentsWhenOnlyTheCommentChanged()
    {
        var before = new ColumnDefinition("NAME", "VARCHAR(50)");

        Assert.Equal(["COMMENT ON COLUMN \"SALES\".\"ORDERS\".\"NAME\" IS ''"], Build(new AlterColumn(before with { Comment = "x" }, before)));
    }

    [Fact]
    public void StructureStatementsFollowTheMacOSDriver()
    {
        Assert.Equal("ALTER TABLE \"SALES\".\"ORDERS\" ADD \"QTY\" INT DEFAULT 0 NOT NULL", Assert.Single(Build(new AddColumn(new ColumnDefinition("QTY", "INT", false, "0")))));
        Assert.Equal("CREATE UNIQUE INDEX \"SALES\".\"IX\" ON \"SALES\".\"ORDERS\" (\"A\", \"B\")", Assert.Single(Build(new CreateIndex(new IndexDefinition("IX", ["A", "B"], true)))));
        Assert.Equal("DROP INDEX \"SALES\".\"IX\"", Assert.Single(Build(new DropIndex("IX"))));
        Assert.Equal("ALTER TABLE \"SALES\".\"ORDERS\" RENAME TO \"ORDERS_OLD\"", Assert.Single(Build(new RenameTable("ORDERS_OLD"))));
        Assert.Equal("ALTER TABLE \"SALES\".\"ORDERS\" DROP CONSTRAINT \"FK\"", Assert.Single(Build(new DropForeignKey("FK"))));
        Assert.Equal("TRUNCATE TABLE \"SALES\".\"ORDERS\"", Assert.Single(Build(new TruncateTable(Cascade: true))));
        Assert.Equal("DROP TABLE \"SALES\".\"ORDERS\" CASCADE", Assert.Single(Build(new DropObject(new DatabaseObject(Orders, ObjectKind.Table), true))));
        Assert.Equal("DROP SEQUENCE \"SALES\".\"S\"", Assert.Single(Build(new DropObject(new DatabaseObject(new ObjectName("SALES", "S"), ObjectKind.Sequence)))));
    }

    [Fact]
    public void ForeignKeysWriteOnlyTheDeleteActionDamengTakes()
    {
        var key = new ForeignKeyDefinition("FK_C", ["CUSTOMER_ID"], new ObjectName(null, "CUSTOMERS"), ["ID"], OnDelete: "cascade", OnUpdate: "CASCADE");

        Assert.Equal(
            "ALTER TABLE \"SALES\".\"ORDERS\" ADD CONSTRAINT \"FK_C\" FOREIGN KEY (\"CUSTOMER_ID\") REFERENCES \"SALES\".\"CUSTOMERS\" (\"ID\") ON DELETE CASCADE",
            Assert.Single(Build(new AddForeignKey(key))));
    }

    [Theory]
    [InlineData("123", 123L)]
    [InlineData(" 9 ", 9L)]
    public void KillTakesANumericSession(string id, long expected) => Assert.Equal(expected, DamengDdl.SessionId(id));

    [Theory]
    [InlineData("1; DROP TABLE T")]
    [InlineData("-1")]
    [InlineData("")]
    public void KillRefusesAnythingElse(string id) => Assert.Throws<ArgumentException>(() => DamengDdl.SessionId(id));

    [Theory]
    [InlineData("varchar", 50, null, null, "VARCHAR(50)")]
    [InlineData("NUMBER", 22, 10, 2, "NUMBER(10,2)")]
    [InlineData("DECIMAL", 9, 9, 0, "DECIMAL(9)")]
    [InlineData("TIMESTAMP", 8, null, 3, "TIMESTAMP(3)")]
    [InlineData("INT", 4, 10, 0, "INT")]
    [InlineData("CLOB", 0, null, null, "CLOB")]
    public void TypesRenderAsTheMacOSDriverRendersThem(string name, int? length, int? precision, int? scale, string expected) =>
        Assert.Equal(expected, DamengDdl.FormatType(name, length, precision, scale));

    [Fact]
    public void ObjectRowsMapToKinds()
    {
        var table = DamengCatalog.MapObject("SALES", ["ORDERS", "TABLE", 1200m, " Orders "]);
        Assert.Equal(new DatabaseObject(new ObjectName("SALES", "ORDERS"), ObjectKind.Table, 1200, "Orders"), table);
        Assert.Equal(ObjectKind.View, DamengCatalog.MapObject("SALES", ["V", "VIEW", null, null]).Kind);
        Assert.Equal(ObjectKind.Function, DamengCatalog.MapObject("SALES", ["F", "FUNCTION", null, null]).Kind);
        Assert.Equal(ObjectKind.Trigger, DamengCatalog.MapObject("SALES", ["G", "TRIGGER", null, null]).Kind);
    }

    [Fact]
    public void ColumnRowsMapWithIdentityAndComments()
    {
        object?[] row = ["ID", "BIGINT", 8, 19, 0, "N", "Y", null, "NEXT VALUE"];
        object?[] name = ["NAME", "VARCHAR", 100, null, null, "Y", "N", " the name ", " 'x' "];
        var identity = new HashSet<string>(StringComparer.Ordinal) { "ID" };

        var id = DamengCatalog.MapColumn(row, 0, identity);
        var text = DamengCatalog.MapColumn(name, 1, identity);

        Assert.Equal(new ColumnInfo("ID", "BIGINT", false, null, true, true, 0), id);
        Assert.Equal(new ColumnInfo("NAME", "VARCHAR(100)", true, "'x'", false, false, 1, "the name"), text);
    }

    [Fact]
    public void IndexRowsGroupByIndexInColumnOrder()
    {
        var indexes = DamengCatalog.MapIndexes(
        [
            ["PK_ORDERS", "UNIQUE", "ID", "Y"],
            ["IX_NAME", "NONUNIQUE", "LAST", "N"],
            ["IX_NAME", "NONUNIQUE", "FIRST", "N"],
        ]);

        Assert.Equal(2, indexes.Count);
        Assert.Equal(("PK_ORDERS", true, true), (indexes[0].Name, indexes[0].IsUnique, indexes[0].IsPrimary));
        Assert.Equal(["ID"], indexes[0].Columns);
        Assert.Equal(["LAST", "FIRST"], indexes[1].Columns);
        Assert.False(indexes[1].IsUnique);
    }

    [Fact]
    public void ForeignKeyRowsGroupColumnsByConstraint()
    {
        var keys = DamengCatalog.MapForeignKeys(
        [
            ["FK_X", "A", "REF", "PARENT", "PA", "CASCADE"],
            ["FK_X", "B", "REF", "PARENT", "PB", "CASCADE"],
        ]);

        var key = Assert.Single(keys);
        Assert.Equal(["A", "B"], key.Columns);
        Assert.Equal(["PA", "PB"], key.ReferencedColumns);
        Assert.Equal(new ObjectName("REF", "PARENT"), key.ReferencedTable);
        Assert.Equal("CASCADE", key.OnDelete);
        Assert.Equal("NO ACTION", key.OnUpdate);
    }

    [Fact]
    public void TriggerRowsRebuildTheirDefinition()
    {
        var trigger = DamengCatalog.MapTrigger(["TRG", "BEFORE EACH ROW", "INSERT", "\"SALES\".\"TRG\" BEFORE INSERT ON \"SALES\".\"ORDERS\" FOR EACH ROW", "BEGIN NULL; END;"]);

        Assert.Equal("BEFORE", trigger.Timing);
        Assert.Equal("INSERT", trigger.Event);
        Assert.Equal("CREATE OR REPLACE TRIGGER \"SALES\".\"TRG\" BEFORE INSERT ON \"SALES\".\"ORDERS\" FOR EACH ROW\nBEGIN NULL; END;", trigger.Definition);
        Assert.Equal("INSTEAD OF", DamengCatalog.MapTrigger(["T", "INSTEAD OF", "UPDATE", null, null]).Timing);
    }

    [Fact]
    public void SystemSchemasAreHiddenUnlessTheSessionIsInOne()
    {
        Assert.Equal(["SALES", "SYSDBA"], DamengCatalog.UserSchemas(["CTISYS", "SALES", "SYS", "SYSDBA"], "SALES"));
        Assert.Equal(["SYS"], DamengCatalog.UserSchemas(["SYS"], "SYS"));
    }

    [Fact]
    public void DefinitionsKeepStoredStatementsAndWrapBareOnes()
    {
        Assert.Equal("CREATE VIEW V AS SELECT 1", DamengCatalog.ViewDefinition(new ObjectName("S", "V"), " CREATE VIEW V AS SELECT 1 "));
        Assert.Equal("CREATE OR REPLACE VIEW \"S\".\"V\" AS\nSELECT 1", DamengCatalog.ViewDefinition(new ObjectName("S", "V"), "SELECT 1"));
        Assert.Equal("CREATE OR REPLACE PROCEDURE P AS\nBEGIN NULL; END;", DamengCatalog.RoutineDefinition(["PROCEDURE P AS\n", "BEGIN NULL; END;"]));
    }

    [Fact]
    public void TableDefinitionFallsBackToTheDictionary()
    {
        var columns = new[]
        {
            new ColumnInfo("ID", "INT", false, null, true, true, 0),
            new ColumnInfo("NAME", "VARCHAR(10)", true, "'n'", false, false, 1, "it's"),
        };
        var indexes = DamengDdl.IndexStatements(Orders, [["IX", "UNIQUE", "NAME"]]);

        var sql = DamengDdl.TableDefinition(Orders, columns, indexes, backslashEscapes: false);

        Assert.Equal(
            "CREATE TABLE \"SALES\".\"ORDERS\" (\n  \"ID\" INT IDENTITY(1,1) NOT NULL,\n  \"NAME\" VARCHAR(10) DEFAULT 'n',\n  PRIMARY KEY (\"ID\")\n);"
            + "\n\nCREATE UNIQUE INDEX \"SALES\".\"IX\" ON \"SALES\".\"ORDERS\" (\"NAME\");"
            + "\n\nCOMMENT ON COLUMN \"SALES\".\"ORDERS\".\"NAME\" IS 'it''s';",
            sql);
    }

    [Fact]
    public void SequenceDefinitionStartsWhereTheSequenceIs()
    {
        var sql = DamengDdl.SequenceDefinition(new ObjectName("S", "SEQ"), [1m, 9999m, 1m, "N", 20m, 41m]);

        Assert.Equal("CREATE SEQUENCE \"S\".\"SEQ\" START WITH 41 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9999 NOCYCLE CACHE 20;", sql);
    }

    [Fact]
    public void LiteralsFollowTheServersBackslashMode()
    {
        Assert.Equal(@"'a\b''c'", DamengDdl.StringLiteral("a\\b'c\0", backslashEscapes: false));
        Assert.Equal(@"'a\\b''c'", DamengDdl.StringLiteral("a\\b'c", backslashEscapes: true));
    }

    [Fact]
    public async Task AMissingDriverIsNamedPlainly()
    {
        var options = new Dictionary<string, string> { ["odbcDriver"] = "TablePro Missing Dameng Driver" };
        var request = ConnectionRequest.Direct(Profiles.Profile(DatabaseEngine.Dameng, options: options), "pw");

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => new DamengDriver().ConnectAsync(request, TestContext.Current.CancellationToken));

        Assert.Contains("\"TablePro Missing Dameng Driver\" is not installed", error.Message, StringComparison.Ordinal);
        Assert.Contains("eco.dameng.com", error.Message, StringComparison.Ordinal);
    }
}
