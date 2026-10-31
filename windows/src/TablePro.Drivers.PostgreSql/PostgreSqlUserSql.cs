using System.Globalization;
using TablePro.Core.Principals;
using TablePro.Core.Sql;

namespace TablePro.Drivers.PostgreSql;

/// <summary>A role attribute: its keyword, the label the attributes form shows, and its pg_roles column.</summary>
internal sealed record PostgreSqlRoleAttribute(string Keyword, string Label, string Column)
{
    public static readonly IReadOnlyList<PostgreSqlRoleAttribute> All =
    [
        new("SUPERUSER", "Superuser", "rolsuper"),
        new("CREATEDB", "Create databases", "rolcreatedb"),
        new("CREATEROLE", "Create roles", "rolcreaterole"),
        new("REPLICATION", "Replication", "rolreplication"),
        new("BYPASSRLS", "Bypass row level security", "rolbypassrls"),
        new("INHERIT", "Inherit privileges", "rolinherit"),
    ];

    public string Spelling(bool enabled) => enabled ? Keyword : "NO" + Keyword;
}

/// <summary>
/// The PostgreSQL statements for each principal change. Users and groups are both roles here, told apart only by LOGIN.
/// Pure, so the text is pinned by unit tests.
/// </summary>
/// <param name="supportsBypassRls">BYPASSRLS arrived in 9.5; an older server rejects the keyword even as NOBYPASSRLS.</param>
internal sealed class PostgreSqlUserSql(bool supportsBypassRls = true) : IPrincipalSqlGenerator
{
    public static readonly IReadOnlyList<PrivilegeDescriptor> DatabasePrivileges =
    [
        new("CONNECT", "Connect", PrivilegeCategoryKeys.Administration),
        new("CREATE", "Create", PrivilegeCategoryKeys.Structure),
        new("TEMPORARY", "Temporary tables", PrivilegeCategoryKeys.Structure),
    ];

    public static readonly IReadOnlyList<PrivilegeDescriptor> SchemaPrivileges =
    [
        new("USAGE", "Usage", PrivilegeCategoryKeys.Administration),
        new("CREATE", "Create", PrivilegeCategoryKeys.Structure),
    ];

    public static readonly IReadOnlyList<PrivilegeDescriptor> TablePrivileges =
    [
        new("SELECT", "Select", PrivilegeCategoryKeys.Data),
        new("INSERT", "Insert", PrivilegeCategoryKeys.Data),
        new("UPDATE", "Update", PrivilegeCategoryKeys.Data),
        new("DELETE", "Delete", PrivilegeCategoryKeys.Data),
        new("TRUNCATE", "Truncate", PrivilegeCategoryKeys.Structure),
        new("REFERENCES", "References", PrivilegeCategoryKeys.Structure),
        new("TRIGGER", "Trigger", PrivilegeCategoryKeys.Structure),
    ];

    public static readonly IReadOnlyList<PrivilegeDescriptor> ColumnPrivileges =
    [
        new("SELECT", "Select", PrivilegeCategoryKeys.Data),
        new("INSERT", "Insert", PrivilegeCategoryKeys.Data),
        new("UPDATE", "Update", PrivilegeCategoryKeys.Data),
        new("REFERENCES", "References", PrivilegeCategoryKeys.Structure),
    ];

    public static PrivilegeCatalog Catalog { get; } = new([], DatabasePrivileges, SchemaPrivileges, TablePrivileges, ColumnPrivileges);

    private static SqlDialect Dialect => PostgreSqlDialect.Instance;

    public IReadOnlyList<PostgreSqlRoleAttribute> Attributes { get; } =
        [.. PostgreSqlRoleAttribute.All.Where(a => supportsBypassRls || a.Keyword != "BYPASSRLS")];

    public IReadOnlyList<string> CreatePrincipal(PrincipalDefinition definition)
    {
        var role = Q(definition.Ref.Name);
        var options = new List<string> { definition.CanLogin ? "LOGIN" : "NOLOGIN" };
        options.AddRange(definition.Attributes.Select(Keyword).OfType<string>());

        // Utility statements take no bind parameters, so the password can only travel as a literal.
        if (definition.HasPassword)
        {
            options.Add("PASSWORD " + Dialect.StringLiteral(definition.Password!));
        }

        if (definition.ConnectionLimit is { } limit)
        {
            options.Add("CONNECTION LIMIT " + limit.ToString(CultureInfo.InvariantCulture));
        }

        var statements = new List<string> { $"CREATE ROLE {role} WITH {string.Join(' ', options)}" };
        statements.AddRange(definition.MemberOf.Select(r => $"GRANT {Q(r)} TO {role}"));
        if (!string.IsNullOrEmpty(definition.Comment))
        {
            statements.Add($"COMMENT ON ROLE {role} IS {Dialect.StringLiteral(definition.Comment)}");
        }

        return statements;
    }

