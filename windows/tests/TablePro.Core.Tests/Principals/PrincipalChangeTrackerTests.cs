using TablePro.Core.Principals;

namespace TablePro.Core.Tests.Principals;

public sealed class PrincipalChangeTrackerTests
{
    private static readonly PrincipalRef Alice = new("alice");
    private static readonly PrincipalRef Bob = new("bob");
    private static readonly PrivilegeScope App = PrivilegeScope.ForDatabase("app");
    private static readonly PrivilegeScope Orders = PrivilegeScope.ForTable("app", "public", "orders");

    private static PrincipalChangeTracker MakeTracker()
    {
        var tracker = new PrincipalChangeTracker();
        tracker.Load(
            [
                new PrincipalInfo(Alice, false, true, [new PrincipalAttribute("CREATEDB", "Create databases", false)], [], 10),
                new PrincipalInfo(Bob, false, true, [], ["readers"]),
                new PrincipalInfo(new PrincipalRef("readers"), isRole: true, canLogin: false),
            ],
            new PrivilegeCatalog([], [new("CONNECT", "Connect"), new("CREATE", "Create")], [], [new("SELECT", "Select"), new("INSERT", "Insert")], []));
        tracker.LoadGrants(Alice, [new PrincipalGrant("CONNECT", App, IsGrantable: true)]);
        tracker.LoadGrants(Bob, []);
        return tracker;
    }

    [Fact]
    public void AFreshLoadHasNoChanges()
    {
        var tracker = MakeTracker();

        Assert.False(tracker.HasChanges);
        Assert.Empty(tracker.PendingChanges());
        Assert.All(tracker.Rows(), r => Assert.Equal(PrincipalStage.Unchanged, r.Stage));
    }

    [Fact]
    public void GrantingAddsAndRevokingRemoves()
    {
        var tracker = MakeTracker();
        tracker.SetGranted(true, ["CREATE"], [App], Alice);
        tracker.SetGranted(false, ["CONNECT"], [App], Alice);

        var changes = Assert.Single(tracker.GrantChanges());
        Assert.Equal([new PrincipalGrant("CREATE", App)], changes.Added);
        Assert.Equal("CONNECT", Assert.Single(changes.Removed).Privilege);
        Assert.Equal(2, tracker.ChangeCount);
        Assert.Equal(PrincipalStage.Modified, tracker.Stage(Alice));
        Assert.True(tracker.IsStaged("CREATE", App, Alice));
    }

    [Fact]
    public void TogglingBackToTheServerStateIsNoChange()
    {
        var tracker = MakeTracker();
        tracker.SetGranted(false, ["CONNECT"], [App], Alice);
        tracker.SetGranted(true, ["CONNECT"], [App], Alice);

        Assert.Empty(tracker.GrantChanges());
        Assert.Equal(0, tracker.ChangeCount);
        Assert.True(tracker.IsGrantable("CONNECT", App, Alice));
    }

    [Fact]
    public void ARevokeCarriesTheGrantOptionFromTheServer()
    {
        var tracker = MakeTracker();
        tracker.SetGranted(false, ["CONNECT"], [App], Alice);

        Assert.True(tracker.GrantChanges()[0].Removed[0].IsGrantable);
    }

    [Fact]
    public void ABulkGrantIsOneUndoStep()
    {
        var tracker = MakeTracker();
        tracker.SetGranted(true, ["SELECT", "INSERT"], [Orders, PrivilegeScope.ForTable("app", "public", "items")], Bob, "Grant 2 privileges");

        Assert.Equal(4, tracker.ChangeCount);
        Assert.Equal("Grant 2 privileges", tracker.UndoActionName);
        tracker.Undo();
        Assert.Equal(0, tracker.ChangeCount);
        Assert.False(tracker.CanUndo);
        tracker.Redo();
        Assert.Equal(4, tracker.ChangeCount);
    }

