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
        var issues = TunnelCommandBuilder.validationIssues(for: state.buildConfig())

        for other in coordinator?.value?.otherEnabledTunnels(excluding: .tunnelCommand) ?? [] {
            issues.append(String(
                format: String(localized: "Cannot use %@ and %@ at the same time"),
                other.kind.displayName,
                ConnectionTunnelKind.tunnelCommand.displayName
            ))
        }

        return issues
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
