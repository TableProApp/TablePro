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
    func runStartupBehavior(hadIntents: Bool)
    func presentWelcomeIfNoMainWindow(hadIntents: Bool)
    func presentWelcome()
    /// Routing has finished. The live environment has usually completed the launch already, off
    /// the first window becoming key; this is what covers a launch that shows no window.
    func launchDidComplete()
}

@MainActor
internal final class LiveLaunchEnvironment: LaunchEnvironment {
    /// Nothing may start the deferred work later than this, however the frame observation goes.
    private static let backstop = Duration.seconds(2)

    private var firstKeyWindowObserver: (any NSObjectProtocol)?
    private var backstopTask: Task<Void, Never>?
    private var hasCompletedLaunch = false
    private var hasMarkedFirstWindow = false

    /// The first window becoming key is the signal, not the end of intent routing.
    ///
    /// `TabRouter.openTable` orders its window and makes it key, and only then awaits
    /// `ensureConnected`. Waiting for routing to return would hold every deferred subsystem, the
    /// MCP server included, behind a database server that may be slow or unreachable, over a window
    /// the person is already looking at.
    ///
    /// The observer stays armed until a frame actually lands. A launch that opens Welcome and then
    /// replaces it with a connection window closes the first candidate before its display link ever
    /// fires, and a view that is hidden or off-display is documented not to drive one; latching on
    /// the candidate rather than on its frame would leave the memory-pressure monitor, the signature
    /// sweep, the history cleanup and the MCP server off for the life of the process.
    internal init() {
        firstKeyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.observeFirstFrame(of: NSApp.keyWindow)
            }
        }
        backstopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.backstop)
            guard !Task.isCancelled else { return }
            self?.finishLaunch()
        }
    }


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
    internal func runStartupBehavior(hadIntents: Bool) {
        guard AppActivationPolicyController.shared.origin == .user else { return }
        guard !hadIntents else { return }

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

    internal func presentWelcomeIfNoMainWindow(hadIntents: Bool) {
        guard AppActivationPolicyController.shared.origin == .user else { return }
        guard !hadIntents else { return }
        guard !NSApp.windows.contains(where: { AppLaunchCoordinator.isMainWindow($0) && $0.isVisible }) else { return }
        presentWelcome()
    }

    internal func presentWelcome() {
        WindowOpener.shared.openWelcome()
    }

    /// Routing is done. A launch that put a window on screen has usually finished already, off that
    /// window's first frame; this is what covers one that shows no window, which is how a process
    /// the MCP bridge started runs.
    internal func launchDidComplete() {
        let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible)
        guard let window else {
            finishLaunch()
            return
        }
        observeFirstFrame(of: window)
    }

    private func observeFirstFrame(of window: NSWindow?) {
        guard !hasCompletedLaunch else { return }
        if !hasMarkedFirstWindow {
            hasMarkedFirstWindow = true
            LaunchTracer.shared.mark(.firstWindowOrdered)
        }
        guard let window else {
            finishLaunch()
            return
        }
        window.afterNextFrame { [weak self] in
            self?.finishLaunch()
        }
    }

    /// The single completion, whichever of the three routes reaches it first. The observer is
    /// removed here rather than in a `deinit`, which cannot reach main-actor state; one of these
    /// lives for the process, held by `AppLaunchCoordinator.shared`.
    private func finishLaunch() {
        guard !hasCompletedLaunch else { return }
        hasCompletedLaunch = true
        backstopTask?.cancel()
        backstopTask = nil
        if let firstKeyWindowObserver {
            NotificationCenter.default.removeObserver(firstKeyWindowObserver)
            self.firstKeyWindowObserver = nil
        }

        if !hasMarkedFirstWindow {
            hasMarkedFirstWindow = true
            LaunchTracer.shared.mark(.firstWindowOrdered)
        }
        LaunchTracer.shared.mark(.firstFramePresented)
        PostLaunchWork.start()
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
