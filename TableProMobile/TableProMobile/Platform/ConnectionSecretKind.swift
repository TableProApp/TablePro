import Foundation

nonisolated enum ConnectionSecretKind: CaseIterable, Sendable {
    case password
    case sshPassword
    case keyPassphrase
    case sshPrivateKey

    var prefix: String {
        switch self {
        case .password: "com.TablePro.password."
        case .sshPassword: "com.TablePro.sshpassword."
        case .keyPassphrase: "com.TablePro.keypassphrase."
        case .sshPrivateKey: "com.TablePro.sshkeydata."
        }
    }

    func account(for connectionId: UUID) -> String {
        prefix + connectionId.uuidString
    }

    static func connectionId(inAccount account: String) -> UUID? {
        guard let kind = allCases.first(where: { account.hasPrefix($0.prefix) }) else { return nil }
        return UUID(uuidString: String(account.dropFirst(kind.prefix.count)))
    }

    static func orphanedAccounts(_ accounts: [String], keeping validConnectionIds: Set<UUID>) -> [String] {
        guard !validConnectionIds.isEmpty else { return [] }
        return accounts.filter { account in
            guard let connectionId = connectionId(inAccount: account) else { return false }
            return !validConnectionIds.contains(connectionId)
        }
    }
}
