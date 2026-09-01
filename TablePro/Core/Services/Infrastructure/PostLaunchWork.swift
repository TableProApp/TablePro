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
/// the first window is still being built and takes main-thread time away from it. Started once that
/// window has presented a frame, it costs the person nothing, because by then they are already
/// looking at the app.
///
/// Nothing whose absence is observable before that frame belongs here, and the bar is not whether
/// it is cheap. A notification handler has to be registered before `applicationDidFinishLaunching`
/// returns or the action that launched the app is dropped, and a stale tunnel process has to be
/// swept before a restored connection tries to bind the port it still holds. Both stay in
/// `AppDelegate`, along with the menu bar, the theme, the window presenters and the
/// `UNUserNotificationCenter` delegate.
@MainActor
internal enum PostLaunchWork {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "Launch")

    private static var hasStarted = false

    /// Idempotent, because the first window presenting a frame and the end of intent routing both
    /// reach this, and which arrives first depends on how long a restored connection takes.
    internal static func start() {
        guard !hasStarted else { return }
        hasStarted = true
        logger.debug("post-launch work starting")

        MemoryPressureAdvisor.startMonitoring()

        Task { await PluginManager.shared.sweepPluginSignatures() }
        Task { await QueryHistoryManager.shared.performStartupCleanup() }

        guard !AppStorageEnvironment.shared.isIsolated else { return }

        /// The registry manifest only feeds the plugin-install UI, and fetching it is a network
        /// call. A sandboxed run has no user plugins directory to install into anyway.
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
