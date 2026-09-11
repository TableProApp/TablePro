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

    /// A ClickHouse HTTP parameter is text: `{p1:String}` takes the characters of `param_p1`
    /// verbatim, so bytes handed over as `0xDEADBEEF` compare as those ten characters and every
    /// predicate on a binary column matches nothing. Bytes are written into the statement as
    /// `unhex('…')` instead, which the server turns back into the value the read produced. The hex
    /// is generated here and holds nothing but `0-9A-F`, so it closes no quote.
    static func bind(query: String, parameters: [PluginCellValue]) -> Bound {
        var converted = ""
        converted.reserveCapacity((query as NSString).length)
        var paramMap: [String: String?] = [:]
        var consumed = 0
        var namedCount = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        for char in query {
            if isEscaped {
                isEscaped = false
                converted.append(char)
                continue
            }
            if char == "\\" && (inSingleQuote || inDoubleQuote) {
                isEscaped = true
                converted.append(char)
                continue
            }
            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            }
            guard char == "?", !inSingleQuote, !inDoubleQuote, consumed < parameters.count else {
                converted.append(char)
                continue
            }
            let parameter = parameters[consumed]
            consumed += 1
            if case .bytes(let data) = parameter {
                converted.append(hexLiteral(data))
                continue
            }
            namedCount += 1
            let name = "p\(namedCount)"
            converted.append("{\(name):String}")
            paramMap[name] = parameter.asText
        }

        return Bound(query: converted, params: paramMap)
    }

    static func hexLiteral(_ data: Data) -> String {
        let hex = data.map { String(format: "%02X", $0) }.joined()
        return "unhex('\(hex)')"
    }
}
