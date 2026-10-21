import Foundation

// The one reader of Redis command text. Arguments follow redis-cli's sdssplitargs (src/sds.c); with
// `endsCommands`, a `;` or a line break outside quotes also ends a command, TablePro's rule for a script.
// The command split and each command's arguments come from the same pass, so they agree on every byte.
struct RedisCommandLexer {
    struct Command {
        // UTF-16 offsets: the first unit of the first argument and the unit past the last argument.
        let start: Int
        let end: Int
        // The last offset a caret can sit at and still belong to the command: past its `;`, or at its line break.
        let reach: Int
        // Nil when a quote is left open or a closing quote runs into more text.
        let arguments: [Data]?
    }

    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let verticalTab: UInt8 = 0x0B
    private static let formFeed: UInt8 = 0x0C
    private static let semicolon = UInt8(ascii: ";")
    private static let backslash = UInt8(ascii: "\\")
    private static let doubleQuote = UInt8(ascii: "\"")
    private static let singleQuote = UInt8(ascii: "'")
    private static let hexMarker = UInt8(ascii: "x")

    private let bytes: String.UTF8View
    private let endsCommands: Bool
    private let decodesArguments: Bool
    private var index: String.Index
    private var offset = 0

    init(_ text: String, endsCommands: Bool, decodesArguments: Bool) {
        bytes = text.utf8
        index = bytes.startIndex
        self.endsCommands = endsCommands
        self.decodesArguments = decodesArguments
    }

    mutating func next() -> Command? {
        var arguments: [Data] = []
        var isValid = true
        var start: Int?
        var end = 0

        func command(reach: Int) -> Command? {
            start.map { Command(start: $0, end: end, reach: reach, arguments: isValid ? arguments : nil) }
        }

        while let byte = peek() {
            if endsCommands, byte == Self.semicolon {
                advance()
                if let found = command(reach: offset) { return found }
                continue
            }
            if endsCommands, byte == Self.newline || byte == Self.carriageReturn {
                let reach = offset
                advance()
                if let found = command(reach: reach) { return found }
                continue
            }
            if Self.isBlank(byte) {
                advance()
                continue
            }
            if start == nil { start = offset }
            let argument = readArgument()
            arguments.append(argument.bytes)
            if !argument.isValid { isValid = false }
            end = offset
        }
        return command(reach: offset)
    }

    private mutating func readArgument() -> (bytes: Data, isValid: Bool) {
        var current = Data()
        var quote: UInt8?
        var isValid = true

        while let byte = peek() {
            switch quote {
            case Self.doubleQuote:
                if byte == Self.backslash, peek(1) == Self.hexMarker,
                   let high = peek(2).flatMap(Self.hexValue), let low = peek(3).flatMap(Self.hexValue) {
                    append(high << 4 | low, to: &current)
                    advance(4)
                } else if byte == Self.backslash, let escaped = peek(1) {
                    append(Self.unescaped(escaped), to: &current)
                    advance(2)
                } else if byte == Self.doubleQuote {
                    advance()
                    quote = nil
                    if closesArgument() { return (current, isValid) }
                    isValid = false
                } else {
                    append(byte, to: &current)
                    advance()
                }
            case Self.singleQuote:
                if byte == Self.backslash, peek(1) == Self.singleQuote {
                    append(Self.singleQuote, to: &current)
                    advance(2)
                } else if byte == Self.singleQuote {
                    advance()
                    quote = nil
                    if closesArgument() { return (current, isValid) }
                    isValid = false
                } else {
                    append(byte, to: &current)
                    advance()
                }
            default:
                if Self.endsBareArgument(byte) || (endsCommands && byte == Self.semicolon) {
                    return (current, isValid)
                }
                if byte == Self.doubleQuote || byte == Self.singleQuote {
                    quote = byte
                } else {
                    append(byte, to: &current)
                }
                advance()
            }
        }
        return (current, isValid && quote == nil)
    }

    // A closing quote ends the argument when a blank, the command's end or the text's end follows it. Anything
    // else makes the command invalid, and the scan reads on unquoted to find where the command ends.
    private func closesArgument() -> Bool {
        guard let byte = peek() else { return true }
        return Self.isBlank(byte) || (endsCommands && byte == Self.semicolon)
    }

    private func append(_ byte: UInt8, to data: inout Data) {
        if decodesArguments { data.append(byte) }
    }

    private func peek(_ distance: Int = 0) -> UInt8? {
        guard let position = bytes.index(index, offsetBy: distance, limitedBy: bytes.endIndex),
              position < bytes.endIndex else { return nil }
        return bytes[position]
    }

    // A UTF-8 lead byte starts one UTF-16 unit, or two for a four-byte scalar; a continuation byte starts none.
    private mutating func advance(_ count: Int = 1) {
        for _ in 0 ..< count where index < bytes.endIndex {
            let byte = bytes[index]
            if byte & 0xC0 != 0x80 { offset += byte >= 0xF0 ? 2 : 1 }
            index = bytes.index(after: index)
        }
    }

    // sdssplitargs skips every isspace byte between arguments, but only these four end an unquoted one.
    private static func isBlank(_ byte: UInt8) -> Bool {
        endsBareArgument(byte) || byte == verticalTab || byte == formFeed
    }

    private static func endsBareArgument(_ byte: UInt8) -> Bool {
        byte == space || byte == tab || byte == newline || byte == carriageReturn
    }

    private static func unescaped(_ byte: UInt8) -> UInt8 {
        switch byte {
        case UInt8(ascii: "n"): return newline
        case UInt8(ascii: "r"): return carriageReturn
        case UInt8(ascii: "t"): return tab
        case UInt8(ascii: "b"): return 0x08
        case UInt8(ascii: "a"): return 0x07
        default: return byte
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
