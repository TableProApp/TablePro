import Foundation

nonisolated enum RedisAuthCommand {
    enum Failure: Equatable, Sendable {
        case rejectedCredentials
        case rejectedWithoutUsername
        case rejectedWithoutPassword
        case serverHasNoPassword
        case usernameUnsupported
        case unrecognized
    }

    /// A typed username is an identity, and an empty password does not cancel it.
    ///
    /// Redis defines the one-argument form as `AUTH default <password>`, so sending it for an ACL
    /// user checks their password against `default` and fails. Skipping AUTH entirely is worse:
    /// the server leaves the connection on `default`, every command runs with `default`'s
    /// privileges, and the app reports a successful sign-in as the user who was never sent.
    /// `AUTH <username> ""` is the wire form for a `nopass` ACL user and is rejected for every
    /// other user, so it is both the correct request and an exact test of the identity.
    static func arguments(username: String?, password: String?) -> [String]? {
        let user = username ?? ""
        let secret = password ?? ""
        if !user.isEmpty { return ["AUTH", user, secret] }
        guard !secret.isEmpty else { return nil }
        return ["AUTH", secret]
    }

    /// `WRONGPASS` is the same reply for a wrong password, an empty one and an unknown user, so
    /// what the client sent is the only thing that can tell the three apart.
    static func failure(serverError: String, hadUsername: Bool, hadPassword: Bool) -> Failure {
        let text = serverError.lowercased()
        if text.contains("wrong number of arguments") { return .usernameUnsupported }
        if text.contains("without any password configured") || text.contains("no password is set") {
            return .serverHasNoPassword
        }
        if text.contains("invalid password") { return .rejectedCredentials }
        if text.contains("wrongpass") {
            if !hadUsername { return .rejectedWithoutUsername }
            if !hadPassword { return .rejectedWithoutPassword }
            return .rejectedCredentials
        }
        return .unrecognized
    }

    static func hint(for failure: Failure) -> String? {
        switch failure {
        case .rejectedWithoutUsername:
            return String(localized: "If this server uses Redis 6 or later ACL users, fill in the Username field.")
        case .rejectedWithoutPassword:
            return String(localized: "The Password field is empty. Fill it in, or clear Username to sign in as the default user.")
        case .serverHasNoPassword:
            return String(localized: "This server has no password set for the default user. Clear the Password field.")
        case .usernameUnsupported:
            return String(localized: "This server predates Redis 6 and takes no username. Clear the Username field.")
        case .rejectedCredentials, .unrecognized:
            return nil
        }
    }
}
