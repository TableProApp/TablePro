//
//  PostgreSQLCheckConstraintDefinition.swift
//  PostgreSQLDriverPlugin
//
//  Reduces pg_get_constraintdef output to the bare CHECK expression.
//  Compiled into the test target via project.yml.
//

import Foundation

enum PostgreSQLCheckConstraintDefinition {
    /// `pg_get_constraintdef` returns the whole clause, not the expression: `CHECK ((a > 0))`, and
    /// `CHECK ((a < 1000)) NOT VALID` for an unvalidated one. The grid edits an expression, so the
    /// keyword, the wrapping parentheses and the trailing flag come off.
    ///
    /// Only the parentheses PostgreSQL itself added are removed. `(a > 0) AND (b > 0)` keeps both
    /// of its pairs because neither wraps the whole expression, which a naive trim of the first and
    /// last character would break.
    static func expression(fromConstraintDef definition: String) -> String {
        var text = definition.trimmingCharacters(in: .whitespacesAndNewlines)

        for suffix in ["NOT VALID", "NO INHERIT"] where text.uppercased().hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard text.uppercased().hasPrefix("CHECK") else { return text }
        text = String(text.dropFirst("CHECK".count)).trimmingCharacters(in: .whitespacesAndNewlines)

        return strippingEnclosingParentheses(text)
    }

    private static func strippingEnclosingParentheses(_ text: String) -> String {
        var current = text
        while current.hasPrefix("("), current.hasSuffix(")"), enclosesWholeExpression(current) {
            current = String(current.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return current
    }

    /// True when the leading parenthesis is the one the trailing parenthesis closes.
    private static func enclosesWholeExpression(_ text: String) -> Bool {
        var depth = 0
        var insideLiteral = false
        for (offset, character) in text.enumerated() {
            if character == "'" {
                insideLiteral.toggle()
                continue
            }
            guard !insideLiteral else { continue }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return offset == text.count - 1 }
            }
        }
        return false
    }
}
