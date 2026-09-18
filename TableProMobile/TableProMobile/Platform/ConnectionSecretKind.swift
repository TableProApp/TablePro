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

    var isSweptWhenOrphaned: Bool {
        switch self {
        case .password, .sshPassword, .keyPassphrase: true
        case .sshPrivateKey: false
        }
    }

    func account(for connectionId: UUID) -> String {
        prefix + connectionId.uuidString
    }

    static func sweptConnectionId(inAccount account: String) -> UUID? {
        let swept = allCases.filter(\.isSweptWhenOrphaned)
        guard let kind = swept.first(where: { account.hasPrefix($0.prefix) }) else { return nil }
        return UUID(uuidString: String(account.dropFirst(kind.prefix.count)))
    }

    static func orphanedAccounts(_ accounts: [String], keeping validConnectionIds: Set<UUID>) -> [String] {
        guard !validConnectionIds.isEmpty else { return [] }
        return accounts.filter { account in
            guard let connectionId = sweptConnectionId(inAccount: account) else { return false }
            return !validConnectionIds.contains(connectionId)
        }
    }
}
