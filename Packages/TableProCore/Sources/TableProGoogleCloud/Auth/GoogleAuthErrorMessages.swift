import Foundation

public enum GoogleAuthErrorMessages {
    public static func message(for error: GoogleAuthError) -> String {
        switch error {
        case .credentialNotJSON:
            return String(localized: "The service account key is not valid JSON.")
        case .credentialIsPEM:
            return String(localized: "Paste the whole service account JSON key or its file path, not the private key alone.")
        case .credentialFileUnreadable:
            return String(localized: "The credentials file can't be read.")
        case .credentialMissingField(let field):
            return String(format: String(localized: "The credentials file has no %@ field."), field)
        case .malformedPrivateKey:
            return String(localized: "The service account private key can't be read.")
        case .applicationDefaultCredentialsNotFound:
            return String(localized: "Application default credentials not found. Run gcloud auth application-default login.")
        case .unsupportedCredentialType(let type):
            return String(format: String(localized: "Credentials of type %@ are not supported."), type)
        case .untrustedEndpoint(let host):
            return String(format: String(localized: "The credentials point at %@, which is not a Google endpoint."), host)
        case .signInRequired:
            return String(localized: "Sign in with your Google account to use this connection.")
        case .tokenRequestRejected(let status, let oauthError):
            return rejectionMessage(status: status, oauthError: oauthError)
        case .invalidTokenResponse:
            return String(localized: "Google returned a token response that can't be read.")
        case .signingFailed:
            return String(localized: "Signing the service account token failed.")
        case .transport(let detail):
            return String(format: String(localized: "Can't reach Google's sign-in service: %@"), detail)
        case .oauthTimedOut:
            return String(localized: "Google sign-in timed out. Try again.")
        case .oauthDenied(let reason):
            return String(format: String(localized: "Google sign-in was denied: %@"), reason)
        case .oauthStateMismatch:
            return String(localized: "Google sign-in returned an unexpected response. Try again.")
        case .oauthCancelled:
            return String(localized: "Google sign-in was cancelled.")
        }
    }

    private static func rejectionMessage(status: Int, oauthError: String?) -> String {
        switch oauthError {
        case "invalid_grant":
            return String(localized: "Google no longer accepts these credentials. Sign in again, or renew the key or the gcloud login.")
        case "invalid_client", "unauthorized_client":
            return String(localized: "Google rejected the OAuth client ID or secret.")
        case .some(let code):
            return String(format: String(localized: "Google rejected the token request (%@)."), code)
        case .none:
            return String(format: String(localized: "Google rejected the token request (HTTP %lld)."), Int64(status))
        }
    }
}
