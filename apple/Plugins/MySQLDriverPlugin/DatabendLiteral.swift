//
//  DatabendLiteral.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

internal enum DatabendLiteralError: Error, Equatable {
    case parameterCountMismatch(placeholders: Int, values: Int)
    case placeholdersDependOnServerVersion
    case serverTooOldToBind
}

extension DatabendLiteralError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case let .parameterCountMismatch(placeholders, values):
            return String(
                format: String(localized: "The statement has %d placeholders but %d values were given."),
                placeholders, values
            )
        case .serverTooOldToBind:
            return String(localized: "Binding parameters needs Databend 1.2.473 or later.")
        case .placeholdersDependOnServerVersion:
            return String(
                localized: "Databend versions end this statement's comments in different places, so its parameters cannot be bound. Rewrite comments such as /**/ or one ending in **/."
            )
        }
    }
}

internal enum DatabendLiteral {
    // QuotedString reads `\0` as an octal escape that takes the octal digits after it, so NUL is `\x00`, as
    // Databend's own writer spells it.
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
            case "\0": result += "\\x00"
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

    // 1.2.473 brought today's literal and name decoding, and every tokenizer change since is a reading below. An
    // older release reads `1_`, `$$`, stage names and several operators differently, so a value bound for it could
    // land outside its literal.
    static let oldestBindingRelease = (major: 1, minor: 2, patch: 473)

    // `8.0.90-v1.2.880-nightly-081742daa3(...)`: the MySQL version Databend answers as, then its own.
    static func release(fromServerVersion banner: String) -> (major: Int, minor: Int, patch: Int)? {
        guard let marker = banner.range(of: "-v") else { return nil }
        return MySQLServerVersion.components(from: String(banner[marker.upperBound...]))
    }

    // A value only stays a literal where every release the server could be reads a placeholder in the same place.
    static func inline(_ sql: String, parameters: [PluginCellValue], serverVersion: String? = nil) throws -> String {
        if let banner = serverVersion, let release = release(fromServerVersion: banner), release < oldestBindingRelease {
            throw DatabendLiteralError.serverTooOldToBind
        }
        let scalars = Array(sql.unicodeScalars)
        let placeholders = DatabendTokenizer.placeholders(in: scalars)
        for rules in DatabendTokenizer.Rules.readings(of: scalars).dropFirst() {
            guard DatabendTokenizer.placeholders(in: scalars, rules: rules) == placeholders else {
                throw DatabendLiteralError.placeholdersDependOnServerVersion
            }
        }
        guard placeholders.count == parameters.count else {
            throw DatabendLiteralError.parameterCountMismatch(placeholders: placeholders.count, values: parameters.count)
        }
        var output = String.UnicodeScalarView()
        var copied = 0
        for (offset, value) in zip(placeholders, parameters) {
            output.append(contentsOf: scalars[copied..<offset])
            output.append(contentsOf: literal(for: value).unicodeScalars)
            copied = offset + 1
        }
        output.append(contentsOf: scalars[copied...])
        return String(output)
    }
}
