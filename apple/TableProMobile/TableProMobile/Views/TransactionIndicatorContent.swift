import Foundation
import TableProModels

nonisolated struct TransactionIndicatorContent: Equatable, Sendable {
    nonisolated enum CommitOffer: Equatable, Sendable {
        case hidden
        case runs
        case asksFirst
    }

    static let openSymbolName = "hourglass"
    static let abortedSymbolName = "exclamationmark.triangle.fill"
    static let commitSymbolName = "checkmark"
    static let rollBackSymbolName = "arrow.uturn.backward"

    let isAborted: Bool
    let title: String
    let subtitle: String
    let accessibilityLabel: String
    let commit: CommitOffer

    var symbolName: String {
        isAborted ? Self.abortedSymbolName : Self.openSymbolName
    }

    init(
        isAborted: Bool,
        connectionName: String,
        activeDatabase: String,
        switchesDatabases: Bool,
        safeModeLevel: SafeModeLevel
    ) {
        self.isAborted = isAborted
        // SQLite, DuckDB and Oracle keep a restored or empty activeDatabase that names nothing on the server.
        let database = switchesDatabases && !activeDatabase.isEmpty ? activeDatabase : nil

        if isAborted {
            title = String(localized: "Transaction Failed")
            subtitle = String(localized: "Roll it back to continue.")
            if let database {
                accessibilityLabel = String(
                    format: String(localized: "Transaction failed on %1$@, %2$@. Roll it back to continue."),
                    database,
                    connectionName
                )
            } else {
                accessibilityLabel = String(
                    format: String(localized: "Transaction failed on %@. Roll it back to continue."),
                    connectionName
                )
            }
            commit = .hidden
            return
        }

        title = String(localized: "Transaction Open")
        subtitle = database ?? connectionName
        if let database {
            accessibilityLabel = String(
                format: String(localized: "Transaction open on %1$@, %2$@"),
                database,
                connectionName
            )
        } else {
            accessibilityLabel = String(format: String(localized: "Transaction open on %@"), connectionName)
        }
        switch safeModeLevel.writePermission {
        case .proceed:
            commit = .runs
        case .requiresConfirmation:
            commit = .asksFirst
        case .blocked:
            commit = .hidden
        }
    }

    // Mirrors ConnectionCoordinator.switchDatabase: only these engines dial a new session to switch.
    static func databaseSwitchEndsSession(for type: DatabaseType) -> Bool {
        type == .postgresql || type == .redshift
    }
}
