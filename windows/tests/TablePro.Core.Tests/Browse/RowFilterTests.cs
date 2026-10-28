using TablePro.Core.Browse;

namespace TablePro.Core.Tests.Browse;

public sealed class RowFilterTests
{
    private static readonly string[] Columns = ["id", "name"];

    [Fact]
    public void TextIgnoresCaseAndNumbersCompareAsNumbers()
    {
        var contains = RowFilter.Compile(new BrowseFilter([new FilterRule("name", FilterOperator.Contains, "ANA")]), Columns, "Test");
        var greater = RowFilter.Compile(new BrowseFilter([new FilterRule("id", FilterOperator.GreaterThan, "9")]), Columns, "Test");

        Assert.True(contains([1, "Ioana"]));
        Assert.False(contains([1, "Bob"]));
        Assert.True(greater([10, "x"]));
        Assert.False(greater([2, "x"]));
    }

    [Fact]
    public void RawWhereIsRefusedNamingTheEngine()
    {
        var error = Assert.Throws<NotSupportedException>(() => RowFilter.Compile(new BrowseFilter([], "id > 3"), Columns, "etcd"));

        Assert.StartsWith("etcd ", error.Message, StringComparison.Ordinal);
    }
}
