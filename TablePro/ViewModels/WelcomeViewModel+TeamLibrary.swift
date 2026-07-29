//
//  WelcomeViewModel+TeamLibrary.swift
//  TablePro
//
//  Publishing connections to the backend-hosted team library. Credentials are never sent: the export
//  envelope strips passwords, passphrases, TOTP secrets, and secure plugin fields.
//

import AppKit

extension WelcomeViewModel {
    func publishConnectionsToTeamLibrary(_ connectionsToPublish: [DatabaseConnection]) {
        guard LicenseManager.shared.isFeatureAvailable(.teamLibrary), !connectionsToPublish.isEmpty else { return }

        Task { @MainActor in
            do {
                let response = try await TeamLibrarySyncCoordinator.shared.publish(
                    connections: connectionsToPublish,
                    favorites: [],
                    folders: []
                )
                presentTeamLibrarySuccess(connectionCount: response.connectionCount)
            } catch {
                presentTeamLibraryError(error)
            }
        }
    }

    private func presentTeamLibrarySuccess(connectionCount: Int) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Published to the team library")
        alert.informativeText = String(
            format: String(localized: "Your team can now see %d shared connections. Passwords were not included."),
            connectionCount
        )
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func presentTeamLibraryError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't publish to the team library")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
