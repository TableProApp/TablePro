//
//  MSSQLCheckConstraintDefinition.swift
//  MSSQLDriverPlugin
//
//  Reduces sys.check_constraints.definition to the bare expression.
//  Compiled into the test target via project.yml.
//

import Foundation

enum MSSQLCheckConstraintDefinition {
    /// SQL Server stores a re-parenthesised form rather than the text that was typed: `a > 0`
    /// comes back as `([a]>(0))`. Only the pair wrapping the whole expression is removed; the
    /// brackets and the operand parentheses are what the server will hand back next time either
    /// way, so rewriting them would only invent a difference.
    static func expression(fromDefinition definition: String) -> String {
        let trimmed = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("("), trimmed.hasSuffix(")"), enclosesWholeExpression(trimmed) else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
