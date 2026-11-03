import Foundation

// One word of an etcd command line, read two ways.
public struct EtcdCommandToken: Equatable, Sendable {
    // As every TablePro release reads the word, with \xHH left as four characters. Commands, flags and names use
    // this, so an older host grades the same command the driver runs.
    public let text: String
    // The bytes of a key or a value, with \xHH as one byte.
    public let bytes: Data

    public init(text: String, bytes: Data) {
        self.text = text
        self.bytes = bytes
    }
}

// One etcd command line as text: the trim, the tokenizer and the quoter share one set of blanks, so an
// argument the quoter leaves bare reads back as the same bytes.
public enum EtcdCommandText {
    public static let endOfFlags = "--"

    public static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    public static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isBlank($0) }),
              let last = scalars.lastIndex(where: { !isBlank($0) }) else {
            return ""
        }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars[first ... last])
        return String(kept)
    }

    // Inside quotes, \n, \r, \t, \\, \" and \' are escapes, and \xHH is one byte of a key or a value.
    public static func tokenize(_ input: String) -> [EtcdCommandToken] {
        let scalars = Array(input.unicodeScalars)
        var tokens: [EtcdCommandToken] = []
        var token = TokenBuilder()
        var tokenStarted = false
        var openQuote: Unicode.Scalar?
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            index += 1

            if let quote = openQuote {
                if scalar == quote {
                    openQuote = nil
                } else if scalar == "\\" {
                    index = appendEscape(in: scalars, at: index, to: &token)
                } else {
                    token.append(scalar)
                }
            } else if scalar == "\"" || scalar == "'" {
                openQuote = scalar
                tokenStarted = true
            } else if isBlank(scalar) {
                if tokenStarted {
                    tokens.append(token.finish())
                    tokenStarted = false
                }
            } else {
                token.append(scalar)
                tokenStarted = true
            }
        }

        if tokenStarted {
            tokens.append(token.finish())
        }
        return tokens
    }

    public static func quoted(_ argument: String) -> String {
        isBare(argument) ? argument : quotedText(argument)
    }

    public static func quoted(_ argument: Data) -> String {
        guard let text = text(argument) else { return quotedBytes(argument) }
        return quoted(text)
    }

    // An argument that starts with "--" would read as a flag, so the flags go first and "--" ends them.
    public static func command(_ name: String, arguments: [Data], flags: [String] = []) -> String {
        let words = arguments.map { quoted($0) }
        guard arguments.contains(where: { $0.starts(with: flagMarker) }) else {
            return ([name] + words + flags).joined(separator: " ")
        }
        return ([name] + flags + [endOfFlags] + words).joined(separator: " ")
    }

    // String(data:encoding:) drops a leading byte order mark, which names a different key.
    public static func text(_ bytes: Data) -> String? {
        let text = String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        return text.utf8.elementsEqual(bytes) ? text : nil
    }

    // MARK: - Private

    private static let flagMarker = Data(endOfFlags.utf8)

    private struct TokenBuilder {
        private var text = String.UnicodeScalarView()
        private var bytes: [UInt8] = []

        mutating func append(_ scalar: Unicode.Scalar) {
            text.append(scalar)
            UTF8.encode(scalar) { bytes.append($0) }
        }

        mutating func appendHexEscape(_ high: Unicode.Scalar, _ low: Unicode.Scalar, byte: UInt8) {
            text.append(contentsOf: ["\\", "x", high, low])
            bytes.append(byte)
        }

        mutating func finish() -> EtcdCommandToken {
            defer {
                text = String.UnicodeScalarView()
                bytes.removeAll()
            }
            return EtcdCommandToken(text: String(text), bytes: Data(bytes))
        }
    }

    private static func appendEscape(in scalars: [Unicode.Scalar], at index: Int, to token: inout TokenBuilder) -> Int {
        guard index < scalars.count else {
            token.append("\\")
            return index
        }
        let escaped = scalars[index]
        switch escaped {
        case "n": token.append("\n")
        case "r": token.append("\r")
        case "t": token.append("\t")
        case "\\", "\"", "'": token.append(escaped)
        case "x" where index + 2 < scalars.count:
            let high = scalars[index + 1]
            let low = scalars[index + 2]
            if let byte = hexByte(high, low) {
                token.appendHexEscape(high, low, byte: byte)
                return index + 3
            }
            token.append("\\")
            token.append(escaped)
        default:
            token.append("\\")
            token.append(escaped)
        }
        return index + 1
    }

    private static func hexByte(_ high: Unicode.Scalar, _ low: Unicode.Scalar) -> UInt8? {
        guard high.properties.isASCIIHexDigit, low.properties.isASCIIHexDigit else { return nil }
        return UInt8(String(high) + String(low), radix: 16)
    }

    // A quote opens a quoted argument and a blank ends one. A control or invisible character is quoted too:
    // text fields and editors drop one at an edge, and CharacterSet.whitespacesAndNewlines holds U+200B.
    private static func isBare(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return !text.unicodeScalars.contains { scalar in
            isBlank(scalar) || scalar == "\"" || scalar == "'"
                || scalar.properties.generalCategory == .control
                || scalar.properties.isDefaultIgnorableCodePoint
        }
    }

    private static func quotedText(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += hexEscape(UInt8(scalar.value))
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    private static func quotedBytes(_ bytes: Data) -> String {
        var result = "\""
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\\"): result += "\\\\"
            case UInt8(ascii: "\""): result += "\\\""
            case 0x20 ..< 0x7F: result.unicodeScalars.append(Unicode.Scalar(byte))
            default: result += hexEscape(byte)
            }
        }
        return result + "\""
    }

    private static func hexEscape(_ byte: UInt8) -> String {
        String(format: "\\x%02x", byte)
    }
}
