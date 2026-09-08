//
//  SQLTransactionTracking.swift
//  TableProPluginKit
//

import Foundation

/// Whether the statements a driver has run leave its session inside a transaction, worked out
/// from the statement text because asking the engine is either impossible or destructive.
///
/// DuckDB's C API offers no way to ask, and the obvious probe destroys the answer: measured on the
/// shipped v1.5.2, a `BEGIN TRANSACTION` issued inside a transaction does not merely fail, it
/// **aborts the transaction it was testing for**, and every following statement answers
/// `Current transaction is aborted (please ROLLBACK)`. On MySQL 8 the tables that would report it
/// (`information_schema.INNODB_TRX`, `performance_schema.events_transactions_current`) are denied
/// to an ordinary user, measured as error 1227 and 1142.
///
/// The engine's own statement classification is not enough either. Measured on DuckDB, a
/// multi-statement batch reports the type of its **last** statement: `BEGIN; INSERT INTO t VALUES
/// (1);` reports `INSERT` and leaves a transaction open, while `BEGIN; INSERT; COMMIT;` reports
/// `TRANSACTION`. The statement text is what carries the answer.
///
/// Every ambiguity resolves toward "a transaction is open", because the only cost of being wrong
/// that way is that the file's lock is not released, which is what happens today anyway. Being
/// wrong the other way closes the handle and rolls the user's transaction back with nothing
/// raised. A `;` inside a string literal can therefore make this over-report, and that is the
/// intended direction.
public enum SQLTransactionTracking {
    public enum Effect: Equatable {
        case opens
        case closes
        case unchanged
    }

    private static let openingKeywords = ["BEGIN", "START"]

    /// Closing is matched against the whole statement rather than its first word, and the two
    /// directions are deliberately asymmetric.
    ///
    /// Statements come from `SQLStatementSplitting`, which does not cut inside a literal or a
    /// comment, so `SELECT ';COMMIT;'` stays one statement. Even so the two directions stay
    /// asymmetric: reading a fragment as an *open* costs only a resource kept a while longer, while
    /// reading one as a *close* clears the flag protecting a real transaction and the release that
    /// follows rolls it back.
    private static let closingStatements: Set<String> = [
        "COMMIT", "COMMIT TRANSACTION", "COMMIT WORK",
        "ROLLBACK", "ROLLBACK TRANSACTION", "ROLLBACK WORK",
        "END", "END TRANSACTION",
        "ABORT", "ABORT TRANSACTION",
    ]

    public static func effect(of sql: String) -> Effect {
        var effect = Effect.unchanged
        for statement in SQLStatementSplitting.statements(in: sql) {
            if closes(statement) {
                effect = .closes
            } else if opens(statement) {
                effect = .opens
            }
        }
        return effect
    }

    private static func opens(_ statement: String) -> Bool {
        guard let keyword = leadingKeyword(of: statement) else { return false }
        return openingKeywords.contains(keyword)
    }

    private static func closes(_ statement: String) -> Bool {
        let normalized = statement
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .uppercased()
        return closingStatements.contains(normalized)
    }

    private static func leadingKeyword(of statement: String) -> String? {
        guard let first = statement.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        return first.uppercased()
    }
}
