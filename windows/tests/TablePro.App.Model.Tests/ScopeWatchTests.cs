using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ScopeWatchTests
{
    private static readonly Guid Acme = Guid.NewGuid();
    private static readonly Guid Globex = Guid.NewGuid();

    private static SavedConnection Connection(string name) =>
        new(Guid.NewGuid(), name, "postgres", "localhost", 5432, "app", "admin", TlsSettings.Disabled);

    private static LibrarySnapshot Snapshot(Guid? scope, params SavedConnection[] connections) =>
        new(connections, [], [], []) { Scope = scope };

    private static LibrarySnapshot WithGroups(Guid? scope, params ConnectionGroup[] groups) =>
        new([], groups, [], []) { Scope = scope };

    private static bool Read(ScopeWatch watch, LibrarySnapshot snapshot) => watch.Show(watch.Start(), snapshot);

    [Fact]
    public void TheFirstReadOfALibraryWithConnectionsChangesTheScopeAndAnEmptyOneDoesNot()
    {
        var empty = new ScopeWatch();
        var filled = new ScopeWatch();

        Assert.False(Read(empty, Snapshot(null)));
        Assert.True(Read(filled, Snapshot(null, Connection("one"))));
        Assert.Null(filled.Current.Project);
        Assert.Single(filled.Current.Connections);
    }

    [Fact]
    public void ASwitchChangesTheScopeEvenBetweenTwoEmptyProjects()
    {
        var watch = new ScopeWatch();

        Assert.True(Read(watch, Snapshot(Acme)));
        Assert.True(Read(watch, Snapshot(Globex)));
        Assert.False(Read(watch, Snapshot(Globex)));
        Assert.True(Read(watch, Snapshot(null)));
        Assert.Null(watch.Current.Project);
    }

    [Fact]
    public void AMoveADeleteAndAnImportChangeTheScopeOfTheProjectTheyTouch()
    {
        var (one, two, three) = (Connection("one"), Connection("two"), Connection("three"));
        var watch = new ScopeWatch();
        Assert.True(Read(watch, Snapshot(Acme, one, two)));

        Assert.True(Read(watch, Snapshot(Acme, one)));
        Assert.True(Read(watch, Snapshot(Acme, one, three)));
        Assert.True(Read(watch, Snapshot(Acme)));

        Assert.Equal(Acme, watch.Current.Project);
        Assert.Empty(watch.Current.Connections);
    }

    [Fact]
    public void AnEditThatLeavesTheConnectionsInScopeAloneChangesNothing()
    {
        var (one, two) = (Connection("one"), Connection("two"));
        var watch = new ScopeWatch();
        Assert.True(Read(watch, Snapshot(Acme, one, two)));

        Assert.False(Read(watch, Snapshot(Acme, two, one with { Name = "renamed", GroupId = Guid.NewGuid() })));
        Assert.True(watch.Current.Connections.SetEquals([one.Id!.Value, two.Id!.Value]));
    }

    [Fact]
    public void AnEmptyGroupMovedIntoOrOutOfTheProjectChangesTheScope()
    {
        var work = new ConnectionGroup(Guid.NewGuid(), "Work", null, 0, null);
        var watch = new ScopeWatch();
        Assert.True(Read(watch, WithGroups(Acme)));

        Assert.True(Read(watch, WithGroups(Acme, work)));
        Assert.False(Read(watch, WithGroups(Acme, work with { Name = "Office" })));
        Assert.True(Read(watch, WithGroups(Acme)));

        Assert.Empty(watch.Current.Groups);
    }

    [Fact]
    public void AProjectDeletedWhileActiveFallsBackToAllConnections()
    {
        var (one, two) = (Connection("one"), Connection("two"));
        var watch = new ScopeWatch();
        Assert.True(Read(watch, Snapshot(Acme, one)));

        Assert.True(Read(watch, Snapshot(null, one, two)));

        Assert.Null(watch.Current.Project);
        Assert.Equal(2, watch.Current.Connections.Count);
    }

    [Fact]
    public void AReadALaterOneOvertookIsDroppedWhateverItFound()
    {
        var one = Connection("one");
        var watch = new ScopeWatch();
        var acme = watch.Start();
        var globex = watch.Start();

        Assert.False(watch.Show(acme, Snapshot(Acme, one)));
        Assert.True(watch.Current.Matches(ScopedSet.None));
        Assert.True(watch.Show(globex, Snapshot(Globex)));
        Assert.Equal(Globex, watch.Current.Project);
    }

    [Fact]
    public void AFailedReadAfterASwitchGoesBackToTheProjectShown()
    {
        var one = Connection("one");
        var watch = new ScopeWatch();
        Assert.True(Read(watch, Snapshot(Acme, one)));

        Assert.Equal(FailedScopeRead.Reverted, watch.Fail(watch.Start(), Globex));

        Assert.Equal(Acme, watch.Current.Project);
        Assert.True(watch.Current.Connections.SetEquals([one.Id!.Value]));
    }

    [Fact]
    public void AFailedSwitchAwayFromAllConnectionsGoesBackToAllConnections()
    {
        var watch = new ScopeWatch();
        Assert.False(Read(watch, Snapshot(null)));

        Assert.Equal(FailedScopeRead.Reverted, watch.Fail(watch.Start(), Acme));
        Assert.Null(watch.Current.Project);
    }

    [Fact]
    public void AFailedReadAfterALibraryChangeKeepsTheProjectAndItsList()
    {
        var one = Connection("one");
        var watch = new ScopeWatch();
        Assert.True(Read(watch, Snapshot(Acme, one)));

        Assert.Equal(FailedScopeRead.Kept, watch.Fail(watch.Start(), Acme));

        Assert.Equal(Acme, watch.Current.Project);
        Assert.Single(watch.Current.Connections);
    }

    [Fact]
    public void AFailedFirstReadKeepsTheProjectTheSettingNames()
    {
        var watch = new ScopeWatch();

        Assert.Equal(FailedScopeRead.Kept, watch.Fail(watch.Start(), Acme));

        Assert.True(watch.Current.Matches(ScopedSet.None));
        Assert.True(Read(watch, Snapshot(Acme)));
    }

    [Fact]
    public void ARetryAfterAFailedReadShowsWhatItFinds()
    {
        var (one, two) = (Connection("one"), Connection("two"));
        var watch = new ScopeWatch();
        Assert.True(Read(watch, Snapshot(Acme, one)));

        Assert.Equal(FailedScopeRead.Reverted, watch.Fail(watch.Start(), Globex));
        Assert.True(Read(watch, Snapshot(Globex)));
        Assert.Equal(Globex, watch.Current.Project);

        Assert.Equal(FailedScopeRead.Kept, watch.Fail(watch.Start(), Globex));
        Assert.True(Read(watch, Snapshot(Globex, two)));
        Assert.Single(watch.Current.Connections);
    }

    [Fact]
    public void AFailedReadALaterGoodOneOvertookSaysNothing()
    {
        var watch = new ScopeWatch();
        Assert.True(Read(watch, Snapshot(Acme)));
        var failed = watch.Start();
        var good = watch.Start();

        Assert.Equal(FailedScopeRead.Overtaken, watch.Fail(failed, Globex));
        Assert.Equal(Acme, watch.Current.Project);
        Assert.True(watch.Show(good, Snapshot(Globex)));
        Assert.Equal(Globex, watch.Current.Project);
    }

    [Fact]
    public void AFailedReadOvertakenByAnotherFailedOneLeavesTheLastToGoBack()
    {
        var watch = new ScopeWatch();
        Assert.True(Read(watch, Snapshot(Acme)));
        var first = watch.Start();
        var second = watch.Start();

        Assert.Equal(FailedScopeRead.Overtaken, watch.Fail(first, Globex));
        Assert.Equal(FailedScopeRead.Reverted, watch.Fail(second, Guid.NewGuid()));
        Assert.Equal(Acme, watch.Current.Project);
    }

    [Fact]
    public void AConnectionNotSavedYetIsInNoScope()
    {
        var unsaved = Connection("draft") with { Id = null };

        Assert.Empty(ScopedSet.Of(Snapshot(Acme, unsaved)).Connections);
    }
}
