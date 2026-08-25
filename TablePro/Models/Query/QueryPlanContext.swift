//
//  QueryPlanContext.swift
//  TablePro
//
//  What a rendered EXPLAIN result knows about its own place in the plan history, and the single
//  builder both EXPLAIN paths go through.
//
//  There are two ways a plan reaches the app: the Explain action, which knows the variant it asked
//  for, and a statement the user typed, which is recognised as a plan only after it comes back.
//  They used to build this independently and had already drifted on where the database name came
//  from, which is enough to split one statement's history into two chains that never compare.
//

import Foundation
import TableProPluginKit

/// Why this run's plan was not saved. The comparison pane says so rather than showing an empty list
/// that reads like a missing feature.
enum QueryPlanCaptureSkipReason: Hashable, Sendable {
    /// The statement carried bind values, and a database is free to echo them into its plan output.
    case parameterized
    /// Larger than `QueryPlanStorageLimits.maximumPlanByteCount`.
    case tooLarge

    var explanation: String {
        switch self {
        case .parameterized:
            return String(localized: "Plans are not saved for queries that carry parameters, because a database can print the values into its plan output.")
        case .tooLarge:
            return String(localized: "This plan is too large to save.")
        }
    }
}

/// Travels on the `ResultSet` so the plan pane can offer a comparison without asking a coordinator
/// anything.
struct QueryPlanContext: Hashable, Sendable, Identifiable {
    let id: UUID
    let identity: QueryPlanIdentity
    let subjectSQL: String
    let capturedAt: Date
    let executionTime: TimeInterval

    /// Nil when this run was not stored, in which case `skipReason` says why.
    let storedSnapshotId: UUID?
    let skipReason: QueryPlanCaptureSkipReason?

    var isStored: Bool { storedSnapshotId != nil }
}

enum QueryPlanCaptureBuilder {
    /// Builds the context every EXPLAIN result carries, and the capture the store is offered when
    /// the run is one we may keep.
    ///
    /// `capturedAt` is passed in rather than read here so the context, the capture and the history
    /// row that links them all carry the same instant.
    static func make(
        subjectSQL: String,
        rawPlan: String,
        format: ExplainPlanFormat,
        variantKey: QueryPlanVariantKey,
        scope: QueryPlanScope,
        executionTime: TimeInterval,
        capturedAt: Date,
        historyId: UUID,
        queryParameters: [QueryParameter]?
    ) -> (context: QueryPlanContext, capture: QueryPlanCapture?) {
        let identity = QueryPlanIdentity(
            fingerprintHash: SQLQueryFingerprint.hash(subjectSQL, databaseType: scope.databaseType),
            scope: scope,
            variantKey: variantKey,
            format: format
        )
        let snapshotId = UUID()
        let capture = QueryPlanCapture(
            id: snapshotId,
            identity: identity,
            subjectSQL: subjectSQL,
            rawPlan: rawPlan,
            executionTime: executionTime,
            capturedAt: capturedAt,
            historyId: historyId
        )

        let skipReason: QueryPlanCaptureSkipReason?
        if queryParameters?.isEmpty == false {
            skipReason = .parameterized
        } else if !capture.isWithinPlanSizeLimit {
            skipReason = .tooLarge
        } else {
            skipReason = nil
        }

        let context = QueryPlanContext(
            id: snapshotId,
            identity: identity,
            subjectSQL: subjectSQL,
            capturedAt: capturedAt,
            executionTime: executionTime,
            storedSnapshotId: skipReason == nil ? snapshotId : nil,
            skipReason: skipReason
        )
        return (context, skipReason == nil ? capture : nil)
    }
}
