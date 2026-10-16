//
//  ContentWindow.swift
//  TablePro
//

import AppKit

/// The window class of the four content windows: main, Data File, Compare & Sync and the value
/// viewers. On macOS 26 and later the theme reaches a toolbar and titlebar only through
/// `backgroundColor`, and only while the titlebar draws no background of its own.
@MainActor
internal class ContentWindow: NSWindow {
    override internal init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        applyTitlebarPolicy()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(willEnterFullScreen(_:)),
            name: NSWindow.willEnterFullScreenNotification, object: self
        )
        center.addObserver(
            self, selector: #selector(didExitFullScreen(_:)),
            name: NSWindow.didExitFullScreenNotification, object: self
        )
    }

    // Hiding the toolbar drops the content's top safe area, so the titlebar is decided again.
    override internal func toggleToolbarShown(_ sender: Any?) {
        super.toggleToolbarShown(sender)
        applyTitlebarPolicy()
    }

    // The full-screen hooks run either side of the style mask flipping, so they name the state they move to.
    internal func applyTitlebarPolicy(isFullScreen: Bool? = nil) {
        // Before macOS 26 a transparent titlebar swaps its material for a flat fill, which would fill chrome.
        guard #available(macOS 26.0, *) else { return }
        titlebarAppearsTransparent = Self.titlebarIsTransparent(
            isFullScreen: isFullScreen ?? styleMask.contains(.fullScreen),
            toolbarVisible: toolbar?.isVisible ?? false
        )
    }

    // In full screen with no toolbar the content reaches the screen edge, and the titlebar that
    // slides down over it needs its own background to stay legible.
    internal static func titlebarIsTransparent(isFullScreen: Bool, toolbarVisible: Bool) -> Bool {
        isFullScreen ? toolbarVisible : true
    }

    @objc private func willEnterFullScreen(_ notification: Notification) {
        applyTitlebarPolicy(isFullScreen: true)
    }

    @objc private func didExitFullScreen(_ notification: Notification) {
        applyTitlebarPolicy(isFullScreen: false)
    }
}
