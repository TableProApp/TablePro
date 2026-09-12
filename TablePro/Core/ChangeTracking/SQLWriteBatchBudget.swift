//
//  SQLWriteBatchBudget.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// How much one parameterized `INSERT` may carry, in the two units that can reject it.
///
/// A bind-parameter count is not a size. `executeParameterized` reaches MySQL as
/// `mysql_stmt_prepare` plus `mysql_stmt_execute`, one packet each, and a packet over
/// `max_allowed_packet` answers `ERROR 1153: Got a packet bigger than 'max_allowed_packet' bytes`,
/// or `ERROR 2006: Server has gone away` once it is large enough. So a batch bounded by parameters
/// alone is unbounded in bytes: 500 rows of three 1 MB values sit well inside a three-column
/// table's 21,845-row parameter ceiling and go out as one 500 MB statement the server refuses,
/// which fails the first batch and leaves nothing written at all. (#2533)
///
/// `maximumBytes` is the mebibyte `mysqldump` settles on for `net_buffer_length` and the SQL export
/// defaults to: under every `max_allowed_packet` a release has shipped with, and far above a batch
/// of ordinary rows, so nothing narrow writes more statements than before. Not a user preference
/// here, because this statement goes to a server the app is connected to rather than into a file.
internal struct SQLWriteBatchBudget: Sendable, Equatable {
    /// However narrow the table is: 65,535 one-column rows in one statement parse slowly on every
    /// engine, cannot be cancelled part-way, and save nothing measurable past a thousand.
    internal static let maximumRows = 1_000
    internal static let maximumBytes = 1_048_576

    internal let maxRows: Int
    internal let maxBytes: Int

    internal init(maxRows: Int, maxBytes: Int = SQLWriteBatchBudget.maximumBytes) {
        self.maxRows = max(1, maxRows)
        self.maxBytes = max(1, maxBytes)
    }

    /// The engine's bind-parameter ceiling over the row's width, clamped by its multi-row `VALUES`
    /// ceiling and by the flat cap. `SQLMultiRowInsert` owns that middle term, so the SQL export
    /// reads the same rule and Oracle keeps its one row per statement.
    internal init(
        columnCount: Int,
        generator: SQLStatementGenerator,
        maxBytes: Int = SQLWriteBatchBudget.maximumBytes
    ) {
        self.init(
            maxRows: min(
                Self.maximumRows,
                SQLMultiRowInsert.maximumRowsPerStatement(
                    forDatabaseTypeId: generator.databaseType.rawValue),
                generator.maxBindParameters / max(1, columnCount)),
            maxBytes: maxBytes)
    }

    /// A batch holding nothing takes the row whatever it weighs: a row cannot be split across two
    /// statements, so refusing it would write nothing at all. It goes out alone, which is what
    /// `mysqldump` does with a row larger than its own buffer.
    internal func hasRoom(for rowBytes: Int, inBatchOf rows: Int, bytes: Int) -> Bool {
        guard rows > 0 else { return true }
        guard rows < maxRows else { return false }
        return bytes + rowBytes <= maxBytes
    }

    /// What a row costs on the wire, as an upper bound.
    ///
    /// Measured against MariaDB 12.3.3 through the binary protocol, the per-value overhead settles
    /// at about 6 bytes: 1,500 values of 100 bytes crossed as 158,650 against 150,000 of payload.
    /// The documented `COM_STMT_EXECUTE` layout says why, and bounds it: 2 bytes of the type array
    /// per parameter, a length-encoded prefix of at most 4 bytes for any value under 16 MB, and one
    /// null-bitmap bit. Twelve covers every size including the 9-byte prefix a value could
    /// theoretically carry, and over-charging many small values is safe where under-charging a few
    /// large ones is exactly what fails.
    internal static func byteCount<Values: Sequence>(of values: Values) -> Int
    where Values.Element == PluginCellValue {
        var total = 0
        for value in values {
            switch value {
            case .null:
                total += valueOverheadBytes
            case .text(let text):
                total += valueOverheadBytes + text.utf8.count
            case .bytes(let data):
                total += valueOverheadBytes + data.count
            }
        }
        return total
    }

    private static let valueOverheadBytes = 12
}

/// Fills one batch at a time under a budget, so no call site holds a byte counter beside its row
/// array and has to keep the two in step. The same shape as `SQLExportStatementAccumulator` and the
/// same rule: a batch is closed *before* the row that would cross the budget, never after, so what
/// is sent stays under the limit.
internal struct SQLWriteBatchFiller<Row> {
    private let budget: SQLWriteBatchBudget
    private var rows: [Row] = []
    private var bytes = 0

    internal init(budget: SQLWriteBatchBudget) {
        self.budget = budget
    }

    /// Hands back the batch this row closed, if it closed one. The row itself is always held, never
    /// handed back inside a batch it did not fit.
    internal mutating func append(_ row: Row, bytes rowBytes: Int) -> [Row]? {
        var completed: [Row]?
        if !budget.hasRoom(for: rowBytes, inBatchOf: rows.count, bytes: bytes) {
            completed = take()
        }
        rows.append(row)
        bytes += rowBytes
        return completed
    }

    /// Closes whatever is held, and answers nil when nothing is.
    internal mutating func take() -> [Row]? {
        guard !rows.isEmpty else { return nil }
        let batch = rows
        rows.removeAll(keepingCapacity: true)
        bytes = 0
        return batch
    }
}
