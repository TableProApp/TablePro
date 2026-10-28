using TablePro.Core.Compare;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Core.Tests.Compare;

public sealed class SchemaCompareTests
{
    private static ColumnInfo Column(string name, string type, int ordinal, bool nullable = true, bool pk = false, string? defaultValue = null) =>
        new(name, type, nullable, defaultValue, pk, IsIdentity: false, ordinal);

    private static TableStructure Table(string schema, string name, ColumnInfo[] columns, IndexInfo[]? indexes = null, ForeignKeyInfo[]? keys = null) =>
        new(new ObjectName(schema, name), columns, indexes ?? [], keys ?? [], []);

    private static readonly TableStructure SourceUsers = Table("dev", "users",
        [Column("id", "integer", 0, nullable: false, pk: true), Column("email", "character varying(200)", 1, nullable: false), Column("age", "int", 2)],
        [new IndexInfo("users_pkey", ["id"], true, true), new IndexInfo("users_email", ["email"], IsUnique: true, IsPrimary: false)]);

    private static readonly TableStructure SourceOrders = Table("dev", "orders",
        [Column("id", "int4", 0, nullable: false, pk: true), Column("user_id", "int4", 1)],
        keys: [new ForeignKeyInfo("orders_user", ["user_id"], new ObjectName("dev", "users"), ["id"])]);

    [Fact]
    public void IdenticalStructuresAcrossSchemasMatch()
    {
        var target = SourceUsers with { Table = new ObjectName("prod", "users") };

        var diff = Assert.Single(SchemaDiffEngine.Compare([SourceUsers], [target]));

        Assert.Equal(SchemaDiffKind.Identical, diff.Kind);
    }

    [Fact]
    public void TypeAliasesAndSpacingDoNotCountAsDifferences()
    {
        Assert.Equal(SchemaDiffEngine.NormalizeType("INTEGER"), SchemaDiffEngine.NormalizeType("int4"));
        Assert.Equal("varchar(200)", SchemaDiffEngine.NormalizeType("character  varying( 200 )"));
        Assert.Equal("geometry(point,4326)", SchemaDiffEngine.NormalizeType("public.geometry(Point, 4326)"));
        Assert.Equal("'x'", SchemaDiffEngine.NormalizeDefault("('x'::character varying)"));
        Assert.Null(SchemaDiffEngine.NormalizeDefault("NULL"));
    }

    [Fact]
    public void ColumnDifferencesBecomeEdits()
    {
        var target = Table("prod", "users",
            [Column("id", "int", 0, nullable: false, pk: true), Column("email", "varchar(100)", 1, nullable: false), Column("legacy", "text", 2)],
            [new IndexInfo("users_pkey", ["id"], true, true)]);

        var diff = Assert.Single(SchemaDiffEngine.Compare([SourceUsers], [target]));

        Assert.Equal(SchemaDiffKind.Changed, diff.Kind);
        var alter = Assert.Single(diff.Changes.OfType<AlterColumn>());
        Assert.Equal("character varying(200)", alter.After.DataType);
        Assert.Equal("varchar(100)", alter.Before.DataType);
        Assert.Equal("age", Assert.Single(diff.Changes.OfType<AddColumn>()).Column.Name);
        Assert.Equal("users_email", Assert.Single(diff.Changes.OfType<CreateIndex>()).Index.Name);
        Assert.Empty(diff.Changes.OfType<DropColumn>());
        Assert.Contains(diff.Notes, n => n.Contains("legacy", StringComparison.Ordinal));
    }

    [Fact]
    public void ExtraColumnsDropOnlyWhenAsked()
    {
        var target = SourceUsers with { Table = new ObjectName("prod", "users"), Columns = [.. SourceUsers.Columns, Column("legacy", "text", 3)] };

        var diff = Assert.Single(SchemaDiffEngine.Compare([SourceUsers], [target], SchemaCompareOptions.Default with { DropExtraColumns = true }));

        Assert.Equal("legacy", Assert.Single(diff.Changes.OfType<DropColumn>()).Column);
    }

    [Fact]
    public void ChangedIndexIsRecreated()
    {
        var target = SourceUsers with
        {
            Table = new ObjectName("prod", "users"),
            Indexes = [new IndexInfo("users_pkey", ["id"], true, true), new IndexInfo("users_email", ["email", "age"], IsUnique: false, IsPrimary: false)],
        };

        var diff = Assert.Single(SchemaDiffEngine.Compare([SourceUsers], [target]));

        Assert.IsType<DropIndex>(diff.Changes[0]);
        Assert.IsType<CreateIndex>(diff.Changes[1]);
    }

