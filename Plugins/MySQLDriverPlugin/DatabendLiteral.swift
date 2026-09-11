//
//  DatabendLiteral.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum DatabendLiteralError: Error, Equatable {
    case parameterCountMismatch(placeholders: Int, values: Int)
}

extension DatabendLiteralError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case let .parameterCountMismatch(placeholders, values):
            return String(
                format: String(localized: "The statement has %d placeholders but %d values were given."),
                placeholders, values
            )
        }
    }
}

internal enum DatabendLiteral {
    static func escapeString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "'": result += "''"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\0": result += "\\0"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func quoted(_ value: String) -> String {
        "'\(escapeString(value))'"
    }

    static func hex(_ data: Data) -> String {
        "X'" + data.map { String(format: "%02X", $0) }.joined() + "'"
    }

    static func literal(for value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let text):
            return quoted(text)
        case .bytes(let data):
            return hex(data)
        }
    }

    static func inline(_ sql: String, parameters: [PluginCellValue]) throws -> String {
        let scalars = Array(sql.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        var nextParameter = 0

        func peek(_ offset: Int) -> Unicode.Scalar? {
            let position = index + offset
            return position < scalars.count ? scalars[position] : nil
        }

        func copyThroughLineEnd() {
            while index < scalars.count, scalars[index] != "\n" {
                output.append(scalars[index])
                index += 1
            }
        }

        func copyBlockComment() {
            output.append(scalars[index])
            output.append(scalars[index + 1])
            index += 2
            while index < scalars.count {
                if scalars[index] == "*", peek(1) == "/" {
                    output.append("*")
                    output.append("/")
                    index += 2
                    return
                }
                output.append(scalars[index])
                index += 1
            }
        }

        func copyQuoted(by terminator: Unicode.Scalar, honoursBackslash: Bool) {
            output.append(scalars[index])
            index += 1
            while index < scalars.count {
                let scalar = scalars[index]
                output.append(scalar)
                if honoursBackslash, scalar == "\\", let next = peek(1) {
                    output.append(next)
                    index += 2
                    continue
                }
                index += 1
                guard scalar == terminator else { continue }
                if peek(0) == terminator {
                    output.append(terminator)
                    index += 1
                    continue
                }
                return
            }
        }

        func copyDollarQuoted() {
            output.append("$")
            output.append("$")
            index += 2
            while index < scalars.count {
                if scalars[index] == "$", peek(1) == "$" {
                    output.append("$")
                    output.append("$")
                    index += 2
                    return
                }
                output.append(scalars[index])
                index += 1
            }
        }

        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "-" where peek(1) == "-":
                copyThroughLineEnd()
            case "/" where peek(1) == "*":
                copyBlockComment()
            case "$" where peek(1) == "$":
                copyDollarQuoted()
            case "'":
                copyQuoted(by: "'", honoursBackslash: true)
            case "\"":
                copyQuoted(by: "\"", honoursBackslash: true)
            case "`":
                copyQuoted(by: "`", honoursBackslash: false)
            case "?":
                if nextParameter < parameters.count {
                    output.append(contentsOf: literal(for: parameters[nextParameter]).unicodeScalars)
                }
                nextParameter += 1
                index += 1
            default:
                output.append(scalar)
                index += 1
            }
        }

        guard nextParameter == parameters.count else {
            throw DatabendLiteralError.parameterCountMismatch(placeholders: nextParameter, values: parameters.count)
        }
        return String(output)
    }
}
