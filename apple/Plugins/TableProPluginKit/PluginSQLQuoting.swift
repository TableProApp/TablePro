//
//  PluginSQLQuoting.swift
//  TableProPluginKit
//

import Foundation

// TableProSQLQuoting's rules for the defaults every plugin inherits. The framework cannot link that package product:
// Xcode promotes a product a framework and its dependents share to a framework of its own, and refuses the static
// form. PluginSQLQuotingParityTests holds the two to the same output.
enum PluginSQLQuoting {
    enum Escapes {
        case standard
        case backslash
        case googleSQL

        init(features: SQLLexicalFeatures) {
            guard features.contains(.backslashEscapesInSingleQuotes) else {
                self = .standard
                return
            }
            self = features.contains(.tripleQuotedStrings) ? .googleSQL : .backslash
        }
    }

    static func identifier(_ name: String) -> String {
        var quoted = String.UnicodeScalarView()
        quoted.append("\"")
        for scalar in name.unicodeScalars {
            if scalar == "\"" { quoted.append(scalar) }
            quoted.append(scalar)
        }
        quoted.append("\"")
        return String(quoted)
    }

    static func stringLiteral(_ value: String, escapes: Escapes = .standard) -> String {
        "'" + stringLiteralBody(value, escapes: escapes) + "'"
    }

    static func stringLiteralBody(_ value: String, escapes: Escapes = .standard) -> String {
        var output = String.UnicodeScalarView()
        let scalars = Array(value.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            switch (scalar, escapes) {
            case (_, .googleSQL):
                appendGoogleSQLEscaped(scalar, to: &output)
            case ("'", _):
                output.append(contentsOf: "''".unicodeScalars)
            case ("\0", .standard):
                continue
            case (_, .standard):
                output.append(scalar)
            case ("\\", _):
                output.append(contentsOf: #"\\"#.unicodeScalars)
            case ("\0", _) where index + 1 < scalars.count && ("0"..."9").contains(scalars[index + 1]):
                output.append(contentsOf: #"\x00"#.unicodeScalars)
            case ("\0", _):
                output.append(contentsOf: #"\0"#.unicodeScalars)
            default:
                output.append(scalar)
            }
        }
        return String(output)
    }

    static func likePattern(_ value: String) -> String {
        var pattern = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if scalar == "\\" || scalar == "%" || scalar == "_" { pattern.append("\\") }
            pattern.append(scalar)
        }
        return String(pattern)
    }

    static func lineCommentText(_ text: String) -> String {
        var line = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}":
                line.append(" ")
            default:
                line.append(scalar)
            }
        }
        return String(line)
    }

    private static let hexDigits = Array("0123456789abcdef".unicodeScalars)

    private static func appendGoogleSQLEscaped(_ scalar: Unicode.Scalar, to output: inout String.UnicodeScalarView) {
        switch scalar {
        case "\\", "'", "\"", "`":
            output.append("\\")
            output.append(scalar)
        case "\n":
            output.append(contentsOf: #"\n"#.unicodeScalars)
        case "\r":
            output.append(contentsOf: #"\r"#.unicodeScalars)
        case "\t":
            output.append(contentsOf: #"\t"#.unicodeScalars)
        case _ where scalar.value < 0x20 || scalar.value == 0x7F:
            output.append(contentsOf: #"\x"#.unicodeScalars)
            output.append(hexDigits[Int(scalar.value >> 4)])
            output.append(hexDigits[Int(scalar.value & 0xF)])
        default:
            output.append(scalar)
        }
    }
}
