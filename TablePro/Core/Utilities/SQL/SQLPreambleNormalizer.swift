//
//  SQLPreambleNormalizer.swift
//  TablePro
//

import Foundation

/// Collapses the options a user typed in front of a statement to one spelling, so
/// `explain  (analyze,buffers)` and `EXPLAIN (ANALYZE, BUFFERS)` are recognised as the same request.
///
/// Deliberately not `SQLQueryFingerprint`: that one replaces literals with `?`, which would erase
/// `COSTS off` and `FORMAT JSON`, the very options that decide whether two plans are comparable.
enum SQLPreambleNormalizer {
    static func normalize(_ sql: String) -> String {
        var components: [String] = []
        var token = ""

        func flush() {
            guard !token.isEmpty else { return }
            components.append(token.uppercased())
            token.removeAll(keepingCapacity: true)
        }

        for character in sql {
            if character.isLetter || character.isNumber || character == "_" {
                token.append(character)
                continue
            }
            flush()
            if !character.isWhitespace {
                components.append(String(character))
            }
        }
        flush()
        return components.joined(separator: " ")
    }
}
