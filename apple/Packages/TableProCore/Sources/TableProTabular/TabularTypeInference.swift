import Foundation
import TableProTabularIO

public enum TabularInferredKind: String, Sendable, Equatable, CaseIterable {
    case text
    case integer
    case decimal
    case boolean
    case date

    public var valueKind: TabularValueKind {
        switch self {
        case .integer, .decimal: return .numeric
        case .boolean: return .boolean
        case .text, .date: return .text
        }
    }

    public var sortsNumerically: Bool {
        self == .integer || self == .decimal
    }
}

public enum TabularTypeInference {
    public static let sampleSize = 200
    // Columns still short of a full sample when this many cells have been read are typed from what they have.
    public static let cellBudget = 10_000_000

    private static let booleanWords: Set<String> = ["true", "false", "yes", "no", "t", "f", "y", "n"]

    public static func inferKinds(
        of table: TabularTable,
        cellBudget: Int = TabularTypeInference.cellBudget
    ) throws -> [TabularColumnID: TabularInferredKind] {
        var samples: [TabularColumnID: [(TabularCellKind, String)]] = [:]
        var open = table.columnIDs
        var row = 0
        var budget = cellBudget
        while row < table.rowCount, !open.isEmpty, budget >= open.count {
            let pass = try samplePass(table, columns: open, from: row, budget: budget, into: &samples)
            guard pass.rows > 0 else { break }
            row += pass.rows
            budget -= pass.rows * open.count
            open = pass.open
        }
        var result: [TabularColumnID: TabularInferredKind] = [:]
        for id in table.columnIDs {
            result[id] = infer(samples[id] ?? [])
        }
        return result
    }

    // A pass ends once half its columns have a full sample, so the next scan plan is built for the rest only.
    private static func samplePass(
        _ table: TabularTable,
        columns: [TabularColumnID],
        from start: Int,
        budget: Int,
        into samples: inout [TabularColumnID: [(TabularCellKind, String)]]
    ) throws -> (rows: Int, open: [TabularColumnID]) {
        var isOpen = [Bool](repeating: true, count: columns.count)
        var openCount = columns.count
        var visited = 0
        var cellsSinceCheck = 0
        var cancelled = false
        let end = start + min(table.rowCount - start, budget / columns.count)
        table.scan(columns: columns, rows: start..<end) { _, cells in
            visited += 1
            for slot in columns.indices where isOpen[slot] {
                let kind = cells.kinds[slot]
                guard !cells.bytes[slot].isEmpty, !kind.isNullLike else { continue }
                samples[columns[slot], default: []].append((kind, cells.string(at: slot)))
                if samples[columns[slot], default: []].count >= sampleSize {
                    isOpen[slot] = false
                    openCount -= 1
                }
            }
            cellsSinceCheck += columns.count
            if cellsSinceCheck >= TabularScanEngine.cancellationStride {
                cellsSinceCheck = 0
                if Task.isCancelled {
                    cancelled = true
                    return false
                }
            }
            return openCount * 2 > columns.count
        }
        if cancelled { throw CancellationError() }
        return (visited, columns.indices.filter { isOpen[$0] }.map { columns[$0] })
    }

    public static func infer(_ sample: [(TabularCellKind, String)]) -> TabularInferredKind {
        guard !sample.isEmpty else { return .text }
        if sample.allSatisfy({ $0.0 == .number }) {
            return sample.allSatisfy({ isInteger($0.1) }) ? .integer : .decimal
        }
        if sample.allSatisfy({ $0.0 == .boolean }) { return .boolean }
        if sample.allSatisfy({ $0.0 == .date }) { return .date }
        let texts = sample.map(\.1)
        if texts.allSatisfy(isInteger), !texts.contains(where: hasRedundantLeadingZero) { return .integer }
        if texts.allSatisfy(isDecimal), !texts.contains(where: hasRedundantLeadingZero) { return .decimal }
        if texts.allSatisfy({ booleanWords.contains($0.lowercased()) }) { return .boolean }
        if texts.allSatisfy(isISODate) { return .date }
        return .text
    }

    private static func isInteger(_ text: String) -> Bool {
        TabularNumberGrammar.shape(of: text)?.isInteger ?? false
    }

    private static func isDecimal(_ text: String) -> Bool {
        TabularNumberGrammar.shape(of: text) != nil
    }

    private static func hasRedundantLeadingZero(_ text: String) -> Bool {
        TabularNumberGrammar.shape(of: text)?.hasRedundantLeadingZero ?? false
    }

    public static func isISODate(_ text: String) -> Bool {
        let utf8 = Array(text.utf8)
        guard utf8.count >= 10, isDigits(utf8, 0..<4), utf8[4] == 0x2D, isDigits(utf8, 5..<7), utf8[7] == 0x2D,
              isDigits(utf8, 8..<10) else { return false }
        guard let month = Int(TabularTextCodec.utf8String(utf8[5..<7])),
              let day = Int(TabularTextCodec.utf8String(utf8[8..<10])),
              (1...12).contains(month), (1...31).contains(day) else { return false }
        guard utf8.count > 10 else { return true }
        guard utf8[10] == 0x54 || utf8[10] == 0x20, utf8.count >= 16, isDigits(utf8, 11..<13), utf8[13] == 0x3A,
              isDigits(utf8, 14..<16) else { return false }
        return true
    }

    private static func isDigits(_ bytes: [UInt8], _ range: Range<Int>) -> Bool {
        range.allSatisfy { TabularValueGrammar.isDigit(bytes[$0]) }
    }
}
