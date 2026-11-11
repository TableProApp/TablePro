//
//  JSONDocumentReader.swift
//  JSONImportPlugin
//

import Foundation

enum JSONDocumentError: LocalizedError, Equatable {
    case endsEarly
    case unexpectedCharacter(byteOffset: Int)

    var errorDescription: String? {
        switch self {
        case .endsEarly:
            return String(localized: "The JSON file ends before its last value is complete.")
        case .unexpectedCharacter(let byteOffset):
            return String(format: String(localized: "The JSON file is not valid at byte %@."), (byteOffset + 1).formatted())
        }
    }
}

// Walks a UTF-8 JSON file one chunk at a time. It finds where each value starts and ends without
// building it, so the file is held one chunk and one value at a time. `JSONSerialization` parses
// each value a caller asks for, so every value reads exactly as it would in a whole-file parse.
struct JSONDocumentReader {
    static let defaultChunkSize = 1 << 20

    private static let quote: UInt8 = 0x22
    private static let backslash: UInt8 = 0x5C
    private static let comma: UInt8 = 0x2C
    private static let colon: UInt8 = 0x3A
    static let openBracket: UInt8 = 0x5B
    private static let closeBracket: UInt8 = 0x5D
    static let openBrace: UInt8 = 0x7B
    private static let closeBrace: UInt8 = 0x7D

    private let handle: FileHandle
    private let chunkSize: Int
    private let checkCancellation: () throws -> Void
    private var buffer: [UInt8] = []
    private var position = 0
    private var bufferStart = 0
    private var valueStart: Int?
    private var reachedEnd = false

    init(
        url: URL,
        chunkSize: Int = Self.defaultChunkSize,
        checkCancellation: @escaping () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.chunkSize = max(1, chunkSize)
        self.checkCancellation = checkCancellation
    }

    var offset: Int { bufferStart + position }

    var heldByteCount: Int { buffer.count }

    func close() {
        try? handle.close()
    }

    // Steps over a UTF-8 byte order mark. False for UTF-16 or UTF-32 text, which `JSONSerialization`
    // also reads: it has a byte order mark of its own or a zero byte in its first two.
    mutating func startDocument() throws -> Bool {
        while buffer.count - position < 4, try refill() {}
        let head = buffer[position...].prefix(4)
        if head.starts(with: [0xEF, 0xBB, 0xBF]) {
            position += 3
            return true
        }
        if head.starts(with: [0xFE, 0xFF]) || head.starts(with: [0xFF, 0xFE]) {
            return false
        }
        return !head.prefix(2).contains(0)
    }

    mutating func seek(to offset: Int) throws {
        try handle.seek(toOffset: UInt64(offset))
        buffer.removeAll(keepingCapacity: true)
        bufferStart = offset
        position = 0
        valueStart = nil
        reachedEnd = false
    }

