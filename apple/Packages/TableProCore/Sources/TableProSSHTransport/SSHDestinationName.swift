import Foundation

// The Linux app's rules for an SSH destination: OpenSSH's valid_hostname and
// valid_ruser, plus what a shell globs or reads as a comment, plus format characters that hide or
// reorder text. Match exec hands both names to /bin/sh, and the host key store is one entry per line.
public enum SSHDestinationName {
    public enum Problem: Error, Hashable, Sendable {
        case host(String)
        case user(String)
        case port(Int)

        public var explanation: String {
            switch self {
            case .host(let host) where host.isEmpty:
                return String(localized: "The SSH host is empty.")
            case .host(let host):
                return String(
                    format: String(localized: "The SSH host %@ contains characters TablePro does not allow in a host name."),
                    host
                )
            case .user(let user):
                return String(
                    format: String(localized: "The SSH user %@ contains characters TablePro does not allow in a user name."),
                    user
                )
            case .port(let port):
                return String(format: String(localized: "The SSH port %lld is not between 1 and 65535."), port)
            }
        }
    }

    private enum Part {
        case host
        case user
    }

    private static let shellCharacters: Set<Unicode.Scalar> = [
        "'", "`", "\"", "$", ";", "&", "<", ">", "|", "(", ")", "{", "}", ",",
    ]
    private static let globAndCommentCharacters: Set<Unicode.Scalar> = ["*", "?", "[", "]", "#"]

    public static func problem(host: String, user: String) -> Problem? {
        if !isValidHost(host) { return .host(host) }
        if !isValidUser(user) { return .user(user) }
        return nil
    }

    // A nil port is unset, and ssh uses 22.
    public static func problem(host: String, user: String, port: Int?) -> Problem? {
        if let problem = problem(host: host, user: user) { return problem }
        if let port, !isValidPort(port) { return .port(port) }
        return nil
    }

    public static func isValidHost(_ host: String) -> Bool {
        isValid(host, as: .host)
    }

    // An empty user is unset: ssh then takes `User` from the config or the local account name.
    public static func isValidUser(_ user: String) -> Bool {
        user.isEmpty || isValid(user, as: .user)
    }

    public static func isValidPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }

    // Process hands every argument over decomposed, where U+037E becomes `;` and U+1FEF a backtick,
    // so a name passes only when its decomposed form passes too.
    private static func isValid(_ value: String, as part: Part) -> Bool {
        [value, value.decomposedStringWithCanonicalMapping].allSatisfy { form in
            var scalars = Array(form.unicodeScalars)
            if part == .host, scalars.count >= 2, scalars.first == "[", scalars.last == "]" {
                scalars = Array(scalars.dropFirst().dropLast())
            }
            return isValid(scalars, as: part)
        }
    }

    private static func isValid(_ scalars: [Unicode.Scalar], as part: Part) -> Bool {
        // A trailing backslash would escape whatever follows it.
        guard let first = scalars.first, first != "-", scalars.last != "\\" else { return false }
        return scalars.allSatisfy { scalar in
            switch scalar {
            // A Windows account may be DOMAIN\user, and `!` negates a pattern in a `Host` line.
            case "\\", "!":
                return part == .user
            default:
                return !shellCharacters.contains(scalar)
                    && !globAndCommentCharacters.contains(scalar)
                    && !isWhitespaceOrInvisible(scalar)
            }
        }
    }

    private static func isWhitespaceOrInvisible(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }
}
