using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

public sealed class ReferencedTablesTests
{
    [Fact]
    public void ListsTheTablesEveryStatementNamesWithoutTheirAliases()
    {
        const string text = "SELECT o.id FROM orders o\nJOIN order_items i ON i.order_id = o.id\nWHERE o.;\nUPDATE main.products SET stock = 0;";

        var tables = SqlCompletion.ReferencedTables(text, SqliteDialect.Instance);

        Assert.Equal(["order_items", "orders", "products"], tables.Order(StringComparer.Ordinal));
    }

    [Fact]
    public void OnceTheReferencedTablesAreLoadedAnAliasOffersItsColumns()
    {
        // The workspace loads the columns of ReferencedTables while the user types; this is the catalog it ends with.
        const string text = "SELECT * FROM orders o WHERE o.";
        var tables = SqlCompletion.ReferencedTables(text, SqliteDialect.Instance);
        var columns = tables.ToDictionary(
            t => t,
            t => (IReadOnlyList<(string Name, string Type)>)[("id", "INTEGER"), ("status", "VARCHAR(20)")],
            StringComparer.OrdinalIgnoreCase);
        var catalog = new CompletionCatalog([], [("orders", false)], columns);

        var (_, items) = SqlCompletion.Suggest(text, text.Length, SqliteDialect.Instance, catalog);

        Assert.Contains(items, i => i.Label == "status" && i.Kind == CompletionKind.Column);
    }

    [Fact]
    public void TextWithoutTablesNamesNone() =>
        Assert.Empty(SqlCompletion.ReferencedTables("SELECT 1;", SqliteDialect.Instance));
}
