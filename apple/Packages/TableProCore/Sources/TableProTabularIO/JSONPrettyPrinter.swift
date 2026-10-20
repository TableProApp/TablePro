import Foundation

public enum JSONPrettyPrinter {
    private static let maxLength = 500_000
    // Indentation grows with depth, so deep nesting under the length cap could print gigabytes.
    private static let maxOutputBytes = 8 << 20
    private static let indentWidth = 2

    public static func format(_ text: String) -> String? {
        guard text.utf16.count <= maxLength else { return nil }
        var source = text
        return source.withUTF8 { bytes -> String? in
            guard let base = bytes.baseAddress else { return nil }
            let cursor = JSONCursor(base: base, count: bytes.count, row: 0)
            let start = cursor.skipWhitespace(from: 0)
            guard let token = try? cursor.value(at: start), cursor.skipWhitespace(from: token.end) == bytes.count else {
                return nil
            }
            var output: [UInt8] = []
            output.reserveCapacity(bytes.count + bytes.count / 2)
            guard write(cursor, from: start, to: token.end, into: &output) else { return nil }
            return output.withUnsafeBufferPointer(JSONText.lossyString)
        }
    }

    private static func write(_ cursor: JSONCursor, from start: Int, to end: Int, into output: inout [UInt8]) -> Bool {
        let base = cursor.base
        var depth = 0
        var index = start
        while index < end {
            let byte = base[index]
            switch byte {
            case JSONByte.quote:
                guard let string = try? cursor.string(at: index) else { return false }
                output.append(contentsOf: cursor.bytes(index..<string.end))
                index = string.end
            case JSONByte.openBrace, JSONByte.openBracket:
                let close = byte == JSONByte.openBrace ? JSONByte.closeBrace : JSONByte.closeBracket
                let next = cursor.skipWhitespace(from: index + 1)
                output.append(byte)
                if next < end, base[next] == close {
                    output.append(close)
                    index = next + 1
                } else {
                    depth += 1
                    guard breakLine(depth: depth, into: &output) else { return false }
                    index = next
                }
            case JSONByte.closeBrace, JSONByte.closeBracket:
                depth -= 1
                guard breakLine(depth: depth, into: &output) else { return false }
                output.append(byte)
                index += 1
            case JSONByte.comma:
                output.append(byte)
                guard breakLine(depth: depth, into: &output) else { return false }
                index = cursor.skipWhitespace(from: index + 1)
            case JSONByte.colon:
                output.append(byte)
                output.append(JSONByte.space)
                index = cursor.skipWhitespace(from: index + 1)
            default:
                guard !JSONByte.isWhitespace(byte) else {
                    index += 1
                    continue
                }
                var scalarEnd = index + 1
                while scalarEnd < end, !endsScalar(base[scalarEnd]) {
                    scalarEnd += 1
                }
                output.append(contentsOf: cursor.bytes(index..<scalarEnd))
                index = scalarEnd
            }
        }
        return true
    }

    private static func breakLine(depth: Int, into output: inout [UInt8]) -> Bool {
        let width = depth * indentWidth
        guard output.count + 1 + width <= maxOutputBytes else { return false }
        output.append(JSONByte.lineFeed)
        output.append(contentsOf: repeatElement(JSONByte.space, count: width))
        return true
    }

    @inline(__always)
    private static func endsScalar(_ byte: UInt8) -> Bool {
        byte == JSONByte.comma || byte == JSONByte.closeBrace || byte == JSONByte.closeBracket || JSONByte.isWhitespace(byte)
    }
}
