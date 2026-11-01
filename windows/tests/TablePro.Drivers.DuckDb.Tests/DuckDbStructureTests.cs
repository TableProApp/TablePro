using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.DuckDb.Tests;

public sealed class DuckDbStructureTests
{
    private static readonly ObjectName Items = new("main", "items");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public void WritesTheTableComment()
    {
        Assert.Equal(["COMMENT ON TABLE \"main\".\"items\" IS 'Stock'"], DuckDbDdl.SetOptions(Items, [new(TableOptionNames.Comment, null, "Stock")]));
        Assert.Equal(["COMMENT ON TABLE \"main\".\"items\" IS NULL"], DuckDbDdl.SetOptions(Items, [new(TableOptionNames.Comment, "Stock", " ")]));
    }

    [Fact]
    public async Task OffersTheCommentButNotCheckEdits()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);
        var ddl = Assert.IsAssignableFrom<ISchemaDdlProvider>(db.Session);

        Assert.Equal(StructureEdits.TableOptions, ddl.SupportedEdits);
        Assert.Equal([TableOptionNames.Comment], ddl.EditableTableOptions.Select(o => o.Name));
        Assert.Empty(ddl.BuildDdl(Items, new AddCheckConstraint(new("ck", "qty > 0"))));
    }

    [Fact]
    public async Task ReadsChecksAndTheCommentAndAppliesANewComment()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);
        var setup = await db.RunAsync(
        [
            "CREATE TABLE items (id INTEGER, qty INTEGER CHECK (qty >= 0), price DECIMAL(10,2), CHECK (price > 0 AND qty < 1000))",
            "COMMENT ON TABLE items IS 'Stock'",
        ], Ct);
        Assert.All(setup, r => Assert.True(r.Succeeded, r.Error));
        var details = Assert.IsAssignableFrom<ITableDetailsProvider>(db.Session);

        var read = await details.GetTableDetailsAsync(Items, Ct);

        Assert.Equal(2, read.CheckConstraints.Count);
        Assert.Contains(read.CheckConstraints, c => c.Expression.Contains("qty >= 0", StringComparison.Ordinal));
        Assert.Null(read.Partitioning);
        Assert.Equal("Stock", Assert.Single(read.Options).Value);

        var ddl = (ISchemaDdlProvider)db.Session;
        var results = await db.RunAsync(ddl.BuildDdl(Items, new SetTableOptions([new(TableOptionNames.Comment, "Stock", "Warehouse stock")])), Ct);
        Assert.All(results, r => Assert.True(r.Succeeded, r.Error));
        Assert.Equal("Warehouse stock", (await details.GetTableDetailsAsync(Items, Ct)).Options[0].Value);
    }
}
