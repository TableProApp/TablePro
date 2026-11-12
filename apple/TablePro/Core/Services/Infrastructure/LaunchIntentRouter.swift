import AppKit
import Foundation
import os
import TableProCloudAPI

@MainActor
internal final class LaunchIntentRouter {
    internal static let shared = LaunchIntentRouter()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "LaunchIntentRouter")

    private init() {}

    internal func route(_ intent: LaunchIntent) async {
        do {
            switch intent {
            case .openConnection,
                 .openTable,
                 .openQuery,
                 .openAgentSession,
                 .openDatabaseURL,
                 .openDatabaseFile,
                 .openSQLFile,
                 .reopenClosedTab:
                try await TabRouter.shared.route(intent)

            case .openDataFile(let url):
                Self.logger.debug("LaunchIntentRouter.route(.openDataFile(\(url.lastPathComponent, privacy: .private(mask: .hash))))")
                try await openDataFileDocument(at: url)

            case .importConnection(let bundle):
                WelcomeRouter.shared.routeImport(bundle)

            case .openConnectionShare(let url):
                WelcomeRouter.shared.routeShare(url)

            case .pairIntegration(let request):
                try await MCPPairingService.shared.startPairing(request)

            case .startMCPServer:
                await startMCPServer()

            case .openSettings(let pane):
                WindowOpener.shared.openSettings(tab: pane)

            case .installPlugin(let url):
                try await installPlugin(url)

            case .openShare(let token):
                try await openShare(token: token)
            }
        } catch let error where error.isUserCancellation {
            Self.logger.info("Intent cancelled: \(error.publicLogShape, privacy: .public)")
        } catch {
            Self.logger.error("Intent failed: \(error.publicLogShape, privacy: .public)")
            await presentError(error, for: intent)
        }
    }

    private func openShare(token: String) async throws {
        let client = ShareClient(api: AccountServices.shared.publicAPI)
        let share: Components.Schemas.PublicShare
        do throws(ShareFailure) {
            share = try await client.view(token: token)
        } catch {
            presentShareUnavailable(error)
            return
        }
        let opened = try await TabRouter.shared.openSharedQuery(sql: share.sql)
        if !opened {
            // No connected database to open against. Queue the SQL the way openSQLFile does, so it
            // opens once the user connects one, and show where to do that.
            WelcomeRouter.shared.enqueueSharedSQL(share.sql)
        }
    }

    private func presentShareUnavailable(_ failure: ShareFailure) {
        let message: String
        switch failure {
        case .canceled:
            return
        case .notFound:
            message = String(localized: "This shared link is no longer available.")
        case .offline:
            message = String(localized: "You appear to be offline. Try again once you're connected.")
        case .rateLimited:
            message = String(localized: "Too many requests just now. Try again in a moment.")
        case .signedOut, .featureRequired, .forbidden, .limitReached, .refused, .server:
            message = String(localized: "The shared query couldn't be opened.")
        }
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        AlertHelper.showInfoSheet(title: String(localized: "Open Shared Query"), message: message, window: nil)
    }

    private func openDataFileDocument(at url: URL) async throws {
        Self.logger.debug("LaunchIntentRouter.openDataFileDocument - calling NSDocumentController.shared (\(String(describing: Swift.type(of: NSDocumentController.shared)), privacy: .public)).openDocument for \(url.lastPathComponent, privacy: .private(mask: .hash))")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, alreadyOpen, error in
                Self.logger.debug("LaunchIntentRouter.openDataFileDocument completion - document=\(document == nil ? "nil" : "present", privacy: .public) alreadyOpen=\(alreadyOpen, privacy: .public) error=\(error?.publicLogShape ?? "nil", privacy: .public) \(error?.localizedDescription ?? "nil", privacy: .private)")
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if document == nil {
                    Self.logger.warning("NSDocumentController returned no document for \(url.lastPathComponent, privacy: .private(mask: .hash))")
                }
                continuation.resume()
            }
        }
    }

    // No alert: the bridge reads the refusal file and tells its client, and an alert would greet every
    // client that tries while MCP is off or broken.
    private func startMCPServer() async {
        let quits = await Self.startMCPServerLeavesNothingToDo(
            manager: MCPServerManager.shared,
            isIdleMachineSession: { AppActivationPolicyController.shared.isIdleMachineSession }
        )
        guard quits else { return }
        NSApp.terminate(nil)
    }

    // A launch made only to serve MCP has nothing left to do once the server is refused or fails to start.
    internal static func startMCPServerLeavesNothingToDo(
        manager: MCPServerManager,
        isIdleMachineSession: () -> Bool
    ) async -> Bool {
        do {
            try await manager.lazyStart()
        } catch {
            logger.info("start-mcp refused: \(error.publicLogShape, privacy: .public)")
            return isIdleMachineSession()
        }
        guard case .failed = manager.state else { return false }
        logger.error("start-mcp failed: the MCP server did not start")
        return isIdleMachineSession()
    }

    private func installPlugin(_ url: URL) async throws {
        let entry = try await PluginManager.shared.installPlugin(from: url)
        Self.logger.info("Installed plugin '\(entry.name, privacy: .public)' from Finder")
        WindowOpener.shared.openSettings(tab: .plugins)
    }

    private func presentRecoverableError(_ error: Error, for intent: LaunchIntent, title: String) -> Bool {
        guard let connectionId = Self.connectionId(for: intent),
              let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId }),
              let action = ConnectionFailureClassifier.recoveryAction(for: error)
        else { return false }
        let info = ConnectionFailureClassifier.info(for: error)
        AlertHelper.showRecoverableErrorSheet(
            title: title,
            message: [info.message, info.failureReason].compactMap { $0 }.joined(separator: "\n\n"),
            recoverySuggestion: info.recoverySuggestion,
            recoveryTitle: action.title,
            window: NSApp.keyWindow
        ) {
            ConnectionRecoveryPerformer.perform(action, for: connection)
        }
        return true
    }

    private static func connectionId(for intent: LaunchIntent) -> UUID? {
        switch intent {
        case .openConnection(let id):
            return id
        case .openTable(let id, _, _, _, _, _):
            return id
        case .openQuery(let id, _):
            return id
        case .reopenClosedTab(let entry):
            return entry.connectionId
        default:
            return nil
        }
    }

    internal static func failedConnectionId(for intent: LaunchIntent, error: Error) -> UUID? {
        connectionId(for: intent) ?? (error as? TabRouterError)?.windowConnectionId
    }

    private func presentError(_ error: Error, for intent: LaunchIntent) async {
        if let connectionId = Self.failedConnectionId(for: intent, error: error),
           WindowManager.shared.hasOpenWindow(for: connectionId) {
            Self.logger.info(
                "Failure already shown in the connection window connId=\(connectionId, privacy: .public)"
            )
            return
        }

        let title: String
        switch intent {
        case .pairIntegration:
            title = String(localized: "Pairing Failed")
        case .installPlugin:
            title = String(localized: "Plugin Installation Failed")
        case .openConnection, .openTable, .openQuery, .openAgentSession, .openDatabaseURL,
             .openDatabaseFile, .reopenClosedTab:
            title = String(localized: "Connection Failed")
        case .openSQLFile, .openDataFile:
            title = String(localized: "Could Not Open File")
        case .importConnection, .openConnectionShare, .openShare, .startMCPServer, .openSettings:
            title = String(localized: "Action Failed")
        }
        if presentRecoverableError(error, for: intent, title: title) { return }
        if error is MCPServerStartError {
            AlertHelper.showRecoverableErrorSheet(
                title: title,
                message: error.localizedDescription,
                recoverySuggestion: nil,
                recoveryTitle: String(localized: "Open MCP Settings"),
                window: NSApp.keyWindow
            ) {
                WindowOpener.shared.openSettings(tab: .mcp)
            }
            return
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
        case (.connectFailedInWindow(let l, _), .connectFailedInWindow(let r, _)): return l == r
        default: return false
        }
    }
}
