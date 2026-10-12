//
//  QuickSwitcherPanel.swift
//  TablePro
//

import AppKit
import SwiftUI

private let fallbackScreenFrame = NSRect(x: 0, y: 0, width: 1_280, height: 800)

/// Whether a panel takes the keyboard. Open Quickly and the switchers do: they own a search field.
/// The recent-tab switcher must not: it is driven by a chord held in the window behind it, and a
/// panel that took key status would dim that window's title bar and move the key events away from
/// the editor for the length of a Control-Tab.
internal enum QuickSwitcherPanelFocus: Equatable {
    case key
    case passive
}

internal final class QuickSwitcherPanel: NSPanel {
    private let focus: QuickSwitcherPanelFocus

    init<Content: View>(
        hostingController: NSHostingController<Content>,
        surfaceCornerRadius: CGFloat,
        focus: QuickSwitcherPanelFocus = .key,
        accessibilityIdentifier: String = "quick-switcher-panel"
    ) {
        self.focus = focus
        hostingController.sizingOptions = []
        let proposal = NSScreen.main?.visibleFrame.size ?? fallbackScreenFrame.size
        let contentSize = hostingController.sizeThatFits(in: proposal)
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        /// Named on the window, the same way the main window is: AppKit publishes `identifier` as
        /// the window's accessibility identifier, so a client can scope a search to this panel
        /// instead of walking the whole application. A SwiftUI modifier could not do it, because an
        /// identifier on the content view overwrites the one every control inside it publishes.
        identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        isFloatingPanel = true
        level = .floating
        collectionBehavior.insert(.fullScreenAuxiliary)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        contentViewController = hostingController
        setContentSize(contentSize)
        /// A panel that never becomes key still takes the clicks that land on it. The passive one
        /// is a readout of a chord held elsewhere, so a click goes to whatever is under it.
        ignoresMouseEvents = focus == .passive
        maskContentToSurfaceShape(cornerRadius: surfaceCornerRadius)
    }

    /// Liquid Glass paints a faint wash across the hosting view's whole bounds, outside the shape
    /// handed to `glassEffect`, and SwiftUI cannot reach it: the glass backdrop is a layer beneath
    /// the SwiftUI render tree, so a `clipShape` over the surface leaves the wash exactly as it is.
    /// Measured on macOS 27 by capturing the panel window without its shadow: the corners outside
    /// the rounded surface carry alpha 5 to 11 unmasked and 0 masked, a `clipShape` on the surface
    /// changes nothing, and removing the `GlassEffectContainer` changes nothing either. That wash
    /// over the square window bounds is the outline this masks away. Below macOS 26 the surface
    /// clips itself and its corners already measure 0, so the mask would buy nothing there and only
    /// cost the offscreen pass that rounding a layer with sublayers forces.
    private func maskContentToSurfaceShape(cornerRadius: CGFloat) {
        guard #available(macOS 26.0, *), let contentView = contentViewController?.view else { return }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return }
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }

    override var canBecomeKey: Bool { focus == .key }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

@MainActor
internal final class QuickSwitcherPanelController: NSObject, NSWindowDelegate {
    private struct Anchor {
        let centerX: CGFloat
        let top: CGFloat
    }

    private static let topOffsetRatio: CGFloat = 0.20

    private var panel: QuickSwitcherPanel?
    private var anchor: Anchor?
    private var presentedIdentity: String?
    private var onClose: (() -> Void)?

    var isPresented: Bool { panel != nil }

    /// Whether the panel on screen is the one a caller named. One controller serves Open Quickly
    /// and Jump to Column, so a command that toggles its own panel has to ask which one is up
    /// rather than whether any is, or Command Shift J would close an Open Quickly it never opened.
    func isPresenting(_ identity: String) -> Bool {
        panel != nil && presentedIdentity == identity
    }

    /// `onClose` runs however the panel goes, including when another presentation replaces it,
    /// which is how a caller that keeps state of its own alongside the panel learns to drop it.
    func present(
        _ content: some View,
        over parentWindow: NSWindow?,
        identity: String? = nil,
        focus: QuickSwitcherPanelFocus = .key,
        accessibilityIdentifier: String = "quick-switcher-panel",
        onClose: (() -> Void)? = nil
    ) {
        dismiss()
        presentedIdentity = identity
        self.onClose = onClose

        let sizeReportingContent = content.onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { [weak self] size in
            self?.contentSizeDidChange(size)
        }
        let hostingController = NSHostingController(rootView: sizeReportingContent)

        let panel = QuickSwitcherPanel(
            hostingController: hostingController,
            surfaceCornerRadius: QuickSwitcherMetrics.cornerRadius,
            focus: focus,
            accessibilityIdentifier: accessibilityIdentifier
        )
        panel.delegate = self
        self.panel = panel

        let reference = parentWindow?.frame
            ?? NSScreen.main?.visibleFrame
            ?? fallbackScreenFrame
        anchor = Anchor(
            centerX: reference.midX,
            top: reference.maxY - reference.height * Self.topOffsetRatio
        )
        applyAnchor(to: panel)
        switch focus {
        case .key:
            panel.makeKeyAndOrderFront(nil)
        case .passive:
            panel.orderFront(nil)
        }
    }

    func dismiss() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel?.contentViewController = nil
        panel = nil
        anchor = nil
        presentedIdentity = nil
        let closed = onClose
        onClose = nil
        closed?()
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        applyAnchor(to: panel)
        panel.invalidateShadow()
    }

    private func contentSizeDidChange(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0, panel.frame.size != size else { return }
        panel.setContentSize(size)
    }

    private func applyAnchor(to panel: QuickSwitcherPanel) {
        guard let anchor else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: anchor.centerX - size.width / 2,
            y: anchor.top - size.height
        ))
    }
}
