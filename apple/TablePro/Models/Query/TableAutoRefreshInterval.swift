//
//  TableAutoRefreshInterval.swift
//  TablePro
//

import Foundation

enum TableAutoRefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300

    var id: Int { rawValue }

    var isOn: Bool { self != .off }

    var duration: Duration { .seconds(rawValue) }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .fiveSeconds: String(localized: "Every 5 Seconds")
        case .tenSeconds: String(localized: "Every 10 Seconds")
        case .thirtySeconds: String(localized: "Every 30 Seconds")
        case .oneMinute: String(localized: "Every Minute")
        case .fiveMinutes: String(localized: "Every 5 Minutes")
        }
    }

    // The status bar's regular tier names the interval beside the glyph, so it has to stay short in every language.
    var shortTitle: String {
        guard isOn else { return String(localized: "Off") }
        return duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
    }
}
