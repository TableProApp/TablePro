import AppIntents
import Foundation
import UniformTypeIdentifiers

enum RowPayload {
    static let maxRows = 10_000

    static func parse(data: String?, file: IntentFile?) async throws -> [PayloadRow] {
        let raw = try await rawContent(data: data, file: file)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntentDataError.emptyPayload }

        let rows = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            ? try parseJSON(trimmed)
            : try parseCSV(raw)

        guard !rows.isEmpty else { throw IntentDataError.emptyPayload }
        guard rows.count <= maxRows else { throw IntentDataError.tooManyRows(maxRows) }
        return rows
    }

    static func parseSingle(data: String?, file: IntentFile?) async throws -> [PayloadRow] {
        let rows = try await parse(data: data, file: file)
        guard rows.count == 1 else { throw IntentDataError.expectedSingleRow }
        return rows
    }

    private static func rawContent(data: String?, file: IntentFile?) async throws -> String {
        if let file {
            let fileData = try await file.data(contentType: .data)
            guard let text = String(data: fileData, encoding: .utf8) else {
                throw IntentDataError.malformedPayload("the file is not UTF-8 text")
            }
            return text
        }
        if let data, !data.isEmpty {
            return data
        }
        throw IntentDataError.emptyPayload
    }

    static func parseJSON(_ text: String) throws -> [PayloadRow] {
        guard let data = text.data(using: .utf8) else {
            throw IntentDataError.malformedPayload("invalid text encoding")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw IntentDataError.malformedPayload(error.localizedDescription)
        }
        if let dictionary = object as? [String: Any] {
            return [row(from: dictionary)]
        }
        if let array = object as? [Any] {
            return try array.map { element in
                guard let dictionary = element as? [String: Any] else {
                    throw IntentDataError.malformedPayload("expected a list of objects")
                }
                return row(from: dictionary)
            }
        }
        throw IntentDataError.malformedPayload("expected a JSON object or a list of objects")
    }

    static func parseCSV(_ text: String) throws -> [PayloadRow] {
        let records = CSVRecordParser.parse(text)
        guard let header = records.first, !header.allSatisfy(\.isEmpty) else {
            throw IntentDataError.malformedPayload("the CSV has no header row")
        }
        return records.dropFirst().compactMap { record in
            guard !(record.count == 1 && record[0].isEmpty) else { return nil }
            var values: [String: PayloadValue] = [:]
            for (index, column) in header.enumerated() where !column.isEmpty {
                let field = index < record.count ? record[index] : ""
                values[column] = .text(field)
            }
            return PayloadRow(values: values)
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

enum CSVRecordParser {
    static func parse(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case ",":
                    record.append(field)
                    field = ""
                case "\n":
                    record.append(field)
                    field = ""
                    records.append(record)
                    record = []
                case "\r":
                    break
                default:
                    field.append(character)
                }
            }
            index += 1
        }

        record.append(field)
        records.append(record)
        return records
    }
}
