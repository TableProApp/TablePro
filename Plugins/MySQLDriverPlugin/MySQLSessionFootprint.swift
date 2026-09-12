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
/// The open transaction is the server's own answer, from the status flags it puts in every reply
/// (`observeServerTransaction`). The rest is read from the statement text, because MySQL will not
/// answer those. Measured on MySQL 8.4.11, a user granted only its own database is refused on
/// every table that would report them: error 1142 on
/// `performance_schema.user_variables_by_thread`, `prepared_statements_instances`,
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
    private(set) var hasOpenHandlers = false
    private(set) var hasSessionSettings = false

    /// A `USE` the user ran themselves. The driver's own database switch does not come through
    /// here, because it records the database it moved to and every reconnect connects to that one;
    /// a `USE` typed into the editor does not, so a reconnect silently puts the session back on
    /// the database the driver still thinks it is on.
    private(set) var hasChangedDatabase = false

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
        if hasOpenHandlers {
            return String(localized: "This connection has open HANDLER cursors, which reconnecting would close.")
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
        if hasChangedDatabase {
            return String(localized: "This connection switched database with USE, which reconnecting would undo.")
        }
        if ranOpaqueRoutine {
            return String(localized: "This connection called a stored routine, so TablePro cannot tell what the session is holding.")
        }
        return nil
    }

    mutating func observe(_ sql: String) {
        for statement in SQLStatementSplitting.statements(in: sql) {
            let body = Self.executableBody(of: statement)
            observeTransaction(body)
            observeStatement(body)
        }
    }

    /// The server's own answer, taken from the status flags in its last reply, which is exact
    /// where reading the statements is a guess. Measured on MySQL 8.4.11: `SET autocommit = 0`
    /// followed by a plain `SELECT` reports a transaction that appears nowhere in the text, and so
    /// do `/*!40101 BEGIN */` and `XA START 'x'`. It is applied after the statement has run, so
    /// the text-derived guess is what stands until the reply arrives.
    mutating func observeServerTransaction(isOpen: Bool) {
        hasOpenTransaction = isOpen
    }

    private mutating func observeTransaction(_ statement: String) {
        switch SQLTransactionTracking.effect(of: statement) {
        case .opens: hasOpenTransaction = true
        case .closes: hasOpenTransaction = false
        case .unchanged: break
        @unknown default: hasOpenTransaction = true
        }
    }

    /// Forgets everything, for a reconnect the driver has decided is safe. Only the statements
    /// that would have blocked it are tracked, so a clean footprint is the whole precondition.
    mutating func reset() {
        self = MySQLSessionFootprint()
    }

    private mutating func observeStatement(_ statement: String) {
        let normalized = statement.uppercased()
        let head = Self.collapsedHead(of: normalized)
        guard !head.isEmpty else { return }

        if head.hasPrefix("CREATE TEMPORARY ") || head.hasPrefix("CREATE OR REPLACE TEMPORARY ") {
            hasTemporaryTables = true
        }
        /// Set, not cleared: a drop names one table and says nothing about the others, and a
        /// session with a temporary table left is still one a reconnect would damage.
        if head.hasPrefix("DROP TEMPORARY ") {
            hasTemporaryTables = true
        }
        if head.hasPrefix("PREPARE ") {
            hasPreparedStatements = true
        }
        if head.hasPrefix("DEALLOCATE ") {
            hasPreparedStatements = true
        }
        if head.hasPrefix("LOCK TABLE") {
            hasLockedTables = true
        }
        /// `FLUSH TABLES WITH READ LOCK` takes a global read lock that is the session's and
        /// nothing else's, and the sessions that hold one are idle by design while a backup
        /// copies files. Measured on MySQL 8.4.11: a writer got error 1205 while it was held, and
        /// the same write went through the moment the holding connection was killed.
        if head.hasPrefix("FLUSH "), Self.isFlushHoldingALock(normalized) {
            hasLockedTables = true
        }
        if head.hasPrefix("UNLOCK TABLES") {
            hasLockedTables = false
        }
        /// Set, not cleared, for the same reason a dropped temporary table is: a `HANDLER ... CLOSE`
        /// names one cursor.
        if head.hasPrefix("HANDLER ") {
            hasOpenHandlers = true
        }
        if head.hasPrefix("CALL ") {
            ranOpaqueRoutine = true
        }
        if head.hasPrefix("USE ") {
            hasChangedDatabase = true
        }
        if normalized.contains("GET_LOCK(") {
            hasAdvisoryLocks = true
        }
        if normalized.contains("RELEASE_ALL_LOCKS(") {
            hasAdvisoryLocks = false
        }
        if head.hasPrefix("SET ") {
            observeSet(head)
        }
        /// `SELECT ... INTO @x` and `EXECUTE ... INTO @x` write a user variable without a leading
        /// `SET`, and `SELECT @x := 1` writes one without either. Both spellings lose the variable
        /// on a reconnect just as `SET @x` does.
        if normalized.contains("INTO @") || normalized.contains("@") && normalized.contains(":=") {
            hasUserVariables = true
        }
    }

    /// What MySQL runs when the statement opens with one of its version-gated comments, and the
    /// statement itself otherwise.
    ///
    /// `/*!40101 SET NAMES utf8mb4 */` is executed by any server from 4.1.1, and MariaDB spells
    /// its own `/*M!100301 ... */`. mysqldump writes its whole preamble this way, so a restore run
    /// from the editor sets the character set, the time zone and eight `@OLD_` variables inside
    /// them. `SQLStatementSplitting` leaves them whole rather than reading them as comments,
    /// because only the engine that executes the body can say what it is.
    ///
    /// Whatever follows the comment is kept, so a line that carries a note after it, or a second
    /// version-gated block, is still classified by the first thing the server would run. The
    /// version number itself is not checked against the server: counting a statement the server
    /// is too old to run holds a connection that is in fact clean, which is the safe direction.
    private static func executableBody(of statement: String) -> String {
        guard statement.hasPrefix("/*!") || statement.hasPrefix("/*M!") else { return statement }
        guard let close = statement.range(of: "*/") else { return statement }
        let marked = statement[statement.index(statement.startIndex, offsetBy: 2)..<close.lowerBound]
        let body = marked
            .drop(while: { $0 == "M" })
            .dropFirst()
            .drop(while: { $0.isNumber })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = statement[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return body }
        return body.isEmpty ? remainder : "\(body) \(remainder)"
    }

    /// The statement's opening words with each run of whitespace collapsed, which is what the
    /// prefix checks match against: `CREATE TEMPORARY\nTABLE` is the same statement as
    /// `CREATE TEMPORARY TABLE`, and reading the first one as neither left a session holding a
    /// temporary table that the idle release then dropped. Only the head is normalised, because
    /// `observe` runs on every statement and a dump's `INSERT` can be megabytes long.
    private static func collapsedHead(of normalized: String) -> String {
        normalized
            .prefix(headLength)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static let headLength = 64

    /// A `FLUSH` names its tables before the clause that matters, and a list of them runs past
    /// the head, so this one reads the whole statement. No `FLUSH` is long enough for that to
    /// cost anything.
    private static func isFlushHoldingALock(_ normalized: String) -> Bool {
        let collapsed = normalized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.contains(" WITH READ LOCK") || collapsed.contains(" FOR EXPORT")
    }

    /// `SET` covers three different things: a user variable (`SET @x = 1`), a session setting
    /// (`SET SESSION sql_mode = ...`, the bare `SET sql_mode = ...` that means the same, and
    /// `SET NAMES` and `SET CHARACTER SET` under another spelling), and a global one, which
    /// outlives the connection and so is not the session's to lose.
    private mutating func observeSet(_ normalized: String) {
        let body = normalized.dropFirst("SET ".count).trimmingCharacters(in: .whitespaces)
        guard !body.hasPrefix("@@GLOBAL."), !body.hasPrefix("GLOBAL ") else { return }
        /// `@@` is a system variable under another spelling, not a user variable: reporting
        /// `SET @@SESSION.sql_mode` as "session variables set" blocks the release for the right
        /// reason and tells the user the wrong one.
        if body.hasPrefix("@"), !body.hasPrefix("@@") {
            hasUserVariables = true
        } else {
            hasSessionSettings = true
        }
    }
}
