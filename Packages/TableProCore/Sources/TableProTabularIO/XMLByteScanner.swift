import Foundation

struct XMLByteScanner {
    enum Token: Equatable {
        case startTag(name: Range<Int>, attributes: Range<Int>, isSelfClosing: Bool)
        case endTag(name: Range<Int>)
        case text(Range<Int>)
        case characterData(Range<Int>)
        case markup
        case incomplete
        case end
    }

    private static let lessThan: UInt8 = 0x3C
    private static let greaterThan: UInt8 = 0x3E
    private static let slash: UInt8 = 0x2F
    private static let question: UInt8 = 0x3F
    private static let exclamation: UInt8 = 0x21
    private static let colon: UInt8 = 0x3A
    private static let equals: UInt8 = 0x3D
    private static let doubleQuote: UInt8 = 0x22
    private static let singleQuote: UInt8 = 0x27
    private static let openBracket: UInt8 = 0x5B
    private static let closeBracket: UInt8 = 0x5D
    private static let hyphen: UInt8 = 0x2D

    let bytes: UnsafeBufferPointer<UInt8>
    let isFinal: Bool
    var position: Int

    init(bytes: UnsafeBufferPointer<UInt8>, isFinal: Bool, position: Int = 0) {
        self.bytes = bytes
        self.isFinal = isFinal
        self.position = position
    }

    mutating func next() -> Token {
        let count = bytes.count
        guard position < count else { return isFinal ? .end : .incomplete }
        guard bytes[position] == Self.lessThan else { return nextText() }
        guard position + 1 < count else { return isFinal ? .end : .incomplete }
        switch bytes[position + 1] {
        case Self.slash:
            return nextEndTag()
        case Self.question:
            return skipProcessingInstruction()
        case Self.exclamation:
            return nextDeclaration()
        default:
            return nextStartTag()
        }
    }

    mutating func skipElement(named name: Range<Int>) -> Bool {
        let target = localName(of: name)
        var depth = 1
        while true {
            switch next() {
            case .startTag(let child, _, let isSelfClosing):
                if !isSelfClosing, sameBytes(localName(of: child), target) { depth += 1 }
            case .endTag(let child):
                if sameBytes(localName(of: child), target) {
                    depth -= 1
                    if depth == 0 { return true }
                }
            case .incomplete, .end:
                return false
            case .text, .characterData, .markup:
                continue
            }
        }
    }

    func localName(of name: Range<Int>) -> Range<Int> {
        var index = name.upperBound
        while index > name.lowerBound {
            if bytes[index - 1] == Self.colon { return index..<name.upperBound }
            index -= 1
        }
        return name
    }

    func hasPrefix(_ name: Range<Int>) -> Bool {
        localName(of: name).lowerBound != name.lowerBound
    }

    func isNamed(_ name: Range<Int>, _ literal: StaticString) -> Bool {
        matches(localName(of: name), literal)
    }

    func matches(_ range: Range<Int>, _ literal: StaticString) -> Bool {
        let length = literal.utf8CodeUnitCount
        guard range.count == length else { return false }
        let expected = literal.utf8Start
        var offset = 0
        while offset < length {
            if bytes[range.lowerBound + offset] != expected[offset] { return false }
            offset += 1
        }
        return true
    }

    func sameBytes(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var offset = 0
        while offset < lhs.count {
            if bytes[lhs.lowerBound + offset] != bytes[rhs.lowerBound + offset] { return false }
            offset += 1
        }
        return true
    }

    func forEachAttribute(in range: Range<Int>, _ body: (_ name: Range<Int>, _ value: Range<Int>) -> Void) {
        var index = range.lowerBound
        let end = range.upperBound
        while index < end {
            while index < end, Self.isWhitespace(bytes[index]) { index += 1 }
            let nameStart = index
            while index < end, bytes[index] != Self.equals, !Self.isWhitespace(bytes[index]) { index += 1 }
            let nameEnd = index
            while index < end, bytes[index] != Self.equals { index += 1 }
            index += 1
            while index < end, Self.isWhitespace(bytes[index]) { index += 1 }
            guard index < end else { return }
            let quote = bytes[index]
            guard quote == Self.doubleQuote || quote == Self.singleQuote else { return }
            let valueStart = index + 1
            var valueEnd = valueStart
            while valueEnd < end, bytes[valueEnd] != quote { valueEnd += 1 }
            if nameEnd > nameStart {
                body(nameStart..<nameEnd, valueStart..<valueEnd)
            }
            index = valueEnd + 1
        }
    }

    func attribute(_ literal: StaticString, in range: Range<Int>) -> Range<Int>? {
        var found: Range<Int>?
        forEachAttribute(in: range) { name, value in
            if found == nil, matches(name, literal) { found = value }
        }
        return found
    }

