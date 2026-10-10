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

    /// Trust covers the target, not what a link runs on it, so a link carrying a filter asks every
    /// time and cannot be trusted from that prompt.
    internal func authorize(
        _ connection: DatabaseConnection,
        scopeName: String?,
        filter: ConnectionURLFilter? = nil
    ) async -> Bool {
        let key = ExternalConnectionTrustKey(connection: connection, scopeName: scopeName)
        let trustable = key.isLoopbackHost && filter == nil
        if trustable, trustStore.isTrusted(key) { return true }

        switch await prompt.prompt(for: connection, filter: filter, offerAlwaysAllow: trustable) {
        case .connect:
            return true
        case .alwaysAllow:
            if trustable {
                trustStore.trust(key)
            }
            return true
        case .cancel:
            return false
        }
    }
}
