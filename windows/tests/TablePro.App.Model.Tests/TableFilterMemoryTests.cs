using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TableFilterMemoryTests : IDisposable
{
    private static readonly TableFilter ByName = new(
        FilterCombinator.Or,
        [
            new FilterRule("Name", FilterOperator.Contains, new FilterValue.One("AC")),
            new FilterRule("Id", FilterOperator.In, new FilterValue.List(["1", "2"])),
        ],
        "Id > 3");

    private static readonly TableName Artist = new("public", "Artist");

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-filters-").FullName;

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    private string Path => System.IO.Path.Combine(_directory, "table-filters.json");

    [Fact]
    public void AFilterComesBackForItsTableAfterARelaunchAndForNoOtherDatabaseOrConnection()
    {
        var connection = TableFilterMemory.ConnectionKey(Guid.NewGuid(), null);
        new TableFilterMemory(Path).For(connection, "shop").Remember(Artist, ByName);

        var memory = new TableFilterMemory(Path);

        Assert.True(TableFilters.Same(ByName, memory.For(connection, "shop").Recall(Artist)));
        Assert.Null(memory.For(connection, "other").Recall(Artist));
        Assert.Null(memory.For(TableFilterMemory.ConnectionKey(null, "C:\\a.sqlite"), "shop").Recall(Artist));
        Assert.Null(memory.For(connection, "shop").Recall(Artist with { Schema = "sales" }));
    }

    [Fact]
    public void ADotInANameCannotMakeTwoTablesOne()
    {
        var memory = new TableFilterMemory(Path);
        var connection = TableFilterMemory.ConnectionKey(Guid.NewGuid(), null);

        memory.Remember(connection, "a.b", new TableName("c", "d"), ByName);

        Assert.Null(memory.Recall(connection, "a", new TableName("b.c", "d")));
    }

    [Fact]
    public void ADroppedTableSchemaOrDatabaseTakesItsFiltersWithIt()
    {
        var memory = new TableFilterMemory(Path);
        var connection = TableFilterMemory.ConnectionKey(Guid.NewGuid(), null);
        var sales = new TableName("sales", "Orders");
        memory.Remember(connection, "shop", Artist, ByName);
        memory.Remember(connection, "shop", sales, ByName);
        memory.Remember(connection, "crm", Artist, ByName);

        memory.ForgetTable(connection, "shop", Artist);
        Assert.Null(memory.Recall(connection, "shop", Artist));

        memory.ForgetSchema(connection, "shop", "sales");
        Assert.Null(memory.Recall(connection, "shop", sales));

        memory.ForgetDatabase(connection, "crm");
        Assert.Null(new TableFilterMemory(Path).Recall(connection, "crm", Artist));
    }
}
