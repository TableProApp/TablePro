//
//  ClickHouseParameterBinding.swift
//  ClickHouseDriverPlugin
//

import Foundation
import TableProPluginKit

nonisolated internal enum ClickHouseParameterBinding {
    struct Bound {
        let query: String
        let params: [String: String?]
    }

    // A `{p1:String}` parameter is text, so bytes are inlined as `unhex('...')` instead of compared as hex characters,
    // and NULL, which a String parameter cannot hold, is inlined as NULL.
    static func bind(query: String, parameters: [PluginCellValue]) -> Bound {
        var converted = String.UnicodeScalarView()
        converted.reserveCapacity(query.utf8.count)
        var paramMap: [String: String?] = [:]
        var consumed = 0
        var namedCount = 0
        // Scalars, not Characters: a combining mark after a quote would merge with it into one Character.
        var openQuote: Unicode.Scalar?
        var isEscaped = false

        for scalar in query.unicodeScalars {
            if isEscaped {
                isEscaped = false
                converted.append(scalar)
                continue
            }
            if let quote = openQuote {
                // ClickHouse reads backslash escapes inside all three quote forms.
                if scalar == "\\" {
                    isEscaped = true
                } else if scalar == quote {
                    openQuote = nil
                }
                converted.append(scalar)
                continue
            }
            if scalar == "'" || scalar == "\"" || scalar == "`" {
                openQuote = scalar
                converted.append(scalar)
                continue
            }
            guard scalar == "?", consumed < parameters.count else {
                converted.append(scalar)
                continue
            }
            let parameter = parameters[consumed]
            consumed += 1
            switch parameter {
            case .bytes(let data):
                converted.append(contentsOf: hexLiteral(data).unicodeScalars)
            case .null:
                converted.append(contentsOf: "NULL".unicodeScalars)
            case .text(let text):
                namedCount += 1
                let name = "p\(namedCount)"
                converted.append(contentsOf: "{\(name):String}".unicodeScalars)
                paramMap[name] = escapedParameterValue(text)
            }
        }

        return Bound(query: String(converted), params: paramMap)
    }

    // The server reads a parameter in its escaped text format: a backslash starts an escape and a raw tab ends the value.
    static func escapedParameterValue(_ text: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped.append(contentsOf: "\\\\".unicodeScalars)
            case "\t": escaped.append(contentsOf: "\\t".unicodeScalars)
            case "\n": escaped.append(contentsOf: "\\n".unicodeScalars)
            case "\r": escaped.append(contentsOf: "\\r".unicodeScalars)
            default: escaped.append(scalar)
            }
        }
        return String(escaped)
    }

    static func hexLiteral(_ data: Data) -> String {
        let hex = data.map { String(format: "%02X", $0) }.joined()
        return "unhex('\(hex)')"
    }
}
