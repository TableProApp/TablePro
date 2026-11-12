import Foundation
import TableProPluginKit

enum TableHealthRowStatus: Int, Sendable {
    case new
    case seen
    case ignored
    case resolved

    var title: String {
        switch self {
        case .new: return String(localized: "New")
        case .seen: return ""
        case .ignored: return String(localized: "Ignored")
        case .resolved: return String(localized: "Resolved")
        }
    }

    var exportValue: String? {
        switch self {
        case .new: return "new"
        case .seen: return nil
        case .ignored: return "ignored"
        case .resolved: return "resolved"
        }
    }
}

// One row of the findings or Resolved table, and of what Copy and Export write. The sort keys are stored and never
// optional: a Table column sorts only by a Comparable value.
struct TableHealthFindingRow: Identifiable, Sendable {
    let id: TableHealthFindingID
    // Nil for a resolved finding, which has no current detail or fix.
    let finding: TableHealthFinding?
    let checkTitle: String
    let checkOrder: Int
    let status: TableHealthRowStatus
    let firstSeen: Date?
    let lastSeen: Date?
    let statusRank: Int
    let tableSortKey: String
    let objectSortKey: String
    let sizeSortKey: Int64
    let detail: String
    let lastSeenSortKey: Date

    init(
        finding: TableHealthFinding,
        checkTitle: String,
        checkOrder: Int,
        status: TableHealthRowStatus,
        firstSeen: Date?,
        lastSeen: Date?
    ) {
        self.init(
            id: finding.id,
            finding: finding,
            checkTitle: checkTitle,
            checkOrder: checkOrder,
            status: status,
            firstSeen: firstSeen,
            lastSeen: lastSeen,
            detail: finding.detail
        )
    }

    init(resolved: TableHealthLedger.ResolvedFinding, checkTitle: String, checkOrder: Int) {
        self.init(
            id: resolved.id,
            finding: nil,
            checkTitle: checkTitle,
            checkOrder: checkOrder,
            status: .resolved,
            firstSeen: resolved.firstSeen,
            lastSeen: resolved.lastSeen,
            detail: ""
        )
    }

    private init(
        id: TableHealthFindingID,
        finding: TableHealthFinding?,
        checkTitle: String,
        checkOrder: Int,
        status: TableHealthRowStatus,
        firstSeen: Date?,
        lastSeen: Date?,
        detail: String
    ) {
        self.id = id
        self.finding = finding
        self.checkTitle = checkTitle
        self.checkOrder = checkOrder
        self.status = status
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.detail = detail
        statusRank = status.rawValue
        tableSortKey = Self.qualifiedTable(schema: id.schema, table: id.table) ?? ""
        objectSortKey = id.object ?? ""
        sizeSortKey = finding?.sizeBytes ?? -1
        lastSeenSortKey = lastSeen ?? .distantPast
    }

    var qualifiedTable: String? {
        Self.qualifiedTable(schema: id.schema, table: id.table)
    }

    func matches(_ filter: String) -> Bool {
        [checkTitle, tableSortKey, objectSortKey, detail].contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    private static func qualifiedTable(schema: String?, table: String?) -> String? {
        guard let table else { return nil }
        guard let schema else { return table }
        return "\(schema).\(table)"
    }
}

// The columns the screen shows, which Copy writes with the same titles and text.
enum TableHealthColumn: Sendable {
    case status
    case check
    case table
    case object
    case size
    case detail
    case lastSeen

    static let findings: [TableHealthColumn] = [.status, .check, .table, .object, .size, .detail]
    static let resolved: [TableHealthColumn] = [.check, .table, .object, .lastSeen]

    var title: String {
        switch self {
        case .status: return String(localized: "Status")
        case .check: return String(localized: "Check")
        case .table: return String(localized: "Table")
        case .object: return String(localized: "Object")
        case .size: return String(localized: "Size")
        case .detail: return String(localized: "Detail")
        case .lastSeen: return String(localized: "Last Seen")
        }
    }

    // "0 bytes", where the file style spells out "Zero kB" for an empty index.
    static func byteSize(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    func text(for row: TableHealthFindingRow) -> String {
        switch self {
        case .status: return row.status.title
        case .check: return row.checkTitle
        case .table: return row.tableSortKey
        case .object: return row.objectSortKey
        case .size: return row.finding?.sizeBytes.map(Self.byteSize) ?? ""
        case .detail: return row.detail
        case .lastSeen: return row.lastSeen.map(TableHealthFormatting.date) ?? ""
        }
    }
}

enum TableHealthTSV {
    static func text(_ rows: [TableHealthFindingRow], columns: [TableHealthColumn]) -> String {
        let header = columns.map(\.title).joined(separator: "\t")
        let lines = rows.map { row in
            columns.map { TableHealthFixScript.singleLine($0.text(for: row)) }.joined(separator: "\t")
        }
        return ([header] + lines).joined(separator: "\n")
    }
}

// Rows are taken when the export request is built, so a refresh while the dialog is open cannot change what it writes.
// Cells are machine formatted: POSIX numbers, UTC timestamps, null for a missing or non-finite value.
final class TableHealthExportDataSource: PluginExportDataSource {
    struct Column: Equatable, Sendable {
        let name: String
        let typeName: String
    }

