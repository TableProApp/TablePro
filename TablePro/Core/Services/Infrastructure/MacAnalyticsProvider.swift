//
//  MacAnalyticsProvider.swift
//  TablePro
//

import Foundation
import TableProAnalytics

@MainActor
final class MacAnalyticsProvider: AnalyticsEnvironmentProvider {
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
}
