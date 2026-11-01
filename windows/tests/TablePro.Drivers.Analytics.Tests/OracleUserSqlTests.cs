using TablePro.Core.Principals;
using TablePro.Drivers.Oracle;

namespace TablePro.Drivers.Analytics.Tests;

public sealed class OracleUserSqlTests
{
    private static readonly OracleUserSql Sql = new(new HashSet<string>(StringComparer.Ordinal) { "READERS", "APP_ROLE" });
    private static readonly PrincipalRef Scott = new("SCOTT");
    private static readonly PrivilegeScope Emp = PrivilegeScope.ForTable("HR", null, "EMP");

    [Fact]
    public void CreateUserIdentifiedByAQuotedPasswordAndGrantsItsRolesInOrder()
    {
        var definition = new PrincipalDefinition(Scott, "tiger 1", true, [], ["READERS", "APP_ROLE"]);

        Assert.Equal(
            ["CREATE USER \"SCOTT\" IDENTIFIED BY \"tiger 1\"", "GRANT \"APP_ROLE\" TO \"SCOTT\"", "GRANT \"READERS\" TO \"SCOTT\""],
            Sql.CreatePrincipal(definition));
    }

    [Fact]
    public void CreateRoleHasNoPassword()
    {
        Assert.Equal(["CREATE ROLE \"AUDITORS\""], Sql.CreatePrincipal(new PrincipalDefinition(new PrincipalRef("AUDITORS"), canLogin: false)));
    }

    [Fact]
    public void APasswordWithADoubleQuoteHasNoSpelling()
    {
        Assert.Null(Sql.CreatePrincipal(new PrincipalDefinition(Scott, "a\"b")));
        Assert.Null(Sql.CreatePrincipal(new PrincipalDefinition(Scott)));
        Assert.Null(Sql.SetPassword(Scott, "a\"b"));
    }

    [Fact]
    public void SetPasswordAltersTheUserButNotARole()
    {
        Assert.Equal(["ALTER USER \"SCOTT\" IDENTIFIED BY \"n3w\""], Sql.SetPassword(Scott, "n3w"));
        Assert.Null(Sql.SetPassword(new PrincipalRef("READERS"), "n3w"));
    }

    [Fact]
    public void AlterLocksTheAccountAndMovesMemberships()
    {
        var old = new PrincipalDefinition(Scott, null, true, [], ["READERS"]);
        var changed = old with { CanLogin = false, MemberOf = ["APP_ROLE"] };

        Assert.Equal(
            ["ALTER USER \"SCOTT\" ACCOUNT LOCK", "REVOKE \"READERS\" FROM \"SCOTT\"", "GRANT \"APP_ROLE\" TO \"SCOTT\""],
            Sql.AlterPrincipal(old, changed));
        Assert.Equal(["ALTER USER \"SCOTT\" ACCOUNT UNLOCK"], Sql.AlterPrincipal(changed with { MemberOf = ["READERS"] }, old));
    }

    [Fact]
    public void AlterCannotRenameOrLockARole()
    {
        var old = new PrincipalDefinition(Scott);
        Assert.Null(Sql.AlterPrincipal(old, old with { Ref = new PrincipalRef("ADAMS") }));

        var role = new PrincipalDefinition(new PrincipalRef("READERS"), null, canLogin: false);
        Assert.Null(Sql.AlterPrincipal(role, role with { CanLogin = true }));
    }

    [Fact]
    public void DropTellsUsersFromRolesWithoutCascade()
    {
        Assert.Equal(["DROP USER \"SCOTT\""], Sql.DropPrincipal(Scott, PrincipalDropOptions.None));
        Assert.Equal(["DROP ROLE \"READERS\""], Sql.DropPrincipal(new PrincipalRef("READERS"), PrincipalDropOptions.None));
    }

    [Fact]
    public void GrantSpellsSystemObjectAndColumnPrivilegesWithTheirOptions()
    {
        PrincipalGrant[] grants =
        [
            new("CREATE SESSION", PrivilegeScope.Server),
            new("SELECT ANY TABLE", PrivilegeScope.Server, IsGrantable: true),
            new("SELECT", Emp),
            new("INSERT", Emp),
            new("UPDATE", PrivilegeScope.ForColumn("HR", null, "EMP", "SAL")),
            new("DELETE", Emp, IsGrantable: true),
        ];

        Assert.Equal(
            [
                "GRANT CREATE SESSION TO \"SCOTT\"",
                "GRANT SELECT ANY TABLE TO \"SCOTT\" WITH ADMIN OPTION",
                "GRANT SELECT, INSERT, UPDATE (\"SAL\") ON \"HR\".\"EMP\" TO \"SCOTT\"",
                "GRANT DELETE ON \"HR\".\"EMP\" TO \"SCOTT\" WITH GRANT OPTION",
            ],
            Sql.Grant(Scott, grants));
    }

