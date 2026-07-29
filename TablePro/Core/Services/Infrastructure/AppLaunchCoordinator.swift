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

    private static let logger = Logger(subsystem: "com.TablePro", category: "AppLaunchCoordinator")
    internal static let collectionWindow: Duration = .milliseconds(150)

    private(set) var phase: LaunchPhase = .launching

    private var pendingIntents: [LaunchIntent] = []
    private var deadlineTask: Task<Void, Never>?
    private var hasFinishedLaunching = false

    private init() {}

    // MARK: - App Lifecycle Hooks

    internal func didFinishLaunching() {
        hasFinishedLaunching = true
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
        deliver(intents)
    }

    internal func handleHandoff(_ activity: NSUserActivity) {
        guard let connectionIdString = activity.userInfo?["connectionId"] as? String,
              let connectionId = UUID(uuidString: connectionIdString) else { return }
        let table = activity.userInfo?["tableName"] as? String

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

    internal func handleReopen(hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }
        showWelcomeWindow()
        return false
    }

    // MARK: - Phase Transitions

    private func deliver(_ intents: [LaunchIntent]) {
        guard !intents.isEmpty else { return }
        if phase.isAcceptingIntents {
            pendingIntents.append(contentsOf: intents)
            for window in NSApp.windows where Self.isWelcomeWindow(window) {
                window.orderOut(nil)
            }
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
        WindowOpener.shared.orderOutWelcome()
    }

    private func runStartupBehaviorIfNeeded(skipping intents: [LaunchIntent]) {
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
        guard !NSApp.windows.contains(where: { Self.isMainWindow($0) }) else { return }

        let connectionIds = LastOpenConnectionsStorage.shared.load()
        guard !connectionIds.isEmpty else { return }

        let connectionsById = Dictionary(
            ConnectionStorage.shared.loadConnections().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var openedAny = false
        for connectionId in connectionIds {
            guard let connection = connectionsById[connectionId] else { continue }
            WindowManager.shared.openTab(
                payload: EditorTabPayload(connectionId: connectionId, intent: .restoreOrDefault)
            )
            openedAny = true
            Task {
                do {
                    try await DatabaseManager.shared.ensureConnected(connection)
                } catch {
                    Self.logger.error(
                        "[restore] reopen connect failed for \(connectionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        if openedAny {
            WindowOpener.shared.orderOutWelcome()
        }
    }

    private func finalizeWindowsIfNoVisibleMain(intents: [LaunchIntent]) {
        guard intents.isEmpty else { return }
        guard !NSApp.windows.contains(where: { Self.isMainWindow($0) && $0.isVisible }) else { return }
        showWelcomeWindow()
    }

    // MARK: - Window Identification

    internal static func isMainWindow(_ window: NSWindow) -> Bool {
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "main" || raw.hasPrefix("main-")
    }

    internal static func isWelcomeWindow(_ window: NSWindow) -> Bool {
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == SceneId.welcome || raw.hasPrefix("\(SceneId.welcome)-")
    }

    internal static func isConnectionFormWindow(_ window: NSWindow) -> Bool {
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == SceneId.connectionForm || raw.hasPrefix("\(SceneId.connectionForm)-")
    }

    private func showWelcomeWindow() {
        WindowOpener.shared.openWelcome()
    }
}
