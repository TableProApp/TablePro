import AppKit
import Foundation
import TableProPluginKit

enum AWSSSOLoginService {
    static func isSSOExpired(_ error: Error) -> Bool {
        guard let ssoError = error as? AWSSSOError else { return false }
        switch ssoError {
        case .tokenCacheNotFound, .tokenCacheMalformed, .tokenExpired, .sessionUnauthorized, .credentialsAlreadyExpired:
            return true
        default:
            return false
        }
    }

    static func signIn(profileName: String) async throws {
        guard let configContents = AWSConfigFile.readFile(AWSConfigFile.defaultConfigPath) else {
            throw AWSSSOError.configReadFailed
        }
        let cacheDirectory = NSString("~/.aws/sso/cache").expandingTildeInPath
        try await AWSSSOLogin.login(
            profileName: profileName,
            configContents: configContents,
            cacheDirectory: cacheDirectory,
            openVerificationURL: { url in
                Task { @MainActor in NSWorkspace.shared.open(url) }
            }
        )
    }
}
