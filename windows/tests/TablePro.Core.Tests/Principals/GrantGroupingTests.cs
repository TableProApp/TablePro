using TablePro.Core.Principals;

namespace TablePro.Core.Tests.Principals;

public sealed class GrantGroupingTests
{
    private static readonly PrivilegeScope Table = PrivilegeScope.ForTable("db", "s", "t");

    [Fact]
    public void ColumnGrantsFoldOntoTheirTableSortedByPrivilege()
    {
        var group = Assert.Single(GrantGrouping.Group(
        [
            new PrincipalGrant("UPDATE", PrivilegeScope.ForColumn("db", "s", "t", "b")),
            new PrincipalGrant("SELECT", Table),
            new PrincipalGrant("INSERT", PrivilegeScope.ForColumn("db", "s", "t", "a")),
            new PrincipalGrant("UPDATE", PrivilegeScope.ForColumn("db", "s", "t", "a")),
            new PrincipalGrant("UPDATE", PrivilegeScope.ForColumn("db", "s", "t", "b")),
        ]));

        Assert.Equal(Table, group.Target);
        Assert.Equal(["SELECT"], group.Privileges);
        Assert.Equal(["INSERT", "UPDATE"], group.ColumnPrivileges.Select(c => c.Privilege));
        Assert.Equal(["b", "a"], group.ColumnPrivileges[1].Columns);
    }

    [Fact]
    public void GrantableAndPlainGrantsOnOneObjectStayApart()
    {
        var groups = GrantGrouping.Group([new PrincipalGrant("SELECT", Table, IsGrantable: true), new PrincipalGrant("INSERT", Table)]);

        Assert.Equal(2, groups.Count);
        Assert.True(groups[0].IsGrantable);
        Assert.Equal(["INSERT"], groups[1].Privileges);
    }

    [Fact]
    public void BuilderSkipsUnsafeNamesAndRefusesAnUnknownTarget()
    {
        var builder = new GrantSqlBuilder("g", static n => $"\"{n}\"", static s => s.Level == PrivilegeLevel.Table ? "T" : null);

        Assert.Equal(["GRANT SELECT ON T TO g WITH GRANT OPTION"], builder.GrantStatements([new PrincipalGrant("select", Table, true), new PrincipalGrant("x;y", Table, true)]));
        Assert.Empty(builder.GrantStatements([new PrincipalGrant("x;y", Table)])!);
        Assert.Null(builder.RevokeStatements([new PrincipalGrant("SELECT", PrivilegeScope.Server)]));
    }
}
