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

    // A `{p1:String}` parameter is text, so bytes are inlined as `unhex('...')` instead of compared as hex characters.
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
            if case .bytes(let data) = parameter {
                converted.append(contentsOf: hexLiteral(data).unicodeScalars)
                continue
            }
            namedCount += 1
            let name = "p\(namedCount)"
            converted.append(contentsOf: "{\(name):String}".unicodeScalars)
            paramMap[name] = parameter.asText
        }

        return Bound(query: String(converted), params: paramMap)
    }

    static func hexLiteral(_ data: Data) -> String {
        let hex = data.map { String(format: "%02X", $0) }.joined()
        return "unhex('\(hex)')"
    }
}
