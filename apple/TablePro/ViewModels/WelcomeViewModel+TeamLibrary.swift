//
//  WelcomeViewModel+TeamLibrary.swift
//  TablePro
//

import AppKit

extension WelcomeViewModel {
    func publishConnectionsToTeamLibrary(_ connectionsToPublish: [DatabaseConnection], teamID: String) {
        guard !connectionsToPublish.isEmpty else { return }

        let library = TeamLibrary.shared
        let destination = library.destination(teamID)
        let syncsPasswords = library.writableTeams.first { $0.id == teamID }?.syncsPasswords ?? true
        Task { @MainActor in
            let outcome = await Self.publishConnections(
                connectionsToPublish,
                to: destination,
                through: library,
                confirm: { await Self.confirmPublishToTeamLibrary($0, syncsPasswords: syncsPasswords) }
            )
            TeamLibraryPublishing.present(outcome) {
                self.activeSheet = .teamLibraryConflicts
            }
        }
    }

    // The form opens on the team's copy with what its envelopes hold, so the person sees the password the team uses.
    func editTeamConnection(rowID: UUID) {
        let library = TeamLibrary.shared
        guard let original = library.content.connection(rowID: rowID), original.canWrite else { return }
        Task { @MainActor in
            let secrets = await library.secrets(for: original)
            TeamCopyEditStage.shared.stage(TeamCopyTarget(original: original, secrets: secrets))
            WindowOpener.shared.openTeamConnectionForm(teamID: original.teamID, itemID: original.id)
        }
    }

    func presentTeamLibraryConflicts() {
        guard !TeamLibrary.shared.conflicts.conflicts.isEmpty else { return }
        activeSheet = .teamLibraryConflicts
    }

    static func publishConnections(
        _ connections: [DatabaseConnection],
        to destination: TeamLibraryDestination,
        through library: TeamLibrary,
        confirm: @MainActor ([DatabaseConnection]) async -> Bool
    ) async -> TeamLibraryPublishOutcome {
        guard await confirm(connections) else { return .declined }
        do throws(TeamLibraryPublishError) {
            return .finished(try await library.publishConnections(connections, to: destination))
        } catch {
            return .failed(error)
        }
    }

    private static func confirmPublishToTeamLibrary(_ connections: [DatabaseConnection], syncsPasswords: Bool) async -> Bool {
        await AlertHelper.confirm(
            title: teamLibraryPublishConfirmationTitle(for: connections),
            message: teamLibraryPublishConfirmationMessage(syncsPasswords: syncsPasswords),
            confirmButton: String(localized: "Publish")
        )
    }

    static func teamLibraryPublishConfirmationMessage(syncsPasswords: Bool) -> String {
        syncsPasswords
            ? String(
                localized: """
                    Everyone on your team will see the host, port, user, database and SSH settings, and can use the \
                    passwords, which are encrypted so only the team's members can read them. Publishing again \
                    updates the team's copy.
                    """
            )
            : String(
                localized: """
                    Everyone on your team will see the host, port, user, database and SSH settings. Publishing again \
                    updates the team's copy. Your team doesn't sync passwords, so they are not included.
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
