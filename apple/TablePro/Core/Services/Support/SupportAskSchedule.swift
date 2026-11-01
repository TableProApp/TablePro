//
//  SupportAskSchedule.swift
//  TablePro
//

import Foundation

/// How someone answered the license ask. The raw values are stored, so they never change.
internal enum SupportAskAnswer: String, Equatable, Sendable {
    case buy
    case personal
    case notNow
}

/// When the app may ask someone without a license to buy one.
///
/// The 30th day of use opens it. Each ask closes it again for 90 days, or for a year once the
/// person says they use TablePro personally, and a license closes it for good. Kept pure, so every
/// rule is tested without a window, a clock or a license.
internal struct SupportAskSchedule: Equatable, Sendable {
    static let firstAskDay = 30
    static let daysBetweenAsks = 90
    static let daysAfterPersonalUse = 365
    /// Someone who just launched the app came to do something; the ask waits until they have.
    static let launchQuietPeriod: TimeInterval = 5 * 60

    var usageDays: Int
    var hasLicense: Bool
    var lastAskedAt: Date?
    var lastAnswer: SupportAskAnswer?

    func isDue(at now: Date, calendar: Calendar) -> Bool {
        guard !hasLicense, usageDays >= Self.firstAskDay else { return false }
        guard let lastAskedAt else { return true }
        let waitDays = lastAnswer == .personal ? Self.daysAfterPersonalUse : Self.daysBetweenAsks
        guard let nextAsk = calendar.date(byAdding: .day, value: waitDays, to: lastAskedAt) else { return false }
        return now >= nextAsk
    }

    /// Whether this is a moment the ask may interrupt: past the launch quiet period, and with no
    /// query running, so a sheet never lands on a result someone is waiting for.
    static func isQuietMoment(launchedAt: Date, now: Date, isQueryRunning: Bool) -> Bool {
        !isQueryRunning && now.timeIntervalSince(launchedAt) >= launchQuietPeriod
    }
}
