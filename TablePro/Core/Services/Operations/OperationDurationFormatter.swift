//
//  OperationDurationFormatter.swift
//  TablePro
//

import Foundation

/// Renders how long an operation took, for a notification body.
///
/// Deliberately not `Duration.formatted`: the units here are always the two largest non-zero ones
/// and never a fractional second, because "192.437 seconds" is how long a query took and "3m 12s"
/// is what a person reads.
internal enum OperationDurationFormatter {
    internal static func string(from duration: Duration) -> String {
        let totalSeconds = max(0, Int(duration.components.seconds))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: String(localized: "%1$lldh %2$02lldm"), hours, minutes)
        }
        if minutes > 0 {
            return String(format: String(localized: "%1$lldm %2$02llds"), minutes, seconds)
        }
        return String(format: String(localized: "%llds"), seconds)
    }
}
