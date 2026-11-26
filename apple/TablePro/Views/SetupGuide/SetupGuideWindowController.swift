import AppKit
import os
import SwiftUI
import TableProImport

// An auxiliary window, not a sheet: the flow is long, and Welcome's one sheet slot belongs to routed requests.
@MainActor
internal final class SetupGuideWindowController: NSWindowController, NSWindowDelegate {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SetupGuide")
    private static let contentSize = NSSize(width: 640, height: 660)
    private static let minimumContentSize = NSSize(width: 600, height: 560)
    private static var shared: SetupGuideWindowController?

    private let model: SetupGuideModel

    internal static func present(trigger: SetupGuideGate.Trigger) {
        logger.info("Setup guide opened from \(String(describing: trigger), privacy: .public)")
        if let shared {
            shared.bringForward()
            return
        }
        let controller = SetupGuideWindowController(model: SetupGuideModel())
        shared = controller
        controller.placeOverWelcome()
        controller.bringForward()
    }

    private init(model: SetupGuideModel) {
        self.model = model
        let hosting = NSHostingController(rootView: SetupGuideView(model: model))
        if #available(macOS 14.0, *) {
            // A hosted import view's title or toolbar must not reach the guide's window.
            hosting.sceneBridgingOptions = []
        }
        let window = NSWindow.titled(String(localized: "Setup Guide"), contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.setupGuide)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // The title stays set: the Window menu and VoiceOver read it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert([.fullScreenNone, .fullScreenDisallowsTiling])
        window.contentMinSize = Self.minimumContentSize
        window.setContentSize(Self.contentSize)
        super.init(window: window)
        window.delegate = self
        model.onEnd = { [weak self] ending in
            self?.finish(with: ending)
        }
        model.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SetupGuideWindowController does not support NSCoder init")
    }

    private func bringForward() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private func placeOverWelcome() {
        guard let window else { return }
        guard let welcome = NSApp.windows.first(where: { AppLaunchCoordinator.isWelcomeWindow($0) && $0.isVisible }) else {
            window.center()
            return
        }
        let size = window.frame.size
        let origin = NSPoint(x: welcome.frame.midX - size.width / 2, y: welcome.frame.midY - size.height / 2)
        window.setFrame(window.constrainFrameRect(NSRect(origin: origin, size: size), to: welcome.screen), display: false)
    }

    // The handoff runs once the guide has closed, so a sheet it opens lands on Welcome with nothing in front.
    private func finish(with ending: SetupGuideEnding) {
        window?.close()
        SetupGuideHandoff.perform(ending)
    }

    // Every ending passes here: Finish, Skip, the close button and Cmd-W.
    internal func windowWillClose(_ notification: Notification) {
        model.stop()
        if Self.shared === self {
            Self.shared = nil
        }
        SetupGuidePresenter.shared.guideDidClose()
    }
}

@MainActor
internal enum SetupGuideHandoff {
    internal static func perform(_ ending: SetupGuideEnding, router: WelcomeRouter = .shared) {
        switch ending {
        case .newConnection:
            WindowOpener.shared.openConnectionForm()
        case .sample:
            SampleDatabaseLauncher.open()
        case .handOff(.stay):
            return
        case .handOff(let handoff):
            router.route(.importHandoff(handoff))
        case .command(let command):
            router.route(command.welcomeRequest)
        }
    }
}
