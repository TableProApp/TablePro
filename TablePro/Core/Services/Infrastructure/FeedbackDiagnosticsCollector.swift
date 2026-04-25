//
//  FeedbackDiagnosticsCollector.swift
//  TablePro
//

import Foundation

struct FeedbackDiagnostics {
    let appVersion: String
    let osVersion: String
    let architecture: String
    let activeDatabaseType: String?
    let installedPlugins: [String]
    let machineId: String

    var formattedSummary: String {
        var parts = ["TablePro \(appVersion)", "\(osVersion) · \(architecture)"]
        if let db = activeDatabaseType {
            parts.append("Database: \(db)")
        }
        return parts.joined(separator: "\n")
    }

    var pluginsSummary: String {
        let count = installedPlugins.count
        return "\(count) plugin\(count == 1 ? "" : "s") installed"
    }
}

@MainActor
enum FeedbackDiagnosticsCollector {
    static func collect() -> FeedbackDiagnostics {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        let architecture: String = {
            #if arch(arm64)
            return "Apple Silicon"
            #else
            return "Intel"
            #endif
        }()

        let databaseType = DatabaseManager.shared.activeSessions.values
            .first
            .map { $0.connection.type.rawValue }

        let plugins = PluginManager.shared.plugins.map { "\($0.name) v\($0.version)" }

        return FeedbackDiagnostics(
            appVersion: "\(Bundle.main.appVersion) (Build \(Bundle.main.buildNumber))",
            osVersion: osVersion,
            architecture: architecture,
            activeDatabaseType: databaseType,
            installedPlugins: plugins,
            machineId: LicenseStorage.shared.machineId
        )
    }
}
