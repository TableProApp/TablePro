//
//  DriverCancellationPolicy.swift
//  TablePro
//

import Foundation

/// Who a leased driver belongs to, so a cancel reaches that lease and nothing else.
///
/// One connection runs one tab's work at a time, but several tabs and several windows queue on the
/// same session driver, and an MCP client leases it too. Without an owner a cancel was keyed by
/// connection alone, so starting a query in one tab aborted the batch another tab had running and
/// rolled it back under a "cancelled by user" the user never asked for.
internal struct DriverLeaseOwner: Hashable, Sendable {
    private let id = UUID()

    internal init() {}
}

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

    /// User SQL and table loads, aborted only by whoever owns the lease. Safe to abort: the worst
    /// case is a result nobody wanted.
    case cancellableRead(DriverLeaseOwner)

    /// Commits, rollbacks, row writes and DDL. Registered so the connection is known to be busy, but
    /// never abortable, because a half-applied write cannot be undone by retrying.
    case protectedWrite

    internal var isTracked: Bool {
        self != .untracked
    }
}

/// When a cancellation request is paid for.
internal enum DriverCancellationDelivery: Equatable, Sendable {
    /// The user pressed Stop and is waiting on it, so the request goes out inline.
    case immediate

    /// A navigation superseded a tab, or a tab was closed. A PostgreSQL cancel opens a second
    /// connection to deliver the request, which through an SSH tunnel costs 70-160ms, so it goes to
    /// a background queue and the lease awaits it on the way out instead of the user waiting for it.
    case background
}

internal struct RunningDriver {
    internal let driver: DatabaseDriver?
    internal let policy: DriverCancellationPolicy

    /// A background cancel already sent for this handle. The lease awaits it before releasing, so a
    /// request that lands late cannot reach the statement the next owner runs on the same driver.
    internal var pendingCancel: Task<Void, Never>?

    internal init(driver: DatabaseDriver?, policy: DriverCancellationPolicy) {
        self.driver = driver
        self.policy = policy
    }

    internal func adopting(_ driver: DatabaseDriver) -> RunningDriver {
        RunningDriver(driver: driver, policy: policy)
    }
}
