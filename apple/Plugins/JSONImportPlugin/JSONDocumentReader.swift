//
//  JSONDocumentReader.swift
//  JSONImportPlugin
//

import Foundation

enum JSONDocumentError: LocalizedError, Equatable {
    case endsEarly
    case unexpectedCharacter(byteOffset: Int)
    case invalidText

    var errorDescription: String? {
        switch self {
        case .endsEarly:
            return String(localized: "The JSON file ends before its last value is complete.")
        case .unexpectedCharacter(let byteOffset):
            return String(format: String(localized: "The JSON file is not valid at byte %@."), (byteOffset + 1).formatted())
        case .invalidText:
            return String(localized: "The JSON file has text that is not valid in its encoding.")
        }
    }
}

// Walks a JSON file one chunk at a time. It finds where each value starts and ends without
// building it, so the file is held one chunk and one value at a time. `JSONSerialization` parses
// each value a caller asks for, so every value reads exactly as it would in a whole-file parse.
// UTF-16 and UTF-32 text is turned into UTF-8 as it is read, so `offset` counts UTF-8 bytes and
// `fileOffset` the file's own.
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
    private var decoder: JSONTextDecoder?
    // Where the text starts in the file, past any byte order mark, and how many of its code units
    // the buffer has already dropped. Only a decoded file uses them.
    private var textStart = 0
    private var droppedUnits = 0

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

    var fileOffset: Int { fileOffset(atBufferIndex: position) }

    var heldByteCount: Int { buffer.count }

    func close() {
        try? handle.close()
    }

    // Steps over a byte order mark and, for UTF-16 or UTF-32 text, decodes what was read so far.
    mutating func startDocument() throws {
        while buffer.count - position < 4, try refill() {}
        let detected = JSONTextEncoding.detect(buffer[position...])
        guard detected.encoding != .utf8 else {
            position += detected.markLength
            return
        }
        var decoder = JSONTextDecoder(encoding: detected.encoding)
        textStart = bufferStart + position + detected.markLength
        let raw = Data(buffer[(position + detected.markLength)...])
        buffer = try decoder.utf8(from: raw)
        if reachedEnd { try decoder.finish() }
        self.decoder = decoder
        bufferStart = 0
        position = 0
        droppedUnits = 0
    }

    // `offset` is one `self.offset` gave. Decoded text has no file position for it, so the text is
    // decoded again from its start up to there.
    mutating func seek(to offset: Int) throws {
        buffer.removeAll(keepingCapacity: true)
        position = 0
        valueStart = nil
        reachedEnd = false
        guard decoder != nil else {
            try handle.seek(toOffset: UInt64(offset))
            bufferStart = offset
            return
        }
        try handle.seek(toOffset: UInt64(textStart))
        decoder?.reset()
        bufferStart = 0
        droppedUnits = 0
        while bufferStart + buffer.count < offset {
            position = buffer.count
            guard try refill() else { throw JSONDocumentError.endsEarly }
        }
        position = offset - bufferStart
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
        guard byte == Self.quote else { throw JSONDocumentError.unexpectedCharacter(byteOffset: fileOffset) }
        let name = try readValue()
        guard let decoded = try JSONSerialization.jsonObject(with: name, options: .fragmentsAllowed) as? String else {
            throw JSONDocumentError.unexpectedCharacter(byteOffset: fileOffset(atBufferIndex: position - name.count))
        }
        try consume(Self.colon)
        return decoded
    }

    mutating func expectEnd() throws {
        guard try nextSignificantByte() == nil else {
            throw JSONDocumentError.unexpectedCharacter(byteOffset: fileOffset)
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
            throw JSONDocumentError.unexpectedCharacter(byteOffset: fileOffset)
        }
        position += 1
        if byte == closing { return false }
        guard try nextSignificantByte() == closing else { return true }
        position += 1
        return false
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard let byte = try nextSignificantByte() else { throw JSONDocumentError.endsEarly }
        guard byte == expected else { throw JSONDocumentError.unexpectedCharacter(byteOffset: fileOffset) }
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
            throw JSONDocumentError.unexpectedCharacter(byteOffset: fileOffset)
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
            if mismatched { throw JSONDocumentError.unexpectedCharacter(byteOffset: fileOffset(atBufferIndex: position - 1)) }
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
            if decoder != nil {
                droppedUnits += codeUnits(in: buffer[0..<keep])
            }
            buffer.removeSubrange(0..<keep)
            bufferStart += keep
            position -= keep
            valueStart = valueStart.map { $0 - keep }
        }
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) } ?? Data()
            guard !chunk.isEmpty else {
                reachedEnd = true
                try decoder?.finish()
                return false
            }
            guard decoder != nil else {
                buffer.append(contentsOf: chunk)
                return true
            }
            let decoded = try decoder?.utf8(from: chunk) ?? []
            // A chunk that ends inside a character can decode to nothing yet.
            guard !decoded.isEmpty else { continue }
            buffer.append(contentsOf: decoded)
            return true
        }
    }

    private func fileOffset(atBufferIndex index: Int) -> Int {
        guard let decoder else { return bufferStart + index }
        let units = droppedUnits + codeUnits(in: buffer[0..<max(0, min(index, buffer.count))])
        return textStart + units * decoder.encoding.unitWidth
    }

    // How many code units of the file's encoding these UTF-8 bytes were: one per character, and two
    // in UTF-16 for one outside the Basic Multilingual Plane, whose UTF-8 form takes four bytes.
    private func codeUnits(in bytes: ArraySlice<UInt8>) -> Int {
        let countsPairs = decoder?.encoding.unitWidth == 2
        var units = 0
        for byte in bytes where byte & 0xC0 != 0x80 {
            units += countsPairs && byte >= 0xF0 ? 2 : 1
        }
        return units
    }
}
