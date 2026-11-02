//
//  ClickHouseParameterBinding.swift
//  ClickHouseDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

nonisolated internal enum ClickHouseParameterBinding {
    struct Bound: Equatable {
        let query: String
        let params: [String: String?]
    }

    // Measured on 25.8: a `param_` item over 131,072 bytes once percent-encoded, or a URL over 1,048,576 bytes, is
    // refused before the query runs (http_max_field_value_size, http_max_uri_size, both from the server's profile).
    // Within those the values ride as parameters, which the server keeps out of the SQL text and out of
    // max_query_size, so a statement that ran before still runs for a user who may not raise that setting. 4 KiB
    // stays for the URL's other items.
    static let maxParameterBytes = 131_072
    static let maxParametersBytes = 1_048_576 - 4_096

    // A `{p1:String}` parameter is text, so bytes are inlined as `unhex('...')` instead of compared as hex characters,
    // and NULL, which a String parameter cannot hold, is inlined as NULL. Text too long for the URL is written into the
    // statement, which travels in the POST body.
    static func bind(query: String, parameters: [PluginCellValue]) -> Bound {
        let escaped = parameters.map { value -> String? in
            guard case .text(let text) = value else { return nil }
            return escapedParameterValue(text)
        }
        let sizes = escaped.compactMap { $0.map(urlEncodedByteCount) }
        // Each item also carries `&param_pN=`, which is most of the URL when a wide batch holds short values.
        let itemBytes = sizes.indices.reduce(0) { $0 + "&param_p\($1 + 1)=".utf8.count }
        let fitsURL = sizes.allSatisfy { $0 <= maxParameterBytes } && sizes.reduce(itemBytes, +) <= maxParametersBytes

        // The engine's own lexer, so a `?` in a string, a quoted name or any comment ClickHouse reads stays text.
        let source = query as NSString
        let units = Array(query.utf16)
        var converted: [UInt16] = []
        converted.reserveCapacity(units.count)
        var paramMap: [String: String?] = [:]
        var consumed = 0
        var namedCount = 0
        var index = 0
        var firstWord: String?
        var isInsertData = false

        while index < units.count {
            if let span = SQLNonCodeSpan.span(at: index, in: source, grammar: grammar) {
                let end = min(max(span.end, index + 1), units.count)
                converted.append(contentsOf: units[index..<end])
                index = end
                continue
            }
            if isWordUnit(units[index]) {
                var end = index + 1
                while end < units.count, isWordUnit(units[end]) {
                    end += 1
                }
                let word = String(decoding: units[index..<end], as: UTF16.self).uppercased()
                firstWord = firstWord ?? word
                isInsertData = isInsertData || (firstWord == "INSERT" && word == "VALUES")
                converted.append(contentsOf: units[index..<end])
                index = end
                continue
            }
            let unit = units[index]
            index += 1
            guard unit == questionMark, consumed < parameters.count else {
                converted.append(unit)
                continue
            }
            if fitsURL, let value = escaped[consumed] {
                namedCount += 1
                let name = "p\(namedCount)"
                converted.append(contentsOf: "{\(name):String}".utf16)
                paramMap[name] = value
            } else {
                converted.append(contentsOf: literal(for: parameters[consumed], isInsertData: isInsertData).utf16)
            }
            consumed += 1
        }

        return Bound(query: String(decoding: converted, as: UTF16.self), params: paramMap)
    }

    private static let grammar = SQLLexicalReadings.resolve(
        databaseTypeId: ClickHousePlugin.databaseTypeId, declared: nil, session: nil
    ).execution

    private static let questionMark = UInt16(UnicodeScalar("?").value)

    // The server substitutes a String parameter as a plain literal, which also fits where no expression may stand,
    // such as IDENTIFIED BY. INSERT data is the exception: there a plain literal goes to the column's own parser, which
    // stores `{6f9619ff-...}` in a UUID column as a different UUID where the parameter was refused, and the cast keeps
    // the parameter's meaning.
    static func literal(for value: PluginCellValue, isInsertData: Bool) -> String {
        switch value {
        case .null:
            return "NULL"
        case .bytes(let data):
            return hexLiteral(data)
        case .text(let text):
            let quoted = "'\(ClickHousePluginDriver.escapeStringLiteral(text))'"
            return isInsertData ? "CAST(\(quoted) AS String)" : quoted
        }
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
            case "\0": escaped.append(contentsOf: "\\0".unicodeScalars)
            default: escaped.append(scalar)
            }
        }
        return String(escaped)
    }

    static func urlEncodedByteCount(_ value: String) -> Int {
        value.utf8.reduce(0) { total, byte in
            total + (ClickHousePluginDriver.isUnreservedURLByte(byte) ? 1 : 3)
        }
    }

    static func hexLiteral(_ data: Data) -> String {
        let hex = data.map { String(format: "%02X", $0) }.joined()
        return "unhex('\(hex)')"
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        unit < 0x80 && SQLNonCodeSpan.isWordUnit(unit)
    }
}
