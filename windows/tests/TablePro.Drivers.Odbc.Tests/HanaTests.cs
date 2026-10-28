extern alias hana;

using hana::TablePro.Drivers.Hana;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Odbc.Tests;

public sealed class HanaTests
{
    private static readonly ObjectName Orders = new("SALES", "ORDERS");

    private static IReadOnlyList<string> Build(SchemaChange change) => HanaDdl.Build(Orders, change);

    [Fact]
    public void ConnectionStringDialsTheTunnelWithTheLogin()
    {
        var pairs = Profiles.Parse(HanaConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.SapHana)));

        Assert.Equal("HDBODBC", pairs["DRIVER"]);
        Assert.Equal("127.0.0.1:15432", pairs["SERVERNODE"]);
        Assert.Equal("app", pairs["UID"]);
        Assert.Equal(Profiles.Password, pairs["PWD"]);
        Assert.Equal("7000", pairs["CONNECTTIMEOUT"]);
        Assert.False(pairs.ContainsKey("CURRENTSCHEMA"));
        Assert.False(pairs.ContainsKey("DATABASENAME"));
    }

    [Fact]
    public void DefaultPortComesFromTheDescriptor()
    {
        var request = ConnectionRequest.Direct(Profiles.Profile(DatabaseEngine.SapHana), "pw") with { Port = 0 };

        Assert.Equal("db.example.com:30015", Profiles.Parse(HanaConnectionStringFactory.Build(request))["SERVERNODE"]);
    }

    [Theory]
    [InlineData("::1", 30015, "[::1]:30015")]
    [InlineData("[fe80::1]", 443, "[fe80::1]:443")]
    [InlineData("hana.example.com", 443, "hana.example.com:443")]
    public void ServerNodeBracketsIpv6(string host, int port, string expected) => Assert.Equal(expected, HanaConnectionStringFactory.ServerNode(host, port));

    [Fact]
    public void TenantAndDriverOptionsAreTranslatedAndOthersPassThrough()
    {
        var options = new Dictionary<string, string> { ["tenant"] = "HXE", ["odbcDriver"] = "HDBODBC32", ["sslTrustStore"] = @"C:\certs\ca.pem", ["CONNECTTIMEOUT"] = "500" };

        var pairs = Profiles.Parse(HanaConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.SapHana, options: options)));

        Assert.Equal("HXE", pairs["DATABASENAME"]);
        Assert.Equal("HDBODBC32", pairs["DRIVER"]);
        Assert.Equal(@"C:\certs\ca.pem", pairs["sslTrustStore"]);
        Assert.Equal("500", pairs["CONNECTTIMEOUT"]);
        Assert.False(pairs.ContainsKey("tenant"));
    }

    [Theory]
    [InlineData("ENCRYPT")]
    [InlineData("sslValidateCertificate")]
    [InlineData("servernode")]
    public void AnOptionCannotWeakenTlsOrRedirectTheConnection(string key)
    {
        var options = new Dictionary<string, string> { [key] = "FALSE" };

        Assert.Throws<ArgumentException>(() => HanaConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.SapHana, options: options)));
    }

    [Theory]
    [InlineData(SslMode.Disabled, "FALSE", null, null)]
    [InlineData(SslMode.Preferred, "TRUE", "FALSE", null)]
    [InlineData(SslMode.Required, "TRUE", "FALSE", null)]
    [InlineData(SslMode.VerifyCa, "TRUE", "TRUE", "*")]
    [InlineData(SslMode.VerifyIdentity, "TRUE", "TRUE", "db.example.com")]
    public void EverySslModeMapsToTheClientsKeys(SslMode mode, string encrypt, string? validate, string? hostName)
    {
        var pairs = Profiles.Parse(HanaConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.SapHana, ssl: mode)));

        Assert.Equal(encrypt, pairs["ENCRYPT"]);
        Assert.Equal(validate, pairs.GetValueOrDefault("sslValidateCertificate"));
        Assert.Equal(hostName, pairs.GetValueOrDefault("sslHostNameInCertificate"));
    }

    [Fact]
    public void VerifyIdentityPrefersTheTlsServerNameOption()
    {
        var options = new Dictionary<string, string> { ["hanaTLSServerName"] = "abc.hanacloud.ondemand.com" };

        var pairs = Profiles.Parse(HanaConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.SapHana, ssl: SslMode.VerifyIdentity, options: options)));

        Assert.Equal("abc.hanacloud.ondemand.com", pairs["sslHostNameInCertificate"]);
        Assert.False(pairs.ContainsKey("hanaTLSServerName"));
    }

    [Fact]
    public void ReadOnlyProfilesPoolApartFromWritableOnes()
    {
        var readOnly = Profiles.Parse(HanaConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.SapHana, safeMode: SafeModeLevel.ReadOnly)));
        var writable = Profiles.Parse(HanaConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.SapHana, safeMode: SafeModeLevel.SafeModeFull)));

        Assert.Equal("READONLY", readOnly["sessionVariable:TABLEPRO_ACCESS"]);
        Assert.False(writable.ContainsKey("sessionVariable:TABLEPRO_ACCESS"));
    }

    [Fact]
    public void EveryConnectionSetsTheSchemaThenReadOnly()
    {
        Assert.Equal(["SET SCHEMA \"MySchema\"", "SET TRANSACTION READ ONLY"], HanaSession.Setup("MySchema", readOnly: true));
        Assert.Empty(HanaSession.Setup(" ".Trim(), readOnly: false));
    }

    [Fact]
    public void SessionDefaultsToTheDatabaseFieldsSchema()
    {
        var session = new HanaSession(Profiles.Tunnelled(DatabaseEngine.SapHana));

        Assert.Equal("SHOP", session.DefaultSchema);
        Assert.Same(HanaDialect.Instance, session.Dialect);
        Assert.Equal("CONNECTION_ID", session.ProcessIdColumn);
        Assert.Equal("ALTER TABLE \"SHOP\".\"T\" DROP (\"C\")", Assert.Single(session.BuildDdl(new ObjectName(null, "T"), new DropColumn("C"))));
    }

    [Fact]
    public void ExplainUsesItsOwnStatementNameAndCleansUp()
    {
        var batch = HanaSession.Explain("SELECT * FROM T;", "TABLEPRO_X");

        Assert.Equal(
            [
                "EXPLAIN PLAN SET STATEMENT_NAME = 'TABLEPRO_X' FOR SELECT * FROM T",
                "SELECT OPERATOR_ID, PARENT_OPERATOR_ID, POSITION, OPERATOR_NAME, OPERATOR_DETAILS, SCHEMA_NAME, TABLE_NAME, OUTPUT_SIZE, SUBTREE_COST "
                + "FROM SYS.EXPLAIN_PLAN_TABLE WHERE STATEMENT_NAME = 'TABLEPRO_X' ORDER BY OPERATOR_ID",
            ],
            batch.Statements);
        Assert.Equal(["DELETE FROM SYS.EXPLAIN_PLAN_TABLE WHERE STATEMENT_NAME = 'TABLEPRO_X'"], batch.Cleanup);
    }

    [Fact]
    public void OnlyTheDialectsExplainPairIsRewritten()
    {
        var session = new HanaSession(Profiles.Tunnelled(DatabaseEngine.SapHana));

        var batch = session.PrepareBatch([.. HanaDialect.Instance.Explain("SELECT 1 FROM DUMMY")]);

        Assert.StartsWith("EXPLAIN PLAN SET STATEMENT_NAME = 'TABLEPRO_", batch.Statements[0], StringComparison.Ordinal);
        Assert.Single(batch.Cleanup);
        Assert.Equal(["SELECT 1 FROM DUMMY", "SELECT 2 FROM DUMMY"], session.PrepareBatch(["SELECT 1 FROM DUMMY", "SELECT 2 FROM DUMMY"]).Statements);
    }

    [Fact]
    public void SavePreviewWritesRepeatedQuestionMarksInOrder()
    {
        var session = new HanaSession(Profiles.Tunnelled(DatabaseEngine.SapHana));
        var update = new RowUpdate(new Dictionary<string, object?> { ["ID"] = 7 }, new Dictionary<string, object?> { ["NAME"] = "x", ["QTY"] = 2 });

        var preview = Assert.Single(session.PreviewChanges(Orders, [update]));

        Assert.Equal("UPDATE \"SALES\".\"ORDERS\" SET \"NAME\" = 'x', \"QTY\" = 2 WHERE \"ID\" = 7", preview);
    }

    [Fact]
    public async Task ReadOnlyProfilesRefuseToSave()
    {
        var session = new HanaSession(Profiles.Tunnelled(DatabaseEngine.SapHana, safeMode: SafeModeLevel.ReadOnly));

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            session.SaveChangesAsync(Orders, [new RowDelete(new Dictionary<string, object?> { ["ID"] = 1 })], TestContext.Current.CancellationToken));
    }

    [Fact]
    public void CreateTableMakesAColumnTable()
    {
        var create = new CreateTable(
            Orders,
            [
                new ColumnDefinition("ID", "BIGINT", IsNullable: false, IsPrimaryKey: true, IsIdentity: true),
                new ColumnDefinition("NAME", "NVARCHAR(100)", IsNullable: false, DefaultExpression: "''", Comment: "it's"),
            ]);

        var statements = Build(create);

        Assert.Equal(
            "CREATE COLUMN TABLE \"SALES\".\"ORDERS\" (\n  \"ID\" BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,\n  \"NAME\" NVARCHAR(100) DEFAULT '' NOT NULL\n)",
            statements[0]);
        Assert.Equal("COMMENT ON COLUMN \"SALES\".\"ORDERS\".\"NAME\" IS N'it''s'", statements[1]);
    }

    [Fact]
    public void StructureStatementsUseHanasOwnSpelling()
    {
        Assert.Equal("ALTER TABLE \"SALES\".\"ORDERS\" ADD (\"QTY\" INTEGER DEFAULT 0 NOT NULL)", Assert.Single(Build(new AddColumn(new ColumnDefinition("QTY", "INTEGER", false, "0")))));
        Assert.Equal("ALTER TABLE \"SALES\".\"ORDERS\" DROP (\"QTY\")", Assert.Single(Build(new DropColumn("QTY"))));
        Assert.Equal("RENAME COLUMN \"SALES\".\"ORDERS\".\"A\" TO \"B\"", Assert.Single(Build(new RenameColumn("A", "B"))));
        Assert.Equal("RENAME TABLE \"SALES\".\"ORDERS\" TO \"ORDERS_OLD\"", Assert.Single(Build(new RenameTable("ORDERS_OLD"))));
        Assert.Equal("CREATE INDEX \"SALES\".\"IX\" ON \"SALES\".\"ORDERS\" (\"A\")", Assert.Single(Build(new CreateIndex(new IndexDefinition("IX", ["A"])))));
        Assert.Equal("DROP INDEX \"SALES\".\"IX\"", Assert.Single(Build(new DropIndex("IX"))));
        Assert.Equal("TRUNCATE TABLE \"SALES\".\"ORDERS\"", Assert.Single(Build(new TruncateTable(true))));
        Assert.Equal("DROP VIEW \"SALES\".\"V\" CASCADE", Assert.Single(Build(new DropObject(new DatabaseObject(new ObjectName("SALES", "V"), ObjectKind.View), true))));
        Assert.Equal("DROP TRIGGER \"SALES\".\"G\"", Assert.Single(Build(new DropObject(new DatabaseObject(new ObjectName("SALES", "G"), ObjectKind.Trigger), true))));
    }

    [Fact]
    public void AlterColumnRestatesTheTypeAndRenamesLast()
    {
        var before = new ColumnDefinition("NAME", "NVARCHAR(50)", IsNullable: true, DefaultExpression: "'a'", Comment: "old");
        var after = new ColumnDefinition("FULL_NAME", "NVARCHAR(100)", IsNullable: false);

        Assert.Equal(
            [
                "ALTER TABLE \"SALES\".\"ORDERS\" ALTER (\"NAME\" NVARCHAR(100) DEFAULT NULL NOT NULL)",
                "COMMENT ON COLUMN \"SALES\".\"ORDERS\".\"NAME\" IS NULL",
                "RENAME COLUMN \"SALES\".\"ORDERS\".\"NAME\" TO \"FULL_NAME\"",
            ],
            Build(new AlterColumn(before, after)));
    }

    [Fact]
    public void ForeignKeysWriteBothActionsHanaTakes()
    {
        var key = new ForeignKeyDefinition("FK", ["C"], new ObjectName("REF", "P"), ["ID"], OnDelete: "set  null", OnUpdate: "NO ACTION");

        Assert.Equal(
            "ALTER TABLE \"SALES\".\"ORDERS\" ADD CONSTRAINT \"FK\" FOREIGN KEY (\"C\") REFERENCES \"REF\".\"P\" (\"ID\") ON DELETE SET NULL",
            Assert.Single(Build(new AddForeignKey(key))));
    }

    [Theory]
    [InlineData("200123", "ALTER SYSTEM DISCONNECT SESSION '200123'")]
    [InlineData(" 7 ", "ALTER SYSTEM DISCONNECT SESSION '7'")]
    public void KillDisconnectsANumericConnection(string id, string expected) => Assert.Equal(expected, HanaDdl.Kill(id));

    [Theory]
    [InlineData("1' --")]
    [InlineData("")]
    public void KillRefusesAnythingElse(string id) => Assert.Throws<ArgumentException>(() => HanaDdl.Kill(id));

    [Theory]
    [InlineData("NVARCHAR", 100, null, "NVARCHAR(100)")]
    [InlineData("DECIMAL", 18, 2, "DECIMAL(18,2)")]
    [InlineData("DECIMAL", 34, null, "DECIMAL")]
    [InlineData("INTEGER", 10, 0, "INTEGER")]
    [InlineData("VARBINARY", 16, null, "VARBINARY(16)")]
    public void TypesRenderAsTheMacOSDriverRendersThem(string name, int? length, int? scale, string expected) =>
        Assert.Equal(expected, HanaCatalog.RenderType(name, length, scale));

    [Fact]
    public void ObjectRowsMapToKinds()
    {
        Assert.Equal(new DatabaseObject(new ObjectName("S", "T"), ObjectKind.Table, 5, "orders"), HanaCatalog.MapObject("S", ["T", "TABLE", 5L, "orders"]));
        Assert.Equal(new DatabaseObject(new ObjectName("S", "V"), ObjectKind.View, null, "v"), HanaCatalog.MapObject("S", ["V", "VIEW", null, "v"]));
        Assert.Equal(ObjectKind.Procedure, HanaCatalog.MapObject("S", ["P", "PROCEDURE", null, null]).Kind);
        Assert.Equal(ObjectKind.Sequence, HanaCatalog.MapObject("S", ["Q", "SEQUENCE", null, null]).Kind);
    }

    [Fact]
    public void ColumnRowsMapIdentityKeysAndDefaults()
    {
        var id = HanaCatalog.MapColumn(["ID", "BIGINT", 19, 0, "FALSE", "BY DEFAULT AS IDENTITY", 1, null, "\"SALES\".\"_SYS_SEQUENCE\"", null], 0);
        var name = HanaCatalog.MapColumn(["NAME", "NVARCHAR", 50, null, "TRUE", null, null, "the name", "x", null], 1);
        var total = HanaCatalog.MapColumn(["TOTAL", "DECIMAL", 18, 2, "TRUE", "ALWAYS AS", null, null, null, "QTY * PRICE"], 2);

        Assert.Equal(new ColumnInfo("ID", "BIGINT", false, null, true, true, 0), id);
        Assert.Equal(new ColumnInfo("NAME", "NVARCHAR(50)", true, "x", false, false, 1, "the name"), name);
        Assert.Equal(new ColumnInfo("TOTAL", "DECIMAL(18,2)", true, null, false, false, 2), total);
    }

    [Fact]
    public void IndexRowsMapConstraintsAndDirection()
    {
        var indexes = HanaCatalog.MapIndexes(
        [
            ["_SYS_TREE_RS_1_#0_#P0", "CPBTREE", "PRIMARY KEY", "ID", "TRUE"],
            ["IX_U", "BTREE", "NOT NULL UNIQUE", "A", "FALSE"],
            ["IX_U", "BTREE", null, "B", "TRUE"],
            ["IX_N", "INVERTED VALUE", null, "C", "TRUE"],
        ]);

        Assert.Equal(3, indexes.Count);
        Assert.True(indexes[0].IsPrimary && indexes[0].IsUnique);
        Assert.Equal(["A DESC", "B"], indexes[1].Columns);
        Assert.True(indexes[1].IsUnique);
        Assert.False(indexes[1].IsPrimary);
        Assert.False(indexes[2].IsUnique);
        Assert.Equal("INVERTED VALUE", indexes[2].Method);
    }

    [Fact]
    public void IndexStatementsSkipThePrimaryKeyAndKeepDirection()
    {
        var statements = HanaDdl.IndexStatements(Orders,
        [
            ["PK", "CPBTREE", "PRIMARY KEY", "ID", "TRUE"],
            ["IX_U", "BTREE", "UNIQUE", "A", "FALSE"],
            ["IX_F", "FULLTEXT INDEX", null, "D", "TRUE"],
        ]);

        Assert.Equal(["CREATE UNIQUE BTREE INDEX \"SALES\".\"IX_U\" ON \"SALES\".\"ORDERS\" (\"A\" DESC);"], statements);
    }

    [Fact]
    public void ForeignKeyRowsCarryBothRules()
    {
        var key = Assert.Single(HanaCatalog.MapForeignKeys([["FK", "C", "REF", "P", "ID", "CASCADE", null]]));

        Assert.Equal(new ObjectName("REF", "P"), key.ReferencedTable);
        Assert.Equal("CASCADE", key.OnUpdate);
        Assert.Equal("RESTRICT", key.OnDelete);
    }

    [Fact]
    public void TriggerRowsKeepTheStoredStatement()
    {
        var trigger = HanaCatalog.MapTrigger(["TRG", "before", "insert", "CREATE TRIGGER TRG BEFORE INSERT ON T FOR EACH ROW BEGIN END"]);

        Assert.Equal(new TriggerInfo("TRG", "BEFORE", "INSERT", "CREATE TRIGGER TRG BEFORE INSERT ON T FOR EACH ROW BEGIN END"), trigger);
    }

    [Fact]
    public void SystemSchemasAreHiddenUnlessTheSessionIsInOne()
    {
        Assert.Equal(["DBADMIN", "SALES"], HanaCatalog.UserSchemas(["DBADMIN", "SALES", "SYS", "_SYS_BI", "SYS_DATABASES"], "SALES"));
        Assert.Equal(["_SYS_BIC"], HanaCatalog.UserSchemas(["_SYS_BIC"], "_SYS_BIC"));
    }

    [Fact]
    public void TableDefinitionFallsBackToTheCatalog()
    {
        object?[][] columns =
        [
            ["ID", "BIGINT", 19, 0, "FALSE", "ALWAYS AS IDENTITY", 1, null, null, null],
            ["NAME", "NVARCHAR", 20, null, "TRUE", null, null, "who", "anon", null],
            ["AT", "TIMESTAMP", 27, 7, "TRUE", null, null, null, "CURRENT_TIMESTAMP", null],
        ];

        var sql = HanaDdl.TableDefinition(Orders, isColumnTable: true, columns, [["IX", "BTREE", null, "NAME", "TRUE"]], "Orders table");

        Assert.Equal(
            "CREATE COLUMN TABLE \"SALES\".\"ORDERS\" (\n  \"ID\" BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,\n  \"NAME\" NVARCHAR(20) DEFAULT N'anon',\n"
            + "  \"AT\" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n  PRIMARY KEY (\"ID\")\n);"
            + "\n\nCREATE BTREE INDEX \"SALES\".\"IX\" ON \"SALES\".\"ORDERS\" (\"NAME\");"
            + "\n\nCOMMENT ON TABLE \"SALES\".\"ORDERS\" IS N'Orders table';"
            + "\n\nCOMMENT ON COLUMN \"SALES\".\"ORDERS\".\"NAME\" IS N'who';",
            sql);
    }

    [Fact]
    public void SequenceAndStoredDefinitions()
    {
        Assert.Equal(
            "CREATE SEQUENCE \"S\".\"Q\" START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 4611686018427387903 NO CYCLE NO CACHE;",
            HanaDdl.SequenceDefinition(new ObjectName("S", "Q"), [1L, 1L, 4611686018427387903L, 1L, "FALSE", 1]));
        Assert.Equal("CREATE VIEW \"S\".\"V\" AS\nSELECT 1 FROM DUMMY", HanaDdl.ViewDefinition(new ObjectName("S", "V"), " SELECT 1 FROM DUMMY "));
        Assert.Equal("CREATE PROCEDURE P AS BEGIN END", HanaDdl.StoredDefinition("PROCEDURE P AS BEGIN END"));
    }

    [Fact]
    public async Task AMissingDriverIsNamedPlainly()
    {
        var options = new Dictionary<string, string> { ["odbcDriver"] = "TablePro Missing HANA Driver" };
        var request = ConnectionRequest.Direct(Profiles.Profile(DatabaseEngine.SapHana, options: options), "pw");

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => new HanaDriver().ConnectAsync(request, TestContext.Current.CancellationToken));

        Assert.Contains("\"TablePro Missing HANA Driver\" is not installed", error.Message, StringComparison.Ordinal);
        Assert.Contains("SAP HANA Client", error.Message, StringComparison.Ordinal);
    }
}
