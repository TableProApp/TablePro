import Foundation

public enum InfluxResponseDecoder {
    // MARK: - 3.x CSV

    /// `/api/v3/query_sql` and `/api/v3/query_influxql` with `format=csv`. CSV is the one 3.x format
    /// that keeps the column order of the statement; JSON returns objects and drops null columns.
    /// An empty cell reads as null, since the format has no other way to write one.
    public static func decodeV3CSV(_ text: String) -> InfluxResultTable {
        var records = InfluxCSV.records(text).filter { !$0.isEmpty }
        guard !records.isEmpty else { return .empty }
        let columns = records.removeFirst()
        let rows: [[String?]] = records.map { record in
            columns.indices.map { index in
                guard index < record.count, !record[index].isEmpty else { return nil }
                return record[index]
            }
        }
        let typeNames = columns.enumerated().map { index, column in
            InfluxTypeName.inferred(column: column, values: rows.map { $0[index] })
        }
        let normalized = rows.map { row in
            row.enumerated().map { index, value in
                typeNames[index] == InfluxTypeName.timestamp
                    ? value.map(InfluxTypeName.normalizedTimestamp)
                    : value
            }
        }
        return InfluxResultTable(columns: columns, typeNames: typeNames, rows: normalized)
    }

    // MARK: - InfluxQL over /query (1.x and the 2.x compatibility API)

    /// Flattens every series of every statement into one grid. A statement that groups by tag
    /// returns one series per tag set; the tags become leading columns, and when the series name
    /// varies (`SHOW FIELD KEYS` over several measurements) a `name` column comes first.
    public static func decodeV1JSON(_ data: Data) throws -> InfluxResultTable {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InfluxError.malformedResponse(String(bytes: data.prefix(200), encoding: .utf8) ?? "")
        }
        if let error = root["error"] as? String {
            throw InfluxError.query(error)
        }
        let results = root["results"] as? [[String: Any]] ?? []
        if let error = results.compactMap({ $0["error"] as? String }).first {
            throw InfluxError.query(error)
        }
        let series = results.flatMap { $0["series"] as? [[String: Any]] ?? [] }
        guard !series.isEmpty else { return .empty }

        let names = Set(series.compactMap { $0["name"] as? String })
        let includesName = names.count > 1
        var tagKeys: [String] = []
        var valueColumns: [String] = []
        for item in series {
            for key in (item["tags"] as? [String: Any] ?? [:]).keys.sorted() where !tagKeys.contains(key) {
                tagKeys.append(key)
            }
            for column in item["columns"] as? [String] ?? [] where !valueColumns.contains(column) {
                valueColumns.append(column)
            }
        }
        valueColumns.removeAll { tagKeys.contains($0) }
        let columns = (includesName ? ["name"] : []) + tagKeys + valueColumns

        var rows: [[String?]] = []
        var jsonTypes = [String?](repeating: nil, count: columns.count)
        for item in series {
            let seriesColumns = item["columns"] as? [String] ?? []
            let tags = item["tags"] as? [String: Any] ?? [:]
            for values in item["values"] as? [[Any]] ?? [] {
                var row = [String?](repeating: nil, count: columns.count)
                var offset = 0
                if includesName {
                    row[0] = item["name"] as? String
                    offset = 1
                }
                for (index, key) in tagKeys.enumerated() {
                    row[offset + index] = text(tags[key])
                }
                for (index, column) in seriesColumns.enumerated() where index < values.count {
                    guard let target = columns.firstIndex(of: column) else { continue }
                    row[target] = text(values[index])
                    if jsonTypes[target] == nil {
                        jsonTypes[target] = typeName(of: values[index])
                    }
                }
                rows.append(row)
            }
        }
        let typeNames = columns.enumerated().map { index, column -> String in
            if column == InfluxTypeName.timeColumn { return InfluxTypeName.timestamp }
            if tagKeys.contains(column) { return InfluxTypeName.tag }
            return jsonTypes[index] ?? InfluxTypeName.string
        }
        return InfluxResultTable(columns: columns, typeNames: typeNames, rows: rows)
    }

    // MARK: - Flux annotated CSV (2.x)

    /// Each Flux table arrives as its own block with its own header. The grid gets the union of
    /// the headers in first-seen order, without the empty annotation column and `result`.
    public static func decodeFluxCSV(_ text: String) throws -> InfluxResultTable {
        var columns: [String] = []
        var typeNames: [String] = []
        var rows: [[String?]] = []

        var datatypes: [String] = []
        var header: [String]?
        for record in InfluxCSV.records(text) {
            if record.isEmpty || record == [""] {
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
                if isFluxErrorHeader(record) { continue }
                for (index, column) in record.enumerated() where keepsFluxColumn(column, index: index) {
                    if !columns.contains(column) {
                        columns.append(column)
                        typeNames.append(fluxTypeName(index < datatypes.count ? datatypes[index] : ""))
                    }
                }
                continue
            }
            if isFluxErrorHeader(currentHeader) {
                throw InfluxError.query(record.count > 1 ? record[1] : "Flux error")
            }
            var row = [String?](repeating: nil, count: columns.count)
            for (index, column) in currentHeader.enumerated() where keepsFluxColumn(column, index: index) {
                guard index < record.count, let target = columns.firstIndex(of: column) else { continue }
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
        case "duration": return "duration"
        case "base64Binary": return "binary"
        default: return InfluxTypeName.string
        }
    }

    // MARK: - Errors

    /// The message out of an error body: `{"message": ...}` on 2.x, `{"error": ...}` on 1.x and some
    /// 3.x paths, plain text on others.
    public static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error", "data"] {
                if let message = object[key] as? String, !message.isEmpty { return message }
            }
        }
        return (String(bytes: data.prefix(2_000), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Values

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
                return String(bytes: data, encoding: .utf8) ?? ""
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
