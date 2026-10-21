import Foundation

// DBA_ views need SELECT_CATALOG_ROLE or SELECT ANY DICTIONARY; without them the ALL_, USER_ and ROLE_ views show what the account can see.
public enum OracleDictionaryAccess: Sendable, Equatable {
    case dba
    case session
}

public struct OraclePrincipalRow: Sendable, Equatable {
    public let name: String
    public let isLocked: Bool

    public init(name: String, isLocked: Bool) {
        self.name = name
        self.isLocked = isLocked
    }
}

public struct OracleRoleGrantRow: Sendable, Equatable {
    public let grantee: String
    public let role: String

    public init(grantee: String, role: String) {
        self.grantee = grantee
        self.role = role
    }
}

public enum OraclePrincipalQueries {
    public static let dbaProbe = "SELECT 1 FROM \(OracleDictionary.view("DBA_USERS")) WHERE ROWNUM = 1"
    public static let currentUser = "SELECT USER FROM \(OracleDictionary.dual)"

    // SYSDBA and the like are granted through the password file and never appear in DBA_SYS_PRIVS.
    public static let systemPrivilegeMap = """
        SELECT NAME FROM \(OracleDictionary.view("SYSTEM_PRIVILEGE_MAP"))
        WHERE NAME NOT IN ('SYSDBA', 'SYSOPER', 'SYSASM', 'SYSBACKUP', 'SYSDG', 'SYSKM', 'SYSRAC')
        ORDER BY NAME
        """

    // Oracle-maintained accounts (12.1+) are system schemas; their roles stay, since CONNECT, RESOURCE and DBA are what gets granted.
    public static func users(access: OracleDictionaryAccess, release: OracleServerRelease?) -> String {
        let filter = (release?.major ?? 12) >= 12 ? "WHERE ORACLE_MAINTAINED = 'N'\n" : ""
        switch access {
        case .dba:
            return """
                SELECT USERNAME, ACCOUNT_STATUS FROM \(OracleDictionary.view("DBA_USERS"))
                \(filter)ORDER BY USERNAME
                """
        case .session:
            return """
                SELECT USERNAME, NULL FROM \(OracleDictionary.allUsers)
                \(filter)ORDER BY USERNAME
                """
        }
    }

    public static func roles(access: OracleDictionaryAccess) -> String {
        switch access {
        case .dba:
            return "SELECT ROLE FROM \(OracleDictionary.view("DBA_ROLES")) ORDER BY ROLE"
        case .session:
            return """
                SELECT GRANTED_ROLE FROM \(OracleDictionary.view("USER_ROLE_PRIVS"))
                UNION SELECT GRANTED_ROLE FROM \(OracleDictionary.view("ROLE_ROLE_PRIVS"))
                UNION SELECT ROLE FROM \(OracleDictionary.view("ROLE_ROLE_PRIVS"))
                ORDER BY 1
                """
        }
    }

    public static func roleGrants(access: OracleDictionaryAccess) -> String {
        switch access {
        case .dba:
            return "SELECT GRANTEE, GRANTED_ROLE FROM \(OracleDictionary.view("DBA_ROLE_PRIVS"))"
        case .session:
            return """
                SELECT USERNAME, GRANTED_ROLE FROM \(OracleDictionary.view("USER_ROLE_PRIVS"))
                WHERE USERNAME <> 'PUBLIC'
                UNION ALL SELECT ROLE, GRANTED_ROLE FROM \(OracleDictionary.view("ROLE_ROLE_PRIVS"))
                """
        }
    }

    public static func systemPrivileges(grantee: String, access: OracleDictionaryAccess) -> String {
        let name = literal(grantee)
        switch access {
        case .dba:
            return """
                SELECT PRIVILEGE, ADMIN_OPTION FROM \(OracleDictionary.view("DBA_SYS_PRIVS"))
                WHERE GRANTEE = \(name)
                ORDER BY PRIVILEGE
                """
        case .session:
            return """
                SELECT PRIVILEGE, ADMIN_OPTION FROM \(OracleDictionary.view("USER_SYS_PRIVS"))
                WHERE USERNAME = \(name)
                UNION ALL SELECT PRIVILEGE, ADMIN_OPTION FROM \(OracleDictionary.view("ROLE_SYS_PRIVS"))
                WHERE ROLE = \(name)
                """
        }
    }

    // Tables and views only: EXECUTE on a package or READ on a directory would show as a table that does not exist.
    public static func objectPrivileges(grantee: String, access: OracleDictionaryAccess) -> String {
        let (privileges, objects, owner) = access == .dba
            ? (OracleDictionary.view("DBA_TAB_PRIVS"), OracleDictionary.view("DBA_OBJECTS"), "OWNER")
            : (OracleDictionary.view("ALL_TAB_PRIVS"), OracleDictionary.allObjects, "TABLE_SCHEMA")
        return """
            SELECT DISTINCT p.\(owner), p.TABLE_NAME, p.PRIVILEGE, p.GRANTABLE
            FROM \(privileges) p
            WHERE p.GRANTEE = \(literal(grantee))
              AND EXISTS (
                  SELECT 1 FROM \(objects) o
                  WHERE o.OWNER = p.\(owner) AND o.OBJECT_NAME = p.TABLE_NAME
                    AND o.OBJECT_TYPE IN ('TABLE', 'VIEW')
              )
            ORDER BY 1, 2, 3
            """
    }

