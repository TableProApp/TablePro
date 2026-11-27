//
//  ContentWindow.swift
//  TablePro
//

import AppKit

// The four content windows: main, Data File, Compare & Sync and the value viewers. From macOS 26 the theme
// reaches the toolbar and titlebar only through `backgroundColor`, and only while the titlebar draws no
// background of its own.
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

    // The full-screen hooks run either side of the style mask flipping, so they name the state they move to.
    internal func applyTitlebarPolicy(isFullScreen: Bool? = nil) {
        guard ThemeWindowBackdrop.canReachChrome else { return }
        titlebarAppearsTransparent = Self.titlebarIsTransparent(
            isFullScreen: isFullScreen ?? styleMask.contains(.fullScreen)
        )
    }

    // Full screen moves the titlebar into a window of its own. Transparent over a themed window, it draws an
    // opaque system backstop under one section in place of the window color, the sidebar's when there is an
    // inspector, and changing the color once it is up does not remove it
    // (apple/scripts/probes/check-fullscreen-titlebar-backstop.sh).
    internal static func titlebarIsTransparent(isFullScreen: Bool) -> Bool {
        !isFullScreen
    }

    // AppKit can refuse full screen after posting willEnterFullScreen, and tells only the delegate.
    internal func fullScreenEntryDidFail() {
        applyTitlebarPolicy(isFullScreen: false)
    }

    @objc private func willEnterFullScreen(_ notification: Notification) {
        applyTitlebarPolicy(isFullScreen: true)
    }

    @objc private func didExitFullScreen(_ notification: Notification) {
        applyTitlebarPolicy(isFullScreen: false)
    }
}
