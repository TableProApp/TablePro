//
//  UpdateCheckFrequency.swift
//  TablePro
//

import Foundation

/// How often Sparkle polls the update feed.
///
/// Deliberately not `Codable` and deliberately absent from `GeneralSettings`: the value belongs to
/// `SPUUpdater.updateCheckInterval`, and a second copy of a Sparkle preference is what
/// `SPUUpdater.h:192-209` warns against.
///
/// Hourly is not offered because polling a 640 KB feed twenty-four times a day buys nothing once
/// installs are silent. Monthly is not offered because it would sit above
/// `SUScheduledImpatientCheckInterval`, which Sparkle documents as needing to be the larger of the
/// two.
enum UpdateCheckFrequency: Int, CaseIterable, Identifiable, Sendable {
    case daily = 86_400
    case weekly = 604_800

    var id: Int { rawValue }

    var seconds: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        }
    }

    /// The closest offered frequency to what the updater currently reports.
    ///
    /// A managed preference or an older build can leave any interval in place, so the picker has
    /// to resolve an arbitrary number to one of its own cases rather than showing nothing.
    static func closest(to interval: TimeInterval) -> UpdateCheckFrequency {
        allCases.min(by: { abs($0.seconds - interval) < abs($1.seconds - interval) }) ?? .daily
    }
}
