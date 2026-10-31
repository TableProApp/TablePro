using TablePro.Core.Schema;
using TablePro.Drivers.Snowflake;

namespace TablePro.Drivers.Warehouse.Tests;

public sealed class SnowflakeDdlTests
{
    private static readonly ObjectName Orders = new("SALES", "ORDERS");

    private static IReadOnlyList<string> Build(SchemaChange change) =>
        SnowflakeDdl.Build(Orders, change, table => SnowflakeSql.TablePath("SHOP", table, "PUBLIC"));

    private static ColumnDefinition Column(string name, string type = "VARCHAR(100)", bool nullable = true, string? defaultValue = null, string? comment = null) =>
        new(name, type, nullable, defaultValue, Comment: comment);

    [Fact]
    public void CreateTableDeclaresColumnsKeyAndComments()
    {
        var change = new CreateTable(new ObjectName(null, "T"), [
            new ColumnDefinition("ID", "NUMBER(38,0)", IsNullable: false, IsPrimaryKey: true, IsIdentity: true),
            Column("NOTE", comment: "it's"),
            Column("STATE", "VARCHAR(10)", false, "'new'"),
        ]);

        Assert.Equal(
            ["CREATE TABLE \"SHOP\".\"PUBLIC\".\"T\" (\n  \"ID\" NUMBER(38,0) AUTOINCREMENT NOT NULL,\n  \"NOTE\" VARCHAR(100) COMMENT 'it''s',\n  \"STATE\" VARCHAR(10) DEFAULT 'new' NOT NULL,\n  PRIMARY KEY (\"ID\")\n)"],
            Build(change));
    }

    [Fact]
    public void ColumnChangesAreOneStatementEach()
    {
        Assert.Equal(["ALTER TABLE \"SHOP\".\"SALES\".\"ORDERS\" ADD COLUMN \"NOTE\" VARCHAR(100)"], Build(new AddColumn(Column("NOTE"))));
        Assert.Equal(["ALTER TABLE \"SHOP\".\"SALES\".\"ORDERS\" DROP COLUMN \"NOTE\""], Build(new DropColumn("NOTE")));
        Assert.Equal(["ALTER TABLE \"SHOP\".\"SALES\".\"ORDERS\" RENAME COLUMN \"A\" TO \"B\""], Build(new RenameColumn("A", "B")));
        Assert.Equal(["ALTER TABLE \"SHOP\".\"SALES\".\"ORDERS\" RENAME TO \"SHOP\".\"SALES\".\"ARCHIVE\""], Build(new RenameTable("ARCHIVE")));
        Assert.Equal(["TRUNCATE TABLE \"SHOP\".\"SALES\".\"ORDERS\""], Build(new TruncateTable()));
    }

    [Fact]
    public void AlterRenamesThenChangesEveryAttributeInOneStatement()
    {
        var before = Column("NOTE", "VARCHAR(100)", true, "'x'", "old");
        var after = Column("MEMO", "VARCHAR(200)", false, null, null);

        Assert.Equal(
            [
                "ALTER TABLE \"SHOP\".\"SALES\".\"ORDERS\" RENAME COLUMN \"NOTE\" TO \"MEMO\"",
                "ALTER TABLE \"SHOP\".\"SALES\".\"ORDERS\" ALTER COLUMN \"MEMO\" SET DATA TYPE VARCHAR(200), COLUMN \"MEMO\" SET NOT NULL, COLUMN \"MEMO\" UNSET COMMENT, COLUMN \"MEMO\" DROP DEFAULT",
            ],
            Build(new AlterColumn(before, after)));
    }

    [Fact]
    public void CommentIsSetWithAnEscapedLiteral()
    {
        Assert.Equal(
            ["ALTER TABLE \"SHOP\".\"SALES\".\"ORDERS\" ALTER COLUMN \"NOTE\" COMMENT 'a\\\\b'"],
            Build(new AlterColumn(Column("NOTE"), Column("NOTE", comment: "a\\b"))));
    }

    [Theory]
    [InlineData("VARCHAR(100)", "VARCHAR(50)")]
    [InlineData("NUMBER(10,2)", "NUMBER(12,4)")]
    [InlineData("NUMBER(10,0)", "VARCHAR(10)")]
    [InlineData("VARCHAR", "VARCHAR(100)")]
    public void TypeChangesSnowflakeRefusesAreNotExpressed(string from, string to)
    {
        Assert.Empty(Build(new AlterColumn(Column("C", from), Column("C", to))));
    }

    [Theory]
    [InlineData("VARCHAR(10)", "VARCHAR(20)")]
    [InlineData("VARCHAR(10)", "VARCHAR")]
    [InlineData("NUMBER(10,2)", "NUMBER(20,2)")]
    public void WideningTypeChangesAreAllowed(string from, string to)
    {
        Assert.True(SnowflakeDdl.IsSupportedTypeChange(from, to));
    }

    [Fact]
    public void ANewDefaultOnAnExistingColumnIsNotExpressed()
    {
        Assert.Empty(Build(new AlterColumn(Column("C"), Column("C", defaultValue: "'x'"))));
    }

    [Fact]
    public void IndexesAndForeignKeysAreNotExpressed()
    {
        Assert.Empty(Build(new CreateIndex(new IndexDefinition("IX", ["A"]))));
        Assert.Empty(Build(new AddForeignKey(new ForeignKeyDefinition("FK", ["A"], new ObjectName("SALES", "C"), ["ID"]))));
    }

    [Fact]
    public void DropsNameRoutinesByTheirArgumentTypes()
    {
        Assert.Equal(
            ["DROP TABLE \"SHOP\".\"SALES\".\"ORDERS\" CASCADE"],
            Build(new DropObject(new DatabaseObject(Orders, ObjectKind.Table), Cascade: true)));
        Assert.Equal(
            ["DROP FUNCTION \"SHOP\".\"SALES\".\"F\"(NUMBER, VARCHAR)"],
            Build(new DropObject(new DatabaseObject(new ObjectName("SALES", "F"), ObjectKind.Function, Comment: "F(NUMBER, VARCHAR) RETURN NUMBER"))));
        Assert.Equal(
            ["DROP VIEW \"SHOP\".\"SALES\".\"V\""],
            Build(new DropObject(new DatabaseObject(new ObjectName("SALES", "V"), ObjectKind.View), Cascade: true)));
    }
}