    public IReadOnlyList<string> AlterPrincipal(PrincipalDefinition old, PrincipalDefinition changed)
    {
        var role = Q(old.Ref.Name);
        var statements = new List<string>();

        var options = new List<string>();
        if (old.CanLogin != changed.CanLogin)
        {
            options.Add(changed.CanLogin ? "LOGIN" : "NOLOGIN");
        }

        var before = old.Attributes.ToDictionary(a => a.Key, a => a.IsEnabled, StringComparer.Ordinal);
        options.AddRange(changed.Attributes
            .Where(a => !before.TryGetValue(a.Key, out var enabled) || enabled != a.IsEnabled)
            .Select(Keyword)
            .OfType<string>());

        // -1 is PostgreSQL's spelling of no limit.
        if (old.ConnectionLimit != changed.ConnectionLimit)
        {
            options.Add("CONNECTION LIMIT " + (changed.ConnectionLimit ?? -1).ToString(CultureInfo.InvariantCulture));
        }

        if (options.Count > 0)
        {
            statements.Add($"ALTER ROLE {role} WITH {string.Join(' ', options)}");
        }

        var oldRoles = old.MemberOf.ToHashSet(StringComparer.Ordinal);
        var newRoles = changed.MemberOf.ToHashSet(StringComparer.Ordinal);
        statements.AddRange(oldRoles.Except(newRoles).Order(StringComparer.Ordinal).Select(r => $"REVOKE {Q(r)} FROM {role}"));
        statements.AddRange(newRoles.Except(oldRoles).Order(StringComparer.Ordinal).Select(r => $"GRANT {Q(r)} TO {role}"));

        if (old.Comment != changed.Comment)
        {
            var comment = string.IsNullOrEmpty(changed.Comment) ? "NULL" : Dialect.StringLiteral(changed.Comment);
            statements.Add($"COMMENT ON ROLE {role} IS {comment}");
        }

        // Last, so every statement above still names the role it found. PostgreSQL clears an MD5 password on rename,
        // since the hash is salted with the name; the server says so in a notice.
        if (old.Ref.Name != changed.Ref.Name)
        {
            statements.Add($"ALTER ROLE {role} RENAME TO {Q(changed.Ref.Name)}");
        }

        return statements;
    }

    public IReadOnlyList<string> SetPassword(PrincipalRef principal, string password) =>
        [$"ALTER ROLE {Q(principal.Name)} WITH PASSWORD {Dialect.StringLiteral(password)}"];

    // REASSIGN OWNED and DROP OWNED reach only the current database; objects the role owns in another database still
    // block the DROP ROLE, and the server's error names them.
    public IReadOnlyList<string> DropPrincipal(PrincipalRef principal, PrincipalDropOptions options)
    {
        var role = Q(principal.Name);
        var statements = new List<string>();
        if (options.ReassignOwnedTo is { } target)
        {
            statements.Add($"REASSIGN OWNED BY {role} TO {Q(target.Name)}");
            statements.Add($"DROP OWNED BY {role}");
        }
        else if (options.DropOwned)
        {
            statements.Add($"DROP OWNED BY {role}");
        }

        statements.Add($"DROP ROLE {role}");
        return statements;
    }

    public IReadOnlyList<string>? Grant(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants) => Builder(principal).GrantStatements(grants);

    public IReadOnlyList<string>? Revoke(PrincipalRef principal, IReadOnlyList<PrincipalGrant> grants) => Builder(principal).RevokeStatements(grants);

    public static string? GrantTarget(PrivilegeScope scope) => scope.Level switch
    {
        PrivilegeLevel.Database => "DATABASE " + Q(scope.Database!),
        PrivilegeLevel.Schema => "SCHEMA " + Q(scope.Schema!),
        PrivilegeLevel.Table or PrivilegeLevel.Column => "TABLE " + (scope.Schema is null ? Q(scope.Table!) : $"{Q(scope.Schema)}.{Q(scope.Table!)}"),
        _ => null,
    };

    private static GrantSqlBuilder Builder(PrincipalRef principal) => new(Q(principal.Name), Q, GrantTarget);

    private string? Keyword(PrincipalAttribute attribute) =>
        Attributes.FirstOrDefault(a => a.Keyword == attribute.Key)?.Spelling(attribute.IsEnabled);

    private static string Q(string name) => Dialect.QuoteIdentifier(name);
}
