//
//  WelcomeWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts `WelcomeWindowView` in an AppKit window so the app no longer needs a SwiftUI
/// scene for it. One instance is kept for the app's lifetime, matching the single-window scene
/// it replaces.
@MainActor
internal final class WelcomeWindowController: NSWindowController {
    private static let contentSize = NSSize(width: 800, height: 480)

    private static var shared: WelcomeWindowController?

    internal static func present() {
        let controller = shared ?? WelcomeWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private convenience init() {
        let content = WelcomeWindowView()
            .frame(width: Self.contentSize.width, height: Self.contentSize.height)
            .environment(\.appServices, .live)
        let hosting = NSHostingController(rootView: content)
        /// A standalone window wants the content's minimum to become the window's, unlike a
        /// split pane's host, where the same minimum would pin the window's dividers.
        hosting.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Welcome to TablePro")
        window.identifier = NSUserInterfaceItemIdentifier(SceneId.welcome)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isRestorable = false
        window.collectionBehavior.insert(.fullScreenNone)
        /// A hidden titlebar has nowhere to draw a tab bar, and the app leaves automatic
        /// window tabbing on, so this window has to opt out for itself.
        window.tabbingMode = .disallowed
        window.setContentSize(Self.contentSize)
        window.applyAutosaveName(SceneId.welcome)
        self.init(window: window)
    }
}
