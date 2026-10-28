using TablePro.Core.Principals;
using TablePro.Drivers.SqlServer;

namespace TablePro.Drivers.Tests;

public sealed class SqlServerUserSqlTests
{
    private const string EnsureFresh =
        "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'fresh' AND sid = SUSER_SID(N'fresh')) CREATE USER [fresh] FOR LOGIN [fresh]";

    private static readonly SqlServerPrincipalDirectory Directory = new(
        "Sales",
        [new("sa", false, "dbo"), new("app", false, "app"), new("CORP\\bob", false, "bob"), new("fresh", false, null)],
        ["sysadmin", "auditors"],
        [new("db_datareader", true, false), new("readers", true, false), new("guest", false, false)],
        [new("app", "auditors")],
        [new("app", "readers"), new("bob", "readers")]);

    private static readonly SqlServerUserSql Sql = new(Directory);

    private static string InSales(string statement) => SqlServerUserSql.InDatabase("Sales", statement);

    [Fact]
    public void DirectoryMergesLoginsWithTheirUsersAndMapsMemberships()
    {
        Assert.Equal(["sa", "app", "CORP\\bob", "fresh", "sysadmin", "auditors", "db_datareader", "readers", "guest"], Directory.Entries.Select(e => e.Name));
        Assert.Equal(["auditors", "readers"], Directory.Entry("app")!.MemberOf);
        Assert.Equal(["readers"], Directory.Entry("CORP\\bob")!.MemberOf);
        Assert.Equal(SqlServerPrincipalKind.DatabaseUser, Directory.Entry("guest")!.Kind);
        Assert.False(Directory.Entry("guest")!.IsEnabled);
        Assert.Equal(["app", "CORP\\bob"], Directory.MembersOf("readers"));
    }

    [Fact]
    public void ANameUsedTwiceKeepsTheLogin()
    {
        var directory = new SqlServerPrincipalDirectory("db", [new("dup", false, null)], [], [new("dup", true, false)], [], []);

        Assert.Equal(SqlServerPrincipalKind.Login, Assert.Single(directory.Entries).Kind);
    }

    [Fact]
    public void CreateUserMakesALoginAndItsUser()
    {
        Assert.Equal(
            ["CREATE LOGIN [carol] WITH PASSWORD = N'pa''ss'", InSales("CREATE USER [carol] FOR LOGIN [carol]")],
            Sql.CreatePrincipal(new PrincipalDefinition(new PrincipalRef("carol"), "pa'ss")));
    }

    [Fact]
    public void CreateUserWithoutPasswordIsRefused()
    {
        Assert.Null(Sql.Create("carol", null, canLogin: true, []));
        Assert.Null(Sql.Create("carol", string.Empty, canLogin: true, []));
    }

    [Fact]
    public void CreateRoleIsADatabaseRole()
    {
        Assert.Equal(
            [InSales("CREATE ROLE [writers]"), InSales("ALTER ROLE [db_datareader] ADD MEMBER [writers]")],
            Sql.Create("writers", null, canLogin: false, ["db_datareader"]));
    }

    [Fact]
    public void CreatedUserJoinsServerAndDatabaseRoles()
    {
        var sql = Sql.Create("carol", "x", canLogin: true, ["sysadmin", "readers"]);

        Assert.Equal([InSales("ALTER ROLE [readers] ADD MEMBER [carol]"), "ALTER SERVER ROLE [sysadmin] ADD MEMBER [carol]"], sql![^2..]);
    }

    [Fact]
    public void DatabaseRoleCannotJoinAServerRole()
    {
        Assert.Null(Sql.Create("writers", null, canLogin: false, ["sysadmin"]));
    }

