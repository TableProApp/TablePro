import Foundation
import os
import TableProAnalytics
import TableProDatabase
import TableProModels
import UIKit

@MainActor
final class IOSAnalyticsProvider: AnalyticsEnvironmentProvider {
    static let shared = IOSAnalyticsProvider()

    private static let logger = Logger(subsystem: "com.TablePro", category: "IOSAnalyticsProvider")

    private weak var appState: AppState?

    private let defaults: UserDefaults

    enum Keys {
        static let connectionAttemptedAt = "com.TablePro.analytics.connectionAttemptedAt"
        static let connectionSucceededAt = "com.TablePro.analytics.connectionSucceededAt"
        static let firstQueryExecutedAt = "com.TablePro.analytics.firstQueryExecutedAt"
        static let successfulConnectionCount = "com.TablePro.analytics.successfulConnectionCount"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func attach(appState: AppState) {
        self.appState = appState
    }

    var machineId: String {
        let stableKey = "com.TablePro.analytics.stableDeviceId"
        if let stable = defaults.string(forKey: stableKey) {
            return stable
        }
        let id: String
        if let vendorId = UIDevice.current.identifierForVendor?.uuidString {
            id = vendorId.sha256
        } else {
            id = UUID().uuidString.sha256
        }
        defaults.set(id, forKey: stableKey)
        return id
    }

    var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    var architecture: String { "arm64" }

    var platform: String { "ios" }

    var locale: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    var isAnalyticsEnabled: Bool {
        defaults.object(forKey: "com.TablePro.settings.shareAnalytics") as? Bool ?? true
    }

    var hasLicense: Bool { false }

    var activeDatabaseTypes: [String] {
        guard let appState else { return [] }
        let active = appState.connections.filter { conn in
            appState.connectionManager.session(for: conn.id) != nil
        }
        return Array(Set(active.map { $0.type.rawValue }))
    }

    var activeConnectionCount: Int {
        guard let appState else { return 0 }
        return appState.connections.filter { conn in
            appState.connectionManager.session(for: conn.id) != nil
        }.count
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

    private func writeOnceDate(_ key: String, label: String) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(Date(), forKey: key)
        Self.logger.info("Recorded \(label, privacy: .public) for first time")
    }
}
