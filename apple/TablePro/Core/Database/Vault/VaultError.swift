//
//  VaultError.swift
//  TablePro
//

import Foundation

enum VaultTokenSource: Hashable, Sendable {
    case environment
    case tokenFile
    case appRole
    case oidc

    var isMinted: Bool {
        switch self {
        case .appRole, .oidc: true
        case .environment, .tokenFile: false
        }
    }

    var displayName: String {
        switch self {
        case .environment: "VAULT_TOKEN"
        case .tokenFile: "~/.vault-token"
        case .appRole: "AppRole"
        case .oidc: "OIDC"
        }
    }
}

struct VaultOIDCLogin: Hashable, Sendable {
    let endpoint: VaultEndpoint
    let mount: String
    let role: String
}

enum VaultError: LocalizedError, Equatable {
    case noAddress
    case invalidAddress(String)
    case noToken
    case tokenRejected(VaultTokenSource, String)
    case secretIdUnreadable(String)
    case oidcSignInRequired(VaultOIDCLogin)
    case oidcFailed(String)
    case oidcCallbackPortInUse
    case credentialsFailed(path: String, message: String)
    case unreachable(String, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .noAddress:
            return String(localized: """
                No Vault address. Enter one in the credential profile, or set VAULT_ADDR in \
                TablePro's environment.
                """)
        case .invalidAddress(let address):
            return String(
                format: String(localized: "%@ is not a Vault address. Use a URL such as https://vault.example.com:8200."),
                address
            )
        case .noToken:
            return String(localized: """
                No Vault token. Set VAULT_TOKEN in TablePro's environment, or sign in with vault login \
                so ~/.vault-token exists.
                """)
        case let .tokenRejected(source, message):
            switch source {
            case .environment, .tokenFile:
                return String(
                    format: String(localized: "Vault rejected the token from %@: %@"),
                    source.displayName,
                    message
                )
            case .appRole, .oidc:
                return String(
                    format: String(localized: "Vault %@ sign-in failed: %@"),
                    source.displayName,
                    message
                )
            }
        case .secretIdUnreadable(let path):
            return String(format: String(localized: "Could not read the AppRole secret ID file: %@"), path)
        case .oidcSignInRequired:
            return String(localized: "Sign in to Vault with your browser to use this connection.")
        case .oidcFailed(let message):
            return String(format: String(localized: "Vault OIDC sign-in failed: %@"), message)
        case .oidcCallbackPortInUse:
            return String(localized: """
                Vault OIDC sign-in needs port 8250 for its callback, and something else is using it. \
                Quit any running vault login and try again.
                """)
        case let .credentialsFailed(path, message):
            return String(format: String(localized: "Vault could not issue credentials from %@: %@"), path, message)
        case let .unreachable(address, message):
            return String(format: String(localized: "Could not reach Vault at %@: %@"), address, message)
        case .malformedResponse:
            return String(localized: "Vault returned a response TablePro could not read.")
        }
    }

    var oidcLogin: VaultOIDCLogin? {
        guard case .oidcSignInRequired(let login) = self else { return nil }
        return login
    }
}
