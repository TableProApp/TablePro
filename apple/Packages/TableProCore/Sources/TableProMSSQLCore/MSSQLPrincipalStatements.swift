import Foundation

public enum MSSQLSecurable: Hashable, Sendable {
    case server
    case database
    case schema(String)
    case object(schema: String, name: String)
}

public struct MSSQLGrant: Hashable, Sendable {
    public let permission: String
    public let securable: MSSQLSecurable
    public let column: String?
    public let withGrantOption: Bool

    public init(permission: String, securable: MSSQLSecurable, column: String? = nil, withGrantOption: Bool = false) {
        self.permission = permission
        self.securable = securable
        self.column = column
        self.withGrantOption = withGrantOption
    }
}

// nil means SQL Server cannot express the change. A name the directory lacks is a staged create: a login with a
// same-named user, or a database role. Database statements run in the directory's database whatever the session is on.
public struct MSSQLPrincipalStatements: Sendable {
    public let directory: MSSQLPrincipalDirectory?

    public init(directory: MSSQLPrincipalDirectory?) {
        self.directory = directory
    }

    // MARK: - Principals

    public func create(name: String, password: String?, canLogin: Bool, memberOf: [String]) -> [String]? {
        var statements: [String]
        if canLogin {
            guard let password, !password.isEmpty else { return nil }
            statements = [
                "CREATE LOGIN \(Self.bracketed(name)) WITH PASSWORD = \(MSSQLStringLiteral.quoted(password))",
                inDatabase("CREATE USER \(Self.bracketed(name)) FOR LOGIN \(Self.bracketed(name))")
            ]
        } else {
            guard !memberOf.contains(where: { directory?.kind(of: $0) == .serverRole }) else { return nil }
            statements = [inDatabase("CREATE ROLE \(Self.bracketed(name))")]
        }
        var ensured: Set<String> = []
        for role in memberOf.sorted() {
            guard let membership = membership(of: name, in: role, adding: true, ensured: &ensured) else {
                return nil
            }
            statements += membership
        }
        return statements
    }

    public func alter(
        name: String,
        oldCanLogin: Bool,
        newCanLogin: Bool,
        oldMemberOf: [String],
        newMemberOf: [String]
    ) -> [String]? {
        var statements: [String] = []
        if oldCanLogin != newCanLogin {
            switch directory?.kind(of: name) {
            case .login:
                statements.append("ALTER LOGIN \(Self.bracketed(name)) \(newCanLogin ? "ENABLE" : "DISABLE")")
            case .databaseUser:
                statements.append(inDatabase(
                    newCanLogin
                        ? "GRANT CONNECT TO \(Self.bracketed(name))"
                        : "REVOKE CONNECT FROM \(Self.bracketed(name))"
                ))
            case .serverRole, .databaseRole, nil:
                return nil
            }
        }

        let old = Set(oldMemberOf)
        let new = Set(newMemberOf)
        var ensured: Set<String> = []
        for role in old.subtracting(new).sorted() {
            guard let membership = membership(of: name, in: role, adding: false, ensured: &ensured) else {
                return nil
            }
            statements += membership
        }
        for role in new.subtracting(old).sorted() {
            guard let membership = membership(of: name, in: role, adding: true, ensured: &ensured) else {
                return nil
            }
            statements += membership
        }
        return statements
    }

    public func setPassword(name: String, password: String) -> [String]? {
        let literal = MSSQLStringLiteral.quoted(password)
        switch directory?.kind(of: name) {
        case .login, nil:
            return ["ALTER LOGIN \(Self.bracketed(name)) WITH PASSWORD = \(literal)"]
        case .databaseUser:
            return [inDatabase("ALTER USER \(Self.bracketed(name)) WITH PASSWORD = \(literal)")]
        case .serverRole, .databaseRole:
            return nil
        }
    }

