//
//  MongoDBFilterClause.swift
//  MongoDBDriverPlugin
//

import Foundation

/// One condition as its own key and body, kept apart rather than pre-joined so that combining
/// several of them can see when two would claim the same key. A JSON object cannot hold a key
/// twice, and several operators emit `$or` or `$nor` at the top level, so merging them blindly
/// drops every clause but the last.
struct MongoDBFilterClause {
    let key: String
    let body: String

    var json: String {
        "\"\(key)\": \(body)"
    }

    /// Merge into a single document, falling back to `$and` when two clauses claim the same key.
    static func document(_ clauses: [MongoDBFilterClause]) -> String? {
        guard let merged = merge(clauses) else { return nil }
        return "{\(merged)}"
    }

    /// Merge into the body of an enclosing document, without the braces.
    static func merge(_ clauses: [MongoDBFilterClause]) -> String? {
        guard !clauses.isEmpty else { return nil }
        if clauses.count == 1 { return clauses[0].json }

        var seen = Set<String>()
        let collides = clauses.contains { !seen.insert($0.key).inserted }
        guard collides else {
            return clauses.map(\.json).joined(separator: ", ")
        }
        let wrapped = clauses.map { "{\($0.json)}" }
        return "\"$and\": [\(wrapped.joined(separator: ", "))]"
    }
}
