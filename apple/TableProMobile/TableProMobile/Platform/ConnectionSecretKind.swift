import Foundation

nonisolated enum ConnectionSecretKind: CaseIterable, Sendable {
    case password
    case sshPassword
    case keyPassphrase
    case sshPrivateKey
    case jumpHostKeys
    case awsSecretAccessKey
    case awsSessionToken
    case gcpServiceAccountKey
    case deviceIAM

    var prefix: String {
        switch self {
        case .password: "com.TablePro.password."
        case .sshPassword: "com.TablePro.sshpassword."
        case .keyPassphrase: "com.TablePro.keypassphrase."
        case .sshPrivateKey: "com.TablePro.sshkeydata."
        case .jumpHostKeys: "com.TablePro.jumphostkeys."
        case .awsSecretAccessKey: "com.TablePro.plugin.awsSecretAccessKey."
        case .awsSessionToken: "com.TablePro.plugin.awsSessionToken."
        case .gcpServiceAccountKey: "com.TablePro.plugin.gcpServiceAccountKey."
        case .deviceIAM: "com.TablePro.deviceiam."
        }
    }

    var isSweptWhenOrphaned: Bool {
        switch self {
        case .password, .sshPassword, .keyPassphrase,
             .awsSecretAccessKey, .awsSessionToken, .gcpServiceAccountKey, .deviceIAM: true
        case .sshPrivateKey, .jumpHostKeys: false
        }
    }

    // A key added for this device only must never reach the Mac's copy of the connection.
    var isDeviceOnly: Bool {
        self == .deviceIAM
    }

    func account(for connectionId: UUID) -> String {
        prefix + connectionId.uuidString
    }

    static func isDeviceOnly(account: String) -> Bool {
        allCases.contains { $0.isDeviceOnly && account.hasPrefix($0.prefix) }
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
