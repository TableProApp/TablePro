//
//  IOSAnalyticsProvider.swift
//  TableProMobile
//

import Foundation
import TableProAnalytics
import TableProDatabase
import TableProModels
import UIKit

@MainActor
final class IOSAnalyticsProvider: AnalyticsEnvironmentProvider {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    var machineId: String {
        let stableKey = "com.TablePro.analytics.stableDeviceId"
        if let stable = UserDefaults.standard.string(forKey: stableKey) {
            return stable
        }
        let id: String
        if let vendorId = UIDevice.current.identifierForVendor?.uuidString {
            id = vendorId.sha256
        } else {
            id = UUID().uuidString.sha256
        }
        UserDefaults.standard.set(id, forKey: stableKey)
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
        UserDefaults.standard.object(forKey: "com.TablePro.settings.shareAnalytics") as? Bool ?? true
    }

    var hasLicense: Bool { false }

    var activeDatabaseTypes: [String] {
        let active = appState.connections.filter { conn in
            appState.connectionManager.session(for: conn.id) != nil
        }
        return Array(Set(active.map { $0.type.rawValue }))
    }

    var activeConnectionCount: Int {
        appState.connections.filter { conn in
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
}
