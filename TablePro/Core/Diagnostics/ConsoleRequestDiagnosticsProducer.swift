import Foundation

/// Underlines what a console request can never send: a JSON body whose brackets do not close.
///
/// Elasticsearch, Typesense and Weaviate highlight as JavaScript because their bodies are JSON, but
/// the document is an HTTP request line followed by that body, not a JavaScript program. Parsed as
/// one, every `"query": {` is a syntax error.
///
/// The request line is left out of the scan because it is a URL: `GET /_cat/indices/*` holds a
/// `/*` that is a wildcard, not the start of a comment, and a query string may hold any bracket.
/// Like the console parsers, only the document's first line is read as the request line.
struct ConsoleRequestDiagnosticsProducer: QueryDiagnosticsProducing {
    func diagnostics(for text: String) -> [QueryDiagnostic] {
        let source = text as NSString
        guard source.length > 0, source.length <= QueryDiagnosticsLimits.maximumDocumentLength else { return [] }

        // The body highlights as JavaScript, so `//` and `/* */` read as comments on screen and the
        // scan has to read them the same way.
        let structure = QueryBracketScanner.scan(blankingRequestLine(source), comments: .javaScript)
        var results: [QueryDiagnostic] = []

        if let range = structure.unmatchedClose {
            results.append(QueryDiagnostic(range: range, message: String(localized: "No matching opening bracket")))
        }
        if let range = structure.unterminatedComment {
            results.append(QueryDiagnostic(range: range, message: String(localized: "Unterminated comment")))
        }

        return results
    }

    /// The document with its request line replaced by spaces, when its first line is one.
    ///
    /// Blanked rather than removed, so a range the scan reports still points at the text the reader typed.
    /// Weaviate also takes a body on the request line itself, `POST /objects {"class": "Article"}`, so text
    /// after the path that opens like JSON stays in the scan.
    private func blankingRequestLine(_ source: NSString) -> NSString {
        let firstVisible = source.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        guard firstVisible.location != NSNotFound else { return source }

        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: firstVisible)
        let lineText = source.substring(with: NSRange(location: firstVisible.location, length: contentsEnd - firstVisible.location))
        let words = lineText.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard let method = words.first, ConsoleRequestLine.methods.contains(method.uppercased()) else { return source }

        var requestEnd = lineText.endIndex
        if words.count == 3, let opener = words[2].first, opener == "{" || opener == "[" {
            requestEnd = words[2].startIndex
        }
        let request = NSRange(lineText.startIndex ..< requestEnd, in: lineText)
        let blanked = NSMutableString(string: source)
        blanked.replaceCharacters(
            in: NSRange(location: firstVisible.location, length: request.length),
            with: String(repeating: " ", count: request.length)
        )
        return blanked
    }
}
