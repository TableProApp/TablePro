using TablePro.Core.Browse;
using TablePro.Core.JoinBuilder;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.JoinBuilder;

public sealed class JoinQuerySqlWriterTests
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

    private string? Write(JoinQueryDraft draft, SqlDialect? dialect = null, string? schema = null) =>
        new JoinQuerySqlWriter(dialect ?? PostgreSqlDialect.Instance, schema).Write(draft, _graph);

    [Fact]
    public void WritesTheJoinOnTheOrdersKey() =>
        Assert.Equal(
            "SELECT *\nFROM \"orders\"\nJOIN \"customers\" ON \"orders\".\"customer_id\" = \"customers\".\"id\"",
            Write(Draft("orders", "customers")));

    [Fact]
    public void QuotesIdentifiersForTheEngine()
    {
        Assert.Contains("JOIN `customers` ON `orders`.`customer_id` = `customers`.`id`", Write(Draft("orders", "customers"), MySqlDialect.Instance), StringComparison.Ordinal);
        Assert.Contains("JOIN [customers] ON [orders].[customer_id] = [customers].[id]", Write(Draft("orders", "customers"), SqlServerDialect.Instance), StringComparison.Ordinal);
    }

    [Fact]
    public void AJunctionPairWritesTwoJoinsAndOuterJoinsSaySo()
    {
        var draft = Draft("orders", "products");
        draft.SetKind(2, JoinKind.Left);

        Assert.Equal(
            "SELECT *\nFROM \"orders\"\nJOIN \"order_items\" ON \"order_items\".\"order_id\" = \"orders\".\"id\"\nLEFT JOIN \"products\" ON \"order_items\".\"product_id\" = \"products\".\"id\"",
            Write(draft));

        draft.SetKind(1, JoinKind.Full);
        draft.SetKind(2, JoinKind.Right);
        var sql = Write(draft);
        Assert.Contains("\nFULL JOIN \"order_items\"", sql, StringComparison.Ordinal);
        Assert.Contains("\nRIGHT JOIN \"products\"", sql, StringComparison.Ordinal);
    }

    [Fact]
    public void AnUnlinkedTableIsCrossJoinedWhateverItsKind()
    {
        var draft = Draft("orders", "notes");
        draft.SetKind(1, JoinKind.Left);

        Assert.EndsWith("\nCROSS JOIN \"notes\"", Write(draft), StringComparison.Ordinal);
    }

    [Fact]
    public void ChosenColumnsReplaceTheStarEachNamedWithItsTable()
    {
        var draft = Draft("orders", "customers");
        draft.SetSelected(new JoinColumnRef("customers", "name"), true, _graph);
        draft.SetSelected(new JoinColumnRef("orders", "id"), true, _graph);

        Assert.StartsWith("SELECT \"orders\".\"id\", \"customers\".\"name\"\nFROM", Write(draft), StringComparison.Ordinal);
    }

    [Fact]
    public void FiltersAreTypedEscapedAndJoinedWithAnd()
    {
        var draft = Draft("orders", "customers");
        draft.Filters.Add(new JoinFilter(new JoinColumnRef("customers", "name"), value: "O'Hara"));
        draft.Filters.Add(new JoinFilter(new JoinColumnRef("orders", "id"), FilterOperator.GreaterThan, "10"));
        draft.Filters.Add(new JoinFilter(new JoinColumnRef("orders", "status"), value: ""));

        Assert.EndsWith("\nWHERE \"customers\".\"name\" = 'O''Hara' AND \"orders\".\"id\" > 10", Write(draft), StringComparison.Ordinal);
    }

    [Fact]
    public void ANumericColumnNeverTakesTextThatOnlyLooksLikeANumber()
    {
        var draft = Draft("orders");
        draft.Filters.Add(new JoinFilter(new JoinColumnRef("orders", "id"), value: "1; DROP TABLE orders"));
        draft.Filters.Add(new JoinFilter(new JoinColumnRef("orders", "customer_id"), FilterOperator.In, "1, 2,x"));

        var sql = Write(draft);

        Assert.Contains("\"orders\".\"id\" = '1; DROP TABLE orders'", sql, StringComparison.Ordinal);
        Assert.Contains("\"orders\".\"customer_id\" IN (1, 2, 'x')", sql, StringComparison.Ordinal);
    }

    [Fact]
    public void PatternFiltersEscapeWildcardsAndCastToText()
    {
        var draft = Draft("orders");
        draft.Filters.Add(new JoinFilter(new JoinColumnRef("orders", "status"), FilterOperator.Contains, "50%"));
        draft.Filters.Add(new JoinFilter(new JoinColumnRef("orders", "status"), FilterOperator.IsNull));
        draft.Filters.Add(new JoinFilter(new JoinColumnRef("orders", "id"), FilterOperator.Between, "1", "9"));

        var sql = Write(draft);

        Assert.Contains("ILIKE '%50!%%' ESCAPE '!'", sql, StringComparison.Ordinal);
        Assert.Contains("\"orders\".\"status\" IS NULL", sql, StringComparison.Ordinal);
        Assert.Contains("\"orders\".\"id\" BETWEEN 1 AND 9", sql, StringComparison.Ordinal);
    }

    [Fact]
    public void SortsFollowTheirOrderAndDirection()
    {
        var draft = Draft("orders", "customers");
        draft.Sorts.Add(new JoinSort(new JoinColumnRef("customers", "name")));
        draft.Sorts.Add(new JoinSort(new JoinColumnRef("orders", "id"), descending: true));

        Assert.EndsWith("\nORDER BY \"customers\".\"name\" ASC, \"orders\".\"id\" DESC", Write(draft), StringComparison.Ordinal);
    }

    [Fact]
    public void TablesAreQualifiedWithTheSchemaWhenGiven() =>
        Assert.Equal(
            "SELECT *\nFROM \"sales\".\"orders\"\nJOIN \"sales\".\"customers\" ON \"orders\".\"customer_id\" = \"customers\".\"id\"",
            Write(Draft("orders", "customers"), schema: "sales"));

    [Fact]
    public void NothingPickedWritesNothing() => Assert.Null(Write(new JoinQueryDraft()));

    [Theory]
    [InlineData("integer", true)]
    [InlineData("NUMERIC(10,2)", true)]
    [InlineData("int(11) unsigned", true)]
    [InlineData("double precision", true)]
    [InlineData("interval", false)]
    [InlineData("varchar(20)", false)]
    [InlineData(null, false)]
    public void RecognisesNumericTypes(string? type, bool numeric) => Assert.Equal(numeric, JoinQuerySqlWriter.IsNumericType(type));
}
