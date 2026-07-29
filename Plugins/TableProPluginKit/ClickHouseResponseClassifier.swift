import Foundation

public enum ClickHouseResponseClassifier {
    public static let requestedFormat = "TabSeparatedWithNamesAndTypes"

    public struct Outcome: Equatable, Sendable {
        public let columns: [String]
        public let columnTypeNames: [String]
        public let rows: [[PluginCellValue]]
        public let affectedRows: Int
        public let isTruncated: Bool
    }

    private static let formatHeaderName = "x-clickhouse-format"
    private static let summaryHeaderName = "x-clickhouse-summary"
    private static let rawBodyByteCap = 1_048_576

    public static func transportQueryItems(supportsWriteExceptionSetting: Bool) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "default_format", value: requestedFormat),
            URLQueryItem(name: "wait_end_of_query", value: "1")
        ]
        if supportsWriteExceptionSetting {
            items.append(URLQueryItem(name: "http_write_exception_in_output_format", value: "0"))
        }
        return items
    }

    public static func classify(
        headers: [String: String],
        body: Data,
        rowLimit: Int = PluginRowLimits.emergencyMax
    ) -> Outcome {
        guard !body.isEmpty else {
            return noResultSetOutcome(headers: headers)
        }
        if let format = headerValue(headers, named: formatHeaderName), format != requestedFormat {
            return rawOutcome(body: body)
        }
        let text = decodedText(body)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return noResultSetOutcome(headers: headers)
        }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else {
            return rawOutcome(body: body)
        }
        return tabSeparatedOutcome(lines: lines, rowLimit: rowLimit)
    }

    public static func affectedRowsFromSummary(headers: [String: String]) -> Int {
        guard let summary = headerValue(headers, named: summaryHeaderName),
              let data = summary.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }
        return intValue(object["written_rows"]) ?? 0
    }

    public static func unescapeTsvField(_ field: String) -> String {
        var result = ""
        result.reserveCapacity((field as NSString).length)
        var iterator = field.makeIterator()

        while let char = iterator.next() {
            if char == "\\" {
                if let next = iterator.next() {
                    switch next {
                    case "\\": result.append("\\")
                    case "t": result.append("\t")
                    case "n": result.append("\n")
                    default:
                        result.append("\\")
                        result.append(next)
                    }
                } else {
                    result.append("\\")
                }
            } else {
                result.append(char)
            }
        }

        return result
    }

    private static func noResultSetOutcome(headers: [String: String]) -> Outcome {
        Outcome(
            columns: [],
            columnTypeNames: [],
            rows: [],
            affectedRows: affectedRowsFromSummary(headers: headers),
            isTruncated: false
        )
    }

    private static func rawOutcome(body: Data) -> Outcome {
        let isTruncated = body.count > rawBodyByteCap
        let text = decodedText(body.prefix(rawBodyByteCap))
        return Outcome(
            columns: [String(localized: "Output")],
            columnTypeNames: ["String"],
            rows: [[.text(text)]],
            affectedRows: 1,
            isTruncated: isTruncated
        )
    }

    private static func tabSeparatedOutcome(lines: [String], rowLimit: Int) -> Outcome {
        let columns = lines[0].components(separatedBy: "\t")
        let columnTypeNames = lines[1].components(separatedBy: "\t")

        var rows: [[PluginCellValue]] = []
        var isTruncated = false
        for index in 2..<lines.count {
            let line = lines[index]
            if line.isEmpty { continue }

            let fields = line.components(separatedBy: "\t")
            let row: [PluginCellValue] = fields.map { field in
                field == "\\N" ? .null : .text(unescapeTsvField(field))
            }
            rows.append(row)
            if rows.count >= rowLimit {
                isTruncated = true
                break
            }
        }

        return Outcome(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            affectedRows: rows.count,
            isTruncated: isTruncated
        )
    }

    private static func decodedText(_ data: Data) -> String {
        for suffixLength in 0...3 where data.count >= suffixLength {
            if let text = String(bytes: data.dropLast(suffixLength), encoding: .utf8) {
                return text
            }
        }
        return String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    private static func headerValue(_ headers: [String: String], named name: String) -> String? {
        if let exact = headers[name] {
            return exact
        }
        return headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }
}
