import Foundation

public enum InfluxResponseDecoder {
    // 3.x CSV keeps the statement's column order; its JSON drops null columns. CSV has no null, so an empty cell is one.
    public static func decodeV3CSV(_ data: Data) -> InfluxResultTable {
        var records = InfluxCSV.records(data)[...]
        guard let columns = records.popFirst() else { return .empty }
        let rows: [[String?]] = records.map { record in
            columns.indices.map { index in
                guard index < record.count, !record[index].isEmpty else { return nil }
                return record[index]
            }
        }
        let typeNames = columns.indices.map { index in
            InfluxTypeName.inferred(column: columns[index], values: rows.map { $0[index] })
        }
        let timestampColumns = typeNames.indices.filter { typeNames[$0] == InfluxTypeName.timestamp }
        let normalized = timestampColumns.isEmpty ? rows : rows.map { row in
            var row = row
            for index in timestampColumns {
                row[index] = row[index].map(InfluxTypeName.normalizedTimestamp)
            }
            return row
        }
        return InfluxResultTable(columns: columns, typeNames: typeNames, rows: normalized)
    }

    // InfluxQL over `/query` (1.x and the 2.x compatibility API). Every series of every statement lands in one grid: a
    // GROUP BY tag set becomes leading tag columns, and a `name` column comes first when the series name varies.
    public static func decodeV1JSON(_ data: Data) throws -> InfluxResultTable {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InfluxError.malformedResponse(preview(of: data))
        }
        if let error = root["error"] as? String {
            throw InfluxError.query(error)
        }
        let results = root["results"] as? [[String: Any]] ?? []
        if let error = results.lazy.compactMap({ $0["error"] as? String }).first {
            throw InfluxError.query(error)
        }
        let series = results.flatMap { $0["series"] as? [[String: Any]] ?? [] }
        guard !series.isEmpty else { return .empty }

