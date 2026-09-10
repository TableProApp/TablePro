//
//  DriverCancellationPolicy.swift
//  TablePro
//

import Foundation

/// Whether a leased driver may be aborted, and by whom.
///
/// Cancellation used to be a bool, and `cancelRunningQuery` aborted every tracked handle. That was
/// survivable while only an explicit Stop cancelled anything; once a navigation that supersedes a
/// tab also cancels, an untyped abort routinely reaches a commit or a DDL statement, which is data
/// loss rather than a lost result.
internal enum DriverCancellationPolicy: Equatable, Sendable {
    /// Metadata and schema reads that share the connection. Never registered, so they can neither be
    /// aborted nor clear the handle a real query registered.
    case untracked

    /// User SQL and table loads. Safe to abort: the worst case is a result nobody wanted.
    case cancellableRead

    /// Commits, rollbacks, row writes and DDL. Registered so the connection is known to be busy, but
    /// never abortable, because a half-applied write cannot be undone by retrying.
    case protectedWrite

    var isTracked: Bool {
        self != .untracked
    }
}

/// How far a cancellation request is allowed to reach when nothing is registered.
internal enum DriverCancellationReach: Equatable, Sendable {
    /// The user pressed Stop. May fall back to the session driver, since the intent is explicit.
    case userStop

    /// A navigation superseded a tab. Only ever aborts a lease it can see, because guessing at the
    /// session driver here would abort work belonging to a different tab.
    case supersededNavigation
}

internal struct RunningDriver {
    let driver: DatabaseDriver?
    let policy: DriverCancellationPolicy

    func adopting(_ driver: DatabaseDriver) -> RunningDriver {
        RunningDriver(driver: driver, policy: policy)
    }
}
