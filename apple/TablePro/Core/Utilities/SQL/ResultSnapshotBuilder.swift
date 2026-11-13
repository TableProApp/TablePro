//
//  ResultSnapshotBuilder.swift
//  TablePro
//

import Foundation
import TableProCloudAPI
import TableProPluginKit

// Turns a displayed result into a share snapshot. Lossless on the web viewer: a value wider than a
// JS safe integer, or a high-precision decimal, goes as a string so no digit is rounded away; safe
// numbers go as JSON numbers so the viewer right-aligns them.
enum ResultSnapshotBuilder {
    static let maxRows = 10_000
    static let maxColumns = 100
    // Per cell and for the whole snapshot, under the server's 256 KB/cell and 5 MB (compressed) caps.
    static let maxCellBytes = 64 * 1_024
    static let maxSnapshotBytes = 8 * 1_024 * 1_024

    struct Built {
        let snapshot: Components.Schemas.SnapshotInput
        let rowsSent: Int
    }

    // totalRowCount: the result's true total when known; nil when the result was cut short with no count.
    // moreRowsAvailable: the result had rows beyond those loaded.
    static func build(
        from read: DisplayedResultReader.Output,
        totalRowCount: Int?,
        moreRowsAvailable: Bool
    ) -> Built {
        var truncated = false

        var columnNames = read.columns
        var columnTypes = read.columnTypes
        if columnNames.count > maxColumns {
            columnNames = Array(columnNames.prefix(maxColumns))
            columnTypes = Array(columnTypes.prefix(maxColumns))
            truncated = true
        }
        let columns = columnNames.enumerated().map { index, name in
            Components.Schemas.ColumnJSON(name: name, _type: columnTypeLabel(columnTypes, at: index))
        }

        var rows: [[OpenAPIValueContainer]?] = []
        var bytes = 0
        for row in read.rows {
            if rows.count >= maxRows { truncated = true; break }
            var cells: [OpenAPIValueContainer] = []
            var rowBytes = 0
            for index in 0 ..< columnNames.count {
                let type = columnTypes.indices.contains(index) ? columnTypes[index] : .text(rawType: nil)
                let cell = row.indices.contains(index) ? row[index] : .null
                let encoded = SnapshotCellEncoder.encode(cell, type: type)
                rowBytes += encoded.byteCount
                cells.append(encoded.value)
            }
            if !rows.isEmpty, bytes + rowBytes > maxSnapshotBytes { truncated = true; break }
            bytes += rowBytes
            rows.append(cells)
        }

        if moreRowsAvailable { truncated = true }
        if let total = totalRowCount, total > rows.count { truncated = true }

        let rowCount: Int64?
        if let total = totalRowCount, total > rows.count {
            rowCount = Int64(total)
        } else {
            rowCount = nil
        }

        let snapshot = Components.Schemas.SnapshotInput(
            columns: columns,
            rowCount: rowCount,
            rows: rows,
            truncated: truncated
        )
        return Built(snapshot: snapshot, rowsSent: rows.count)
    }

    private static func columnTypeLabel(_ types: [ColumnType], at index: Int) -> String? {
        guard types.indices.contains(index) else { return nil }
        return types[index].rawType ?? types[index].displayName
    }
}

// The cell mapping, factored out so it can be tested without a result set.
enum SnapshotCellEncoder {
    struct Encoded {
        let value: OpenAPIValueContainer
        let byteCount: Int
    }

    // 2^53 - 1: the largest integer a JS number holds exactly, so the viewer's JSON.parse keeps it.
    static let safeIntegerMagnitude: Int64 = 9_007_199_254_740_991

    static func encode(_ cell: PluginCellValue, type: ColumnType) -> Encoded {
        switch cell {
        case .null:
            return Encoded(value: OpenAPIValueContainer(nilLiteral: ()), byteCount: 4)
        case .bytes(let data):
            return string("(binary, \(data.count) bytes)")
        case .text(let value):
            return encodeText(value, type: type)
        }
    }

    private static func encodeText(_ value: String, type: ColumnType) -> Encoded {
        switch type {
        case .boolean:
            return encodeBoolean(value)
        case .integer:
            return encodeInteger(value)
        case .decimal:
            return encodeDecimal(value)
        case .text, .date, .timestamp, .datetime, .json, .blob,
             .enumType, .set, .spatial, .vector, .array:
            return string(value)
        }
    }

    private static func encodeBoolean(_ value: String) -> Encoded {
        switch value.lowercased() {
        case "true", "1", "yes", "on":
            return Encoded(value: OpenAPIValueContainer(booleanLiteral: true), byteCount: 4)
        case "false", "0", "no", "off":
            return Encoded(value: OpenAPIValueContainer(booleanLiteral: false), byteCount: 5)
        default:
            // MySQL's BOOLEAN is TINYINT(1), which also stores 2 or -1.
            return encodeInteger(value)
        }
    }

    private static func encodeInteger(_ value: String) -> Encoded {
        guard let literal = JsonNumberNormalizer.integerLiteral(from: value) else {
            return string(value)
        }
        if let number = Int64(literal), (-safeIntegerMagnitude ... safeIntegerMagnitude).contains(number) {
            return Encoded(value: OpenAPIValueContainer(integerLiteral: Int(number)), byteCount: literal.utf8.count)
        }
        return string(literal)
    }

    private static func encodeDecimal(_ value: String) -> Encoded {
        guard let literal = JsonNumberNormalizer.numberLiteral(from: value) else {
            return string(value)
        }
        if let double = Double(literal), double.isFinite,
           JsonNumberNormalizer.numberLiteral(from: String(double)) == literal {
            return Encoded(value: OpenAPIValueContainer(floatLiteral: double), byteCount: literal.utf8.count)
        }
        return string(literal)
    }

    private static func string(_ value: String) -> Encoded {
        let capped = capped(value)
        return Encoded(value: OpenAPIValueContainer(stringLiteral: capped), byteCount: capped.utf8.count)
    }

    private static func capped(_ value: String) -> String {
        guard value.utf8.count > ResultSnapshotBuilder.maxCellBytes else { return value }
        let prefix = String(value.prefix(ResultSnapshotBuilder.maxCellBytes / 4))
        return prefix + "…"
    }
}
