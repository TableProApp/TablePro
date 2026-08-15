//
//  ExplainResultRouter.swift
//  TablePro
//
//  Decides whether the result of a hand-typed statement is a query plan rather than a grid.
//

import Foundation
import TableProPluginKit

enum ExplainResultRouter {
    struct RoutedPlan {
        let rawText: String
        let plan: QueryPlan?
    }

    /// A plan either arrives in one column, or is multi-column output the app can actually read
    /// as a tree. Requiring a successful parse for the multi-column case is what lets SQLite's
    /// four-column `EXPLAIN QUERY PLAN` reach the viewer while MySQL's tabular `EXPLAIN`, which
    /// no parser understands, stays in the results grid where it belongs.
    static func route(
        sql: String,
        columns: [String],
        rows: [[PluginCellValue]],
        databaseType: DatabaseType,
        declaredVariants: [ExplainVariant]
    ) -> RoutedPlan? {
        guard QueryClassifier.isExplainStatement(sql) else { return nil }

        let text = ExplainPlanTextFlattener.flatten(rows: rows)
        guard !text.isEmpty else { return nil }

        let format = ExplainFormatResolver.resolve(
            sql: sql, databaseType: databaseType, declaredVariants: declaredVariants
        )
        let plan = ExplainPlanParserRegistry.plan(from: text, format: format)

        guard columns.count == 1 || plan != nil else { return nil }
        return RoutedPlan(rawText: text, plan: plan)
    }
}
