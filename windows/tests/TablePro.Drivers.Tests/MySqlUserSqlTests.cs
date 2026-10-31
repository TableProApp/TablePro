using TablePro.Core.Connections;
using TablePro.Core.Principals;
using TablePro.Drivers.MySql;

namespace TablePro.Drivers.Tests;

public sealed class MySqlUserSqlTests
{
    private static readonly MySqlUserSql Modern = new();
    private static readonly MySqlUserSql Legacy = new(MySqlAccountSyntax.GrantUsage);
    private static readonly PrincipalRef App = new("app", "%");

    [Fact]
    public void AccountQuotesUserAndHost()
    {
        Assert.Equal("`o``brien`@`10.0.%`", MySqlUserSql.Account(new PrincipalRef("o`brien", "10.0.%")));
        Assert.Equal("`app`@`%`", MySqlUserSql.Account(new PrincipalRef("app")));
    }

    [Fact]
    public void CreateCarriesPasswordAndLimitInOneStatement()
    {
        var definition = new PrincipalDefinition(App, "p'w\\x") with { ConnectionLimit = 3 };

        Assert.Equal(["CREATE USER `app`@`%` IDENTIFIED BY 'p''w\\\\x' WITH MAX_USER_CONNECTIONS 3"], Modern.CreatePrincipal(definition));
    }

    [Fact]
    public void LegacyCreateSetsTheLimitThroughGrantUsageAfterward()
    {
        var definition = new PrincipalDefinition(App, "pw") with { ConnectionLimit = 3 };

        Assert.Equal(
            ["CREATE USER `app`@`%` IDENTIFIED BY 'pw'", "GRANT USAGE ON *.* TO `app`@`%` WITH MAX_USER_CONNECTIONS 3"],
            Legacy.CreatePrincipal(definition));
    }

    [Fact]
    public void NoBackslashEscapesKeepsBackslashesAsTheyAre()
    {
        var sql = new MySqlUserSql(noBackslashEscapes: true);

        Assert.Equal(["ALTER USER `app`@`%` IDENTIFIED BY 'a\\b''c'"], sql.SetPassword(App, "a\\b'c"));
    }

    [Fact]
    public void PasswordSpellingFollowsTheServer()
    {
        Assert.Equal(["ALTER USER `app`@`%` IDENTIFIED BY 'x'"], Modern.SetPassword(App, "x"));
        Assert.Equal(["GRANT USAGE ON *.* TO `app`@`%` IDENTIFIED BY 'x'"], Legacy.SetPassword(App, "x"));
    }

    [Fact]
    public void AlterChangesTheLimitThenRenames()
    {
        var old = new PrincipalDefinition(App) with { ConnectionLimit = 5 };
        var changed = old with { Ref = new PrincipalRef("svc", "localhost"), ConnectionLimit = null };

        Assert.Equal(
            ["ALTER USER `app`@`%` WITH MAX_USER_CONNECTIONS 0", "RENAME USER `app`@`%` TO `svc`@`localhost`"],
            Modern.AlterPrincipal(old, changed));
    }

    [Fact]
    public void DropNamesTheAccount()
    {
        Assert.Equal(["DROP USER `app`@`%`"], Modern.DropPrincipal(App, PrincipalDropOptions.None));
    }

    [Fact]
    public void GrantTargetsEscapeWildcardsOnlyAtDatabaseLevel()
    {
        Assert.Equal("*.*", MySqlUserSql.GrantTarget(PrivilegeScope.Server));
        Assert.Equal("`my\\_db`.*", MySqlUserSql.GrantTarget(PrivilegeScope.ForDatabase("my_db")));
        Assert.Equal("`my_db`.`t`", MySqlUserSql.GrantTarget(PrivilegeScope.ForTable("my_db", null, "t")));
        Assert.Equal("`my_db`.`t`", MySqlUserSql.GrantTarget(PrivilegeScope.ForColumn("my_db", null, "t", "c")));
    }

    [Fact]
    public void GrantsFoldColumnsAndKeepTheGrantOption()
    {
        var grants = new[]
        {
            new PrincipalGrant("RELOAD", PrivilegeScope.Server),
            new PrincipalGrant("SELECT", PrivilegeScope.ForColumn("shop", null, "orders", "id")),
            new PrincipalGrant("INSERT", PrivilegeScope.ForTable("shop", null, "orders")),
            new PrincipalGrant("SELECT", PrivilegeScope.ForDatabase("shop"), IsGrantable: true),
        };

        Assert.Equal(
            [
                "GRANT RELOAD ON *.* TO `app`@`%`",
                "GRANT INSERT, SELECT (`id`) ON `shop`.`orders` TO `app`@`%`",
                "GRANT SELECT ON `shop`.* TO `app`@`%` WITH GRANT OPTION",
            ],
            Modern.Grant(App, grants));
        Assert.Equal(["REVOKE RELOAD ON *.* FROM `app`@`%`"], Modern.Revoke(App, [grants[0]]));
    }

