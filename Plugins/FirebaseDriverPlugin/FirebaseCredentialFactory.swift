import Foundation
import TableProFirebaseCore
import TableProGoogleCloud
import TableProPluginKit

internal enum FirebaseCredentialFactory {
    /// The Realtime Database REST API wants the two Firebase scopes beside `cloud-platform`.
    static let scopes = [
        GoogleOAuthClient.cloudPlatformScope,
        "https://www.googleapis.com/auth/firebase.database",
        "https://www.googleapis.com/auth/userinfo.email"
    ]

    struct Resolved {
        let credential: FirebaseCredential
        let projectHint: String?
    }

    static func resolve(config: DriverConnectionConfig) throws -> Resolved {
        let fields = config.additionalFields
        let method = trimmed(fields[FirebaseFieldID.authMethod]).flatMap(FirebaseAuthMethod.init(rawValue:))
            ?? .serviceAccount
        let source: GoogleCredentialSource
        switch method {
        case .emulator:
            return Resolved(credential: .emulator, projectHint: nil)
        case .serviceAccount:
            guard let value = trimmed(fields[FirebaseFieldID.serviceAccountJson]) ?? trimmed(config.password) else {
                throw FirebaseError.configuration(String(localized: "Choose a service account key file, or paste its JSON."))
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
            credential: FirebaseCredential(
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
