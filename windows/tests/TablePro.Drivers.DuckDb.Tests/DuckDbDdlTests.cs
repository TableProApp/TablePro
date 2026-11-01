using TablePro.Core.Browse;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.DuckDb.Tests;

public sealed class DuckDbDdlTests
{
    private static readonly ObjectName Notes = new("main", "notes");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task AddsRenamesAltersAndDropsAColumn()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);

        await ApplyAsync(db, Notes, new AddColumn(new ColumnDefinition("rank", "INTEGER", DefaultExpression: "0", Comment: "Sort order")));
        await ApplyAsync(db, Notes, new RenameColumn("rank", "position"));
        await ApplyAsync(db, Notes, new AlterColumn(
            new ColumnDefinition("position", "INTEGER", DefaultExpression: "0", Comment: "Sort order"),
            new ColumnDefinition("position", "BIGINT", IsNullable: false, DefaultExpression: "1")));

        var altered = Assert.Single((await db.Session.GetStructureAsync(Notes, Ct)).Columns, c => c.Name == "position");
        Assert.Equal("BIGINT", altered.DataType);
        Assert.False(altered.IsNullable);
        Assert.Equal("1", altered.DefaultValue);
        Assert.Null(altered.Comment);

        await ApplyAsync(db, Notes, new DropColumn("position"));
        Assert.DoesNotContain((await db.Session.GetStructureAsync(Notes, Ct)).Columns, c => c.Name == "position");
        Assert.Equal(2, await db.Session.CountAsync(Notes, BrowseFilter.None, Ct));
    }

    [Fact]
    public async Task CreatesAndDropsAnIndex()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);

        await ApplyAsync(db, Notes, new CreateIndex(new IndexDefinition("ux_notes_id", ["id"], IsUnique: true)));
        Assert.Contains((await db.Session.GetStructureAsync(Notes, Ct)).Indexes, i => i.Name == "ux_notes_id" && i.IsUnique && i.Columns.SequenceEqual(["id"]));

        await ApplyAsync(db, Notes, new DropIndex("ux_notes_id"));
        Assert.DoesNotContain((await db.Session.GetStructureAsync(Notes, Ct)).Indexes, i => i.Name == "ux_notes_id");
    }

    [Fact]
    public async Task CreatesATableWithAnIdentityColumnThenRenamesTruncatesAndDropsIt()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);
        var table = new ObjectName("main", "tags");
        await ApplyAsync(db, table, new CreateTable(table, [
            new ColumnDefinition("id", "INTEGER", IsNullable: false, IsPrimaryKey: true, IsIdentity: true),
            new ColumnDefinition("label", "VARCHAR", IsNullable: false, DefaultExpression: "'x'", Comment: "Shown name"),
        ]));
        await db.RunAsync(["INSERT INTO tags DEFAULT VALUES", "INSERT INTO tags DEFAULT VALUES"], Ct);
        var created = await db.Session.GetStructureAsync(table, Ct);
        Assert.True(created.Columns[0].IsIdentity);
        Assert.Equal("Shown name", created.Columns[1].Comment);

        await ApplyAsync(db, table, new RenameTable("labels"));
        var renamed = new ObjectName("main", "labels");
        Assert.Equal(2, await db.Session.CountAsync(renamed, BrowseFilter.None, Ct));

        await ApplyAsync(db, renamed, new TruncateTable());
        Assert.Equal(0, await db.Session.CountAsync(renamed, BrowseFilter.None, Ct));

        await ApplyAsync(db, renamed, new DropObject(new DatabaseObject(renamed, ObjectKind.Table)));
        Assert.DoesNotContain(await db.Session.GetObjectsAsync("main", Ct), o => o.Name == renamed);
    }

    [Fact]
    public void ForeignKeyEditsAreNotOffered()
    {
        var key = new ForeignKeyDefinition("fk", ["a"], new ObjectName("main", "p"), ["id"]);
        var session = new DuckDbSession(ConnectionRequest.Direct(new Core.Connections.ConnectionProfile { Name = "x", Engine = Core.Connections.DatabaseEngine.DuckDb }, null));

        Assert.Empty(session.BuildDdl(Notes, new AddForeignKey(key)));
        Assert.Empty(session.BuildDdl(Notes, new DropForeignKey("fk")));
    }

    [Fact]
    public void ReadsIndexKeysFromStoredStatements()
    {
        Assert.Equal(["title", "price"], DuckDbDdl.IndexColumns("CREATE INDEX ix ON books(title, price);"));
        Assert.Equal(["a b", "lower(c)"], DuckDbDdl.IndexColumns("CREATE UNIQUE INDEX \"ix\" ON main.t (\"a b\", lower(c))"));
    }

    private static async Task ApplyAsync(DuckDbDatabase db, ObjectName table, SchemaChange change)
    {
        var ddl = Assert.IsAssignableFrom<ISchemaDdlProvider>(db.Session).BuildDdl(table, change);
        Assert.NotEmpty(ddl);
        var results = await db.RunAsync(ddl, Ct);
        foreach (var result in results)
        {
            Assert.True(result.Succeeded, $"{result.Sql}: {result.Error}");
        }

        Assert.Equal(ddl.Count, results.Count);
    }
}
