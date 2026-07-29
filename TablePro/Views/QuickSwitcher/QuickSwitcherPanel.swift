//
//  QuickSwitcherPanel.swift
//  TablePro
//

import AppKit
import SwiftUI

private let fallbackScreenFrame = NSRect(x: 0, y: 0, width: 1_280, height: 800)

internal final class QuickSwitcherPanel: NSPanel {
    init<Content: View>(hostingController: NSHostingController<Content>) {
        hostingController.sizingOptions = []
        let proposal = NSScreen.main?.visibleFrame.size ?? fallbackScreenFrame.size
        let contentSize = hostingController.sizeThatFits(in: proposal)
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
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
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        contentViewController = hostingController
        setContentSize(contentSize)
    }

    override var canBecomeKey: Bool { true }
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

    var isPresented: Bool { panel != nil }

    func present(_ content: some View, over parentWindow: NSWindow?) {
        dismiss()

        let sizeReportingContent = content.onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { [weak self] size in
            self?.contentSizeDidChange(size)
        }
        let hostingController = NSHostingController(rootView: sizeReportingContent)

        let panel = QuickSwitcherPanel(hostingController: hostingController)
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
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel?.contentViewController = nil
        panel = nil
        anchor = nil
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
