import Foundation

internal enum JSONByte {
    static let quote: UInt8 = 0x22
    static let backslash: UInt8 = 0x5C
    static let slash: UInt8 = 0x2F
    static let openBrace: UInt8 = 0x7B
    static let closeBrace: UInt8 = 0x7D
    static let openBracket: UInt8 = 0x5B
    static let closeBracket: UInt8 = 0x5D
    static let comma: UInt8 = 0x2C
    static let colon: UInt8 = 0x3A
    static let lineFeed: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let tab: UInt8 = 0x09
    static let minus: UInt8 = 0x2D
    static let plus: UInt8 = 0x2B
    static let dot: UInt8 = 0x2E
    static let zero: UInt8 = 0x30
    static let nine: UInt8 = 0x39
    static let letterB: UInt8 = 0x62
    static let letterE: UInt8 = 0x65
    static let letterF: UInt8 = 0x66
    static let letterN: UInt8 = 0x6E
    static let letterR: UInt8 = 0x72
    static let letterT: UInt8 = 0x74
    static let letterU: UInt8 = 0x75
    static let backspace: UInt8 = 0x08
    static let formFeed: UInt8 = 0x0C

    static let utf8ByteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
    static let utf16ByteOrderMarks: [[UInt8]] = [[0xFF, 0xFE], [0xFE, 0xFF]]

    @inline(__always)
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == lineFeed || byte == carriageReturn || byte == tab
    }

    @inline(__always)
    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= zero && byte <= nine
    }

    @inline(__always)
    static func isLineBreak(_ byte: UInt8) -> Bool {
        byte == lineFeed || byte == carriageReturn
    }

    static func startsValue(_ byte: UInt8) -> Bool {
        switch byte {
        case quote, openBracket, openBrace, minus, zero...nine, letterT, letterF, letterN:
            return true
        default:
            return false
        }
    }
}

internal enum JSONWord {
    static let ones: UInt64 = 0x0101_0101_0101_0101
    static let highBits: UInt64 = 0x8080_8080_8080_8080
    static let quotes: UInt64 = 0x2222_2222_2222_2222
    static let backslashes: UInt64 = 0x5C5C_5C5C_5C5C_5C5C
    static let spaces: UInt64 = 0x2020_2020_2020_2020
    static let openers: UInt64 = 0x7B7B_7B7B_7B7B_7B7B
    static let closers: UInt64 = 0x7D7D_7D7D_7D7D_7D7D
    static let colons: UInt64 = 0x3A3A_3A3A_3A3A_3A3A
    static let lowSevenBits: UInt64 = 0x7F7F_7F7F_7F7F_7F7F

    @inline(__always)
    static func load(_ base: UnsafePointer<UInt8>, _ offset: Int) -> UInt64 {
        UnsafeRawPointer(base + offset).loadUnaligned(as: UInt64.self)
    }

    @inline(__always)
    static func zeroBytes(_ word: UInt64) -> UInt64 {
        (word &- ones) & ~word & highBits
    }

    @inline(__always)
    static func exactZeroBytes(_ word: UInt64) -> UInt64 {
        ~(((word & lowSevenBits) &+ lowSevenBits) | word) & highBits
    }

    @inline(__always)
    static func bytesBelowSpace(_ word: UInt64) -> UInt64 {
        (word &- spaces) & ~word & highBits
    }

    @inline(__always)
    static func validatingStringStops(_ word: UInt64) -> UInt64 {
        zeroBytes(word ^ quotes) | zeroBytes(word ^ backslashes) | bytesBelowSpace(word)
    }

    @inline(__always)
    static func gatherHighBits(_ word: UInt64) -> UInt64 {
        ((word >> 7) &* 0x0102_0408_1020_4080) >> 56
    }

    @inline(__always)
    static func equal(_ lhs: UnsafePointer<UInt8>, _ rhs: UnsafePointer<UInt8>, count: Int) -> Bool {
        var offset = 0
        while offset + 8 <= count {
            if load(lhs, offset) != load(rhs, offset) { return false }
            offset += 8
        }
        while offset < count {
            if lhs[offset] != rhs[offset] { return false }
            offset += 1
        }
        return true
    }
}

internal struct JSONBracketStack {
    private var bits: UInt64 = 0
    private var spill: [UInt64] = []
    private(set) var depth = 0

    mutating func reset() {
        bits = 0
        depth = 0
        spill.removeAll(keepingCapacity: true)
    }

    @inline(__always)
    mutating func push(isArray: Bool) {
        if depth > 0, depth & 63 == 0 {
            spill.append(bits)
            bits = 0
        }
        bits = (bits << 1) | (isArray ? 1 : 0)
        depth += 1
    }

    @inline(__always)
    mutating func pop() -> Bool {
        let isArray = bits & 1 == 1
        bits >>= 1
        depth -= 1
        if depth > 0, depth & 63 == 0, let restored = spill.popLast() {
            bits = restored
        }
        return isArray
    }

    var topIsArray: Bool {
        bits & 1 == 1
    }
}

internal struct JSONBlockMasks {
    static let width = 64
    static let empty = JSONBlockMasks(quote: 0, backslash: 0, structural: 0)

