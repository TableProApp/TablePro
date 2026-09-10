//
//  ExplainFormatResolver.swift
//  TablePro
//
//  Resolves which plan format a piece of EXPLAIN output is in, for both the Explain action
//  (where the variant is known) and a hand-typed statement (where only the SQL is).
//

import Foundation
import TableProPluginKit

enum ExplainFormatResolver {
    static func resolve(declared: ExplainPlanFormat, databaseType: DatabaseType) -> ExplainPlanFormat {
        guard declared == .plainText else { return declared }
        return ExplainPlanFormatDefaults.format(for: databaseType)
    }

    static func resolve(
        sql: String,
        databaseType: DatabaseType,
        declaredVariants: [ExplainVariant]
    ) -> ExplainPlanFormat {
        let declared = matchingVariant(sql: sql, declaredVariants: declaredVariants)?.format ?? .plainText
        return resolve(declared: declared, databaseType: databaseType)
    }

    /// The declared variant whose SQL prefix the statement starts with. Longest prefix wins so
    /// `EXPLAIN FORMAT=JSON ...` matches the JSON variant rather than the bare `EXPLAIN` one.
    static func matchingVariant(sql: String, declaredVariants: [ExplainVariant]) -> ExplainVariant? {
        let normalized = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        return declaredVariants
            .filter { !$0.sqlPrefix.isEmpty }
            .filter { normalized.range(of: $0.sqlPrefix, options: [.caseInsensitive, .anchored]) != nil }
            .max { $0.sqlPrefix.count < $1.sqlPrefix.count }
    }
}
