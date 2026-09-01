//
//  PostLaunchWork.swift
//  TablePro
//

import Foundation
import os

/// The subsystem work a launch has to do but the first window does not need.
///
/// Everything here is main-actor work: a registry fetch, a favourites prune that reads the
/// connection store, an MCP server bind, a history cleanup. Started from the delegate it runs while
/// the first window is still being built and takes main-thread time away from it. Started from
/// `AppLaunchCoordinator` once that window has presented its first frame, it costs the person
/// nothing, because by then they are already looking at the app.
///
/// Nothing whose absence is observable in the first frame belongs here. The menu bar, the theme,
/// the window presenters and the `UNUserNotificationCenter` delegate all stay in `AppDelegate`.
@MainActor
internal enum PostLaunchWork {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "Launch")

    private static var hasStarted = false

    /// Idempotent, because a launch that opens several windows reaches the end of routing once but
    /// a future caller should not have to know that.
    internal static func start() {
        guard !hasStarted else { return }
        hasStarted = true
        logger.debug("post-launch work starting")

        MemoryPressureAdvisor.startMonitoring()
        PluginNotificationService.shared.setUp()
        OperationCompletionReporter.shared.setUp()
        ChatToolBootstrap.register()

        Task { await PluginManager.shared.sweepPluginSignatures() }
        Task { await CloudflareTunnelManager.shared.sweepStalePidsIfNeeded() }
        Task { await CloudSQLProxyManager.shared.sweepStalePidsIfNeeded() }
        Task { await QueryHistoryManager.shared.performStartupCleanup() }

        guard !AppStorageEnvironment.shared.isIsolated else { return }

        Task { await RegistryClient.shared.ensureManifest(.ifStale) }

        Task { @MainActor in
            let activeIds = Set(ConnectionStorage.shared.loadConnections().map(\.id))
            await SQLFavoriteManager.shared.pruneOrphaned(activeConnectionIds: activeIds)
        }

        let mcp = AppSettingsManager.shared.mcp
        guard mcp.enabled else { return }
        Task { await MCPServerManager.shared.start(port: UInt16(clamping: mcp.port)) }
    }
}