    [Fact]
    public void CanLogInTogglesTheLoginOrTheConnectPermission()
    {
        Assert.Equal(["ALTER LOGIN [app] DISABLE"], Sql.Alter("app", true, false, [], []));
        Assert.Equal(["ALTER LOGIN [app] ENABLE"], Sql.Alter("app", false, true, [], []));
        Assert.Equal([InSales("GRANT CONNECT TO [guest]")], Sql.Alter("guest", false, true, [], []));
        Assert.Equal([InSales("REVOKE CONNECT FROM [guest]")], Sql.Alter("guest", true, false, [], []));
        Assert.Null(Sql.Alter("readers", false, true, [], []));
    }

    [Fact]
    public void MembershipUsesTheMappedUserOrTheLogin()
    {
        Assert.Equal([InSales("ALTER ROLE [readers] ADD MEMBER [dbo]")], Sql.Alter("sa", true, true, [], ["readers"]));
        Assert.Equal(
            ["ALTER SERVER ROLE [auditors] DROP MEMBER [app]", "ALTER SERVER ROLE [sysadmin] ADD MEMBER [app]"],
            Sql.Alter("app", true, true, ["auditors"], ["sysadmin"]));
    }

    [Fact]
    public void LoginWithoutAUserGetsOneBeforeJoiningADatabaseRole()
    {
        Assert.Equal(
            [InSales(EnsureFresh), InSales("ALTER ROLE [db_datareader] ADD MEMBER [fresh]"), InSales("ALTER ROLE [readers] ADD MEMBER [fresh]")],
            Sql.Alter("fresh", true, true, [], ["db_datareader", "readers"]));
    }

    [Fact]
    public void RenameIsRefused()
    {
        Assert.Null(Sql.AlterPrincipal(new PrincipalDefinition(new PrincipalRef("app")), new PrincipalDefinition(new PrincipalRef("svc"))));
    }

    [Fact]
    public void PasswordGoesToTheLoginOrTheContainedUser()
    {
        Assert.Equal(["ALTER LOGIN [app] WITH PASSWORD = N'n''ew'"], Sql.SetPassword(new PrincipalRef("app"), "n'ew"));
        Assert.Equal([InSales("ALTER USER [guest] WITH PASSWORD = N'x'")], Sql.SetPassword(new PrincipalRef("guest"), "x"));
        Assert.Null(Sql.SetPassword(new PrincipalRef("readers"), "x"));
    }

    [Fact]
    public void DropLoginDropsItsUserFirst()
    {
        Assert.Equal([InSales("DROP USER [bob]"), "DROP LOGIN [CORP\\bob]"], Sql.Drop("CORP\\bob"));
        Assert.Equal(["DROP LOGIN [fresh]"], Sql.Drop("fresh"));
    }

    [Fact]
    public void DropRoleEmptiesItFirst()
    {
        Assert.Equal(
            [
                InSales("IF DATABASE_PRINCIPAL_ID(N'app') IS NOT NULL ALTER ROLE [readers] DROP MEMBER [app]"),
                InSales("IF DATABASE_PRINCIPAL_ID(N'bob') IS NOT NULL ALTER ROLE [readers] DROP MEMBER [bob]"),
                InSales("DROP ROLE [readers]"),
            ],
            Sql.Drop("readers"));
        Assert.Equal(
            ["IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'app') ALTER SERVER ROLE [auditors] DROP MEMBER [app]", "DROP SERVER ROLE [auditors]"],
            Sql.Drop("auditors"));
        Assert.Equal([InSales("DROP USER [guest]")], Sql.Drop("guest"));
    }

    [Fact]
    public void DropOfAnUnknownNameIsRefused()
    {
        Assert.Null(Sql.Drop("nobody"));
        Assert.Null(new SqlServerUserSql(null).Drop("app"));
    }

