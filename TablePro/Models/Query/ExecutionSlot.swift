//
//  ExecutionSlot.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct ExecutionSlot: Equatable {
    internal enum Report: Equatable {
        case running
        case lastRun(PluginQueryTiming)
    }

    internal let report: Report?
    internal let leadsWithSeparator: Bool

    internal init(isOffered: Bool, followsReadout: Bool, isRevealed: Bool, lastTiming: PluginQueryTiming?) {
        let report = isOffered ? Self.report(isRevealed: isRevealed, lastTiming: lastTiming) : nil
        self.report = report
        leadsWithSeparator = followsReadout && report != nil
    }

    private static func report(isRevealed: Bool, lastTiming: PluginQueryTiming?) -> Report? {
        guard !isRevealed else { return .running }
        return lastTiming.map(Report.lastRun)
    }
}
