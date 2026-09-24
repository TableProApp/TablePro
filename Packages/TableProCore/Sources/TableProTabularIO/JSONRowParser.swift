import Foundation

public struct JSONMember: Sendable, Equatable {
    public let key: String
    public let keyRange: Range<Int>
    public let valueRange: Range<Int>
    public let kind: TabularCellKind

    public init(key: String, keyRange: Range<Int>, valueRange: Range<Int>, kind: TabularCellKind) {
        self.key = key
        self.keyRange = keyRange
        self.valueRange = valueRange
        self.kind = kind
    }
}

public struct JSONObjectLayout: Sendable, Equatable {
    public let range: Range<Int>
    public let members: [JSONMember]

    public init(range: Range<Int>, members: [JSONMember]) {
        self.range = range
        self.members = members
    }

    public func lastMember(forKey key: String) -> JSONMember? {
        members.last { $0.key == key }
    }
}

public enum JSONRowParser {
    public static func parseObject(
        in bytes: UnsafeBufferPointer<UInt8>,
        at start: Int,
        row: Int = 0
    ) throws -> JSONObjectLayout {
        guard let base = bytes.baseAddress else { throw JSONTableError.truncated(row: row, byteOffset: 0) }
        let cursor = JSONCursor(base: base, count: bytes.count, row: row)
        var members: [JSONMember] = []
        let end = try cursor.forEachMember(objectAt: start) { token in
            members.append(
                JSONMember(
                    key: cursor.key(of: token),
                    keyRange: token.keyRange,
                    valueRange: token.valueRange,
                    kind: token.kind
                )
            )
        }
        return JSONObjectLayout(range: start..<end, members: members)
    }

    public static func cell(for member: JSONMember, in bytes: UnsafeBufferPointer<UInt8>) -> TabularCell {
        let value = UnsafeBufferPointer(rebasing: bytes[member.valueRange])
        switch member.kind {
        case .text:
            return TabularCell(kind: .text, text: JSONText.decodedString(UnsafeBufferPointer(rebasing: value.dropFirst().dropLast())))
        case .object, .array:
            var compact: [UInt8] = []
            compact.reserveCapacity(value.count)
            JSONText.appendCompact(value, into: &compact)
            return TabularCell(kind: member.kind, text: compact.withUnsafeBufferPointer(JSONText.lossyString))
        default:
            return TabularCell(kind: member.kind, text: JSONText.lossyString(value))
        }
    }

    public static func validateValue(in bytes: UnsafeBufferPointer<UInt8>, row: Int = 0) throws -> TabularCellKind {
        guard let base = bytes.baseAddress else { throw JSONTableError.truncated(row: row, byteOffset: 0) }
        let cursor = JSONCursor(base: base, count: bytes.count, row: row)
        let start = cursor.skipWhitespace(from: 0)
        let token = try cursor.value(at: start)
        let trailing = cursor.skipWhitespace(from: token.end)
        guard trailing == bytes.count else {
            throw JSONTableError.trailingContent(row: row, byteOffset: trailing)
        }
        return token.kind
    }

    public static func objectEnd(in bytes: UnsafeBufferPointer<UInt8>, at start: Int, row: Int = 0) throws -> Int {
        guard let base = bytes.baseAddress else { throw JSONTableError.truncated(row: row, byteOffset: 0) }
        return try JSONCursor(base: base, count: bytes.count, row: row).forEachMember(objectAt: start) { _ in }
    }
}

internal struct JSONMemberToken {
    let keyRange: Range<Int>
    let keyHasEscapes: Bool
    let valueRange: Range<Int>
    let kind: TabularCellKind
    let valueNeedsRewrite: Bool

    var keyContent: Range<Int> {
        (keyRange.lowerBound + 1)..<(keyRange.upperBound - 1)
    }
}

internal struct JSONKeyToken {
    let end: Int
    let hasEscapes: Bool
    let valueStart: Int
}

internal struct JSONValueToken {
    let end: Int
    let kind: TabularCellKind
    let needsRewrite: Bool
}

internal struct JSONCursor {
    private static let trueWord: UInt32 = 0x6575_7274
    private static let nullWord: UInt32 = 0x6C6C_756E
    private static let falsWord: UInt32 = 0x736C_6166

    let base: UnsafePointer<UInt8>
    let count: Int
    let row: Int

    func key(of token: JSONMemberToken) -> String {
        let content = keyBytes(of: token)
        return token.keyHasEscapes ? JSONText.decodedString(content) : JSONText.lossyString(content)
    }

