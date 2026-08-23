//
//  StructureEditingSession+Apply.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What happened when a tab was asked to apply its staged structure edits.
///
/// The distinction that matters is `allowsClose`. A close offers Save because the tab holds staged
/// ALTERs; if the save did not put them in the database, closing destroys them, so every way of not
/// applying them has to stand the close down rather than report success.
internal enum StructureSaveOutcome: Equatable {
    /// Nothing was staged. The close may proceed: there is no work to lose.
    case nothingToApply
    case applied
    /// Safe Mode refused the write, or the user cancelled the destructive-changes prompt. The edits
    /// are still staged.
    case refused
    case failed(String)

    internal var allowsClose: Bool {
        switch self {
        case .nothingToApply, .applied: true
        case .refused, .failed: false
        }
    }
}

internal extension StructureEditingSession {
    /// Applies this tab's staged ALTERs, with no mounted view required.
    ///
    /// This is deliberately not on `TableStructureView`. `hasUnsavedWork` reads the session, so a
    /// tab that is merely open, or open on its Data view, can raise the unsaved-changes prompt; the
    /// save it offers used to dispatch through `coordinator.structureActions`, a weak slot only the
    /// mounted structure view ever fills. Answering Save from anywhere else ran nothing, reported
    /// success, and closed the tab over the work.
    func applyStagedChanges(coordinator: MainContentCoordinator?) async -> StructureSaveOutcome {
        /// Asked before Safe Mode, so a tab with nothing staged is never refused. `.refused` stands
        /// the close down, and refusing a save that had no work to do would leave the user unable to
        /// close the tab through Save at all.
        let changes = changeManager.getChangesArray()
        guard !changes.isEmpty else { return .nothingToApply }

        let liveSafeModeLevel = coordinator?.safeModeLevel ?? connection.safeModeLevel
        guard !liveSafeModeLevel.blocksAllWrites else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Safe Mode Is Read-Only"),
                message: String(
                    localized: "Cannot save schema changes: TablePro's Safe Mode is set to read-only for this connection."
                ),
                window: coordinator?.contentWindow
            )
            return .refused
        }

        let destructiveChanges = changes.filter(\.requiresDataMigration)
        if !destructiveChanges.isEmpty {
            let message = String(
                format: String(localized: "The following changes may cause data loss:\n\n%@\n\nDo you want to proceed?"),
                destructiveChanges.map(\.description).joined(separator: "\n")
            )
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Destructive Changes"),
                message: message,
                confirmButton: String(localized: "Apply Changes"),
                cancelButton: String(localized: "Cancel"),
                window: coordinator?.contentWindow
            )
            guard confirmed else { return .refused }
        }

        /// Started here, not at the top of the function. The destructive-changes prompt sits above
        /// this and the user can take as long as they like over it, so a clock started earlier
        /// measures their reading time and reports an instant ALTER as having taken a minute.
        let operationStart = ContinuousClock.Instant.now
        isApplying = true

        do {
            try await DatabaseManager.shared.executeSchemaChanges(
                tableName: tableName,
                changes: changes,
                databaseType: connection.type,
                scope: scope
            )
            changeManager.discardChanges()
            tabData.markAllStale()
            hasLoaded = false
            lastAppliedAt = Date()
            isApplying = false
            markApplied()
            report(.succeeded(OperationSummary()), startedAt: operationStart, coordinator: coordinator)
            return .applied
        } catch {
            isApplying = false
            report(.failed(reason: error.localizedDescription), startedAt: operationStart, coordinator: coordinator)
            AlertHelper.showErrorSheet(
                title: String(localized: "Error Applying Changes"),
                message: error.localizedDescription,
                window: coordinator?.contentWindow
            )
            return .failed(error.localizedDescription)
        }
    }

    /// Reported against this tab's own database, never the one the sidebar is browsing. A batch
    /// close applies tabs pointed at other databases, so ambient state names the wrong one.
    private func report(
        _ outcome: OperationOutcome,
        startedAt: ContinuousClock.Instant,
        coordinator: MainContentCoordinator?
    ) {
        OperationCompletionReporter.shared.report(
            OperationCompletion(
                kind: .schemaChange,
                owner: .connection(connection.id),
                connectionId: connection.id,
                connectionName: connection.name,
                databaseName: databaseName,
                elapsed: startedAt.duration(to: .now),
                outcome: outcome
            )
        )
    }
}
