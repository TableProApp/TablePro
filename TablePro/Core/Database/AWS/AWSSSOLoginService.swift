import AppKit
import Foundation
import TableProPluginKit

enum AWSSSOLoginService {
    static let defaultProfileName = "default"

    /// Two spellings are in use: the Cassandra and RDS drivers declare `awsAuth`, DynamoDB
    /// declares `awsAuthMethod`. Both mean the same thing here.
    static func usesSSO(_ fields: [String: String]) -> Bool {
        fields["awsAuth"] == "sso" || fields["awsAuthMethod"] == "sso"
    }

    static func profileName(from fields: [String: String]) -> String {
        fields["awsProfileName"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultProfileName
    }

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
