//
//  Date+Extensions.swift
//  TablePro
//
//  Date extensions for relative time display.
//

import Foundation
import os

extension Date {
    private static let relativeFormatter: OSAllocatedUnfairLock<RelativeDateTimeFormatter> = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return OSAllocatedUnfairLock(uncheckedState: formatter)
    }()

    /// Returns a localized, human-readable relative time string (e.g., "2 hours ago", "3 days ago")
    func timeAgoDisplay() -> String {
        Self.relativeFormatter.withLockUnchecked { $0.localizedString(for: self, relativeTo: Date()) }
    }
}
