//
//  SSHPaneViewModel.swift
//  TablePro
//

import Foundation

@Observable
@MainActor
final class SSHPaneViewModel {
    var state = SSHTunnelFormState()

    var coordinator: WeakCoordinatorRef?

    var validationIssues: [String] {
        guard state.enabled else { return [] }
        var issues: [String] = []
        for other in coordinator?.value?.otherEnabledTunnels(excluding: .ssh) ?? [] {
            issues.append(String(
                format: String(localized: "Cannot use %@ and %@ at the same time"),
                other.kind.displayName,
                ConnectionTunnelKind.ssh.displayName
            ))
        }
        guard state.profileId == nil else { return issues }
        if state.host.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(String(localized: "SSH host is required"))
        }
        if !state.port.isEmpty,
           Int(state.port).map({ !(1...65_535).contains($0) }) ?? true {
            issues.append(String(localized: "SSH port must be between 1 and 65535"))
        }
        if !state.jumpHosts.allSatisfy(\.isValid) {
            issues.append(String(localized: "Jump host configuration is invalid"))
        }
        return issues
    }

    func loadSSHConfig() {
        Task {
            let entries = await Task.detached { SSHConfigParser.parse() }.value
            state.configEntries = entries
        }
    }

    func load(from connection: DatabaseConnection, storage: ConnectionStorage) {
        state.profiles = SSHProfileStorage.shared.loadProfiles()
        state.load(from: connection)
        state.loadSecrets(connectionId: connection.id, storage: storage)
    }

    func loadProfiles() {
        state.profiles = SSHProfileStorage.shared.loadProfiles()
    }
}
