import Foundation

public struct CSVStreamingParser: Sendable {
    public let dialect: CSVDialect

    public init(dialect: CSVDialect) {
        self.dialect = dialect
    }

    public func indexRows(_ bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let quote = dialect.quoteChar
        let delimiter = dialect.delimiter
        let count = bytes.count
        var i = bomSkip(in: bytes)
        var rowStart = i
        var insideQuotes = false
        var atFieldStart = true

        while i < count {
            let byte = bytes[i]
            if insideQuotes {
                if byte == quote {
                    if i + 1 < count, bytes[i + 1] == quote {
                        i += 2
                        continue
                    }
                    insideQuotes = false
                }
                i += 1
                continue
            }
            if byte == quote, atFieldStart {
                insideQuotes = true
                atFieldStart = false
                i += 1
                continue
            }
            if byte == delimiter {
                atFieldStart = true
                i += 1
                continue
            }
            if byte == 0x0A {
                i += 1
                ranges.append(rowStart..<i)
                rowStart = i
                atFieldStart = true
                continue
            }
            if byte == 0x0D {
                i += 1
                if i < count, bytes[i] == 0x0A { i += 1 }
                ranges.append(rowStart..<i)
                rowStart = i
                atFieldStart = true
                continue
            }
            atFieldStart = false
            i += 1
        }
        if rowStart < count {
            ranges.append(rowStart..<count)
        }
        return ranges
    }

    public func parseRow(_ bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>) -> [String] {
        var fields: [String] = []
        var field: [UInt8] = []
        let quote = dialect.quoteChar
        let delimiter = dialect.delimiter
        var insideQuotes = false
        var i = range.lowerBound
        let end = min(range.upperBound, bytes.count)

        while i < end {
            let byte = bytes[i]
            if insideQuotes {
                if byte == quote {
                    if i + 1 < end, bytes[i + 1] == quote {
                        field.append(quote)
                        i += 2
                        continue
                    }
                    insideQuotes = false
                    i += 1
                    continue
                }
                field.append(byte)
                i += 1
                continue
            }
            if byte == quote, field.isEmpty {
                insideQuotes = true
                i += 1
                continue
            }
            if byte == delimiter {
                fields.append(decode(field))
                field.removeAll(keepingCapacity: true)
                i += 1
                continue
            }
            if byte == 0x0A || byte == 0x0D {
                break
            }
            field.append(byte)
            i += 1
        }
        fields.append(decode(field))
        return fields
    }

    public func field(_ bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>, column: Int) -> String {
        guard column >= 0 else { return "" }
        let quote = dialect.quoteChar
        let delimiter = dialect.delimiter
        var insideQuotes = false
        var i = range.lowerBound
        let end = min(range.upperBound, bytes.count)
        var currentColumn = 0
        var fieldStarted = false
        var field: [UInt8] = []

        while i < end {
            let byte = bytes[i]
            if insideQuotes {
                if byte == quote {
                    if i + 1 < end, bytes[i + 1] == quote {
                        if currentColumn == column { field.append(quote) }
                        i += 2
                        continue
                    }
                    insideQuotes = false
                    i += 1
                    continue
                }
                if currentColumn == column { field.append(byte) }
                i += 1
                continue
            }
            if byte == quote, !fieldStarted {
                insideQuotes = true
                fieldStarted = true
                i += 1
                continue
            }
            if byte == delimiter {
                if currentColumn == column { return decode(field) }
                currentColumn += 1
                fieldStarted = false
                i += 1
                continue
            }
            if byte == 0x0A || byte == 0x0D {
                break
            }
            if currentColumn == column { field.append(byte) }
            fieldStarted = true
            i += 1
        }
        return currentColumn == column ? decode(field) : ""
    }

    private func decode(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "" }
        if let decoded = String(bytes: bytes, encoding: dialect.encoding) {
            return decoded
        }
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }

    private func bomSkip(in bytes: UnsafeBufferPointer<UInt8>) -> Int {
        guard dialect.hasBom else { return 0 }
        switch dialect.encoding {
        case .utf8: return min(3, bytes.count)
        case .utf16BigEndian, .utf16LittleEndian: return min(2, bytes.count)
        default: return 0
        }
    }
}
