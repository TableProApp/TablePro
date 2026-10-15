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

    static func resolve(config: DriverConnectionConfig) throws -> (credential: GoogleRESTCredential, projectHint: String?) {
        let fields = config.additionalFields
        let method = trimmed(fields[FirebaseFieldID.authMethod]).flatMap(FirebaseAuthMethod.init(rawValue:))
            ?? .serviceAccount
        switch method {
        case .emulator:
            return (.firebaseEmulator, nil)
        case .serviceAccount:
            guard let value = trimmed(fields[FirebaseFieldID.serviceAccountJson]) ?? trimmed(config.password) else {
                throw FirebaseError.configuration(String(localized: "Choose a service account key file, or paste its JSON."))
            }
            return try GoogleRESTCredential.resolving(.serviceAccountKey(value), scopes: scopes)
        case .applicationDefault:
            return try GoogleRESTCredential.resolving(.applicationDefault, scopes: scopes)
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
