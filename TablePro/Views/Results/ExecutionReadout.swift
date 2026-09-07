//
//  ExecutionReadout.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What the status bar needs to report a query's progress: whether one is running for this tab,
/// how long the last one took, and how to stop it.
///
/// Whether anything is running is not stored here, it is asked. `TabExecutionRegistry` is the only
/// thing that knows, and a stored copy of the answer is what let the titlebar report a query that
/// had already ended, recoverable only by pressing Stop (#2342, and #548 before it). As a stored
/// `Bool` this was a parameter any caller could hand any value, and the invariant could only be
/// written down; as a computed read there is nothing to hand.
///
/// `isBusy`, not `isExecuting`: Fetch All extends the result already on screen and so registers
/// unclaimed work rather than a claim, and the readout this replaced watched a window-wide flag
/// that counted both. With the narrower predicate a Fetch All ran with no spinner and no Stop
/// button anywhere in the window.
///
/// `lastTiming` is per tab for the same reason the busy bit is: this is drawn under one tab's own
/// rows, so a duration another tab produced would be reported as this tab's.
struct ExecutionReadout: Equatable {
    let tabId: UUID
    let execution: TabExecutionRegistry
    let lastTiming: PluginQueryTiming?
    let onCancel: () -> Void

    var isExecuting: Bool {
        execution.isBusy(tabId)
    }

    /// Nothing to draw when no query has run and none is running. The toolbar used to hold an
    /// em-dash placeholder there, which spent width to say nothing.
    var isActive: Bool {
        isExecuting || lastTiming != nil
    }

    static func == (lhs: ExecutionReadout, rhs: ExecutionReadout) -> Bool {
        lhs.isExecuting == rhs.isExecuting && lhs.lastTiming == rhs.lastTiming
    }
}
