//
//  BeancountDirectiveDetails.swift
//  BeancountDriverPlugin
//

import Foundation

struct BeancountDirectiveDetails: @unchecked Sendable {
    var notes: [[String: Any]] = []
    var balances: [[String: Any]] = []
}

/// Reads the two directive fields neither backend reports.
///
/// `rledger` fills `tags` and `links` on transaction entries only, so a note's own tags and links
/// come back empty, and neither backend exposes a balance assertion's explicit `~` tolerance at
/// all. Everything else about these directives, metadata included, comes from the backend.
enum BeancountDirectiveDetailsReader {
    static func read(sourceGraph: BeancountSourceGraph) -> BeancountDirectiveDetails {
        var details = BeancountDirectiveDetails()
        for sourceFile in sourceGraph.sourceFiles {
            guard let lines = sourceGraph.lines[sourceFile] else { continue }
            append(lines: lines, sourceURL: sourceFile, to: &details)
        }
        return details
    }

    static func read(contents: String, sourceURL: URL) -> BeancountDirectiveDetails {
        var details = BeancountDirectiveDetails()
        append(
            lines: BeancountSourceScanner.lines(of: contents),
            sourceURL: sourceURL,
            to: &details
        )
        return details
    }

    private static func append(
        lines: [String],
        sourceURL: URL,
        to details: inout BeancountDirectiveDetails
    ) {
        BeancountSourceScanner.scanDirectives(lines: lines, sourceURL: sourceURL) { directive in
            append(directive, to: &details)
        }
    }

    private static func append(
        _ directive: BeancountSourceDirective,
        to details: inout BeancountDirectiveDetails
    ) {
        let tokens = directive.tokens
        guard tokens.count >= 2, let date = BeancountSourceScanner.canonicalDate(tokens[0].value) else {
            return
        }

        switch tokens[1].value {
        case "note":
            guard tokens.count >= 4 else { return }
            details.notes.append([
                "date": date,
                "account": tokens[2].value,
                "comment": tokens[3].value,
                "tags": names(tokens.dropFirst(4), prefix: "#"),
                "links": names(tokens.dropFirst(4), prefix: "^")
            ])
        case "balance":
            guard tokens.count >= 5, let currency = tokens.last?.value else { return }
            var row: [String: Any] = [
                "date": date,
                "account": tokens[2].value,
                "currency": currency
            ]
            if let toleranceIndex = tokens.firstIndex(where: { $0.value == "~" }),
               toleranceIndex + 1 < tokens.count {
                row["tolerance"] = tokens[toleranceIndex + 1].value
            }
            details.balances.append(row)
        default:
            return
        }
    }

    private static func names(
        _ tokens: ArraySlice<BeancountSourceToken>,
        prefix: Character
    ) -> [String] {
        tokens.compactMap { token in
            guard !token.quoted, token.value.first == prefix else { return nil }
            return String(token.value.dropFirst())
        }
    }
}
