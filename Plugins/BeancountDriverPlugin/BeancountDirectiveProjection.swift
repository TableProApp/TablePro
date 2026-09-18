//
//  BeancountDirectiveProjection.swift
//  BeancountDriverPlugin
//

import Foundation

struct BeancountDirectiveProjection: @unchecked Sendable {
    var queries: [[String: Any]] = []
    var custom: [[String: Any]] = []
}

/// Projects `query` and `custom` directives, which neither backend reports.
///
/// `rledger` exposes no `#queries` or `#custom` table and its `#entries` rows carry no name, query
/// text or value list for either, so both are read from the ledger source through
/// `BeancountSourceScanner`.
enum BeancountDirectiveProjectionReader {
    static func read(sourceGraph: BeancountSourceGraph) -> BeancountDirectiveProjection {
        var projection = BeancountDirectiveProjection()
        for sourceFile in sourceGraph.sourceFiles {
            guard let lines = sourceGraph.lines[sourceFile] else { continue }
            append(lines: lines, sourceURL: sourceFile, to: &projection)
        }
        return projection
    }

    static func read(contents: String, sourceURL: URL) -> BeancountDirectiveProjection {
        var projection = BeancountDirectiveProjection()
        append(
            lines: BeancountSourceScanner.lines(of: contents),
            sourceURL: sourceURL,
            to: &projection
        )
        return projection
    }

    private static func append(
        lines: [String],
        sourceURL: URL,
        to projection: inout BeancountDirectiveProjection
    ) {
        BeancountSourceScanner.scanDirectives(lines: lines, sourceURL: sourceURL) { directive in
            append(directive, to: &projection)
        }
    }

    private static func append(
        _ directive: BeancountSourceDirective,
        to projection: inout BeancountDirectiveProjection
    ) {
        let tokens = directive.tokens
        guard tokens.count >= 4, let date = BeancountSourceScanner.canonicalDate(tokens[0].value) else {
            return
        }
        let source: [String: Any] = [
            "filename": directive.sourceURL.path,
            "lineno": directive.lineNumber,
            "location": "\(directive.sourceURL.path):\(directive.lineNumber)"
        ]

        switch tokens[1].value {
        case "query":
            guard tokens[2].quoted, tokens[3].quoted else { return }
            projection.queries.append(source.merging([
                "date": date,
                "name": tokens[2].value,
                "query": tokens[3].value
            ], uniquingKeysWith: { _, new in new }))
        case "custom":
            guard tokens[2].quoted else { return }
            let customID = projection.custom.count + 1
            projection.custom.append(source.merging([
                "id": customID,
                "date": date,
                "type": tokens[2].value,
                "values": customValues(Array(tokens.dropFirst(3)))
            ], uniquingKeysWith: { _, new in new }))
        default:
            return
        }
    }

    private static func customValues(_ tokens: [BeancountSourceToken]) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.quoted {
                rows.append(["value_type": "string", "value": token.value])
            } else if let date = BeancountSourceScanner.canonicalDate(token.value) {
                rows.append(["value_type": "date", "value": date])
            } else if token.value == "TRUE" || token.value == "FALSE" {
                rows.append(["value_type": "boolean", "value": token.value])
            } else if isNumber(token.value), index + 1 < tokens.count,
                      isCurrency(tokens[index + 1].value) {
                let currency = tokens[index + 1].value
                rows.append([
                    "value_type": "amount",
                    "value": "\(token.value) \(currency)",
                    "number": token.value,
                    "currency": currency
                ])
                index += 1
            } else if token.value.contains(":") {
                rows.append(["value_type": "account", "value": token.value])
            } else if isNumber(token.value) {
                rows.append([
                    "value_type": "number",
                    "value": token.value,
                    "number": token.value
                ])
            }
            index += 1
        }
        return rows
    }

    private static func isNumber(_ value: String) -> Bool {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) != nil
    }

    private static func isCurrency(_ value: String) -> Bool {
        guard let first = value.first, first.isUppercase else { return false }
        return value.allSatisfy { $0.isUppercase || $0.isNumber || "'._-".contains($0) }
    }
}
