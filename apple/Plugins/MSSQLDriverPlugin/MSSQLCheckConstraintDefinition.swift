//
//  MSSQLCheckConstraintDefinition.swift
//  MSSQLDriverPlugin
//
//  Reduces sys.check_constraints.definition to the bare expression.
//

import Foundation
import TableProMSSQLCore

enum MSSQLCheckConstraintDefinition {
    // SQL Server stores `a > 0` as `([a]>(0))`; only the pair around the whole expression is removed.
    static func expression(fromDefinition definition: String) -> String {
        let trimmed = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        var scalars = trimmed.unicodeScalars
        guard scalars.first == "(", scalars.last == ")", MSSQLDefinitionText.isParenthesizedExpression(trimmed) else {
            return trimmed
        }
        scalars.removeFirst()
        scalars.removeLast()
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