        let includesName = Set(series.compactMap { $0["name"] as? String }).count > 1
        var tagKeys: [String] = []
        var valueColumns: [String] = []
        var seen: Set<String> = []
        for item in series {
            for key in (item["tags"] as? [String: Any] ?? [:]).keys.sorted() where seen.insert("t:" + key).inserted {
                tagKeys.append(key)
            }
        }
        let tagSet = Set(tagKeys)
        for item in series {
            for column in item["columns"] as? [String] ?? [] where !tagSet.contains(column) {
                if seen.insert("v:" + column).inserted { valueColumns.append(column) }
            }
        }
        // `SHOW MEASUREMENTS; SHOW DATABASES` names both series and both value columns `name`.
        let taken = tagSet.union(valueColumns)
        let seriesColumn = ["name", "series"].first { !taken.contains($0) } ?? "series name"
        let columns = (includesName ? [seriesColumn] : []) + tagKeys + valueColumns
        let offset = includesName ? 1 : 0
        let position = Dictionary(
            (tagKeys + valueColumns).enumerated().map { ($1, $0 + offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let tagRange = offset ..< offset + tagKeys.count

        var rows: [[String?]] = []
        var jsonTypes = [String?](repeating: nil, count: columns.count)
        for item in series {
            let targets = (item["columns"] as? [String] ?? []).map { position[$0] }
            let tags = item["tags"] as? [String: Any] ?? [:]
            let tagValues = tagKeys.map { text(tags[$0]) }
            for values in item["values"] as? [[Any]] ?? [] {
                var row = [String?](repeating: nil, count: columns.count)
                if includesName { row[0] = item["name"] as? String }
                for (index, value) in tagValues.enumerated() {
                    row[offset + index] = value
                }
                for (index, target) in targets.enumerated() where index < values.count {
                    guard let target else { continue }
                    row[target] = text(values[index])
                    if jsonTypes[target] == nil { jsonTypes[target] = typeName(of: values[index]) }
                }
                rows.append(row)
            }
        }
        let typeNames = columns.indices.map { index -> String in
            if columns[index] == InfluxTypeName.timeColumn { return InfluxTypeName.timestamp }
            if tagRange.contains(index) { return InfluxTypeName.tag }
            return jsonTypes[index] ?? InfluxTypeName.string
        }
        return InfluxResultTable(columns: columns, typeNames: typeNames, rows: rows)
    }

    // Flux annotated CSV: each table brings its own header. The grid gets the union of headers in first-seen order,
    // without the empty annotation column and `result`.
    public static func decodeFluxCSV(_ data: Data) throws -> InfluxResultTable {
        var columns: [String] = []
        var typeNames: [String] = []
        var position: [String: Int] = [:]
        var rows: [[String?]] = []

        var datatypes: [String] = []
        var header: [String]?
        var targets: [Int?] = []
        for record in InfluxCSV.records(data) {
            if record == [""] {
                datatypes = []
                header = nil
                continue
            }
            if let first = record.first, first.hasPrefix("#") {
                if first == "#datatype" { datatypes = record }
                continue
            }
            guard let currentHeader = header else {
                header = record
                if isFluxErrorHeader(record) {
                    targets = []
                    continue
                }
                targets = record.indices.map { index -> Int? in
                    let column = record[index]
                    guard keepsFluxColumn(column, index: index) else { return nil }
                    if let existing = position[column] { return existing }
                    position[column] = columns.count
                    columns.append(column)
                    typeNames.append(fluxTypeName(index < datatypes.count ? datatypes[index] : ""))
                    return columns.count - 1
                }
                continue
            }
            if isFluxErrorHeader(currentHeader) {
                throw InfluxError.query(record.count > 1 ? record[1] : "Flux error")
            }
            var row = [String?](repeating: nil, count: columns.count)
            for (index, target) in targets.enumerated() where index < record.count {
                guard let target else { continue }
                row[target] = record[index].isEmpty ? nil : record[index]
            }
            rows.append(row)
        }
        for index in rows.indices where rows[index].count < columns.count {
            rows[index] += [String?](repeating: nil, count: columns.count - rows[index].count)
        }
        return InfluxResultTable(columns: columns, typeNames: typeNames, rows: rows)
    }

    private static func isFluxErrorHeader(_ header: [String]) -> Bool {
        header.dropFirst().elementsEqual(["error", "reference"])
    }

    private static func keepsFluxColumn(_ column: String, index: Int) -> Bool {
        !(index == 0 && column.isEmpty) && column != "result"
    }

    static func fluxTypeName(_ annotation: String) -> String {
        switch annotation {
        case "dateTime:RFC3339", "dateTime:RFC3339Nano": return InfluxTypeName.timestamp
        case "long": return InfluxTypeName.integer
        case "unsignedLong": return InfluxTypeName.unsigned
        case "double": return InfluxTypeName.float
        case "boolean": return InfluxTypeName.boolean
        case "duration": return InfluxTypeName.duration
        case "base64Binary": return InfluxTypeName.binary
        default: return InfluxTypeName.string
        }
    }

    // `{"message": ...}` on 2.x, `{"error": ...}` on 1.x and some 3.x paths, plain text on others.
    public static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error", "data"] {
                if let message = object[key] as? String, !message.isEmpty { return message }
            }
        }
        let text = String(decoding: data.prefix(2_000), as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func preview(of data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }

    static func text(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull:
            return nil
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case let other?:
            if JSONSerialization.isValidJSONObject(other),
               let data = try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys]) {
                return String(bytes: data, encoding: .utf8)
            }
            return "\(other)"
        }
    }

    static func typeName(of value: Any) -> String? {
        switch value {
        case is NSNull:
            return nil
        case is String:
            return InfluxTypeName.string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return InfluxTypeName.boolean }
            return CFNumberIsFloatType(number) ? InfluxTypeName.float : InfluxTypeName.integer
        default:
            return InfluxTypeName.string
        }
    }
}
