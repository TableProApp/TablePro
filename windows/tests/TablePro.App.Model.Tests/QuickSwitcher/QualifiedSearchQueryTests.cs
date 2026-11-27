using TablePro.App.Model.QuickSwitcher;

namespace TablePro.App.Model.Tests.QuickSwitcher;

public sealed class QualifiedSearchQueryTests
{
    [Fact]
    public void NameAndContainerSplitOnDots()
    {
        var query = QualifiedSearchQuery.Parse("shop.orders");
        Assert.NotNull(query);
        Assert.Equal(["shop"], query.Containers);
        Assert.Equal("orders", query.Name);
    }

    [Fact]
    public void TwoContainersStayOutermostFirst()
    {
        var query = QualifiedSearchQuery.Parse("db.shop.orders");
        Assert.NotNull(query);
        Assert.Equal(["db", "shop"], query.Containers);
        Assert.Equal("orders", query.Name);
    }

    [Fact]
    public void ATrailingDotLeavesAnEmptyName()
    {
        var query = QualifiedSearchQuery.Parse("attendance.");
        Assert.NotNull(query);
        Assert.Equal(["attendance"], query.Containers);
        Assert.Equal(string.Empty, query.Name);
    }

    [Theory]
    [InlineData("orders")]
    [InlineData(".orders")]
    [InlineData("a..b")]
    public void TextWithNoFilledContainerIsNotQualified(string text) => Assert.Null(QualifiedSearchQuery.Parse(text));

    [Fact]
    public void SpacesAroundADotAreIgnored()
    {
        var query = QualifiedSearchQuery.Parse("shop . orders");
        Assert.NotNull(query);
        Assert.Equal(["shop"], query.Containers);
        Assert.Equal("orders", query.Name);
    }

    [Fact]
    public void ADotInsideQuotesBelongsToTheName()
    {
        var query = QualifiedSearchQuery.Parse("\"a.b\".orders");
        Assert.NotNull(query);
        Assert.Equal(["a.b"], query.Containers);
        Assert.Equal("orders", query.Name);
    }

    [Fact]
    public void BracketAndBacktickQuotesAreAccepted()
    {
        var brackets = QualifiedSearchQuery.Parse("[a.b].c");
        Assert.Equal(["a.b"], brackets!.Containers);
        var backticks = QualifiedSearchQuery.Parse("`a.b`.c");
        Assert.Equal(["a.b"], backticks!.Containers);
    }

    [Fact]
    public void ADoubledClosingQuoteIsAnEscape()
    {
        var query = QualifiedSearchQuery.Parse("\"a\"\"b\".c");
        Assert.Equal(["a\"b"], query!.Containers);
        Assert.Equal("c", query.Name);
    }

    [Fact]
    public void ContainerPairsLineUpFromTheRight()
    {
        var query = QualifiedSearchQuery.Parse("shop.orders");
        var pairs = query!.ContainerPairs(["db", "shop"]);
        Assert.Equal([("shop", "shop")], pairs);
    }

    [Fact]
    public void ContainerPairsAreNullWhenTheQueryNamesMoreThanTheLocation()
    {
        var query = QualifiedSearchQuery.Parse("a.b.c");
        Assert.Null(query!.ContainerPairs(["only"]));
    }

    [Fact]
    public void LocationDropsEmptyParts()
    {
        Assert.Equal(["db", "schema"], QualifiedSearchQuery.Location("db", "schema"));
        Assert.Equal(["schema"], QualifiedSearchQuery.Location(null, "schema"));
        Assert.Empty(QualifiedSearchQuery.Location(null, null));
    }
}
