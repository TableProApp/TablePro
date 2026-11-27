using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class LibraryScopeTests
{
    private static readonly ConnectionProject Acme = new(Guid.NewGuid(), "Acme", 0, null);
    private static readonly ConnectionProject Globex = new(Guid.NewGuid(), "Globex", 1, "red");
    private static readonly ConnectionProject Initech = new(Guid.NewGuid(), "Initech", 2, null);

    private static SavedConnection Connection(string name, Guid? group = null, Guid? project = null) =>
        new(Guid.NewGuid(), name, "postgres", "localhost", 5432, "app", "admin", TlsSettings.Disabled, GroupId: group)
        {
            ProjectId = project,
        };

    private static LibrarySnapshot Snapshot(
        Guid? scope,
        IReadOnlyList<SavedConnection>? connections = null,
        IReadOnlyList<ConnectionGroup>? groups = null) =>
        new(connections ?? [], groups ?? [], [], []) { Projects = [Acme, Globex], Scope = scope };

    [Fact]
    public void TheActiveProjectIsTheOneTheSnapshotIsNarrowedTo()
    {
        Assert.Equal(Globex, LibraryScope.Active(Snapshot(Globex.Id)));
        Assert.Null(LibraryScope.Active(Snapshot(null)));
        Assert.Null(LibraryScope.Active(Snapshot(Initech.Id)));
    }

    [Fact]
    public void ASettingThatOutlivedItsProjectReadsAsAllConnections()
    {
        Assert.Equal(Acme.Id, LibraryScope.Resolve(Acme.Id, [Acme, Globex]));
        Assert.Null(LibraryScope.Resolve(Initech.Id, [Acme, Globex]));
        Assert.Null(LibraryScope.Resolve(null, [Acme]));
    }

    [Fact]
    public void AnEmptyProjectIsNotAnEmptyLibrary()
    {
        var group = new ConnectionGroup(Guid.NewGuid(), "Work", null, 0, null);

        Assert.Equal(LibraryEmptiness.Library, LibraryScope.Emptiness(Snapshot(null)));
        Assert.Equal(LibraryEmptiness.Project, LibraryScope.Emptiness(Snapshot(Acme.Id)));
        Assert.Equal(LibraryEmptiness.NotEmpty, LibraryScope.Emptiness(Snapshot(Acme.Id, [Connection("prod")])));
        Assert.Equal(LibraryEmptiness.NotEmpty, LibraryScope.Emptiness(Snapshot(Acme.Id, groups: [group])));
    }

    [Fact]
    public void OnlyUngroupedConnectionsAndTopLevelGroupsMoveToAProject()
    {
        var top = new ConnectionGroup(Guid.NewGuid(), "Work", null, 0, null);
        var nested = new ConnectionGroup(Guid.NewGuid(), "Staging", top.Id, 0, null);

        Assert.True(LibraryScope.CanMove([Connection("a"), Connection("b")]));
        Assert.False(LibraryScope.CanMove([Connection("a"), Connection("b", top.Id)]));
        Assert.False(LibraryScope.CanMove(Array.Empty<SavedConnection>()));
        Assert.True(LibraryScope.CanMove(top));
        Assert.False(LibraryScope.CanMove(nested));
    }

    [Fact]
    public void TheMoveMenuListsNoProjectFirstAndMarksTheOneEveryItemIsIn()
    {
        var shared = LibraryScope.Choices([Acme, Globex], [Globex.Id, Globex.Id]);
        var mixed = LibraryScope.Choices([Acme, Globex], [Globex.Id, null]);
        var none = LibraryScope.Choices([Acme], [null]);

        Assert.Equal<Guid?>([null, Acme.Id, Globex.Id], shared.Select(choice => choice.Id));
        Assert.Equal<string?>([null, "Acme", "Globex"], shared.Select(choice => choice.Name));
        Assert.Equal<bool>([false, false, true], shared.Select(choice => choice.IsCurrent));
        Assert.DoesNotContain(mixed, choice => choice.IsCurrent);
        Assert.Equal<bool>([true, false], none.Select(choice => choice.IsCurrent));
    }

    [Fact]
    public void ANewConnectionPicksGroupsOfTheActiveProjectAndAnEditedOneOfItsOwn()
    {
        Assert.Equal(Acme.Id, LibraryScope.FormScope(null, Acme.Id));
        Assert.Null(LibraryScope.FormScope(null, null));
        Assert.Equal(Globex.Id, LibraryScope.FormScope(Connection("prod", project: Globex.Id), Acme.Id));
        Assert.Null(LibraryScope.FormScope(Connection("stray"), Acme.Id));
    }

    [Fact]
    public void AStepUpOrDownNamesTheProjectToLandBefore()
    {
        ConnectionProject[] projects = [Acme, Globex, Initech];

        Assert.True(LibraryScope.TryStep(projects, Globex.Id, up: true, out var first));
        Assert.Equal(Acme.Id, first);
        Assert.True(LibraryScope.TryStep(projects, Acme.Id, up: false, out var middle));
        Assert.Equal(Initech.Id, middle);
        Assert.True(LibraryScope.TryStep(projects, Globex.Id, up: false, out var last));
        Assert.Null(last);
        Assert.False(LibraryScope.TryStep(projects, Acme.Id, up: true, out _));
        Assert.False(LibraryScope.TryStep(projects, Initech.Id, up: false, out _));
        Assert.False(LibraryScope.TryStep(projects, Guid.NewGuid(), up: true, out _));
    }

    [Fact]
    public void TheTreeOfAScopedSnapshotShowsOnlyWhatTheCoreKept()
    {
        var prod = Connection("prod", project: Acme.Id);
        var snapshot = Snapshot(Acme.Id, [prod]) with { Recent = [prod.Id!.Value] };

        var roots = LibraryTree.Build(snapshot, null, id => id);
        var found = LibraryTree.Build(snapshot, "other", id => id);

        Assert.Equal([LibraryNodeKind.Recent, LibraryNodeKind.AllConnections], roots.Select(root => root.Kind));
        Assert.Equal(prod.Id, Assert.Single(roots[1].Children).Id);
        Assert.Empty(found);
    }
}
