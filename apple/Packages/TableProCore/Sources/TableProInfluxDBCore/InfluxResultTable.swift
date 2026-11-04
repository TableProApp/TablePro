import Foundation

public struct InfluxResultTable: Sendable, Equatable {
    public var columns: [String]
    public var typeNames: [String]
    public var rows: [[String?]]

    public init(columns: [String], typeNames: [String], rows: [[String?]]) {
        self.columns = columns
        self.typeNames = typeNames
        self.rows = rows
    }

    public static let empty = InfluxResultTable(columns: [], typeNames: [], rows: [])

    public func column(named name: String) -> [String?] {
        guard let index = columns.firstIndex(of: name) else { return [] }
        return rows.map { index < $0.count ? $0[index] : nil }
    }

    // A grid query's columns typed from the measurement's schema rather than from the values on one page.
    public func typed(by schema: [InfluxColumn]) -> InfluxResultTable {
        let byName = Dictionary(schema.map { ($0.name, $0.typeName) }, uniquingKeysWith: { first, _ in first })
        var table = self
        table.typeNames = zip(columns, typeNames).map { column, inferred in byName[column] ?? inferred }
        return table
    }
}

public enum InfluxTypeName {
    public static let timestamp = "timestamp"
    public static let tag = "tag"
    public static let float = "float"
    public static let integer = "integer"
    public static let unsigned = "unsigned"
    public static let string = "string"
    public static let boolean = "boolean"
    public static let duration = "duration"
    public static let binary = "binary"

    public static let timeColumn = "time"

    // The SQL spelling the app classifies a column by, so a tag reads as text and a field as its number kind.
    public static func classificationName(for typeName: String) -> String {
        switch typeName {
        case timestamp: return "TIMESTAMP"
        case float: return "DOUBLE"
        case integer: return "BIGINT"
        case unsigned: return "UBIGINT"
        case boolean: return "BOOLEAN"
        case binary: return "BLOB"
        default: return "TEXT"
        }
    }

    // The 3.x CSV carries no types, so a user query's columns are named by what every value parses as.
    static func inferred(column: String, values: [String?]) -> String {
        if column == timeColumn { return timestamp }
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return string }
        if present.allSatisfy({ Int64($0) != nil }) { return integer }
        if present.allSatisfy({ UInt64($0) != nil }) { return unsigned }
        if present.allSatisfy({ Double($0) != nil }) { return float }
        if present.allSatisfy({ $0 == "true" || $0 == "false" }) { return boolean }
        return string
    }

    // 3.x writes a UTC timestamp without a zone; the `Z` makes it match 2.x and parse back as RFC 3339 in a filter.
    static func normalizedTimestamp(_ value: String) -> String {
        guard value.count >= 19, value.dropFirst(10).first == "T" else { return value }
        let time = value.dropFirst(11)
        if time.contains("Z") || time.contains("+") || time.contains("-") { return value }
        return value + "Z"
    }
}
