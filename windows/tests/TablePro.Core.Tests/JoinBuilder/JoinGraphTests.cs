using TablePro.Core.JoinBuilder;
using TablePro.Core.Schema;

namespace TablePro.Core.Tests.JoinBuilder;

public sealed class JoinGraphTests
{
    internal static TableStructure Table(string name, string[] columns, params ForeignKeyInfo[] keys) =>
        Table(name, columns.Select(c => (c, c.EndsWith("id", StringComparison.Ordinal) ? "integer" : "text")).ToArray(), keys);

    internal static TableStructure Table(string name, (string Name, string Type)[] columns, params ForeignKeyInfo[] keys) =>
        new(
            new ObjectName(null, name),
            [.. columns.Select((c, i) => new ColumnInfo(c.Name, c.Type, true, null, false, false, i))],
            [],
            keys,
            []);

    internal static ForeignKeyInfo Key(string name, string column, string parent, string parentColumn, string? schema = null) =>
        new(name, [column], new ObjectName(schema, parent), [parentColumn]);

    internal static readonly TableStructure[] Shop =
    [
        Table("customers", ["id", "name"]),
        Table("orders", [("id", "integer"), ("customer_id", "integer"), ("status", "varchar(20)")], Key("orders_customer_fk", "customer_id", "customers", "id")),
        Table("products", ["id", "title"]),
        Table(
            "order_items",
            ["order_id", "product_id", "quantity"],
            Key("items_order_fk", "order_id", "orders", "id"),
            Key("items_product_fk", "product_id", "products", "id")),
        Table("notes", ["id", "body"]),
    ];

    internal static JoinGraph Graph(IEnumerable<TableStructure>? tables = null, string? schema = null) => JoinGraph.FromStructures(tables ?? Shop, schema);

    [Fact]
    public void FindsADirectKeyFromEitherSide()
    {
        var graph = Graph();

        var fromOrders = graph.PathTo("customers", ["orders"]);
        var fromCustomers = graph.PathTo("orders", ["customers"]);

        Assert.NotNull(fromOrders);
        Assert.NotNull(fromCustomers);
        Assert.Equal(["customers"], fromOrders.Select(s => s.Table));
        Assert.Equal("orders", fromOrders[0].Relationship.ChildTable);
        Assert.Equal([new JoinColumnPair("customer_id", "id")], fromOrders[0].Relationship.ColumnPairs);
        Assert.Equal(["orders"], fromCustomers.Select(s => s.Table));
        Assert.Equal(fromOrders[0].Relationship, fromCustomers[0].Relationship);
    }

    [Fact]
    public void LinksAManyToManyPairThroughItsJunctionTable()
    {
        var steps = Graph().PathTo("products", ["orders"]);

        Assert.NotNull(steps);
        Assert.Equal(["order_items", "products"], steps.Select(s => s.Table));
        Assert.Equal(["items_order_fk", "items_product_fk"], steps.Select(s => s.Relationship.Name));
    }

    [Fact]
    public void PrefersAJunctionOverAParentTheTwoTablesOnlyShare()
    {
        TableStructure[] tables =
        [
            Table("orders", ["id", "created_by"], Key("orders_user_fk", "created_by", "users", "id")),
            Table("products", ["id", "created_by"], Key("products_user_fk", "created_by", "users", "id")),
            Table("users", ["id"]),
            Table("zz_lines", ["order_id", "product_id"], Key("lines_order_fk", "order_id", "orders", "id"), Key("lines_product_fk", "product_id", "products", "id")),
        ];

        var steps = Graph(tables).PathTo("products", ["orders"]);

        Assert.NotNull(steps);
        Assert.Equal(["zz_lines", "products"], steps.Select(s => s.Table));
    }

    [Fact]
    public void ASharedParentStillLinksWhenNothingElseDoes()
    {
        TableStructure[] tables =
        [
            Table("orders", ["id", "created_by"], Key("orders_user_fk", "created_by", "users", "id")),
            Table("products", ["id", "created_by"], Key("products_user_fk", "created_by", "users", "id")),
            Table("users", ["id"]),
        ];

        var steps = Graph(tables).PathTo("products", ["orders"]);

        Assert.NotNull(steps);
        Assert.Equal(["users", "products"], steps.Select(s => s.Table));
    }

