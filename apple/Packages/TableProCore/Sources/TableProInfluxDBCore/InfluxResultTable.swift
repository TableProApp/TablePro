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
}

public enum InfluxTypeName {
    public static let timestamp = "timestamp"
    public static let tag = "tag"
    public static let float = "float"
    public static let integer = "integer"
    public static let unsigned = "unsigned"
    public static let string = "string"
    public static let boolean = "boolean"

    public static let timeColumn = "time"

    /// Names the text a column holds when the response carries no types (the 3.x CSV format):
    /// integer, float or boolean when every value reads as one, else string.
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

    /// 3.x returns `2024-10-27T03:33:20` for a UTC timestamp. Adding the zone makes it read the
    /// same as the 2.x value and parse as RFC 3339 when pasted back into a filter.
    static func normalizedTimestamp(_ value: String) -> String {
        guard value.count >= 19, value.dropFirst(10).first == "T" else { return value }
        let time = value.dropFirst(11)
        if time.contains("Z") || time.contains("+") || time.contains("-") { return value }
        return value + "Z"
    }
}
