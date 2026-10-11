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

    private static let booleanWords: Set<String> = ["true", "false", "yes", "no", "t", "f", "y", "n"]

    public static func inferKinds(of table: TabularTable) -> [TabularColumnID: TabularInferredKind] {
        var samples: [TabularColumnID: [(TabularCellKind, String)]] = [:]
        let ids = table.columnIDs
        for id in ids {
            samples[id] = []
        }
        var open = Set(ids)
        var row = 0
        let rows = table.rowCount
        while row < rows, !open.isEmpty {
            let end = min(rows, row + 256)
            table.scan(columns: ids, rows: row..<end) { _, cells in
                for (slot, id) in ids.enumerated() where open.contains(id) {
                    let kind = cells.kinds[slot]
                    guard !cells.bytes[slot].isEmpty, !kind.isNullLike else { continue }
                    samples[id, default: []].append((kind, cells.string(at: slot)))
                    if samples[id, default: []].count >= sampleSize {
                        open.remove(id)
                    }
                }
                return !open.isEmpty
            }
            row = end
        }
        var result: [TabularColumnID: TabularInferredKind] = [:]
        for id in ids {
            result[id] = infer(samples[id] ?? [])
        }
        return result
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
