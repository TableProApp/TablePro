//
//  UsageDayCounter.swift
//  TablePro
//

import Foundation

/// Counts the distinct local days TablePro was in use, so the license ask can tell someone trying
/// the app from someone who has made it part of their week.
///
/// The count stays in this Mac's defaults and is never sent anywhere. A day is stored as its
/// calendar date rather than a timestamp, so recording it twice is harmless however often the app
/// becomes active.
@MainActor
internal final class UsageDayCounter {
    static let shared = UsageDayCounter(defaults: AppStorageEnvironment.shared.defaults)

    enum Keys {
        static let days = "com.TablePro.support.usageDays"
        static let lastDay = "com.TablePro.support.lastUsageDay"
    }

    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults, calendar: Calendar = .autoupdatingCurrent) {
        self.defaults = defaults
        self.calendar = calendar
    }

    var days: Int {
        defaults.integer(forKey: Keys.days)
    }

    func recordUse(at date: Date) {
        let day = dayStamp(of: date)
        guard defaults.string(forKey: Keys.lastDay) != day else { return }
        defaults.set(day, forKey: Keys.lastDay)
        defaults.set(days + 1, forKey: Keys.days)
    }

    private func dayStamp(of date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
