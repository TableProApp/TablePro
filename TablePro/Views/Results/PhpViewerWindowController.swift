//
//  PhpViewerWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
final class PhpViewerWindowController {
    private static var activeWindows: [ObjectIdentifier: PhpViewerWindowController] = [:]
    private static let defaultSize = NSSize(width: 640, height: 500)
    private static let minSize = NSSize(width: 400, height: 300)
    private static let autosaveName: NSWindow.FrameAutosaveName = "PhpViewerWindow"

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    static func open(text: String?, columnName: String?) {
        let controller = PhpViewerWindowController()
        controller.showWindow(text: text, columnName: columnName)
    }

    private func showWindow(text: String?, columnName: String?) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("php-viewer")
        if let columnName {
            window.title = String(format: String(localized: "PHP — %@"), columnName)
        } else {
            window.title = String(localized: "PHP Viewer")
        }
        window.isReleasedWhenClosed = false
        window.minSize = Self.minSize
        window.collectionBehavior = [.fullScreenPrimary]

        let closeWindow: () -> Void = { [weak window] in window?.close() }
        let contentView = PhpViewerWindowContent(
            initialValue: text,
            onDismiss: closeWindow
        )
        window.contentView = NSHostingView(rootView: contentView)

        self.window = window

        let key = ObjectIdentifier(self)
        Self.activeWindows[key] = self

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Self.activeWindows.removeValue(forKey: key)
                self?.closeObserver.map { NotificationCenter.default.removeObserver($0) }
                self?.closeObserver = nil
                self?.window = nil
            }
        }

        window.applyAutosaveName(Self.autosaveName)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Window Content

private struct PhpViewerWindowContent: View {
    let initialValue: String?
    let onDismiss: (() -> Void)?

    var body: some View {
        PhpViewerView(
            rawValue: initialValue ?? "",
            onDismiss: onDismiss,
            onPopOut: nil
        )
    }
}
