import Foundation
import TableProPluginKit

enum DamengParameterBindingError: PluginDriverError, Equatable {
    case embeddedNull
    case insufficientParameters
    case unusedParameters
    case unknownBackslashHandling

    var pluginErrorMessage: String {
        switch self {
        case .embeddedNull:
            return String(localized: "Dameng cannot store a text value that contains a null character.")
        case .insufficientParameters:
            return String(localized: "This Dameng statement has more placeholders than values.")
        case .unusedParameters:
            return String(localized: "This Dameng statement has more values than placeholders.")
        case .unknownBackslashHandling:
            return String(localized: """
                TablePro could not tell how this Dameng server treats backslashes, so it will not send a \
                value that contains one. Reconnect, then try again.
                """)
        }
    }
}

enum DamengTextEscaping: Sendable {
    case backslashLiteral
    case backslashEscape
    case unknown
}

enum DamengParameterBinder {
    private enum State: Equatable {
        case code
        case singleQuote
        case doubleQuote
        case alternativeQuote(UInt8)
        case lineComment
        case blockComment(Int)
    }

    static func bind(
        query: String,
        parameters: [PluginCellValue],
        escaping: DamengTextEscaping
    ) throws -> String {
        let input = Array(query.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count + parameters.count * 8)
        var state = State.code
        var parameterIndex = 0
        var index = 0

        while index < input.count {
            let byte = input[index]
            let next = index + 1 < input.count ? input[index + 1] : nil

            switch state {
            case .code:
                if byte == 0x2D, next == 0x2D {
                    output.append(contentsOf: [byte, 0x2D])
                    state = .lineComment
                    index += 2
                } else if byte == 0x2F, next == 0x2A {
                    output.append(contentsOf: [byte, 0x2A])
                    state = .blockComment(1)
                    index += 2
                } else if byte == 0x27 {
                    output.append(byte)
                    state = .singleQuote
                    index += 1
                } else if byte == 0x22 {
                    output.append(byte)
                    state = .doubleQuote
                    index += 1
                } else if isAlternativeQuoteStart(input, at: index) {
                    let opener = input[index + 2]
                    output.append(contentsOf: input[index...index + 2])
                    state = .alternativeQuote(alternativeQuoteCloser(opener))
                    index += 3
                } else if byte == 0x3F {
                    guard parameterIndex < parameters.count else {
                        throw DamengParameterBindingError.insufficientParameters
                    }
                    let bound = try literal(for: parameters[parameterIndex], escaping: escaping)
                    output.append(contentsOf: bound.utf8)
                    parameterIndex += 1
                    index += 1
                } else {
                    output.append(byte)
                    index += 1
                }
            case .singleQuote:
                if escaping == .backslashEscape, byte == 0x5C, let next {
                    output.append(contentsOf: [byte, next])
                    index += 2
                    continue
                }
                output.append(byte)
                if byte == 0x27, next == 0x27 {
                    output.append(0x27)
                    index += 2
                } else {
                    if byte == 0x27 { state = .code }
                    index += 1
                }
            case .doubleQuote:
                output.append(byte)
                if byte == 0x22, next == 0x22 {
                    output.append(0x22)
                    index += 2
                } else {
                    if byte == 0x22 { state = .code }
                    index += 1
                }
            case .alternativeQuote(let closer):
                output.append(byte)
                if byte == closer, next == 0x27 {
                    output.append(0x27)
                    state = .code
                    index += 2
                } else {
                    index += 1
                }
            case .lineComment:
                output.append(byte)
                if byte == 0x0A || byte == 0x0D { state = .code }
                index += 1
            case .blockComment(let depth):
                if byte == 0x2F, next == 0x2A {
                    output.append(contentsOf: [byte, 0x2A])
                    state = .blockComment(depth + 1)
                    index += 2
                } else if byte == 0x2A, next == 0x2F {
                    output.append(contentsOf: [byte, 0x2F])
                    state = depth == 1 ? .code : .blockComment(depth - 1)
                    index += 2
                } else {
                    output.append(byte)
                    index += 1
                }
            }
        }

        guard parameterIndex == parameters.count else {
            throw DamengParameterBindingError.unusedParameters
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func literal(for value: PluginCellValue, escaping: DamengTextEscaping) throws -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let text):
            guard !text.unicodeScalars.contains("\0") else {
                throw DamengParameterBindingError.embeddedNull
            }
            return "'\(try escapedText(text, escaping: escaping))'"
        case .bytes(let data):
            return "HEXTORAW('\(data.map { String(format: "%02X", $0) }.joined())')"
        }
    }

    /// Escapes by Unicode scalar. `String.replacingOccurrences` matches whole grapheme clusters, so a quote
    /// carrying a combining mark is not doubled and the value escapes its own literal.
    static func escapedText(_ text: String, escaping: DamengTextEscaping) throws -> String {
        if escaping == .unknown, text.unicodeScalars.contains("\\") {
            throw DamengParameterBindingError.unknownBackslashHandling
        }
        var escaped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\\", escaping == .backslashEscape {
                escaped.append(scalar)
            } else if scalar == "'" {
                escaped.append(scalar)
            }
            escaped.append(scalar)
        }
        return String(escaped)
    }

    private static func isAlternativeQuoteStart(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index + 2 < bytes.count else { return false }
        return (bytes[index] == 0x51 || bytes[index] == 0x71) && bytes[index + 1] == 0x27
    }

    private static func alternativeQuoteCloser(_ opener: UInt8) -> UInt8 {
        switch opener {
        case 0x5B: return 0x5D
        case 0x28: return 0x29
        case 0x7B: return 0x7D
        case 0x3C: return 0x3E
        default: return opener
        }
    }
}
