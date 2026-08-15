//
//  ExplainResultRouter.swift
//  TablePro
//
//  Decides whether the result of a hand-typed statement is a query plan rather than a grid.
//

import Foundation
import TableProPluginKit

enum ExplainResultRouter {
    /// A plan either arrives in one column, or comes from a statement whose prefix matches an
    /// EXPLAIN variant the driver declares. The second arm is what lets SQLite's four-column
    /// `EXPLAIN QUERY PLAN` reach the viewer, without pulling in a maintenance command such as
    /// MySQL's `ANALYZE TABLE`, which `isExplainStatement` also matches but no variant declares.
    static func planText(
        sql: String,
        columns: [String],
        rows: [[PluginCellValue]],
        declaredVariants: [ExplainVariant]
    ) -> String? {
        guard QueryClassifier.isExplainStatement(sql) else { return nil }

        let isDeclaredVariant = ExplainFormatResolver.matchingVariant(
            sql: sql, declaredVariants: declaredVariants
        ) != nil
        guard columns.count == 1 || isDeclaredVariant else { return nil }

        let text = ExplainPlanTextFlattener.flatten(rows: rows)
        return text.isEmpty ? nil : text
    }
}