    [Fact]
    public void EachEditIsItsOwnUndoStepAndANewEditClearsRedo()
    {
        var tracker = MakeTracker();
        tracker.SetGranted(true, ["SELECT"], [Orders], Bob);
        tracker.SetGranted(true, ["INSERT"], [Orders], Bob);
        tracker.Undo();

        Assert.True(tracker.IsGranted("SELECT", Orders, Bob));
        Assert.False(tracker.IsGranted("INSERT", Orders, Bob));
        Assert.True(tracker.CanRedo);

        tracker.StageDrop(Alice, PrincipalDropOptions.None);
        Assert.False(tracker.CanRedo);
    }

    [Fact]
    public void ReloadKeepsUnsatisfiedIntentAndRefetchesGrants()
    {
        var tracker = MakeTracker();
        tracker.SetGranted(true, ["CREATE"], [App], Alice);
        tracker.Reload(tracker.Principals, tracker.Catalog);

        Assert.False(tracker.HasLoadedGrants(Alice));
        tracker.LoadGrants(Alice, [new PrincipalGrant("CONNECT", App)]);
        Assert.Equal([new PrincipalGrant("CREATE", App)], tracker.GrantChanges()[0].Added);

        // The server now has what was staged, so the intent is satisfied.
        tracker.LoadGrants(Alice, [new PrincipalGrant("CONNECT", App), new PrincipalGrant("CREATE", App)]);
        Assert.Empty(tracker.GrantChanges());
        Assert.Equal(0, tracker.ChangeCount);
    }

    [Fact]
    public void ReloadDropsEditsForPrincipalsThatAreGoneAndFinishedCreates()
    {
        var tracker = MakeTracker();
        tracker.StageCreate(new PrincipalDefinition(new PrincipalRef("carol"), "pw"));
        tracker.StageCreate(new PrincipalDefinition(new PrincipalRef("dave"), "pw"));
        tracker.SetGranted(true, ["SELECT"], [Orders], Bob);

        tracker.Reload([new PrincipalInfo(Alice), new PrincipalInfo(new PrincipalRef("carol"))], tracker.Catalog);

        Assert.Equal([new PrincipalRef("dave")], tracker.PendingCreates.Select(c => c.Ref));
        Assert.Empty(tracker.GrantChanges());
        Assert.True(tracker.HasLoadedGrants(new PrincipalRef("dave")));
    }

    [Fact]
    public void AnAttributeEditOnAStagedCreateFoldsIntoItAndKeepsThePassword()
    {
        var tracker = MakeTracker();
        var carol = new PrincipalRef("carol");
        tracker.StageCreate(new PrincipalDefinition(carol, "secret"));
        tracker.StageAlter(carol, new PrincipalDefinition(carol) with { ConnectionLimit = 4 });

        var create = Assert.IsType<CreatePrincipal>(Assert.Single(tracker.PendingChanges()));
        Assert.Equal(4, create.Definition.ConnectionLimit);
        Assert.Equal("secret", create.Definition.Password);
        Assert.Equal(1, tracker.ChangeCount);
    }

    [Fact]
    public void RemovingAStagedCreateTakesItsGrantsAndPasswordAndUndoBringsThemBack()
    {
        var tracker = MakeTracker();
        var carol = new PrincipalRef("carol");
        tracker.StageCreate(new PrincipalDefinition(carol, "pw"));
        tracker.SetGranted(true, ["CONNECT"], [App], carol);
        tracker.StageSetPassword(carol, "other");
        Assert.Equal(3, tracker.ChangeCount);

        tracker.UnstageCreate(carol);
        Assert.Equal(0, tracker.ChangeCount);
        Assert.DoesNotContain(tracker.Rows(), r => r.Ref == carol);

        tracker.Undo();
        Assert.Equal(3, tracker.ChangeCount);
        Assert.True(tracker.IsGranted("CONNECT", App, carol));
        Assert.Equal(PrincipalStage.Created, tracker.Stage(carol));
    }

    [Fact]
    public void ANoOpAlterIsNeverStaged()
    {
        var tracker = MakeTracker();
        tracker.StageAlter(Alice, tracker.Draft(Alice)!);

        Assert.False(tracker.HasChanges);
        Assert.False(tracker.CanUndo);
    }