    [Theory]
    [InlineData(DatabaseEngine.MySql, "5.6.51", true)]
    [InlineData(DatabaseEngine.MySql, "5.7.6", false)]
    [InlineData(DatabaseEngine.MySql, "8.0.36-0ubuntu0.22.04.1", false)]
    [InlineData(DatabaseEngine.MariaDb, "10.1.48-MariaDB", true)]
    [InlineData(DatabaseEngine.MariaDb, "10.6.12-MariaDB-log", false)]
    [InlineData(DatabaseEngine.MySql, null, false)]
    [InlineData(DatabaseEngine.MySql, "unknown", false)]
    [InlineData(DatabaseEngine.OceanBase, "5.6.25", false)]
    public void LegacySyntaxFollowsTheVersion(DatabaseEngine engine, string? version, bool legacy)
    {
        Assert.Equal(legacy ? MySqlAccountSyntax.GrantUsage : MySqlAccountSyntax.AlterUser, MySqlUserSql.SyntaxFor(engine, version));
    }

    [Fact]
    public void ParsesAGlobalGrantWithGrantOption()
    {
        var grant = MySqlGrantParser.Parse("GRANT RELOAD, PROCESS ON *.* TO `root`@`localhost` WITH GRANT OPTION");

        Assert.NotNull(grant);
        Assert.Equal(PrivilegeScope.Server, grant.Scope);
        Assert.True(grant.IsGrantable);
        Assert.Equal(["RELOAD", "PROCESS"], grant.Privileges.Select(p => p.Name));
    }

    [Fact]
    public void ParsesColumnListsAndQuotedNames()
    {
        var grant = MySqlGrantParser.Parse("GRANT SELECT (`id`, `na,me`), UPDATE (`id`) ON `shop`.`ord``ers` TO 'app'@'%'");

        Assert.NotNull(grant);
        Assert.Equal(PrivilegeScope.ForTable("shop", null, "ord`ers"), grant.Scope);
        Assert.False(grant.IsGrantable);
        Assert.Equal(["id", "na,me"], grant.Privileges[0].Columns);
        Assert.Equal(["id"], grant.Privileges[1].Columns);
    }

    [Fact]
    public void DatabasePatternIsUnescapedButATableTargetIsNot()
    {
        Assert.Equal(PrivilegeScope.ForDatabase("my_db"), MySqlGrantParser.Parse("GRANT SELECT ON `my\\_db`.* TO `a`@`%`")!.Scope);
        Assert.Equal(PrivilegeScope.ForTable("my\\_db", null, "t"), MySqlGrantParser.Parse("GRANT SELECT ON `my\\_db`.`t` TO `a`@`%`")!.Scope);
    }

    [Theory]
    [InlineData("GRANT `reader`@`%` TO `app`@`%`")]
    [InlineData("GRANT PROXY ON ''@'' TO 'root'@'localhost' WITH GRANT OPTION")]
    [InlineData("REVOKE SELECT ON *.* FROM `a`@`%`")]
    [InlineData("GRANT SELECT ON *.t TO `a`@`%`")]
    public void IgnoresLinesThatAreNotObjectGrants(string line)
    {
        Assert.Null(MySqlGrantParser.Parse(line));
    }

    [Fact]
    public void AllPrivilegesExpandsToTheLevelsCatalog()
    {
        var catalog = MySqlUserCatalog.Build([("Select", "Tables"), ("Insert", "Tables"), ("Create", "Databases,Tables,Indexes"), ("Reload", "Server Admin"), ("Grant option", "Databases,Tables")]);
        var parsed = MySqlGrantParser.Parse("GRANT ALL PRIVILEGES ON `shop`.* TO `a`@`%`")!;

        // A table privilege can be granted on a whole database too, so it belongs to the database level as well.
        Assert.Equal(["SELECT", "INSERT", "CREATE"], MySqlUserCatalog.Expand(parsed, catalog).Select(g => g.Privilege));
        Assert.All(MySqlUserCatalog.Expand(parsed, catalog), g => Assert.Equal(PrivilegeScope.ForDatabase("shop"), g.Scope));
    }

    [Fact]
    public void CatalogPlacesPrivilegesByContextAndFlagsDynamicOnes()
    {
        var catalog = MySqlUserCatalog.Build(
        [
            ("Select", "Tables"),
            ("Create view", "Tables"),
            ("Show databases", "Server Admin"),
            ("Grant option", "Databases,Tables,Functions,Procedures"),
            ("Proxy", "Server Admin"),
            ("BACKUP_ADMIN", "Server Admin"),
        ]);

        Assert.Equal(["SELECT", "CREATE VIEW", "SHOW DATABASES", "BACKUP_ADMIN"], catalog.Server.Select(d => d.Name));
        Assert.Equal(["SELECT", "CREATE VIEW"], catalog.Table.Select(d => d.Name));
        Assert.Equal(["SELECT"], catalog.Column.Select(d => d.Name));
        Assert.Equal(["SELECT", "CREATE VIEW"], catalog.Database.Select(d => d.Name));
        Assert.True(catalog.SupportsDynamicPrivileges);
        Assert.Equal(PrivilegeCategoryKeys.Dynamic, catalog.Server[3].Category);
        Assert.Equal(PrivilegeCategoryKeys.Structure, catalog.Server[1].Category);
    }

    [Fact]
    public void CurrentUserSplitsAtTheLastAt()
    {
        Assert.Equal(new PrincipalRef("me@corp", "localhost"), MySqlUserCatalog.ParseAccount("me@corp@localhost"));
        Assert.Equal(new PrincipalRef("root", "%"), MySqlUserCatalog.ParseAccount("root"));
    }

    [Fact]
    public void SearchPatternEscapesWithBang()
    {
        Assert.Equal("%a!%b!_c!!%", MySqlUserCatalog.ContainsPattern("a%b_c!"));
    }
}
