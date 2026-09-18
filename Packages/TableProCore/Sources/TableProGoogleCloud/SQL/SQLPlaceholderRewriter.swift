import Foundation

public enum SQLPlaceholderLexicon: Sendable {
    case googleSQL
    case postgreSQL
}

public enum SQLPlaceholderRewriteError: Error, Sendable, Equatable {
    case countMismatch(found: Int, expected: Int)
}

public enum SQLPlaceholderRewriter {
    public static func rewrite(
        _ sql: String,
        lexicon: SQLPlaceholderLexicon,
        expectedCount: Int?,
        placeholder: (Int) -> String
    ) throws -> (sql: String, count: Int) {
        var scanner = SQLPlaceholderScanner(units: Array(sql.utf16), lexicon: lexicon)
        let offsets = scanner.placeholderOffsets()
        if let expectedCount, expectedCount != offsets.count {
            throw SQLPlaceholderRewriteError.countMismatch(found: offsets.count, expected: expectedCount)
        }
        guard !offsets.isEmpty else { return (sql, 0) }
        return (replacing(offsets, in: scanner.units, with: placeholder), offsets.count)
    }

    private static func replacing(_ offsets: [Int], in units: [UInt16], with placeholder: (Int) -> String) -> String {
        var output: [UInt16] = []
        output.reserveCapacity(units.count + offsets.count * 4)
        var copiedUpTo = 0
        for (position, offset) in offsets.enumerated() {
            output.append(contentsOf: units[copiedUpTo..<offset])
            output.append(contentsOf: placeholder(position + 1).utf16)
            copiedUpTo = offset + 1
        }
        output.append(contentsOf: units[copiedUpTo...])
        return String(decoding: output, as: UTF16.self)
    }
}
