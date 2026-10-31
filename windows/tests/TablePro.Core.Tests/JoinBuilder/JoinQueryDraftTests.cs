using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.JoinBuilder;

namespace TablePro.Core.Tests.JoinBuilder;

public sealed class JoinQueryDraftTests
{
    private readonly JoinGraph _graph = JoinGraphTests.Graph();

    private JoinQueryDraft Draft(params string[] tables)
    {
        var draft = new JoinQueryDraft();
        foreach (var table in tables)
        {
            draft.Add(table, _graph);
        }

        return draft;
    }

    [Fact]
    public void TheSecondTableJoinsOnTheFirstTablesKey()
    {
        var draft = Draft("orders", "customers");

        Assert.Equal(["orders", "customers"], draft.Tables.Select(t => t.Name));
        Assert.Null(draft.Tables[0].Condition);
        Assert.Equal("orders_customer_fk", draft.Tables[1].Condition?.Name);
        Assert.Equal(JoinKind.Inner, draft.Tables[1].Kind);
    }

    [Fact]
    public void AManyToManyPairBringsInItsJunction()
    {
        var draft = Draft("orders", "products");

        Assert.Equal(["orders", "order_items", "products"], draft.Tables.Select(t => t.Name));
        Assert.Equal("items_order_fk", draft.Tables[1].Condition?.Name);
        Assert.Equal("items_product_fk", draft.Tables[2].Condition?.Name);
    }

    [Fact]
    public void ATableNoKeyReachesIsCrossJoined()
    {
        var draft = Draft("orders", "notes");

        Assert.Equal(["orders", "notes"], draft.Tables.Select(t => t.Name));
        Assert.Null(draft.Tables[1].Condition);
        Assert.Equal(["notes"], draft.CrossJoinedTables);
    }

    [Fact]
    public void RemovingTheTableALaterOneJoinedOnRelinksOrCrossJoinsIt()
    {
        var linked = Draft("customers", "orders", "order_items");
        linked.Remove("orders", _graph);
        Assert.Equal(["customers", "order_items"], linked.Tables.Select(t => t.Name));
        Assert.Null(linked.Tables[1].Condition);

        var restarted = Draft("orders", "customers");
        restarted.Remove("orders", _graph);
        Assert.Equal(["customers"], restarted.Tables.Select(t => t.Name));
        Assert.Null(restarted.Tables[0].Condition);

        var relinked = Draft("orders", "order_items", "products");
        relinked.Add("customers", _graph);
        relinked.Remove("order_items", _graph);
        Assert.Equal(["orders", "products", "customers"], relinked.Tables.Select(t => t.Name));
        Assert.Null(relinked.Tables[1].Condition);
        Assert.Equal("orders_customer_fk", relinked.Tables[2].Condition?.Name);
    }

    [Fact]
    public void ACrossJoinTheUserChoseSurvivesRemovingAnUnrelatedTable()
    {
        var draft = Draft("orders", "customers");
        draft.SetCondition(1, null, _graph);
        draft.Add("notes", _graph);

        draft.Remove("notes", _graph);

        Assert.Equal(["orders", "customers"], draft.Tables.Select(t => t.Name));
        Assert.Null(draft.Tables[1].Condition);
    }

    [Fact]
    public void RemovingATableDropsItsFiltersAndSorts()
    {
        var draft = Draft("orders", "customers");
        draft.Filters.Add(new JoinFilter(new JoinColumnRef("customers", "name"), value: "Ada"));
        draft.Filters.Add(new JoinFilter(new JoinColumnRef("orders", "status"), value: "paid"));
        draft.Sorts.Add(new JoinSort(new JoinColumnRef("customers", "name")));

        draft.Remove("customers", _graph);

        Assert.Equal(["orders"], draft.Filters.Select(f => f.Column.Table));
        Assert.Empty(draft.Sorts);
    }

    [Fact]
    public void OnlyAKeyToAnEarlierTableCanBeACondition()
    {
        var draft = Draft("orders", "customers", "notes");
        var key = _graph.RelationshipsBetween("orders", "customers")[0];

        draft.SetCondition(2, key, _graph);
        Assert.Null(draft.Tables[2].Condition);

        draft.SetCondition(1, null, _graph);
        Assert.Null(draft.Tables[1].Condition);
        draft.SetCondition(1, key, _graph);
        Assert.Equal(key, draft.Tables[1].Condition);
        Assert.Equal([key], draft.Candidates(1, _graph));
    }

    [Fact]
    public void SelectedColumnsKeepTheTablesOrder()
    {
        var draft = Draft("orders");

        draft.SetSelected(new JoinColumnRef("orders", "status"), true, _graph);
        draft.SetSelected(new JoinColumnRef("orders", "id"), true, _graph);
        Assert.Equal(["id", "status"], draft.Tables[0].SelectedColumns);

        draft.SetSelected(new JoinColumnRef("orders", "id"), false, _graph);
        Assert.Equal(["status"], draft.Tables[0].SelectedColumns);
        Assert.True(draft.IsSelected(new JoinColumnRef("orders", "status")));
    }

    [Fact]
    public void OffersEveryPickedColumnInFromOrder()
    {
        var draft = Draft("customers", "orders");

        Assert.Equal(
            ["customers.id", "customers.name", "orders.id", "orders.customer_id", "orders.status"],
            draft.AvailableColumns(_graph).Select(c => c.ToString()));
    }

    [Fact]
    public void MySqlOffersNoFullJoin()
    {
        Assert.DoesNotContain(JoinKind.Full, JoinKinds.SupportedBy(DatabaseEngine.MySql));
        Assert.Contains(JoinKind.Full, JoinKinds.SupportedBy(DatabaseEngine.PostgreSql));
        Assert.Equal(FilterOperator.Equals, new JoinFilter(new JoinColumnRef("a", "b")).Operator);
    }
}
