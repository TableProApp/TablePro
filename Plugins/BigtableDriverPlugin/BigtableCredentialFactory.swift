import Foundation
import TableProBigtableCore
import TableProGoogleCloud
import TableProPluginKit

internal enum BigtableCredentialFactory {
    static let scopes = [GoogleOAuthClient.cloudPlatformScope]

    struct Resolved {
        let credential: BigtableCredential
        let projectHint: String?
    }

    static func resolve(config: DriverConnectionConfig) throws -> Resolved {
        let fields = config.additionalFields
        let method = trimmed(fields[BigtableFieldID.authMethod]).flatMap(BigtableAuthMethod.init(rawValue:)) ?? .serviceAccount
        let source: GoogleCredentialSource
        switch method {
        case .serviceAccount:
            guard let value = trimmed(fields[BigtableFieldID.serviceAccountJson]) ?? trimmed(config.password) else {
                throw BigtableError.configuration(String(localized: "Choose a service account key file, or paste its JSON."))
            }
            source = .serviceAccountKey(value)
        case .applicationDefault:
            source = .applicationDefault
        }
        let environment = ProcessInfo.processInfo.environment
        let credentials = try GoogleTokenProviders.credentials(
            from: source,
            scopes: scopes,
            readFile: { FileManager.default.contents(atPath: $0) },
            environment: environment,
            http: URLSessionGoogleHTTPClient()
        )
        let provider = credentials.tokenProvider
        let environmentProject = source == .applicationDefault ? trimmed(environment["GOOGLE_CLOUD_PROJECT"]) : nil
        return Resolved(
            credential: BigtableCredential(
                token: { try await provider.accessToken() },
                invalidate: { await provider.invalidateCachedToken() },
                quotaProject: credentials.quotaProject
            ),
            projectHint: credentials.projectHint ?? environmentProject
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
