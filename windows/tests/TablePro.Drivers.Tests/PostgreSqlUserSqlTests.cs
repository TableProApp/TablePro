using TablePro.Core.Principals;
using TablePro.Drivers.PostgreSql;

namespace TablePro.Drivers.Tests;

public sealed class PostgreSqlUserSqlTests
{
    private static readonly PostgreSqlUserSql Sql = new();
    private static readonly PrincipalRef App = new("app");

    [Fact]
    public void CreateSpellsLoginAttributesPasswordLimitMembershipAndComment()
    {
        var definition = new PrincipalDefinition(
            new PrincipalRef("Ann\"e"),
            "pa'ss",
            CanLogin: true,
            [new PrincipalAttribute("CREATEDB", "Create databases", true), new PrincipalAttribute("SUPERUSER", "Superuser", false)],
            ["readers"],
            ConnectionLimit: 5,
            Comment: "it's me");

        Assert.Equal(
            [
                "CREATE ROLE \"Ann\"\"e\" WITH LOGIN CREATEDB NOSUPERUSER PASSWORD 'pa''ss' CONNECTION LIMIT 5",
                "GRANT \"readers\" TO \"Ann\"\"e\"",
                "COMMENT ON ROLE \"Ann\"\"e\" IS 'it''s me'",
            ],
            Sql.CreatePrincipal(definition));
    }

    [Fact]
    public void CreateRoleWithoutPasswordIsNoLogin()
    {
        Assert.Equal(["CREATE ROLE \"writers\" WITH NOLOGIN"], Sql.CreatePrincipal(new PrincipalDefinition(new PrincipalRef("writers"), canLogin: false)));
    }

    [Fact]
    public void BypassRlsIsLeftOutBeforeNinePointFive()
    {
        var legacy = new PostgreSqlUserSql(supportsBypassRls: false);
        var definition = new PrincipalDefinition(App, null, true, [new PrincipalAttribute("BYPASSRLS", "Bypass", true)], []);

        Assert.Equal(["CREATE ROLE \"app\" WITH LOGIN"], legacy.CreatePrincipal(definition));
        Assert.DoesNotContain(legacy.Attributes, a => a.Keyword == "BYPASSRLS");
        Assert.Equal(PostgreSqlRoleAttribute.All.Count, Sql.Attributes.Count);
    }

    [Fact]
    public void AlterSpellsOnlyWhatChangedAndRenamesLast()
    {
        var old = new PrincipalDefinition(App, null, true, [new PrincipalAttribute("CREATEDB", "Create databases", false)], ["a", "b"], 10, "x");
        var changed = old with
        {
            Ref = new PrincipalRef("svc"),
            CanLogin = false,
            Attributes = [new PrincipalAttribute("CREATEDB", "Create databases", true)],
            MemberOf = ["b", "c"],
            ConnectionLimit = null,
            Comment = null,
        };

        Assert.Equal(
            [
                "ALTER ROLE \"app\" WITH NOLOGIN CREATEDB CONNECTION LIMIT -1",
                "REVOKE \"a\" FROM \"app\"",
                "GRANT \"c\" TO \"app\"",
                "COMMENT ON ROLE \"app\" IS NULL",
                "ALTER ROLE \"app\" RENAME TO \"svc\"",
            ],
            Sql.AlterPrincipal(old, changed));
    }

    [Fact]
    public void AlterWithNothingChangedIsEmpty()
    {
        var definition = new PrincipalDefinition(App);
        Assert.Empty(Sql.AlterPrincipal(definition, definition));
    }

    [Fact]
    public void PasswordIsALiteral()
    {
        Assert.Equal(["ALTER ROLE \"app\" WITH PASSWORD 'n''ew'"], Sql.SetPassword(App, "n'ew"));
    }

    [Fact]
    public void DropReassignsOrDropsOwnedObjectsFirst()
    {
        Assert.Equal(["DROP ROLE \"app\""], Sql.DropPrincipal(App, PrincipalDropOptions.None));
        Assert.Equal(["DROP OWNED BY \"app\"", "DROP ROLE \"app\""], Sql.DropPrincipal(App, new PrincipalDropOptions(DropOwned: true)));
        Assert.Equal(
            ["REASSIGN OWNED BY \"app\" TO \"postgres\"", "DROP OWNED BY \"app\"", "DROP ROLE \"app\""],
            Sql.DropPrincipal(App, new PrincipalDropOptions(new PrincipalRef("postgres"))));
    }

