//
//  WelcomeViewModel+TeamLibrary.swift
//  TablePro
//
//  Publishing connections to the team library. Credentials are never sent: the export envelope strips passwords,
//  passphrases, TOTP secrets and secure plugin fields.
//

import AppKit

extension WelcomeViewModel {
    func publishConnectionsToTeamLibrary(_ connectionsToPublish: [DatabaseConnection], teamID: String) {
        guard !connectionsToPublish.isEmpty else { return }

        Task { @MainActor in
            let outcome = await Self.publishConnections(
                connectionsToPublish,
                to: teamID,
                through: TeamLibrarySync.shared,
                confirm: Self.confirmPublishToTeamLibrary
            )
            TeamLibraryPublishing.present(outcome, itemCount: connectionsToPublish.count, kind: .connections) {
                self.activeSheet = .teamLibraryConflicts
            }
        }
    }

    func presentTeamLibraryConflicts() {
        guard !TeamLibrarySync.shared.conflicts.isEmpty else { return }
        activeSheet = .teamLibraryConflicts
    }

    static func publishConnections(
        _ connections: [DatabaseConnection],
        to teamID: String,
        through sync: TeamLibrarySync,
        exporter: ConnectionBundleExporter = ConnectionBundleExporter(),
        confirm: @MainActor ([DatabaseConnection]) async -> Bool
    ) async -> TeamLibraryPublishOutcome {
        guard await confirm(connections) else { return .declined }
        let plan = connections.map {
            TeamLibraryPublishPlan.Connection(id: $0.id, settings: exporter.portableSettings(for: $0))
        }
        do throws(TeamLibraryPublishError) {
            return .finished(try await sync.publishConnections(plan, to: teamID))
        } catch {
            return .failed(error)
        }
    }

    private static func confirmPublishToTeamLibrary(_ connections: [DatabaseConnection]) async -> Bool {
        await AlertHelper.confirm(
            title: teamLibraryPublishConfirmationTitle(for: connections),
            message: teamLibraryPublishConfirmationMessage,
            confirmButton: String(localized: "Publish")
        )
    }

    static var teamLibraryPublishConfirmationMessage: String {
        String(
            localized: """
                Everyone on your team will see the host, port, user, database and SSH settings. \
                Publishing again updates the team's copy. Passwords are not included.
                """
        )
    }

    static func teamLibraryPublishConfirmationTitle(for connections: [DatabaseConnection]) -> String {
        guard connections.count == 1, let connection = connections.first else {
            return String(format: String(localized: "Publish %d connections to your team?"), connections.count)
        }
        return String(format: String(localized: "Publish “%@” to your team?"), connection.name)
    }
}
