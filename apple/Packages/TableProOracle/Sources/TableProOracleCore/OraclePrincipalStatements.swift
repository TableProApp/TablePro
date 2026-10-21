import Foundation

public enum OracleSecurable: Hashable, Sendable {
    case system
    case object(owner: String, name: String)
}

public struct OracleGrant: Hashable, Sendable {
    public let privilege: String
    public let securable: OracleSecurable
    public let column: String?
    // WITH ADMIN OPTION on a system privilege, WITH GRANT OPTION on an object privilege.
    public let isGrantable: Bool

    public init(privilege: String, securable: OracleSecurable, column: String? = nil, isGrantable: Bool = false) {
        self.privilege = privilege
        self.securable = securable
        self.column = column
        self.isGrantable = isGrantable
    }
}

// nil means Oracle cannot express the change. A name outside `roles` is a user or a staged create.
public struct OraclePrincipalStatements: Sendable {
    public let roles: Set<String>

    public init(roles: Set<String>) {
        self.roles = roles
    }

    // MARK: - Principals

    // IDENTIFIED BY takes a quoted identifier, which cannot hold a double quote.
    public func create(name: String, password: String?, canLogin: Bool, memberOf: [String]) -> [String]? {
        var statements: [String]
        if canLogin {
            guard let identified = Self.identifiedBy(password) else { return nil }
            statements = ["CREATE USER \(Self.quoted(name)) \(identified)"]
        } else {
            statements = ["CREATE ROLE \(Self.quoted(name))"]
        }
        statements += memberOf.sorted().map { "GRANT \(Self.quoted($0)) TO \(Self.quoted(name))" }
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
            guard !roles.contains(name) else { return nil }
            statements.append("ALTER USER \(Self.quoted(name)) ACCOUNT \(newCanLogin ? "UNLOCK" : "LOCK")")
        }
        let old = Set(oldMemberOf)
        let new = Set(newMemberOf)
        statements += old.subtracting(new).sorted().map { "REVOKE \(Self.quoted($0)) FROM \(Self.quoted(name))" }
        statements += new.subtracting(old).sorted().map { "GRANT \(Self.quoted($0)) TO \(Self.quoted(name))" }
        return statements
    }

    public func setPassword(name: String, password: String) -> [String]? {
        guard !roles.contains(name), let identified = Self.identifiedBy(password) else { return nil }
        return ["ALTER USER \(Self.quoted(name)) \(identified)"]
    }

    // No CASCADE: a user who owns objects fails with ORA-01922 instead of losing them.
    public func drop(name: String) -> [String]? {
        [roles.contains(name) ? "DROP ROLE \(Self.quoted(name))" : "DROP USER \(Self.quoted(name))"]
    }

    // MARK: - Privileges

    public func grantStatements(_ grants: [OracleGrant], to grantee: String) -> [String]? {
        groups(grants).compactMap { group in
            guard let clause = Self.clause(group) else { return nil }
            let target = Self.target(group.key.securable).map { " ON \($0)" } ?? ""
            let option: String
            if group.key.isGrantable {
                option = group.key.securable == .system ? " WITH ADMIN OPTION" : " WITH GRANT OPTION"
            } else {
                option = ""
            }
            return "GRANT \(clause)\(target) TO \(Self.quoted(grantee))\(option)"
        }
    }

    // A column privilege is revoked only from the whole table (ORA-01750), which would hit every other column too.
    public func revokeStatements(_ grants: [OracleGrant], from grantee: String) -> [String]? {
        guard !grants.contains(where: { $0.column != nil }) else { return nil }
        return groups(grants.map {
            OracleGrant(privilege: $0.privilege, securable: $0.securable)
        }).compactMap { group in
            guard let clause = Self.clause(group) else { return nil }
            let target = Self.target(group.key.securable).map { " ON \($0)" } ?? ""
            return "REVOKE \(clause)\(target) FROM \(Self.quoted(grantee))"
        }
    }

    private struct GroupKey: Hashable {
        let securable: OracleSecurable
        let isGrantable: Bool
    }

    private struct Group {
        let key: GroupKey
        var privileges: [String] = []
        var columns: [String: [String]] = [:]
    }

    private func groups(_ grants: [OracleGrant]) -> [Group] {
        var order: [GroupKey] = []
        var byKey: [GroupKey: Group] = [:]
        for grant in grants {
            guard let privilege = OraclePrivilegeName.sanitized(grant.privilege) else { continue }
            if grant.column != nil, grant.securable == .system { continue }
            let key = GroupKey(securable: grant.securable, isGrantable: grant.isGrantable)
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = Group(key: key)
            }
            if let column = grant.column {
                var columns = byKey[key]?.columns[privilege] ?? []
                if !columns.contains(column) { columns.append(column) }
                byKey[key]?.columns[privilege] = columns
            } else if byKey[key]?.privileges.contains(privilege) == false {
                byKey[key]?.privileges.append(privilege)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    private static func clause(_ group: Group) -> String? {
        let parts = group.privileges + group.columns.sorted { $0.key < $1.key }.map { privilege, columns in
            "\(privilege) (\(columns.map(quoted).joined(separator: ", ")))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func target(_ securable: OracleSecurable) -> String? {
        switch securable {
        case .system:
            nil
        case let .object(owner, name):
            "\(quoted(owner)).\(quoted(name))"
        }
    }

    private static func identifiedBy(_ password: String?) -> String? {
        guard let password, !password.isEmpty, !password.unicodeScalars.contains("\"") else { return nil }
        return "IDENTIFIED BY \"\(password)\""
    }

    public static func quoted(_ name: String) -> String {
        OracleSchemaQueries.quoteIdentifier(name)
    }
}

public enum OraclePrivilegeName {
    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ _")

    public static func sanitized(_ raw: String) -> String? {
        let normalized = raw.uppercased()
        guard !normalized.isEmpty, normalized.allSatisfy({ allowed.contains($0) }) else { return nil }
        return normalized
    }
}