    // A role must be empty before it is dropped. A member dropped earlier in the same apply is skipped.
    // A login's users in other databases are left orphaned.
    public func drop(name: String) -> [String]? {
        guard let directory, let kind = directory.kind(of: name) else { return nil }
        switch kind {
        case let .login(user):
            let dropUser = user.map { [inDatabase("DROP USER \(Self.bracketed($0))")] } ?? []
            return dropUser + ["DROP LOGIN \(Self.bracketed(name))"]
        case .serverRole:
            let members = directory.members(of: name).map { member in
                "IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = \(MSSQLStringLiteral.quoted(member))) "
                    + "ALTER SERVER ROLE \(Self.bracketed(name)) DROP MEMBER \(Self.bracketed(member))"
            }
            return members + ["DROP SERVER ROLE \(Self.bracketed(name))"]
        case .databaseRole:
            let members = directory.members(of: name).compactMap { member in
                databaseGrantee(member).map {
                    inDatabase(
                        "IF DATABASE_PRINCIPAL_ID(\(MSSQLStringLiteral.quoted($0.name))) IS NOT NULL "
                            + "ALTER ROLE \(Self.bracketed(name)) DROP MEMBER \(Self.bracketed($0.name))"
                    )
                }
            }
            return members + [inDatabase("DROP ROLE \(Self.bracketed(name))")]
        case .databaseUser:
            return [inDatabase("DROP USER \(Self.bracketed(name))")]
        }
    }

    // MARK: - Permissions

    public func grantStatements(_ grants: [MSSQLGrant], to principal: String) -> [String]? {
        statements(grants, principal: principal, revoking: false)
    }

    public func revokeStatements(_ grants: [MSSQLGrant], from principal: String) -> [String]? {
        statements(grants, principal: principal, revoking: true)
    }

    private struct GroupKey: Hashable {
        let securable: MSSQLSecurable
        let withGrantOption: Bool
    }

    private func statements(_ grants: [MSSQLGrant], principal: String, revoking: Bool) -> [String]? {
        var order: [GroupKey] = []
        var wholePermissions: [GroupKey: [String]] = [:]
        var columnPermissions: [GroupKey: [String: [String]]] = [:]

        for grant in grants {
            guard let permission = MSSQLPermissionName.sanitized(grant.permission) else { continue }
            if grant.column != nil {
                guard case .object = grant.securable else { return nil }
            }
            let key = GroupKey(securable: grant.securable, withGrantOption: grant.withGrantOption)
            if wholePermissions[key] == nil, columnPermissions[key] == nil {
                order.append(key)
            }
            if let column = grant.column {
                var columns = columnPermissions[key]?[permission] ?? []
                if !columns.contains(column) { columns.append(column) }
                columnPermissions[key, default: [:]][permission] = columns
            } else {
                var permissions = wholePermissions[key] ?? []
                if !permissions.contains(permission) { permissions.append(permission) }
                wholePermissions[key] = permissions
            }
        }

        var statements: [String] = []
        var ensured: Set<String> = []
        for key in order {
            var clause = wholePermissions[key] ?? []
            clause += (columnPermissions[key] ?? [:]).sorted { $0.key < $1.key }.map { permission, columns in
                "\(permission) (\(columns.map(Self.bracketed).joined(separator: ", ")))"
            }
            guard !clause.isEmpty else { continue }

            if key.securable == .server {
                guard serverGrantee(principal) else { return nil }
                let statement = Self.permissionStatement(
                    clause: clause.joined(separator: ", "),
                    target: nil,
                    grantee: Self.bracketed(principal),
                    withGrantOption: key.withGrantOption,
                    revoking: revoking
                )
                statements.append(Self.inDatabase("master", statement))
                continue
            }

            guard let grantee = databaseGrantee(principal) else { return nil }
            if let login = grantee.loginNeedingUser, !revoking, ensured.insert(login).inserted {
                statements.append(inDatabase(Self.ensureUser(forLogin: login)))
            }
            statements.append(inDatabase(
                Self.permissionStatement(
                    clause: clause.joined(separator: ", "),
                    target: Self.target(key.securable),
                    grantee: Self.bracketed(grantee.name),
                    withGrantOption: key.withGrantOption,
                    revoking: revoking
                )
            ))
        }
        return statements
    }

