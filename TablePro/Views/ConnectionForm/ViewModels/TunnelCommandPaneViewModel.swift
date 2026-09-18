//
//  TunnelCommandPaneViewModel.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
final class TunnelCommandPaneViewModel: ObservableObject {
    @Published var state = TunnelCommandFormState()

    @Published var coordinator: WeakCoordinatorRef?

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