    let quote: UInt64
    let backslash: UInt64
    let structural: UInt64

    private init(quote: UInt64, backslash: UInt64, structural: UInt64) {
        self.quote = quote
        self.backslash = backslash
        self.structural = structural
    }

    @inline(__always)
    init(_ pointer: UnsafePointer<UInt8>) {
        var quote: UInt64 = 0
        var backslash: UInt64 = 0
        var structural: UInt64 = 0
        for word in 0..<8 {
            let value = JSONWord.load(pointer, word * 8)
            let folded = value | JSONWord.spaces
            let shift = UInt64(word * 8)
            quote |= JSONWord.gatherHighBits(JSONWord.exactZeroBytes(value ^ JSONWord.quotes)) << shift
            backslash |= JSONWord.gatherHighBits(JSONWord.exactZeroBytes(value ^ JSONWord.backslashes)) << shift
            let brackets = JSONWord.exactZeroBytes(folded ^ JSONWord.openers)
                | JSONWord.exactZeroBytes(folded ^ JSONWord.closers)
                | JSONWord.exactZeroBytes(value ^ JSONWord.colons)
            structural |= JSONWord.gatherHighBits(brackets) << shift
        }
        self.quote = quote
        self.backslash = backslash
        self.structural = structural
    }

    @inline(__always)
    static func prefixXor(_ value: UInt64) -> UInt64 {
        var result = value
        result ^= result << 1
        result ^= result << 2
        result ^= result << 4
        result ^= result << 8
        result ^= result << 16
        result ^= result << 32
        return result
    }

    @inline(__always)
    static func bits(below bit: Int) -> UInt64 {
        (1 << UInt64(bit)) &- 1
    }
}

internal struct JSONBlockCursor {
    private(set) var start = 0
    var events: UInt64 = 0
    private var isLoaded = false
    private var quotes: UInt64 = 0
    private var backslashes: UInt64 = 0
    private var escapes = JSONEscapeTracker()
    private var inStringCarry: UInt64 = 0
    private var lastQuote = -1
    private var previousQuote = -1

    init() {}

    init(masks: JSONBlockMasks, at blockStart: Int) {
        load(masks, at: blockStart)
    }

    @inline(__always)
    func contains(_ position: Int) -> Bool {
        isLoaded && position >= start && position - start < JSONBlockMasks.width
    }

    @inline(__always)
    mutating func discardEvents(before position: Int) {
        events &= ~JSONBlockMasks.bits(below: position - start)
    }

    mutating func advance(to masks: JSONBlockMasks, at blockStart: Int) {
        if quotes != 0 {
            let topBit = 63 - quotes.leadingZeroBitCount
            let rest = quotes & ~(1 << UInt64(topBit))
            previousQuote = rest != 0 ? start + 63 - rest.leadingZeroBitCount : lastQuote
            lastQuote = start + topBit
        }
        load(masks, at: blockStart)
    }

    @inline(__always)
    func keyQuotes(before bit: Int) -> (opening: Int, closing: Int) {
        var below = quotes & JSONBlockMasks.bits(below: bit)
        guard below != 0 else { return (previousQuote, lastQuote) }
        let closingBit = 63 - below.leadingZeroBitCount
        below &= ~(1 << UInt64(closingBit))
        guard below != 0 else { return (lastQuote, start + closingBit) }
        return (start + 63 - below.leadingZeroBitCount, start + closingBit)
    }

    @inline(__always)
    func hasBackslash(between opening: Int, and closing: Int) -> Bool {
        guard backslashes != 0 else { return false }
        let span = JSONBlockMasks.bits(below: closing - start) & ~JSONBlockMasks.bits(below: opening + 1 - start)
        return backslashes & span != 0
    }

    @inline(__always)
    private mutating func load(_ masks: JSONBlockMasks, at blockStart: Int) {
        start = blockStart
        isLoaded = true
        backslashes = masks.backslash
        quotes = masks.quote & ~escapes.escapedBytes(backslashes: masks.backslash)
        let inString = JSONBlockMasks.prefixXor(quotes) ^ inStringCarry
        inStringCarry = UInt64(bitPattern: Int64(bitPattern: inString) >> 63)
        events = masks.structural & ~inString
    }
}

internal struct JSONEscapeTracker {
    private static let oddBits: UInt64 = 0xAAAA_AAAA_AAAA_AAAA

    private var nextIsEscaped: UInt64 = 0

    @inline(__always)
    mutating func escapedBytes(backslashes: UInt64) -> UInt64 {
        guard backslashes != 0 else {
            let escaped = nextIsEscaped
            nextIsEscaped = 0
            return escaped
        }
        let potentialEscapes = backslashes & ~nextIsEscaped
        let maybeEscaped = potentialEscapes << 1
        let escapeAndTerminalCodes = ((maybeEscaped | Self.oddBits) &- potentialEscapes) ^ Self.oddBits
        let escaped = escapeAndTerminalCodes ^ (backslashes | nextIsEscaped)
        nextIsEscaped = (escapeAndTerminalCodes & backslashes) >> 63
        return escaped
    }
}
