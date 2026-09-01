//
//  LaunchEnvironment.swift
//  TablePro
//

import AppKit
import Foundation

/// Everything `AppLaunchCoordinator` does to the world, so the coordinator itself is pure
/// orchestration: which intents are collected, when routing runs, and what phase follows.
///
/// The launch sequence had no test of any kind before this existed, because every path through it
/// opened a real window, read the real settings store, or waited on a real timer.
@MainActor
internal protocol LaunchEnvironment: AnyObject {
    /// Runs `body` on the next pass of the main run loop, in common modes so a tracking or modal
    /// loop cannot hold it back.
    func scheduleNextTurn(_ body: @escaping @MainActor () -> Void)
    func route(_ intent: LaunchIntent) async
    func closeWelcome()
    func dismissWelcomeIfMainWindowVisible()
    func runStartupBehavior(skipping intents: [LaunchIntent])
    func presentWelcomeIfNoMainWindow(intents: [LaunchIntent])
    func presentWelcome()
    /// The last thing a launch does: record the frame the first window presents, and start the
    /// subsystem work that window did not need.
    func launchDidComplete()
}

@MainActor
internal final class LiveLaunchEnvironment: LaunchEnvironment {
    internal init() {}

    internal func scheduleNextTurn(_ body: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated(body)
        }
    }

    internal func route(_ intent: LaunchIntent) async {
        await LaunchIntentRouter.shared.route(intent)
    }

    internal func closeWelcome() {
        WindowOpener.shared.closeWelcome()
    }

    internal func dismissWelcomeIfMainWindowVisible() {
        guard NSApp.windows.contains(where: { AppLaunchCoordinator.isMainWindow($0) && $0.isVisible }) else { return }
        WindowOpener.shared.closeWelcome()
    }

    /// A launch nobody asked for opens nothing, whatever the startup behaviour says. Reopening the
    /// last session, or falling back to the welcome window, would put the person's connections on
    /// screen because a client asked a question.
    internal func runStartupBehavior(skipping intents: [LaunchIntent]) {
        guard AppActivationPolicyController.shared.origin == .user else { return }
        guard intents.isEmpty else { return }

        let general = AppSettingsStorage.shared.loadGeneral()
        switch general.startupBehavior {
        case .showWelcome:
            for window in NSApp.windows where AppLaunchCoordinator.isMainWindow(window) {
                window.close()
            }
        case .reopenLast:
            reopenLastSession()
        }
    }

    internal func presentWelcomeIfNoMainWindow(intents: [LaunchIntent]) {
        guard AppActivationPolicyController.shared.origin == .user else { return }
        guard intents.isEmpty else { return }
        guard !NSApp.windows.contains(where: { AppLaunchCoordinator.isMainWindow($0) && $0.isVisible }) else { return }
        presentWelcome()
    }

    internal func presentWelcome() {
        WindowOpener.shared.openWelcome()
    }

    internal func launchDidComplete() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else {
            LaunchTracer.shared.mark(.firstWindowOrdered)
            LaunchTracer.shared.mark(.firstFramePresented)
            PostLaunchWork.start()
            return
        }
        LaunchTracer.shared.mark(.firstWindowOrdered)
        window.afterNextFrame {
            MainActor.assumeIsolated {
                LaunchTracer.shared.mark(.firstFramePresented)
                PostLaunchWork.start()
            }
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
}
