//
//  MySQLSessionFootprint.swift
//  MySQLDriverPlugin
//
//  What a session is holding that reconnecting would destroy, tracked from the statements
//  that go through it. No CMariaDB import, so TableProTests can exercise it without loading
//  the plugin bundle.
//

import Foundation
import TableProPluginKit

/// Everything a MySQL session accumulates that a close and reconnect silently throws away.
///
/// Measured against MySQL 8.4.11 and MariaDB 12.3.3: a reconnect loses the selected database,
/// every `SET SESSION` value, every user variable, every `TEMPORARY` table, every prepared
/// statement, every `GET_LOCK` advisory lock and `LAST_INSERT_ID`, and rolls an open transaction
/// back reporting success.
///
/// This is tracked from the statement text rather than asked of the server, which is the opposite
/// of what the DuckDB driver does, because MySQL will not answer the question. Measured on MySQL
/// 8.4.11, a user granted only its own database is refused on every table that would report this:
/// error 1142 on `performance_schema.user_variables_by_thread`, `prepared_statements_instances`,
/// `metadata_locks` and `events_transactions_current`, and error 1227 on
/// `information_schema.INNODB_TRX` and `INNODB_TEMP_TABLE_INFO`. Asking would therefore work only
/// for a privileged user, and `GET_LOCK` has no enumeration for anybody. Reading the statements
/// costs no privilege, needs no round trip, and behaves the same on MariaDB.
///
/// Every ambiguity resolves toward "the session is holding something". The cost of that is only
/// that a connection keeps its slot, which is what happens today; the cost of the opposite is
/// destroying a user's transaction or temporary table without telling them.
struct MySQLSessionFootprint: Equatable {
    private(set) var hasOpenTransaction = false
    private(set) var hasTemporaryTables = false
    private(set) var hasUserVariables = false
    private(set) var hasPreparedStatements = false
    private(set) var hasAdvisoryLocks = false
    private(set) var hasLockedTables = false
    private(set) var hasSessionSettings = false

    /// A `CALL` runs a body this driver never sees, and a routine is free to create a temporary
    /// table, take a lock or open a transaction. Opaque is the only honest reading.
    private(set) var ranOpaqueRoutine = false

    var isClean: Bool {
        self == MySQLSessionFootprint()
    }

    /// Why the session cannot be released, in the user's language, or nil when it can.
    var blockingReason: String? {
        if hasOpenTransaction {
            return String(localized: "This connection has an open transaction. Commit or roll it back first.")
        }
        if hasTemporaryTables {
            return String(localized: "This connection has temporary tables, which reconnecting would delete.")
        }
        if hasLockedTables {
            return String(localized: "This connection holds table locks, which reconnecting would release.")
        }
        if hasAdvisoryLocks {
            return String(localized: "This connection holds advisory locks, which reconnecting would release.")
        }
        if hasPreparedStatements {
            return String(localized: "This connection has prepared statements, which reconnecting would discard.")
        }
        if hasUserVariables {
            return String(localized: "This connection has session variables set, which reconnecting would clear.")
        }
        if hasSessionSettings {
            return String(localized: "This connection has session settings changed, which reconnecting would reset.")
        }
        if ranOpaqueRoutine {
            return String(localized: "This connection called a stored routine, so TablePro cannot tell what the session is holding.")
        }
        return nil
    }

    mutating func observe(_ sql: String) {
        switch SQLTransactionTracking.effect(of: sql) {
        case .opens: hasOpenTransaction = true
        case .closes: hasOpenTransaction = false
        case .unchanged: break
        @unknown default: hasOpenTransaction = true
        }

        for statement in sql.split(separator: ";") {
            observeStatement(statement)
        }
    }

    /// Forgets everything, for a reconnect the driver has decided is safe. Only the statements
    /// that would have blocked it are tracked, so a clean footprint is the whole precondition.
    mutating func reset() {
        self = MySQLSessionFootprint()
    }

    private mutating func observeStatement(_ statement: Substring) {
        let normalized = statement
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty else { return }

        if normalized.hasPrefix("CREATE TEMPORARY ") || normalized.hasPrefix("CREATE OR REPLACE TEMPORARY ") {
            hasTemporaryTables = true
        }
        /// Set, not cleared: a drop names one table and says nothing about the others, and a
        /// session with a temporary table left is still one a reconnect would damage.
        if normalized.hasPrefix("DROP TEMPORARY ") {
            hasTemporaryTables = true
        }
        if normalized.hasPrefix("PREPARE ") {
            hasPreparedStatements = true
        }
        if normalized.hasPrefix("DEALLOCATE ") {
            hasPreparedStatements = true
        }
        if normalized.hasPrefix("LOCK TABLE") {
            hasLockedTables = true
        }
        if normalized.hasPrefix("UNLOCK TABLES") {
            hasLockedTables = false
        }
        if normalized.hasPrefix("CALL ") {
            ranOpaqueRoutine = true
        }
        if normalized.contains("GET_LOCK(") {
            hasAdvisoryLocks = true
        }
        if normalized.contains("RELEASE_ALL_LOCKS(") {
            hasAdvisoryLocks = false
        }
        if normalized.hasPrefix("SET ") {
            observeSet(normalized)
        }
        /// `SELECT ... INTO @x` and `EXECUTE ... INTO @x` both write a user variable without a
        /// leading `SET`. `INTO @` is specific enough to catch them and rare enough elsewhere.
        if normalized.contains("INTO @") {
            hasUserVariables = true
        }
    }

    /// `SET` covers three different things: a user variable (`SET @x = 1`), a session setting
    /// (`SET SESSION sql_mode = ...`, the bare `SET sql_mode = ...` that means the same, and
    /// `SET NAMES` and `SET CHARACTER SET` under another spelling), and a global one, which
    /// outlives the connection and so is not the session's to lose.
    private mutating func observeSet(_ normalized: String) {
        let body = normalized.dropFirst("SET ".count).trimmingCharacters(in: .whitespaces)
        guard !body.hasPrefix("@@GLOBAL."), !body.hasPrefix("GLOBAL ") else { return }
        if body.hasPrefix("@") {
            hasUserVariables = true
        } else {
            hasSessionSettings = true
        }
    }
}