    [Fact]
    public void PrimaryKeyDifferenceIsANoteNotAnEdit()
    {
        // Built anew rather than with `with`, which would copy the primary key TableStructure computed from the old columns.
        var target = Table("prod", "users",
            [Column("id", "integer", 0, nullable: false), Column("email", "varchar(200)", 1, nullable: false, pk: true), Column("age", "int", 2)],
            [.. SourceUsers.Indexes]);

        var diff = Assert.Single(SchemaDiffEngine.Compare([SourceUsers], [target]));

        Assert.Contains(diff.Notes, n => n.StartsWith("Primary key differs", StringComparison.Ordinal));
    }

    [Fact]
    public void MigrationCreatesTablesBeforeAddingTheirForeignKeys()
    {
        var target = Table("prod", "legacy", [Column("id", "int", 0, pk: true)]);
        var diffs = SchemaDiffEngine.Compare([SourceUsers, SourceOrders], [target]);
        var ddl = new RecordingDdl();

        var script = SchemaMigrationBuilder.Build(diffs, ddl, "prod");

        Assert.Equal(
            ["CreateTable prod.orders", "CreateTable prod.users", "CreateIndex prod.users", "AddForeignKey prod.orders"],
            script.Statements.Select(s => s.Sql));
        var foreignKey = Assert.IsType<AddForeignKey>(ddl.Changes[^1]);
        Assert.Equal(new ObjectName("prod", "users"), foreignKey.ForeignKey.ReferencedTable);
        Assert.Empty(script.Unsupported);
    }

    [Fact]
    public void MigrationDropsExtraTablesChildrenFirstOnlyWhenAsked()
    {
        var parent = Table("prod", "parent", [Column("id", "int", 0, pk: true)]);
        var child = Table("prod", "child", [Column("id", "int", 0, pk: true), Column("parent_id", "int", 1)],
            keys: [new ForeignKeyInfo("child_parent", ["parent_id"], new ObjectName("prod", "parent"), ["id"])]);
        var diffs = SchemaDiffEngine.Compare([], [parent, child]);

        Assert.Empty(SchemaMigrationBuilder.Build(diffs, new RecordingDdl(), "prod").Statements);

        var options = SchemaCompareOptions.Default with { DropExtraTables = true };
        var script = SchemaMigrationBuilder.Build(diffs, new RecordingDdl(), "prod", options);

        Assert.Equal(["DropObject prod.child", "DropObject prod.parent"], script.Statements.Select(s => s.Sql));
        Assert.All(script.Statements, s => Assert.True(s.IsDestructive));
    }

    [Fact]
    public void MigrationOrdersEditsInsideATable()
    {
        var target = SourceUsers with
        {
            Table = new ObjectName("prod", "users"),
            Columns = [Column("id", "integer", 0, nullable: false, pk: true), Column("email", "text", 1, nullable: false), Column("gone", "int", 2)],
            Indexes = [new IndexInfo("users_pkey", ["id"], true, true), new IndexInfo("old_index", ["gone"], false, false)],
            ForeignKeys = [new ForeignKeyInfo("old_fk", ["gone"], new ObjectName("prod", "x"), ["id"])],
        };
        var options = SchemaCompareOptions.Default with { DropExtraColumns = true };

        var script = SchemaMigrationBuilder.Build(SchemaDiffEngine.Compare([SourceUsers], [target], options), new RecordingDdl(), "prod", options);

        Assert.Equal(
            ["DropForeignKey", "DropIndex", "DropColumn", "AlterColumn", "AddColumn", "CreateIndex"],
            script.Statements.Select(s => s.Sql.Split(' ')[0]));
    }

    [Fact]
    public void EditsTheEngineCannotExpressAreListed()
    {
        var diffs = SchemaDiffEngine.Compare([SourceOrders], []);

        var script = SchemaMigrationBuilder.Build(diffs, new RecordingDdl { Refuse = typeof(AddForeignKey) }, null);

        Assert.Contains(script.Unsupported, u => u.Contains("orders_user", StringComparison.Ordinal));
    }

    private sealed class RecordingDdl : ISchemaDdlProvider
    {
        public List<SchemaChange> Changes { get; } = [];

        public Type? Refuse { get; init; }

        public IReadOnlyList<string> CommonDataTypes => ["int", "text"];

        public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change)
        {
            Changes.Add(change);
            return change.GetType() == Refuse ? [] : [$"{change.GetType().Name} {table}"];
        }
    }
}
