using TablePro.Core.Browse;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Sqlite.Tests;

public sealed class SqliteDdlTests
{
    private static readonly ObjectName Books = new(null, "books");
    private static readonly ObjectName Authors = new(null, "authors");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task AddsRenamesAndDropsAColumn()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);

        await ApplyAsync(db, Books, new AddColumn(new ColumnDefinition("isbn", "TEXT", DefaultExpression: "'n/a'")));
        await ApplyAsync(db, Books, new RenameColumn("isbn", "code"));
        var renamed = await db.Session.GetStructureAsync(Books, Ct);
        Assert.Equal("'n/a'", Assert.Single(renamed.Columns, c => c.Name == "code").DefaultValue);

        await ApplyAsync(db, Books, new DropColumn("code"));
        var dropped = await db.Session.GetStructureAsync(Books, Ct);
        Assert.DoesNotContain(dropped.Columns, c => c.Name == "code");
    }

    [Fact]
    public async Task CreatesAndDropsAnIndex()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);

        await ApplyAsync(db, Authors, new CreateIndex(new IndexDefinition("ux_authors_name", ["name"], IsUnique: true)));
        Assert.Contains((await db.Session.GetStructureAsync(Authors, Ct)).Indexes, i => i.Name == "ux_authors_name" && i.IsUnique);

        await ApplyAsync(db, Authors, new DropIndex("ux_authors_name"));
        Assert.DoesNotContain((await db.Session.GetStructureAsync(Authors, Ct)).Indexes, i => i.Name == "ux_authors_name");
    }

    [Fact]
    public async Task DroppingAnIndexedColumnRebuildsTheTableAndKeepsRowsAndOtherObjects()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        var ddl = Ddl(db).BuildDdl(Books, new DropColumn("price"));
        Assert.Contains("PRAGMA foreign_keys = OFF", ddl);

        await RunAllAsync(db, ddl);

        var structure = await db.Session.GetStructureAsync(Books, Ct);
        Assert.Equal(["id", "author_id", "title"], structure.Columns.Select(c => c.Name));
        Assert.DoesNotContain(structure.Indexes, i => i.Name == "ix_books_title");
        Assert.Single(structure.ForeignKeys);
        Assert.Single(structure.Triggers);
        Assert.Equal(5, await db.Session.CountAsync(Books, BrowseFilter.None, Ct));
        var page = await db.Session.BrowseAsync(new BrowseRequest(Books, BrowseFilter.None, [new SortColumn("id", false)], 0, 10), Ct);
        Assert.Equal("Alpha", page[0, page.ColumnIndex("title")]);
    }

    [Fact]
    public async Task AlteringAColumnKeepsItsOtherClauses()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        var before = new ColumnDefinition("title", "TEXT", IsNullable: false);
        var after = new ColumnDefinition("title", "VARCHAR(200)", IsNullable: true, DefaultExpression: "'untitled'");

        await ApplyAsync(db, Books, new AlterColumn(before, after));

        var structure = await db.Session.GetStructureAsync(Books, Ct);
        var title = Assert.Single(structure.Columns, c => c.Name == "title");
        Assert.Equal("VARCHAR(200)", title.DataType);
        Assert.True(title.IsNullable);
        Assert.Equal("'untitled'", title.DefaultValue);
        Assert.Contains(structure.Indexes, i => i.Name == "ix_books_title");
        var definition = await db.Session.GetDefinitionAsync(new DatabaseObject(Books, ObjectKind.Table), Ct);
        Assert.Contains("COLLATE NOCASE", definition, StringComparison.Ordinal);

        // The CHECK on price survives the rebuild, so a negative price is still refused.
        var results = await db.RunAsync(["INSERT INTO books (id, author_id, title, price) VALUES (50, 1, 'x', -1)"], Ct);
        Assert.False(results[0].Succeeded);
    }

    [Fact]
    public async Task AlterColumnKeepsAutoincrementHighWaterMark()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        await db.RunAsync(["DELETE FROM authors WHERE id = 3"], Ct);

        await ApplyAsync(db, Authors, new AlterColumn(new ColumnDefinition("name", "TEXT", false), new ColumnDefinition("name", "VARCHAR(80)", false)));
        var results = await db.RunAsync(["INSERT INTO authors (name) VALUES ('Eve')", "SELECT max(id) FROM authors"], Ct);

        Assert.Equal(4L, results[1].ResultSets[0][0, 0]);
    }

    [Fact]
    public async Task AddsAndDropsAForeignKeyByRebuilding()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        await ApplyAsync(db, Authors, new AddColumn(new ColumnDefinition("mentor_id", "INTEGER")));

        var key = new ForeignKeyDefinition("fk_authors_mentor", ["mentor_id"], Authors, ["id"], OnDelete: "SET NULL");
        await ApplyAsync(db, Authors, new AddForeignKey(key));
        var added = Assert.Single((await db.Session.GetStructureAsync(Authors, Ct)).ForeignKeys);
        Assert.Equal("fk_authors_mentor", added.Name);
        Assert.Equal("SET NULL", added.OnDelete);

        await ApplyAsync(db, Authors, new DropForeignKey("fk_authors_mentor"));
        Assert.Empty((await db.Session.GetStructureAsync(Authors, Ct)).ForeignKeys);
        Assert.Equal(5, await db.Session.CountAsync(Books, BrowseFilter.None, Ct));
    }

    [Fact]
    public async Task CreatesRenamesTruncatesAndDropsATable()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        var table = new ObjectName(null, "tags");
        await ApplyAsync(db, table, new CreateTable(table, [
            new ColumnDefinition("id", "INTEGER", IsNullable: false, IsPrimaryKey: true, IsIdentity: true),
            new ColumnDefinition("label", "TEXT", IsNullable: false, DefaultExpression: "lower('X')"),
        ]));
        await db.RunAsync(["INSERT INTO tags DEFAULT VALUES"], Ct);
        var created = await db.Session.GetStructureAsync(table, Ct);
        Assert.True(created.Columns[0].IsIdentity);

        await ApplyAsync(db, table, new RenameTable("labels"));
        var renamed = new ObjectName(null, "labels");
        Assert.Equal(1, await db.Session.CountAsync(renamed, BrowseFilter.None, Ct));

        await ApplyAsync(db, renamed, new TruncateTable());
        Assert.Equal(0, await db.Session.CountAsync(renamed, BrowseFilter.None, Ct));

        await ApplyAsync(db, renamed, new DropObject(new DatabaseObject(renamed, ObjectKind.Table)));
        Assert.DoesNotContain(await db.Session.GetObjectsAsync(null, Ct), o => o.Name == renamed);
    }

    [Fact]
    public void ParsesColumnClausesAroundForeignKeyActions()
    {
        var parts = SqliteTableDdl.ParseColumn("\"a\" INTEGER NOT NULL CONSTRAINT fk REFERENCES p (id) ON DELETE SET NULL NOT DEFERRABLE DEFAULT 3");

        Assert.NotNull(parts);
        Assert.Equal("a", parts.Name);
        Assert.Equal(["NOT", "REFERENCES", "DEFAULT"], parts.Clauses.Select(c => c.Kind));
        Assert.Equal("fk", parts.Clauses[1].ConstraintName);
    }

    [Fact]
    public void RefusesToParseVirtualTables()
    {
        Assert.Null(SqliteTableDdl.Parse("CREATE VIRTUAL TABLE docs USING fts5(title, body)"));
        Assert.Null(SqliteTableDdl.Parse("CREATE TABLE t AS SELECT 1 AS x"));
    }

    [Fact]
    public void WrapsFunctionDefaultsInParentheses()
    {
        Assert.Equal("(datetime('now'))", SqliteTableDdl.DefaultValue("datetime('now')"));
        Assert.Equal("CURRENT_TIMESTAMP", SqliteTableDdl.DefaultValue("CURRENT_TIMESTAMP"));
        Assert.Equal("-1", SqliteTableDdl.DefaultValue("-1"));
        Assert.Equal("'a, b'", SqliteTableDdl.DefaultValue("'a, b'"));
    }

    private static ISchemaDdlProvider Ddl(SqliteDatabase db) => Assert.IsAssignableFrom<ISchemaDdlProvider>(db.Session);

    private static async Task ApplyAsync(SqliteDatabase db, ObjectName table, SchemaChange change)
    {
        var ddl = Ddl(db).BuildDdl(table, change);
        Assert.NotEmpty(ddl);
        await RunAllAsync(db, ddl);
    }

    private static async Task RunAllAsync(SqliteDatabase db, IReadOnlyList<string> ddl)
    {
        var results = await db.RunAsync(ddl, Ct);
        foreach (var result in results)
        {
            Assert.True(result.Succeeded, $"{result.Sql}: {result.Error}");
        }

        Assert.Equal(ddl.Count, results.Count);
    }
}
