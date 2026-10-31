namespace TablePro.Drivers.PostgreSql;

/// <summary>
/// The catalog queries behind the Users and Roles editor. Grants come from aclexplode over each object's ACL, which
/// reports what was granted to the role itself; what it inherits from its roles is worked out in the app.
/// </summary>
internal static class PostgreSqlUserCatalog
{
    // pg_% roles are the server's predefined roles; they cannot be altered or dropped.
    public static string Principals(bool includeBypassRls) => $"""
        SELECT r.rolname, r.rolcanlogin, r.rolsuper, r.rolcreatedb, r.rolcreaterole, r.rolreplication,
               {(includeBypassRls ? "r.rolbypassrls" : "false")}, r.rolinherit, r.rolconnlimit,
               pg_catalog.shobj_description(r.oid, 'pg_authid'),
               ARRAY(SELECT b.rolname::text FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles b ON b.oid = m.roleid
                     WHERE m.member = r.oid ORDER BY b.rolname)
        FROM pg_catalog.pg_roles r
        WHERE r.rolname NOT LIKE 'pg!_%' ESCAPE '!'
        ORDER BY r.rolname
        """;

    public const string Session = "SELECT current_setting('server_version_num')::int, current_user::text, current_database()::text";

    public const string DatabaseGrants = """
        SELECT s.datname::text, (s.acl).privilege_type, (s.acl).is_grantable
        FROM (
            SELECT d.datname, pg_catalog.aclexplode(d.datacl) AS acl
            FROM pg_catalog.pg_database d
            WHERE d.datacl IS NOT NULL AND NOT d.datistemplate
        ) s
        JOIN pg_catalog.pg_roles r ON r.oid = (s.acl).grantee
        WHERE r.rolname = @role
        ORDER BY 1, 2
        """;

    public const string SchemaGrants = """
        SELECT s.nspname::text, (s.acl).privilege_type, (s.acl).is_grantable
        FROM (
            SELECT n.nspname, pg_catalog.aclexplode(n.nspacl) AS acl
            FROM pg_catalog.pg_namespace n
            WHERE n.nspacl IS NOT NULL AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        ) s
        JOIN pg_catalog.pg_roles r ON r.oid = (s.acl).grantee
        WHERE r.rolname = @role
        ORDER BY 1, 2
        """;

    public const string TableGrants = """
        SELECT s.nspname::text, s.relname::text, (s.acl).privilege_type, (s.acl).is_grantable
        FROM (
            SELECT n.nspname, c.relname, pg_catalog.aclexplode(c.relacl) AS acl
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relacl IS NOT NULL
              AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
              AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        ) s
        JOIN pg_catalog.pg_roles r ON r.oid = (s.acl).grantee
        WHERE r.rolname = @role
        ORDER BY 1, 2, 3
        """;

    public const string ColumnGrants = """
        SELECT s.nspname::text, s.relname::text, s.attname::text, (s.acl).privilege_type, (s.acl).is_grantable
        FROM (
            SELECT n.nspname, c.relname, a.attname, pg_catalog.aclexplode(a.attacl) AS acl
            FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE a.attacl IS NOT NULL AND a.attnum > 0 AND NOT a.attisdropped
              AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        ) s
        JOIN pg_catalog.pg_roles r ON r.oid = (s.acl).grantee
        WHERE r.rolname = @role
        ORDER BY 1, 2, 3, 4
        """;

    public const string Schemas = """
        SELECT n.nspname::text
        FROM pg_catalog.pg_namespace n
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg!_%' ESCAPE '!'
        ORDER BY 1
        """;

    public const string Tables = """
        SELECT c.relname::text
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = @schema AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
        ORDER BY 1
        """;

    public const string Columns = """
        SELECT a.attname::text
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = @schema AND c.relname = @table AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
        """;

    // The pattern is bound with its LIKE metacharacters escaped, so a typed % or _ matches itself.
    public const string SearchObjects = """
        SELECT n.nspname::text, c.relname::text
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'v', 'm', 'p', 'f')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND c.relname ILIKE @pattern
        ORDER BY 1, 2
        LIMIT @limit
        """;

    // 'o' is ownership and 'a' an ACL entry; either makes DROP ROLE fail until the objects are dealt with.
    public const string OwnsObjects = """
        SELECT EXISTS (
            SELECT 1 FROM pg_catalog.pg_shdepend s
            JOIN pg_catalog.pg_roles r ON r.oid = s.refobjid
            WHERE r.rolname = @role AND s.deptype IN ('o', 'a'))
        """;

    public static string ContainsPattern(string text) =>
        "%" + text.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("%", "\\%", StringComparison.Ordinal).Replace("_", "\\_", StringComparison.Ordinal) + "%";
}
