//
//  QueryTimingAggregation.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginQueryTiming {
    /// Folds a batch of statements into one timing.
    ///
    /// A part is summed only when every statement supplied it. Summing the ones that did and
    /// ignoring the rest would report a server time smaller than the work it claims to describe,
    /// which reads as a fast batch rather than as a partly unmeasured one.
    static func total(of timings: [PluginQueryTiming]) -> PluginQueryTiming? {
        guard !timings.isEmpty else { return nil }
        return PluginQueryTiming(
            total: timings.reduce(0) { $0 + $1.total },
            firstRow: summed(timings.map(\.firstRow)),
            server: summed(timings.map(\.server))
        )
    }

    /// A batch with nothing in it still has to report something, and zero is what the elapsed sum
    /// reported before there was a timing to fold.
    static func batch(of results: [QueryResult]) -> PluginQueryTiming {
        total(of: results.map(\.resolvedTiming)) ?? PluginQueryTiming(total: 0)
    }

    private static func summed(_ parts: [TimeInterval?]) -> TimeInterval? {
        var accumulated: TimeInterval = 0
        for part in parts {
            guard let part else { return nil }
            accumulated += part
        }
        return accumulated
    }
}
