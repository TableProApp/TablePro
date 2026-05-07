//
//  InlineAssistantOverlayController.swift
//  TablePro
//

import AppKit
import CodeEditTextView
import SwiftUI

@MainActor
final class InlineAssistantOverlayController {
    private weak var textView: TextView?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<InlineAssistantPromptView>?
    private var anchorRange = NSRange(location: 0, length: 0)
    private var parentObservers: [NSObjectProtocol] = []

    private static let topMargin: CGFloat = 6
    private static let panelMargin: CGFloat = 8

    func present(
        view: InlineAssistantPromptView,
        anchorRange: NSRange,
        in textView: TextView
    ) {
        dismiss()
        self.textView = textView
        self.anchorRange = anchorRange

        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 60),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior.insert(.transient)
        panel.collectionBehavior.insert(.moveToActiveSpace)
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting

        guard let parentWindow = textView.window else { return }
        parentWindow.addChildWindow(panel, ordered: .above)
        repositionPanel()
        installParentObservers(parentWindow: parentWindow)

        panel.makeKeyAndOrderFront(nil)
    }

    func updateRootView(_ view: InlineAssistantPromptView) {
        hostingView?.rootView = view
        repositionPanel()
    }

    func dismiss() {
        if let parent = panel?.parent {
            parent.removeChildWindow(panel ?? NSPanel())
        }
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        textView = nil
        for observer in parentObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        parentObservers.removeAll()
    }

    deinit {
        for observer in parentObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func installParentObservers(parentWindow: NSWindow) {
        let center = NotificationCenter.default
        let queue: OperationQueue = .main

        let resize = center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: parentWindow,
            queue: queue
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionPanel() }
        }
        let move = center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: parentWindow,
            queue: queue
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionPanel() }
        }
        parentObservers.append(contentsOf: [resize, move])
    }

    private func repositionPanel() {
        guard let panel, let textView else { return }
        guard let rect = anchorScreenRect(in: textView) else { return }

        var contentSize = panel.contentView?.fittingSize ?? NSSize(width: 480, height: 60)
        if contentSize.width < 360 { contentSize.width = 360 }
        if contentSize.height < 60 { contentSize.height = 60 }

        let parent = textView.window
        let screenFrame = parent?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        var origin = NSPoint(
            x: rect.minX,
            y: rect.maxY + Self.topMargin
        )

        if origin.x + contentSize.width + Self.panelMargin > screenFrame.maxX {
            origin.x = max(screenFrame.minX + Self.panelMargin, screenFrame.maxX - contentSize.width - Self.panelMargin)
        }
        if origin.x < screenFrame.minX + Self.panelMargin {
            origin.x = screenFrame.minX + Self.panelMargin
        }
        if origin.y + contentSize.height + Self.panelMargin > screenFrame.maxY {
            origin.y = rect.minY - contentSize.height - Self.topMargin
        }
        if origin.y < screenFrame.minY + Self.panelMargin {
            origin.y = screenFrame.minY + Self.panelMargin
        }

        panel.setFrame(NSRect(origin: origin, size: contentSize), display: true)
    }

    private func anchorScreenRect(in textView: TextView) -> NSRect? {
        let location = anchorRange.location
        guard let rectInView = textView.layoutManager.rectForOffset(location) else { return nil }

        let width = max(rectInView.width, 1)
        let height = max(rectInView.height, 16)
        let viewRect = NSRect(x: rectInView.origin.x, y: rectInView.origin.y, width: width, height: height)
        let windowRect = textView.convert(viewRect, to: nil)
        return textView.window?.convertToScreen(windowRect)
    }
}