    [Fact]
    public void AnAlterEditedBackToTheServerStateIsUnstaged()
    {
        var tracker = MakeTracker();
        var original = tracker.Draft(Alice)!;
        tracker.StageAlter(Alice, original with { ConnectionLimit = 2 });
        Assert.Equal(1, tracker.ChangeCount);

        tracker.StageAlter(Alice, original with { MemberOf = [] });
        Assert.Equal(0, tracker.ChangeCount);
    }

    [Fact]
    public void ARealAlterReachesTheChangeList()
    {
        var tracker = MakeTracker();
        tracker.StageAlter(Alice, tracker.Draft(Alice)! with { Attributes = [new PrincipalAttribute("CREATEDB", "Create databases", true)] });

        var alter = Assert.IsType<AlterPrincipal>(Assert.Single(tracker.PendingChanges()));
        Assert.False(alter.Old.Attributes[0].IsEnabled);
        Assert.True(alter.New.Attributes[0].IsEnabled);
    }

    [Fact]
    public void ARenameMakesLaterChangesNameTheNewPrincipal()
    {
        var tracker = MakeTracker();
        var renamed = new PrincipalRef("alicia");
        tracker.StageAlter(Alice, tracker.Draft(Alice)! with { Ref = renamed });
        tracker.StageSetPassword(Alice, "pw");
        tracker.SetGranted(true, ["CREATE"], [App], Alice);

        var changes = tracker.PendingChanges();
        Assert.Equal(Alice, Assert.IsType<AlterPrincipal>(changes[0]).Principal);
        Assert.Equal(renamed, Assert.IsType<SetPrincipalPassword>(changes[1]).Ref);
        Assert.Equal(renamed, Assert.IsType<ModifyGrants>(changes[2]).Principal);
    }

    [Fact]
    public void ADroppedPrincipalTakesItsOtherEditsWithIt()
    {
        var tracker = MakeTracker();
        tracker.StageAlter(Alice, tracker.Draft(Alice)! with { ConnectionLimit = 1 });
        tracker.SetGranted(true, ["CREATE"], [App], Alice);
        tracker.StageSetPassword(Alice, "pw");
        tracker.StageDrop(Alice, PrincipalDropOptions.None);

        Assert.IsType<DropPrincipal>(Assert.Single(tracker.PendingChanges()));
        Assert.Equal(PrincipalStage.Dropped, tracker.Stage(Alice));

        tracker.UnstageDrop(Alice);
        Assert.Equal(3, tracker.PendingChanges().Count);
    }

    [Fact]
    public void CopyingPrivilegesStagesWhatTheTargetLacks()
    {
        var tracker = MakeTracker();
        tracker.CopyGrants(Alice, Bob);

        Assert.True(tracker.IsGranted("CONNECT", App, Bob));
        Assert.Equal("Copy Privileges from alice", tracker.UndoActionName);
        Assert.Equal([new PrincipalGrant("CONNECT", App)], tracker.GrantChanges()[0].Added);
    }

    [Fact]
    public void SelfImpactWarnsAboutTheConnectedAccount()
    {
        var tracker = MakeTracker();
        Assert.Null(tracker.SelfImpact(new PrincipalRef("ALICE")));

        tracker.SetGranted(false, ["CONNECT"], [App], Alice);
        Assert.Contains("revoke every privilege", tracker.SelfImpact(new PrincipalRef("ALICE")), StringComparison.Ordinal);

        tracker.StageDrop(Alice, PrincipalDropOptions.None);
        Assert.Contains("drop alice", tracker.SelfImpact(new PrincipalRef("alice")), StringComparison.Ordinal);
        Assert.Null(tracker.SelfImpact(null));
    }

