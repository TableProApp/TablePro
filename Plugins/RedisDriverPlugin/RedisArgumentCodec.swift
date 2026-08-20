//
//  RedisArgumentCodec.swift
//  RedisDriverPlugin
//

import Foundation

struct RedisArgument {
    let bytes: Data

    var text: String { String(decoding: bytes, as: UTF8.self) }

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    init(_ text: String) {
        bytes = Data(text.utf8)
    }
}

extension String {
    var redisArgument: Data {
        Data(utf8)
    }
}

extension Array where Element == String {
    var asRedisArguments: [Data] {
        map { Data($0.utf8) }
    }
}

extension Array where Element == RedisArgument {
    var asRedisArguments: [Data] {
        map(\.bytes)
    }
}

enum RedisArgumentCodec {
    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let backslash = UInt8(ascii: "\\")
    private static let doubleQuote = UInt8(ascii: "\"")
    private static let singleQuote = UInt8(ascii: "'")
    private static let hexMarker = UInt8(ascii: "x")

    static func split(_ input: String) -> [Data]? {
        let bytes = Array(input.utf8)
        var arguments: [Data] = []
        var index = 0

        while index < bytes.count {
            while index < bytes.count, isBlank(bytes[index]) {
                index += 1
            }
            guard index < bytes.count else { break }

            var current = Data()
            var inDoubleQuote = false
            var inSingleQuote = false
            var closed = false

            while index < bytes.count {
                let byte = bytes[index]

                if inDoubleQuote {
                    if byte == backslash,
                       index + 3 < bytes.count,
                       bytes[index + 1] == hexMarker,
                       let high = hexValue(bytes[index + 2]),
                       let low = hexValue(bytes[index + 3]) {
                        current.append(high << 4 | low)
                        index += 4
                        continue
                    }
                    if byte == backslash, index + 1 < bytes.count {
                        current.append(unescaped(bytes[index + 1]))
                        index += 2
                        continue
                    }
                    if byte == doubleQuote {
                        guard index + 1 >= bytes.count || isBlank(bytes[index + 1]) else { return nil }
                        index += 1
                        closed = true
                        break
                    }
                    current.append(byte)
                    index += 1
                    continue
                }

                if inSingleQuote {
                    if byte == backslash, index + 1 < bytes.count, bytes[index + 1] == singleQuote {
                        current.append(singleQuote)
                        index += 2
                        continue
                    }
                    if byte == singleQuote {
                        guard index + 1 >= bytes.count || isBlank(bytes[index + 1]) else { return nil }
                        index += 1
                        closed = true
                        break
                    }
                    current.append(byte)
                    index += 1
                    continue
                }

                if isBlank(byte) {
                    closed = true
                    break
                }
                if byte == doubleQuote {
                    inDoubleQuote = true
                    index += 1
                    continue
                }
                if byte == singleQuote {
                    inSingleQuote = true
                    index += 1
                    continue
                }
                current.append(byte)
                index += 1
            }

            if !closed, inDoubleQuote || inSingleQuote { return nil }
            arguments.append(current)
        }

        return arguments
    }

    static func quote(_ bytes: Data) -> String {
        if let text = String(data: bytes, encoding: .utf8) {
            return isBare(text) ? text : quotedText(text)
        }
        return quotedBytes(bytes)
    }

    static func quote(_ text: String) -> String {
        isBare(text) ? text : quotedText(text)
    }

    private static func isBare(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return !text.unicodeScalars.contains { scalar in
            scalar.value < 0x21 || scalar.value == 0x7F
                || scalar == "\"" || scalar == "'" || scalar == "\\"
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

    private static func isBlank(_ byte: UInt8) -> Bool {
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