    // A grant made WITH GRANT OPTION needs CASCADE to revoke (Msg 4611).
    private static func permissionStatement(
        clause: String,
        target: String?,
        grantee: String,
        withGrantOption: Bool,
        revoking: Bool
    ) -> String {
        let on = target.map { " ON \($0)" } ?? ""
        if revoking {
            return "REVOKE \(clause)\(on) FROM \(grantee)\(withGrantOption ? " CASCADE" : "")"
        }
        return "GRANT \(clause)\(on) TO \(grantee)\(withGrantOption ? " WITH GRANT OPTION" : "")"
    }

    private static func target(_ securable: MSSQLSecurable) -> String? {
        switch securable {
        case .server, .database:
            nil
        case let .schema(schema):
            "SCHEMA::\(bracketed(schema))"
        case let .object(schema, name):
            "OBJECT::\(bracketed(schema)).\(bracketed(name))"
        }
    }

    // MARK: - Grantees

    private struct DatabaseGrantee {
        let name: String
        let loginNeedingUser: String?
    }

    private func serverGrantee(_ name: String) -> Bool {
        switch directory?.kind(of: name) {
        case .login, .serverRole, nil: true
        case .databaseRole, .databaseUser: false
        }
    }

    private func databaseGrantee(_ name: String) -> DatabaseGrantee? {
        switch directory?.kind(of: name) {
        case let .login(user):
            DatabaseGrantee(name: user ?? name, loginNeedingUser: user == nil ? name : nil)
        case .databaseRole, .databaseUser, nil:
            DatabaseGrantee(name: name, loginNeedingUser: nil)
        case .serverRole:
            nil
        }
    }

    private func membership(
        of member: String,
        in role: String,
        adding: Bool,
        ensured: inout Set<String>
    ) -> [String]? {
        let verb = adding ? "ADD" : "DROP"
        if directory?.kind(of: role) == .serverRole {
            guard serverGrantee(member) else { return nil }
            return ["ALTER SERVER ROLE \(Self.bracketed(role)) \(verb) MEMBER \(Self.bracketed(member))"]
        }
        guard directory?.kind(of: role).map({ $0 == .databaseRole }) ?? true,
              let grantee = databaseGrantee(member) else { return nil }
        var statements: [String] = []
        if let login = grantee.loginNeedingUser, adding, ensured.insert(login).inserted {
            statements.append(inDatabase(Self.ensureUser(forLogin: login)))
        }
        statements.append(inDatabase("ALTER ROLE \(Self.bracketed(role)) \(verb) MEMBER \(Self.bracketed(grantee.name))"))
        return statements
    }

    // MARK: - Spelling

    private func inDatabase(_ statement: String) -> String {
        guard let database = directory?.database, !database.isEmpty else { return statement }
        return Self.inDatabase(database, statement)
    }

    public static func bracketed(_ name: String) -> String {
        "[\(MSSQLSchemaQueries.escapeBracket(name))]"
    }

    // A login reaches a database only through a user. A same-named user with another SID makes CREATE USER fail
    // rather than take the login's grants.
    public static func ensureUser(forLogin login: String) -> String {
        let name = MSSQLStringLiteral.quoted(login)
        return "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = \(name) AND sid = SUSER_SID(\(name))) "
            + "CREATE USER \(bracketed(login)) FOR LOGIN \(bracketed(login))"
    }

    // A system procedure called through a database name runs in that database, with no USE on the session.
    // Server permissions need master (Msg 4621).
    public static func inDatabase(_ database: String, _ statement: String) -> String {
        "EXEC \(bracketed(database)).sys.sp_executesql \(MSSQLStringLiteral.quoted(statement))"
    }
}

public enum MSSQLPermissionName {
    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ _")

    public static func sanitized(_ raw: String) -> String? {
        let normalized = raw.uppercased()
        guard !normalized.isEmpty, normalized.allSatisfy({ allowed.contains($0) }) else { return nil }
        return normalized
    }
}
