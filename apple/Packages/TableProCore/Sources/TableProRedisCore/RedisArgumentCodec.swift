import Foundation

public struct RedisArgument: Sendable {
    public let bytes: Data

    public var text: String { String(decoding: bytes, as: UTF8.self) } // swiftlint:disable:this optional_data_string_conversion

    public init(_ bytes: Data) {
        self.bytes = bytes
    }

    public init(_ text: String) {
        bytes = Data(text.utf8)
    }
}

public extension String {
    var redisArgument: Data {
        Data(utf8)
    }
}

public extension Array where Element == String {
    var asRedisArguments: [Data] {
        map { Data($0.utf8) }
    }
}

public extension Array where Element == RedisArgument {
    var asRedisArguments: [Data] {
        map(\.bytes)
    }
}

public enum RedisArgumentCodec {
    private static let tab = UInt8(ascii: "\t")
    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let backslash = UInt8(ascii: "\\")
    private static let doubleQuote = UInt8(ascii: "\"")

    // One command's arguments, as redis-cli reads one line: a `;` is an argument byte and a line break a blank.
    public static func split(_ input: String) -> [Data]? {
        var lexer = RedisCommandLexer(input, endsCommands: false, decodesArguments: true)
        guard let command = lexer.next() else { return [] }
        return command.arguments
    }

    public static func quote(_ bytes: Data) -> String {
        if let text = String(data: bytes, encoding: .utf8) {
            return isBare(text) ? text : quotedText(text)
        }
        return quotedBytes(bytes)
    }

    public static func quote(_ text: String) -> String {
        isBare(text) ? text : quotedText(text)
    }

    // A `;` ends a command, and a blank or invisible character at an edge is trimmed by text fields and editors.
    private static func isBare(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return !text.unicodeScalars.contains { scalar in
            scalar.value < 0x21 || scalar.value == 0x7F
                || scalar == "\"" || scalar == "'" || scalar == "\\" || scalar == ";"
                || scalar.properties.isWhitespace
                || scalar.properties.generalCategory == .control
                || scalar.properties.isDefaultIgnorableCodePoint
        }
    }

    public static func quotedText(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{07}": result += "\\a"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\x%02x", scalar.value)
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
            case doubleQuote: result += "\\\""
            case newline: result += "\\n"
            case carriageReturn: result += "\\r"
            case tab: result += "\\t"
            case 0x08: result += "\\b"
            case 0x07: result += "\\a"
            default:
                if byte >= 0x20, byte < 0x7F {
                    result.unicodeScalars.append(UnicodeScalar(byte))
                } else {
                    result += String(format: "\\x%02x", byte)
                }
            }
        }
        return result + "\""
    }
}
