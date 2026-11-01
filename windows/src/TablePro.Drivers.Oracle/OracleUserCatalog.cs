using System.Text;
using TablePro.Core.Principals;

namespace TablePro.Drivers.Oracle;

/// <summary>
/// The DBA_ views need SELECT_CATALOG_ROLE or SELECT ANY DICTIONARY; without them the ALL_, USER_ and ROLE_ views show
/// what the account itself can see, so every read has both spellings.
/// </summary>
internal enum OracleDictionaryAccess
{
    Dba,
    Session,
}

/// <summary>The dictionary reads behind the Users and Roles editor. Names are bound, never spliced.</summary>
internal static class OracleUserCatalog
{
    public const string DbaProbe = "SELECT 1 FROM SYS.DBA_USERS WHERE ROWNUM = 1";

    public const string CurrentUser = "SELECT USER FROM DUAL";

    // SYSDBA and the like are granted through the password file and never appear in DBA_SYS_PRIVS.
    public const string SystemPrivilegeMap = """
        SELECT NAME FROM SYS.SYSTEM_PRIVILEGE_MAP
        WHERE NAME NOT IN ('SYSDBA', 'SYSOPER', 'SYSASM', 'SYSBACKUP', 'SYSDG', 'SYSKM', 'SYSRAC')
        ORDER BY NAME
        """;

    // Oracle-maintained accounts are system schemas; their roles stay, since CONNECT, RESOURCE and DBA are what gets granted.
    public static string Users(OracleDictionaryAccess access) => access == OracleDictionaryAccess.Dba
        ? "SELECT USERNAME, ACCOUNT_STATUS FROM SYS.DBA_USERS WHERE ORACLE_MAINTAINED = 'N' ORDER BY USERNAME"
        : "SELECT USERNAME, NULL FROM SYS.ALL_USERS WHERE ORACLE_MAINTAINED = 'N' ORDER BY USERNAME";

    public static string Roles(OracleDictionaryAccess access) => access == OracleDictionaryAccess.Dba
        ? "SELECT ROLE FROM SYS.DBA_ROLES ORDER BY ROLE"
        : """
          SELECT GRANTED_ROLE FROM SYS.USER_ROLE_PRIVS
          UNION SELECT GRANTED_ROLE FROM SYS.ROLE_ROLE_PRIVS
          UNION SELECT ROLE FROM SYS.ROLE_ROLE_PRIVS
          ORDER BY 1
          """;

    public static string RoleGrants(OracleDictionaryAccess access) => access == OracleDictionaryAccess.Dba
        ? "SELECT GRANTEE, GRANTED_ROLE FROM SYS.DBA_ROLE_PRIVS"
        : """
          SELECT USERNAME, GRANTED_ROLE FROM SYS.USER_ROLE_PRIVS WHERE USERNAME <> 'PUBLIC'
          UNION ALL SELECT ROLE, GRANTED_ROLE FROM SYS.ROLE_ROLE_PRIVS
          """;

    public static string SystemPrivileges(OracleDictionaryAccess access) => access == OracleDictionaryAccess.Dba
        ? "SELECT PRIVILEGE, ADMIN_OPTION FROM SYS.DBA_SYS_PRIVS WHERE GRANTEE = :grantee ORDER BY PRIVILEGE"
        : """
          SELECT PRIVILEGE, ADMIN_OPTION FROM SYS.USER_SYS_PRIVS WHERE USERNAME = :grantee
          UNION ALL SELECT PRIVILEGE, ADMIN_OPTION FROM SYS.ROLE_SYS_PRIVS WHERE ROLE = :grantee
          """;

    // Tables and views only: EXECUTE on a package or READ on a directory would show as a table that does not exist.
    public static string ObjectPrivileges(OracleDictionaryAccess access)
    {
        var (privileges, objects, owner) = access == OracleDictionaryAccess.Dba
            ? ("SYS.DBA_TAB_PRIVS", "SYS.DBA_OBJECTS", "OWNER")
            : ("SYS.ALL_TAB_PRIVS", "SYS.ALL_OBJECTS", "TABLE_SCHEMA");
        return $"""
            SELECT DISTINCT p.{owner}, p.TABLE_NAME, p.PRIVILEGE, p.GRANTABLE
            FROM {privileges} p
            WHERE p.GRANTEE = :grantee
              AND EXISTS (
                  SELECT 1 FROM {objects} o
                  WHERE o.OWNER = p.{owner} AND o.OBJECT_NAME = p.TABLE_NAME AND o.OBJECT_TYPE IN ('TABLE', 'VIEW'))
            ORDER BY 1, 2, 3
            """;
    }

    public static string ColumnPrivileges(OracleDictionaryAccess access)
    {
        var (view, owner) = access == OracleDictionaryAccess.Dba ? ("SYS.DBA_COL_PRIVS", "OWNER") : ("SYS.ALL_COL_PRIVS", "TABLE_SCHEMA");
        return $"""
            SELECT DISTINCT {owner}, TABLE_NAME, COLUMN_NAME, PRIVILEGE, GRANTABLE
            FROM {view}
            WHERE GRANTEE = :grantee
            ORDER BY 1, 2, 3, 4
            """;
    }

    public const string Objects = """
        SELECT TABLE_NAME FROM SYS.ALL_TABLES WHERE OWNER = :owner
        UNION SELECT VIEW_NAME FROM SYS.ALL_VIEWS WHERE OWNER = :owner
        ORDER BY 1
        """;

    public const string Columns = "SELECT COLUMN_NAME FROM SYS.ALL_TAB_COLUMNS WHERE OWNER = :owner AND TABLE_NAME = :tbl ORDER BY COLUMN_ID";

