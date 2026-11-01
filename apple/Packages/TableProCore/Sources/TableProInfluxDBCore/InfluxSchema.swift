import Foundation

public struct InfluxColumn: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case time
        case tag
        case field
    }

    public let name: String
    public let typeName: String
    public let role: Role

    public init(name: String, typeName: String, role: Role) {
        self.name = name
        self.typeName = typeName
        self.role = role
    }

    public var isText: Bool {
        role == .tag || typeName == InfluxTypeName.string
    }
}

/// The catalog statements behind the sidebar, and the mapping of what they return into columns.
/// Columns come back with `time` first and the rest by name, the order InfluxQL's `SELECT *` uses.
public enum InfluxSchema {
    public static func measurementsStatement(generation: InfluxGeneration) -> (String, InfluxQueryLanguage) {
        switch generation {
        case .v3:
            return (
                "SELECT table_name FROM information_schema.tables WHERE table_schema = 'iox' ORDER BY table_name",
                .sql
            )
        case .v1, .v2:
            return ("SHOW MEASUREMENTS", .influxQL)
        }
    }

    public static func measurements(from table: InfluxResultTable, generation: InfluxGeneration) -> [String] {
        let column = generation == .v3 ? "table_name" : "name"
        return table.column(named: column).compactMap { $0 }
    }

    public static func v3ColumnsStatement(measurement: String) -> String {
        let literal = InfluxSelectBuilder.stringLiteral(measurement, language: .sql)
        return "SELECT column_name, data_type FROM information_schema.columns "
            + "WHERE table_schema = 'iox' AND table_name = \(literal)"
    }

    public static func v3Columns(from table: InfluxResultTable) -> [InfluxColumn] {
        let names = table.column(named: "column_name")
        let types = table.column(named: "data_type")
        let columns = zip(names, types).compactMap { name, arrowType -> InfluxColumn? in
            guard let name else { return nil }
            return column(name: name, arrowType: arrowType ?? "")
        }
        return ordered(columns)
    }

    public static func v1TagKeysStatement(measurement: String) -> String {
        "SHOW TAG KEYS FROM \(InfluxSelectBuilder.quoteIdentifier(measurement, language: .influxQL))"
    }

    public static func v1FieldKeysStatement(measurement: String) -> String {
        "SHOW FIELD KEYS FROM \(InfluxSelectBuilder.quoteIdentifier(measurement, language: .influxQL))"
    }

    public static func v1Columns(tagKeys: InfluxResultTable, fieldKeys: InfluxResultTable) -> [InfluxColumn] {
        var columns = [InfluxColumn(name: InfluxTypeName.timeColumn, typeName: InfluxTypeName.timestamp, role: .time)]
        for tag in tagKeys.column(named: "tagKey").compactMap({ $0 }) {
            columns.append(InfluxColumn(name: tag, typeName: InfluxTypeName.tag, role: .tag))
        }
        let names = fieldKeys.column(named: "fieldKey")
        let types = fieldKeys.column(named: "fieldType")
        for (name, type) in zip(names, types) {
            guard let name, !columns.contains(where: { $0.name == name }) else { continue }
            columns.append(InfluxColumn(name: name, typeName: type ?? InfluxTypeName.string, role: .field))
        }
        return ordered(columns)
    }

    static func column(name: String, arrowType: String) -> InfluxColumn {
        if arrowType.hasPrefix("Timestamp") {
            return InfluxColumn(name: name, typeName: InfluxTypeName.timestamp, role: .time)
        }
        if arrowType.hasPrefix("Dictionary") {
            return InfluxColumn(name: name, typeName: InfluxTypeName.tag, role: .tag)
        }
        let typeName: String
        switch arrowType {
        case "Float64", "Float32": typeName = InfluxTypeName.float
        case "Int64", "Int32": typeName = InfluxTypeName.integer
        case "UInt64", "UInt32": typeName = InfluxTypeName.unsigned
        case "Boolean": typeName = InfluxTypeName.boolean
        default: typeName = InfluxTypeName.string
        }
        return InfluxColumn(name: name, typeName: typeName, role: .field)
    }

    static func ordered(_ columns: [InfluxColumn]) -> [InfluxColumn] {
        let time = columns.filter { $0.name == InfluxTypeName.timeColumn }
        let rest = columns.filter { $0.name != InfluxTypeName.timeColumn }
            .sorted { $0.name < $1.name }
        return time + rest
    }
}
