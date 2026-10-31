using TablePro.Core.Principals;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Oracle;

/// <summary>
/// The Oracle statements for each principal change. Users and roles are different objects here, so the generator is
/// given the server's role names; a name outside them is a user or a staged create. Pure, so the text is pinned by
/// unit tests. A schema is what the scope tree lists as a database, so a table's scope is (owner, no schema, table).
/// </summary>
internal sealed class OracleUserSql(IReadOnlySet<string> roles) : IPrincipalSqlGenerator
{
    private static SqlDialect Dialect => OracleDialect.Instance;

    public IReadOnlyList<string>? CreatePrincipal(PrincipalDefinition definition)
    {
        var name = Q(definition.Ref.Name);
        var statements = new List<string>();
        if (definition.CanLogin)
        {
            if (IdentifiedBy(definition.Password) is not { } identified)
            {
                return null;
            }

            statements.Add($"CREATE USER {name} {identified}");
        }
        else
        {
            statements.Add($"CREATE ROLE {name}");
        }

        statements.AddRange(definition.MemberOf.Order(StringComparer.Ordinal).Select(r => $"GRANT {Q(r)} TO {name}"));
        return statements;
    }

    /// <summary>Oracle renames neither users nor roles, and a role has no account to lock.</summary>
    public IReadOnlyList<string>? AlterPrincipal(PrincipalDefinition old, PrincipalDefinition changed)
    {
        if (old.Ref != changed.Ref)
        {
            return null;
        }

        var name = Q(old.Ref.Name);
        var statements = new List<string>();
        if (old.CanLogin != changed.CanLogin)
        {
            if (roles.Contains(old.Ref.Name))
            {
                return null;
            }

            statements.Add($"ALTER USER {name} ACCOUNT {(changed.CanLogin ? "UNLOCK" : "LOCK")}");
        }

        var before = old.MemberOf.ToHashSet(StringComparer.Ordinal);
        var after = changed.MemberOf.ToHashSet(StringComparer.Ordinal);
        statements.AddRange(before.Except(after).Order(StringComparer.Ordinal).Select(r => $"REVOKE {Q(r)} FROM {name}"));
        statements.AddRange(after.Except(before).Order(StringComparer.Ordinal).Select(r => $"GRANT {Q(r)} TO {name}"));
        return statements;
    }

    public IReadOnlyList<string>? SetPassword(PrincipalRef principal, string password) =>
        roles.Contains(principal.Name) || IdentifiedBy(password) is not { } identified ? null : [$"ALTER USER {Q(principal.Name)} {identified}"];

    // No CASCADE: a user who owns objects fails with ORA-01922 instead of losing them.
    public IReadOnlyList<string> DropPrincipal(PrincipalRef principal, PrincipalDropOptions options) =>
        [roles.Contains(principal.Name) ? $"DROP ROLE {Q(principal.Name)}" : $"DROP USER {Q(principal.Name)}"];

    public IReadOnlyList<string>? Grant(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants)
    {
        var grantee = Q(principal.Name);
        var statements = new List<string>();
        foreach (var group in GrantGrouping.Group(grants))
        {
            if (Clause(group) is not { } clause)
            {
                continue;
            }

            if (!TryTarget(group.Target, out var on))
            {
                return null;
            }

            // A system privilege is passed on WITH ADMIN OPTION, an object privilege WITH GRANT OPTION.
            var option = !group.IsGrantable ? string.Empty : on is null ? " WITH ADMIN OPTION" : " WITH GRANT OPTION";
            statements.Add($"GRANT {clause}{(on is null ? string.Empty : " ON " + on)} TO {grantee}{option}");
        }

        return statements;
    }

    // A column privilege is revoked only from the whole table (ORA-01750), which would take it from every other column too.
    public IReadOnlyList<string>? Revoke(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants)
    {
        if (grants.Any(g => g.Scope.Level == PrivilegeLevel.Column))
        {
            return null;
        }

        var grantee = Q(principal.Name);
        var statements = new List<string>();
        foreach (var group in GrantGrouping.Group(grants.Select(g => g with { IsGrantable = false })))
        {
            if (Clause(group) is not { } clause)
            {
                continue;
            }

            if (!TryTarget(group.Target, out var on))
            {
                return null;
            }

            statements.Add($"REVOKE {clause}{(on is null ? string.Empty : " ON " + on)} FROM {grantee}");
        }

        return statements;
    }

    private static string Q(string name) => Dialect.QuoteIdentifier(name);

    private static string? Clause(GrantGroup group)
    {
        var parts = group.Privileges.Select(PrivilegeName.Sanitize).OfType<string>().Distinct(StringComparer.Ordinal).ToList();
        foreach (var (privilege, columns) in group.ColumnPrivileges)
        {
            if (PrivilegeName.Sanitize(privilege) is { } name && columns.Count > 0)
            {
                parts.Add($"{name} ({string.Join(", ", columns.Select(Q))})");
            }
        }

        return parts.Count == 0 ? null : string.Join(", ", parts);
    }

    /// <summary>The server takes system privileges with no ON clause; a schema or database scope has no Oracle target.</summary>
    private static bool TryTarget(PrivilegeScope scope, out string? on)
    {
        on = null;
        switch (scope.Level)
        {
            case PrivilegeLevel.Server:
                return true;
            case PrivilegeLevel.Table:
                on = $"{Q(scope.Database!)}.{Q(scope.Table!)}";
                return true;
            default:
                return false;
        }
    }

    // IDENTIFIED BY takes a quoted identifier, which cannot hold a double quote, so such a password has no spelling.
    private static string? IdentifiedBy(string? password) =>
        string.IsNullOrEmpty(password) || password.Contains('"', StringComparison.Ordinal) ? null : $"IDENTIFIED BY \"{password}\"";
}
