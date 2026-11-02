using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class LibraryTreeTests
{
    private static readonly Guid Work = Guid.NewGuid();
    private static readonly Guid Staging = Guid.NewGuid();

    private static SavedConnection Connection(string name, string host, Guid? group = null, string engine = "postgres") =>
        new(Guid.NewGuid(), name, engine, host, 5432, "app", "admin", TlsSettings.Disabled, GroupId: group);

    private static string EngineName(string id) => id == "postgres" ? "PostgreSQL" : id;

    private static (LibrarySnapshot Snapshot, SavedConnection Local, SavedConnection Prod, SavedConnection Stage) Library()
    {
        var local = Connection("local", "localhost");
        var prod = Connection("prod", "db.example.com", Work);
        var stage = Connection("stage", "stage.example.com", Staging);
        var snapshot = new LibrarySnapshot(
            [local, prod, stage],
            [new ConnectionGroup(Work, "Work", null, 0, null), new ConnectionGroup(Staging, "Staging", Work, 0, null)],
            [prod.Id!.Value],
            [local.Id!.Value]);
        return (snapshot, local, prod, stage);
    }

    [Fact]
    public void FavoritesAndRecentComeFirstThenEveryConnectionInItsGroup()
    {
        var (snapshot, local, prod, stage) = Library();

        var roots = LibraryTree.Build(snapshot, null, EngineName);

        Assert.Equal(
            [LibraryNodeKind.Favorites, LibraryNodeKind.Recent, LibraryNodeKind.AllConnections],
            roots.Select(root => root.Kind));
        Assert.Equal(prod.Id, Assert.Single(roots[0].Children).Id);
        Assert.Equal(local.Id, Assert.Single(roots[1].Children).Id);
        var work = roots[2].Children[0];
        Assert.Equal("Work", work.Title);
        Assert.Equal("Staging", work.Children[0].Title);
        Assert.Equal(stage.Id, work.Children[0].Children[0].Id);
        Assert.Equal(prod.Id, work.Children[1].Id);
        Assert.Equal(local.Id, roots[2].Children[1].Id);
    }

    [Fact]
    public void AFavoriteHasOneRowPerSection()
    {
        var (snapshot, _, prod, _) = Library();

        var roots = LibraryTree.Build(snapshot, null, EngineName);
        var rows = Flatten(roots).Where(node => node.Id == prod.Id).ToList();

        Assert.Equal(2, rows.Count);
        Assert.NotEqual(rows[0].Key, rows[1].Key);
    }

    [Fact]
    public void ASearchMatchesEveryWordAndKeepsOnlyTheGroupsThatHoldAMatch()
    {
        var (snapshot, _, _, stage) = Library();

        var roots = LibraryTree.Build(snapshot, "staging POSTGRES", EngineName);

        var all = Assert.Single(roots);
        Assert.Equal(LibraryNodeKind.AllConnections, all.Kind);
        var work = Assert.Single(all.Children);
        var staging = Assert.Single(work.Children);
        Assert.Equal(stage.Id, Assert.Single(staging.Children).Id);
    }

    [Fact]
    public void ASearchWithNoMatchShowsNothing()
    {
        var (snapshot, _, _, _) = Library();

        Assert.Empty(LibraryTree.Build(snapshot, "mysql", EngineName));
    }

    [Fact]
    public void AnEmptyLibraryStillHasItsConnectionsSection()
    {
        var empty = new LibrarySnapshot([], [], [], []);

        var root = Assert.Single(LibraryTree.Build(empty, null, EngineName));

        Assert.Equal(LibraryNodeKind.AllConnections, root.Kind);
        Assert.Empty(root.Children);
    }

    [Fact]
    public void AGroupPathNamesEveryParent()
    {
        var (snapshot, _, _, _) = Library();

        var path = LibraryTree.GroupPath(Staging, snapshot.Groups.ToDictionary(group => group.Id));

        Assert.Equal("Work / Staging", path);
    }

    [Fact]
    public void ARowDescribesWhereTheConnectionPoints()
    {
        var network = Connection("prod", "db.example.com");
        var file = new SavedConnection(Guid.NewGuid(), "app", "sqlite", string.Empty, 0, @"C:\data\app.db", string.Empty, TlsSettings.Disabled);

        Assert.Equal("admin@db.example.com:5432/app", ConnectionSearch.Describe(network, isFileEngine: false));
        Assert.Equal(@"C:\data\app.db", ConnectionSearch.Describe(file, isFileEngine: true));
    }

    private static IEnumerable<LibraryNode> Flatten(IEnumerable<LibraryNode> nodes) =>
        nodes.SelectMany(node => Flatten(node.Children).Prepend(node));
}