    [Fact]
    public void ReachesAGrandparentThroughAChain()
    {
        TableStructure[] tables =
        [
            Table("track", ["id", "album_id"], Key("track_album_fk", "album_id", "album", "id")),
            Table("album", ["id", "artist_id"], Key("album_artist_fk", "artist_id", "artist", "id")),
            Table("artist", ["id"]),
        ];

        var steps = Graph(tables).PathTo("artist", ["track"]);

        Assert.NotNull(steps);
        Assert.Equal(["album", "artist"], steps.Select(s => s.Table));
    }

    [Fact]
    public void TheShortestChainFromAnyPickedTableWins()
    {
        var steps = Graph().PathTo("products", ["customers", "order_items"]);

        Assert.NotNull(steps);
        Assert.Equal(["products"], steps.Select(s => s.Table));
    }

    [Fact]
    public void AnUnreachableTableHasNoPathAndAPickedOneAnEmptyPath()
    {
        var graph = Graph();

        Assert.Null(graph.PathTo("notes", ["orders"]));
        Assert.Empty(graph.PathTo("orders", ["orders"])!);
        Assert.Null(graph.PathTo("missing", ["orders"]));
    }

    [Fact]
    public void ACompositeKeyIsOneRelationshipWithEveryPairInOrder()
    {
        TableStructure[] tables =
        [
            Table("shipments", ["order_id", "line", "id"], new ForeignKeyInfo("ship_line_fk", ["order_id", "line"], new ObjectName(null, "lines"), ["order_id", "line"])),
            Table("lines", ["order_id", "line"]),
        ];

        var graph = Graph(tables);

        var relationship = Assert.Single(graph.Relationships);
        Assert.Equal([new JoinColumnPair("order_id", "order_id"), new JoinColumnPair("line", "line")], relationship.ColumnPairs);
    }

    [Fact]
    public void TwoKeysToOneTableStayTwoRelationships()
    {
        TableStructure[] tables =
        [
            Table("orders", ["billing_id", "shipping_id"], Key("billing_fk", "billing_id", "addresses", "id"), Key("shipping_fk", "shipping_id", "addresses", "id")),
            Table("addresses", ["id"]),
        ];

        Assert.Equal(["billing_fk", "shipping_fk"], Graph(tables).RelationshipsBetween("orders", "addresses").Select(r => r.Name));
    }

    [Fact]
    public void AKeyIntoAnotherSchemaNeverJoinsASameNamedTableOfThisOne()
    {
        TableStructure[] tables =
        [
            Table("customers", ["id"]),
            Table("orders", ["id", "customer_id"], Key("orders_customer_fk", "customer_id", "customers", "id", schema: "billing")),
        ];

        var graph = Graph(tables, schema: "public");

        Assert.Empty(graph.Relationships);
        Assert.Null(graph.PathTo("customers", ["orders"]));
    }

    [Fact]
    public void AKeySpelledInAnotherCaseFollowsTheCatalog()
    {
        TableStructure[] tables =
        [
            Table("Parent", ["ID", "name"]),
            Table("child", ["id", "Parent_Id"], Key("fk_child_0", "parent_id", "parent", "id")),
        ];

        var relationship = Assert.Single(Graph(tables).Relationships);

        Assert.Equal("Parent", relationship.ParentTable);
        Assert.Equal([new JoinColumnPair("Parent_Id", "ID")], relationship.ColumnPairs);
    }

    [Fact]
    public void AnExactSpellingWinsOverATableThatDiffersOnlyInCase()
    {
        TableStructure[] tables =
        [
            Table("Parent", ["id"]),
            Table("parent", ["id"]),
            Table("child", ["parent_id"], Key("fk", "parent_id", "parent", "id")),
        ];

        Assert.Equal("parent", Assert.Single(Graph(tables).Relationships).ParentTable);
    }

    [Fact]
    public void ASelfReferenceIsNeverAJoinBetweenTwoTables()
    {
        TableStructure[] tables =
        [
            Table("employees", ["id", "manager_id"], Key("manager_fk", "manager_id", "employees", "id")),
            Table("teams", ["id"]),
        ];

        var graph = Graph(tables);

        Assert.Empty(graph.RelationshipsBetween("employees", "employees"));
        Assert.Null(graph.PathTo("teams", ["employees"]));
    }

    [Fact]
    public void KeepsColumnTypesForFilters()
    {
        var graph = Graph();

        Assert.Equal("varchar(20)", graph.TypeOf("orders", "status"));
        Assert.Null(graph.TypeOf("orders", "missing"));
        Assert.Equal(["customers", "notes", "order_items", "orders", "products"], graph.TableNames);
    }
}
