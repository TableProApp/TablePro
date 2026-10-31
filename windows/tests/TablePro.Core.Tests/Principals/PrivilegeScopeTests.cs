using TablePro.Core.Principals;

namespace TablePro.Core.Tests.Principals;

public sealed class PrivilegeScopeTests
{
    private static readonly PrivilegeScope Column = PrivilegeScope.ForColumn("shop", "sales", "orders", "id");

    [Fact]
    public void ScopesCompareByValue()
    {
        Assert.Equal(PrivilegeScope.ForTable("shop", "sales", "orders"), PrivilegeScope.ForTable("shop", "sales", "orders"));
        Assert.NotEqual(PrivilegeScope.ForTable("shop", null, "orders"), PrivilegeScope.ForTable("shop", "sales", "orders"));
        Assert.Single(new HashSet<PrivilegeScope> { PrivilegeScope.ForDatabase("a"), PrivilegeScope.ForDatabase("a") });
    }

    [Fact]
    public void ParentsWalkUpToTheServer()
    {
        Assert.Equal(PrivilegeScope.ForTable("shop", "sales", "orders"), Column.Parent);
        Assert.Equal(PrivilegeScope.ForSchema("shop", "sales"), Column.Parent!.Parent);
        Assert.Equal(PrivilegeScope.ForDatabase("shop"), PrivilegeScope.ForSchema("shop", "sales").Parent);
        Assert.Equal(PrivilegeScope.Server, PrivilegeScope.ForDatabase("shop").Parent);
        Assert.Null(PrivilegeScope.Server.Parent);
    }

    [Fact]
    public void ATableWithoutSchemaSitsUnderItsDatabase()
    {
        Assert.Equal(PrivilegeScope.ForDatabase("shop"), PrivilegeScope.ForTable("shop", null, "orders").Parent);
    }

    [Fact]
    public void ContainsIsStrictAncestry()
    {
        Assert.True(PrivilegeScope.Server.Contains(Column));
        Assert.True(PrivilegeScope.ForDatabase("shop").Contains(Column));
        Assert.False(Column.Contains(Column));
        Assert.False(PrivilegeScope.ForDatabase("other").Contains(Column));
    }

    [Fact]
    public void AColumnGrantTargetsItsTable()
    {
        Assert.Equal(PrivilegeScope.ForTable("shop", "sales", "orders"), Column.GrantTarget);
        Assert.Equal(PrivilegeScope.ForDatabase("shop"), PrivilegeScope.ForDatabase("shop").GrantTarget);
    }

    [Fact]
    public void NamesForDisplay()
    {
        Assert.Equal("id", Column.DisplayName);
        Assert.Equal("shop › sales › orders › id", Column.DisplayPath);
        Assert.Equal("Server", PrivilegeScope.Server.DisplayName);
    }

    [Fact]
    public void SortKeyPutsParentsBeforeChildren()
    {
        var scopes = new[] { Column, PrivilegeScope.ForDatabase("shop"), PrivilegeScope.ForSchema("shop", "sales"), PrivilegeScope.Server };

        Assert.Equal([PrivilegeScope.Server, PrivilegeScope.ForDatabase("shop"), PrivilegeScope.ForSchema("shop", "sales"), Column], scopes.OrderBy(s => s.SortKey, StringComparer.Ordinal));
    }

    [Theory]
    [InlineData("select", "SELECT")]
    [InlineData(" show view ", "SHOW VIEW")]
    [InlineData("BACKUP_ADMIN", "BACKUP_ADMIN")]
    [InlineData("SELECT; DROP", null)]
    [InlineData("", null)]
    [InlineData("SELECT(a)", null)]
    public void PrivilegeNamesAreKeywordsOnly(string raw, string? expected)
    {
        Assert.Equal(expected, PrivilegeName.Sanitize(raw));
    }
}
