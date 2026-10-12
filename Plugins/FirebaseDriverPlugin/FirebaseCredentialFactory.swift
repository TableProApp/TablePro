import Foundation
import TableProFirebaseCore
import TableProGoogleCloud
import TableProPluginKit

/// Turns the connection's auth fields into the bearer token every Firebase request carries.
internal enum FirebaseCredentialFactory {
    /// `cloud-platform` reaches Firestore and the management APIs; the Realtime Database REST API
    /// also wants the two Firebase scopes, which a user login from `gcloud` already includes.
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
        let http = URLSessionGoogleHTTPClient()
        switch method {
        case .emulator:
            return Resolved(credential: .emulator, projectHint: nil)
        case .serviceAccount:
            guard let value = trimmed(fields[FirebaseFieldID.serviceAccountJson]) ?? trimmed(config.password) else {
                throw FirebaseError.configuration(String(localized: "Choose a service account key file, or paste its JSON."))
            }
            let key = try GoogleServiceAccountKey.parse(
                fieldValue: value,
                readFile: { FileManager.default.contents(atPath: $0) }
            )
            let provider = GoogleTokenProviders.serviceAccount(key, scopes: scopes, http: http)
            return Resolved(credential: credential(from: provider, quotaProject: nil), projectHint: key.projectId)
        case .applicationDefault:
            let credentials = try GoogleApplicationDefaultCredentials.load(
                path: nil,
                readFile: { FileManager.default.contents(atPath: $0) },
                environment: ProcessInfo.processInfo.environment
            )
            let provider = GoogleTokenProviders.applicationDefault(credentials, scopes: scopes, http: http)
            var quotaProject: String?
            if case .authorizedUser(_, _, _, let project) = credentials {
                quotaProject = project
            }
            let environmentProject = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]
            return Resolved(
                credential: credential(from: provider, quotaProject: quotaProject),
                projectHint: credentials.projectHint ?? trimmed(environmentProject)
            )
        }
    }

    private static func credential(from provider: any GoogleAccessTokenProviding, quotaProject: String?) -> FirebaseCredential {
        FirebaseCredential(
            token: { try await provider.accessToken() },
            invalidate: { await provider.invalidateCachedToken() },
            quotaProject: quotaProject
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
