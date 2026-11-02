import Foundation
import TableProDamengCore
import TableProPluginKit
import TableProSQLQuoting

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
    static func bind(
        query: String,
        parameters: [PluginCellValue],
        escaping: DamengTextEscaping
    ) throws -> String {
        let pieces = DamengPlaceholders.pieces(of: query, backslashEscapes: escaping == .backslashEscape)
        var bound = pieces[0]
        for (index, piece) in pieces.dropFirst().enumerated() {
            guard index < parameters.count else {
                throw DamengParameterBindingError.insufficientParameters
            }
            bound += try literal(for: parameters[index], escaping: escaping)
            bound += piece
        }
        guard pieces.count - 1 == parameters.count else {
            throw DamengParameterBindingError.unusedParameters
        }
        return bound
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

    // With the mode unknown, text without a backslash is written the way both modes read it.
    static func escapedText(_ text: String, escaping: DamengTextEscaping) throws -> String {
        switch escaping {
        case .backslashEscape:
            return SQLQuoting.stringLiteralBody(text, escapes: .backslash)
        case .backslashLiteral:
            return SQLQuoting.stringLiteralBody(text)
        case .unknown:
            guard !text.unicodeScalars.contains("\\") else {
                throw DamengParameterBindingError.unknownBackslashHandling
            }
            return SQLQuoting.stringLiteralBody(text)
        }
    }
}
