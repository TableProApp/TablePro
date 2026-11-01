using System.Text;

namespace TablePro.Core.Principals;

/// <summary>The privileges one GRANT or REVOKE names on one object; column grants fold in as column lists.</summary>
public sealed record GrantGroup(
    PrivilegeScope Target,
    IReadOnlyList<string> Privileges,
    IReadOnlyList<(string Privilege, IReadOnlyList<string> Columns)> ColumnPrivileges,
    bool IsGrantable);

public static class GrantGrouping
{
    /// <summary>
    /// One group per target object and grant option, in the order the targets first appear, so
    /// <c>GRANT SELECT (a, b), UPDATE (a) ON t</c> is one statement. Grantable and plain grants on the same object stay
    /// apart: folding them together would hand out the grant option on privileges that never had it.
    /// </summary>
    public static IReadOnlyList<GrantGroup> Group(IEnumerable<PrincipalGrant> grants)
    {
        var order = new List<(PrivilegeScope Target, bool Grantable)>();
        var whole = new Dictionary<(PrivilegeScope, bool), List<string>>();
        var byColumn = new Dictionary<(PrivilegeScope, bool), SortedDictionary<string, List<string>>>();

        foreach (var grant in grants)
        {
            var key = (grant.Scope.GrantTarget, grant.IsGrantable);
            if (!whole.ContainsKey(key) && !byColumn.ContainsKey(key))
            {
                order.Add(key);
            }

            if (grant.Scope.Column is { } column)
            {
                if (!byColumn.TryGetValue(key, out var privileges))
                {
                    privileges = new SortedDictionary<string, List<string>>(StringComparer.Ordinal);
                    byColumn[key] = privileges;
                }

                if (!privileges.TryGetValue(grant.Privilege, out var columns))
                {
                    columns = [];
                    privileges[grant.Privilege] = columns;
                }

                if (!columns.Contains(column))
                {
                    columns.Add(column);
                }
            }
            else
            {
                if (!whole.TryGetValue(key, out var privileges))
                {
                    privileges = [];
                    whole[key] = privileges;
                }

                if (!privileges.Contains(grant.Privilege))
                {
                    privileges.Add(grant.Privilege);
                }
            }
        }

        return order.Select(key => new GrantGroup(
                key.Target,
                whole.TryGetValue(key, out var privileges) ? privileges : [],
                byColumn.TryGetValue(key, out var columns) ? columns.Select(c => (c.Key, (IReadOnlyList<string>)c.Value)).ToArray() : [],
                key.Grantable))
            .ToArray();
    }
}

/// <summary>
/// GRANT and REVOKE share one shape across PostgreSQL and MySQL: a privilege clause, a target and a grantee. Only the
/// target and the grantee are dialect-specific, so a driver supplies those and the clause is built here once.
/// </summary>
public sealed class GrantSqlBuilder(string grantee, Func<string, string> quoteIdentifier, Func<PrivilegeScope, string?> target)
{
    /// <returns>Null when a grant names an object the engine has no target for.</returns>
    public IReadOnlyList<string>? GrantStatements(IEnumerable<PrincipalGrant> grants) =>
        Statements(grants, (clause, on, group) => $"GRANT {clause} ON {on} TO {grantee}{(group.IsGrantable ? " WITH GRANT OPTION" : string.Empty)}");

    public IReadOnlyList<string>? RevokeStatements(IEnumerable<PrincipalGrant> grants) =>
        Statements(grants, (clause, on, _) => $"REVOKE {clause} ON {on} FROM {grantee}");

    public string? PrivilegeClause(GrantGroup group)
    {
        var parts = new List<string>();
        foreach (var privilege in group.Privileges)
        {
            if (PrivilegeName.Sanitize(privilege) is { } name)
            {
                parts.Add(name);
            }
        }

        foreach (var (privilege, columns) in group.ColumnPrivileges)
        {
            if (PrivilegeName.Sanitize(privilege) is { } name && columns.Count > 0)
            {
                parts.Add(new StringBuilder(name).Append(" (").AppendJoin(", ", columns.Select(quoteIdentifier)).Append(')').ToString());
            }
        }

        return parts.Count == 0 ? null : string.Join(", ", parts);
    }

    private List<string>? Statements(IEnumerable<PrincipalGrant> grants, Func<string, string, GrantGroup, string> render)
    {
        var statements = new List<string>();
        foreach (var group in GrantGrouping.Group(grants))
        {
            if (PrivilegeClause(group) is not { } clause)
            {
                continue;
            }

            if (target(group.Target) is not { } on)
            {
                return null;
            }

            statements.Add(render(clause, on, group));
        }

        return statements;
    }
}
