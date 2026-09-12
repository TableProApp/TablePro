//
//  SQLExportStatementBudget.swift
//  SQLExportPlugin
//

import Foundation

/// How large one `INSERT` may get, in the two units that actually bound it.
///
/// `maxBytes` is the real constraint. MySQL treats one statement as one packet and rejects an
/// oversized one with `ERROR 1153: Got a packet bigger than 'max_allowed_packet' bytes`; measured
/// against MariaDB 12.3.3 at its 16 MiB default, 500 rows of a mebibyte each came back as
/// `ERROR 2006: Server has gone away` instead, which names nothing a user could act on. Zero turns
/// the byte ceiling off and reproduces a row-count-only dump.
///
/// `maxRows` is a syntax ceiling, not a size one: see `SQLMultiRowInsert`.
internal struct SQLExportStatementBudget: Equatable {
    internal let maxRows: Int
    internal let maxBytes: Int

    internal init(maxRows: Int, maxBytes: Int) {
        self.maxRows = max(1, maxRows)
        self.maxBytes = max(0, maxBytes)
    }
}

/// What one export's statements came to, carried back out rather than kept on the plugin.
///
/// `PluginManager.exportPlugin(forFormat:)` hands every window the same cached plugin instance, so a
/// figure accumulated on that instance belongs to whichever export wrote it last. It also carries the
/// limit it was measured against, because the setting behind that limit is mutable and a second
/// window's options pane can move it while this export is still running.
internal struct SQLExportStatementTally: Equatable {
    internal var largestStatementBytes = 0
    internal var largestStatementRows = 0
    internal var oversizedRowCount = 0
    internal var limitBytes = 0

    /// Values the engine cannot carry in one statement whatever spelling is used, so the dump holds
    /// SQL that may not restore. Oracle caps a string literal at 4,000 characters, which is 2,000
    /// binary bytes through `HEXTORAW`, and nothing else can express one in a single statement.
    internal var unrepresentableValues = 0

    internal mutating func merge(_ other: SQLExportStatementTally) {
        if other.largestStatementBytes > largestStatementBytes {
            largestStatementBytes = other.largestStatementBytes
            largestStatementRows = other.largestStatementRows
        }
        oversizedRowCount += other.oversizedRowCount
        unrepresentableValues += other.unrepresentableValues
        limitBytes = max(limitBytes, other.limitBytes)
    }
}

/// Packs rendered rows into `INSERT` statements, closing each one at whichever limit it reaches first.
///
/// The budget is a ceiling rather than a trigger: a statement is closed *before* the row that would
/// cross it, so what gets written stays under the limit. That is what `mysqldump` does, measured over
/// 5,000 rows at its own `net_buffer_length` of 1,046,528: narrow rows produced a single 68,921 byte
/// statement, rows of a kibibyte produced five topping out at 1,046,411, and `--net-buffer-length=16384`
/// produced 1,247 narrow rows per statement against 15 wide ones. It carries no row counter at all.
///
/// A row that exceeds the whole budget on its own cannot be split, so it is written as its own
/// statement and counted in `oversizedRowCount`. `mysqldump` and HeidiSQL both do this; the export
/// reports it rather than letting the cap read as having held.
///
/// A class because it is a running buffer whose identity outlives the chunk of rows being fed to it:
/// a statement spans as many driver chunks as the budget allows, so nothing may reset it at a chunk
/// boundary.
internal final class SQLExportStatementAccumulator {
    /// What separates two rows, and what terminates a statement. Both are counted as the UTF-8 bytes
    /// they are, because the file is written as UTF-8 whatever encoding its prologue declares to the
    /// server.
    private static let rowSeparator = ",\n"
    private static let terminator = ";\n\n"
    private static let rowSeparatorBytes = 2
    private static let terminatorBytes = 3

    private let prefix: String
    private let suffix: String
    private let budget: SQLExportStatementBudget
    private let prefixBytes: Int
    private let suffixBytes: Int

    private var rows: [String] = []
    private var bodyBytes = 0

    internal private(set) var largestStatementBytes = 0
    internal private(set) var largestStatementRows = 0
    internal private(set) var oversizedRowCount = 0
    internal private(set) var statementCount = 0

    internal init(prefix: String, suffix: String, budget: SQLExportStatementBudget) {
        self.prefix = prefix
        self.suffix = suffix
        self.budget = budget
        prefixBytes = prefix.utf8.count
        suffixBytes = suffix.utf8.count
    }

    /// What this accumulator wrote, against the limit it was built with rather than whatever the
    /// setting says by the time the export finishes.
    internal var tally: SQLExportStatementTally {
        SQLExportStatementTally(
            largestStatementBytes: largestStatementBytes,
            largestStatementRows: largestStatementRows,
            oversizedRowCount: oversizedRowCount,
            limitBytes: budget.maxBytes)
    }

    /// Everything a statement costs beyond its rows. The suffix is part of it because an upsert's
    /// trailing clause is not small: `ON DUPLICATE KEY UPDATE` over a wide table, or a PostgreSQL
    /// `ON CONFLICT ... DO UPDATE SET`, runs to hundreds of bytes that a budget counting only values
    /// would spend twice.
    private var envelopeBytes: Int { prefixBytes + suffixBytes + Self.terminatorBytes }

    /// Takes one rendered row and hands back the statement it closed, if it closed one.
    internal func append(_ renderedRow: String) -> String? {
        let rowBytes = renderedRow.utf8.count
        var completed: String?
        if !rows.isEmpty {
            let projected = envelopeBytes + bodyBytes + Self.rowSeparatorBytes + rowBytes
            let rowsAreFull = rows.count >= budget.maxRows
            let bytesWouldOverflow = budget.maxBytes > 0 && projected > budget.maxBytes
            if rowsAreFull || bytesWouldOverflow {
                completed = finish()
            }
        }
        if rows.isEmpty {
            if budget.maxBytes > 0, envelopeBytes + rowBytes > budget.maxBytes {
                oversizedRowCount += 1
            }
            rows = [renderedRow]
            bodyBytes = rowBytes
        } else {
            rows.append(renderedRow)
            bodyBytes += Self.rowSeparatorBytes + rowBytes
        }
        return completed
    }

    /// Closes whatever is held, and answers nil when nothing is.
    internal func finish() -> String? {
        guard !rows.isEmpty else { return nil }
        let statement = prefix + rows.joined(separator: Self.rowSeparator) + suffix + Self.terminator
        let statementBytes = envelopeBytes + bodyBytes
        if statementBytes > largestStatementBytes {
            largestStatementBytes = statementBytes
            largestStatementRows = rows.count
        }
        statementCount += 1
        rows.removeAll(keepingCapacity: true)
        bodyBytes = 0
        return statement
    }
}
