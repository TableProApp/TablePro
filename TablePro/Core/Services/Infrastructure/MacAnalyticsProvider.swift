//
//  MacAnalyticsProvider.swift
//  TablePro
//

import Foundation
import os
import TableProAnalytics

@MainActor
final class MacAnalyticsProvider: AnalyticsEnvironmentProvider {
    static let shared = MacAnalyticsProvider()

    private static let logger = Logger(subsystem: "com.TablePro", category: "MacAnalyticsProvider")

    private let defaults: UserDefaults

    enum Keys {
        static let connectionAttemptedAt = "com.TablePro.analytics.connectionAttemptedAt"
        static let connectionSucceededAt = "com.TablePro.analytics.connectionSucceededAt"
        static let firstQueryExecutedAt = "com.TablePro.analytics.firstQueryExecutedAt"
        static let successfulConnectionCount = "com.TablePro.analytics.successfulConnectionCount"
        static let newsletterPromptShown = "com.TablePro.newsletter.promptShown"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var machineId: String {
        LicenseStorage.shared.machineId
    }

    var appVersion: String? {
        Bundle.main.appVersion
    }

    var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    var platform: String { "macos" }

    var locale: String {
        AppSettingsStorage.shared.loadGeneral().language.rawValue
    }

    var isAnalyticsEnabled: Bool {
        AppSettingsStorage.shared.loadGeneral().shareAnalytics
    }

    var hasLicense: Bool {
        LicenseStorage.shared.loadLicenseKey() != nil
    }

    var activeDatabaseTypes: [String] {
        Array(Set(DatabaseManager.shared.activeSessions.values.compactMap { $0.connection.type.rawValue }))
    }

    var activeConnectionCount: Int {
        DatabaseManager.shared.activeSessions.count
    }

    var hmacSecret: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AnalyticsHMACSecret") as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else {
            return nil
        }
        return value
    }

    var connectionAttemptedAt: Date? {
        defaults.object(forKey: Keys.connectionAttemptedAt) as? Date
    }

    var connectionSucceededAt: Date? {
        defaults.object(forKey: Keys.connectionSucceededAt) as? Date
    }

    var firstQueryExecutedAt: Date? {
        defaults.object(forKey: Keys.firstQueryExecutedAt) as? Date
    }

    var successfulConnectionCount: Int {
        defaults.integer(forKey: Keys.successfulConnectionCount)
    }

    var newsletterPromptShown: Bool {
        defaults.bool(forKey: Keys.newsletterPromptShown)
    }

    func markConnectionAttempted() {
        writeOnceDate(Keys.connectionAttemptedAt, label: "connectionAttemptedAt")
    }

    func markConnectionSucceeded() {
        writeOnceDate(Keys.connectionSucceededAt, label: "connectionSucceededAt")
        let next = defaults.integer(forKey: Keys.successfulConnectionCount) + 1
        defaults.set(next, forKey: Keys.successfulConnectionCount)
    }

    func markFirstQueryExecuted() {
        writeOnceDate(Keys.firstQueryExecutedAt, label: "firstQueryExecutedAt")
    }

    func markNewsletterPromptShown() {
        defaults.set(true, forKey: Keys.newsletterPromptShown)
    }

    private func writeOnceDate(_ key: String, label: String) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(Date(), forKey: key)
        Self.logger.info("Recorded \(label, privacy: .public) for first time")
    }
}