    func keyBytes(of token: JSONMemberToken) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: base + token.keyContent.lowerBound, count: token.keyContent.count)
    }

    func bytes(_ range: Range<Int>) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: base + range.lowerBound, count: range.count)
    }

    @inline(__always)
    func skipWhitespace(from start: Int) -> Int {
        var index = start
        while index < count, JSONByte.isWhitespace(base[index]) {
            index += 1
        }
        return index
    }

    func forEachMember(objectAt start: Int, _ body: (JSONMemberToken) -> Void) throws -> Int {
        guard start < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
        guard base[start] == JSONByte.openBrace else {
            guard JSONByte.startsValue(base[start]) else {
                throw JSONTableError.unexpectedByte(row: row, byteOffset: start)
            }
            throw JSONTableError.rowIsNotAnObject(row: row, byteOffset: start)
        }
        var index = skipWhitespace(from: start + 1)
        guard index < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
        if base[index] == JSONByte.closeBrace { return index + 1 }
        while true {
            var ignoredWhitespace = false
            let key = try memberKey(at: index, sawWhitespace: &ignoredWhitespace)
            let value = try value(at: key.valueStart)
            body(
                JSONMemberToken(
                    keyRange: index..<key.end,
                    keyHasEscapes: key.hasEscapes,
                    valueRange: key.valueStart..<value.end,
                    kind: value.kind,
                    valueNeedsRewrite: value.needsRewrite
                )
            )
            index = skipWhitespace(from: value.end)
            guard index < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
            if base[index] == JSONByte.closeBrace { return index + 1 }
            guard base[index] == JSONByte.comma else {
                throw JSONTableError.unexpectedByte(row: row, byteOffset: index)
            }
            index = skipWhitespace(from: index + 1)
        }
    }

    func value(at start: Int) throws -> JSONValueToken {
        guard start < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
        switch base[start] {
        case JSONByte.quote:
            let string = try string(at: start)
            return JSONValueToken(end: string.end, kind: .text, needsRewrite: string.hasEscapes)
        case JSONByte.openBrace, JSONByte.openBracket:
            let container = try container(at: start)
            let kind: TabularCellKind = base[start] == JSONByte.openBrace ? .object : .array
            return JSONValueToken(end: container.end, kind: kind, needsRewrite: container.hasWhitespace)
        default:
            return try scalar(at: start)
        }
    }

    func string(at start: Int) throws -> (end: Int, hasEscapes: Bool) {
        var index = start + 1
        var hasEscapes = false
        while index < count {
            if index + 8 <= count {
                let hits = JSONWord.validatingStringStops(JSONWord.load(base, index))
                if hits == 0 {
                    index += 8
                    continue
                }
                index += hits.trailingZeroBitCount >> 3
            }
            let byte = base[index]
            if byte == JSONByte.quote { return (index + 1, hasEscapes) }
            if byte == JSONByte.backslash {
                hasEscapes = true
                index = try escapeEnd(at: index)
                continue
            }
            guard byte >= JSONByte.space else {
                throw JSONTableError.invalidString(row: row, byteOffset: index)
            }
            index += 1
        }
        throw JSONTableError.truncated(row: row, byteOffset: count)
    }

    private func scalar(at start: Int) throws -> JSONValueToken {
        let byte = base[start]
        if byte == JSONByte.minus || JSONByte.isDigit(byte) {
            return JSONValueToken(end: try number(at: start), kind: .number, needsRewrite: false)
        }
        switch byte {
        case JSONByte.letterT:
            return JSONValueToken(end: try literal(at: start, word: Self.trueWord, length: 4), kind: .boolean, needsRewrite: false)
        case JSONByte.letterN:
            return JSONValueToken(end: try literal(at: start, word: Self.nullWord, length: 4), kind: .null, needsRewrite: false)
        case JSONByte.letterF:
            let end = try literal(at: start, word: Self.falsWord, length: 5)
            return JSONValueToken(end: end, kind: .boolean, needsRewrite: false)
        default:
            throw JSONTableError.unexpectedByte(row: row, byteOffset: start)
        }
    }

    private func escapeEnd(at index: Int) throws -> Int {
        guard index + 1 < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
        switch base[index + 1] {
        case JSONByte.quote, JSONByte.backslash, JSONByte.slash,
             JSONByte.letterB, JSONByte.letterF, JSONByte.letterN, JSONByte.letterR, JSONByte.letterT:
            return index + 2
        case JSONByte.letterU:
            guard index + 6 <= count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
            for offset in 2..<6 where JSONText.hexValue(base[index + offset]) == nil {
                throw JSONTableError.invalidEscape(row: row, byteOffset: index)
            }
            return index + 6
        default:
            throw JSONTableError.invalidEscape(row: row, byteOffset: index)
        }
    }

    func number(at start: Int) throws -> Int {
        var index = start
        if base[index] == JSONByte.minus {
            index += 1
        }
        guard index < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
        guard JSONByte.isDigit(base[index]) else { throw JSONTableError.invalidNumber(row: row, byteOffset: start) }
        index = base[index] == JSONByte.zero ? index + 1 : digitsEnd(from: index)
        if index < count, base[index] == JSONByte.dot {
            guard index + 1 < count, JSONByte.isDigit(base[index + 1]) else {
                throw JSONTableError.invalidNumber(row: row, byteOffset: start)
            }
            index = digitsEnd(from: index + 1)
        }
        if index < count, base[index] | 0x20 == JSONByte.letterE {
            index += 1
            if index < count, base[index] == JSONByte.plus || base[index] == JSONByte.minus {
                index += 1
            }
            guard index < count, JSONByte.isDigit(base[index]) else {
                throw JSONTableError.invalidNumber(row: row, byteOffset: start)
            }
            index = digitsEnd(from: index)
        }
        if index < count, continuesToken(base[index]) {
            throw JSONTableError.invalidNumber(row: row, byteOffset: start)
        }
        return index
    }

    @inline(__always)
    private func digitsEnd(from start: Int) -> Int {
        var index = start
        while index < count, JSONByte.isDigit(base[index]) {
            index += 1
        }
        return index
    }

    private func literal(at start: Int, word: UInt32, length: Int) throws -> Int {
        guard start + length <= count else {
            throw JSONTableError.invalidLiteral(row: row, byteOffset: start)
        }
        let loaded = UnsafeRawPointer(base + start).loadUnaligned(as: UInt32.self)
        let matches = loaded == word && (length == 4 || base[start + 4] == JSONByte.letterE)
        let end = start + length
        guard matches, end == count || !continuesToken(base[end]) else {
            throw JSONTableError.invalidLiteral(row: row, byteOffset: start)
        }
        return end
    }

    @inline(__always)
    private func continuesToken(_ byte: UInt8) -> Bool {
        let folded = byte | 0x20
        return JSONByte.isDigit(byte) || (folded >= 0x61 && folded <= 0x7A)
            || byte == JSONByte.dot || byte == JSONByte.plus || byte == JSONByte.minus
    }

    private func memberKey(at start: Int, sawWhitespace: inout Bool) throws -> JSONKeyToken {
        guard start < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
        guard base[start] == JSONByte.quote else {
            throw JSONTableError.unexpectedByte(row: row, byteOffset: start)
        }
        let key = try string(at: start)
        let colon = advance(from: key.end, sawWhitespace: &sawWhitespace)
        guard colon < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
        guard base[colon] == JSONByte.colon else {
            throw JSONTableError.unexpectedByte(row: row, byteOffset: colon)
        }
        let valueStart = advance(from: colon + 1, sawWhitespace: &sawWhitespace)
        return JSONKeyToken(end: key.end, hasEscapes: key.hasEscapes, valueStart: valueStart)
    }

    private func container(at start: Int) throws -> (end: Int, hasWhitespace: Bool) {
        var stack = JSONBracketStack()
        var sawWhitespace = false
        var index = start
        var expectingValue = true
        while true {
            if expectingValue {
                guard index < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
                let byte = base[index]
                guard byte == JSONByte.openBrace || byte == JSONByte.openBracket else {
                    index = try value(at: index).end
                    expectingValue = false
                    continue
                }
                let isArray = byte == JSONByte.openBracket
                stack.push(isArray: isArray)
                index = advance(from: index + 1, sawWhitespace: &sawWhitespace)
                guard index < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
                if base[index] == (isArray ? JSONByte.closeBracket : JSONByte.closeBrace) {
                    _ = stack.pop()
                    index += 1
                    expectingValue = false
                } else if !isArray {
                    index = try memberKey(at: index, sawWhitespace: &sawWhitespace).valueStart
                }
                continue
            }
            if stack.depth == 0 { return (index, sawWhitespace) }
            index = advance(from: index, sawWhitespace: &sawWhitespace)
            guard index < count else { throw JSONTableError.truncated(row: row, byteOffset: count) }
            let byte = base[index]
            if byte == JSONByte.comma {
                index = advance(from: index + 1, sawWhitespace: &sawWhitespace)
                if !stack.topIsArray {
                    index = try memberKey(at: index, sawWhitespace: &sawWhitespace).valueStart
                }
                expectingValue = true
                continue
            }
            let closesArray = byte == JSONByte.closeBracket
            guard closesArray || byte == JSONByte.closeBrace else {
                throw JSONTableError.unexpectedByte(row: row, byteOffset: index)
            }
            guard closesArray == stack.topIsArray else {
                throw JSONTableError.mismatchedBracket(row: row, byteOffset: index)
            }
            _ = stack.pop()
            index += 1
        }
    }

    @inline(__always)
    private func advance(from start: Int, sawWhitespace: inout Bool) -> Int {
        let index = skipWhitespace(from: start)
        if index != start { sawWhitespace = true }
        return index
    }
}
