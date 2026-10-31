import Foundation

// The checks OpenSSH runs on a host and user before it reads any config (valid_hostname and
// valid_ruser in ssh.c). The user also refuses control characters, which no account name holds.
public enum SSHDestinationName {
    public enum Problem: Error, Hashable, Sendable {
        case host(String)
        case user(String)

        public var explanation: String {
            switch self {
            case .host(let host):
                return String(
                    format: String(localized: "The SSH host %@ contains characters ssh does not allow in a host name."),
                    host
                )
            case .user(let user):
                return String(
                    format: String(localized: "The SSH user %@ contains characters ssh does not allow in a user name."),
                    user
                )
            }
        }
    }

    private static let hostShellCharacters = CharacterSet(charactersIn: "'`\"$;&<>|(){},")
    private static let userShellCharacters = CharacterSet(charactersIn: "'`\";&<>|(){}")

    public static func problem(host: String, user: String) -> Problem? {
        if !isValidHost(host) { return .host(host) }
        if !isValidUser(user) { return .user(user) }
        return nil
    }

    public static func isValidHost(_ host: String) -> Bool {
        guard host.unicodeScalars.first != "-" else { return false }
        return host.unicodeScalars.allSatisfy { scalar in
            !hostShellCharacters.contains(scalar)
                && scalar != "\\"
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    public static func isValidUser(_ user: String) -> Bool {
        let scalars = Array(user.unicodeScalars)
        guard scalars.first != "-", scalars.last != "\\" else { return false }
        for (index, scalar) in scalars.enumerated() {
            if userShellCharacters.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                return false
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar), index + 1 < scalars.count, scalars[index + 1] == "-" {
                return false
            }
        }
        return true
    }
}
