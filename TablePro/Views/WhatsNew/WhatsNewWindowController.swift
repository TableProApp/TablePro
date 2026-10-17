import AppKit
import SwiftUI

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
