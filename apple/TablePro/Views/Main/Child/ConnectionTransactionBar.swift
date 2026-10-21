//
//  ConnectionTransactionBar.swift
//  TablePro
//

import AppKit
import SwiftUI

/// What one hold's row says, kept apart from the view so the wording is pinned by a test.
internal struct ConnectionTransactionBarContent: Equatable {
    static let openSymbolName = "hourglass"
    static let abortedSymbolName = "exclamationmark.triangle.fill"

    let isAborted: Bool
    let title: String
    let subtitle: String
    let accessibilityLabel: String
    let offersCommit: Bool

    var symbolName: String {
        isAborted ? Self.abortedSymbolName : Self.openSymbolName
    }

    init(isAborted: Bool, connectionName: String, database: String?, safeModeLevel: SafeModeLevel) {
        self.isAborted = isAborted
        let database = database.flatMap { $0.isEmpty ? nil : $0 }
        if isAborted {
            title = String(localized: "Transaction Failed")
            subtitle = String(localized: "Roll it back to continue.")
            accessibilityLabel = database.map {
                String(
                    format: String(localized: "Transaction failed on %1$@, %2$@. Roll it back to continue."),
                    $0,
                    connectionName
                )
            } ?? String(format: String(localized: "Transaction failed on %@. Roll it back to continue."), connectionName)
            offersCommit = false
            return
        }
        title = String(localized: "Transaction Open")
        subtitle = database ?? connectionName
        accessibilityLabel = database.map {
            String(format: String(localized: "Transaction open on %1$@, %2$@"), $0, connectionName)
        } ?? String(format: String(localized: "Transaction open on %@"), connectionName)
        offersCommit = !safeModeLevel.blocksAllWrites
    }
}

/// Shown above every tab of a connection while one of its session connections holds a transaction.
internal struct ConnectionTransactionBar: View {
    let connectionId: UUID
    @ObservedObject var transactions: SessionTransactionTracker
    let databaseManager: DatabaseManager

    @State private var actingOn: SessionTransactionTracker.Key?

    var body: some View {
        let holds = transactions.holds(for: connectionId)
        if let session = databaseManager.session(for: connectionId), !holds.isEmpty {
            VStack(spacing: 0) {
                ForEach(holds) { hold in
                    row(hold, content: content(for: hold, in: session))
                    Divider()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("connection-transaction-bar")
        }
    }

    private func content(for hold: SessionTransactionTracker.Hold, in session: ConnectionSession) -> ConnectionTransactionBarContent {
        ConnectionTransactionBarContent(
            isAborted: hold.state == .aborted,
            connectionName: session.connection.name,
            database: hold.key.lane ?? namedDatabase(of: session),
            safeModeLevel: session.safeModeLevel
        )
    }

    // SQLite, DuckDB and other single-file engines name no database the server knows.
    private func namedDatabase(of session: ConnectionSession) -> String? {
        guard PluginManager.shared.supportsDatabaseSwitching(for: session.connection.type) else { return nil }
        return session.resolvedBrowseDatabase
    }

    private func row(_ hold: SessionTransactionTracker.Hold, content: ConnectionTransactionBarContent) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                if actingOn == hold.key {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: content.symbolName)
                        .foregroundStyle(content.isAborted ? Color.red : Color.orange)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(content.title)
                        .font(.callout.weight(.semibold))
                    Text(content.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.accessibilityLabel)

            Spacer(minLength: 8)

            Button(String(localized: "Roll Back")) {
                act(on: hold) { try await rollBack(hold) }
            }
            if content.offersCommit {
                Button(String(localized: "Commit")) {
                    act(on: hold) { try await commit(hold) }
                }
            }
        }
        .controlSize(.small)
        .disabled(actingOn != nil)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .paneBarBackground()
    }

    // Never gated by Safe Mode: rolling back keeps nothing, so it is the way out at every level.
    private func rollBack(_ hold: SessionTransactionTracker.Hold) async throws {
        let confirmed = await AlertHelper.confirmDestructive(
            title: String(localized: "Roll Back the Transaction?"),
            message: String(localized: "Its uncommitted changes are discarded."),
            confirmButton: String(localized: "Roll Back"),
            window: NSApp.keyWindow
        )
        guard confirmed else { return }
        try await databaseManager.endTransaction(hold, committing: false)
    }

    // A COMMIT is a write, so it asks what a typed one asks: nothing at Silent, a confirmation at
    // Alert, Touch ID at Safe Mode.
    private func commit(_ hold: SessionTransactionTracker.Hold) async throws {
        guard let session = databaseManager.session(for: connectionId) else { return }
        let decision = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: connectionId,
                databaseType: session.connection.type,
                sql: "COMMIT",
                kind: .writeQuery,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: String(localized: "Commit the transaction")
            )
        )
        switch decision {
        case .authorized:
            try await databaseManager.endTransaction(hold, committing: true)
        case .denied(_, .cancelledByUser):
            return
        case .denied(let reason, .policy):
            throw SessionTransactionDenial(reason: reason)
        }
    }

    private func act(on hold: SessionTransactionTracker.Hold, _ action: @escaping @MainActor () async throws -> Void) {
        actingOn = hold.key
        Task {
            defer { actingOn = nil }
            do {
                try await action()
            } catch is CancellationError {
                return
            } catch {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Could Not End the Transaction"),
                    message: error.localizedDescription,
                    window: NSApp.keyWindow
                )
            }
        }
    }
}

private struct SessionTransactionDenial: LocalizedError {
    let reason: String

    var errorDescription: String? { reason }
}
