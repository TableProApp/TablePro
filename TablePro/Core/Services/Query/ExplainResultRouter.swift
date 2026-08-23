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
        let format: ExplainPlanFormat
        let variantKey: QueryPlanVariantKey
        let subjectSQL: String
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

        let explainSQL = QueryClassifier.strippingLeadingComments(sql)
        let variant = ExplainFormatResolver.matchingVariant(
            sql: explainSQL, declaredVariants: declaredVariants
        )
        let format = ExplainFormatResolver.resolve(
            declared: variant?.format ?? .plainText, databaseType: databaseType
        )
        let plan = ExplainPlanParserRegistry.plan(from: text, format: format)

        guard columns.count == 1 || plan != nil else { return nil }

        let subjectSQL = QueryClassifier.explainedStatement(in: explainSQL) ?? sql
        return RoutedPlan(
            rawText: text,
            plan: plan,
            format: format,
            variantKey: variantKey(
                explainSQL: explainSQL,
                subjectSQL: subjectSQL,
                declaredVariants: declaredVariants,
                matched: variant
            ),
            subjectSQL: subjectSQL
        )
    }

    /// Which chain of saved plans this run belongs to.
    ///
    /// A typed `EXPLAIN (ANALYZE, BUFFERS)` and a plain `EXPLAIN` describe the same statement but
    /// report different things, so they are separate chains. The options the user typed are the
    /// only thing that distinguishes them, and they are keyed by their normalized spelling rather
    /// than by a digest of it, so a stored key stays readable in the picker and in a database
    /// browser.
    ///
    /// A typed statement that happens to spell a variant the driver declares is folded onto that
    /// variant's key, so running EXPLAIN from the toolbar and typing the same thing by hand share
    /// one history.
    private static func variantKey(
        explainSQL: String,
        subjectSQL: String,
        declaredVariants: [ExplainVariant],
        matched: ExplainVariant?
    ) -> QueryPlanVariantKey {
        guard let subjectRange = explainSQL.range(of: subjectSQL, options: [.literal, .backwards]) else {
            return matched.map { .declared($0.id) } ?? .driverBuilt
        }

        let preamble = SQLPreambleNormalizer.normalize(String(explainSQL[..<subjectRange.lowerBound]))
        guard !preamble.isEmpty else {
            return matched.map { .declared($0.id) } ?? .driverBuilt
        }
        if let declared = declaredVariants.first(where: {
            SQLPreambleNormalizer.normalize($0.sqlPrefix) == preamble
        }) {
            return .declared(declared.id)
        }
        return .typed(preamble: preamble)
    }
}
