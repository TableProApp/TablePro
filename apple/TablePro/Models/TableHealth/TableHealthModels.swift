import Foundation

// The raw values are stored in the history ledger: renaming one orphans every finding saved under it.
enum TableHealthCheckKind: String, CaseIterable, Codable, Sendable {
    case bloat
    case unusedIndex
    case redundantIndex
    case missingPrimaryKey
    case unindexedForeignKey
    case invalidIndex
    case nearLimit
    case transactionIdAge
    case staleStatistics
    case reclaimableSpace

    var title: String {
        switch self {
        case .bloat: return String(localized: "Bloated Tables")
        case .unusedIndex: return String(localized: "Unused Indexes")
        case .redundantIndex: return String(localized: "Redundant Indexes")
        case .missingPrimaryKey: return String(localized: "Tables Without a Primary Key")
        case .unindexedForeignKey: return String(localized: "Foreign Keys Without an Index")
        case .invalidIndex: return String(localized: "Invalid Indexes")
        case .nearLimit: return String(localized: "Counters Near Their Limit")
        case .transactionIdAge: return String(localized: "Transaction ID Wraparound")
        case .staleStatistics: return String(localized: "Stale Statistics")
        case .reclaimableSpace: return String(localized: "Reclaimable Space")
        }
    }

    // Symbols from SF Symbols 2 or earlier, so each draws on macOS 13.
    var systemImage: String {
        switch self {
        case .bloat: return "trash"
        case .unusedIndex: return "list.bullet.indent"
        case .redundantIndex: return "square.on.square"
        case .missingPrimaryKey: return "key"
        case .unindexedForeignKey: return "link"
        case .invalidIndex: return "xmark.square"
        case .nearLimit: return "arrow.up.to.line"
        case .transactionIdAge: return "hourglass"
        case .staleStatistics: return "chart.bar.xaxis"
        case .reclaimableSpace: return "internaldrive"
        }
    }
}

struct TableHealthCheck: Hashable, Sendable {
    let kind: TableHealthCheckKind
    let title: String
    let systemImage: String
    let summary: String

    init(kind: TableHealthCheckKind, title: String? = nil, systemImage: String? = nil, summary: String) {
        self.kind = kind
        self.title = title ?? kind.title
        self.systemImage = systemImage ?? kind.systemImage
        self.summary = summary
    }
}

struct TableHealthFindingID: Hashable, Sendable {
    let kind: TableHealthCheckKind
    let schema: String?
    let table: String?
    let object: String?

    init(kind: TableHealthCheckKind, schema: String?, table: String?, object: String?) {
        self.kind = kind
        self.schema = schema
        self.table = table
        self.object = object
    }

    init?(storageKey: String) {
        guard let parts = TableHealthStorageKey(encoded: storageKey) else { return nil }
        self.init(parts: parts)
    }

    init?(parts: TableHealthStorageKey) {
        guard let kind = TableHealthCheckKind(rawValue: parts.kindName) else { return nil }
        self.init(kind: kind, schema: parts.schema, table: parts.table, object: parts.object)
    }

    var storageParts: TableHealthStorageKey {
        TableHealthStorageKey(kindName: kind.rawValue, schema: schema, table: table, object: object)
    }

    var storageKey: String { storageParts.encoded }
}

// A finding id as stored, its kind kept as text so a kind this build does not know still parses. Only ASCII letters,
// digits and `_` stay literal: what CharacterSet.alphanumerics holds grows with each Unicode version, and a key that
// encoded differently after an OS update would read as a new finding.
struct TableHealthStorageKey: Hashable, Sendable {
    var kindName: String
    var schema: String?
    var table: String?
    var object: String?

    init(kindName: String, schema: String?, table: String?, object: String?) {
        self.kindName = kindName
        self.schema = schema
        self.table = table
        self.object = object
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4,
              parts[0] != "-",
              let kindName = parts[0].removingPercentEncoding,
              let schema = Self.decode(parts[1]),
              let table = Self.decode(parts[2]),
              let object = Self.decode(parts[3])
        else { return nil }
        self.init(kindName: kindName, schema: schema, table: table, object: object)
    }

    var encoded: String {
        [kindName, schema, table, object].map(Self.encode).joined(separator: ".")
    }

