//
//  ExplainRequest.swift
//  TablePro
//
//  The SQL an EXPLAIN run sends and the format its output will come back in.
//

import Foundation
import TableProPluginKit

struct ExplainRequest: Equatable {
    let sql: String
    let subjectSQL: String
    let format: ExplainPlanFormat
    let variantId: String?

    /// A driver that declares no variants and builds its own statement may return anything,
    /// including a multi-column document. Those results go through the ordinary query pipeline
    /// so they keep their grid rather than being forced into a plan pane.
    let isDriverBuilt: Bool

    /// Picks the variant to run: the one the user chose, otherwise the driver's first declared
    /// one. Returns nil when the driver declares none, which is the caller's cue to fall back to
    /// `buildExplainQuery`.
    static func make(
        variant: ExplainVariant?,
        declaredVariants: [ExplainVariant],
        databaseType: DatabaseType,
        statement: String
    ) -> ExplainRequest? {
        guard let resolved = variant ?? declaredVariants.first else { return nil }
        return ExplainRequest(
            sql: "\(resolved.sqlPrefix) \(statement)",
            subjectSQL: statement,
            format: ExplainFormatResolver.resolve(declared: resolved.format, databaseType: databaseType),
            variantId: resolved.id,
            isDriverBuilt: false
        )
    }

    static func driverBuilt(
        sql: String,
        databaseType: DatabaseType,
        subjectSQL: String? = nil
    ) -> ExplainRequest {
        ExplainRequest(
            sql: sql,
            subjectSQL: subjectSQL ?? sql,
            format: ExplainFormatResolver.resolve(declared: .plainText, databaseType: databaseType),
            variantId: nil,
            isDriverBuilt: true
        )
    }
}
