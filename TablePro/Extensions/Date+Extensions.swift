//
//  Date+Extensions.swift
//  TablePro
//
//  Date extensions for relative time display.
//

import Foundation

extension Date {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Returns a localized, human-readable relative time string (e.g., "2 hours ago", "3 days ago")
    func timeAgoDisplay() -> String {
        Self.relativeFormatter.localizedString(for: self, relativeTo: Date())
    }
}
