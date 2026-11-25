//
//  ConnectionEditorWindowFrame.swift
//  TablePro
//

import AppKit

// The window's sizes. The content includes the toolbar band, since the window uses a full-size content view.
enum ConnectionEditorWindowFrame {
    static let sidebarWidth: CGFloat = 220
    static let detailWidth: CGFloat = 560
    static let contentWidth: CGFloat = sidebarWidth + detailWidth
    static let minimumContentHeight: CGFloat = 480
    static let preferredContentHeight: CGFloat = 700
    static let screenMargin: CGFloat = 80
    // A new name: "connection-form" holds 560 wide frames from the single-form editor.
    static let autosaveName = "ConnectionEditorWindow"

    static var minimumContentSize: NSSize {
        NSSize(width: contentWidth, height: minimumContentHeight)
    }

    static func maximumContentHeight(visibleHeight: CGFloat) -> CGFloat {
        max(minimumContentHeight, visibleHeight - screenMargin)
    }

    static func defaultContentSize(visibleHeight: CGFloat) -> NSSize {
        NSSize(width: contentWidth, height: min(preferredContentHeight, maximumContentHeight(visibleHeight: visibleHeight)))
    }

    static func clampedContentSize(_ size: NSSize, visibleHeight: CGFloat) -> NSSize {
        let height = min(max(size.height, minimumContentHeight), maximumContentHeight(visibleHeight: visibleHeight))
        return NSSize(width: contentWidth, height: height)
    }

    // Restored by hand: AppKit lets one open window own an autosave name, and every editor window shares this one.
    @MainActor
    static func apply(to window: NSWindow, autosaveName: String?) {
        let screen = window.screen ?? NSScreen.main
        window.setContentSize(defaultContentSize(visibleHeight: screen?.visibleFrame.height ?? 800))

        // Restored before the size limits go on: AppKit clamps a restored frame to them, which hides an older size.
        let restored = autosaveName.map { window.setFrameUsingName($0) } ?? false
        if restored {
            let visibleHeight = (window.screen ?? screen)?.visibleFrame.height ?? 800
            let content = window.contentRect(forFrameRect: window.frame).size
            let clamped = clampedContentSize(content, visibleHeight: visibleHeight)
            if clamped != content {
                let top = window.frame.maxY
                var frame = window.frameRect(forContentRect: NSRect(origin: window.frame.origin, size: clamped))
                frame.origin.y = top - frame.height
                window.setFrame(frame, display: false)
            }
            window.setFrame(window.constrainFrameRect(window.frame, to: window.screen), display: false)
        } else {
            window.center()
        }
        window.contentMinSize = minimumContentSize
        window.contentMaxSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
    }

    @MainActor
    static func save(_ window: NSWindow, autosaveName: String?) {
        guard let autosaveName else { return }
        window.saveFrame(usingName: autosaveName)
    }
}
