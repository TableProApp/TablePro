//
//  WhatsNewWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts the What's New notes in an ordinary `NSWindowController`, like every other window in the
/// app. One instance for the app's lifetime, so reopening from the menu raises the same window
/// rather than stacking copies.
///
/// Pull-only. Nothing opens this on launch or after an update installs: updates now apply on quit
/// with no dialog, and a window that appeared after each one would be more than a hundred
/// interruptions a year spent on exactly what background installs remove.
@MainActor
internal final class WhatsNewWindowController: NSWindowController {
    private static var shared: WhatsNewWindowController?

    internal static func present() {
        let controller = shared ?? WhatsNewWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    internal convenience init() {
        let content = WhatsNewView {
            guard let url = URL(string: MainMenuLink.changelog) else { return }
            NSWorkspace.shared.open(url)
        }
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "What's New")
        window.keepsKeyViewLoopCurrent()
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isRestorable = false
        window.setContentSize(NSSize(width: 480, height: 380))
        window.center()
        self.init(window: window)
    }
}
