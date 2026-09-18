import Foundation

nonisolated enum ConnectionSecretKind: CaseIterable, Sendable {
    case password
    case sshPassword
    case keyPassphrase
    case sshPrivateKey

    static var orphanSweepPrefixes: [String] {
        allCases.filter(\.isSweptWhenOrphaned).map(\.prefix)
    }

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
}
