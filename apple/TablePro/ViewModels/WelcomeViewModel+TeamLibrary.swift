//
//  WelcomeViewModel+TeamLibrary.swift
//  TablePro
//
//  Publishing connections to the backend-hosted team library. Credentials are never sent: the export
//  envelope strips passwords, passphrases, TOTP secrets, and secure plugin fields.
//

import AppKit

internal enum TeamLibraryConnectionPublishOutcome {
    case declined
    case published
    case failed(Error)
}

extension WelcomeViewModel {
    func publishConnectionsToTeamLibrary(_ connectionsToPublish: [DatabaseConnection]) {
        guard LicenseManager.shared.isFeatureAvailable(.teamLibrary), !connectionsToPublish.isEmpty else { return }

        Task { @MainActor in
            let outcome = await Self.publishConnections(
                connectionsToPublish,
                through: TeamLibrarySyncCoordinator.shared,
                confirm: Self.confirmPublishToTeamLibrary
            )
            if case .failed(let error) = outcome {
                presentTeamLibraryError(error)
            }
        }
    }

    static func publishConnections(
        _ connections: [DatabaseConnection],
        through coordinator: TeamLibrarySyncCoordinator,
        confirm: @MainActor ([DatabaseConnection]) async -> Bool
    ) async -> TeamLibraryConnectionPublishOutcome {
        guard await confirm(connections) else { return .declined }
        do {
            try await coordinator.publish(connections: connections, favorites: [], folders: [])
            return .published
        } catch {
            return .failed(error)
        }
    }

    private static func confirmPublishToTeamLibrary(_ connections: [DatabaseConnection]) async -> Bool {
        await AlertHelper.confirmDestructive(
            title: teamLibraryPublishConfirmationTitle(for: connections),
            message: teamLibraryPublishConfirmationMessage,
            confirmButton: String(localized: "Publish")
        )
    }

    static var teamLibraryPublishConfirmationMessage: String {
        String(
            localized: """
                Everyone on your team will see the host, port, user, database and SSH settings. \
                This replaces the connections and saved queries you published before. \
                Passwords are not included.
                """
        )
    }

    static func teamLibraryPublishConfirmationTitle(for connections: [DatabaseConnection]) -> String {
        guard connections.count == 1, let connection = connections.first else {
            return String(format: String(localized: "Publish %d connections to your team?"), connections.count)
        }
        return String(format: String(localized: "Publish “%@” to your team?"), connection.name)
    }

    private func presentTeamLibraryError(_ error: Error) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Couldn't publish to the team library"),
            message: error.localizedDescription,
            window: nil
        )
    }
}
