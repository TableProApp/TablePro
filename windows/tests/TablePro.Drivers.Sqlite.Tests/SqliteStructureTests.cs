using TablePro.Core.Browse;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Sqlite.Tests;

public sealed class SqliteStructureTests
{
    private static readonly ObjectName Books = new(null, "books");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public void ListsOnlyTableLevelChecksAndNamesTheUnnamedOnes()
    {
        var create = SqliteTableDdl.Parse("""
            CREATE TABLE t (
              a INTEGER CHECK (a > 0),
              b TEXT,
              CONSTRAINT "ck_b" CHECK (length(b) < 10),
              CHECK (a < 100),
              UNIQUE (b)
            ) STRICT
            """)!;

        var checks = SqliteTableDdl.CheckConstraints(create, "t");

        Assert.Equal(["ck_b", "ck_t_2"], checks.Select(c => c.Name));
        Assert.Equal("length(b) < 10", checks[0].Expression);
        Assert.True(checks[0].IsNamed);
        Assert.False(checks[1].IsNamed);
        Assert.Contains(new TableOption(TableOptionNames.Strict, "YES"), SqliteDdl.ReadOptions(create));
        Assert.Contains(new TableOption(TableOptionNames.WithoutRowid, "NO"), SqliteDdl.ReadOptions(create));
    }

    [Fact]
    public void ReplacesAndRemovesACheckEntryInPlace()
    {
        var create = SqliteTableDdl.Parse("CREATE TABLE t (a INTEGER, CHECK (a < 100), b TEXT)")!;

        var replaced = SqliteDdl.WithCheck(create, "t", "ck_t_1", new CheckConstraintDefinition("ck_a", "a < 50"))!;
        var removed = SqliteDdl.WithCheck(create, "t", "CK_T_1", null)!;

        Assert.Equal(["a INTEGER", "CONSTRAINT \"ck_a\" CHECK (a < 50)", "b TEXT"], replaced.Select(e => e.Text));
        Assert.Equal(["a INTEGER", "b TEXT"], removed.Select(e => e.Text));
        Assert.Null(SqliteDdl.WithCheck(create, "t", "missing", null));
    }

    [Fact]
    public async Task AddsEditsAndDropsAChecksByRebuildingTheTable()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        var ddl = Assert.IsAssignableFrom<ISchemaDdlProvider>(db.Session);
        var details = Assert.IsAssignableFrom<ITableDetailsProvider>(db.Session);
        Assert.Equal(StructureEdits.CheckConstraints, ddl.SupportedEdits);

        // The column-level check on price moves with its column and is not listed.
        Assert.Empty((await details.GetTableDetailsAsync(Books, Ct)).CheckConstraints);

        await RunAsync(db, ddl.BuildDdl(Books, new AddCheckConstraint(new("ck_title", "length(title) > 0"))));
        var added = Assert.Single((await details.GetTableDetailsAsync(Books, Ct)).CheckConstraints);
        Assert.Equal(new CheckConstraintInfo("ck_title", "length(title) > 0"), added);

        await RunAsync(db, ddl.BuildDdl(Books, new AlterCheckConstraint(added.ToDefinition(), new("ck_title_short", "length(title) < 40"))));
        Assert.Equal("ck_title_short", Assert.Single((await details.GetTableDetailsAsync(Books, Ct)).CheckConstraints).Name);

        // The rebuild keeps the rows, the index, the trigger and the foreign key.
        var structure = await db.Session.GetStructureAsync(Books, Ct);
        Assert.Contains(structure.Indexes, i => i.Name == "ix_books_title");
        Assert.Single(structure.ForeignKeys);
        Assert.Single(structure.Triggers);
        Assert.Equal(5L, await db.Session.CountAsync(Books, BrowseFilter.None, Ct));

        await RunAsync(db, ddl.BuildDdl(Books, new DropCheckConstraint("ck_title_short")));
        Assert.Empty((await details.GetTableDetailsAsync(Books, Ct)).CheckConstraints);
    }

    [Fact]
    public async Task ACheckTheRowsFailLeavesTheTableAsItWas()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        var ddl = (ISchemaDdlProvider)db.Session;

        var results = await db.RunAsync(ddl.BuildDdl(Books, new AddCheckConstraint(new("ck_cheap", "price < 10"))), Ct);

        Assert.Contains(results, r => !r.Succeeded);
        Assert.Empty((await ((ITableDetailsProvider)db.Session).GetTableDetailsAsync(Books, Ct)).CheckConstraints);
        Assert.Equal(5L, await db.Session.CountAsync(Books, BrowseFilter.None, Ct));
    }

    [Fact]
    public async Task DropsACheckSqliteStoredWithoutAName()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        await RunAsync(db, ["CREATE TABLE stock (id INTEGER PRIMARY KEY, qty INTEGER, CHECK (qty >= 0))"]);
        var details = (ITableDetailsProvider)db.Session;
        var stock = new ObjectName(null, "stock");

        var check = Assert.Single((await details.GetTableDetailsAsync(stock, Ct)).CheckConstraints);
        Assert.Equal("ck_stock_1", check.Name);

        await RunAsync(db, ((ISchemaDdlProvider)db.Session).BuildDdl(stock, new DropCheckConstraint(check.Name)));
        Assert.Empty((await details.GetTableDetailsAsync(stock, Ct)).CheckConstraints);
    }

    private static async Task RunAsync(SqliteDatabase db, IReadOnlyList<string> statements)
    {
        Assert.NotEmpty(statements);
        var results = await db.RunAsync(statements, Ct);
        Assert.All(results, r => Assert.True(r.Succeeded, r.Error));
    }
}
