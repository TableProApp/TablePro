using TablePro.App.Model.QuickSwitcher;

namespace TablePro.App.Model.Tests.QuickSwitcher;

public sealed class PaletteRankerTests
{
    private static readonly Guid Connection = Guid.NewGuid();
    private static readonly Dictionary<string, double> NoFrecency = new(StringComparer.Ordinal);

    private static PaletteItem Item(
        string name,
        PaletteItemKind kind,
        string? key = null,
        string? schema = null,
        string? database = null) => new()
    {
        FrecencyKey = key ?? name,
        Name = name,
        Kind = kind,
        SchemaName = schema,
        DatabaseName = database,
    };

    private static IReadOnlyList<PaletteGroup> Filtered(
        IReadOnlyList<PaletteItem> items,
        string query,
        IReadOnlyDictionary<string, double>? scores = null) =>
        PaletteRanker.FilteredGroups(items, query, scores ?? NoFrecency, Connection, TestContext.Current.CancellationToken);

    private static IReadOnlyList<PaletteGroup> Empty(
        IReadOnlyList<PaletteItem> items,
        PaletteScope scope,
        IReadOnlyList<string> recent) =>
        PaletteRanker.EmptyQueryGroups(items, scope, recent, Connection, TestContext.Current.CancellationToken);

    private static IReadOnlyList<PaletteItem> Results(IReadOnlyList<PaletteGroup> groups) =>
        groups.SingleOrDefault(group => group.Header is PaletteGroupHeader.NoHeader)?.Items ?? [];

    [Fact]
    public void AHigherWeightedKindRanksAboveALowerOne()
    {
        var items = new[] { Item("users", PaletteItemKind.History), Item("users", PaletteItemKind.Table) };
        var results = Results(Filtered(items, "users"));
        Assert.Equal(PaletteItemKind.Table, results[0].Kind);
    }

    [Fact]
    public void FrecencyLiftsAnEquallyScoredRow()
    {
        var items = new[] { Item("alpha", PaletteItemKind.Table, "a1"), Item("alpha", PaletteItemKind.Table, "a2") };
        var scores = new Dictionary<string, double>(StringComparer.Ordinal) { ["a2"] = 1.0 };
        var results = Results(Filtered(items, "alpha", scores));
        Assert.Equal("a2", results[0].FrecencyKey);
    }

    [Fact]
    public void AnOpenTabIsLiftedOverAnEqualRow()
    {
        var items = new[]
        {
            Item("alpha", PaletteItemKind.Table, "a1"),
            Item("alpha", PaletteItemKind.Table, "a2") with { IsOpenInTab = true },
        };
        var results = Results(Filtered(items, "alpha"));
        Assert.Equal("a2", results[0].FrecencyKey);
    }

    [Fact]
    public void TheEmptyQueryLeadsWithTheRecentGroup()
    {
        var items = new[] { Item("users", PaletteItemKind.Table), Item("orders", PaletteItemKind.Table) };
        var groups = Empty(items, PaletteScope.All, ["orders"]);
        Assert.Equal(PaletteGroupHeader.Recent, groups[0].Header);
        Assert.Equal("orders", groups[0].Items.Single().Name);
    }

    [Fact]
    public void TheEmptyQueryGroupsAScopeByKind()
    {
        var items = new[] { Item("b", PaletteItemKind.View), Item("a", PaletteItemKind.Table) };
        var groups = Empty(items, PaletteScope.Tables, []);
        var headers = groups.Select(group => group.Header).OfType<PaletteGroupHeader.SectionHeader>().Select(header => header.Kind);
        Assert.Equal([PaletteItemKind.Table, PaletteItemKind.View], headers);
    }

    [Fact]
    public void AllScopeEmptyQueryShowsOnlyRecent()
    {
        var items = new[] { Item("users", PaletteItemKind.Table), Item("orders", PaletteItemKind.Table) };
        var groups = Empty(items, PaletteScope.All, ["orders"]);
        Assert.Single(groups);
        Assert.Equal(PaletteGroupHeader.Recent, groups[0].Header);
    }

    [Fact]
    public void AQualifiedQueryMatchesThroughTheContainerPath()
    {
        var items = new[] { Item("orders", PaletteItemKind.Table, schema: "shop") };
        Assert.Single(Results(Filtered(items, "shop.orders")));
        Assert.Empty(Results(Filtered(items, "shop.zzz")));
        Assert.Empty(Results(Filtered(items, "nope.orders")));
    }

    [Fact]
    public void ATrailingDotTakesEveryObjectInTheContainer()
    {
        var items = new[]
        {
            Item("orders", PaletteItemKind.Table, schema: "shop"),
            Item("staff", PaletteItemKind.Table, schema: "shop"),
            Item("orders", PaletteItemKind.Table, schema: "hr"),
        };
        var results = Results(Filtered(items, "shop."));
        Assert.Equal(2, results.Count);
        Assert.All(results, item => Assert.Equal("shop", item.SchemaName));
    }

    [Fact]
    public void ResultsAreCappedAtMaxResults()
    {
        var items = Enumerable.Range(0, PaletteRanking.MaxResults + 50)
            .Select(index => Item($"users{index:D3}", PaletteItemKind.Table, $"k{index}"))
            .ToArray();
        var results = Results(Filtered(items, "users"));
        Assert.Equal(PaletteRanking.MaxResults, results.Count);
    }

    [Fact]
    public void OnlyTheRowsShownCarryMatchedIndices()
    {
        var items = new[] { Item("users", PaletteItemKind.Table) };
        var results = Results(Filtered(items, "us"));
        Assert.Equal([0, 1], results[0].MatchedIndices);
    }

    [Fact]
    public void AForeignResultDoesNotBorrowThisConnectionsFrecency()
    {
        var target = new PaletteTarget(Guid.NewGuid(), "Other", null, null);
        var items = new[]
        {
            Item("alpha", PaletteItemKind.Table, "a2"),
            Item("alpha", PaletteItemKind.Table, "a1") with { Target = target },
        };
        // a1's score would lift it over a2 if it were applied, but a1 belongs to another connection, so it is not.
        var scores = new Dictionary<string, double>(StringComparer.Ordinal) { ["a1"] = 1.0 };
        var results = Results(Filtered(items, "alpha", scores));
        Assert.Equal("a2", results[0].FrecencyKey);
    }
}
