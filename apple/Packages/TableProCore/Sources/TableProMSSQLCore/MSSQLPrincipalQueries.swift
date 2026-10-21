import Foundation

public enum MSSQLPrincipalQueries {
    public static let currentDatabase = "SELECT DB_NAME()"
    public static let currentLogin = "SELECT SUSER_SNAME()"

    // Every database view is read through the database the list was loaded on, which the session may have left since.
    // ##...## logins are certificate logins the server creates for itself.
    public static func logins(database: String) -> String {
        """
        SELECT sp.name, CAST(sp.is_disabled AS int), dp.name
        FROM sys.server_principals AS sp
        LEFT JOIN \(view("database_principals", in: database)) AS dp
            ON dp.sid = sp.sid AND dp.type IN ('S', 'U', 'G', 'E', 'X')
        WHERE sp.type IN ('S', 'U', 'G', 'E', 'X')
          AND sp.name NOT LIKE N'##%'
        ORDER BY sp.name
        """
    }

    // public holds every login implicitly and takes no members.
    public static let serverRoles = """
        SELECT name
        FROM sys.server_principals
        WHERE type = 'R' AND name <> N'public'
        ORDER BY name
        """

    // Roles, and users no visible login maps to: contained, WITHOUT LOGIN, or orphaned.
    public static func databasePrincipals(database: String) -> String {
        """
        SELECT dp.name, dp.type, CASE WHEN EXISTS (
                SELECT 1
                FROM \(view("database_permissions", in: database)) AS p
                WHERE p.grantee_principal_id = dp.principal_id
                  AND p.class = 0
                  AND p.permission_name = N'CONNECT'
                  AND p.state IN ('G', 'W')
            ) THEN 1 ELSE 0 END
        FROM \(view("database_principals", in: database)) AS dp
        WHERE (dp.type = 'R' AND dp.name <> N'public')
           OR (dp.type IN ('S', 'U', 'G', 'E', 'X', 'C', 'K')
               AND dp.name NOT IN (N'sys', N'INFORMATION_SCHEMA')
               AND dp.name NOT LIKE N'##%'
               AND NOT EXISTS (
                   SELECT 1
                   FROM sys.server_principals AS sp
                   WHERE sp.sid = dp.sid AND sp.type IN ('S', 'U', 'G', 'E', 'X')
               ))
        ORDER BY dp.name
        """
    }

    public static let serverRoleMembers = """
        SELECT m.name, r.name
        FROM sys.server_role_members AS rm
        JOIN sys.server_principals AS r ON r.principal_id = rm.role_principal_id
        JOIN sys.server_principals AS m ON m.principal_id = rm.member_principal_id
        """

    public static func databaseRoleMembers(database: String) -> String {
        """
        SELECT m.name, r.name
        FROM \(view("database_role_members", in: database)) AS rm
        JOIN \(view("database_principals", in: database)) AS r ON r.principal_id = rm.role_principal_id
        JOIN \(view("database_principals", in: database)) AS m ON m.principal_id = rm.member_principal_id
        """
    }

    public static let builtinPermissions = """
        SELECT class_desc, permission_name
        FROM sys.fn_builtin_permissions(DEFAULT)
        WHERE class_desc IN (N'SERVER', N'DATABASE', N'SCHEMA', N'OBJECT')
        ORDER BY class_desc, permission_name
        """

    // Class 100 is the server; endpoints and logins as securables are other classes.
    public static func serverPermissions(grantee: String) -> String {
        """
        SELECT p.permission_name, p.state
        FROM sys.server_permissions AS p
        JOIN sys.server_principals AS g ON g.principal_id = p.grantee_principal_id
        WHERE g.name = \(MSSQLStringLiteral.quoted(grantee))
          AND p.class = 100
          AND p.state IN ('G', 'W')
        ORDER BY p.permission_name
        """
    }

    // Class 0 database, 3 schema, 1 object (a column with minor_id). W is WITH GRANT OPTION; DENY is left out.
    public static func databasePermissions(grantee: String, database: String) -> String {
        """
        SELECT p.class, p.permission_name, p.state, COALESCE(s.name, os.name), o.name, c.name
        FROM \(view("database_permissions", in: database)) AS p
        JOIN \(view("database_principals", in: database)) AS g ON g.principal_id = p.grantee_principal_id
        LEFT JOIN \(view("schemas", in: database)) AS s ON p.class = 3 AND s.schema_id = p.major_id
        LEFT JOIN \(view("objects", in: database)) AS o ON p.class = 1 AND o.object_id = p.major_id
        LEFT JOIN \(view("schemas", in: database)) AS os ON os.schema_id = o.schema_id
        LEFT JOIN \(view("columns", in: database)) AS c
            ON p.class = 1 AND p.minor_id <> 0 AND c.object_id = p.major_id AND c.column_id = p.minor_id
        WHERE g.name = \(MSSQLStringLiteral.quoted(grantee))
          AND p.state IN ('G', 'W')
          AND (p.class IN (0, 3) OR (p.class = 1 AND o.type IN ('U', 'V')))
        ORDER BY p.class, 4, 5, 6, p.permission_name
        """
    }