    public const string SearchObjects = """
        SELECT DISTINCT OWNER, OBJECT_NAME FROM SYS.ALL_OBJECTS
        WHERE OBJECT_TYPE IN ('TABLE', 'VIEW')
          AND UPPER(OBJECT_NAME) LIKE :pattern ESCAPE '\'
          AND OWNER IN (SELECT USERNAME FROM SYS.ALL_USERS WHERE ORACLE_MAINTAINED = 'N')
        ORDER BY OWNER, OBJECT_NAME
        FETCH FIRST :limit ROWS ONLY
        """;

    /// <summary>A LIKE pattern for names containing <paramref name="text"/>, with the wildcards in it taken literally.</summary>
    public static string ContainsPattern(string text)
    {
        var builder = new StringBuilder("%");
        foreach (var c in text.Trim().ToUpperInvariant())
        {
            if (c is '\\' or '%' or '_')
            {
                builder.Append('\\');
            }

            builder.Append(c);
        }

        return builder.Append('%').ToString();
    }

    /// <summary>LOCKED, LOCKED(TIMED) or EXPIRED &amp; LOCKED; ALL_USERS has no status and reads as open.</summary>
    public static bool IsLocked(string? accountStatus) => accountStatus?.Contains("LOCKED", StringComparison.OrdinalIgnoreCase) == true;

    public static bool IsYes(string? value) => string.Equals(value, "YES", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The principals the editor lists: users that are not also roles, then roles, each with the roles granted to it.
    /// </summary>
    public static IReadOnlyList<PrincipalInfo> Principals(
        IReadOnlyList<(string Name, bool IsLocked)> users,
        IReadOnlyList<string> roles,
        IReadOnlyList<(string Grantee, string Role)> roleGrants)
    {
        var roleNames = roles.ToHashSet(StringComparer.Ordinal);
        var memberOf = new Dictionary<string, SortedSet<string>>(StringComparer.Ordinal);
        foreach (var (grantee, role) in roleGrants)
        {
            if (!roleNames.Contains(role))
            {
                continue;
            }

            if (!memberOf.TryGetValue(grantee, out var set))
            {
                set = new SortedSet<string>(StringComparer.Ordinal);
                memberOf[grantee] = set;
            }

            set.Add(role);
        }

        IReadOnlyList<string> MemberOf(string name) => memberOf.TryGetValue(name, out var set) ? [.. set] : [];

        var principals = new List<PrincipalInfo>(users.Count + roles.Count);
        principals.AddRange(users
            .Where(u => !roleNames.Contains(u.Name))
            .Select(u => new PrincipalInfo(new PrincipalRef(u.Name), IsRole: false, CanLogin: !u.IsLocked, [], MemberOf(u.Name))));
        principals.AddRange(roles.Select(r => new PrincipalInfo(new PrincipalRef(r), IsRole: true, CanLogin: false, [], MemberOf(r))));
        return principals;
    }

    /// <summary>The checklist group of a system privilege, read from its name.</summary>
    public static PrivilegeDescriptor SystemPrivilege(string name)
    {
        string category;
        if (name == "CREATE SESSION")
        {
            category = PrivilegeCategoryKeys.Administration;
        }
        else if (name.StartsWith("CREATE ", StringComparison.Ordinal) || name.StartsWith("ALTER ", StringComparison.Ordinal) || name.StartsWith("DROP ", StringComparison.Ordinal))
        {
            category = PrivilegeCategoryKeys.Structure;
        }
        else if (DataPrefixes.Any(p => name.StartsWith(p, StringComparison.Ordinal)))
        {
            category = PrivilegeCategoryKeys.Data;
        }
        else
        {
            category = PrivilegeCategoryKeys.Administration;
        }

        return new PrivilegeDescriptor(name, name, category);
    }

    // READ arrived in 12.1, the oldest release this driver lists users for; it reads without the row locks SELECT ... FOR UPDATE takes.
    public static readonly IReadOnlyList<PrivilegeDescriptor> TablePrivileges =
    [
        new("SELECT", "SELECT", PrivilegeCategoryKeys.Data),
        new("INSERT", "INSERT", PrivilegeCategoryKeys.Data),
        new("UPDATE", "UPDATE", PrivilegeCategoryKeys.Data),
        new("DELETE", "DELETE", PrivilegeCategoryKeys.Data),
        new("READ", "READ", PrivilegeCategoryKeys.Data),
        new("ALTER", "ALTER", PrivilegeCategoryKeys.Structure),
        new("INDEX", "INDEX", PrivilegeCategoryKeys.Structure),
        new("REFERENCES", "REFERENCES", PrivilegeCategoryKeys.Structure),
        new("FLASHBACK", "FLASHBACK", PrivilegeCategoryKeys.Administration),
        new("DEBUG", "DEBUG", PrivilegeCategoryKeys.Administration),
    ];

    // Oracle takes only these on a column; SELECT is granted on the whole table or through a view.
    public static readonly IReadOnlyList<PrivilegeDescriptor> ColumnPrivilegeList =
    [
        new("INSERT", "INSERT", PrivilegeCategoryKeys.Data),
        new("UPDATE", "UPDATE", PrivilegeCategoryKeys.Data),
        new("REFERENCES", "REFERENCES", PrivilegeCategoryKeys.Structure),
    ];

    /// <summary>System privileges at the server; schemas take none of their own, tables and columns the object privileges.</summary>
    public static PrivilegeCatalog Catalog(IEnumerable<string> systemPrivileges) =>
        new([.. systemPrivileges.Where(n => PrivilegeName.Sanitize(n) is not null).Select(SystemPrivilege)], [], [], TablePrivileges, ColumnPrivilegeList);

    private static readonly string[] DataPrefixes = ["SELECT ANY", "INSERT ANY", "UPDATE ANY", "DELETE ANY", "EXECUTE ANY", "READ ANY"];
}
