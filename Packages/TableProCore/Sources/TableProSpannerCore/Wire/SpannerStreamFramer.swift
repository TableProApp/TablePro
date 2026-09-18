import Foundation

public struct SpannerStreamFramer: Sendable {
    private enum Byte {
        static let openBrace = UInt8(ascii: "{")
        static let closeBrace = UInt8(ascii: "}")
        static let openBracket = UInt8(ascii: "[")
        static let closeBracket = UInt8(ascii: "]")
        static let comma = UInt8(ascii: ",")
        static let quote = UInt8(ascii: "\"")
        static let backslash = UInt8(ascii: "\\")
        static let colon = UInt8(ascii: ":")
        static let space = UInt8(ascii: " ")
        static let tab = UInt8(ascii: "\t")
        static let newline = UInt8(ascii: "\n")
        static let carriageReturn = UInt8(ascii: "\r")
    }

    private static let resultKey = Array("\"result\"".utf8)

    private var buffer: [UInt8] = []
    private var scanIndex = 0
    private var objectStart = 0
    private var depth = 0
    private var inString = false
    private var escaped = false

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(contentsOf: data)
        var frames: [Data] = []
        while scanIndex < buffer.count {
            let byte = buffer[scanIndex]
            if depth == 0 {
                try scanSeparator(byte)
            } else if let frame = scanObjectByte(byte) {
                frames.append(frame)
            }
            scanIndex += 1
        }
        compact()
        return frames
    }

    public func finish() throws {
        guard depth == 0 else { throw SpannerTransportError.invalidResponse }
    }

    private mutating func scanSeparator(_ byte: UInt8) throws {
        switch byte {
        case Byte.openBrace:
            objectStart = scanIndex
            depth = 1
        case Byte.space, Byte.tab, Byte.newline, Byte.carriageReturn,
             Byte.openBracket, Byte.closeBracket, Byte.comma:
            return
        default:
            throw SpannerTransportError.invalidResponse
        }
    }

    private mutating func scanObjectByte(_ byte: UInt8) -> Data? {
        if inString {
            if escaped {
                escaped = false
            } else if byte == Byte.backslash {
                escaped = true
            } else if byte == Byte.quote {
                inString = false
            }
            return nil
        }
        switch byte {
        case Byte.quote:
            inString = true
        case Byte.openBrace:
            depth += 1
        case Byte.closeBrace:
            depth -= 1
            guard depth == 0 else { return nil }
            return Self.unwrapped(buffer[objectStart...scanIndex])
        default:
            break
        }
        return nil
    }

    private mutating func compact() {
        let keepFrom = depth > 0 ? objectStart : scanIndex
        guard keepFrom > 0 else { return }
        buffer.removeSubrange(0..<keepFrom)
        scanIndex -= keepFrom
        objectStart = max(0, objectStart - keepFrom)
    }

    private static func unwrapped(_ object: ArraySlice<UInt8>) -> Data {
        guard let inner = resultPayloadRange(in: object) else { return Data(object) }
        return Data(object[inner])
    }

    private static func resultPayloadRange(in object: ArraySlice<UInt8>) -> Range<Int>? {
        var index = skipWhitespace(in: object, from: object.startIndex + 1)
        guard object[index...].starts(with: resultKey) else { return nil }
        index = skipWhitespace(in: object, from: index + resultKey.count)
        guard index < object.endIndex, object[index] == Byte.colon else { return nil }
        let innerStart = skipWhitespace(in: object, from: index + 1)
        guard innerStart < object.endIndex, object[innerStart] == Byte.openBrace,
              let innerEnd = matchingBraceEnd(in: object, from: innerStart)
        else {
            return nil
        }
        let closing = skipWhitespace(in: object, from: innerEnd)
        guard closing == object.endIndex - 1, object[closing] == Byte.closeBrace else { return nil }
        return innerStart..<innerEnd
    }

    private static func skipWhitespace(in bytes: ArraySlice<UInt8>, from start: Int) -> Int {
        var index = start
        while index < bytes.endIndex, isWhitespace(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == Byte.space || byte == Byte.tab || byte == Byte.newline || byte == Byte.carriageReturn
    }

    private static func matchingBraceEnd(in bytes: ArraySlice<UInt8>, from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < bytes.endIndex {
            let byte = bytes[index]
            index += 1
            if inString {
                if escaped {
                    escaped = false
                } else if byte == Byte.backslash {
                    escaped = true
                } else if byte == Byte.quote {
                    inString = false
                }
                continue
            }
            if byte == Byte.quote {
                inString = true
            } else if byte == Byte.openBrace {
                depth += 1
            } else if byte == Byte.closeBrace {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }
}
