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

    // A transparent titlebar lets the content under it take the press, so AppKit never sees the double-click it turns
    // into the user's titlebar action, and only the window drag still worked there. Where content, not a control, is
    // under the pointer, the window runs that action itself; the titlebar's own views still answer as AppKit's do.
    override internal func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2, takesTitlebarDoubleClick(at: event.locationInWindow) {
            performTitlebarDoubleClickAction()
            return
        }
        super.sendEvent(event)
    }

    internal func takesTitlebarDoubleClick(at point: NSPoint) -> Bool {
        guard point.y >= contentLayoutRect.maxY,
              let contentView,
              let frameView = contentView.superview,
              let hit = frameView.hitTest(point),
              hit.isDescendant(of: contentView),
              !(hit is NSControl)
        else { return false }
        var view: NSView? = hit
        while let current = view, current !== frameView {
            guard current.mouseDownCanMoveWindow else { return false }
            view = current.superview
        }
        return true
    }

    // Read when it is needed, so a change in System Settings applies at once.
    internal static var titlebarDoubleClickAction: () -> TitlebarDoubleClickAction = { .current }

    private func performTitlebarDoubleClickAction() {
        switch Self.titlebarDoubleClickAction() {
        case .zoom: performZoom(nil)
        case .minimize: performMiniaturize(nil)
        case .none: break
        }
    }

    // Hiding the toolbar drops the content's top safe area, so the titlebar is decided again.
    override internal func toggleToolbarShown(_ sender: Any?) {
        super.toggleToolbarShown(sender)
        applyTitlebarPolicy()
    }

    // The full-screen hooks run either side of the style mask flipping, so they name the state they move to.
    internal func applyTitlebarPolicy(isFullScreen: Bool? = nil) {
        guard ThemeWindowBackdrop.canReachChrome else { return }
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