    static let fixedColumns: [Column] = [
        Column(name: "database", typeName: "varchar"),
        Column(name: "check", typeName: "varchar"),
        Column(name: "schema", typeName: "varchar"),
        Column(name: "table", typeName: "varchar"),
        Column(name: "object", typeName: "varchar"),
        Column(name: "status", typeName: "varchar"),
        Column(name: "size_bytes", typeName: "bigint"),
        Column(name: "detail", typeName: "varchar"),
        Column(name: "first_seen", typeName: "timestamp"),
        Column(name: "last_seen", typeName: "timestamp"),
        Column(name: "fix_sql", typeName: "varchar"),
    ]

    let databaseTypeId = DataSourceExportRequest.dataFileTypeId
    let columns: [Column]
    let rows: [PluginRow]

    init(database: String, rows: [TableHealthFindingRow]) {
        let metricColumns = Self.metricColumns(in: rows)
        columns = Self.fixedColumns + metricColumns
        let metricIds = metricColumns.map(\.name)
        self.rows = rows.map { Self.cells(of: $0, database: database, metricIds: metricIds) }
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let header = PluginStreamHeader(
            columns: columns.map(\.name),
            columnTypeNames: columns.map(\.typeName),
            estimatedRowCount: rows.count
        )
        let rows = rows
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(header))
            if !rows.isEmpty {
                continuation.yield(.rows(rows))
            }
            continuation.finish()
        }
    }

    // Parquet types its columns from here, not from the stream header.
    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        columns.map { PluginColumnInfo(name: $0.name, dataType: $0.typeName) }
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        rows.count
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        ""
    }

    func execute(query: String) async throws -> PluginQueryResult {
        throw ExportError.exportFailed(String(localized: "Table Health findings cannot run queries."))
    }

    func quoteIdentifier(_ identifier: String) -> String {
        SQLEscaping.quoteIdentifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        SQLEscaping.escapeStringLiteral(value)
    }

    static func metricColumns(in rows: [TableHealthFindingRow]) -> [Column] {
        let ordered = rows.enumerated()
            .sorted { ($0.element.checkOrder, $0.offset) < ($1.element.checkOrder, $1.offset) }
            .map(\.element)
        var seen: Set<String> = []
        var columns: [Column] = []
        for row in ordered {
            for metric in row.finding?.metrics ?? [] where seen.insert(metric.id).inserted {
                columns.append(Column(name: metric.id, typeName: typeName(of: metric.value)))
            }
        }
        return columns
    }

    static func typeName(of value: TableHealthMetric.Value) -> String {
        switch value {
        case .count, .bytes: return "bigint"
        case .bigCount: return "decimal(20,0)"
        case .percent: return "double"
        case .date: return "timestamp"
        case .flag: return "boolean"
        case .text: return "varchar"
        }
    }

    static func cell(_ value: TableHealthMetric.Value) -> PluginCellValue {
        switch value {
        case .count(let count): return .text(String(count))
        case .bigCount(let count): return .text(String(count))
        case .bytes(let bytes): return .text(String(bytes))
        case .percent(let fraction): return fraction.isFinite ? .text(String(fraction)) : .null
        case .date(let date): return .text(timestamp(date))
        case .text(let text): return .text(text)
        case .flag(let flag): return .text(flag ? "true" : "false")
        }
    }

    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04ld-%02ld-%02ld %02ld:%02ld:%02ld",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    private static func cells(of row: TableHealthFindingRow, database: String, metricIds: [String]) -> PluginRow {
        let finding = row.finding
        let text: (String?) -> PluginCellValue = { $0.map(PluginCellValue.text) ?? .null }
        var cells: PluginRow = [
            .text(database),
            .text(row.checkTitle),
            text(row.id.schema),
            text(row.id.table),
            text(row.id.object),
            text(row.status.exportValue),
            text(finding?.sizeBytes.map { String($0) }),
            text(finding?.detail),
            text(row.firstSeen.map(timestamp)),
            text(row.lastSeen.map(timestamp)),
            text(finding?.fixSQL),
        ]
        for id in metricIds {
            cells.append(finding?.metric(id).map { cell($0.value) } ?? .null)
        }
        return cells
    }
}
