using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ColumnLayoutTests : IDisposable
{
    private static readonly string[] Columns = ["id", "name", "email", "created"];

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-columns-").FullName;

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    [Fact]
    public void TheDefaultShowsEveryColumnInTheTablesOrder()
    {
        var arranged = ColumnLayout.Default.Resolve(Columns);

        Assert.Equal([0, 1, 2, 3], arranged.Order);
        Assert.Equal(0, arranged.Frozen);
        Assert.True(arranged.IsIdentity(Columns.Length));
    }

    [Fact]
    public void AMovedColumnKeepsItsPlaceAndAHiddenOneComesBackWhereItWas()
    {
        var layout = ColumnLayout.Default.Move(Columns, from: 3, to: 0);
        Assert.Equal([3, 0, 1, 2], layout.Resolve(Columns).Order);

        layout = layout.Hide(Columns, 1);
        Assert.Equal([3, 0, 2], layout.Resolve(Columns).Order);
        Assert.True(layout.IsHidden("name"));

        layout = layout.Move(Columns, from: 2, to: 1);
        Assert.Equal([3, 2, 0], layout.Resolve(Columns).Order);

        layout = layout.ShowAll();
        Assert.Equal([3, 2, 0, 1], layout.Resolve(Columns).Order);
    }

    [Fact]
    public void AColumnAddedSinceGoesLastAndADroppedOneIsPassedOver()
    {
        var layout = ColumnLayout.Default.Move(Columns, from: 0, to: 3).Hide(Columns, 2);
        string[] altered = ["created", "name", "id", "status"];

        Assert.Equal([1, 0, 2, 3], layout.Resolve(altered).Order);
    }

    [Fact]
    public void TheLastShownColumnCannotBeHiddenAndFreezingIsClampedToTheShownColumns()
    {
        string[] two = ["id", "name"];
        var layout = ColumnLayout.Default.Hide(two, 0);

        Assert.Same(layout, layout.Hide(two, 1));
        Assert.Equal([1], layout.Resolve(two).Order);
        Assert.Equal(1, layout.Freeze(5).Resolve(two).Frozen);
    }

    [Fact]
    public void HidingAFrozenColumnFreezesOneFewer()
    {
        var layout = ColumnLayout.Default.Freeze(2).Hide(Columns, 0);

        Assert.Equal(1, layout.Resolve(Columns).Frozen);
        Assert.Equal(2, ColumnLayout.Default.Freeze(2).Hide(Columns, 3).Resolve(Columns).Frozen);
    }

    [Fact]
    public void ALayoutIsKeptPerTableAcrossARestartAndTheDefaultForgetsIt()
    {
        var path = Path.Combine(_directory, "table-columns.json");
        var orders = new TableName("public", "orders");
        var layout = ColumnLayout.Default.Move(Columns, 2, 0).Hide(Columns, 3).Freeze(1);
        new ColumnLayoutMemory(path).For("id:a", "shop").Remember(orders, layout);

        var again = new ColumnLayoutMemory(path);
        var kept = again.For("id:a", "shop").Recall(orders);

        Assert.Equal([2, 0, 1], kept.Resolve(Columns).Order);
        Assert.Equal(1, kept.Frozen);
        Assert.True(again.For("id:a", "other").Recall(orders).IsDefault);
        Assert.True(again.For("id:b", "shop").Recall(orders).IsDefault);

        again.For("id:a", "shop").Remember(orders, ColumnLayout.Default);
        Assert.True(new ColumnLayoutMemory(path).For("id:a", "shop").Recall(orders).IsDefault);
    }

    [Fact]
    public void ADroppedSchemaOrDatabaseTakesItsTablesLayoutsWithIt()
    {
        var memory = new ColumnLayoutMemory(Path.Combine(_directory, "table-columns.json"));
        var layout = ColumnLayout.Default.Hide(Columns, 1);
        memory.Remember("id:a", "shop", new TableName("sales", "orders"), layout);
        memory.Remember("id:a", "shop", new TableName("public", "people"), layout);
        memory.Remember("id:a", "crm", new TableName("public", "leads"), layout);

        memory.ForgetSchema("id:a", "shop", "sales");
        memory.ForgetDatabase("id:a", "crm");

        Assert.True(memory.Recall("id:a", "shop", new TableName("sales", "orders")).IsDefault);
        Assert.False(memory.Recall("id:a", "shop", new TableName("public", "people")).IsDefault);
        Assert.True(memory.Recall("id:a", "crm", new TableName("public", "leads")).IsDefault);
    }

    [Fact]
    public void LayoutsOfTablesASchemaNoLongerListsAreForgotten()
    {
        var memory = new ColumnLayoutMemory(Path.Combine(_directory, "table-columns.json"));
        var layout = ColumnLayout.Default.Hide(Columns, 1);
        memory.Remember("id:a", "shop", new TableName("public", "orders"), layout);
        memory.Remember("id:a", "shop", new TableName("public", "orders_2025"), layout);
        memory.Remember("id:a", "shop", new TableName(null, "people"), layout);

        Assert.Equal(["public", null], memory.SchemasWithLayouts("id:a", "shop"));
        memory.ForgetMissing("id:a", "shop", "public", new HashSet<string>(["orders"], StringComparer.Ordinal));

        Assert.False(memory.Recall("id:a", "shop", new TableName("public", "orders")).IsDefault);
        Assert.True(memory.Recall("id:a", "shop", new TableName("public", "orders_2025")).IsDefault);
        Assert.False(memory.Recall("id:a", "shop", new TableName(null, "people")).IsDefault);
    }
}