    func prefixedAttribute(_ local: StaticString, in range: Range<Int>) -> Range<Int>? {
        var found: Range<Int>?
        forEachAttribute(in: range) { name, value in
            if found == nil, hasPrefix(name), isNamed(name, local) { found = value }
        }
        return found
    }

    func string(_ range: Range<Int>) -> String {
        var decoded: [UInt8] = []
        XMLTextDecoder.append(bytes, range, to: &decoded, unescapingOOXML: false)
        return decoded.withUnsafeBufferPointer { TabularTextCodec.string(from: $0, encoding: .utf8) }
    }

    func integer(_ range: Range<Int>) -> Int? {
        var index = range.lowerBound
        while index < range.upperBound, Self.isWhitespace(bytes[index]) { index += 1 }
        var value = 0
        var digits = 0
        while index < range.upperBound, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            guard digits < 18 else { return nil }
            value = value * 10 + Int(bytes[index] - 0x30)
            digits += 1
            index += 1
        }
        return digits > 0 ? value : nil
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func find(_ byte: UInt8, from start: Int) -> Int? {
        guard let base = bytes.baseAddress, start < bytes.count else { return nil }
        guard let hit = memchr(base + start, Int32(byte), bytes.count - start) else { return nil }
        return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
    }

    private mutating func nextText() -> Token {
        let start = position
        guard let stop = find(Self.lessThan, from: start) else {
            guard isFinal else { return .incomplete }
            position = bytes.count
            return .text(start..<bytes.count)
        }
        position = stop
        return .text(start..<stop)
    }

    private mutating func nextEndTag() -> Token {
        guard let close = find(Self.greaterThan, from: position + 2) else { return .incomplete }
        var nameEnd = close
        while nameEnd > position + 2, Self.isWhitespace(bytes[nameEnd - 1]) { nameEnd -= 1 }
        let name = (position + 2)..<nameEnd
        position = close + 1
        return .endTag(name: name)
    }

    private mutating func nextStartTag() -> Token {
        let nameStart = position + 1
        var index = nameStart
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            if Self.isWhitespace(byte) || byte == Self.slash || byte == Self.greaterThan { break }
            index += 1
        }
        let nameEnd = index
        while index < count {
            let byte = bytes[index]
            if byte == Self.greaterThan { break }
            if byte == Self.doubleQuote || byte == Self.singleQuote {
                guard let closing = find(byte, from: index + 1) else { return .incomplete }
                index = closing + 1
                continue
            }
            index += 1
        }
        guard index < count else { return .incomplete }
        let isSelfClosing = index > nameEnd && bytes[index - 1] == Self.slash
        let attributes = nameEnd..<(isSelfClosing ? index - 1 : index)
        position = index + 1
        return .startTag(name: nameStart..<nameEnd, attributes: attributes, isSelfClosing: isSelfClosing)
    }

    private mutating func skipProcessingInstruction() -> Token {
        var search = position + 2
        while let close = find(Self.greaterThan, from: search) {
            if bytes[close - 1] == Self.question {
                position = close + 1
                return .markup
            }
            search = close + 1
        }
        return .incomplete
    }

    private mutating func nextDeclaration() -> Token {
        if startsWith("<!--") {
            guard let close = locate("-->", from: position + 4) else { return .incomplete }
            position = close + 3
            return .markup
        }
        if startsWith("<![CDATA[") {
            let contentStart = position + 9
            guard let close = locate("]]>", from: contentStart) else { return .incomplete }
            position = close + 3
            return .characterData(contentStart..<close)
        }
        if position + 9 > bytes.count, !isFinal {
            return .incomplete
        }
        return skipDocumentType()
    }

    private mutating func skipDocumentType() -> Token {
        var index = position + 2
        var bracketDepth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == Self.openBracket {
                bracketDepth += 1
            } else if byte == Self.closeBracket {
                bracketDepth -= 1
            } else if byte == Self.greaterThan, bracketDepth <= 0 {
                position = index + 1
                return .markup
            }
            index += 1
        }
        return .incomplete
    }

    private func startsWith(_ literal: StaticString) -> Bool {
        let length = literal.utf8CodeUnitCount
        guard position + length <= bytes.count else { return false }
        return matches(position..<(position + length), literal)
    }

    private func locate(_ literal: StaticString, from start: Int) -> Int? {
        let length = literal.utf8CodeUnitCount
        let first = literal.utf8Start[0]
        var search = start
        while let hit = find(first, from: search) {
            guard hit + length <= bytes.count else { return nil }
            if matches(hit..<(hit + length), literal) { return hit }
            search = hit + 1
        }
        return nil
    }
}
