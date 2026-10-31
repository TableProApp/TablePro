using TablePro.Core.Principals;

namespace TablePro.Core.Tests.Principals;

public sealed class PrivilegeEffectivenessTests
{
    private static readonly PrivilegeScope Database = PrivilegeScope.ForDatabase("shop");
    private static readonly PrivilegeScope Table = PrivilegeScope.ForTable("shop", "public", "orders");
    private static readonly PrivilegeScope Column = PrivilegeScope.ForColumn("shop", "public", "orders", "id");

    private static readonly Func<PrivilegeScope, PrivilegeScope, bool> MySqlCascade = static (a, d) => a.Contains(d);
    private static readonly Func<PrivilegeScope, PrivilegeScope, bool> PostgreSqlCascade =
        static (a, d) => a.Level == PrivilegeLevel.Table && d.Level == PrivilegeLevel.Column && a.Contains(d);

    private static PrivilegeInheritanceContext Context(Func<PrivilegeScope, PrivilegeScope, bool> cascades, bool inherits = true, params (string Role, PrincipalGrantKey[] Grants)[] roles) =>
        new(
            roles.ToDictionary(r => new PrincipalRef(r.Role), r => (IReadOnlySet<PrincipalGrantKey>)r.Grants.ToHashSet()),
            roles.Select(r => r.Role).ToArray(),
            inherits,
            cascades);

    [Fact]
    public void ADirectGrantOutranksEverythingElse()
    {
        var direct = new HashSet<PrincipalGrantKey> { new("SELECT", Table), new("SELECT", Database) };

        Assert.Equal(PrivilegeEffectiveness.Direct, PrivilegeEffectivenessResolver.Resolve("SELECT", Table, direct, Context(MySqlCascade)));
    }

    [Fact]
    public void MySqlCarriesADatabaseGrantDownToATable()
    {
        var effect = PrivilegeEffectivenessResolver.Resolve("SELECT", Table, new HashSet<PrincipalGrantKey> { new("SELECT", Database) }, Context(MySqlCascade));

        Assert.Equal(EffectivenessKind.ViaScope, effect.Kind);
        Assert.Equal(Database, effect.Scope);
        Assert.Equal("Granted on shop", effect.Description);
    }

    [Fact]
    public void PostgreSqlCarriesOnlyATableGrantToItsColumns()
    {
        var databaseGrant = new HashSet<PrincipalGrantKey> { new("SELECT", Database) };
        var tableGrant = new HashSet<PrincipalGrantKey> { new("SELECT", Table) };

        Assert.False(PrivilegeEffectivenessResolver.Resolve("SELECT", Table, databaseGrant, Context(PostgreSqlCascade)).IsEffective);
        Assert.Equal(EffectivenessKind.ViaScope, PrivilegeEffectivenessResolver.Resolve("SELECT", Column, tableGrant, Context(PostgreSqlCascade)).Kind);
    }

    [Fact]
    public void ARoleGrantIsInherited()
    {
        var effect = PrivilegeEffectivenessResolver.Resolve("SELECT", Column, new HashSet<PrincipalGrantKey>(), Context(PostgreSqlCascade, true, ("readers", [new("SELECT", Table)])));

        Assert.Equal(EffectivenessKind.ViaRole, effect.Kind);
        Assert.Equal("Inherited from readers", effect.Description);
        Assert.Equal("Inherited automatically.", effect.Detail);
    }

    [Fact]
    public void ANoInheritPrincipalNeedsSetRole()
    {
        var effect = PrivilegeEffectivenessResolver.Resolve("SELECT", Table, new HashSet<PrincipalGrantKey>(), Context(PostgreSqlCascade, false, ("readers", [new("SELECT", Table)])));

        Assert.Equal("Available after SET ROLE readers.", effect.Detail);
    }

    [Fact]
    public void RoleClosureIsTransitiveAndSurvivesACycle()
    {
        var principals = new[]
        {
            new PrincipalInfo(new PrincipalRef("app"), false, true, [], ["a"]),
            new PrincipalInfo(new PrincipalRef("a"), true, false, [], ["b"]),
            new PrincipalInfo(new PrincipalRef("b"), true, false, [], ["a", "app"]),
        };

        Assert.Equal(["a", "b"], PrivilegeEffectivenessResolver.RoleClosure(new PrincipalRef("app"), principals));
    }

