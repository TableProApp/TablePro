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
        let variantId: String?
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
            variantId: historyVariantIdentifier(
                explainSQL: explainSQL,
                subjectSQL: subjectSQL,
                declaredVariants: declaredVariants,
                fallback: variant?.id
            ),
            subjectSQL: subjectSQL
        )
    }

    private static func historyVariantIdentifier(
        explainSQL: String,
        subjectSQL: String,
        declaredVariants: [ExplainVariant],
        fallback: String?
    ) -> String? {
        guard let subjectRange = explainSQL.range(
            of: subjectSQL,
            options: [.literal, .backwards]
        ) else { return fallback }

        let preamble = normalizePreamble(String(explainSQL[..<subjectRange.lowerBound]))
        guard !preamble.isEmpty else { return fallback }

        if let declared = declaredVariants.first(where: {
            normalizePreamble($0.sqlPrefix) == preamble
        }) {
            return declared.id
        }
        return "__typed_explain__:\(preamble.sha256)"
    }

    private static func normalizePreamble(_ sql: String) -> String {
        var components: [String] = []
        var token = ""

        func appendToken() {
            guard !token.isEmpty else { return }
            components.append(token.uppercased())
            token.removeAll(keepingCapacity: true)
        }

        for character in sql {
            if character.isLetter || character.isNumber || character == "_" {
                token.append(character)
            } else {
                appendToken()
                if !character.isWhitespace {
                    components.append(String(character))
                }
            }
        }
        appendToken()
        return components.joined(separator: " ")
    }
}
