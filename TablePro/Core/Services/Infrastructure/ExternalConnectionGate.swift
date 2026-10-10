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

    /// The trust key names neither a filter nor an SSH server, so trusting a link that carries one
    /// would cover whatever SQL or server a later link picks. A tunnelled loopback host is not on
    /// this Mac either.
    internal func authorize(
        _ connection: DatabaseConnection,
        scopeName: String?,
        filter: ConnectionURLFilter? = nil
    ) async -> Bool {
        let key = ExternalConnectionTrustKey(connection: connection, scopeName: scopeName)
        let trustable = key.isLoopbackHost && !connection.sshConfig.enabled && filter == nil
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
