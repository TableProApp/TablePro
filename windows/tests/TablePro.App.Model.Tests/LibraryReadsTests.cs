using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class LibraryReadsTests
{
    private static readonly SavedConnection One =
        new(Guid.NewGuid(), "one", "postgres", "localhost", 5432, "app", "admin", TlsSettings.Disabled);

    private static readonly ScopedSet Acme = Scope(Guid.NewGuid(), One);
    private static readonly ScopedSet Globex = Scope(Guid.NewGuid());
    private static readonly ScopedSet All = Scope(null, One);

    private static ScopedSet Scope(Guid? project, params SavedConnection[] connections) =>
        ScopedSet.Of(new LibrarySnapshot(connections, [], [], []) { Scope = project });

    [Fact]
    public void ASettledListOfTheProjectAskedForIsNotReadAgain()
    {
        var reads = new LibraryReads();
        Assert.False(reads.ScopeNeedsRead(ScopedSet.None, ScopedSet.None));

        Assert.True(reads.Show(reads.Start()));

        Assert.False(reads.ScopeNeedsRead(Acme, Acme));
        Assert.True(reads.ScopeNeedsRead(Acme, Globex));
        Assert.True(reads.ScopeNeedsRead(Acme, All));
    }

    [Fact]
    public void AListOfTheProjectIsReadAgainOnceTheProjectHoldsOtherConnections()
    {
        var reads = new LibraryReads();
        Assert.True(reads.Show(reads.Start()));

        Assert.True(reads.ScopeNeedsRead(Acme, Scope(Acme.Project)));
        Assert.False(reads.ScopeNeedsRead(Acme, Scope(Acme.Project, One with { Name = "renamed" })));
    }

    [Fact]
    public void SwitchingBackWhileAnotherProjectsReadIsOutReadsAgainAndDropsThatRead()
    {
        var reads = new LibraryReads();
        Assert.True(reads.Show(reads.Start()));
        Assert.True(reads.ScopeNeedsRead(Acme, Globex));
        var globex = reads.Start();

        Assert.True(reads.ScopeNeedsRead(Acme, Acme));
        var acme = reads.Start();

        Assert.False(reads.Show(globex));
        Assert.True(reads.Show(acme));
        Assert.False(reads.ScopeNeedsRead(Acme, Acme));
    }

    [Fact]
    public void OnlyTheLastReadStartedIsShownWhateverOrderTheyEndIn()
    {
        var reads = new LibraryReads();
        var first = reads.Start();
        var second = reads.Start();

        Assert.False(reads.Show(first));
        Assert.True(reads.Show(second));
        Assert.False(reads.Show(first));
    }

    [Fact]
    public void AReadThatNeverShowedLeavesTheNextSwitchToReadAgain()
    {
        var reads = new LibraryReads();
        Assert.True(reads.Show(reads.Start()));
        reads.Start();

        Assert.True(reads.ScopeNeedsRead(Acme, Acme));
    }
}
