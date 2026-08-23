import Foundation

nonisolated enum RedisAuthCommand {
    enum Failure: Equatable, Sendable {
        case rejectedCredentials
        case rejectedWithoutUsername
        case serverHasNoPassword
        case usernameUnsupported
        case unrecognized
    }

    static func arguments(username: String?, password: String?) -> [String]? {
        guard let password, !password.isEmpty else { return nil }
        guard let username, !username.isEmpty else { return ["AUTH", password] }
        return ["AUTH", username, password]
    }

    static func failure(serverError: String, hadUsername: Bool) -> Failure {
        let text = serverError.lowercased()
        if text.contains("wrong number of arguments") { return .usernameUnsupported }
        if text.contains("without any password configured") || text.contains("no password is set") {
            return .serverHasNoPassword
        }
        if text.contains("invalid password") { return .rejectedCredentials }
        if text.contains("wrongpass") {
            return hadUsername ? .rejectedCredentials : .rejectedWithoutUsername
        }
        return .unrecognized
    }
}
