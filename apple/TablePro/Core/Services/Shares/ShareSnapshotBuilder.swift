//
//  ShareSnapshotBuilder.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// The displayed result a Share Result sheet works from: visible columns in grid order, filtered rows, masked values.
internal struct ShareResultSource: Sendable {
    let columns: [String]
    let columnTypes: [ColumnType]
    let rows: [[PluginCellValue]]
    // The result's true total when known; never less than rows.count.
    let totalRowCount: Int
}

internal enum ShareSnapshotOutcome: Equatable, Sendable {
    case snapshot(ShareSnapshot)
    case tooLarge
}

internal enum ShareSnapshotBuilder {
    // Under the server's 5 MiB, so a size it counts differently never refuses a share the sheet offered.
    static let maxColumns = 100
    static let maxCellBytes = 256 * 1_024
    static let maxBodyBytes = 4_500_000

    static func build(_ source: ShareResultSource, maxRows: Int) -> ShareSnapshotOutcome {
        guard !source.columns.isEmpty, source.columns.count <= maxColumns else { return .tooLarge }
        let columns = source.columns.indices.map { index in
            ShareSnapshot.Column(name: source.columns[index], type: typeLabel(source.columnTypes, at: index))
        }

        var rows: [[ShareCell]] = []
        rows.reserveCapacity(min(source.rows.count, max(0, maxRows)))
        var bodyBytes = 2
        for row in source.rows {
            guard rows.count < maxRows else { break }
            var cells: [ShareCell] = []
            cells.reserveCapacity(columns.count)
            var rowBytes = 2 + max(0, columns.count - 1) + 1
            for index in columns.indices {
                let type = source.columnTypes.indices.contains(index) ? source.columnTypes[index] : .text(rawType: nil)
                let cell = ShareCellEncoder.encode(row.indices.contains(index) ? row[index] : .null, type: type)
                let size = ShareCellEncoder.jsonByteCount(cell)
                guard size <= maxCellBytes else { return .tooLarge }
                rowBytes += size
                cells.append(cell)
            }
            if bodyBytes + rowBytes > maxBodyBytes {
                guard !rows.isEmpty else { return .tooLarge }
                break
            }
            bodyBytes += rowBytes
            rows.append(cells)
        }

        return .snapshot(ShareSnapshot(
            columns: columns,
            rows: rows,
            rowCount: max(source.totalRowCount, source.rows.count, rows.count)
        ))
    }

    private static func typeLabel(_ types: [ColumnType], at index: Int) -> String? {
        guard types.indices.contains(index) else { return nil }
        return types[index].rawType ?? types[index].displayName.lowercased()
    }
}

internal enum ShareCellEncoder {
    // 2^53 - 1: the widest integer a JavaScript number keeps exactly.
    static let safeIntegerMagnitude: Int64 = 9_007_199_254_740_991

    static func encode(_ cell: PluginCellValue, type: ColumnType) -> ShareCell {
        switch cell {
        case .null:
            return .null
        case .bytes(let data):
            // Data, not interface text: every app and the viewer write the same words.
            return .string("(binary, \(data.count) bytes)")
        case .text(let value):
            return encode(text: value, type: type)
        }
    }

    private static func encode(text value: String, type: ColumnType) -> ShareCell {
        switch type {
        case .boolean:
            return boolean(value)
        case .integer:
            return integer(value)
        case .decimal:
            return decimal(value)
        case .text, .date, .timestamp, .datetime, .json, .blob, .enumType, .set, .spatial, .vector, .array:
            return .string(value)
        }
    }

    private static func boolean(_ value: String) -> ShareCell {
        switch value.lowercased() {
        case "true", "t", "1", "yes", "on":
            return .bool(true)
        case "false", "f", "0", "no", "off":
            return .bool(false)
        default:
            // MySQL's BOOLEAN is TINYINT(1), which also stores 2 or -1.
            return integer(value)
        }
    }

    private static func integer(_ value: String) -> ShareCell {
        guard let literal = JsonNumberNormalizer.integerLiteral(from: value) else { return .string(value) }
        if let number = Int64(literal), (-safeIntegerMagnitude...safeIntegerMagnitude).contains(number) {
            return .integer(number)
        }
        return .string(literal)
    }

    // A number only when a browser prints exactly what the database printed; otherwise the digits travel as text.
    private static func decimal(_ value: String) -> ShareCell {
        guard let literal = JsonNumberNormalizer.numberLiteral(from: value) else { return .string(value) }
        guard let number = Double(literal), number.isFinite, javaScriptText(of: number) == literal else {
            return .string(literal)
        }
        return .double(number)
    }

    // ECMAScript Number::toString over Swift's shortest round-trip digits.
    static func javaScriptText(of number: Double) -> String {
        if number == 0 { return "0" }
        let sign = number < 0 ? "-" : ""
        let described = "\(abs(number))"
        let parts = described.lowercased().split(separator: "e", maxSplits: 1)
        var exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let mantissa = parts[0].split(separator: ".", maxSplits: 1)
        let whole = String(mantissa[0])
        let fraction = mantissa.count == 2 ? String(mantissa[1]) : ""
        exponent += whole.count
        var digits = whole + fraction
        while digits.hasPrefix("0"), digits.count > 1 {
            digits.removeFirst()
            exponent -= 1
        }
        while digits.hasSuffix("0"), digits.count > 1 {
            digits.removeLast()
        }
        let count = digits.count
        if count <= exponent, exponent <= 21 {
            return sign + digits + String(repeating: "0", count: exponent - count)
        }
        if exponent > 0, exponent <= 21 {
            let split = digits.index(digits.startIndex, offsetBy: exponent)
            return sign + String(digits[..<split]) + "." + String(digits[split...])
        }
        if exponent > -6, exponent <= 0 {
            return sign + "0." + String(repeating: "0", count: -exponent) + digits
        }
        let power = exponent - 1
        let powerText = power < 0 ? "-\(-power)" : "+\(power)"
        let head = String(digits.prefix(1))
        let tail = String(digits.dropFirst())
        return sign + head + (tail.isEmpty ? "" : "." + tail) + "e" + powerText
    }

    static func jsonByteCount(_ cell: ShareCell) -> Int {
        switch cell {
        case .null: return 4
        case .bool(let value): return value ? 4 : 5
        case .integer(let value): return String(value).utf8.count
        case .double(let value): return javaScriptText(of: value).utf8.count
        case .string(let value): return quotedByteCount(value)
        }
    }

    private static func quotedByteCount(_ value: String) -> Int {
        var count = 2
        for byte in value.utf8 {
            switch byte {
            case 0x22, 0x5C, 0x2F, 0x08, 0x0C, 0x0A, 0x0D, 0x09: count += 2
            case 0x00..<0x20, 0x3C, 0x3E, 0x26: count += 6
            default: count += 1
            }
        }
        return count
    }
}
