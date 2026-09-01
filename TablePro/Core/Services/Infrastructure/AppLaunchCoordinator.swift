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

    private(set) var phase: LaunchPhase = .launching

    @ObservationIgnored private let environment: any LaunchEnvironment
    private var pendingIntents: [LaunchIntent] = []
    private var hasFinishedLaunching = false

    internal init(environment: any LaunchEnvironment = LiveLaunchEnvironment()) {
        self.environment = environment
    }

    // MARK: - App Lifecycle Hooks

    /// Intents are collected for exactly one run-loop turn rather than a fixed span of time.
    ///
    /// Measured on macOS 27 with a probe app registered for a URL scheme and a document type:
    /// LaunchServices always delivers the gesture that started the app to `application(_:open:)`
    /// before `applicationDidFinishLaunching` returns, coalesces several documents from one gesture
    /// into a single call, and delivers a straggler from a second request 2.4 to 7.1ms later, in
    /// every run before the first turn of the main queue. A timed window buys nothing over that and
    /// costs the person every millisecond of it, because the window they are waiting for is not
    /// built until it closes.
    internal func didFinishLaunching() {
        hasFinishedLaunching = true
        deliver(UITestLaunchEnvironment.launchIntents)
        phase = .collectingIntents
        environment.scheduleNextTurn { [weak self] in
            self?.transitionToRouting()
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
        environment.presentWelcome()
        return false
    }

    // MARK: - Phase Transitions

    /// The one way an intent enters the launch pipeline, whether it came from a URL, a handoff, or
    /// the UI-test environment.
    internal func deliver(_ intents: [LaunchIntent]) {
        guard !intents.isEmpty else { return }
        if phase.isAcceptingIntents {
            pendingIntents.append(contentsOf: intents)
            environment.closeWelcome()
        } else {
            Task { [weak self] in
                guard let self else { return }
                for intent in intents {
                    await environment.route(intent)
                }
                self.environment.dismissWelcomeIfMainWindowVisible()
            }
        }
    }

    private func transitionToRouting() {
        guard hasFinishedLaunching, !phase.isReady, phase != .routing else { return }
        phase = .routing
        let intents = pendingIntents
        pendingIntents.removeAll()

        Task { [weak self] in
            guard let self else { return }
            for intent in intents {
                await environment.route(intent)
            }
            self.environment.dismissWelcomeIfMainWindowVisible()
            self.environment.runStartupBehavior(skipping: intents)
            LaunchTracer.shared.mark(.intentsRouted)
            self.phase = .ready
            self.environment.presentWelcomeIfNoMainWindow(intents: intents)
            self.environment.launchDidComplete()
        }
    }

    // MARK: - Window Identification

    internal static func isMainWindow(_ window: NSWindow) -> Bool {
        ConnectionWindowIdentity.isPrimaryWindow(window.identifier?.rawValue)
    }

    internal static func isWelcomeWindow(_ window: NSWindow) -> Bool {
        ConnectionWindowIdentity.isWelcomeWindow(window.identifier?.rawValue)
    }
}
