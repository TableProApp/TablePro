//
//  SOCKSProxyPaneViewModel.swift
//  TablePro
//

import Foundation

@Observable
@MainActor
final class SOCKSProxyPaneViewModel {
    var state = SOCKSProxyFormState()

    var coordinator: WeakCoordinatorRef?

    var validationIssues: [String] {
        guard state.enabled else { return [] }
        var issues: [String] = []

        if state.host.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(String(localized: "SOCKS proxy host is required"))
        }

        let portIsValid = Int(state.port).map { (1...65_535).contains($0) } ?? false
        if !portIsValid {
            issues.append(String(localized: "SOCKS proxy port must be between 1 and 65535"))
        }

        for other in coordinator?.value?.otherEnabledTunnels(excluding: .socksProxy) ?? [] {
            issues.append(String(
                format: String(localized: "Cannot use %@ and %@ at the same time"),
                other.kind.displayName,
                ConnectionTunnelKind.socksProxy.displayName
            ))
        }

        return issues
    }

    func load(from connection: DatabaseConnection, storage: ConnectionStorage) {
        state.load(from: connection)
        state.password = storage.loadSOCKSProxyPassword(for: connection.id) ?? ""
    }

    func save(to connectionId: UUID, storage: ConnectionStorage) {
        guard state.enabled, !state.password.isEmpty else {
            storage.deleteSOCKSProxyPassword(for: connectionId)
            return
        }
        storage.saveSOCKSProxyPassword(state.password, for: connectionId)
    }
}
