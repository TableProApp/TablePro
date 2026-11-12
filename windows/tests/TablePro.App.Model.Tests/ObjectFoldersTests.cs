using System.Globalization;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ObjectFoldersTests
{
    private static ObjectEntry Entry(string name, ObjectKind kind = ObjectKind.Table, string? schema = null) =>
        new(schema, name, kind, null);

    [Fact]
    public void ObjectsGoIntoOneFolderPerKindInTheFixedOrderSortedByName()
    {
        var folders = ObjectFolders.Group(
            [
                Entry("zeta"), Entry("v_people", ObjectKind.View), Entry("alpha"), Entry("parts", ObjectKind.PartitionedTable),
                Entry("next_id", ObjectKind.Sequence),
            ],
            CultureInfo.InvariantCulture);

        Assert.Equal([FolderKind.Tables, FolderKind.Views, FolderKind.Sequences], folders.Select(folder => folder.Kind));
        Assert.Equal(["alpha", "parts", "zeta"], folders[0].Objects.Select(entry => entry.Name));
    }

    [Fact]
    public void AFilterRanksNamesThatStartWithTheTextFirst()
    {
        var matches = Catalog(Entry("user_roles"), Entry("audit_users"), Entry("Users"), Entry("orders")).Filter("USER", TestContext.Current.CancellationToken);

        Assert.Equal(["user_roles", "Users", "audit_users"], matches.Select(entry => entry.Name));
    }

    [Fact]
    public void AnEmptyFilterMatchesNothing()
    {
        Assert.Empty(Catalog(Entry("a")).Filter("  ", TestContext.Current.CancellationToken));
    }

    // The order the list showed when each keystroke sorted its matches: starts-with first, then name, then schema.
    [Theory]
    [InlineData("en-US")]
    [InlineData("vi-VN")]
    [InlineData("de-DE")]
    [InlineData("tr-TR")]
    public void TheCatalogFiltersInTheOrderAPerKeystrokeSortGave(string name)
    {
        var culture = CultureInfo.GetCultureInfo(name);
        var names = new[]
        {
            "users", "Users", "user_roles", "audit_users", "đơn_hàng", "Đơn_Hàng_cũ", "khách_hàng", "ıncome", "Income",
            "INCOME_tax", "straße", "STRASSE", "orders", "order_items", "s_user", "USER", "zuser", "a_user_b",
        };
        var entries = names
            .SelectMany(each => new[] { Entry(each, schema: "public"), Entry(each, schema: "archive"), Entry(each) })
            .ToList();
        var catalog = new ObjectCatalog(entries, culture);
        var shown = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = culture;
        try
        {
            foreach (var text in new[] { "user", "USER", "đơn", "hàng", "income", "İNCOME", "strasse", "ß", "o", " r " })
            {
                var needle = text.Trim();
                List<ObjectEntry> expected =
                [
                    .. entries
                        .Where(entry => entry.Name.Contains(needle, StringComparison.CurrentCultureIgnoreCase))
                        .OrderBy(entry => entry.Name.StartsWith(needle, StringComparison.CurrentCultureIgnoreCase) ? 0 : 1)
                        .ThenBy(entry => entry.Name, StringComparer.CurrentCultureIgnoreCase)
                        .ThenBy(entry => entry.Schema, StringComparer.CurrentCultureIgnoreCase),
                ];

                Assert.Equal(expected, catalog.Filter(text, TestContext.Current.CancellationToken));
            }
        }
        finally
        {
            CultureInfo.CurrentCulture = shown;
        }
    }

    [Fact]
    public void AFilterStoppedMidwayThrowsInsteadOfReturningPartOfTheMatches()
    {
        var catalog = Catalog([.. Enumerable.Range(0, 5_000).Select(index => Entry($"t{index}"))]);
        using var stopped = new CancellationTokenSource();
        stopped.Cancel();

        Assert.Throws<OperationCanceledException>(() => catalog.Filter("t", stopped.Token));
    }

    private static ObjectCatalog Catalog(params ObjectEntry[] entries) => new(entries, CultureInfo.InvariantCulture);

    [Fact]
    public void OnlyTablesAndViewsHaveRowsToShow()
    {
        Assert.True(ObjectFolders.HasRows(ObjectKind.Table));
        Assert.True(ObjectFolders.HasRows(ObjectKind.MaterializedView));
        Assert.False(ObjectFolders.HasRows(ObjectKind.Function));
        Assert.False(ObjectFolders.HasRows(ObjectKind.Key));
    }

    [Fact]
    public void RoutinesTriggersAndSequencesOpenTheirDefinition()
    {
        Assert.All(
            [ObjectKind.Function, ObjectKind.Procedure, ObjectKind.Trigger, ObjectKind.Sequence],
            kind => Assert.True(ObjectFolders.HasDefinition(kind)));
        Assert.All(
            [ObjectKind.Table, ObjectKind.View, ObjectKind.Key, ObjectKind.Dictionary, ObjectKind.Other],
            kind => Assert.False(ObjectFolders.HasDefinition(kind)));
    }
}
