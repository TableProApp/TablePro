//
//  SidebarFilterPacer.swift
//  TablePro
//

import Foundation

/// Decides how long a filter keystroke waits before the sidebar applies it, from what the last
/// applied query cost. A key that comes at least one refresh after the last refresh ended applies
/// at once; a faster key waits out the rest of that refresh's cost, so typing faster than the list
/// can redraw collapses to the latest text, and the main thread spends at most about half its time
/// on filter refreshes. No key waits longer than `longestWait`.
struct SidebarFilterPacer: Equatable {
    static let longestWait: Duration = .milliseconds(150)

    private var lastRefreshEnd: Duration?
    private var lastRefreshCost: Duration = .zero

    /// Times are offsets on one clock, so the pacer stays a value a test can drive.
    mutating func recordRefresh(start: Duration, end: Duration) {
        lastRefreshEnd = end
        lastRefreshCost = max(.zero, end - start)
    }

    func delay(at now: Duration) -> Duration {
        guard let lastRefreshEnd else { return .zero }
        let ready = lastRefreshEnd + min(lastRefreshCost, Self.longestWait)
        return max(.zero, ready - now)
    }
}
