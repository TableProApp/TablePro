//
//  TunnelCommandPaneViewModel.swift
//  TablePro
//

import Foundation

@Observable
@MainActor
final class TunnelCommandPaneViewModel {
    var state = TunnelCommandFormState()

    var coordinator: WeakCoordinatorRef?

    var validationIssues: [String] {
        guard state.enabled else { return [] }
        return TunnelCommandBuilder.validationIssues(for: state.buildConfig())
    }

    func previewCommand(remoteHost: String, remotePort: Int) -> String? {
        TunnelCommandBuilder.previewCommand(
            for: state.buildConfig(),
            remoteHost: remoteHost.isEmpty ? "localhost" : remoteHost,
            remotePort: remotePort
        )
    }

    func load(from connection: DatabaseConnection) {
        state.load(from: connection)
    }
}
