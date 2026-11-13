//
//  ShareSnapshotBuilder.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// The rows a Share Result sheet works from: visible columns in grid order, display order, masked values.
internal struct ShareResultSource: Sendable {
    let columns: [String]
    let columnTypes: [ColumnType]
    let rows: [[PluginCellValue]]
    // The result's true total, at least rows.count; nil when more rows exist and nobody counted them.
    let totalRowCount: Int?
    // The statement these rows came from.
    let sql: String
}

internal enum ShareSnapshotOutcome: Equatable, Sendable {
    case snapshot(ShareSnapshot)
    case tooLarge
}

internal enum ShareSnapshotBuilder {
    static let maxColumns = 100
    static let maxCellBytes = 256 * 1_024
    // Under the server's 5 MiB, so a size it counts differently never refuses a share the sheet offered.
    static let maxBodyBytes = 4_500_000

    // Nil once the caller's task is cancelled.
    static func build(_ source: ShareResultSource, maxRows: Int) -> ShareSnapshotOutcome? {
        guard !source.columns.isEmpty, source.columns.count <= maxColumns else { return .tooLarge }
        let columns = source.columns.indices.map { index in
            ShareSnapshot.Column(name: source.columns[index], type: typeLabel(source.columnTypes, at: index))
        }

        var rows: [[ShareCell]] = []
        rows.reserveCapacity(min(source.rows.count, max(0, maxRows)))
        var bodyBytes = 2 + columns.reduce(0) { $0 + ShareCellEncoder.quotedByteCount($1.name) + 12 }
        for row in source.rows {
            guard rows.count < maxRows else { break }
            if rows.count % 256 == 0, Task.isCancelled { return nil }
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
            rowCount: source.totalRowCount.map { max($0, rows.count) }
        ))
    }

    private static func typeLabel(_ types: [ColumnType], at index: Int) -> String? {
        guard types.indices.contains(index) else { return nil }
        return types[index].rawType ?? types[index].displayName.lowercased()
    }
}

// The core's snapshot cell rules (core/crates/core/src/export/snapshot.rs), so a result looks the same from any app.
internal enum ShareCellEncoder {
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
            return JsonNumberNormalizer.integerLiteral(from: value).map(ShareCell.number) ?? .string(value)
        case .decimal:
            // NaN and Infinity have no JSON number, so they go as their names.
            return JsonNumberNormalizer.numberLiteral(from: value).map(ShareCell.number) ?? .string(value)
        case .json:
            return document(value) ?? .string(value)
        case .array(_, let element):
            return array(value, element: element)
        case .timestamp, .datetime:
            return .string(isoTimestamp(value))
        case .text, .date, .blob, .enumType, .set, .spatial, .vector:
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
            return JsonNumberNormalizer.integerLiteral(from: value).map(ShareCell.number) ?? .string(value)
        }
    }

    private static func document(_ value: String) -> ShareCell? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.isValidJson else { return nil }
        return .document(trimmed)
    }

    // A driver that writes arrays as JSON gives a document; PostgreSQL's literal is read element by element.
    private static func array(_ value: String, element: ColumnType) -> ShareCell {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), let document = document(trimmed) {
            return document
        }
        guard let elements = PostgresArrayLiteralCodec.parse(trimmed) else { return .string(value) }
        return .array(elements.map { item in
            if case .value(let text) = item {
                return encode(text: text, type: element)
            }
            return .null
        })
    }

    private static let timestampPattern = try? NSRegularExpression(
        pattern: "^(-?\\d{4,}-\\d{2}-\\d{2})[ T](\\d{2}:\\d{2}(?::\\d{2}(?:\\.\\d+)?)?) ?(Z|[+-]\\d{2}(?::?\\d{2}){0,2})?( BC)?$"
    )

    // ISO 8601 as the core writes it: a T between date and time, and an offset as +HH:MM.
    static func isoTimestamp(_ value: String) -> String {
        let text = value as NSString
        guard let pattern = timestampPattern,
              let match = pattern.firstMatch(in: value, range: NSRange(location: 0, length: text.length))
        else { return value }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : text.substring(with: range)
        }
        let date = group(1) ?? ""
        let time = group(2) ?? ""
        let offset = group(3).map(isoOffset) ?? ""
        return date + "T" + time + offset + (group(4) ?? "")
    }

    private static func isoOffset(_ offset: String) -> String {
        guard offset != "Z" else { return "+00:00" }
        let sign = offset.prefix(1)
        let digits = offset.dropFirst().filter(\.isNumber)
        let hours = digits.prefix(2)
        let minutes = digits.dropFirst(2).prefix(2)
        let seconds = digits.dropFirst(4).prefix(2)
        var text = sign + hours + ":" + (minutes.isEmpty ? "00" : minutes)
        if !seconds.isEmpty, seconds != "00" {
            text += ":" + seconds
        }
        return String(text)
    }

    static func jsonByteCount(_ cell: ShareCell) -> Int {
        switch cell {
        case .null: return 4
        case .bool(let value): return value ? 4 : 5
        case .number(let token): return token.utf8.count
        case .document(let text): return text.utf8.count
        case .string(let value): return quotedByteCount(value)
        case .array(let cells): return cells.reduce(2 + max(0, cells.count - 1)) { $0 + jsonByteCount($1) }
        }
    }

    static func quotedByteCount(_ value: String) -> Int {
        var count = 2
        for byte in value.utf8 {
            switch byte {
            case 0x22, 0x5C, 0x08, 0x0C, 0x0A, 0x0D, 0x09: count += 2
            case 0x00..<0x20, 0x3C, 0x3E, 0x26: count += 6
            default: count += 1
            }
        }
        return count
    }

    // How the preview shows a cell, as one line.
    static func previewText(_ cell: ShareCell) -> String {
        switch cell {
        case .null: return ""
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let token): return token
        case .string(let text), .document(let text): return text
        case .array(let cells): return "[" + cells.map(previewElement).joined(separator: ", ") + "]"
        }
    }

    private static func previewElement(_ cell: ShareCell) -> String {
        switch cell {
        case .null: return "null"
        case .string(let text): return "\"\(text)\""
        default: return previewText(cell)
        }
    }
}
