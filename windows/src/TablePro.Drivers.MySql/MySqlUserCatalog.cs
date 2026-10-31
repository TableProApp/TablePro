using TablePro.Core.Principals;

namespace TablePro.Drivers.MySql;

/// <summary>The queries behind the Users and Roles editor, and the reading of SHOW PRIVILEGES into a catalog.</summary>
internal static class MySqlUserCatalog
{
    public const string PrincipalsWithLimit = "SELECT User, Host, max_user_connections FROM mysql.user ORDER BY User, Host";

    // TiDB's mysql.user has no max_user_connections column.
    public const string Principals = "SELECT User, Host FROM mysql.user ORDER BY User, Host";

    public const string Session = "SELECT CURRENT_USER(), @@SESSION.sql_mode, VERSION()";

    public const string Privileges = "SHOW PRIVILEGES";

    public const string Tables = "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = @database ORDER BY TABLE_NAME";

    public const string Columns = """
        SELECT COLUMN_NAME FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = @database AND TABLE_NAME = @table
        ORDER BY ORDINAL_POSITION
        """;

    public const string SearchObjects = """
        SELECT TABLE_SCHEMA, TABLE_NAME FROM information_schema.TABLES
        WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
          AND TABLE_NAME LIKE @pattern ESCAPE '!'
        ORDER BY TABLE_SCHEMA, TABLE_NAME
        LIMIT @limit
        """;

    // MySQL's static privileges are a closed set; anything else SHOW PRIVILEGES lists is a dynamic privilege a
    // component registered (MySQL 8). Classifying by membership keeps CREATE_TABLESPACE_ADMIN from being called static.
    private static readonly HashSet<string> DataPrivileges = ["SELECT", "INSERT", "UPDATE", "DELETE", "EXECUTE", "SHOW VIEW", "LOCK TABLES"];

    private static readonly HashSet<string> StructurePrivileges =
    [
        "CREATE", "DROP", "ALTER", "INDEX", "CREATE VIEW", "CREATE ROUTINE", "ALTER ROUTINE", "CREATE TEMPORARY TABLES", "EVENT", "TRIGGER",
        "REFERENCES", "CREATE TABLESPACE",
    ];

    private static readonly HashSet<string> AdministrationPrivileges =
    [
        "CREATE USER", "CREATE ROLE", "DROP ROLE", "FILE", "PROCESS", "RELOAD", "REPLICATION CLIENT", "REPLICATION SLAVE", "SHOW DATABASES",
        "SHUTDOWN", "SUPER", "GRANT OPTION", "PROXY", "USAGE",
    ];

    // GRANT OPTION is the WITH GRANT OPTION clause, and PROXY is granted on an account rather than an object.
    private static readonly HashSet<string> Excluded = ["GRANT OPTION", "PROXY"];

    private static readonly string[] DatabaseContexts = ["DATABASE", "TABLE", "INDEX", "VIEW", "TRIGGER", "EVENT", "FUNCTION", "PROCEDURE"];

    private static readonly string[] TableContexts = ["TABLE", "INDEX", "VIEW", "TRIGGER"];

    private static readonly HashSet<string> ColumnPrivileges = ["SELECT", "INSERT", "UPDATE", "REFERENCES"];

    public static bool IsDynamic(string name) => !DataPrivileges.Contains(name) && !StructurePrivileges.Contains(name) && !AdministrationPrivileges.Contains(name);

    public static string Category(string name) =>
        DataPrivileges.Contains(name) ? PrivilegeCategoryKeys.Data
        : StructurePrivileges.Contains(name) ? PrivilegeCategoryKeys.Structure
        : AdministrationPrivileges.Contains(name) ? PrivilegeCategoryKeys.Administration
        : PrivilegeCategoryKeys.Dynamic;

    /// <summary>
    /// Every privilege can be granted globally. Its Context column says where else: "Databases,Tables" reaches both
    /// levels below. Dynamic privileges are global only.
    /// </summary>
    public static PrivilegeCatalog Build(IEnumerable<(string Privilege, string? Context)> rows)
    {
        List<PrivilegeDescriptor> server = [], database = [], table = [], column = [];
        var dynamic = false;
        foreach (var (raw, context) in rows)
        {
            if (PrivilegeName.Sanitize(raw) is not { } name || Excluded.Contains(name))
            {
                continue;
            }

            var descriptor = new PrivilegeDescriptor(name, raw.Trim(), Category(name));
            server.Add(descriptor);
            if (IsDynamic(name))
            {
                dynamic = true;
                continue;
            }

            var where = (context ?? string.Empty).ToUpperInvariant();
            if (DatabaseContexts.Any(where.Contains))
            {
                database.Add(descriptor);
            }

            if (TableContexts.Any(where.Contains))
            {
                table.Add(descriptor);
            }

            if (ColumnPrivileges.Contains(name))
            {
                column.Add(descriptor);
            }
        }

        return new PrivilegeCatalog(server, database, [], table, column, dynamic);
    }

    /// <summary>The account's grants as the editor keys them; ALL PRIVILEGES stands for every privilege of its level.</summary>
    public static IEnumerable<PrincipalGrant> Expand(MySqlParsedGrant parsed, PrivilegeCatalog catalog)
    {
        foreach (var privilege in parsed.Privileges)
        {
            if (privilege.Columns.Count > 0)
            {
                if (parsed.Scope.Level != PrivilegeLevel.Table)
                {
                    continue;
                }

                foreach (var name in privilege.Columns)
                {
                    yield return new PrincipalGrant(privilege.Name, PrivilegeScope.ForColumn(parsed.Scope.Database!, null, parsed.Scope.Table!, name), parsed.IsGrantable);
                }

                continue;
            }

            var names = privilege.Name == MySqlGrantParser.AllPrivileges ? catalog.For(parsed.Scope).Select(d => d.Name) : [privilege.Name];
            foreach (var name in names)
            {
                yield return new PrincipalGrant(name, parsed.Scope, parsed.IsGrantable);
            }
        }
    }

    // ! rather than the default backslash, which NO_BACKSLASH_ESCAPES takes away from LIKE as well.
    public static string ContainsPattern(string text) =>
        "%" + text.Replace("!", "!!", StringComparison.Ordinal).Replace("%", "!%", StringComparison.Ordinal).Replace("_", "!_", StringComparison.Ordinal) + "%";

    /// <summary>CURRENT_USER() answers user@host unquoted; the host never holds an @, so the last one splits them.</summary>
    public static PrincipalRef ParseAccount(string value)
    {
        var at = value.LastIndexOf('@');
        return at < 0 ? new PrincipalRef(value, MySqlUserSql.DefaultHost) : new PrincipalRef(value[..at], value[(at + 1)..]);
    }
}
