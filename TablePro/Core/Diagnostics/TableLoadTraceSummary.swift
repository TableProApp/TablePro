//
//  TableLoadTraceSummary.swift
//  TablePro
//

import Foundation

/// The closed vocabulary of ways a table load can end. A persisted history has to carry a set an
/// external report can group by, which a free-form string cannot be: `finish` used to take one, and
/// the failure case interpolated a Swift type name into it. The type name now rides in the log-only
/// `detail`, so the log line is unchanged and the recorded field is closed.
internal enum TableLoadOutcome: String, Sendable, CaseIterable {
    case completed
    case cancelled
    case failed
    case superseded
    case blocked
    case staleDropped
    case notConnected
    case replaceFailed
    case prepareAbandoned
    case loadAlreadyInFlight
    case emptyQuery
    case safeModePromptAlreadyOpen
    case safeModeDenied
    case evicted
}

/// What the load was running against, pushed in when the trace begins. `TableLoadTracer` is one
/// process-wide singleton while `MainContentCoordinator` is one per connection session, so reading
/// this at the ending site would read whichever coordinator happened to be current, not the one the
/// trace belongs to.
internal struct TableLoadEnvironment: Sendable, Equatable {
    internal static let unknown = TableLoadEnvironment(databaseTypeId: "", usesSSH: false, openTabCount: 0)

    internal let databaseTypeId: String
    internal let usesSSH: Bool
    internal let openTabCount: Int
}

/// One completed trace, reduced to durations and coarse shape. Produced by `TableLoadTraceRecorder`
/// at every ending, and the only thing that crosses out of the diagnostics recorder.
internal struct TableLoadTraceSummary: Sendable, Equatable {
    internal let origin: TableLoadOrigin
    internal let outcome: TableLoadOutcome
    internal let anomalies: [TableLoadAnomaly]
    internal let environment: TableLoadEnvironment
    internal let resultMetrics: TableLoadResultMetrics?
    internal let total: Duration
    internal let preparation: Duration?
    internal let driverFetch: Duration?
    internal let resultApply: Duration?
    internal let gridReload: Duration?
    internal let mainRunLoopIdle: Duration?
}

internal enum TableLoadDuration {
    internal static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
