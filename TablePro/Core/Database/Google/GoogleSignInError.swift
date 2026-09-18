import Foundation
import TableProGoogleCloud

internal enum GoogleSignInError: LocalizedError, Equatable {
    case clientNotConfigured
    case noRefreshToken
    case authentication(GoogleAuthError)

    var errorDescription: String? {
        switch self {
        case .clientNotConfigured:
            return String(
                localized: "Enter the OAuth client ID and client secret for this connection, then sign in again."
            )
        case .noRefreshToken:
            return String(
                localized: "Google did not return a refresh token. Remove TablePro's access in your Google Account settings, then sign in again."
            )
        case .authentication(let error):
            return GoogleAuthErrorMessages.message(for: error)
        }
    }
}
