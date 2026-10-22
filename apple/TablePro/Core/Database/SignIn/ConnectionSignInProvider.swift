import AppKit
import Foundation

enum ConnectionSignInKind: String, Equatable, CaseIterable {
    case awsSSO
    case entraID
    case googleOAuth
    case vaultOIDC
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
    // Gets the failure it claimed, which can carry what to sign in to.
    let signIn: @MainActor @Sendable (Error, [String: String], NSWindow?) async throws -> Void
}

enum ConnectionSignInRegistry {
    static let providers: [ConnectionSignInProvider] = [.awsSSO, .entraID, .googleOAuth, .vaultOIDC]

    /// The provider that recognises this failure, if any. `fields` is the connection's
    /// `additionalFields`.
    static func provider(
        for error: Error,
        fields: [String: String]
    ) -> ConnectionSignInProvider? {
        providers.first { $0.claims(error, fields) }
    }

    @MainActor
    static func fields(for connection: DatabaseConnection) -> [String: String] {
        fields(
            connection.additionalFields,
            secureFieldIds: PluginManager.shared.secureConnectionFieldIds(for: connection.type),
            loadSecureField: { ConnectionStorage.shared.loadPluginSecureField(fieldId: $0, for: connection.id) }
        )
    }

    static func fields(
        _ storedFields: [String: String],
        secureFieldIds: [String],
        loadSecureField: (String) -> String?
    ) -> [String: String] {
        var resolved = storedFields
        for fieldId in secureFieldIds where resolved[fieldId]?.isEmpty ?? true {
            guard let value = loadSecureField(fieldId) else { continue }
            resolved[fieldId] = value
        }
        return resolved
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
                AWSSSOLoginService.signInProfileName(from: fields)
            )
        },
        signedInMessage: String(localized: "AWS SSO sign-in finished. Test the connection again."),
        failureTitle: String(localized: "AWS SSO Sign-In Failed"),
        signIn: { _, fields, _ in
            try await AWSSSOLoginService.signIn(profileName: AWSSSOLoginService.signInProfileName(from: fields))
        }
    )

    static let entraID = ConnectionSignInProvider(
        kind: .entraID,
        claims: { error, _ in EntraSignInService.needsSignIn(error) },
        title: String(localized: "Microsoft Entra ID Sign-In Required"),
        message: { _ in String(localized: "Sign in to Microsoft Entra ID with your browser?") },
        signedInMessage: String(localized: "Microsoft Entra ID sign-in finished. Test the connection again."),
        failureTitle: String(localized: "Microsoft Entra ID Sign-In Failed"),
        signIn: { _, fields, window in
            try await EntraSignInService.signIn(fields: fields, window: window)
        }
    )

    static let googleOAuth = ConnectionSignInProvider(
        kind: .googleOAuth,
        claims: { error, fields in GoogleSignInService.claims(error, fields: fields) },
        title: String(localized: "Google Sign-In Required"),
        message: { _ in String(localized: "Sign in to Google with your browser?") },
        signedInMessage: String(localized: "Google sign-in finished. Test the connection again."),
        failureTitle: String(localized: "Google Sign-In Failed"),
        signIn: { _, fields, _ in
            try await GoogleSignInService.signIn(fields: fields)
        }
    )

    static let vaultOIDC = ConnectionSignInProvider(
        kind: .vaultOIDC,
        claims: { error, _ in (error as? VaultError)?.oidcLogin != nil },
        title: String(localized: "Vault Sign-In Required"),
        message: { _ in String(localized: "Sign in to Vault with your browser?") },
        signedInMessage: String(localized: "Vault sign-in finished. Test the connection again."),
        failureTitle: String(localized: "Vault Sign-In Failed"),
        signIn: { error, _, _ in
            guard let login = (error as? VaultError)?.oidcLogin else { return }
            try await VaultAuthenticator.shared.signIn(login)
        }
    )
}
