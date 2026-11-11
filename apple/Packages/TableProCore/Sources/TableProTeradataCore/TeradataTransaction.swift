import Foundation

public enum TeradataTransactionState: Sendable, Equatable {
    case idle
    case open
    case unknown
}

public enum TeradataSessionModeSource: Sendable, Equatable {
    case configured
    case helpSession
    case sessionInfoView
    // Neither read answered, so the session runs with Teradata semantics as before and its state is unknown.
    case unresolved
}

// BT and ET are invalid in an ANSI session, and COMMIT in a Teradata one. ANSI opens a transaction with the first
// request, so there is nothing to send to begin one.
enum TeradataTransactionSQL {
    // ROLLBACK and ABORT answer with a failure parcel even when they worked: 3514, or 3513 with a message.
    static let rollbackAnswerCodes: Set<Int> = [3_513, 3_514]

    static func begin(_ mode: TeradataTransactionMode) -> String? {
        mode == .ansi ? nil : "BEGIN TRANSACTION"
    }

    static func commit(_ mode: TeradataTransactionMode) -> String {
        mode == .ansi ? "COMMIT WORK" : "END TRANSACTION"
    }

    static func rollback(_ mode: TeradataTransactionMode) -> String {
        mode == .ansi ? "ROLLBACK WORK" : "ROLLBACK"
    }
}

enum TeradataSessionModeProbe {
    static let helpSession = "HELP SESSION"
    static let sessionInfo = "SELECT Transaction_Mode FROM DBC.SessionInfoV WHERE SessionNo = SESSION"

    static func mode(fromHelpSession result: TeradataResultSet) -> TeradataTransactionMode? {
        switch value(of: "Transaction Semantics", in: result) {
        case "ANSI"?: return .ansi
        case "TERADATA"?: return .tera
        default: return nil
        }
    }

    static func mode(fromSessionInfo result: TeradataResultSet) -> TeradataTransactionMode? {
        switch value(of: "Transaction_Mode", in: result) {
        case "A"?: return .ansi
        case "T"?: return .tera
        default: return nil
        }
    }

    // Matched by name, ignoring case, spaces and underscores, since the column's place in HELP SESSION is not fixed.
    private static func value(of column: String, in result: TeradataResultSet) -> String? {
        let wanted = normalized(column)
        guard let index = result.columns.firstIndex(where: { normalized($0.name) == wanted }),
              let row = result.rows.first, index < row.count,
              case .text(let text) = row[index] else { return nil }
        return text.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private static func normalized(_ name: String) -> String {
        name.uppercased().filter { $0 != " " && $0 != "_" }
    }
}

// Tracks the session's transaction from the requests that ran on it and how each ended.
struct TeradataTransactionTracker {
    let mode: TeradataTransactionMode
    private var explicitDepth = 0
    private var holdsChanges = false

    init(mode: TeradataTransactionMode) {
        self.mode = mode
    }

    // An ANSI session that only read holds read locks, which a commit releases harmlessly.
    var state: TeradataTransactionState {
        switch mode {
        case .ansi: return holdsChanges ? .open : .idle
        case .tera: return explicitDepth > 0 ? .open : .idle
        case .default: return .unknown
        }
    }

    // An abort rolls back the whole transaction; outside BT a Teradata-mode request is a transaction of its own.
    var abortRollsBackTransaction: Bool {
        mode == .ansi || explicitDepth > 0
    }

    mutating func ran(_ kinds: [TeradataStatementKind]) {
        for kind in kinds {
            switch kind {
            case .read:
                continue
            case .change:
                holdsChanges = true
            case .begin:
                if mode == .ansi { holdsChanges = true } else { explicitDepth += 1 }
            case .end:
                if mode == .ansi { holdsChanges = true } else { explicitDepth = max(explicitDepth - 1, 0) }
            case .commit:
                if mode == .ansi { holdsChanges = false }
            case .rollback:
                // Only `ROLLBACK ... WHERE` with a false condition answers success, and it rolled nothing back.
                continue
            }
        }
    }

    mutating func failed(_ kinds: [TeradataStatementKind], code: Int) {
        if code == TeradataConnection.userAbortCode
            || (kinds.contains(.rollback) && TeradataTransactionSQL.rollbackAnswerCodes.contains(code)) {
            rolledBack()
            return
        }
        // In Teradata semantics a failure rolls the whole transaction back. In ANSI the docs disagree on whether it
        // ends the transaction, so what it held is kept.
        if mode != .ansi { explicitDepth = 0 }
    }

    mutating func rolledBack() {
        explicitDepth = 0
        holdsChanges = false
    }
}