    private static func encode(_ part: String?) -> String {
        guard let part else { return "-" }
        var encoded = ""
        for byte in part.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"):
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    // Nil for text that is not a part, .some(nil) for an absent one.
    private static func decode(_ part: String) -> String?? {
        if part == "-" { return .some(nil) }
        guard let decoded = part.removingPercentEncoding else { return nil }
        return .some(decoded)
    }
}

struct TableHealthMetric: Hashable, Sendable {
    enum Value: Hashable, Sendable {
        case count(Int64)
        // AUTO_INCREMENT on a bigint unsigned column passes Int64.max.
        case bigCount(UInt64)
        case bytes(Int64)
        // A fraction: 0.25 reads as 25%.
        case percent(Double)
        case date(Date)
        case text(String)
        case flag(Bool)
    }

    // Stable snake_case: the export column id.
    let id: String
    let label: String
    let value: Value

    var formattedValue: String { value.formatted }

    static func estimatedRows(_ rows: Int64) -> TableHealthMetric {
        TableHealthMetric(id: "estimated_rows", label: String(localized: "Estimated Rows"), value: .count(rows))
    }
}

extension TableHealthMetric.Value {
    var formatted: String {
        switch self {
        case .count(let value): return value.formatted()
        case .bigCount(let value): return value.formatted()
        case .bytes(let value): return ByteSizeFormatting.string(bytes: value)
        case .percent(let value):
            guard value.isFinite else { return "" }
            return value.formatted(.percent.precision(.fractionLength(0...1)))
        case .date(let value): return TableHealthFormatting.date(value)
        case .text(let value): return value
        case .flag(let value): return value ? String(localized: "Yes") : String(localized: "No")
        }
    }
}

// Equal and hashed by id alone, so a finding whose numbers moved between runs is still the same finding.
struct TableHealthFinding: Identifiable, Hashable, Sendable {
    let id: TableHealthFindingID
    // Nil where the engine has no schema level below the database.
    let schema: String?
    // Nil only for a sequence no column uses.
    let table: String?
    let objectName: String?
    let detail: String
    // On-disk size of what the fix acts on: the index for an index check, the table otherwise.
    let sizeBytes: Int64?
    let metrics: [TableHealthMetric]
    let fixSQL: String?

    init(
        kind: TableHealthCheckKind,
        schema: String?,
        table: String?,
        objectName: String?,
        detail: String,
        sizeBytes: Int64? = nil,
        metrics: [TableHealthMetric] = [],
        fixSQL: String?
    ) {
        self.id = TableHealthFindingID(kind: kind, schema: schema, table: table, object: objectName)
        self.schema = schema
        self.table = table
        self.objectName = objectName
        self.detail = detail
        self.sizeBytes = sizeBytes
        self.metrics = metrics
        self.fixSQL = fixSQL
    }

    var kind: TableHealthCheckKind { id.kind }

    var qualifiedTable: String? {
        guard let table else { return nil }
        guard let schema else { return table }
        return "\(schema).\(table)"
    }

    var qualifiedName: String {
        [schema, table, objectName].compactMap { $0 }.joined(separator: ".")
    }

    func metric(_ id: String) -> TableHealthMetric? {
        metrics.first { $0.id == id }
    }

    static func == (lhs: TableHealthFinding, rhs: TableHealthFinding) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct TableHealthCheckResult: Identifiable, Sendable {
    enum Outcome: Equatable, Sendable {
        case completed
        case failed(String)
        // The server records nothing the check could read, so it did not run.
        case skipped(String)
    }

    let check: TableHealthCheck
    var findings: [TableHealthFinding]
    var outcome: Outcome
    var note: String?

    var kind: TableHealthCheckKind { check.kind }

    var id: TableHealthCheckKind { check.kind }
}

struct TableHealthReport: Sendable {
    let database: String
    var checks: [TableHealthCheckResult]
    var notes: [String] = []
    let generatedAt: Date

    var findingCount: Int {
        checks.reduce(0) { $0 + $1.findings.count }
    }

    var findings: [TableHealthFinding] {
        checks.flatMap(\.findings)
    }

    func result(for kind: TableHealthCheckKind) -> TableHealthCheckResult? {
        checks.first { $0.kind == kind }
    }

    func finding(id: TableHealthFinding.ID) -> TableHealthFinding? {
        result(for: id.kind)?.findings.first { $0.id == id }
    }
}

struct TableHealthStatistics: Equatable, Sendable {
    // PostgreSQL's server_version_num; for MySQL and MariaDB, major * 10000 + minor * 100 + patch.
    var serverVersion: Int?
    var isMariaDB = false
    var isStandby = false
    var notes: [String] = []
    var skippedChecks: [TableHealthCheckKind: String] = [:]
}

enum TableHealthFormatting {
    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
