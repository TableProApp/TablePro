//
//  ConsoleRequestLine.swift
//  TablePro
//

import Foundation

/// The line that opens a console request, `GET /_cat/indices`, in an Elasticsearch, Typesense or
/// Weaviate document.
enum ConsoleRequestLine {
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]

    /// Whether the line's first word is an HTTP method, which is how the console parsers find a request.
    static func opensRequest(_ line: String) -> Bool {
        guard let firstWord = line.split(maxSplits: 1, whereSeparator: \.isWhitespace).first else { return false }
        return methods.contains(firstWord.uppercased())
    }
}
