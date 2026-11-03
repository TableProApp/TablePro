import Foundation

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

    // Inside quotes, \n, \r, \t, \\, \", \' and \xHH are escapes; \xHH is one byte, so any key can be written.
    public static func tokenize(_ input: String) -> [Data] {
        let scalars = Array(input.unicodeScalars)
        var tokens: [Data] = []
        var token: [UInt8] = []
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
                    append(scalar, to: &token)
                }
            } else if scalar == "\"" || scalar == "'" {
                openQuote = scalar
                tokenStarted = true
            } else if isBlank(scalar) {
                if tokenStarted {
                    tokens.append(Data(token))
                    token.removeAll()
                    tokenStarted = false
                }
            } else {
                append(scalar, to: &token)
                tokenStarted = true
            }
        }

        if tokenStarted {
            tokens.append(Data(token))
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
    private static let backslash = UInt8(ascii: "\\")

    private static func append(_ scalar: Unicode.Scalar, to token: inout [UInt8]) {
        UTF8.encode(scalar) { token.append($0) }
    }

    private static func appendEscape(in scalars: [Unicode.Scalar], at index: Int, to token: inout [UInt8]) -> Int {
        guard index < scalars.count else {
            token.append(backslash)
            return index
        }
        let escaped = scalars[index]
        switch escaped {
        case "n": token.append(0x0A)
        case "r": token.append(0x0D)
        case "t": token.append(0x09)
        case "\\", "\"", "'": token.append(UInt8(escaped.value))
        case "x" where index + 2 < scalars.count:
            if let byte = hexByte(scalars[index + 1], scalars[index + 2]) {
                token.append(byte)
                return index + 3
            }
            token.append(backslash)
            append(escaped, to: &token)
        default:
            token.append(backslash)
            append(escaped, to: &token)
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
            case backslash: result += "\\\\"
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
