using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class SavedQueryTreeTests
{
    private static readonly SavedQueryList Library = new(
        [
            Query(1, "Top second", null, 1),
            Query(2, "Monthly totals", 11, 0),
            Query(3, "Top first", null, 0),
            Query(4, "Invoices", 10, 1),
            Query(5, "Customers", 10, 0),
        ],
        [
            Folder(10, "Reports", null, 1),
            Folder(11, "Monthly", 10, 0),
            Folder(12, "Admin", null, 0),
            Folder(13, "Archive", 10, 1),
        ]);

    [Fact]
    public void EachLevelListsItsFoldersThenItsQueriesInTheirOrder()
    {
        var roots = SavedQueryTree.Build(Library);

        Assert.Equal<string>(["Admin", "Reports", "Top first", "Top second"], roots.Select(node => node.Name));
        var reports = roots[1];
        Assert.Equal(Id(10), reports.Folder?.Id);
        Assert.Equal<string>(["Monthly", "Archive", "Customers", "Invoices"], reports.Children.Select(node => node.Name));
        Assert.Equal<string>(["Monthly totals"], reports.Children[0].Children.Select(node => node.Name));
        Assert.Empty(roots[0].Children);
        Assert.Null(roots[2].Folder);
        Assert.Equal(Id(3), roots[2].Query?.Id);
    }

    [Fact]
    public void APlaceTheListLacksShowsAtTheTopLevel()
    {
        var list = new SavedQueryList([Query(1, "Lost", 99, 0)], [Folder(10, "Orphan", 98, 0)]);

        var roots = SavedQueryTree.Build(list);

        Assert.Equal<string>(["Orphan", "Lost"], roots.Select(node => node.Name));
    }

    [Fact]
    public void AnEmptyListBuildsNoRows()
    {
        Assert.Empty(SavedQueryTree.Build(new SavedQueryList([], [])));
        Assert.Empty(SavedQueryTree.Folders(new SavedQueryList([], [])));
    }

    [Fact]
    public void FoldersComeInTreeOrderWithThePathAboveEach()
    {
        var folders = SavedQueryTree.Folders(Library);

        Assert.Equal<Guid>([Id(12), Id(10), Id(11), Id(13)], folders.Select(folder => folder.Id));
        Assert.Equal<string>(["Admin", "Reports", "Reports / Monthly", "Reports / Archive"], folders.Select(folder => folder.Path));
        Assert.Equal<int>([0, 0, 1, 1], folders.Select(folder => folder.Depth));
        Assert.Equal("Monthly", folders[2].Name);
    }

    [Fact]
    public void AFolderLeadsUpToTheTopLevel()
    {
        Assert.Equal<Guid>([Id(11), Id(10)], SavedQueryTree.FolderAndAncestors(Id(11), Library));
        Assert.Equal<Guid>([Id(12)], SavedQueryTree.FolderAndAncestors(Id(12), Library));
        Assert.Empty(SavedQueryTree.FolderAndAncestors(Id(99), Library));
    }

    [Fact]
    public void AFolderLoopEndsTheWayUp()
    {
        var list = new SavedQueryList([], [Folder(1, "A", 2, 0), Folder(2, "B", 1, 0)]);

        Assert.Equal<Guid>([Id(1), Id(2)], SavedQueryTree.FolderAndAncestors(Id(1), list));
    }

    [Theory]
    [InlineData("-- Get active users\nSELECT * FROM users WHERE active = 1", "Get active users")]
    [InlineData("SELECT * FROM orders", "SELECT * FROM orders")]
    [InlineData("--\nSELECT 1", "SELECT 1")]
    [InlineData("\r\n   \r\n  --   Totals  \r\nSELECT 1", "Totals")]
    [InlineData("  select 1  ", "select 1")]
    [InlineData("", "Untitled")]
    [InlineData("--\n  -- \n", "Untitled")]
    public void TheAutomaticNameIsTheFirstCommentOrLine(string sql, string name)
    {
        Assert.Equal(name, SavedQueryText.AutoName(sql, "Untitled"));
    }

    [Fact]
    public void TheAutomaticNameIsCutToFiftyCharacters()
    {
        Assert.Equal(new string('A', 50), SavedQueryText.AutoName(new string('A', 100), "Untitled"));
    }

    [Fact]
    public void TheCutNeverSplitsACharacter()
    {
        var sql = new string('a', 49) + "\U0001F600" + "tail";

        var name = SavedQueryText.AutoName(sql, "Untitled");

        Assert.Equal(new string('a', 49), name);
    }

    [Theory]
    [InlineData("\n\n  SELECT 1\nFROM t", "SELECT 1")]
    [InlineData("-- note\nSELECT 1", "-- note")]
    [InlineData("  \n ", "")]
    public void TheCaptionIsTheFirstLineWithText(string sql, string line)
    {
        Assert.Equal(line, SavedQueryText.FirstLine(sql));
    }

    [Fact]
    public void WithNoQueryTabTheQueryOpensInANewTab()
    {
        Assert.Equal(
            new SavedQueryInsertion(SavedQueryInsertKind.NewTab, "SELECT 1"),
            SavedQueryText.Insertion(null, "SELECT 1"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("  \n\t ")]
    public void ABlankEditorTakesTheQuery(string text)
    {
        Assert.Equal(
            new SavedQueryInsertion(SavedQueryInsertKind.Replace, "SELECT 1"),
            SavedQueryText.Insertion(text, "SELECT 1"));
    }

    [Fact]
    public void AnEditorWithTextGetsTheQueryAfterABlankLine()
    {
        Assert.Equal(
            new SavedQueryInsertion(SavedQueryInsertKind.Append, "\n\nSELECT * FROM users"),
            SavedQueryText.Insertion("SELECT 1", "SELECT * FROM users"));
    }

    // Record ids are UUIDs (core ADR 0052); a number picks one the test can name.
    private static Guid Id(int number) => new($"00000000-0000-4000-8000-{number:D12}");

    private static SavedQuery Query(int id, string name, int? folderId, long order) =>
        new(Id(id), name, $"SELECT {id}", null, folderId is { } folder ? Id(folder) : null, order, DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));

    private static SavedQueryFolder Folder(int id, string name, int? parentId, long order) =>
        new(Id(id), name, parentId is { } parent ? Id(parent) : null, order);
}
