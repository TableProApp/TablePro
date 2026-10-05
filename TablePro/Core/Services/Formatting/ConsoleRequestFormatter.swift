//
//  ConsoleRequestFormatter.swift
//  TablePro
//

import Foundation

/// Formats an Elasticsearch, Typesense or Weaviate document by re-indenting each JSON body and leaving
/// every other line as typed.
///
/// These engines highlight as JavaScript, but a request line is a URL and nothing in it can be reflowed:
/// `GET /_cat/indices/*` holds a `/*` that is a wildcard, and `?q=name:lamp` a colon that takes no space.
/// A body that is not exactly one JSON value, such as a GraphQL query or a browse query the grid encoded,
/// is left alone rather than guessed at.
struct ConsoleRequestFormatter: QueryFormatting {
    /// Endpoints that read one JSON document per line, where indenting even a single document turns it
    /// into several lines the endpoint reads as separate, broken records.
    private static let lineDelimitedEndpoints: Set<String> = ["_bulk", "_msearch", "_find_structure", "find_structure"]

    func format(_ text: String, cursorOffset: Int?) throws -> QueryFormatResult {
        let source = text as NSString
        var output = ""
        var bodyStart = 0
        var bodyIsLineDelimited = false
        var lineStart = 0

        while lineStart < source.length {
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            let line = source.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            if ConsoleRequestLine.opensRequest(line) {
                let body = source.substring(with: NSRange(location: bodyStart, length: lineStart - bodyStart))
                output += bodyIsLineDelimited ? body : Self.formattedBody(body)
                output += source.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
                bodyStart = lineEnd
                bodyIsLineDelimited = Self.takesLineDelimitedBody(line)
            }
            lineStart = lineEnd
        }
        let body = source.substring(from: bodyStart)
        output += bodyIsLineDelimited ? body : Self.formattedBody(body)

        // Trimmed like the other formatters: formatting a selection puts its own boundary whitespace back.
        return QueryFormatResult(text: Self.trimmingWhitespace(output), cursorOffset: nil)
    }

    static func takesLineDelimitedBody(_ requestLine: String) -> Bool {
        let words = requestLine.split(maxSplits: 2, whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return false }
        let path = words[1].split(separator: "?", maxSplits: 1).first ?? ""
        let components = path.split(separator: "/").map { $0.lowercased() }
        if components.contains(where: lineDelimitedEndpoints.contains) {
            return true
        }
        return Array(components.suffix(2)) == ["documents", "import"]
    }

    /// The body with its JSON value re-indented and the blank lines around it kept.
    ///
    /// A trailing semicolon is kept too: the editor splits these documents at semicolons, so it is the
    /// separator between two requests rather than part of the body.
    private static func formattedBody(_ body: String) -> String {
        let leading = body.prefix(while: \.isWhitespace)
        let rest = body.dropFirst(leading.count)
        let trailingCount = rest.reversed().prefix(while: \.isWhitespace).count
        var value = rest.dropLast(trailingCount)
        guard !value.isEmpty else { return body }

        let isTerminated = value.last == ";"
        if isTerminated {
            value = value.dropLast()
        }
        guard let indented = JsonReindenter.reindentIfValid(String(value)) else { return body }
        return String(leading) + indented + (isTerminated ? ";" : "") + String(rest.suffix(trailingCount))
    }

    private static func trimmingWhitespace(_ text: String) -> String {
        let leadingCount = text.prefix(while: \.isWhitespace).count
        let rest = text.dropFirst(leadingCount)
        return String(rest.dropLast(rest.reversed().prefix(while: \.isWhitespace).count))
    }
}
