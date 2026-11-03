//
//  AIProviderStatus.swift
//  TablePro
//

import Foundation

// One answer to "can this provider answer right now", read by the Settings row, the provider sheet
// and the chat panel, so they never disagree.
internal enum AIProviderStatus: Equatable, Sendable {
    case checking
    case ready(detail: String?)
    case needsAPIKey
    case needsSignIn
    case signingIn
    case needsInstall
    case needsUpdate(version: String)
    case failed(message: String)
    case notConfigured

    internal var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    internal var title: String {
        switch self {
        case .checking: String(localized: "Checking…")
        case .ready(let detail): detail ?? String(localized: "Ready")
        case .needsAPIKey: String(localized: "Needs an API key")
        case .needsSignIn: String(localized: "Not signed in")
        case .signingIn: String(localized: "Signing in…")
        case .needsInstall: String(localized: "Claude Code not installed")
        case .needsUpdate(let version): String(format: String(localized: "Claude Code %@ is too old"), version)
        case .failed(let message): message
        case .notConfigured: String(localized: "Not configured")
        }
    }

    // Only a state the user has to fix carries a symbol; a working or busy provider shows none.
    internal var severity: NoticeSeverity? {
        switch self {
        case .checking, .ready, .signingIn: nil
        case .failed: .error
        case .needsAPIKey, .needsSignIn, .needsInstall, .needsUpdate, .notConfigured: .warning
        }
    }

    internal static func resolve(
        provider: AIProviderConfig,
        hasAPIKey: Bool,
        oauthState: OAuthAuthState?,
        serviceError: String?,
        claudeAgent: ClaudeAgentService.InstallState
    ) -> AIProviderStatus {
        switch provider.authStyle {
        case .apiKey:
            return hasAPIKey ? .ready(detail: String(localized: "API key set")) : .needsAPIKey
        case .optionalApiKey:
            if hasAPIKey { return .ready(detail: String(localized: "API key set")) }
            return endpointStatus(provider.endpoint.isEmpty ? provider.defaultEndpoint : provider.endpoint)
        case .oauth:
            if let serviceError, !serviceError.isEmpty { return .failed(message: serviceError) }
            // No state yet: the sign-in lives in a service that has not answered.
            guard let oauthState else { return .checking }
            switch oauthState {
            case .signedIn(let identity):
                return .ready(detail: identity.isEmpty
                    ? String(localized: "Signed in")
                    : String(format: String(localized: "Signed in as %@"), identity))
            case .signingIn:
                return .signingIn
            case .signedOut:
                return .needsSignIn
            }
        case .none:
            if provider.type == .claudeAgent { return claudeAgentStatus(claudeAgent) }
            return endpointStatus(provider.endpoint.isEmpty ? provider.defaultEndpoint : provider.endpoint)
        }
    }

    private static func endpointStatus(_ endpoint: String) -> AIProviderStatus {
        guard !endpoint.isEmpty else { return .notConfigured }
        guard let host = URL(string: endpoint)?.host, !host.isEmpty else { return .ready(detail: endpoint) }
        if host == "localhost" || host == "127.0.0.1" { return .ready(detail: String(localized: "Local")) }
        return .ready(detail: host)
    }

    private static func claudeAgentStatus(_ state: ClaudeAgentService.InstallState) -> AIProviderStatus {
        switch state {
        case .unknown:
            return .checking
        case .notInstalled:
            return .needsInstall
        case .outdated(let version):
            return .needsUpdate(version: version)
        case .signedOut:
            return .needsSignIn
        case .signedIn(let account, _):
            guard let account, !account.isEmpty else { return .ready(detail: String(localized: "Signed in")) }
            return .ready(detail: String(format: String(localized: "Signed in as %@"), account))
        }
    }
}
