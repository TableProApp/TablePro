//
//  LaunchIntentRouter.swift
//  TablePro
//

import AppKit
import Foundation
import os

@MainActor
internal final class LaunchIntentRouter {
    internal static let shared = LaunchIntentRouter()

    private static let logger = Logger(subsystem: "com.TablePro", category: "LaunchIntentRouter")

    private init() {}

    internal func route(_ intent: LaunchIntent) async {
        do {
            switch intent {
            case .openConnection,
                 .openTable,
                 .openQuery,
                 .openDatabaseURL,
                 .openDatabaseFile,
                 .openSQLFile:
                try await TabRouter.shared.route(intent)

            case .importConnection(let exportable):
                WelcomeRouter.shared.routeImport(exportable)

            case .openConnectionShare(let url):
                WelcomeRouter.shared.routeShare(url)

            case .pairIntegration(let request):
                try await MCPPairingService.shared.startPairing(request)

            case .startMCPServer:
                await MCPServerManager.shared.lazyStart()

            case .installPlugin(let url):
                try await installPlugin(url)
            }
        } catch let error as TabRouterError where error == .userCancelled {
            Self.logger.info("Intent cancelled by user")
        } catch let error as MCPError where error.isUserCancelled {
            Self.logger.info("Pairing cancelled by user")
        } catch is CancellationError {
            Self.logger.info("Intent cancelled")
        } catch {
            Self.logger.error("Intent failed: \(error.localizedDescription, privacy: .public)")
            await presentError(error, for: intent)
        }
    }

    private func installPlugin(_ url: URL) async throws {
        let entry = try await PluginManager.shared.installPlugin(from: url)
        Self.logger.info("Installed plugin '\(entry.name, privacy: .public)' from Finder")
        UserDefaults.standard.set(SettingsTab.plugins.rawValue, forKey: "selectedSettingsTab")
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }

    private func presentError(_ error: Error, for intent: LaunchIntent) async {
        let title: String
        switch intent {
        case .pairIntegration:
            title = String(localized: "Pairing Failed")
        case .installPlugin:
            title = String(localized: "Plugin Installation Failed")
        case .openConnection, .openTable, .openQuery, .openDatabaseURL, .openDatabaseFile:
            title = String(localized: "Connection Failed")
        case .openSQLFile:
            title = String(localized: "Could Not Open File")
        case .importConnection, .openConnectionShare, .startMCPServer:
            title = String(localized: "Action Failed")
        }
        AlertHelper.showErrorSheet(
            title: title,
            message: error.localizedDescription,
            window: NSApp.keyWindow
        )
    }
}

extension TabRouterError: Equatable {
    internal static func == (lhs: TabRouterError, rhs: TabRouterError) -> Bool {
        switch (lhs, rhs) {
        case (.userCancelled, .userCancelled): return true
        case (.connectionNotFound(let l), .connectionNotFound(let r)): return l == r
        case (.malformedDatabaseURL(let l), .malformedDatabaseURL(let r)): return l == r
        case (.unsupportedIntent(let l), .unsupportedIntent(let r)): return l == r
        default: return false
        }
    }
}
