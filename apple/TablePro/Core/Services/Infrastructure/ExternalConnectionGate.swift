//
//  ExternalConnectionGate.swift
//  TablePro
//

import Foundation
import TableProSSHConfig

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

    // The key names neither a filter nor a transport, so trusting a link that carries one would cover whatever SQL or
    // server a later link picks. A loopback host behind any tunnel or proxy is not on this Mac either.
    internal func authorize(
        _ connection: DatabaseConnection,
        isSaved: Bool = false,
        scopeName: String?,
        filter: ConnectionURLFilter? = nil
    ) async -> Bool {
        let key = ExternalConnectionTrustKey(connection: connection, scopeName: scopeName, isSaved: isSaved)
        let staysOnThisMac = connection.enabledTunnelKinds.isEmpty
            && !connection.sshConfig.enabled
            && !connection.resolvedSSHConfig.enabled
        let trustable = key.isLoopbackHost && staysOnThisMac && filter == nil
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