    public static func columnPrivileges(grantee: String, access: OracleDictionaryAccess) -> String {
        let (view, owner) = access == .dba
            ? (OracleDictionary.view("DBA_COL_PRIVS"), "OWNER")
            : (OracleDictionary.view("ALL_COL_PRIVS"), "TABLE_SCHEMA")
        return """
            SELECT DISTINCT \(owner), TABLE_NAME, COLUMN_NAME, PRIVILEGE, GRANTABLE
            FROM \(view)
            WHERE GRANTEE = \(literal(grantee))
            ORDER BY 1, 2, 3, 4
            """
    }

    public static func objects(owner: String) -> String {
        let name = literal(owner)
        return """
            SELECT TABLE_NAME FROM \(OracleDictionary.allTables) WHERE OWNER = \(name)
            UNION SELECT VIEW_NAME FROM \(OracleDictionary.allViews) WHERE OWNER = \(name)
            ORDER BY 1
            """
    }

    public static func columns(owner: String, table: String) -> String {
        """
        SELECT COLUMN_NAME FROM \(OracleDictionary.view("ALL_TAB_COLUMNS"))
        WHERE OWNER = \(literal(owner)) AND TABLE_NAME = \(literal(table))
        ORDER BY COLUMN_ID
        """
    }

    // ROWNUM, since 11g has no FETCH FIRST.
    public static func searchObjects(matching text: String, limit: Int, release: OracleServerRelease?) -> String {
        let pattern = "%" + likeEscaped(text.uppercased()) + "%"
        let ownerFilter = (release?.major ?? 12) >= 12
            ? "\n      AND OWNER IN (SELECT USERNAME FROM \(OracleDictionary.allUsers) WHERE ORACLE_MAINTAINED = 'N')"
            : ""
        return """
            SELECT OWNER, OBJECT_NAME FROM (
                SELECT DISTINCT OWNER, OBJECT_NAME FROM \(OracleDictionary.allObjects)
                WHERE OBJECT_TYPE IN ('TABLE', 'VIEW')
                  AND UPPER(OBJECT_NAME) LIKE \(literal(pattern)) ESCAPE '\\'\(ownerFilter)
                ORDER BY OWNER, OBJECT_NAME
            )
            WHERE ROWNUM <= \(max(1, limit))
            """
    }

    // MARK: - Rows

    // LOCKED, LOCKED(TIMED) or EXPIRED & LOCKED; ALL_USERS has no status and reads as open.
    public static func parseUsers(_ rows: [[String?]]) -> [OraclePrincipalRow] {
        rows.compactMap { row in
            guard let name = row.first ?? nil else { return nil }
            let status = (row[safe: 1] ?? nil)?.uppercased() ?? ""
            return OraclePrincipalRow(name: name, isLocked: status.contains("LOCKED"))
        }
    }

    public static func parseNames(_ rows: [[String?]]) -> [String] {
        rows.compactMap { $0.first ?? nil }
    }

    public static func parseRoleGrants(_ rows: [[String?]]) -> [OracleRoleGrantRow] {
        rows.compactMap { row in
            guard let grantee = row.first ?? nil, let role = row[safe: 1] ?? nil else { return nil }
            return OracleRoleGrantRow(grantee: grantee, role: role)
        }
    }

    public static func parseSystemPrivileges(_ rows: [[String?]]) -> [OracleGrant] {
        rows.compactMap { row in
            guard let privilege = row.first ?? nil else { return nil }
            return OracleGrant(privilege: privilege, securable: .system, isGrantable: isYes(row[safe: 1]))
        }
    }

    public static func parseObjectPrivileges(_ rows: [[String?]]) -> [OracleGrant] {
        rows.compactMap { row in
            guard let owner = row.first ?? nil,
                  let table = row[safe: 1] ?? nil,
                  let privilege = row[safe: 2] ?? nil else { return nil }
            return OracleGrant(
                privilege: privilege,
                securable: .object(owner: owner, name: table),
                isGrantable: isYes(row[safe: 3])
            )
        }
    }

    public static func parseColumnPrivileges(_ rows: [[String?]]) -> [OracleGrant] {
        rows.compactMap { row in
            guard let owner = row.first ?? nil,
                  let table = row[safe: 1] ?? nil,
                  let column = row[safe: 2] ?? nil,
                  let privilege = row[safe: 3] ?? nil else { return nil }
            return OracleGrant(
                privilege: privilege,
                securable: .object(owner: owner, name: table),
                column: column,
                isGrantable: isYes(row[safe: 4])
            )
        }
    }

    public static func isMissingView(_ error: OracleCoreError) -> Bool {
        guard case let .queryFailed(detail) = error else { return false }
        return detail.contains("ORA-00942")
    }

    private static func isYes(_ cell: String??) -> Bool {
        (cell ?? nil)?.uppercased() == "YES"
    }

    private static func literal(_ value: String) -> String {
        "'\(OracleSchemaQueries.escapeLiteral(value))'"
    }

    private static func likeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
            .replacingOccurrences(of: "%", with: "\\%", options: .literal)
            .replacingOccurrences(of: "_", with: "\\_", options: .literal)
    }
}
