//
//  QueryDurationFormatter.swift
//  TablePro
//

import Foundation

/// One spelling of a query duration, so a row in the history drawer and a row in the insights tab
/// never disagree about what the same number reads as.
enum QueryDurationFormatter {
    static func string(from duration: TimeInterval) -> String {
        let milliseconds = duration * 1_000
        if milliseconds < 1 {
            return String(localized: "<1 ms", comment: "Query duration under one millisecond")
        }
        if duration < 1.0 {
            return String(format: "%.0f ms", milliseconds)
        }
        if duration < 60 {
            return String(format: "%.2f s", duration)
        }
        return Duration.seconds(duration).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
    }
}