    // The same schemas the sidebar lists: not sys, INFORMATION_SCHEMA, guest, or a fixed role's schema (16384 and up).
    public static func schemas(database: String) -> String {
        """
        SELECT s.name
        FROM \(view("schemas", in: database)) AS s
        WHERE s.schema_id < 16384
          AND s.name NOT IN (N'sys', N'INFORMATION_SCHEMA', N'guest')
        ORDER BY s.name
        """
    }

    public static func objects(schema: String, database: String) -> String {
        """
        SELECT o.name
        FROM \(view("objects", in: database)) AS o
        JOIN \(view("schemas", in: database)) AS s ON s.schema_id = o.schema_id
        WHERE s.name = \(MSSQLStringLiteral.quoted(schema))
          AND o.type IN ('U', 'V')
          AND o.is_ms_shipped = 0
        ORDER BY o.name
        """
    }

    public static func columns(schema: String, object: String, database: String) -> String {
        """
        SELECT c.name
        FROM \(view("columns", in: database)) AS c
        JOIN \(view("objects", in: database)) AS o ON o.object_id = c.object_id
        JOIN \(view("schemas", in: database)) AS s ON s.schema_id = o.schema_id
        WHERE s.name = \(MSSQLStringLiteral.quoted(schema))
          AND o.name = \(MSSQLStringLiteral.quoted(object))
        ORDER BY c.column_id
        """
    }

    public static func searchObjects(matching text: String, limit: Int, database: String) -> String {
        """
        SELECT TOP (\(max(1, limit))) s.name, o.name
        FROM \(view("objects", in: database)) AS o
        JOIN \(view("schemas", in: database)) AS s ON s.schema_id = o.schema_id
        WHERE o.type IN ('U', 'V')
          AND o.is_ms_shipped = 0
          AND o.name LIKE \(MSSQLStringLiteral.likePattern(text, prefixWildcard: true, suffixWildcard: true))
        ORDER BY s.name, o.name
        """
    }

    private static func view(_ name: String, in database: String) -> String {
        "[\(MSSQLSchemaQueries.escapeBracket(database))].sys.\(name)"
    }

    // MARK: - Rows

    public static func parseLogins(_ rows: [[String?]]) -> [MSSQLPrincipalDirectory.LoginRow] {
        rows.compactMap { row in
            guard let name = row.first ?? nil else { return nil }
            return MSSQLPrincipalDirectory.LoginRow(
                name: name,
                isDisabled: isTrue(row[safe: 1]),
                user: row[safe: 2] ?? nil
            )
        }
    }

    public static func parseNames(_ rows: [[String?]]) -> [String] {
        rows.compactMap { $0.first ?? nil }
    }

    public static func parseDatabasePrincipals(_ rows: [[String?]]) -> [MSSQLPrincipalDirectory.DatabasePrincipalRow] {
        rows.compactMap { row in
            guard let name = row.first ?? nil, let type = row[safe: 1] ?? nil else { return nil }
            return MSSQLPrincipalDirectory.DatabasePrincipalRow(
                name: name,
                isRole: type.trimmingCharacters(in: .whitespaces) == "R",
                hasConnect: isTrue(row[safe: 2])
            )
        }
    }

    public static func parseMemberships(_ rows: [[String?]]) -> [MSSQLPrincipalDirectory.MembershipRow] {
        rows.compactMap { row in
            guard let member = row.first ?? nil, let role = row[safe: 1] ?? nil else { return nil }
            return MSSQLPrincipalDirectory.MembershipRow(member: member, role: role)
        }
    }

    public static func parseServerPermissions(_ rows: [[String?]]) -> [MSSQLGrant] {
        rows.compactMap { row in
            guard let permission = row.first ?? nil else { return nil }
            return MSSQLGrant(permission: permission, securable: .server, withGrantOption: isGrantable(row[safe: 1]))
        }
    }

    public static func parseDatabasePermissions(_ rows: [[String?]]) -> [MSSQLGrant] {
        rows.compactMap { row in
            guard let permissionClass = (row.first ?? nil).flatMap({ Int($0) }),
                  let permission = row[safe: 1] ?? nil else { return nil }
            let withGrantOption = isGrantable(row[safe: 2])
            let schema = row[safe: 3] ?? nil
            let object = row[safe: 4] ?? nil
            let column = row[safe: 5] ?? nil

            switch permissionClass {
            case 0:
                return MSSQLGrant(permission: permission, securable: .database, withGrantOption: withGrantOption)
            case 3:
                guard let schema else { return nil }
                return MSSQLGrant(permission: permission, securable: .schema(schema), withGrantOption: withGrantOption)
            case 1:
                guard let schema, let object else { return nil }
                return MSSQLGrant(
                    permission: permission,
                    securable: .object(schema: schema, name: object),
                    column: column,
                    withGrantOption: withGrantOption
                )
            default:
                return nil
            }
        }
    }

    private static func isTrue(_ cell: String??) -> Bool {
        guard let value = cell ?? nil else { return false }
        return value == "1" || value.lowercased() == "true"
    }

    private static func isGrantable(_ state: String??) -> Bool {
        (state ?? nil)?.trimmingCharacters(in: .whitespaces).uppercased() == "W"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
