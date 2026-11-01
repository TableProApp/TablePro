import Foundation

public struct InfluxColumn: Sendable, Equatable, Hashable {
    public enum Role: Sendable, Equatable, Hashable {
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

    public var kind: InfluxColumnKind {
        switch role {
        case .time: return .time
        case .tag: return .tag
        case .field:
            switch typeName {
            case InfluxTypeName.float, InfluxTypeName.integer, InfluxTypeName.unsigned: return .number
            case InfluxTypeName.boolean: return .boolean
            default: return .text
            }
        }
    }
}

// Columns come back with `time` first and the rest by name, the order InfluxQL's `SELECT *` uses.
public enum InfluxSchema {
    // 2.x lists a mapping that is not its database's default only with `ON "db"."rp"`.
    public static func measurementsStatement(generation: InfluxGeneration, target: InfluxQLTarget? = nil) -> InfluxStatement {
        switch generation {
        case .v3:
            return InfluxStatement(
                language: .sql,
                text: "SELECT table_name FROM information_schema.tables WHERE table_schema = 'iox' ORDER BY table_name"
            )
        case .v2:
            guard let target, let policy = target.retentionPolicy, !policy.isEmpty else {
                return InfluxStatement(language: .influxQL, text: "SHOW MEASUREMENTS")
            }
            return InfluxStatement(
                language: .influxQL,
                text: "SHOW MEASUREMENTS ON \(quoted(target.database)).\(quoted(policy))"
            )
        }
    }

    public static func measurements(from table: InfluxResultTable, generation: InfluxGeneration) -> [String] {
        table.column(named: generation == .v3 ? "table_name" : "name").compactMap { $0 }
    }

    public static func v3ColumnsStatement(measurement: String) -> InfluxStatement {
        let literal = InfluxGridQuery.stringLiteral(measurement, language: .sql)
        return InfluxStatement(
            language: .sql,
            text: "SELECT column_name, data_type FROM information_schema.columns "
                + "WHERE table_schema = 'iox' AND table_name = \(literal)"
        )
    }

    public static func v3Columns(from table: InfluxResultTable) -> [InfluxColumn] {
        let columns = zip(table.column(named: "column_name"), table.column(named: "data_type"))
            .compactMap { name, arrowType -> InfluxColumn? in
                guard let name else { return nil }
                return column(name: name, arrowType: arrowType ?? "")
            }
        return ordered(columns)
    }

    // 2.x answers `SHOW TAG KEYS` only for a database with a default retention policy; for another mapping the tags
    // are read off one point's columns instead.
    public static func influxQLTagKeysStatement(measurement: String, target: InfluxQLTarget? = nil) -> InfluxStatement {
        let source = qualified(measurement, target: target)
        if let target, !target.isDefault {
            return InfluxStatement(language: .influxQL, text: "SELECT * FROM \(source) LIMIT 1")
        }
        return InfluxStatement(language: .influxQL, text: "SHOW TAG KEYS FROM \(source)")
    }

    public static func influxQLFieldKeysStatement(measurement: String, target: InfluxQLTarget? = nil) -> InfluxStatement {
        InfluxStatement(language: .influxQL, text: "SHOW FIELD KEYS FROM \(qualified(measurement, target: target))")
    }

    private static func qualified(_ measurement: String, target: InfluxQLTarget?) -> String {
        guard let policy = target?.retentionPolicy, !policy.isEmpty else { return quoted(measurement) }
        return quoted(policy) + "." + quoted(measurement)
    }

    private static func quoted(_ name: String) -> String {
        InfluxGridQuery.quoteIdentifier(name, language: .influxQL)
    }

    // `tagKeys` is the answer to `influxQLTagKeysStatement`: `SHOW TAG KEYS` rows, or one point whose columns hold
    // every tag and field.
    public static func influxQLColumns(tagKeys: InfluxResultTable, fieldKeys: InfluxResultTable) -> [InfluxColumn] {
        let fieldNames = Set(fieldKeys.column(named: "fieldKey").compactMap { $0 })
        let tags = tagKeys.columns == ["tagKey"]
            ? tagKeys.column(named: "tagKey").compactMap { $0 }
            : tagKeys.columns.filter { $0 != InfluxTypeName.timeColumn && !fieldNames.contains($0) }
        var columns = [InfluxColumn(name: InfluxTypeName.timeColumn, typeName: InfluxTypeName.timestamp, role: .time)]
        var names: Set<String> = [InfluxTypeName.timeColumn]
        for tag in tags where names.insert(tag).inserted {
            columns.append(InfluxColumn(name: tag, typeName: InfluxTypeName.tag, role: .tag))
        }
        for (name, type) in zip(fieldKeys.column(named: "fieldKey"), fieldKeys.column(named: "fieldType")) {
            guard let name, names.insert(name).inserted else { continue }
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
        let rest = columns.filter { $0.name != InfluxTypeName.timeColumn }.sorted { $0.name < $1.name }
        return time + rest
    }
}

public enum InfluxConnectionFieldID {
    public static let token = "influxToken"
    public static let organization = "influxOrg"
    public static let skipTLSVerify = "influxSkipTLSVerify"
}

// Shared by the plugin and the app's built-in metadata, which the editor reads before the plugin loads.
public enum InfluxCompletions {
    public static let entries: [(label: String, insertText: String)] = [
        ("SHOW MEASUREMENTS", "SHOW MEASUREMENTS"),
        ("SHOW TAG KEYS", "SHOW TAG KEYS FROM \"measurement\""),
        ("SHOW FIELD KEYS", "SHOW FIELD KEYS FROM \"measurement\""),
        ("SQL: last hour", "SELECT * FROM \"measurement\" WHERE time >= now() - INTERVAL '1 hour' ORDER BY time DESC"),
        (
            "SQL: 5 minute averages",
            """
            SELECT date_bin(INTERVAL '5 minutes', time) AS bucket, avg("field")
            FROM "measurement"
            WHERE time >= now() - INTERVAL '1 hour'
            GROUP BY bucket
            ORDER BY bucket
            """
        ),
        (
            "InfluxQL: 5 minute averages",
            "SELECT MEAN(\"field\") FROM \"measurement\" WHERE time > now() - 1h GROUP BY time(5m)"
        ),
        (
            "Flux: last hour",
            """
            from(bucket: "bucket")
              |> range(start: -1h)
              |> filter(fn: (r) => r._measurement == "measurement")
              |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
            """
        ),
    ]

    public static let columnTypesByCategory: [String: [String]] = [
        "Time": [InfluxTypeName.timestamp],
        "Tag": [InfluxTypeName.tag],
        "Field": [
            InfluxTypeName.float, InfluxTypeName.integer, InfluxTypeName.unsigned,
            InfluxTypeName.string, InfluxTypeName.boolean,
        ],
    ]
}
