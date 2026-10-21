import Foundation

// One list for both levels: a login carries the user sharing its SID here (`sa` is `dbo`), and a shared name keeps the first of login, server role, database role, database user.
public struct MSSQLPrincipalDirectory: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case login(user: String?)
        case serverRole
        case databaseRole
        case databaseUser

        public var isRole: Bool {
            switch self {
            case .serverRole, .databaseRole: true
            case .login, .databaseUser: false
            }
        }
    }

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let kind: Kind
        // A login not disabled, or a database user holding CONNECT.
        public let isEnabled: Bool
        public let memberOf: [String]
    }

    public struct LoginRow: Sendable, Equatable {
        public let name: String
        public let isDisabled: Bool
        public let user: String?

        public init(name: String, isDisabled: Bool, user: String?) {
            self.name = name
            self.isDisabled = isDisabled
            self.user = user
        }
    }

    public struct DatabasePrincipalRow: Sendable, Equatable {
        public let name: String
        public let isRole: Bool
        public let hasConnect: Bool

        public init(name: String, isRole: Bool, hasConnect: Bool) {
            self.name = name
            self.isRole = isRole
            self.hasConnect = hasConnect
        }
    }

    public struct MembershipRow: Sendable, Equatable {
        public let member: String
        public let role: String

        public init(member: String, role: String) {
            self.member = member
            self.role = role
        }
    }

    public let database: String
    public let entries: [Entry]
    private let positions: [String: Int]

    public init(
        database: String,
        logins: [LoginRow],
        serverRoles: [String],
        databasePrincipals: [DatabasePrincipalRow],
        serverMemberships: [MembershipRow],
        databaseMemberships: [MembershipRow]
    ) {
        var candidates: [(name: String, kind: Kind, isEnabled: Bool)] = []
        candidates += logins.map { ($0.name, .login(user: $0.user), !$0.isDisabled) }
        candidates += serverRoles.map { ($0, .serverRole, true) }
        candidates += databasePrincipals.filter(\.isRole).map { ($0.name, .databaseRole, true) }
        candidates += databasePrincipals.filter { !$0.isRole }.map { ($0.name, .databaseUser, $0.hasConnect) }

        var kept: [(name: String, kind: Kind, isEnabled: Bool)] = []
        var seen: Set<String> = []
        for candidate in candidates where seen.insert(candidate.name).inserted {
            kept.append(candidate)
        }

        var entryByUser: [String: String] = [:]
        for candidate in kept {
            switch candidate.kind {
            case let .login(user):
                if let user { entryByUser[user] = candidate.name }
            case .databaseRole, .databaseUser:
                entryByUser[candidate.name] = candidate.name
            case .serverRole:
                break
            }
        }
        let serverNames = Set(kept.filter { $0.kind == .serverRole || $0.kind.isLogin }.map(\.name))
        let serverRoleNames = Set(kept.filter { $0.kind == .serverRole }.map(\.name))
        let databaseRoleNames = Set(kept.filter { $0.kind == .databaseRole }.map(\.name))

        var memberOf: [String: [String]] = [:]
        for row in serverMemberships where serverRoleNames.contains(row.role) && serverNames.contains(row.member) {
            memberOf[row.member, default: []].append(row.role)
        }
        for row in databaseMemberships where databaseRoleNames.contains(row.role) {
            guard let member = entryByUser[row.member] else { continue }
            memberOf[member, default: []].append(row.role)
        }

        self.database = database
        entries = kept.map { candidate in
            Entry(
                name: candidate.name,
                kind: candidate.kind,
                isEnabled: candidate.isEnabled,
                memberOf: Array(Set(memberOf[candidate.name] ?? [])).sorted()
            )
        }
        positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.name, $0) })
    }

    public func entry(named name: String) -> Entry? {
        positions[name].map { entries[$0] }
    }

    public func kind(of name: String) -> Kind? {
        entry(named: name)?.kind
    }

    public func members(of role: String) -> [String] {
        entries.filter { $0.memberOf.contains(role) }.map(\.name)
    }

    public static func == (lhs: MSSQLPrincipalDirectory, rhs: MSSQLPrincipalDirectory) -> Bool {
        lhs.database == rhs.database && lhs.entries == rhs.entries
    }
}

extension MSSQLPrincipalDirectory.Kind {
    var isLogin: Bool {
        if case .login = self { return true }
        return false
    }
}