    [Fact]
    public void GrantsGroupPerObjectWithColumnLists()
    {
        var grants = new[]
        {
            new PrincipalGrant("CONNECT", PrivilegeScope.ForDatabase("shop")),
            new PrincipalGrant("USAGE", PrivilegeScope.ForSchema("shop", "sales")),
            new PrincipalGrant("SELECT", PrivilegeScope.ForTable("shop", "sales", "orders")),
            new PrincipalGrant("UPDATE", PrivilegeScope.ForColumn("shop", "sales", "orders", "status")),
            new PrincipalGrant("UPDATE", PrivilegeScope.ForColumn("shop", "sales", "orders", "note")),
            new PrincipalGrant("INSERT", PrivilegeScope.ForTable("shop", "sales", "orders"), IsGrantable: true),
        };

        Assert.Equal(
            [
                "GRANT CONNECT ON DATABASE \"shop\" TO \"app\"",
                "GRANT USAGE ON SCHEMA \"sales\" TO \"app\"",
                "GRANT SELECT, UPDATE (\"status\", \"note\") ON TABLE \"sales\".\"orders\" TO \"app\"",
                "GRANT INSERT ON TABLE \"sales\".\"orders\" TO \"app\" WITH GRANT OPTION",
            ],
            Sql.Grant(App, grants));
    }

    [Fact]
    public void RevokeNamesTheSameTargets()
    {
        Assert.Equal(
            ["REVOKE SELECT, DELETE ON TABLE \"sales\".\"orders\" FROM \"app\""],
            Sql.Revoke(App, [new PrincipalGrant("SELECT", PrivilegeScope.ForTable("shop", "sales", "orders")), new PrincipalGrant("DELETE", PrivilegeScope.ForTable("shop", "sales", "orders"))]));
    }

    [Fact]
    public void PrivilegeNamesThatAreNotKeywordsAreDropped()
    {
        Assert.Equal(
            ["GRANT SELECT ON TABLE \"t\" TO \"app\""],
            Sql.Grant(App, [new PrincipalGrant("SELECT", PrivilegeScope.ForTable("db", null, "t")), new PrincipalGrant("SELECT; DROP TABLE x", PrivilegeScope.ForTable("db", null, "t"))]));
    }

    [Fact]
    public void AServerGrantHasNoTarget()
    {
        Assert.Null(Sql.Grant(App, [new PrincipalGrant("SUPERUSER", PrivilegeScope.Server)]));
    }

    [Fact]
    public void CatalogOffersNothingAtServerLevel()
    {
        Assert.Empty(PostgreSqlUserSql.Catalog.Server);
        Assert.Contains(PostgreSqlUserSql.Catalog.Column, d => d.Name == "UPDATE");
        Assert.DoesNotContain(PostgreSqlUserSql.Catalog.Column, d => d.Name == "DELETE");
    }

    [Fact]
    public void SearchPatternEscapesLikeMetacharacters()
    {
        Assert.Equal("%a\\%b\\_c\\\\%", PostgreSqlUserCatalog.ContainsPattern("a%b_c\\"));
    }

    [Fact]
    public void ScriptRunsCreatesBeforeGrantsAndDropsLast()
    {
        var changes = new PrincipalChange[]
        {
            new DropPrincipal(new PrincipalRef("old"), PrincipalDropOptions.None),
            new ModifyGrants(new PrincipalGrantChanges(App, [new PrincipalGrant("CONNECT", PrivilegeScope.ForDatabase("shop"))], [new PrincipalGrant("TEMPORARY", PrivilegeScope.ForDatabase("shop"))])),
            new CreatePrincipal(new PrincipalDefinition(App, "pw")),
        };

        var statements = PrincipalScript.Build(Sql, changes);

        Assert.Equal(
            [
                "CREATE ROLE \"app\" WITH LOGIN PASSWORD 'pw'",
                "REVOKE TEMPORARY ON DATABASE \"shop\" FROM \"app\"",
                "GRANT CONNECT ON DATABASE \"shop\" TO \"app\"",
                "DROP ROLE \"old\"",
            ],
            statements.Select(s => s.Sql));
        Assert.True(statements[0].CarriesCredentials);
        Assert.False(statements[2].CarriesCredentials);
        Assert.True(statements[1].IsDestructive);
        Assert.True(statements[3].IsDestructive);
    }
}
