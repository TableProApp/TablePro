//
//  WelcomeWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal final class WelcomeWindowController: NSWindowController {
    private static let contentSize = NSSize(width: 800, height: 480)

    private static var shared: WelcomeWindowController?

    private let viewModel: WelcomeViewModel

    internal static func present() {
        let controller = shared ?? WelcomeWindowController(viewModel: WelcomeViewModel())
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private init(viewModel: WelcomeViewModel) {
        self.viewModel = viewModel
        let content = WelcomeWindowView(vm: viewModel)
            .frame(width: Self.contentSize.width, height: Self.contentSize.height)
            .environment(\.appServices, .live)
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.minSize]

        let window = NSWindow.titled(String(localized: "Welcome to TablePro"), contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.welcome)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isRestorable = false
        window.collectionBehavior.insert(.fullScreenNone)
        window.tabbingMode = .disallowed
        window.setContentSize(Self.contentSize)
        window.applyAutosaveName(WindowIdentifier.welcome)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WelcomeWindowController does not support NSCoder init")
    }

    @objc
    internal func performFind(_ sender: Any?) {
        NotificationCenter.default.post(name: .welcomeWindowFindRequested, object: window)
    }
}

extension WelcomeWindowController: NSMenuItemValidation {
    internal func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performFind(_:)) else { return true }
        return window?.isKeyWindow == true && viewModel.isSearchAvailable
    }
}

internal extension Notification.Name {
    static let welcomeWindowFindRequested = Notification.Name("com.TablePro.welcomeWindowFindRequested")
}
