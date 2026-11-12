import AppIntents
import Foundation
import TableProTabularIO
import UniformTypeIdentifiers

nonisolated enum RowPayload {
    static let maxRows = 10_000

    static func parse(data: String?, file: IntentFile?) async throws -> [PayloadRow] {
        let raw = try await rawContent(data: data, file: file)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntentDataError.emptyPayload }

        let rows = try sniffedRows(raw: raw, trimmed: trimmed)

        guard !rows.isEmpty else { throw IntentDataError.emptyPayload }
        guard rows.count <= maxRows else { throw IntentDataError.tooManyRows(maxRows) }
        return rows
    }

    // A CSV header can open with `[` or `{`, as SQL Server's `[id],[name]` does, so only text that parses as JSON is
    // JSON. Text that is neither keeps the JSON error, which names what broke in a payload meant as JSON. So does JSON
    // that still splits into even CSV records, one object per line with a trailing comma: its headers hold `":`.
    private static func sniffedRows(raw: String, trimmed: String) throws -> [PayloadRow] {
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return try parseCSV(raw) }
        do {
            return try parseJSON(trimmed)
        } catch IntentDataError.malformedPayload(let reason) {
            guard let rows = try? parseCSV(raw), !rows.isEmpty,
                  !rows.contains(where: { row in row.keys.contains { $0.contains("\":") } }) else {
                throw IntentDataError.malformedPayload(reason)
            }
            return rows
        }
    }

    static func parseSingle(data: String?, file: IntentFile?) async throws -> [PayloadRow] {
        let rows = try await parse(data: data, file: file)
        guard rows.count == 1 else { throw IntentDataError.expectedSingleRow }
        return rows
    }

    private static func rawContent(data: String?, file: IntentFile?) async throws -> String {
        if let file {
            return try text(of: try await contents(of: file))
        }
        if let data, !data.isEmpty {
            return data
        }
        throw IntentDataError.emptyPayload
    }

    private static func contents(of file: IntentFile) async throws -> Data {
        #if os(macOS)
        guard #available(macOS 15.0, *) else { return file.data }
        #endif
        return try await file.data(contentType: .data)
    }

    static func text(of fileData: Data) throws -> String {
        let sniff = TabularEncodingDetector.sniff(fileData)
        guard sniff.encoding != .utf8 else {
            if let line = TabularTextTranscoder.firstInvalidUTF8Line(in: fileData, skippingPrefix: sniff.byteOrderMarkLength) {
                throw IntentDataError.unreadableText(line: line, encoding: sniff.encoding.displayName)
            }
            return TabularTextCodec.utf8String(fileData.dropFirst(sniff.byteOrderMarkLength))
        }
        let decoded = try TabularTextTranscoder.utf8Data(
            from: fileData,
            encoding: sniff.encoding,
            skippingPrefix: sniff.byteOrderMarkLength
        )
        if let line = decoded.firstUndecodableLine {
            throw IntentDataError.unreadableText(line: line, encoding: sniff.encoding.displayName)
        }
        return TabularTextCodec.utf8String(decoded.data)
    }

    static func parseJSON(_ text: String) throws -> [PayloadRow] {
        guard let data = text.data(using: .utf8) else {
            throw IntentDataError.invalidTextEncoding
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw IntentDataError.malformedPayload(error.localizedDescription)
        }
        if let dictionary = object as? [String: Any] {
            return [row(from: dictionary)]
        }
        if let array = object as? [Any] {
            return try array.map { element in
                guard let dictionary = element as? [String: Any] else {
                    throw IntentDataError.jsonArrayContainsNonObject
                }
                return row(from: dictionary)
            }
        }
        throw IntentDataError.invalidJSONShape
    }

    // An unquoted empty field is no value, so the column takes its default or NULL. A quoted "" is an empty string.
    static func parseCSV(_ text: String) throws -> [PayloadRow] {
        let records = try csvRecords(in: text)
        guard let header = records.first?.map({ $0.text }), !header.allSatisfy(\.isEmpty) else {
            throw IntentDataError.csvMissingHeader
        }
        return try records.enumerated().dropFirst().compactMap { line, record in
            guard !(record.count == 1 && record[0].text.isEmpty && !record[0].isQuoted) else { return nil }
            guard record.count == header.count else {
                throw IntentDataError.csvFieldCountMismatch(record: line + 1, found: record.count, expected: header.count)
            }
            var values: [String: PayloadValue] = [:]
            for (column, field) in zip(header, record) where !column.isEmpty {
                guard field.isQuoted || !field.text.isEmpty else { continue }
                values[column] = .text(field.text)
            }
            return PayloadRow(values: values)
        }
    }

    private static func csvRecords(in text: String) throws -> [[(text: String, isQuoted: Bool)]] {
        let dialect = DelimitedDialect()
        let reader = DelimitedFieldReader(dialect: dialect)
        return try Array(text.utf8).withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return [] }
            let index = try DelimitedRowIndexer.index(buffer, dialect: dialect, contentStart: 0)
            return (0..<index.rowCount).map { reader.fieldsWithQuoting(in: base, range: index.range(ofRow: $0)) }
        }
    }

    private static func row(from dictionary: [String: Any]) -> PayloadRow {
        var values: [String: PayloadValue] = [:]
        for (key, value) in dictionary {
            values[key] = payloadValue(from: value)
        }
        return PayloadRow(values: values)
    }

    private static func payloadValue(from value: Any) -> PayloadValue {
        switch value {
        case is NSNull:
            return .null
        case let string as String:
            return .text(string)
        case let number as NSNumber:
            return .text(numberString(number))
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value, options: []),
               let string = String(data: data, encoding: .utf8) {
                return .text(string)
            }
            return .text(String(describing: value))
        }
    }

    private static func numberString(_ number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return number.stringValue
    }
}
