import AppKit
import Foundation

enum ConnectionSignInKind: String, Equatable, CaseIterable {
    case awsSSO
    case entraID
}

/// A driver credential that a person can renew by signing in again.
///
/// Connect failures are otherwise terminal: the user reads an error and has nothing to click. A
/// provider says which failures it recognises and what to run to recover, so both the connection
/// form and the real connect path can offer the same recovery without either knowing which driver
/// is involved.
struct ConnectionSignInProvider: Sendable {
    let kind: ConnectionSignInKind

    /// Whether this provider recognises the failure. Kept free of UI so it stays testable.
    let claims: @Sendable (Error, [String: String]) -> Bool

    let title: String
    let message: @Sendable ([String: String]) -> String
    let signedInMessage: String
    let failureTitle: String
    let signIn: @MainActor @Sendable ([String: String], NSWindow?) async throws -> Void
}

enum ConnectionSignInRegistry {
    static let providers: [ConnectionSignInProvider] = [.awsSSO, .entraID]

    /// The provider that recognises this failure, if any. `fields` is the connection's
    /// `additionalFields`.
    static func provider(
        for error: Error,
        fields: [String: String]
    ) -> ConnectionSignInProvider? {
        providers.first { $0.claims(error, fields) }
    }
}

extension ConnectionSignInProvider {
    static let awsSSO = ConnectionSignInProvider(
        kind: .awsSSO,
        claims: { error, fields in
            AWSSSOLoginService.usesSSO(fields) && AWSSSOLoginService.isSSOExpired(error)
        },
        title: String(localized: "AWS SSO Sign-In Required"),
        message: { fields in
            String(
                format: String(localized: "The SSO session for profile \"%@\" has expired. Sign in with your browser?"),
                AWSSSOLoginService.profileName(from: fields)
            )
        },
        signedInMessage: String(localized: "AWS SSO sign-in finished. Test the connection again."),
        failureTitle: String(localized: "AWS SSO Sign-In Failed"),
        signIn: { fields, _ in
            try await AWSSSOLoginService.signIn(profileName: AWSSSOLoginService.profileName(from: fields))
        }
    )

    static let entraID = ConnectionSignInProvider(
        kind: .entraID,
        claims: { error, _ in EntraSignInService.needsSignIn(error) },
        title: String(localized: "Microsoft Entra ID Sign-In Required"),
        message: { _ in String(localized: "Sign in to Microsoft Entra ID with your browser?") },
        signedInMessage: String(localized: "Microsoft Entra ID sign-in finished. Test the connection again."),
        failureTitle: String(localized: "Microsoft Entra ID Sign-In Failed"),
        signIn: { fields, window in
            try await EntraSignInService.signIn(fields: fields, window: window)
        }
    )
}
