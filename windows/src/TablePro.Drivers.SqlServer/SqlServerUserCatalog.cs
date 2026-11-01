using TablePro.Core.Principals;
using TablePro.Core.Sql;

namespace TablePro.Drivers.SqlServer;

/// <summary>
/// The queries behind the Users and Roles editor. Every database view is named through the database the list was read
/// from, which the session may have left since; names and patterns are bound as parameters.
/// </summary>
internal static class SqlServerUserCatalog
{
    public const string Session = "SELECT DB_NAME(), SUSER_SNAME()";

    // ##...## logins are certificate logins the server creates for itself.
    public static string Logins(string database) => $"""
        SELECT sp.name, CAST(sp.is_disabled AS int), dp.name
        FROM sys.server_principals AS sp
        LEFT JOIN {View("database_principals", database)} AS dp
            ON dp.sid = sp.sid AND dp.type IN ('S', 'U', 'G', 'E', 'X')
        WHERE sp.type IN ('S', 'U', 'G', 'E', 'X') AND sp.name NOT LIKE N'##%'
        ORDER BY sp.name
        """;

    // public holds every login implicitly and takes no members.
    public const string ServerRoles = "SELECT name FROM sys.server_principals WHERE type = 'R' AND name <> N'public' ORDER BY name";

    // Roles, and users no visible login maps to: contained, WITHOUT LOGIN, or orphaned.
    public static string DatabasePrincipals(string database) => $"""
        SELECT dp.name, dp.type, CASE WHEN EXISTS (
                SELECT 1 FROM {View("database_permissions", database)} AS p
                WHERE p.grantee_principal_id = dp.principal_id AND p.class = 0 AND p.permission_name = N'CONNECT' AND p.state IN ('G', 'W')
            ) THEN 1 ELSE 0 END
        FROM {View("database_principals", database)} AS dp
        WHERE (dp.type = 'R' AND dp.name <> N'public')
           OR (dp.type IN ('S', 'U', 'G', 'E', 'X', 'C', 'K')
               AND dp.name NOT IN (N'sys', N'INFORMATION_SCHEMA')
               AND dp.name NOT LIKE N'##%'
               AND NOT EXISTS (
                   SELECT 1 FROM sys.server_principals AS sp
                   WHERE sp.sid = dp.sid AND sp.type IN ('S', 'U', 'G', 'E', 'X')))
        ORDER BY dp.name
        """;

    public const string ServerRoleMembers = """
        SELECT m.name, r.name
        FROM sys.server_role_members AS rm
        JOIN sys.server_principals AS r ON r.principal_id = rm.role_principal_id
        JOIN sys.server_principals AS m ON m.principal_id = rm.member_principal_id
        """;

    public static string DatabaseRoleMembers(string database) => $"""
        SELECT m.name, r.name
        FROM {View("database_role_members", database)} AS rm
        JOIN {View("database_principals", database)} AS r ON r.principal_id = rm.role_principal_id
        JOIN {View("database_principals", database)} AS m ON m.principal_id = rm.member_principal_id
        """;

    public const string BuiltinPermissions = """
        SELECT class_desc, permission_name
        FROM sys.fn_builtin_permissions(DEFAULT)
        WHERE class_desc IN (N'SERVER', N'DATABASE', N'SCHEMA', N'OBJECT')
        ORDER BY class_desc, permission_name
        """;

    // Class 100 is the server itself; endpoints and logins as securables are other classes. W is WITH GRANT OPTION.
    public const string ServerPermissions = """
        SELECT p.permission_name, p.state
        FROM sys.server_permissions AS p
        JOIN sys.server_principals AS g ON g.principal_id = p.grantee_principal_id
        WHERE g.name = @grantee AND p.class = 100 AND p.state IN ('G', 'W')
        ORDER BY p.permission_name
        """;

    // Class 0 is the database, 3 a schema, 1 an object (a column when minor_id is set). DENY is left out.
    public static string DatabasePermissions(string database) => $"""
        SELECT p.class, p.permission_name, p.state, COALESCE(s.name, os.name), o.name, c.name
        FROM {View("database_permissions", database)} AS p
        JOIN {View("database_principals", database)} AS g ON g.principal_id = p.grantee_principal_id
        LEFT JOIN {View("schemas", database)} AS s ON p.class = 3 AND s.schema_id = p.major_id
        LEFT JOIN {View("objects", database)} AS o ON p.class = 1 AND o.object_id = p.major_id
        LEFT JOIN {View("schemas", database)} AS os ON os.schema_id = o.schema_id
        LEFT JOIN {View("columns", database)} AS c ON p.class = 1 AND p.minor_id <> 0 AND c.object_id = p.major_id AND c.column_id = p.minor_id
        WHERE g.name = @grantee AND p.state IN ('G', 'W') AND (p.class IN (0, 3) OR (p.class = 1 AND o.type IN ('U', 'V')))
        ORDER BY p.class, 4, 5, 6, p.permission_name
        """;

    // The schemas the sidebar lists: not sys, INFORMATION_SCHEMA, guest, or a fixed role's schema (16384 and up).
    public static string Schemas(string database) => $"""
        SELECT s.name FROM {View("schemas", database)} AS s
        WHERE s.schema_id < 16384 AND s.name NOT IN (N'sys', N'INFORMATION_SCHEMA', N'guest')
        ORDER BY s.name
        """;

