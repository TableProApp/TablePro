//
//  AppLaunchCoordinator.swift
//  TablePro
//

import AppKit
import Foundation
import Observation
import os

@MainActor
@Observable
internal final class AppLaunchCoordinator {
    internal static let shared = AppLaunchCoordinator()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "AppLaunchCoordinator")
    internal static let collectionWindow: Duration = .milliseconds(150)

    private(set) var phase: LaunchPhase = .launching

    private var pendingIntents: [LaunchIntent] = []
    private var deadlineTask: Task<Void, Never>?
    private var hasFinishedLaunching = false

    private init() {}

    // MARK: - App Lifecycle Hooks

    internal func didFinishLaunching() {
        hasFinishedLaunching = true
        deliver(UITestLaunchEnvironment.launchIntents)
        let deadline = Date().addingTimeInterval(0.150)
        phase = .collectingIntents(deadline: deadline)
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: Self.collectionWindow)
            await MainActor.run {
                self?.transitionToRouting()
            }
        }
    }

    internal func handleOpenURLs(_ urls: [URL]) {
        let intents: [LaunchIntent] = urls.compactMap { url in
            switch URLClassifier.classify(url) {
            case .none:
                Self.logger.warning("Unrecognized URL: \(url.sanitizedForLogging, privacy: .public)")
                return nil
            case .some(.failure(let error)):
                Self.logger.error("URL parse failed: \(error.localizedDescription, privacy: .public) for \(url.sanitizedForLogging, privacy: .public)")
                return nil
            case .some(.success(let intent)):
                return intent
            }
        }
        /// Unconditional, even when nothing parsed: LaunchServices treats every `open` request as a
        /// launch and puts a running background process back in the Dock, so the role has to be
        /// re-applied on arrival rather than only when the URL turns out to mean something.
        AppActivationPolicyController.shared.adoptIntents(intents, isLaunching: !hasFinishedLaunching)
        deliver(intents)
    }

    internal func handleHandoff(_ activity: NSUserActivity) {
        guard let connectionIdString = activity.userInfo?["connectionId"] as? String,
              let connectionId = UUID(uuidString: connectionIdString) else { return }
        let table = activity.userInfo?["tableName"] as? String
        AppActivationPolicyController.shared.adoptUserSession()

        if let table {
            deliver([.openTable(
                connectionId: connectionId,
                database: nil,
                schema: nil,
                table: table,
                isView: false
            )])
        } else {
            deliver([.openConnection(connectionId)])
        }
    }

    /// Reaching for the app itself is the gesture that makes a machine-started process the person's
    /// own, so it keeps its Dock icon and menu bar from here on however it started.
    internal func handleReopen(hasVisibleWindows: Bool) -> Bool {
        AppActivationPolicyController.shared.adoptUserSession()
        if hasVisibleWindows { return true }
        showWelcomeWindow()
        return false
    }

    // MARK: - Phase Transitions

    private func deliver(_ intents: [LaunchIntent]) {
        guard !intents.isEmpty else { return }
        if phase.isAcceptingIntents {
            pendingIntents.append(contentsOf: intents)
            WindowOpener.shared.closeWelcome()
        } else {
            Task { [weak self] in
                guard let self else { return }
                for intent in intents {
                    await LaunchIntentRouter.shared.route(intent)
                }
                self.dismissWelcomeIfMainWindowVisible()
            }
        }
    }

    private func transitionToRouting() {
        guard hasFinishedLaunching else { return }
        phase = .routing
        let intents = pendingIntents
        pendingIntents.removeAll()

        Task { [weak self] in
            guard let self else { return }
            for intent in intents {
                await LaunchIntentRouter.shared.route(intent)
            }
            self.dismissWelcomeIfMainWindowVisible()
            self.runStartupBehaviorIfNeeded(skipping: intents)
            self.phase = .ready
            self.finalizeWindowsIfNoVisibleMain(intents: intents)
        }
    }

    private func dismissWelcomeIfMainWindowVisible() {
        guard NSApp.windows.contains(where: { Self.isMainWindow($0) && $0.isVisible }) else { return }
        WindowOpener.shared.closeWelcome()
    }

    /// A launch nobody asked for opens nothing, whatever the startup behaviour says. Reopening the
    /// last session, or falling back to the welcome window, would put the person's connections on
    /// screen because a client asked a question.
    private func runStartupBehaviorIfNeeded(skipping intents: [LaunchIntent]) {
        guard AppActivationPolicyController.shared.origin == .user else { return }
        guard intents.isEmpty else { return }

        let general = AppSettingsStorage.shared.loadGeneral()
        switch general.startupBehavior {
        case .showWelcome:
            for window in NSApp.windows where Self.isMainWindow(window) {
                window.close()
            }
        case .reopenLast:
            reopenLastSession()
        }
    }

    private func reopenLastSession() {
        guard !NSApp.windows.contains(where: {
            ConnectionWindowIdentity.isConnectionWindow($0.identifier?.rawValue)
        }) else { return }

        let connectionIds = LastOpenConnectionsStorage.shared.load()
        guard !connectionIds.isEmpty else { return }

        let knownIds = Set(ConnectionStorage.shared.loadConnections().map(\.id))
        var frontWindow: NSWindow?
        for connectionId in connectionIds where knownIds.contains(connectionId) {
            WindowManager.shared.openTab(
                payload: EditorTabPayload(connectionId: connectionId, intent: .restoreOrDefault),
                activate: false,
                autoConnect: true
            )
            if frontWindow == nil {
                frontWindow = WindowManager.shared.window(for: connectionId)
            }
        }

        guard let frontWindow else { return }
        WindowOpener.shared.closeWelcome()
        frontWindow.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private func finalizeWindowsIfNoVisibleMain(intents: [LaunchIntent]) {
        guard AppActivationPolicyController.shared.origin == .user else { return }
        guard intents.isEmpty else { return }
        guard !NSApp.windows.contains(where: { Self.isMainWindow($0) && $0.isVisible }) else { return }
        showWelcomeWindow()
    }

    // MARK: - Window Identification

    internal static func isMainWindow(_ window: NSWindow) -> Bool {
        ConnectionWindowIdentity.isPrimaryWindow(window.identifier?.rawValue)
    }

    internal static func isWelcomeWindow(_ window: NSWindow) -> Bool {
        ConnectionWindowIdentity.isWelcomeWindow(window.identifier?.rawValue)
    }

    private func showWelcomeWindow() {
        WindowOpener.shared.openWelcome()
    }
}
