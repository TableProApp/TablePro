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
    static let minSize = NSSize(width: 400, height: 300)
    private static let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]

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
        let window = Self.makeWindow(identifier: identifier, title: title, content: content)

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

    /// A hosting view that is a window's content view rewrites that window's size limits from its
    /// SwiftUI content on every constraint pass, so `NSWindow.minSize` alone lasts until the first
    /// one: a viewer with a small toolbar could be dragged down to it. The floor is part of the
    /// content, which is the size the hosting view publishes.
    static func makeWindow<Content: View>(
        identifier: String,
        title: String,
        @ViewBuilder content: (@escaping () -> Void) -> Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.keepsKeyViewLoopCurrent()
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = minSize
        window.collectionBehavior = [.fullScreenPrimary]

        let contentFloor = NSWindow.contentRect(
            forFrameRect: NSRect(origin: .zero, size: minSize),
            styleMask: styleMask
        ).size
        window.contentView = NSHostingView(
            rootView: content { [weak window] in window?.close() }
                .frame(minWidth: contentFloor.width, minHeight: contentFloor.height)
        )
        return window
    }
}