    // The next byte that is not JSON whitespace, left unread, or nil at the end of the file.
    mutating func nextSignificantByte() throws -> UInt8? {
        while true {
            while position < buffer.count {
                switch buffer[position] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    position += 1
                default:
                    return buffer[position]
                }
            }
            guard try refill() else { return nil }
        }
    }

    // MARK: - Containers

    mutating func enterArray() throws -> Bool {
        try enter(opening: Self.openBracket, closing: Self.closeBracket)
    }

    mutating func enterObject() throws -> Bool {
        try enter(opening: Self.openBrace, closing: Self.closeBrace)
    }

    mutating func continueArray() throws -> Bool {
        try continueAfterValue(closing: Self.closeBracket)
    }

    mutating func continueObject() throws -> Bool {
        try continueAfterValue(closing: Self.closeBrace)
    }

    mutating func memberName() throws -> String {
        guard let byte = try nextSignificantByte() else { throw JSONDocumentError.endsEarly }
        guard byte == Self.quote else { throw JSONDocumentError.unexpectedCharacter(byteOffset: offset) }
        let start = offset
        let name = try readValue()
        guard let decoded = try JSONSerialization.jsonObject(with: name, options: .fragmentsAllowed) as? String else {
            throw JSONDocumentError.unexpectedCharacter(byteOffset: start)
        }
        try consume(Self.colon)
        return decoded
    }

    mutating func expectEnd() throws {
        guard try nextSignificantByte() == nil else {
            throw JSONDocumentError.unexpectedCharacter(byteOffset: offset)
        }
    }

    // Consumes the opening bracket and tells whether an element or member follows it.
    private mutating func enter(opening: UInt8, closing: UInt8) throws -> Bool {
        try consume(opening)
        guard let next = try nextSignificantByte() else { throw JSONDocumentError.endsEarly }
        guard next == closing else { return true }
        position += 1
        return false
    }

    // Consumes the comma and returns true, or consumes the closing bracket and returns false.
    // `JSONSerialization` takes one comma before a closing bracket, so a file it reads reads here too.
    private mutating func continueAfterValue(closing: UInt8) throws -> Bool {
        guard let byte = try nextSignificantByte() else { throw JSONDocumentError.endsEarly }
        guard byte == Self.comma || byte == closing else {
            throw JSONDocumentError.unexpectedCharacter(byteOffset: offset)
        }
        position += 1
        if byte == closing { return false }
        guard try nextSignificantByte() == closing else { return true }
        position += 1
        return false
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard let byte = try nextSignificantByte() else { throw JSONDocumentError.endsEarly }
        guard byte == expected else { throw JSONDocumentError.unexpectedCharacter(byteOffset: offset) }
        position += 1
    }

    // MARK: - Values

    // The bytes of the next value. They stay in the buffer while it is read, so a value costs its own size and no more.
    mutating func readValue() throws -> Data {
        guard try nextSignificantByte() != nil else { throw JSONDocumentError.endsEarly }
        valueStart = position
        defer { valueStart = nil }
        try passValue()
        guard let start = valueStart else { return Data() }
        return Data(buffer[start..<position])
    }

    mutating func skipValue() throws {
        guard try nextSignificantByte() != nil else { throw JSONDocumentError.endsEarly }
        try passValue()
    }

    private mutating func passValue() throws {
        switch buffer[position] {
        case Self.quote:
            try passString()
        case Self.openBrace, Self.openBracket:
            try passContainer()
        case 0x2D, 0x30...0x39, 0x66, 0x6E, 0x74:
            try passLiteral()
        default:
            throw JSONDocumentError.unexpectedCharacter(byteOffset: offset)
        }
    }

    private mutating func passString() throws {
        position += 1
        var escaped = false
        while true {
            var index = position
            let closed = buffer.withUnsafeBufferPointer { bytes -> Bool in
                while index < bytes.count {
                    let byte = bytes[index]
                    index += 1
                    if escaped {
                        escaped = false
                    } else if byte == Self.backslash {
                        escaped = true
                    } else if byte == Self.quote {
                        return true
                    }
                }
                return false
            }
            position = index
            if closed { return }
            guard try refill() else { throw JSONDocumentError.endsEarly }
        }
    }

    private mutating func passContainer() throws {
        var closers: [UInt8] = []
        var inString = false
        var escaped = false
        while true {
            var index = position
            var mismatched = false
            let closed = buffer.withUnsafeBufferPointer { bytes -> Bool in
                while index < bytes.count {
                    let byte = bytes[index]
                    index += 1
                    if inString {
                        if escaped {
                            escaped = false
                        } else if byte == Self.backslash {
                            escaped = true
                        } else if byte == Self.quote {
                            inString = false
                        }
                        continue
                    }
                    switch byte {
                    case Self.quote:
                        inString = true
                    case Self.openBrace:
                        closers.append(Self.closeBrace)
                    case Self.openBracket:
                        closers.append(Self.closeBracket)
                    case Self.closeBrace, Self.closeBracket:
                        guard closers.last == byte else {
                            mismatched = true
                            return true
                        }
                        closers.removeLast()
                        if closers.isEmpty { return true }
                    default:
                        break
                    }
                }
                return false
            }
            position = index
            if mismatched { throw JSONDocumentError.unexpectedCharacter(byteOffset: offset - 1) }
            if closed { return }
            guard try refill() else { throw JSONDocumentError.endsEarly }
        }
    }

    // A number, `true`, `false` or `null` runs to the next delimiter. `JSONSerialization` checks its spelling.
    private mutating func passLiteral() throws {
        while true {
            while position < buffer.count {
                switch buffer[position] {
                case 0x20, 0x09, 0x0A, 0x0D, Self.comma, Self.colon, Self.quote,
                     Self.openBracket, Self.closeBracket, Self.openBrace, Self.closeBrace:
                    return
                default:
                    position += 1
                }
            }
            guard try refill() else { return }
        }
    }

    // MARK: - Buffer

    // Drops what was read before the value in progress, then appends the next chunk.
    private mutating func refill() throws -> Bool {
        guard !reachedEnd else { return false }
        try checkCancellation()
        let keep = valueStart ?? position
        if keep > 0 {
            buffer.removeSubrange(0..<keep)
            bufferStart += keep
            position -= keep
            valueStart = valueStart.map { $0 - keep }
        }
        let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) } ?? Data()
        guard !chunk.isEmpty else {
            reachedEnd = true
            return false
        }
        buffer.append(contentsOf: chunk)
        return true
    }
}
