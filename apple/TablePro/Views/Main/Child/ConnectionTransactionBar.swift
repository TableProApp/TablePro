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

    init(isAborted: Bool, connectionName: String, database: String?, effectiveSafeModeLevel: SafeModeLevel) {
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
        offersCommit = ConnectionTransactionActions.offersCommit(.open, effectiveLevel: effectiveSafeModeLevel)
    }
}

/// Shown above every tab of a connection while one of its session connections holds a transaction.
internal struct ConnectionTransactionBar: View {
    let connectionId: UUID
    @ObservedObject var transactions: SessionTransactionTracker
    let databaseManager: DatabaseManager
    // Passed from the toolbar state the window observes, so the bar redraws when the level changes; the session's own
    // level publishes nothing. Commit follows the gate's level, read in `content(for:in:)`.
    let safeModeLevel: SafeModeLevel

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
            effectiveSafeModeLevel: ExecutionGateProvider.effectiveSafeModeLevel(for: connectionId, in: databaseManager)
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
                act(on: hold) {
                    try await ConnectionTransactionActions.rollBack(
                        hold, databaseManager: databaseManager, window: NSApp.keyWindow
                    )
                }
            }
            if content.offersCommit {
                Button(String(localized: "Commit")) {
                    act(on: hold) { try await ConnectionTransactionActions.commit(hold, databaseManager: databaseManager) }
                }
            }
        }
        .controlSize(.small)
        .disabled(actingOn != nil)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .paneBarBackground()
    }

    private func act(on hold: SessionTransactionTracker.Hold, _ action: @escaping @MainActor () async throws -> Void) {
        actingOn = hold.key
        Task {
            defer { actingOn = nil }
            await ConnectionTransactionActions.perform(window: NSApp.keyWindow, action)
        }
    }
}
