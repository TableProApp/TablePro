//
//  IntegrationsActivityWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts the activity log and connected clients in an AppKit window so the app no longer needs a
/// SwiftUI scene for it. One instance is kept for the app's lifetime, matching the single-window
/// scene it replaces.
@MainActor
internal final class IntegrationsActivityWindowController: NSWindowController {
    private static var shared: IntegrationsActivityWindowController?

    internal static func present() {
        let controller = shared ?? IntegrationsActivityWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private convenience init() {
        let selection = SidebarSelection(IntegrationsActivitySection.activityLog)
        let split = SidebarSplitViewController(
            sidebar: IntegrationsActivitySidebar(selection: selection),
            detail: IntegrationsActivityDetail(selection: selection)
                .environment(\.appServices, .live),
            sidebarThickness: 200...280,
            idealSidebarThickness: 220,
            detailMinimumThickness: 520
        )

        let window = NSWindow.titled(String(localized: "Integrations Activity"), contentViewController: split)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.integrationsActivity)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 720, height: 400)
        window.setContentSize(NSSize(width: 960, height: 600))
        if let autosaveName = SplitViewAutosaveName.current(WindowIdentifier.integrationsActivity) {
            window.setFrameAutosaveName(autosaveName)
        }
        self.init(window: window)
    }
}
