//
//  ValueViewerWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The detached window a popped-out cell value opens in. Subclasses supply the content and the
/// window's identity; the bookkeeping that keeps a detached window alive lives here once.
@MainActor
internal class ValueViewerWindowController {
    private static var activeWindows: [ObjectIdentifier: ValueViewerWindowController] = [:]
    private static let defaultSize = NSSize(width: 640, height: 500)
    private static let minSize = NSSize(width: 400, height: 300)

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// A popped-out editor commits through the display row it was opened from, so whoever opened
    /// it has to be able to close it once those rows are gone.
    func close() {
        window?.close()
    }

    func present<Content: View>(
        identifier: String,
        title: String,
        autosaveName: NSWindow.FrameAutosaveName,
        @ViewBuilder content: (@escaping () -> Void) -> Content
    ) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: ValueViewerWindowController.defaultSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = ValueViewerWindowController.minSize
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = NSHostingView(rootView: content { [weak window] in window?.close() })

        self.window = window

        let key = ObjectIdentifier(self)
        ValueViewerWindowController.activeWindows[key] = self

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                ValueViewerWindowController.activeWindows.removeValue(forKey: key)
                self?.closeObserver.map { NotificationCenter.default.removeObserver($0) }
                self?.closeObserver = nil
                self?.window = nil
            }
        }

        window.applyAutosaveName(autosaveName)
        window.makeKeyAndOrderFront(nil)
    }
}
