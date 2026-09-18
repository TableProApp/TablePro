//
//  TableLoadPerformanceRecord.swift
//  TablePro
//

import Foundation

internal enum TableLoadRowBucket: String, Sendable, CaseIterable {
    case none = "0"
    case upTo100 = "1-100"
    case upTo1000 = "101-1000"
    case upTo10000 = "1001-10000"
    case above10000 = ">10000"

    internal init(rowCount: Int) {
        switch rowCount {
        case ..<1: self = .none
        case ..<101: self = .upTo100
        case ..<1_001: self = .upTo1000
        case ..<10_001: self = .upTo10000
        default: self = .above10000
        }
    }
}

/// A statement that returns no columns is a real result, so it gets a bucket of its own rather than
/// being folded into the first one and reported as a result that had between one and twenty columns.
internal enum TableLoadColumnBucket: String, Sendable, CaseIterable {
    case none = "0"
    case upTo20 = "1-20"
    case upTo100 = "21-100"
    case upTo500 = "101-500"
    case above500 = ">500"

    internal init(columnCount: Int) {
        switch columnCount {
        case ..<1: self = .none
        case ..<21: self = .upTo20
        case ..<101: self = .upTo100
        case ..<501: self = .upTo500
        default: self = .above500
        }
    }
}

internal enum TableLoadResultSizeBucket: String, Sendable, CaseIterable {
    case underOneMegabyte = "<1MB"
    case upTo10Megabytes = "1-10MB"
    case upTo100Megabytes = "10-100MB"
    case above100Megabytes = ">100MB"

    private static let megabyte = 1_024 * 1_024

    internal init(byteCount: Int) {
        switch byteCount {
        case ..<Self.megabyte: self = .underOneMegabyte
        case ..<(10 * Self.megabyte): self = .upTo10Megabytes
        case ..<(100 * Self.megabyte): self = .upTo100Megabytes
        default: self = .above100Megabytes
        }
    }
}

internal enum TableLoadOpenTabBucket: String, Sendable, CaseIterable {
    case none = "0"
    case one = "1"
    case upTo5 = "2-5"
    case upTo10 = "6-10"
    case upTo30 = "11-30"
    case above30 = ">30"

    internal init(tabCount: Int) {
        switch tabCount {
        case ..<1: self = .none
        case 1: self = .one
        case ..<6: self = .upTo5
        case ..<11: self = .upTo10
        case ..<31: self = .upTo30
        default: self = .above30
        }
    }
}

/// The build and the OS the measurement came from, so a history that spans an app update can say
/// whether performance changed with it. Resolved once per process rather than per record.
internal struct TableLoadRuntimeStamp: Sendable, Equatable {
    internal static let current = TableLoadRuntimeStamp(
        appVersion: Bundle.main.appVersion,
        appBuild: Bundle.main.buildNumber,
        osVersion: TableLoadRuntimeStamp.systemVersion()
    )

    internal let appVersion: String
    internal let appBuild: String
    internal let osVersion: String

    private static func systemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

/// One persisted line of the local performance history.
///
/// Everything here is either a duration, a coarse bucket, or a version string. The trace it comes
/// from knows the table name, and the connection behind it knows a host, a port and a username; none
/// of that is reachable from this type, because a diagnostics file that accumulates for a week has to
/// be something a user can hand over without reading it first.
///
/// The buckets are stored as their raw strings rather than as the enums, so a record written by an
/// older build still decodes after a bucket is renamed or added. A trace that never fetched a result
/// leaves the three result buckets absent rather than reporting an empty one, which would be a
/// measurement it never took.
internal struct TableLoadPerformanceRecord: Codable, Sendable, Equatable {
    internal let recordedAt: Date
    internal let appVersion: String
    internal let appBuild: String
    internal let osVersion: String
    internal let origin: String
    internal let outcome: String
    internal let anomalies: [String]
    internal let databaseTypeId: String
    internal let usesSSH: Bool
    internal let totalMs: Double
    internal let preparationMs: Double?
    internal let driverFetchMs: Double?
    internal let resultApplyMs: Double?
    internal let gridReloadMs: Double?
    internal let mainRunLoopIdleMs: Double?
    internal let rowBucket: String?
    internal let columnBucket: String?
    internal let resultSizeBucket: String?
    internal let openTabBucket: String

    internal init(summary: TableLoadTraceSummary, stamp: TableLoadRuntimeStamp, recordedAt: Date) {
        self.recordedAt = recordedAt
        self.appVersion = stamp.appVersion
        self.appBuild = stamp.appBuild
        self.osVersion = stamp.osVersion
        self.origin = summary.origin.rawValue
        self.outcome = summary.outcome.rawValue
        self.anomalies = summary.anomalies.map(\.rawValue)
        self.databaseTypeId = summary.environment.databaseTypeId
        self.usesSSH = summary.environment.usesSSH
        self.totalMs = TableLoadDuration.milliseconds(summary.total)
        self.preparationMs = summary.preparation.map(TableLoadDuration.milliseconds)
        self.driverFetchMs = summary.driverFetch.map(TableLoadDuration.milliseconds)
        self.resultApplyMs = summary.resultApply.map(TableLoadDuration.milliseconds)
        self.gridReloadMs = summary.gridReload.map(TableLoadDuration.milliseconds)
        self.mainRunLoopIdleMs = summary.mainRunLoopIdle.map(TableLoadDuration.milliseconds)
        self.rowBucket = summary.resultMetrics.map { TableLoadRowBucket(rowCount: $0.rowCount).rawValue }
        self.columnBucket = summary.resultMetrics.map { TableLoadColumnBucket(columnCount: $0.columnCount).rawValue }
        self.resultSizeBucket = summary.resultMetrics.map {
            TableLoadResultSizeBucket(byteCount: $0.estimatedBytes).rawValue
        }
        self.openTabBucket = TableLoadOpenTabBucket(tabCount: summary.environment.openTabCount).rawValue
    }
}