    [Fact]
    public void ServerPermissionsRunInMaster()
    {
        Assert.Equal(
            ["EXEC [master].sys.sp_executesql N'GRANT VIEW SERVER STATE TO [app]'"],
            Sql.Grant(new PrincipalRef("app"), [new PrincipalGrant("VIEW SERVER STATE", PrivilegeScope.Server)]));
        Assert.Equal(
            ["EXEC [master].sys.sp_executesql N'GRANT CONNECT SQL TO [o''brien]'"],
            new SqlServerUserSql(null).Grant(new PrincipalRef("o'brien"), [new PrincipalGrant("CONNECT SQL", PrivilegeScope.Server)]));
    }

    [Fact]
    public void PermissionsAtTheWrongLevelAreRefused()
    {
        Assert.Null(Sql.Grant(new PrincipalRef("readers"), [new PrincipalGrant("SHUTDOWN", PrivilegeScope.Server)]));
        Assert.Null(Sql.Grant(new PrincipalRef("sysadmin"), [new PrincipalGrant("SELECT", PrivilegeScope.ForDatabase("Sales"))]));
    }

    [Fact]
    public void AScopeInAnotherDatabaseIsRefused()
    {
        Assert.Null(Sql.Grant(new PrincipalRef("app"), [new PrincipalGrant("SELECT", PrivilegeScope.ForSchema("Other", "dbo"))]));
    }

    [Fact]
    public void PermissionsAreGroupedPerSecurable()
    {
        var grants = new[]
        {
            new PrincipalGrant("CREATE TABLE", PrivilegeScope.ForDatabase("Sales")),
            new PrincipalGrant("SELECT", PrivilegeScope.ForSchema("Sales", "dbo")),
            new PrincipalGrant("INSERT", PrivilegeScope.ForSchema("Sales", "dbo")),
            new PrincipalGrant("SELECT", PrivilegeScope.ForColumn("Sales", "dbo", "Orders", "id")),
            new PrincipalGrant("SELECT", PrivilegeScope.ForColumn("Sales", "dbo", "Orders", "total")),
            new PrincipalGrant("DELETE", PrivilegeScope.ForTable("Sales", "dbo", "Orders")),
        };

        Assert.Equal(
            [
                InSales("GRANT CREATE TABLE TO [dbo]"),
                InSales("GRANT SELECT, INSERT ON SCHEMA::[dbo] TO [dbo]"),
                InSales("GRANT DELETE, SELECT ([id], [total]) ON OBJECT::[dbo].[Orders] TO [dbo]"),
            ],
            Sql.Grant(new PrincipalRef("sa"), grants));
    }

    [Fact]
    public void DatabasePermissionForALoginWithoutAUserCreatesTheUserOnce()
    {
        Assert.Equal(
            [InSales(EnsureFresh), InSales("GRANT CONNECT TO [fresh]"), InSales("GRANT SELECT ON SCHEMA::[dbo] TO [fresh]")],
            Sql.Grant(new PrincipalRef("fresh"), [new PrincipalGrant("CONNECT", PrivilegeScope.ForDatabase("Sales")), new PrincipalGrant("SELECT", PrivilegeScope.ForSchema("Sales", "dbo"))]));
    }

    [Fact]
    public void RevokingAGrantableGrantCascades()
    {
        Assert.Equal(
            [InSales("REVOKE SELECT ON OBJECT::[dbo].[T] FROM [app] CASCADE"), InSales("REVOKE UPDATE ON OBJECT::[dbo].[T] FROM [app]")],
            Sql.Revoke(
                new PrincipalRef("app"),
                [new PrincipalGrant("SELECT", PrivilegeScope.ForTable("Sales", "dbo", "T"), IsGrantable: true), new PrincipalGrant("UPDATE", PrivilegeScope.ForTable("Sales", "dbo", "T"))]));
    }

    [Fact]
    public void GrantOptionIsKept()
    {
        Assert.Equal(
            [InSales("GRANT SELECT ON SCHEMA::[dbo] TO [readers] WITH GRANT OPTION")],
            Sql.Grant(new PrincipalRef("readers"), [new PrincipalGrant("SELECT", PrivilegeScope.ForSchema("Sales", "dbo"), IsGrantable: true)]));
    }

