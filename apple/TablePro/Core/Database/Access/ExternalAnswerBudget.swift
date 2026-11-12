//
//  ExternalAnswerBudget.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// The bytes one answer to an MCP client or the assistant may hold, measured after masking. The limits, the
// measure and the mark are the core's (`core/crates/mcp/src/collected_results.rs`), so both apps answer alike.
internal struct ExternalAnswerBudget: Sendable, Equatable {
    internal enum LongValues: Sendable, Equatable {
        case cut
        // An export is data to keep exactly, so a row that does not fit is left out instead.
        case whole
    }

    internal static let answerBytes = 4 << 20
    internal static let valueBytes = 64 << 10
    internal static let assistantAnswerBytes = 256 << 10

    // A cell's quotes, colon and comma, and a row's brackets and comma.
    private static let cellBytes = 6
    private static let rowBytes = 3
    private static let nullBytes = 4

    internal let limitBytes: Int
    internal let longValues: LongValues
    internal private(set) var spentBytes = 0
    internal private(set) var valuesCut = false
    internal private(set) var sizeLimited = false

    internal init(bytes: Int, longValues: LongValues = .cut) {
        limitBytes = max(bytes, 0)
        self.longValues = longValues
    }

    internal static var mcpAnswer: ExternalAnswerBudget {
        ExternalAnswerBudget(bytes: answerBytes)
    }

    internal static var assistantAnswer: ExternalAnswerBudget {
        ExternalAnswerBudget(bytes: assistantAnswerBytes)
    }

    internal static var export: ExternalAnswerBudget {
        ExternalAnswerBudget(bytes: answerBytes, longValues: .whole)
    }

    internal var remainingBytes: Int {
        max(limitBytes - spentBytes, 0)
    }

    // The leading rows of `result` that fit, each long value cut when values are cut. Once one row does not fit,
    // no later row of this or any later result is kept. `weight` counts a result the answer writes more than once.
    internal mutating func keep(_ result: QueryResult, weight: Int = 1) -> QueryResult {
        guard !result.rows.isEmpty else { return result }
        let nameBytes = result.columns.map { $0.utf8.count + Self.cellBytes }
        var kept: [[PluginCellValue]] = []
        kept.reserveCapacity(result.rows.count)
        var changed = false
        for row in result.rows {
            guard !sizeLimited else {
                changed = true
                break
            }
            var cells = row
            var cut = false
            var size = Self.rowBytes
            for index in cells.indices {
                if longValues == .cut, let shortened = Self.cut(cells[index]) {
                    cells[index] = shortened
                    cut = true
                }
                size += (index < nameBytes.count ? nameBytes[index] : Self.cellBytes) + Self.encodedBytes(cells[index])
            }
            let cost = size.multipliedReportingOverflow(by: max(weight, 1))
            guard !cost.overflow, cost.partialValue <= remainingBytes else {
                sizeLimited = true
                changed = true
                break
            }
            spentBytes += cost.partialValue
            valuesCut = valuesCut || cut
            changed = changed || cut
            kept.append(cells)
        }
        guard changed else { return result }
        return result.keepingLeadingRows(kept, truncated: result.isTruncated || kept.count < result.rows.count)
    }

    internal mutating func keep(text: String) -> String {
        let size = text.utf8.count
        guard size > remainingBytes else {
            spentBytes += size
            return text
        }
        sizeLimited = true
        let kept = Self.cut(text, toBytes: remainingBytes)
        spentBytes = limitBytes
        return kept
    }

    // A part its caller measured, kept only whole. Leaving it out does not stop the parts after it, which may fit.
    internal mutating func keepWhole(bytes: Int) -> Bool {
        guard !sizeLimited, bytes <= remainingBytes else { return false }
        spentBytes += bytes
        return true
    }

    // A source that stopped reading at its own byte limit left rows out too.
    internal mutating func markSizeLimited() {
        sizeLimited = true
    }

    internal var notes: [String] {
        var notes: [String] = []
        if valuesCut {
            notes.append(String(localized: """
                Some values were longer than 64 KB and were cut there; each one cut ends in a mark with its full \
                length. Read such a value in parts with a narrower query.
                """))
        }
        if sizeLimited {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(limitBytes), countStyle: .memory)
            let text = longValues == .whole
                ? String(localized: """
                    The rows reached TablePro's %@ limit for one answer, so an export marked truncated holds only the \
                    rows that fit, and the exports after it may hold none. Export fewer tables, columns or rows per call.
                    """)
                : String(localized: """
                    The rows reached TablePro's %@ limit for one answer, so a result marked truncated holds only the \
                    rows that fit. Ask for fewer columns or rows.
                    """)
            notes.append(String(format: text, limit))
        }
        return notes
    }

    internal static func cut(_ text: String) -> String {
        cut(text, toBytes: valueBytes)
    }

    private static func cut(_ text: String, toBytes limit: Int) -> String {
        let utf8 = text.utf8
        let total = utf8.count
        guard total > limit else { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: max(limit, 0))
        while end > utf8.startIndex, utf8[end] & 0xC0 == 0x80 {
            end = utf8.index(before: end)
        }
        return String(String.UnicodeScalarView(text.unicodeScalars[..<end])) + mark(total)
    }

    // A cut value is sent as text, so binary keeps the base64 the MCP encoding writes.
    private static func cut(_ cell: PluginCellValue) -> PluginCellValue? {
        switch cell {
        case .null:
            return nil
        case .text(let text):
            guard text.utf8.count > valueBytes else { return nil }
            return .text(cut(text))
        case .bytes(let data):
            guard base64Bytes(data.count) > valueBytes else { return nil }
            return .text(data.prefix(valueBytes / 4 * 3).base64EncodedString() + mark(data.count))
        }
    }

    private static func mark(_ total: Int) -> String {
        " [TablePro cut this value: \(total) bytes in all]"
    }

    // Measured without rendering, since rendering is what the limit is there to avoid.
    private static func encodedBytes(_ cell: PluginCellValue) -> Int {
        switch cell {
        case .null: return nullBytes
        case .text(let text): return text.utf8.count
        case .bytes(let data): return base64Bytes(data.count)
        }
    }

    private static func base64Bytes(_ count: Int) -> Int {
        4 * ((count + 2) / 3)
    }
}

extension QueryResult {
    // `rows` is a prefix of this result's rows, so what the driver keeps per row keeps its place.
    func keepingLeadingRows(_ rows: [[PluginCellValue]], truncated: Bool) -> QueryResult {
        var kept = QueryResult(
            columns: columns,
            columnTypes: columnTypes,
            rows: rows,
            rowsAffected: rowsAffected,
            executionTime: executionTime,
            error: error
        )
        kept.timing = timing
        kept.isTruncated = truncated
        kept.statusMessage = statusMessage
        kept.columnMeta = columnMeta
        kept.columnOrigins = columnOrigins
        kept.rowLocators = rowLocators.map { Array($0.prefix(rows.count)) }
        kept.serverOutput = serverOutput
        kept.exportDocuments = exportDocuments.map { Array($0.prefix(rows.count)) }
        kept.absentCells = absentCells.filter { $0.key < rows.count }
        kept.unloadedCells = unloadedCells.filter { $0.key < rows.count }
        return kept
    }
}