    [Fact]
    public void GrantedScopeClosureIncludesEveryAncestor()
    {
        var tracker = MakeTracker();
        var column = PrivilegeScope.ForColumn("app", "public", "orders", "id");
        tracker.SetGranted(true, ["SELECT"], [column], Bob);

        var closure = tracker.GrantedScopeClosure(Bob);
        Assert.Equal(5, closure.Count);
        Assert.Contains(PrivilegeScope.Server, closure);
        Assert.Contains(PrivilegeScope.ForSchema("app", "public"), closure);
        Assert.Equal(1, tracker.DescendantGrantCount(App, Bob));
    }

    [Fact]
    public void DiscardRestoresTheLoadedState()
    {
        var tracker = MakeTracker();
        tracker.SetGranted(true, ["CREATE"], [App], Alice);
        tracker.StageCreate(new PrincipalDefinition(new PrincipalRef("carol"), "pw"));
        tracker.Discard();

        Assert.False(tracker.HasChanges);
        Assert.False(tracker.CanUndo);
        Assert.Equal(3, tracker.Rows().Count);
    }

    [Fact]
    public void ChangedFiresOnEveryEdit()
    {
        var tracker = MakeTracker();
        var count = 0;
        tracker.Changed += (_, _) => count++;
        tracker.SetGranted(true, ["CREATE"], [App], Alice);
        tracker.Undo();

        Assert.Equal(2, count);
    }

    [Fact]
    public void ADuplicateCreateIsIgnored()
    {
        var tracker = MakeTracker();
        tracker.StageCreate(new PrincipalDefinition(Alice, "pw"));

        Assert.False(tracker.HasChanges);
    }

    [Fact]
    public void CreatedPrincipalsAppearAsRowsAndRolesWhenTheyCannotLogIn()
    {
        var tracker = MakeTracker();
        tracker.StageCreate(new PrincipalDefinition(new PrincipalRef("writers"), canLogin: false));

        var row = tracker.Rows()[^1];
        Assert.Equal(PrincipalStage.Created, row.Stage);
        Assert.True(row.Info.IsRole);
        Assert.Equal("Will be created when you apply changes", row.StageDescription);
    }

    [Fact]
    public void ScriptOrdersChangesAndMasksPasswordsOnRequest()
    {
        var tracker = MakeTracker();
        tracker.StageDrop(Bob, PrincipalDropOptions.None);
        tracker.StageCreate(new PrincipalDefinition(new PrincipalRef("carol"), "secret"));
        tracker.StageSetPassword(Alice, "pw");

        var masked = tracker.PendingChanges().Select(c => c.MaskingPassword(PrincipalScript.PasswordPlaceholder)).ToArray();
        var statements = PrincipalScript.Build(new EchoGenerator(), masked);

        Assert.Equal(["create carol <password>", "password alice <password>", "drop bob"], statements.Select(s => s.Sql));
        Assert.True(statements[0].CarriesCredentials);
        Assert.True(statements[2].IsDestructive);
    }

    [Fact]
    public void AChangeTheEngineCannotExpressStopsTheScript()
    {
        var tracker = MakeTracker();
        tracker.StageSetPassword(new PrincipalRef("readers"), "x");

        Assert.Throws<UnsupportedPrincipalChangeException>(() => PrincipalScript.Build(new EchoGenerator(), tracker.PendingChanges()));
    }

    private sealed class EchoGenerator : IPrincipalSqlGenerator
    {
        public IReadOnlyList<string>? CreatePrincipal(PrincipalDefinition definition) => [$"create {definition.Ref} {definition.Password}"];

        public IReadOnlyList<string>? AlterPrincipal(PrincipalDefinition old, PrincipalDefinition changed) => [];

        public IReadOnlyList<string>? SetPassword(PrincipalRef principal, string password) => principal.Name == "readers" ? null : [$"password {principal} {password}"];

        public IReadOnlyList<string>? DropPrincipal(PrincipalRef principal, PrincipalDropOptions options) => [$"drop {principal}"];

        public IReadOnlyList<string>? Grant(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants) => [$"grant {principal}"];

        public IReadOnlyList<string>? Revoke(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants) => [$"revoke {principal}"];
    }
}
