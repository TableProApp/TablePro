//
//  ClickHouseParameterBinding.swift
//  ClickHouseDriverPlugin
//

import Foundation
import TableProPluginKit

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

        // Scalars, not Characters: a combining mark after a quote would merge with it into one Character.
        let scalars = Array(query.unicodeScalars)
        var converted = String.UnicodeScalarView()
        converted.reserveCapacity(query.utf8.count)
        var paramMap: [String: String?] = [:]
        var consumed = 0
        var namedCount = 0
        var index = 0
        var firstWord: String?
        var isInsertData = false

        while index < scalars.count {
            let skipped = skippedEnd(in: scalars, from: index)
            if skipped > index {
                converted.append(contentsOf: scalars[index..<skipped])
                index = skipped
                continue
            }
            if isWordScalar(scalars[index]) {
                var end = index + 1
                while end < scalars.count, isWordScalar(scalars[end]) {
                    end += 1
                }
                let word = String(String.UnicodeScalarView(scalars[index..<end])).uppercased()
                firstWord = firstWord ?? word
                isInsertData = isInsertData || (firstWord == "INSERT" && word == "VALUES")
                converted.append(contentsOf: scalars[index..<end])
                index = end
                continue
            }
            let scalar = scalars[index]
            index += 1
            guard scalar == "?", consumed < parameters.count else {
                converted.append(scalar)
                continue
            }
            if fitsURL, let value = escaped[consumed] {
                namedCount += 1
                let name = "p\(namedCount)"
                converted.append(contentsOf: "{\(name):String}".unicodeScalars)
                paramMap[name] = value
            } else {
                converted.append(contentsOf: literal(for: parameters[consumed], isInsertData: isInsertData).unicodeScalars)
            }
            consumed += 1
        }

        return Bound(query: String(converted), params: paramMap)
    }

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

    // The spans SQLParameterExtractor skips when it writes the `?`s, so a `?` or a quote inside a string, a name, a
    // comment or a dollar-quoted body is never taken for a placeholder.
    private static func skippedEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        let next = start + 1 < scalars.count ? scalars[start + 1] : nil
        switch scalars[start] {
        case "'", "\"", "`":
            return quotedEnd(in: scalars, from: start)
        case "-" where next == "-":
            return scalars[start...].firstIndex(of: "\n") ?? scalars.count
        case "/" where next == "*":
            return blockCommentEnd(in: scalars, from: start)
        case "$":
            return dollarQuotedEnd(in: scalars, from: start) ?? start
        default:
            return start
        }
    }

    // ClickHouse reads backslash escapes inside all three quote forms. A doubled quote closes the span and opens the next.
    private static func quotedEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        let quote = scalars[start]
        var index = start + 1
        while index < scalars.count {
            if scalars[index] == "\\" {
                index += 2
                continue
            }
            if scalars[index] == quote {
                return index + 1
            }
            index += 1
        }
        return scalars.count
    }

    private static func blockCommentEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start + 2
        while index + 1 < scalars.count {
            if scalars[index] == "*" && scalars[index + 1] == "/" {
                return index + 2
            }
            index += 1
        }
        return scalars.count
    }

    // `$$...$$` or `$tag$...$tag$`, the tag made of letters, digits and underscores. An unclosed one runs to the end.
    private static func dollarQuotedEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var tagEnd = start + 1
        while tagEnd < scalars.count, isWordScalar(scalars[tagEnd]) {
            tagEnd += 1
        }
        guard tagEnd < scalars.count, scalars[tagEnd] == "$" else { return nil }
        let tag = Array(scalars[start...tagEnd])
        var index = tagEnd + 1
        while index + tag.count <= scalars.count {
            if scalars[index] == "$", Array(scalars[index..<index + tag.count]) == tag {
                return index + tag.count
            }
            index += 1
        }
        return scalars.count
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}
