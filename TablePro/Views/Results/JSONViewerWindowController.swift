//
//  JSONViewerWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
final class JSONViewerWindowController {
    private static var activeWindows: [ObjectIdentifier: JSONViewerWindowController] = [:]
    private static var lastCascadePoint: NSPoint = .zero
    private static let defaultSize = NSSize(width: 640, height: 500)
    private static let minSize = NSSize(width: 400, height: 300)
    private static let sizeKey = "JSONViewerWindow.size"

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    static func open(
        text: String?,
        columnName: String?,
        isEditable: Bool,
        onCommit: ((String) -> Void)?
    ) {
        let controller = JSONViewerWindowController()
        controller.showWindow(text: text, columnName: columnName, isEditable: isEditable, onCommit: onCommit)
    }

    private func showWindow(
        text: String?,
        columnName: String?,
        isEditable: Bool,
        onCommit: ((String) -> Void)?
    ) {
        let savedSize = UserDefaults.standard.size(forKey: Self.sizeKey) ?? Self.defaultSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: savedSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("json-viewer")
        window.title = columnName.map { "JSON — \($0)" } ?? String(localized: "JSON Viewer")
        window.isReleasedWhenClosed = false
        window.minSize = Self.minSize
        window.collectionBehavior = [.fullScreenPrimary]

        let closeWindow: () -> Void = { [weak window] in window?.close() }
        let contentView = JSONViewerWindowContent(
            initialValue: text,
            isEditable: isEditable,
            onCommit: onCommit,
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
        ) { [weak self] notification in
            Task { @MainActor in
                if let closingWindow = notification.object as? NSWindow {
                    UserDefaults.standard.set(closingWindow.frame.size, forKey: Self.sizeKey)
                }
                Self.activeWindows.removeValue(forKey: key)
                self?.closeObserver.map { NotificationCenter.default.removeObserver($0) }
                self?.closeObserver = nil
                self?.window = nil
            }
        }

        Self.lastCascadePoint = window.cascadeTopLeft(from: Self.lastCascadePoint)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Window Content

private struct JSONViewerWindowContent: View {
    let initialValue: String?
    let isEditable: Bool
    let onCommit: ((String) -> Void)?
    let onDismiss: (() -> Void)?

    @State private var text: String

    init(
        initialValue: String?,
        isEditable: Bool,
        onCommit: ((String) -> Void)?,
        onDismiss: (() -> Void)?
    ) {
        self.initialValue = initialValue
        self.isEditable = isEditable
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self._text = State(initialValue: initialValue?.prettyPrintedAsJson() ?? initialValue ?? "")
    }

    var body: some View {
        JSONViewerView(
            text: $text,
            isEditable: isEditable,
            onDismiss: onDismiss,
            onCommit: isEditable ? { newValue in
                if newValue.isEmpty && initialValue == nil { return }
                let normalizedNew = JSONViewerView.compact(newValue)
                let normalizedOld = JSONViewerView.compact(initialValue)
                if normalizedNew != normalizedOld {
                    onCommit?(newValue)
                }
            } : nil
        )
    }
}

// MARK: - UserDefaults + NSSize

private extension UserDefaults {
    func size(forKey key: String) -> NSSize? {
        guard let string = string(forKey: key) else { return nil }
        let size = NSSizeFromString(string)
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }

    func set(_ size: NSSize, forKey key: String) {
        set(NSStringFromSize(size), forKey: key)
    }
}
