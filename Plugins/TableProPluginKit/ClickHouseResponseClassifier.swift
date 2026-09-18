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
        let bytes = [UInt8](body)
        guard !ClickHouseTabSeparatedBytes.isAsciiWhitespace(bytes) else {
            return noResultSetOutcome(headers: headers)
        }
        let lines = ClickHouseTabSeparatedBytes.lines(bytes)
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
        let bytes = Array(field.utf8)
        return String(decoding: ClickHouseTabSeparatedBytes.unescape(bytes[...]), as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
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

    /// A body the server wrote in a format the user asked for is one opaque value. It is text when
    /// it decodes as text and bytes when it does not, because a `Native` or `Parquet` body read as
    /// Latin-1 is mojibake that cannot be copied back out.
    private static func rawOutcome(body: Data) -> Outcome {
        let isTruncated = body.count > rawBodyByteCap
        let capped = [UInt8](body.prefix(rawBodyByteCap))
        let decodable = isTruncated ? Array(droppingCutSequence(capped)) : capped
        let value: PluginCellValue = utf8Text(decodable).map { .text($0) } ?? .bytes(Data(capped))
        return Outcome(
            columns: [String(localized: "Output")],
            columnTypeNames: ["String"],
            rows: [[value]],
            affectedRows: 1,
            isTruncated: isTruncated
        )
    }

    private static func tabSeparatedOutcome(lines: [ArraySlice<UInt8>], rowLimit: Int) -> Outcome {
        let columns = ClickHouseTabSeparatedBytes.fields(lines[0]).map(ClickHouseTabSeparatedBytes.headerText)
        let columnTypeNames = ClickHouseTabSeparatedBytes.fields(lines[1]).map(ClickHouseTabSeparatedBytes.headerText)

        var rows: [[PluginCellValue]] = []
        var binaryColumns = Set<Int>()
        var isTruncated = false
        for index in 2..<lines.count {
            let line = lines[index]
            if line.isEmpty { continue }

            let fields = ClickHouseTabSeparatedBytes.fields(line)
            var row: [PluginCellValue] = []
            row.reserveCapacity(fields.count)
            for (column, field) in fields.enumerated() {
                if ClickHouseTabSeparatedBytes.isNullMarker(field) {
                    row.append(.null)
                    continue
                }
                let value = ClickHouseTabSeparatedBytes.unescape(field)
                guard let text = utf8Text(value) else {
                    binaryColumns.insert(column)
                    row.append(.bytes(Data(value)))
                    continue
                }
                row.append(.text(text))
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
            rows: demoteBinaryColumns(binaryColumns, in: rows),
            affectedRows: rows.count,
            isTruncated: isTruncated
        )
    }

    /// One value that is not text makes the whole column binary. A `FixedString(16)` of raw UUIDs
    /// decodes on the rows whose bytes happen to be valid UTF-8 and not on the rest, and a column
    /// that renders as hex on some rows and as mojibake on others is the worse answer. Re-encoding
    /// a decoded value is exact: UTF-8 round-trips whenever the decode succeeded.
    private static func demoteBinaryColumns(
        _ binaryColumns: Set<Int>,
        in rows: [[PluginCellValue]]
    ) -> [[PluginCellValue]] {
        guard !binaryColumns.isEmpty else { return rows }
        return rows.map { row in
            row.enumerated().map { column, value in
                guard binaryColumns.contains(column), case .text(let text) = value else { return value }
                return .bytes(Data(text.utf8))
            }
        }
    }

    private static func utf8Text(_ bytes: [UInt8]) -> String? {
        String(bytes: bytes, encoding: .utf8)
    }

    /// The byte cap can stop inside a multi-byte character, so a truncated body sheds that one
    /// incomplete sequence and nothing else. Dropping trailing bytes until the rest decodes would
    /// call a short binary body text, and a field is never cut, so it never comes through here.
    private static func droppingCutSequence(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        guard !bytes.isEmpty else { return bytes[...] }
        for offset in 1...min(3, bytes.count) {
            let index = bytes.count - offset
            let byte = bytes[index]
            if byte & 0xC0 == 0x80 { continue }
            let sequenceLength: Int
            switch byte {
            case 0xC0...0xDF: sequenceLength = 2
            case 0xE0...0xEF: sequenceLength = 3
            case 0xF0...0xF7: sequenceLength = 4
            default: return bytes[...]
            }
            return offset < sequenceLength ? bytes[..<index] : bytes[...]
        }
        return bytes[...]
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
