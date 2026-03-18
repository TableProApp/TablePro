//
//  JsonRowConverter.swift
//  TablePro
//

import Foundation

internal struct JsonRowConverter {
    internal let columns: [String]
    internal let columnTypes: [ColumnType]

    private static let maxRows = 50_000

    func generateJson(rows: [[String?]]) -> String {
        let cappedRows = rows.prefix(Self.maxRows)
        let rowCount = cappedRows.count

        if rowCount == 0 {
            return "[]"
        }

        // Estimate capacity: ~100 bytes per cell as rough heuristic
        var result = String()
        result.reserveCapacity(rowCount * columns.count * 100)

        result.append("[\n")

        for (rowIdx, row) in cappedRows.enumerated() {
            result.append("  {\n")

            for (colIdx, column) in columns.enumerated() {
                result.append("    \"")
                result.append(escapeString(column))
                result.append("\": ")

                guard row.indices.contains(colIdx), let value = row[colIdx] else {
                    result.append("null")
                    appendPropertySuffix(to: &result, colIdx: colIdx)
                    continue
                }

                let colType: ColumnType
                if columnTypes.indices.contains(colIdx) {
                    colType = columnTypes[colIdx]
                } else {
                    colType = .text(rawType: nil)
                }

                result.append(formatValue(value, type: colType))
                appendPropertySuffix(to: &result, colIdx: colIdx)
            }

            result.append("  }")
            if rowIdx < rowCount - 1 {
                result.append(",")
            }
            result.append("\n")
        }

        result.append("]")
        return result
    }

    private func appendPropertySuffix(to result: inout String, colIdx: Int) {
        if colIdx < columns.count - 1 {
            result.append(",")
        }
        result.append("\n")
    }

    private func formatValue(_ value: String, type: ColumnType) -> String {
        switch type {
        case .integer:
            return formatInteger(value)
        case .decimal:
            return formatDecimal(value)
        case .boolean:
            return formatBoolean(value)
        case .json:
            return formatJson(value)
        case .blob:
            return formatBlob(value)
        case .text, .date, .timestamp, .datetime, .enumType, .set, .spatial:
            return quotedEscaped(value)
        }
    }

    private func formatInteger(_ value: String) -> String {
        if let intVal = Int64(value) {
            return String(intVal)
        }
        if let doubleVal = Double(value), doubleVal == doubleVal.rounded(.towardZero), !doubleVal.isInfinite, !doubleVal.isNaN {
            return String(Int64(doubleVal))
        }
        return quotedEscaped(value)
    }

    private func formatDecimal(_ value: String) -> String {
        // Emit verbatim if already a valid JSON number — preserves full database precision
        if isValidJsonNumber(value) {
            return value
        }
        // Fallback for non-standard formats (e.g., "1.0E5" with leading +)
        if let doubleVal = Double(value), !doubleVal.isInfinite, !doubleVal.isNaN {
            return String(doubleVal)
        }
        return quotedEscaped(value)
    }

    /// Checks whether a string conforms to JSON number grammar (RFC 8259 §6)
    private func isValidJsonNumber(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        var iter = scalars.makeIterator()
        guard var ch = iter.next() else { return false }

        // Optional leading minus
        if ch == "-" { guard let next = iter.next() else { return false }; ch = next }

        // Integer part: "0" or [1-9][0-9]*
        guard ch >= "0" && ch <= "9" else { return false }
        if ch == "0" {
            // "0" must not be followed by another digit
            if let next = iter.next() { ch = next } else { return true }
        } else {
            while true {
                guard let next = iter.next() else { return true }
                ch = next
                guard ch >= "0" && ch <= "9" else { break }
            }
        }

        // Optional fractional part
        if ch == "." {
            guard let next = iter.next(), next >= "0" && next <= "9" else { return false }
            while true {
                guard let next = iter.next() else { return true }
                ch = next
                guard ch >= "0" && ch <= "9" else { break }
            }
        }

        // Optional exponent
        if ch == "e" || ch == "E" {
            guard var next = iter.next() else { return false }
            if next == "+" || next == "-" {
                guard let signed = iter.next() else { return false }
                next = signed
            }
            guard next >= "0" && next <= "9" else { return false }
            for remaining in IteratorSequence(iter) {
                guard remaining >= "0" && remaining <= "9" else { return false }
            }
        } else {
            return false // Unexpected trailing character
        }

        return true
    }

    private func formatBoolean(_ value: String) -> String {
        switch value.lowercased() {
        case "true", "1", "yes", "on":
            return "true"
        case "false", "0", "no", "off":
            return "false"
        default:
            return quotedEscaped(value)
        }
    }

    private func formatJson(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            return quotedEscaped(value)
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            return trimmed
        } catch {
            return quotedEscaped(value)
        }
    }

    private func formatBlob(_ value: String) -> String {
        guard let data = value.data(using: .utf8) else {
            return quotedEscaped(value)
        }
        let encoded = data.base64EncodedString()
        return "\"\(encoded)\""
    }

    private func quotedEscaped(_ value: String) -> String {
        "\"\(escapeString(value))\""
    }

    private func escapeString(_ value: String) -> String {
        var result = String()
        result.reserveCapacity((value as NSString).length)

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                result.append("\\\"")
            case "\\":
                result.append("\\\\")
            case "\n":
                result.append("\\n")
            case "\r":
                result.append("\\r")
            case "\t":
                result.append("\\t")
            default:
                if scalar.value < 0x20 {
                    result.append(String(format: "\\u%04X", scalar.value))
                } else {
                    result.append(Character(scalar))
                }
            }
        }

        return result
    }
}
