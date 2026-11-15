import Foundation
import TableProPluginKit

// How much one parameterized INSERT may carry, in rows and in bytes. A parameter count is no size: MySQL sends a
// prepared statement as one packet, and one over `max_allowed_packet` fails the first batch (#2533). The byte cap is the
// mebibyte `mysqldump` uses for `net_buffer_length`, under every shipped `max_allowed_packet`.
nonisolated struct SQLWriteBatchBudget: Sendable, Equatable {
    // However narrow the table: 65,535 one-column rows parse slowly, cannot be cancelled part-way, and save nothing past
    // a thousand.
    static let maximumRows = 1_000
    static let maximumBytes = 1_048_576

    let maxRows: Int
    let maxBytes: Int

    // A driver that renders values into the SQL text, as Databend does through `DatabendLiteral.inline`, pays for hex
    // and escaping: two 400,000-byte values are 800,024 bytes of parameters but over 1.6 MiB of SQL.
    let rendersValuesAsLiterals: Bool

    init(
        maxRows: Int,
        maxBytes: Int = SQLWriteBatchBudget.maximumBytes,
        rendersValuesAsLiterals: Bool = false
    ) {
        self.maxRows = max(1, maxRows)
        self.maxBytes = max(1, maxBytes)
        self.rendersValuesAsLiterals = rendersValuesAsLiterals
    }

    // The bind ceiling over the row's width, clamped by the multi-row VALUES ceiling, so Oracle keeps one row per
    // statement.
    init(
        columnCount: Int,
        statements: SQLImportStatements,
        maxBytes: Int = SQLWriteBatchBudget.maximumBytes
    ) {
        self.init(
            maxRows: min(
                Self.maximumRows,
                statements.maxRowsPerInsert,
                statements.maxBindParameters / max(1, columnCount)),
            maxBytes: maxBytes,
            rendersValuesAsLiterals: statements.rendersValuesAsLiterals)
    }

    // ClickHouse writes the values of a statement too long for the URL into it as escaped literals, binary as hex (#3777).
    static func rendersValuesAsLiterals(databaseTypeId: String) -> Bool {
        databaseTypeId == "Databend" || databaseTypeId == "ClickHouse"
    }

    // An empty batch takes the row whatever it weighs: a row cannot be split, so it goes out alone, as `mysqldump`
    // sends a row larger than its buffer.
    func hasRoom(for rowBytes: Int, inBatchOf rows: Int, bytes: Int) -> Bool {
        guard rows > 0 else { return true }
        guard rows < maxRows else { return false }
        return bytes + rowBytes <= maxBytes
    }

    // An upper bound. Measured on MariaDB 12.3.3, a value costs about 6 bytes beyond its payload; `COM_STMT_EXECUTE`
    // bounds it at 2 type bytes, a length prefix of at most 9 and a null bit, so 12 covers every size.
    func byteCount<Values: Sequence>(of values: Values) -> Int
    where Values.Element == PluginCellValue {
        var total = 0
        for value in values {
            switch value {
            case .null:
                total += Self.valueOverheadBytes
            case .text(let text):
                total += Self.valueOverheadBytes + charged(text)
            case .bytes(let data):
                total += Self.valueOverheadBytes + charged(data.count)
            }
        }
        return total
    }

    // Double is what hex costs a binary value and the worst escaping of a text one, but for NUL: Databend writes `\x00`.
    private func charged(_ bytes: Int) -> Int {
        rendersValuesAsLiterals ? bytes * 2 : bytes
    }

    private func charged(_ text: String) -> Int {
        guard rendersValuesAsLiterals else { return text.utf8.count }
        return text.utf8.reduce(into: text.utf8.count * 2) { total, byte in
            if byte == 0 { total += 2 }
        }
    }

    private static let valueOverheadBytes = 12
}

// A batch closes before the row that would cross the budget, never after, so what is sent stays under it.
nonisolated struct SQLWriteBatchFiller<Row> {
    private let budget: SQLWriteBatchBudget
    private var rows: [Row] = []
    private var bytes = 0

    init(budget: SQLWriteBatchBudget) {
        self.budget = budget
    }

    // The batch this row closed, if any. The row itself is always held for the next one.
    mutating func append(_ row: Row, bytes rowBytes: Int) -> [Row]? {
        var completed: [Row]?
        if !budget.hasRoom(for: rowBytes, inBatchOf: rows.count, bytes: bytes) {
            completed = take()
        }
        rows.append(row)
        bytes += rowBytes
        return completed
    }

    mutating func take() -> [Row]? {
        guard !rows.isEmpty else { return nil }
        let batch = rows
        rows.removeAll(keepingCapacity: true)
        bytes = 0
        return batch
    }
}
