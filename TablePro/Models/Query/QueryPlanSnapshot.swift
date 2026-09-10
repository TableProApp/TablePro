//
//  QueryPlanSnapshot.swift
//  TablePro
//
//  A saved EXPLAIN plan, and the identity that decides which saved plans are comparable.
//
//  Identity is the statement's fingerprint rather than its text. `SQLQueryFingerprint` already
//  folds literals, whitespace, comments and identifier quoting the way `pg_stat_statements` does,
//  and every history row already stores and indexes the same hash, so a reformatted or
//  re-parameterized statement keeps its chain of earlier plans instead of starting a new one.
//

import Foundation
import TableProPluginKit

/// Where a plan was produced. Two plans from different databases describe different work even when
/// the statement is spelled the same way.
struct QueryPlanScope: Hashable, Sendable {
    let connectionId: UUID
    let databaseType: DatabaseType
    let databaseName: String
    let schemaName: String?
}

/// The scope two plans have to share before comparing them means anything: the same statement
/// shape, on the same database, asked the same way.
struct QueryPlanIdentity: Hashable, Sendable {
    let fingerprintHash: Int64
    let scope: QueryPlanScope
    let variantKey: QueryPlanVariantKey
    let format: ExplainPlanFormat
}

/// Which flavour of EXPLAIN produced the plan. A plain `EXPLAIN` and an `EXPLAIN ANALYZE` describe
/// the same statement but report different things, so they are separate chains.
///
/// Spelled out rather than hashed: a stored key a developer can read is one they can debug, and it
/// is what the baseline picker shows the user.
struct QueryPlanVariantKey: Hashable, Sendable, RawRepresentable {
    /// Long enough for any real EXPLAIN preamble, short enough that a pathological statement cannot
    /// grow the index entry without bound.
    static let maximumLength = 200

    let rawValue: String

    init(rawValue: String) {
        self.rawValue = String(rawValue.prefix(Self.maximumLength))
    }

    /// A variant the driver declared. Its identifier is stable across releases, so it keys the
    /// chain directly.
    static func declared(_ variantId: String) -> QueryPlanVariantKey {
        QueryPlanVariantKey(rawValue: "variant:\(variantId)")
    }

    /// A statement the user typed themselves. The preamble is normalized to uppercase tokens so
    /// `explain  (analyze)` and `EXPLAIN (ANALYZE)` are one chain.
    static func typed(preamble: String) -> QueryPlanVariantKey {
        QueryPlanVariantKey(rawValue: "sql:\(SQLPreambleNormalizer.normalize(preamble))")
    }

    /// The driver built the statement and told us nothing about it.
    static let driverBuilt = QueryPlanVariantKey(rawValue: "driver")

    /// What the baseline picker shows beside a run. The prefix is machinery, not something to read.
    var displayName: String {
        if let value = rawValue.dropPrefixIfPresent("sql:"), !value.isEmpty { return value }
        if let value = rawValue.dropPrefixIfPresent("variant:"), !value.isEmpty { return value }
        return rawValue
    }
}

/// One stored plan, with the raw text loaded.
struct QueryPlanSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let identity: QueryPlanIdentity
    let subjectSQL: String
    let rawPlan: String
    let executionTime: TimeInterval
    let capturedAt: Date
    let isPinned: Bool
}

/// A row of the baseline list. Deliberately carries no plan text: a list of fifty runs would
/// otherwise pull fifty plans into memory to draw fifty dates.
struct QueryPlanSnapshotSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let subjectSQL: String
    let executionTime: TimeInterval
    let capturedAt: Date
    let isPinned: Bool
    let byteCount: Int
}

/// What a finished EXPLAIN offers the store, before the store decides whether to keep it.
struct QueryPlanCapture: Sendable {
    let id: UUID
    let identity: QueryPlanIdentity
    let subjectSQL: String
    let rawPlan: String
    let executionTime: TimeInterval
    let capturedAt: Date
    let historyId: UUID?

    var byteCount: Int { rawPlan.utf8.count }

    var isWithinPlanSizeLimit: Bool { byteCount <= QueryPlanStorageLimits.maximumPlanByteCount }
}

enum QueryPlanStorageLimits {
    /// A single plan larger than this is a dump rather than a plan, and storing it would cost more
    /// than every other plan put together.
    static let maximumPlanByteCount = 2_000_000

    /// Ceiling on everything unpinned, enforced on the same cadence as query-history retention.
    static let maximumTotalByteCount: Int64 = 100_000_000
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
