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
        AlertHelper.showInfoSheet(
            title: String(localized: "Published to the team library"),
            message: String(
                format: String(localized: "Your team can now see %d shared connections. Passwords were not included."),
                connectionCount
            ),
            window: nil
        )
    }

    private func presentTeamLibraryError(_ error: Error) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Couldn't publish to the team library"),
            message: error.localizedDescription,
            window: nil
        )
    }
}