    public static string Objects(string database) => $"""
        SELECT o.name
        FROM {View("objects", database)} AS o
        JOIN {View("schemas", database)} AS s ON s.schema_id = o.schema_id
        WHERE s.name = @schema AND o.type IN ('U', 'V') AND o.is_ms_shipped = 0
        ORDER BY o.name
        """;

    public static string Columns(string database) => $"""
        SELECT c.name
        FROM {View("columns", database)} AS c
        JOIN {View("objects", database)} AS o ON o.object_id = c.object_id
        JOIN {View("schemas", database)} AS s ON s.schema_id = o.schema_id
        WHERE s.name = @schema AND o.name = @object
        ORDER BY c.column_id
        """;

    public static string SearchObjects(string database) => $"""
        SELECT TOP (@limit) s.name, o.name
        FROM {View("objects", database)} AS o
        JOIN {View("schemas", database)} AS s ON s.schema_id = o.schema_id
        WHERE o.type IN ('U', 'V') AND o.is_ms_shipped = 0 AND o.name LIKE @pattern ESCAPE '\'
        ORDER BY s.name, o.name
        """;

    /// <summary>
    /// [ opens a character class in a T-SQL LIKE pattern, so it is escaped with the other metacharacters; otherwise a
    /// search for a[bc] would find ab and ac and never the name typed.
    /// </summary>
    public static string ContainsPattern(string text) =>
        "%" + text.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("%", "\\%", StringComparison.Ordinal)
            .Replace("_", "\\_", StringComparison.Ordinal).Replace("[", "\\[", StringComparison.Ordinal) + "%";

    // EXECUTE is for modules and RECEIVE for queues, never a table or view.
    private static readonly HashSet<string> ExcludedObjectPermissions = ["EXECUTE", "RECEIVE"];

    private static readonly string[] DataOrder = ["SELECT", "INSERT", "UPDATE", "DELETE", "EXECUTE"];

    public static readonly IReadOnlyList<string> ColumnPermissions = ["SELECT", "UPDATE", "REFERENCES"];

    /// <summary>The permissions fn_builtin_permissions lists for each class, data permissions first and the rest by name.</summary>
    public static PrivilegeCatalog BuildCatalog(IEnumerable<(string Class, string Permission)> rows)
    {
        var byClass = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var (permissionClass, permission) in rows)
        {
            if (PrivilegeName.Sanitize(permission) is not { } name)
            {
                continue;
            }

            if (!byClass.TryGetValue(permissionClass, out var names))
            {
                names = [];
                byClass[permissionClass] = names;
            }

            if (!names.Contains(name))
            {
                names.Add(name);
            }
        }

        IReadOnlyList<PrivilegeDescriptor> Descriptors(string permissionClass, Func<string, bool>? keep = null) =>
            Ordered(byClass.TryGetValue(permissionClass, out var names) ? names.Where(keep ?? (_ => true)) : [])
                .Select(n => new PrivilegeDescriptor(n, n, Category(n)))
                .ToArray();

        return new PrivilegeCatalog(
            Descriptors("SERVER"),
            Descriptors("DATABASE"),
            Descriptors("SCHEMA"),
            Descriptors("OBJECT", n => !ExcludedObjectPermissions.Contains(n)),
            [.. ColumnPermissions.Select(n => new PrivilegeDescriptor(n, n, Category(n)))]);
    }

    public static string Category(string permission) =>
        DataOrder.Contains(permission) ? PrivilegeCategoryKeys.Data
        : permission.StartsWith("CREATE ", StringComparison.Ordinal) || permission.StartsWith("ALTER", StringComparison.Ordinal) || permission == "REFERENCES"
            ? PrivilegeCategoryKeys.Structure
            : PrivilegeCategoryKeys.Administration;

    /// <summary>A row of <see cref="DatabasePermissions"/> as a grant on the listed database, or null for a class the editor skips.</summary>
    public static PrincipalGrant? DatabaseGrant(string database, int permissionClass, string permission, string? state, string? schema, string? obj, string? column)
    {
        var grantable = IsGrantable(state);
        return permissionClass switch
        {
            0 => new PrincipalGrant(permission, PrivilegeScope.ForDatabase(database), grantable),
            3 when schema is not null => new PrincipalGrant(permission, PrivilegeScope.ForSchema(database, schema), grantable),
            1 when schema is not null && obj is not null => new PrincipalGrant(
                permission,
                column is null ? PrivilegeScope.ForTable(database, schema, obj) : PrivilegeScope.ForColumn(database, schema, obj, column),
                grantable),
            _ => null,
        };
    }

    public static bool IsGrantable(string? state) => string.Equals(state?.Trim(), "W", StringComparison.OrdinalIgnoreCase);

    private static IEnumerable<string> Ordered(IEnumerable<string> names)
    {
        var list = names.ToList();
        return DataOrder.Where(list.Contains).Concat(list.Where(n => !DataOrder.Contains(n)).Order(StringComparer.Ordinal));
    }

    private static string View(string name, string database) => $"{SqlServerDialect.Instance.QuoteIdentifier(database)}.sys.{name}";
}
