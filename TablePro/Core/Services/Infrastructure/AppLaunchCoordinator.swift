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
            self.runStartupBehaviorIfNeeded(skipping: intents)
            self.phase = .ready
            self.finalizeWindowsIfNoVisibleMain(intents: intents)
        }
    }

    private func runStartupBehaviorIfNeeded(skipping intents: [LaunchIntent]) {
        guard intents.isEmpty else {
            closeRestoredMainWindowsExcept(intents: intents)
            return
        }
        let general = AppSettingsStorage.shared.loadGeneral()
        guard general.startupBehavior == .reopenLast else {
            closeRestoredMainWindowsExcept(intents: intents)
            return
        }
        let openIds = AppSettingsStorage.shared.loadLastOpenConnectionIds()
        if !openIds.isEmpty {
            attemptAutoReconnect(connectionIds: openIds)
            return
        }
        if let lastId = AppSettingsStorage.shared.loadLastConnectionId() {
            attemptAutoReconnect(connectionIds: [lastId])
            return
        }
        Task { [weak self] in
            let diskIds = await TabDiskActor.shared.connectionIdsWithSavedState()
            if !diskIds.isEmpty {
                self?.attemptAutoReconnect(connectionIds: diskIds)
            } else {
                self?.closeRestoredMainWindowsExcept(intents: [])
            }
        }
    }

    private func finalizeWindowsIfNoVisibleMain(intents: [LaunchIntent]) {
        guard intents.isEmpty else { return }
        guard !NSApp.windows.contains(where: { Self.isMainWindow($0) && $0.isVisible }) else { return }
        showWelcomeWindow()
    }

    private func closeRestoredMainWindowsExcept(intents: [LaunchIntent]) {
        let preserved = Set(intents.compactMap { $0.targetConnectionId })
        for window in NSApp.windows where Self.isMainWindow(window) {
            if let id = WindowLifecycleMonitor.shared.connectionId(forWindow: window),
               preserved.contains(id) {
                continue
            }
            window.close()
        }
    }

    private func attemptAutoReconnect(connectionIds: [UUID]) {
        let saved = ConnectionStorage.shared.loadConnections()
        let valid = connectionIds.compactMap { id in
            saved.first(where: { $0.id == id })
        }
        guard !valid.isEmpty else {
            AppSettingsStorage.shared.saveLastOpenConnectionIds([])
            AppSettingsStorage.shared.saveLastConnectionId(nil)
            closeRestoredMainWindowsExcept(intents: [])
            showWelcomeWindow()
            return
        }
        for window in NSApp.windows where Self.isWelcomeWindow(window) {
            window.orderOut(nil)
        }
        Task { [weak self] in
            for connection in valid {
                let payload = EditorTabPayload(
                    connectionId: connection.id, intent: .restoreOrDefault
                )
                WindowManager.shared.openTab(payload: payload)
                do {
                    try await DatabaseManager.shared.ensureConnected(connection)
                } catch is CancellationError {
                    for window in WindowLifecycleMonitor.shared.windows(for: connection.id) {
                        window.close()
                    }
                } catch {
                    Self.logger.error("Auto-reconnect failed for '\(connection.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                    for window in WindowLifecycleMonitor.shared.windows(for: connection.id) {
                        window.close()
                    }
                }
            }
            for window in NSApp.windows where Self.isWelcomeWindow(window) {
                window.close()
            }
            if !NSApp.windows.contains(where: { Self.isMainWindow($0) && $0.isVisible }) {
                self?.showWelcomeWindow()
            }
        }
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
