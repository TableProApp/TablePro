import Foundation

nonisolated enum IAMSignInError: Error, LocalizedError, Equatable, Sendable {
    case accessKeyMissing
    case profileNeedsDeviceKey(profile: String)
    case applicationDefaultNeedsDeviceKey
    case serviceAccountKeyMissing
    case serviceAccountKeyIsMacFile
    case ssoNotSetUp
    case ssoSignInRequired
    case encryptionNotEstablished

    var needsSignIn: Bool {
        self == .ssoSignInRequired
    }

    var errorDescription: String? {
        switch self {
        case .accessKeyMissing:
            String(localized: "This connection signs in with an AWS access key, and this device does not have it.")
        case .profileNeedsDeviceKey(let profile):
            String(
                format: String(localized: "This connection signs in with the AWS profile \"%@\", which is read from files on the Mac."),
                profile
            )
        case .applicationDefaultNeedsDeviceKey:
            String(localized: "This connection signs in with the gcloud credentials on the Mac.")
        case .serviceAccountKeyMissing:
            String(localized: "This connection signs in with a Google Cloud service account, and this device does not have its key.")
        case .serviceAccountKeyIsMacFile:
            String(localized: "The service account key is a file on the Mac, which this device cannot read.")
        case .ssoNotSetUp:
            String(localized: "This connection signs in with IAM Identity Center, which is not set up on this device.")
        case .ssoSignInRequired:
            String(localized: "Sign in to IAM Identity Center to use this connection.")
        case .encryptionNotEstablished:
            String(localized: "The server did not encrypt the connection, so TablePro closed it. An IAM sign-in needs TLS.")
        }
    }
}
