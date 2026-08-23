//
//  CompareSyncWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts `CompareSyncWindowView` in an AppKit window. The registry keyed by the prefilled
/// source is the behaviour `WindowGroup(for:)` gave for free: a repeat open for the same
/// source focuses the comparison already in progress instead of starting a second one.
@MainActor
internal final class CompareSyncWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [UUID?: CompareSyncWindowController] = [:]

    internal static func present(prefillSource connectionId: UUID?) {
        let controller = controllers[connectionId] ?? CompareSyncWindowController(prefillSource: connectionId)
        controllers[connectionId] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private convenience init(prefillSource connectionId: UUID?) {
        let content = CompareSyncWindowView(prefillSourceConnectionId: connectionId)
            .environment(\.appServices, .live)
        let hosting = NSHostingController(rootView: content)
        /// A standalone window wants the content's minimum to become the window's, unlike a
        /// split pane's host, where the same minimum would pin the window's dividers.
        hosting.sizingOptions = [.minSize]

        let window = NSWindow.titled(String(localized: "Compare & Sync"), contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.compareSync)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isRestorable = false
        window.setContentSize(NSSize(width: 1_040, height: 680))
        window.setFrameAutosaveName(WindowIdentifier.compareSync)
        self.init(window: window)
        window.delegate = self
    }

    internal func windowWillClose(_ notification: Notification) {
        Self.controllers = Self.controllers.filter { $0.value !== self }
    }
}
