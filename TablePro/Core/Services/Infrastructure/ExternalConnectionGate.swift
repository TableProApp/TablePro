//
//  ExternalConnectionGate.swift
//  TablePro
//

import Foundation

@MainActor
internal struct ExternalConnectionGate {
    private let trustStore: ExternalConnectionTrustChecking
    private let prompt: ExternalConnectionPrompting

    internal init(
        trustStore: ExternalConnectionTrustChecking? = nil,
        prompt: ExternalConnectionPrompting? = nil
    ) {
        self.trustStore = trustStore ?? ExternalConnectionTrustStore.shared
        self.prompt = prompt ?? ExternalConnectionAlertPrompt()
    }

    internal func authorize(_ connection: DatabaseConnection, scopeName: String?) async -> Bool {
        let key = ExternalConnectionTrustKey(connection: connection, scopeName: scopeName)
        if key.isLoopbackHost, trustStore.isTrusted(key) { return true }

        switch await prompt.prompt(for: connection, offerAlwaysAllow: key.isLoopbackHost) {
        case .connect:
            return true
        case .alwaysAllow:
            trustStore.trust(key)
            return true
        case .cancel:
            return false
        }
    }
}
