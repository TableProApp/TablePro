import Foundation

// The Mac keeps an SSH profile's secrets under the profile's id. The prefixes are the Mac's
// (`SSHProfileStorage`), and the orphan sweep never matches them: a profile id is never a connection's.
nonisolated enum SSHProfileSecretKind: CaseIterable, Sendable {
    case password
    case keyPassphrase
    case totpSecret

    var prefix: String {
        switch self {
        case .password: "com.TablePro.sshprofile.password."
        case .keyPassphrase: "com.TablePro.sshprofile.keypassphrase."
        case .totpSecret: "com.TablePro.sshprofile.totpsecret."
        }
    }

    func account(for profileId: UUID) -> String {
        prefix + profileId.uuidString
    }
}