    [Fact]
    public void IdentifiersAndPermissionsAreEscaped()
    {
        Assert.Equal(
            [InSales("GRANT SELECT ON OBJECT::[d]]bo].[a]]] TO [we]]ird]")],
            Sql.Grant(
                new PrincipalRef("we]ird"),
                [new PrincipalGrant("SELECT; DROP TABLE x", PrivilegeScope.ForDatabase("Sales")), new PrincipalGrant("select", PrivilegeScope.ForTable("Sales", "d]bo", "a]"))]));
    }

    [Fact]
    public void ColumnPermissionOutsideAnObjectIsRefused()
    {
        Assert.Null(Sql.GrantStatements([new SqlServerGrant("SELECT", SqlServerSecurable.Database, "c")], "app"));
    }

    [Fact]
    public void StatementsRunInTheListedDatabase()
    {
        Assert.Equal("EXEC [Sales].sys.sp_executesql N'GRANT SELECT TO [x]'", InSales("GRANT SELECT TO [x]"));
        Assert.Equal("EXEC [we]]ird].sys.sp_executesql N'SELECT ''a'''", SqlServerUserSql.InDatabase("we]ird", "SELECT 'a'"));
        Assert.Equal(
            ["GRANT SELECT ON SCHEMA::[dbo] TO [app]"],
            new SqlServerUserSql(null).Grant(new PrincipalRef("app"), [new PrincipalGrant("SELECT", PrivilegeScope.ForSchema("Sales", "dbo"))]));
    }

    [Fact]
    public void CatalogOrdersDataPermissionsFirstAndDropsModulePermissionsFromObjects()
    {
        var catalog = SqlServerUserCatalog.BuildCatalog(
        [
            ("OBJECT", "UPDATE"), ("OBJECT", "SELECT"), ("OBJECT", "EXECUTE"), ("OBJECT", "ALTER"), ("OBJECT", "RECEIVE"),
            ("DATABASE", "CREATE TABLE"), ("DATABASE", "CONNECT"), ("SERVER", "VIEW SERVER STATE"), ("SCHEMA", "SELECT"), ("SCHEMA", "SELECT"),
        ]);

        Assert.Equal(["SELECT", "UPDATE", "ALTER"], catalog.Table.Select(d => d.Name));
        Assert.Equal(["CONNECT", "CREATE TABLE"], catalog.Database.Select(d => d.Name));
        Assert.Equal(["SELECT"], catalog.Schema.Select(d => d.Name));
        Assert.Equal(["SELECT", "UPDATE", "REFERENCES"], catalog.Column.Select(d => d.Name));
        Assert.Equal(PrivilegeCategoryKeys.Structure, SqlServerUserCatalog.Category("CREATE TABLE"));
        Assert.Equal(PrivilegeCategoryKeys.Administration, SqlServerUserCatalog.Category("CONNECT"));
    }

    [Fact]
    public void PermissionRowsBecomeGrantsOnTheListedDatabase()
    {
        Assert.Equal(new PrincipalGrant("CONNECT", PrivilegeScope.ForDatabase("Sales"), true), SqlServerUserCatalog.DatabaseGrant("Sales", 0, "CONNECT", "W", null, null, null));
        Assert.Equal(new PrincipalGrant("SELECT", PrivilegeScope.ForColumn("Sales", "dbo", "T", "c")), SqlServerUserCatalog.DatabaseGrant("Sales", 1, "SELECT", "G", "dbo", "T", "c"));
        Assert.Null(SqlServerUserCatalog.DatabaseGrant("Sales", 25, "SELECT", "G", null, null, null));
    }

    [Fact]
    public void SearchPatternEscapesTheCharacterClassBracket()
    {
        Assert.Equal("%a\\[b\\_%", SqlServerUserCatalog.ContainsPattern("a[b_"));
    }
}