    [Fact]
    public void RevokeFoldsGrantOptionsAndRefusesColumns()
    {
        PrincipalGrant[] grants = [new("SELECT", Emp, IsGrantable: true), new("INSERT", Emp), new("CREATE SESSION", PrivilegeScope.Server)];

        Assert.Equal(["REVOKE SELECT, INSERT ON \"HR\".\"EMP\" FROM \"SCOTT\"", "REVOKE CREATE SESSION FROM \"SCOTT\""], Sql.Revoke(Scott, grants));
        Assert.Null(Sql.Revoke(Scott, [new PrincipalGrant("UPDATE", PrivilegeScope.ForColumn("HR", null, "EMP", "SAL"))]));
    }

    [Fact]
    public void ASchemaScopeHasNoOracleTargetAndAnUnsafePrivilegeIsDropped()
    {
        Assert.Null(Sql.Grant(Scott, [new PrincipalGrant("SELECT", PrivilegeScope.ForDatabase("HR"))]));
        Assert.Empty(Sql.Grant(Scott, [new PrincipalGrant("SELECT; DROP", Emp)])!);
    }

    [Fact]
    public void BuildRunsCreatesBeforeGrantsAndMarksPasswords()
    {
        var statements = PrincipalScript.Build(
            Sql,
            [
                new ModifyGrants(new PrincipalGrantChanges(Scott, [new PrincipalGrant("SELECT", Emp)], [])),
                new CreatePrincipal(new PrincipalDefinition(Scott, "tiger")),
            ]);

        Assert.Equal(["CREATE USER \"SCOTT\" IDENTIFIED BY \"tiger\"", "GRANT SELECT ON \"HR\".\"EMP\" TO \"SCOTT\""], statements.Select(s => s.Sql));
        Assert.True(statements[0].CarriesCredentials);
        Assert.False(statements[1].CarriesCredentials);
    }

    [Fact]
    public void PrincipalsListUsersThenRolesWithTheirRoles()
    {
        var principals = OracleUserCatalog.Principals(
            [("SCOTT", false), ("LOCKED", true), ("READERS", false)],
            ["READERS", "DBA"],
            [("SCOTT", "READERS"), ("SCOTT", "DBA"), ("READERS", "DBA"), ("SCOTT", "NOT_A_ROLE")]);

        Assert.Equal(["SCOTT", "LOCKED", "READERS", "DBA"], principals.Select(p => p.Ref.Name));
        Assert.Equal(["DBA", "READERS"], principals[0].MemberOf);
        Assert.False(principals[1].CanLogin);
        Assert.True(principals[2].IsRole);
        Assert.Equal(["DBA"], principals[2].MemberOf);
    }

    [Theory]
    [InlineData("LOCKED(TIMED)", true)]
    [InlineData("EXPIRED & LOCKED", true)]
    [InlineData("OPEN", false)]
    [InlineData(null, false)]
    public void AccountStatusReadsLocked(string? status, bool locked) => Assert.Equal(locked, OracleUserCatalog.IsLocked(status));

    [Fact]
    public void SystemPrivilegesAreGroupedByName()
    {
        Assert.Equal(PrivilegeCategoryKeys.Administration, OracleUserCatalog.SystemPrivilege("CREATE SESSION").Category);
        Assert.Equal(PrivilegeCategoryKeys.Structure, OracleUserCatalog.SystemPrivilege("CREATE TABLE").Category);
        Assert.Equal(PrivilegeCategoryKeys.Data, OracleUserCatalog.SystemPrivilege("SELECT ANY TABLE").Category);
        Assert.Equal(PrivilegeCategoryKeys.Administration, OracleUserCatalog.SystemPrivilege("AUDIT SYSTEM").Category);
    }

    [Fact]
    public void SearchPatternTakesWildcardsLiterally() =>
        Assert.Equal("%EMP\\_50\\%%", OracleUserCatalog.ContainsPattern(" emp_50% "));
}
