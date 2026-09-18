import Foundation

public enum GoogleAuthError: Error, Sendable, Equatable {
    case credentialNotJSON
    case credentialIsPEM
    case credentialFileUnreadable
    case credentialMissingField(String)
    case malformedPrivateKey
    case applicationDefaultCredentialsNotFound
    case unsupportedCredentialType(String)
    case untrustedEndpoint(String)
    case signInRequired
    case tokenRequestRejected(status: Int, oauthError: String?)
    case invalidTokenResponse
    case signingFailed
    case transport(String)
    case oauthTimedOut
    case oauthDenied(String)
    case oauthStateMismatch
    case oauthCancelled

    public var requiresSignIn: Bool {
        switch self {
        case .signInRequired:
            return true
        case .tokenRequestRejected(_, let oauthError):
            return oauthError == GoogleOAuthErrorCode.invalidGrant
        default:
            return false
        }
    }

    public var isAuthenticationFailure: Bool {
        if requiresSignIn { return true }
        guard case .tokenRequestRejected(let status, let oauthError) = self else { return false }
        if status == 401 { return true }
        return oauthError == GoogleOAuthErrorCode.invalidClient || oauthError == GoogleOAuthErrorCode.unauthorizedClient
    }
}

internal enum GoogleOAuthErrorCode {
    static let invalidGrant = "invalid_grant"
    static let invalidClient = "invalid_client"
    static let unauthorizedClient = "unauthorized_client"

    private static let maximumLength = 64

    static func sanitized(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= maximumLength else { return nil }
        let allowed = raw.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == ".")
        }
        return allowed ? raw : nil
    }
}