    [Fact]
    public void TrackerResolvesThroughLoadedRoleGrants()
    {
        var tracker = new PrincipalChangeTracker { Cascades = PostgreSqlCascade };
        tracker.Load(
            [new PrincipalInfo(new PrincipalRef("app"), false, true, [new PrincipalAttribute("INHERIT", "Inherit", false)], ["readers"]), new PrincipalInfo(new PrincipalRef("readers"), true, false)],
            PrivilegeCatalog.Empty);
        tracker.LoadGrants(new PrincipalRef("app"), []);
        Assert.False(tracker.Effectiveness("SELECT", Table, new PrincipalRef("app")).IsEffective);

        tracker.LoadGrants(new PrincipalRef("readers"), [new PrincipalGrant("SELECT", Table)]);
        var effect = tracker.Effectiveness("SELECT", Column, new PrincipalRef("app"));
        Assert.Equal(EffectivenessKind.ViaRole, effect.Kind);
        Assert.False(effect.InheritsAutomatically);
    }

    [Fact]
    public void ABrowsingRestrictedDatabaseIsNeverShownAsEmpty()
    {
        var summary = ScopeSummary.Make([], [new("CONNECT", "Connect")], 0, false, isBrowsingRestricted: true);

        Assert.IsType<ScopeSummary.BrowsingRestricted>(summary);
        Assert.Equal("Connect to this database to browse it", summary.Text);
    }

    [Fact]
    public void EveryGrantablePrivilegeCollapsesToAll()
    {
        Assert.Equal("All (2)", ScopeSummary.Make(["A", "B"], [new("A", "A"), new("B", "B")], 0, false, false).Text);
    }

    [Fact]
    public void SomeGrantedListsTheFirstNamesAndCountsTheRest()
    {
        var summary = ScopeSummary.Make(["C", "A", "B"], [new("A", "A"), new("B", "B"), new("C", "C"), new("D", "D")], 0, true, false);

        Assert.Equal("A, B +1 (grantable)", summary.Text);
    }

    [Fact]
    public void DescendantGrantsShowWhenTheScopeHasNone()
    {
        Assert.Equal("3 grants inside", ScopeSummary.Make([], [new("A", "A")], 3, false, false).Text);
        Assert.Equal("1 grant inside", ScopeSummary.Make([], [], 1, false, false).Text);
    }

    [Fact]
    public void NothingGrantableDiffersFromNothingGranted()
    {
        Assert.IsType<ScopeSummary.NotGrantable>(ScopeSummary.Make([], [], 0, false, false));
        Assert.IsType<ScopeSummary.NoneGranted>(ScopeSummary.Make([], [new("A", "A")], 0, false, false));
    }

    [Fact]
    public void CategoriesSortInAFixedOrderAndUnknownKeysShowVerbatim()
    {
        var sections = PrivilegeSection.Group(
        [
            new("SUPER", "Super", PrivilegeCategoryKeys.Administration),
            new("SELECT", "Select", PrivilegeCategoryKeys.Data),
            new("X", "X", "custom"),
            new("Y", "Y"),
            new("CREATE", "Create", PrivilegeCategoryKeys.Structure),
            new("INSERT", "Insert", PrivilegeCategoryKeys.Data),
        ]);

        Assert.Equal(["Data", "Structure", "Administration", "Other", "custom"], sections.Select(s => s.Category.Title));
        Assert.Equal(["SELECT", "INSERT"], sections[0].Privileges.Select(p => p.Name));
        Assert.True(sections[2].Category.IsCollapsedByDefault);
        Assert.False(sections[0].Category.IsCollapsedByDefault);
    }

    [Fact]
    public void FilteringKeepsMatchingPrivilegesAndDropsEmptySections()
    {
        var sections = PrivilegeSection.Group([new("SELECT", "Select", PrivilegeCategoryKeys.Data), new("CREATE", "Create", PrivilegeCategoryKeys.Structure)]);

        var filtered = PrivilegeSection.Filter(sections, "sel");
        Assert.Equal("SELECT", Assert.Single(Assert.Single(filtered).Privileges).Name);
        Assert.Same(sections, PrivilegeSection.Filter(sections, "  "));
    }

    [Fact]
    public void GeneratedPasswordsUseTheUnambiguousAlphabet()
    {
        var password = PasswordGenerator.Generate();

        Assert.Equal(PasswordGenerator.DefaultLength, password.Length);
        Assert.DoesNotContain(password, c => c is '0' or 'O' or '1' or 'l' or 'I' or '\'' or '"');
        Assert.NotEqual(password, PasswordGenerator.Generate());
        Assert.Equal(string.Empty, PasswordGenerator.Generate(0));
    }
}
