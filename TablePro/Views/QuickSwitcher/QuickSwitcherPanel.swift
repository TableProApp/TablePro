//
//  QuickSwitcherPanel.swift
//  TablePro
//

import AppKit
import SwiftUI

internal final class QuickSwitcherPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentView.fittingSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior.insert(.fullScreenAuxiliary)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
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

    var isPresented: Bool { panel != nil }

    func present(_ content: some View, over parentWindow: NSWindow?) {
        dismiss()

        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = .preferredContentSize

        let panel = QuickSwitcherPanel(contentView: hostingView)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss() }
        self.panel = panel

        let reference = parentWindow?.frame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
        anchor = Anchor(
            centerX: reference.midX,
            top: reference.maxY - reference.height * Self.topOffsetRatio
        )
        applyAnchor(to: panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let panel else { return }
        panel.delegate = nil
        panel.onCancel = nil
        self.panel = nil
        anchor = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        applyAnchor(to: panel)
        panel.invalidateShadow()
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

internal struct QuickSwitcherPanelBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.cornerRadius = cornerRadius
            return glassView
        }
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        return effectView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let glassView = nsView as? NSGlassEffectView {
            glassView.cornerRadius = cornerRadius
            return
        }
        if let effectView = nsView as? NSVisualEffectView {
            effectView.layer?.cornerRadius = cornerRadius
        }
    }
}
