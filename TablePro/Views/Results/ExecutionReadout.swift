//
//  ExecutionReadout.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What the status bar needs to report a query's progress: whether one is running for this tab,
/// how long the last one took, and how to stop it.
///
/// `isExecuting` is per tab, because that is the tab whose rows are about to change. `lastTiming`
/// is the window's, which is what produced it: a duration belongs to the query that ran, and the
/// window runs one at a time per tab. Keeping them apart is deliberate; collapsing them into one
/// "busy" flag is what let a connection that was merely dialing paint the query indicator (#2342).
struct ExecutionReadout: Equatable {
    let isExecuting: Bool
    let lastTiming: PluginQueryTiming?
    let onCancel: () -> Void

    /// Nothing to draw when no query has run and none is running. The toolbar used to hold an
    /// em-dash placeholder there, which spent width to say nothing.
    var isActive: Bool {
        isExecuting || lastTiming != nil
    }

    static func == (lhs: ExecutionReadout, rhs: ExecutionReadout) -> Bool {
        lhs.isExecuting == rhs.isExecuting && lhs.lastTiming == rhs.lastTiming
    }
}
