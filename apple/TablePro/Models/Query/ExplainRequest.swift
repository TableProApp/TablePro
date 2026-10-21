//
//  ExplainRequest.swift
//  TablePro
//
//  The SQL an EXPLAIN run sends and the format its output will come back in.
//

import Foundation
import TableProPluginKit

struct ExplainRequest: Equatable {
    struct DriverStep: Equatable {
        let variantId: String
        let runsStatement: Bool
    }

    // The statement alone for a driver plan: no single text reproduces a plan the driver assembles.
    let sql: String
    let subjectSQL: String
    let format: ExplainPlanFormat

    /// Which chain of saved plans a run of this request belongs to. Shared with the hand-typed
    /// path, so the Explain action and the same statement typed into the editor build one history
    /// rather than two.
    let variantKey: QueryPlanVariantKey

    let driverStep: DriverStep?

    /// Picks the variant to run: the one the user chose, otherwise the driver's first declared
    /// one. Returns nil when the driver declares none, because an engine that declares no plan
    /// has nothing to explain.
    static func make(
        variant: ExplainVariant?,
        declaredVariants: [ExplainVariant],
        databaseType: DatabaseType,
        statement: String
    ) -> ExplainRequest? {
        guard let resolved = variant ?? declaredVariants.first else { return nil }
        let driverStep: DriverStep?
        let sql: String
        switch resolved.step {
        case .sqlPrefix:
            driverStep = nil
            sql = "\(resolved.sqlPrefix) \(statement)"
        case .driver(let runsStatement):
            driverStep = DriverStep(variantId: resolved.id, runsStatement: runsStatement)
            sql = statement
        @unknown default:
            // A step from a newer kit is not run as a prefix: an empty prefix would run the statement itself.
            return nil
        }
        return ExplainRequest(
            sql: sql,
            subjectSQL: statement,
            format: ExplainFormatResolver.resolve(declared: resolved.format, databaseType: databaseType),
            variantKey: .declared(resolved.id),
            driverStep: driverStep
        )
    }

    // Rerunning a driver plan's subject would run the statement the plan only described.
    var replayableSQL: String? {
        driverStep == nil ? sql : nil
    }

    // What the execution gate classifies, which reads the text as well as the kind.
    var gatedSQL: String {
        driverStep.map { Self.gatedSQL(subject: subjectSQL, runsStatement: $0.runsStatement) } ?? sql
    }

    func operationKind(databaseType: DatabaseType) -> OperationKind {
        OperationKind.worst(of: [gatedSQL], databaseType: databaseType)
    }

    // A plan that only plans the statement is gated as a plain EXPLAIN of it. A SET or USE is not planned: SQL Server
    // runs it even with SHOWPLAN on, so it is gated as itself.
    static func gatedSQL(subject: String, runsStatement: Bool) -> String {
        guard !runsStatement else { return subject }
        let planned = "EXPLAIN \(subject)"
        return QueryClassifier.explainedStatement(in: planned) == nil ? subject : planned
    }
}
