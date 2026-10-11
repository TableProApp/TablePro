import Foundation

public struct XLSXCellReference: Sendable, Hashable {
    public static let maximumRowCount = 1_048_576
    public static let maximumColumnCount = 16_384

    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public init?(_ text: String) {
        var copy = text
        let parsed = copy.withUTF8 { Self.parse($0, 0..<$0.count) }
        guard let parsed, let row = parsed.row else { return nil }
        self.init(row: row, column: parsed.column)
    }

    public var text: String {
        "\(Self.columnName(column))\(row + 1)"
    }

    public static func columnName(_ column: Int) -> String {
        var letters: [Character] = []
        var remaining = max(0, column)
        repeat {
            letters.append(Character(Unicode.Scalar(UInt8(65 + remaining % 26))))
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return String(letters.reversed())
    }

    static func parse(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> (row: Int?, column: Int)? {
        var index = range.lowerBound
        let end = range.upperBound
        if index < end, bytes[index] == 0x24 { index += 1 }
        var column = 0
        var letters = 0
        while index < end {
            let byte = bytes[index] & 0xDF
            guard byte >= 0x41, byte <= 0x5A else { break }
            column = column * 26 + Int(byte - 0x40)
            letters += 1
            guard letters <= 3 else { return nil }
            index += 1
        }
        guard letters > 0, column <= maximumColumnCount else { return nil }
        if index < end, bytes[index] == 0x24 { index += 1 }
        var row = 0
        var digits = 0
        while index < end, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            row = row * 10 + Int(bytes[index] - 0x30)
            digits += 1
            guard digits <= 7 else { return nil }
            index += 1
        }
        guard index == end else { return nil }
        guard digits > 0 else { return (nil, column - 1) }
        guard row >= 1, row <= maximumRowCount else { return nil }
        return (row - 1, column - 1)
    }
}

public struct XLSXCellRange: Sendable, Hashable {
    public let start: XLSXCellReference
    public let end: XLSXCellReference

    public init(start: XLSXCellReference, end: XLSXCellReference) {
        self.start = XLSXCellReference(row: min(start.row, end.row), column: min(start.column, end.column))
        self.end = XLSXCellReference(row: max(start.row, end.row), column: max(start.column, end.column))
    }

    public init?(_ text: String) {
        var copy = text
        guard let range = copy.withUTF8({ Self.parse($0, 0..<$0.count) }) else { return nil }
        self = range
    }

    public var rows: ClosedRange<Int> { start.row...end.row }
    public var columns: ClosedRange<Int> { start.column...end.column }

    public func contains(_ reference: XLSXCellReference) -> Bool {
        rows.contains(reference.row) && columns.contains(reference.column)
    }

    static func parse(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> XLSXCellRange? {
        var separator = range.lowerBound
        while separator < range.upperBound, bytes[separator] != 0x3A { separator += 1 }
        guard let first = XLSXCellReference.parse(bytes, range.lowerBound..<separator), let firstRow = first.row else {
            return nil
        }
        let start = XLSXCellReference(row: firstRow, column: first.column)
        guard separator < range.upperBound else { return XLSXCellRange(start: start, end: start) }
        guard let second = XLSXCellReference.parse(bytes, (separator + 1)..<range.upperBound), let secondRow = second.row else {
            return nil
        }
        return XLSXCellRange(start: start, end: XLSXCellReference(row: secondRow, column: second.column))
    }
}
