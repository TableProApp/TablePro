//
//  LibPQConnectionLoss.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

enum LibPQTransactionState: Sendable, Equatable {
    case idle
    case active
    case inTransaction
    case inError
    case unknown

    var mayHoldTransaction: Bool {
        self != .idle
    }
}

enum LibPQServerMessage {
    private static let sessionEndingSeverities: Set<String> = ["FATAL", "PANIC"]
    private static let sessionEndingClasses: Set<Substring> = ["08", "57"]

    static func endsSession(severity: String?, sqlState: String?) -> Bool {
        if let severity {
            return sessionEndingSeverities.contains(severity)
        }
        guard let sqlState, sqlState.count == 5 else { return false }
        return sessionEndingClasses.contains(sqlState.prefix(2))
    }
}

enum LibPQConnectionLoss: Sendable, Equatable {
    case beforeSending(transactionMayBeOpen: Bool)
    case afterSending

    init(sent: Bool, recordedState: LibPQTransactionState) {
        self = sent ? .afterSending : .beforeSending(transactionMayBeOpen: recordedState.mayHoldTransaction)
    }
}

struct LibPQConnectionLostError: PluginDriverError {
    let loss: LibPQConnectionLoss
    let underlying: LibPQPluginError

    /// The server's own text stays in front of the explanation. Everything that reads an error
    /// reads this string: `DatabaseManager.isAuthenticationFailure` matches "authentication
    /// failed" in it, because PostgreSQL sends `28P01` rather than the `28000` its SQLSTATE arm
    /// looks for, and `DatabaseWriteRejectionDiagnosis` quotes it back to the user.
    var pluginErrorMessage: String {
        let parts = [underlying.message, explanation].filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    private var explanation: String {
        switch loss {
        case .beforeSending(transactionMayBeOpen: false):
            return String(
                localized: "The connection to the server was closed before the statement was sent. It was not run."
            )
        case .beforeSending(transactionMayBeOpen: true):
            return String(
                localized: """
                    The connection to the server was closed before the statement was sent. It was not run, and \
                    any open transaction was rolled back.
                    """
            )
        case .afterSending:
            return String(
                localized: """
                    Lost the connection to the server while the statement was running. It may or may not have \
                    completed. If a transaction was open, it was rolled back unless this statement committed it.
                    """
            )
        }
    }

    var pluginSqlState: String? {
        underlying.sqlState
    }

    var pluginErrorDetail: String? {
        underlying.detail
    }
}
