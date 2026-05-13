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
        guard intents.isEmpty else { return }

        let general = AppSettingsStorage.shared.loadGeneral()
        if general.startupBehavior == .showWelcome {
            for window in NSApp.windows where Self.isMainWindow(window) {
                window.close()
            }
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
