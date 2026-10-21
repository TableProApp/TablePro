import Foundation

public struct CLIResultSet: Sendable, Equatable {
    public let columns: [String]
    public let rows: [[JsonValue]]

    public init(columns: [String], rows: [[JsonValue]]) {
        self.columns = columns
        self.rows = rows
    }
}

public enum CLIRowWriter {
    // JSON nests one array per result set so the output stays one document.
    public static func write(_ sets: [CLIResultSet], as format: CLIOutputFormat, to output: inout some TextOutputStream) {
        let printable = sets.filter { !$0.columns.isEmpty }
        guard printable.count > 1 else {
            if let only = printable.first {
                write(only, as: format, to: &output)
            }
            return
        }
        switch format {
        case .json:
            output.write("[\n")
            for (index, set) in printable.enumerated() {
                writeJsonArray(set, indent: "  ", last: index == printable.count - 1, to: &output)
            }
            output.write("]\n")
        case .jsonl:
            for set in printable {
                write(set, as: format, to: &output)
            }
        case .csv, .tsv, .table:
            for (index, set) in printable.enumerated() {
                if index > 0 {
                    output.write("\n")
                }
                write(set, as: format, to: &output)
            }
        }
    }

    public static func write(_ set: CLIResultSet, as format: CLIOutputFormat, to output: inout some TextOutputStream) {
        guard !set.columns.isEmpty else { return }
        switch format {
        case .csv:
            writeDelimited(set, separator: ",", to: &output, field: csvField)
        case .tsv:
            writeDelimited(set, separator: "\t", to: &output, field: tsvField)
        case .json:
            writeJsonArray(set, indent: "", last: true, to: &output)
        case .jsonl:
            let keys = uniqueKeys(set.columns)
            for row in set.rows {
                output.write(jsonObject(keys: keys, row: row))
                output.write("\n")
            }
        case .table:
            writeTable(set, to: &output)
        }
    }

    private static func writeDelimited(
        _ set: CLIResultSet,
        separator: String,
        to output: inout some TextOutputStream,
        field: (JsonValue) -> String
    ) {
        output.write(set.columns.map { field(.string($0)) }.joined(separator: separator))
        output.write("\n")
        for row in set.rows {
            output.write(cells(row, count: set.columns.count).map(field).joined(separator: separator))
            output.write("\n")
        }
    }

    // NULL is an empty field and an empty string is "", so the two stay apart.
    static func csvField(_ value: JsonValue) -> String {
        guard let text = text(of: value) else { return "" }
        let needsQuotes = text.isEmpty || text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func tsvField(_ value: JsonValue) -> String {
        guard let text = text(of: value) else { return "" }
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\t": escaped += "\\t"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private static func writeJsonArray(
        _ set: CLIResultSet,
        indent: String,
        last: Bool,
        to output: inout some TextOutputStream
    ) {
        let close = last ? "]\n" : "],\n"
        guard !set.rows.isEmpty else {
            output.write(indent + "[" + close)
            return
        }
        let keys = uniqueKeys(set.columns)
        output.write(indent + "[\n")
        for (index, row) in set.rows.enumerated() {
            output.write(indent + "  ")
            output.write(jsonObject(keys: keys, row: row))
            output.write(index == set.rows.count - 1 ? "\n" : ",\n")
        }
        output.write(indent + close)
    }

    static func jsonObject(keys: [String], row: [JsonValue]) -> String {
        let values = cells(row, count: keys.count)
        let members = zip(keys, values).map { key, value in jsonString(key) + ":" + jsonLiteral(value) }
        return "{" + members.joined(separator: ",") + "}"
    }

    // `SELECT 1 AS a, 2 AS a` would otherwise give an object whose second key replaces the first.
    static func uniqueKeys(_ columns: [String]) -> [String] {
        var taken = Set<String>()
        return columns.map { column in
            var candidate = column
            var suffix = 2
            while taken.contains(candidate) {
                candidate = "\(column)_\(suffix)"
                suffix += 1
            }
            taken.insert(candidate)
            return candidate
        }
    }

    private static func jsonLiteral(_ value: JsonValue) -> String {
        switch value {
        case .null:
            return "null"
        case .string(let text):
            return jsonString(text)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .int(let number):
            return String(number)
        case .double, .array, .object:
            return value.jsonString()
        }
    }

    static func jsonString(_ text: String) -> String {
        var escaped = "\""
        escaped.reserveCapacity(text.utf8.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        escaped += "\""
        return escaped
    }

    static let nullMarker = "NULL"

    private static func writeTable(_ set: CLIResultSet, to output: inout some TextOutputStream) {
        let header = set.columns.map(tableCell)
        let body = set.rows.map { cells($0, count: set.columns.count).map(tableCellValue) }
        var widths = header.map(\.count)
        for row in body {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }
        output.write(tableLine(header, widths: widths))
        output.write(widths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-"))
        output.write("\n")
        for row in body {
            output.write(tableLine(row, widths: widths))
        }
    }

    private static func tableLine(_ cells: [String], widths: [Int]) -> String {
        let padded = cells.enumerated().map { index, cell in
            index == cells.count - 1 ? cell : cell + String(repeating: " ", count: widths[index] - cell.count)
        }
        return padded.joined(separator: " | ") + "\n"
    }

    private static func tableCellValue(_ value: JsonValue) -> String {
        guard let text = text(of: value) else { return nullMarker }
        return tableCell(text)
    }

    // The table goes to a terminal, so a stored escape sequence is shown, never run.
    static func tableCell(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isControl) else { return text }
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\t": escaped += "\\t"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            default:
                if isControl(scalar) {
                    escaped += String(format: "\\x%02X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    private static func cells(_ row: [JsonValue], count: Int) -> [JsonValue] {
        guard row.count != count else { return row }
        if row.count > count {
            return Array(row.prefix(count))
        }
        return row + Array(repeating: JsonValue.null, count: count - row.count)
    }

    private static func text(of value: JsonValue) -> String? {
        switch value {
        case .null:
            return nil
        case .string(let text):
            return text
        case .bool(let flag):
            return flag ? "true" : "false"
        case .int(let number):
            return String(number)
        case .double, .array, .object:
            return value.jsonString()
        }
    }
}
