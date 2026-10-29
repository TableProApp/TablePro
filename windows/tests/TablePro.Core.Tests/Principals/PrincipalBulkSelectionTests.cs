using TablePro.Core.Principals;

namespace TablePro.Core.Tests.Principals;

/// <summary>Several principals dropped at once and several objects granted on at once, as the macOS editor allows.</summary>
public sealed class PrincipalBulkSelectionTests
{
    private static readonly PrincipalRef Alice = new("alice");
    private static readonly PrincipalRef Bob = new("bob");
    private static readonly PrincipalRef Readers = new("readers");
    private static readonly PrivilegeScope Orders = PrivilegeScope.ForTable("app", "public", "orders");
    private static readonly PrivilegeScope Items = PrivilegeScope.ForTable("app", "public", "items");

    private static PrincipalChangeTracker MakeTracker()
    {
        var tracker = new PrincipalChangeTracker();
        tracker.Load(
            [new PrincipalInfo(Alice), new PrincipalInfo(Bob), new PrincipalInfo(Readers, isRole: true, canLogin: false)],
            new PrivilegeCatalog([], [], [], [new("SELECT", "Select"), new("INSERT", "Insert")], []));
        tracker.LoadGrants(Alice, [new PrincipalGrant("SELECT", Orders)]);
        return tracker;
    }

    [Fact]
    public void DroppingSeveralIsOneUndoStep()
    {
        var tracker = MakeTracker();

        tracker.StageDrops([Alice, Bob], PrincipalDropOptions.None, "Drop 2");

        Assert.Equal(PrincipalStage.Dropped, tracker.Stage(Alice));
        Assert.Equal(PrincipalStage.Dropped, tracker.Stage(Bob));
        Assert.Equal(2, tracker.ChangeCount);
        Assert.Equal("Drop 2", tracker.UndoActionName);

        tracker.Undo();

        Assert.False(tracker.HasChanges);
        Assert.False(tracker.CanUndo);
    }

    [Fact]
    public void DroppingAStagedCreateRemovesItAndKeepsTheOthersDropped()
    {
        var tracker = MakeTracker();
        var carol = new PrincipalRef("carol");
        tracker.StageCreate(new PrincipalDefinition(carol, "secret"));

        tracker.StageDrops([carol, Bob], PrincipalDropOptions.None);

        Assert.DoesNotContain(tracker.Rows(), r => r.Ref == carol);
        Assert.Equal(PrincipalStage.Dropped, tracker.Stage(Bob));
        var drop = Assert.IsType<DropPrincipal>(Assert.Single(tracker.PendingChanges()));
        Assert.Equal(Bob, drop.Ref);
    }

    [Fact]
    public void DroppingWhatIsAlreadyDroppedOrUnknownIsNoStep()
    {
        var tracker = MakeTracker();
        tracker.StageDrops([Alice], PrincipalDropOptions.None);

        tracker.StageDrops([Alice, new PrincipalRef("nobody")], PrincipalDropOptions.None);

        Assert.Equal(1, tracker.ChangeCount);
        tracker.Undo();
        Assert.False(tracker.CanUndo);
    }

    [Fact]
    public void OwnersKeepTheChosenDisposition()
    {
        var tracker = MakeTracker();
        var options = new PrincipalDropOptions(ReassignOwnedTo: Alice);

        tracker.StageDrops([Bob, Readers], options);

        Assert.All(tracker.PendingChanges().OfType<DropPrincipal>(), d => Assert.Equal(options, d.Options));
        Assert.Equal(2, tracker.PendingChanges().Count);
    }

    [Fact]
    public void GrantStateIsMixedWhenSomeObjectsHoldThePrivilege()
    {
        var tracker = MakeTracker();

        Assert.Null(tracker.GrantState("SELECT", [Orders, Items], Alice));
        Assert.False(tracker.GrantState("INSERT", [Orders, Items], Alice));
        Assert.True(tracker.GrantState("SELECT", [Orders], Alice));
    }

    [Fact]
    public void GrantingAcrossObjectsFillsTheMixedStateInOneStep()
    {
        var tracker = MakeTracker();

        tracker.SetGranted(true, ["SELECT", "INSERT"], [Orders, Items], Alice, "Grant on 2 objects");

        Assert.True(tracker.GrantState("SELECT", [Orders, Items], Alice));
        Assert.True(tracker.GrantState("INSERT", [Orders, Items], Alice));
        var changes = Assert.Single(tracker.GrantChanges());
        Assert.Equal(3, changes.Added.Count);
        Assert.Equal("Grant on 2 objects", tracker.UndoActionName);
    }

    [Fact]
    public void ASelectionAcrossLevelsIsMixed()
    {
        Assert.False(PrivilegeScope.IsMixedLevel([]));
        Assert.False(PrivilegeScope.IsMixedLevel([Orders, Items]));
        Assert.True(PrivilegeScope.IsMixedLevel([Orders, PrivilegeScope.ForSchema("app", "public")]));
        Assert.True(PrivilegeScope.IsMixedLevel([PrivilegeScope.Server, PrivilegeScope.ForDatabase("app")]));
    }
}
